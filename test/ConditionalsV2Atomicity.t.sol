// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {ConditionalsV2} from "src/ConditionalsV2.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IOracleAttestation} from "src/interfaces/IOracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Fault injection at the external-call boundary. Both requests really transfer their payment;
/// the second can revert or return an id already used by the first.
contract AtomicityIntake is IIntake {
    address public immutable treasury;
    uint256 public count;
    uint256 public refuseAt;
    bool public duplicate;

    error RequestRefused(uint256 number);

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function configure(uint256 refuseAt_, bool duplicate_) external {
        refuseAt = refuseAt_;
        duplicate = duplicate_;
    }

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        ++count;
        require(IERC20(asset).transferFrom(msg.sender, treasury, amount));
        if (count == refuseAt) revert RequestRefused(count);
        return keccak256(abi.encode(address(this), duplicate ? uint256(1) : count));
    }
}

contract ConditionalsV2AtomicityTest is Fixture {
    /// @dev Include all financial fields touched by these calls, not just the reverting call's return value.
    function _books(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                c.getMarket(id),
                c.sharesOf(id, alice),
                c.sharesOf(id, bob),
                c.netIn(id, alice),
                c.netIn(id, bob),
                imd.balanceOf(address(c)),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                imd.balanceOf(creator),
                imd.balanceOf(builder),
                imd.balanceOf(DEAD),
                c.owed(creator),
                c.owed(builder),
                c.owed(DEAD),
                c.totalBurned(),
                c.totalBuilderFees(),
                c.totalOracleSpend()
            )
        );
    }

    function _faultyIntake(uint256 refuseAt, bool duplicate) internal returns (AtomicityIntake faulty, uint256 id) {
        faulty = new AtomicityIntake(makeAddr("atomicity-treasury"));
        faulty.configure(refuseAt, duplicate);
        ConditionalsV2.OracleConfig memory cfg = _config();
        cfg.intake = IIntake(address(faulty));
        vm.prank(owner);
        c.proposeOracleConfig(cfg);
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        c.activateOracleConfig();
        id = _create();
        vm.warp(resolveTime);
    }

    function _assertAskBatchRolledBack(uint256 id, AtomicityIntake faulty, bytes32 before_) internal view {
        assertEq(_books(id), before_, "market, budget and payments rolled back");
        assertEq(faulty.count(), 0, "first external request rolled back too");
        assertEq(imd.balanceOf(faulty.treasury()), 0, "neither price was spent");
        assertEq(imd.allowance(address(c), address(faulty)), 0, "no approval escaped");
        bytes32 first = keccak256(abi.encode(address(faulty), uint256(1)));
        (,, bool live,) = c.asks(keccak256(abi.encode(address(faulty), first)));
        assertFalse(live, "no orphaned first ask");
    }

    function test_requestSecondExternalFailureRollsBackFirstPaymentAndAsk() public {
        (AtomicityIntake faulty, uint256 id) = _faultyIntake(2, false);
        bytes32 before_ = _books(id);
        vm.expectRevert(abi.encodeWithSelector(AtomicityIntake.RequestRefused.selector, 2));
        c.requestResolution(id);
        _assertAskBatchRolledBack(id, faulty, before_);

        faulty.configure(0, false);
        assertEq(c.requestResolution(id), 2, "a repaired intake can retry immediately");
        assertEq(faulty.count(), 2);
        assertEq(imd.balanceOf(faulty.treasury()), 1 ether);
        assertEq(imd.allowance(address(c), address(faulty)), 0);
    }

    function test_duplicateIntakeIdRollsBackBothPayments() public {
        (AtomicityIntake faulty, uint256 id) = _faultyIntake(0, true);
        bytes32 before_ = _books(id);
        vm.expectRevert(ConditionalsV2.DuplicateAsk.selector);
        c.requestResolution(id);
        _assertAskBatchRolledBack(id, faulty, before_);
    }

    function test_secondQuestionShortfallFailureRestoresBudgetAndCallerAllowance() public {
        uint256 id = _create();
        intake.setPrice(0.75 ether);
        vm.warp(resolveTime);
        vm.prank(alice);
        imd.approve(address(c), 0.5 ether - 1);
        bytes32 before_ = _books(id);
        uint256 treasuryBefore = imd.balanceOf(intake.PAYEE());
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(c), 0.5 ether - 1, 0.5 ether
            )
        );
        c.requestResolution(id);
        assertEq(_books(id), before_);
        assertEq(intake.count(), 0);
        assertEq(imd.balanceOf(intake.PAYEE()), treasuryBefore);
        assertEq(imd.allowance(alice, address(c)), 0.5 ether - 1);
        assertEq(imd.allowance(address(c), address(intake)), 0);

        vm.startPrank(alice);
        imd.approve(address(c), 0.5 ether);
        assertEq(c.requestResolution(id), 2);
        vm.stopPrank();
        assertEq(imd.allowance(alice, address(c)), 0);
        assertEq(c.getMarket(id).budget, 0);
        assertEq(c.totalOracleSpend(), 1.5 ether);
    }

    function test_stakeForFailedPullCannotCreditTheBeneficiary() public {
        uint256 id = _create();
        vm.prank(alice);
        imd.approve(address(c), 5 ether - 1);
        bytes32 before_ = _books(id);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(c), 5 ether - 1, 5 ether)
        );
        c.stakeFor(bob, id, 1, 0, 5 ether, 0);
        assertEq(_books(id), before_);
        assertEq(imd.allowance(alice, address(c)), 5 ether - 1);
    }

    function test_exitSlippageRestoresSetsSharesBasisAndFees() public {
        uint256 id = _create();
        // Opposite conditional positions leave complete sets plus residual maker trades.
        _stake(alice, id, 0, 0, 8 ether);
        _stake(alice, id, 0, 1, 5 ether);
        bytes32 before_ = _books(id);
        vm.prank(alice);
        vm.expectRevert(ConditionalsV2.SlippageExceeded.selector);
        c.exit(id, type(uint256).max);
        assertEq(_books(id), before_);
        vm.prank(alice);
        assertGt(c.exit(id, 0), 0, "the failed exit did not strand the position");
    }

    function test_blockedSellerRetainsPositionAndCostBasis() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 5 ether);
        imd.setBlocked(alice, true);
        bytes32 before_ = _books(id);
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        c.sell(id, 2, 1 ether, 0);
        assertEq(_books(id), before_);
        imd.setBlocked(alice, false);
        vm.prank(alice);
        assertGt(c.sell(id, 2, 1 ether, 0), 0);
    }

    function test_failedFeeWithdrawalKeepsTheDebtCollectible() public {
        uint256 id = _create();
        _stake(alice, id, 0, 0, 5 ether);
        uint256 debt = c.owed(creator);
        assertGt(debt, 0);
        imd.setBlocked(creator, true);
        bytes32 before_ = _books(id);
        vm.prank(creator);
        vm.expectRevert(bytes("blocked"));
        c.withdrawOwed();
        assertEq(_books(id), before_);
        imd.setBlocked(creator, false);
        uint256 balance = imd.balanceOf(creator);
        vm.prank(creator);
        assertEq(c.withdrawOwed(), debt);
        assertEq(imd.balanceOf(creator), balance + debt);
        assertEq(c.owed(creator), 0);
    }

    /// @dev Mutate all 15 signed fields AFTER signing. Several fields have no separate semantic check,
    /// so acceptance would expose an omitted field in the EIP-712 struct hash.
    function test_oracleSignatureBindsEveryAttestationField() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        bytes memory signature = _sign(_attestation(id, refs[0], true), signerKey);
        for (uint256 field; field < 15; ++field) {
            IOracleAttestation.Attestation memory a = _attestation(id, refs[0], true);
            if (field == 0) a.requestId ^= bytes32(uint256(1));
            else if (field == 1) ++a.chainId;
            else if (field == 2) a.questionHash ^= bytes32(uint256(1));
            else if (field == 3) ++a.answerType;
            else if (field == 4) a.answer = abi.encode(false);
            else if (field == 5) ++a.figure;
            else if (field == 6) ++a.fromBlock;
            else if (field == 7) ++a.toBlock;
            else if (field == 8) a.blockHash ^= bytes32(uint256(1));
            else if (field == 9) a.panelJobId ^= bytes32(uint256(1));
            else if (field == 10) ++a.panelSize;
            else if (field == 11) ++a.quorum;
            else if (field == 12) --a.agreed;
            else if (field == 13) ++a.issuedAt;
            else ++a.expiresAt;
            vm.prank(address(intake));
            vm.expectRevert(ConditionalsV2.BadAttestation.selector);
            c.onOracleResult(refs[0].requestId, a, signature);
            assertEq(c.getMarket(id).answers[0], 0);
            assertEq(c.getMarket(id).openAsks[0], 1, "bad answer did not consume the ask");
        }
        assertTrue(_answer(id, refs[0], true), "honest answer remains deliverable within 200,000 gas");
    }

    function test_oracleSignatureCannotCrossConsumerOrChainDomains() public {
        uint256 id = _create();
        AskRef[] memory refs = _request(id);
        IOracleAttestation.Attestation memory a = _attestation(id, refs[0], true);
        ConditionalsV2 other = new ConditionalsV2(owner, imd, intake, signer, builder);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, other.attestationDigest(a));
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.BadAttestation.selector);
        c.onOracleResult(refs[0].requestId, a, abi.encodePacked(r, s, v));

        // A cheatcode read prevents the optimizer treating CHAINID as invariant across vm.chainId.
        uint256 originalChain = vm.getChainId();
        vm.chainId(originalChain + 1);
        bytes memory wrongChainSignature = _sign(a, signerKey);
        vm.chainId(originalChain);
        vm.prank(address(intake));
        vm.expectRevert(ConditionalsV2.BadAttestation.selector);
        c.onOracleResult(refs[0].requestId, a, wrongChainSignature);
        assertTrue(_answer(id, refs[0], true));
    }
}
