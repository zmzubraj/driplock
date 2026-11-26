// Package driplock escrows coins or GRC20 tokens and releases them to a
// recipient on a vesting schedule: continuous or in steps (for example
// monthly), with an optional cliff and an optional cancel window.
//
// Create a stream of native coins (send exactly one coin with the call):
//
//	gnokey maketx call -pkgpath gno.land/r/<ns>/driplock -func CreateCoinStream \
//	  -args <recipient> -args 0 -args 0 -args <endUnix> -args 0 -args 0 \
//	  -send 1000000ugnot ...
//
// The arguments after the recipient are start, cliff, end, period and
// cancelUntil. start = 0 means now, cliff = 0 means no cliff, period = 0
// means continuous, and cancelUntil = 0 means the stream can never be
// canceled. The recipient calls Withdraw(id) at any time to collect what has
// vested. Before cancelUntil, the sender can Cancel(id): the unvested part
// returns to the sender at once and the vested part stays with the recipient.
// The cancel window is fixed at creation and shown on the stream's page.
//
// GRC20 streams pull an exact amount from an allowance the caller granted to
// this realm's address, through gno.land/r/nt/grc20reg/v0.
package driplock

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/zdev/driplock/schedule"
	"gno.land/r/nt/grc20reg/v0"
)

type assetKind int

const (
	kindCoin assetKind = iota
	kindGRC20
)

func (k assetKind) String() string {
	if k == kindGRC20 {
		return "grc20"
	}
	return "coin"
}

// stream is internal state. It is never returned by pointer; readers get a
// StreamInfo copy from GetStream.
type stream struct {
	id          seqid.ID
	sender      address
	recipient   address
	kind        assetKind
	asset       string // coin denom, or grc20reg key
	sched       schedule.Schedule
	cancelUntil int64 // 0 = never cancelable; otherwise Cancel works while now < cancelUntil
	createdAt   int64
	withdrawn   int64
	canceled    bool
	canceledAt  int64
	refunded    int64

	// Recovery: if the recipient shows no activity for `inactivity` seconds,
	// `backup` may take over the stream. Only the recipient's own actions
	// count as activity; relayed withdrawals do not.
	backup     address
	inactivity int64
	lastActive int64

	history []entry // capped at historyCap, newest kept; see statement.gno
}

var (
	streams     avl.Tree // id.Binary() -> *stream
	bySender    avl.Tree // sender + "/" + id.Binary() -> struct{}
	byRecipient avl.Tree // recipient + "/" + id.Binary() -> struct{}
	counter     seqid.ID

	// escrowed tracks, per asset, how much this realm owes to streams.
	// It is a defense-in-depth check: a payout can never exceed it.
	escrowed avl.Tree // assetKey -> int64

	// activeByAsset indexes streams that still hold funds, per asset, so
	// Proof of Lock pages scan only live streams.
	activeByAsset avl.Tree // assetKey + "/" + id.Binary() -> struct{}

	// self is this realm's address: the spender a GRC20 sender must approve.
	self     address
	selfPath string // for example gno.land/r/ns/driplock, used in links
)

func init(cur realm) {
	self = cur.Address()
	selfPath = cur.PkgPath()
}

// Address returns this realm's address. Approve it on a GRC20 token before
// calling CreateGRC20Stream.
func Address() address { return self }

// CreateCoinStream escrows the single native coin sent with this call.
// Times are Unix seconds: start = 0 means now, cliff = 0 means no cliff,
// period = 0 means continuous, cancelUntil = 0 means never cancelable.
func CreateCoinStream(cur realm, recipient address, start, cliff, end, period, cancelUntil int64) uint64 {
	return createCoin(0, cur, recipient, terms{start, cliff, end, period, cancelUntil})
}

func createCoin(_ int, rlm realm, recipient address, tm terms) uint64 {
	coin := receiveCoin(0, rlm)
	sched, cancelUntil := mustTerms(coin.Amount, tm)
	checkRecipient(rlm.Address(), recipient)
	return store(rlm.Previous().Address(), recipient, kindCoin, coin.Denom, sched, cancelUntil)
}

// CreateCoinStreamFor is CreateCoinStream with times relative to now, in
// seconds: the cliff, the full duration, the step period (0 = continuous)
// and the cancel window (0 = never cancelable). Setting cancelSeconds equal
// to cliffSeconds gives the usual "can only be canceled before the cliff".
func CreateCoinStreamFor(cur realm, recipient address, cliffSeconds, durationSeconds, periodSeconds, cancelSeconds int64) uint64 {
	return createCoin(0, cur, recipient, relativeTerms(cliffSeconds, durationSeconds, periodSeconds, cancelSeconds))
}

// CreateCoinStreamBatch opens one stream per recipient from a single -send,
// for example a team vesting plan. recipients and amounts are comma-separated
// lists of equal length (at most MaxBatch), and the amounts must add up to
// exactly the coin sent. All streams share the same relative schedule. It is
// all or nothing: any bad entry reverts the whole call. Returns the new ids,
// comma-separated.
func CreateCoinStreamBatch(cur realm, recipients, amounts string, cliffSeconds, durationSeconds, periodSeconds, cancelSeconds int64) string {
	coin := receiveCoin(0, cur)
	addrs := splitList(recipients)
	amts := splitList(amounts)
	if len(addrs) == 0 || len(addrs) != len(amts) {
		panic("driplock: recipients and amounts must be non-empty lists of the same length")
	}
	if len(addrs) > MaxBatch {
		panic("driplock: batch is larger than " + strconv.Itoa(MaxBatch))
	}
	tm := relativeTerms(cliffSeconds, durationSeconds, periodSeconds, cancelSeconds)
	parsed := make([]int64, len(amts))
	var sum int64
	for i, a := range amts {
		v, err := strconv.ParseInt(a, 10, 64)
		if err != nil || v <= 0 {
			panic("driplock: amount #" + strconv.Itoa(i+1) + " must be a positive integer")
		}
		if v > maxInt64-sum {
			panic("driplock: amounts overflow")
		}
		sum += v
		parsed[i] = v
	}
	if sum != coin.Amount {
		panic("driplock: amounts add up to " + strconv.FormatInt(sum, 10) + " but " + strconv.FormatInt(coin.Amount, 10) + " was sent")
	}
	// Validate every entry before storing any stream, so the batch is atomic
	// even without relying on transaction rollback.
	scheds := make([]schedule.Schedule, len(addrs))
	var cancelUntil int64
	for i, raw := range addrs {
		checkRecipient(cur.Address(), address(raw))
		scheds[i], cancelUntil = mustTerms(parsed[i], tm)
	}
	sender := cur.Previous().Address()
	ids := make([]string, len(addrs))
	for i, raw := range addrs {
		ids[i] = strconv.FormatUint(store(sender, address(raw), kindCoin, coin.Denom, scheds[i], cancelUntil), 10)
	}
	return strings.Join(ids, ",")
}

// CreateGRC20Stream pulls exactly amount of the registered token from the
// caller's allowance to this realm, then opens a stream. The caller may be
// a user or another realm (for example a DAO treasury).
// The schedule arguments work as in CreateCoinStream.
func CreateGRC20Stream(cur realm, recipient address, tokenKey string, amount, start, cliff, end, period, cancelUntil int64) uint64 {
	return createGRC20(0, cur, recipient, tokenKey, amount, terms{start, cliff, end, period, cancelUntil})
}

func createGRC20(_ int, rlm realm, recipient address, tokenKey string, amount int64, tm terms) uint64 {
	if amount <= 0 {
		panic("driplock: amount must be positive")
	}
	sender := rlm.Previous().Address()
	tok := grc20reg.MustGet(tokenKey)
	// Validate everything before moving tokens, so a bad schedule never pulls funds.
	sched, cancelUntil := mustTerms(amount, tm)
	checkRecipient(rlm.Address(), recipient)
	if err := tok.RealmTeller(0, rlm).TransferFrom(0, rlm, sender, rlm.Address(), amount); err != nil {
		panic("driplock: cannot pull tokens from allowance: " + err.Error())
	}
	return store(sender, recipient, kindGRC20, tokenKey, sched, cancelUntil)
}

// CreateGRC20StreamFor is CreateGRC20Stream with relative times, like
// CreateCoinStreamFor.
func CreateGRC20StreamFor(cur realm, recipient address, tokenKey string, amount, cliffSeconds, durationSeconds, periodSeconds, cancelSeconds int64) uint64 {
	return createGRC20(0, cur, recipient, tokenKey, amount, relativeTerms(cliffSeconds, durationSeconds, periodSeconds, cancelSeconds))
}

// Withdraw pays the recipient everything vested and not yet withdrawn.
// Only the recipient can call it.
func Withdraw(cur realm, id uint64) int64 {
	s := mustGet(id)
	if cur.Previous().Address() != s.recipient {
		panic("driplock: only the recipient can withdraw")
	}
	s.lastActive = now()
	return withdraw(0, cur, s)
}

// WithdrawFor lets anyone (a friend, a bot, a DAO) trigger the payout of a
// stream. The money always goes to the stream's recipient, never to the
// caller, so this only saves the recipient a transaction.
func WithdrawFor(cur realm, id uint64) int64 {
	return withdraw(0, cur, mustGet(id))
}

// TransferRecipient hands a stream to a new recipient, for example after a
// key rotation. Only the current recipient can call it. What was already
// withdrawn stays withdrawn; everything still owed now goes to newRecipient.
func TransferRecipient(cur realm, id uint64, newRecipient address) {
	s := mustGet(id)
	if cur.Previous().Address() != s.recipient {
		panic("driplock: only the recipient can transfer the stream")
	}
	changeRecipient(s, cur.Address(), newRecipient, "transfer")
}

// Recovery limits for SetBackup.
const (
	MinInactivity = int64(86400)            // 1 day
	MaxInactivity = int64(10 * 365 * 86400) // 10 years
)

// SetBackup names a backup address that may take over this stream if the
// recipient shows no activity for inactivitySeconds (between 1 day and 10
// years). Only the recipient can call it. Pass an empty backup to remove it.
// Calling it, Ping and the recipient's own Withdraw all count as activity.
func SetBackup(cur realm, id uint64, backup address, inactivitySeconds int64) {
	s := mustGet(id)
	if cur.Previous().Address() != s.recipient {
		panic("driplock: only the recipient can set a backup")
	}
	s.lastActive = now()
	if backup == "" {
		s.backup, s.inactivity = "", 0
		chain.Emit("StreamBackupCleared", "id", s.idString())
		return
	}
	checkRecipient(cur.Address(), backup)
	if backup == s.recipient {
		panic("driplock: backup must differ from the recipient")
	}
	if inactivitySeconds < MinInactivity || inactivitySeconds > MaxInactivity {
		panic("driplock: inactivity must be between 1 day and 10 years")
	}
	s.backup, s.inactivity = backup, inactivitySeconds
	chain.Emit("StreamBackupSet",
		"id", s.idString(),
		"backup", backup.String(),
		"inactivity", strconv.FormatInt(inactivitySeconds, 10),
	)
}

// Ping proves the recipient still controls their key, resetting the
// inactivity timer without moving any funds.
func Ping(cur realm, id uint64) {
	s := mustGet(id)
	if cur.Previous().Address() != s.recipient {
		panic("driplock: only the recipient can ping")
	}
	s.lastActive = now()
}

// ClaimAsBackup lets the named backup take over the stream once the
// recipient has been inactive for the agreed time. Everything still owed
// then goes to the backup.
func ClaimAsBackup(cur realm, id uint64) {
	s := mustGet(id)
	caller := cur.Previous().Address()
	if s.backup == "" || caller != s.backup {
		panic("driplock: only the stream's backup can claim it")
	}
	if now() < s.lastActive+s.inactivity {
		panic("driplock: the recipient is not inactive long enough yet")
	}
	changeRecipient(s, cur.Address(), caller, "recovery")
}

// changeRecipient moves the stream to a new owner. Any backup is cleared:
// the new owner must choose their own.
func changeRecipient(s *stream, self, to address, reason string) {
	checkRecipient(self, to)
	old := s.recipient
	if to == old {
		panic("driplock: new recipient is the current recipient")
	}
	key := s.id.Binary()
	byRecipient.Remove(old.String() + "/" + key)
	byRecipient.Set(to.String()+"/"+key, struct{}{})
	involve(to, key)
	logEvent(s, reason, 0, old, to)
	s.recipient = to
	s.backup, s.inactivity = "", 0
	s.lastActive = now()
	chain.Emit("StreamRecipientChanged",
		"id", s.idString(),
		"from", old.String(),
		"to", to.String(),
		"reason", reason,
	)
}

func withdraw(_ int, rlm realm, s *stream) int64 {
	amount := s.withdrawableAt(now())
	if amount <= 0 {
		panic("driplock: nothing to withdraw yet")
	}
	// Effects before the transfer.
	s.withdrawn += amount
	release(s, amount)
	settleIfDone(s)
	logEvent(s, "withdraw", amount, self, s.recipient)
	pay(0, rlm, s, s.recipient, amount)
	chain.Emit("StreamWithdrawn",
		"id", s.idString(),
		"recipient", s.recipient.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
	return amount
}

// Cancel stops a stream while its cancel window is open. The unvested part
// returns to the sender now; the vested part stays withdrawable by the
// recipient and can never be taken back.
func Cancel(cur realm, id uint64) int64 {
	s := mustGet(id)
	caller := cur.Previous().Address()
	if caller != s.sender {
		panic("driplock: only the sender can cancel")
	}
	if s.cancelUntil == 0 {
		panic("driplock: stream is not cancelable")
	}
	if s.canceled {
		panic("driplock: stream already canceled")
	}
	t := now()
	if t >= s.cancelUntil {
		panic("driplock: the cancel window has closed")
	}
	if s.sched.FullyVestedAt(t) {
		panic("driplock: stream is fully vested, nothing to cancel")
	}
	refund := s.sched.Total() - s.sched.VestedAt(t)
	// Effects before the transfer.
	s.canceled = true
	s.canceledAt = t
	s.refunded = refund
	settleIfDone(s)
	logEvent(s, "cancel refund", refund, self, s.sender)
	if refund > 0 {
		release(s, refund)
		pay(0, cur, s, s.sender, refund)
	}
	chain.Emit("StreamCanceled",
		"id", s.idString(),
		"sender", s.sender.String(),
		"refund", strconv.FormatInt(refund, 10),
	)
	return refund
}

// StreamInfo is a read-only copy of a stream, for other realms and clients.
type StreamInfo struct {
	ID           uint64
	Sender       address
	Recipient    address
	Kind         string // "coin" or "grc20"
	Asset        string // coin denom or grc20reg key
	Total        int64
	Start        int64
	Cliff        int64
	End          int64
	Period       int64 // step length in seconds, 0 = continuous
	Cancelable   bool  // true if the stream had a cancel window at creation
	CancelUntil  int64 // the window closes at this time (0 = never cancelable)
	Canceled     bool
	CanceledAt   int64
	Withdrawn    int64
	Refunded     int64
	Vested       int64   // at the current block time
	Withdrawable int64   // at the current block time
	Backup       address // recovery address, empty if none
	Inactivity   int64   // seconds of recipient inactivity before Backup may claim
	LastActive   int64   // last activity of the recipient (Unix time)
}

// GetStream returns a copy of the stream with the given id.
func GetStream(id uint64) (StreamInfo, bool) {
	v := streams.Get(seqid.ID(id).Binary())
	if v == nil {
		return StreamInfo{}, false
	}
	return v.(*stream).info(now()), true
}

// MaxListLimit caps ListStreams pages.
const MaxListLimit = 50

// ListStreams returns up to limit streams (at most MaxListLimit) that addr
// receives (receiving = true) or sends, with ids greater than afterID. Pass
// the last id of a page as afterID to read the next page.
func ListStreams(addr address, receiving bool, afterID uint64, limit int) []StreamInfo {
	if limit <= 0 || limit > MaxListLimit {
		limit = MaxListLimit
	}
	idx := &bySender
	if receiving {
		idx = &byRecipient
	}
	t := now()
	page := idsAfter(idx, addr.String()+"/", afterID, limit)
	out := make([]StreamInfo, len(page))
	for i, s := range page {
		out[i] = s.info(t)
	}
	return out
}

// StreamCount returns how many streams were ever created.
func StreamCount() int { return streams.Size() }

// ---- internals ----

const (
	// MaxBatch bounds CreateCoinStreamBatch so one call stays cheap.
	MaxBatch = 50
	maxInt64 = int64(9223372036854775807)
)

// receiveCoin returns the single coin sent with a direct user call.
//
// Payment guard pair (keep both): IsUserCall guarantees the -send coins
// landed at this realm, so OriginSend describes a real receipt.
func receiveCoin(_ int, rlm realm) chain.Coin {
	if !rlm.Previous().IsUserCall() {
		panic("driplock: coin streams must be created by a direct user call (maketx call)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Amount <= 0 {
		panic("driplock: send exactly one coin denom with a positive amount")
	}
	return sent[0]
}

// terms are a stream's timing rules, as given by the caller.
type terms struct {
	start, cliff, end, period, cancelUntil int64
}

// relativeTerms turns durations from now (in seconds) into absolute terms.
func relativeTerms(cliffSeconds, durationSeconds, periodSeconds, cancelSeconds int64) terms {
	if durationSeconds <= 0 || durationSeconds > schedule.MaxDuration {
		panic("driplock: duration must be between 1 second and 50 years")
	}
	if cliffSeconds < 0 || cliffSeconds > durationSeconds {
		panic("driplock: cliff must be between 0 and the duration")
	}
	if cancelSeconds < 0 || cancelSeconds > durationSeconds {
		panic("driplock: cancel window must be between 0 and the duration")
	}
	t := now()
	tm := terms{start: t, cliff: t + cliffSeconds, end: t + durationSeconds, period: periodSeconds}
	if cancelSeconds > 0 {
		tm.cancelUntil = t + cancelSeconds
	}
	return tm
}

// splitList splits a comma-separated list and trims spaces around entries.
func splitList(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	for i, p := range parts {
		parts[i] = strings.TrimSpace(p)
	}
	return parts
}

func store(sender, recipient address, kind assetKind, asset string, sched schedule.Schedule, cancelUntil int64) uint64 {
	id := counter.Next()
	s := &stream{
		id:          id,
		sender:      sender,
		recipient:   recipient,
		kind:        kind,
		asset:       asset,
		sched:       sched,
		cancelUntil: cancelUntil,
		createdAt:   now(),
		lastActive:  now(),
	}
	key := id.Binary()
	streams.Set(key, s)
	bySender.Set(sender.String()+"/"+key, struct{}{})
	byRecipient.Set(recipient.String()+"/"+key, struct{}{})
	ak := s.assetKey()
	activeByAsset.Set(ak+"/"+key, struct{}{})
	involve(sender, key)
	involve(recipient, key)
	logEvent(s, "created", sched.Total(), sender, self)
	escrowed.Set(ak, escrowedOf(ak)+sched.Total())
	chain.Emit("StreamCreated",
		"id", s.idString(),
		"sender", sender.String(),
		"recipient", recipient.String(),
		"kind", kind.String(),
		"asset", asset,
		"total", strconv.FormatInt(sched.Total(), 10),
		"start", strconv.FormatInt(sched.Start(), 10),
		"cliff", strconv.FormatInt(sched.Cliff(), 10),
		"end", strconv.FormatInt(sched.End(), 10),
		"period", strconv.FormatInt(sched.Period(), 10),
		"cancel_until", strconv.FormatInt(cancelUntil, 10),
	)
	return uint64(id)
}

// mustTerms applies the convenience defaults and validates the schedule and
// the cancel window. It returns the schedule and the cancelUntil time.
func mustTerms(total int64, tm terms) (schedule.Schedule, int64) {
	t := now()
	if tm.start == 0 {
		tm.start = t
	}
	if tm.cliff == 0 {
		tm.cliff = tm.start
	}
	if tm.end <= t {
		panic("driplock: end must be in the future")
	}
	sched, err := schedule.NewStepped(total, tm.start, tm.cliff, tm.end, tm.period)
	if err != nil {
		panic("driplock: " + err.Error())
	}
	if tm.cancelUntil != 0 && (tm.cancelUntil <= t || tm.cancelUntil > tm.end) {
		panic("driplock: cancelUntil must be 0 (never) or a time after now and no later than end")
	}
	return sched, tm.cancelUntil
}

func checkRecipient(self, recipient address) {
	if !recipient.IsValid() {
		panic("driplock: invalid recipient address")
	}
	if recipient == self {
		panic("driplock: recipient cannot be this realm")
	}
}

// release lowers the per-asset escrow and refuses to go below zero.
func release(s *stream, amount int64) {
	ak := s.assetKey()
	left := escrowedOf(ak) - amount
	if left < 0 {
		panic("driplock: escrow accounting violated")
	}
	escrowed.Set(ak, left)
}

// pay sends amount of the stream's asset from this realm to `to`.
// rlm is the live cur of the calling crossing function. The leading int
// keeps pay a plain (non-crossing) function.
func pay(_ int, rlm realm, s *stream, to address, amount int64) {
	switch s.kind {
	case kindCoin:
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
		bnk.SendCoins(rlm.Address(), to, chain.Coins{chain.NewCoin(s.asset, amount)})
	case kindGRC20:
		tok := grc20reg.MustGet(s.asset)
		if err := tok.RealmTeller(0, rlm).Transfer(0, rlm, to, amount); err != nil {
			panic("driplock: token transfer failed: " + err.Error())
		}
	default:
		panic("driplock: unknown asset kind")
	}
}

func escrowedOf(assetKey string) int64 {
	v := escrowed.Get(assetKey)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func mustGet(id uint64) *stream {
	v := streams.Get(seqid.ID(id).Binary())
	if v == nil {
		panic("driplock: unknown stream id")
	}
	return v.(*stream)
}

func now() int64 { return time.Now().Unix() }

// effectiveTime freezes the schedule at the cancel time.
func (s *stream) effectiveTime(t int64) int64 {
	if s.canceled && s.canceledAt < t {
		return s.canceledAt
	}
	return t
}

func (s *stream) vestedAt(t int64) int64 {
	return s.sched.VestedAt(s.effectiveTime(t))
}

func (s *stream) withdrawableAt(t int64) int64 {
	return s.vestedAt(t) - s.withdrawn
}

// settleIfDone drops a stream from the active index once every unit has
// left escrow (withdrawn by the recipient or refunded to the sender).
func settleIfDone(s *stream) {
	if s.withdrawn+s.refunded == s.sched.Total() {
		activeByAsset.Remove(s.assetKey() + "/" + s.id.Binary())
	}
}

// cancelOpen reports whether the sender could cancel at time t.
func (s *stream) cancelOpen(t int64) bool {
	return s.cancelUntil != 0 && !s.canceled && t < s.cancelUntil && !s.sched.FullyVestedAt(t)
}

func (s *stream) assetKey() string { return s.kind.String() + ":" + s.asset }

func (s *stream) idString() string { return strconv.FormatUint(uint64(s.id), 10) }

func (s *stream) status(t int64) string {
	switch {
	case s.canceled && s.withdrawableAt(t) == 0:
		return "canceled"
	case s.canceled:
		return "canceled, vested part claimable"
	case s.withdrawn == s.sched.Total():
		return "completed"
	case s.sched.FullyVestedAt(t):
		return "fully vested"
	case t < s.sched.Cliff():
		return "before cliff"
	default:
		return "streaming"
	}
}

func (s *stream) info(t int64) StreamInfo {
	return StreamInfo{
		ID:           uint64(s.id),
		Sender:       s.sender,
		Recipient:    s.recipient,
		Kind:         s.kind.String(),
		Asset:        s.asset,
		Total:        s.sched.Total(),
		Start:        s.sched.Start(),
		Cliff:        s.sched.Cliff(),
		End:          s.sched.End(),
		Period:       s.sched.Period(),
		Cancelable:   s.cancelUntil != 0,
		CancelUntil:  s.cancelUntil,
		Canceled:     s.canceled,
		CanceledAt:   s.canceledAt,
		Withdrawn:    s.withdrawn,
		Refunded:     s.refunded,
		Vested:       s.vestedAt(t),
		Withdrawable: s.withdrawableAt(t),
		Backup:       s.backup,
		Inactivity:   s.inactivity,
		LastActive:   s.lastActive,
	}
}
