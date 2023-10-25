// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KSquaredLending} from "contracts/KSquaredLending.sol";
import {BaseSetUp} from "./BaseSetUp.t.sol";

import "forge-std/console.sol";

contract K2LendingTest is BaseSetUp {
    
    KSquaredLending public k2Lending;

    function setUp() public override {
        BaseSetUp.setUp();

        vm.prank(alice);
        k2Lending = new KSquaredLending(
            // address _keth,
            address(kethToken),
            // address _daoAddress,
            dao,
            // address _interestRateModel,
            address(interestRateModel),
            // string memory _name,
            // string memory _symbol,
            "K2 Lending", "K2L",
            // uint256 _maxBorrowRatio_RAY,
            // uint256 _maxSlashableRatio_RAY
            30, 50
        );
        console.logString("HOLA DESDE ACA");
    }

    function test_NumberIs42() public {
        assertEq(42 == 42, true);
    }

    function testFail_Subtract43() public pure {
        uint x = 42;
        x -= 43;
    }
}