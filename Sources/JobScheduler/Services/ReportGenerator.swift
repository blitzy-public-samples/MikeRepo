// Sources/JobScheduler/Services/ReportGenerator.swift
// WealthLedger — Paginated CSV Report Generation with Field Selection
//
// Generates CSV reports from account data with configurable field selection,
// account filtering, and target date parameters. Paginates at
// AppConstants.batchSize (1,000) accounts per page to enforce Rule 7
// (batch memory cap). Account objects are converted to lightweight string
// row arrays per batch, then released before the next batch is loaded.
//
// Rules Enforced:
//   Rule 4  — Entitlement Enforcement: account data is fetched via
//             AccountService which pre-filters by user entitlements.
//   Rule 7  — Batch Memory Cap: paginates at 1,000 accounts per page.
//             Account objects are released after each batch is processed
//             into string rows. Only string rows accumulate across batches.
//   Rule 8  — MySQLKit-Only: no SwiftData imports.
//   Rule 9  — Offline Runtime: all data from local MySQL, export to local FS.
//   Gate 2  — Swift 6 strict concurrency: Sendable final class, let-only
//             properties. Zero @unchecked Sendable or warning suppressions.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared

// Selective imports to avoid ReferenceData type name collisions between
// the Persistence module and ReferenceDataService module.
import struct ReferenceDataService.CSVExporter
import class AccountManagement.AccountService
import struct AccountManagement.Account
import class ValuationEngine.ValuationService

// MARK: - ReportGenerator

/// Generates CSV reports with configurable field selection, account filtering,
/// and target date support.
///
/// `ReportGenerator` is the execution engine for report-type jobs created by
/// ``JobSchedulerService``. It fetches account data (respecting entitlements
/// per Rule 4), extracts selected fields, formats the output as RFC 4180 CSV
/// via ``CSVExporter``, and writes the result to a local file.
///
/// ## Pagination (Rule 7 — Batch Memory Cap)
///
/// Account data is processed in batches of ``AppConstants/batchSize`` (1,000).
/// Each batch of ``Account`` objects is converted to string row arrays and then
/// released from memory before the next batch is loaded. Only lightweight
/// `[[String]]` row arrays accumulate across batches — not full ``Account``
/// objects. This ensures no more than 1,000 account records exist in memory
/// simultaneously, regardless of the total number of accounts in the report.
///
/// ## Field Extraction
///
/// Supported fields are mapped from ``JobParameters/fieldSelection`` strings
/// to ``Account`` properties via ``extractFieldValue(from:field:targetDate:)``.
/// Unknown fields produce an empty string in the CSV output rather than failing
/// the entire report.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// This class is `public final class` with only immutable `let` properties of
/// `Sendable`-conforming types (`AccountService`, `ValuationService`,
/// `CSVExporter`). It conforms to `Sendable` without `@unchecked` annotations.
/// All `DateFormatter` instances are created locally within methods — not
/// stored as properties — for thread safety. Zero warning suppressions.
public final class ReportGenerator: Sendable {

    // MARK: - Dependencies (all immutable for Sendable safety)

    /// Service for querying account data with entitlement enforcement (Rule 4).
    ///
    /// Provides `search(name:id:type:group:userId:page:pageSize:)` for paginated
    /// all-account reports and `getAccounts(ids:userId:)` for specific-account
    /// reports. All query paths enforce RBAC entitlements via the `userId`
    /// parameter — users without READ access receive zero records.
    private let accountService: AccountService

    /// Service for per-account NAV valuation data retrieval.
    ///
    /// Available for fresh valuation runs via `runValuation(for:marketDate:)`.
    /// The current report flow uses cached valuation values from ``Account``
    /// properties (`cachedValuationAmount`, `cachedValueDate`), but this
    /// service can be invoked for on-demand valuation when needed.
    private let valuationService: ValuationService

    /// Stateless CSV exporter for RFC 4180 formatting and atomic file writing.
    ///
    /// Provides `exportToCSV(headers:rows:)` for CSV string formatting and
    /// `writeCSVToFile(csvString:to:)` for atomic local filesystem writes.
    private let csvExporter: CSVExporter

    // MARK: - Initializer

    /// Creates a new `ReportGenerator` with all required dependencies.
    ///
    /// All dependencies are injected by ``DependencyContainer`` during
    /// application startup. No global state, no singletons.
    ///
    /// - Parameters:
    ///   - accountService: Service for entitlement-filtered account data access (Rule 4).
    ///   - valuationService: Service for per-account valuation computations.
    ///   - csvExporter: Stateless CSV formatting and file writing utility.
    public init(
        accountService: AccountService,
        valuationService: ValuationService,
        csvExporter: CSVExporter
    ) {
        self.accountService = accountService
        self.valuationService = valuationService
        self.csvExporter = csvExporter
    }

    // MARK: - Report Generation

    /// Generates a CSV report based on the provided job parameters.
    ///
    /// This method orchestrates the full report workflow:
    /// 1. Determine the target date from parameters (or use current date).
    /// 2. Resolve headers from ``JobParameters/fieldSelection`` (or use defaults).
    /// 3. Fetch accounts in batches of 1,000 (Rule 7), converting each batch to
    ///    string rows before releasing Account objects from memory.
    /// 4. Format all accumulated rows as CSV via ``CSVExporter/exportToCSV(headers:rows:)``.
    /// 5. Write to a local file and return the file path.
    ///
    /// ## Entitlement Enforcement (Rule 4)
    ///
    /// Account data is fetched via ``AccountService``, which pre-filters results
    /// by the user's entitled account groups. Users without READ access to an
    /// account group receive zero records for that group — never an error.
    ///
    /// ## Pagination (Rule 7 — Batch Memory Cap)
    ///
    /// Account objects are processed in batches of ``AppConstants/batchSize``
    /// (1,000). Each batch is immediately converted to lightweight string row
    /// arrays and then the Account objects go out of scope (released). Only
    /// `[[String]]` rows accumulate across batches.
    ///
    /// - Parameters:
    ///   - parameters: Job configuration including field selection, account
    ///     selection, and target date for point-in-time reporting.
    ///   - userId: The authenticated user ID for entitlement-filtered data access.
    /// - Returns: The file path of the generated CSV report.
    /// - Throws: If data retrieval or file writing fails.
    public func generateReport(
        parameters: JobParameters,
        userId: UInt64
    ) async throws -> String {
        // Step 1: Determine target date (use current date if not specified)
        let targetDate = parameters.targetDate ?? Date()

        // Step 2: Resolve field selection (use defaults if not specified)
        let selectedFields = resolveFieldSelection(parameters.fieldSelection)

        // Step 3: Fetch accounts in batches and build rows (Rule 7)
        // Account objects are converted to string rows per batch, then released.
        // Only lightweight [[String]] rows accumulate across batches.
        var allRows: [[String]] = []

        if let accountIds = parameters.accountSelection, !accountIds.isEmpty {
            // Report on specific accounts — paginate the account IDs list
            let batchSize = AppConstants.batchSize
            let totalBatches = (accountIds.count + batchSize - 1) / batchSize

            for batchIndex in 0..<totalBatches {
                let startIndex = batchIndex * batchSize
                let endIndex = min(startIndex + batchSize, accountIds.count)
                let batchIds = Array(accountIds[startIndex..<endIndex])

                // Fetch this batch of accounts (entitlement-filtered via AccountService)
                let accounts = try await accountService.getAccounts(
                    ids: batchIds,
                    userId: userId
                )

                // Convert to string rows immediately; Account objects go out of scope
                let rows = buildRows(
                    accounts: accounts,
                    fields: selectedFields,
                    targetDate: targetDate
                )
                allRows.append(contentsOf: rows)
            }
        } else {
            // Report on all accessible accounts — paginate via search
            var page = 1
            let pageSize = AppConstants.batchSize

            while true {
                let accounts = try await accountService.search(
                    name: nil,
                    id: nil,
                    type: nil,
                    group: nil,
                    userId: userId,
                    page: page,
                    pageSize: pageSize
                )

                // Empty page signals end of results
                if accounts.isEmpty {
                    break
                }

                // Convert to string rows immediately; Account objects go out of scope
                let rows = buildRows(
                    accounts: accounts,
                    fields: selectedFields,
                    targetDate: targetDate
                )
                allRows.append(contentsOf: rows)

                // If fewer than pageSize results, we've reached the last page
                if accounts.count < pageSize {
                    break
                }
                page += 1
            }
        }

        // Step 4: Format as CSV via CSVExporter
        let csvString = csvExporter.exportToCSV(headers: selectedFields, rows: allRows)

        // Step 5: Write to local file (Rule 9 — offline, local filesystem only)
        let outputPath = generateOutputPath(targetDate: targetDate)
        try csvExporter.writeCSVToFile(csvString: csvString, to: outputPath)

        return outputPath
    }

    // MARK: - Field Resolution

    /// Resolves field selection from job parameters, falling back to defaults.
    ///
    /// If the input is nil or empty, returns a comprehensive default set covering
    /// all primary account properties for a complete report.
    ///
    /// - Parameter fieldSelection: Optional array of field name strings from
    ///   ``JobParameters/fieldSelection``.
    /// - Returns: Array of field names to include in the report.
    private func resolveFieldSelection(_ fieldSelection: [String]?) -> [String] {
        if let selection = fieldSelection, !selection.isEmpty {
            return selection
        }
        return defaultFieldNames()
    }

    /// Returns the default field names for report generation when no explicit
    /// selection is provided.
    ///
    /// Default fields include: accountId, accountName, accountType, accountStatus,
    /// accountGroupId, valuationTimezone, cachedValuationAmount, cachedValueDate.
    /// These cover all primary account properties that are most commonly needed
    /// in account reports.
    private func defaultFieldNames() -> [String] {
        [
            "accountId",
            "accountName",
            "accountType",
            "accountStatus",
            "accountGroupId",
            "valuationTimezone",
            "cachedValuationAmount",
            "cachedValueDate"
        ]
    }

    // MARK: - Row Building

    /// Builds CSV rows from account data based on selected field names.
    ///
    /// Each row corresponds to one account. Field values are extracted by name
    /// via ``extractFieldValue(from:field:targetDate:)``. After this method
    /// returns, the caller's `accounts` array can go out of scope to free memory
    /// while the lightweight string rows are retained (Rule 7).
    ///
    /// - Parameters:
    ///   - accounts: Array of account records for this batch (≤ 1,000 per Rule 7).
    ///   - fields: Array of field names to extract from each account.
    ///   - targetDate: Target date for the report (used in date-context fields).
    /// - Returns: Array of rows, each row being an array of string values
    ///   positionally matching the `fields` array.
    private func buildRows(
        accounts: [Account],
        fields: [String],
        targetDate: Date
    ) -> [[String]] {
        accounts.map { account in
            fields.map { field in
                extractFieldValue(from: account, field: field, targetDate: targetDate)
            }
        }
    }

    /// Extracts a field value from an account based on the field name string.
    ///
    /// Maps string field names from ``JobParameters/fieldSelection`` to the
    /// corresponding ``Account`` property. Unknown field names produce an empty
    /// string rather than failing the entire report — this ensures forward
    /// compatibility when new fields are added.
    ///
    /// ## Supported Fields
    ///
    /// | Field Name | Source Property | Type |
    /// |------------|----------------|------|
    /// | `accountId` | `Account.id` | `UInt64` → `String` |
    /// | `accountName` | `Account.name` | `String` |
    /// | `accountType` | `Account.fundType.rawValue` | `FundType` → `String` |
    /// | `accountStatus` | `Account.status.rawValue` | `AccountStatus` → `String` |
    /// | `accountGroupId` | `Account.accountGroupId` | `UInt64` → `String` |
    /// | `valuationTimezone` | `Account.valuationTimezone` | `String` |
    /// | `cachedValuationAmount` | `Account.cachedValuationAmount` | `Decimal?` → `String` |
    /// | `cachedValueDate` | `Account.cachedValueDate` | `Date?` → `String` |
    /// | `valuationSchedule` | `Account.valuationSchedule` | `String?` → `String` |
    /// | `ownershipDetails` | `Account.ownershipDetails` | `String?` → `String` |
    ///
    /// - Parameters:
    ///   - account: The account to extract the field from.
    ///   - field: The field name string (case-sensitive).
    ///   - targetDate: The target date for the report (available for date-context fields).
    /// - Returns: The string representation of the field value, or empty string
    ///   for unknown fields.
    private func extractFieldValue(
        from account: Account,
        field: String,
        targetDate: Date
    ) -> String {
        switch field {
        case "accountId":
            return String(account.id)
        case "accountName":
            return account.name
        case "accountType":
            return account.fundType.rawValue
        case "accountStatus":
            return account.status.rawValue
        case "accountGroupId":
            return String(account.accountGroupId)
        case "valuationTimezone":
            return account.valuationTimezone
        case "cachedValuationAmount":
            return "\(account.cachedValuationAmount ?? Decimal.zero)"
        case "cachedValueDate":
            if let date = account.cachedValueDate {
                return formatDate(date)
            }
            return ""
        case "valuationSchedule":
            return account.valuationSchedule ?? ""
        case "ownershipDetails":
            return account.ownershipDetails ?? ""
        case "targetDate":
            return formatDate(targetDate)
        default:
            // Unknown field — return empty string rather than failing the report
            return ""
        }
    }

    // MARK: - Date Formatting

    /// Formats a date value for CSV output using ISO 8601 date format (yyyy-MM-dd).
    ///
    /// Creates a local ``DateFormatter`` instance for thread safety — no shared
    /// formatter state that could cause data races. Uses `en_US_POSIX` locale
    /// for consistent formatting regardless of user locale settings.
    ///
    /// - Parameter date: The date to format.
    /// - Returns: Formatted date string (e.g., `"2026-04-15"`).
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - Output Path Generation

    /// Generates an output file path for the CSV report.
    ///
    /// The file is written to the user's Documents directory with a filename
    /// containing both the target date and a generation timestamp for uniqueness.
    /// Falls back to `/tmp` if the Documents directory is unavailable.
    /// Only writes to local filesystem (Rule 9 — offline).
    ///
    /// Filename format: `WealthLedger_Report_<targetDate>_<timestamp>.csv`
    /// Example: `WealthLedger_Report_20260415_20260415_143022.csv`
    ///
    /// - Parameter targetDate: The target date for the report (used in filename).
    /// - Returns: Absolute path for the output CSV file.
    private func generateOutputPath(targetDate: Date) -> String {
        // Timestamp for uniqueness (avoids overwrites when generating multiple reports)
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd_HHmmss"
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = timestampFormatter.string(from: Date())

        // Target date for report identification in filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let datePart = dateFormatter.string(from: targetDate)

        // Resolve Documents directory or fall back to /tmp for safety
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first?.path ?? "/tmp"

        return "\(documentsPath)/WealthLedger_Report_\(datePart)_\(timestamp).csv"
    }
}
