/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IInterestRateModel {
    function getInterestRate(
        uint256 assumedLiquidity,
        uint256 availableLiquidity,
        uint256 maxSlashableAmountPerLiveness, // 0 - 5
        uint256 maxSlashableAmountPerCorruption // 0 - 1`
    ) external view returns (uint256);
}
