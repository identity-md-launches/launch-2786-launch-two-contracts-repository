"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

import { RULES } from "@/lib/config";
import { demoMarkets } from "@/lib/demo";
import { cost, quoteExit, quoteStake, type Q } from "@/lib/lmsr";
import { seedFor } from "@/lib/market";
import type { Actions, Coin, MarketView, Side, Source, World } from "@/lib/types";

const DEMO_ACCOUNT = "0xdem0000000000000000000000000000000000000";
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** Sample rates: what one unit of each coin buys in IMD, after pool fees. */
const RATES: Record<Coin, number> = { IMD: 1, ETH: 650, USDG: 0.29 };

/** Same rules as the contract, in memory: stake, exit, ask, answer (you play the oracle), settle, claim. */
function payout(m: MarketView): number {
  if (m.status !== "settled") return 0;
  return m.mine[2 * m.world + m.winningSide];
}

export function useDemoMarkets(): Source {
  const [markets, setMarkets] = useState<MarketView[]>([]);
  const [balance, setBalance] = useState(250);
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [burned, setBurned] = useState(41.37);
  const [builderFees, setBuilderFees] = useState(20.69);
  const [oracleSpend, setOracleSpend] = useState(9);

  // Sample markets are timed from the browser's clock, never during prerender.
  useEffect(() => {
    const load = () => setMarkets(demoMarkets(Math.floor(Date.now() / 1000)));
    load();
  }, []);

  const update = useCallback((id: number, fn: (m: MarketView) => MarketView) => {
    setMarkets((ms) => ms.map((m) => (m.id === id ? withClaimable(fn(m)) : m)));
  }, []);

  const busy = useCallback(async (label: string, fn: () => void) => {
    setPending(label);
    await wait(650);
    fn();
    setPending(null);
  }, []);

  const actions: Actions = useMemo(
    () => ({
      stake: async (id, world, side, amount, coin) => {
        const imd = amount * RATES[coin];
        if (imd < RULES.minStake) return setError(`The smallest stake is ${RULES.minStake} IMD.`);
        if (coin === "IMD" && amount > balance) return setError("Not enough demo IMD.");
        await busy(coin === "IMD" ? "Staking" : `Swapping ${coin} and staking`, () => {
          if (coin === "IMD") setBalance((b) => b - amount);
          update(id, (m) => {
            const { k, q, fee } = quoteStake(m.q, m.b, world, side, imd);
            setBurned((x) => x + (fee * 67) / 200);
            setBuilderFees((x) => x + (fee * 33) / 200);
            const mine = [...m.mine] as Q;
            mine[2 * world + side] += imd + k;
            mine[2 * (1 - world)] += imd;
            mine[2 * (1 - world) + 1] += imd;
            return { ...m, q, mine, liquidity: m.liquidity + imd - fee };
          });
        });
      },
      exit: async (id) => {
        await busy("Selling", () => {
          update(id, (m) => {
            const got = quoteExit(m.q, m.b, m.mine);
            setBalance((b) => b + got);
            const q = m.q.map((v, i) => v - m.mine[i]) as Q;
            const moved = cost(m.q, m.b) - cost(q, m.b);
            return { ...m, q, mine: [0, 0, 0, 0], liquidity: Math.max(0, m.liquidity - moved) };
          });
        });
      },
      create: async (input) => {
        const seed = seedFor(input.b);
        const total = RULES.oracleDeposit + seed;
        if (balance < total) {
          setError(`Not enough demo IMD for the ${total.toFixed(2)} IMD this market needs.`);
          return undefined;
        }
        const id = markets.reduce((max, m) => Math.max(max, m.id), 0) + 1;
        await busy("Creating market", () => {
          setBalance((b) => b - total);
          setMarkets((ms) => {
            const m: MarketView = {
              id,
              creator: DEMO_ACCOUNT,
              condition: input.condition,
              outcome: input.outcome,
              rules: input.rules,
              closeTime: input.closeTime,
              resolveTime: input.resolveTime,
              voidAfter: input.resolveTime + RULES.resolutionDays * 86_400,
              status: "open",
              world: 0,
              winningSide: 0,
              answers: [0, 0],
              openAsks: [0, 0],
              lastAskAt: [0, 0],
              budget: RULES.oracleDeposit,
              q: [0, 0, 0, 0],
              b: input.b,
              seed,
              liquidity: seed,
              mine: [0, 0, 0, 0],
              claimable: 0,
              claimed: false,
              tag: "New",
            };
            return [m, ...ms];
          });
        });
        return id;
      },
      requestResolution: async (id) => {
        await busy("Paying the oracle", () => {
          const now = Math.floor(Date.now() / 1000);
          setOracleSpend((s) => s + 1);
          update(id, (m) => ({ ...m, budget: 0, openAsks: [1, 1], lastAskAt: [now, now] }));
        });
      },
      claim: async (id) => {
        const amount = markets.find((m) => m.id === id)?.claimable ?? 0;
        await busy("Claiming", () => {
          setBalance((b) => b + amount);
          update(id, (m) => ({ ...m, claimed: true }));
        });
      },
      settle: async () => {},
      voidMarket: async (id) => {
        await busy("Voiding", () => update(id, (m) => ({ ...m, status: "voided" })));
      },
      simulateAnswer: (id, condition, outcome) => {
        const m = markets.find((x) => x.id === id);
        if (!m || m.status !== "open") return;
        const world: World = condition ? 0 : 1;
        const winningSide: Side = outcome ? 0 : 1;
        update(id, () => ({
          ...m,
          answers: [condition ? 1 : 2, outcome ? 1 : 2],
          openAsks: [0, 0],
          status: "settled",
          world,
          winningSide,
          budget: 0,
        }));
      },
    }),
    [balance, busy, update, markets],
  );

  const totals = useMemo(() => {
    const staked = markets.reduce((s, m) => s + m.liquidity, 0);
    return { burned, builderFees, oracleSpend, markets: markets.length, staked };
  }, [markets, burned, builderFees, oracleSpend]);

  return {
    live: false,
    ready: markets.length > 0,
    markets,
    totals,
    account: DEMO_ACCOUNT,
    connected: true,
    wrongChain: false,
    connect: () => {},
    disconnect: () => {},
    balance,
    coinBalances: { IMD: balance, ETH: 0.5, USDG: 500 },
    rates: RATES,
    actions,
    pending,
    error,
    clearError: () => setError(null),
  };
}

function withClaimable(m: MarketView): MarketView {
  return m.claimed ? { ...m, claimable: 0 } : { ...m, claimable: payout(m) };
}
