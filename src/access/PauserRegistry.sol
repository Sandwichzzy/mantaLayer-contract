// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "src/access/interfaces/IPauserRegistry.sol";

contract PauserRegistry is IPauserRegistry {
    mapping(address => bool) public isPauser; // 多个 pauser 可以：暂停功能（不能解除）

    address public unpauser; // 唯一的 unpauser 可以：解除暂停、设置新的 pauser、更换 unpauser

    modifier onlyUnpauser() {
        require(msg.sender == unpauser, "msg.sender is not permissioned as unpauser");
        _;
    }

    constructor(address[] memory _pausers, address _unpauser) {
        for (uint256 i = 0; i < _pausers.length; i++) {
            isPauser[_pausers[i]] = true;
        }
        _setUnpauser(_unpauser);
    }

    function setIsPauser(address newPauser, bool canPause) external onlyUnpauser {
        _setIsPauser(newPauser, canPause);
    }

    function setUnpauser(address newUnpauser) external onlyUnpauser {
        _setUnpauser(newUnpauser);
    }

    function _setIsPauser(address pauser, bool canPause) internal {
        require(pauser != address(0), "PauserRegistry._setPauser: zero address input");
        isPauser[pauser] = canPause;
        emit PauserStatusChanged(pauser, canPause);
    }

    function _setUnpauser(address newUnpauser) internal {
        require(newUnpauser != address(0), "PauserRegistry._setUnpauser: zero address input");
        emit UnpauserChanged(unpauser, newUnpauser);
        unpauser = newUnpauser;
    }
}
