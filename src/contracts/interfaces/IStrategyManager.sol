// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyBase} from "./IStrategyBase.sol";

/**
 * @title IStrategyManager
 * @notice 策略管理器接口，定义质押策略的存款、提款和份额管理
 * @dev 管理用户在不同策略中的资产存款和份额
 */
interface IStrategyManager {
    /// @notice 当用户存入代币到策略时触发
    /// @param staker 质押者地址
    /// @param mantaToken 存入的代币合约
    /// @param strategy 目标策略合约
    /// @param shares 获得的份额数量
    event Deposit(address staker, IERC20 mantaToken, IStrategyBase strategy, uint256 shares);

    /// @notice 当策略的第三方转账限制被更新时触发
    /// @param strategy 策略合约
    /// @param value 新的限制值（true=禁止第三方转账，false=允许）
    event UpdatedThirdPartyTransfersForbidden(IStrategyBase strategy, bool value);

    /// @notice 当策略白名单管理员地址变更时触发
    /// @param previousAddress 之前的管理员地址
    /// @param newAddress 新的管理员地址
    event StrategyWhitelisterChanged(address previousAddress, address newAddress);

    /// @notice 当策略被添加到存款白名单时触发
    /// @param strategy 被添加的策略合约
    event StrategyAddedToDepositWhitelist(IStrategyBase strategy);

    /// @notice 当策略从存款白名单中移除时触发
    /// @param strategy 被移除的策略合约
    event StrategyRemovedFromDepositWhitelist(IStrategyBase strategy);

    /**
     * @notice 将代币存入指定策略
     * @param strategy 目标策略合约
     * @param tokenAddress 要存入的代币合约地址
     * @param amount 存入金额
     * @return shares 获得的策略份额数量
     * @dev 调用者需要先授权代币给本合约
     */
    function depositIntoStrategy(IStrategyBase strategy, IERC20 tokenAddress, uint256 amount)
        external
        returns (uint256 shares);

    /**
     * @notice 通过签名代表质押者存入代币（元交易）
     * @param strategy 目标策略合约
     * @param tokenAddress 要存入的代币合约地址
     * @param amount 存入金额
     * @param staker 质押者地址
     * @param expiry 签名过期时间戳
     * @param signature 质押者的EIP712签名
     * @return shares 获得的策略份额数量
     * @dev 允许第三方代表用户执行存款，用户需提供有效签名
     */
    function depositIntoStrategyWithSignature(
        IStrategyBase strategy,
        IERC20 tokenAddress,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes memory signature
    ) external returns (uint256 shares);

    /**
     * @notice 移除质押者在策略中的份额（仅限内部调用）
     * @param staker 质押者地址
     * @param strategy 策略合约
     * @param shares 要移除的份额数量
     * @dev 通常在提款或取消委托时调用
     */
    function removeShares(address staker, IStrategyBase strategy, uint256 shares) external;

    /**
     * @notice 为质押者增加策略份额（仅限内部调用）
     * @param staker 质押者地址
     * @param mantaToken 代币合约
     * @param strategy 策略合约
     * @param shares 要增加的份额数量
     * @dev 通常在完成提款或迁移时调用
     */
    function addShares(address staker, IERC20 mantaToken, IStrategyBase strategy, uint256 shares) external;

    /**
     * @notice 将策略份额提取为代币
     * @param recipient 接收代币的地址
     * @param strategy 策略合约
     * @param shares 要提取的份额数量
     * @param tokenAddress 要提取的代币合约地址
     * @dev 立即从策略中赎回份额并发送代币给接收者
     */
    function withdrawSharesAsTokens(address recipient, IStrategyBase strategy, uint256 shares, IERC20 tokenAddress)
        external;

    /**
     * @notice 查询质押者在特定策略中的份额
     * @param user 质押者地址
     * @param strategy 策略合约
     * @return shares 份额数量
     */
    function stakerStrategyShares(address user, IStrategyBase strategy) external view returns (uint256 shares);

    /**
     * @notice 获取质押者的所有存款信息（策略和对应份额）
     * @param staker 质押者地址
     * @return 策略合约数组和对应的份额数量数组
     */
    function getDeposits(address staker) external view returns (IStrategyBase[] memory, uint256[] memory);

    /**
     * @notice 获取质押者参与的策略数量
     * @param staker 质押者地址
     * @return 策略数量
     */
    function stakerStrategyListLength(address staker) external view returns (uint256);

    /**
     * @notice 将策略添加到存款白名单（仅限白名单管理员）
     * @param strategiesToWhitelist 要添加的策略数组
     * @param thirdPartyTransfersForbiddenValues 每个策略是否禁止第三方转账
     */
    function addStrategiesToDepositWhitelist(
        IStrategyBase[] calldata strategiesToWhitelist,
        bool[] calldata thirdPartyTransfersForbiddenValues
    ) external;

    /**
     * @notice 从存款白名单中移除策略（仅限白名单管理员）
     * @param strategiesToRemoveFromWhitelist 要移除的策略数组
     */
    function removeStrategiesFromDepositWhitelist(IStrategyBase[] calldata strategiesToRemoveFromWhitelist) external;

    /**
     * @notice 获取策略白名单管理员地址
     * @return 管理员地址
     */
    function strategyWhitelister() external view returns (address);

    /**
     * @notice 查询策略是否禁止第三方转账
     * @param strategy 策略合约
     * @return 如果禁止第三方转账返回true，否则返回false
     */
    function thirdPartyTransfersForbidden(IStrategyBase strategy) external view returns (bool);

    /**
     * @notice 已弃用的提款者和随机数结构体（用于向后兼容）
     * @param withdrawer 提款接收者地址
     * @param nonce 96位随机数
     */
    struct DeprecatedStruct_WithdrawerAndNonce {
        address withdrawer;
        uint96 nonce;
    }

    /**
     * @notice 已弃用的排队提款结构体（用于从旧版本迁移）
     * @param strategies 涉及的策略数组
     * @param shares 每个策略的份额数量
     * @param staker 质押者地址
     * @param withdrawerAndNonce 提款者和随机数
     * @param withdrawalStartBlock 提款开始区块
     * @param delegatedAddress 委托的操作员地址
     */
    struct DeprecatedStruct_QueuedWithdrawal {
        IStrategyBase[] strategies;
        uint256[] shares;
        address staker;
        DeprecatedStruct_WithdrawerAndNonce withdrawerAndNonce;
        uint32 withdrawalStartBlock;
        address delegatedAddress;
    }

    /**
     * @notice 迁移旧版本的排队提款
     * @param queuedWithdrawal 旧版本的提款结构体
     * @return 迁移是否成功和新的提款根哈希
     * @dev 用于将旧版StrategyManager的提款迁移到新的DelegationManager
     */
    function migrateQueuedWithdrawal(DeprecatedStruct_QueuedWithdrawal memory queuedWithdrawal)
        external
        returns (bool, bytes32);

    /**
     * @notice 计算已弃用提款结构体的根哈希
     * @param queuedWithdrawal 提款结构体
     * @return 提款根哈希
     * @dev 用于验证和迁移旧版本的提款
     */
    function calculateWithdrawalRoot(DeprecatedStruct_QueuedWithdrawal memory queuedWithdrawal)
        external
        pure
        returns (bytes32);
}
