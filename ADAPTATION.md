# Adaptation for the Robinhood Chain launch (ConditionalsV2)

Launch kind `evm_contracts`, chain 4663, two contracts in this order:

1. `src/ConditionalsV2.sol:ConditionalsV2`, constructor `(address owner = $owner, IERC20 imd =
   0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127, IIntake intake = 0xa43e6f75ee006411f79ac1c84120606c2330de82,
   address oracleSigner = 0x5598aa9146215bc13eb26f2c692ad1461fd32982, address feeRecipient =
   0x63bcf2d1483c7628d7d53704ff9c8199dc28d907)`.
2. `src/ConditionalsZap.sol:ConditionalsZap`, constructor `(ConditionalsV2 conditionals = $contract:ConditionalsV2,
   IPoolManager poolManager = 0x8366a39cc670b4001a1121b8f6a443a643e40951, IERC20 imd = 0x5f7b…7127, IERC20 usdg =
   0x5fc5360d0400a0fd4f2af552add042d716f1d168)`.

(The previous version of this file covered the v1 launch 2278, `legacy/`. It is still in git history.)

## Launch rules: no change needed

- Both constructors were already right for the factory: nonpayable, 5 and 4 static `address` arguments, no external
  calls, no requirement that any address has code. The owner is the `owner_` argument (`Ownable(owner_)`), never
  `msg.sender` or `tx.origin`. ConditionalsZap has no owner.
- No token, mint, pause, freeze, blacklist, proxy, initializer, DELEGATECALL, CALLCODE or SELFDESTRUCT. Every
  `transferFrom` is from `msg.sender`. No `abi.encodePacked`, and no Yul. Every library call is internal, so the
  bytecode needs no linking. `bytecode_hash = "none"` was already set.
- Rehearsed: `test/ConditionalsV2Launch.t.sol` deploys both contracts by CREATE2 from a factory stand-in in one call
  on an empty chain (chain id 4663, no code at the IMD, Intake, PoolManager or USDG addresses) with the brief's
  arguments and the zap pointing at the ConditionalsV2 deployed just before it. It checks every constructor value,
  that the owner is `$owner` and not the factory, the callback selectors, that the zap has no owner, that a zero
  address is refused, and scans both runtimes as the launch floor does. The runtimes are 24,269 bytes (ConditionalsV2)
  and 3,646 bytes (ConditionalsZap), both under 24,576, and no DELEGATECALL, CALLCODE or SELFDESTRUCT is reachable.

No launch.json is written here: the manifest step owns it. `foundry.toml`, remappings, `lib/` and lockfiles are
untouched.

## Audit findings

Each finding was reproduced against the code as it arrived, using the audit's proofs and the new tests below. Each
new test fails on the original `src/ConditionalsV2.sol` and passes on this one.

### 7011982a (low): `exit` underflowed `Market.sets`. Reproduced and fixed

The proof fails on the original with panic 0x11 at `m.sets -= sets_`. A complete set bought from the maker one outcome
at a time is backed by the maker, not by `sets`. `exit` now takes the redeemed sets from `sets` while they last.
The rest are redeemed from the maker: every `q[i]` and `makerBalance` move down by the same amount. C(q) moves
down by exactly that amount, so prices do not change and `makerBalance >= C(q)` still holds. `makerBalance` cannot
underflow because the account holds those shares, so `q[i] >= fromMaker` for every i. The proof now passes (Bob
gets exactly 1 IMD).

- `src/ConditionalsV2.sol`: `exit`.
- `test/ConditionalsV2.t.sol`: `test_audit_exitRedeemsSetsBoughtFromTheMaker` (the audit's scenario, with
  unchanged prices and solvency checked) and `testFuzz_audit_exitAnyCompleteSet`. The fuzz test also settles to each
  outcome and checks that the contract pays everything out.

### 913c99ee (low): sells could price a world at zero. Reproduced and fixed

The proof fails on the original with `DivWadFailed`. The problem was wider than the audit described. With world 0 at
zero, every buy and every stake in either world reverted `PriceLimit`, because `_checkSpread` is global, until
someone sold world-1 shares. `_sell` now runs the same `_checkSpread` as buys and stakes. Every trade therefore
keeps `max q - min q <= 20 b`, and every price stays above about 2e-9.

The original comment's reason for skipping the check was that nobody should be stopped from leaving. To keep that
for `exit`, it sells each leftover outcome only up to `_sellRoom`, the amount that keeps the spread, and skips
amounts below `MIN_TRADE`. The shares beyond that are worth under about 2e-9 IMD each. They stay with the account,
and a later `exit` or `sell` can sell them once the market moves. `sell` reverts `PriceLimit` only for a sell that
would break the bound. A smaller sell goes through.

Skipping dust below `MIN_TRADE` also removes the audit's side note (b84bec92) that a dust holding made `exit` revert
`TradeTooSmall`.

The held proof cannot pass against this fix: it needs `sell(id, 0, 24e18, 0)` to succeed. On this tree it stops
there with `PriceLimit`, which is the fix working. Its scenario is covered below.

- `src/ConditionalsV2.sol`: `_sell` (spread check), `exit` (sells what fits), new `_sellRoom`.
- `test/ConditionalsV2.t.sol`: `test_audit_sellCannotPriceAWorldAtZero` (the audit's scenario). The dump reverts and a
  sell inside the spread works. `conditionals`, `quoteStake` and a stake on world 0 all work afterwards.
  `test_audit_exitSellsWhatFitsTheSpread`: `exit` does not revert at the bound, keeps the unsellable shares, and a
  second exit closes the position.
- `test/ConditionalsV2Invariant.t.sol`: `invariant_spreadBounded`, which also calls `conditionals`. On the original
  code the handler breaks it on its own.
- `README.md`: "Spread bound".

### b37b3ab1 (low): a live price above the snapshot stranded the market. Reproduced and fixed

The proof fails on the original with `PriceNotMet`. `_askPrice` now pays the Intake's live price whenever it is
non-zero and at most `MAX_PRICE`, the 10 IMD bound that already applies to configurations. The existing `_ask` path
does the rest: the budget pays while it covers the price, then the caller pays, exactly as a retry already
charges the caller. The unspent budget still returns to the creator at settlement or void. An unreadable,
zero or above-10-IMD live price falls back to the snapshot, as before. The proof now passes.

This reverses v1's choice (d2cd6ea6 in the previous file) for ConditionalsV2. The audit reproduced it as a defect:
with the old behaviour, a protocol price change voids every open market. Under the new one, the caller of
`requestResolution` can be charged up to `MAX_PRICE` per ask. The question format, the body, the callback checks and
the oracle flow are unchanged.

- `src/ConditionalsV2.sol`: `_askPrice` and its comment.
- `test/ConditionalsV2.t.sol`: `test_audit_askPaysALivePriceAboveTheSnapshot` (0.6 IMD: both asks are answered and
  settle; since the revision below the budget pays 1 IMD and the caller the 0.2 IMD shortfall). Also
  `test_audit_askNeverPaysAboveMaxPrice` (10 IMD + 1 is refused, 10 IMD is paid). The existing
  `test_oracle_budgetSpentThenReturned` (a lower price) is unchanged and passes.
- `README.md`: "Price changes".

### 34e17b7a (low): each market pins its signer. Confirmed, not changed

Confirmed by reading the code (no audit proof was supplied): `onOracleResult` verifies only against `m.oracle.signer`,
and that is snapshotted at creation. A market created under signer S1 therefore refuses an answer signed by S2
after a rotation, and it ends in a void.
This is what the brief requires: the answer needs "an EIP-712 signature … from the market's oracle signer". The owner
"cannot touch trades, answers or open markets". If a rotated signer applied to open markets, the owner could settle
them with a key of its choice after 3 days. Rotation without stranding markets is still possible:
`SignatureChecker` accepts an ERC-1271 signer, so a market created with the protocol's signer registry as its signer
follows the registry's rotations.

### b84bec92 (info): coverage. Nothing to fix

The only note in it that changed behaviour (dust below `MIN_TRADE` blocking `exit`) is handled under 913c99ee. The
other note, that `a.requestId` is not consumed, was not changed. Retries are at least `RETRY_DELAY` apart, so two
asks never share a question hash and no replay is possible.

## Review findings (revision)

An independent review reopened the accepted work with one high finding and four advisory ones. Each was reproduced
first; the answers are in `.imd-responses.json`.

### d1218754 (high): a void refunded losses realised against the maker. Reproduced and fixed

The proof failed on the accepted tree: two accounts cycling the maker (B buys, A buys more, B sells at the top, A
sells at the bottom) left the pair with no shares, A with a positive `netIn` equal to the loss B had already taken
out, and a void paid that claim out of the creator's seed and then out of the honest staker's refund (pair +14.879
IMD after fees, honest refunded 39.504 of 49.888, `toCreator` 0).

`netIn` was cash in minus cash out. Its positive part was treated as a refund claim, but a loss realised against
the maker is IMD another trader took out of the market, so nothing backs it. The fix keeps a **cost basis per
account and outcome** (`_basis`): a buy adds its cost; a stake adds its collateral, with the opposite side carrying
what it fetched (so it nets to zero) and the rest spread over the three outcomes kept by their prices before the
trade; a sell or an exit releases the sold shares' share of their outcome's basis, whatever they fetched
(`_release`). `netIn(marketId, account)` is now the sum of that basis, the cost of the shares still held, so the
public view keeps its signature and `refundBase` stays its sum over accounts. A void refunds it pro rata exactly as
before. A realised loss is no longer a claim, and a realised gain no longer reduces the claim on shares still held.
The split by price matters: an equal split would let a staker sell the two legs the market prices high at their
market value and keep an inflated basis on the cheap one.

`claim` now returns 0, and changes nothing, for an account with nothing to claim; it used to revert
`NothingToClaim`. The proof calls `claim` for the account whose claim the fix removes, so the revert had to go. The
error still guards `withdrawOwed`. Three existing tests that expected the revert now assert the zero return.

What this does not change: an account that still holds shares bought at a price another trader pumped has a claim
at that cost and shares a short pool pro rata with everyone else, as before. That is the at-cost design the brief
asks for ("accounts get their net IMD in back"), it is bounded by the spread bound (20 b per outcome), and the
creator's loss stays bounded by the seed. The review's attack, which grew without bound with every cycle and
needed no position, is closed.

- `src/ConditionalsV2.sol`: `_basis`, `_release`, `_basisOf`, `netIn` (view), `buy`, `exit`, `_stake`,
  `_stakeMath` (returns `gross` and `spend`), `_sell`, `_payout`, `claim`, docs.
- `test/ConditionalsV2.t.sol`: `test_review_voidDoesNotRefundRealisedLosses` (the review's scenario: A refunded 0,
  the honest staker exactly its collateral, the creator the seed, the pair below its start),
  `test_review_voidRefundsTheCostOfSharesStillHeld`, `test_review_stakeCostFollowsPrices`,
  `test_review_exitReleasesTheSetsCost`, `testFuzz_review_partialSellKeepsAShareOfTheCost`;
  `test_void_refundsCostLessFees`, `test_void_paysTheCreatorLastAndProRataWhenShort` and
  `test_stake_losingSideLosesTheStake` updated for the zero return. `invariant_refundBaseMatchesPositiveNets` holds
  unchanged.
- `README.md`: "Void" and "Void refunds".

### fc599613 (low): the budget paid all or nothing. Reproduced and fixed

`_ask` charged the budget only when it covered the whole price, else the caller paid everything. It now draws the
budget down to zero and pulls only the shortfall from the caller. The kept rule, now also in `requestResolution`'s
NatSpec, is the one `_askPrice` documented: the budget pays while it lasts, retries included, then the caller.
`test_review_askDrawsTheBudgetDownThenChargesTheCaller` (10 IMD: caller pays 9 then 10, budget 0),
`test_review_retryIsPaidFromTheBudgetWhileItLasts`, and `test_audit_askPaysALivePriceAboveTheSnapshot` updated
(0.6 IMD: budget pays 1, caller 0.2, nothing idles).

### 06e7064f (low): small stakes reverted on a saturated market. Reproduced and fixed

`_quoteBuyExactIn` lowered `k` by fixed relative cuts that could not absorb the two rounding margins when the
spend was small, so stakes of 1e15 to 1e17 wei reverted `TradeTooSmall` with b = 100 after a 1900 IMD buy. Each cut
is now at least `2 * margin * sum / e + 1` shares, the amount whose cost at the entry price covers the margins.
`test_review_smallStakeOnASaturatedMarket`.

### 0196ef8b (info): createMarket binds only the price. Reproduced, not changed

An expected-configuration argument would change `createMarket`'s ABI, which the frontend calls, for a race the
design already mitigates: a rotation is proposed (evented), waits 3 days, and `pendingOracleConfig` and
`pendingOracleConfigAt` are public, so a creator can see a pending change before sending. Documented as a limit.

### 87a6c426 (info): claimable was 0 for a settleable open market. Reproduced and fixed

`claimable` returns the shares of the outcome the stored answers select when the market is settleable (`_winner`,
shared with `_settle`). `test_review_claimableCountsASettleableMarket`, `test_review_claimableIsZeroWhileAnAnswerIsMissing`.

### Size savings, behaviour unchanged

The cost basis added about 800 bytes. To stay under the limit, without changing behaviour: one `_quote` for buys and
sells; `_range` shared by `_normalised`, `_absorb` and `_checkSpread`; `_takeAsk` shared by both callbacks;
`_known` for the view checks; `_validateText` reports the space `rules` must have; `_push` uses `try`; the
attestation struct is hashed with one `abi.encode`; the question's `chainId` is the literal `1` (the hash vectors,
including the live-API one, are unchanged); `_ask` reads the configuration from storage. Runtime: 24,490 bytes.

## Review findings (second revision)

A second independent review reopened the work with two findings, both reproduced with the reviewer's proofs on the
accepted tree and fixed. Answers are in `.imd-responses.json`.

### e665f90a (critical): `buy` wrapped shares above `type(int256).max`. Reproduced and fixed

`Proof_e665f90a9e1f` failed on the accepted tree: `buy(id, i, 2**256 - 1e15, max)` was priced as a sale of 0.001
shares and credited ~1.16e77 shares, and the thief left with 1,190.6 IMD of honest stakes. `buy` now reverts
`TradeTooLarge` when `shares > uint256(type(int256).max)`, before the cast. The other casts are not exposed: `sell`
and `exit` release the shares from the account first (an underflow for anyone holding fewer), and a stake's
`amount` must be transferred in. The proof passes.

- `src/ConditionalsV2.sol`: `buy`.
- `test/ConditionalsV2.t.sol`: `test_review_buyAboveInt256MaxReverts` (both the proof's value and
  `type(int256).max + 1`, on every outcome).

### bf61cff9 (high): a short void diluted fully backed refunds. Reproduced and fixed

`Proof_bf61cff9dc2b` failed on the accepted tree: refundBase 299.02 IMD against a pool of 213.99, the honest staker
paid 71.405 of 99.776 IMD. Cost basis on several outcomes can exceed what the market holds, since only one outcome
pays. The brief's rule is kept where the market can pay: a void that is not short refunds every account's cost
(`netIn`) exactly as before. Only the short case changed: "pro rata if short" is now pro rata over the cost that
the position's value at the final prices does not back, instead of over all cost.

With V the value of every position at the final prices (`sum p_i (q_i + sets)`, rounded up), v an account's
value (rounded down), c its cost, pool the market's balance and S = refundBase - pool, an account is paid
`(v * S + c * (pool - V)) / (refundBase - V)`. That is between v and c, the payouts sum to at most the pool, and
the pool always covers V because `makerBalance >= C(q) >= sum p_i q_i`. A stake's complete sets are worth their
cost at any prices, so the honest staker is refunded in full. The holder whose cost was pumped on two outcomes takes
the shortfall. If rounding ever made V reach the pool, each account is paid `v * pool / V`. The creator is still
paid last (`balance - pool`, which is zero when short), and `refundPool`, `refundBase`, `netIn` and the `Voided`
event are unchanged. The proof passes: the honest staker is paid 100.04 IMD and the pair ends +15.1 IMD, below the
27.7 IMD seed.

The reviewer offered refunding maker positions at final prices as one option. That would also change a void that
is not short, where the brief says accounts get their net IMD back. This rule changes only the short case.

- `src/ConditionalsV2.sol`: `_payout`.
- `test/ConditionalsV2.t.sol`: `test_review_voidShortfallFallsOnUnbackedCost` (the proof's scenario: the honest
  staker gets at least its cost, the holder less than its cost, the payouts fit in the pool, the pair takes at most
  the seed), and `testFuzz_review_voidPaysEveryClaimWithinThePool` (random buys and sells by three accounts beside a
  stake: every claim succeeds, they total at most the pool, and each is exactly `netIn` when not short).
  `test_void_paysTheCreatorLastAndProRataWhenShort` passes unchanged: with one holder the rule pays the whole pool.
- `README.md`: "Void refunds".

### Size savings, behaviour unchanged

The two fixes added about 360 bytes. To make room, the question document and the request body are now built in one
`_documents` from shared parts (the same JSON strings, so the hash vectors, including the live-API one, are
unchanged), and `_ask` builds them once instead of twice. Runtime: 24,541 bytes.

## Review findings (third revision)

A third independent review reopened the work with one finding, reproduced with the reviewer's proof on the accepted
tree and fixed. The answer is in `.imd-responses.json`.

### 0b859a73 (medium): a short void could refund more than the cost. Reproduced and fixed

`Proof_0b859a733266` failed on the accepted tree: Carol (net in 165.72 IMD) was refunded 184.30 and Dave (a staker,
net in 99.78) 103.61, both out of Alice's refund. The short-void rule from bf61cff9 paid each account between its
value at the final prices (v) and its cost (c). When v > c (an outcome bought cheap whose price was later pumped,
or a staker whose complete sets gained from a pump), "between" is above the cost, which breaks the brief's rule
that a void returns "net IMD in back excluding fees, pro rata if short", and lets a trader who expects a void pump
an outcome it holds for a profit paid by other accounts.

`_payout` now clips v at the cost before the interpolation (`v = FPM.min(v, net)`). With u = min(v, c) an account is
paid `(u * S + c * (pool - V)) / (refundBase - V)`, which is at most `c * (refundBase - V) / (refundBase - V) = c`,
and the sum over accounts is at most `(V * S + refundBase * (pool - V)) / (refundBase - V) = pool`, since the sum of
u is at most V. The rounding branch (`total >= pool`) pays `u * pool / total`, at most c as well. So every refund is
at most the cost, the refunds still fit in the pool, a position worth its cost (a stake's complete sets) is still
refunded in full, and the shortfall still falls on cost the position's value does not back. A void that is not
short is unchanged: every account gets its cost.

What the cap costs: in a short void where some position is worth more than its cost, the refunds no longer add up
to the whole pool, and the difference stays in the contract (in the proof's scenario 22.42 IMD of a 324.54 IMD pool,
against Alice's 73.02 IMD of cost, of which she is refunded 36.62).
Redistributing it would need the sum of the clipped values over every account, which the contract cannot compute
without a list of accounts, and the runtime has 21 bytes left. The creator is still paid last (`balance - pool`,
zero when short), so this is IMD no account had a claim to under the brief's rule rather than a loss to anyone.

Launch 2765 then parked on that leftover (`5a89dee7`, medium); the fix is the next section.

- `src/ConditionalsV2.sol`: `_payout` (one line and its comment).
- `test/ConditionalsV2.t.sol`: `test_review_shortVoidNeverPaysAboveCost` (the proof's scenario: every refund at
  most the cost, Carol and Dave exactly at cost, Alice below it, the total within the pool), and
  `testFuzz_review_voidPaysEveryClaimWithinThePool` now also asserts every claim is at most `netIn` when short.
  `test_review_voidShortfallFallsOnUnbackedCost` (bf61cff9) and `test_void_paysTheCreatorLastAndProRataWhenShort`
  pass unchanged.
- `README.md`: "Void refunds".

## Launch 2765: the parked finding, fixed before the relaunch

Launch 2765 (job `81264d12`) accepted the three revisions above and then parked with one medium finding open. The
requester fixed it on the project's `v2` branch (commit `be62e2a`) before ordering this relaunch; the fix arrived with
this tree and is recorded here because it is the only behaviour change since the audited revisions.

### 5a89dee7 (medium): a short void's capped refunds stranded part of the pool. Reproduced and fixed

After 0b859a73 every short-void refund is capped at the account's cost, so the refunds can add up to less than the
pool, and the difference stayed in the contract with no function able to move it. Reproduced by the suite's
`_shortVoid` scenario (`test_sweep_paysTheCreatorWhatTheCappedRefundsLeave` asserts the leftover is over 1 IMD).

`sweepVoid(marketId)` pays that leftover to the creator, who is paid last in every void, from `SWEEP_DELAY`
(365 days) after the void. It needs a voided market whose `refundPool` is below `refundBase` (short) and above
`refundPaid` (something left), sets `refundPool` to zero and pushes `refundPool - refundPaid` with `_push`, so a
creator IMD blocks is credited in `owed`. Refunds still unclaimed at the sweep lapse: `_payout` then pays
`v * 0 / total = 0`, and `claim` returns 0 without marking the account. Late claims work until somebody sweeps. A void
that was not short has `refundPool == refundBase`, nothing left over, and `sweepVoid` refuses it, so its refunds
never lapse. To support it, `voidMarket` now records the void's time in `voidAfter` (nothing reads it as a deadline
once the market is voided) and `claim` counts a void's payouts in the new `Market.refundPaid`.

- `src/ConditionalsV2.sol`: `sweepVoid`, `SWEEP_DELAY`, `Market.refundPaid`, `VoidSwept`, `voidMarket` (records the
  time), `claim` (counts `refundPaid`).
- `test/ConditionalsV2.t.sol`: `test_sweep_paysTheCreatorWhatTheCappedRefundsLeave` (too early reverts, the creator is
  paid exactly the leftover, the contract then holds only `owed`, a second sweep reverts),
  `test_sweep_unclaimedRefundsLapse` (a late claim before the sweep is paid in full, a claim after it gets 0),
  `test_sweep_onlyAfterAShortVoid` (an open market and a void that was not short refuse it, and that void's refund
  never lapses), `test_sweep_blockedCreatorIsOwed`.
- `test/ConditionalsV2Lifecycle.t.sol` (this task): the handler can now `sweep` and `jumpPastSweep`, with ghosts for
  the pool a void set aside, what a sweep took and whether it happened. `invariant_sweepIsExact`: a sweep that
  succeeds is the first for its market, on a short void at least a year old, pays the creator exactly
  `refundPool - refundPaid` and zeroes the pool; one the rules allow is never refused; nothing is refunded after it.
  `invariant_refundBooksAgree` now also checks that the refunds paid before a sweep and the sweep add up to at most
  the pool the void set aside. `test_handlerSweepsAShortVoid` drives the handler through a short void, a too-early
  sweep, the sweep, a lapsed claim and a refused second sweep, so the invariant is exercised on a swept market.

### Size trims that made room, behaviour unchanged

`sweepVoid` needed about 300 bytes against a limit the previous revision had 21 bytes under. The requester removed
the `conditionals(marketId)` view (the site derives both conditional probabilities from `getMarket`'s `q` and `b`,
and `prices(marketId)` still returns the four prices), the `totalCreatorFees` counter (creator fees are in `owed`),
and the public getters of `pendingOracleConfig` (the `OracleConfigProposed` event carries the proposal, and
`pendingOracleConfigAt` stays public) and of seven constants (`BURN_ADDRESS`, `FEE_BPS`, `MIN_TRADE`, `MIN_B`,
`MAX_B`, `RESOLUTION_PERIOD`, `RETRY_DELAY`; their values are in this file and the README). No trade, fee, oracle
or payout path changed. `test/ConditionalsV2Invariant.t.sol`'s `invariant_spreadBounded` calls `prices` instead of
`conditionals`. The frontend ABI was regenerated.

## This relaunch: the audit of the code as it arrived

The audit step of this launch (`6f01e635`, info) read both contracts, the interfaces, the mocks and the tests in
full, traced every state-changing function for caller, value moved and trust, and ran a 512-run fuzz for
`makerBalance >= C(q)` and a short-void scenario with `sweepVoid`. It found no reproducible defect and reported the
deliberate designs (the caller pays an ask's shortfall above the budget, `createMarket` binds only the price, the
spread bound leaves `exit` dust, `sweepVoid` lapses unclaimed refunds of a short void after a year, `a.chainId` is
not checked and `a.requestId` is not consumed) as implemented and documented, not as defects. Nothing to fix. This
task therefore changes no source: it adds the launch rehearsal test described under "Launch rules", the lifecycle
invariant coverage of `sweepVoid` described above, and this record.

## Size

ConditionalsV2's runtime is 24,269 bytes (limit 24,576), with `optimizer_runs = 1` as configured. It was 24,148 as
it arrived at launch 2765, 24,433 after the audit fixes, 24,490 after the first revision, 24,541 after the second,
24,555 after the third, and 24,269 after `sweepVoid` and the trims above. ConditionalsZap is 3,646 bytes.

## Checks run

- `forge build`: clean, sizes as above.
- `FOUNDRY_FUZZ_SEED=0x1603cce38c873662a78756267580099c44a77c9c5fe92d6a89347de0a67f480e forge test`, in an empty
  environment: 130 tests pass, 1 skipped (the fork suite, which needs `ROBINHOOD_RPC_URL`). That is the unit and fuzz
  suites (`ConditionalsV2`, `ConditionalsV2FailurePaths`, `ConditionalsZap`), the two invariant suites, the question
  and live-API hash vectors, the oracle conformance vectors, and the launch rehearsal.
- The fork tests were not run here (no RPC); the requester's last run against Robinhood Chain is recorded in
  `HANDOFF.md`.
- The third review's proof `Proof_0b859a733266.t.sol` passed on the tree that fixed it (Carol and Dave are refunded
  exactly their net in); it is not supplied on this machine.
- The second review's proofs `Proof_e665f90a9e1f.t.sol` and `Proof_bf61cff9dc2b.t.sol` are no longer supplied on
  this machine. Their scenarios are the suite's `test_review_buyAboveInt256MaxReverts` and
  `test_review_voidShortfallFallsOnUnbackedCost`, which pass unchanged.
- The first review's proof `Proof_d1218754d210.t.sol` passes on this tree, as do `Proof_7011982acbf0` and
  `Proof_b37b3ab115a8`. `Proof_913c99ee0269` still stops at `PriceLimit`, which is the fix working (see above).
- `FORK_ROBINHOOD=1 forge test --mc Fork`: all 5 fork tests pass against Robinhood Chain (the real Intake takes
  the asks, and the zap stakes with ETH and USDG and honours `minImd`).
