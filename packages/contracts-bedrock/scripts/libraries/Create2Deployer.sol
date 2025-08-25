// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import { console } from "forge-std/console.sol";

/// @title Create2Deployer
/// @notice This contract is used to deploy contracts to a deterministic address using CREATE2.
contract Create2Deployer {
    function performCreate2(bytes memory _initCode, bytes32 _salt) public returns (address payable addr_) {
        assembly {
            addr_ := create2(0, add(_initCode, 0x20), mload(_initCode), _salt)
        }
        require(addr_ != address(0), "CREATE2 failed");
    }

    function computeAddress(bytes memory _initCode, bytes32 _salt) public view returns (address) {
        bytes32 initCodeHash = keccak256(_initCode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, initCodeHash)))));
    }
}
