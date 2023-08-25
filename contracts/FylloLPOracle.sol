pragma solidity ^0.5.16;

import "./ChainlinkAggregatorV3Interface.sol";
import "./IUniswapV2Pair.sol";
import "./compound/SafeMath.sol";
import "./compound/EIP20Interface.sol";
import "./Ownable.sol";

contract FylloLPOracle is ChainlinkAggregatorV3Interface, Ownable {
    using SafeMath for uint;
    using SafeMath for uint8;

    uint8 private decimals_;
    string private description_;
    address public pair;

    ChainlinkAggregatorV3Interface public token0Source;
    ChainlinkAggregatorV3Interface public token1Source;

    uint private p0Decimals;
    uint private p1Decimals;

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    event ChainlinkSourceChanged(
        uint index,
        address newSource);

    constructor(
        uint8 _decimals,
        string memory _description,
        address _token0ChanlinkSource,
        address _token1ChanlinkSource,
        address _pair) public {
        decimals_ = _decimals;
        description_ = _description;
        token0Source = ChainlinkAggregatorV3Interface(_token0ChanlinkSource);
        token1Source = ChainlinkAggregatorV3Interface(_token1ChanlinkSource);
        pair = _pair;

        p0Decimals = token0Source.decimals();
        p1Decimals = token1Source.decimals();
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function description() external view returns (string memory) {
        return description_;
    }

    function version() external view returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId) public
    view
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        _roundId;

        RoundData memory data;
        uint totalSupply = IUniswapV2Pair(pair).totalSupply();
        (uint r0, uint r1, ) = IUniswapV2Pair(pair).getReserves();
        require(r0 != 0 && r1 != 0, "FylloLPOracle: bad reserve");

        uint sqrtK = sqrt(r0.mul(r1)).mul(10 ** uint(decimals_)).div(totalSupply);
        (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound) =
                getTokenPrice(IUniswapV2Pair(pair).token0(), token0Source);
        (, int256 px1,,,) = getTokenPrice(IUniswapV2Pair(pair).token1(), token1Source);
        // fair token0 amt: sqrtK * sqrt(px1/px0)
        // fair token1 amt: sqrtK * sqrt(px0/px1)
        // fair lp price = 2 * sqrt(px0 * px1)
        // split into 2 sqrts multiplication to prevent uint overflow
        answer = int256(sqrtK.mul(2).mul(sqrt(uint(data.answer))).div(sqrt(10 ** p0Decimals)).mul(sqrt(uint(px1))).div(sqrt(10 ** p1Decimals)));
        roundId = data.roundId;
        startedAt = data.startedAt;
        updatedAt = data.updatedAt;
        answeredInRound = data.answeredInRound;
    }

    function latestRoundData()
    external
    view
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return getRoundData(0);
    }

    function getTokenPrice(address token, ChainlinkAggregatorV3Interface tokenSource) private view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound) {
        uint tokenDecimals = uint(EIP20Interface(token).decimals());
        uint lpDecimals = uint(EIP20Interface(pair).decimals());

        RoundData memory data;
        (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound) = tokenSource.latestRoundData();
        require(data.answer > 0, "FylloLPOracle: bad token price");

        answer = int256(uint(data.answer).mul(10 ** lpDecimals).div(10 ** tokenDecimals));
        roundId = data.roundId;
        startedAt = data.startedAt;
        updatedAt = data.updatedAt;
        answeredInRound = data.answeredInRound;
    }

    function setChainlinkSource(address _token0ChanlinkSource, address _token1ChanlinkSource) external onlyOwner {
        if (_token0ChanlinkSource != address(0)) {
            token0Source = ChainlinkAggregatorV3Interface(_token0ChanlinkSource);
            p0Decimals = token0Source.decimals();
            emit ChainlinkSourceChanged(0, _token0ChanlinkSource);
        }

        if (_token1ChanlinkSource != address(0)) {
            token1Source = ChainlinkAggregatorV3Interface(_token1ChanlinkSource);
            p1Decimals = token1Source.decimals();
            emit ChainlinkSourceChanged(1, _token1ChanlinkSource);
        }
    }

    // implementation from https://github.com/Uniswap/uniswap-lib/commit/99f3f28770640ba1bb1ff460ac7c5292fb8291a0
    // original implementation: https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol#L687
    function sqrt(uint x) internal pure returns (uint) {
        if (x == 0) return 0;
        uint xx = x;
        uint r = 1;

        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }

        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }

        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint r1 = x / r;
        return (r < r1 ? r : r1);
    }
}
