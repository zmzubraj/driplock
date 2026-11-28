package driplock

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/zdev/dripdemo"
)

var dave = testutils.TestAddress("dave")

// fund models `amount` ugnot attached with -send and landing at the realm.
// testing.SetRealm must be called in the test function itself: a realm set
// inside a helper is dropped when the helper returns.
func fund(amount int64) {
	testing.IssueCoins(pkgAddr(), chain.Coins{{"ugnot", amount}})
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
}

func TestCreateCoinStreamFor(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1000)
	id := CreateCoinStreamFor(cross(cur), bob, 20, 100, 0, 0)
	testing.SetOriginSend(nil)

	info, _ := GetStream(id)
	uassert.Equal(t, info.Start+20, info.Cliff)
	uassert.Equal(t, info.Start+100, info.End)

	testing.SetRealm(testing.NewUserRealm(bob))
	sec(15)
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { Withdraw(cross(cur), id) })
	sec(35) // 50s in
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id))
}

func TestRelativeTimesValidation(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1000)
	uassert.AbortsWithMessage(t, cur, "driplock: duration must be between 1 second and 50 years",
		func() { CreateCoinStreamFor(cross(cur), bob, 0, 0, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: cliff must be between 0 and the duration",
		func() { CreateCoinStreamFor(cross(cur), bob, 200, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: cliff must be between 0 and the duration",
		func() { CreateCoinStreamFor(cross(cur), bob, -1, 100, 0, 0) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, 0, StreamCount())
}

func TestBatchCreatesOneStreamPerRecipient(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(600)
	ids := CreateCoinStreamBatch(cross(cur), bob.String()+", "+carol.String()+","+dave.String(), "100, 200,300", 0, 100, 0, 100)
	testing.SetOriginSend(nil)
	uassert.Equal(t, "1,2,3", ids)
	uassert.Equal(t, int64(600), escrowedOf("coin:ugnot"))

	for i, want := range []struct {
		to    address
		total int64
	}{{bob, 100}, {carol, 200}, {dave, 300}} {
		info, ok := GetStream(uint64(i + 1))
		uassert.True(t, ok)
		uassert.Equal(t, want.to, info.Recipient)
		uassert.Equal(t, want.total, info.Total)
		uassert.Equal(t, alice, info.Sender)
	}

	sec(100)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.Equal(t, int64(300), Withdraw(cross(cur), 3))
}

func TestBatchIsAllOrNothing(cur realm, t *testing.T) {
	reset()
	two := bob.String() + "," + carol.String()

	testing.SetRealm(testing.NewUserRealm(alice))
	fund(300)
	uassert.AbortsWithMessage(t, cur, "driplock: amounts add up to 250 but 300 was sent",
		func() { CreateCoinStreamBatch(cross(cur), two, "100,150", 0, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: recipients and amounts must be non-empty lists of the same length",
		func() { CreateCoinStreamBatch(cross(cur), two, "300", 0, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: recipients and amounts must be non-empty lists of the same length",
		func() { CreateCoinStreamBatch(cross(cur), " ", "", 0, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: amount #2 must be a positive integer",
		func() { CreateCoinStreamBatch(cross(cur), two, "300,0", 0, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: amount #1 must be a positive integer",
		func() { CreateCoinStreamBatch(cross(cur), two, "abc,300", 0, 100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: amounts overflow",
		func() { CreateCoinStreamBatch(cross(cur), two, "9223372036854775807,1", 0, 100, 0, 0) })
	// A bad address in the middle reverts the streams created before it.
	uassert.AbortsWithMessage(t, cur, "driplock: invalid recipient address",
		func() { CreateCoinStreamBatch(cross(cur), bob.String()+",nope", "100,200", 0, 100, 0, 0) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, 0, StreamCount())
	uassert.Equal(t, int64(0), escrowedOf("coin:ugnot"))
}

func TestBatchSizeCap(cur realm, t *testing.T) {
	reset()
	addrs := make([]string, MaxBatch+1)
	amts := make([]string, MaxBatch+1)
	for i := range addrs {
		addrs[i] = bob.String()
		amts[i] = "1"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(int64(MaxBatch + 1))
	uassert.AbortsWithMessage(t, cur, "driplock: batch is larger than 50",
		func() {
			CreateCoinStreamBatch(cross(cur), strings.Join(addrs, ","), strings.Join(amts, ","), 0, 100, 0, 0)
		})
	testing.SetOriginSend(nil)
}

func TestBatchRequiresDirectUserCall(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 100}})
	uassert.AbortsWithMessage(t, cur, "driplock: coin streams must be created by a direct user call (maketx call)",
		func() { CreateCoinStreamBatch(cross(cur), bob.String(), "100", 0, 100, 0, 0) })
	testing.SetOriginSend(nil)
}

func TestWithdrawForAlwaysPaysRecipient(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, false)
	sec(40)

	testing.SetRealm(testing.NewUserRealm(carol)) // a stranger, or a bot
	carolBefore, bobBefore := ugnot(carol), ugnot(bob)
	uassert.Equal(t, int64(400), WithdrawFor(cross(cur), id))
	uassert.Equal(t, carolBefore, ugnot(carol))
	uassert.Equal(t, bobBefore+400, ugnot(bob))

	// A code realm can relay too, and still cannot redirect the money.
	sec(10)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/some/keeper"))
	uassert.Equal(t, int64(100), WithdrawFor(cross(cur), id))
	uassert.Equal(t, bobBefore+500, ugnot(bob))
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { WithdrawFor(cross(cur), id) })
}

func TestTransferRecipient(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, true)
	sec(30)

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can transfer the stream",
		func() { TransferRecipient(cross(cur), id, carol) })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can transfer the stream",
		func() { TransferRecipient(cross(cur), id, alice) })

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(300), Withdraw(cross(cur), id))
	uassert.AbortsWithMessage(t, cur, "driplock: new recipient is the current recipient",
		func() { TransferRecipient(cross(cur), id, bob) })
	uassert.AbortsWithMessage(t, cur, "driplock: recipient cannot be this realm",
		func() { TransferRecipient(cross(cur), id, pkgAddr()) })
	TransferRecipient(cross(cur), id, dave)

	// Bob has lost the stream; Dave now owns what is still owed.
	sec(20)
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can withdraw", func() { Withdraw(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.Equal(t, int64(200), Withdraw(cross(cur), id))

	info, _ := GetStream(id)
	uassert.Equal(t, int64(500), info.Withdrawn)
	uassert.Equal(t, dave, info.Recipient)

	// Indexes moved too.
	uassert.True(t, strings.Contains(Render("addr/"+dave.String()), link("1")+")"))
	uassert.True(t, strings.Contains(Render("addr/"+bob.String()), "## Receiving\n\nNone."))

	// The sender's cancel now refunds against the new owner's schedule.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(500), Cancel(cross(cur), id))
	uassert.Equal(t, info.Total, int64(500)+int64(500))
}

func TestGRC20StreamFor(cur realm, t *testing.T) {
	reset()
	const unit = int64(1_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	dripdemo.Faucet(cross(cur))
	dripdemo.Approve(cross(cur), pkgAddr(), 100*unit)
	id := CreateGRC20StreamFor(cross(cur), dave, tokKey, 100*unit, 0, 50, 0, 0)
	sec(50)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.Equal(t, 100*unit, Withdraw(cross(cur), id))
	uassert.Equal(t, 100*unit, dripdemo.BalanceOf(dave))
}

func TestHomeShowsValueLocked(cur realm, t *testing.T) {
	reset()
	uassert.False(t, strings.Contains(Render(""), "## Value locked"))
	newCoinStream(cur, 3_000_000, 0, 100, true)
	home := Render("")
	uassert.True(t, strings.Contains(home, "## Value locked"))
	uassert.True(t, strings.Contains(home, "| coin ugnot | 3 GNOT |"))

	sec(100)
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), 1)
	uassert.True(t, strings.Contains(Render(""), "Nothing locked right now."))
}
