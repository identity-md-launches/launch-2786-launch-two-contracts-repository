// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Independent numerical oracle for the supported LMSR domain. It uses Taylor series at
/// 36 decimal places, rather than Solady's rational exp/ln approximations or the maker's margins.
/// Inputs to exp have 27 decimal places: at b <= 100 IMD, truncation is much less than one wei.
/// This is intentionally slow test code; never use it to price a production transaction.
library LmsrReference {
    uint256 internal constant ONE = 1e36;
    uint256 internal constant RAY = 1e27;

    function cost(int256[4] memory q, uint256 b) internal pure returns (int256) {
        require(b >= 0.5 ether && b <= 100 ether, "reference b domain");
        int256 top = q[0];
        for (uint256 i = 1; i < 4; ++i) {
            if (q[i] > top) top = q[i];
        }
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 x = uint256(top - q[i]) * RAY / b;
            require(x <= 20 * RAY, "reference spread domain");
            // exp(-x) = 1 / exp(x); positive series terms avoid cancellation at x = 20.
            uint256 term = ONE;
            uint256 exponential = ONE;
            for (uint256 n = 1; term != 0 && n < 256; ++n) {
                term = term * x / RAY / n;
                exponential += term;
            }
            require(term == 0, "reference exp convergence");
            sum += ONE * ONE / exponential;
        }
        // ln(y) = 2 * (z + z^3/3 + z^5/5 + ...), z = (y-1)/(y+1).
        // The normalized sum is in [1,4], hence z <= 3/5 and the series converges quickly.
        uint256 z = (sum - ONE) * ONE / (sum + ONE);
        uint256 zSquared = z * z / ONE;
        uint256 power = z;
        uint256 logarithm;
        for (uint256 odd = 1; power != 0 && odd < 513; odd += 2) {
            logarithm += power / odd;
            power = power * zSquared / ONE;
        }
        require(power == 0, "reference ln convergence");
        return top + int256(b * (2 * logarithm) / ONE);
    }
}
