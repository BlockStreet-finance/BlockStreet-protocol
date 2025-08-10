#!/bin/bash

# BlockStreet Protocol Deployment Script
# Usage: ./script/deploy.sh [testnet|mainnet] [--verify]

set -e

# Load environment variables
if [ -f .env ]; then
    echo "Loading environment variables from .env..."
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

# Configuration
ENVIRONMENT=${1:-testnet}
VERIFY_FLAG=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse options
for arg in "$@"; do
    case $arg in
        --verify)
            VERIFY_FLAG="--verify"
            shift
            ;;
    esac
done

# Set network-specific variables
if [ "$ENVIRONMENT" = "testnet" ]; then
    NETWORK_FLAG="--rpc-url ${BSC_TESTNET_RPC:-https://data-seed-prebsc-1-s1.binance.org:8545/} --with-gas-price 100000000"
    ETHERSCAN_API_KEY="$BSCSCAN_TESTNET_API_KEY"
    echo "🚀 Deploying to BSC Testnet..."
elif [ "$ENVIRONMENT" = "mainnet" ]; then
    NETWORK_FLAG="--rpc-url ${BSC_MAINNET_RPC:-https://bsc-dataseed.binance.org/} --with-gas-price 200000000"
    ETHERSCAN_API_KEY="$BSCSCAN_API_KEY"
    echo "🚀 Deploying to BSC Mainnet..."
    echo "⚠️  WARNING: This is MAINNET deployment!"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled"
        exit 1
    fi
else
    echo "❌ Invalid environment. Use 'testnet' or 'mainnet'"
    exit 1
fi

# Validate environment variables
echo "🔍 Validating environment..."

if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ PRIVATE_KEY not set in .env"
    exit 1
fi

if [ "$VERIFY_FLAG" = "--verify" ] && [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "❌ BSCScan API key not set for verification"
    exit 1
fi

echo "✅ Environment validated"

# Create deployments directory if it doesn't exist
mkdir -p deployments

# Deploy contracts
echo "📦 Deploying contracts..."

DEPLOY_CMD="forge script script/Deploy.s.sol:DeployScript \
    $NETWORK_FLAG \
    --private-key $PRIVATE_KEY \
    --broadcast \
    -vvvv"

if [ "$VERIFY_FLAG" = "--verify" ]; then
  if [ "$ENVIRONMENT" = "testnet" ]; then
        DEPLOY_CMD="$DEPLOY_CMD --verify --verifier-url https://api.etherscan.io/v2/api?chainid=97 --etherscan-api-key $ETHERSCAN_API_KEY"
  else
        DEPLOY_CMD="$DEPLOY_CMD --verify --verifier-url https://api.etherscan.io/v2/api?chainid=56 --etherscan-api-key $ETHERSCAN_API_KEY"
  fi
fi

echo "Executing: $DEPLOY_CMD"
eval $DEPLOY_CMD

if [ $? -eq 0 ]; then
    echo "✅ Deployment completed successfully!"
    echo ""
    echo "📁 Deployment artifacts saved in broadcast/ directory"
else
    echo "❌ Deployment failed!"
    exit 1
fi