// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IRewardManager {
    event OperatorAndStakeReward(address strategy, address operator, uint256 stakerFee, uint256 operatorFee);

    event OperatorClaimReward(address operator, uint256 amount);
    event StakeHolderClaimReward(address stakeHolder, address strategy, uint256 amount);

    function payFee(address strategy, address operator, uint256 baseFee) external;
}
