package driplock

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestStatementTracksMovementsAcrossTransfers(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1_000_000, 0, 100, true)
	sec(30)
	testing.SetRealm(testing.NewUserRealm(bob))
	Withdraw(cross(cur), id) // bob +0.3 GNOT
	TransferRecipient(cross(cur), id, dave)
	sec(20)
	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id) // alice gets 0.5 GNOT back; dave keeps 0.2 claimable

	alicePage := Render("statement/" + alice.String())
	uassert.True(t, strings.Contains(alicePage, "| created | - 1 GNOT |"))
	uassert.True(t, strings.Contains(alicePage, "| cancel refund | + 0.5 GNOT |"))

	// Bob keeps his history after transferring the stream away.
	bobPage := Render("statement/" + bob.String())
	uassert.True(t, strings.Contains(bobPage, "| withdraw | + 0.3 GNOT |"))
	uassert.True(t, strings.Contains(bobPage, "| transfer |"))
	uassert.False(t, strings.Contains(bobPage, "| cancel refund |"))

	davePage := Render("statement/" + dave.String())
	uassert.True(t, strings.Contains(davePage, "| transfer |"))
	uassert.True(t, strings.Contains(davePage, "```csv"))
	uassert.True(t, strings.Contains(davePage, ",1,transfer,,0,coin:ugnot"))

	csvLine := ",1,withdraw,in,300000,coin:ugnot"
	uassert.True(t, strings.Contains(bobPage, csvLine))
}

func TestStatementBounds(cur realm, t *testing.T) {
	reset()
	uassert.True(t, strings.Contains(Render("statement/nope"), "not a valid address"))
	uassert.True(t, strings.Contains(Render("statement/"+carol.String()), "No activity."))
}

func TestHistoryIsCapped(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 100_000, 0, 100_000, false)
	testing.SetRealm(testing.NewUserRealm(bob))
	for i := 0; i < historyCap+10; i++ {
		sec(5)
		Withdraw(cross(cur), id)
	}
	s := mustGet(id)
	uassert.Equal(t, historyCap, len(s.history))
	uassert.Equal(t, "withdraw", s.history[0].event) // the oldest ("created") rolled off
}

func TestCSVSafe(t *testing.T) {
	uassert.Equal(t, "'=SUM(A1)", csvSafe("=SUM(A1)"))
	uassert.Equal(t, "a b", csvSafe("a,b"))
	uassert.Equal(t, "coin:ugnot", csvSafe("coin:ugnot"))
}
