// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IRewardManager.sol";
import "../interfaces/IDelegationManager.sol";

abstract contract RewardManagerStorage is IRewardManager {
    IDelegationManager public immutable i_delegationManager;

    IStrategyManager public immutable i_strategyManager;

    IERC20 public immutable i_rewardTokenAddress;

    uint256 public stakePercent;

    address public rewardManager;

    address public payFeeManager;

    mapping(address => uint256) public strategyStakeRewards;
    mapping(address => uint256) public operatorRewards;

    uint256[100] private __gap;
}
