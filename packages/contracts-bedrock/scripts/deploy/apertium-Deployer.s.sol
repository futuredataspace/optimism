// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

// Forge Standard Library
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

// Apertium Utilities & Naming Conventions
import { DeployConfig } from "scripts/deploy/DeployConfig.s.sol";
import { Artifacts } from "scripts/Artifacts.s.sol";
import { DeployUtils } from "scripts/libraries/DeployUtils.sol";

// Verified Contract Implementations (to be deployed)
import { ProxyAdmin } from "op-contracts-universal/ProxyAdmin.sol";
import { SuperchainConfig } from "src/L1/SuperchainConfig.sol";
import { ProtocolVersions } from "src/L1/ProtocolVersions.sol";
import { SystemConfig } from "src/L1/SystemConfig.sol";
import { L1CrossDomainMessenger } from "src/L1/L1CrossDomainMessenger.sol";
import { L1ERC721Bridge } from "src/L1/L1ERC721Bridge.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";
import { OptimismPortal2 as OptimismPortalImpl } from "src/L1/OptimismPortal2.sol"; // Using 'as' for clarity
import { DisputeGameFactory } from "src/dispute/DisputeGameFactory.sol";
import { AnchorStateRegistry } from "src/dispute/AnchorStateRegistry.sol";
import { AddressManager } from "src/legacy/AddressManager.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Verified Structs & Enums (for function arguments)
import { Proposal, GameTypes, Hash } from "src/dispute/lib/Types.sol";

// Verified Interfaces (for type casting and initialization calls)
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IProtocolVersions, ProtocolVersion } from "interfaces/L1/IProtocolVersions.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";


/// @title ApertiumDeployer
/// @notice 专用于 Apertium L2 的分阶段 L1 部署脚本。
/// @custom:version 1.0.0
contract ApertiumDeployer is Script {

    // --- State variables ---
    DeployConfig internal cfg;
    Artifacts    internal artifacts;

    // ====================================================================================
    //
    //                                  STAGE 1: SUPERCHAIN
    //
    // ====================================================================================
    // 目标：部署与特定链无关的超级链基础设施。
    // 产出：生成 apertium-1-superchain-contracts.json
    // ====================================================================================

    function deployStage1_Superchain() public {
        _setup("apertium-1-superchain-contracts.json");
        console.log("APERTIUM DEPLOYER | STAGE 1: Deploying Superchain Contracts...");

        // 1. Generate a deterministic salt.
        bytes32 salt = keccak256(abi.encodePacked("apertium.superchain", cfg.getSaltMixer()));

        // 2. Deploy the SuperchainProxyAdmin.
        address proxyAdminOwner = msg.sender; // Initially owned by the deployer.
        bytes32 proxyAdminSalt = keccak256(abi.encodePacked("ProxyAdmin", salt));
        ProxyAdmin superchainProxyAdmin = new ProxyAdmin{salt: proxyAdminSalt}(proxyAdminOwner);
        artifacts.save("SuperchainProxyAdmin", address(superchainProxyAdmin));

        // 3. Deploy SuperchainConfig (Impl + Proxy) and initialize.
        bytes32 scImplSalt = keccak256(abi.encodePacked("SuperchainConfigImpl", salt));
        SuperchainConfig scImpl = new SuperchainConfig{salt: scImplSalt}();
        artifacts.save("SuperchainConfigImpl", address(scImpl));

        address scProxyAddr = _deployProxy("SuperchainConfigProxy", salt, address(scImpl), superchainProxyAdmin);
        artifacts.save("SuperchainConfigProxy", scProxyAddr);

        vm.startPrank(proxyAdminOwner);
        ISuperchainConfig(payable(scProxyAddr)).initialize(cfg.superchainConfigGuardian());

        // 4. Deploy ProtocolVersions (Impl + Proxy) and initialize.
        bytes32 pvImplSalt = keccak256(abi.encodePacked("ProtocolVersionsImpl", salt));
        ProtocolVersions pvImpl = new ProtocolVersions{salt: pvImplSalt}();
        artifacts.save("ProtocolVersionsImpl", address(pvImpl));

        address pvProxyAddr = _deployProxy("ProtocolVersionsProxy", salt, address(pvImpl), superchainProxyAdmin);
        artifacts.save("ProtocolVersionsProxy", pvProxyAddr);

        IProtocolVersions(payable(pvProxyAddr)).initialize(
            cfg.finalSystemOwner(),
            ProtocolVersion.wrap(cfg.requiredProtocolVersion()),
            ProtocolVersion.wrap(cfg.recommendedProtocolVersion())
        );

        // 5. Transfer ownership of the ProxyAdmin to the final owner.
        superchainProxyAdmin.transferOwnership(cfg.finalSystemOwner());
        vm.stopPrank();

        console.log("[SUCCESS] APERTIUM DEPLOYER | STAGE 1: Superchain contracts deployed.");
    }

    // ====================================================================================
    //
    //                                STAGE 2: IMPLEMENTATIONS
    //
    // ====================================================================================
    // 目标：仅部署所有 OP-Chain 核心合约的逻辑实现，不进行初始化。
    // 产出：生成 apertium-2-implementation-contracts.json
    // ====================================================================================

    function deployStage2_Implementations() public {
        _setup("apertium-2-implementation-contracts.json");
        console.log("APERTIUM DEPLOYER | STAGE 2: Deploying Implementation Contracts...");

        // 1. Generate a deterministic salt.
        bytes32 salt = keccak256(abi.encodePacked("apertium.implementations", cfg.getSaltMixer()));

        // 2. Batch deploy all implementation contracts using the same salt.
        // For contracts needing constructor args, they are read from the config.
        uint256 proofMaturityDelaySeconds = cfg.proofMaturityDelaySeconds();
        uint256 disputeGameFinalityDelaySeconds = cfg.disputeGameFinalityDelaySeconds();

        // Note: We use `new Contract{salt: salt}()` to perform a deterministic deployment.
        // The resulting address is predictable. We then save these addresses to the artifact file.
        artifacts.save("AddressManagerImpl", address(new AddressManager{salt: salt}()));
        artifacts.save("SystemConfigImpl", address(new SystemConfig{salt: salt}()));
        artifacts.save("L1CrossDomainMessengerImpl", address(new L1CrossDomainMessenger{salt: salt}()));
        artifacts.save("L1ERC721BridgeImpl", address(new L1ERC721Bridge{salt: salt}()));
        artifacts.save("L1StandardBridgeImpl", address(new L1StandardBridge{salt: salt}()));
        artifacts.save("OptimismPortalImpl", address(new OptimismPortalImpl{salt: salt}(proofMaturityDelaySeconds)));
        artifacts.save("DisputeGameFactoryImpl", address(new DisputeGameFactory{salt: salt}()));
        artifacts.save("AnchorStateRegistryImpl", address(new AnchorStateRegistry{salt: salt}(disputeGameFinalityDelaySeconds)));

        console.log("[SUCCESS] APERTIUM DEPLOYER | STAGE 2: Implementation contracts deployed.");
    }

    // ====================================================================================
    //
    //                               STAGE 3: PROXIES & INIT
    //
    // ====================================================================================
    // 目标：部署代理合约，并使用前两个阶段的成果来初始化整个系统。
    // 产出：生成 apertium-3-opchain-contracts.json
    // ====================================================================================

    function deployStage3_ProxiesAndInit() public {
        // [关键] 加载前两个阶段的构件文件
        vm.envString("DEPLOYMENT_OUTFILE", "generated/apertium-1-superchain-contracts.json");
        Artifacts memory artifactsS1 = new Artifacts();
        artifactsS1.setUp();

        vm.envString("DEPLOYMENT_OUTFILE", "generated/apertium-2-implementation-contracts.json");
        Artifacts memory artifactsS2 = new Artifacts();
        artifactsS2.setUp();

        _setup("apertium-3-opchain-contracts.json");
        console.log("APERTIUM DEPLOYER | STAGE 3: Deploying Proxies and Initializing System...");

        // 1. Generate a deterministic salt for this OP-Chain's proxies.
        bytes32 salt = keccak256(abi.encodePacked("apertium.opchain", cfg.getSaltMixer()));

        // 2. Deploy a new ProxyAdmin for this OP-Chain.
        address proxyAdminOwner = msg.sender; // Initially owned by the deployer.
        bytes32 opProxyAdminSalt = keccak256(abi.encodePacked("ProxyAdmin", salt));
        ProxyAdmin opProxyAdmin = new ProxyAdmin{salt: opProxyAdminSalt}(proxyAdminOwner);
        artifacts.save("ProxyAdmin", address(opProxyAdmin));

        // 3. Deploy proxies for all implementation contracts.
        address amProxyAddr = _deployProxy("AddressManagerProxy", salt, artifactsS2.mustGetAddress("AddressManagerImpl"), opProxyAdmin);
        address scProxyAddr = _deployProxy("SystemConfigProxy", salt, artifactsS2.mustGetAddress("SystemConfigImpl"), opProxyAdmin);
        address opProxyAddr = _deployProxy("OptimismPortalProxy", salt, artifactsS2.mustGetAddress("OptimismPortalImpl"), opProxyAdmin);
        address l1cdmProxyAddr = _deployProxy("L1CrossDomainMessengerProxy", salt, artifactsS2.mustGetAddress("L1CrossDomainMessengerImpl"), opProxyAdmin);
        address l1sbProxyAddr = _deployProxy("L1StandardBridgeProxy", salt, artifactsS2.mustGetAddress("L1StandardBridgeImpl"), opProxyAdmin);
        address dgfProxyAddr = _deployProxy("DisputeGameFactoryProxy", salt, artifactsS2.mustGetAddress("DisputeGameFactoryImpl"), opProxyAdmin);
        address asrProxyAddr = _deployProxy("AnchorStateRegistryProxy", salt, artifactsS2.mustGetAddress("AnchorStateRegistryImpl"), opProxyAdmin);
        address l1e721bProxyAddr = _deployProxy("L1ERC721BridgeProxy", salt, artifactsS2.mustGetAddress("L1ERC721BridgeImpl"), opProxyAdmin);
        artifacts.save("L2OutputOracleProxy", opProxyAddr); // L2OO is an alias for OptimismPortal

        // 4. Prepare all necessary structs and addresses for initialization.
        ISystemConfig.Addresses memory addresses = _getAddresses(l1cdmProxyAddr, l1e721bProxyAddr, l1sbProxyAddr, opProxyAddr);
        IResourceMetering.ResourceConfig memory resourceConfig = _getResourceConfig();
        Proposal memory startingAnchor = Proposal({
            root: Hash.wrap(bytes32(0)),
            l2SequenceNumber: cfg.l2OutputOracleStartingBlockNumber()
        });
        ISuperchainConfig superchainConfig = ISuperchainConfig(payable(artifactsS1.mustGetAddress("SuperchainConfigProxy")));

        // 5. Initialize contracts in the correct order.
        vm.startPrank(proxyAdminOwner);

        SystemConfig(payable(scProxyAddr)).initialize(
            cfg.finalSystemOwner(),
            cfg.basefeeScalar(),
            cfg.blobbasefeeScalar(),
            bytes32(0), // batcherHash
            uint64(cfg.l2GenesisBlockGasLimit()),
            cfg.p2pSequencerAddress(),
            resourceConfig,
            _getBatchInbox(cfg.l1ChainID()),
            addresses,
            cfg.l2ChainID(),
            superchainConfig
        );

        OptimismPortalImpl(payable(opProxyAddr)).initialize(
            ISystemConfig(payable(scProxyAddr)),
            IAnchorStateRegistry(payable(asrProxyAddr)),
            IETHLockbox(address(0)) // ethLockbox is not used in this setup
        );

        L1CrossDomainMessenger(payable(l1cdmProxyAddr)).initialize(
            ISystemConfig(payable(scProxyAddr)),
            IOptimismPortal(payable(opProxyAddr))
        );

        L1StandardBridge(payable(l1sbProxyAddr)).initialize(
            IL1CrossDomainMessenger(payable(l1cdmProxyAddr)),
            ISystemConfig(payable(scProxyAddr))
        );

        L1ERC721Bridge(payable(l1e721bProxyAddr)).initialize(
            IL1CrossDomainMessenger(payable(l1cdmProxyAddr)),
            ISystemConfig(payable(scProxyAddr))
        );

        DisputeGameFactory(payable(dgfProxyAddr)).initialize(cfg.finalSystemOwner());

        AnchorStateRegistry(payable(asrProxyAddr)).initialize(
            ISystemConfig(payable(scProxyAddr)),
            IDisputeGameFactory(payable(dgfProxyAddr)),
            startingAnchor,
            GameTypes.CANNON
        );

        // 6. Transfer ownership of the ProxyAdmin to the final owner.
        opProxyAdmin.transferOwnership(cfg.finalSystemOwner());
        vm.stopPrank();

        console.log("[SUCCESS] APERTIUM DEPLOYER | STAGE 3: Proxies deployed and system initialized.");
    }

    // --- 内部辅助函数 ---

    function _setup(string memory _artifactFile) internal {
        cfg = new DeployConfig();
        cfg.read(vm.envString("DEPLOY_CONFIG_PATH"));
        artifacts = new Artifacts();
        vm.envString("DEPLOYMENT_OUTFILE", string.concat("generated/", _artifactFile));
        artifacts.setUp();
    }

    function _getResourceConfig() internal view returns (IResourceMetering.ResourceConfig memory) {
        // These are hardcoded values from the getting-started guide, not from deploy-config.
        return IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: uint8(10),
            baseFeeMaxChangeDenominator: uint8(8),
            minimumBaseFee: 1,
            systemTxMaxGas: 1_000_000,
            maximumBaseFee: 10_000_000_000_000_000_000 // 10 gwei
        });
    }

    function _getBatchInbox(uint256 _l1ChainID) internal view returns (address) {
        // This is a hardcoded value from the getting-started guide.
        if (_l1ChainID == 901) { // sepolia
            return 0xFf00000000000000000000000000000000000901;
        } else { // devnet
            return 0xfF00000000000000000000000000000000000000;
        }
    }

    function _getAddresses(
        address _l1CrossDomainMessenger,
        address _l1Erc721Bridge,
        address _l1StandardBridge,
        address _optimismPortal
    ) internal pure returns (ISystemConfig.Addresses memory) {
        return ISystemConfig.Addresses({
            l1CrossDomainMessenger: _l1CrossDomainMessenger,
            l1ERC721Bridge: _l1Erc721Bridge,
            l1StandardBridge: _l1StandardBridge,
            optimismPortal: _optimismPortal,
            optimismMintableERC20Factory: address(0) // Not used in this setup
        });
    }

    /// @notice Deploys a TransparentUpgradeableProxy deterministically.
    /// @param _name The name of the contract for salt generation and artifact saving.
    /// @param _salt The base salt for this deployment.
    /// @param _impl The address of the implementation contract.
    /// @param _admin The address of the ProxyAdmin.
    /// @return addr_ The address of the deployed proxy.
    function _deployProxy(string memory _name, bytes32 _salt, address _impl, ProxyAdmin _admin) internal returns (address addr_) {
        bytes32 proxySalt = keccak256(abi.encodePacked(_name, _salt));
        bytes memory constructorArgs = abi.encode(_impl, address(_admin), bytes(""));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: proxySalt}(_impl, address(_admin), bytes(""));
        addr_ = address(proxy);
        artifacts.save(_name, addr_);
    }
}
