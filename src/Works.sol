// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {EmissionsController} from "./EmissionsController.sol";

/// @title Stable.Works Governance Token
/// @author Stable.Works Team
/// @notice Governance token of the Stable.Works protocol.

contract Works is ERC20("Stable.Works Governance Token", "WORKS", 18) {
    
    /// @notice Total supply of WORKS to be distributed.
    uint256 public constant TOTAL_SUPPLY = 70_000 * (10 ** 18);

    /// @notice WORKS Emissions Controller contract.
    EmissionsController public emissionsController;

    /// @notice Emits WORKS supply for emissions.
    function emitSupply() external {
        _mint(address(emissionsController), TOTAL_SUPPLY);
    }

    /// @notice Mints new WORKS tokens.
    /// @param _to Address to mint WORKS to.
    /// @param _amount Amount of WORKS to mint.
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == address(emissionsController), "Only the Controller can call this");
        _mint(_to, _amount);
    }

    /// @notice Sets the WORKS emissions controller contract.
    /// @param _emissionsController Emissions controller contract.
    function setEmissionsController(EmissionsController _emissionsController) external {
        require(address(emissionsController) == address(0), "Controller already set");
        emissionsController = _emissionsController;
    }
}