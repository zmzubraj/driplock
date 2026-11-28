package driplock

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// lockScanCap bounds how many live streams one Proof of Lock page or
	// summary reads, so the cost stays flat however popular a token gets.
	lockScanCap = 500
	// calendarBuckets x bucketSeconds is the calendar horizon (12 x 30 days).
	calendarBuckets = 12
	bucketSeconds   = int64(30 * 86400)
	lockListLimit   = 50
)

// LockSummary describes everything Driplock holds for one asset right now.
// Other realms (launchpads, DAOs, explorers) can read it with GetLockSummary.
type LockSummary struct {
	Asset      string // asset key, for example "coin:ugnot" or "grc20:<grc20reg key>"
	Streams    int    // live streams counted
	Truncated  bool   // true if there were more than lockScanCap live streams
	Locked     int64  // held in escrow for this asset (from the escrow ledger)
	Unvested   int64  // not yet vested: the part still locked by schedules
	Claimable  int64  // vested but not yet withdrawn
	Cancelable int64  // unvested amount whose sender may still cancel
	NextUnlock int64  // Unix time of the next unlock, 0 if none
	Reconciled bool   // per-stream sum equals the escrow ledger
}

// GetLockSummary returns the live lock summary for an asset key, and false if
// Driplock has never held that asset.
func GetLockSummary(assetKey string) (LockSummary, bool) {
	if escrowed.Get(assetKey) == nil {
		return LockSummary{}, false
	}
	sum, _ := summarize(assetKey, now(), nil)
	return sum, true
}

// summarize walks live streams of an asset (bounded by lockScanCap). If
// buckets is non-nil it also fills the unlock calendar starting at t.
func summarize(assetKey string, t int64, buckets []int64) (LockSummary, []*stream) {
	sum := LockSummary{Asset: assetKey, Locked: escrowedOf(assetKey)}
	var live []*stream
	prefix := assetKey + "/"
	activeByAsset.Iterate(prefix, prefix+"\xff", func(k string, _ any) bool {
		if len(live) >= lockScanCap {
			sum.Truncated = true
			return true
		}
		v := streams.Get(strings.TrimPrefix(k, prefix))
		if v == nil {
			return false
		}
		s := v.(*stream)
		live = append(live, s)
		vested := s.vestedAt(t)
		unvested := s.sched.Total() - s.refunded - vested
		sum.Unvested += unvested
		sum.Claimable += vested - s.withdrawn
		if s.cancelOpen(t) {
			sum.Cancelable += unvested
		}
		if !s.canceled {
			if next, ok := s.sched.NextUnlockAfter(t); ok && (sum.NextUnlock == 0 || next < sum.NextUnlock) {
				sum.NextUnlock = next
			}
			for i := range buckets {
				a := t + int64(i)*bucketSeconds
				buckets[i] += s.sched.ReleasedBetween(a, a+bucketSeconds)
			}
		}
		return false
	})
	sum.Streams = len(live)
	sum.Reconciled = !sum.Truncated && sum.Unvested+sum.Claimable == sum.Locked
	return sum, live
}

func renderLock(assetKey string, t int64) string {
	if escrowed.Get(assetKey) == nil {
		return "# Not found\n\nDriplock has never held that asset.\n"
	}
	kind, asset := splitAssetKey(assetKey)
	buckets := make([]int64, calendarBuckets)
	sum, live := summarize(assetKey, t, buckets)
	fmtA := func(v int64) string { return formatAsset(kind, asset, v) }

	var b strings.Builder
	b.WriteString("# Proof of Lock: " + assetName(kind, asset) + "\n\n")
	b.WriteString("Computed live by the chain from Driplock's escrow, not copied from an off-chain tracker. ")
	// InlineCode picks a safe fence itself; InlineText would leave visible backslashes inside a code span.
	b.WriteString("Asset key: " + sanitize.InlineCode(assetKey) + ".\n\n")

	b.WriteString("| Measure | Amount |\n| --- | --- |\n")
	b.WriteString("| Locked in Driplock now | " + fmtA(sum.Locked) + " |\n")
	b.WriteString("| Still vesting | " + fmtA(sum.Unvested) + " |\n")
	b.WriteString("| Vested, waiting to be withdrawn | " + fmtA(sum.Claimable) + " |\n")
	b.WriteString("| Still cancelable by senders | " + fmtA(sum.Cancelable) + " (" + pct(sum.Cancelable, sum.Unvested) + " of what is vesting) |\n")
	b.WriteString("| Live streams | " + strconv.Itoa(sum.Streams) + " |\n")
	if sum.NextUnlock > 0 {
		b.WriteString("| Next unlock | " + unix(sum.NextUnlock) + " |\n")
	}
	b.WriteString("\n")
	switch {
	case sum.Truncated:
		b.WriteString("Only the first " + strconv.Itoa(lockScanCap) + " live streams are counted on this page.\n\n")
	case sum.Reconciled:
		b.WriteString("**Reconciled:** the sum over every live stream equals the escrow ledger.\n\n")
	default:
		b.WriteString("**Warning:** the per-stream sum does not match the escrow ledger.\n\n")
	}

	b.WriteString("## Unlock calendar\n\nWhat unlocks in each 30-day window from now.\n\n")
	b.WriteString("| From | To | Unlocks | Share of what is vesting |\n| --- | --- | --- | --- |\n")
	var later = sum.Unvested
	for i, v := range buckets {
		a := t + int64(i)*bucketSeconds
		b.WriteString("| " + unix(a) + " | " + unix(a+bucketSeconds) + " | " + fmtA(v) + " | " + pct(v, sum.Unvested) + " |\n")
		later -= v
	}
	if later > 0 {
		b.WriteString("| " + unix(t+calendarBuckets*bucketSeconds) + " | later | " + fmtA(later) + " | " + pct(later, sum.Unvested) + " |\n")
	}

	b.WriteString("\n## Live streams\n\n")
	if len(live) == 0 {
		b.WriteString("None.\n")
		return b.String()
	}
	b.WriteString("| Stream | Recipient | Still vesting | Cancel terms |\n| --- | --- | --- | --- |\n")
	for i, s := range live {
		if i >= lockListLimit {
			b.WriteString("\nShowing the first " + strconv.Itoa(lockListLimit) + " of " + strconv.Itoa(len(live)) + ".\n")
			break
		}
		unvested := s.sched.Total() - s.refunded - s.vestedAt(t)
		b.WriteString("| [#" + s.idString() + "](" + link(s.idString()) + ") | " + s.recipient.String() +
			" | " + fmtA(unvested) + " | " + shortTerms(s, t) + " |\n")
	}
	return b.String()
}

func shortTerms(s *stream, t int64) string {
	switch {
	case s.canceled:
		return "canceled"
	case s.cancelUntil == 0:
		return "never cancelable"
	case t < s.cancelUntil:
		return "cancelable until " + unix(s.cancelUntil)
	default:
		return "no longer cancelable"
	}
}

func splitAssetKey(key string) (assetKind, string) {
	if strings.HasPrefix(key, "grc20:") {
		return kindGRC20, strings.TrimPrefix(key, "grc20:")
	}
	return kindCoin, strings.TrimPrefix(key, "coin:")
}

// assetName is the display name of an asset: GNOT, a token symbol, or a denom.
func assetName(kind assetKind, asset string) string {
	full := formatAsset(kind, asset, 0) // "0 <name>"
	return strings.TrimPrefix(full, "0 ")
}
