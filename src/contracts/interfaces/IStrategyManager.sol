// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyBase} from "./IStrategyBase.sol";

interface IStrategyManager {
    event Deposit(address staker, IERC20 mantaToken, IStrategyBase strategy, uint256 shares);

    event UpdatedThirdPartyTransfersForbidden(IStrategyBase strategy, bool value);
}
