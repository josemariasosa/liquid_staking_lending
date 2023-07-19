/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @dev Struct containing information on a particular lender address
struct LenderPosition {
    uint256 cumulativeKethPerShareLU_RAY;
    uint256 kethEarned;
}

/// @dev Struct containing information on a particular debtor address
struct DebtPosition {
    address debtor;
    address designatedVerifier;
    uint256 principalAmount;
    uint256 interestPerSec_RAY;
    uint256 endTimestamp;
    uint256 slashAmount;
    uint256 maxSlashableAmountPerLiveness;
    uint256 maxSlashableAmountPerCorruption;
}

interface IBorrowingPoolEvents {
    /// @dev Emitted when KETH is deposited to the pool
    event KETHDeposited(address indexed depositor, uint256 amount);

    /// @dev Emitted when KETH is withdrawn from the pool
    event KETHWithdrawn(address indexed depositor, uint256 amount);

    /// @dev Emitted when KETH rewards are claimed for a depositor
    event KETHClaimed(address indexed depositor, uint256 amount);

    /// @dev Emitted when the strategy borrows ETH for a wallet
    event Borrowed(address indexed borrower, uint256 amount);

    /// @dev Emitted when a slash happens
    event Slashed(address debtor, uint256 amount, address recipient);
}

interface IBorrowingPool is IBorrowingPoolEvents {
    function borrow(
        address designatedVerifier,
        uint256 amount,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    ) external;

    function getExpectedInterest(
        uint256 principalAmount,
        uint256 duration,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    ) external view returns (uint256);

    function getDebtor(
        address debtor
    ) external view returns (DebtPosition memory);

    function getLender(
        address lender
    ) external view returns (LenderPosition memory);
}
