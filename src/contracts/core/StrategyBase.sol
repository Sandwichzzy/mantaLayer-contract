// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";

import "src/access/Pausable.sol";

import "../interfaces/IStrategyBase.sol";
import "../interfaces/IStrategyManager.sol";
import "../../access/interfaces/IPauserRegistry.sol";

contract StrategyBase is Initializable, IStrategyBase, Pausable {
    using SafeERC20 for IERC20;

    uint8 internal constant PAUSED_DEPOSITS = 0;
    uint8 internal constant PAUSED_WITHDRAWALS = 1;

    uint256 internal constant SHARES_OFFSET = 1e3;

    uint256 internal constant BALANCE_OFFSET = 1e3;

    IStrategyManager public immutable i_strategyManager;

    IERC20 public underlyingToken;

    uint256 public maxPerDeposit;

    uint256 public maxTotalDeposits;

    uint256 public totalShares;

    modifier onlyStrategyManager() {
        require(msg.sender == address(i_strategyManager), "StrategyBase: caller is not the strategy manager");
        _;
    }

    constructor(IStrategyManager _strategyManager) {
        i_strategyManager = _strategyManager;
        _disableInitializers();
    }

    function initialize(
        IERC20 _underlyingToken,
        IPauserRegistry _pauseRegistry,
        uint256 _maxPerDeposit,
        uint256 _maxTotalDeposits
    ) public virtual initializer {
        underlyingToken = _underlyingToken;
        _setDepositLimits(_maxPerDeposit, _maxTotalDeposits);
        _initializePauser(_pauseRegistry, UNPAUSE_ALL);
    }

    function setDepositLimits(uint256 newMaxPerDeposit, uint256 newMaxTotalDeposits) external onlyStrategyManager {
        _setDepositLimits(newMaxPerDeposit, newMaxTotalDeposits);
    }

    function _setDepositLimits(uint256 newMaxPerDeposit, uint256 newMaxTotalDeposits) internal {
        require(
            newMaxPerDeposit <= newMaxTotalDeposits,
            "StrategyBase._setDepositLimits: maxPerDeposit exceeds maxTotalDeposits"
        );
        maxPerDeposit = newMaxPerDeposit;
        maxTotalDeposits = newMaxTotalDeposits;
        emit MaxPerDepositUpdated(maxPerDeposit, newMaxPerDeposit);
        emit MaxTotalDepositsUpdated(maxTotalDeposits, newMaxTotalDeposits);
    }
}
