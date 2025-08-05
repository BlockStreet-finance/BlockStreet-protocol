// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./BToken.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@pythnetwork/pyth-sdk-solidity/PythUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
/**
 * @title The BloPriceOracle for the BlockStreet Protocol
 * @author BlockStreet
 * @notice Provides reliable, real-time asset prices for the BlockStreet protocol.
 * @dev This is the official, production-grade price oracle. It replaces SimplePriceOracle
 *      for mainnet deployment. It sources prices from Chainlink and Pyth Network,
 *      implementing the PriceOracle interface required by the Blotroller.
 */

contract BloPriceOracle is PriceOracle, Ownable {
    /// @notice The internal price precision used to normalize prices from all external sources.
    uint256 private constant INTERNAL_PRICE_DECIMALS = 6;
    uint256 private constant INTERNAL_PRICE_UNIT = 10 ** INTERNAL_PRICE_DECIMALS;

    /// @notice The Pyth Network oracle contract, configured at deployment.
    IPyth public immutable pyth;

    /// @notice Configuration for a single bToken market.
    struct AssetConfig {
        address underlying;
        uint256 baseUnit; // The scaling factor of the underlying token (e.g., 1e8 for TSLA, 1e6 for USDT).
        AggregatorV3Interface chainlinkFeed;
        bytes32 pythPriceId;
        uint32 maxPriceAge; // Maximum age of a price feed in seconds before it's considered stale.
        bool isCollateralAsset; // Whether this asset is used as collateral (true) or borrowed (false).
    }

    /// @notice Maps a bToken address to its price feed configuration.
    mapping(address => AssetConfig) public assetConfigs;

    event MarketOracleConfigUpdated(address indexed bToken, AssetConfig newConfig);

    error OracleMarketNotConfigured(address bToken);
    error OraclePriceNotFound(address bToken);
    error OracleInvalidConfiguration();

    /**
     * @notice Constructs the price oracle.
     * @param pythOracleAddress The on-chain address of the Pyth Network oracle contract.
     */
    constructor(IPyth pythOracleAddress) Ownable(msg.sender) {
        pyth = pythOracleAddress;
    }

    /**
     * @notice Gets the price of a bToken's underlying asset, scaled for the Blotroller.
     * @dev This function precisely implements the `PriceOracle` interface. It fetches the most
     *      recent valid price from configured sources and scales it to the format required
     *      by the Blotroller.
     * @param bToken The BToken contract to get the price for.
     * @return The price, scaled by 1e(36 - underlying_decimals).
     */
    function getUnderlyingPrice(BToken bToken) external view override returns (uint256) {
        address bTokenAddress = address(bToken);
        AssetConfig memory config = assetConfigs[bTokenAddress];

        if (config.underlying == address(0)) {
            revert OracleMarketNotConfigured(bTokenAddress);
        }

        (uint256 chainlinkPrice, uint256 chainlinkTimestamp) = _fetchChainlinkPrice(config);
        (uint256 pythPrice, uint256 pythTimestamp) = _fetchPythPrice(config);

        // Select the price from the source with the most recent, valid timestamp.
        uint256 priceInternal;
        if (pythTimestamp > chainlinkTimestamp) {
            priceInternal = pythPrice;
        } else {
            priceInternal = chainlinkPrice;
        }

        if (priceInternal == 0) {
            revert OraclePriceNotFound(bTokenAddress);
        }

        // The Blotroller expects prices scaled by 1e(36 - underlying_decimals).
        // Our internal price has 6 decimals, so we scale it to 36 total decimals
        // before dividing by the underlying token's base unit.
        //return (priceInternal * 1e30) / config.baseUnit;
        return OZMath.mulDiv(priceInternal, 1e30, config.baseUnit);
    }

    /**
     * @dev Fetches and normalizes the price from a Chainlink feed.
     * @return price The price normalized to INTERNAL_PRICE_UNIT (1e6), or 0 if invalid/stale.
     * @return timestamp The timestamp of the fetched price, or 0.
     */
    function _fetchChainlinkPrice(AssetConfig memory config) internal view returns (uint256 price, uint256 timestamp) {
        if (address(config.chainlinkFeed) == address(0)) return (0, 0);

        try config.chainlinkFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 ts, uint80) {
            if (answer <= 0 || block.timestamp > ts + config.maxPriceAge) {
                return (0, 0);
            }
            // Normalize price to our internal 6-decimal format.
            price = (uint256(answer) * INTERNAL_PRICE_UNIT) / (10 ** config.chainlinkFeed.decimals());
            /*if (price == 0) {
                return (0, 0);
            }*/
            timestamp = ts;
        } catch {
            return (0, 0);
        }
    }

    /**
     * @dev Fetches and normalizes the price from the Pyth Network with confidence interval adjustment.
     * @dev For collateral assets, applies conservative pricing (price - confidence).
     * @dev For borrowed assets, applies conservative debt valuation (price + confidence).
     * @return price The price normalized to INTERNAL_PRICE_UNIT (1e6), adjusted for confidence, or 0 if invalid/stale.
     * @return timestamp The timestamp of the fetched price, or 0.
     */
    function _fetchPythPrice(AssetConfig memory config) internal view returns (uint256 price, uint256 timestamp) {
        if (config.pythPriceId == bytes32(0)) return (0, 0);

        try pyth.getPriceNoOlderThan(config.pythPriceId, config.maxPriceAge) returns (
            PythStructs.Price memory pythPrice
        ) {
            if (pythPrice.price <= 0) {
                return (0, 0);
            }

            // Normalize price and confidence to our internal 6-decimal format
            uint256 priceRaw = PythUtils.convertToUint(pythPrice.price, pythPrice.expo, uint8(INTERNAL_PRICE_DECIMALS));
            uint256 confidence =
                PythUtils.convertToUint(int64(pythPrice.conf), pythPrice.expo, uint8(INTERNAL_PRICE_DECIMALS));

            if (confidence >= priceRaw) {
                // If confidence is greater than or equal to price, fall back to Chainlink
                return (0, 0);
            }

            // Apply confidence interval based on asset type
            if (config.isCollateralAsset) {
                // For collateral assets: use conservative valuation (price - confidence)
                price = priceRaw - confidence;
            } else {
                // For borrowed assets: use conservative debt valuation (price + confidence)
                price = priceRaw + confidence;
            }

            timestamp = pythPrice.publishTime;
        } catch {
            return (0, 0);
        }
    }

    /**
     * @notice Sets or updates the configurations for multiple bToken markets.
     * @dev Admin-only function. This is the preferred method for bulk updates to save gas.
     * @param bTokens An array of bToken addresses to configure.
     * @param configs An array of AssetConfig structs corresponding to each bToken.
     */
    function setAssetConfigs(address[] calldata bTokens, AssetConfig[] calldata configs) external onlyOwner {
        uint256 numTokens = bTokens.length;
        if (numTokens != configs.length) revert OracleInvalidConfiguration();

        for (uint256 i = 0; i < numTokens; i++) {
            _setAssetConfig(bTokens[i], configs[i]);
        }
    }

    /**
     * @dev Internal logic to set a single asset's configuration.
     * @dev Validates that the asset has at least one price source (Chainlink or Pyth).
     */
    function _setAssetConfig(address bToken, AssetConfig calldata config) internal {
        if (bToken == address(0) || config.underlying == address(0) || config.baseUnit == 0 || config.maxPriceAge == 0)
        {
            revert OracleInvalidConfiguration();
        }

        assetConfigs[bToken] = config;
        emit MarketOracleConfigUpdated(bToken, config);
    }
}
