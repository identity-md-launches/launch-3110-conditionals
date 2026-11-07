// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

/// @dev Independent balance/allowance model driven by successful and rejected ERC-20 operations.
contract TokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    ConditionalsToken internal immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(ConditionalsToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, bool valid) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, valid ? expectedBalance[from] : SUPPLY + 1);
        bool expectedSuccess = amount <= expectedBalance[from];
        vm.prank(from);
        (bool success, bytes memory result) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        assertEq(success, expectedSuccess, "transfer success differs from model");
        if (success) {
            assertTrue(abi.decode(result, (bool)));
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = unlimited ? type(uint256).max : bound(rawAmount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount, bool valid)
        external
    {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowanceBefore = expectedAllowance[owner][spender];
        uint256 balanceBefore = expectedBalance[owner];
        uint256 limit = balanceBefore < allowanceBefore ? balanceBefore : allowanceBefore;
        uint256 amount = bound(rawAmount, 0, valid ? limit : SUPPLY + 1);
        bool expectedSuccess = amount <= allowanceBefore && amount <= balanceBefore;
        vm.prank(spender);
        (bool success, bytes memory result) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, owner, to, amount));
        assertEq(success, expectedSuccess, "transferFrom success differs from model");
        if (success) {
            assertTrue(abi.decode(result, (bool)));
            expectedBalance[owner] -= amount;
            expectedBalance[to] += amount;
            if (allowanceBefore != type(uint256).max) {
                expectedAllowance[owner][spender] = allowanceBefore - amount;
            }
        }
    }
}

contract ConditionalsTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    ConditionalsToken internal token;
    TokenHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2"), makeAddr("actor3")];
        token = new ConditionalsToken();
        token.transfer(actors[0], SUPPLY);
        handler = new TokenHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSupplyBalancesAndAllowancesMatchModel() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 balance = token.balanceOf(actor);
            sum += balance;
            assertEq(balance, handler.expectedBalance(actor), "balance differs from model");
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actor, actors[j]),
                    handler.expectedAllowance(actor, actors[j]),
                    "allowance differs from model"
                );
            }
        }
        assertEq(sum, SUPPLY, "tokens lost or created");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
