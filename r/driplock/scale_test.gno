package driplock

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func makeStreams(cur realm, n int) {
	for i := 0; i < n; i++ {
		newCoinStream(cur, 1000, 0, 1000, false)
	}
}

func TestHomePagination(cur realm, t *testing.T) {
	reset()
	makeStreams(cur, 45)

	p1 := Render("")
	uassert.True(t, strings.Contains(p1, "[#45]("))
	uassert.True(t, strings.Contains(p1, "[#26]("))
	uassert.False(t, strings.Contains(p1, "[#25]("))
	uassert.True(t, strings.Contains(p1, "Page 1 of 3."))
	uassert.True(t, strings.Contains(p1, "[Older](/r/zdev/driplock:?page=2)"))

	p3 := Render("?page=3")
	uassert.True(t, strings.Contains(p3, "[#5]("))
	uassert.True(t, strings.Contains(p3, "[#1]("))
	uassert.False(t, strings.Contains(p3, "[#6]("))
	uassert.True(t, strings.Contains(p3, "[Newer]"))

	// Out-of-range and junk page values fall back safely.
	uassert.True(t, strings.Contains(Render("?page=999"), "Page 3 of 3."))
	uassert.True(t, strings.Contains(Render("?page=-1"), "Page 1 of 3."))
	uassert.True(t, strings.Contains(Render("?page=abc"), "Page 1 of 3."))
}

func TestAddressCursorPagination(cur realm, t *testing.T) {
	reset()
	makeStreams(cur, addrPageSize+5)

	p1 := Render("addr/" + bob.String())
	uassert.True(t, strings.Contains(p1, "[#1]("))
	uassert.True(t, strings.Contains(p1, "[#50]("))
	uassert.False(t, strings.Contains(p1, "[#51]("))
	next := "?after=" + strconv.Itoa(addrPageSize)
	uassert.True(t, strings.Contains(p1, next))

	p2 := Render("addr/" + bob.String() + next)
	uassert.True(t, strings.Contains(p2, "[#51]("))
	uassert.True(t, strings.Contains(p2, "[#55]("))
	uassert.False(t, strings.Contains(p2, "[#50]("))
}

func TestListStreamsAPI(cur realm, t *testing.T) {
	reset()
	makeStreams(cur, 7)

	page := ListStreams(bob, true, 0, 3)
	uassert.Equal(t, 3, len(page))
	uassert.Equal(t, uint64(1), page[0].ID)
	page = ListStreams(bob, true, page[2].ID, 3)
	uassert.Equal(t, uint64(4), page[0].ID)

	uassert.Equal(t, 7, len(ListStreams(alice, false, 0, 1000))) // capped at MaxListLimit
	uassert.Equal(t, 0, len(ListStreams(carol, true, 0, 10)))
}
