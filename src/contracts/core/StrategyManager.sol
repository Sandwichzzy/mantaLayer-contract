// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./StrategyManagerStorage.sol";
import "../../libraries/EIP1271SignatureUtils.sol";

contract StrategyManager is Initializable, OwnableUpgradeable, ReentrancyGuard, StrategyManagerStorage {
    using SafeERC20 for IERC20;

    uint8 internal constant PAUSED_DEPOSITS = 0;
    uint256 internal immutable ORIGINAL_CHAIN_ID;

    modifier onlyDelegationManager() {
        require(
            msg.sender == address(i_delegation),
            "StrategyManager.onlyDelegationManager: Caller is not DelegationManager"
        );
        _;
    }

    modifier onlyStrategyWhitelister() {
        require(
            msg.sender == strategyWhitelister, "StrategyManager.onlyStrategyWhitelister: not the strategyWhitelister"
        );
        _;
    }

    modifier onlyStrategiesWhitelistedForDeposit(IStrategyBase strategy) {
        require(
            strategyIsWhitelistedForDeposit[strategy],
            "StrategyManager.onlyStrategiesWhitelistedForDeposit: strategy not whitelisted"
        );
        _;
    }

    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/
    constructor(IDelegationManager _delegation) StrategyManagerStorage(_delegation) {
        _disableInitializers();
    }

    function initialize(address initialOwner, address initialStrategyWhitelister) external initializer {
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _transferOwnership(initialOwner);
        _setStrategyWhitelister(initialStrategyWhitelister);
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS
    *******************************************************************************/

    function depositIntoStrategy(IStrategyBase strategy, IERC20 tokenAddress, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _depositIntoStrategy(msg.sender, strategy, tokenAddress, amount);
    }

    /*******************************************************************************
                            INTERNAL FUNCTIONS
    *******************************************************************************/
    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("MantaLayer")), block.chainid, address(this)));
    }

    function _setStrategyWhitelister(address newStrategyWhitelister) internal {
        address previousAddress = strategyWhitelister;
        strategyWhitelister = newStrategyWhitelister;
        emit StrategyWhitelisterChanged(previousAddress, newStrategyWhitelister);
    }

    function _depositIntoStrategy(address staker, IStrategyBase strategy, IERC20 tokenAddress, uint256 amount)
        internal
        onlyStrategiesWhitelistedForDeposit(strategy) //判断质押策略是否在白名单中
        returns (uint256 shares)
    {
        require(amount > 0, "StrategyManager._depositIntoStrategy: amount must be > 0");
        //将token转入到对应的策略里
        tokenAddress.safeTransferFrom(msg.sender, address(strategy), amount);
        //根据质押token的数量，去策略base合约中计算质押获得的份额(shares)
        shares = strategy.deposit(tokenAddress, amount);
        //将token的amount 计算出来的质押份额shares 加到质押者的地址上
        _addShares(staker, tokenAddress, strategy, shares);
        //若staker 已经delegate给过对应的operator，这里就直接将质押shares委托给这个operator
        i_delegation.increaseDelegatedShares(staker, strategy, shares);

        return shares;
    }

    //如果是首次质押，将策略加入到策略质押池
    function _addShares(address staker, IERC20 mantaToken, IStrategyBase strategy, uint256 shares) internal {
        require(staker != address(0), "StrategyManager._addShares:staker cannot be zero address");
        require(shares != 0, "StrategyManager._addShares: shares should not be zero!");

        if (stakerStrategyShares[staker][strategy] == 0) {
            require(
                stakerStrategyList[staker].length < MAX_STAKER_STRATEGY_LIST_LENGTH,
                "StrategyManager._addShares: staker strategy list length exceeded max limit"
            );
            stakerStrategyList[staker].push(strategy);
        }
        //将质押的shares加到给staker
        stakerStrategyShares[staker][strategy] += shares;

        emit Deposit(staker, mantaToken, strategy, shares);
    }
}
