# Driplock security review

**Date:** 2026-11-28
**Scope:** `r/driplock` (driplock.gno, lock.gno, statement.gno, render.gno), `p/schedule`, `r/dripdemo`, on gno v1.8.0.
**Method:**
- A line-by-line manual review against gno.land's own checklists (`docs/resources/gno-ai-contract-review.md` and `gno-security-guide.md` in gnolang/gno).
- A read of the dependencies Driplock trusts: `p/nt/grc20`, `r/nt/grc20reg`, `chain/banker`, and the VM keeper's `OriginSend` handling.
- A proof-of-concept test for every suspected weakness, written to pass while the weakness existed.
- Each fix, followed by turning each proof of concept into a regression test (`r/driplock/audit_test.gno`).
- Mutation checks: disabling a fix makes its regression test fail.

**Who reviewed it:** this is a self-review by the author's tooling, not an independent audit. Treat it as a first pass.

## Summary

| ID | Severity | Finding | Status |
|---|---|---|---|
| F1 | Medium | Proof of Lock trusted its own ledger, not the real balance | Fixed |
| F2 | Low | Coins sent to a call that takes no payment were trapped | Fixed |
| F3 | Low | Anyone could erase a stream's creation entry from its history | Fixed |
| F4 | Low | Dust streams could hide an address's newest activity from its statement | Fixed |
| F5 | Low | Dust streams can exceed the Proof of Lock scan cap | Mitigated (residual) |
| F6 | Info | A cursor at the largest id wrapped around to the first page | Fixed |
| F7 | Info | Escrow sum had no explicit overflow check | Fixed (defensive) |
| F8 | Info | A GRC20 symbol can imitate another asset's name | Fixed (label) |

No finding lets anyone take funds they are not owed. Withdrawals, cancels, recovery and payouts were already correct; the findings concern the proof pages, the records, and user mistakes.

## Findings

### F1 (Medium): Proof of Lock trusted its own ledger

**Problem:**
- "Reconciled" compared the per-stream sum with Driplock's internal escrow ledger, never with what the realm actually holds.
- A GRC20 token's admin can burn Driplock's balance without touching that ledger.
- The page then kept saying "Reconciled" while the tokens were gone.

**Proof:** a test token was minted, streamed, and then burned from the realm. `GetLockSummary` still returned `Reconciled: true`.

**Fix:**
- New fields: `Held` (the real bank or token balance) and `Backed` (`Held >= Locked`).
- The page shows "Actually held by the contract", and shows a warning when the balance falls short.
- "Reconciled" now requires both the ledger match and a covering balance.
- The balance check is O(1), so it holds even when the stream scan is truncated.
- GRC20 pages are labeled "(GRC20 token)".

### F2 (Low): coins trapped by an unneeded `-send`

**Problem:** these calls accepted coins sent with them:
- `Withdraw`, `WithdrawFor`, `Cancel`, `TransferRecipient`, `SetBackup`, `Ping` and `ClaimAsBackup`;
- the GRC20 create functions.

Nothing recorded those coins and nothing could return them.

**Fix:**
- `refuseSend` rejects any `-send` on a direct user call to these functions. The transaction reverts, so the user keeps the coins.
- Realm callers are not affected: their transaction's coins went to the realm the user called first.

### F3 (Low): history could be erased by strangers

**Problem:**
- `WithdrawFor` is open to anyone, and each call adds a history event.
- History was capped at the newest 64 events, so 66 relayed calls pushed the "created" entry out.
- The sender's statement then lost the record of the lock.

**Fix:**
- The creation entry is pinned: the cap now drops the oldest entry after it.
- Each stream counts the events it trimmed.
- The statement prints that count with the stream's exact totals, read from state.

### F4 (Low): dust could hide new activity from a statement

**Problem:**
- Statements read only the first 100 streams of an address, oldest first.
- 100 unsolicited one-unit streams (two batch calls) hid every newer real stream.

**Fix:**
- Statements read the 100 most recent streams.
- Row collection is capped at 2,000 before sorting, which bounds the page's cost.

### F5 (Low, residual): dust and the Proof of Lock scan cap

**Problem:**
- The itemized Proof of Lock reads at most 500 live streams per asset.
- 10 batch calls of 50 one-unit streams reach that cap.
- After that, the per-stream check is skipped, and newer streams are not itemized.

**Mitigation:**
- The O(1) solvency check from F1 still runs and is shown as "**Backed:**".
- Each dust stream also costs the attacker its storage deposit.

**Not fixed:** a full per-stream proof beyond 500 streams would need incremental aggregates.

### F6 (Info): cursor wrap

**Problem:** `ListStreams(addr, receiving, 2^64-1, n)` computed `after+1`, which wrapped to 0 and returned the first page. An integrator's pagination loop could then repeat forever.

**Fix:** that cursor now returns an empty page.

### F7 (Info): escrow overflow

The sum of locked amounts per asset is bounded by the token's supply. `p/nt/grc20` caps supply at the int64 maximum. `store` now also refuses a deposit that would overflow the ledger.

### F8 (Info): symbol imitation

Any realm can register a token with any symbol, including "GNOT". GRC20 Proof of Lock titles now say "(GRC20 token)", and the full asset key is printed under the title.

## Checked and found sound

| Area | Result |
|---|---|
| Caller identity | Every mutator reads `cur.Previous().Address()`. No address argument is trusted. |
| Coin payment guard | `IsUserCall()` plus `OriginSend()`, the pattern `effective-gno.md` requires. `OriginSend` is set per message by the VM keeper, so a multi-message transaction cannot reuse one deposit. Tests cover wrapper realms. |
| GRC20 pulls | `TransferFrom(sender = caller)`, so nobody can spend another user's allowance. `grc20reg` keys are unique and can never be replaced. |
| Reentrancy | Banker sends and `p/nt/grc20` transfers run no external code. State changes still happen before transfers. |
| Arithmetic | `VestedAt` is exact and overflow-free up to 50 years. Batch sums check for overflow. Every time input is validated. |
| Cancel and withdraw | The refund equals total minus vested at the cancel time. The vested part is frozen and stays claimable. Totals always settle exactly. |
| Recovery | Only the recipient's own actions reset the timer. A claim needs the named backup and the full inactivity period. Transfers clear the backup. |
| Exported state | No pointers to internal state are returned. No realm values are stored. No callbacks are taken. |
| Render | Every path segment is validated. User values are escaped. CSV cells are inert. Every loop is capped. |

## Not covered

- An independent review by another person.
- Fuzzing beyond the brute-force schedule checks.
- On-chain behavior of the deployed Onyx version: this review is of the repository code.

## Deployed versions

- **v1** at `gno.land/r/g1c4p2qq2l7ndqrn7weez9z53x99mtv5rcxhm7s8/driplock` predates these fixes and stays live. Gno packages cannot be changed after deployment.
- **v2** at `gno.land/r/g1c4p2qq2l7ndqrn7weez9z53x99mtv5rcxhm7s8/driplock/v2` carries every fix. It was published on 2026-11-28 at height 1479176 (tx `/PWsvz6b+DPdN9waqx7gB/FEO5WxromfAoBn4G7psxs=`). Its realm address is `g1rv9dkcs7r8x5hpq2jmv8cuq7pmyjeegn5dap27`.
- Both versions reuse the unchanged `p/.../driplock/schedule` package and the DRIP demo token.
- The live v2 Proof of Lock pages show the new "Actually held by the contract" row and the extended "Reconciled" check.
