## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
## Deployment

### Prerequisites

**Set up environment variables**:
```bash
cp .env.example .env
# Edit .env with your configuration
```

### Configuration

Edit `config/deploy.json` to customize deployment parameters:

```json
{
  "protocol": {
    "closeFactor": "500000000000000000",
    "liquidationIncentive": "1080000000000000000",
    "maxAssets": 10
  },
  "governance": {
    "admin": "0x...",
    "pauseGuardian": "0x...",
    "borrowCapGuardian": "0x..."
  },
  "markets": {
    "USDC": {
      "collateralFactor": "800000000000000000",
      "reserveFactor": "100000000000000000",
      "borrowCap": "10000000000000000000000000"
    }
  }
}
```

### Deploy to Testnet

```bash
# Deploy to BSC Testnet
./script/deploy.sh testnet

# Deploy with contract verification
./script/deploy.sh testnet --verify
```

### View Deployed Addresses

```bash
# View testnet addresses
./script/addresses.sh testnet

# View mainnet addresses  
./script/addresses.sh mainnet
```

Example output:
```
📋 BlockStreet Protocol Addresses (testnet)
================================================
Core Contracts:
  Unitroller: 0x5a66463Bc17ecefA01920bea61980d1b4Fe0E5a5
  Blotroller: 0x96f6d18bA601D21E7A2816762f61b178b8D1d91f
  Price Oracle: 0x96ca588c9A216B2561cA56f0E4215a6A05DA2fd0
  Interest Rate Model: 0x55Fc55e6177F8d16689BA121B6aFeF3cC9eC2a63
  BErc20 Delegate: 0xBD0392Bd4992fE2D6a880fF24008579267a22E26

Market Contracts:
  bUSDC: 0x1fa8b126D273e571499cc62f56B609D9882822a9
  bTSLA: 0x9b8A426277f9F12c44dA6BDB6c93a7E66c96F3eD

Test Tokens:
  Mock USDC: 0x64544969ed7EBf5f083679233325356EbE738930
  Mock TSLA: 0x57F61DA3b7FC9df62857b979aA76A16417BeF396
```
