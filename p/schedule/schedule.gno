// Package schedule implements a linear vesting schedule with an optional cliff.
//
// It is pure math with no state, so any realm can import it to vest coins,
// GRC20 tokens, points or anything else measured in int64 units.
//
// A schedule releases nothing before its cliff. At the cliff, everything that
// accrued since start unlocks at once, and the rest then unlocks linearly
// until end:
//
//	s, err := schedule.New(1_000_000, start, start+30*day, start+365*day)
//	vested := s.VestedAt(now)
//
// All times are Unix seconds.
package schedule

import "errors"

// MaxDuration caps end-start at 50 years. The cap keeps VestedAt free of
// int64 overflow for every positive total (see VestedAt).
const MaxDuration int64 = 50 * 365 * 24 * 60 * 60

var (
	ErrNonPositiveTotal = errors.New("schedule: total must be positive")
	ErrNegativeTime     = errors.New("schedule: times must not be negative")
	ErrBadOrder         = errors.New("schedule: need start <= cliff <= end and start < end")
	ErrTooLong          = errors.New("schedule: end - start exceeds 50 years")
	ErrBadPeriod        = errors.New("schedule: period must be 0 (continuous) or between 1 and end - start")
)

// Schedule is an immutable vesting schedule. Build it with New (continuous)
// or NewStepped (unlocks in steps of a fixed period).
type Schedule struct {
	total  int64
	start  int64
	cliff  int64
	end    int64
	period int64 // 0 = continuous
}

// New validates the inputs and returns a continuous (per-second) schedule.
func New(total, start, cliff, end int64) (Schedule, error) {
	return NewStepped(total, start, cliff, end, 0)
}

// NewStepped returns a schedule that unlocks in steps: at start+period,
// start+2*period, and so on, with the last step at end. Each step releases
// what a linear schedule would have released by then, so a 12-month schedule
// with a 1-month period pays 1/12 each month. The cliff still applies:
// nothing unlocks before it, and steps due before it unlock at the cliff.
// period = 0 means continuous, the same as New.
func NewStepped(total, start, cliff, end, period int64) (Schedule, error) {
	if total <= 0 {
		return Schedule{}, ErrNonPositiveTotal
	}
	if start < 0 {
		return Schedule{}, ErrNegativeTime
	}
	if !(start <= cliff && cliff <= end && start < end) {
		return Schedule{}, ErrBadOrder
	}
	if end-start > MaxDuration {
		return Schedule{}, ErrTooLong
	}
	if period < 0 || period > end-start {
		return Schedule{}, ErrBadPeriod
	}
	return Schedule{total: total, start: start, cliff: cliff, end: end, period: period}, nil
}

func (s Schedule) Total() int64 { return s.total }
func (s Schedule) Start() int64 { return s.start }
func (s Schedule) Cliff() int64 { return s.cliff }
func (s Schedule) End() int64   { return s.end }

// Period is the step length in seconds, or 0 for a continuous schedule.
func (s Schedule) Period() int64 { return s.period }

// VestedAt returns how much of the total has vested at time t.
//
// It equals floor(total * (t-start) / (end-start)) between cliff and end,
// computed as q*e + (r*e)/d with q, r = total/d, total%d. That form is exact,
// and it cannot overflow: q*e <= total, and r*e < d*d <= MaxDuration^2,
// which is about 2.5e18, below the int64 limit of about 9.2e18.
func (s Schedule) VestedAt(t int64) int64 {
	if s.total <= 0 {
		return 0 // zero value, not built by New
	}
	if t < s.cliff {
		return 0
	}
	if t >= s.end {
		return s.total
	}
	d := s.end - s.start
	e := t - s.start
	if s.period > 0 {
		e -= e % s.period // round down to the last completed step
	}
	q, r := s.total/d, s.total%d
	return q*e + (r*e)/d
}

// ReleasedBetween returns how much unlocks in the window (a, b].
// It is the building block for unlock calendars.
func (s Schedule) ReleasedBetween(a, b int64) int64 {
	if b <= a {
		return 0
	}
	return s.VestedAt(b) - s.VestedAt(a)
}

// NextUnlockAfter returns the first time after t at which the vested amount
// grows, or (0, false) if nothing more will unlock. VestedAt never decreases,
// so a binary search over (t, end] finds it in at most about 31 steps for
// any schedule up to MaxDuration, continuous or stepped.
func (s Schedule) NextUnlockAfter(t int64) (int64, bool) {
	if s.total <= 0 || t >= s.end {
		return 0, false
	}
	v := s.VestedAt(t)
	lo, hi := t+1, s.end
	if lo < s.start {
		lo = s.start
	}
	for lo < hi {
		mid := lo + (hi-lo)/2
		if s.VestedAt(mid) > v {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo, true
}

// FullyVestedAt reports whether the whole total has vested at time t.
func (s Schedule) FullyVestedAt(t int64) bool {
	return t >= s.end
}
