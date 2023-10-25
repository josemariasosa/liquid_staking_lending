/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IKETHVault} from "./interfaces/IKETHVault.sol";
import {KSquaredLending} from "./KSquaredLending.sol";

contract KSquaredLendingDepositor {
    using SafeERC20 for IERC20;

    /// @notice keth vault address (the same as keth token address)
    address public kethVault;

    /// @notice k-squared lending contract address
    address public kSquaredLending;

    constructor(address _kethVault, address _kSquaredLending) {
        kethVault = _kethVault;
        kSquaredLending = _kSquaredLending;
    }

    /// @dev Deposit asset into K-Squared Lending pool
    /// @param token The token address
    /// @param amount Amount of token to deposit
    function deposit(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        if (token != kethVault) {
            // underlying token deposit
            amount = IKETHVault(kethVault).deposit(
                token,
                amount,
                address(this),
                false
            );
        }

        IERC20(kethVault).approve(kSquaredLending, amount);
        KSquaredLending(kSquaredLending).depositFor(amount, msg.sender);
    }
}
