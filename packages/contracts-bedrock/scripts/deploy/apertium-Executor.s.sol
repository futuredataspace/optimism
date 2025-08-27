// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/* ─────────────────────────────────────────────────────────────────────────────
   仅保留最小接口，避免 import src/ 与 interfaces/ 造成全仓库编译
   ───────────────────────────────────────────────────────────────────────────── */

// SuperchainConfig 仅作类型占位（SystemConfig.initialize 需要）
interface ISuperchainConfig {}

// SystemConfig 最小接口（签名与参数布局需与实现保持一致）
interface ISystemConfig {
    struct ResourceConfig {
        uint32  maxResourceLimit;
        uint8   elasticityMultiplier;
        uint8   baseFeeMaxChangeDenominator;
        uint256 minimumBaseFee;
        uint256 systemTxMaxGas;
        uint256 maximumBaseFee;
    }

    struct Addresses {
        address l1CrossDomainMessenger;
        address l1ERC721Bridge;
        address l1StandardBridge;
        address optimismPortal;
        address optimismMintableERC20Factory;
    }

    function initialize(
        address                _owner,
        uint32                 _basefeeScalar,
        uint32                 _blobbasefeeScalar,
        bytes32                _batcherHash,
        uint64                 _l2GenesisBlockGasLimit,
        address                _unsafeBlockSigner,
        ResourceConfig calldata _resourceConfig,
        address                _batchInbox,
        Addresses calldata     _addresses,
        uint256                _l2ChainID,
        ISuperchainConfig      _superchainConfig
    ) external;
}

// OptimismPortal2 最小接口
interface IOptimismPortal2 {
    function initialize(
        ISystemConfig        _systemConfig,
        address              _anchorStateRegistry, // 作为 IAnchorStateRegistry 传入地址也可
        address              _ethLockbox          // 可为 address(0)
    ) external;
}

// L1CrossDomainMessenger 最小接口
interface IL1CrossDomainMessenger {
    function initialize(
        ISystemConfig   _systemConfig,
        IOptimismPortal2 _portal
    ) external;
}

// L1StandardBridge 最小接口
interface IL1StandardBridge {
    function initialize(
        IL1CrossDomainMessenger _messenger,
        ISystemConfig           _systemConfig
    ) external;
}

// L1ERC721Bridge 最小接口
interface IL1ERC721Bridge {
    function initialize(
        IL1CrossDomainMessenger _messenger,
        ISystemConfig           _systemConfig
    ) external;
}

// DisputeGameFactory 最小接口
interface IDisputeGameFactory {
    function initialize(address _owner) external;
}

// AnchorStateRegistry 最小接口（Proposal / GameTypes 简化）
interface IAnchorStateRegistry {
    struct Proposal {
        bytes32 root;            // 等价于 Types.Hash.wrap(bytes32)
        uint256 l2SequenceNumber;
    }

    // 注意：Bedrock 中 CANNON 的枚举值为 0，这里只声明一个即可
    enum GameTypes { CANNON }

    function initialize(
        ISystemConfig        _systemConfig,
        IDisputeGameFactory  _factory,
        Proposal calldata    _startingAnchor,
        GameTypes            _gameType
    ) external;
}

// ProxyAdmin 最小接口
interface IProxyAdmin {
    function transferOwnership(address newOwner) external;
}

/* ─────────────────────────────────────────────────────────────────────────────
   ApertiumExecutor（扁平参数版本）
   ───────────────────────────────────────────────────────────────────────────── */

contract ApertiumExecutor is Script {

    /// @notice 直接用扁平参数，避免 struct 造成脚本 CLI 传参复杂化
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
        uint32  basefeeScalar,
        uint32  blobbasefeeScalar,
        uint64  l2GenesisBlockGasLimit,
        address p2pSequencerAddress,
        uint256 l1ChainID,
        uint256 l2ChainID,
        uint256 l2OutputOracleStartingBlockNumber
    ) public {
        console.log("APERTIUM EXECUTOR | Initializing System...");
        vm.startBroadcast();

        // 1) SystemConfig.initialize
        ISystemConfig.ResourceConfig memory resourceConfig = _getResourceConfig();
        ISystemConfig.Addresses memory addrs = ISystemConfig.Addresses({
            l1CrossDomainMessenger: l1CrossDomainMessengerProxy,
            l1ERC721Bridge:         l1ERC721BridgeProxy,
            l1StandardBridge:       l1StandardBridgeProxy,
            optimismPortal:         optimismPortalProxy,
            optimismMintableERC20Factory: address(0)
        });

        ISystemConfig(systemConfigProxy).initialize(
            finalSystemOwner,
            basefeeScalar,
            blobbasefeeScalar,
            bytes32(0),                 // _batcherHash
            l2GenesisBlockGasLimit,
            p2pSequencerAddress,        // _unsafeBlockSigner
            resourceConfig,
            _getBatchInbox(l1ChainID),  // _batchInbox
            addrs,
            l2ChainID,
            ISuperchainConfig(superchainConfigProxy)
        );

        // 2) OptimismPortal.initialize
        IOptimismPortal2(optimismPortalProxy).initialize(
            ISystemConfig(systemConfigProxy),
            anchorStateRegistryProxy,      // 直接传地址
            address(0)                     // IETHLockbox(0)
        );

        // 3) L1CrossDomainMessenger.initialize
        IL1CrossDomainMessenger(l1CrossDomainMessengerProxy).initialize(
            ISystemConfig(systemConfigProxy),
            IOptimismPortal2(optimismPortalProxy)
        );

        // 4) L1StandardBridge.initialize
        IL1StandardBridge(l1StandardBridgeProxy).initialize(
            IL1CrossDomainMessenger(l1CrossDomainMessengerProxy),
            ISystemConfig(systemConfigProxy)
        );

        // 5) L1ERC721Bridge.initialize
        IL1ERC721Bridge(l1ERC721BridgeProxy).initialize(
            IL1CrossDomainMessenger(l1CrossDomainMessengerProxy),
            ISystemConfig(systemConfigProxy)
        );

        // 6) DisputeGameFactory.initialize
        IDisputeGameFactory(disputeGameFactoryProxy).initialize(finalSystemOwner);

        // 7) AnchorStateRegistry.initialize
        IAnchorStateRegistry.Proposal memory startingAnchor = IAnchorStateRegistry.Proposal({
            root: bytes32(0),
            l2SequenceNumber: l2OutputOracleStartingBlockNumber
        });
        IAnchorStateRegistry(anchorStateRegistryProxy).initialize(
            ISystemConfig(systemConfigProxy),
            IDisputeGameFactory(disputeGameFactoryProxy),
            startingAnchor,
            IAnchorStateRegistry.GameTypes.CANNON
        );

        vm.stopBroadcast();
        console.log("[SUCCESS] APERTIUM EXECUTOR | System initialized.");
    }

    function finalizeOwnership(address proxyAdmin, address finalSystemOwner) public {
        console.log("APERTIUM EXECUTOR | Finalizing Ownership...");
        vm.startBroadcast();
        IProxyAdmin(proxyAdmin).transferOwnership(finalSystemOwner);
        vm.stopBroadcast();
        console.log("[SUCCESS] APERTIUM EXECUTOR | Ownership finalized.");
    }

    // ---- Internal helpers ----

    function _getResourceConfig() internal pure returns (ISystemConfig.ResourceConfig memory) {
        return ISystemConfig.ResourceConfig({
            maxResourceLimit:           20_000_000,
            elasticityMultiplier:       10,
            baseFeeMaxChangeDenominator: 8,
            minimumBaseFee:             1,
            systemTxMaxGas:             1_000_000,
            maximumBaseFee:             10_000_000_000_000_000_000
        });
    }

    function _getBatchInbox(uint256 _l1ChainID) internal pure returns (address) {
        // 901 = Sepolia；Holesky(17000) 等统一走 devnet 常量地址（OP Stack 常用）
        if (_l1ChainID == 901) {
            return 0xFf00000000000000000000000000000000000901;
        } else {
            return 0xfF00000000000000000000000000000000000000;
        }
    }
}
