// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";

contract DeployL1StandardBridge is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_FOR_TEST");

        vm.startBroadcast(deployerPrivateKey);

        L1StandardBridge bridge = new L1StandardBridge();

        vm.stopBroadcast();

        console.log("L1StandardBridge implementation deployed to:", address(bridge));
    }
}
