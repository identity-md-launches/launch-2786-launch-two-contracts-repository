"use client";

import { useCallback, useMemo, useState } from "react";
import {
  useConnect,
  useConnection,
  useConnectors,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useBalance,
  useReadContracts,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { decodeEventLog, encodeAbiParameters, formatEther, formatUnits, keccak256, parseEther, parseUnits, zeroAddress, type Address, type Hex } from "viem";

import { conditionalsAbi, erc20Abi, zapAbi } from "@/lib/abi";
import { ADDRESSES, chain, RULES } from "@/lib/config";
import { askCost } from "@/lib/market";
import type { Q } from "@/lib/lmsr";
import type { Actions, Answer, Coin, MarketView, Side, Source, Status } from "@/lib/types";

const C = ADDRESSES.conditionals as Address;
const IMD = ADDRESSES.imd;
const ZAP = ADDRESSES.zap as Address;
const USDG = ADDRESSES.usdg;
const MANAGER = ADDRESSES.poolManager;
/** The newest markets the page reads. */
const WINDOW = 60;

const n = (v: bigint | undefined) => (v === undefined ? 0 : Number(formatEther(v)));
const STATUS: Status[] = ["open", "settled", "voided"];
const signed = (v: bigint) => Number(formatEther(v));
/** Solidity's `x * (1 - slippage)`. */
const lessSlippage = (v: bigint) => (v * BigInt(Math.round((1 - RULES.slippage) * 10_000))) / 10_000n;

const extsloadAbi = [
  {
    type: "function",
    name: "extsload",
    stateMutability: "view",
    inputs: [{ name: "slot", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

/** The storage slot of a hookless ETH pool's sqrt price in the v4 PoolManager (pools mapping at slot 6). */
const poolSlot = (token: Address, fee: number, tickSpacing: number) => {
  const id = keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [zeroAddress, token, fee, tickSpacing, zeroAddress],
    ),
  );
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [id, 6n]));
};
const ETH_IMD = poolSlot(IMD, 10_000, 100);
const ETH_USDG = poolSlot(USDG, 500, 10);
/** Token1 per wei of ETH at a pool's price. */
const price1Per0 = (slot0: Hex | undefined) => {
  if (!slot0) return 0;
  const sqrt = Number(BigInt(slot0) & ((1n << 160n) - 1n)) / 2 ** 96;
  return sqrt * sqrt;
};

type RawMarket = {
  creator: Address;
  closeTime: bigint;
  resolveTime: bigint;
  voidAfter: bigint;
  status: number;
  winner: number;
  answers: readonly [number, number];
  openAsks: readonly [number, number];
  lastAskAt: readonly [bigint, bigint];
  budget: bigint;
  q: readonly [bigint, bigint, bigint, bigint];
  b: bigint;
  subsidy: bigint;
  makerBalance: bigint;
  sets: bigint;
  condition: string;
  outcome: string;
  rules: string;
};

export function useLiveMarkets(): Source {
  const { address, isConnected, chainId } = useConnection();
  const connectors = useConnectors();
  const { mutate: connectWallet } = useConnect();
  const { mutate: disconnectWallet } = useDisconnect();
  const { mutateAsync: switchChain } = useSwitchChain();
  const { mutateAsync: write } = useWriteContract();
  const client = usePublicClient({ chainId: chain.id });

  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const base = { address: C, abi: conditionalsAbi, chainId: chain.id } as const;
  const core = useReadContracts({
    contracts: [
      { ...base, functionName: "marketCount" },
      { ...base, functionName: "totalBurned" },
      { ...base, functionName: "totalBuilderFees" },
      { ...base, functionName: "totalOracleSpend" },
    ],
    query: { refetchInterval: 6_000 },
  });
  const count = Number(core.data?.[0]?.result ?? 0n);
  const ids = useMemo(() => {
    const out: number[] = [];
    for (let i = count; i >= 1 && out.length < WINDOW; i--) out.push(i);
    return out;
  }, [count]);

  const marketsR = useReadContracts({
    contracts: ids.map((id) => ({ ...base, functionName: "getMarket", args: [BigInt(id)] }) as const),
    query: { enabled: ids.length > 0, refetchInterval: 6_000 },
  });

  const userR = useReadContracts({
    contracts: address
      ? ids.flatMap(
          (id) =>
            [
              { ...base, functionName: "sharesOf", args: [BigInt(id), address] },
              { ...base, functionName: "claimable", args: [BigInt(id), address] },
              { ...base, functionName: "claimed", args: [BigInt(id), address] },
            ] as const,
        )
      : [],
    query: { enabled: Boolean(address) && ids.length > 0, refetchInterval: 6_000 },
  });

  const balanceR = useReadContract({
    address: IMD,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: chain.id,
    query: { enabled: Boolean(address), refetchInterval: 6_000 },
  });
  const allowanceR = useReadContract({
    address: IMD,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, C] : undefined,
    chainId: chain.id,
    query: { enabled: Boolean(address), refetchInterval: 6_000 },
  });

  const usdgR = useReadContracts({
    contracts: address
      ? ([
          { address: USDG, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: chain.id },
          { address: USDG, abi: erc20Abi, functionName: "allowance", args: [address, ZAP], chainId: chain.id },
        ] as const)
      : [],
    query: { enabled: Boolean(address), refetchInterval: 6_000 },
  });
  const { data: ethBalance } = useBalance({ address, chainId: chain.id, query: { refetchInterval: 6_000 } });
  const poolsR = useReadContracts({
    contracts: [
      { address: MANAGER, abi: extsloadAbi, functionName: "extsload", args: [ETH_IMD], chainId: chain.id },
      { address: MANAGER, abi: extsloadAbi, functionName: "extsload", args: [ETH_USDG], chainId: chain.id },
    ] as const,
    query: { refetchInterval: 12_000 },
  });
  const rates = useMemo<Record<Coin, number>>(() => {
    // Both pools hold ETH as currency0. IMD has 18 decimals, like ETH; USDG has 6.
    const imdPerEth = price1Per0(poolsR.data?.[0]?.result as Hex | undefined) * 0.99;
    const usdgPerEth = (price1Per0(poolsR.data?.[1]?.result as Hex | undefined) * 1e12) / 0.9995;
    return { IMD: 1, ETH: imdPerEth, USDG: usdgPerEth > 0 ? imdPerEth / usdgPerEth : 0 };
  }, [poolsR.data]);

  const markets: MarketView[] = useMemo(() => {
    return ids.flatMap((id, i) => {
      const raw = marketsR.data?.[i]?.result as RawMarket | undefined;
      if (!raw) return [];
      const shares = userR.data?.[i * 3]?.result as readonly [bigint, bigint, bigint, bigint] | undefined;
      return [
        {
          id,
          creator: raw.creator,
          condition: raw.condition,
          outcome: raw.outcome,
          rules: raw.rules,
          closeTime: Number(raw.closeTime),
          resolveTime: Number(raw.resolveTime),
          voidAfter: Number(raw.voidAfter),
          status: STATUS[raw.status] ?? "open",
          world: (raw.winner >= 2 ? 1 : 0) as 0 | 1,
          winningSide: (raw.winner % 2) as Side,
          answers: [raw.answers[0] as Answer, raw.answers[1] as Answer],
          openAsks: [Number(raw.openAsks[0]), Number(raw.openAsks[1])],
          lastAskAt: [Number(raw.lastAskAt[0]), Number(raw.lastAskAt[1])],
          budget: n(raw.budget),
          q: raw.q.map(signed) as Q,
          b: n(raw.b),
          seed: n(raw.subsidy),
          liquidity: n(raw.makerBalance + raw.sets),
          mine: (shares ? shares.map(n) : [0, 0, 0, 0]) as Q,
          claimable: n(userR.data?.[i * 3 + 1]?.result as bigint | undefined),
          claimed: Boolean(userR.data?.[i * 3 + 2]?.result),
        },
      ];
    });
  }, [ids, marketsR.data, userR.data]);

  const refresh = useCallback(() => {
    core.refetch();
    marketsR.refetch();
    userR.refetch();
    balanceR.refetch();
    allowanceR.refetch();
    usdgR.refetch();
  }, [core, marketsR, userR, balanceR, allowanceR, usdgR]);

  const run = useCallback(
    async (label: string, fn: () => Promise<Hex>) => {
      setPending(label);
      setError(null);
      try {
        if (chainId !== chain.id) await switchChain({ chainId: chain.id });
        const hash = await fn();
        setPending("Confirming");
        const receipt = await client?.waitForTransactionReceipt({ hash });
        refresh();
        return receipt;
      } catch (e) {
        const msg = e instanceof Error ? (e as { shortMessage?: string }).shortMessage ?? e.message.split("\n")[0] : String(e);
        setError(msg.length > 180 ? `${msg.slice(0, 180)}…` : msg);
        return undefined;
      } finally {
        setPending(null);
      }
    },
    [chainId, client, refresh, switchChain],
  );

  /** Approves enough IMD for `amount`, if the allowance is short. */
  const ensureAllowance = useCallback(
    async (amount: bigint) => {
      const current = (allowanceR.data as bigint | undefined) ?? 0n;
      if (current >= amount) return true;
      const r = await run("Approving IMD", () =>
        write({ address: IMD, abi: erc20Abi, functionName: "approve", args: [C, amount], chainId: chain.id }),
      );
      return Boolean(r);
    },
    [allowanceR.data, run, write],
  );

  const actions: Actions = {
    stake: async (id, world, side, amount, coin) => {
      const market = BigInt(id);
      if (coin === "IMD") {
        const wei = parseEther(amount.toString());
        if (!(await ensureAllowance(wei))) return;
        const [k] = (await client!.readContract({ ...base, functionName: "quoteStake", args: [market, world, side, wei] })) as readonly [bigint, bigint];
        await run("Staking", () => write({ ...base, functionName: "stakeConditional", args: [market, world, side, wei, lessSlippage(k)] }));
        return;
      }
      const imdWei = parseEther((amount * rates[coin]).toFixed(18));
      const [k] = (await client!.readContract({ ...base, functionName: "quoteStake", args: [market, world, side, imdWei] })) as readonly [bigint, bigint];
      const minImd = lessSlippage(imdWei);
      const minShares = lessSlippage(lessSlippage(k));
      const zap = { address: ZAP, abi: zapAbi, chainId: chain.id } as const;
      if (coin === "ETH") {
        await run("Swapping ETH and staking", () =>
          write({ ...zap, functionName: "stakeWithEth", args: [market, world, side, minImd, minShares], value: parseEther(amount.toString()) }),
        );
        return;
      }
      const usdg = parseUnits(amount.toFixed(6), 6);
      if (((usdgR.data?.[1]?.result as bigint | undefined) ?? 0n) < usdg) {
        const ok = await run("Approving USDG", () =>
          write({ address: USDG, abi: erc20Abi, functionName: "approve", args: [ZAP, usdg], chainId: chain.id }),
        );
        if (!ok) return;
      }
      await run("Swapping USDG and staking", () =>
        write({ ...zap, functionName: "stakeWithUsdg", args: [market, world, side, usdg, minImd, minShares] }),
      );
    },
    exit: async (id) => {
      if (!address) return;
      // The contract's own answer to what leaving pays now, simulated from the account.
      const { result } = await client!.simulateContract({ ...base, account: address, functionName: "exit", args: [BigInt(id), 0n] });
      await run("Selling", () => write({ ...base, functionName: "exit", args: [BigInt(id), lessSlippage(result as bigint)] }));
    },
    create: async (input) => {
      const budget = parseEther(String(RULES.oracleDeposit));
      const b = parseEther(input.b.toString());
      const seed = (await client!.readContract({ ...base, functionName: "seedFor", args: [b] })) as bigint;
      if (!(await ensureAllowance(budget + seed))) return undefined;
      const receipt = await run("Creating market", () =>
        write({
          ...base,
          functionName: "createMarket",
          // maxBudget caps what the contract may pull for the oracle: a configuration activated meanwhile that
          // charges more makes the call revert instead of taking a larger deposit.
          args: [input.condition, input.outcome, input.rules, BigInt(input.closeTime), BigInt(input.resolveTime), budget, b],
        }),
      );
      for (const log of receipt?.logs ?? []) {
        try {
          const ev = decodeEventLog({ abi: conditionalsAbi, data: log.data, topics: log.topics });
          if (ev.eventName === "MarketCreated") return Number(ev.args.marketId);
        } catch {}
      }
      return undefined;
    },
    requestResolution: async (id) => {
      const m = markets.find((x) => x.id === id);
      const now = Math.floor(Date.now() / 1000);
      const extra = m ? askCost(m, now) : 0;
      if (extra > 0 && !(await ensureAllowance(parseEther(extra.toString())))) return;
      await run("Paying the oracle", () => write({ ...base, functionName: "requestResolution", args: [BigInt(id)] }));
    },
    claim: async (id) => {
      await run("Claiming", () => write({ ...base, functionName: "claim", args: [BigInt(id)] }));
    },
    settle: async (id) => {
      await run("Settling", () => write({ ...base, functionName: "settle", args: [BigInt(id)] }));
    },
    voidMarket: async (id) => {
      await run("Voiding", () => write({ ...base, functionName: "voidMarket", args: [BigInt(id)] }));
    },
  };

  const totals = {
    burned: n(core.data?.[1]?.result as bigint | undefined),
    builderFees: n(core.data?.[2]?.result as bigint | undefined),
    oracleSpend: n(core.data?.[3]?.result as bigint | undefined),
    markets: count,
    staked: markets.reduce((s, m) => s + m.liquidity, 0),
  };

  return {
    live: true,
    ready: core.isSuccess && (ids.length === 0 || marketsR.isSuccess),
    markets,
    totals,
    account: address,
    connected: isConnected,
    wrongChain: isConnected && chainId !== chain.id,
    connect: () => {
      const c = connectors[0];
      if (c) connectWallet({ connector: c, chainId: chain.id });
      else setError("No browser wallet found. Install MetaMask or Rabby.");
    },
    disconnect: () => disconnectWallet(),
    balance: n(balanceR.data as bigint | undefined),
    coinBalances: {
      IMD: n(balanceR.data as bigint | undefined),
      ETH: ethBalance ? Number(formatEther(ethBalance.value)) : 0,
      USDG: Number(formatUnits((usdgR.data?.[0]?.result as bigint | undefined) ?? 0n, 6)),
    },
    rates,
    actions,
    pending,
    error,
    clearError: () => setError(null),
  };
}
