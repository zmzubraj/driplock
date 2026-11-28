package driplock

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestLockSummaryAndReconciliation(cur realm, t *testing.T) {
	reset()
	// A: 1200 over 1200s, cancelable for the first 600s.
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1200)
	a := CreateCoinStreamFor(cross(cur), bob, 0, 1200, 0, 600)
	// B: 600 over 600s, never cancelable.
	fund(600)
	CreateCoinStreamFor(cross(cur), carol, 0, 600, 0, 0)
	testing.SetOriginSend(nil)

	sec(300)
	sum, ok := GetLockSummary("coin:ugnot")
	uassert.True(t, ok)
	uassert.Equal(t, 2, sum.Streams)
	uassert.Equal(t, int64(1800), sum.Locked)
	// Vested: A 300, B 300. Unvested: 900 + 300.
	uassert.Equal(t, int64(1200), sum.Unvested)
	uassert.Equal(t, int64(600), sum.Claimable)
	uassert.Equal(t, int64(900), sum.Cancelable) // only A's unvested part
	uassert.True(t, sum.Reconciled)

	// After A's window closes, nothing is cancelable any more.
	sec(300)
	sum, _ = GetLockSummary("coin:ugnot")
	uassert.Equal(t, int64(0), sum.Cancelable)

	// Withdrawals keep the books reconciled.
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), a)
	sum, _ = GetLockSummary("coin:ugnot")
	uassert.True(t, sum.Reconciled)
	uassert.Equal(t, int64(1800-600), sum.Locked)
}

func TestSettledStreamsLeaveTheLiveIndex(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100, true)
	sec(100)
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), id)
	sum, ok := GetLockSummary("coin:ugnot")
	uassert.True(t, ok)
	uassert.Equal(t, 0, sum.Streams)
	uassert.Equal(t, int64(0), sum.Locked)
	uassert.True(t, sum.Reconciled)

	// A canceled stream stays live until its vested remainder is withdrawn.
	id2 := newCoinStream(cur, 1000, 0, 100, true)
	sec(40)
	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id2)
	sum, _ = GetLockSummary("coin:ugnot")
	uassert.Equal(t, 1, sum.Streams)
	uassert.Equal(t, int64(0), sum.Unvested)
	uassert.Equal(t, int64(400), sum.Claimable)
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), id2)
	sum, _ = GetLockSummary("coin:ugnot")
	uassert.Equal(t, 0, sum.Streams)
}

func TestUnlockCalendar(cur realm, t *testing.T) {
	reset()
	const month = 30 * 86400
	// 1200 GNOT-units over 12 months in monthly steps, 3-month cliff.
	testing.SetRealm(testing.NewUserRealm(alice))
	fund(1200)
	CreateCoinStreamFor(cross(cur), bob, 3*month, 12*month, month, 0)
	testing.SetOriginSend(nil)

	buckets := make([]int64, calendarBuckets)
	sum, _ := summarize("coin:ugnot", now(), buckets)
	// Windows are (start, start+30d]: the cliff step (300) lands in window 3,
	// then 100 per month.
	want := []int64{0, 0, 300, 100, 100, 100, 100, 100, 100, 100, 100, 100} // sums to 1200
	for i, w := range want {
		uassert.Equal(t, w, buckets[i])
	}
	uassert.Equal(t, int64(1200), sum.Unvested)

	page := Render("lock/coin:ugnot")
	uassert.True(t, strings.Contains(page, "# Proof of Lock: GNOT"))
	uassert.True(t, strings.Contains(page, "**Reconciled:**"))
	uassert.True(t, strings.Contains(page, "## Unlock calendar"))
	uassert.True(t, strings.Contains(page, "never cancelable"))
	uassert.True(t, strings.Contains(page, "Asset key: `coin:ugnot`."))
}

func TestLockPageUnknownAndHostile(cur realm, t *testing.T) {
	reset()
	uassert.True(t, strings.Contains(Render("lock/coin:ugnot"), "never held that asset"))
	uassert.True(t, strings.Contains(Render("lock/<script>x</script>"), "never held that asset"))
	uassert.False(t, strings.Contains(Render("lock/<script>x</script>"), "<script>"))
	_, ok := GetLockSummary("grc20:nope")
	uassert.False(t, ok)
}

func TestHomeLinksToProofOfLock(cur realm, t *testing.T) {
	reset()
	newCoinStream(cur, 1000, 0, 100, false)
	uassert.True(t, strings.Contains(Render(""), "(/r/zdev/driplock:lock/coin:ugnot)"))
	uassert.True(t, strings.Contains(Render("1"), "[Proof of Lock](/r/zdev/driplock:lock/coin:ugnot)"))
}
