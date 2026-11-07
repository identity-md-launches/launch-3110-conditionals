// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

/// @dev Models the launch factory: deploys the token and performs the launch distribution inside one
/// call (one transaction), checking supply and custody as it goes.
contract OneCallLauncher {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    function launch(bytes32 salt, address distributor, address poolManager, address remainderTo, uint256 poolBps)
        external
        returns (ConditionalsToken token, uint256 swarm, uint256 pool, uint256 rest)
    {
        token = new ConditionalsToken{salt: salt}();
        require(token.totalSupply() == SUPPLY, "supply");
        require(token.balanceOf(address(this)) == SUPPLY, "custody");
        swarm = SUPPLY * 1_000 / 10_000;
        pool = SUPPLY * poolBps / 10_000;
        rest = SUPPLY - swarm - pool;
        require(token.transfer(distributor, swarm), "swarm");
        require(token.balanceOf(distributor) == swarm, "swarm short");
        if (pool > 0) {
            require(token.transfer(poolManager, pool), "pool");
            require(token.balanceOf(poolManager) == pool, "pool short");
        }
        if (rest > 0) {
            require(token.transfer(remainderTo, rest), "rest");
            require(token.balanceOf(remainderTo) == rest, "rest short");
        }
        require(token.balanceOf(address(this)) == 0, "factory kept tokens");
    }
}

contract ConditionalsTokenLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    ConditionalsToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new ConditionalsToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 256
    function testFuzzSupplyGoesToImmediateDeployerNotOrigin(address who, address origin) public {
        vm.assume(who != address(0) && who.code.length == 0);
        assumeNotPrecompile(who);
        assumeNotForgeAddress(who);
        vm.prank(who, origin);
        ConditionalsToken fresh = new ConditionalsToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(who), SUPPLY);
        if (origin != who) assertEq(fresh.balanceOf(origin), 0);
    }

    function testSupplyConstantIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.totalSupply(), 10 ** 9 * 10 ** uint256(token.decimals()));
    }

    function testTwoDeploymentsAreIndependent() public {
        vm.prank(alice);
        ConditionalsToken second = new ConditionalsToken();
        vm.prank(deployer);
        token.transfer(bob, 1);
        assertEq(second.balanceOf(bob), 0);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testSameSaltCannotBeRedeployed() public {
        OneCallLauncher launcher = new OneCallLauncher();
        launcher.launch(bytes32(uint256(7)), alice, bob, deployer, 5_000);
        vm.expectRevert();
        launcher.launch(bytes32(uint256(7)), alice, bob, deployer, 5_000);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzOneTransactionLaunchFlowsAreExact(uint256 poolBps, bytes32 salt) public {
        poolBps = bound(poolBps, 0, 9_000);
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainderTo = makeAddr("remainderTo");
        OneCallLauncher launcher = new OneCallLauncher();
        (ConditionalsToken launched, uint256 swarm, uint256 pool, uint256 rest) =
            launcher.launch(salt, distributor, poolManager, remainderTo, poolBps);
        assertEq(swarm + pool + rest, SUPPLY);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.balanceOf(remainderTo), rest);
        assertEq(launched.totalSupply(), SUPPLY);

        // A claim out of the distributor arrives whole.
        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(distributor), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Bytecode and privileged surface
    // ---------------------------------------------------------------------------------------------

    function testRuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function testNoSupplyIncreasingOrFreezingCallFromDeployerOrStranger() public {
        address attacker = makeAddr("attacker");
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        string[16] memory sigs = [
            "mint(address,uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "unpause()",
            "blocklist(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "renounceOwnership()",
            "grantRole(bytes32,address)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "upgradeToAndCall(address,bytes)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            bytes memory data = abi.encodeWithSignature(sigs[i], attacker, type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, sigs[i]);
            vm.prank(attacker);
            (ok,) = address(token).call(data);
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.allowance(alice, attacker), 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000e18));
    }

    function testTransferAndApproveReturnExactlyOneWordTrue() public {
        vm.prank(deployer);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        vm.prank(alice);
        (ok, ret) = address(token).call(abi.encodeCall(token.approve, (bob, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        vm.prank(bob);
        (ok, ret) = address(token).call(abi.encodeCall(token.transferFrom, (alice, bob, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function testTruncatedCalldataReverts() public {
        // transfer(address,uint256) selector with a missing amount word.
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(token.transfer.selector, bytes32(uint256(uint160(alice)))));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testDirtyAddressUpperBitsRejected() public {
        bytes memory data = abi.encodePacked(
            token.transfer.selector, bytes32(uint256(uint160(alice)) | (uint256(1) << 200)), uint256(1)
        );
        vm.prank(deployer);
        (bool ok,) = address(token).call(data);
        assertFalse(ok);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Edge cases around holders and allowances
    // ---------------------------------------------------------------------------------------------

    function testTokensSentToTokenAddressAreNotRecoverableByDeployer() public {
        vm.prank(deployer);
        token.transfer(address(token), 5e18);
        assertEq(token.balanceOf(address(token)), 5e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 5e18));
        token.transferFrom(address(token), deployer, 5e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testOneWeiShortOfBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100, 101));
        token.transfer(bob, 101);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100);
    }

    function testAllowanceOneBelowMaxIsDecremented() public {
        uint256 nearMax = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, nearMax);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), nearMax - 1);
    }

    function testSpentAllowanceCannotBeReused() public {
        vm.prank(deployer);
        token.approve(alice, 5);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 5);
    }

    function testSelfApprovalIsSeparateFromBalance() public {
        vm.startPrank(deployer);
        token.approve(deployer, 3);
        assertTrue(token.transferFrom(deployer, alice, 3));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 3);
    }

    function testAllowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 10));
        token.transferFrom(deployer, bob, 10);
        assertEq(token.allowance(deployer, alice), 10);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzTransferBetweenAnyHolders(address from, address to, uint256 seedAmount, uint256 amount) public {
        vm.assume(from != address(0) && to != address(0) && from != deployer);
        assumeNotForgeAddress(from);
        seedAmount = bound(seedAmount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(from, seedAmount);
        amount = bound(amount, 0, seedAmount + 1);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        if (amount > fromBefore) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, fromBefore, amount)
            );
            token.transfer(to, amount);
            assertEq(token.balanceOf(from), fromBefore);
            assertEq(token.balanceOf(to), toBefore);
        } else {
            assertTrue(token.transfer(to, amount));
            if (from == to) {
                assertEq(token.balanceOf(from), fromBefore);
            } else {
                assertEq(token.balanceOf(from), fromBefore - amount);
                assertEq(token.balanceOf(to), toBefore + amount);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzApproveOverwritesRegardlessOfPrevious(address owner, address spender, uint256 a, uint256 b)
        public
    {
        vm.assume(owner != address(0) && spender != address(0));
        vm.startPrank(owner);
        token.approve(spender, a);
        assertEq(token.allowance(owner, spender), a);
        token.approve(spender, b);
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), b);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzTransferFromBalanceOrAllowanceShortReverts(uint256 bal, uint256 allowed, uint256 amount) public {
        bal = bound(bal, 0, SUPPLY);
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, bal);
        vm.prank(alice);
        token.approve(bob, allowed);
        bool expectOk = amount <= allowed && amount <= bal;
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount)
            );
        } else if (amount > bal) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, bal, amount));
        }
        vm.prank(bob);
        bool ok = token.transferFrom(alice, deployer, amount);
        if (expectOk) {
            assertTrue(ok);
            assertEq(token.balanceOf(alice), bal - amount);
            assertEq(token.allowance(alice, bob), allowed - amount);
        } else {
            assertEq(token.balanceOf(alice), bal);
            assertEq(token.allowance(alice, bob), allowed);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
