// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../BErc20.sol";
import "../BToken.sol";
import "../PriceOracle.sol";
import "../EIP20Interface.sol";

interface BlotrollerLensInterface {
    function markets(address) external view returns (bool, uint);
    function oracle() external view returns (PriceOracle);
    function getAccountLiquidity(address) external view returns (uint, uint, uint);
    function getAssetsIn(address) external view returns (BToken[] memory);
    function borrowCaps(address) external view returns (uint);
}

interface GovernorBravoInterface {
    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }
    struct Proposal {
        uint id;
        address proposer;
        uint eta;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        uint abstainVotes;
        bool canceled;
        bool executed;
    }
    function getActions(uint proposalId) external view returns (address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas);
    function proposals(uint proposalId) external view returns (Proposal memory);
    function getReceipt(uint proposalId, address voter) external view returns (Receipt memory);
}

contract BlockStreetLens {
    struct BTokenMetadata {
        address bToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint bTokenDecimals;
        uint underlyingDecimals;
        uint borrowCap;
    }


    function bTokenMetadata(BToken bToken) public returns (BTokenMetadata memory) {
        uint exchangeRateCurrent = bToken.exchangeRateCurrent();
        BlotrollerLensInterface comptroller = BlotrollerLensInterface(address(bToken.comptroller()));
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(address(bToken));
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(bToken.symbol(), "bETH")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            BErc20 bErc20 = BErc20(address(bToken));
            underlyingAssetAddress = bErc20.underlying();
            underlyingDecimals = EIP20Interface(bErc20.underlying()).decimals();
        }

        uint borrowCap = 0;
        (bool borrowCapSuccess, bytes memory borrowCapReturnData) =
            address(comptroller).call(
                abi.encodePacked(
                    comptroller.borrowCaps.selector,
                    abi.encode(address(bToken))
                )
            );
        if (borrowCapSuccess) {
            borrowCap = abi.decode(borrowCapReturnData, (uint));
        }

        return BTokenMetadata({
            bToken: address(bToken),
            exchangeRateCurrent: exchangeRateCurrent,
            supplyRatePerBlock: bToken.supplyRatePerBlock(),
            borrowRatePerBlock: bToken.borrowRatePerBlock(),
            reserveFactorMantissa: bToken.reserveFactorMantissa(),
            totalBorrows: bToken.totalBorrows(),
            totalReserves: bToken.totalReserves(),
            totalSupply: bToken.totalSupply(),
            totalCash: bToken.getCash(),
            isListed: isListed,
            collateralFactorMantissa: collateralFactorMantissa,
            underlyingAssetAddress: underlyingAssetAddress,
            bTokenDecimals: bToken.decimals(),
            underlyingDecimals: underlyingDecimals,
            borrowCap: borrowCap
        });
    }

    function bTokenMetadataAll(BToken[] calldata bTokens) external returns (BTokenMetadata[] memory) {
        uint bTokenCount = bTokens.length;
        BTokenMetadata[] memory res = new BTokenMetadata[](bTokenCount);
        for (uint i = 0; i < bTokenCount; i++) {
            res[i] = bTokenMetadata(bTokens[i]);
        }
        return res;
    }

    struct BTokenBalances {
        address bToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    function bTokenBalances(BToken bToken, address payable account) public returns (BTokenBalances memory) {
        uint balanceOf = bToken.balanceOf(account);
        uint borrowBalanceCurrent = bToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = bToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (compareStrings(bToken.symbol(), "bETH")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            BErc20 bErc20 = BErc20(address(bToken));
            EIP20Interface underlying = EIP20Interface(bErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(bToken));
        }

        return BTokenBalances({
            bToken: address(bToken),
            balanceOf: balanceOf,
            borrowBalanceCurrent: borrowBalanceCurrent,
            balanceOfUnderlying: balanceOfUnderlying,
            tokenBalance: tokenBalance,
            tokenAllowance: tokenAllowance
        });
    }

    function bTokenBalancesAll(BToken[] calldata bTokens, address payable account) external returns (BTokenBalances[] memory) {
        uint bTokenCount = bTokens.length;
        BTokenBalances[] memory res = new BTokenBalances[](bTokenCount);
        for (uint i = 0; i < bTokenCount; i++) {
            res[i] = bTokenBalances(bTokens[i], account);
        }
        return res;
    }

    struct BTokenUnderlyingPrice {
        address bToken;
        uint underlyingPrice;
    }

    function bTokenUnderlyingPrice(BToken bToken) public returns (BTokenUnderlyingPrice memory) {
        BlotrollerLensInterface comptroller = BlotrollerLensInterface(address(bToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return BTokenUnderlyingPrice({
            bToken: address(bToken),
            underlyingPrice: priceOracle.getUnderlyingPrice(bToken)
        });
    }

    function bTokenUnderlyingPriceAll(BToken[] calldata bTokens) external returns (BTokenUnderlyingPrice[] memory) {
        uint bTokenCount = bTokens.length;
        BTokenUnderlyingPrice[] memory res = new BTokenUnderlyingPrice[](bTokenCount);
        for (uint i = 0; i < bTokenCount; i++) {
            res[i] = bTokenUnderlyingPrice(bTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        BToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    function getAccountLimits(BlotrollerLensInterface comptroller, address account) public view returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0);

        return AccountLimits({
            markets: comptroller.getAssetsIn(account),
            liquidity: liquidity,
            shortfall: shortfall
        });
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function add(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        require(b <= a, errorMessage);
        uint c = a - b;
        return c;
    }
}
