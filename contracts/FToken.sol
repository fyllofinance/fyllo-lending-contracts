pragma solidity ^0.5.16;

import "./compound/CToken.sol";
import "./Fyllotroller.sol";
import "./IERC3156FlashBorrower.sol";
import "./ILiquidityGauge.sol";

contract FToken is CToken {
    struct LiquidationLocalVars {
        uint256 borrowerTokensNew;
        uint256 liquidatorTokensNew;
        uint256 safetyVaultTokensNew;
        uint256 safetyVaultTokens;
        uint256 liquidatorSeizeTokens;
    }

    function mintFresh(address minter, uint256 mintAmount) internal returns (uint256, uint256) {
        (uint256 mintError, uint256 actualMintAmount) = super.mintFresh(minter, mintAmount);

        if (mintError == uint256(Error.NO_ERROR)) {
            notifySavingsChange(minter);
        }
        return (mintError, actualMintAmount);
    }

    function redeemFresh(
        address payable redeemer,
        uint256 redeemTokensIn,
        uint256 redeemAmountIn
    ) internal returns (uint256) {
        uint256 redeemError = super.redeemFresh(redeemer, redeemTokensIn, redeemAmountIn);

        if (redeemError == uint256(Error.NO_ERROR)) {
            notifySavingsChange(redeemer);
        }
        return redeemError;
    }

    function notifySavingsChange(address addr) internal {
        FylloConfig fylloCfg = Fyllotroller(address(comptroller)).fylloCfg();
        ILiquidityGauge liquidityGauge = fylloCfg.liquidityGauge();
        if (address(liquidityGauge) != address(0)) {
            liquidityGauge.notifySavingsChange(addr);
        }
    }

    function transferTokens(address spender, address src, address dst, uint256 tokens) internal returns (uint256) {
        uint256 errorCode = super.transferTokens(spender, src, dst, tokens);
        if (errorCode == uint256(Error.NO_ERROR)) {
            notifySavingsChange(src);
            notifySavingsChange(dst);
        }
        return errorCode;
    }

    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) internal returns (uint256) {
        /* Fail if seize not allowed */
        uint256 allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, allowed);
        }

        /* Fail if borrower = liquidator */
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }

        LiquidationLocalVars memory vars;

        FylloConfig fylloCfg = Fyllotroller(address(comptroller)).fylloCfg();
        uint256 liquidationIncentive = comptroller.getLiquidationIncentive(seizerToken);
        (vars.liquidatorSeizeTokens, vars.safetyVaultTokens) = fylloCfg.calculateSeizeTokenAllocation(
            seizeTokens,
            liquidationIncentive
        );
        address safetyVault = fylloCfg.safetyVault();
        /*
         * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
         *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
         *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
         */
        vars.borrowerTokensNew = sub_(accountTokens[borrower], seizeTokens);

        vars.liquidatorTokensNew = add_(accountTokens[liquidator], vars.liquidatorSeizeTokens);

        vars.safetyVaultTokensNew = add_(accountTokens[safetyVault], vars.safetyVaultTokens);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write the previously calculated values into storage */
        accountTokens[borrower] = vars.borrowerTokensNew;
        accountTokens[liquidator] = vars.liquidatorTokensNew;
        accountTokens[safetyVault] = vars.safetyVaultTokensNew;

        notifySavingsChange(borrower);
        notifySavingsChange(liquidator);
        notifySavingsChange(safetyVault);
        /* Emit a Transfer event */
        emit Transfer(borrower, liquidator, vars.liquidatorSeizeTokens);
        emit Transfer(borrower, safetyVault, vars.safetyVaultTokens);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets a new reserve factor for the protocol (*requires fresh interest accrual)
     * @dev Admin function to set a new reserve factor
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setReserveFactorFresh(uint256 newReserveFactorMantissa) internal returns (uint256) {
        // Check caller is admin
        if (msg.sender != comptroller.safetyGuardian() && msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_RESERVE_FACTOR_ADMIN_CHECK);
        }

        // Verify market's block timestamp equals current block timestamp
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_RESERVE_FACTOR_FRESH_CHECK);
        }

        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            return fail(Error.BAD_INPUT, FailureInfo.SET_RESERVE_FACTOR_BOUNDS_CHECK);
        }

        uint256 oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReservesFresh(address payable to, uint256 reduceAmount) internal returns (uint256) {
        // totalReserves - reduceAmount
        uint256 totalReservesNew;

        // Check caller is admin
        if (msg.sender != comptroller.safetyGuardian()) {
            return fail(Error.UNAUTHORIZED, FailureInfo.REDUCE_RESERVES_ADMIN_CHECK);
        }

        // We fail gracefully unless market's block timestamp equals current block timestamp
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.REDUCE_RESERVES_FRESH_CHECK);
        }

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < reduceAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH, FailureInfo.REDUCE_RESERVES_CASH_NOT_AVAILABLE);
        }

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        if (reduceAmount > totalReserves) {
            return fail(Error.BAD_INPUT, FailureInfo.REDUCE_RESERVES_VALIDATION);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        totalReservesNew = sub_(totalReserves, reduceAmount);

        // Store reserves[n+1] = reserves[n] - reduceAmount
        totalReserves = totalReservesNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(to, reduceAmount);

        emit ReservesReduced(to, reduceAmount, totalReservesNew);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice updates the interest rate model (*requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint256) {
        // Used to store old model for use in the event that is emitted on success
        InterestRateModel oldInterestRateModel;

        // Check caller is admin
        if (msg.sender != comptroller.safetyGuardian() && msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_INTEREST_RATE_MODEL_OWNER_CHECK);
        }

        // We fail gracefully unless market's block timestamp equals current block timestamp
        if (accrualBlockTimestamp != getBlockTimestamp()) {
            return fail(Error.MARKET_NOT_FRESH, FailureInfo.SET_INTEREST_RATE_MODEL_FRESH_CHECK);
        }

        // Track the market's current interest rate model
        oldInterestRateModel = interestRateModel;

        // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
        require(newInterestRateModel.isInterestRateModel(), "invalid irm");

        // Set the interest rate model to newInterestRateModel
        interestRateModel = newInterestRateModel;

        // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);

        return uint256(Error.NO_ERROR);
    }

    function isNativeToken() public pure returns (bool) {
        return false;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view returns (uint256) {
        validateFlashLoanToken(token);
        return Fyllotroller(address(comptroller)).getFlashLoanCap(address(this));
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view returns (uint256) {
        validateFlashLoanToken(token);
        return getFlashFeeInternal(token, amount);
    }

    function getFlashFeeInternal(address token, uint256 amount) internal view returns (uint256) {
        token;
        return Fyllotroller(address(comptroller)).fylloCfg().getFlashFee(msg.sender, address(this), amount);
    }

    /**
     * @dev Initiate a flash loan.
     * @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        accrueInterest();
        validateFlashLoanToken(token);

        Fyllotroller(address(comptroller)).flashLoanAllowed(address(this), address(receiver), amount);

        uint256 cashBefore = getCashPrior();
        require(cashBefore >= amount, "insufficient cash");
        // 1. calculate fee
        uint256 fee = getFlashFeeInternal(token, amount);
        // 2. update totalBorrows
        totalBorrows = add_(totalBorrows, amount);
        // 3. transfer fund  to receiver
        doFlashLoanTransferOut(address(uint160(address(receiver))), token, amount);
        // 4. execute receiver's callback function
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "IERC3156: Callback failed"
        );
        // 5. take amount + fee from receiver
        uint256 repaymentAmount = add_(amount, fee);
        doFlashLoanTransferIn(address(receiver), token, repaymentAmount);

        // 6. update reserves
        totalReserves = add_(totalReserves, fee);
        totalBorrows = sub_(totalBorrows, amount);
        return true;
    }

    function doFlashLoanTransferOut(address payable receiver, address token, uint256 amount) internal {
        token;
        doTransferOut(receiver, amount);
    }

    function doFlashLoanTransferIn(address receiver, address token, uint256 amount) internal {
        token;
        uint256 actualAmount = doTransferIn(receiver, amount);
        require(actualAmount == amount, "!amount");
    }

    function validateFlashLoanToken(address token) internal view;
}
