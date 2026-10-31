# Conditionals: everything done so far

Status as of Saturday 31 October 2026, about 11:30 (WAT). For recovery steps, see "If you go offline or the session dies".

## Latest: launch 2765 parked

- **Launch 2765 parked at about 10:55 AM, and its 0.5 IMD is lost.** IMD's reason: "1 blocking finding(s) never resolved", the last
  medium finding (a short void could leave part of its refund pool stuck forever). Nothing was deployed, so no market funds were at risk.
- **The fix is ready and pushed to branch `v2` (`6d83b91`).** `sweepVoid` pays any leftover to the creator from a year after the void.
  To fit the size limit, some unused getters are no longer public, leaving 307 bytes spare.
- **Tests:** 129 pass at heavier fuzzing. 10 of 11 fork tests pass against the real chain at the latest block. The 11th failed only
  after I changed its pinned block for that run, on an assertion comparing `block.number` with that block.
- **IMD's free check:** clean, no blockers.
- **Not paid yet.** You've decided to relaunch with another 0.5 IMD when you get back. The steps are in `HANDOFF.md`, under
  "LATEST HANDOFF SESSION".
- **Risk:** a new run could find something new and park again. The last run allowed three rounds of fixes before parking.

## Where things stand

| Area | Status |
|---|---|
| Website | **Live** at https://conditionals.xyz, still running v1 |
| V2 contracts | **Not deployed.** Launch 2765 parked; the fix is ready and the relaunch is waiting for you |
| V2 frontend | Built, on branch `v2`, **not live** until the contracts deploy |
| The 4 markets | Agreed, **not created yet** |
| Launch videos | Both films finished, waiting for you to pick one |
| Wallet | 15.5 IMD and about 0.0015 ETH |

## What Conditionals is

Conditional prediction markets on Robinhood Chain, settled by the IMD oracle. A market asks "If X happens, will Y happen?"
and has two worlds: one where X happens and one where it doesn't. You bet on Y inside a world. If your world doesn't
happen, your stake comes back.

It's a separate project from GAMMA and runs under the **UgwujaGeorge** GitHub and Vercel accounts.

## 1. Domain

- You bought **conditionals.xyz** on Vercel: $1.99 for the first year, $13 a year after that. It expires 1 November 2027.
- Vercel refuses domain purchases from agents, and from the `!` prefix, so you had to complete it yourself.
- `conditionals.xyz` and `www.conditionals.xyz` are attached to the Vercel project.
- `www` and the old `conditionals-bay.vercel.app` both redirect to `conditionals.xyz`.

## 2. Frontend changes already live

**Hero**
- Moved the content up so the buttons fit on the first screen. You view the site at about 1253x550 because of Windows
  150% scaling, so that's the size it's tested at.
- Moved the fork visual and the World A and World B labels up, so "it doesn't" fits on the first screen.
- Moved "Settled by IMD oracle" to sit directly under the Conditionals title.
- "If an event happens" is now all orange, and "if it doesn't" stays blue.
- Removed "in IMD" from "Conditional markets in IMD."

**Removed**
- The "IMD Hackathon" footer link.
- The 3% fee card. "Why two worlds" now fills that width.
- The "Built on IMD" section that explained how Conditionals uses IMD.
- Contract address links, from the footer, the market panel and `/docs`.

**Added**
- An "IMD" section with two cards: "Bets are made in IMD" and "Place bets with ETH or USDG", the second tagged
  "Coming with v2". The top menu link now says "IMD".

## 3. V2 contracts

Branch `v2`, commit `4b1f184`. Two contracts, deployed together.

### `ConditionalsV2`: markets, in IMD only
- **Live prices from the first trade**, using an LMSR market maker with four outcomes per market.
- **Conditional stake:** pay X IMD. If your world happens on your side you're paid; if the other world happens you get X back.
- **Early exit:** sell your whole position back to the maker before the market closes.
- **Seed required:** the creator funds the maker with b ln 4. The seed takes no side and is the most the creator can lose.
- **Fee:** 2% on every trade with the maker. Half goes to the market's creator, 67/200 is burned, and the rest (33/200) goes to you as
  builder. Claims are free. This replaces v1's 3% of the winning pot.
- **Oracle flow:** carried over from v1, the part IMD already audited. Two questions, panel of 5, 4 must agree.
- **If the oracle never answers:** after 30 days anyone can void the market. Traders get their money back at cost,
  excluding fees, pro rata if short, and the creator is paid last.
- **Owner powers:** can only rotate the oracle settings for future markets (3 day delay) and change the fee recipient.
  It can't touch trades, answers or open markets.
- **Left out on purpose:** the liquidity vault from the design PDF, `mint` and `redeemSets` (to fit the 24.5KB size limit;
  `exit` covers redeeming), and the late fee ramp.

### `ConditionalsZap`: bet with ETH or USDG
- Swaps the coin into IMD and places the bet in one transaction. If the price moves past the limit, the whole thing cancels.
- Holds no funds between calls and has no owner, so the swap code stays away from market money.
- **Route:** USDG → ETH (0.05% pool) → IMD (1% pool). Both are real Uniswap v4 pools with no hooks.
- ETH and USDG bets cost about 1% to 1.05% in pool fees, on top of the 2% trading fee.

### Addresses and facts we verified on the chain
| What | Value |
|---|---|
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| USDG (genuine Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| IMD Intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| IMD oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Launch wallet (owner, fee recipient) | `0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907` |
| V1 contract | `0xc8cc656b71dd77ae1e29b0bc7890edd110e73255` |

**Correction:** I first told you the direct IMD/USDG pool had about $25k. It later showed about $43, so it isn't used.
Several tokens on the chain are named USDG, so only the address above is accepted.

### Testing
- **51 tests pass:** unit, fuzz, invariants, the oracle conformance vector and a live-API question-hash vector.
- **5 fork tests pass** against the real chain. The real Intake accepted the oracle questions, and real swaps filled:
  0.0005 ETH bought 0.32 IMD, and 5 USDG bought 1.45 IMD, with nothing left behind in the zap.
- A fresh clone from GitHub builds and passes the 51 tests.
- **Bugs the tests caught, both fixed:** a memory bug that made "before" and "after" prices identical, and an exit
  that could wrongly report the maker as short of funds.

## 4. IMD launch

| | |
|---|---|
| Launch number | 2765 |
| Job | `81264d12-a201-4065-b9ff-c8df33483dfe` |
| Payment tx | `0x0ed9be336c67e29c184f4a1adae5cadb7b331af07bf1ddc04053e09357adf98e` |
| Approval tx | `0x52477587dcde336ded676150cf7588e2a527875363fac9fad57e8cf973fcb078` |
| Delivery repo | https://github.com/identity-md-launches/launch-2765-launch-two-contracts-repository |
| Cost | 0.5 IMD |
| Free check before paying | Clean, no blockers |

**Progress:**
- First audit: done.
- Audits of math, permissions, economics and flow: all done.
- Final audit judge: has sent the work back **three times** for fixes. The third round started at 10:25.
- Still to come: tests, launch manifest, then the judge again.

**What the audit found** (public at `GET https://api.imd.fun/jobs/<job>/submissions`):

| Severity | Bug | Status |
|---|---|---|
| Critical | Oversized `buy()` amounts wrapped around, crediting free shares. About 0.001 IMD could drain a market. This was in my code and my tests missed it | Fixed |
| High | Two cooperating accounts could wash trade, then a void would pay them out of the seed and honest stakers' refunds | Fixed |
| Medium | A short void can refund an account more than it paid in, taken from other accounts. It came from the fix for the high bug | **Open, being fixed in round 3** |

Before creating any markets, I need to review every change the swarm made and rerun the tests myself.
`ConditionalsV2` is also close to the chain's size limit (about 72 bytes spare after the critical fix), which leaves little room for more fixes.

**Risk:** if a medium or high finding is still open at the end, the launch parks and the 0.5 IMD is lost. The 15.5 IMD would
cover one more launch and the 4 markets.

## 5. V2 frontend

On branch `v2`, commit `a9678ee`. Tested end to end in demo mode with no page errors, but **not yet against live contracts**.

- Live odds per world, from the market maker.
- IMD, ETH and USDG selector when placing a bet, with slippage protection.
- "Sell position" button, showing what you'd get now.
- Liquidity seed slider when creating a market.
- Updated text across the home page and `/docs` for the new fee and payout model.
- "Coming with v2" tag removed, ready for when ETH and USDG bets really work.

**V1's market:** the v2 site won't list it. The v1 contract holds exactly 1 IMD, the oracle deposit, so no trader has
money in it.

## 6. The 4 markets

You picked these. We dropped the Binance one because the breach was only based on reports.

| # | If… | Will… | Target |
|---|---|---|---|
| 1 | The Fed raises rates at its Dec 9 decision | BTC close above it on Dec 31? | $80,000 |
| 2 | The US carries out **new** strikes on Iran between market creation and Dec 31 | ICE Brent front-month settle above it on Dec 31? | $115 |
| 3 | The Senate holds another Clarity Act vote by Dec 31 | ETH close above it on Dec 31? | $2,500 |
| 4 | BTC closes above $85,000 on Dec 31 | IMD close above it on Dec 31? | $5 |

- All targets get rechecked on creation day so each market stays a real contest.
- Brent's January contract settled at $113.43 on Oct 30, and the expiring December contract at $117.64.
- Market 2 says "new" because reports already describe an Iran war, so the old wording could have been true before anyone bet.
- We skipped the US midterms because voting on Nov 3 comes before v2 can be live.

## 7. Money

| Item | Cost | Status |
|---|---|---|
| Domain | $1.99 | Paid; $13 a year to renew |
| V2 IMD launch | 0.5 IMD | Paid |
| Oracle for 4 markets | 4 IMD (1 each) | Not spent yet; unspent amounts come back |
| Seeds for 4 markets | About 8 IMD (2 each) | Not spent yet; the most you can lose on them |
| Gas | About 0.000005 ETH so far | Market gas is cheap at current prices |

The wallet has 15.5 IMD and about 0.0015 ETH. After the 4 markets, about 3.5 IMD is left, before seeds, deposits or fees
come back.

## 8. Videos

Saved in `C:\Users\Administrator\Videos\Conditionals\`, with sources in `~/projects/conditionals-video`.

| File | What it is |
|---|---|
| `conditionals-sketch.mp4` | First rough sketch. You rejected its song and it won't be used again |
| `conditionals-film.mp4` | "One line becomes two worlds": 60 seconds, calm, elegant, with an original soundtrack |
| `conditionals-film-2.mp4` | "Reality Splits": 55 seconds at 60fps, loud, fast and in 3D, with an original dance track |

- **Song:** "Do I Clench My Fists" is dropped, and I deleted the copy I extracted. Only the old sketch file still has it.
- **Your second download:** its audio is only 32 seconds, too short for the 60-second film.
- **Don't post either film yet:** they promise ETH and USDG bets, which don't work until v2 is live, and show sample markets.
  The final versions should use your 4 real markets.

## 9. What's next

1. Relaunch through IMD (0.5 IMD), then wait for the swarm to finish.
2. Review its changes, merge them, update the ABI, and point the site at the new addresses.
3. Test a small real ETH bet and a small real USDG bet. This needs a little USDG, bought with the wallet's ETH.
4. Create the 4 markets with b = 1.44 (about 2 IMD seed each), with exact wording and named price sources.
5. Push the site live and check it.
6. Recapture the app screens with the real markets, re-render your chosen film, and post it.

## If you go offline or the session dies

**What keeps running**
- **The IMD launch:** it runs on IMD's servers and carries on whatever happens on your machine.
- **Going offline:** the film render and launch watcher both carry on. The watcher ignores failed checks and catches up when you reconnect.
  Claude can't reply or act until you're back, so nothing gets deployed from here, spent or created while you're away.

**What stops them**
- **Sleep:** pauses both until the computer wakes. Keep it plugged in and awake.
- **Closing Claude Code or the terminal, or restarting WSL:** may kill both.

**What's safe either way**
- The wallet and its funds are onchain. The key is in `~/.conditionals/deployer.env` and `wallet.txt`.
- All contract and frontend work is committed on branch `v2`. GitHub has it up to the contracts commit `4b1f184`, so **the v2 frontend (`a9678ee` to `6db159e`) exists only on this machine**. Going offline or restarting won't lose it.
- The finished films are in `C:\Users\Administrator\Videos\Conditionals\`.
- Film sources are in `~/projects/conditionals-video`.
- Film 2's frames are in the session's temporary folder, which may be wiped. If so, the render starts over, taking about 40 minutes for 30fps.

**To pick up in a new session,** tell Claude: "read the latest handoff session in `~/projects/conditionals/HANDOFF.md` and continue." The commands it needs:

Check the launch:
```bash
J=81264d12-a201-4065-b9ff-c8df33483dfe
curl -s https://api.imd.fun/jobs/$J | jq '{state, launch, nodes: [.nodes[] | {key, state, revisions}]}'
curl -s https://api.imd.fun/jobs/$J/submissions | jq '.submissions[] | select(.nodeKey == "audit_judge") | {createdAt, accepted, findings: [.findings[]? | {severity, title}]}'
curl -s https://api.imd.fun/jobs/$J/result | jq '{complete, delivery, launch}'
```

Restart the launch watcher (it stops by itself when the job finishes):
```bash
~/projects/conditionals-video/watch.sh
```

Resume film 2 (finished frames are skipped, and this needs internet to fetch fonts):
```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory ~/projects/conditionals-video &
~/projects/conditionals-video/render2.sh 1   # every second frame, for 30fps
~/projects/conditionals-video/render2.sh 2   # the frames between, for 60fps
```

Encode film 2 (`S` is the temporary folder named inside `render2.sh`):
```bash
cd ~/projects/conditionals-video
OUT=/mnt/c/Users/Administrator/Videos/Conditionals
# 30fps, after pass 1
ffmpeg -framerate 30 -pattern_type glob -i "$S/film2/f*[02468].jpg" -i music2.wav -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 256k -shortest -movflags +faststart $OUT/conditionals-film-2.mp4
# 60fps, after pass 2
ffmpeg -framerate 60 -i "$S/film2/f%05d.jpg" -i music2.wav -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 256k -shortest -movflags +faststart $OUT/conditionals-film-2.mp4
```

**After the launch finishes:** follow "What's next" above. Review every change the swarm made and rerun the tests before creating any market.
**If the launch parks:** the 0.5 IMD is lost. Read the open findings with the second command above, then decide on a new launch. The wallet can pay for one more launch and the 4 markets.

## Things still to confirm

- **Fed odds (Market 1):** the 80%+ odds of a December hike came from one source. The market still works if that's right, but the
  "no hike" world becomes the unlikely one.
- **Close times:** Market 1 has to stop trading before Dec 9. I'll set the others so trading stops before the answer is public,
  because the seed is what informed traders can take.
- **Soundtracks:** I can't hear audio, so I only checked levels. Please listen to both films.
