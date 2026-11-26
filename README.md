# Driplock

**Verifiable token vesting for gno.land.** Lock GNOT or any GRC20 token on a schedule (continuous or monthly steps, with a cliff). The chain itself publishes proof of what is locked, when it unlocks, and who can still take it back.

## Why Driplock

| The pain | What Driplock does |
|---|---|
| "Team tokens are locked" is a claim that holders cannot check. Unlock calendars live in off-chain trackers, which tell investors to double-check them. | **Proof of Lock:** a page per token, served by the chain from live escrow. It shows what is locked, what is still vesting, what senders can still cancel, a 12-month unlock calendar, and a check that every stream adds up to the escrow ledger. |
| Admins can revoke vesting without warning. | **Binding cancel terms:** a cancel window is fixed when the stream is created (for example "only before the cliff"). It is shown on the stream's page and enforced on chain. Vested value can never be taken back. |
| A lost key loses every future unlock. | **Lost-key recovery:** the recipient names a backup and an inactivity window. If they stay silent past it, the backup takes over. Relayed withdrawals do not reset the timer, so nobody can block a recovery. |
| Shared-pool vesting contracts have been drained through share-accounting bugs (UNCX: about $86k, then about $1.5M across four chains). | **Exact per-stream accounting:** no shares. A per-asset escrow ledger refuses any payout above deposits, and Proof of Lock reconciles the two in public. |
| Accounting for vesting payouts is left to the user. | **Statements:** every movement per address, with a CSV to copy into a spreadsheet. |

Website: https://driplock.vercel.app

Everything is a gnoweb page rendered from chain state. There is no separate frontend, indexer or server to trust.

## What is in this repo

| Path | What it is |
|---|---|
| `p/schedule` | A pure, reusable package: continuous or stepped vesting with a cliff, `ReleasedBetween` and `NextUnlockAfter`. Exact integer math with no overflow for any int64 total up to 50 years. Any realm can import it. |
| `r/driplock` | The realm: escrow, streams, cancel windows, recovery, Proof of Lock, statements, paginated pages and read APIs. |
| `r/dripdemo` | A free demo GRC20 token (DRIP) with an hourly faucet, so anyone can try GRC20 streams. |
| `SPEC.md`, `FEATURE-PLAN.md` | The rules, the invariants, and the research behind each feature. |

Local paths use the placeholder namespace `zdev`. At deploy time it is replaced with the deployer's address namespace.

## Functions

| Function | Who | What |
|---|---|---|
| `CreateCoinStreamFor(recipient, cliffSeconds, durationSeconds, periodSeconds, cancelSeconds)` | Sender, with `-send` | The easy way: times are relative to now. `period = 0` means continuous. `cancelSeconds = 0` means never cancelable; set it equal to `cliffSeconds` for "cancelable only before the cliff". |
| `CreateCoinStream(recipient, start, cliff, end, period, cancelUntil)` | Sender, with `-send` | The same, with absolute Unix times. |
| `CreateCoinStreamBatch(recipients, amounts, cliffSeconds, durationSeconds, periodSeconds, cancelSeconds)` | Sender, with `-send` | Up to 50 recipients from one payment. Comma-separated lists. All or nothing. |
| `CreateGRC20StreamFor(...)` / `CreateGRC20Stream(...)` | Sender (a user or a realm such as a DAO) | Pulls an exact amount from an allowance. Approve `Address()` first. |
| `Withdraw(id)` | Recipient | Collects everything vested. Counts as activity. |
| `WithdrawFor(id)` | Anyone | Triggers the payout. The money always goes to the recipient. |
| `Cancel(id)` | Sender, inside the cancel window | Refunds the unvested part. The vested part stays with the recipient. |
| `TransferRecipient(id, newRecipient)` | Recipient | Moves the stream, for example after a key rotation. |
| `SetBackup(id, backup, inactivitySeconds)` / `Ping(id)` | Recipient | Names a recovery address (1 day to 10 years of inactivity) and proves they are still active. |
| `ClaimAsBackup(id)` | The backup | Takes over after the inactivity window. |
| `GetStream`, `ListStreams`, `GetLockSummary`, `StreamCount`, `Address` | Anyone, including other realms | Read APIs that return value copies. `ListStreams` uses cursor pages of up to 50. |

## Pages

| Path | Shows |
|---|---|
| `/r/<ns>/driplock` | How to use it, value locked per asset with links to Proof of Lock, and the latest streams (`?page=N`). |
| `:<id>` | One stream: progress bar, amounts, unlock style, cancel terms, recovery status, and Withdraw and Cancel actions. |
| `:lock/<asset key>` | Proof of Lock and the unlock calendar, for example `:lock/coin:ugnot`. |
| `:addr/<g1...>` | Streams an address receives and sends (`?after=<id>` for the next page). |
| `:statement/<g1...>` | Every movement for that address, plus a CSV block. |

## Run it locally

```bash
gnodev local -C /path/to/driplock \
  -paths gno.land/p/zdev/driplock/schedule,gno.land/r/zdev/driplock,gno.land/r/zdev/dripdemo
# then open http://localhost:8888/r/zdev/driplock
```

## Try it (gnokey)

```bash
# Team vesting: 12 GNOT over 12 months in monthly steps, 3-month cliff,
# cancelable only before the cliff.
M=2592000   # 30 days in seconds
gnokey maketx call -pkgpath gno.land/r/<ns>/driplock -func CreateCoinStreamFor \
  -args <recipient> -args $((3*M)) -args $((12*M)) -args $M -args $((3*M)) \
  -send 12000000ugnot -gas-fee 1000000ugnot -gas-wanted 80000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your key>

# The recipient adds a backup with a 180-day inactivity window.
gnokey maketx call -pkgpath gno.land/r/<ns>/driplock -func SetBackup \
  -args 1 -args <backup address> -args 15552000 ... <recipient key>
```

## Deploy to Onyx (testnet)

1. Get testnet GNOT for your address at https://faucet.gno.land (Onyx faucet).
2. Build a copy under your address namespace. This changes nothing on chain:
   ```bash
   scripts/prepare-deploy.sh <your g1 address>
   ```
3. Run the three printed `gnokey maketx addpkg` commands in order. After each one, wait until its page opens on `https://onyx.testnets.gno.land/...`: the gpao oracle enables new packages after it type-checks them.

Onyx storage costs 100 ugnot per byte (`vm:p:storage_price`). The source-only build is about 53 KB of Gno source, and each command caps its deposit with `-max-deposit`.

## Security design

The realm follows the gno.land contract review checklist (`docs/resources/gno-ai-contract-review.md` in gnolang/gno):

- **Caller identity** always comes from `cur.Previous().Address()`, never from an argument.
- **Coin payments** use the required pair: `IsUserCall()` plus `OriginSend()`. Wrapper realms and `maketx run` scripts are rejected, and tests cover both.
- **GRC20 pulls** take an exact amount through the canonical `grc20reg` token and a `RealmTeller` bound to this realm.
- **Checks, effects, then transfers.** Batches validate every entry before writing any stream.
- **Escrow ledger** per asset: no payout can exceed deposits. Proof of Lock shows whether it reconciles.
- **Recovery cannot be griefed:** only the recipient's own actions reset the inactivity timer. A transfer clears the old owner's backup.
- **No exported mutable state:** read APIs return value copies, and every tree stays unexported.
- **Render** validates every path segment, never echoes raw input, escapes user values, caps every loop, and makes CSV cells inert in spreadsheets.

The only `chain/runtime/unsafe` import is for `OriginSend()`, paired with `IsUserCall()`, as in the official `r/demo/defi/atomicswap` example.

**Known limits:**
- A GRC20 token's own admin realm controls its ledger, so only stream tokens you trust.
- Each stream keeps its newest 64 history events.
- Proof of Lock pages count at most 500 live streams per asset and say so when they hit the cap.

## Scalability

- Every list is paginated, and every loop has a fixed cap.
- Streams, address indexes and the live per-asset index are AVL trees, so lookups are O(log n).
- Settled streams leave the live index, so Proof of Lock only scans streams that still hold funds.

Gas measured with `gno test` on gno v1.8.0, with 200 live streams of one asset:

| Operation | Gas |
|---|---|
| Create a stream | about 3.0M |
| Home page | about 6.9M |
| Address page (200 streams, first page of 50) | about 19.3M |
| Statement page | about 14.5M |
| Proof of Lock page with the 12-month calendar | about 117M |

The default per-query budget of a gno.land node is 3,000,000,000 gas (`DefaultQueryMaxGas` in `gno.land/pkg/sdk/vm/keeper.go`). So even a Proof of Lock page at the 500-stream cap (about 300M, estimated) uses about a tenth of the budget.

## Tests

```bash
gno test ./... -v
```

- **57 tests in total:** 11 in `p/schedule` and 46 in `r/driplock`.
- **`p/schedule`** checks stepped and continuous math exhaustively against a brute-force reference, plus extreme totals.
- **`r/driplock`** covers:
  - creating, withdrawing and canceling streams, and the cancel window;
  - step unlocks and batches;
  - attempts to bypass the payment guard;
  - recovery, including attempts to block it;
  - Proof of Lock reconciliation and the unlock calendar;
  - statements and pagination;
  - hostile Render paths.
- **Mutation checks:** bugs were injected into the refund, access control, cancel window, step rounding, settlement, cancelable totals, recovery timer and statement indexing. Each one made the suite fail.

## License

MIT
