// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CONDITIONALS (COND)
/// @notice Fixed-supply, 18-decimal ERC-20 for conditionals.xyz.
/// @dev The immediate deployer receives the entire supply. There are no administrative roles.
contract ConditionalsToken is ERC20 {
    /// @notice One billion tokens expressed in the token's 18-decimal base units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("CONDITIONALS", "COND") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
