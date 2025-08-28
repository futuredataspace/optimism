// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// 只引接口
import {ISuperchainConfig} from "interfaces/L1/ISuperchainConfig.sol";
import {ISystemConfig} from "interfaces/L1/ISystemConfig.sol";
import {IL1CrossDomainMessenger} from "interfaces/L1/IL1CrossDomainMessenger.sol";
import {IL1StandardBridge} from "interfaces/L1/IL1StandardBridge.sol";
import {IL1ERC721Bridge} from "interfaces/L1/IL1ERC721Bridge.sol";
import {IOptimismPortal2 as IOptimismPortal} from "interfaces/L1/IOptimismPortal2.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IAnchorStateRegistry} from "interfaces/dispute/IAnchorStateRegistry.sol";
import {IETHLockbox} from "interfaces/L1/IETHLockbox.sol";
import {IResourceMetering} from "interfaces/L1/IResourceMetering.sol";

// 最小初始化接口
interface IProxyAdmin { function transferOwnership(address newOwner) external; }

interface ISystemConfigInit {
    struct Addresses {
        address l1CrossDomainMessenger;
        address l1ERC721Bridge;
        address l1StandardBridge;
        address optimismPortal;
        address optimismMintableERC20Factory;
    }
    function initialize(
        address _owner,
        uint32 _basefeeScalar,
        uint32 _blobbasefeeScalar,
        bytes32 _batcherHash,
        uint64 _gasLimit,
        address _unsafeBlockSigner,
        IResourceMetering.ResourceConfig calldata _config,
        address _batchInboxAddress,
        Addresses calldata _addrs,
        uint256 _l2ChainId,
        ISuperchainConfig _superchainConfig
    ) external;
}

interface IOptimismPortalInit {
    function initialize(
        ISystemConfig _systemConfig,
        IAnchorStateRegistry _anchorStateRegistry,
        IETHLockbox _ethLockbox
    ) external;
}

interface IL1CDMInit {
    function initialize(
        ISystemConfig _systemConfig,
        IOptimismPortal _optimismPortal
    ) external;
}

interface IL1StandardBridgeInit {
    function initialize(
        IL1CrossDomainMessenger _cdm,
        ISystemConfig _systemConfig
    ) external;
}

interface IL1ERC721BridgeInit {
    function initialize(
        IL1CrossDomainMessenger _cdm,
        ISystemConfig _systemConfig
    ) external;
}

interface IDisputeGameFactoryInit { function initialize(address _owner) external; }

interface IAnchorStateRegistryInit {
    struct Proposal { bytes32 root; uint256 l2SequenceNumber; }
    function initialize(
        ISystemConfig _systemConfig,
        IDisputeGameFactory _factory,
        Proposal calldata _startingAnchor,
        uint8 _gameType
    ) external;
}

contract ApertiumExecutor is Script {
    uint8 constant GAME_TYPE_CANNON = 0;

    function initializeSystemFlat(
        address systemConfigProxy,
        address optimismPortalProxy,
        address l1CrossDomainMessengerProxy,
        address l1StandardBridgeProxy,
        address disputeGameFactoryProxy,
        address anchorStateRegistryProxy,
        address l1ERC721BridgeProxy,
        address superchainConfigProxy,
        address finalSystemOwner,
        uint32 basefeeScalar,
        uint32 blobbasefeeScalar,
        uint64 l2GenesisBlockGasLimit,
        address p2pSequencerAddress,
        uint256 l1ChainID,
        uint256 l2ChainID,
        uint256 l2OutputOracleStartingBlockNumber
    ) public {
        console.log("APERTIUM EXECUTOR | Initializing System (flat)...");
        vm.startBroadcast();

        // 1) SystemConfig
        IResourceMetering.ResourceConfig memory rc = _getResourceConfig();
        ISystemConfigInit.Addresses memory addrs = ISystemConfigInit.Addresses({
            l1CrossDomainMessenger: l1CrossDomainMessengerProxy,
            l1ERC721Bridge:        l1ERC721BridgeProxy,
            l1StandardBridge:      l1StandardBridgeProxy,
            optimismPortal:        optimismPortalProxy,
            optimismMintableERC20Factory: address(0)
        });
        ISystemConfigInit(systemConfigProxy).initialize(
            finalSystemOwner,
            basefeeScalar,
            blobbasefeeScalar,
            bytes32(0),
            l2GenesisBlockGasLimit,
            p2pSequencerAddress,
            rc,
            _getBatchInbox(l1ChainID),
            addrs,
            l2ChainID,
            ISuperchainConfig(superchainConfigProxy)
        );

        // 2) OptimismPortal
        IOptimismPortalInit(optimismPortalProxy).initialize(
            ISystemConfig(systemConfigProxy),
            IAnchorStateRegistry(anchorStateRegistryProxy),
            IETHLockbox(address(0))
        );

        // 3) L1CrossDomainMessenger
        IL1CDMInit(l1CrossDomainMessengerProxy).initialize(
            ISystemConfig(systemConfigProxy),
            // IOptimismPortal2 有 payable fallback，必须强转 payable
            IOptimismPortal(payable(optimismPortalProxy))
        );

        // 4) L1StandardBridge
        IL1StandardBridgeInit(l1StandardBridgeProxy).initialize(
            IL1CrossDomainMessenger(l1CrossDomainMessengerProxy),
            ISystemConfig(systemConfigProxy)
        );

        // 5) L1ERC721Bridge
        IL1ERC721BridgeInit(l1ERC721BridgeProxy).initialize(
            IL1CrossDomainMessenger(l1CrossDomainMessengerProxy),
            ISystemConfig(systemConfigProxy)
        );

        // 6) DisputeGameFactory
        IDisputeGameFactoryInit(disputeGameFactoryProxy).initialize(finalSystemOwner);

        // 7) AnchorStateRegistry —— 仅当 DGF 已有 CANNON 实现时才初始化
        bool dgfReady = _dgfHasCannonImpl(disputeGameFactoryProxy, l2ChainID);
        if (!dgfReady) {
            //console.log("⚠️  DGF has no readable CANNON implementation; skipping AnchorStateRegistry.initialize for now.");
            console.log("WARNING: DGF has no readable CANNON implementation; skipping AnchorStateRegistry.initialize for now.");
        } else {
            IAnchorStateRegistryInit.Proposal memory startingAnchor =
                IAnchorStateRegistryInit.Proposal({
                    root: bytes32(0),
                    l2SequenceNumber: l2OutputOracleStartingBlockNumber
                });
            IAnchorStateRegistryInit(anchorStateRegistryProxy).initialize(
                ISystemConfig(systemConfigProxy),
                IDisputeGameFactory(disputeGameFactoryProxy),
                startingAnchor,
                GAME_TYPE_CANNON
            );
        }

        vm.stopBroadcast();
        console.log("[SUCCESS] APERTIUM EXECUTOR | System initialized (Anchor init skipped? ", !dgfReady, ").");
    }

    function finalizeOwnership(address proxyAdmin, address finalSystemOwner) public {
        console.log("APERTIUM EXECUTOR | Finalizing Ownership...");
        vm.startBroadcast();
        IProxyAdmin(proxyAdmin).transferOwnership(finalSystemOwner);
        vm.stopBroadcast();
        console.log("[SUCCESS] APERTIUM EXECUTOR | Ownership finalized.");
    }

    // ---------------- internal helpers ----------------

    function _getResourceConfig() internal pure returns (IResourceMetering.ResourceConfig memory) {
        return IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: uint8(10),
            baseFeeMaxChangeDenominator: uint8(8),
            minimumBaseFee: 1,
            systemTxMaxGas: 1_000_000,
            maximumBaseFee: 10_000_000_000_000_000_000
        });
    }

    function _getBatchInbox(uint256 _l1ChainID) internal pure returns (address) {
        return (_l1ChainID == 901)
            ? 0xFf00000000000000000000000000000000000901
            : 0xfF00000000000000000000000000000000000000;
    }

    // 仅“检查”是否存在实现：用多种常见签名读取，全部失败/回退则视为“未配置”
    function _dgfHasCannonImpl(address dgf, uint256 l2ChainId) internal view returns (bool ok) {
        // 1) gameImpls(uint8,uint256) -> address
        (ok, ) = dgf.staticcall(abi.encodeWithSignature("gameImpls(uint8,uint256)", GAME_TYPE_CANNON, l2ChainId));
        if (ok) return true;

        // 2) gameImpls(uint8) -> address
        (ok, ) = dgf.staticcall(abi.encodeWithSignature("gameImpls(uint8)", GAME_TYPE_CANNON));
        if (ok) return true;

        // 3) getGameImplementation(uint8,uint256) -> address
        (ok, ) = dgf.staticcall(
            abi.encodeWithSignature("getGameImplementation(uint8,uint256)", GAME_TYPE_CANNON, l2ChainId)
        );
        if (ok) return true;

        // 4) getGameImplementation(uint8) -> address
        (ok, ) = dgf.staticcall(abi.encodeWithSignature("getGameImplementation(uint8)", GAME_TYPE_CANNON));
        return ok;
    }
}
