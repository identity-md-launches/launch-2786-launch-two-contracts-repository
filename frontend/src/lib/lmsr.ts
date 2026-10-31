/** The contract's LMSR in floating point, for what the page shows. Transactions use the contract's own numbers. */

export type Q = [number, number, number, number];

function normalised(q: Q, b: number) {
  const max = Math.max(...q);
  return { max, sum: q.reduce((s, v) => s + Math.exp((v - max) / b), 0) };
}

export function cost(q: Q, b: number) {
  const { max, sum } = normalised(q, b);
  return max + b * Math.log(sum);
}

export function prices(q: Q, b: number): Q {
  const { max, sum } = normalised(q, b);
  return q.map((v) => Math.exp((v - max) / b) / sum) as Q;
}

/** Puts a market at the given chances of YES in each world, with the condition at 50%. */
export function qForOdds(yesA: number, yesB: number, b: number): Q {
  return [yesA / 2, (1 - yesA) / 2, yesB / 2, (1 - yesB) / 2].map((p) => b * Math.log(4 * p)) as Q;
}

const FEE = 0.02;

/** What a stake of `x` IMD gives: the extra shares `k` and the fee. Mirrors `_stakeMath`. */
export function quoteStake(q0: Q, b: number, world: 0 | 1, side: 0 | 1, x: number) {
  const chosen = 2 * world + side;
  const opposite = 2 * world + (1 - side);
  const q = [...q0] as Q;
  const before = cost(q, b);
  q[opposite] -= x;
  const gross = before - cost(q, b);
  const sellFee = gross * FEE;
  const spendable = gross - sellFee;
  const spend = spendable / (1 + FEE);
  const { max, sum } = normalised(q, b);
  const e = Math.exp((q[chosen] - max) / b);
  const k = b * Math.log((sum * Math.exp(spend / b) - sum + e) / e);
  q[chosen] += k;
  const limited = Math.max(...q) - Math.min(...q) > 20 * b;
  return { k, q, fee: sellFee + (spendable - spend), limited };
}

/** What selling every share gives now, after fees. Mirrors `exit`. */
export function quoteExit(q0: Q, b: number, shares: Q) {
  const sets = Math.min(...shares);
  let proceeds = sets;
  const q = [...q0] as Q;
  shares.forEach((held, i) => {
    const rest = held - sets;
    if (rest <= 0) return;
    const before = cost(q, b);
    q[i] -= rest;
    proceeds += (before - cost(q, b)) * (1 - FEE);
  });
  return proceeds;
}
