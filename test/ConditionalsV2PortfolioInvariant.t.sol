// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConditionalsV2} from "src/ConditionalsV2.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";
import {LmsrReference} from "./utils/LmsrReference.sol";

/// @dev Three simultaneous markets at the minimum, intermediate and maximum b. The handler
/// accounts for fees from actual payer and collateral movements, independently of fee events/counters.
contract PortfolioHandler is Test {
    ConditionalsV2 public immutable c;
    MockIMD public immutable imd;
    address public immutable creator;
    address[4] public actors;
    address[4] public recipients; // creator, two rotating fee recipients, burn sink
    uint256[3] public ids;
    mapping(address => uint256) public expectedOwed;
    uint256 public expectedBurned;
    uint256 public expectedBuilderFees;
    uint256[4] public successes;
    bool public unexpectedRevert;
    bool public negativeFee;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    constructor(ConditionalsV2 c_, MockIMD imd_, address creator_, address builder, uint256[3] memory ids_) {
        c = c_;
        imd = imd_;
        creator = creator_;
        ids = ids_;
        recipients = [creator_, builder, makeAddr("portfolio-builder-two"), DEAD];
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("portfolio-trader-", vm.toString(i)));
            imd.mint(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            imd.approve(address(c), type(uint256).max);
        }
    }

    function _assets(uint256 id) internal view returns (uint256) {
        ConditionalsV2.Market memory m = c.getMarket(id);
        return m.makerBalance + m.sets;
    }

    function _record(uint256 id, address payer, uint256 assetsBefore, uint256 balanceBefore, uint256 kind) internal {
        // Cash into the contract minus cash added to maker/complete-set collateral is exactly the fee,
        // for buys, stakes, sales and exits (including fee-free redemption of complete sets).
        int256 fee = int256(balanceBefore) - int256(imd.balanceOf(payer)) - (int256(_assets(id)) - int256(assetsBefore));
        if (fee < 0) {
            negativeFee = true;
            return;
        }
        uint256 creatorPart = uint256(fee) / 2;
        uint256 burned = uint256(fee) * 67 / 200;
        uint256 builderPart = uint256(fee) - creatorPart - burned;
        expectedOwed[creator] += creatorPart;
        expectedOwed[c.feeRecipient()] += builderPart;
        if (imd.blocked(DEAD)) expectedOwed[DEAD] += burned;
        expectedBurned += burned;
        expectedBuilderFees += builderPart;
        ++successes[kind];
    }

    function _tradeFailure(bytes memory reason) internal {
        bytes4 selector;
        if (reason.length >= 4) {
            assembly ("memory-safe") { selector := mload(add(reason, 32)) }
        }
        // Saturation and rounding dust are specified refusals. Panics, insolvency and token failures
        // are not swallowed: the invariant fails even when Foundry's global fail_on_revert is false.
        if (
            selector != ConditionalsV2.PriceLimit.selector && selector != ConditionalsV2.TradeTooSmall.selector
                && selector != ConditionalsV2.TradeTooLarge.selector && selector != ConditionalsV2.NoPosition.selector
        ) unexpectedRevert = true;
    }

    function stake(uint256 market, uint256 payerSeed, uint256 receiverSeed, uint8 world, uint8 side, uint256 amount)
        external
    {
        uint256 id = ids[market % 3];
        address payer = actors[payerSeed % 4];
        address receiver = actors[receiverSeed % 4];
        amount = bound(amount, 1e15, 3 * c.getMarket(id).b);
        uint256 assetsBefore = _assets(id);
        uint256 balanceBefore = imd.balanceOf(payer);
        vm.prank(payer);
        try c.stakeFor(receiver, id, world % 2, side % 2, amount, 0) {
            _record(id, payer, assetsBefore, balanceBefore, 0);
        } catch (bytes memory reason) {
            _tradeFailure(reason);
        }
    }

    function buy(uint256 market, uint256 who, uint8 outcome, uint256 shares) external {
        uint256 id = ids[market % 3];
        address actor = actors[who % 4];
        shares = bound(shares, 1e15, 4 * c.getMarket(id).b);
        uint256 assetsBefore = _assets(id);
        uint256 balanceBefore = imd.balanceOf(actor);
        vm.prank(actor);
        try c.buy(id, outcome % 4, shares, type(uint256).max) returns (uint256 cost, uint256 fee) {
            assertEq(fee, (cost * 2 + 99) / 100, "buy fee rounds up to two percent");
            assertEq(balanceBefore - imd.balanceOf(actor), cost + fee);
            _record(id, actor, assetsBefore, balanceBefore, 1);
        } catch (bytes memory reason) {
            _tradeFailure(reason);
        }
    }

    function sell(uint256 market, uint256 who, uint8 outcome, uint256 shares) external {
        uint256 id = ids[market % 3];
        address actor = actors[who % 4];
        outcome %= 4;
        uint256 held = c.sharesOf(id, actor)[outcome];
        if (held < 1e15) return;
        shares = bound(shares, 1e15, held);
        uint256 assetsBefore = _assets(id);
        uint256 balanceBefore = imd.balanceOf(actor);
        vm.prank(actor);
        try c.sell(id, outcome, shares, 0) returns (uint256 proceeds) {
            uint256 gross = assetsBefore - _assets(id);
            assertEq(proceeds, gross - (gross * 2 + 99) / 100, "sell charges two percent of gross");
            assertEq(imd.balanceOf(actor) - balanceBefore, proceeds);
            _record(id, actor, assetsBefore, balanceBefore, 2);
        } catch (bytes memory reason) {
            _tradeFailure(reason);
        }
    }

    function exit(uint256 market, uint256 who) external {
        uint256 id = ids[market % 3];
        address actor = actors[who % 4];
        uint256 assetsBefore = _assets(id);
        uint256 balanceBefore = imd.balanceOf(actor);
        vm.prank(actor);
        try c.exit(id, 0) returns (uint256 proceeds) {
            assertEq(imd.balanceOf(actor) - balanceBefore, proceeds);
            _record(id, actor, assetsBefore, balanceBefore, 3);
        } catch (bytes memory reason) {
            _tradeFailure(reason);
        }
    }

    function rotateFees(uint256 recipient) external {
        vm.prank(c.owner());
        c.setFeeRecipient(recipients[recipient % 3]);
    }

    function blockBurn(bool blocked) external {
        imd.setBlocked(DEAD, blocked);
    }

    function withdraw(uint256 recipient) external {
        address account = recipients[recipient % 4];
        uint256 debt = expectedOwed[account];
        if (debt == 0) return;
        uint256 balanceBefore = imd.balanceOf(account);
        vm.prank(account);
        try c.withdrawOwed() returns (uint256 amount) {
            assertEq(amount, debt);
            assertEq(imd.balanceOf(account), balanceBefore + amount);
            expectedOwed[account] = 0;
        } catch (bytes memory reason) {
            if (
                account != DEAD || !imd.blocked(DEAD)
                    || keccak256(reason) != keccak256(abi.encodeWithSignature("Error(string)", "blocked"))
            ) {
                unexpectedRevert = true;
            }
        }
    }
}

contract ConditionalsV2PortfolioInvariantTest is Test {
    ConditionalsV2 internal c;
    MockIMD internal imd;
    PortfolioHandler internal h;
    address internal creator = makeAddr("portfolio-creator");
    address internal builder = makeAddr("portfolio-builder");
    uint256[3] internal ids;
    uint256 internal supply;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.roll(26_000_000);
        imd = new MockIMD();
        MockIntake intake = new MockIntake();
        c = new ConditionalsV2(address(this), imd, intake, makeAddr("portfolio-oracle"), builder);
        imd.mint(creator, 1_000 ether);
        uint256[3] memory liquidity = [uint256(0.5 ether), uint256(20 ether), uint256(100 ether)];
        vm.startPrank(creator);
        imd.approve(address(c), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            ids[i] = c.createMarket(
                "The specified public event occurs",
                "The specified public outcome occurs",
                "Use the published outcome at the resolution time.",
                uint64(block.timestamp + 7 days),
                uint64(block.timestamp + 14 days),
                1 ether,
                liquidity[i]
            );
        }
        vm.stopPrank();
        h = new PortfolioHandler(c, imd, creator, builder, ids);
        supply = imd.totalSupply();
        // Every sequence starts with real funded positions, including a payer different from its beneficiary.
        for (uint256 i; i < 3; ++i) {
            h.stake(i, i, (i + 1) % 4, 0, 0, liquidity[i] / 10);
        }
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = h.stake.selector;
        selectors[1] = h.buy.selector;
        selectors[2] = h.sell.selector;
        selectors[3] = h.exit.selector;
        selectors[4] = h.rotateFees.selector;
        selectors[5] = h.blockBurn.selector;
        selectors[6] = h.withdraw.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_portfolioConservesAssetsAndFundsTheFullLmsrCost() public view {
        assertFalse(h.unexpectedRevert(), "unexpected handler failure");
        assertFalse(h.negativeFee(), "a trade gave away unaccounted collateral");
        uint256 liabilities;
        for (uint256 k; k < 3; ++k) {
            ConditionalsV2.Market memory m = c.getMarket(ids[k]);
            // Stronger than just covering the largest q[i]: the cost includes the seed/entropy term.
            int256 cost = LmsrReference.cost(m.q, m.b);
            assertGe(int256(m.makerBalance), cost, "maker below independent LMSR cost");
            liabilities += m.makerBalance + m.sets + m.budget;
            uint256 basis;
            uint256[4] memory shares;
            for (uint256 a; a < 4; ++a) {
                address actor = h.actors(a);
                int256 net = c.netIn(ids[k], actor);
                assertGe(net, 0);
                basis += uint256(net);
                uint256[4] memory held = c.sharesOf(ids[k], actor);
                for (uint256 outcome; outcome < 4; ++outcome) {
                    shares[outcome] += held[outcome];
                }
            }
            assertEq(basis, m.refundBase);
            for (uint256 outcome; outcome < 4; ++outcome) {
                assertGe(cost, m.q[outcome]);
                assertEq(int256(shares[outcome]), m.q[outcome] + int256(m.sets));
            }
        }
        uint256 tokensOutside;
        for (uint256 i; i < 4; ++i) {
            address recipient = h.recipients(i);
            assertEq(c.owed(recipient), h.expectedOwed(recipient), "fee debt disagrees with cash-flow ledger");
            liabilities += h.expectedOwed(recipient);
            tokensOutside += imd.balanceOf(recipient) + imd.balanceOf(h.actors(i));
        }
        assertEq(imd.balanceOf(address(c)), liabilities, "exact custody across all three markets");
        assertEq(imd.totalSupply(), supply, "trading cannot mint IMD");
        assertEq(tokensOutside + imd.balanceOf(address(c)), supply, "no token leak");
        assertEq(c.totalBuilderFees(), h.expectedBuilderFees());
        assertEq(c.totalBurned(), h.expectedBurned());
        address dead = h.recipients(3);
        assertEq(imd.balanceOf(dead) + c.owed(dead), c.totalBurned(), "burn is transferred or still owed");
    }

    /// @dev Close every generated portfolio through the public API. This catches trapped claims that
    /// a balance inequality or a handler which catches all claim reverts would miss.
    function afterInvariant() public {
        vm.warp(uint256(c.getMarket(ids[2]).voidAfter) + 1);
        for (uint256 k; k < 3; ++k) {
            c.voidMarket(ids[k]);
            ConditionalsV2.Market memory m = c.getMarket(ids[k]);
            uint256[4] memory prices = c.prices(ids[k]);
            uint256 paid;
            for (uint256 a; a < 4; ++a) {
                // Vary claim order with the generated history.
                address actor = h.actors((a + h.successes(1)) % 4);
                uint256 cost = uint256(c.netIn(ids[k], actor));
                uint256 quote = c.claimable(ids[k], actor);
                uint256[4] memory held = c.sharesOf(ids[k], actor);
                uint256 value;
                for (uint256 outcome; outcome < 4; ++outcome) {
                    value += held[outcome] * prices[outcome] / 1e18;
                }
                assertLe(quote, cost, "a void must never refund above cost");
                assertGe(quote, value < cost ? value : cost, "short refund below backed position value");
                if (m.refundPool == m.refundBase) assertEq(quote, cost);
                uint256 before_ = imd.balanceOf(actor);
                vm.prank(actor);
                uint256 amount = c.claim(ids[k]);
                assertEq(amount, quote);
                assertEq(imd.balanceOf(actor), before_ + quote);
                assertEq(c.claimable(ids[k], actor), 0);
                paid += amount;
            }
            assertEq(c.getMarket(ids[k]).refundPaid, paid);
            assertLe(paid, m.refundPool);
        }
        vm.warp(block.timestamp + 365 days);
        for (uint256 k; k < 3; ++k) {
            ConditionalsV2.Market memory m = c.getMarket(ids[k]);
            if (m.refundPool < m.refundBase && m.refundPool > m.refundPaid) {
                uint256 before_ = imd.balanceOf(creator);
                c.sweepVoid(ids[k]);
                assertEq(imd.balanceOf(creator) - before_, m.refundPool - m.refundPaid);
            }
        }
        h.blockBurn(false);
        for (uint256 i; i < 4; ++i) {
            h.withdraw(i);
        }
        assertFalse(h.unexpectedRevert());
        assertEq(imd.balanceOf(address(c)), 0, "all claims, fees, budgets and residuals can leave");
    }

    function test_handlerExercisesAllTradeAndFeePaths() public {
        h.blockBurn(true);
        h.rotateFees(0); // creator is also builder: both parts must accumulate in the same debt
        h.buy(0, 0, 2, 0.1 ether);
        h.sell(0, 0, 2, 0.05 ether);
        h.exit(0, 0);
        assertGt(h.expectedOwed(h.recipients(3)), 0);
        h.withdraw(3); // blocked burn withdrawal must retain its debt
        h.rotateFees(2);
        h.buy(1, 3, 1, 2 ether);
        h.withdraw(2);
        for (uint256 i; i < 4; ++i) {
            assertGt(h.successes(i), 0);
        }
        invariant_portfolioConservesAssetsAndFundsTheFullLmsrCost();
        afterInvariant();
    }

    function test_referenceNeutralAndTranslationVectors() public pure {
        int256[4] memory q;
        assertEq(LmsrReference.cost(q, 1 ether), 1_386_294_361_119_890_618);
        for (uint256 i; i < 4; ++i) {
            q[i] = -20 ether;
        }
        assertEq(LmsrReference.cost(q, 1 ether), -18_613_705_638_880_109_382);
    }

    /// @dev Frozen, independent vectors: Python decimal at precision 100, evaluating
    /// max(q) + b * ln(sum(exp((q[i]-max(q))/b))) and taking the integer floor.
    /// No Python, FFI or downloaded data is needed when the suite runs.
    function test_referenceSaturatedFractionalAndSubWeiVectors() public pure {
        int256[4] memory q;
        assertEq(LmsrReference.cost(q, 0.5 ether), 693_147_180_559_945_309);
        q = [int256(10 ether), int256(0), int256(0), int256(0)];
        assertEq(LmsrReference.cost(q, 0.5 ether), 10_000_000_003_091_730_424);
        q = [int256(-10 ether), int256(0), int256(-10 ether), int256(0)];
        assertEq(LmsrReference.cost(q, 0.5 ether), 346_573_591_310_549_464);
        q = [int256(2_000 ether), int256(0), int256(0), int256(0)];
        assertEq(LmsrReference.cost(q, 100 ether), 2_000_000_000_618_346_084_819);
        q = [int256(17 ether), int256(-3 ether), int256(2 ether), int256(16 ether)];
        assertEq(LmsrReference.cost(q, 1_234_567_890_123_456_789), 17_454_339_272_851_938_395);
        q = [int256(1), int256(-1), int256(0), int256(0)];
        assertEq(LmsrReference.cost(q, 100 ether - 1), 138_629_436_111_989_061_882);
        q = [int256(300 ether), int256(300 ether - 1), int256(280 ether), int256(291 ether)];
        assertEq(LmsrReference.cost(q, 1 ether), 300_693_208_884_588_832_713);
    }
}
