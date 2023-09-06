pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../CErc20.sol";
import "../../FToken.sol";
import "../CToken.sol";
import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../SafeMath.sol";

interface ComptrollerLensInterface {
    function markets(address) external view returns (bool, uint256);

    function oracle() external view returns (PriceOracle);

    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);

    function getAssetsIn(address) external view returns (CToken[] memory);

    function claimComp(address) external;

    function compAccrued(address) external view returns (uint256);
}

contract CompoundLens {
    using SafeMath for uint256;

    struct CTokenMetadata {
        address cToken;
        uint256 exchangeRateCurrent;
        uint256 supplyRatePerSecond;
        uint256 borrowRatePerSecond;
        uint256 reserveFactorMantissa;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 totalSupply;
        uint256 totalCash;
        bool isListed;
        uint256 collateralFactorMantissa;
        address underlyingAssetAddress;
        uint256 cTokenDecimals;
        uint256 underlyingDecimals;
    }

    function cTokenMetadataExpand(
        FToken cToken
    )
        public
        returns (
            uint256 collateralFactorMantissa,
            uint256 exchangeRateCurrent,
            uint256 supplyRatePerSecond,
            uint256 borrowRatePerSecond,
            uint256 reserveFactorMantissa,
            uint256 totalBorrows,
            uint256 totalReserves,
            uint256 totalSupply,
            uint256 totalCash,
            bool isListed,
            address underlyingAssetAddress,
            uint256 underlyingDecimals
        )
    {
        CTokenMetadata memory cTokenData = cTokenMetadata(cToken);
        exchangeRateCurrent = cTokenData.exchangeRateCurrent;
        supplyRatePerSecond = cTokenData.supplyRatePerSecond;
        borrowRatePerSecond = cTokenData.borrowRatePerSecond;
        reserveFactorMantissa = cTokenData.reserveFactorMantissa;
        totalBorrows = cTokenData.totalBorrows;
        totalReserves = cTokenData.totalReserves;
        totalSupply = cTokenData.totalSupply;
        totalCash = cTokenData.totalCash;
        isListed = cTokenData.isListed;
        collateralFactorMantissa = cTokenData.collateralFactorMantissa;
        underlyingAssetAddress = cTokenData.underlyingAssetAddress;
        underlyingDecimals = cTokenData.underlyingDecimals;
    }

    function cTokenMetadata(FToken cToken) public returns (CTokenMetadata memory) {
        uint256 exchangeRateCurrent = cToken.exchangeRateCurrent();
        ComptrollerLensInterface comptroller = ComptrollerLensInterface(address(cToken.comptroller()));
        (bool isListed, uint256 collateralFactorMantissa) = comptroller.markets(address(cToken));
        address underlyingAssetAddress;
        uint256 underlyingDecimals;

        if (cToken.isNativeToken()) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            CErc20 cErc20 = CErc20(address(cToken));
            underlyingAssetAddress = cErc20.underlying();
            underlyingDecimals = EIP20Interface(cErc20.underlying()).decimals();
        }

        return
            CTokenMetadata({
                cToken: address(cToken),
                exchangeRateCurrent: exchangeRateCurrent,
                supplyRatePerSecond: cToken.supplyRatePerSecond(),
                borrowRatePerSecond: cToken.borrowRatePerSecond(),
                reserveFactorMantissa: cToken.reserveFactorMantissa(),
                totalBorrows: cToken.totalBorrows(),
                totalReserves: cToken.totalReserves(),
                totalSupply: cToken.totalSupply(),
                totalCash: cToken.getCash(),
                isListed: isListed,
                collateralFactorMantissa: collateralFactorMantissa,
                underlyingAssetAddress: underlyingAssetAddress,
                cTokenDecimals: cToken.decimals(),
                underlyingDecimals: underlyingDecimals
            });
    }

    function cTokenMetadataAll(FToken[] calldata cTokens) external returns (CTokenMetadata[] memory) {
        uint256 cTokenCount = cTokens.length;
        CTokenMetadata[] memory res = new CTokenMetadata[](cTokenCount);
        for (uint256 i = 0; i < cTokenCount; i++) {
            res[i] = cTokenMetadata(cTokens[i]);
        }
        return res;
    }

    struct CTokenBalances {
        address cToken;
        uint256 balanceOf;
        uint256 borrowBalanceCurrent;
        uint256 balanceOfUnderlying;
        uint256 tokenBalance;
        uint256 tokenAllowance;
    }

    function cTokenBalances(FToken cToken, address payable account) public returns (CTokenBalances memory) {
        uint256 balanceOf = cToken.balanceOf(account);
        uint256 borrowBalanceCurrent = cToken.borrowBalanceCurrent(account);
        uint256 balanceOfUnderlying = cToken.balanceOfUnderlying(account);
        uint256 tokenBalance;
        uint256 tokenAllowance;

        if (cToken.isNativeToken()) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            CErc20 cErc20 = CErc20(address(cToken));
            EIP20Interface underlying = EIP20Interface(cErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(cToken));
        }

        return
            CTokenBalances({
                cToken: address(cToken),
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                balanceOfUnderlying: balanceOfUnderlying,
                tokenBalance: tokenBalance,
                tokenAllowance: tokenAllowance
            });
    }

    function cTokenBalancesAll(
        FToken[] calldata cTokens,
        address payable account
    ) external returns (CTokenBalances[] memory) {
        uint256 cTokenCount = cTokens.length;
        CTokenBalances[] memory res = new CTokenBalances[](cTokenCount);
        for (uint256 i = 0; i < cTokenCount; i++) {
            res[i] = cTokenBalances(cTokens[i], account);
        }
        return res;
    }

    struct CTokenUnderlyingPrice {
        address cToken;
        uint256 underlyingPrice;
    }

    function cTokenUnderlyingPrice(CToken cToken) public view returns (CTokenUnderlyingPrice memory) {
        ComptrollerLensInterface comptroller = ComptrollerLensInterface(address(cToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return
            CTokenUnderlyingPrice({cToken: address(cToken), underlyingPrice: priceOracle.getUnderlyingPrice(cToken)});
    }

    function cTokenUnderlyingPriceAll(
        CToken[] calldata cTokens
    ) external view returns (CTokenUnderlyingPrice[] memory) {
        uint256 cTokenCount = cTokens.length;
        CTokenUnderlyingPrice[] memory res = new CTokenUnderlyingPrice[](cTokenCount);
        for (uint256 i = 0; i < cTokenCount; i++) {
            res[i] = cTokenUnderlyingPrice(cTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        CToken[] markets;
        uint256 liquidity;
        uint256 shortfall;
    }

    function getAccountLimits(
        ComptrollerLensInterface comptroller,
        address account
    ) public view returns (AccountLimits memory) {
        (uint256 errorCode, uint256 liquidity, uint256 shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0);

        return AccountLimits({markets: comptroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall});
    }

    function getAccountLimitsExpand(
        ComptrollerLensInterface comptroller,
        address account
    ) public view returns (uint256 liquidity, uint256 shortfall, CToken[] memory markets) {
        AccountLimits memory accountLimits = getAccountLimits(comptroller, account);
        liquidity = accountLimits.liquidity;
        shortfall = accountLimits.shortfall;
        markets = accountLimits.markets;
    }

    function getCompBalanceWithAccrued(
        EIP20Interface comp,
        ComptrollerLensInterface comptroller,
        address account
    ) external returns (uint256 balance, uint256 allocated) {
        balance = comp.balanceOf(account);
        comptroller.claimComp(account);
        uint256 newBalance = comp.balanceOf(account);
        uint256 accrued = comptroller.compAccrued(account);
        uint256 total = add(accrued, newBalance, "sum comp total");
        allocated = sub(total, balance, "sub allocated");
    }

    function add(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }
}
