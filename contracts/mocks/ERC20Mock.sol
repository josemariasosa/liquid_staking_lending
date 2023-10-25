/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor(
        string memory _name,
        string memory _symbol,
        address _initialSupplyRecipient,
        uint256 _initialAmount
    ) ERC20(_name, _symbol) {
        _mint(_initialSupplyRecipient, _initialAmount);
    }
}
