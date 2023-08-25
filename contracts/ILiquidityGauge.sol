pragma solidity ^0.5.16;

interface ILiquidityGauge {
    function notifySavingsChange(address addr) external;
}
