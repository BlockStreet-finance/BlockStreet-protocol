#!/bin/bash

# Display deployed contract addresses
# Usage: ./script/addresses.sh [testnet|mainnet]

ENVIRONMENT=${1:-testnet}

if [ "$ENVIRONMENT" = "testnet" ]; then
    FILE="deployments/testnet-latest.json"
elif [ "$ENVIRONMENT" = "mainnet" ]; then
    FILE="deployments/mainnet-latest.json"
else
    echo "❌ Invalid environment. Use 'testnet' or 'mainnet'"
    exit 1
fi

if [ ! -f "$FILE" ]; then
    echo "❌ Deployment file not found: $FILE"
    echo "Run deployment first: ./script/deploy.sh $ENVIRONMENT"
    exit 1
fi

echo "📋 BlockStreet Protocol Addresses ($ENVIRONMENT)"
echo "================================================"

# Parse and display addresses
cat "$FILE" | jq -r '
  "Core Contracts:",
  "  Unitroller: " + .unitroller,
  "  Blotroller: " + .blotroller,
  "  Price Oracle: " + .priceOracle,
  "  Interest Rate Model: " + .interestRateModel,
  "  BErc20 Delegate: " + .bErc20Delegate,
  "",
  "Market Contracts:",
  "  bUSDC: " + .bUSDC,
  "  bTSLA: " + .bTSLA,
  (if .mockUSDC then ("", "Test Tokens:", "  Mock USDC: " + .mockUSDC) else empty end),
  (if .mockTSLA then ("  Mock TSLA: " + .mockTSLA) else empty end)
'