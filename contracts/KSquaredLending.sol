/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IBorrowingPool, DebtPosition, LenderPosition} from "./interfaces/IBorrowingPool.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {RAY, SECONDS_PER_YEAR} from "./helpers/Constants.sol";
import {ReporterRegistry} from "./ReporterRegistry.sol";

contract KSquaredLending is AccessControl, ERC20, IBorrowingPool {
    using SafeERC20 for IERC20;

    /// @dev Identifier for the Strategy role
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    /// @dev Identifier for the Reporter role
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    /// @dev Identifier for the Configurator (owner) role
    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");

    /// @dev KETH token address
    address public immutable keth;

    /// @dev Borrow duration
    uint256 public immutable borrowDuration;

    /// @dev DAO address
    address public daoAddress;

    /// @dev Address of the interest rate model
    address public interestRateModel;

    /// @dev Amount of KETH liquidity that was not yet spent to acquire KETH
    uint256 public assumedLiquidity;

    /// @dev Amount of KETH liquidity currently borrowed from the pool
    uint256 public borrowedLiquidity;

    /// @dev Amount of KETH per single pool share, multiplied by RAY
    uint256 public currentCumulativeKethPerShare_RAY;

    /// @dev The latest recorded interest rate, in RAY format
    uint256 public interestPerSecLU_RAY;

    /// @dev Timestamp of the latest interest index update
    uint256 public timestampLU;

    /// @dev Minimal size of deposit
    uint256 public minDepositLimit = 1 ether / 10;

    /// @dev Map from lender address to their data
    mapping(address => LenderPosition) public lenders;

    /// @dev Debt positions array
    mapping(uint256 => DebtPosition) public debtPositions;

    /// @dev Debt position start index
    uint256 private debtPositionStart;
    
    /// @dev Debt position end index
    uint256 private debtPositionEnd;

    /// @dev Map from debtor address the their data
    mapping(address => uint256) public debtors;

    /// @dev Maximum borrow ratio
    uint256 public maxBorrowRatio_RAY;

    /// @dev Maximum slashable ratio
    uint256 public maxSlashableRatio_RAY;

    /// @param _keth Address of the KETH token
    /// @param _daoAddress Dao address
    /// @param _interestRateModel Address of the interest rate model
    /// @param _name Name of the pool's share ERC20
    /// @param _symbol Symbol of the pool's share ERC20
    /// @param _maxBorrowRatio_RAY Maximum borrow ratio
    /// @param _maxSlashableRatio_RAY Maximum slashable raio
    constructor(
        address _keth,
        address _daoAddress,
        address _interestRateModel,
        string memory _name,
        string memory _symbol,
        uint256 _maxBorrowRatio_RAY,
        uint256 _maxSlashableRatio_RAY
    ) ERC20(_name, _symbol) {
        require(_keth != address(0));

        keth = _keth; // F: [CSBP-1]
        daoAddress = _daoAddress;
        interestRateModel = _interestRateModel; // F: [CSBP-1]

        interestPerSecLU_RAY = 0; // F: [CSBP-1]
        timestampLU = block.timestamp; // F: [CSBP-1]

        _grantRole(CONFIGURATOR_ROLE, msg.sender); // F: [CSBP-1]
        _setRoleAdmin(STRATEGY_ROLE, CONFIGURATOR_ROLE); // F: [CSBP-1]
        _setRoleAdmin(REPORTER_ROLE, CONFIGURATOR_ROLE); // F: [CSBP-1]

        borrowDuration = 180 days;
        debtPositionStart = 1;
        debtPositionEnd = 1;
        maxBorrowRatio_RAY = _maxBorrowRatio_RAY;
        maxSlashableRatio_RAY = _maxSlashableRatio_RAY;
    }

    // MODIFIERS
    // -------------------------

    /// @dev Updates the current cumulative interest index
    ///      before executing the function the function
    /// @notice Must be called before all functions that modify
    ///         assumed or available liquidity, since the borrow
    ///         rate will change afterwards
    modifier withInterestUpdate() {
        _updateInterest();
        _;
    }

    /// @dev Updates the accrued rewards amount and cumulative reward per token
    ///      for a lender before executing the function
    /// @notice Must be called before all functions that modify the
    ///         lender's share balance
    modifier withLenderUpdate(address lender) {
        _updateLenderPosition(lender);
        _;
    }

    // LP DEPOSITS & WITHDRAWALS
    // -------------------------

    /// @dev Deposits KETH into the pool and mints pool shares to sender
    /// @notice Modifies both the lender's balance and the interest rate,
    ///         so index and lender's cumulative reward per token have
    ///         to be updated
    function deposit(uint256 amount) external {
        depositFor(amount, msg.sender);
    }

    /// @dev Deposits KETH into the pool and mints pool shares to sender
    /// @notice Modifies both the lender's balance and the interest rate,
    ///         so index and lender's cumulative reward per token have
    ///         to be updated
    function depositFor(
        uint256 amount,
        address recipient
    )
        public
        withInterestUpdate // F: [CSBP-14]
        withLenderUpdate(recipient) // F: [CSBP-15]
    {
        require(
            amount >= minDepositLimit,
            "BorrowingPool: Attempting to deposit less than the minimal deposit amount"
        ); // F: [CSBP-2]
        IERC20(keth).safeTransferFrom(msg.sender, address(this), amount); // F: [CSBP-6]

        // In theory, a scenario may be reached when assumedLiquidity == 0
        // but there are outstanding shares (i.e. when the entire pool was
        // borrowed and then repaid, without any new deposits). In this
        // case, new deposits are impossible due to division by zero. Therefore,
        // a minimal assumed liquidity amount has to be established. The depositor
        // will lose an amount to existing shareholders, but it will be negligible.

        uint256 assumedLiquidityAdj = assumedLiquidity < 1e12
            ? 1e12 // F: [CSBP-4A]
            : assumedLiquidity;

        uint256 shares = totalSupply() == 0
            ? amount // F: [CSBP-3]
            : (amount * totalSupply()) / assumedLiquidityAdj; // F: [CSBP-4]

        assumedLiquidity += amount; // F: [CSBP-3,4]

        _mint(recipient, shares); // F: [CSBP-3,4]
        emit KETHDeposited(recipient, amount); // F: [CSBP-3,4]
    }

    /// @dev Burns shares from the sender and return the equivalent fraction
    ///      of remaining KETH liquidity. Optionally, sends all KETH accrued
    ///      by the lender.
    /// @param shares The amount of shares to burn
    /// @param claim Whether to claim accrued KETH
    /// @notice Modifies both the lender's balance and the interest rate,
    ///         so index and lender's cumulative reward per token have
    ///         to be updated
    function withdraw(
        uint256 shares,
        bool claim
    )
        external
        withInterestUpdate // F: [CSBP-14]
        withLenderUpdate(msg.sender) // F: [CSBP-15]
    {
        uint256 amount = (shares * assumedLiquidity) / totalSupply(); // F: [CSBP-8]

        _burn(msg.sender, shares); // F: [CSBP-8]

        assumedLiquidity -= amount; // F: [CSBP-8]

        if (claim) {
            _claimKETH(msg.sender); // F: [CSBP-8]
        }

        IERC20(keth).safeTransfer(msg.sender, amount);
        emit KETHWithdrawn(msg.sender, amount); // F: [CSBP-8]
    }

    /// @dev Claims all of the accrued KETH for the lender
    ///      and sends it to the lender's address
    /// @param lender Lender to claim for
    /// @notice While this doesn't modify the lender balance,
    ///         the position is updated to record
    ///         the latest reward amount beforehand
    function claimKETH(
        address lender
    )
        external
        withInterestUpdate // F: [CSBP-14]
        withLenderUpdate(lender) // F: [CSBP-15]
        returns (uint256)
    {
        return _claimKETH(lender);
    }

    /// @dev Claims all of the accrued KETH for msg.sender
    ///      and sends it to the msg.sender's address
    /// @notice While this doesn't modify the sender's balance,
    ///         the position is updated to record
    ///         the latest reward amount beforehand
    function claimKETH()
        external
        withInterestUpdate // F: [CSBP-14]
        withLenderUpdate(msg.sender) // F: [CSBP-15]
        returns (uint256)
    {
        return _claimKETH(msg.sender);
    }

    /// @dev IMPLEMENTATION: claimKETH
    /// @param lender The address to claim for
    function _claimKETH(address lender) internal returns (uint256 amount) {
        amount = lenders[lender].kethEarned;
        lenders[lender].kethEarned = 0;

        IERC20(keth).safeTransfer(lender, amount);
        emit KETHClaimed(lender, amount);
    }

    /// @dev Slash KETH from the pool
    /// @param slashType the slash type (liveness & corruption)
    /// @param debtor the debtor address
    /// @param amount the slash amount
    /// @param recipient the recipient address
    function slash(
        ReporterRegistry.SlashType slashType,
        address debtor,
        uint256 amount,
        address recipient
    )
        external
        onlyRole(REPORTER_ROLE) // F: [CSBP-13]
    {
        require(assumedLiquidity > amount, "not enough liquidity to slash");

        uint256 debtIndex = debtors[debtor];
        DebtPosition storage position = debtPositions[debtIndex];
        if (slashType == ReporterRegistry.SlashType.Liveness) {
            require(
                amount < position.maxSlashableAmountPerLiveness,
                "exceed maximum slashable amount per livenss"
            );
        }
        if (slashType == ReporterRegistry.SlashType.Corruption) {
            require(
                amount < position.maxSlashableAmountPerCorruption,
                "exceed maximum slashable amount per corruption"
            );
        }

        uint256 outstandingInterest = (position.endTimestamp > block.timestamp)
            ? (position.interestPerSec_RAY *
                (position.endTimestamp - block.timestamp)) / RAY
            : 0;
        if (
            (outstandingInterest * maxSlashableRatio_RAY) / RAY <
            position.slashAmount + amount
        ) {
            // distribute outstandintInterest to lenders
            assumedLiquidity += outstandingInterest;

            // liquidate position
            borrowedLiquidity -= position.principalAmount;
            interestPerSecLU_RAY -= position.interestPerSec_RAY;
            delete debtors[debtor];
            delete debtPositions[debtIndex];
        }

        unchecked {
            position.slashAmount += amount;
            assumedLiquidity -= amount;
        }

        uint256 halfAmount = amount / 2;
        /// transfer 50% to recipient
        IERC20(keth).safeTransfer(recipient, halfAmount);
        /// transfer 50% to dao address
        IERC20(keth).safeTransfer(daoAddress, amount - halfAmount);

        emit Slashed(debtor, amount, recipient);
    }

    /// @dev Terminate debt position
    /// @param debtor the debtor address
    function terminate(address debtor) external {
        uint256 debtIndex = debtors[debtor];
        DebtPosition storage position = debtPositions[debtIndex];
        uint256 outstandingInterest = (position.endTimestamp > block.timestamp)
            ? (position.interestPerSec_RAY *
                (position.endTimestamp - block.timestamp)) / RAY
            : 0;
        uint256 maxSlashableAmount = (outstandingInterest *
            maxSlashableRatio_RAY) / RAY;

        require(assumedLiquidity <= maxSlashableAmount);

        // transfer outstanding interest back to the debtor
        IERC20(keth).safeTransfer(debtor, outstandingInterest);

        // close position
        borrowedLiquidity -= position.principalAmount;
        interestPerSecLU_RAY -= position.interestPerSec_RAY;
        delete debtors[debtor];
        delete debtPositions[debtIndex];
    }

    /// @dev Top up slash amount
    /// @param amount the amount
    function topUpSlashAmount(uint256 amount) external {
        IERC20(keth).safeTransferFrom(msg.sender, address(this), amount);

        address debtor = msg.sender;
        DebtPosition storage position = debtPositions[debtors[debtor]];
        require(position.slashAmount >= amount, "more than slashed amount");

        unchecked {
            position.slashAmount -= amount;
            assumedLiquidity += amount;
        }
    }

    // IBorrowingPool
    // --------------

    /// @dev Borrows KETH from the pool and records the debt to
    ///      the debtor's address
    /// @param designatedVerifier The designated verifier of debtor
    /// @param amount The debt principal to borrow
    /// @param maxSlashableAmountPerLiveness Maximum slashable amount per liveness
    /// @param maxSlashableAmountPerCorruption Maximum slashable amount per corruption
    /// @notice Can only be called by the strategy, since the pool
    ///         itself does not enforce repayment and only strategy
    ///         can do that. As such, the debt will be
    ///         recorded to the address of the strategy.
    /// @notice This function changes the available liquidity,
    ///         so the index has to update beforehand. Also, the
    ///         cumulative index at debt opening is recorded,
    ///         so the index must be up to date, to correctly
    ///         compute interest for the debtor
    function borrow(
        address designatedVerifier,
        uint256 amount,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    )
        external
        withInterestUpdate // F: [CSBP-14]
    {
        address debtor = msg.sender;
        // A single debtor can only have one debt position,
        // since the pool also does not take additional debt
        // for a debtor before finishing the full lifecycle
        // and repaying the debt
        require(
            debtors[debtor] == 0,
            "BorrowingPool Borrow: Debtor has outstanding debt"
        );

        _borrow(
            debtor,
            designatedVerifier,
            amount,
            0,
            maxSlashableAmountPerLiveness,
            maxSlashableAmountPerCorruption
        );
    }

    /// @dev IMPLEMENTATION: increase debt
    /// @param designatedVerifier The designated verifier of debtor
    /// @param amount The debt principal to borrow
    /// @param maxSlashableAmountPerLiveness Maximum slashable amount per liveness
    /// @param maxSlashableAmountPerCorruption Maximum slashable amount per corruption
    function increaseDebt(
        address designatedVerifier,
        uint256 amount,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    )
        external
        withInterestUpdate // F: [CSBP-14]
    {
        address debtor = msg.sender;
        uint256 index = debtors[debtor];
        require(
            index != 0,
            "BorrowingPool Borrow: Debtor has outstanding debt"
        );
        DebtPosition memory position = debtPositions[index];
        require(position.slashAmount == 0, "Top up slash amount first");
        require(
            maxSlashableAmountPerLiveness >=
                position.maxSlashableAmountPerLiveness,
            "invalid maximum slashable amount per liveness"
        );
        require(
            maxSlashableAmountPerCorruption >=
                position.maxSlashableAmountPerCorruption,
            "invalid maximum slashable amount per corruption"
        );

        uint256 outstandingInterest = (position.endTimestamp > block.timestamp)
            ? (position.interestPerSec_RAY *
                (position.endTimestamp - block.timestamp)) / RAY
            : 0;

        uint256 newBorrow = position.principalAmount + amount;

        borrowedLiquidity -= position.principalAmount;
        interestPerSecLU_RAY -= position.interestPerSec_RAY;
        delete debtPositions[index];
        delete debtors[debtor];

        _borrow(
            debtor,
            designatedVerifier,
            newBorrow,
            outstandingInterest,
            maxSlashableAmountPerLiveness,
            maxSlashableAmountPerCorruption
        );
    }

    /// @dev IMPLEMENTATION: borrow
    /// @param debtor The debtor address
    /// @param designatedVerifier The designated verifier of debtor
    /// @param amount The debt principal to borrow
    /// @param outstandingInterest The outstanding interest
    /// @param maxSlashableAmountPerLiveness Maximum slashable amount per liveness
    /// @param maxSlashableAmountPerCorruption Maximum slashable amount per corruption
    function _borrow(
        address debtor,
        address designatedVerifier,
        uint256 amount,
        uint256 outstandingInterest,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    ) internal {
        uint256 totalBorrowableAmount = (assumedLiquidity *
            maxBorrowRatio_RAY) / RAY;
        require(
            totalBorrowableAmount >= borrowedLiquidity + amount,
            "exceed maximum borrow ratio"
        );

        // take upfront interest
        uint256 interestPerSec_RAY = (amount *
            _getInterestRate(
                totalBorrowableAmount,
                borrowedLiquidity + amount,
                maxSlashableAmountPerLiveness,
                maxSlashableAmountPerCorruption
            )) / (SECONDS_PER_YEAR);

        uint256 interestAmount = (interestPerSec_RAY * borrowDuration) / RAY;
        if (interestAmount > outstandingInterest) {
            IERC20(keth).safeTransferFrom(
                msg.sender,
                address(this),
                interestAmount - outstandingInterest
            );
        } else {
            // adjust interestPerSec when outstanding interest is more than new debt interest
            interestPerSec_RAY = (outstandingInterest * RAY) / borrowDuration;
        }

        // add debt position
        debtPositions[debtPositionEnd] = DebtPosition({
            debtor: debtor,
            designatedVerifier: designatedVerifier,
            principalAmount: amount,
            slashAmount: 0,
            interestPerSec_RAY: interestPerSec_RAY,
            endTimestamp: block.timestamp + borrowDuration,
            maxSlashableAmountPerLiveness: maxSlashableAmountPerLiveness,
            maxSlashableAmountPerCorruption: maxSlashableAmountPerCorruption
        });
        debtors[debtor] = debtPositionEnd;
        debtPositionEnd++;

        /// Requirement above ensures the underflow protection
        unchecked {
            borrowedLiquidity += amount; // F: [CSBP-5]
            interestPerSecLU_RAY += interestPerSec_RAY;
        }

        emit Borrowed(debtor, amount); // F: [CSBP-5]
    }

    /// @dev Returns the expected interest accrued over a duration,
    ///      assuming interest rate doesn't change after the initial borrow
    /// @param principalAmount The debt principal to compute
    ///                        interest for
    /// @param duration Expected duration of a debt position
    /// @param maxSlashableAmountPerLiveness Maximum slashable amount per liveness
    /// @param maxSlashableAmountPerCorruption Maximum slashable amount per corruption
    /// @return Expected interest amount in KETH
    function getExpectedInterest(
        uint256 principalAmount,
        uint256 duration,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    ) external view returns (uint256) {
        uint256 totalBorrowableAmount = (assumedLiquidity *
            maxBorrowRatio_RAY) / RAY;
        return
            (principalAmount *
                _getInterestRate(
                    totalBorrowableAmount,
                    borrowedLiquidity + principalAmount,
                    maxSlashableAmountPerLiveness,
                    maxSlashableAmountPerCorruption
                ) *
                duration) / (SECONDS_PER_YEAR * RAY); // F: [CSBP-17]
    }

    /// @dev Returns data for a particular debtor
    /// @param debtor Address to return the struct for
    function getDebtor(
        address debtor
    ) external view returns (DebtPosition memory) {
        return debtPositions[debtors[debtor]];
    }

    /// @dev Returns data for a particular debtor
    /// @param debtor Address to return the struct for
    function getDesignatedVerifier(
        address debtor
    ) external view returns (address) {
        return debtPositions[debtors[debtor]].designatedVerifier;
    }

    /// @dev Returns data for a particular lender
    /// @param lender Address to return the struct for
    function getLender(
        address lender
    ) external view returns (LenderPosition memory) {
        return lenders[lender];
    }

    // ERC20
    // ------------------

    /// @dev Transfers pool shares to another address
    /// @param to Address to transfer shares to
    /// @param amount Amount of shares to transfer
    /// @notice This function modifies the sender's
    ///         and the recipient's share balances,
    ///         so positions of both must be updated
    function transfer(
        address to,
        uint256 amount
    )
        public
        override
        withLenderUpdate(msg.sender) // F: [CSBP-15]
        withLenderUpdate(to) // F: [CSBP-15]
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @dev Transfers pool shares from one address to another
    /// @param from Address to transfer shares from
    /// @param to Address to transfer shares to
    /// @param amount Amount of shares to transfer
    /// @notice This function modifies the sender's
    ///         and the recipient's share balances,
    ///         so positions of both must be updated
    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        override
        withLenderUpdate(from) // F: [CSBP-15]
        withLenderUpdate(to) // F: [CSBP-15]
        returns (bool)
    {
        if (from != msg.sender) {
            _spendAllowance(from, msg.sender, amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    // Yield calculations
    // ------------------

    /// @dev Retrieves the current interest rate from the model,
    ///      based on assumed (total) and available liquidity
    /// @param _borrowableLiquidity Borrowable liquidity to compute interest rate
    /// @param _borrowedLiquidity Borrowed liquidity to compute interest rate
    function _getInterestRate(
        uint256 _borrowableLiquidity,
        uint256 _borrowedLiquidity,
        uint256 maxSlashableAmountPerLiveness,
        uint256 maxSlashableAmountPerCorruption
    ) internal view returns (uint256) {
        return
            IInterestRateModel(interestRateModel).getInterestRate(
                _borrowableLiquidity,
                _borrowedLiquidity,
                maxSlashableAmountPerLiveness,
                maxSlashableAmountPerCorruption
            );
    }

    /// @dev Sets the recorded index value to the most current index
    ///      and updates the timestamp.
    /// @notice This must always be done immediately before a
    ///         change in interest rate, as otherwise the new
    ///         interest rate will be erroneously applied to the
    ///         entire period since last update
    function _updateInterest() internal {
        uint256 newRewards;
        DebtPosition memory position;
        for (; debtPositionStart < debtPositionEnd; debtPositionStart++) {
            position = debtPositions[debtPositionStart];
            if (position.endTimestamp == 0) {
                // already closed position
                continue;
            }

            if (position.endTimestamp > block.timestamp) {
                newRewards +=
                    (interestPerSecLU_RAY * (block.timestamp - timestampLU)) /
                    RAY;
                timestampLU = block.timestamp;
                break;
            } else {
                newRewards +=
                    (interestPerSecLU_RAY *
                        (position.endTimestamp - timestampLU)) /
                    RAY;
                timestampLU = position.endTimestamp;

                borrowedLiquidity -= position.principalAmount;
                interestPerSecLU_RAY -= position.interestPerSec_RAY;
                delete debtors[position.debtor];
                delete debtPositions[debtPositionStart];
            }
        }

        currentCumulativeKethPerShare_RAY += newRewards / totalSupply();
    }

    /// @dev Updates the KETH amount pending to the lender, and their
    ///      last recorded cumulative reward per share.
    /// @notice This must always be done immediately before a change in
    ///         lender's balance, as otherwise the old cumulative rewards
    ///         diff will be erroneously applied to the new balance
    function _updateLenderPosition(address lender) internal {
        uint256 newReward = ((currentCumulativeKethPerShare_RAY -
            lenders[lender].cumulativeKethPerShareLU_RAY) * balanceOf(lender)) /
            RAY;

        lenders[lender]
            .cumulativeKethPerShareLU_RAY = currentCumulativeKethPerShare_RAY;
        lenders[lender].kethEarned += newReward;
    }

    // Configuration
    // ------------------

    /// @dev Sets a new DAO address
    /// @notice Restricted to configurator only
    function setDaoAddress(
        address newDaoAddress
    ) external onlyRole(CONFIGURATOR_ROLE) {
        daoAddress = newDaoAddress;
    }

    /// @dev Sets a new interest rate calculator
    /// @notice Restricted to configurator only
    function setNewInterestRateModel(
        address newInterestRateModel
    )
        external
        onlyRole(CONFIGURATOR_ROLE) // F: [CSBP-9]
    {
        interestRateModel = newInterestRateModel; // F: [CSBP-9]
    }

    /// @dev Sets a new deposit limit
    /// @notice Restricted to configurator only
    function setMinDepositLimit(
        uint256 newMinDepositLimit
    )
        external
        onlyRole(CONFIGURATOR_ROLE) // F: [CSBP-10]
    {
        minDepositLimit = newMinDepositLimit; // F: [CSBP-10]
    }

    /// @dev Transfers the configurator role to another address
    /// @notice Restricted to configurator only.
    /// @notice Caution! The action is irreversible and can lead to loss
    ///         of control if the new address is wrong.
    function setConfigurator(
        address newConfigurator
    )
        external
        onlyRole(CONFIGURATOR_ROLE) // F: [CSBP-11]
    {
        _grantRole(CONFIGURATOR_ROLE, newConfigurator); // F: [CSBP-11]
        _revokeRole(CONFIGURATOR_ROLE, msg.sender); // F: [CSBP-11]
    }
}
