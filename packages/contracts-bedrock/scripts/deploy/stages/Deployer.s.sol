// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

// Utilities
import { DeployConfig } from "scripts/deploy/DeployConfig.s.sol";
import { Artifacts } from "scripts/Artifacts.s.sol";
import { DeployUtils } from "scripts/libraries/DeployUtils.sol";

// [FIX] Correctly import implementations AND interfaces from their actual locations
// Implementations
import { ProxyAdmin } from "op-contracts-universal/ProxyAdmin.sol";
import { SuperchainConfig } from "src/L1/SuperchainConfig.sol";
import { ProtocolVersions } from "src/L1/ProtocolVersions.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { SystemConfig } from "src/L1/SystemConfig.sol";
import { L1CrossDomainMessenger } from "src/L1/L1CrossDomainMessenger.sol";
import { L1ERC721Bridge } from "src/L1/L1ERC721Bridge.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";
// [FIX-FINAL] The contract is named OptimismPortal2. Import it as such and alias it.
import { OptimismPortal2 as OptimismPortalImpl } from "src/L1/OptimismPortal2.sol";
import { DisputeGameFactory } from "src/dispute/DisputeGameFactory.sol";
import { AnchorStateRegistry } from "src/dispute/AnchorStateRegistry.sol";
import { AddressManager } from "src/legacy/AddressManager.sol";

// Interfaces
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


/// @title Phased Deployer
/// @notice A self-contained script for phased L1 contract deployment.
contract Deployer is Script {
    // Slot for the deployment outfile path in the Artifacts contract.
    // We need to manipulate this directly to load artifacts from previous stages.
    bytes32 private constant ARTIFACTS_OUTFILE_SLOT = 0x6469720000000000000000000000000000000000000000000000000000000000;

    // --- State variables ---
    DeployConfig internal cfg;
    Artifacts internal artifacts;

    // --- Entrypoint for all stages ---
    function run() external {
        // This script is designed to be called with specific function signatures for each stage.
        console.log("Please run a specific stage: deployStage1, deployStage2, or deployStage3");
    }

    // ====================================================================================
    // ================================= STAGE 1: SUPERCHAIN ==============================
    // ====================================================================================

    function deployStage1_Superchain() public {
        _setup("1_superchain_contracts.json");
        console.log("PHASE 1: DEPLOYING SUPERCHAIN CONTRACTS...");

        // Deploy Superchain ProxyAdmin
        address proxyAdminOwner = cfg.proxyAdminOwner();
        bytes32 proxyAdminSalt = keccak256(abi.encodePacked("ProxyAdmin", cfg.getSaltMixer()));
        ProxyAdmin superchainProxyAdmin = new ProxyAdmin{salt: proxyAdminSalt}(proxyAdminOwner);
        artifacts.save("SuperchainProxyAdmin", address(superchainProxyAdmin));

        // Deploy SuperchainConfig (Impl + Proxy)
        bytes32 implSalt = keccak256(bytes("SuperchainConfig"));
        SuperchainConfig scImpl = new SuperchainConfig{salt: implSalt}();
        artifacts.save("SuperchainConfigImpl", address(scImpl));

        address scProxyAddr = _deployProxy("SuperchainConfigProxy", address(scImpl), superchainProxyAdmin);
        artifacts.save("SuperchainConfigProxy", scProxyAddr);

        // Deploy ProtocolVersions (Impl + Proxy)
        bytes32 pvImplSalt = keccak256(bytes("ProtocolVersions"));
        ProtocolVersions pvImpl = new ProtocolVersions{salt: pvImplSalt}();
        artifacts.save("ProtocolVersionsImpl", address(pvImpl));

        address pvProxyAddr = _deployProxy("ProtocolVersionsProxy", address(pvImpl), superchainProxyAdmin);
        artifacts.save("ProtocolVersionsProxy", pvProxyAddr);

        // Initialize contracts
        vm.startPrank(proxyAdminOwner);
        ISuperchainConfig(payable(scProxyAddr)).initialize(cfg.superchainConfigGuardian());
        IProtocolVersions(payable(pvProxyAddr)).initialize(
            cfg.finalSystemOwner(),
            ProtocolVersion.wrap(cfg.requiredProtocolVersion()),
            ProtocolVersion.wrap(cfg.recommendedProtocolVersion())
        );
        vm.stopPrank();


        console.log("[SUCCESS] Stage 1: Superchain contracts deployed.");
    }

    // ====================================================================================
    // ============================= STAGE 2: IMPLEMENTATIONS =============================
    // ====================================================================================

    function deployStage2_Implementations() public {
        _setup("2_implementation_contracts.json");
        console.log("PHASE 2: DEPLOYING IMPLEMENTATION CONTRACTS...");
        
        bytes32 implSalt = keccak256(bytes("optimism-impl-salt"));

        // Define constructor args for clarity
        uint256 proofMaturityDelaySeconds_ = cfg.proofMaturityDelaySeconds();
        uint256 disputeGameFinalityDelaySeconds_ = cfg.disputeGameFinalityDelaySeconds();

        // Deploy logic contracts
        new AddressManager{salt: implSalt}();
        new SystemConfig{salt: implSalt}();
        new L1CrossDomainMessenger{salt: implSalt}();
        new L1ERC721Bridge{salt: implSalt}();
        new L1StandardBridge{salt: implSalt}();
        new OptimismPortalImpl{salt: implSalt}(proofMaturityDelaySeconds_);
        new DisputeGameFactory{salt: implSalt}();
        new AnchorStateRegistry{salt: implSalt}(disputeGameFinalityDelaySeconds_);

        // Compute and save deterministic addresses
        bytes memory amCode = vm.getCode("AddressManager.sol:AddressManager");
        artifacts.save("AddressManagerImpl", vm.computeCreate2Address(implSalt, keccak256(amCode)));

        bytes memory scCode = vm.getCode("SystemConfig.sol:SystemConfig");
        artifacts.save("SystemConfigImpl", vm.computeCreate2Address(implSalt, keccak256(scCode)));

        bytes memory cdmCode = vm.getCode("L1CrossDomainMessenger.sol:L1CrossDomainMessenger");
        artifacts.save("L1CrossDomainMessengerImpl", vm.computeCreate2Address(implSalt, keccak256(cdmCode)));

        bytes memory e721bCode = vm.getCode("L1ERC721Bridge.sol:L1ERC721Bridge");
        artifacts.save("L1ERC721BridgeImpl", vm.computeCreate2Address(implSalt, keccak256(e721bCode)));

        bytes memory sbCode = vm.getCode("L1StandardBridge.sol:L1StandardBridge");
        artifacts.save("L1StandardBridgeImpl", vm.computeCreate2Address(implSalt, keccak256(sbCode)));

        bytes memory opCode = vm.getCode("OptimismPortal2.sol:OptimismPortal2");
        bytes memory opConstructorArgs = abi.encode(proofMaturityDelaySeconds_);
        artifacts.save("OptimismPortalImpl", vm.computeCreate2Address(implSalt, keccak256(abi.encodePacked(opCode, opConstructorArgs))));

        bytes memory dgfCode = vm.getCode("DisputeGameFactory.sol:DisputeGameFactory");
        artifacts.save("DisputeGameFactoryImpl", vm.computeCreate2Address(implSalt, keccak256(dgfCode)));

        bytes memory asrCode = vm.getCode("AnchorStateRegistry.sol:AnchorStateRegistry");
        bytes memory asrConstructorArgs = abi.encode(disputeGameFinalityDelaySeconds_);
        artifacts.save("AnchorStateRegistryImpl", vm.computeCreate2Address(implSalt, keccak256(abi.encodePacked(asrCode, asrConstructorArgs))));

        console.log("[SUCCESS] Stage 2: Implementation contracts deployed.");
    }
    
    // ====================================================================================
    // =============================== STAGE 3: PROXIES & INIT ============================
    // ====================================================================================

    function deployStage3_ProxiesAndInit() public {
        // Create new Artifacts instances to load deployment data from previous stages.
        // We must set the DEPLOYMENT_OUTFILE env var *before* creating the instance,
        // as it's read during the constructor/setup phase.
        vm.envString("DEPLOYMENT_OUTFILE", "generated/1_superchain_contracts.json");
        Artifacts artifactsS1 = new Artifacts();
        artifactsS1.setUp();

        vm.envString("DEPLOYMENT_OUTFILE", "generated/2_implementation_contracts.json");
        Artifacts artifactsS2 = new Artifacts();
        artifactsS2.setUp();

        // Now, set up the Artifacts for the current stage to save new deployment data.
        _setup("3_opchain_contracts.json");

        console.log("PHASE 3: DEPLOYING PROXIES AND INITIALIZING...");

        // Deploy OP Chain ProxyAdmin
        address proxyAdminOwner = cfg.proxyAdminOwner();
        bytes32 proxyAdminSalt = keccak256(abi.encodePacked("ProxyAdmin", cfg.getSaltMixer()));
        ProxyAdmin opProxyAdmin = new ProxyAdmin{salt: proxyAdminSalt}(proxyAdminOwner);
        artifacts.save("ProxyAdmin", address(opProxyAdmin));

        // Deploy a proxy for AddressManager. It has no initializer.
        address amImplAddr = artifactsS2.mustGetAddress("AddressManagerImpl");
        address amProxyAddr = _deployProxy("AddressManagerProxy", amImplAddr, opProxyAdmin);

        // Deploy Other Proxies
        address scProxyAddr = _deployProxy("SystemConfigProxy", artifactsS2.mustGetAddress("SystemConfigImpl"), opProxyAdmin);
        address opProxyAddr = _deployProxy("OptimismPortalProxy", artifactsS2.mustGetAddress("OptimismPortalImpl"), opProxyAdmin);
        address l1cdmProxyAddr = _deployProxy("L1CrossDomainMessengerProxy", artifactsS2.mustGetAddress("L1CrossDomainMessengerImpl"), opProxyAdmin);
        address l1sbProxyAddr = _deployProxy("L1StandardBridgeProxy", artifactsS2.mustGetAddress("L1StandardBridgeImpl"), opProxyAdmin);
        address dgfProxyAddr = _deployProxy("DisputeGameFactoryProxy", artifactsS2.mustGetAddress("DisputeGameFactoryImpl"), opProxyAdmin);
        address asrProxyAddr = _deployProxy("AnchorStateRegistryProxy", artifactsS2.mustGetAddress("AnchorStateRegistryImpl"), opProxyAdmin);
        address l1e721bProxyAddr = _deployProxy("L1ERC721BridgeProxy", artifactsS2.mustGetAddress("L1ERC721BridgeImpl"), opProxyAdmin);

        // Save proxy addresses
        artifacts.save("AddressManagerProxy", amProxyAddr);
        artifacts.save("SystemConfigProxy", scProxyAddr);
        artifacts.save("OptimismPortalProxy", opProxyAddr);
        artifacts.save("L1CrossDomainMessengerProxy", l1cdmProxyAddr);
        artifacts.save("L1StandardBridgeProxy", l1sbProxyAddr);
        artifacts.save("DisputeGameFactoryProxy", dgfProxyAddr);
        artifacts.save("AnchorStateRegistryProxy", asrProxyAddr);
        artifacts.save("L1ERC721BridgeProxy", l1e721bProxyAddr);
        // L2OutputOracle is an alias for OptimismPortal
        artifacts.save("L2OutputOracleProxy", opProxyAddr);


        // Initialize contracts
        vm.startPrank(proxyAdminOwner);

        // [FIX-FINAL] Correct the argument order for SystemConfig.initialize.
        // The unsafeBlockSigner was being passed where the p2pSequencerAddress should have been.
        ISystemConfig.Addresses memory addresses = _getAddresses(l1cdmProxyAddr, l1e721bProxyAddr, l1sbProxyAddr, opProxyAddr, address(0));
        IResourceMetering.ResourceConfig memory resourceConfig = _getResourceConfig();

        ISystemConfig(payable(scProxyAddr)).initialize(
            cfg.finalSystemOwner(),
            cfg.basefeeScalar(),
            cfg.blobbasefeeScalar(),
            bytes32(0), // batcherHash is set to zero in getting-started
            cfg.l2GenesisBlockGasLimit(),
            cfg.unsafeBlockSigner(), // [CRITICAL-FIX] This was reverted by mistake. This is the correct parameter.
            resourceConfig,
            _getBatchInbox(cfg.l1ChainID()),
            addresses,
            cfg.l2ChainID(),
            ISuperchainConfig(payable(artifactsS1.mustGetAddress("SuperchainConfigProxy")))
        );
        IOptimismPortal(payable(opProxyAddr)).initialize(ISystemConfig(payable(scProxyAddr)), IAnchorStateRegistry(payable(asrProxyAddr)), IETHLockbox(address(0)));
        IL1CrossDomainMessenger(payable(l1cdmProxyAddr)).initialize(ISystemConfig(payable(scProxyAddr)), IOptimismPortal(payable(opProxyAddr)));
        IL1StandardBridge(payable(l1sbProxyAddr)).initialize(IL1CrossDomainMessenger(payable(l1cdmProxyAddr)), ISystemConfig(payable(scProxyAddr)));
        IL1ERC721Bridge(payable(l1e721bProxyAddr)).initialize(IL1CrossDomainMessenger(payable(l1cdmProxyAddr)), ISystemConfig(payable(scProxyAddr)));
        IDisputeGameFactory(payable(dgfProxyAddr)).initialize(cfg.finalSystemOwner());
        IAnchorStateRegistry(payable(asrProxyAddr)).initialize(cfg.finalSystemOwner());

        vm.stopPrank();

        console.log("[SUCCESS] Stage 3: Proxies deployed and system initialized.");
    }

    // --- Internal Helpers ---

    function _setup(string memory _artifactFile) internal {
        cfg = new DeployConfig();
        cfg.read(vm.envString("DEPLOY_CONFIG_PATH"));
        artifacts = new Artifacts();
        artifacts.setUp(string.concat("generated/", _artifactFile));
    }

    function _deployProxy(string memory _name, address _impl, ProxyAdmin _admin) internal returns (address addr_) {
        bytes32 salt = keccak256(abi.encodePacked(_name, cfg.getSaltMixer()));
        // Note: The TransparentUpgradeableProxy constructor takes (_logic, admin_, _data)
        // We are passing in empty bytes for _data, so no initialization is done here.
        // Initialization is done in the subsequent steps.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: salt}(
            _impl,
            address(_admin),
            bytes("")
        );
        artifacts.save(_name, address(proxy));
        return address(proxy);
    }

    function _getResourceConfig() internal pure returns (IResourceMetering.ResourceConfig memory) {
        // This is a hardcoded value from the getting-started guide.
        // It is not configurable in the deploy-config.
        uint32 maxResourceLimit = 20_000_000;
        uint32 elasticityMultiplier = 10;
        uint32 baseFeeMaxChangeDenominator = 8;
        uint32 minimumBaseFee = 1;
        uint32 systemTxMaxGas = 1_000_000;
        uint128 maximumBaseFee = 10_000_000_000_000_000_000; // 10 gwei

        return IResourceMetering.ResourceConfig({
            maxResourceLimit: maxResourceLimit,
            elasticityMultiplier: elasticityMultiplier,
            baseFeeMaxChangeDenominator: baseFeeMaxChangeDenominator,
            minimumBaseFee: minimumBaseFee,
            systemTxMaxGas: systemTxMaxGas,
            maximumBaseFee: maximumBaseFee
        });
    }

    function _getBatchInbox(uint256 l1ChainID) internal view returns (address) {
        // This is a hardcoded value from the getting-started guide.
        // It is not configurable in the deploy-config.
        if (l1ChainID == 901) { // sepolia
            return 0xff00000000000000000000000000000000000901;
        } else { // devnet
            return 0xff00000000000000000000000000000000000000;
        }
    }

    function _getAddresses(
        address _l1CrossDomainMessenger,
        address _l1Erc721Bridge,
        address _l1StandardBridge,
        address _optimismPortal,
        address _l2OutputOracle
    ) internal view returns (ISystemConfig.Addresses memory) {
        return ISystemConfig.Addresses({
            l1CrossDomainMessenger: _l1CrossDomainMessenger,
            l1Erc721Bridge: _l1Erc721Bridge,
            l1StandardBridge: _l1StandardBridge,
            optimismPortal: _optimismPortal,
            l2OutputOracle: _l2OutputOracle
        });
    }

}
