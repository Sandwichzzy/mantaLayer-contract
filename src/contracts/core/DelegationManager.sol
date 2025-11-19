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
    {
        _delegate(msg.sender, operator, approverSignatureAndExpiry, approverSalt);
    }

    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external {
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

    function setMinWithdrawalDelayBlocks(uint256 newMinWithdrawalDelayBlocks) external onlyOwner {
        _setMinWithdrawalDelayBlocks(newMinWithdrawalDelayBlocks);
    }

    function increaseDelegatedShares(address staker, IStrategyBase strategy, uint256 shares)
        external
        onlyStrategyManager
    {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];
            _increaseOperatorShares(operator, staker, strategy, shares);
        }
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

    function getDelegatableShares(address staker) public view returns (IStrategyBase[] memory, uint256[] memory) {
        (IStrategyBase[] memory strategyManagerStrats, uint256[] memory strategyManagerShares) =
            i_strategyManager.getDeposits(staker);
        return (strategyManagerStrats, strategyManagerShares);
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
}
