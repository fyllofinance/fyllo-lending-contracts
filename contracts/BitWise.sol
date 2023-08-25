pragma solidity ^0.5.16;

contract BitWise {
    function split(uint256 compSpeed) pure public returns(uint256 borrowSpeed, uint256 supplySpeed) {
        borrowSpeed = uint256(uint128(compSpeed));
        supplySpeed = compSpeed >> 128;
    }
    
    function merge(uint256 borrowSpeed, uint256 supplySpeed) pure public returns(uint256 compSpeed) {
        compSpeed = uint256(supplySpeed << 128) + borrowSpeed;
    }
}