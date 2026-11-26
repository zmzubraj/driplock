package schedule

import "testing"

const maxInt64 int64 = 9223372036854775807

func mustNew(t *testing.T, total, start, cliff, end int64) Schedule {
	t.Helper()
	s, err := New(total, start, cliff, end)
	if err != nil {
		t.Fatalf("New(%d, %d, %d, %d): unexpected error %v", total, start, cliff, end, err)
	}
	return s
}

func TestNewValidation(t *testing.T) {
	cases := []struct {
		name                     string
		total, start, cliff, end int64
		want                     error
	}{
		{"zero total", 0, 0, 0, 10, ErrNonPositiveTotal},
		{"negative total", -5, 0, 0, 10, ErrNonPositiveTotal},
		{"negative start", 1, -1, 0, 10, ErrNegativeTime},
		{"cliff before start", 1, 10, 5, 20, ErrBadOrder},
		{"cliff after end", 1, 0, 30, 20, ErrBadOrder},
		{"start equals end", 1, 10, 10, 10, ErrBadOrder},
		{"too long", 1, 0, 0, MaxDuration + 1, ErrTooLong},
		{"ok no cliff", 1, 0, 0, 10, nil},
		{"ok cliff at end", 1, 0, 10, 10, nil},
		{"ok max duration", 1, 0, 0, MaxDuration, nil},
	}
	for _, c := range cases {
		_, err := New(c.total, c.start, c.cliff, c.end)
		if err != c.want {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

func TestVestedAtLinearNoCliff(t *testing.T) {
	s := mustNew(t, 1000, 100, 100, 200)
	cases := []struct{ at, want int64 }{
		{0, 0}, {99, 0}, {100, 0}, {101, 10}, {150, 500}, {199, 990}, {200, 1000}, {10_000, 1000},
	}
	for _, c := range cases {
		if got := s.VestedAt(c.at); got != c.want {
			t.Errorf("VestedAt(%d) = %d, want %d", c.at, got, c.want)
		}
	}
}

func TestVestedAtCliffUnlocksAccrued(t *testing.T) {
	// 1200 over 12 "months" of 100s with a 3-month cliff.
	s := mustNew(t, 1200, 0, 300, 1200)
	if got := s.VestedAt(299); got != 0 {
		t.Errorf("before cliff: got %d, want 0", got)
	}
	if got := s.VestedAt(300); got != 300 {
		t.Errorf("at cliff: got %d, want 300 (accrued since start)", got)
	}
	if got := s.VestedAt(600); got != 600 {
		t.Errorf("mid: got %d, want 600", got)
	}
}

func TestVestedAtRoundsDown(t *testing.T) {
	s := mustNew(t, 10, 0, 0, 3)
	want := []int64{0, 3, 6, 10}
	for at, w := range want {
		if got := s.VestedAt(int64(at)); got != w {
			t.Errorf("VestedAt(%d) = %d, want %d", at, got, w)
		}
	}
}

func TestVestedAtNoOverflowAtExtremes(t *testing.T) {
	s := mustNew(t, maxInt64, 0, 0, MaxDuration)
	prev := int64(0)
	// Sample across the whole range, including points near the end where r*e is largest.
	points := []int64{1, 2, MaxDuration / 3, MaxDuration / 2, MaxDuration - 2, MaxDuration - 1, MaxDuration}
	for _, at := range points {
		got := s.VestedAt(at)
		if got < prev {
			t.Fatalf("not monotonic at %d: %d < %d", at, got, prev)
		}
		if got < 0 || got > maxInt64 {
			t.Fatalf("out of range at %d: %d", at, got)
		}
		prev = got
	}
	if s.VestedAt(MaxDuration) != maxInt64 {
		t.Fatalf("end must release the full total")
	}
	// Exactness check at the midpoint: floor(maxInt64 * (d/2) / d) with even d.
	d := MaxDuration
	if d%2 != 0 {
		t.Fatalf("test assumes an even MaxDuration")
	}
	if got, want := s.VestedAt(d/2), maxInt64/2; got != want {
		t.Fatalf("midpoint: got %d, want %d", got, want)
	}
}

func TestVestedAtMonotonicSmallSchedules(t *testing.T) {
	for total := int64(1); total <= 40; total++ {
		for d := int64(1); d <= 12; d++ {
			for cliff := int64(0); cliff <= d; cliff++ {
				s := mustNew(t, total, 0, cliff, d)
				prev := int64(0)
				for at := int64(-1); at <= d+1; at++ {
					got := s.VestedAt(at)
					if got < prev || got > total {
						t.Fatalf("total=%d d=%d cliff=%d at=%d: got %d (prev %d)", total, d, cliff, at, got, prev)
					}
					if at >= cliff && at < d && got != total*at/d {
						t.Fatalf("total=%d d=%d at=%d: got %d, want %d", total, d, at, got, total*at/d)
					}
					prev = got
				}
				if prev != total {
					t.Fatalf("total=%d d=%d cliff=%d: final %d", total, d, cliff, prev)
				}
			}
		}
	}
}

func TestZeroValueVestsNothing(t *testing.T) {
	var s Schedule
	if s.VestedAt(123) != 0 {
		t.Fatal("zero schedule must vest nothing")
	}
}

// refVested is a slow, obviously-correct reference for stepped schedules.
func refVested(total, start, cliff, end, period, t int64) int64 {
	if t < cliff {
		return 0
	}
	if t >= end {
		return total
	}
	e := t - start
	if period > 0 {
		e = (e / period) * period
	}
	return total * e / (end - start)
}

func TestSteppedMatchesReferenceExhaustively(t *testing.T) {
	for total := int64(1); total <= 30; total += 7 {
		for d := int64(1); d <= 13; d++ {
			for period := int64(0); period <= d; period++ {
				for cliff := int64(0); cliff <= d; cliff += 3 {
					s, err := NewStepped(total, 0, cliff, d, period)
					if err != nil {
						t.Fatalf("unexpected error: %v", err)
					}
					for at := int64(-1); at <= d+1; at++ {
						if got, want := s.VestedAt(at), refVested(total, 0, cliff, d, period, at); got != want {
							t.Fatalf("total=%d d=%d period=%d cliff=%d at=%d: got %d want %d", total, d, period, cliff, at, got, want)
						}
					}
				}
			}
		}
	}
}

func TestMonthlySteps(t *testing.T) {
	const month = int64(30 * 24 * 3600)
	// 1200 over 12 months, monthly steps, 3-month cliff.
	s, err := NewStepped(1200, 0, 3*month, 12*month, month)
	if err != nil {
		t.Fatal(err)
	}
	checks := []struct{ at, want int64 }{
		{month, 0}, {3*month - 1, 0}, {3 * month, 300}, {4*month - 1, 300}, {4 * month, 400}, {12 * month, 1200},
	}
	for _, c := range checks {
		if got := s.VestedAt(c.at); got != c.want {
			t.Errorf("VestedAt(%d) = %d, want %d", c.at, got, c.want)
		}
	}
	if got := s.ReleasedBetween(3*month, 6*month); got != 300 {
		t.Errorf("ReleasedBetween = %d, want 300", got)
	}
}

func TestBadPeriod(t *testing.T) {
	if _, err := NewStepped(10, 0, 0, 100, -1); err != ErrBadPeriod {
		t.Errorf("negative period: got %v", err)
	}
	if _, err := NewStepped(10, 0, 0, 100, 101); err != ErrBadPeriod {
		t.Errorf("period longer than schedule: got %v", err)
	}
}

func TestNextUnlockAfter(t *testing.T) {
	s, _ := NewStepped(1200, 0, 300, 1200, 100)
	cases := []struct{ at, want int64 }{{0, 300}, {299, 300}, {300, 400}, {399, 400}, {1100, 1200}}
	for _, c := range cases {
		got, ok := s.NextUnlockAfter(c.at)
		if !ok || got != c.want {
			t.Errorf("NextUnlockAfter(%d) = %d,%v want %d", c.at, got, ok, c.want)
		}
	}
	if _, ok := s.NextUnlockAfter(1200); ok {
		t.Error("nothing should unlock after the end")
	}
	// Continuous with a tiny total: one unit every 100 seconds.
	c, _ := New(10, 0, 0, 1000)
	if got, _ := c.NextUnlockAfter(0); got != 100 {
		t.Errorf("continuous next = %d, want 100", got)
	}
	// Property: the answer is the earliest time with a larger vested amount.
	for _, sc := range []Schedule{s, c} {
		for at := int64(-5); at < sc.End(); at += 37 {
			next, ok := sc.NextUnlockAfter(at)
			if !ok {
				t.Fatalf("expected an unlock after %d", at)
			}
			if sc.VestedAt(next) <= sc.VestedAt(at) || (next-1 > at && sc.VestedAt(next-1) > sc.VestedAt(at)) {
				t.Fatalf("NextUnlockAfter(%d) = %d is not the earliest increase", at, next)
			}
		}
	}
}
