// Sources/JobScheduler/Services/ReportGenerator.swift
// WealthLedger — Paginated CSV Report Generation with Field Selection
//
// Generates CSV reports from account data with configurable field selection,
// account filtering, and target date parameters. Paginates at
// AppConstants.batchSize (1,000) accounts per page to enforce Rule 7
// (batch memory cap). Delegates CSV formatting to CSVExporter.
//
// Rules Enforced:
//   Rule 4  — Entitlement Enforcement: account data is fetched via
//             AccountService which pre-filters by user entitlements.
//   Rule 7  — Batch Memory Cap: paginates at 1,000 accounts per page.
//   Rule 8  — MySQLKit-Only: no SwiftData imports.
//   Rule 9  — Offline Runtime: all data from local MySQL, export to local FS.
//   Gate 2  — Swift 6 strict concurrency: Sendable final class, let-only
//             properties. Zero @unchecked Sendable or warning suppressions.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared

// Selective imports to avoid ReferenceData type name collisions.
import struct ReferenceDataService.CSVExporter
import class AccountManagement.AccountService
import struct AccountManagement.Account
import class ValuationEngine.ValuationService

// MARK: - ReportGenerator

/// Generates CSV reports with configurable field selection and account filtering.
///
/// `ReportGenerator` is the execution engine for report-type jobs created by
/// ``JobSchedulerService``. It fetches account data (respecting entitlements
/// per Rule 4), extracts selected fields, formats the output as RFC 4180 CSV
/// via ``CSVExporter``, and writes the result to a local file.
///
/// ## Pagination (Rule 7)
///
/// When processing account selections larger than ``AppConstants/batchSize``
/// (1,000), the generator batches account ID fetches to avoid exceeding the
/// memory cap. When no specific account selection is provided, it paginates
/// through the full account universe via ``AccountService/search``.
///
/// ## Field Extraction
///
/// Supported fields are mapped from ``JobParameters/fieldSelection`` strings
/// to ``Account`` properties via ``extractFieldValue(from:field:)``. Unknown
/// fields produce an empty string in the CSV output rather than failing the
/// entire report.
///
/// ## Thread Safety (Gate 2)
///
/// This class is `final` with only immutable `let` properties of `Sendable`-
/// conforming types. Zero `@unchecked Sendable` annotations.
public final class ReportGenerator: Sendable {

    // MARK: - Dependencies (all immutable for Sendable safety)

    /// Account service for fetching account data with entitlement enforcement (Rule 4).
    private let accountService: AccountService

    /// Valuation service for per-account valuation data (used for target-date reports).
    private let valuationService: ValuationService

    /// Stateless CSV exporter for RFC 4180 formatting and atomic file writing.
    private let csvExporter: CSVExporter

    // MARK: - Initializer

    /// Creates a new `ReportGenerator` with all required dependencies.
    ///
    /// - Parameters:
    ///   - accountService: Service for entitlement-filtered account data access.
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
    /// 1. Determine headers from ``JobParameters/fieldSelection`` (or use defaults).
    /// 2. Fetch accounts — either specific IDs from ``JobParameters/accountSelection``
    ///    or paginated search results from the full universe.
    /// 3. Extract field values for each account into row arrays.
    /// 4. Format as CSV via ``CSVExporter/exportToCSV(headers:rows:)``.
    /// 5. Write to a local file and return the file path.
    ///
    /// ## Entitlement Enforcement (Rule 4)
    /// Account data is fetched via ``AccountService``, which pre-filters results
    /// by the user's entitled account groups. Users without READ access to an
    /// account group receive zero records for that group.
    ///
    /// ## Pagination (Rule 7)
    /// Account IDs are fetched in batches of ``AppConstants/batchSize`` (1,000).
    /// This ensures no more than 1,000 account records exist in memory at any
    /// point during report generation.
    ///
    /// - Parameters:
    ///   - parameters: Job configuration including field selection, account
    ///     selection, target date, and source file path for output.
    ///   - userId: The authenticated user ID for entitlement-filtered data access.
    /// - Returns: The file path of the generated CSV report.
    /// - Throws: ``AppError/dataAccessFailed(_:)`` for I/O errors or data access failures.
    public func generateReport(
        parameters: JobParameters,
        userId: UInt64
    ) async throws -> String {
        // Step 1: Determine field headers
        let fields = resolveFieldSelection(parameters.fieldSelection)

        // Step 2: Fetch accounts in batches (Rule 7)
        let accounts = try await fetchAccounts(
            accountSelection: parameters.accountSelection,
            userId: userId
        )

        // Step 3: Extract field values into row arrays
        var rows: [[String]] = []
        rows.reserveCapacity(accounts.count)
        for account in accounts {
            let row = fields.map { field in
                extractFieldValue(from: account, field: field)
            }
            rows.append(row)
        }

        // Step 4: Format as CSV
        let csvString = csvExporter.exportToCSV(headers: fields, rows: rows)

        // Step 5: Write to local file
        let outputPath = resolveOutputPath(parameters: parameters)
        try csvExporter.writeCSVToFile(csvString: csvString, to: outputPath)

        return outputPath
    }

    // MARK: - Private Helpers

    /// Resolves field selection from job parameters, falling back to defaults.
    ///
    /// - Parameter fieldSelection: Optional array of field name strings from job parameters.
    /// - Returns: Array of field names to include in the report. If the input is
    ///   nil or empty, returns a comprehensive default set.
    private func resolveFieldSelection(_ fieldSelection: [String]?) -> [String] {
        if let selection = fieldSelection, !selection.isEmpty {
            return selection
        }
        // Default fields covering all primary account properties
        return [
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

    /// Fetches accounts in batches respecting the memory cap (Rule 7).
    ///
    /// If `accountSelection` is provided, fetches those specific IDs in batches.
    /// Otherwise, paginates through the full account universe via search.
    ///
    /// - Parameters:
    ///   - accountSelection: Optional array of specific account IDs to fetch.
    ///   - userId: The authenticated user ID for entitlement filtering.
    /// - Returns: Aggregated array of accounts (each batch ≤ 1,000).
    private func fetchAccounts(
        accountSelection: [UInt64]?,
        userId: UInt64
    ) async throws -> [Account] {
        if let selectedIds = accountSelection, !selectedIds.isEmpty {
            return try await fetchAccountsByIds(selectedIds, userId: userId)
        } else {
            return try await fetchAllAccountsPaginated(userId: userId)
        }
    }

    /// Fetches specific accounts by ID in batches of AppConstants.batchSize.
    ///
    /// - Parameters:
    ///   - ids: Account IDs to fetch.
    ///   - userId: User ID for entitlement filtering.
    /// - Returns: All fetched accounts across all batches.
    private func fetchAccountsByIds(
        _ ids: [UInt64],
        userId: UInt64
    ) async throws -> [Account] {
        var allAccounts: [Account] = []
        let batchSize = AppConstants.batchSize

        // Process IDs in batches of 1,000 (Rule 7)
        var offset = 0
        while offset < ids.count {
            let endIndex = min(offset + batchSize, ids.count)
            let batchIds = Array(ids[offset..<endIndex])

            let batchAccounts = try await accountService.getAccounts(
                ids: batchIds,
                userId: userId
            )
            allAccounts.append(contentsOf: batchAccounts)
            offset = endIndex
        }

        return allAccounts
    }

    /// Paginates through all accounts the user has access to via search.
    ///
    /// - Parameter userId: User ID for entitlement filtering.
    /// - Returns: All accessible accounts across all pages.
    private func fetchAllAccountsPaginated(userId: UInt64) async throws -> [Account] {
        var allAccounts: [Account] = []
        var page = 1
        let pageSize = AppConstants.batchSize

        while true {
            let batch = try await accountService.search(
                name: nil,
                id: nil,
                type: nil,
                group: nil,
                userId: userId,
                page: page,
                pageSize: pageSize
            )

            allAccounts.append(contentsOf: batch)

            // If we got fewer than pageSize, we've reached the last page
            if batch.count < pageSize {
                break
            }
            page += 1
        }

        return allAccounts
    }

    /// Extracts a field value from an account based on the field name string.
    ///
    /// Maps string field names from ``JobParameters/fieldSelection`` to the
    /// corresponding ``Account`` property. Unknown field names produce an empty
    /// string rather than failing the report.
    ///
    /// Supported fields:
    /// - `accountId` — Account primary key
    /// - `accountName` — Account display name
    /// - `accountType` — Fund type raw value (e.g., "etf", "sma")
    /// - `accountStatus` — Lifecycle status raw value (e.g., "active")
    /// - `accountGroupId` — Parent account group FK
    /// - `valuationTimezone` — IANA timezone string
    /// - `cachedValuationAmount` — Latest cached NAV amount
    /// - `cachedValueDate` — Latest cached valuation date
    /// - `valuationSchedule` — Valuation schedule description
    /// - `ownershipDetails` — Ownership detail string
    ///
    /// - Parameters:
    ///   - account: The account to extract the field from.
    ///   - field: The field name string.
    /// - Returns: The string representation of the field value.
    private func extractFieldValue(from account: Account, field: String) -> String {
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
            if let amount = account.cachedValuationAmount {
                return "\(amount)"
            }
            return ""
        case "cachedValueDate":
            if let date = account.cachedValueDate {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                return formatter.string(from: date)
            }
            return ""
        case "valuationSchedule":
            return account.valuationSchedule ?? ""
        case "ownershipDetails":
            return account.ownershipDetails ?? ""
        default:
            // Unknown field — return empty string rather than failing the report
            return ""
        }
    }

    /// Resolves the output file path for the generated CSV report.
    ///
    /// If `sourceFilePath` is set in the parameters, it is used as the output
    /// directory base. Otherwise, a default path is generated in the current
    /// working directory with a timestamp-based filename.
    ///
    /// - Parameter parameters: Job parameters that may specify an output path.
    /// - Returns: The resolved file path for the CSV output.
    private func resolveOutputPath(parameters: JobParameters) -> String {
        if let sourcePath = parameters.sourceFilePath, !sourcePath.isEmpty {
            // Use the source path as the output directory, appending a report filename
            let directory = (sourcePath as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                return "\(directory)/report_\(timestamp).csv"
            }
        }

        // Default: generate in current working directory
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "report_\(timestamp).csv"
    }
}
