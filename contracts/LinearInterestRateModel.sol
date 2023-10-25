/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {RAY} from "./helpers/Constants.sol";

/// @title Linear Interest Rate Model
/// @notice Implements calculations required to determine
///         the borrowing interest rate in a borrowing pool,
///         based on liquidit utilization. Interest rate that grows
///         with utilization promotes balancing of supply and demand
///         in the borrowing pool.
contract LinearInterestRateModel is IInterestRateModel {
    /// @dev Interest rate at 0% utilization
    uint256 public immutable baseRateRAY;

    /// @dev Interest rate at function breakpoint
    uint256 public immutable optimalRateRAY;

    /// @dev Interest rate at 100% utilization
    uint256 public immutable maxRateRAY;

    /// @dev Function breakpoint
    /// @notice The slope of the function should increase significantly
    ///         after the breakpoint. This should make borrowing up to
    ///         the breakpoint the optimal strategy, and discourages
    ///         fully draining the pool
    uint256 public immutable breakpointRAY;

    uint256 public immutable maxSlashableAmountPerLivenessUpper;
    uint256 public immutable maxSlashableAmountPerCorruptionUpper;

    /// @param _baseRateRAY Interest rate at 0% utilization, in RAY format
    /// @param _optimalRateRAY Interest rate at breakpoint, in RAY format
    /// @param _maxRateRAY Interest rate at 100% utilizatoin, in RAY format
    /// @param _breakpointRAY Utilization percentage where the function slope increases
    /// @notice Since the function's parameter space is [0%; 100%] and the interest rate function
    ///         is a piecewise linear function of pool utilization, these 4 parameters fully define
    ///         the interest model
    constructor(
        uint256 _baseRateRAY,
        uint256 _optimalRateRAY,
        uint256 _maxRateRAY,
        uint256 _breakpointRAY,
        uint256 _maxSlashableAmountPerLivenessUpper,
        uint256 _maxSlashableAmountPerCorruptionUpper
    ) {
        require(
            _optimalRateRAY >= _baseRateRAY,
            "Base Rate Ray exceeds Optimal Rate Ray"
        );
        require(
            _maxRateRAY >= _optimalRateRAY,
            "Optimal rate Ray exceeds Max Rate Ray"
        );

        baseRateRAY = _baseRateRAY;
        optimalRateRAY = _optimalRateRAY;
        maxRateRAY = _maxRateRAY;
        breakpointRAY = _breakpointRAY;
        maxSlashableAmountPerLivenessUpper = _maxSlashableAmountPerLivenessUpper;
        maxSlashableAmountPerCorruptionUpper = _maxSlashableAmountPerCorruptionUpper;
    }

    /// @dev Returns the current interest rate in RAY format, based on assumed (total) and available liquidity
    /// @param assumedLiquidity Total liquidity in the pool, including available and borrowed funds
    /// @param borrowedLiquidity Liquidity borrowed from the pool
    /// @param maxSlashableAmountPerLiveness Maximum slashable amount per liveness
    /// @param maxSlashableAmountPerCorruption Maximum slashable amount per corruption
    function getInterestRate(
        uint256 assumedLiquidity,
        uint256 borrowedLiquidity,
        uint256 maxSlashableAmountPerLiveness, // 0 - 5
        uint256 maxSlashableAmountPerCorruption // 0 - 1
    ) external view returns (uint256) {
        // If there is no liquidity in the pool, return the base interest rate, in order to
        // prevent sudden interest rate jumps when liquidity is deposited
        if (assumedLiquidity == 0) {
            return baseRateRAY;
        }

        // Pool utilization in the range [0; 1], computed in RAY format
        uint256 utilizationRAY = (RAY * borrowedLiquidity) / assumedLiquidity;

        if (utilizationRAY < breakpointRAY) {
            // Before the breakpoint, we're on the first part of the piecewise function;
            // Interest rate is computed as 'baseRate + R1 * utilization / optimalUtilization', where
            // optimalRate = baseRate + R1
            utilizationRAY =
                baseRateRAY +
                ((optimalRateRAY - baseRateRAY) * utilizationRAY) /
                breakpointRAY;
        } else {
            // After the breakpoint, we're on the second part of the piecewise function;
            // Interest rate is computed as optimalRate + R2 * (utilization - optimalUtilization) / (1 - optimalUtilization),
            // where maxRate = optimalRate + R2
            utilizationRAY =
                optimalRateRAY +
                ((maxRateRAY - optimalRateRAY) *
                    (utilizationRAY - breakpointRAY)) /
                (RAY - breakpointRAY);
        }

        return
            utilizationRAY +
            (utilizationRAY * maxSlashableAmountPerLiveness) /
            maxSlashableAmountPerLivenessUpper +
            (utilizationRAY * maxSlashableAmountPerCorruption) /
            maxSlashableAmountPerCorruptionUpper;
    }
}
