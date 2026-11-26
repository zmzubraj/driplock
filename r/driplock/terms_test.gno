package driplock

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// The usual "good leaver" term: cancelable only before the cliff.
func TestCancelOnlyBeforeCliff(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1200)
	id := CreateCoinStreamFor(cross(cur), bob, 300, 1200, 0, 300)
	testing.SetOriginSend(nil)
	uassert.True(t, strings.Contains(Render("1"), "the sender can cancel until"))

	sec(300) // window closes exactly at the cliff
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "driplock: the cancel window has closed", func() { Cancel(cross(cur), id) })
	page := Render("1")
	uassert.True(t, strings.Contains(page, "no longer cancelable"))
	uassert.False(t, strings.Contains(page, "func=Cancel"))
}

func TestCancelInsideWindowRefundsUnvested(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1000)
	id := CreateCoinStreamFor(cross(cur), bob, 0, 100, 0, 50)
	testing.SetOriginSend(nil)
	sec(20)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(800), Cancel(cross(cur), id))
}

func TestNeverCancelableIsStated(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1000)
	id := CreateCoinStreamFor(cross(cur), bob, 0, 100, 0, 0)
	testing.SetOriginSend(nil)
	uassert.True(t, strings.Contains(Render("1"), "never cancelable"))
	uassert.AbortsWithMessage(t, cur, "driplock: stream is not cancelable", func() { Cancel(cross(cur), id) })
	info, _ := GetStream(id)
	uassert.False(t, info.Cancelable)
}

func TestCancelTermsValidation(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1000)
	uassert.AbortsWithMessage(t, cur, "driplock: cancel window must be between 0 and the duration",
		func() { CreateCoinStreamFor(cross(cur), bob, 0, 100, 0, 101) })
	uassert.AbortsWithMessage(t, cur, "driplock: cancel window must be between 0 and the duration",
		func() { CreateCoinStreamFor(cross(cur), bob, 0, 100, 0, -1) })
	n := nowForTest()
	uassert.AbortsWithMessage(t, cur, "driplock: cancelUntil must be 0 (never) or a time after now and no later than end",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, n+100, 0, n+101) })
	uassert.AbortsWithMessage(t, cur, "driplock: cancelUntil must be 0 (never) or a time after now and no later than end",
		func() { CreateCoinStream(cross(cur), bob, 0, 0, n+100, 0, n) })
	uassert.AbortsWithMessage(t, cur, "driplock: schedule: period must be 0 (continuous) or between 1 and end - start",
		func() { CreateCoinStreamFor(cross(cur), bob, 0, 100, 101, 0) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, 0, StreamCount())
}

// Monthly steps through the realm, end to end.
func TestSteppedStreamWithdraws(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1200)
	// 12 steps of 100 seconds, no cliff.
	id := CreateCoinStreamFor(cross(cur), bob, 0, 1200, 100, 0)
	testing.SetOriginSend(nil)
	uassert.True(t, strings.Contains(Render("1"), "in steps, every 100 seconds"))

	testing.SetRealm(testing.NewUserRealm(bob))
	sec(95)
	uassert.AbortsWithMessage(t, cur, "driplock: nothing to withdraw yet", func() { Withdraw(cross(cur), id) })
	sec(5)
	uassert.Equal(t, int64(100), Withdraw(cross(cur), id))
	sec(250) // 350s: 3 steps vested in total
	uassert.Equal(t, int64(200), Withdraw(cross(cur), id))
	info, _ := GetStream(id)
	uassert.Equal(t, int64(100), info.Period)
}

func TestHumanDuration(t *testing.T) {
	uassert.Equal(t, "1 month", humanDuration(30*86400))
	uassert.Equal(t, "3 months", humanDuration(90*86400))
	uassert.Equal(t, "2 weeks", humanDuration(14*86400))
	uassert.Equal(t, "1 day", humanDuration(86400))
	uassert.Equal(t, "90 minutes", humanDuration(5400))
	uassert.Equal(t, "7 seconds", humanDuration(7))
}

func nowForTest() int64 { return now() }
