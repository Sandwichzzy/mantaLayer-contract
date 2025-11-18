// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

interface IPauserRegistry {
    event PauserStatusChanged(address pauser, bool canPause);

    event UnpauserChanged(address previousUnpauser, address newUnpauser);

    function isPauser(address pauser) external view returns (bool);

    function unpauser() external view returns (address);

    function setIsPauser(address newPauser, bool canPause) external;

    function setUnpauser(address newUnpauser) external;
}
