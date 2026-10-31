import { qForOdds } from "./lmsr";
import type { MarketView } from "./types";

const DAY = 86_400;
const B = 30;

type Seed = Pick<MarketView, "creator" | "condition" | "outcome" | "rules" | "tag"> &
  Partial<Pick<MarketView, "status" | "world" | "winningSide" | "answers">> & {
    /** Chance of YES in each world. */
    odds: [number, number];
    liquidity: number;
    closeIn: number;
    resolveIn: number;
    asking?: boolean;
  };

const SEEDS: Seed[] = [
  {
    tag: "Macro",
    creator: "0x1c9e8b7a6d5f4e3c2b1a0f9e8d7c6b5a4f3e2d1c",
    condition: "The Federal Reserve raises the federal funds target range at its December 9 2026 decision",
    outcome: "BTC closes above 80000 USD on Coinbase on 2026-12-31",
    rules: "Rate decision: the FOMC statement on federalreserve.gov. Price: the Coinbase BTC-USD daily close (UTC) on 2026-12-31.",
    odds: [0.38, 0.61],
    liquidity: 842.6,
    closeIn: 8 * DAY,
    resolveIn: 61 * DAY,
  },
  {
    tag: "World",
    creator: "0x2b7f6e5d4c3b2a19f8e7d6c5b4a3928170f6e5d4",
    condition: "The United States carries out military strikes on Iran by 2026-12-31",
    outcome: "Brent crude closes above 100 USD on 2026-12-31",
    rules: "Strikes: confirmed by the US Department of Defense or at least two of Reuters, AP and BBC. Price: the ICE Brent front-month settlement.",
    odds: [0.72, 0.27],
    liquidity: 613.4,
    closeIn: 20 * DAY,
    resolveIn: 61 * DAY,
  },
  {
    tag: "Policy",
    creator: "0x8f3a4d1e0b6c2a9f7e5d3c1b0a9f8e7d6c5b4a39",
    condition: "The US Senate holds another cloture vote on the Clarity Act by 2026-12-31",
    outcome: "ETH closes above 2500 USD on Coinbase on 2026-12-31",
    rules: "Vote: the roll call on senate.gov. Price: the Coinbase ETH-USD daily close (UTC) on 2026-12-31.",
    odds: [0.56, 0.41],
    liquidity: 377.9,
    closeIn: 18 * DAY,
    resolveIn: 61 * DAY,
  },
  {
    tag: "IMD",
    creator: "0x4de63474f3715c407dafaa1429fa664559814401",
    condition: "BTC closes above 85000 USD on Coinbase on 2026-12-31",
    outcome: "IMD trades above 5 USD on its most liquid Uniswap pool on 2026-12-31",
    rules: "BTC: the Coinbase BTC-USD daily close (UTC). IMD: the DexScreener USD price at 2026-12-31 23:59 UTC.",
    odds: [0.64, 0.23],
    liquidity: 251.2,
    closeIn: 40 * DAY,
    resolveIn: 61 * DAY,
  },
  {
    tag: "Macro",
    creator: "0x5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d",
    condition: "US CPI year-over-year inflation for September 2026 is at or below 3 percent",
    outcome: "The S&P 500 closes at a record high at any point in October 2026",
    rules: "CPI: the BLS release on bls.gov (CPI-U, not seasonally adjusted). Record close: S&P Dow Jones Indices.",
    odds: [0.73, 0.46],
    liquidity: 298.6,
    closeIn: -2 * DAY,
    resolveIn: -6 * 3600,
    asking: true,
  },
  {
    tag: "Macro",
    creator: "0x7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b",
    condition: "The Federal Reserve raises the federal funds target range at its September 2026 meeting",
    outcome: "BTC closes above 100000 USD on Coinbase on 2026-10-01",
    rules: "Rate decision: the FOMC statement on federalreserve.gov. Price: the Coinbase BTC-USD daily close (UTC).",
    odds: [0.72, 0.26],
    liquidity: 1100,
    closeIn: -60 * DAY,
    resolveIn: -30 * DAY,
    status: "settled",
    world: 0,
    winningSide: 1,
    answers: [1, 2],
  },
];

/** Sample markets for the demo, timed relative to `now` (unix seconds). */
export function demoMarkets(now: number): MarketView[] {
  return SEEDS.map(({ closeIn, resolveIn, asking, odds, ...s }, i) => {
    const resolveTime = Math.floor(now + resolveIn);
    const status = s.status ?? "open";
    return {
      status,
      world: 0,
      winningSide: 0,
      answers: [0, 0],
      ...s,
      id: i + 1,
      closeTime: Math.floor(now + closeIn),
      resolveTime,
      voidAfter: resolveTime + 30 * DAY,
      openAsks: asking ? [1, 1] : [0, 0],
      lastAskAt: asking ? [now - 3600, now - 3600] : [0, 0],
      budget: asking || status !== "open" ? 0 : 1,
      q: qForOdds(odds[0], odds[1], B),
      b: B,
      seed: B * Math.log(4),
      mine: [0, 0, 0, 0],
      claimable: 0,
      claimed: false,
    };
  });
}
