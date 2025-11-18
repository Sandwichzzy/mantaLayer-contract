// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "src/access/interfaces/IPausable.sol";

contract Pausable is IPausable {
    IPauserRegistry public pauserRegistry;

    //每一位（bit）代表一个功能的暂停状态：0=运行，1=暂停
    uint256 private _paused; // 用一个 uint256（256位）来表示暂停状态

    uint256 internal constant UNPAUSE_ALL = 0; // 全部解除：0000...0000
    uint256 internal constant PAUSE_ALL = type(uint256).max; // 全部暂停：1111...1111

    modifier onlyPauser() {
        require(pauserRegistry.isPauser(msg.sender), "msg.sender is not permissioned as pauser");
        _;
    }

    modifier onlyUnpauser() {
        require(msg.sender == pauserRegistry.unpauser(), "msg.sender is not permissioned as unpauser");
        _;
    }

    modifier whenNotPaused() {
        require(_paused == 0, "Pausable: contract is paused");
        _;
    }

    // 只有当功能索引index没有被暂停时才能执行
    modifier onlyWhenNotPaused(uint8 index) {
        require(!paused(index), "Pausable: index is paused");
        _;
    }

    function _initializePauser(IPauserRegistry _pauserRegistry, uint256 initPausedStatus) internal {
        require(
            address(pauserRegistry) == address(0) && address(_pauserRegistry) != address(0),
            "Pausable._initializePauser: _initializePauser() can only be called once"
        );
        _paused = initPausedStatus;
        emit Paused(msg.sender, initPausedStatus);
        _setPauserRegistry(_pauserRegistry);
    }

    function pause(uint256 newPausedStatus) external onlyPauser {
        // 关键检查：确保pauser只能"增加"暂停，不能"减少"暂停
        // 解释：(_paused & newPausedStatus) == _paused
        // 意思是：新状态必须包含所有旧状态已暂停的位
        // 例如：_paused = 0011, newPausedStatus 只能是 0011, 0111, 1011, 1111 等
        // 0011 & 0111 = 0011 ✓ 等于 _paused
        //      不能是 0001（这会解除第2位的暂停，只有 unpauser 能做）
        require((_paused & newPausedStatus) == _paused, "Pausable.pause: invalid attempt to unpause functionality");
        _paused = newPausedStatus;
        emit Paused(msg.sender, newPausedStatus);
    }

    function pauseAll() external onlyPauser {
        _paused = type(uint256).max;
        emit Paused(msg.sender, type(uint256).max);
    }

    /* 确保unpauser只能"减少"暂停，不能"增加"暂停
        (~_paused) 对 _paused 按位取反，把暂停位变成运行位
        检查 ((~_paused) & (~newPausedStatus)) == (~_paused)
        意思是：新状态的"运行位"必须包含所有旧状态的"运行位"

        当前状态 _paused = 0110 (功能1和2被暂停)
        取反后 ~_paused = 1001 (功能0和3在运行)
        ✅允许: newPausedStatus = 0010 (解除功能1的暂停)
            ~newPausedStatus = 1101
            1001 & 1101 = 1001 ✓ 等于 ~_paused

        ❌拒绝: newPausedStatus = 1110 (试图添加功能3的暂停)
            ~newPausedStatus = 0001
            1001 & 0001 = 0001 ✗ 不等于 ~_paused
    */
    function unpause(uint256 newPausedStatus) external onlyUnpauser {
        require(
            ((~_paused) & (~newPausedStatus)) == (~_paused), "Pausable.unpause: invalid attempt to pause functionality"
        );
        _paused = newPausedStatus;
        emit Unpaused(msg.sender, newPausedStatus);
    }

    function paused() public view virtual returns (uint256) {
        return _paused;
    }

    function paused(uint8 index) public view virtual returns (bool) {
        // 创建一个掩码（mask），只有第 index 位是 1
        // 例如：index=2 时，mask = 0100
        uint256 mask = 1 << index;
        // 检查 _paused 的第 index 位是否为 1
        // 如果 (_paused & mask) == mask，说明该位被暂停了
        return ((_paused & mask) == mask);
    }

    function setPauserRegistry(IPauserRegistry newPauserRegistry) external onlyUnpauser {
        _setPauserRegistry(newPauserRegistry);
    }

    function _setPauserRegistry(IPauserRegistry newPauserRegistry) internal {
        require(
            address(newPauserRegistry) != address(0),
            "Pausable._setPauserRegistry: newPauserRegistry cannot be the zero address"
        );
        emit PauserRegistrySet(pauserRegistry, newPauserRegistry);
        pauserRegistry = newPauserRegistry;
    }

    uint256[100] private __gap; //  这是为可升级合约预留的存储空间，防止未来添加新变量时破坏存储布局。
}
