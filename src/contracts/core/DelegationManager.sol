// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../libraries/EIP1271SignatureUtils.sol";
import "../../access/interfaces/IPauserRegistry.sol";
import "../../access/Pausable.sol";

import "./DelegationManagerStorage.sol";

contract DelegationManager is Initializable, OwnableUpgradeable, ReentrancyGuard, Pausable, DelegationManagerStorage {
    uint8 internal constant PAUSED_NEW_DELEGATION = 0;

    uint8 internal constant PAUSED_ENTER_WITHDRAWAL_QUEUE = 1;

    uint8 internal constant PAUSED_EXIT_WITHDRAWAL_QUEUE = 2;

    uint256 internal immutable ORIGINAL_CHAIN_ID;

    uint256 public constant MAX_STAKER_OPT_OUT_WINDOW_BLOCKS = (180 days) / 12;

    modifier onlyStrategyManager() {
        require(
            msg.sender == address(i_strategyManager),
            "DelegationManager.onlyStrategyManager: Caller is not StrategyManager"
        );
        _;
    }
    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/

    constructor(IStrategyManager _strategyManager) DelegationManagerStorage(_strategyManager) {
        ORIGINAL_CHAIN_ID = block.chainid;
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        IPauserRegistry _pauserRegistry,
        uint256 initialPausedStatus,
        uint256 _minWithdrawalDelayBlocks,
        IStrategyBase[] calldata _strategies,
        uint256[] calldata _withdrawalDelayBlocks
    ) external initializer {
        _initializePauser(_pauserRegistry, initialPausedStatus);
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _transferOwnership(initialOwner);
        _setMinWithdrawalDelayBlocks(_minWithdrawalDelayBlocks);
        _setStrategyWithdrawalDelayBlocks(_strategies, _withdrawalDelayBlocks);
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS
    *******************************************************************************/

    //将operator的链下信息提交到链上，例如：节点p2p通信链接
    function registerAsOperator(OperatorDetails calldata registeringOperatorDetails, string calldata nodeUrl) external {
        require(
            _operatorDetails[msg.sender].earningsReceiver == address(0),
            "DelegationManager.registerAsOperator: Operator already registered"
        );
        _setOperatorDetails(msg.sender, registeringOperatorDetails);
        SignatureWithExpiry memory emptySignatureAndExpiry;
        _delegate(msg.sender, msg.sender, emptySignatureAndExpiry, bytes32(0));
        emit OperatorRegistered(msg.sender, registeringOperatorDetails);
        emit OperatorNodeUrlUpdated(msg.sender, nodeUrl);
    }

    function modifyOperatorDetails(OperatorDetails calldata newOperatorDetails) external {
        require(isOperator(msg.sender), "DelegationManager.modifyOperatorDetails: caller must be an operator");
        _setOperatorDetails(msg.sender, newOperatorDetails);
    }

    function updateOperatorNodeUrl(string calldata nodeUrl) external {
        require(isOperator(msg.sender), "DelegationManager.updateOperatorNodeUrl: caller must be an operator");
        emit OperatorNodeUrlUpdated(msg.sender, nodeUrl);
    }

    function delegateTo(address operator, SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt)
        external
        nonReentrant
        onlyWhenNotPaused(PAUSED_NEW_DELEGATION)
    {
        _delegate(msg.sender, operator, approverSignatureAndExpiry, approverSalt);
    }

    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external onlyWhenNotPaused(PAUSED_NEW_DELEGATION) {
        require(
            stakerSignatureAndExpiry.expiry >= block.timestamp,
            "DelegationManager.delegateToBySignature: staker signature expired"
        );
        uint256 currentStakeNoce = stakerNonce[staker];
        bytes32 stakerDigestHash =
            calculateStakerDelegationDigestHash(staker, currentStakeNoce, operator, stakerSignatureAndExpiry.expiry);
        unchecked {
            stakerNonce[staker] = currentStakeNoce + 1;
        }
        EIP1271SignatureUtils.checkSignature_EIP1271(staker, stakerDigestHash, stakerSignatureAndExpiry.signature);
        _delegate(staker, operator, approverSignatureAndExpiry, approverSalt);
    }

    //解质押会触发staker全部取款
    function undelegate(address staker) external returns (bytes32[] memory withdrawalRoots) {
        //staker 必须已经被委托才能undelegate
        require(isDelegated(staker), "DelegationManager.undelegate: staker must be delegated to undelegate");
        require(!isOperator(staker), "DelegationManager.undelegate: operators cannot be undelegated"); //operator自我委托不允许undelegate
        require(staker != address(0), "DelegationManager.undelegate: cannot undelegate zero address");
        address operator = delegatedTo[staker];
        //只能是staker本人，operator，或者operator的delegationApprover来调用undelegate函数
        require(
            msg.sender == staker || msg.sender == operator
                || msg.sender == _operatorDetails[operator].delegationApprover,
            "DelegationManager.undelegate: caller must be staker or operator or approver"
        );
        //获取staker在各个策略中质押的shares，返回数组
        (IStrategyBase[] memory strategies, uint256[] memory shares) = getDelegatableShares(staker);
        if (msg.sender != staker) {
            emit StakerForceUndelegated(staker, operator);
        }
        emit StakerUndelegated(staker, operator);
        //将staker和operator之间的委托关系移除
        delegatedTo[staker] = address(0);

        if (strategies.length == 0) {
            withdrawalRoots = new bytes32[](0);
        } else {
            withdrawalRoots = new bytes32[](strategies.length);
            for (uint256 i = 0; i < strategies.length; i++) {
                IStrategyBase[] memory singleStrategy = new IStrategyBase[](1);
                uint256[] memory singleShare = new uint256[](1);
                singleStrategy[0] = strategies[i];
                singleShare[0] = shares[i];
                // IStrategyBase singleStrategy = strategies[i];
                // uint256 singleShare = shares[i];
                //将stake委托给operator的shares移除，并将staker在策略里面shares清0, 生成排队取款的交易
                withdrawalRoots[i] = _removeSharesAndQueueWithdrawal({
                    staker: staker,
                    operator: operator,
                    withdrawer: staker,
                    strategies: singleStrategy,
                    shares: singleShare
                });
            }
        }
        return withdrawalRoots;
    }

    //部分取款，和undelegate区别是没有解除委托关系
    function queueWithdrawals(QueuedWithdrawalParams[] calldata queuedWithdrawalParams)
        external
        onlyWhenNotPaused(PAUSED_ENTER_WITHDRAWAL_QUEUE)
        returns (bytes32[] memory)
    {
        bytes32[] memory withdrawalRoots = new bytes32[](queuedWithdrawalParams.length);
        address operator = delegatedTo[msg.sender];
        for (uint256 i = 0; i < queuedWithdrawalParams.length; i++) {
            require(
                queuedWithdrawalParams[i].strategies.length == queuedWithdrawalParams[i].shares.length,
                "DelegationManager.queueWithdrawals: Lengths of strategies and shares do not match"
            );
            //解除staker委托给operator的shares,将staker在策略里面的shares部分解除，生成排队取款交易
            withdrawalRoots[i] = _removeSharesAndQueueWithdrawal({
                staker: queuedWithdrawalParams[i].withdrawer,
                operator: operator,
                withdrawer: queuedWithdrawalParams[i].withdrawer,
                strategies: queuedWithdrawalParams[i].strategies,
                shares: queuedWithdrawalParams[i].shares
            });
        }
        return withdrawalRoots;
    }

    function completeQueuedWithdrawal(Withdrawal calldata withdrawal, IERC20 mantaToken)
        external
        nonReentrant
        onlyWhenNotPaused(PAUSED_EXIT_WITHDRAWAL_QUEUE)
    {
        _completeQueuedWithdrawal(withdrawal, mantaToken);
    }

    function completeQueuedWithdrawals(Withdrawal[] calldata withdrawals, IERC20 mantaToken)
        external
        nonReentrant
        onlyWhenNotPaused(PAUSED_EXIT_WITHDRAWAL_QUEUE)
    {
        for (uint256 i = 0; i < withdrawals.length; ++i) {
            _completeQueuedWithdrawal(withdrawals[i], mantaToken);
        }
    }

    function setMinWithdrawalDelayBlocks(uint256 newMinWithdrawalDelayBlocks) external onlyOwner {
        _setMinWithdrawalDelayBlocks(newMinWithdrawalDelayBlocks);
    }

    function increaseDelegatedShares(address staker, IStrategyBase strategy, uint256 shares)
        external
        onlyStrategyManager
    {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];
            _increaseOperatorShares({operator: operator, staker: staker, strategy: strategy, shares: shares});
        }
    }

    function decreaseDelegatedShares(address staker, IStrategyBase strategy, uint256 shares)
        external
        onlyStrategyManager
    {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];
            _decreaseOperatorShares({operator: operator, staker: staker, strategy: strategy, shares: shares});
        }
    }

    function setStrategyWithdrawalDelayBlocks(
        IStrategyBase[] calldata strategies,
        uint256[] calldata withdrawalDelayBlocks
    ) external onlyOwner {
        _setStrategyWithdrawalDelayBlocks(strategies, withdrawalDelayBlocks);
    }

    /*******************************************************************************
                            INTERNAL FUNCTIONS
    *******************************************************************************/
    function _setOperatorDetails(address operator, OperatorDetails calldata newOperatorDetails) internal {
        //非零地址判断
        require(
            newOperatorDetails.earningsReceiver != address(0),
            "DelegationManager._setOperatorDetails: earningsReceiver cannot be address(0)"
        );
        //质押周期判断
        require(
            newOperatorDetails.stakerOptOutWindowBlocks <= MAX_STAKER_OPT_OUT_WINDOW_BLOCKS,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be > MAX_STAKER_OPT_OUT_WINDOW_BLOCKS"
        );
        require(
            newOperatorDetails.stakerOptOutWindowBlocks >= _operatorDetails[operator].stakerOptOutWindowBlocks,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be decreased"
        );
        _operatorDetails[operator] = newOperatorDetails;
        emit OperatorDetailsModified(msg.sender, newOperatorDetails);
    }

    function _delegate(
        address staker,
        address operator,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) internal {
        //判断staker是否已经委托给了某个operator，operator是否已经注册
        require(!isDelegated(staker), "DelegationManager._delegate: staker is already actively delegated");
        require(isOperator(operator), "DelegationManager._delegate: operator is not registered in MantaLayer");
        address _delegationApprover = _operatorDetails[operator].delegationApprover;

        //授权者验证
        if (_delegationApprover != address(0) && msg.sender != _delegationApprover && msg.sender != operator) {
            require(
                approverSignatureAndExpiry.expiry >= block.timestamp,
                "DelegationManager._delegate: Delegation approval signature expired"
            );
            require(
                !delegationApproverSaltIsSpent[_delegationApprover][approverSalt],
                "DelegationManager._delegate: approverSalt already spent"
            );
            delegationApproverSaltIsSpent[_delegationApprover][approverSalt] = true;

            bytes32 approverDigestHash = calculateDelegationApprovalDigestHash(
                staker, operator, _delegationApprover, approverSalt, approverSignatureAndExpiry.expiry
            );

            EIP1271SignatureUtils.checkSignature_EIP1271(
                _delegationApprover, approverDigestHash, approverSignatureAndExpiry.signature
            );
        }
        //将operator和staker的委托关系记录在链上
        delegatedTo[staker] = operator;
        emit StakerDelegated(staker, operator);
        //获取staker在各个策略中质押的shares
        (IStrategyBase[] memory strategies, uint256[] memory shares) = getDelegatableShares(staker);
        //将staker在各个策略中的质押份额shares 委托给 operator
        for (uint256 i = 0; i < strategies.length;) {
            //使用命名参数调用函数，提升可读性， 参数顺序可以任意调整
            _increaseOperatorShares({operator: operator, staker: staker, strategy: strategies[i], shares: shares[i]});
            //禁用溢出检查 节省gas
            unchecked {
                ++i;
            }
        }
    }

    function _setMinWithdrawalDelayBlocks(uint256 _minWithdrawalDelayBlocks) internal {
        require(
            _minWithdrawalDelayBlocks <= MAX_WITHDRAWAL_DELAY_BLOCKS,
            "DelegationManager._setMinWithdrawalDelayBlocks: _minWithdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS"
        );
        emit MinWithdrawalDelayBlocksSet(minWithdrawalDelayBlocks, _minWithdrawalDelayBlocks);
        minWithdrawalDelayBlocks = _minWithdrawalDelayBlocks;
    }

    function _setStrategyWithdrawalDelayBlocks(
        IStrategyBase[] calldata _strategies,
        uint256[] calldata _withdrawalDelayBlocks
    ) internal {
        require(
            _strategies.length == _withdrawalDelayBlocks.length,
            "DelegationManager._setStrategyWithdrawalDelayBlocks: Lengths of _strategies and _withdrawalDelayBlocks do not match"
        );
        for (uint256 i = 0; i < _strategies.length; i++) {
            IStrategyBase strategy = _strategies[i];
            uint256 prevStrategyWithdrawalDelayBlocks = strategyWithdrawalDelayBlocks[strategy];
            uint256 newStrategyWithdrawalDelayBlocks = _withdrawalDelayBlocks[i];
            require(
                newStrategyWithdrawalDelayBlocks <= MAX_WITHDRAWAL_DELAY_BLOCKS,
                "DelegationManager._setStrategyWithdrawalDelayBlocks: _withdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS"
            );
            strategyWithdrawalDelayBlocks[strategy] = newStrategyWithdrawalDelayBlocks;
            emit StrategyWithdrawalDelayBlocksSet(
                strategy, prevStrategyWithdrawalDelayBlocks, newStrategyWithdrawalDelayBlocks
            );
        }
    }

    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("MantaLayer")), block.chainid, address(this)));
    }

    function _increaseOperatorShares(address operator, address staker, IStrategyBase strategy, uint256 shares)
        internal
    {
        operatorShares[operator][strategy] += shares;
        emit OperatorSharesIncreased(operator, staker, strategy, shares);
    }

    function _decreaseOperatorShares(address operator, address staker, IStrategyBase strategy, uint256 shares)
        internal
    {
        operatorShares[operator][strategy] -= shares;
        emit OperatorSharesDecreased(operator, staker, strategy, shares);
    }

    function _removeSharesAndQueueWithdrawal(
        address staker,
        address operator,
        address withdrawer,
        IStrategyBase[] memory strategies,
        uint256[] memory shares
    ) internal returns (bytes32) {
        require(
            staker != address(0), "DelegationManager._removeSharesAndQueueWithdrawal: staker cannot be zero address"
        );
        require(strategies.length != 0, "DelegationManager._removeSharesAndQueueWithdrawal: strategies cannot be empty");
        for (uint256 i = 0; i < strategies.length;) {
            if (operator != address(0)) {
                //解除staker委托给operator的shares,若是全部取款，其实就是清零了
                _decreaseOperatorShares({
                    operator: operator, staker: staker, strategy: strategies[i], shares: shares[i]
                });
            }
            require(
                //如果thirdPartyTransfersForbidden为true，则withdrawer必须是staker自己
                staker == withdrawer || !i_strategyManager.thirdPartyTransfersForbidden(strategies[i]),
                "DelegationManager._removeSharesAndQueueWithdrawal: withdrawer must be same address as staker if thirdPartyTransfersForbidden are set"
            );
            //解除staker在策略中的shares
            i_strategyManager.removeShares(staker, strategies[i], shares[i]);
            unchecked {
                ++i;
            }
        }
        uint256 nonce = cumulativeWithdrawalsQueued[staker];
        cumulativeWithdrawalsQueued[staker]++;

        Withdrawal memory withdrawal = Withdrawal({
            staker: staker,
            delegatedTo: operator,
            withdrawer: withdrawer,
            nonce: nonce,
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: shares
        });

        bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);

        pendingWithdrawals[withdrawalRoot] = true;

        emit WithdrawalQueued(withdrawalRoot, withdrawal);
        return withdrawalRoot;
    }

    function _completeQueuedWithdrawal(Withdrawal memory withdrawal, IERC20 mantaToken) internal {
        bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);
        //判断withdrawalRoot是否在待处理排队取款队列中
        require(
            pendingWithdrawals[withdrawalRoot],
            "DelegationManager._completeQueuedWithdrawal: withdrawal not found in pendingWithdrawals queue"
        );
        //判断要提现的交易是否已经过了最小提款延迟区块数
        require(
            withdrawal.startBlock + minWithdrawalDelayBlocks <= block.number,
            "DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed"
        );
        //判断提现者是否正确
        require(
            msg.sender == withdrawal.withdrawer,
            "DelegationManager._completeQueuedWithdrawal: only withdrawer can complete action"
        );
        //将pendingWithdrawals中的取款请求删除
        delete pendingWithdrawals[withdrawalRoot];
        address currentOperator = delegatedTo[msg.sender];
        for (uint256 i = 0; i < withdrawal.strategies.length;) {
            //每个质押的策略都要检查是否过了该策略的提款延迟区块数
            require(
                withdrawal.startBlock + strategyWithdrawalDelayBlocks[withdrawal.strategies[i]] <= block.number,
                "DelegationManager._completeQueuedWithdrawal: withdrawalDelayBlocks period has not yet passed for this strategy"
            );
            //将shares转换成token并提现给withdrawer
            _withdrawSharesAsTokens({
                withdrawer: msg.sender,
                strategy: withdrawal.strategies[i],
                shares: withdrawal.shares[i],
                mantaToken: mantaToken
            });
            emit WithdrawalCompleted(currentOperator, msg.sender, withdrawal.strategies[i], withdrawal.shares[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _withdrawSharesAsTokens(address withdrawer, IStrategyBase strategy, uint256 shares, IERC20 mantaToken)
        internal
    {
        i_strategyManager.withdrawSharesAsTokens(withdrawer, strategy, shares, mantaToken);
    }

    /*******************************************************************************
                            VIEW FUNCTIONS
    *******************************************************************************/
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        } else {
            return _calculateDomainSeparator();
        }
    }

    function isDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] != address(0));
    }

    function isOperator(address operator) public view returns (bool) {
        return (_operatorDetails[operator].earningsReceiver != address(0));
    }

    function operatorDetails(address operator) external view returns (OperatorDetails memory) {
        return _operatorDetails[operator];
    }

    function getDelegatableShares(address staker) public view returns (IStrategyBase[] memory, uint256[] memory) {
        (IStrategyBase[] memory strategyManagerStrats, uint256[] memory strategyManagerShares) =
            i_strategyManager.getDeposits(staker);
        return (strategyManagerStrats, strategyManagerShares);
    }

    function calculateWithdrawalRoot(Withdrawal memory withdrawal) public pure returns (bytes32) {
        return keccak256(abi.encode(withdrawal));
    }

    function calculateCurrentStakerDelegationDigestHash(address staker, address operator, uint256 expiry)
        external
        view
        returns (bytes32)
    {
        uint256 currentStakerNonce = stakerNonce[staker];
        return calculateStakerDelegationDigestHash(staker, currentStakerNonce, operator, expiry);
    }

    function calculateStakerDelegationDigestHash(
        address staker,
        uint256 _stakerNonce,
        address operator,
        uint256 expiry
    ) public view returns (bytes32) {
        //计算质押者委托的类型hash
        bytes32 stakerStructHash =
            keccak256(abi.encode(STAKER_DELEGATION_TYPEHASH, staker, operator, _stakerNonce, expiry));
        //计算最终摘要哈希
        bytes32 stakerDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), stakerStructHash));
        return stakerDigestHash;
    }

    function calculateDelegationApprovalDigestHash(
        address staker,
        address operator,
        address _delegationApprover,
        bytes32 approverSalt,
        uint256 expiry
    ) public view returns (bytes32) {
        //委托批准的类型哈希，用于验证operator批准者的签名
        bytes32 approverStructHash = keccak256(
            abi.encode(DELEGATION_APPROVAL_TYPEHASH, staker, operator, _delegationApprover, approverSalt, expiry)
        );
        bytes32 approverDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), approverStructHash));
        return approverDigestHash;
    }

    function earningsReceiver(address operator) external view returns (address) {
        return _operatorDetails[operator].earningsReceiver;
    }

    function delegationApprover(address operator) external view returns (address) {
        return _operatorDetails[operator].delegationApprover;
    }

    //获取操作员的质押者选择退出窗口期（区块数）
    function stakerOptOutWindowBlocks(address operator) external view returns (uint256) {
        return _operatorDetails[operator].stakerOptOutWindowBlocks;
    }

    function getOperatorShares(address operator, IStrategyBase[] memory strategies)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory shares = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; ++i) {
            shares[i] = operatorShares[operator][strategies[i]];
        }
        return shares;
    }

    function getWithdrawalDelay(IStrategyBase[] calldata strategies) public view returns (uint256) {
        uint256 withdrawalDelay = minWithdrawalDelayBlocks;
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 strategyDelay = strategyWithdrawalDelayBlocks[strategies[i]];
            if (strategyDelay > withdrawalDelay) {
                withdrawalDelay = strategyDelay;
            }
        }
        return withdrawalDelay;
    }
}
