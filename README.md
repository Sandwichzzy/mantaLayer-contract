# MantaLayer 质押协议

基于以太坊构建的安全高效的质押和委托协议，使用户能够质押代币、委托给运营商并获得奖励。

## 📋 目录

- [概述](#概述)
- [架构设计](#架构设计)
- [核心合约](#核心合约)
- [核心功能](#核心功能)
- [安全机制](#安全机制)
- [快速开始](#快速开始)
- [部署指南](#部署指南)
- [使用指南](#使用指南)
- [紧急控制](#紧急控制)
- [开发指南](#开发指南)
- [测试](#测试)

## 🌟 概述

MantaLayer 是一个去中心化质押协议，允许用户：

- **质押代币**到多种策略中
- **委托质押权**给运营商
- **赚取奖励**基于质押参与度
- **提取资金**通过安全的队列系统

该协议采用类 EigenLayer 架构，增强了安全特性和灵活的提款机制。

## 🏗️ 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                        用户界面                             │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
┌──────────────┐ ┌─────────────┐ ┌──────────────┐
│   策略管理   │ │  委托管理   │ │   奖励管理   │
│   合约       │ │  合约       │ │   合约       │
└──────┬───────┘ └──────┬──────┘ └──────┬───────┘
       │                │               │
       │                │               │
       ▼                ▼               ▼
┌──────────────┐ ┌─────────────┐ ┌──────────────┐
│   策略基础   │ │  运营商注册 │ │   奖励分发   │
│   合约       │ │  表         │ │              │
└──────────────┘ └─────────────┘ └──────────────┘
```

## 📦 核心合约

### 1. **StrategyManager.sol**（策略管理合约）

管理用户存款和策略分配。

**核心函数：**

- `depositIntoStrategy()` - 将代币存入策略
- `depositIntoStrategyWithSignature()` - 通过 EIP-712 签名存款
- `removeShares()` - 在提款时移除份额
- `addShares()` - 向用户账户添加份额

**特性：**

- 多策略支持（每个用户最多 32 个策略）
- 策略白名单管理
- 第三方转账限制
- EIP-712 签名支持无 gas 存款
- 可暂停存款功能以应对紧急情况

### 2. **DelegationManager.sol**（委托管理合约）

处理质押者和运营商之间的委托关系。

**核心函数：**

- `registerAsOperator()` - 注册为运营商
- `delegateTo()` - 将质押权委托给运营商
- `undelegate()` - 移除委托（触发全额提款）
- `queueWithdrawals()` - 排队部分提款
- `completeQueuedWithdrawal()` - 延迟后完成提款

**特性：**

- 运营商注册，支持可配置参数
- 委托审批机制
- 提款队列系统，支持自定义延迟
- EIP-712 签名支持委托
- 细粒度暂停控制（委托、进入队列、退出队列）

### 3. **RewardManager.sol**（奖励管理合约）

管理向质押者分发奖励。

**核心函数：**

- `createRewardDistribution()` - 创建新的奖励分发
- `claimReward()` - 领取已赚取的奖励
- `getClaimableReward()` - 查看可领取奖励

**特性：**

- 基于时间的奖励分发
- 基于份额的比例奖励计算
- Merkle 树验证以提高领取效率
- 奖励资格白名单管理

### 4. **StrategyBase.sol**（策略基础合约）

质押策略的基础实现。

**核心函数：**

- `deposit()` - 将代币转换为份额
- `withdraw()` - 将份额转换回代币
- `sharesToUnderlying()` - 计算份额的代币价值
- `underlyingToShares()` - 从代币数量计算份额

## ✨ 核心功能

### 🔐 安全特性

- **重入保护** - 所有外部函数使用 `nonReentrant` 修饰符保护
- **可暂停系统** - 每个函数的细粒度紧急暂停控制
- **签名验证** - EIP-712 和 EIP-1271 签名验证
- **访问控制** - 所有者和基于角色的权限
- **提款延迟** - 可配置延迟以防止闪电攻击

### 🚀 高级功能

- **可升级合约** - UUPS 代理模式，便于未来改进
- **Gas 优化** - 使用 Yul IR 和 200 次优化器运行进行优化
- **多策略支持** - 用户可以同时在多个策略中质押
- **运营商委托** - 灵活的委托和审批机制
- **EIP-712 签名** - 无 gas 交易和元交易支持

### 📊 灵活提款

- **部分提款** - 无需取消委托即可排队特定金额
- **全额提款** - 取消委托会自动触发全额提款队列
- **策略特定延迟** - 每个策略的不同提款延迟
- **提款验证** - 提款完成的根哈希验证

## 🔒 安全机制

### 暂停系统

协议实现了基于位图的可暂停系统，具有三个级别：

#### StrategyManager 暂停索引

- **索引 0** (`PAUSED_DEPOSITS`) - 暂停所有存款功能

#### DelegationManager 暂停索引

- **索引 0** (`PAUSED_NEW_DELEGATION`) - 暂停新委托
- **索引 1** (`PAUSED_ENTER_WITHDRAWAL_QUEUE`) - 暂停进入提款队列
- **索引 2** (`PAUSED_EXIT_WITHDRAWAL_QUEUE`) - 暂停完成提款

### 签名安全

- **域分隔符** - 链特定，防止跨链重放攻击
- **Nonce 追踪** - 防止同一链内的签名重放
- **过期时间戳** - 时间限制签名，增强安全性
- **EIP-1271 支持** - 智能合约钱包兼容性

## 🚀 快速开始

### 前置要求

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/)
- [Node.js](https://nodejs.org/)（可选，用于额外工具）

### 安装

```bash
# 克隆仓库
git clone https://github.com/your-org/mantaLayer-contract.git
cd mantaLayer-contract

# 安装依赖
forge install

# 构建合约
forge build
```

### 环境配置

创建 `.env` 文件：

```bash
# 网络 RPC URLs
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY

# 部署钱包
PRIVATE_KEY=your_private_key_here

# Etherscan API key 用于验证
ETHERSCAN_API_KEY=your_etherscan_key

# 合约地址（部署后）
STRATEGY_MANAGER=0x...
DELEGATION_MANAGER=0x...
REWARD_MANAGER=0x...
```

## 📝 部署指南

### 1. 部署核心合约

```bash
# 部署 StrategyManager
forge script script/DeployStrategyManager.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify

# 部署 DelegationManager
forge script script/DeployDelegationManager.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify

# 部署 RewardManager
forge script script/DeployRewardManager.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### 2. 初始化合约

```solidity
// 初始化 StrategyManager
strategyManager.initialize(
    owner,                    // 合约所有者地址
    strategyWhitelister,      // 可以将策略加入白名单的地址
    pauserRegistry,          // PauserRegistry 合约地址
    0                        // 初始暂停状态（0 = 未暂停）
);

// 初始化 DelegationManager
delegationManager.initialize(
    owner,                   // 合约所有者地址
    pauserRegistry,         // PauserRegistry 合约地址
    0,                      // 初始暂停状态
    50400,                  // 最小提款延迟区块数（约 7 天）
    strategies,             // 初始策略数组
    withdrawalDelayBlocks   // 每个策略的提款延迟
);

// 初始化 RewardManager
rewardManager.initialize(
    owner,                  // 合约所有者地址
    strategyManager         // StrategyManager 地址
);
```

### 3. 配置系统

```solidity
// 将策略添加到白名单
IStrategyBase[] memory strategies = [strategy1, strategy2];
bool[] memory transferRestrictions = [false, true];
strategyManager.addStrategiesToDepositWhitelist(
    strategies,
    transferRestrictions
);

// 为策略设置提款延迟
delegationManager.setStrategyWithdrawalDelayBlocks(
    strategies,
    [50400, 86400]  // 每个策略不同的延迟
);
```

## 📖 使用指南

### 质押者操作

#### 1. 存入代币

```solidity
// 首先授权代币
token.approve(address(strategyManager), amount);

// 存入策略
strategyManager.depositIntoStrategy(
    strategy,
    token,
    amount
);
```

#### 2. 委托给运营商

```solidity
// 委托你的质押权
delegationManager.delegateTo(
    operatorAddress,
    emptySignature,  // 如果运营商没有审批者
    bytes32(0)       // Salt
);
```

#### 3. 排队提款

```solidity
// 准备提款参数
IDelegationManager.QueuedWithdrawalParams[] memory params =
    new IDelegationManager.QueuedWithdrawalParams[](1);

params[0] = IDelegationManager.QueuedWithdrawalParams({
    strategies: strategiesArray,
    shares: sharesArray,
    withdrawer: msg.sender
});

// 排队提款
bytes32[] memory roots = delegationManager.queueWithdrawals(params);
```

#### 4. 完成提款

```solidity
// 提款延迟期后
delegationManager.completeQueuedWithdrawal(
    withdrawal,
    mantaToken
);
```

### 运营商操作

#### 1. 注册为运营商

```solidity
IDelegationManager.OperatorDetails memory details =
    IDelegationManager.OperatorDetails({
        earningsReceiver: revenueAddress,
        delegationApprover: approverAddress,  // 或 address(0)
        stakerOptOutWindowBlocks: 50400       // 约 7 天
    });

delegationManager.registerAsOperator(
    details,
    "https://metadata-url.com/operator.json"
);
```

#### 2. 更新运营商信息

```solidity
delegationManager.modifyOperatorDetails(newDetails);
delegationManager.updateOperatorNodeUrl(newMetadataUrl);
```

## 🚨 紧急控制

### 暂停功能

#### 暂停存款

```solidity
// Pauser 角色可以暂停存款
uint256 pauseStatus = 1 << 0;  // 设置位 0
pauserRegistry.pause(pauseStatus);
```

#### 暂停委托

```solidity
// 暂停新委托（位 0）
uint256 pauseStatus = 1 << 0;
pauserRegistry.pause(pauseStatus);
```

#### 暂停提款

```solidity
// 暂停进入提款队列（位 1）
uint256 pauseEntry = 1 << 1;
pauserRegistry.pause(pauseEntry);

// 暂停完成提款（位 2）
uint256 pauseExit = 1 << 2;
pauserRegistry.pause(pauseExit);

// 同时暂停两者
uint256 pauseBoth = (1 << 1) | (1 << 2);
pauserRegistry.pause(pauseBoth);
```

#### 暂停所有功能

```solidity
// 紧急暂停所有功能
pauserRegistry.pauseAll();
```

#### 解除暂停

```solidity
// 只有 unpauser 角色可以解除暂停
pauserRegistry.unpause(0);  // 解除所有暂停
```

### 角色和权限

| 角色                                         | 权限                         |
| -------------------------------------------- | ---------------------------- |
| **Owner（所有者）**                          | 更改设置，升级合约           |
| **Pauser（暂停者）**                         | 暂停功能（只能添加暂停）     |
| **Unpauser（解除暂停者）**                   | 解除暂停功能（只能移除暂停） |
| **Strategy Whitelister（策略白名单管理员）** | 从白名单添加/移除策略        |
| **Delegation Approver（委托审批者）**        | 批准对特定运营商的委托       |

## 🛠️ 开发指南

### 构建

```bash
forge build
```

### 测试

```bash
# 运行所有测试
forge test

# 运行特定测试文件
forge test --match-path test/StrategyManager.t.sol

# 带 gas 报告运行
forge test --gas-report

# 带详细输出运行
forge test -vvv
```

### 格式化代码

```bash
forge fmt
```

### 代码覆盖率

```bash
forge coverage
```

### Gas 快照

```bash
forge snapshot
```

### 本地开发节点

```bash
# 启动本地节点
anvil

# 部署到本地节点
forge script script/Deploy.s.sol \
    --rpc-url http://127.0.0.1:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

## 🧪 测试

### 单元测试

```bash
forge test --match-contract StrategyManagerTest
forge test --match-contract DelegationManagerTest
forge test --match-contract RewardManagerTest
```

### 集成测试

```bash
forge test --match-contract IntegrationTest
```

### 不变量测试

```bash
forge test --match-contract InvariantTest
```

### Fork 测试

```bash
forge test --fork-url $MAINNET_RPC_URL --match-contract ForkTest
```

## 📊 合约规范

### StrategyManager

- **Solidity 版本**: 0.8.30
- **优化器**: 启用（200 次运行）
- **EVM 版本**: Cancun
- **可升级性**: UUPS 代理
- **继承**: Initializable, OwnableUpgradeable, ReentrancyGuard, Pausable

### DelegationManager

- **Solidity 版本**: 0.8.30
- **优化器**: 启用（200 次运行）
- **EVM 版本**: Cancun
- **可升级性**: UUPS 代理
- **继承**: Initializable, OwnableUpgradeable, ReentrancyGuard, Pausable

### 关键常量

```solidity
// StrategyManager
MAX_STAKER_STRATEGY_LIST_LENGTH = 32

// DelegationManager
MAX_WITHDRAWAL_DELAY_BLOCKS = 216000  // 约 30 天
MAX_STAKER_OPT_OUT_WINDOW_BLOCKS = 1296000  // 约 180 天
```

## 🔧 实用命令

### Cast 命令

```bash
# 检查存储槽
cast storage <CONTRACT_ADDRESS> <SLOT> --rpc-url $RPC_URL

# 调用视图函数
cast call <CONTRACT_ADDRESS> "getDeposits(address)" <STAKER_ADDRESS> \
    --rpc-url $RPC_URL

# 发送交易
cast send <CONTRACT_ADDRESS> "depositIntoStrategy(address,address,uint256)" \
    <STRATEGY> <TOKEN> <AMOUNT> \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL

# 获取 ABI
forge inspect StrategyManager abi > abi/StrategyManager.json

# 获取存储布局
forge inspect StrategyManager storage-layout --pretty
```

## 📚 其他资源

- [Foundry 文档](https://book.getfoundry.sh/)
- [Solidity 文档](https://docs.soliditylang.org/)
- [OpenZeppelin 合约](https://docs.openzeppelin.com/contracts/)
- [EIP-712 规范](https://eips.ethereum.org/EIPS/eip-712)
- [EIP-1271 规范](https://eips.ethereum.org/EIPS/eip-1271)
