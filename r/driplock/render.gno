package driplock

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/svg/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	homeLimit    = 20
	addrPageSize = 50
)

// Render serves three pages:
//
//	""             latest streams and how to use the realm
//	"<id>"         one stream, with a progress bar
//	"addr/<g1...>" streams sent or received by one address
//
// path is attacker-controlled: it is parsed, validated, and never echoed raw.
func Render(path string) string {
	query := ""
	if i := strings.Index(path, "?"); i >= 0 {
		path, query = path[:i], path[i+1:]
	}
	t := now()
	switch {
	case path == "":
		return renderHome(t, queryInt(query, "page", 1))
	case strings.HasPrefix(path, "lock/"):
		return renderLock(strings.TrimPrefix(path, "lock/"), t)
	case strings.HasPrefix(path, "statement/"):
		return renderStatement(strings.TrimPrefix(path, "statement/"))
	case strings.HasPrefix(path, "addr/"):
		return renderAddr(strings.TrimPrefix(path, "addr/"), t, uint64(queryInt(query, "after", 0)))
	default:
		id, err := strconv.ParseUint(path, 10, 64)
		if err != nil {
			return "# Not found\n\nUse a numeric stream id, or `addr/<address>`.\n"
		}
		v := streams.Get(seqid.ID(id).Binary())
		if v == nil {
			return "# Not found\n\nNo stream with that id.\n"
		}
		return renderStream(v.(*stream), t)
	}
}

// link builds an absolute gnoweb link to a sub-page of this realm, for
// example "/r/ns/driplock:3". gnoweb does not resolve ":3" on its own.
func link(sub string) string {
	return strings.TrimPrefix(selfPath, "gno.land") + ":" + sub
}

func renderHome(t int64, page int) string {
	var b strings.Builder
	b.WriteString("# Driplock\n\n")
	b.WriteString("Token vesting and payment streams on gno.land. Lock GNOT or a GRC20 token, ")
	b.WriteString("and the recipient withdraws it as it vests, with an optional cliff.\n\n")
	b.WriteString("## Start a stream\n\n")
	b.WriteString("- **Native coins:** call [CreateCoinStream](" + txlink.Call("CreateCoinStream") + ") ")
	b.WriteString("with `-send` (for example `5000000ugnot`). Pass `start = 0` for now and `cliff = 0` for no cliff. `end` is a Unix time. ")
	b.WriteString("Or use [CreateCoinStreamFor](" + txlink.Call("CreateCoinStreamFor") + ") with a cliff and a duration in seconds.\n")
	b.WriteString("- **A whole team at once:** [CreateCoinStreamBatch](" + txlink.Call("CreateCoinStreamBatch") + ") takes comma-separated recipients and amounts from one `-send`.\n")
	b.WriteString("- **GRC20 tokens:** approve this realm (`" + self.String() + "`) for the amount on the token's realm, then call ")
	b.WriteString("[CreateGRC20Stream](" + txlink.Call("CreateGRC20Stream") + ") with the token's `grc20reg` key.\n")
	b.WriteString("- **Recipients** call [Withdraw](" + txlink.Call("Withdraw") + ") at any time. ")
	b.WriteString("Anyone can trigger a payout with [WithdrawFor](" + txlink.Call("WithdrawFor") + "); it always goes to the recipient. ")
	b.WriteString("Recipients can move a stream to a new address with [TransferRecipient](" + txlink.Call("TransferRecipient") + "). ")
	b.WriteString("**Senders** can [Cancel](" + txlink.Call("Cancel") + ") only inside the cancel window fixed at creation; vested value is never taken back.\n\n")

	n := streams.Size()
	if n == 0 {
		b.WriteString("## Latest streams\n\nNo streams yet.\n")
		return b.String()
	}
	b.WriteString("## Value locked\n\n")
	writeLocked(&b)
	b.WriteString("## Latest streams\n\n" + strconv.Itoa(n) + " streams in total.\n\n")
	b.WriteString("| Stream | Amount | Vested | Status |\n| --- | --- | --- | --- |\n")
	pages := (n + homeLimit - 1) / homeLimit
	if page > pages {
		page = pages
	}
	// ReverseIterateByOffset counts from the end of the tree: O(log n) per page.
	streams.ReverseIterateByOffset((page-1)*homeLimit, homeLimit, func(_ string, v any) bool {
		writeRow(&b, v.(*stream), t)
		return false
	})
	b.WriteString("\nPage " + strconv.Itoa(page) + " of " + strconv.Itoa(pages) + ".")
	if page > 1 {
		b.WriteString(" [Newer](" + link("?page="+strconv.Itoa(page-1)) + ")")
	}
	if page < pages {
		b.WriteString(" [Older](" + link("?page="+strconv.Itoa(page+1)) + ")")
	}
	b.WriteString("\n")
	return b.String()
}

func renderAddr(raw string, t int64, after uint64) string {
	addr := address(raw)
	if !addr.IsValid() {
		return "# Not found\n\nThat is not a valid address.\n"
	}
	var b strings.Builder
	b.WriteString("# Streams of " + addr.String() + "\n\n")
	b.WriteString("[Statement and CSV](" + link("statement/"+addr.String()) + ")\n\n")
	writeIndex(&b, "Receiving", &byRecipient, addr, t, after)
	writeIndex(&b, "Sending", &bySender, addr, t, after)
	return b.String()
}

// writeIndex prints up to addrPageSize streams of an index, starting after
// stream id `after` (cursor pagination: each page costs the same).
func writeIndex(b *strings.Builder, title string, idx *avl.Tree, addr address, t int64, after uint64) {
	b.WriteString("## " + title + "\n\n")
	prefix := addr.String() + "/"
	page := idsAfter(idx, prefix, after, addrPageSize+1)
	for i, s := range page {
		if i == addrPageSize {
			b.WriteString("\n[Next page](" + link("addr/"+addr.String()+"?after="+page[i-1].idString()) + ")\n")
			break
		}
		if i == 0 {
			b.WriteString("| Stream | Amount | Vested | Status |\n| --- | --- | --- | --- |\n")
		}
		writeRow(b, s, t)
	}
	if len(page) == 0 {
		b.WriteString("None.\n")
	}
	b.WriteString("\n")
}

// idsAfter returns up to limit streams from an address index whose id is
// greater than after.
func idsAfter(idx *avl.Tree, prefix string, after uint64, limit int) []*stream {
	start := prefix
	if after > 0 {
		start = prefix + seqid.ID(after+1).Binary()
	}
	var out []*stream
	idx.Iterate(start, prefix+"\xff", func(k string, _ any) bool {
		if v := streams.Get(strings.TrimPrefix(k, prefix)); v != nil {
			out = append(out, v.(*stream))
		}
		return len(out) >= limit
	})
	return out
}

// queryInt reads a positive integer query parameter, or returns def.
func queryInt(query, key string, def int) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, key+"=") {
			v, err := strconv.Atoi(strings.TrimPrefix(kv, key+"="))
			if err == nil && v > 0 && v < 1_000_000_000 {
				return v
			}
		}
	}
	return def
}

func writeRow(b *strings.Builder, s *stream, t int64) {
	id := s.idString()
	b.WriteString("| [#" + id + "](" + link(id) + ") | " + formatAmount(s, s.sched.Total()) +
		" | " + pct(s.vestedAt(t), s.sched.Total()) + " | " + s.status(t) + " |\n")
}

func renderStream(s *stream, t int64) string {
	id := s.idString()
	total := s.sched.Total()
	vested := s.vestedAt(t)
	var b strings.Builder
	b.WriteString("# Stream #" + id + "\n\n")
	b.WriteString(progressBar(s, vested, total).Render("vesting progress") + "\n\n")
	b.WriteString("| Field | Value |\n| --- | --- |\n")
	row := func(k, v string) { b.WriteString("| " + k + " | " + v + " |\n") }
	row("Status", s.status(t))
	row("Asset", sanitize.TableCell(s.kind.String()+" "+s.asset)+" ([Proof of Lock]("+link("lock/"+s.assetKey())+"))")
	row("Total", formatAmount(s, total))
	row("Vested now", formatAmount(s, vested)+" ("+pct(vested, total)+")")
	row("Withdrawn", formatAmount(s, s.withdrawn))
	row("Withdrawable now", formatAmount(s, s.withdrawableAt(t)))
	if s.canceled {
		row("Canceled at", unix(s.canceledAt))
		row("Refunded to sender", formatAmount(s, s.refunded))
	}
	row("Sender", s.sender.String()+" ([streams]("+link("addr/"+s.sender.String())+"))")
	row("Recipient", s.recipient.String()+" ([streams]("+link("addr/"+s.recipient.String())+"))")
	row("Start", unix(s.sched.Start()))
	row("Cliff", unix(s.sched.Cliff()))
	row("End", unix(s.sched.End()))
	row("Unlocks", unlockStyle(s.sched.Period()))
	row("Cancel terms", cancelTerms(s, t))
	row("Lost-key recovery", recoveryTerms(s, t))
	b.WriteString("\n[Withdraw](" + txlink.Call("Withdraw", "id", id) + ")")
	if s.cancelOpen(t) {
		b.WriteString(" · [Cancel](" + txlink.Call("Cancel", "id", id) + ")")
	}
	b.WriteString("\n")
	return b.String()
}

func progressBar(s *stream, vested, total int64) *svg.Canvas {
	const w, h = 480, 28
	c := svg.NewCanvas(w, h)
	c.Append(svg.NewRectangle(0, 0, w, h, "#e7e5df"))
	c.Append(svg.NewRectangle(0, 0, int(bps(vested, total)*w/10000), h, "#7cb38a"))
	c.Append(svg.NewRectangle(0, 0, int(bps(s.withdrawn, total)*w/10000), h, "#2f6b45"))
	if s.canceled {
		x := int(bps(s.sched.VestedAt(s.canceledAt), total) * w / 10000)
		c.Append(svg.NewRectangle(x, 0, 2, h, "#b3412f"))
	}
	return c
}

// bps returns part/total in basis points, clamped to [0, 10000], without
// overflowing for large totals.
func bps(part, total int64) int64 {
	if total <= 0 || part <= 0 {
		return 0
	}
	var r int64
	if total >= 10000 {
		r = part / (total / 10000)
	} else {
		r = part * 10000 / total
	}
	if r > 10000 {
		r = 10000
	}
	return r
}

func pct(part, total int64) string {
	p := bps(part, total)
	return strconv.FormatInt(p/100, 10) + "." + pad2(p%100) + "%"
}

func pad2(v int64) string {
	if v < 10 {
		return "0" + strconv.FormatInt(v, 10)
	}
	return strconv.FormatInt(v, 10)
}

// formatAmount shows ugnot as GNOT and GRC20 amounts with the token's decimals.
func formatAmount(s *stream, amount int64) string {
	return formatAsset(s.kind, s.asset, amount)
}

func formatAsset(kind assetKind, asset string, amount int64) string {
	switch {
	case kind == kindCoin && asset == "ugnot":
		return withDecimals(amount, 6) + " GNOT"
	case kind == kindGRC20:
		if tok := grc20reg.Get(asset); tok != nil {
			return withDecimals(amount, tok.GetDecimals()) + " " + sanitize.TableCell(tok.GetSymbol())
		}
	}
	return strconv.FormatInt(amount, 10) + " " + sanitize.TableCell(asset)
}

// writeLocked lists, per asset, what the realm currently holds for streams.
func writeLocked(b *strings.Builder) {
	rows := 0
	escrowed.Iterate("", "", func(key string, v any) bool {
		amount := v.(int64)
		if amount == 0 {
			return false
		}
		kind, asset := splitAssetKey(key)
		if rows == 0 {
			b.WriteString("| Asset | Locked in streams | Proof of Lock |\n| --- | --- | --- |\n")
		}
		b.WriteString("| " + sanitize.TableCell(kind.String()+" "+asset) + " | " + formatAsset(kind, asset, amount) +
			" | [calendar and proof](" + link("lock/"+key) + ") |\n")
		rows++
		return rows >= 20
	})
	if rows == 0 {
		b.WriteString("Nothing locked right now.\n")
	}
	b.WriteString("\n")
}

func withDecimals(amount int64, decimals int) string {
	raw := strconv.FormatInt(amount, 10)
	if decimals <= 0 {
		return raw
	}
	for len(raw) <= decimals {
		raw = "0" + raw
	}
	whole, frac := raw[:len(raw)-decimals], strings.TrimRight(raw[len(raw)-decimals:], "0")
	if frac == "" {
		return whole
	}
	return whole + "." + frac
}

func unix(ts int64) string {
	return time.Unix(ts, 0).UTC().Format("2006-01-02 15:04 UTC")
}

// cancelTerms states the binding cancel rule in plain words.
func cancelTerms(s *stream, t int64) string {
	switch {
	case s.canceled:
		return "canceled on " + unix(s.canceledAt)
	case s.cancelUntil == 0:
		return "**never cancelable**: the sender cannot take anything back"
	case t < s.cancelUntil:
		return "the sender can cancel until " + unix(s.cancelUntil) + "; vested value always stays with the recipient"
	default:
		return "**no longer cancelable** (the window closed on " + unix(s.cancelUntil) + ")"
	}
}

func unlockStyle(period int64) string {
	if period == 0 {
		return "continuously, every second"
	}
	return "in steps, every " + humanDuration(period)
}

// humanDuration prints seconds as the largest whole unit that fits.
func humanDuration(sec int64) string {
	units := []struct {
		n    int64
		name string
	}{{365 * 86400, "year"}, {30 * 86400, "month"}, {7 * 86400, "week"}, {86400, "day"}, {3600, "hour"}, {60, "minute"}, {1, "second"}}
	for _, u := range units {
		if sec%u.n == 0 {
			v := sec / u.n
			if v == 1 {
				return "1 " + u.name
			}
			return strconv.FormatInt(v, 10) + " " + u.name + "s"
		}
	}
	return strconv.FormatInt(sec, 10) + " seconds"
}

func recoveryTerms(s *stream, t int64) string {
	if s.backup == "" {
		return "no backup set (the recipient can add one with [SetBackup](" + txlink.Call("SetBackup", "id", s.idString()) + "))"
	}
	due := s.lastActive + s.inactivity
	if t >= due {
		return "backup " + s.backup.String() + " **can take over now** (recipient inactive since " + unix(s.lastActive) + ")"
	}
	return "backup " + s.backup.String() + " can take over after " + unix(due) + " if the recipient stays inactive"
}
