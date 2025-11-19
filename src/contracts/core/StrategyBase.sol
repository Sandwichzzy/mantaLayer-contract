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

    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/
    constructor(IStrategyManager _strategyManager) {
        i_strategyManager = _strategyManager;
        _disableInitializers();
    }

    function initialize(
        IERC20 _underlyingToken,
        IPauserRegistry _pauserRegistry,
        uint256 _maxPerDeposit,
        uint256 _maxTotalDeposits
    ) public virtual initializer {
        underlyingToken = _underlyingToken;
        _setDepositLimits(_maxPerDeposit, _maxTotalDeposits);
        _initializeStrategyBase(_underlyingToken, _pauserRegistry);
    }

    function _initializeStrategyBase(IERC20 _underlyingToken, IPauserRegistry _pauserRegistry)
        internal
        onlyInitializing
    {
        underlyingToken = _underlyingToken;
        _initializePauser(_pauserRegistry, UNPAUSE_ALL);
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS
    *******************************************************************************/
    function deposit(IERC20 token, uint256 amount)
        external
        virtual
        override
        onlyStrategyManager
        returns (uint256 newShares)
    {
        _beforeDeposit(token, amount);

        uint256 priorTotalShares = totalShares; // 记录存款前的总份额
        // 计算虚拟份额总量（加上偏移量，防止除零和通胀攻击）
        uint256 virtualShareAmount = priorTotalShares + SHARES_OFFSET; // 虚拟份额 = 实际份额 + 1000
        // 计算虚拟代币余额（当前余额已包含刚转入的 amount）
        uint256 virtualTokenBalance = _tokenBalance() + BALANCE_OFFSET; // 虚拟余额 = 实际余额 + 1000
        // 计算存款前的虚拟余额（减去本次存入的金额）
        uint256 virtualPriorTokenBalance = virtualTokenBalance - amount;
        // 新份额 = (本次质押token数量 x (截止到上一次质押的shares量+1000)) ÷ (token在策略里的余额+1000-本次质押token数量)
        newShares = (amount * virtualShareAmount) / virtualPriorTokenBalance;

        require(newShares != 0, "StrategyBase.deposit: newShares cannot be zero");
        totalShares = (priorTotalShares + newShares); //更新总份额
        return newShares;
    }

    function withdraw(address recipient, IERC20 token, uint256 amountShares)
        external
        virtual
        override
        onlyStrategyManager
    {
        _beforeWithdrawal(recipient, token, amountShares);
        uint256 priorTotalShares = totalShares; //记录提款前的总份额
        require(
            amountShares <= priorTotalShares,
            "StrategyBase.withdraw: amountShares must be less than or equal to totalShares"
        );
        uint256 virtualPriorTotalShares = priorTotalShares + SHARES_OFFSET; //计算虚拟总份额（加上偏移量）
        uint256 virtualTokenBalance = _tokenBalance() + BALANCE_OFFSET; //计算虚拟代币余额（加上偏移量）
        // 返还金额 = (虚拟余额 × 销毁份额) ÷ 虚拟总份额
        uint256 amountToSend = (virtualTokenBalance * amountShares) / virtualPriorTotalShares;
        totalShares = priorTotalShares - amountShares;
        _afterWithdrawal(recipient, token, amountToSend);
    }

    function setDepositLimits(uint256 newMaxPerDeposit, uint256 newMaxTotalDeposits) external onlyStrategyManager {
        _setDepositLimits(newMaxPerDeposit, newMaxTotalDeposits);
    }

    function getDepositLimits() external view returns (uint256, uint256) {
        return (maxPerDeposit, maxTotalDeposits);
    }

    function explanation() external pure virtual override returns (string memory) {
        return "Base Strategy implementation to inherit from for more complex implementations";
    }

    function sharesToUnderlyingView(uint256 amountShares) public view virtual override returns (uint256) {
        uint256 virtualTotalShares = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = _tokenBalance() + BALANCE_OFFSET;
        return (virtualTokenBalance * amountShares) / virtualTotalShares;
    }

    function sharesToUnderlying(uint256 amountShares) public view virtual override returns (uint256) {
        return sharesToUnderlyingView(amountShares);
    }

    function underlyingToSharesView(uint256 amountUnderlying) public view virtual returns (uint256) {
        uint256 virtualTotalShares = totalShares + SHARES_OFFSET;
        uint256 virtualTokenBalance = _tokenBalance() + BALANCE_OFFSET;
        return (amountUnderlying * virtualTotalShares) / virtualTokenBalance;
    }

    function underlyingToShares(uint256 amountUnderlying) external view virtual returns (uint256) {
        return underlyingToSharesView(amountUnderlying);
    }

    function userUnderlying(address user) external virtual returns (uint256) {
        return sharesToUnderlying(shares(user));
    }

    function userUnderlyingView(address user) external view virtual returns (uint256) {
        return sharesToUnderlyingView(shares(user));
    }

    function shares(address user) public view virtual returns (uint256) {
        return strategyManager.stakerStrategyShares(user, IStrategyBase(address(this)));
    }

    /*******************************************************************************
                            INTERNAL FUNCTIONS
    *******************************************************************************/
    function _beforeDeposit(IERC20 token, uint256 amount) internal virtual {
        require(token == underlyingToken, "StrategyBase.deposit: Can only deposit underlyingToken");
        require(amount <= maxPerDeposit, "StrategyBase: max per deposit exceeded");
        require(_tokenBalance() <= maxTotalDeposits, "StrategyBase: max deposits exceeded");
    }

    function _beforeWithdrawal(address recipient, IERC20 token, uint256 amountShares) internal virtual {
        require(token == underlyingToken, "StrategyBase.withdraw: Can only withdraw the strategy token");
    }

    function _afterWithdrawal(address recipient, IERC20 token, uint256 amountToSend) internal virtual {
        token.safeTransfer(recipient, amountToSend);
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

    function _tokenBalance() internal view virtual returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    uint256[100] private __gap;
}
