// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConditionalsV2} from "../src/ConditionalsV2.sol";
import {ConditionalsZap} from "../src/ConditionalsZap.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

/// @dev Stands in for the launch factory: deploys every application by CREATE2 in one call, so each constructor runs
///      with the factory as `msg.sender` and nothing else on the chain.
contract LaunchProbe {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
        }
    }
}

/// @dev Rehearses the `evm_contracts` launch as its floor does: both contracts deployed from their init code by a
///      factory on an empty chain with id 4663 and the brief's constructor arguments, in the brief's order, with the
///      zap pointing at the ConditionalsV2 deployed just before it. No RPC: the IMD, Intake, PoolManager and USDG
///      addresses have no code here, which is why neither constructor may call them.
contract ConditionalsV2LaunchTest is Test {
    address constant OWNER = 0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant FEE_RECIPIENT = 0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    LaunchProbe factory;
    ConditionalsV2 c;
    ConditionalsZap zap;

    function setUp() public {
        vm.chainId(4663);
        factory = new LaunchProbe();
        assertEq(IMD.code.length, 0, "the rehearsal chain is empty");
        assertEq(INTAKE.code.length, 0);
        assertEq(POOL_MANAGER.code.length, 0);

        bytes32 salt0 = keccak256("ConditionalsV2");
        bytes32 salt1 = keccak256("ConditionalsZap");
        bytes memory code0 =
            abi.encodePacked(type(ConditionalsV2).creationCode, abi.encode(OWNER, IMD, INTAKE, SIGNER, FEE_RECIPIENT));
        address predicted0 = vm.computeCreate2Address(salt0, keccak256(code0), address(factory));
        // $contract:ConditionalsV2 resolves to the address of the contract deployed before the zap.
        bytes memory code1 =
            abi.encodePacked(type(ConditionalsZap).creationCode, abi.encode(predicted0, POOL_MANAGER, IMD, USDG));

        bytes[] memory codes = new bytes[](2);
        bytes32[] memory salts = new bytes32[](2);
        (codes[0], codes[1], salts[0], salts[1]) = (code0, code1, salt0, salt1);
        address[] memory deployed = factory.deployAll(codes, salts);
        assertEq(deployed[0], predicted0);
        c = ConditionalsV2(deployed[0]);
        zap = ConditionalsZap(deployed[1]);
    }

    function test_launch_constructorsConfigureEverything() public view {
        assertEq(block.chainid, 4663);
        assertEq(c.owner(), OWNER, "the owner is $owner, not the factory");
        assertTrue(c.owner() != address(factory));
        assertEq(c.pendingOwner(), address(0));
        assertEq(address(c.imd()), IMD);
        assertEq(c.feeRecipient(), FEE_RECIPIENT);
        (IIntake intake, address signer, uint128 price, uint16 panel, uint16 quorum, bytes32 action) = c.oracleConfig();
        assertEq(address(intake), INTAKE);
        assertEq(signer, SIGNER);
        assertEq(price, 0.5 ether);
        assertEq(panel, 5);
        assertEq(quorum, 4);
        assertEq(action, bytes32("oracle.request@oracle-1"));
        assertEq(c.pendingOracleConfigAt(), 0);
        assertEq(c.marketCount(), 0);

        assertEq(address(zap.conditionals()), address(c));
        assertEq(address(zap.poolManager()), POOL_MANAGER);
        assertEq(address(zap.imd()), IMD);
        assertEq(address(zap.usdg()), USDG);
    }

    function test_launch_callbackSelectorsAreTheProtocolOnes() public pure {
        assertEq(ConditionalsV2.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(ConditionalsV2.onFailure.selector, bytes4(0x5a0df71e));
    }

    /// @dev EIP-170 and the floor's opcode scan: no DELEGATECALL, CALLCODE or SELFDESTRUCT reachable in either runtime.
    function test_launch_runtimesFitAndHaveNoEscapeOpcodes() public view {
        address[2] memory apps = [address(c), address(zap)];
        for (uint256 i; i < 2; ++i) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
                if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                    reachable = false;
                }
            }
        }
    }

    /// @dev The zap has no owner and keeps nothing: there is no function that could move what it does not hold.
    function test_launch_zapHasNoOwnerAndHoldsNothing() public {
        assertEq(address(zap).balance, 0);
        (bool ok,) = address(zap).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner() on the zap");
        vm.expectRevert(ConditionalsZap.NotPoolManager.selector);
        zap.unlockCallback("");
    }

    /// @dev A deposit of a zero address is refused in both constructors, so a mis-filled manifest cannot deploy.
    function test_launch_constructorsRefuseZeroAddresses() public {
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(OWNER, IERC20(address(0)), IIntake(INTAKE), SIGNER, FEE_RECIPIENT);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(OWNER, IERC20(IMD), IIntake(INTAKE), SIGNER, address(0));
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(OWNER, IERC20(IMD), IIntake(address(0)), SIGNER, FEE_RECIPIENT);
        vm.expectRevert(ConditionalsV2.ZeroAddress.selector);
        new ConditionalsV2(OWNER, IERC20(IMD), IIntake(INTAKE), address(0), FEE_RECIPIENT);
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(ConditionalsV2(address(0)), IPoolManager(POOL_MANAGER), IERC20(IMD), IERC20(USDG));
        vm.expectRevert(ConditionalsZap.ZeroAddress.selector);
        new ConditionalsZap(c, IPoolManager(address(0)), IERC20(IMD), IERC20(USDG));
    }
}
