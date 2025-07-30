// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/Unitroller.sol";
import "../src/BlotrollerStorage.sol";
import "../src/ErrorReporter.sol";
import "../src/SimplePriceOracle.sol";
import "../src/BTokenInterfaces.sol";
import "../src/BErc20Delegate.sol";
import "../src/BErc20Delegator.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";

/**
 * @title Test Suite for A/B Token Separation System
 * @author BlockStreet
 * @dev Tests the core A/B token separation functionality with real BTokens
 */
contract ABTokenSeparationTest is Test {
    // --- Core Contracts ---
    Unitroller internal unitroller;
    Blotroller internal blotrollerImplementation;
    Blotroller internal blotroller; // This will be the proxy interface
    SimplePriceOracle internal oracle;
    JumpRateModel internal interestRateModel;
    BErc20Delegate internal bErc20Delegate;
    
    // --- Underlying Tokens ---
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    
    // --- BTokens ---
    BErc20Delegator internal bTokenA;
    BErc20Delegator internal bTokenB;
    BErc20Delegator internal bTokenC;
    
    // --- Users ---
    address internal admin = address(0x1);
    address internal user1 = address(0x2);
    address internal liquidityProvider = address(0x3); // Provides liquidity for cross-borrowing

    function setUp() public {
        vm.startPrank(admin);
        
        // 1. Deploy underlying ERC20 tokens
        _deployUnderlyingTokens();
        
        // 2. Deploy core contracts (Unitroller + Blotroller)
        _deployCore();
        
        // 3. Deploy BToken implementation and interest rate model
        _deployBTokenInfrastructure();
        
        // 4. Deploy BTokens
        _deployBTokens();
        
        vm.stopPrank();
    }

    function _deployUnderlyingTokens() internal {
        tokenA = new MockERC20("Token A", "TOKA", 18, 1_000_000 * 10**18);
        tokenB = new MockERC20("Token B", "TOKB", 6, 1_000_000 * 10**6);
        tokenC = new MockERC20("Token C", "TOKC", 18, 1_000_000 * 10**18);
    }

    function _deployCore() internal {
        // 1. Deploy Blotroller implementation first
        blotrollerImplementation = new Blotroller();
        
        // 2. Deploy Unitroller proxy
        unitroller = new Unitroller();
        
        // 3. Set Blotroller as pending implementation
        unitroller._setPendingImplementation(address(blotrollerImplementation));
        
        // 4. Accept implementation (Blotroller becomes the implementation)
        blotrollerImplementation._become(unitroller);
        
        // 5. Now we can interact with Blotroller through the Unitroller proxy
        blotroller = Blotroller(payable(address(unitroller)));
        
        // 6. Deploy and set price oracle
        oracle = new SimplePriceOracle();
        blotroller._setPriceOracle(oracle);
    }

    function _deployBTokenInfrastructure() internal {
        // Deploy interest rate model
        interestRateModel = new JumpRateModel(
            2102400000000000000, // base rate: 2.1% annually
            10512000000000000000, // multiplier: 10.512% annually
            10512000000000000000, // jump multiplier: 10.512% annually
            800000000000000000   // kink: 80%
        );
        
        // Deploy BErc20 Delegate (implementation)
        bErc20Delegate = new BErc20Delegate();
    }

    function _deployBTokens() internal {
        // Deploy bTokenA
        bTokenA = new BErc20Delegator(
            address(tokenA),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            200000000000000000000000000, // initial exchange rate: 0.2 * 10^18
            "BlockStreet Token A",
            "bTOKA",
            18,
            payable(admin),
            address(bErc20Delegate),
            ""
        );
        
        // Deploy bTokenB
        bTokenB = new BErc20Delegator(
            address(tokenB),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            200000000000000, // initial exchange rate: 0.2 * 10^6 (6 decimals)
            "BlockStreet Token B",
            "bTOKB",
            8,
            payable(admin),
            address(bErc20Delegate),
            ""
        );
        
        // Deploy bTokenC
        bTokenC = new BErc20Delegator(
            address(tokenC),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            200000000000000000000000000, // initial exchange rate: 0.2 * 10^18
            "BlockStreet Token C",
            "bTOKC",
            18,
            payable(admin),
            address(bErc20Delegate),
            ""
        );
        
        // Set initial prices in oracle
        oracle.setUnderlyingPrice(BToken(address(bTokenA)), 1000000000000000000); // $1.00
        oracle.setUnderlyingPrice(BToken(address(bTokenB)), 1000000000000000000000000000000); // $1.00 (scaled for 6 decimals)
        oracle.setUnderlyingPrice(BToken(address(bTokenC)), 1000000000000000000); // $1.00
    }

    // ============================================================
    // Section: Token Type Setting Tests
    // ============================================================
    
    function test_AdminCanSetTokenTypes() public {
        vm.startPrank(admin);
        
        // Properly support markets first
        blotroller._supportMarket(BToken(address(bTokenA)));
        blotroller._supportMarket(BToken(address(bTokenB)));
        
        // Set token types
        uint256 result1 = blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        uint256 result2 = blotroller._setTokenType(BToken(address(bTokenB)), BlotrollerStorage.TokenType.TYPE_B);
        
        assertEq(result1, 0, "Setting TYPE_A should succeed");
        assertEq(result2, 0, "Setting TYPE_B should succeed");
        
        // Verify token types (TYPE_A = 0, TYPE_B = 1)
        assertEq(uint256(blotroller.tokenTypes(address(bTokenA))), 0, "bTokenA should be TYPE_A");
        assertEq(uint256(blotroller.tokenTypes(address(bTokenB))), 1, "bTokenB should be TYPE_B");
        
        vm.stopPrank();
    }
    
    function test_Fail_NonAdminCannotSetTokenTypes() public {
        vm.startPrank(user1);
        
        uint256 result = blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        assertEq(result, uint256(BlotrollerErrorReporter.Error.UNAUTHORIZED), "Non-admin should not be able to set token types");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Separation Mode Tests
    // ============================================================
    
    function test_AdminCanEnableSeparationMode() public {
        vm.startPrank(admin);
        
        // Initially disabled
        assertFalse(blotroller.separationModeEnabled(), "Separation mode should be disabled initially");
        
        // Enable separation mode
        uint256 result = blotroller._setSeparationMode(true);
        assertEq(result, 0, "Enabling separation mode should succeed");
        assertTrue(blotroller.separationModeEnabled(), "Separation mode should be enabled");
        
        vm.stopPrank();
    }
    
    function test_Fail_NonAdminCannotChangeSeparationMode() public {
        vm.startPrank(user1);
        
        uint256 result = blotroller._setSeparationMode(true);
        assertEq(result, uint256(BlotrollerErrorReporter.Error.UNAUTHORIZED), "Non-admin should not be able to change separation mode");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Token Type Management Tests
    // ============================================================
    
    function test_CanChangeTokenType() public {
        _setupTokenTypes();
        
        vm.startPrank(admin);
        
        // Change TYPE_A to TYPE_B
        uint256 result = blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_B);
        assertEq(result, 0, "Changing token type should succeed");
        assertEq(uint256(blotroller.tokenTypes(address(bTokenA))), 1, "bTokenA should now be TYPE_B");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Separation Mode Queries Tests
    // ============================================================
    
    function test_Fail_SeparatedLiquidityWhenModeDisabled() public {
        // Don't enable separation mode
        (uint256 err, , , , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(err, uint256(BlotrollerErrorReporter.Error.COMPTROLLER_MISMATCH), "Should fail when separation mode is disabled");
    }
    
    function test_SeparatedLiquidityQueryWhenModeEnabled() public {
        _setupSeparationMode();
        
        // Should not error when separation mode is enabled
        (uint256 err, , , , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(err, 0, "Should not error when separation mode is enabled");
    }

    // ============================================================
    // Section: Hypothetical Liquidity Tests
    // ============================================================
    
    function test_HypotheticalSeparatedLiquidityQueryWhenModeEnabled() public {
        _setupSeparationMode();
        
        // Should not error when separation mode is enabled
        (uint256 err, , , , ) = blotroller.getHypotheticalAccountLiquiditySeparated(
            user1, 
            address(bTokenA), 
            0, 
            0
        );
        assertEq(err, 0, "Should not error when separation mode is enabled");
    }
    
    function test_Fail_HypotheticalSeparatedLiquidityWhenModeDisabled() public {
        // Don't enable separation mode
        (uint256 err, , , , ) = blotroller.getHypotheticalAccountLiquiditySeparated(
            user1, 
            address(bTokenA), 
            0, 
            0
        );
        assertEq(err, uint256(BlotrollerErrorReporter.Error.COMPTROLLER_MISMATCH), "Should fail when separation mode is disabled");
    }

    // ============================================================
    // Section: Integration Tests
    // ============================================================
    
    function test_FullSeparationModeWorkflow() public {
        vm.startPrank(admin);
        
        // 1. Set up token types
        blotroller._supportMarket(BToken(address(bTokenA)));
        blotroller._supportMarket(BToken(address(bTokenB)));
        blotroller._supportMarket(BToken(address(bTokenC)));
        
        blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        blotroller._setTokenType(BToken(address(bTokenB)), BlotrollerStorage.TokenType.TYPE_B);
        // bTokenC remains unclassified
        
        // 2. Enable separation mode
        blotroller._setSeparationMode(true);
        
        // 3. Verify state
        assertTrue(blotroller.separationModeEnabled(), "Separation mode should be enabled");
        assertEq(uint256(blotroller.tokenTypes(address(bTokenA))), 0, "bTokenA should be TYPE_A");
        assertEq(uint256(blotroller.tokenTypes(address(bTokenB))), 1, "bTokenB should be TYPE_B");
        assertEq(uint256(blotroller.tokenTypes(address(bTokenC))), 0, "bTokenC should be unclassified");
        
        // 4. Test liquidity queries work
        (uint256 err, , , , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(err, 0, "Separated liquidity query should work");
        
        // 5. Disable separation mode
        blotroller._setSeparationMode(false);
        assertFalse(blotroller.separationModeEnabled(), "Separation mode should be disabled");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Core A/B Borrowing Rules Tests
    // ============================================================
    
    function test_TypeA_CanOnlyBorrowTypeB() public {
        _setupSeparationModeWithCollateral();
        
        vm.startPrank(user1);
        
        // User1 mints bTokenA (TYPE_A) as collateral
        tokenA.approve(address(bTokenA), 1000 * 10**18);
        bTokenA.mint(1000 * 10**18);
        
        // Enter market for bTokenA
        address[] memory markets = new address[](1);
        markets[0] = address(bTokenA);
        blotroller.enterMarkets(markets);
        
        // Should be able to borrow TYPE_B token
        uint256 borrowResult = bTokenB.borrow(100 * 10**6); // 100 TOKB
        assertEq(borrowResult, 0, "Should be able to borrow TYPE_B token with TYPE_A collateral");
        
        // Should NOT be able to borrow TYPE_A token - expect revert with error code 4
        vm.expectRevert(abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, 4));
        bTokenA.borrow(100 * 10**18);
        
        vm.stopPrank();
    }
    
    function test_TypeB_CanOnlyBorrowTypeA() public {
        _setupSeparationModeWithCollateral();
        
        vm.startPrank(user1);
        
        // User1 mints bTokenB (TYPE_B) as collateral  
        tokenB.approve(address(bTokenB), 1000 * 10**6);
        bTokenB.mint(1000 * 10**6);
        
        // Enter market for bTokenB
        address[] memory markets = new address[](1);
        markets[0] = address(bTokenB);
        blotroller.enterMarkets(markets);
        
        // Should be able to borrow TYPE_A token
        uint256 borrowResult = bTokenA.borrow(100 * 10**18); // 100 TOKA
        assertEq(borrowResult, 0, "Should be able to borrow TYPE_A token with TYPE_B collateral");
        
        // Should NOT be able to borrow TYPE_B token - expect revert with error code 4
        vm.expectRevert(abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, 4));
        bTokenB.borrow(100 * 10**6);
        
        vm.stopPrank();
    }
    
    
    function test_MixedCollateral_FollowsABRules() public {
        _setupSeparationModeWithCollateral();
        
        vm.startPrank(user1);
        
        // User1 provides both TYPE_A and TYPE_B collateral
        tokenA.approve(address(bTokenA), 1000 * 10**18);
        bTokenA.mint(1000 * 10**18);
        
        tokenB.approve(address(bTokenB), 1000 * 10**6);
        bTokenB.mint(1000 * 10**6);
        
        // Enter both markets
        address[] memory markets = new address[](2);
        markets[0] = address(bTokenA);
        markets[1] = address(bTokenB);
        blotroller.enterMarkets(markets);
        
        // Should be able to borrow both TYPE_A and TYPE_B tokens (each supported by opposite collateral)
        uint256 borrowResultA = bTokenA.borrow(50 * 10**18); // Supported by TYPE_B collateral
        assertEq(borrowResultA, 0, "Should be able to borrow TYPE_A with TYPE_B collateral");
        
        uint256 borrowResultB = bTokenB.borrow(50 * 10**6); // Supported by TYPE_A collateral
        assertEq(borrowResultB, 0, "Should be able to borrow TYPE_B with TYPE_A collateral");
        
        vm.stopPrank();
    }
    
    function test_SeparationModeDisabled_AllowsNormalBorrowing() public {
        _setupTokenTypesAndCollateral();
        // Note: separation mode is NOT enabled
        
        vm.startPrank(user1);
        
        // Provide TYPE_A collateral
        tokenA.approve(address(bTokenA), 1000 * 10**18);
        bTokenA.mint(1000 * 10**18);
        
        address[] memory markets = new address[](1);
        markets[0] = address(bTokenA);
        blotroller.enterMarkets(markets);
        
        // Should be able to borrow same type token when separation mode is disabled
        uint256 borrowResult = bTokenA.borrow(100 * 10**18);
        assertEq(borrowResult, 0, "Should be able to borrow same type when separation mode disabled");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Liquidity Calculation Accuracy Tests  
    // ============================================================
    
    function test_SeparatedLiquidityCalculation_AccurateResults() public {
        _setupSeparationModeWithCollateral();
        
        vm.startPrank(user1);
        
        // Provide TYPE_A collateral (1000 TOKA = $1000, 80% collateral factor = $800)
        tokenA.approve(address(bTokenA), 1000 * 10**18);
        bTokenA.mint(1000 * 10**18);
        
        address[] memory markets = new address[](1);
        markets[0] = address(bTokenA);
        blotroller.enterMarkets(markets);
        
        // Check separated liquidity
        (uint256 err, uint256 liquidityA, uint256 shortfallA, uint256 liquidityB, uint256 shortfallB) = 
            blotroller.getAccountLiquiditySeparated(user1);
            
        assertEq(err, 0, "Should not error");
        assertGt(liquidityA, 0, "TYPE_A liquidity should be > 0 (TYPE_A collateral available for TYPE_B borrowing)");
        assertEq(liquidityB, 0, "TYPE_B liquidity should be 0 (no TYPE_B collateral for TYPE_A borrowing)");
        assertEq(shortfallA, 0, "Should have no TYPE_A shortfall");
        assertEq(shortfallB, 0, "Should have no TYPE_B shortfall");
        
        vm.stopPrank();
    }

    // ============================================================
    // Internal Helper Functions (Updated)
    // ============================================================
    
    function _setupTokenTypes() internal {
        vm.startPrank(admin);
        
        // Support markets first
        blotroller._supportMarket(BToken(address(bTokenA)));
        blotroller._supportMarket(BToken(address(bTokenB)));
        
        blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        blotroller._setTokenType(BToken(address(bTokenB)), BlotrollerStorage.TokenType.TYPE_B);
        
        vm.stopPrank();
    }
    
    function _setupSeparationMode() internal {
        _setupTokenTypes();
        
        vm.startPrank(admin);
        blotroller._setSeparationMode(true);
        vm.stopPrank();
    }
    
    function _setupTokenTypesAndCollateral() internal {
        vm.startPrank(admin);
        
        // Support markets
        blotroller._supportMarket(BToken(address(bTokenA)));
        blotroller._supportMarket(BToken(address(bTokenB)));
        blotroller._supportMarket(BToken(address(bTokenC)));
        
        // Set token types
        blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        blotroller._setTokenType(BToken(address(bTokenB)), BlotrollerStorage.TokenType.TYPE_B);
        // bTokenC remains unclassified
        
        // Set collateral factors (80%)
        blotroller._setCollateralFactor(BToken(address(bTokenA)), 800000000000000000);
        blotroller._setCollateralFactor(BToken(address(bTokenB)), 800000000000000000);
        blotroller._setCollateralFactor(BToken(address(bTokenC)), 800000000000000000);
        
        // Give tokens to user1 for testing
        tokenA.transfer(user1, 10000 * 10**18);
        tokenB.transfer(user1, 10000 * 10**6);
        tokenC.transfer(user1, 10000 * 10**18);
        
        // Give tokens to liquidityProvider for cross-liquidity
        tokenA.transfer(liquidityProvider, 10000 * 10**18);
        tokenB.transfer(liquidityProvider, 10000 * 10**6);
        tokenC.transfer(liquidityProvider, 10000 * 10**18);
        
        // Keep enough tokens for admin to provide liquidity
        // (admin already has the initial supply)
        
        vm.stopPrank();
    }
    
    function _setupSeparationModeWithCollateral() internal {
        _setupTokenTypesAndCollateral();
        
        vm.startPrank(admin);
        blotroller._setSeparationMode(true);
        
        // Provide liquidity to all BTokens so they have cash to lend
        tokenA.approve(address(bTokenA), 100000 * 10**18);
        bTokenA.mint(100000 * 10**18);
        
        tokenB.approve(address(bTokenB), 100000 * 10**6);
        bTokenB.mint(100000 * 10**6);
        
        tokenC.approve(address(bTokenC), 100000 * 10**18);
        bTokenC.mint(100000 * 10**18);
        
        // Admin also provides collateral for both TYPE_A and TYPE_B to create cross-liquidity
        // This ensures there's enough liquidity for both A->B and B->A borrowing
        address[] memory adminMarkets = new address[](2);
        adminMarkets[0] = address(bTokenA);
        adminMarkets[1] = address(bTokenB);
        blotroller.enterMarkets(adminMarkets);
        
        vm.stopPrank();
        
        // Set up liquidityProvider to provide TYPE_B collateral for TYPE_A borrowing
        vm.startPrank(liquidityProvider);
        
        tokenB.approve(address(bTokenB), 5000 * 10**6);
        bTokenB.mint(5000 * 10**6);
        
        address[] memory lpMarkets = new address[](1);
        lpMarkets[0] = address(bTokenB);
        blotroller.enterMarkets(lpMarkets);
        
        vm.stopPrank();
    }
}
