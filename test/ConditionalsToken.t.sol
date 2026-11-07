// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

/// @dev Test-only factory to exercise the same immediate-deployer semantics as a launch factory.
contract TokenFactoryHarness {
    function deploy(bytes32 salt) external returns (ConditionalsToken) {
        return new ConditionalsToken{salt: salt}();
    }

    function move(ConditionalsToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev Any unexpected token callback would make the transfer fail.
contract RejectingReceiver {
    fallback() external {
        revert("unexpected callback");
    }
}

contract ConditionalsTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    ConditionalsToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new ConditionalsToken();
    }

    function testMetadataAndEntireSupplyAtDeployment() public view {
        assertEq(token.name(), "CONDITIONALS");
        assertEq(token.symbol(), "COND");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function testConstructorEmitsSingleMintEvent() public {
        vm.recordLogs();
        vm.prank(deployer);
        ConditionalsToken fresh = new ConditionalsToken();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].emitter, address(fresh));
        assertEq(entries[0].topics.length, 3);
        assertEq(entries[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(entries[0].topics[1], bytes32(0));
        assertEq(entries[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(entries[0].data, (uint256)), SUPPLY);
    }

    function testCreate2MintsToFactoryAndLaunchTransfersAreExact() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        vm.prank(deployer, deployer);
        ConditionalsToken launched = factory.deploy(keccak256("launch"));
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(deployer), 0);

        // These test actors model token movements, not a live pool or distributor implementation.
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainder = makeAddr("remainder");
        uint256 swarmAmount = SUPPLY / 10;
        uint256 poolAmount = SUPPLY * 7 / 10;
        uint256 remainderAmount = SUPPLY * 2 / 10;
        assertTrue(factory.move(launched, distributor, swarmAmount));
        assertTrue(factory.move(launched, poolManager, poolAmount));
        assertTrue(factory.move(launched, remainder, remainderAmount));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarmAmount);
        assertEq(launched.balanceOf(poolManager), poolAmount);
        assertEq(launched.balanceOf(remainder), remainderAmount);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarmAmount));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), swarmAmount);
        vm.prank(poolManager);
        assertTrue(launched.transfer(bob, 1_000e18));
        assertEq(launched.balanceOf(bob), 1_000e18);
        vm.prank(bob);
        assertTrue(launched.transfer(poolManager, 1_000e18));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(poolManager), poolAmount);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testTransferEmitsEventAndDeliversExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 15e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 15e18));
        assertEq(token.balanceOf(deployer), SUPPLY - 15e18);
        assertEq(token.balanceOf(alice), 15e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferEntireBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function testZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function testSelfTransferPreservesBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferDoesNotCallRecipient() public {
        RejectingReceiver recipient = new RejectingReceiver();
        vm.prank(deployer);
        assertTrue(token.transfer(address(recipient), 1e18));
        assertEq(token.balanceOf(address(recipient)), 1e18);
    }

    function testTransferToZeroRevertsEvenForZeroAmount() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferWithInsufficientBalanceRevertsWithoutMutation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testMaximumTransferRevertsWithoutOverflow() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testApproveEmitsEventAndCanBeReplacedAndRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 10e18);
        vm.startPrank(deployer);
        assertTrue(token.approve(spender, 10e18));
        assertEq(token.allowance(deployer, spender), 10e18);
        assertTrue(token.approve(spender, 3e18));
        assertEq(token.allowance(deployer, spender), 3e18);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testApprovalBelongsOnlyToCallerAndDoesNotMoveTokens() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    function testTransferFromDecrementsFiniteAllowanceAndEmitsTransfer() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 4e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 4e18));
        assertEq(token.allowance(deployer, spender), 6e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 4e18);
        assertEq(token.balanceOf(alice), 4e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 6e18));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(alice), 10e18);
    }

    function testInfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function testTransferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function testTransferFromToSelfConsumesAllowanceButPreservesBalance() public {
        vm.prank(deployer);
        token.approve(spender, 12e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 12e18));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testTransferFromByHolderStillRequiresAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testTransferFromInsufficientAllowanceRevertsWithoutMutation() public {
        vm.prank(deployer);
        token.approve(spender, 9);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 9, 10));
        token.transferFrom(deployer, alice, 10);
        assertEq(token.allowance(deployer, spender), 9);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testTransferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10e18));
        token.transferFrom(alice, bob, 10e18);
        assertEq(token.allowance(alice, spender), 10e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function testTransferFromToZeroRollsBackAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 10e18);
        assertEq(token.allowance(deployer, spender), 10e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromZeroSenderReverts() public {
        vm.prank(spender);
        // OpenZeppelin validates the allowance owner before attempting the transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function testDeployerCannotSeizeHolderTokensWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 100e18));
        token.transferFrom(alice, deployer, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));
        assertEq(token.balanceOf(bob), 100e18);
    }

    function testNoMintBurnAdminOrUpgradeEntryPoints() public {
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1e18);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1e18);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1e18);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1e18);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[10] = abi.encodeWithSignature("setMinter(address)", alice);
        calls[11] = abi.encodeWithSignature("initialize(address)", alice);
        calls[12] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[13] = abi.encodeWithSignature("owner()");
        calls[14] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        vm.prank(deployer);
        token.transfer(alice, 2e18);
        for (uint256 i; i < calls.length; ++i) {
            _assertUnsupported(deployer, calls[i]);
            _assertUnsupported(bob, calls[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 2e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 2e18));
    }

    function testRejectsNativeEtherAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(token).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(address(token).balance, 0);
        _assertUnsupported(alice, hex"ffffffff");
    }

    function testFuzzTransferConservesSupply(uint256 amount, address recipient) public {
        vm.assume(recipient != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        if (recipient == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
            assertEq(token.balanceOf(recipient), amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzTransferFromTracksAllowance(uint256 approved, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        approved = bound(approved, amount, type(uint256).max);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzOverspendReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzzInsufficientAllowanceReverts(uint256 approved, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        approved = bound(approved, 0, amount - 1);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), approved);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function _assertUnsupported(address caller, bytes memory data) internal {
        vm.prank(caller);
        (bool success,) = address(token).call(data);
        assertFalse(success);
    }
}
