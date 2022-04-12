// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @title Wrapped STABLE
/// @author Stable.Works Core Team
/// @notice A rebase-safe wrapper for STABLE.

contract wStable is ERC20("Wrapped STABLE", "wSTABLE", 18) {
    using SafeTransferLib for IERC20;

    /// @notice STABLE token.
    IERC20 public stable;

    constructor(IERC20 _stable) {
        stable = _stable;
    }

    /// @notice Wraps tokens into the wrapper.
    /// @param _amount Amount of tokens to wrap.
    function wrap(uint256 _amount) external {
        uint256 balance = stable.balanceOf(address(this));
        uint256 wrapperSupply = totalSupply;

        if(balance == 0 || wrapperSupply == 0) {
            _mint(msg.sender, _amount);
        } else {
            uint256 toMint = (_amount * wrapperSupply) / balance;
            _mint(msg.sender, toMint);
        }

        stable.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Unwraps tokens from the wrapper.
    /// @param _amount Amount of tokens to unwrap.
    function unwrap(uint256 _amount) external {
        uint256 toSend = (_amount * stable.balanceOf(address(this))) / totalSupply;
        _burn(msg.sender, _amount);
        stable.safeTransfer(msg.sender, toSend);
    }

    /// @notice Calculates the ratio of the wrapper token.
    /// @return How much of `wrappedToken` one wrapper token is worth.
    function ratio() external view returns (int256) {
        return int256(stable.balanceOf(address(this)) / totalSupply);
    }
}