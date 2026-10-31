import { RULES } from "./config";
import { prices, quoteExit, quoteStake } from "./lmsr";
import type { MarketView, Side, World } from "./types";

export const WORLD_NAMES: Record<World, string> = { 0: "It happens", 1: "It doesn't" };

export function totalStaked(m: MarketView) {
  return m.liquidity;
}

/** The market's chance of YES in a world. */
export function yesChance(m: MarketView, w: World): number {
  const p = prices(m.q, m.b);
  const yes = p[2 * w];
  return yes / (yes + p[2 * w + 1]);
}

/** How many points the condition moves the outcome: YES in world 0 minus YES in world 1. */
export function impact(m: MarketView): number {
  return (yesChance(m, 0) - yesChance(m, 1)) * 100;
}

/** What a new stake of `amount` IMD would pay if its world happens and its side wins. */
export function estimatePayout(m: MarketView, w: World, s: Side, amount: number) {
  if (amount <= 0) return 0;
  return amount + quoteStake(m.q, m.b, w, s, amount).k;
}

export function multiple(m: MarketView, w: World, s: Side, amount: number): number | null {
  return amount > 0 ? estimatePayout(m, w, s, amount) / amount : null;
}

/** Whether a stake would push the market past the contract's price limit. */
export function overLimit(m: MarketView, w: World, s: Side, amount: number) {
  return amount > 0 && quoteStake(m.q, m.b, w, s, amount).limited;
}

/** What selling the connected account's whole position gives now. */
export function exitValue(m: MarketView) {
  return quoteExit(m.q, m.b, m.mine);
}

/** The seed a liquidity parameter needs, b ln 4: also the most a creator can lose. */
export const seedFor = (b: number) => b * Math.log(4);

export type Stage = "trading" | "closed" | "resolving" | "voidable" | "settled" | "voided";

export function stage(m: MarketView, now: number): Stage {
  if (m.status === "settled") return "settled";
  if (m.status === "voided") return "voided";
  if (now < m.closeTime) return "trading";
  if (now < m.resolveTime) return "closed";
  if (voidable(m, now)) return "voidable";
  return "resolving";
}

/** Both answers are needed: the outcome decides the winning side in whichever world happened. */
export function settleable(m: MarketView) {
  if (m.status !== "open") return false;
  return m.answers[0] !== 0 && m.answers[1] !== 0;
}

/** Whether `voidMarket` would succeed now: past voidAfter, not settleable, and no live ask younger than a day. */
export function voidable(m: MarketView, now: number) {
  if (m.status !== "open" || now <= m.voidAfter || settleable(m)) return false;
  for (const q of [0, 1] as const) {
    if (m.answers[q] === 0 && m.openAsks[q] > 0 && now < m.lastAskAt[q] + RULES.retryHours * 3600) return false;
  }
  return true;
}

/** Whether `requestResolution` would ask something now. */
export function askable(m: MarketView, now: number) {
  if (m.status !== "open" || now < m.resolveTime || now > m.voidAfter) return false;
  const can = (q: 0 | 1) => {
    if (m.answers[q] !== 0) return false;
    return m.openAsks[q] === 0 || now >= m.lastAskAt[q] + RULES.retryHours * 3600;
  };
  return can(0) || can(1);
}

/** Questions the next ask pays for itself: the budget covers 0.5 IMD each. */
export function askCost(m: MarketView, now: number) {
  let n = 0;
  for (const q of [0, 1] as const) {
    if (m.answers[q] !== 0) continue;
    if (m.openAsks[q] === 0 || now >= m.lastAskAt[q] + RULES.retryHours * 3600) n++;
  }
  return Math.max(0, n * RULES.oraclePrice - m.budget);
}

export const STAGE_LABEL: Record<Stage, string> = {
  trading: "Live",
  closed: "Closed",
  resolving: "Asking the oracle",
  voidable: "Voidable",
  settled: "Settled",
  voided: "Voided",
};

export function myTotal(m: MarketView) {
  return m.mine[0] + m.mine[1] + m.mine[2] + m.mine[3];
}
