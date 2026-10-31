export type Status = "open" | "settled" | "voided";

/** 0: the condition happens, 1: it does not. */
export type World = 0 | 1;
/** 0: YES, 1: NO. */
export type Side = 0 | 1;

/** Answer per question: 0 none, 1 true, 2 false (as the contract stores it). */
export type Answer = 0 | 1 | 2;

export interface MarketView {
  id: number;
  creator: string;
  condition: string;
  outcome: string;
  rules: string;
  /** Unix seconds. */
  closeTime: number;
  resolveTime: number;
  voidAfter: number;
  status: Status;
  /** Set on settlement. */
  world: World;
  winningSide: Side;
  answers: [Answer, Answer];
  openAsks: [number, number];
  lastAskAt: [number, number];
  budget: number;
  /** The maker's net shares sold per outcome (index 2 * world + side), its liquidity parameter, and its IMD. */
  q: [number, number, number, number];
  b: number;
  seed: number;
  /** IMD in the market: the maker's balance plus complete sets. */
  liquidity: number;
  /** The connected account's shares per outcome, and the IMD it has in net of what it took out. */
  mine: [number, number, number, number];
  claimable: number;
  claimed: boolean;
  /** Display only: a category tag for demo markets. */
  tag?: string;
}

export interface Totals {
  burned: number;
  builderFees: number;
  oracleSpend: number;
  markets: number;
  staked: number;
}

export interface CreateInput {
  condition: string;
  outcome: string;
  rules: string;
  closeTime: number;
  resolveTime: number;
  /** The liquidity parameter. The seed, and the most the creator can lose, is b ln 4. */
  b: number;
}

/** What a stake is paid in. ETH and USDG are swapped into IMD in the same transaction. */
export type Coin = "IMD" | "ETH" | "USDG";

export interface Actions {
  /** `amount` is in `coin`. */
  stake: (id: number, world: World, side: Side, amount: number, coin: Coin) => Promise<void>;
  /** Sells the whole position back to the maker. */
  exit: (id: number) => Promise<void>;
  create: (input: CreateInput) => Promise<number | undefined>;
  requestResolution: (id: number) => Promise<void>;
  claim: (id: number) => Promise<void>;
  settle: (id: number) => Promise<void>;
  voidMarket: (id: number) => Promise<void>;
  /** Demo only: play the oracle. */
  simulateAnswer?: (id: number, condition: boolean, outcome: boolean) => void;
}

export interface Source {
  live: boolean;
  ready: boolean;
  markets: MarketView[];
  totals: Totals;
  account?: string;
  connected: boolean;
  wrongChain: boolean;
  connect: () => void;
  disconnect: () => void;
  balance: number;
  /** The wallet's balance of each coin. */
  coinBalances: Record<Coin, number>;
  /** IMD one unit of each coin buys now, after pool fees. */
  rates: Record<Coin, number>;
  actions: Actions;
  pending: string | null;
  error: string | null;
  clearError: () => void;
}
