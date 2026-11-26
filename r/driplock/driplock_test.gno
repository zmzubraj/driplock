package driplock

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/zdev/dripdemo"
)

const (
	pkgPath = "gno.land/r/zdev/driplock"
	tokKey  = "gno.land/r/zdev/dripdemo.DRIP"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
)

func reset() {
	streams = avl.Tree{}
	bySender = avl.Tree{}
	byRecipient = avl.Tree{}
	escrowed = avl.Tree{}
	activeByAsset = avl.Tree{}
	everByAddr = avl.Tree{}
	counter = seqid.ID(0)
	testing.SetOriginSend(nil)
}

func pkgAddr() address { return chain.PackageAddress(pkgPath) }

func ugnot(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

// sec advances block time by n seconds, in 5-second blocks.
func sec(n int64) { testing.SkipHeights(n / 5) }

// newCoinStream has alice stream `amount` ugnot to bob over `dur` seconds.
func newCoinStream(cur realm, amount, cliffAfter, dur int64, cancelable bool) uint64 {
	t := time.Now().Unix()
	testing.IssueCoins(pkgAddr(), chain.Coins{{"ugnot", amount}}) // models the -send landing
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
	cliff := int64(0)
	if cliffAfter > 0 {
		cliff = t + cliffAfter
	}
	cancelUntil := int64(0)
	if cancelable {
		cancelUntil = t + dur
	}
	id := CreateCoinStream(cross(cur), bob, t, cliff, t+dur, 0, cancelUntil)
	testing.SetOriginSend(nil)
	return id
}

func TestCoinStreamWithdrawLinear(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, false)
	uassert.Equal(t, uint64(1), id)

	info, ok := GetStream(id)
	uassert.True(t, ok)
	uassert.Equal(t, int64(0), info.Vested)

	sec(50)
	testing.SetRealm(testing.NewUserRealm(bob))
	before := ugnot(bob)
	got := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(500), got)
	uassert.Equal(t, before+500, ugnot(bob))

	// Nothing new in the same block.
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { Withdraw(cross(cur), id) })

	sec(500) // past the end
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id))
	info, _ = GetStream(id)
	uassert.Equal(t, int64(1000), info.Withdrawn)
	uassert.Equal(t, int64(0), escrowedOf("coin:ugnot"))
	uassert.True(t, strings.Contains(Render("1"), "completed"))
}

func TestCliffHoldsThenReleasesAccrued(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1200, 300, 1200, false)
	testing.SetRealm(testing.NewUserRealm(bob))

	sec(295)
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { Withdraw(cross(cur), id) })

	sec(5) // exactly at the cliff
	uassert.Equal(t, int64(300), Withdraw(cross(cur), id))
}

func TestOnlyRecipientWithdrawsOnlySenderCancels(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, true)
	sec(50)

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can withdraw", func() { Withdraw(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, "driplock: only the sender can cancel", func() { Cancel(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can withdraw", func() { Withdraw(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "driplock: only the sender can cancel", func() { Cancel(cross(cur), id) })
}

func TestCancelSplitsExactly(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, true)
	sec(30)

	testing.SetRealm(testing.NewUserRealm(alice))
	aliceBefore := ugnot(alice)
	refund := Cancel(cross(cur), id)
	uassert.Equal(t, int64(700), refund)
	uassert.Equal(t, aliceBefore+700, ugnot(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: stream already canceled", func() { Cancel(cross(cur), id) })

	// Time keeps moving, but the recipient's share is frozen at 300.
	sec(500)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(300), Withdraw(cross(cur), id))
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { Withdraw(cross(cur), id) })

	info, _ := GetStream(id)
	uassert.Equal(t, info.Total, info.Withdrawn+info.Refunded) // invariant 3
	uassert.Equal(t, int64(0), escrowedOf("coin:ugnot"))
	uassert.True(t, strings.Contains(Render("1"), "canceled"))
}

func TestCancelRules(cur realm, t *testing.T) {
	reset()
	fixed := newCoinStream(cur, 1000, 0, 100, false)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: stream is not cancelable", func() { Cancel(cross(cur), fixed) })

	done := newCoinStream(cur, 1000, 0, 100, true)
	sec(200)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: the cancel window has closed", func() { Cancel(cross(cur), done) })
}

func TestCoinStreamRejectsBadInput(cur realm, t *testing.T) {
	reset()
	now := time.Now().Unix()
	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "driplock: send exactly one coin denom with a positive amount",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, now+100, 0, 0) })

	testing.SetOriginSend(chain.Coins{{"ugnot", 10}, {"foo", 10}})
	uassert.AbortsWithMessage(t, cur, "driplock: send exactly one coin denom with a positive amount",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, now+100, 0, 0) })

	testing.SetOriginSend(chain.Coins{{"ugnot", 10}})
	uassert.AbortsWithMessage(t, cur, "driplock: end must be in the future",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, now, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: schedule: need start <= cliff <= end and start < end",
		func() { CreateCoinStream(cross(cur), bob, now, now+500, now+100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: invalid recipient address",
		func() { CreateCoinStream(cross(cur), address("not-an-address"), 0, 0, now+100, 0, 0) })
	uassert.AbortsWithMessage(t, cur, "driplock: recipient cannot be this realm",
		func() { CreateCoinStream(cross(cur), pkgAddr(), 0, 0, now+100, 0, 0) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, 0, StreamCount())
}

// An intermediate code realm cannot reuse the user's -send envelope.
func TestCoinStreamRequiresDirectUserCall(cur realm, t *testing.T) {
	reset()
	now := time.Now().Unix()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1000}})
	uassert.AbortsWithMessage(t, cur, "driplock: coin streams must be created by a direct user call (maketx call)",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, now+100, 0, 0) })
	testing.SetOriginSend(nil)
}

func TestEscrowIsolatedPerStream(cur realm, t *testing.T) {
	reset()
	a := newCoinStream(cur, 1000, 0, 100, true)
	b := newCoinStream(cur, 500, 0, 100, true)
	uassert.Equal(t, int64(1500), escrowedOf("coin:ugnot"))

	sec(100)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(1000), Withdraw(cross(cur), a))
	uassert.Equal(t, int64(500), Withdraw(cross(cur), b))
	uassert.Equal(t, int64(0), escrowedOf("coin:ugnot"))
}

func TestGRC20Stream(cur realm, t *testing.T) {
	reset()
	now := time.Now().Unix()
	const unit = int64(1_000_000) // 1 DRIP

	testing.SetRealm(testing.NewUserRealm(alice))
	dripdemo.Faucet(cross(cur)) // 1,000 DRIP
	uassert.Equal(t, 1000*unit, dripdemo.BalanceOf(alice))

	// Without an allowance the pull fails and no stream is stored.
	uassert.AbortsContains(t, cur, "driplock: cannot pull tokens from allowance",
		func() { CreateGRC20Stream(cross(cur), bob, tokKey, 400*unit, 0, 0, now+100, 0, now+100) })
	uassert.Equal(t, 0, StreamCount())

	dripdemo.Approve(cross(cur), pkgAddr(), 400*unit)
	id := CreateGRC20Stream(cross(cur), bob, tokKey, 400*unit, 0, 0, now+100, 0, now+100)
	uassert.Equal(t, 600*unit, dripdemo.BalanceOf(alice))
	uassert.Equal(t, 400*unit, dripdemo.BalanceOf(pkgAddr()))
	uassert.Equal(t, int64(0), dripdemo.Allowance(alice, pkgAddr()))

	sec(25)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, 100*unit, Withdraw(cross(cur), id))
	uassert.Equal(t, 100*unit, dripdemo.BalanceOf(bob))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, 300*unit, Cancel(cross(cur), id))
	uassert.Equal(t, 900*unit, dripdemo.BalanceOf(alice))
	uassert.Equal(t, int64(0), dripdemo.BalanceOf(pkgAddr()))
	uassert.True(t, strings.Contains(Render("1"), "400 DRIP"))
}

func TestGRC20UnknownToken(cur realm, t *testing.T) {
	reset()
	now := time.Now().Unix()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "unknown token",
		func() { CreateGRC20Stream(cross(cur), bob, "gno.land/r/nope.X", 1, 0, 0, now+100, 0, now+100) })
}

func TestRenderPages(cur realm, t *testing.T) {
	reset()
	uassert.True(t, strings.Contains(Render(""), "No streams yet."))
	newCoinStream(cur, 2_500_000, 0, 100, true)

	home := Render("")
	uassert.True(t, strings.Contains(home, "[#1](/r/zdev/driplock:1)"))
	uassert.True(t, strings.Contains(home, "2.5 GNOT"))

	one := Render("1")
	uassert.True(t, strings.Contains(one, "# Stream #1"))
	uassert.True(t, strings.Contains(one, "data:image/svg+xml;base64,"))

	byAddr := Render("addr/" + bob.String())
	uassert.True(t, strings.Contains(byAddr, "## Receiving"))
	uassert.True(t, strings.Contains(one, "([streams](/r/zdev/driplock:addr/"+bob.String()+"))"))
	uassert.True(t, strings.Contains(byAddr, "[#1](/r/zdev/driplock:1)"))

	// Hostile paths are never echoed back.
	evil := "addr/<script>alert(1)</script>"
	uassert.False(t, strings.Contains(Render(evil), "<script>"))
	uassert.False(t, strings.Contains(Render("](javascript:x)"), "javascript"))
	uassert.True(t, strings.Contains(Render("999"), "No stream with that id."))
}

func TestFormatting(t *testing.T) {
	uassert.Equal(t, "0.000001", withDecimals(1, 6))
	uassert.Equal(t, "1", withDecimals(1_000_000, 6))
	uassert.Equal(t, "12.5", withDecimals(12_500_000, 6))
	uassert.Equal(t, "42", withDecimals(42, 0))
	uassert.Equal(t, "50.00%", pct(1, 2))
	uassert.Equal(t, "100.00%", pct(9223372036854775807, 9223372036854775807))
	uassert.Equal(t, "0.00%", pct(0, 5))
}
