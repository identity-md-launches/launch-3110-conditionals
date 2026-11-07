// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

/// @dev Drives the token with an open recipient set (fresh addresses, the token itself, the handler)
/// and ghost accounting, including expected rejections, so every invariant is checked against
/// sequences that also contain failed calls.
contract OpenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    ConditionalsToken public immutable token;

    address[] public holders;
    mapping(address => bool) public known;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public okCalls;
    uint256 public rejectedCalls;
    uint256 public ghostMoved;

    constructor(ConditionalsToken token_, address initialHolder) {
        token = token_;
        _track(initialHolder);
        _track(address(token_));
        _track(address(this));
        ghostBalance[initialHolder] = SUPPLY;
    }

    function holdersLength() external view returns (uint256) {
        return holders.length;
    }

    function _track(address a) internal {
        if (!known[a]) {
            known[a] = true;
            holders.push(a);
        }
    }

    function _pick(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    /// @dev Either an existing holder or a brand-new address derived from the seed.
    function _pickOrNew(uint256 seed, bool fresh) internal returns (address a) {
        if (fresh && holders.length < 24) {
            a = address(uint160(uint256(keccak256(abi.encode("fresh", seed)))));
            _track(a);
        } else {
            a = _pick(seed);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount, bool fresh, bool overspend) external {
        address from = _pick(fromSeed);
        address to = _pickOrNew(toSeed, fresh);
        uint256 bal = ghostBalance[from];
        amount = overspend ? bound(amount, bal + 1, SUPPLY + 1) : bound(amount, 0, bal);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertEq(ok, !overspend, "transfer outcome");
        if (ok) {
            assertTrue(abi.decode(ret, (bool)));
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostMoved += amount;
            ++okCalls;
        } else {
            ++rejectedCalls;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _pick(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to zero accepted");
        ++rejectedCalls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool fresh) external {
        address owner = _pick(ownerSeed);
        address spender = _pickOrNew(spenderSeed, fresh);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        ++okCalls;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount, uint8 mode) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 bal = ghostBalance[owner];
        mode = mode % 3;
        if (mode == 0) {
            amount = bound(amount, 0, allowed < bal ? allowed : bal);
        } else if (mode == 1) {
            if (allowed >= SUPPLY + 1) return;
            amount = bound(amount, allowed + 1, SUPPLY + 1);
        } else {
            amount = bound(amount, bal + 1, SUPPLY + 1);
        }
        bool expectOk = amount <= allowed && amount <= bal;
        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertEq(ok, expectOk, "transferFrom outcome");
        if (ok) {
            assertTrue(abi.decode(ret, (bool)));
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ghostMoved += amount;
            ++okCalls;
        } else {
            ++rejectedCalls;
        }
    }

    function tryPrivileged(uint256 callerSeed, uint8 which, uint256 amount) external {
        address caller = _pick(callerSeed);
        bytes memory data;
        which = which % 4;
        if (which == 0) data = abi.encodeWithSignature("mint(address,uint256)", caller, amount);
        else if (which == 1) data = abi.encodeWithSignature("burn(uint256)", amount);
        else if (which == 2) data = abi.encodeWithSignature("burnFrom(address,uint256)", _pick(amount), amount);
        else data = abi.encodeWithSignature("pause()");
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "privileged call accepted");
        ++rejectedCalls;
    }
}

contract ConditionalsTokenOpenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    ConditionalsToken internal token;
    OpenHandler internal handler;
    address internal deployer = makeAddr("openDeployer");

    function setUp() public {
        vm.prank(deployer);
        token = new ConditionalsToken();
        handler = new OpenHandler(token, deployer);
        targetContract(address(handler));
        excludeSender(address(token));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_fixedSupplyAndConservation() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        uint256 n = handler.holdersLength();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address h = handler.holders(i);
            uint256 bal = token.balanceOf(h);
            assertEq(bal, handler.ghostBalance(h), "balance differs from ghost");
            sum += bal;
        }
        assertEq(sum, SUPPLY, "sum of balances differs from supply");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.holdersLength();
        for (uint256 i; i < n; ++i) {
            address o = handler.holders(i);
            for (uint256 j; j < n; ++j) {
                address s = handler.holders(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s), "allowance differs from ghost");
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }
}
