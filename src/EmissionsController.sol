// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
        uint256 derivStk; // Derived stake amount for the user. Used for boost math.
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

    /// @notice How long WORKS supply will be distributed for.
    uint256 public constant WORKS_DISTRIBUTION_DURATION = 52.17 weeks; // A full year.

    /// @notice WORKS token to distribute as a farming incentive.
    IERC20 public works;

    /// @notice veWORKS token for calculating boosts.
    IERC20 public veWorks;

    /// @notice The time when WORKS emissions start.
    uint256 public tRewardStart;

    /// @notice The time when WORKS emissions end.
    uint256 public tRewardEnd;

    /// @notice Forges supported by the emissions controller.
    Forge[] public forges;

    /// @notice The rate at which WORKS are emitted at per second.
    uint256 public worksEmissionRate;

    /// @notice Total weight of the Forges.
    uint256 public totalForgeWeight;

    /// @notice Forge ID for a specific token.
    mapping(IERC20 => uint256) public fidForToken;

    /// @notice User info for each Forge.
    mapping(uint256 => mapping(address => UserForgeInfo)) public userForgeInfo;

    /// @notice Reward weights for each Forge.
    mapping(uint256 => uint256) public weightForForge;

    /// @notice Reward weight reserved for each Forge.
    mapping(uint256 => uint256) public reservedWeightForForge;

    /// @notice Votes by a user for a specific Forge.
    mapping(address => mapping(uint256 => uint256)) public userForgeVotes;

    /// @notice Forges voted for by a user.
    mapping(address => uint256[]) public userVotedForges;

    /// @notice Voting weights used by a user.
    mapping(address => uint256) public userUsedForgeWeights;

    /// @notice Emitted on a new deposit into a Forge.
    event ForgeDeposit(uint256 indexed fid, uint256 amount);

    /// @notice Emitted on withdrawal from the Forge.
    event ForgeWithdrawal(uint256 indexed fid, uint256 amount);

    /// @notice Distributes WORKS supply and starts emissions.
    /// @param _supply Supply to emit.
    function kickstartMyHeart(uint256 _supply) external {
        require(tRewardStart == 0, "Rewards already started");
        works.safeTransferFrom(msg.sender, address(this), _supply);
        tRewardStart = block.timestamp;
        tRewardEnd = block.timestamp + WORKS_DISTRIBUTION_DURATION;
        worksEmissionRate = _supply / WORKS_DISTRIBUTION_DURATION;
    }

    /// @notice Votes on forge weights on the EmissionsController
    /// @param _fids Forge IDs to vote on the weights of.
    /// @param _weights Weights of each forge in `_fids`.
    function vote(uint256[] calldata _fids, uint256[] calldata _weights) external {
        require(_weights.length == _fids.length, "Lengths do not match");
        _vote(msg.sender, _fids, _weights);
    }

    /// @notice Rebalances the weights of Forges based on their current votes.
    function cast() external {
        if(totalForgeWeight > 0) {
            updateForges(); // Needed, or else rewards will be lost.
            Forge[] storage _forges = forges;
            for(uint256 i; i < _forges.length; i++) {
                _forges[i].worksRate = uint128((worksEmissionRate * weightForForge[i]) / totalForgeWeight);
            }
        }
    }

    /// @notice Resets a user's votes.
    function reset() external {
        _reset(msg.sender);
    }

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
            works.safeTransfer(msg.sender, ((_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd);
        }
        _forgeUser.rwrd = (_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12;
        delete userForgeInfo[_fid][msg.sender];
        userForgeInfo[_fid][msg.sender] = _forgeUser;

        _forge.stkToken.safeTransferFrom(msg.sender, address(this), _amount);
        _updateDerivedBalanceForUser(_fid, msg.sender);
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
        uint256 pendingRwrd = ((_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd;
        works.safeTransfer(msg.sender, pendingRwrd);

        _forgeUser.stk -= _amount;
        _forgeUser.rwrd = (_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12;
        delete userForgeInfo[_fid][msg.sender];
        userForgeInfo[_fid][msg.sender] = _forgeUser;

        _forge.stkToken.safeTransfer(msg.sender, _amount);
        _updateDerivedBalanceForUser(_fid, msg.sender);
        emit ForgeWithdrawal(_fid, _amount);
    }

    /// @notice Claims WORKS rewards from a Forge.
    /// @param _fid Forge ID to claim rewards from.
    function claim(uint256 _fid) external {
        _updateForge(_fid);
        Forge memory _forge = forges[_fid];
        UserForgeInfo memory _forgeUser = userForgeInfo[_fid][msg.sender];

        // Claim and update derived balance.
        if(_forgeUser.stk > 0) {
            works.safeTransfer(msg.sender, ((_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd);
        }
        _forgeUser.rwrd = (_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12;
        _updateDerivedBalanceForUser(_fid, msg.sender);
    }

    /// @notice Claims from multiple forges.
    /// @param _fids Forge IDs to claim from.
    function claimForForges(uint256[] calldata _fids) external {
        for(uint256 i; i < _fids.length; i++) {
            uint256 _fid = _fids[i];
            _updateForge(_fid);
            Forge memory _forge = forges[_fid];
            UserForgeInfo memory _forgeUser = userForgeInfo[_fid][msg.sender];

            // Claim and update derived balance.
            if(_forgeUser.stk > 0) {
                works.safeTransfer(msg.sender, ((_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12) - _forgeUser.rwrd);
            }
            _forgeUser.rwrd = (_forgeUser.derivStk * _forge.poolWorksPerShare) / 1e12;
            _updateDerivedBalanceForUser(_fid, msg.sender);
        }
    }

    /// @notice Updates reward data for all forges.
    function updateForges() public {
        uint256 _forges = forges.length;
        for(uint256 i; i < _forges; i++) {
            _updateForge(i);
        }
    }

    /// @notice Adds a new Forge to the EmissionsController.
    /// @param _stk Token to stake in the pool.
    /// @param _nReserveWeight Weight reserved for the Forge. Used to bootstrap the initial reward.
    /// @param _updateForges Whether or not to update all of the reward variables for the forges.
    function addForge(IERC20 _stk, uint256 _nReserveWeight, bool _updateForges) public {
        // Update the forges if we have to.
        if(_updateForges) {
            updateForges();
        }

        // Push a new forge with the token.
        require(fidForToken[_stk] == 0, "Pool already exists");
        forges.push(Forge({
            nLastDist: uint64(block.timestamp),
            worksRate: 0,
            stkToken: _stk,
            poolWorksPerShare: 0
        }));
        uint256 _fid = forges.length - 1;
        fidForToken[_stk] = _fid;

        // Add reserved weight.
        weightForForge[_fid] = _nReserveWeight;
        reservedWeightForForge[_fid] = _nReserveWeight;
        totalForgeWeight += _nReserveWeight;
    }

    /// @notice Removes the reserved weight for a specific Forge.
    /// @param _fid Forge ID to remove the reserved weight of.
    /// @param _updateForges Whether or not to update the reward variables of all forges.
    function removeReservedWeight(uint256 _fid, bool _updateForges) public {
        // Update if we have to.
        if(_updateForges) {
            updateForges();
        }

        // Remove reserved weights.
        uint256 reserved = reservedWeightForForge[_fid];
        weightForForge[_fid] -= reserved;
        totalForgeWeight -= reserved;

        reservedWeightForForge[_fid] = 0;
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
        uint256 nRwrd = (block.timestamp - _forge.nLastDist) * _forge.worksRate;
        _forge.nLastDist = uint64(block.timestamp);
        _forge.poolWorksPerShare += (nRwrd * 1e12) / nStk;

        // Overwrite memory to storage. As aforementioned, this function should be executed BEFORE
        // so that reward variable updates are written to memory and not the storage beforehand.
        delete forges[_fid];
        forges[_fid] = _forge;
    }

    function _updateDerivedBalanceForUser(uint256 _fid, address _user) internal {
        Forge memory _forge = forges[_fid];
        UserForgeInfo memory _forgeUser = userForgeInfo[_fid][_user];

        // Calculate boost adjusted staked balance.
        IERC20 _veWorks = veWorks;
        uint256 deriv = (_forgeUser.stk * 40) / 100;
        uint256 boostAdjusted = 
        (((_forge.stkToken.balanceOf(address(this)) * _veWorks.balanceOf(msg.sender)) / _veWorks.totalSupply()) * 60) / 100;
        _forgeUser.derivStk = Math.min(deriv + boostAdjusted, _forgeUser.stk);

        // Clear user info and rewrite with updated info.
        delete userForgeInfo[_fid][_user];
        userForgeInfo[_fid][_user] = _forgeUser;
    }

    function _reset(address _owner) internal {
        uint256[] storage _userVotedForges = userVotedForges[_owner];
        uint256 voteCount = _userVotedForges.length;

        for(uint256 i; i < voteCount; i++) {
            uint256 fid = _userVotedForges[i];
            uint256 _userForgeVote = userForgeVotes[_owner][fid];

            // Remove the user's voting weight if the forge has a weight.
            if(_userForgeVote > 0) {
                totalForgeWeight -= _userForgeVote;
                weightForForge[fid] -= _userForgeVote;
                userForgeVotes[_owner][fid] = 0;
            }
        }
        delete userVotedForges[_owner];
    }

    function _vote(address _owner, uint256[] memory _forgeVotes, uint256[] memory _weights) internal {
        _reset(_owner);
        uint256 nVotes = _forgeVotes.length;
        uint256 usrWeight = veWorks.balanceOf(_owner);
        uint256 totalWeight = 0;
        uint256 usedWeight = 0;

        for(uint256 i; i < nVotes; i++) {
            totalWeight += _weights[i];
        }

        for(uint256 i; i < nVotes; i++) {
            uint256 fid = _forgeVotes[i];
            uint256 forgeWeight = (_weights[i] * usrWeight) / totalWeight;

            usedWeight += forgeWeight;
            totalForgeWeight += forgeWeight;
            weightForForge[fid] += forgeWeight;
            userVotedForges[_owner].push(fid);
            userForgeVotes[_owner][fid] = forgeWeight;
        }

        userUsedForgeWeights[_owner] = usedWeight;
    }
}