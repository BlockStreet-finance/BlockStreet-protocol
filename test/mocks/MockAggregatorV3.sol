// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 private _latestAnswer;
    uint256 private _latestTimestamp;
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    // --- Test Helper Functions ---

    function setPrice(int256 price) public {
        _latestAnswer = price;
        _latestTimestamp = block.timestamp;
    }

    function setPrice(int256 price, uint256 timestamp) public {
        _latestAnswer = price;
        _latestTimestamp = timestamp;
    }

    // --- AggregatorV3Interface Implementation ---

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80, // roundId
            int256, // answer
            uint256, // startedAt
            uint256, // updatedAt
            uint80 // answeredInRound
        )
    {
        return (1, _latestAnswer, block.timestamp, _latestTimestamp, 1);
    }

    // --- Unused Interface Functions ---
    function description() external pure override returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _latestAnswer, block.timestamp, _latestTimestamp, 1);
    }
}
