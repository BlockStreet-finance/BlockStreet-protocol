// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/BloPriceOracle.sol";
import "../src/BToken.sol";

// Import test mocks. Ensure the 'mocks' directory is present in 'test/'.
import "./mocks/MockPyth.sol";
import "./mocks/MockAggregatorV3.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Test Suite for the BloPriceOracle
 * @author BlockStreet
 * @dev This suite tests all core functionalities of the BloPriceOracle, including
 *      admin controls, price selection logic, failure modes, and correct price scaling.
 *      It specifically tests a stock asset (TSLA) and a stablecoin (USDT).
 */
contract BloPriceOracleTest is Test {
    // --- Test Environment Constants ---
    uint256 internal constant TEST_BLOCK_TIMESTAMP = 1672531200;
    uint256 internal constant TEST_BLOCK_NUMBER = 1000000;

    // --- Contracts and Mocks ---
    BloPriceOracle internal oracle;
    MockPyth internal mockPyth;
    MockAggregatorV3 internal mockChainlinkTsla;
    MockAggregatorV3 internal mockChainlinkUsdt;

    // --- Users ---
    address internal owner = address(0x1);
    address internal user = address(0x2);

    // --- Test Constants for TSLA Market ---
    MockBToken internal constant TSLA_BTOKEN = MockBToken(payable(address(0x751A))); // Mock bTSLA
    address internal constant TSLA_UNDERLYING = 0x1E42624ed29F2D23a993f3425c53202294676176; // Mock synthetic TSLA
    bytes32 internal constant TSLA_PYTH_ID = 0x2b923c83c435941669a2f9a5c4159428b37e41e52952a3473e1b365101259315;

    // --- Test Constants for USDT Market ---
    MockBToken internal constant USDT_BTOKEN = MockBToken(payable(address(0xDEAD))); // Mock bUSDT
    address internal constant USDT_UNDERLYING = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // Real USDT on Mainnet
    bytes32 internal constant USDT_PYTH_ID = 0x2b89b9d85295bf3e83411b5f52b4b54957415b937f8c15365ceb6d36b4d1d364;

    uint32 internal constant MAX_PRICE_AGE = 3600; // 1 hour

    function setUp() public {
        vm.warp(TEST_BLOCK_TIMESTAMP);
        vm.roll(TEST_BLOCK_NUMBER);
        vm.startPrank(owner);
        // Deploy mocks
        mockPyth = new MockPyth();
        // Chainlink price feeds for synthetic stocks often use 8 decimals
        mockChainlinkTsla = new MockAggregatorV3(8);
        // USDT on Ethereum has 6 decimals
        mockChainlinkUsdt = new MockAggregatorV3(6);

        // Deploy the oracle contract under test
        oracle = new BloPriceOracle(IPyth(address(mockPyth)));

        vm.stopPrank();
    }

    // ============================================================
    // Section: Admin Functions
    // ============================================================

    function test_OwnerCanSetAssetConfigs() public {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](2);
        bTokens[0] = address(TSLA_BTOKEN);
        bTokens[1] = address(USDT_BTOKEN);

        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](2);
        configs[0] = _createTslaConfig();
        configs[1] = _createUsdtConfig();

        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        (address tslaUnderlying,,,,,) = oracle.assetConfigs(address(TSLA_BTOKEN));
        assertEq(tslaUnderlying, TSLA_UNDERLYING);

        (address usdtUnderlying,,,,,) = oracle.assetConfigs(address(USDT_BTOKEN));
        assertEq(usdtUnderlying, USDT_UNDERLYING);
    }

    function test_Fail_NonOwnerCannotSetConfig() public {
        vm.startPrank(user);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfig();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();
    }

    function test_Fail_SetAssetConfigWithInvalidData() public {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfig();
        configs[0].baseUnit = 0; // Set an invalid base unit

        vm.expectRevert(BloPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();
    }

    // ============================================================
    // Section: Price Selection Logic
    // ============================================================

    function test_PriceSelection_PrefersNewerPythPrice() public {
        _setupTslaMarket(); // TSLA is collateral asset

        mockChainlinkTsla.setPrice(250 * 1e8, block.timestamp - 10);
        mockPyth.setPrice(TSLA_PYTH_ID, 251 * 1e6, -6); // This sets conf = 1 by default

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);

        // Expected: (251 - 1) * 1e6 = 250 * 1e6 (price - confidence for collateral)
        uint256 priceInternal = (251 * 1e6) - 1; // 251000000 - 1 = 250999999
        uint256 baseUnit = 1e8;
        uint256 expectedPrice = OZMath.mulDiv(priceInternal, 1e30, baseUnit);

        assertEq(price, expectedPrice);
    }

    function test_PriceSelection_PrefersNewerChainlinkPrice() public {
        _setupTslaMarket();
        mockPyth.setPrice(TSLA_PYTH_ID, 250 * 1e6, -6);
        vm.warp(TEST_BLOCK_TIMESTAMP + 10);
        mockChainlinkTsla.setPrice(251 * 1e8); // Set Chainlink price now

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        uint256 priceInternal = 251 * 1e6; // Normalized price
        uint256 baseUnit = 1e8;
        uint256 expectedPrice = OZMath.mulDiv(priceInternal, 1e30, baseUnit);
        assertEq(price, expectedPrice);
    }

    // ============================================================
    // Section: Edge Cases and Failure Modes
    // ============================================================

    function test_Fail_WhenMarketIsNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(BloPriceOracle.OracleMarketNotConfigured.selector, address(TSLA_BTOKEN)));
        oracle.getUnderlyingPrice(TSLA_BTOKEN);
    }

    function test_Fail_WhenAllPricesAreStaleOrInvalid() public {
        _setupTslaMarket();
        mockChainlinkTsla.setPrice(0); // Set an invalid (zero) price
        mockPyth.setPrice(TSLA_PYTH_ID, 251 * 1e6, -6);
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1); // Make the only valid price (Pyth) become stale

        //vm.expectRevert(BloPriceOracle.OraclePriceNotFound.selector);
        vm.expectRevert(abi.encodeWithSelector(BloPriceOracle.OraclePriceNotFound.selector, address(TSLA_BTOKEN)));
        oracle.getUnderlyingPrice(TSLA_BTOKEN);
    }

    // ============================================================
    // Section: Price Scaling Verification
    // ============================================================

    function test_PriceScaling_IsCorrectForStablecoin() public {
        _setupUsdtMarket(); // USDT has 6 decimals
        mockChainlinkUsdt.setPrice(1 * 1e6); // Price is exactly $1.00

        uint256 price = oracle.getUnderlyingPrice(USDT_BTOKEN);
        // Expected: (1 * 1e6) * 1e30 / 1e6 = 1 * 1e30
        uint256 expectedPrice = 1e30;
        assertEq(price, expectedPrice, "Price scaling for USDT is incorrect");
    }

    function test_PriceScaling_IsCorrectForStockAsset() public {
        _setupTslaMarket(); // TSLA has 8 decimals
        mockChainlinkTsla.setPrice(250 * 1e8); // Price is $250.00

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        uint256 priceInternal = 250 * 1e6; // Normalized price
        uint256 baseUnit = 1e8;
        uint256 expectedPrice = OZMath.mulDiv(priceInternal, 1e30, baseUnit);
        assertEq(price, expectedPrice, "Price scaling for TSLA is incorrect");
    }

    function test_PriceSelection_HandlesEdgeCases() public {
        _setupTslaMarket();

        mockChainlinkTsla.setPrice(-100 * 1e8, block.timestamp - 5);
        mockPyth.setPrice(TSLA_PYTH_ID, 250 * 1e6, -6); // conf = 1 by default

        uint256 price1 = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        // Expected: (250 - 1) * 1e6 for collateral asset
        uint256 expectedPrice1 = OZMath.mulDiv((250 * 1e6) - 1, 1e30, 1e8);
        assertEq(price1, expectedPrice1, "Should ignore negative price and apply confidence interval");

        int256 smallPrice = 100; // $0.000001
        mockChainlinkTsla.setPrice(smallPrice);

        uint256 price2 = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        assertGt(price2, 0, "Small but valid price should work");

        int256 largePrice = 1_000_000 * 1e8; // $1M  protection?
        mockChainlinkTsla.setPrice(largePrice);

        uint256 price3 = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        assertGt(price3, 0, "Large price should work");
    }

    // ============================================================
    // Section: Confidence Interval Tests
    // ============================================================

    function test_ConfidenceInterval_CollateralAsset() public {
        _setupTslaMarket(); // TSLA is configured as collateral asset

        // Set Pyth price with confidence: $250 ± $5
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 250 * 1e6, 5 * 1e6, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: (250 - 5) * 1e6 = 245 * 1e6 (conservative pricing for collateral)
        uint256 expectedPriceInternal = 245 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Collateral asset should use price - confidence");
    }

    function test_ConfidenceInterval_BorrowedAsset() public {
        _setupUsdtMarket(); // USDT is configured as borrowed asset

        // Set Pyth price with confidence: $1.00 ± $0.02
        mockPyth.setPriceWithConfidence(USDT_PYTH_ID, 1000000, 20000, -6); // $1.000000 ± $0.020000

        uint256 price = oracle.getUnderlyingPrice(USDT_BTOKEN);
        
        // Expected: (1.00 + 0.02) * 1e6 = 1.02 * 1e6 (conservative debt valuation)
        uint256 expectedPriceInternal = 1020000;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e6);
        
        assertEq(price, expectedPrice, "Borrowed asset should use price + confidence");
    }

    function test_ConfidenceInterval_FallbackWhenConfidenceExceedsPrice() public {
        _setupTslaMarket();

        // Set extreme confidence that exceeds price: $100 ± $150
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 150 * 1e6, -6);
        // Also set Chainlink as fallback
        mockChainlinkTsla.setPrice(105 * 1e8, block.timestamp - 5);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Should fallback to Chainlink price: $105
        uint256 expectedPriceInternal = 105 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should fallback to Chainlink when confidence >= price");
    }

    function test_ConfidenceInterval_NormalOperationWithSmallConfidence() public {
        _setupTslaMarket();

        // Set normal confidence: $250 ± $1 (0.4% confidence)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 250 * 1e6, 1 * 1e6, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: (250 - 1) * 1e6 = 249 * 1e6
        uint256 expectedPriceInternal = 249 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Normal confidence should work correctly");
    }

    function test_ConfidenceInterval_BorrowedAssetWithHighButReasonableConfidence() public {
        // Setup TSLA as borrowed asset for this test
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfigAsBorrowed();
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        // Set high but reasonable confidence: $100 ± $50 (50% confidence - high volatility but reasonable)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 50 * 1e6, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: (100 + 50) * 1e6 = 150 * 1e6 (conservative debt valuation)
        uint256 expectedPriceInternal = 150 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Borrowed asset should use price + confidence for reasonable confidence levels");
    }

    function test_ConfidenceInterval_BothAssetTypesFallbackWhenConfidenceExceedsPrice() public {
        // Test that both collateral and borrowed assets fallback when confidence >= price
        vm.startPrank(owner);
        
        // Setup both asset types
        address[] memory bTokens = new address[](2);
        bTokens[0] = address(TSLA_BTOKEN);  // Will be collateral
        bTokens[1] = address(USDT_BTOKEN);  // Will be borrowed
        
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](2);
        configs[0] = _createTslaConfig();    // isCollateralAsset = true
        configs[1] = _createUsdtConfig();    // isCollateralAsset = false
        
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        // Set unreasonable confidence for both: price ± (price + 1)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 101 * 1e6, -6);  // $100 ± $101
        mockPyth.setPriceWithConfidence(USDT_PYTH_ID, 1000000, 1000001, -6);        // $1.00 ± $1.000001
        
        // Set Chainlink as fallback for both
        mockChainlinkTsla.setPrice(105 * 1e8);
        mockChainlinkUsdt.setPrice(1010000); // $1.01 in 6 decimals

        // Both should fallback to Chainlink
        uint256 tslaPrice = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        uint256 usdtPrice = oracle.getUnderlyingPrice(USDT_BTOKEN);
        
        // Expected Chainlink prices (no confidence adjustment)
        uint256 expectedTslaPrice = OZMath.mulDiv(105 * 1e6, 1e30, 1e8);
        uint256 expectedUsdtPrice = OZMath.mulDiv(1010000, 1e30, 1e6);
        
        assertEq(tslaPrice, expectedTslaPrice, "Collateral asset should fallback when confidence >= price");
        assertEq(usdtPrice, expectedUsdtPrice, "Borrowed asset should also fallback when confidence >= price");
    }

    // ============================================================
    // Internal Helper Functions
    // ============================================================

    function _createTslaConfig() internal view returns (BloPriceOracle.AssetConfig memory) {
        return BloPriceOracle.AssetConfig({
            underlying: TSLA_UNDERLYING,
            baseUnit: 1e8,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            isCollateralAsset: true // TSLA as collateral asset
        });
    }

    function _createUsdtConfig() internal view returns (BloPriceOracle.AssetConfig memory) {
        return BloPriceOracle.AssetConfig({
            underlying: USDT_UNDERLYING,
            baseUnit: 1e6,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkUsdt)),
            pythPriceId: USDT_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            isCollateralAsset: false // USDT as borrowed asset
        });
    }

    function _createTslaConfigAsBorrowed() internal view returns (BloPriceOracle.AssetConfig memory) {
        return BloPriceOracle.AssetConfig({
            underlying: TSLA_UNDERLYING,
            baseUnit: 1e8,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            isCollateralAsset: false // TSLA as borrowed asset for testing
        });
    }

    function _setupTslaMarket() internal {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfig();
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();
    }

    function _setupUsdtMarket() internal {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(USDT_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createUsdtConfig();
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();
    }
}

/**
 * @dev A minimal mock BToken to satisfy the type requirement of getUnderlyingPrice.
 * It implements the BToken interface with empty functions, as we only need the
 * type for compilation, not the logic.
 */
contract MockBToken is BToken {
    // The constructor for BToken is empty, so we can call it directly.
    constructor() BToken() {}

    // =================================================================
    // == Implementation of BToken's abstract functions ==
    // =================================================================
    // We must provide empty bodies for these functions to make MockBToken non-abstract.

    function getCashPrior() internal view virtual override returns (uint256) {
        return 0;
    }

    function doTransferIn(address from, uint256 amount) internal virtual override returns (uint256) {
        // To avoid "unused parameter" warnings, we can use the parameters.
        if (from == address(0) || amount == 0) {
            return 0;
        }
        return amount;
    }

    function doTransferOut(address payable to, uint256 amount) internal virtual override {
        // To avoid "unused parameter" warnings, we can use the parameters.
        if (to == address(0) || amount == 0) {
            return;
        }
    }

    // NOTE: We DO NOT implement any other functions like `initialize`, `mint`, etc.
    // Inheriting them from the base BToken is sufficient. Attempting to re-declare them
    // without `override` would cause a "Function with the same name exists" error,
    // and adding `override` would cause a "Function is not virtual" error.
    // By only implementing the required abstract functions, we avoid all these issues.
}
