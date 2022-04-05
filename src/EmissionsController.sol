// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @title Stable.Works Emissions Controller
/// @author Stable.Works Core Team
/// @notice Emissions controller/WORKS farming contract.

contract EmissionsController {
    using SafeTransferLib for IERC20;
    
    /// @notice Info for each user on each forge.
    struct UserForgeInfo {
        uint256 stk;    // Amount of tokens staked by the user in the Forge.
        uint256 rwrd;   // Amount of tokens endebted to the user in the Forge.
    }

    /// @notice Data structure for pools. We track rewards via a `Forge`.
    /// @dev This struct should be packed efficiently to use less storage and reduce cost.
    /// To structure the Forge properly, place smaller vars first, larger last. 
    struct Forge {
        uint64 nLastDist;   // Timestamp of the last distribution of WORKS.
        uint128 worksRate;  // WORKS tokens distributed per second.
        IERC20 stkToken;    // Token staked into the Forge.
        uint256 poolWorksPerShare;   // Amount of WORKS per share of the Forge. This is used for tracking earnings.
    }

    /// @notice WORKS token to distribute as a farming incentive.
    IERC20 public works;

    /// @notice Forges supported by the emissions controller.
    Forge[] public forges;

    /// @notice Forge ID for a specific token.
    mapping(IERC20 => uint256) public fidForToken;

    /// @notice User info for each Forge.
    mapping(uint256 => mapping(address => UserForgeInfo)) public userForgeInfo;

    /// @notice Emitted on a new deposit into a Forge.
    event ForgeDeposit(uint256 indexed fid, uint256 amount);

    /// @notice Emitted on withdrawal from the Forge.
    event ForgeWithdrawal(uint256 indexed fid, uint256 amount);

    /// @notice Deposits into a Forge contract.
    /// @param _fid ID of the Forge to deposit into.
    /// @param _amount Amount of tokens to deposit into the Forge.
    function deposit(uint256 _fid, uint256 _amount) external {
        _updateForge(_fid);
        Forge memory _forge = forges[_fid];
        UserForgeInfo memory _forgeUser = userForgeInfo[_fid][msg.sender];

        // Update user state data and claim any pending rewards.
        _forgeUser.stk = _amount;
        if(_forgeUser.stk > 0) {
            uint256 pendingRwrd = ((_forgeUser.stk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd;
            works.safeTransfer(msg.sender, pendingRwrd);
        }
        _forgeUser.rwrd = (_forgeUser.stk * _forge.poolWorksPerShare) / 1e12;
        delete userForgeInfo[_fid][msg.sender];
        userForgeInfo[_fid][msg.sender] = _forgeUser;

        _forge.stkToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit ForgeDeposit(_fid, _amount);
    }

    /// @notice Withdraws from the Forge contract.
    /// @param _fid Forge ID to withdraw from.
    /// @param _amount Amount of tokens to withdraw from the Forge.
    function withdraw(uint256 _fid, uint256 _amount) external {
        _updateForge(_fid);
        Forge memory _forge = forges[_fid];
        UserForgeInfo memory _forgeUser = userForgeInfo[_fid][msg.sender];

        require(_forgeUser.stk >= _amount, "Cannot withdraw over deposit amount");
        uint256 pendingRwrd = ((_forgeUser.stk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd;
        works.safeTransfer(msg.sender, pendingRwrd);
        _forgeUser.stk -= _amount;
        _forgeUser.rwrd = (_forgeUser.stk * _forge.poolWorksPerShare) / 1e12;
        delete userForgeInfo[_fid][msg.sender];
        userForgeInfo[_fid][msg.sender] = _forgeUser;

        _forge.stkToken.safeTransfer(msg.sender, _amount);
        emit ForgeWithdrawal(_fid, _amount);
    }

    /// @notice Updates reward data for all forges.
    function updateForges() public {
        uint256 _forges = forges.length;
        for(uint256 i = 0; i < _forges; i++) {
            _updateForge(i);
        }
    }

    function _updateForge(uint256 _fid) internal {
        // WARNING WARNING:
        // THIS FUNCTION CAN EASILY CAUSE YOU TO SHOOT YOURSELF IN THE FOOT
        // AND LEAD TO AN EXPLOIT IN THE CONTRACT. TO MITIGATE THIS, CALL THIS FUNCTION
        // BEFORE YOU READ **ANY** POOLS TO MEMORY, OR ELSE THE CONTRACT **WILL** GET EXPLOITED.
        Forge memory _forge = forges[_fid];
        if(_forge.nLastDist <= block.timestamp) {
            return;
        }

        uint256 nStk = _forge.stkToken.balanceOf(address(this));
        if(nStk == 0) {
            _forge.nLastDist = uint64(block.timestamp);
            delete forges[_fid];
            forges[_fid] = _forge;
        }
        uint256 nRwrd = (_forge.nLastDist - block.timestamp) * _forge.worksRate;
        _forge.nLastDist = uint64(block.timestamp);
        _forge.poolWorksPerShare += (nRwrd * 1e12) / nStk;

        // Overwrite memory to storage. As aforementioned, this function should be executed BEFORE
        // so that reward variable updates are written to memory and not the storage beforehand.
        delete forges[_fid];
        forges[_fid] = _forge;
    }
}