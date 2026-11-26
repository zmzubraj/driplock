# Driplock feature plan (2026-11-26)

**Goal:** features that are production-grade and scalable, solve real pain points that vesting tools on other chains leave open, and use what only gno.land offers. Deadline: 18 Dec 2026, 07:00 Dhaka.

## 0. The pitch: four USPs (pain, solution, proof)

The 2026-11-26 review regrouped the features around the pains with the strongest evidence. Step unlocks, batch creation and pagination are kept, but as supporting features, not USPs: other tools already have them.

| USP | The pain (who feels it) | How strong is the evidence | Driplock's answer | Why other chains cannot copy it easily | How we prove it in the demo |
|---|---|---|---|---|---|
| **1. Proof of Lock** | Holders and investors cannot verify a team's claim that "team tokens are locked". Unlock dates live in off-chain trackers that tell you to double-check them. | Strong: Tokenomist's own advice; the GRVT unlock backlash. | A public, chain-served page per token: who holds locked tokens, what can still be canceled, and an unlock calendar for the next 90 days, computed from the live escrow. Projects link it in their docs. | On EVM and Solana this needs an indexer and a website that people have to trust. On gno.land the chain itself renders it, from state anyone can read. | Open the token's calendar page during the demo and match it against the streams. |
| **2. Binding cancel terms** | Employees, contributors and investors can have vesting revoked by an admin without warning. | Strong: an audited vesting manager lets admins revoke any schedule. | Cancel rights are fixed at creation (`cancelUntil`, for example "only before the cliff"), shown on the stream page, and enforced on chain. Vested value can never be taken back. | Most tools make revocation a role or an upgrade; here it is a visible, per-stream term with no admin. | Try to cancel after the window: the chain refuses. |
| **3. Recovery-ready vesting** | A recipient who loses a key loses every future unlock, forever. | Strong pain in general (about 20% of BTC estimated lost); no vesting tool found that addresses it. | The recipient names a backup address and an inactivity window. If they go silent past it, the backup can take over the stream. Any withdraw or `Ping` resets the timer. | Not found in Sablier, Streamflow, Hedgey or Superfluid. | Fast-forward on a local chain: the backup claims after the window, and an attacker cannot. |
| **4. Exploit-resistant accounting** | Shared-pool vesting contracts are drained through share-math bugs. | Strong: UNCX, about $86k, then about $1.5M across four chains. | Every stream holds exact units, with no shares. A per-asset escrow ledger refuses any payout above what was deposited. Invariants are tested, and the tests are themselves checked by injected bugs. | A design choice, made visible: invariants and test results are published in the README. | Show the invariant tests and the mutation check. |

**Supporting features:**
- Step unlocks (monthly or quarterly).
- Batch team vesting.
- `WithdrawFor` relays.
- `TransferRecipient`.
- Statements with CSV for accounting.
- Pagination and read APIs for other realms.

## 1. What the research found

### Competitors

| Product | Chain | What it does well | Gap Driplock can use |
|---|---|---|---|
| Sablier (Lockup, Flow) | EVM | Linear and cliff streams, NFT positions that can be transferred, airdrops | Its rival Streamflow says Sablier is in maintenance mode, with no new streams on its Solana app (not independently confirmed). Needs an off-chain app and indexer to be usable. |
| Streamflow | Solana | Linear, cliff, graded (step), milestone and price-based vesting | Contracts are immutable, with no clawback, so cancel terms must be designed upfront. Needs its own web app. |
| Hedgey | EVM | Linear, periodic and cliff vesting, plus a lockup after vesting. Free core, paid tiers from $150 a month. | Reported acquired by Anchorage Digital in December 2025. EVM only. |
| Superfluid | EVM | Open-ended payroll streams | Senders lock a deposit buffer and can lose it. Off-chain liquidators close streams near insolvency. Accounting must track the exact liquidation time. |
| Tokenomist and similar trackers | Off-chain | Unlock calendars for 500+ tokens | Their own glossary tells investors to verify big unlocks against the original documents. The calendar is an off-chain copy that people have to trust. |

### Real pain points (with evidence)

| # | Pain | Evidence |
|---|---|---|
| P1 | **Shared-pool accounting bugs drain vesting contracts.** | UNCX vesting: about $86k taken through a cancel-path double count, and a later share-accounting flaw reported at about $1.5M across four chains. |
| P2 | **Admins can revoke or claw back without warning.** Recipients cannot see the cancel terms. | An audit of a Starknet vesting manager notes admins can revoke any schedule and withdraw the undistributed funds. |
| P3 | **Lost keys lock vested tokens forever.** | Chainalysis estimates about 20% of all Bitcoin is lost. Inheritance tools exist for wallets but not for vesting positions. |
| P4 | **Unlock calendars are off-chain and trust-based.** Surprise unlocks hit holders. | Tokenomist's own advice to verify against original documents. GRVT users were upset by a 12-month unlock they did not expect. |
| P5 | **Accounting and tax are left to the user.** | A payroll accounting guide notes Sablier and Superfluid move money but do no tax or withholding work, and that forced closures change the accrual date. |
| P6 | **"Unlocked" and "claimed" are different dates.** Gas and effort pile up for many small claims. | An essay on vesting as an unfinished payment rail stresses the unlock-date and claim-date gap. |
| P7 | **Step (monthly or quarterly) unlocks are the norm for teams.** Linear-only tools force workarounds. | Streamflow (graded) and Hedgey (periodic) both offer them. |

### What gno.land gives us that other chains do not

- **The chain renders the UI.** `Render()` pages are served by gnoweb straight from chain state, so every stream, calendar and statement is a public, verifiable web page with no separate app, indexer or server. On EVM and Solana each of these needs an off-chain service.
- **Importable packages.** `p/schedule` can be imported by any realm (DAOs, launchpads, payroll), which also meets the hackathon's adoption criterion.
- **Exact integer math, no floats, readable source.** Anyone can read the realm's code on gnoweb next to its state.

## 2. Already built today (22 realm tests + 7 package tests pass)

| Feature | Pain it addresses |
|---|---|
| Per-stream exact accounting, plus a per-asset escrow check that refuses any payout above deposits | P1: no shared share-math to exploit |
| `CreateCoinStreamFor` / `CreateGRC20StreamFor` (cliff and duration in seconds) | Usability: no Unix time math |
| `CreateCoinStreamBatch` (up to 50 recipients from one `-send`, all or nothing, validated before any write) | Team vesting in one transaction |
| `WithdrawFor` (anyone can trigger, money always goes to the recipient) | P6: bots or friends can claim for you |
| `TransferRecipient` (only the recipient can move the stream to a new address) | Key rotation; partial answer to P3 |
| "Value locked" table on the home page | Transparency |

## 3. Proposed new features, ranked

Score = impact on users and judges x how hard other chains find it, adjusted for build risk before the deadline.

| Rank | Feature | Pain | Why it is unique on gno.land | Effort |
|---|---|---|---|---|
| **1** | **Onchain unlock calendar per token** (`:calendar/<asset>`): unlocks per day and week for the next 90 days, summed across every stream of that token, plus "next unlock" and "total still locked". | P4 | On other chains this needs Tokenomist-style off-chain trackers. Here the chain computes and serves it, so it is the source of truth, not a copy. | Medium |
| **2** | **Step unlocks** (a `period` in the schedule: monthly, quarterly or any interval, with a cliff). | P7 | Table stakes; done as pure, tested math in the reusable package. | Small |
| **3** | **Backup beneficiary for lost keys:** the recipient names a backup address and an inactivity window (for example 180 days). Any withdraw or `Ping` resets the timer. After the window, the backup can take over the stream. | P3 | No major vesting tool found offers recovery for a vesting position itself. | Medium |
| **4** | **Cancel terms shown upfront and enforced:** `cancelableUntil` (for example "only before the cliff", the usual good-leaver term). The stream page shows "the sender can cancel until <date>" or "cannot be canceled". After that date, cancel is impossible. | P2 | Recipients see binding terms on a chain-rendered page before they accept. | Small |
| **5** | **Statements for accounting** (`:statement/<address>`): every create, withdraw, cancel and transfer with date and amount, plus a CSV block to copy into a spreadsheet. | P5 | Served by the chain itself; no indexer. | Medium (needs a small per-stream event log, capped) |
| **6** | **Scalability hardening:** `?page=` on every list, a per-asset stream index, paginated read APIs (`ListByRecipient(addr, offset, limit)`), hard caps on every loop. Gas measured and published in the README. | Production readiness | | Small |

**Deferred, and why:**

| Idea | Why not now |
|---|---|
| Milestone or approval-based release (grants) | Needs an approver and dispute design. Better as v2 after feedback. |
| Selling locked positions (a secondary market) | Large scope and real regulatory risk. `TransferRecipient` already lets a recipient move a position. |
| Voting with locked tokens | Depends on each token's governance; no common standard on gno.land yet. |
| Price-based unlocks | Needs an oracle; no trusted price feed checked on Onyx. |

## 4. Order of work and checkpoints

1. **Step unlocks** in `p/schedule`, with an exhaustive math test against a brute-force reference.
2. **Cancel window**: one field, enforcement, a page line, tests.
3. **Unlock calendar**: per-asset index, a bounded bucket computation, the page, a gas check on gnodev with 200 streams.
4. **Backup beneficiary**: `SetBackup`, `Ping`, `ClaimAsBackup`, timer reset on withdraw, tests for early or late claims and for an attacker claiming.
5. **Statements**: a capped per-stream log, the page and CSV, tests.
6. **Scalability pass**: pagination everywhere, read APIs, a gas table.
7. **Gate after each step:** `gno lint` clean, all tests pass, mutation check on the new rules, and a gnodev page check. Then README and SPEC are updated.

Steps 1 and 2 are small and finish first. Steps 3 to 5 are each about a day. Everything fits well before 18 Dec, which leaves time for the deploy, the demo video and the docs (20% of the score).

## Sources

- Streamflow vs Sablier 2026: https://streamflow.finance/blog/streamflow-vs-sablier-2026
- Streamflow vs Hedgey: https://streamflow.finance/blog/streamflow-vs-hedgey
- Best token distribution platforms in 2026: https://streamflow.finance/blog/best-token-distribution-platforms-in-2026
- UNCX vesting pool exploit (Blockaid report): https://cryptobriefing.com/uncx-network-vesting-pool-exploited/
- UNCX share-accounting flaw: https://crypto.news/uncx-exploit-exposes-share-accounting-flaw-behind-loss/
- Hedgey audit (ConsenSys Diligence): https://diligence.consensys.io/audits/2023/06/hedgey-token-lockup-and-vesting-plans
- Superfluid liquidations: https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga
- Streaming payroll accounting guide: https://beancount.io/blog/2026/07/15/streaming-payroll-superfluid-sablier-per-second-wage-expense-guide
- Sablier streaming models overview: https://blog.sablier.com/overview-token-streaming-models
- Tokenomist unlock calendar glossary: https://www.tokenomist.ai/learn/glossary-term/unlock-calendar
- GRVT unlock disappointment: https://cryptobriefing.com/grvt-tge-unlock-schedule-disappointment/
- Vesting is crypto's unfinished payment rail: https://hackernoon.com/vesting-is-cryptos-unfinished-payment-rail
- Crypto inheritance and lost coins: https://fortune.com/crypto/2024/04/11/crypto-bitcoin-lost-inheritance-estate-planning-will
