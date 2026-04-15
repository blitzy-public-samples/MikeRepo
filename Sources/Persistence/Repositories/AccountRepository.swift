// Sources/Persistence/Repositories/AccountRepository.swift
// WealthLedger — Account Table CRUD, Search, Batch Operations, Cached Valuation
//
// The most complex repository in the system. Provides full CRUD, multi-criteria
// search with partial name match (LIKE 'prefix%'), exact ID lookup, type filter,
// group filter, pagination at 1,000 records, batch status update for up to 1,000
// accounts, and cached valuation atomic update within transactions. Used by
// AccountService, ValuationService, and multiple UI views.
//
// SPDX-License-Identifier: MIT

import Foundation
import MySQLKit
import MySQLNIO
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - FundType (Persistence-Layer Definition)

/// Fund type classification for accounts in the persistence layer.
///
/// Defined locally within the Persistence module to avoid a circular module
/// dependency. The AccountManagement module depends on Persistence — not vice
/// versa. Raw values match the MySQL `ENUM` column values in the `accounts`
/// table (`fund_type` column) from migration `004_create_accounts.sql`.
///
/// | Case              | MySQL Enum Value        | Category      |
/// |-------------------|-------------------------|---------------|
/// | openMutualFund    | `open_mutual_fund`      | Institutional |
/// | closedMutualFund  | `closed_mutual_fund`    | Institutional |
/// | etf               | `etf`                   | Institutional |
/// | hedgeFund         | `hedge_fund`            | Institutional |
/// | sma               | `sma`                   | Wealth        |
/// | uma               | `uma`                   | Wealth        |
public enum FundType: String, Sendable, Codable, CaseIterable {
    case openMutualFund = "open_mutual_fund"
    case closedMutualFund = "closed_mutual_fund"
    case etf = "etf"
    case hedgeFund = "hedge_fund"
    case sma = "sma"
    case uma = "uma"

    /// Whether this fund type belongs to the Institutional category.
    public var isInstitutional: Bool {
        switch self {
        case .openMutualFund, .closedMutualFund, .etf, .hedgeFund:
            return true
        case .sma, .uma:
            return false
        }
    }

    /// Whether this fund type belongs to the Wealth category.
    public var isWealth: Bool {
        !isInstitutional
    }
}

// MARK: - AccountStatus (Persistence-Layer Definition)

/// Account lifecycle status in the persistence layer.
///
/// Defined locally to avoid circular module dependency. Raw values match the
/// MySQL `ENUM` column values in the `accounts` table (`account_status` column)
/// from migration `004_create_accounts.sql`.
public enum AccountStatus: String, Sendable, Codable, CaseIterable {
    case active = "active"
    case inactive = "inactive"
    case pending = "pending"
    case suspended = "suspended"
}

// MARK: - Account Model (Persistence-Layer Definition)

/// Represents a single account record from the MySQL `accounts` table.
///
/// This struct is defined within the Persistence module because the
/// AccountManagement module depends on Persistence — not vice versa. Defining
/// Account here avoids a circular module dependency while providing a concrete
/// `Entity` type for ``RepositoryProtocol`` conformance.
///
/// The struct mirrors the MySQL `accounts` table schema exactly:
///
/// | Swift Property           | MySQL Column              | MySQL Type                                    |
/// |--------------------------|---------------------------|-----------------------------------------------|
/// | `id`                     | `id`                      | BIGINT UNSIGNED AUTO_INCREMENT                |
/// | `name`                   | `account_name`            | VARCHAR(255) NOT NULL                         |
/// | `fundType`               | `fund_type`               | ENUM(...) NOT NULL                            |
/// | `ownershipDetails`       | `ownership_details`       | TEXT (nullable)                               |
/// | `valuationTimezone`      | `valuation_timezone`      | VARCHAR(64) NOT NULL DEFAULT 'America/New_York' |
/// | `valuationSchedule`      | `valuation_schedule`      | VARCHAR(255) (nullable)                       |
/// | `cachedValuationAmount`  | `cached_valuation_amount` | DECIMAL(20,6) DEFAULT NULL                    |
/// | `cachedValueDate`        | `cached_value_date`       | DATE DEFAULT NULL                             |
/// | `status`                 | `account_status`          | ENUM(...) NOT NULL DEFAULT 'pending'          |
/// | `accountGroupId`         | `account_group_id`        | BIGINT UNSIGNED NOT NULL, FK                  |
/// | `createdAt`              | `created_at`              | TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP  |
///
/// ## Rules Compliance
///
/// - **Rule 3**: `valuationTimezone` stores IANA timezone strings.
/// - **Rule 8**: No SwiftData anywhere.
/// - **Rule 10**: `accountGroupId` is an FK to `account_groups.id`.
/// - **Rule 11**: `cachedValuationAmount` and `cachedValueDate` are nullable,
///   populated atomically by `ValuationService`.
/// - **Gate 2**: All properties are value types → naturally `Sendable`.
public struct Account: Sendable, Equatable, Identifiable {

    /// Unique identifier (BIGINT UNSIGNED AUTO_INCREMENT).
    /// A value of `0` indicates the entity has not yet been persisted.
    public let id: UInt64

    /// Human-readable account name (VARCHAR 255, NOT NULL).
    public let name: String

    /// Fund type classification for this account.
    public let fundType: FundType

    /// Free-form ownership details (TEXT, nullable).
    public let ownershipDetails: String?

    /// IANA timezone string for valuation date computation (Rule 3).
    /// Example: `"America/New_York"`, `"Europe/London"`.
    public let valuationTimezone: String

    /// Description of the valuation schedule (nullable).
    public let valuationSchedule: String?

    /// Cached latest NAV valuation amount (Rule 11).
    /// `nil` before first valuation is run. Uses `Decimal` for financial precision.
    public let cachedValuationAmount: Decimal?

    /// Cached latest valuation date (Rule 11).
    /// `nil` before first valuation is run.
    public let cachedValueDate: Date?

    /// Current lifecycle status of the account.
    public let status: AccountStatus

    /// Foreign key to `account_groups.id` (Rule 10).
    public let accountGroupId: UInt64

    /// Timestamp when this account was created.
    public let createdAt: Date

    /// Creates a new Account instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (0 for new entities).
    ///   - name: Human-readable account name.
    ///   - fundType: Fund type classification.
    ///   - ownershipDetails: Optional ownership details.
    ///   - valuationTimezone: IANA timezone string (Rule 3).
    ///   - valuationSchedule: Optional valuation schedule description.
    ///   - cachedValuationAmount: Optional cached NAV amount (Rule 11).
    ///   - cachedValueDate: Optional cached valuation date (Rule 11).
    ///   - status: Current lifecycle status.
    ///   - accountGroupId: Foreign key to account groups (Rule 10).
    ///   - createdAt: Timestamp of creation.
    public init(
        id: UInt64,
        name: String,
        fundType: FundType,
        ownershipDetails: String?,
        valuationTimezone: String,
        valuationSchedule: String?,
        cachedValuationAmount: Decimal?,
        cachedValueDate: Date?,
        status: AccountStatus,
        accountGroupId: UInt64,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.fundType = fundType
        self.ownershipDetails = ownershipDetails
        self.valuationTimezone = valuationTimezone
        self.valuationSchedule = valuationSchedule
        self.cachedValuationAmount = cachedValuationAmount
        self.cachedValueDate = cachedValueDate
        self.status = status
        self.accountGroupId = accountGroupId
        self.createdAt = createdAt
    }
}

// MARK: - AccountRepository

/// Repository for the `accounts` MySQL table providing full CRUD, multi-criteria
/// search, batch status updates, and atomic cached valuation writes.
///
/// ``AccountRepository`` is the data-access layer for all account-related
/// persistence. It is consumed by:
/// - ``AccountService`` — for CRUD, search, and batch status updates.
/// - ``ValuationService`` — for cached valuation atomic updates (Rule 11).
/// - Multiple UI views — via service layer for account display.
///
/// ## Rules Compliance
///
/// - **Rule 7 (Batch Memory Cap)**: All paginated methods enforce a maximum
///   page size of ``AppConstants/defaultPagination`` (1,000). Batch operations
///   cap at ``AppConstants/batchSize`` (1,000) records.
/// - **Rule 8 (MySQLKit-Only)**: All queries use MySQLKit/SQLKit. No SwiftData.
/// - **Rule 10 (Schema Referential Integrity)**: FK to `account_groups` enforced
///   at MySQL DDL level. Deleting an account may fail with FK constraint errors
///   from `positions` or `transactions` tables.
/// - **Rule 11 (Cached Valuation Denormalization)**: ``updateCachedValuation``
///   and ``batchUpdateCachedValuations`` accept an external `MySQLDatabase`
///   connection from an active transaction, enabling atomic writes with the
///   valuation result.
/// - **Rule 13 (Performance)**: Search queries leverage B-tree indexes
///   (`idx_accounts_name`, `idx_accounts_fund_type`, `idx_accounts_group`).
///   Name search uses `LIKE 'prefix%'` (B-tree compatible), NOT `LIKE '%sub%'`.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: This is a `final class` with only
///   immutable `let` stored properties of `Sendable` types (`ConnectionPool` is
///   an actor; `Logger` is `Sendable`). No `@unchecked Sendable`.
public final class AccountRepository: RepositoryProtocol, Sendable {

    // MARK: - Associated Types

    /// The entity type managed by this repository.
    public typealias Entity = Account

    /// The primary key type for accounts.
    public typealias EntityID = UInt64

    // MARK: - Properties

    /// AsyncKit-based MySQL connection pool for executing all database queries.
    /// Injected via constructor for dependency injection and testability.
    private let pool: ConnectionPool

    /// Structured logger for repository lifecycle events, including query
    /// execution tracing, batch operation progress, search performance metrics,
    /// and error diagnostics.
    private let logger: Logger

    // MARK: - Constants

    /// Standard SELECT column list for the `accounts` table.
    /// Centralised here to guarantee consistent column ordering across all
    /// query methods and to avoid typos in repeated SQL fragments.
    private static let selectColumns: String =
        "id, account_name, fund_type, account_group_id, ownership_details, " +
        "valuation_timezone, valuation_schedule, cached_valuation_amount, " +
        "cached_value_date, account_status, created_at"

    // MARK: - Initializer

    /// Creates a new account repository backed by the given connection pool.
    ///
    /// - Parameters:
    ///   - pool: The ``ConnectionPool`` actor providing managed MySQL connections.
    ///   - logger: Structured logger. Defaults to label `"persistence.account-repository"`.
    public init(
        pool: ConnectionPool,
        logger: Logger = Logger(label: "persistence.account-repository")
    ) {
        self.pool = pool
        self.logger = logger
    }

    // MARK: - RepositoryProtocol Conformance — Read Operations

    /// Retrieves a single account by its primary key.
    ///
    /// Executes a parameterised `SELECT` against `accounts.id`. Returns `nil`
    /// when no row matches — this is not treated as an error condition.
    ///
    /// - Parameter id: The account's primary key (BIGINT UNSIGNED).
    /// - Returns: The matching ``Account``, or `nil` if not found.
    /// - Throws: Database connection or query execution errors.
    public func findById(_ id: UInt64) async throws -> Account? {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Finding account by id: \(id)")
            let rows = try await db.query(
                "SELECT \(Self.selectColumns) FROM accounts WHERE id = ?",
                [MySQLData(int: Int(id))]
            ).get()
            guard let row = rows.first else {
                return nil
            }
            return try AccountRepository.mapRow(row)
        }
    }

    /// Retrieves a paginated list of accounts ordered by primary key ascending.
    ///
    /// Enforces Rule 7 (Batch Memory Cap): page size is capped at
    /// ``AppConstants/defaultPagination`` (1,000). Pages are 1-based; page
    /// values less than 1 are clamped to 1. Page sizes less than 1 are clamped
    /// to 1.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Values < 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: Array of accounts for the requested page, may be empty.
    /// - Throws: Database connection or query execution errors.
    public func findAll(page: Int, pageSize: Int) async throws -> [Account] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Finding all accounts: page=\(effectivePage), pageSize=\(effectivePageSize), offset=\(offset)")
            let rows = try await db.query(
                "SELECT \(Self.selectColumns) FROM accounts ORDER BY id ASC LIMIT ? OFFSET ?",
                [MySQLData(int: effectivePageSize), MySQLData(int: offset)]
            ).get()
            return try rows.map { try AccountRepository.mapRow($0) }
        }
    }

    // MARK: - RepositoryProtocol Conformance — Write Operations

    /// Creates a new account in the database.
    ///
    /// Inserts a row into the `accounts` table with all provided fields. The
    /// auto-generated ID is retrieved via `LAST_INSERT_ID()` on the same
    /// connection to guarantee correctness. The `created_at` timestamp is
    /// populated by MySQL via `DEFAULT CURRENT_TIMESTAMP`.
    ///
    /// Nullable fields (`ownership_details`, `valuation_schedule`,
    /// `cached_valuation_amount`, `cached_value_date`) are bound as SQL `NULL`
    /// when their Swift values are `nil`.
    ///
    /// FK constraint on `account_group_id` → `account_groups.id` is enforced
    /// by the MySQL schema (Rule 10). Inserting with an invalid group ID will
    /// cause a MySQL constraint error.
    ///
    /// - Parameter entity: The account to create. The `id` field is ignored;
    ///   MySQL generates the auto-increment ID.
    /// - Returns: The created account with the auto-generated ID populated.
    /// - Throws: MySQL FK constraint errors if `accountGroupId` is invalid,
    ///   or database connection errors.
    public func create(_ entity: Account) async throws -> Account {
        let name = entity.name
        let fundType = entity.fundType.rawValue
        let accountGroupId = entity.accountGroupId
        let ownershipDetails = entity.ownershipDetails
        let valuationTimezone = entity.valuationTimezone
        let valuationSchedule = entity.valuationSchedule
        let cachedAmount = entity.cachedValuationAmount
        let cachedDate = entity.cachedValueDate
        let status = entity.status.rawValue
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Creating account with name: \(name), fundType: \(fundType), groupId: \(accountGroupId)")

            // Build binding array — handle nullable fields with MySQLData.null
            let ownershipBind: MySQLData = ownershipDetails.map { MySQLData(string: $0) } ?? .null
            let scheduleBind: MySQLData = valuationSchedule.map { MySQLData(string: $0) } ?? .null
            let cachedAmountBind: MySQLData = cachedAmount.map { MySQLData(string: "\($0)") } ?? .null
            let cachedDateBind: MySQLData
            if let date = cachedDate {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                cachedDateBind = MySQLData(string: formatter.string(from: date))
            } else {
                cachedDateBind = .null
            }

            _ = try await db.query(
                """
                INSERT INTO accounts (account_name, fund_type, account_group_id,
                    ownership_details, valuation_timezone, valuation_schedule,
                    cached_valuation_amount, cached_value_date, account_status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    MySQLData(string: name),
                    MySQLData(string: fundType),
                    MySQLData(int: Int(accountGroupId)),
                    ownershipBind,
                    MySQLData(string: valuationTimezone),
                    scheduleBind,
                    cachedAmountBind,
                    cachedDateBind,
                    MySQLData(string: status),
                ]
            ).get()

            // Retrieve the auto-generated ID on the same connection
            let idRows = try await db.query(
                "SELECT LAST_INSERT_ID() AS insert_id"
            ).get()
            guard let insertId = idRows.first?.column("insert_id")?.uint64 else {
                logger.error("Failed to retrieve LAST_INSERT_ID after account creation for name: \(name)")
                throw AppError.migrationFailed
            }

            logger.info("Created account '\(name)' with id: \(insertId)")
            return Account(
                id: insertId,
                name: name,
                fundType: entity.fundType,
                ownershipDetails: ownershipDetails,
                valuationTimezone: valuationTimezone,
                valuationSchedule: valuationSchedule,
                cachedValuationAmount: cachedAmount,
                cachedValueDate: cachedDate,
                status: entity.status,
                accountGroupId: accountGroupId,
                createdAt: Date()
            )
        }
    }

    /// Deletes an account by its primary key.
    ///
    /// Executes `DELETE FROM accounts WHERE id = ?`. If no row matches the
    /// given identifier, the operation completes silently (no error).
    ///
    /// - Important: This operation may fail with a foreign key constraint error
    ///   if the `positions` or `transactions` tables still reference this
    ///   account. Callers should remove associated positions and transactions
    ///   before deleting the account.
    ///
    /// - Parameter id: The primary key of the account to delete.
    /// - Throws: FK constraint violations or database connection errors.
    public func delete(_ id: UInt64) async throws {
        let logger = self.logger
        try await pool.withConnection { db in
            logger.info("Deleting account with id: \(id)")
            _ = try await db.query(
                "DELETE FROM accounts WHERE id = ?",
                [MySQLData(int: Int(id))]
            ).get()
            logger.info("Deleted account with id: \(id)")
        }
    }

    // MARK: - Search Methods (Rule 13 — Performance Critical)

    /// Searches accounts with optional multi-criteria filters and pagination.
    ///
    /// **THE most performance-critical method** — must search 100,000 accounts
    /// in under 2 seconds (Rule 13). Builds a dynamic `WHERE` clause from
    /// non-nil parameters, leveraging MySQL indexes for efficiency.
    ///
    /// ## Index Usage
    ///
    /// | Filter        | MySQL Index               | Match Type           |
    /// |---------------|---------------------------|----------------------|
    /// | `name`        | `idx_accounts_name`       | Prefix LIKE 'abc%'   |
    /// | `accountId`   | Primary Key               | Exact match          |
    /// | `accountType` | `idx_accounts_fund_type`  | Exact match          |
    /// | `accountGroupId` | `idx_accounts_group`   | Exact match          |
    ///
    /// **CRITICAL**: Name search uses `LIKE 'prefix%'` (B-tree compatible), NOT
    /// `LIKE '%substring%'` which cannot leverage B-tree indexes. This is
    /// essential for meeting the 2-second threshold across 100,000 accounts.
    ///
    /// ## Pagination (Rule 7)
    ///
    /// Page size is capped at ``AppConstants/maxSearchResults`` (1,000). Pages
    /// are 1-based. An empty result set is returned (not an error) when no
    /// accounts match the criteria or when the page is beyond available data.
    ///
    /// - Parameters:
    ///   - name: Optional account name prefix for partial match. Empty strings
    ///     are treated as nil (skipped).
    ///   - accountId: Optional exact account ID match.
    ///   - accountType: Optional exact fund type match (raw value string, e.g.,
    ///     `"etf"`, `"hedge_fund"`).
    ///   - accountGroupId: Optional exact account group ID match.
    ///   - page: 1-based page number. Values < 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: Array of matching accounts, or empty array if none match.
    /// - Throws: Database connection or query execution errors.
    public func search(
        name: String?,
        accountId: UInt64?,
        accountType: String?,
        accountGroupId: UInt64?,
        page: Int,
        pageSize: Int
    ) async throws -> [Account] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.maxSearchResults)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize
        let logger = self.logger

        return try await pool.withConnection { db in
            // Build dynamic WHERE clause from non-nil parameters
            var conditions: [String] = []
            var bindings: [MySQLData] = []

            if let name = name, !name.isEmpty {
                // Rule 13: Use LIKE 'prefix%' for B-tree index compatibility
                conditions.append("account_name LIKE ?")
                bindings.append(MySQLData(string: "\(name)%"))
            }
            if let accountId = accountId {
                conditions.append("id = ?")
                bindings.append(MySQLData(int: Int(accountId)))
            }
            if let accountType = accountType, !accountType.isEmpty {
                // Queries the fund_type ENUM column using idx_accounts_fund_type index
                conditions.append("fund_type = ?")
                bindings.append(MySQLData(string: accountType))
            }
            if let accountGroupId = accountGroupId {
                // Queries account_group_id using idx_accounts_group index
                conditions.append("account_group_id = ?")
                bindings.append(MySQLData(int: Int(accountGroupId)))
            }

            let whereClause = conditions.isEmpty
                ? ""
                : "WHERE \(conditions.joined(separator: " AND "))"

            // Append pagination bindings
            bindings.append(MySQLData(int: effectivePageSize))
            bindings.append(MySQLData(int: offset))

            let sql = "SELECT \(Self.selectColumns) FROM accounts \(whereClause) ORDER BY id ASC LIMIT ? OFFSET ?"

            logger.info("Search accounts: \(sql) with \(bindings.count) bindings, page=\(effectivePage), pageSize=\(effectivePageSize)")

            let rows = try await db.query(sql, bindings).get()
            return try rows.map { try AccountRepository.mapRow($0) }
        }
    }

    /// Searches accounts restricted to a set of entitled account group IDs.
    ///
    /// **Used by ``AccountService``** after ``EntitlementService`` restricts
    /// the query to groups the current user has READ access to (Rule 4 —
    /// Entitlement Enforcement). This is the primary entitlement-aware search
    /// path: the caller first resolves accessible group IDs, then passes them
    /// here.
    ///
    /// The IN clause restricts results to only the specified account groups,
    /// ensuring users never see accounts in groups they lack permission for.
    /// Additional optional filters for name and type further narrow results.
    ///
    /// An empty `accountGroupIds` array returns an empty result immediately
    /// without executing a database query.
    ///
    /// - Parameters:
    ///   - accountGroupIds: Array of account group IDs the user has READ
    ///     access to. Empty array returns empty result.
    ///   - name: Optional account name prefix for partial match.
    ///   - accountType: Optional exact fund type match (raw value string).
    ///   - page: 1-based page number. Values < 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: Array of matching accounts within entitled groups.
    /// - Throws: Database connection or query execution errors.
    public func searchByGroupIds(
        accountGroupIds: [UInt64],
        name: String?,
        accountType: String?,
        page: Int,
        pageSize: Int
    ) async throws -> [Account] {
        // Short-circuit: no entitled groups means no visible accounts (Rule 4)
        guard !accountGroupIds.isEmpty else {
            return []
        }

        let effectivePageSize = min(max(pageSize, 1), AppConstants.maxSearchResults)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize
        let logger = self.logger

        return try await pool.withConnection { db in
            // Build parameterised IN clause for entitled group IDs
            var conditions: [String] = []
            var bindings: [MySQLData] = []

            let placeholders = accountGroupIds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("account_group_id IN (\(placeholders))")
            bindings.append(contentsOf: accountGroupIds.map { MySQLData(int: Int($0)) })

            // Additional optional filters
            if let name = name, !name.isEmpty {
                conditions.append("account_name LIKE ?")
                bindings.append(MySQLData(string: "\(name)%"))
            }
            if let accountType = accountType, !accountType.isEmpty {
                conditions.append("fund_type = ?")
                bindings.append(MySQLData(string: accountType))
            }

            let whereClause = "WHERE \(conditions.joined(separator: " AND "))"

            // Append pagination bindings
            bindings.append(MySQLData(int: effectivePageSize))
            bindings.append(MySQLData(int: offset))

            let sql = "SELECT \(Self.selectColumns) FROM accounts \(whereClause) ORDER BY id ASC LIMIT ? OFFSET ?"

            logger.info("Search by group IDs (\(accountGroupIds.count) groups): page=\(effectivePage), pageSize=\(effectivePageSize)")

            let rows = try await db.query(sql, bindings).get()
            return try rows.map { try AccountRepository.mapRow($0) }
        }
    }

    // MARK: - Batch Operations (Rule 7)

    /// Updates the lifecycle status of multiple accounts in a single transaction.
    ///
    /// **Rule 7 — Batch Memory Cap**: Validates that the input array does not
    /// exceed ``AppConstants/batchSize`` (1,000) account IDs. If the limit is
    /// exceeded, only the first 1,000 IDs are processed and a log warning is
    /// emitted. The operation is executed within a transaction for atomicity.
    ///
    /// Uses a dynamically built `IN` clause with parameterised bindings to
    /// prevent SQL injection.
    ///
    /// - Parameters:
    ///   - accountIds: Array of account primary keys to update. Empty array
    ///     returns immediately without executing a query.
    ///   - newStatus: The new status raw value string (e.g., `"active"`,
    ///     `"suspended"`). Must match an ``AccountStatus`` raw value.
    /// - Throws: Database connection errors or transaction failures.
    public func batchUpdateStatus(
        accountIds: [UInt64],
        newStatus: String
    ) async throws {
        // Short-circuit: nothing to update
        guard !accountIds.isEmpty else {
            return
        }

        // Rule 7: Cap at batchSize (1,000) IDs per operation
        let cappedIds = Array(accountIds.prefix(AppConstants.batchSize))
        if accountIds.count > AppConstants.batchSize {
            logger.info(
                "Batch status update truncated from \(accountIds.count) to \(AppConstants.batchSize) account IDs (Rule 7)"
            )
        }

        let logger = self.logger

        try await pool.withTransaction { db in
            logger.info("Batch updating \(cappedIds.count) accounts to status: \(newStatus)")

            // Build parameterised IN clause: "?, ?, ?, ..."
            let placeholders = cappedIds.map { _ in "?" }.joined(separator: ", ")

            // First binding is the new status, then all account IDs
            var bindings: [MySQLData] = [MySQLData(string: newStatus)]
            bindings.append(contentsOf: cappedIds.map { MySQLData(int: Int($0)) })

            let sql = "UPDATE accounts SET account_status = ? WHERE id IN (\(placeholders))"
            _ = try await db.query(sql, bindings).get()

            logger.info("Batch status update completed for \(cappedIds.count) accounts")
        }
    }

    /// Retrieves accounts matching a list of primary key IDs.
    ///
    /// Constructs a parameterized `IN` clause dynamically. Used by the
    /// Accounts Viewer to load selected accounts.
    ///
    /// **Rule 7**: Input array is capped at ``AppConstants/batchSize`` (1,000)
    /// IDs per query. Excess IDs beyond the cap are silently dropped with
    /// a log message.
    ///
    /// - Parameter ids: Array of account primary keys to retrieve. Empty array
    ///   returns empty result without executing a query.
    /// - Returns: Array of matching accounts ordered by ID ascending.
    /// - Throws: Database connection or query execution errors.
    public func findByIds(_ ids: [UInt64]) async throws -> [Account] {
        // Short-circuit: empty input produces empty output
        guard !ids.isEmpty else {
            return []
        }

        // Rule 7: Limit to batchSize IDs per query
        let cappedIds = Array(ids.prefix(AppConstants.batchSize))
        if ids.count > AppConstants.batchSize {
            logger.info(
                "findByIds truncated from \(ids.count) to \(AppConstants.batchSize) IDs (Rule 7)"
            )
        }

        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Finding \(cappedIds.count) accounts by IDs")

            let placeholders = cappedIds.map { _ in "?" }.joined(separator: ", ")
            let bindings = cappedIds.map { MySQLData(int: Int($0)) }
            let sql = "SELECT \(Self.selectColumns) FROM accounts WHERE id IN (\(placeholders)) ORDER BY id ASC"

            let rows = try await db.query(sql, bindings).get()
            return try rows.map { try AccountRepository.mapRow($0) }
        }
    }

    /// Retrieves paginated accounts belonging to a specific account group.
    ///
    /// Leverages the `idx_accounts_group` index on `account_group_id` for
    /// efficient filtering. Used by entitlement-filtered queries and the
    /// Accounts Viewer.
    ///
    /// - Parameters:
    ///   - groupId: The account group ID to filter by.
    ///   - page: 1-based page number. Values < 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: Array of accounts in the specified group.
    /// - Throws: Database connection or query execution errors.
    public func findByGroupId(
        _ groupId: UInt64,
        page: Int,
        pageSize: Int
    ) async throws -> [Account] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Finding accounts by groupId: \(groupId), page=\(effectivePage), pageSize=\(effectivePageSize)")
            let rows = try await db.query(
                "SELECT \(Self.selectColumns) FROM accounts WHERE account_group_id = ? ORDER BY id ASC LIMIT ? OFFSET ?",
                [
                    MySQLData(int: Int(groupId)),
                    MySQLData(int: effectivePageSize),
                    MySQLData(int: offset),
                ]
            ).get()
            return try rows.map { try AccountRepository.mapRow($0) }
        }
    }

    // MARK: - Cached Valuation Atomic Update (Rule 11 — CRITICAL)

    /// Updates the cached valuation amount and date for a single account.
    ///
    /// **Rule 11 — Cached Valuation Denormalization (CRITICAL)**:
    /// This method MUST be called within an existing transaction. The caller
    /// (``ValuationService``) passes a `MySQLDatabase` connection from an
    /// active transaction context. This ensures the cached valuation update
    /// is committed atomically with the valuation result write:
    ///
    /// ```swift
    /// try await pool.withTransaction { db in
    ///     // 1. Write valuation result
    ///     // 2. Update cached account values atomically
    ///     try await accountRepo.updateCachedValuation(
    ///         accountId: id,
    ///         valuationAmount: amount,
    ///         valueDate: date,
    ///         on: db
    ///     )
    /// }
    /// ```
    ///
    /// Both the valuation write and the cache update commit or rollback
    /// together, maintaining consistency.
    ///
    /// - Parameters:
    ///   - accountId: The account to update.
    ///   - valuationAmount: The computed NAV value (Decimal precision).
    ///   - valueDate: The valuation date (computed using account's timezone).
    ///   - database: A `MySQLDatabase` from an active transaction.
    /// - Throws: Database constraint or execution errors.
    public func updateCachedValuation(
        accountId: UInt64,
        valuationAmount: Decimal,
        valueDate: Date,
        on database: any MySQLDatabase
    ) async throws {
        logger.info("Updating cached valuation for account \(accountId): amount=\(valuationAmount)")

        // Format date as 'YYYY-MM-DD' for MySQL DATE column
        let dateString = AccountRepository.formatDateForMySQL(valueDate)

        _ = try await database.query(
            "UPDATE accounts SET cached_valuation_amount = ?, cached_value_date = ? WHERE id = ?",
            [
                MySQLData(string: "\(valuationAmount)"),
                MySQLData(string: dateString),
                MySQLData(int: Int(accountId)),
            ]
        ).get()

        logger.info("Cached valuation updated for account \(accountId)")
    }

    /// Batch updates cached valuations for multiple accounts within a shared
    /// transaction.
    ///
    /// **Rule 11 + Rule 7**: Updates up to ``AppConstants/batchSize`` (1,000)
    /// accounts per batch within the same transaction context provided by the
    /// caller. All updates share the same transaction — they all commit or
    /// rollback together.
    ///
    /// Each element in the `updates` array contains an `accountId`, the
    /// computed `amount` (Decimal), and the valuation `date`.
    ///
    /// - Parameters:
    ///   - updates: Array of tuples `(accountId, amount, date)` to update.
    ///     Capped at ``AppConstants/batchSize`` (1,000) per call.
    ///   - database: A `MySQLDatabase` from an active transaction.
    /// - Throws: Database constraint or execution errors.
    public func batchUpdateCachedValuations(
        updates: [(accountId: UInt64, amount: Decimal, date: Date)],
        on database: any MySQLDatabase
    ) async throws {
        // Short-circuit: nothing to update
        guard !updates.isEmpty else {
            return
        }

        // Rule 7: Cap at batchSize (1,000) updates per call
        let cappedUpdates = Array(updates.prefix(AppConstants.batchSize))
        if updates.count > AppConstants.batchSize {
            logger.info(
                "Batch cached valuation update truncated from \(updates.count) to \(AppConstants.batchSize) (Rule 7)"
            )
        }

        logger.info("Batch updating cached valuations for \(cappedUpdates.count) accounts")

        // Execute each update on the shared transaction connection
        for update in cappedUpdates {
            let dateString = AccountRepository.formatDateForMySQL(update.date)
            _ = try await database.query(
                "UPDATE accounts SET cached_valuation_amount = ?, cached_value_date = ? WHERE id = ?",
                [
                    MySQLData(string: "\(update.amount)"),
                    MySQLData(string: dateString),
                    MySQLData(int: Int(update.accountId)),
                ]
            ).get()
        }

        logger.info("Batch cached valuation update completed for \(cappedUpdates.count) accounts")
    }

    // MARK: - Private Helpers

    /// Maps a MySQL result row to an ``Account`` model instance.
    ///
    /// Decodes all 11 columns from the `accounts` table into the corresponding
    /// Swift properties. Uses `Decimal` for `cached_valuation_amount` to
    /// maintain financial precision matching MySQL `DECIMAL(20,6)`.
    ///
    /// Handles nullable columns (`ownership_details`, `valuation_schedule`,
    /// `cached_valuation_amount`, `cached_value_date`) by reading through
    /// optional column accessors.
    ///
    /// This method is `static` to allow safe invocation from `@Sendable`
    /// closures passed to the connection pool without capturing `self`.
    ///
    /// - Parameter row: A MySQL result row containing all expected columns.
    /// - Returns: A fully populated ``Account`` instance.
    /// - Throws: ``AppError/accountNotFound`` if required columns are missing
    ///   or cannot be decoded.
    private static func mapRow(_ row: MySQLRow) throws -> Account {
        // Required columns — fail if any is missing
        guard let id = row.column("id")?.uint64,
              let name = row.column("account_name")?.string,
              let fundTypeRaw = row.column("fund_type")?.string,
              let accountGroupId = row.column("account_group_id")?.uint64,
              let valuationTimezone = row.column("valuation_timezone")?.string,
              let statusRaw = row.column("account_status")?.string,
              let createdAt = row.column("created_at")?.date else {
            throw AppError.accountNotFound
        }

        // Parse fund type enum from raw string
        guard let fundType = FundType(rawValue: fundTypeRaw) else {
            throw AppError.accountNotFound
        }

        // Parse account status enum from raw string
        guard let status = AccountStatus(rawValue: statusRaw) else {
            throw AppError.accountNotFound
        }

        // Nullable columns — nil for SQL NULL
        let ownershipDetails = row.column("ownership_details")?.string
        let valuationSchedule = row.column("valuation_schedule")?.string

        // Cached valuation amount: DECIMAL(20,6) → Decimal?
        // MySQLNIO's `.decimal` accessor handles the NEWDECIMAL wire type in the
        // binary protocol, reading the buffer as a string and converting via
        // Decimal(string:). Using `.string` would return nil for NEWDECIMAL
        // columns, silently breaking cached valuation readback (Rule 11).
        let cachedValuationAmount: Decimal? = row.column("cached_valuation_amount")?.decimal

        // Cached value date: DATE → Date?
        let cachedValueDate: Date? = row.column("cached_value_date")?.date

        return Account(
            id: id,
            name: name,
            fundType: fundType,
            ownershipDetails: ownershipDetails,
            valuationTimezone: valuationTimezone,
            valuationSchedule: valuationSchedule,
            cachedValuationAmount: cachedValuationAmount,
            cachedValueDate: cachedValueDate,
            status: status,
            accountGroupId: accountGroupId,
            createdAt: createdAt
        )
    }

    /// Formats a Foundation `Date` as a `YYYY-MM-DD` string for MySQL DATE
    /// columns. Uses UTC calendar for consistent date formatting regardless
    /// of the system timezone.
    ///
    /// This method is `static` to allow safe invocation from any context
    /// without capturing `self`.
    ///
    /// - Parameter date: The date to format.
    /// - Returns: A string in `YYYY-MM-DD` format.
    private static func formatDateForMySQL(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
