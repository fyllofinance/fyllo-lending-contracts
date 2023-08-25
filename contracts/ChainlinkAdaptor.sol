pragma solidity ^0.5.16;

import "./compound/SafeMath.sol";
import "./compound/PriceOracle.sol";
import "./compound/CErc20.sol";
import "./ChainlinkAggregatorV3Interface.sol";
import "./FToken.sol";

contract ChainlinkAdaptor is PriceOracle {
    using SafeMath for uint256;

    address public governance;

    mapping(address => ChainlinkAggregatorV3Interface) public assetsPriceSources;
    ChainlinkAggregatorV3Interface public nativeTokenPriceSource;

    PriceOracle public fallbackPriceOracle;

    event AssetPriceSourceUpdated(address indexed asset, address indexed source);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    modifier onlyGovernance {
        require(msg.sender == governance, "Governance required.");
        _;
    }

    constructor(address _nativeTokenPriceSource) public {
        governance = msg.sender;
        nativeTokenPriceSource = ChainlinkAggregatorV3Interface(_nativeTokenPriceSource);
    }

    function getUnderlyingPrice(CToken cToken) external view returns (uint) {
        if (FToken(address(cToken)).isNativeToken()) {
            return 1e18;
        }

        address asset = address(CErc20(address(cToken)).underlying());
        ChainlinkAggregatorV3Interface priceSource = assetsPriceSources[asset];

        if (address(priceSource) == address(0x0)) {
            return getUnderlyingPriceFromFallback(cToken);
        }

        uint256 priceFromChainlink = getUnderlyingPriceFromChainlink(priceSource, cToken);
        if (priceFromChainlink == 0) {
            return getUnderlyingPriceFromFallback(cToken);
        }
        return priceFromChainlink;
    }

    function getUnderlyingPriceFromFallback(CToken cToken) public view returns (uint) {
        if (address(fallbackPriceOracle) != address(0x0)) {
            return fallbackPriceOracle.getUnderlyingPrice(cToken);
        }
        return 0;
    }

    function getUnderlyingPriceFromChainlink(ChainlinkAggregatorV3Interface chainlinkPriceSource, CToken cToken) view internal returns(uint256) {
        uint256 assetPriceDecimals = chainlinkPriceSource.decimals();
        address asset = address(CErc20(address(cToken)).underlying());

        uint256 assetDecimals = CErc20(address(asset)).decimals();
        uint256 assetPriceInUsd = getPrice(chainlinkPriceSource);

        uint256 nativeTokenPriceDecimals = nativeTokenPriceSource.decimals();
        uint256 nativeTokenPriceInUsd = getPrice(nativeTokenPriceSource);

        if (assetPriceInUsd == 0 || nativeTokenPriceInUsd == 0) {
            return 0;
        }
        if (assetPriceDecimals == nativeTokenPriceDecimals) {
            return assetPriceInUsd.mul(10 ** 18).mul(10 ** 18).div(nativeTokenPriceInUsd.mul(10 ** assetDecimals));
        } else {
            return assetPriceInUsd.mul(10 ** 18).mul(10 ** nativeTokenPriceDecimals).mul(10 ** 18).div(nativeTokenPriceInUsd.mul(10 ** assetDecimals).mul(10 ** assetPriceDecimals));
        }
    }

    function preCheckPrice(ChainlinkAggregatorV3Interface chainlinkPriceSource, CToken cToken) view external returns(uint256 priceFromChainlink, uint256 priceFromFallback) {
        (priceFromChainlink, priceFromFallback) = (getUnderlyingPriceFromChainlink(chainlinkPriceSource, cToken), getUnderlyingPriceFromFallback(cToken));
    }

    function getSourcePrice(address asset) view public returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        return assetsPriceSources[asset].latestRoundData();
    }

    function getPrice(ChainlinkAggregatorV3Interface priceSource) public view returns (uint256) {
        (,int256 answer,,,) = priceSource.latestRoundData();
        if (answer > 0) {
            return uint256(answer);
        } else {
            return 0;
        }
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external onlyGovernance {
        _setAssetsSources(assets, sources);
    }

    function setFallbackPriceOracle(address _fallbackPriceOracle) external onlyGovernance {
        fallbackPriceOracle = PriceOracle(_fallbackPriceOracle);
    }

    function _setAssetsSources(address[] memory assets, address[] memory sources) internal {
        require(assets.length == sources.length, 'Inconsistent parameter length');
        for (uint256 i = 0; i < assets.length; i++) {
            assetsPriceSources[assets[i]] = ChainlinkAggregatorV3Interface(sources[i]);
            emit AssetPriceSourceUpdated(assets[i], sources[i]);
        }
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "New governance is zero address");
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }
}