// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {ConditionalsZap} from "../src/ConditionalsZap.sol";
import {IPoolManager, IUnlockCallback} from "../src/interfaces/IPoolManager.sol";

/// @dev A PoolManager that keeps the rules the zap relies on: it calls back only the unlocker, swaps fill at a fixed
///      rate (optionally only half the input), and the unlock reverts unless every delta is settled.
contract MockPoolManager {
    MockIMD public imd;
    address public usdg;
    bool public unlocked;
    bool public halfFill;
    uint256 public partialOnSwap;
    uint256 public swapsThisUnlock;
    /// @dev Output per 1e18 of input, per pool (keyed by currency1).
    mapping(address => uint256) public rate;
    mapping(address => int256) public delta;
    address public synced;
    uint256 public syncedBalance;
    IPoolManager.PoolKey[] public keys;
    IPoolManager.SwapParams[] public parameters;
    bytes32[] public hookDataHashes;

    constructor(MockIMD imd_, address usdg_) {
        imd = imd_;
        usdg = usdg_;
    }

    receive() external payable {}

    function setRate(address token, uint256 r) external {
        rate[token] = r;
    }

    function setPartial(bool p) external {
        halfFill = p;
    }

    function setPartialOnSwap(uint256 number) external {
        partialOnSwap = number;
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "already unlocked");
        unlocked = true;
        swapsThisUnlock = 0;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(delta[address(0)] == 0 && delta[address(imd)] == 0 && delta[usdg] == 0, "CurrencyNotSettled");
        unlocked = false;
    }

    function swap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        returns (int256)
    {
        require(unlocked, "locked");
        require(params.amountSpecified < 0, "exact input only");
        keys.push(key);
        parameters.push(params);
        hookDataHashes.push(keccak256(hookData));
        ++swapsThisUnlock;
        uint256 amountIn = uint256(-params.amountSpecified);
        if (halfFill || partialOnSwap == swapsThisUnlock) amountIn /= 2;
        uint256 out = amountIn * rate[key.currency1] / 1e18;
        int128 a0;
        int128 a1;
        if (params.zeroForOne) {
            a0 = -int128(int256(amountIn));
            a1 = int128(int256(out));
        } else {
            a0 = int128(int256(out));
            a1 = -int128(int256(amountIn));
        }
        delta[key.currency0] += a0;
        delta[key.currency1] += a1;
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address currency) external {
        synced = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (synced == address(0)) {
            paid = msg.value;
            delta[address(0)] += int256(paid);
        } else {
            paid = IERC20(synced).balanceOf(address(this)) - syncedBalance;
            delta[synced] += int256(paid);
            synced = address(0);
        }
    }

    function take(address currency, address to, uint256 amount) external {
        delta[currency] -= int256(amount);
        imd.mint(to, amount);
        require(currency == address(imd), "take");
    }
}

contract ConditionalsZapTest is Fixture {
    MockIMD internal usdg;
    MockPoolManager internal pm;
    ConditionalsZap internal zap;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        usdg = new MockIMD();
        pm = new MockPoolManager(imd, address(usdg));
        pm.setRate(address(imd), 600 ether); // 1 ETH buys 600 IMD
        zap = new ConditionalsZap(c, IPoolManager(address(pm)), IERC20(address(imd)), IERC20(address(usdg)));
        id = _create();
        vm.deal(alice, 10 ether);
        usdg.mint(alice, 1_000e6);
        vm.prank(alice);
        usdg.approve(address(zap), type(uint256).max);
    }

    function _assertHoldsNothing() internal view {
        assertEq(address(zap).balance, 0, "eth left");
        assertEq(imd.balanceOf(address(zap)), 0, "imd left");
        assertEq(usdg.balanceOf(address(zap)), 0, "usdg left");
        assertEq(imd.allowance(address(zap), address(c)), 0, "allowance left");
        uint256[4] memory s = c.sharesOf(id, address(zap));
        assertEq(s[0] + s[1] + s[2] + s[3], 0, "the zap holds no position");
    }

    function test_eth_stakesForTheCallerThroughTheEthImdPool() public {
        vm.prank(alice);
        (uint256 imdStaked, uint256 shares) = zap.stakeWithEth{value: 0.01 ether}(id, 1, 0, 6 ether, 0);
        assertEq(imdStaked, 6 ether);
        assertEq(c.sharesOf(id, alice)[2], imdStaked + shares);
        assertEq(c.sharesOf(id, alice)[0], imdStaked, "the other world refunds");
        assertGt(c.netIn(id, alice), 0);
        assertEq(pm.keyCount(), 1);
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = pm.keys(0);
        assertEq(c0, address(0));
        assertEq(c1, address(imd));
        assertEq(fee, 10_000);
        assertEq(spacing, 100);
        assertEq(hooks, address(0));
        assertEq(address(pm).balance, 0.01 ether);
        _assertHoldsNothing();
    }

    function test_usdg_stakesForTheCaller() public {
        // The mock prices by currency1; for the USDG pool the output is ETH per USDG unit.
        pm.setRate(address(usdg), 0.0005 ether * 1e18 / 1e6); // 1 USDG = 0.0005 ETH
        vm.prank(alice);
        (uint256 imdStaked,) = zap.stakeWithUsdg(id, 0, 1, 20e6, 0, 0);
        assertEq(imdStaked, 6 ether, "20 USDG -> 0.01 ETH -> 6 IMD");
        assertEq(usdg.balanceOf(alice), 980e6);
        assertEq(usdg.balanceOf(address(pm)), 20e6, "the USDG was paid to the manager");
        assertEq(pm.keyCount(), 2);
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = pm.keys(0);
        assertEq(c0, address(0));
        assertEq(c1, address(usdg));
        assertEq(fee, 500);
        assertEq(spacing, 10);
        assertEq(hooks, address(0));
        (, c1, fee, spacing,) = pm.keys(1);
        assertEq(c1, address(imd));
        assertEq(fee, 10_000);
        assertEq(spacing, 100);
        assertGt(c.sharesOf(id, alice)[1], imdStaked, "the chosen side got the extra shares");
        assertEq(c.sharesOf(id, alice)[2], imdStaked);
        _assertHoldsNothing();
    }

    function test_partialFillReverts() public {
        pm.setPartial(true);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.PartialFill.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 0, 0);
        pm.setRate(address(usdg), 0.0005 ether * 1e18 / 1e6);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.PartialFill.selector);
        zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(alice.balance, 10 ether);
        assertEq(usdg.balanceOf(alice), 1_000e6);
    }

    function test_slippageBoundsRevert() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 6 ether + 1, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 6 ether, 100 ether);
        assertEq(alice.balance, 10 ether);
    }

    function test_marketRefusalRevertsTheWholeZap() public {
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.BettingClosed.selector);
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.UnknownMarket.selector);
        zap.stakeWithEth{value: 0.01 ether}(99, 0, 0, 0, 0);
    }

    function test_tinySwapBelowMinTradeReverts() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.TradeTooSmall.selector);
        zap.stakeWithEth{value: 1e12}(id, 0, 0, 0, 0); // 1e12 wei buys 6e14 IMD < MIN_TRADE
    }

    function test_zeroAmountsAndCallerChecks() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithEth(id, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.ZeroAmount.selector);
        zap.stakeWithUsdg(id, 0, 0, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(false, 1 ether));
        // Without approval the USDG pull fails before any swap.
        vm.prank(bob);
        vm.expectRevert();
        zap.stakeWithUsdg(id, 0, 0, 1e6, 0, 0);
    }

    function test_constructorRefusesZeroAddresses() public {
        IPoolManager p = IPoolManager(address(pm));
        IERC20 i = IERC20(address(imd));
        IERC20 u = IERC20(address(usdg));
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(ConditionalsV2(address(0)), p, i, u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, IPoolManager(address(0)), i, u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, p, IERC20(address(0)), u);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, p, i, IERC20(address(0)));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ethZapLeavesNothingBehind(uint96 value, uint8 world, uint8 side) public {
        value = uint96(bound(value, 1e13, 0.2 ether));
        vm.deal(alice, value);
        vm.prank(alice);
        try zap.stakeWithEth{value: value}(id, world % 2, side % 2, 0, 0) returns (uint256 imdStaked, uint256) {
            assertEq(imdStaked, uint256(value) * 600);
            assertEq(alice.balance, 0);
        } catch {
            assertEq(alice.balance, value, "a refused zap returns the ETH");
        }
        _assertHoldsNothing();
    }

    function _twoHopRate() internal {
        pm.setRate(address(usdg), 0.0005 ether * 1e18 / 1e6);
    }

    function _zapState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                c.getMarket(id),
                c.sharesOf(id, alice),
                c.netIn(id, alice),
                c.owed(creator),
                c.owed(builder),
                c.totalBurned(),
                imd.balanceOf(DEAD),
                imd.balanceOf(address(c)),
                imd.balanceOf(address(zap)),
                imd.totalSupply(),
                imd.allowance(address(zap), address(c)),
                usdg.balanceOf(alice),
                usdg.balanceOf(address(zap)),
                usdg.balanceOf(address(pm)),
                usdg.allowance(alice, address(zap)),
                alice.balance,
                address(zap).balance,
                address(pm).balance,
                pm.delta(address(0)),
                pm.delta(address(imd)),
                pm.delta(address(usdg)),
                pm.synced(),
                pm.syncedBalance(),
                pm.keyCount(),
                pm.swapsThisUnlock(),
                pm.unlocked()
            )
        );
    }

    function test_usdgSecondLegPartialFillRestoresFirstSwapAndPayment() public {
        _twoHopRate();
        pm.setPartialOnSwap(2);
        vm.prank(alice);
        usdg.approve(address(zap), 20e6);
        bytes32 before_ = _zapState();
        // The first hop really reaches ERC-20 settlement before the second hop refuses the fill.
        vm.expectCall(address(usdg), abi.encodeCall(IERC20.transfer, (address(pm), 20e6)));
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.PartialFill.selector);
        zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(_zapState(), before_, "both pools, allowance and positions roll back");

        pm.setPartialOnSwap(0);
        vm.prank(alice);
        (uint256 amount,) = zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(amount, 6 ether);
        assertEq(usdg.allowance(alice, address(zap)), 0);
        _assertHoldsNothing();
    }

    function test_usdgBothSlippageBoundsAndInvalidChoiceRollBackTwoHops() public {
        _twoHopRate();
        vm.prank(alice);
        usdg.approve(address(zap), 20e6);
        bytes32 before_ = _zapState();
        vm.prank(alice);
        vm.expectRevert(ConditionalsZap.SlippageExceeded.selector);
        zap.stakeWithUsdg(id, 0, 0, 20e6, 6 ether + 1, 0);
        assertEq(_zapState(), before_);
        (uint256 quote,) = c.quoteStake(id, 0, 0, 6 ether);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        zap.stakeWithUsdg(id, 0, 0, 20e6, 6 ether, quote + 1);
        assertEq(_zapState(), before_);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.InvalidChoice.selector);
        zap.stakeWithUsdg(id, 2, 0, 20e6, 0, 0);
        assertEq(_zapState(), before_);
    }

    function test_usdgSettlementFailureReturnsTheInputAndAllowance() public {
        _twoHopRate();
        usdg.setBlocked(address(pm), true);
        vm.prank(alice);
        usdg.approve(address(zap), 20e6);
        bytes32 before_ = _zapState();
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(_zapState(), before_);
    }

    function test_outputTokenRefusalRollsBackBothPaymentRoutes() public {
        _twoHopRate();
        imd.setBlocked(address(zap), true);
        bytes32 before_ = _zapState();
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        zap.stakeWithEth{value: 0.01 ether}(id, 0, 0, 0, 0);
        assertEq(_zapState(), before_);
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        zap.stakeWithUsdg(id, 0, 0, 20e6, 0, 0);
        assertEq(_zapState(), before_);
    }

    /// @dev Six-decimal input units cross two opposite swap directions. All bounded cases must
    /// succeed, so an always-reverting zap cannot pass this property.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_usdgExactInputTwoHopAccounting(uint96 units, uint8 world, uint8 side) public {
        _twoHopRate();
        uint256 amount = bound(units, 1e6, 100e6);
        world %= 2;
        side %= 2;
        uint256 ethOutput = amount * 5e8;
        uint256 imdOutput = ethOutput * 600;
        (uint256 expectedShares,) = c.quoteStake(id, world, side, imdOutput);
        vm.startPrank(alice);
        usdg.approve(address(zap), amount);
        (uint256 staked, uint256 shares) = zap.stakeWithUsdg(id, world, side, amount, imdOutput, expectedShares);
        vm.stopPrank();
        assertEq(staked, imdOutput);
        assertEq(shares, expectedShares);
        uint256[4] memory held = c.sharesOf(id, alice);
        assertEq(held[2 * world + side], imdOutput + shares);
        assertEq(held[2 * world + (1 - side)], 0);
        assertEq(held[2 * (1 - world)], imdOutput);
        assertEq(held[2 * (1 - world) + 1], imdOutput);
        assertEq(usdg.balanceOf(alice), 1_000e6 - amount);
        assertEq(usdg.balanceOf(address(pm)), amount);
        assertEq(usdg.allowance(alice, address(zap)), 0);
        assertEq(address(pm).balance, 0, "intermediate ETH nets internally");
        assertEq(pm.delta(address(0)), 0);
        assertEq(pm.delta(address(imd)), 0);
        assertEq(pm.delta(address(usdg)), 0);
        assertFalse(pm.unlocked());
        assertEq(pm.keyCount(), 2);
        (bool direction, int256 specified, uint160 limit) = pm.parameters(0);
        assertFalse(direction, "USDG -> ETH");
        assertEq(specified, -int256(amount));
        assertEq(limit, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341);
        (direction, specified, limit) = pm.parameters(1);
        assertTrue(direction, "ETH -> IMD");
        assertEq(specified, -int256(ethOutput));
        assertEq(limit, 4_295_128_740);
        assertEq(pm.hookDataHashes(0), keccak256(""));
        assertEq(pm.hookDataHashes(1), keccak256(""));
        _assertHoldsNothing();
    }
}
