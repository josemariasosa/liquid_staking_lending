// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KSquaredLending} from "contracts/KSquaredLending.sol";
import {BaseSetUp} from "./BaseSetUp.t.sol";

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
            // string memory _name,
            // string memory _symbol,
            // uint256 _maxBorrowRatio_RAY,
            // uint256 _maxSlashableRatio_RAY
        );
    }

    // function test_NumberIs42() public {
    //     assertEq(testNumber, 42);
    // }

    // function testFail_Subtract43() public {
    //     testNumber -= 43;
    // }
}