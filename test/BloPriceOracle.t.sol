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

        (address tslaUnderlying,,,,,uint16 tslaMaxConf) = oracle.assetConfigs(address(TSLA_BTOKEN));
        assertEq(tslaUnderlying, TSLA_UNDERLYING);
        assertEq(tslaMaxConf, 200, "TSLA maxConfidenceRatio should be 200");

        (address usdtUnderlying,,,,,uint16 usdtMaxConf) = oracle.assetConfigs(address(USDT_BTOKEN));
        assertEq(usdtUnderlying, USDT_UNDERLYING);
        assertEq(usdtMaxConf, 50, "USDT maxConfidenceRatio should be 50");
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

    function test_SetAssetConfigWithZeroMaxConfidenceRatio() public {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfig();
        configs[0].maxConfidenceRatio = 0; // Valid: 0% means always fallback to Chainlink

        oracle.setAssetConfigs(bTokens, configs);
        
        // Verify the configuration was set
        (,,,,,uint16 maxConf) = oracle.assetConfigs(address(TSLA_BTOKEN));
        assertEq(maxConf, 0, "maxConfidenceRatio should be 0");
        
        vm.stopPrank();
    }

    function test_Fail_SetAssetConfigWithExcessiveMaxConfidenceRatio() public {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = _createTslaConfig();
        configs[0].maxConfidenceRatio = 10001; // Invalid: > 100%

        vm.expectRevert(BloPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();
    }

    function test_SetAssetConfigWithValidMaxConfidenceRatios() public {
        vm.startPrank(owner);
        address[] memory bTokens = new address[](3);
        bTokens[0] = address(TSLA_BTOKEN);
        bTokens[1] = address(USDT_BTOKEN);
        bTokens[2] = address(0x1234); // Mock third token

        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](3);
        configs[0] = _createTslaConfig();
        configs[0].maxConfidenceRatio = 0; // Minimum: 0% (always fallback)
        
        configs[1] = _createUsdtConfig();
        configs[1].maxConfidenceRatio = 10000; // Maximum: 100%
        
        configs[2] = BloPriceOracle.AssetConfig({
            underlying: address(0x5678),
            baseUnit: 1e18,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 500 // 5%
        });

        oracle.setAssetConfigs(bTokens, configs);
        
        // Verify configurations were set correctly
        (,,,,,uint16 maxConf1) = oracle.assetConfigs(bTokens[0]);
        (,,,,,uint16 maxConf2) = oracle.assetConfigs(bTokens[1]);
        (,,,,,uint16 maxConf3) = oracle.assetConfigs(bTokens[2]);
        
        assertEq(maxConf1, 0, "First asset should have 0% threshold (always fallback)");
        assertEq(maxConf2, 10000, "Second asset should have 100% threshold");
        assertEq(maxConf3, 500, "Third asset should have 5% threshold");
        
        vm.stopPrank();
    }

    // ============================================================
    // Section: Price Selection Logic
    // ============================================================

    function test_PriceSelection_PrefersNewerPythPrice() public {
        _setupTslaMarket();

        mockChainlinkTsla.setPrice(250 * 1e8, block.timestamp - 10);
        mockPyth.setPrice(TSLA_PYTH_ID, 251 * 1e6, -6); // This sets conf = 1 by default

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);

        // Expected: 251 * 1e6 (uses raw price since confidence is within threshold)
        uint256 priceInternal = 251 * 1e6;
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
        // Expected: 250 * 1e6 (uses raw price since confidence is within threshold)
        uint256 expectedPrice1 = OZMath.mulDiv(250 * 1e6, 1e30, 1e8);
        assertEq(price1, expectedPrice1, "Should ignore negative price and use Pyth price");

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

    function test_ConfidenceRatio_BelowThreshold() public {
        _setupTslaMarket(); // maxConfidenceRatio = 200 (2%)

        // Set Pyth price with confidence: $250 ± $2.5 (1% confidence ratio)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 250 * 1e6, 2500000, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: 250 * 1e6 (uses raw price since confidence ratio is below threshold)
        uint256 expectedPriceInternal = 250 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should use raw price when confidence ratio is below threshold");
    }

    function test_ConfidenceRatio_AboveThreshold_FallbackToChainlink() public {
        _setupTslaMarket(); // maxConfidenceRatio = 200 (2%)

        // Set Pyth price with confidence: $100 ± $5 (5% confidence ratio - above 2% threshold)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 5 * 1e6, -6);
        // Also set Chainlink as fallback
        mockChainlinkTsla.setPrice(105 * 1e8, block.timestamp - 5);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Should fallback to Chainlink price: $105
        uint256 expectedPriceInternal = 105 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should fallback to Chainlink when confidence ratio exceeds threshold");
    }

    function test_ConfidenceRatio_ExactlyAtThreshold() public {
        _setupTslaMarket(); // maxConfidenceRatio = 200 (2%)

        // Set Pyth price with confidence: $100 ± $2 (exactly 2% confidence ratio)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 2 * 1e6, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: 100 * 1e6 (uses raw price since confidence ratio equals threshold)
        uint256 expectedPriceInternal = 100 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should use raw price when confidence ratio equals threshold");
    }

    function test_ConfidenceRatio_VeryHighThreshold() public {
        // Setup with very high threshold (50% = 5000 basis points)
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = BloPriceOracle.AssetConfig({
            underlying: TSLA_UNDERLYING,
            baseUnit: 1e8,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 5000 // 50%
        });
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        // Set high confidence: $100 ± $40 (40% confidence ratio - still below 50% threshold)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 40 * 1e6, -6);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Expected: 100 * 1e6 (uses raw price since confidence ratio is below threshold)
        uint256 expectedPriceInternal = 100 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should use raw price when confidence ratio is below high threshold");
    }

    function test_ConfidenceRatio_MultipleAssets_DifferentThresholds() public {
        // Setup assets with different confidence thresholds
        vm.startPrank(owner);
        
        address[] memory bTokens = new address[](2);
        bTokens[0] = address(TSLA_BTOKEN);
        bTokens[1] = address(USDT_BTOKEN);
        
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](2);
        configs[0] = BloPriceOracle.AssetConfig({
            underlying: TSLA_UNDERLYING,
            baseUnit: 1e8,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 200 // 2% for TSLA
        });
        configs[1] = BloPriceOracle.AssetConfig({
            underlying: USDT_UNDERLYING,
            baseUnit: 1e6,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkUsdt)),
            pythPriceId: USDT_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 50 // 0.5% for USDT (stablecoin, tighter threshold)
        });
        
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        // Set same confidence ratio for both: 1%
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 1 * 1e6, -6);  // $100 ± $1 (1%)
        mockPyth.setPriceWithConfidence(USDT_PYTH_ID, 1000000, 10000, -6);       // $1.00 ± $0.01 (1%)
        
        // Set Chainlink as fallback (older timestamp to ensure Pyth is selected first)
        mockChainlinkTsla.setPrice(105 * 1e8, block.timestamp - 10);
        mockChainlinkUsdt.setPrice(1010000, block.timestamp - 10);

        uint256 tslaPrice = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        uint256 usdtPrice = oracle.getUnderlyingPrice(USDT_BTOKEN);
        
        // TSLA: 1% < 2% threshold, so uses Pyth price
        uint256 expectedTslaPrice = OZMath.mulDiv(100 * 1e6, 1e30, 1e8);
        // USDT: 1% > 0.5% threshold, so fallback to Chainlink
        uint256 expectedUsdtPrice = OZMath.mulDiv(1010000, 1e30, 1e6);
        
        assertEq(tslaPrice, expectedTslaPrice, "TSLA should use Pyth price (within threshold)");
        assertEq(usdtPrice, expectedUsdtPrice, "USDT should fallback to Chainlink (exceeds threshold)");
    }

    function test_ConfidenceRatio_ZeroThreshold_AlwaysFallback() public {
        // Setup with zero threshold (always fallback to Chainlink)
        vm.startPrank(owner);
        address[] memory bTokens = new address[](1);
        bTokens[0] = address(TSLA_BTOKEN);
        BloPriceOracle.AssetConfig[] memory configs = new BloPriceOracle.AssetConfig[](1);
        configs[0] = BloPriceOracle.AssetConfig({
            underlying: TSLA_UNDERLYING,
            baseUnit: 1e8,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkTsla)),
            pythPriceId: TSLA_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 0 // 0% means always fallback to Chainlink
        });
        oracle.setAssetConfigs(bTokens, configs);
        vm.stopPrank();

        // Set very small confidence: $100 ± $0.01 (0.01% confidence ratio)
        mockPyth.setPriceWithConfidence(TSLA_PYTH_ID, 100 * 1e6, 10000, -6); // $100 ± $0.01
        // Set Chainlink price (older timestamp to ensure Pyth would normally be selected)
        mockChainlinkTsla.setPrice(105 * 1e8, block.timestamp - 10);

        uint256 price = oracle.getUnderlyingPrice(TSLA_BTOKEN);
        
        // Should always fallback to Chainlink price: $105, regardless of confidence
        uint256 expectedPriceInternal = 105 * 1e6;
        uint256 expectedPrice = OZMath.mulDiv(expectedPriceInternal, 1e30, 1e8);
        
        assertEq(price, expectedPrice, "Should always fallback to Chainlink when maxConfidenceRatio is 0");
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
            maxConfidenceRatio: 200 // 2% threshold for TSLA
        });
    }

    function _createUsdtConfig() internal view returns (BloPriceOracle.AssetConfig memory) {
        return BloPriceOracle.AssetConfig({
            underlying: USDT_UNDERLYING,
            baseUnit: 1e6,
            chainlinkFeed: AggregatorV3Interface(address(mockChainlinkUsdt)),
            pythPriceId: USDT_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 50 // 0.5% threshold for USDT (stablecoin)
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
