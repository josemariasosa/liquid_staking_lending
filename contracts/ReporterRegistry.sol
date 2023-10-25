/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {KSquaredLending} from "./KSquaredLending.sol";

contract ReporterRegistry is Ownable, EIP712, ReentrancyGuard {
    /// @notice Event signaling new reporter registration
    /// @param reporter - reporter ECDSA address
    event ReporterRegistered(address reporter);

    /// @notice Event reporter designated verifier updated
    /// @param designatedVerifier - designated verifier
    event DesignatedVerifierUpdated(address designatedVerifier);

    /// @notice Event signaling reporter ragequitting
    /// @param reporter - ECDSA address of the reporter
    event ReporterRagequitted(address reporter);

    /// @notice Report Submission
    event ReportSubmitted(address reporter, address debtor, uint256 amount);

    /// @notice Penalty type enumeration
    enum SlashType {
        Liveness,
        Corruption
    }

    /// @notice Standard Elliptic Curve ECDSA signature
    struct SignatureECDSA {
        uint8 v; /// version
        bytes32 r; /// x coordinate of the curve
        bytes32 s; /// y coordinate of the curve
    }

    /// @notice Structure representing he report
    struct Report {
        SlashType slashType;
        address debtor; // Borrower address
        uint256 amount; // Amount being slashed
        uint256 identifier; // Unique ID to avoid double reporting
        uint256 block; // Block number
        bytes signature; // Blind signature being reported
    }

    /// @notice EIP712-compliant typehash
    bytes32 public constant REPORT_TYPEHASH =
        keccak256(
            "Report(uint8 slashType,address debtor,uint256 amount,uint256 identifier,uint256 block,bytes signature)"
        );

    /// @notice The K-Squared Lending pool
    address public kSquaredLendingPool;

    /// @notice mapping to the reporter registration status
    mapping(address => bool) public isReporterActive;

    /// @notice mapping about the reporter resignations
    mapping(address => bool) public isReporterRagequitted;

    /// @notice Used to prevent double-reporting
    mapping(uint256 => bool) public isReportUsed;

    constructor(
        address _kSquaredLendingPool,
        string memory _eip712Name,
        string memory _eip712VersionName
    )
        Ownable(msg.sender)
        EIP712(_eip712Name, _eip712VersionName)
    {
        kSquaredLendingPool = _kSquaredLendingPool;
    }

    /// @notice Function to register the reporter
    function registerReporter() external {
        address reporter = msg.sender;

        require(!isReporterActive[reporter], "Reporter already registered");
        // In conclusion, for security considerations, it is not recommended to directly
        // use the return value of Address.isContract() to determine whether a caller is
        // a contract or not. require(msg.sender == tx.orign) works now and is a better practice.
        // require(!Address.isContract(reporter), "Contracts cannot be reporters");
        require(msg.sender == tx.origin, "Contracts cannot be reporters");

        isReporterActive[reporter] = true;

        emit ReporterRegistered(reporter);
    }

    /// @notice Function to ragequit the reporter
    function ragequitReporter() external {
        address reporter = msg.sender;

        require(isReporterOperational(reporter), "Reporter not operational");

        /// Setting the reporter as retired
        isReporterRagequitted[reporter] = true;

        emit ReporterRagequitted(msg.sender);
    }

    /// @notice function to make sure the reporter is operational and can perform reports
    /// @param _reporter - ECDSA address of the reporter
    function isReporterOperational(
        address _reporter
    ) public view returns (bool) {
        return isReporterActive[_reporter] && !isReporterRagequitted[_reporter];
    }

    /// @notice Function to submit the report about the proposer
    /// @param _report - Report structure signed by the service
    /// @param _reportSignature - Signature certifying the report
    function submitReport(
        Report calldata _report,
        SignatureECDSA calldata _reportSignature
    ) external nonReentrant {
        address reporter = msg.sender;
        require(isReporterOperational(reporter), "Reporter non-operational");

        require(
            _verifyReport(_reportSignature, _report),
            "Report signature invalid"
        );

        KSquaredLending(kSquaredLendingPool).slash(
            _report.slashType,
            _report.debtor,
            _report.amount,
            reporter
        );

        emit ReportSubmitted(reporter, _report.debtor, _report.amount);
    }

    /// @notice Internal function to verify report validity
    /// @param _signature - ECDSA signature validating the report
    /// @param _report - Proposer report
    function _verifyReport(
        SignatureECDSA calldata _signature,
        Report calldata _report
    ) internal returns (bool) {
        require(block.number <= _report.block, "Expired");
        require(!isReportUsed[_report.identifier], "Slot already reported");

        bytes32 structHash = keccak256(
            abi.encodePacked(
                REPORT_TYPEHASH,
                _report.slashType,
                _report.debtor,
                _report.amount,
                _report.identifier,
                _report.block,
                keccak256(_report.signature)
            )
        );
        bytes32 typedHash = _hashTypedDataV4(structHash);

        isReportUsed[_report.identifier] = true;

        return _verifySignature(_report.debtor, _signature, typedHash);
    }

    /// @notice Internal function to verify rsignature
    /// @param _debtor - The debtor address
    /// @param _signature - ECDSA signature validating the report
    /// @param _typedHash - Typehash of signature
    function _verifySignature(
        address _debtor,
        SignatureECDSA calldata _signature,
        bytes32 _typedHash
    ) internal view virtual returns (bool) {
        /// Verify the EIP712-compatible signed struct hash
        address recovery = ECDSA.recover(
            _typedHash,
            _signature.v,
            _signature.r,
            _signature.s
        );

        return
            recovery ==
            KSquaredLending(kSquaredLendingPool).getDesignatedVerifier(_debtor);
    }
}
