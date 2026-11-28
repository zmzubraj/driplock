package driplock

import (
	"sort"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	historyCap        = 64   // events kept per stream: the creation entry plus the newest
	statementStreams  = 100  // streams read per statement page (the most recent)
	statementRowLimit = 500  // rows printed per statement page
	statementRowCap   = 2000 // rows collected before sorting, to bound the page's cost
)

// entry is one money movement or ownership change of a stream.
type entry struct {
	t      int64
	event  string // created, withdraw, cancel refund, transfer, recovery
	amount int64
	from   address
	to     address
}

// everByAddr indexes every stream an address was ever part of (as sender,
// recipient or later owner), so statements survive transfers.
var everByAddr avl.Tree // addr + "/" + id.Binary() -> struct{}

func involve(addr address, key string) {
	everByAddr.Set(addr.String()+"/"+key, struct{}{})
}

// logEvent appends to a stream's history. When the cap is reached it drops
// the oldest event after the first: the creation entry is never dropped, so
// nobody (for example a stranger calling WithdrawFor many times) can erase
// the record of what was locked. Exact totals always come from the stream's
// state, which the statement prints next to the rows.
func logEvent(s *stream, event string, amount int64, from, to address) {
	s.history = append(s.history, entry{t: now(), event: event, amount: amount, from: from, to: to})
	if len(s.history) > historyCap {
		kept := make([]entry, 0, historyCap)
		kept = append(kept, s.history[0])
		kept = append(kept, s.history[len(s.history)-historyCap+1:]...)
		s.trimmed += len(s.history) - len(kept)
		s.history = kept
	}
}

type stmtRow struct {
	e    entry
	s    *stream
	sign string // "+" received by the address, "-" paid by it, "" other
}

type byTime []stmtRow

func (r byTime) Len() int           { return len(r) }
func (r byTime) Less(i, j int) bool { return r[i].e.t < r[j].e.t }
func (r byTime) Swap(i, j int)      { r[i], r[j] = r[j], r[i] }

func renderStatement(raw string) string {
	addr := address(raw)
	if !addr.IsValid() {
		return "# Not found\n\nThat is not a valid address.\n"
	}
	var rows []stmtRow
	prefix := addr.String() + "/"
	n := 0
	truncated := false
	rowsCapped := false
	var trimmedStreams []*stream
	// Newest streams first, so unsolicited old or new dust cannot hide an
	// address's latest real activity behind the stream limit.
	everByAddr.ReverseIterate(prefix, prefix+"\xff", func(k string, _ any) bool {
		if n >= statementStreams {
			truncated = true
			return true
		}
		if len(rows) >= statementRowCap {
			rowsCapped = true
			return true
		}
		n++
		v := streams.Get(strings.TrimPrefix(k, prefix))
		if v == nil {
			return false
		}
		s := v.(*stream)
		if s.trimmed > 0 {
			trimmedStreams = append(trimmedStreams, s)
		}
		for _, e := range s.history {
			sign := ""
			switch {
			case e.to == addr && e.amount > 0:
				sign = "+"
			case e.from == addr && e.amount > 0:
				sign = "-"
			case e.from != addr && e.to != addr:
				continue // not this address's movement
			}
			rows = append(rows, stmtRow{e: e, s: s, sign: sign})
		}
		return false
	})
	sort.Stable(byTime(rows))

	var b strings.Builder
	b.WriteString("# Statement for " + addr.String() + "\n\n")
	b.WriteString("Every Driplock movement that involves this address, oldest first, served by the chain. ")
	b.WriteString("`+` is money this address received (a withdrawal or a cancel refund). `-` is money it locked into a stream.\n\n")
	if len(rows) == 0 {
		b.WriteString("No activity.\n")
		return b.String()
	}
	b.WriteString("| Date | Stream | Event | Amount |\n| --- | --- | --- | --- |\n")
	var csv strings.Builder
	csv.WriteString("date_utc,unix,stream,event,direction,amount_units,asset\n")
	for i, r := range rows {
		if i >= statementRowLimit {
			b.WriteString("\nShowing the first " + strconv.Itoa(statementRowLimit) + " rows.\n")
			break
		}
		id := r.s.idString()
		amount := ""
		if r.e.amount > 0 {
			amount = r.sign + " " + formatAmount(r.s, r.e.amount)
		}
		b.WriteString("| " + unix(r.e.t) + " | [#" + id + "](" + link(id) + ") | " + r.e.event + " | " + amount + " |\n")
		dir := map[string]string{"+": "in", "-": "out", "": ""}[r.sign]
		csv.WriteString(unix(r.e.t) + "," + strconv.FormatInt(r.e.t, 10) + "," + id + "," + r.e.event + "," + dir + "," +
			strconv.FormatInt(r.e.amount, 10) + "," + csvSafe(r.s.assetKey()) + "\n")
	}
	if truncated {
		b.WriteString("\nOnly the " + strconv.Itoa(statementStreams) + " most recent streams are included.\n")
	}
	if rowsCapped {
		b.WriteString("\nOnly the first " + strconv.Itoa(statementRowCap) + " events read are included.\n")
	}
	for _, s := range trimmedStreams {
		b.WriteString("\nStream [#" + s.idString() + "](" + link(s.idString()) + ") has " + strconv.Itoa(s.trimmed) +
			" older events not listed. Its exact totals: withdrawn " + formatAmount(s, s.withdrawn) +
			", refunded " + formatAmount(s, s.refunded) + ".\n")
	}
	b.WriteString("\n## CSV\n\nCopy into a spreadsheet. Amounts are in base units (ugnot, or the token's smallest unit).\n\n")
	b.WriteString("```csv\n" + csv.String() + "```\n")
	return b.String()
}

// csvSafe keeps a CSV cell on one line, unquoted, and inert in spreadsheets.
func csvSafe(v string) string {
	v = strings.NewReplacer(",", " ", "\n", " ", "\r", " ", "`", "'").Replace(v)
	if v != "" && strings.ContainsAny(v[:1], "=+-@") {
		v = "'" + v
	}
	return v
}
