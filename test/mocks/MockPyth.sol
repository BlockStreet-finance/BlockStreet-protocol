// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal prices;

    // --- Functions you actually use in tests ---

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view override returns (PythStructs.Price memory) {
        PythStructs.Price memory p = prices[id];
        require(p.publishTime >= block.timestamp - age, "MockPyth: Price is too old");
        return p;
    }

    // Helper function for tests to set the price
    function setPrice(bytes32 id, int64 price, int32 expo) public {
        prices[id] = PythStructs.Price({
            price: price,
            conf: 1, // Use a non-zero confidence for realism
            expo: expo,
            publishTime: uint64(block.timestamp)
        });
    }

    function getPriceUnsafe(bytes32 id) external view override returns (PythStructs.Price memory) {
        return prices[id];
    }

    // --- Stub implementations for unused interface functions ---

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256 feeAmount) {
        return 1; // Return a nominal fee
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        // Empty implementation is sufficient
    }

    function getEmaPriceUnsafe(bytes32 id) external view override returns (PythStructs.Price memory) {
        return prices[id];
    }

    function getEmaPriceNoOlderThan(bytes32 id, uint256 age)
        external
        view
        override
        returns (PythStructs.Price memory)
    {
        PythStructs.Price memory p = prices[id];
        require(p.publishTime >= block.timestamp - age, "MockPyth: Price is too old");
        return p;
    }

    function parsePriceFeedUpdates(bytes[] calldata, bytes32[] calldata, uint64, uint64)
        external
        payable
        override
        returns (PythStructs.PriceFeed[] memory)
    {
        return new PythStructs.PriceFeed[](0);
    }

    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata)
        external
        payable
        override
    {
        // Empty implementation is sufficient
    }

    // --- NEWLY ADDED MISSING FUNCTIONS BASED ON THE LATEST IPyth.sol ---

    function getTwapUpdateFee(bytes[] calldata) external pure override returns (uint256 feeAmount) {
        return 1; // Return a nominal fee
    }

    function parsePriceFeedUpdatesWithConfig(bytes[] calldata, bytes32[] calldata, uint64, uint64, bool, bool, bool)
        external
        payable
        override
        returns (PythStructs.PriceFeed[] memory, uint64[] memory)
    {
        return (new PythStructs.PriceFeed[](0), new uint64[](0));
    }

    function parseTwapPriceFeedUpdates(bytes[] calldata, bytes32[] calldata)
        external
        payable
        override
        returns (PythStructs.TwapPriceFeed[] memory)
    {
        return new PythStructs.TwapPriceFeed[](0);
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata, uint64, uint64)
        external
        payable
        override
        returns (PythStructs.PriceFeed[] memory)
    {
        return new PythStructs.PriceFeed[](0);
    }
}
