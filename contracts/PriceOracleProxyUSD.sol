pragma solidity ^0.5.16;

import "./compound/SafeMath.sol";
import "./compound/PriceOracle.sol";
import "./compound/CErc20.sol";
import "./AggregatorV3Interface.sol";
import "./Ownable.sol";

contract PriceOracleProxyUSD is PriceOracle, Ownable, Exponential {
    /// @notice The minimum staleness check
    uint256 private constant minStalenessCheck = 600; // the number of seconds in 10 minutes
    /// @notice The maximum staleness check
    uint256 private constant maxStalenessCheck = 5400; // the number of seconds in 90 minutes
    /// @notice The current staleness check
    uint256 public oracleStalenessCheck = 3600; // the number of seconds in 60 minutes
    /// @notice The max price diff that we could tolerant
    uint256 public maxPriceDiff = 0.1e18;

    /// @notice Chainlink Aggregators
    mapping(address => AggregatorV3Interface) public aggregators;

    event MaxPriceDiffUpdated(uint256 maxDiff);
    event AggregatorUpdated(address cTokenAddress, address source);
    event OracleStalenessCheckUpdated(uint256 indexed preOracleStalenessCheck, uint256 indexed newOracleStalenessCheck);

    constructor() public {}

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(CToken cToken) external view returns (uint256) {
        address cTokenAddress = address(cToken);

        uint256 chainLinkPrice = getPriceFromChainlink(cTokenAddress);
        return chainLinkPrice;
    }

    /*** Internal functions ***/

    /**
     * @notice Check the max diff between two prices.
     * @param price1 Price 1
     * @param price2 Price 2
     */
    function checkPriceDiff(uint256 price1, uint256 price2) internal view {
        uint256 min = price1 < price2 ? price1 : price2;
        uint256 max = price1 < price2 ? price2 : price1;

        // priceCap = min * (1 + maxPriceDiff)
        uint256 onePlusMaxDiffMantissa = add_(1e18, maxPriceDiff);
        uint256 priceCap = mul_(min, Exp({mantissa: onePlusMaxDiffMantissa}));
        require(priceCap > max, "too much diff between price feeds");
    }

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cTokenAddress The cToken address
     * @return The price. Return 0 if the aggregator is not set.
     */
    function getPriceFromChainlink(address cTokenAddress) internal view returns (uint256) {
        AggregatorV3Interface aggregator = aggregators[cTokenAddress];
        if (address(aggregator) != address(0)) {
            (, int256 answer, , uint256 updatedAt, ) = aggregator.latestRoundData();
            uint256 timeSinceUp = sub_(block.timestamp, updatedAt);

            require(answer > 0 && timeSinceUp < oracleStalenessCheck, "invalid answer");

            // Extend the decimals to 1e18.
            uint256 price = mul_(uint256(answer), 10 ** (18 - uint256(aggregator.decimals())));
            return getNormalizedPrice(price, cTokenAddress);
        }
        return 0;
    }

    /**
     * @notice Normalize the price according to the underlying decimals.
     * @param price The original price
     * @param cTokenAddress The cToken address
     * @return The normalized price.
     */
    function getNormalizedPrice(uint256 price, address cTokenAddress) internal view returns (uint256) {
        uint256 underlyingDecimals = EIP20Interface(CErc20(cTokenAddress).underlying()).decimals();
        return mul_(price, 10 ** (18 - underlyingDecimals));
    }

    ////////////////
    // Only Owner //
    ////////////////

    /**
     * @notice Set ChainLink aggregators for multiple cTokens
     * @param cTokenAddresses The list of cTokens
     * @param sources The list of ChainLink aggregator sources
     */
    function _setAggregators(address[] calldata cTokenAddresses, address[] calldata sources) external onlyOwner {
        for (uint256 i = 0; i < cTokenAddresses.length; i++) {
            aggregators[cTokenAddresses[i]] = AggregatorV3Interface(sources[i]);
            emit AggregatorUpdated(cTokenAddresses[i], sources[i]);
        }
    }

    function _setMaxPriceDiff(uint256 _maxPriceDiff) external onlyOwner {
        maxPriceDiff = _maxPriceDiff;
        emit MaxPriceDiffUpdated(_maxPriceDiff);
    }

    /**
     * @notice set a staleness check for the oracle; revert if it exceeds this value
     * @dev Only callable by the owner
     */
    function _setOracleStalenessCheck(uint256 _oracleStalenessCheck) external onlyOwner {
        require(
            _oracleStalenessCheck > minStalenessCheck && _oracleStalenessCheck < maxStalenessCheck,
            "invalid oracleStalenessCheck"
        );
        emit OracleStalenessCheckUpdated(oracleStalenessCheck, _oracleStalenessCheck);
        oracleStalenessCheck = _oracleStalenessCheck;
    }
}
