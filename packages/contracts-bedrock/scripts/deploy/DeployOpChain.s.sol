// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DeployUtils } from "scripts/libraries/DeployUtils.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";

import { ProxyAdmin } from "op-contracts-universal/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";

import { SystemConfig } from "src/L1/SystemConfig.sol";
import { ETHLockbox } from "src/L1/ETHLockbox.sol";
import { AnchorStateRegistry } from "src/dispute/AnchorStateRegistry.sol";
import { DisputeGameFactory } from "src/dispute/DisputeGameFactory.sol";
import { AddressManager } from "src/legacy/AddressManager.sol";

import { DeployImplementations } from "scripts/deploy/DeployImplementations.s.sol";
import { DeploySuperchain } from "scripts/deploy/DeploySuperchain.s.sol";
import { DeployConfig } from "scripts/deploy/DeployConfig.s.sol";

/// @title DeployOpChain
/// @notice This script deploys the L1 contracts for an OP Chain.
/// It is a stateless script that can be used to deploy a new OP Chain.
contract DeployOpChain is Script {
struct OpChainContracts {
    ProxyAdmin proxyAdmin;
    AddressManager addressManager;
        ISystemConfig systemConfigProxy;
        IDisputeGameFactory disputeGameFactoryProxy;
        IAnchorStateRegistry anchorStateRegistryProxy;
        IOptimismPortal optimismPortalProxy;
        IETHLockbox ethLockboxProxy;
    IL1StandardBridge l1StandardBridgeProxy;
    IL1CrossDomainMessenger l1CrossDomainMessengerProxy;
    IL1ERC721Bridge l1ERC721BridgeProxy;
        IL1StandardBridge l2OutputOracleProxy; // Re-using L1StandardBridge as a placeholder type
    }

    function run(
        DeployImplementations.Output memory _implementations,
        DeploySuperchain.Output memory _superchain,
        address finalSystemOwner,
        string memory saltMixer,
        DeployConfig cfg
    )
        public
        returns (OpChainContracts memory opChainContracts)
    {
        opChainContracts = _deployProxies(_implementations, finalSystemOwner, saltMixer);

        _initializeSystem(
            opChainContracts,
            _implementations,
            opChainContracts.proxyAdmin,
            finalSystemOwner,
            DisputeGameFactory(payable(address(opChainContracts.disputeGameFactoryProxy))),
            cfg,
            ISuperchainConfig(payable(address(_superchain.superchainConfigProxy)))
        );
        return opChainContracts;
    }

    /// @notice Deploy the proxies for the OP Chain contracts.
    function _deployProxies(
        DeployImplementations.Output memory _implementations,
        address proxyAdminOwner,
        string memory saltMixer
    )
        internal
        returns (OpChainContracts memory opChainContracts)
    {
        bytes32 saltMixerHash = keccak256(abi.encodePacked(saltMixer));

        bytes32 proxyAdminSalt = keccak256(abi.encodePacked("ProxyAdmin", saltMixerHash));
        bytes memory proxyAdminArgs = abi.encode(proxyAdminOwner);
        address proxyAdminAddr = DeployUtils.create2("ProxyAdmin", proxyAdminArgs, proxyAdminSalt);
        opChainContracts.proxyAdmin = ProxyAdmin(payable(proxyAdminAddr));

        bytes32 addressManagerImplSalt = keccak256(abi.encodePacked("AddressManagerImpl", saltMixerHash));
        address addressManagerImpl = DeployUtils.create2("AddressManager", bytes(""), addressManagerImplSalt);

        opChainContracts.addressManager = AddressManager(
            payable(
                _deployERC1967Proxy("AddressManager", addressManagerImpl, opChainContracts.proxyAdmin, saltMixer)
            )
        );

        vm.startPrank(proxyAdminOwner);
        opChainContracts.proxyAdmin.setAddressManager(IAddressManager(address(opChainContracts.addressManager)));
        vm.stopPrank();

        opChainContracts.optimismPortalProxy = IOptimismPortal(
            payable(
                _deployERC1967Proxy(
                    "OptimismPortalProxy",
                    address(_implementations.optimismPortalImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.l2OutputOracleProxy = IL1StandardBridge(payable(address(opChainContracts.optimismPortalProxy)));

        opChainContracts.systemConfigProxy = ISystemConfig(
            payable(
                _deployERC1967Proxy(
                    "SystemConfigProxy",
                    address(_implementations.systemConfigImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.disputeGameFactoryProxy = IDisputeGameFactory(
            payable(
                _deployERC1967Proxy(
                    "DisputeGameFactoryProxy",
                    address(_implementations.disputeGameFactoryImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.anchorStateRegistryProxy = IAnchorStateRegistry(
            payable(
                _deployERC1967Proxy(
                    "AnchorStateRegistryProxy",
                    address(_implementations.anchorStateRegistryImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.ethLockboxProxy = IETHLockbox(
            payable(
                _deployERC1967Proxy(
                    "ETHLockboxProxy",
                    address(_implementations.ethLockboxImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );

        opChainContracts.l1StandardBridgeProxy = IL1StandardBridge(
            payable(
                _deployERC1967Proxy(
                    "L1StandardBridgeProxy",
                    address(_implementations.l1StandardBridgeImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.l1CrossDomainMessengerProxy = IL1CrossDomainMessenger(
            payable(
                _deployERC1967Proxy(
                    "L1CrossDomainMessengerProxy",
                    address(_implementations.l1CrossDomainMessengerImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
        opChainContracts.l1ERC721BridgeProxy = IL1ERC721Bridge(
            payable(
                _deployERC1967Proxy(
                    "L1ERC721BridgeProxy",
                    address(_implementations.l1ERC721BridgeImpl),
                    opChainContracts.proxyAdmin,
                    saltMixer
                )
            )
        );
    }

    /// @notice Initialize the OP Chain contracts.
    function _initializeSystem(
        OpChainContracts memory _opChainContracts,
        DeployImplementations.Output memory _implementations,
        ProxyAdmin proxyAdmin,
        address finalSystemOwner,
        DisputeGameFactory disputeGameFactoryProxy,
        DeployConfig cfg,
        ISuperchainConfig _superchainConfig
    )
        internal
    {
        vm.startPrank(proxyAdmin.owner());
        proxyAdmin.upgrade(payable(address(_opChainContracts.l1StandardBridgeProxy)), address(_implementations.l1StandardBridgeImpl));
        proxyAdmin.upgrade(
            payable(address(_opChainContracts.l1CrossDomainMessengerProxy)), address(_implementations.l1CrossDomainMessengerImpl)
        );
        proxyAdmin.upgrade(payable(address(_opChainContracts.l1ERC721BridgeProxy)), address(_implementations.l1ERC721BridgeImpl));

        _opChainContracts.optimismPortalProxy.initialize(
            ISystemConfig(address(_opChainContracts.systemConfigProxy)),
            IAnchorStateRegistry(address(_opChainContracts.anchorStateRegistryProxy)),
            IETHLockbox(address(_opChainContracts.ethLockboxProxy))
        );

        _opChainContracts.l1StandardBridgeProxy.initialize(
            IL1CrossDomainMessenger(payable(address(_opChainContracts.l1CrossDomainMessengerProxy))),
            ISystemConfig(address(_opChainContracts.systemConfigProxy))
        );

        _opChainContracts.l1CrossDomainMessengerProxy.initialize(
            ISystemConfig(address(_opChainContracts.systemConfigProxy)),
            IOptimismPortal(payable(address(_opChainContracts.optimismPortalProxy)))
        );

        _opChainContracts.l1ERC721BridgeProxy.initialize(
            IL1CrossDomainMessenger(payable(address(_opChainContracts.l1CrossDomainMessengerProxy))),
            ISystemConfig(address(_opChainContracts.systemConfigProxy))
        );

        ISystemConfig.Addresses memory addresses = ISystemConfig.Addresses({
            l1CrossDomainMessenger: address(_opChainContracts.l1CrossDomainMessengerProxy),
            l1ERC721Bridge: address(_opChainContracts.l1ERC721BridgeProxy),
            l1StandardBridge: address(_opChainContracts.l1StandardBridgeProxy),
            optimismPortal: address(_opChainContracts.optimismPortalProxy),
            optimismMintableERC20Factory: address(0) // Not deployed in this flow
        });

        IResourceMetering.ResourceConfig memory resourceConfig = IResourceMetering.ResourceConfig({
            maxResourceLimit: 20000000,
            elasticityMultiplier: 10,
            baseFeeMaxChangeDenominator: 8,
            minimumBaseFee: 1,
            systemTxMaxGas: 1000000,
            maximumBaseFee: 100000000000
        });

        _opChainContracts.systemConfigProxy.initialize(
            finalSystemOwner,
            cfg.basefeeScalar(),
            cfg.blobbasefeeScalar(),
            bytes32(0), // batcherHash
            uint64(cfg.l2GenesisBlockGasLimit()),
            cfg.p2pSequencerAddress(),
            resourceConfig,
            address(0x6887246668a3b87F54DeB3b94Ba47a6f63F32985), // batchInbox on Holesky (same as mainnet, sepolia)
            addresses,
            cfg.l2ChainID(),
            ISuperchainConfig(address(0)) // Not used in this flow
        );
        vm.stopPrank();
    }

    function _deployERC1967Proxy(
        string memory _name,
        address _implementation,
        ProxyAdmin proxyAdmin,
        string memory saltMixer
    )
        internal
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(_name, saltMixer));
        bytes memory args = abi.encode(_implementation, proxyAdmin, "");
        return DeployUtils.create2("TransparentUpgradeableProxy", args, salt);
    }
}
