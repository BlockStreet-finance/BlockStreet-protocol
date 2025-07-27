// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./BToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./BlotrollerInterface.sol";
import "./BlotrollerStorage.sol";
import "./Unitroller.sol";

/**
 * @title BlockStreet's Blotroller Contract
 * @author BlockStreet
 */
contract Blotroller is BlotrollerStorage, BlotrollerInterface, BlotrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(BToken bToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(BToken bToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(BToken bToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(BToken bToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(BToken bToken, string action, bool pauseState);


    /// @notice Emitted when borrow cap for a bToken is changed
    event NewBorrowCap(BToken indexed bToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (BToken[] memory) {
        BToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param bToken The bToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, BToken bToken) external view returns (bool) {
        return markets[address(bToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param bTokens The list of addresses of the bToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory bTokens) override public returns (uint[] memory) {
        uint len = bTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            BToken bToken = BToken(bTokens[i]);

            results[i] = uint(addToMarketInternal(bToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param bToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(BToken bToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(bToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(bToken);

        emit MarketEntered(bToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param bTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address bTokenAddress) override external returns (uint) {
        BToken bToken = BToken(bTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the bToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = bToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(bTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(bToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set bToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete bToken from the account’s list of assets */
        // load into memory for faster iteration
        BToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == bToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        BToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(bToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param bToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address bToken, address minter, uint mintAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[bToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param bToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address bToken, address minter, uint actualMintAmount, uint mintTokens) override external {
        // Shh - currently unused
        bToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param bToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of bTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address bToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(bToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }



        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address bToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[bToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        if (separationModeEnabled) {
            // Get token type being redeemed
            TokenType redeemTokenType = tokenTypes[bToken];
            
            (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) = 
                getHypotheticalAccountLiquidityInternalSeparated(redeemer, BToken(bToken), redeemTokens, 0);
            
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            
            // Check if redeeming would cause shortfall in the corresponding borrow type
            // Type A collateral supports Type B borrowing
            // Type B collateral supports Type A borrowing
            if (redeemTokenType == TokenType.TYPE_A) {
                if (shortfallB > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            } else if (redeemTokenType == TokenType.TYPE_B) {
                if (shortfallA > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            }
            // Non-classified tokens can be redeemed freely in separation mode
        } else {
            // Original logic for non-separation mode
            (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, BToken(bToken), redeemTokens, 0);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            if (shortfall > 0) {
                return uint(Error.INSUFFICIENT_LIQUIDITY);
            }
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param bToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address bToken, address redeemer, uint redeemAmount, uint redeemTokens) override external {
        // Shh - currently unused
        bToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param bToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address bToken, address borrower, uint borrowAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[bToken], "borrow is paused");

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[bToken].accountMembership[borrower]) {
            // only bTokens may call borrowAllowed if borrower not in market
            require(msg.sender == bToken, "sender must be bToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(BToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[bToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(BToken(bToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[bToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = BToken(bToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        // Check liquidity based on separation mode
        if (separationModeEnabled) {
            // Get token type being borrowed
            TokenType borrowTokenType = tokenTypes[bToken];
            
            // In separation mode, only allow borrowing A/B classified tokens
            if (borrowTokenType != TokenType.TYPE_A && borrowTokenType != TokenType.TYPE_B) {
                return uint(Error.MARKET_NOT_LISTED); // Reuse this error for non-classified tokens in separation mode
            }
            
            (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) = 
                getHypotheticalAccountLiquidityInternalSeparated(borrower, BToken(bToken), 0, borrowAmount);
            
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            
            // Type A tokens can only be borrowed with Type B collateral
            // Type B tokens can only be borrowed with Type A collateral
            if (borrowTokenType == TokenType.TYPE_A) {
                if (shortfallB > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            } else if (borrowTokenType == TokenType.TYPE_B) {
                if (shortfallA > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            }
        } else {
            // Original logic for non-separation mode
            (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, BToken(bToken), 0, borrowAmount);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            if (shortfall > 0) {
                return uint(Error.INSUFFICIENT_LIQUIDITY);
            }
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param bToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address bToken, address borrower, uint borrowAmount) override external {
        // Shh - currently unused
        bToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param bToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address bToken,
        address payer,
        address borrower,
        uint repayAmount) override external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param bToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address bToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) override external {
        // Shh - currently unused
        bToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) override external returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[bTokenBorrowed].isListed || !markets[bTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = BToken(bTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(BToken(bTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            if (separationModeEnabled) {
                // In separation mode, check shortfall based on borrowed token type
                TokenType borrowedTokenType = tokenTypes[bTokenBorrowed];
                
                (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) = 
                    getHypotheticalAccountLiquidityInternalSeparated(borrower, BToken(address(0)), 0, 0);
                
                if (err != Error.NO_ERROR) {
                    return uint(err);
                }
                
                // Check shortfall for the appropriate type
                uint relevantShortfall = 0;
                if (borrowedTokenType == TokenType.TYPE_A) {
                    relevantShortfall = shortfallB; // Type A borrows require Type B collateral
                } else if (borrowedTokenType == TokenType.TYPE_B) {
                    relevantShortfall = shortfallA; // Type B borrows require Type A collateral
                }
                
                if (relevantShortfall == 0) {
                    return uint(Error.INSUFFICIENT_SHORTFALL);
                }
            } else {
                // Original logic for non-separation mode
                (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
                if (err != Error.NO_ERROR) {
                    return uint(err);
                }

                if (shortfall == 0) {
                    return uint(Error.INSUFFICIENT_SHORTFALL);
                }
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) override external {
        // Shh - currently unused
        bTokenBorrowed;
        bTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[bTokenCollateral].isListed || !markets[bTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (BToken(bTokenCollateral).comptroller() != BToken(bTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external {
        // Shh - currently unused
        bTokenCollateral;
        bTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param bToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address bToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(bToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param bToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     */
    function transferVerify(address bToken, address src, address dst, uint transferTokens) override external {
        // Shh - currently unused
        bToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `bTokenBalance` is the number of bTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint bTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @dev Separate liquidity calculation results for A/B token separation mode
     */
    struct SeparatedLiquidityLocalVars {
        uint sumCollateralA;      // Type A collateral
        uint sumCollateralB;      // Type B collateral
        uint sumBorrowA;          // Type A borrow
        uint sumBorrowB;          // Type B borrow
        uint sumBorrowPlusEffectsA; // Type A borrow plus effects
        uint sumBorrowPlusEffectsB; // Type B borrow plus effects
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, BToken(address(0)), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address bTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(bTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral bToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        BToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            BToken asset = assets[i];

            // Read the balances and exchange rate from the bToken
            (oErr, vars.bTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * bTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.bTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with bTokenModify
            if (asset == bTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Helper function to process a single asset for separated liquidity calculation
     */
    function _processSeparatedAsset(
        BToken asset,
        address account,
        SeparatedLiquidityLocalVars memory sepVars
    ) internal view returns (Error) {
        (uint oErr, uint bTokenBalance, uint borrowBalance, uint exchangeRateMantissa) = asset.getAccountSnapshot(account);
        if (oErr != 0) {
            return Error.SNAPSHOT_ERROR;
        }

        uint oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
        if (oraclePriceMantissa == 0) {
            return Error.PRICE_ERROR;
        }

        uint collateralFactorMantissa = markets[address(asset)].collateralFactorMantissa;
        
        // Calculate collateral and borrow values
        uint collateralValue = mul_ScalarTruncate(
            mul_(mul_(Exp({mantissa: collateralFactorMantissa}), Exp({mantissa: exchangeRateMantissa})), Exp({mantissa: oraclePriceMantissa})),
            bTokenBalance
        );
        uint borrowValue = mul_ScalarTruncate(Exp({mantissa: oraclePriceMantissa}), borrowBalance);

        // Accumulate by token type (only TYPE_A and TYPE_B participate in separation mode)
        TokenType tokenType = tokenTypes[address(asset)];
        if (tokenType == TokenType.TYPE_A) {
            sepVars.sumCollateralA += collateralValue;
            sepVars.sumBorrowA += borrowValue;
            sepVars.sumBorrowPlusEffectsA = sepVars.sumBorrowA;
        } else if (tokenType == TokenType.TYPE_B) {
            sepVars.sumCollateralB += collateralValue;
            sepVars.sumBorrowB += borrowValue;
            sepVars.sumBorrowPlusEffectsB = sepVars.sumBorrowB;
        }
        // Non-classified tokens (default value 0) are ignored in separation mode

        return Error.NO_ERROR;
    }

    /**
     * @notice Helper function to apply hypothetical changes to separated liquidity
     */
    function _applySeparatedEffects(
        BToken bTokenModify,
        address account,
        uint redeemTokens,
        uint borrowAmount,
        SeparatedLiquidityLocalVars memory sepVars
    ) internal view returns (Error) {
        if (address(bTokenModify) == address(0)) {
            return Error.NO_ERROR;
        }

        (, , , uint exchangeRateMantissa) = bTokenModify.getAccountSnapshot(account);
        uint oraclePriceMantissa = oracle.getUnderlyingPrice(bTokenModify);
        if (oraclePriceMantissa == 0) {
            return Error.PRICE_ERROR;
        }

        uint collateralFactorMantissa = markets[address(bTokenModify)].collateralFactorMantissa;
        TokenType tokenType = tokenTypes[address(bTokenModify)];

        if (tokenType == TokenType.TYPE_A) {
            sepVars.sumBorrowPlusEffectsA += mul_ScalarTruncate(
                mul_(mul_(Exp({mantissa: collateralFactorMantissa}), Exp({mantissa: exchangeRateMantissa})), Exp({mantissa: oraclePriceMantissa})),
                redeemTokens
            );
            sepVars.sumBorrowPlusEffectsA += mul_ScalarTruncate(Exp({mantissa: oraclePriceMantissa}), borrowAmount);
        } else if (tokenType == TokenType.TYPE_B) {
            sepVars.sumBorrowPlusEffectsB += mul_ScalarTruncate(
                mul_(mul_(Exp({mantissa: collateralFactorMantissa}), Exp({mantissa: exchangeRateMantissa})), Exp({mantissa: oraclePriceMantissa})),
                redeemTokens
            );
            sepVars.sumBorrowPlusEffectsB += mul_ScalarTruncate(Exp({mantissa: oraclePriceMantissa}), borrowAmount);
        }

        return Error.NO_ERROR;
    }

    /**
     * @notice Determine what the account liquidity would be with A/B separation mode
     * @param account The account to determine liquidity for
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code,
                Type A liquidity,
                Type A shortfall,
                Type B liquidity,
                Type B shortfall)
     */
    function getHypotheticalAccountLiquidityInternalSeparated(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint, uint, uint) {

        SeparatedLiquidityLocalVars memory sepVars;

        // Process each asset
        BToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            Error assetErr = _processSeparatedAsset(assets[i], account, sepVars);
            if (assetErr != Error.NO_ERROR) {
                return (assetErr, 0, 0, 0, 0);
            }
        }

        // Apply hypothetical effects
        Error effectsErr = _applySeparatedEffects(bTokenModify, account, redeemTokens, borrowAmount, sepVars);
        if (effectsErr != Error.NO_ERROR) {
            return (effectsErr, 0, 0, 0, 0);
        }

        // Calculate final results
        uint liquidityA = sepVars.sumCollateralA > sepVars.sumBorrowPlusEffectsB ? 
            sepVars.sumCollateralA - sepVars.sumBorrowPlusEffectsB : 0;
        uint shortfallA = sepVars.sumBorrowPlusEffectsB > sepVars.sumCollateralA ? 
            sepVars.sumBorrowPlusEffectsB - sepVars.sumCollateralA : 0;
        uint liquidityB = sepVars.sumCollateralB > sepVars.sumBorrowPlusEffectsA ? 
            sepVars.sumCollateralB - sepVars.sumBorrowPlusEffectsA : 0;
        uint shortfallB = sepVars.sumBorrowPlusEffectsA > sepVars.sumCollateralB ? 
            sepVars.sumBorrowPlusEffectsA - sepVars.sumCollateralB : 0;

        return (Error.NO_ERROR, liquidityA, shortfallA, liquidityB, shortfallB);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in bToken.liquidateBorrowFresh)
     * @param bTokenBorrowed The address of the borrowed bToken
     * @param bTokenCollateral The address of the collateral bToken
     * @param actualRepayAmount The amount of bTokenBorrowed underlying to convert into bTokenCollateral tokens
     * @return (errorCode, number of bTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address bTokenBorrowed, address bTokenCollateral, uint actualRepayAmount) override external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(BToken(bTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(BToken(bTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = BToken(bTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param bToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(BToken bToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(bToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(bToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(bToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param bToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(BToken bToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(bToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        bToken.isBToken(); // Sanity check to make sure its really a BToken

        Market storage newMarket = markets[address(bToken)];
        newMarket.isListed = true;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(bToken));

        emit MarketListed(bToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address bToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != BToken(bToken), "market already added");
        }
        allMarkets.push(BToken(bToken));
    }



    /**
      * @notice Set the given borrow caps for the given bToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param bTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(BToken[] calldata bTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps");

        uint numMarkets = bTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(bTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(bTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(BToken bToken, bool state) public returns (bool) {
        require(markets[address(bToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(BToken bToken, bool state) public returns (bool) {
        require(markets[address(bToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }


    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }


    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (BToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given bToken market has been deprecated
     * @dev All borrows in a deprecated bToken market can be immediately liquidated
     * @param bToken The market to check if deprecated
     */
    function isDeprecated(BToken bToken) public view returns (bool) {
        return
            markets[address(bToken)].collateralFactorMantissa == 0 &&
            borrowGuardianPaused[address(bToken)] == true &&
            bToken.reserveFactorMantissa() == 1e18
        ;
    }

    function getBlockNumber() virtual public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Admin function to set token type for A/B classification
     * @param bToken The bToken to classify
     * @param tokenType The type to assign (UNCLASSIFIED, TYPE_A, or TYPE_B)
     * @return uint 0=success, otherwise a failure
     */
    function _setTokenType(BToken bToken, TokenType tokenType) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        if (!markets[address(bToken)].isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        // Store old type for event
        TokenType oldType = tokenTypes[address(bToken)];
        
        // Set new type
        tokenTypes[address(bToken)] = tokenType;

        // Emit event
        emit TokenTypeSet(address(bToken), oldType, tokenType);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to toggle A/B separation mode
     * @param enabled Whether to enable separation mode
     * @return uint 0=success, otherwise a failure
     */
    function _setSeparationMode(bool enabled) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Store old mode for event
        bool oldMode = separationModeEnabled;
        
        // Set new mode
        separationModeEnabled = enabled;

        // Emit event
        emit SeparationModeToggled(oldMode, enabled);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Get separated account liquidity information (A/B types)
     * @param account The account to get liquidity for
     * @return (error code, A liquidity, A shortfall, B liquidity, B shortfall)
     */
    function getAccountLiquiditySeparated(address account) public view returns (uint, uint, uint, uint, uint) {
        if (!separationModeEnabled) {
            return (uint(Error.COMPTROLLER_MISMATCH), 0, 0, 0, 0); // Reuse error for disabled mode
        }
        
        (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) = 
            getHypotheticalAccountLiquidityInternalSeparated(account, BToken(address(0)), 0, 0);
        
        return (uint(err), liquidityA, shortfallA, liquidityB, shortfallB);
    }

    /**
     * @notice Get hypothetical separated account liquidity (A/B types)
     * @param account The account to get liquidity for
     * @param bTokenModify The market to hypothetically modify
     * @param redeemTokens Number of tokens to hypothetically redeem
     * @param borrowAmount Amount to hypothetically borrow
     * @return (error code, A liquidity, A shortfall, B liquidity, B shortfall)
     */
    function getHypotheticalAccountLiquiditySeparated(
        address account,
        address bTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) public view returns (uint, uint, uint, uint, uint) {
        if (!separationModeEnabled) {
            return (uint(Error.COMPTROLLER_MISMATCH), 0, 0, 0, 0); // Reuse error for disabled mode
        }
        
        (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) = 
            getHypotheticalAccountLiquidityInternalSeparated(account, BToken(bTokenModify), redeemTokens, borrowAmount);
        
        return (uint(err), liquidityA, shortfallA, liquidityB, shortfallB);
    }

}
