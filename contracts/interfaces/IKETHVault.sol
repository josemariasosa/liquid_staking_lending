/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IKETHVault {
    function deposit(
        address _underlying,
        uint256 _amount,
        address _recipient,
        bool _sellForDETH
    ) external payable returns (uint256 share);
}
