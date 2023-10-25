// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {ERC20Mock} from "contracts/mocks/ERC20Mock.sol";
import {LinearInterestRateModel} from "contracts/LinearInterestRateModel.sol";

contract BaseSetUp is Test {

    ERC20Mock internal kethToken;
    LinearInterestRateModel internal interestRateModel;

    address internal alice;
    address internal bob;
    address internal dao;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        dao = makeAddr("dao");

        kethToken = new ERC20Mock("KETH", "K2 ETH test token", alice, 100 ether);
        interestRateModel = new LinearInterestRateModel(
            // uint256 _baseRateRAY,
            10,
            // uint256 _optimalRateRAY,
            21,
            // uint256 _maxRateRAY,
            30,
            // uint256 _breakpointRAY,
            28,
            // uint256 _maxSlashableAmountPerLivenessUpper,
            100,
            // uint256 _maxSlashableAmountPerCorruptionUpper
            100
        );
    }
}