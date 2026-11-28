package driplock

// Regression tests for the 2026-11-28 security audit (see AUDIT.md). Each
// test started as a proof of concept that passed while the weakness existed.

import (
	"chain"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// F1: the Proof of Lock must compare the ledger with the real balance. A
// GRC20 admin can burn the realm's tokens without touching the ledger.
func TestAuditProofChecksRealBalance(cur realm, t *testing.T) {
	reset()
	tok, led := grc20.NewToken("Evil", "EVL", 6, 0, cur)
	key := grc20reg.Register(cross(cur), tok, "")
	uassert.NoError(t, led.Mint(alice, 1000))
	uassert.NoError(t, led.Approve(alice, pkgAddr(), 1000))
	now := time.Now().Unix()
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateGRC20Stream(cross(cur), bob, key, 1000, 0, 0, now+100, 0, 0)

	sum, _ := GetLockSummary("grc20:" + key)
	uassert.Equal(t, int64(1000), sum.Held)
	uassert.True(t, sum.Backed)
	uassert.True(t, sum.Reconciled)
	page := Render("lock/grc20:" + key)
	uassert.True(t, strings.Contains(page, "**Reconciled:**"))
	uassert.True(t, strings.Contains(page, "(GRC20 token)")) // a symbol alone could be spoofed

	uassert.NoError(t, led.Burn(pkgAddr(), 400)) // the token admin drains part of the escrow
	sum, _ = GetLockSummary("grc20:" + key)
	uassert.Equal(t, int64(600), sum.Held)
	uassert.False(t, sum.Backed)
	page = Render("lock/grc20:" + key)
	uassert.False(t, strings.Contains(page, "**Reconciled:**"))
	uassert.True(t, strings.Contains(page, "**Warning:** the contract holds"))
}

func TestAuditCoinProofIsBacked(cur realm, t *testing.T) {
	reset()
	newCoinStream(cur, 1000, 0, 100, false)
	sum, _ := GetLockSummary("coin:ugnot")
	uassert.True(t, sum.Held >= 1000)
	uassert.True(t, sum.Backed)
	uassert.True(t, strings.Contains(Render("lock/coin:ugnot"), "Actually held by the contract"))
}

// F2: coins attached to a call that takes no payment must be refused (the
// transaction reverts and the user keeps them) instead of being trapped.
func TestAuditStraySendIsRefused(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, true)
	sec(50)
	stray := chain.Coins{{"ugnot", 777}}
	const msg = "driplock: this function does not take coins; do not use -send"

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(stray)
	uassert.AbortsWithMessage(t, cur, msg, func() { Withdraw(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { WithdrawFor(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Ping(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { SetBackup(cross(cur), id, carol, MinInactivity) })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferRecipient(cross(cur), id, carol) })
	uassert.AbortsWithMessage(t, cur, msg, func() { ClaimAsBackup(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { CreateGRC20Stream(cross(cur), carol, tokKey, 1, 0, 0, 10, 0, 0) })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, msg, func() { Cancel(cross(cur), id) })

	// Without -send everything works as before.
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id))

	// A realm caller is not refused: the -send of the transaction went to the
	// realm the user called first, not to Driplock.
	sec(10)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/some/keeper"))
	testing.SetOriginSend(stray)
	uassert.Equal(t, int64(100), WithdrawFor(cross(cur), id))
	testing.SetOriginSend(nil)
}

// F3: relayed withdrawals must not erase the creation entry from history.
func TestAuditRelayedWithdrawalsKeepTheLockEntry(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 100000, 0, 10000, false)
	testing.SetRealm(testing.NewUserRealm(carol))
	for i := 0; i < historyCap+2; i++ {
		sec(5)
		WithdrawFor(cross(cur), id)
	}
	st := Render("statement/" + alice.String())
	uassert.True(t, strings.Contains(st, "| created | - 0.1 GNOT |"))
	uassert.True(t, strings.Contains(st, "older events not listed"))
}

// F4: dust streams must not push an address's newest real activity out of
// its statement.
func TestAuditDustCannotHideNewActivity(cur realm, t *testing.T) {
	reset()
	dustBatches(cur, carol, bob, 3) // 150 one-ugnot streams to bob
	real := newCoinStream(cur, 1000, 0, 100, false)
	sec(100)
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), real)
	st := Render("statement/" + bob.String())
	uassert.True(t, strings.Contains(st, "[#"+strconv.FormatUint(real, 10)+"]"))
	uassert.True(t, strings.Contains(st, "most recent streams are included"))
}

// F5 (residual, by design): dust streams can exceed the per-stream scan, but
// the O(1) solvency check still answers.
func TestAuditDustKeepsSolvencyProof(cur realm, t *testing.T) {
	reset()
	newCoinStream(cur, 1000, 0, 100, false)
	dustBatches(cur, carol, carol, lockScanCap/MaxBatch)
	sum, _ := GetLockSummary("coin:ugnot")
	uassert.True(t, sum.Truncated)
	uassert.True(t, sum.Backed)
	uassert.True(t, strings.Contains(Render("lock/coin:ugnot"), "**Backed:** the contract holds at least what it owes"))
}

// F6: a cursor at the largest id must end the listing, not wrap around.
func TestAuditMaxCursorEndsListing(cur realm, t *testing.T) {
	reset()
	newCoinStream(cur, 1000, 0, 100, false)
	uassert.Equal(t, 0, len(ListStreams(bob, true, ^uint64(0), 10)))
	uassert.Equal(t, 1, len(ListStreams(bob, true, 0, 10)))
}

// dustBatches has `from` open n batches of 50 one-ugnot streams to `to`.
func dustBatches(cur realm, from, to address, n int) {
	recips := strings.TrimSuffix(strings.Repeat(to.String()+",", MaxBatch), ",")
	amts := strings.TrimSuffix(strings.Repeat("1,", MaxBatch), ",")
	for i := 0; i < n; i++ {
		testing.IssueCoins(pkgAddr(), chain.Coins{{"ugnot", MaxBatch}})
		testing.SetRealm(testing.NewUserRealm(from))
		testing.SetOriginSend(chain.Coins{{"ugnot", MaxBatch}})
		CreateCoinStreamBatch(cross(cur), recips, amts, 0, 365*86400, 0, 0)
	}
	testing.SetOriginSend(nil)
}
