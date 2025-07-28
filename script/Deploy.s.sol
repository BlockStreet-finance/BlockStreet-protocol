// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "../src/Unitroller.sol";
import "../src/Blotroller.sol";
import "../src/BErc20Delegator.sol";
import "../src/BErc20Delegate.sol";
import "../src/SimplePriceOracle.sol";
import "../src/JumpRateModel.sol";

contract DeployScript is Script {
    using stdJson for string;
    
    // Deployment configuration
    struct Config {
        uint256 closeFactor;
        uint256 liquidationIncentive;
        uint256 maxAssets;
        address admin;
        address pauseGuardian;
        address borrowCapGuardian;
        InterestRateConfig interestRate;
        MarketConfig usdcMarket;
        MarketConfig tslaMarket;
    }
    
    struct InterestRateConfig {
        uint256 baseRatePerYear;
        uint256 multiplierPerYear;
        uint256 jumpMultiplierPerYear;
        uint256 kink;
    }
    
    struct MarketConfig {
        string name;
        string symbol;
        uint8 decimals;
        address underlying;
        uint256 collateralFactor;
        uint256 reserveFactor;
        uint256 borrowCap;
        uint256 initialExchangeRate;
        uint256 initialPrice;
    }
    
    // Deployed contracts
    Unitroller public unitroller;
    Blotroller public blotroller;
    SimplePriceOracle public priceOracle;
    JumpRateModel public interestRateModel;
    BErc20Delegate public bErc20Delegate;
    BErc20Delegator public bUSDC;
    BErc20Delegator public bTSLA;
    
    Config public config;
    string public network;
    
    function run() external {
        // Load configuration
        _loadConfig();
        
        // Start deployment
        vm.startBroadcast();
        
        console.log("=== BlockStreet Protocol Deployment ===");
        console.log("Network:", network);
        console.log("Deployer:", msg.sender);
        console.log("Admin:", config.admin);
        
        // Deploy core contracts
        _deployCore();
        
        // Deploy markets
        _deployMarkets();
        
        // Initialize protocol
        _initializeProtocol();
        
        // Setup markets
        _setupMarkets();
        
        // Transfer ownership
        _transferOwnership();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        _logDeployment();
    }
    
    function _loadConfig() internal {
        // Determine network
        if (block.chainid == 97) {
            network = "testnet";
        } else if (block.chainid == 56) {
            network = "mainnet";
        } else {
            revert("Unsupported network");
        }
        
        // Load config from JSON
        string memory configFile = vm.readFile("config/deploy.json");
        
        // Parse protocol config
        config.closeFactor = configFile.readUint(".protocol.closeFactor");
        config.liquidationIncentive = configFile.readUint(".protocol.liquidationIncentive");
        config.maxAssets = configFile.readUint(".protocol.maxAssets");
        
        // Parse governance config - prioritize env vars, fallback to JSON config
        address jsonAdmin = configFile.readAddress(".governance.admin");
        address jsonPauseGuardian = configFile.readAddress(".governance.pauseGuardian");
        address jsonBorrowCapGuardian = configFile.readAddress(".governance.borrowCapGuardian");
        
        // Use env vars if set, otherwise use JSON config, fallback to deployer
        config.admin = vm.envOr("ADMIN_ADDRESS", jsonAdmin != address(0) ? jsonAdmin : msg.sender);
        config.pauseGuardian = vm.envOr("PAUSE_GUARDIAN", jsonPauseGuardian != address(0) ? jsonPauseGuardian : config.admin);
        config.borrowCapGuardian = vm.envOr("BORROW_CAP_GUARDIAN", jsonBorrowCapGuardian != address(0) ? jsonBorrowCapGuardian : config.admin);
        
        // Parse interest rate config
        string memory irPath = ".interestRateModel";
        config.interestRate.baseRatePerYear = configFile.readUint(string.concat(irPath, ".baseRatePerYear"));
        config.interestRate.multiplierPerYear = configFile.readUint(string.concat(irPath, ".multiplierPerYear"));
        config.interestRate.jumpMultiplierPerYear = configFile.readUint(string.concat(irPath, ".jumpMultiplierPerYear"));
        config.interestRate.kink = configFile.readUint(string.concat(irPath, ".kink"));
        
        // Parse market configs
        _loadMarketConfig("USDC", config.usdcMarket);
        _loadMarketConfig("TSLA", config.tslaMarket);
    }
    
    function _loadMarketConfig(string memory market, MarketConfig storage marketConfig) internal {
        string memory configFile = vm.readFile("config/deploy.json");
        string memory basePath = string.concat(".markets.", market);
        
        marketConfig.name = configFile.readString(string.concat(basePath, ".name"));
        marketConfig.symbol = configFile.readString(string.concat(basePath, ".symbol"));
        marketConfig.decimals = uint8(configFile.readUint(string.concat(basePath, ".decimals")));
        
        // Get underlying address based on network
        string memory underlyingPath = string.concat(basePath, ".underlying.", network);
        marketConfig.underlying = configFile.readAddress(underlyingPath);
        
        marketConfig.collateralFactor = configFile.readUint(string.concat(basePath, ".collateralFactor"));
        marketConfig.reserveFactor = configFile.readUint(string.concat(basePath, ".reserveFactor"));
        marketConfig.borrowCap = configFile.readUint(string.concat(basePath, ".borrowCap"));
        marketConfig.initialExchangeRate = configFile.readUint(string.concat(basePath, ".initialExchangeRate"));
        marketConfig.initialPrice = configFile.readUint(string.concat(basePath, ".initialPrice"));
    }
    
    function _deployCore() internal {
        console.log("\n=== Deploying Core Contracts ===");
        
        // Deploy Unitroller (Proxy)
        unitroller = new Unitroller();
        console.log("Unitroller deployed:", address(unitroller));
        
        // Deploy Blotroller (Implementation)
        blotroller = new Blotroller();
        console.log("Blotroller deployed:", address(blotroller));
        
        // Deploy Price Oracle
        priceOracle = new SimplePriceOracle();
        console.log("SimplePriceOracle deployed:", address(priceOracle));
        
        // Deploy Interest Rate Model
        interestRateModel = new JumpRateModel(
            config.interestRate.baseRatePerYear,
            config.interestRate.multiplierPerYear,
            config.interestRate.jumpMultiplierPerYear,
            config.interestRate.kink
        );
        console.log("JumpRateModel deployed:", address(interestRateModel));
        
        // Deploy BErc20 Delegate (Implementation)
        bErc20Delegate = new BErc20Delegate();
        console.log("BErc20Delegate deployed:", address(bErc20Delegate));
        
        // Set Blotroller implementation
        unitroller._setPendingImplementation(address(blotroller));
        blotroller._become(unitroller);
        console.log("Blotroller implementation set");
    }
    
    function _deployMarkets() internal {
        console.log("\n=== Deploying Markets ===");
        
        // Deploy bUSDC
        bUSDC = new BErc20Delegator(
            config.usdcMarket.underlying,
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            config.usdcMarket.initialExchangeRate,
            config.usdcMarket.name,
            config.usdcMarket.symbol,
            config.usdcMarket.decimals,
            payable(msg.sender),
            address(bErc20Delegate),
            ""
        );
        console.log("bUSDC deployed:", address(bUSDC));
        
        // Deploy bTSLA
        bTSLA = new BErc20Delegator(
            config.tslaMarket.underlying,
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            config.tslaMarket.initialExchangeRate,
            config.tslaMarket.name,
            config.tslaMarket.symbol,
            config.tslaMarket.decimals,
            payable(msg.sender),
            address(bErc20Delegate),
            ""
        );
        console.log("bTSLA deployed:", address(bTSLA));
    }
    
    function _initializeProtocol() internal {
        console.log("\n=== Initializing Protocol ===");
        
        Blotroller comptroller = Blotroller(payable(address(unitroller)));
        
        // Set price oracle
        comptroller._setPriceOracle(PriceOracle(address(priceOracle)));
        console.log("Price oracle set");
        
        // Set protocol parameters
        comptroller._setCloseFactor(config.closeFactor);
        console.log("Close factor set to:", config.closeFactor / 1e16, "%");
        
        comptroller._setLiquidationIncentive(config.liquidationIncentive);
        console.log("Liquidation incentive set to:", (config.liquidationIncentive - 1e18) / 1e16, "%");
        
        // Set guardians
        comptroller._setPauseGuardian(config.pauseGuardian);
        console.log("Pause guardian set");
        
        comptroller._setBorrowCapGuardian(config.borrowCapGuardian);
        console.log("Borrow cap guardian set");
    }
    
    function _setupMarkets() internal {
        console.log("\n=== Setting Up Markets ===");
        
        Blotroller comptroller = Blotroller(payable(address(unitroller)));
        
        // Support markets
        comptroller._supportMarket(BToken(address(bUSDC)));
        console.log("USDC market supported");
        
        comptroller._supportMarket(BToken(address(bTSLA)));
        console.log("TSLA market supported");
        
        // Set collateral factors
        comptroller._setCollateralFactor(BToken(address(bUSDC)), config.usdcMarket.collateralFactor);
        console.log("USDC collateral factor:", config.usdcMarket.collateralFactor / 1e16, "%");
        
        comptroller._setCollateralFactor(BToken(address(bTSLA)), config.tslaMarket.collateralFactor);
        console.log("TSLA collateral factor:", config.tslaMarket.collateralFactor / 1e16, "%");
        
        // Set borrow caps
        BToken[] memory bTokens = new BToken[](2);
        uint[] memory borrowCaps = new uint[](2);
        
        bTokens[0] = BToken(address(bUSDC));
        bTokens[1] = BToken(address(bTSLA));
        borrowCaps[0] = config.usdcMarket.borrowCap;
        borrowCaps[1] = config.tslaMarket.borrowCap;
        
        comptroller._setMarketBorrowCaps(bTokens, borrowCaps);
        console.log("Borrow caps set");
        
        // Set reserve factors
        bUSDC._setReserveFactor(config.usdcMarket.reserveFactor);
        bTSLA._setReserveFactor(config.tslaMarket.reserveFactor);
        console.log("Reserve factors set");
        
        // Set initial prices
        priceOracle.setUnderlyingPrice(BToken(address(bUSDC)), config.usdcMarket.initialPrice);
        priceOracle.setUnderlyingPrice(BToken(address(bTSLA)), config.tslaMarket.initialPrice);
        console.log("Initial prices set");
    }
    
    function _transferOwnership() internal {
        console.log("\n=== Transferring Ownership ===");
        
        if (config.admin != msg.sender) {
            // Transfer Unitroller admin
            unitroller._setPendingAdmin(payable(config.admin));
            console.log("Unitroller admin transfer initiated to:", config.admin);
            
            // Transfer market admin
            bUSDC._setPendingAdmin(payable(config.admin));
            bTSLA._setPendingAdmin(payable(config.admin));
            console.log("Market admin transfers initiated");
            
            console.log("IMPORTANT: New admin must call _acceptAdmin() on all contracts");
        }
    }
    
    function _logDeployment() internal view {
        console.log("\n=== Deployment Summary ===");
        console.log("Network:", network);
        console.log("Unitroller:", address(unitroller));
        console.log("Blotroller:", address(blotroller));
        console.log("PriceOracle:", address(priceOracle));
        console.log("InterestRateModel:", address(interestRateModel));
        console.log("BErc20Delegate:", address(bErc20Delegate));
        console.log("bUSDC:", address(bUSDC));
        console.log("bTSLA:", address(bTSLA));
        console.log("Admin:", config.admin);
        console.log("\n=== Next Steps ===");
        console.log("1. Verify contracts on BSCScan");
        console.log("2. Accept admin role from Safe multisig");
        console.log("3. Update price oracle with real prices");
        console.log("4. Test protocol functionality");
    }
}