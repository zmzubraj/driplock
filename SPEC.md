# Driplock spec (v0.2, 2026-11-26)

Verifiable token vesting on gno.land. Built for the Gnome Tavern Hackathon. The function list is in `README.md`; this file fixes the rules and the invariants the tests check.

## Parts

| Part | Path (local placeholder namespace `zdev`) | Role |
|---|---|---|
| Schedule package | `gno.land/p/zdev/driplock/schedule` | Pure math. No state. Reusable by any realm. |
| Driplock realm | `gno.land/r/zdev/driplock` | Escrow, streams, cancel windows, recovery, Proof of Lock, statements, pages, read APIs. |
| Demo token | `gno.land/r/zdev/dripdemo` | A free GRC20 (DRIP) with an hourly faucet. |

At deploy time `zdev` is replaced with the deployer's own address namespace, because Onyx only lets an account deploy under its own address or a registered name.

## Schedule rules

- **Inputs:** `total`, `start`, `cliff`, `end`, `period`, all `int64`, with times in Unix seconds.
- **Valid when:**
  - `total > 0`;
  - `start >= 0`;
  - `start <= cliff <= end` and `start < end`;
  - `end - start <= 50 years`;
  - `period` is 0 (continuous) or between 1 and `end - start`.
- **`VestedAt(t)`:**
  - `0` when `t < cliff`.
  - `total` when `t >= end`.
  - Otherwise `floor(total * e / (end - start))`, where `e = t - start`, rounded down to a whole number of periods when `period > 0`. This is computed without overflow as `q*e + (r*e)/d`.
- **At the cliff,** everything accrued since `start` unlocks at once.
- **`ReleasedBetween(a, b)`** is `VestedAt(b) - VestedAt(a)`.
- **`NextUnlockAfter(t)`** is the earliest time after `t` with a larger vested amount, found by binary search.

## Realm rules

| Rule | Detail |
|---|---|
| Create | Coin streams need a direct user call (`IsUserCall` plus `OriginSend`) carrying exactly one coin. GRC20 streams pull an exact amount from an allowance. `start = 0` means now and `cliff = 0` means no cliff. `end` must be in the future. |
| Cancel window | `cancelUntil = 0` means never cancelable. Otherwise it must be after now and no later than `end`. Cancel works only while `now < cancelUntil`, the stream is not canceled, and it is not fully vested. Cancel refunds `total - VestedAt(now)`. |
| Withdraw | The recipient (or anyone through `WithdrawFor`) pays `VestedAt(effective now) - withdrawn` to the recipient. Effective now is the cancel time for canceled streams. |
| Transfer | Only the recipient. It clears any backup. |
| Recovery | The recipient sets a backup and an inactivity window (1 day to 10 years). Only the recipient's `Withdraw`, `Ping` and `SetBackup` count as activity. The backup may claim when `now >= lastActive + inactivity`. |
| Batch | At most 50 entries. The amounts must add up exactly to the coin sent. Every entry is validated before any stream is stored. |
| History | Each stream keeps its newest 64 events. Statements read at most 100 streams and 500 rows per page. |
| Proof of Lock | Reads at most 500 live streams per asset. "Live" means still holding funds: a stream leaves the live index once `withdrawn + refunded == total`. |

## Invariants (tested)

1. For every stream, `withdrawn + refunded <= total`, at all times.
2. `withdrawn` never decreases. A withdraw never pays more than `VestedAt(effectiveNow) - withdrawn`, and always pays the recipient.
3. After a cancel, `withdrawn + refunded` reaches exactly `total` once the recipient withdraws the rest.
4. Per asset, the escrow ledger equals the sum over live streams of (unvested + claimable). Proof of Lock shows this as "Reconciled".
5. Identity always comes from `cur.Previous().Address()`, never from an argument.
6. Cancel is impossible outside the window fixed at creation.
7. A relayer cannot reset the recovery timer, and an old owner's backup has no power after a transfer.
8. State is written before any transfer, and batches are validated before any write.
9. Render never echoes raw path input, escapes user-supplied values, caps every loop, and makes CSV cells inert in spreadsheets.

## Known limits

- A GRC20 token's own admin realm controls its ledger and could burn escrowed balances. Only stream tokens you trust. This cannot affect other tokens.
- No top-up and no milestone-based release in v0.2.
