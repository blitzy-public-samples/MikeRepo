// Sources/Persistence/Repositories/TransactionRepository.swift
// WealthLedger — Append-Only Transaction Repository (IMMUTABLE)
//
// Provides append-only inserts, offsetting-entry creation for restatements, and
// read queries for the `transactions` MySQL table.  NO UPDATE or DELETE
// statements are permitted on this table (Rule 2 — Transaction Immutability).
//
// Rule 1: Double-entry enforcement is *not* this repository's responsibility
//         (that belongs to DoubleEntryValidator / LedgerService). The repository
//         stores debit_amount and credit_amount as passed in.
// Rule 2: Transaction Immutability — zero UPDATE / DELETE against `transactions`.
//         The `delete(_:)` protocol method throws `AppError.operationNotPermitted`.
// Rule 5: Asset Class Guard — `create(_:)` rejects non-equity asset types.
// Rule 7: Batch Memory Cap — findAll / findByAccountId paginate at 1,000 max.
// Rule 8: MySQLKit-only persistence — NO SwiftData.
// Rule 10: Schema Referential Integrity — FKs enforced at MySQL DDL level.
//
// SPDX-License-Identifier: MIT

import Foundation
import MySQLKit
import MySQLNIO
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - Transaction Model (Persistence-Layer Definition)

/// Immutable ledger entry recording a financial event against an account.
///
/// This struct is defined within the Persistence module because the
/// LedgerEngine module depends on Persistence — not vice versa.  Defining
/// `Transaction` here avoids a circular module dependency
/// (`Persistence → LedgerEngine → Persistence`) while providing a concrete
/// `Entity` type for ``RepositoryProtocol`` conformance.
///
/// The struct mirrors the MySQL `transactions` table schema
/// (`007_create_transactions.sql`) exactly:
///
/// | Swift Property        | MySQL Column          | MySQL Type                     |
/// |-----------------------|-----------------------|--------------------------------|
/// | `id`                  | `id`                  | BIGINT UNSIGNED AUTO_INCREMENT |
/// | `accountId`           | `account_id`          | BIGINT UNSIGNED NOT NULL       |
/// | `instrumentId`        | `instrument_id`       | BIGINT UNSIGNED DEFAULT NULL   |
/// | `quantity`            | `quantity`             | DECIMAL(20,6) NOT NULL         |
/// | `assetType`           | `asset_type`          | ENUM('equity') NOT NULL        |
/// | `ownershipPercentage` | `ownership_pct`       | DECIMAL(10,6) DEFAULT NULL     |
/// | `debitAmount`         | `debit_amount`        | DECIMAL(20,6) NOT NULL         |
/// | `creditAmount`        | `credit_amount`       | DECIMAL(20,6) NOT NULL         |
/// | `restatementRefId`    | `restatement_ref_id`  | BIGINT UNSIGNED DEFAULT NULL   |
/// | `createdAt`           | `created_at`          | TIMESTAMP NOT NULL             |
///
/// ## Rules Compliance
///
/// - **Rule 2 (Transaction Immutability)**: All stored properties are `let`.
///   The struct carries no mutating methods.
/// - **Rule 5 (Asset Class Guard)**: `assetType` is validated before INSERT.
/// - **Rule 8 (MySQLKit-Only)**: Only `Foundation` is imported — no SwiftData.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: All properties are value types,
///   making this struct naturally `Sendable`.
public struct Transaction: Sendable, Equatable, Identifiable {

    // MARK: - Primary Key

    /// Unique identifier for this transaction.
    ///
    /// Maps to `transactions.id` (BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY).
    /// A value of `0` indicates the entity has not yet been persisted; the
    /// database assigns the actual identifier on INSERT.
    public let id: UInt64

    // MARK: - Foreign Keys

    /// The account this transaction is posted against.
    ///
    /// Maps to `transactions.account_id` (BIGINT UNSIGNED NOT NULL,
    /// FK → `accounts.id`).
    public let accountId: UInt64

    /// The instrument (security) involved in this transaction.
    ///
    /// Maps to `transactions.instrument_id` (BIGINT UNSIGNED DEFAULT NULL,
    /// FK → `reference_data.id`). `nil` is acceptable for cash-only entries
    /// that do not reference a specific instrument.
    public let instrumentId: UInt64?

    // MARK: - Financial Fields

    /// Number of units/shares transacted.
    ///
    /// Maps to `transactions.quantity` (DECIMAL(20,6) NOT NULL).
    /// Uses `Decimal` for financial precision — never `Double` or `Float`.
    public let quantity: Decimal

    /// The asset class of the instrument.
    ///
    /// Maps to `transactions.asset_type` (ENUM('equity') NOT NULL).
    /// Per Rule 5, only `"equity"` is permitted.  Validation is enforced
    /// at the repository layer in ``TransactionRepository/create(_:)``.
    public let assetType: String

    /// Ownership percentage for this entry.
    ///
    /// Maps to `transactions.ownership_pct` (DECIMAL(10,6) DEFAULT NULL).
    /// `nil` when ownership is 100 % or not applicable.
    public let ownershipPercentage: Decimal?

    /// Debit component of this double-entry line.
    ///
    /// Maps to `transactions.debit_amount` (DECIMAL(20,6) NOT NULL).
    public let debitAmount: Decimal

    /// Credit component of this double-entry line.
    ///
    /// Maps to `transactions.credit_amount` (DECIMAL(20,6) NOT NULL).
    public let creditAmount: Decimal

    // MARK: - Restatement Support

    /// Reference to the original transaction this entry offsets.
    ///
    /// Maps to `transactions.restatement_ref_id` (BIGINT UNSIGNED DEFAULT NULL,
    /// FK → `transactions.id`). `nil` for original entries; populated for
    /// offsetting restatement entries (Rule 2 correction mechanism).
    public let restatementRefId: UInt64?

    // MARK: - Timestamps

    /// Timestamp when the transaction was recorded.
    ///
    /// Maps to `transactions.created_at` (TIMESTAMP NOT NULL DEFAULT
    /// CURRENT_TIMESTAMP). Set by the database on INSERT.
    public let createdAt: Date

    // MARK: - Initializer

    /// Creates a new transaction instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (0 for new entities before persistence).
    ///   - accountId: The account FK (→ `accounts.id`).
    ///   - instrumentId: The instrument FK (→ `reference_data.id`), or `nil`.
    ///   - quantity: Number of units/shares. Must be `Decimal` for precision.
    ///   - assetType: Asset class string — must be `"equity"` per Rule 5.
    ///   - ownershipPercentage: Ownership percentage, or `nil`.
    ///   - debitAmount: Debit component of the double-entry line.
    ///   - creditAmount: Credit component of the double-entry line.
    ///   - restatementRefId: Original transaction FK for offsets, or `nil`.
    ///   - createdAt: Persistence timestamp. Defaults to current date.
    public init(
        id: UInt64 = 0,
        accountId: UInt64,
        instrumentId: UInt64? = nil,
        quantity: Decimal,
        assetType: String,
        ownershipPercentage: Decimal? = nil,
        debitAmount: Decimal,
        creditAmount: Decimal,
        restatementRefId: UInt64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.quantity = quantity
        self.assetType = assetType
        self.ownershipPercentage = ownershipPercentage
        self.debitAmount = debitAmount
        self.creditAmount = creditAmount
        self.restatementRefId = restatementRefId
        self.createdAt = createdAt
    }
}

// MARK: - TransactionRepository

/// Repository for the `transactions` MySQL table providing **append-only**
/// inserts, offsetting-entry creation for restatements, and paginated read
/// queries.
///
/// ``TransactionRepository`` is the most constrained repository in the system.
/// **No UPDATE or DELETE statements may target the `transactions` table**
/// (Rule 2 — Transaction Immutability).  Corrections are performed exclusively
/// through offsetting entries that reference the original transaction via a
/// self-referencing foreign key (`restatement_ref_id`).
///
/// ## Rules Compliance
///
/// - **Rule 2 (Transaction Immutability)**: ``create(_:)`` is the **only**
///   write operation.  ``delete(_:)`` is implemented solely for
///   ``RepositoryProtocol`` conformance and always throws
///   ``AppError/operationNotPermitted``.  There is **no** `update()` method.
///   There are **zero** `UPDATE transactions` or `DELETE FROM transactions`
///   SQL strings anywhere in this file.
/// - **Rule 5 (Asset Class Guard)**: ``create(_:)`` validates that
///   `assetType` is `"equity"` before any INSERT.  Non-equity types are
///   rejected with ``AppError/invalidAssetClass`` and zero database writes.
/// - **Rule 7 (Batch Memory Cap)**: ``findAll(page:pageSize:)`` and
///   ``findByAccountId(_:page:pageSize:)`` enforce a maximum page size of
///   ``AppConstants/defaultPagination`` (1,000).
/// - **Rule 8 (MySQLKit-Only)**: All queries use MySQLKit / SQLKit.  No SwiftData.
/// - **Rule 10 (Schema Referential Integrity)**: FK constraints on
///   `account_id`, `instrument_id`, and `restatement_ref_id` are enforced at
///   the MySQL DDL level; the repository delegates FK validation to the
///   database engine.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: This is a `final class` with
///   only immutable `let` stored properties of `Sendable` types
///   (`ConnectionPool` is an actor; `Logger` is `Sendable`).  Conforms to
///   `Sendable` transitively via ``RepositoryProtocol``.
public final class TransactionRepository: RepositoryProtocol {

    // MARK: - Associated Types

    /// The entity type managed by this repository.
    public typealias Entity = Transaction

    /// The primary key type for transactions.
    public typealias EntityID = UInt64

    // MARK: - Properties

    /// AsyncKit-based connection pool for executing all database queries.
    /// Injected via constructor for dependency injection and testability.
    private let pool: ConnectionPool

    /// Structured logger for repository lifecycle events, including asset
    /// class guard rejections (Rule 5), restatement audit trail entries,
    /// query execution tracing, and error diagnostics.
    private let logger: Logger

    // MARK: - Constants

    /// Set of valid asset type strings accepted by ``create(_:)``.
    /// Any asset type not in this set is rejected per Rule 5 (Asset Class Guard).
    private static let validAssetTypes: Set<String> = ["equity"]

    /// Standard SELECT column list for the `transactions` table.
    /// Centralised here to guarantee consistent column ordering across all
    /// query methods and to avoid typos in repeated SQL fragments.
    private static let selectColumns: String =
        "id, account_id, instrument_id, quantity, asset_type, ownership_pct, debit_amount, credit_amount, restatement_ref_id, created_at"

    // MARK: - Initializer

    /// Creates a new transaction repository backed by the given connection pool.
    ///
    /// - Parameters:
    ///   - pool: The ``ConnectionPool`` actor providing managed MySQL connections.
    ///   - logger: Structured logger.  Defaults to label
    ///     `"persistence.transaction-repository"`.
    public init(
        pool: ConnectionPool,
        logger: Logger = Logger(label: "persistence.transaction-repository")
    ) {
        self.pool = pool
        self.logger = logger
    }

    // MARK: - RepositoryProtocol — Read Operations

    /// Retrieves a single transaction by its primary key.
    ///
    /// Executes a parameterised `SELECT` against `transactions.id`.  Returns
    /// `nil` when no row matches — this is not treated as an error condition.
    ///
    /// - Parameter id: The transaction's primary key.
    /// - Returns: The matching ``Transaction``, or `nil` if not found.
    /// - Throws: Database connection or query execution errors.
    public func findById(_ id: UInt64) async throws -> Transaction? {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM transactions WHERE id = \(bind: id)"
            ).all()
            guard let row = rows.first else {
                return nil
            }
            return try self.mapRow(row)
        }
    }

    /// Retrieves a paginated list of transactions ordered by primary key.
    ///
    /// Enforces Rule 7 (Batch Memory Cap) by capping `pageSize` at
    /// ``AppConstants/defaultPagination`` (1,000).  Pages are 1-based:
    /// page 1 returns the first `pageSize` records.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Values below 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: An array of transactions for the requested page, or an empty
    ///   array if the page is beyond available data.
    /// - Throws: Database connection or query execution errors.
    public func findAll(page: Int, pageSize: Int) async throws -> [Transaction] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize

        return try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM transactions ORDER BY id LIMIT \(bind: effectivePageSize) OFFSET \(bind: offset)"
            ).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    // MARK: - RepositoryProtocol — Write Operations

    /// Creates a new transaction in the database.
    ///
    /// **This is the ONLY write operation permitted on the `transactions`
    /// table** (Rule 2 — Transaction Immutability).
    ///
    /// **Rule 5 — Asset Class Guard**: Before any database write, this method
    /// validates that `entity.assetType` is an allowed equity type.  If the
    /// asset type is not `"equity"`, the method throws
    /// ``AppError/invalidAssetClass`` with zero database writes.
    ///
    /// The method executes the INSERT and retrieves the auto-generated primary
    /// key via `LAST_INSERT_ID()` on the same connection to guarantee correctness.
    ///
    /// FK constraints on `account_id` → `accounts.id`, `instrument_id` →
    /// `reference_data.id`, and `restatement_ref_id` → `transactions.id` are
    /// enforced by the MySQL schema (Rule 10).
    ///
    /// - Parameter entity: The transaction to insert.  The `id` field is
    ///   ignored; the database assigns the identifier.
    /// - Returns: The created transaction with the auto-generated `id` populated.
    /// - Throws: ``AppError/invalidAssetClass`` for non-equity asset types,
    ///   or database constraint / connection errors.
    public func create(_ entity: Transaction) async throws -> Transaction {
        // Rule 5: Asset Class Guard — equities only.
        guard Self.validAssetTypes.contains(entity.assetType.lowercased()) else {
            logger.warning(
                "Asset class guard rejected non-equity type: '\(entity.assetType)' for account \(entity.accountId)"
            )
            throw AppError.invalidAssetClass
        }

        // Capture all values for Sendable closure
        let accountId = entity.accountId
        let instrumentId = entity.instrumentId
        let quantity = entity.quantity
        let assetType = entity.assetType
        let ownershipPercentage = entity.ownershipPercentage
        let debitAmount = entity.debitAmount
        let creditAmount = entity.creditAmount
        let restatementRefId = entity.restatementRefId

        return try await pool.withConnection { db in
            let sqlDb = db.sql()

            // Build the INSERT query with proper NULL handling for
            // optional columns: instrument_id, ownership_pct, restatement_ref_id
            var query: SQLQueryString = "INSERT INTO transactions (account_id, instrument_id, quantity, asset_type, ownership_pct, debit_amount, credit_amount, restatement_ref_id) VALUES ("
            query += "\(bind: accountId), "

            if let instrId = instrumentId {
                query += "\(bind: instrId), "
            } else {
                query += "NULL, "
            }

            query += "\(bind: quantity), "
            query += "\(bind: assetType), "

            if let ownPct = ownershipPercentage {
                query += "\(bind: ownPct), "
            } else {
                query += "NULL, "
            }

            query += "\(bind: debitAmount), "
            query += "\(bind: creditAmount), "

            if let restRefId = restatementRefId {
                query += "\(bind: restRefId)"
            } else {
                query += "NULL"
            }

            query += ")"

            try await sqlDb.raw(query).run()

            // Retrieve the auto-generated primary key on the same connection
            let idRows = try await sqlDb.raw(
                "SELECT LAST_INSERT_ID() AS insert_id"
            ).all()
            guard let idRow = idRows.first else {
                throw AppError.operationNotPermitted
            }
            let newId = try idRow.decode(column: "insert_id", as: UInt64.self)

            return Transaction(
                id: newId,
                accountId: accountId,
                instrumentId: instrumentId,
                quantity: quantity,
                assetType: assetType,
                ownershipPercentage: ownershipPercentage,
                debitAmount: debitAmount,
                creditAmount: creditAmount,
                restatementRefId: restatementRefId,
                createdAt: Date()
            )
        }
    }

    /// Throws ``AppError/operationNotPermitted`` — transaction deletion is
    /// **not permitted** (Rule 2 — Transaction Immutability).
    ///
    /// This method exists solely to satisfy the ``RepositoryProtocol``
    /// conformance requirement.  It **never** executes a SQL statement against
    /// the `transactions` table.  Corrections must use offsetting entries via
    /// ``createRestatement(originalTransactionId:offsettingEntry:)``.
    ///
    /// - Parameter id: Ignored — the method always throws.
    /// - Throws: ``AppError/operationNotPermitted`` unconditionally.
    public func delete(_ id: UInt64) async throws {
        logger.warning(
            "Attempted to delete transaction \(id) — operation not permitted (Rule 2 — Transaction Immutability)"
        )
        throw AppError.operationNotPermitted
    }

    // MARK: - Domain-Specific Read Operations

    /// Retrieves paginated transaction history for a single account.
    ///
    /// Results are ordered by `created_at DESC` (newest first) and leverage
    /// the `idx_transactions_account` index from migration 008 for
    /// performance.
    ///
    /// Enforces Rule 7 (Batch Memory Cap) by capping `pageSize` at
    /// ``AppConstants/defaultPagination`` (1,000).
    ///
    /// - Parameters:
    ///   - accountId: The account's primary key.
    ///   - page: 1-based page number. Values below 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: Paginated transaction history for the account, or an empty
    ///   array if no transactions exist or the page is beyond available data.
    /// - Throws: Database connection or query execution errors.
    public func findByAccountId(
        _ accountId: UInt64,
        page: Int,
        pageSize: Int
    ) async throws -> [Transaction] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize

        return try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM transactions WHERE account_id = \(bind: accountId) ORDER BY created_at DESC LIMIT \(bind: effectivePageSize) OFFSET \(bind: offset)"
            ).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    /// Creates an offsetting entry that references the original transaction.
    ///
    /// **This is the ONLY way to "correct" a transaction** (Rule 2).
    /// The original transaction remains untouched in the ledger.  The
    /// offsetting entry's debit/credit amounts should negate the original
    /// (that logic is handled by `LedgerService` before calling this method).
    ///
    /// Steps:
    /// 1. Verify the original transaction exists.
    /// 2. Create the offsetting entry with `restatementRefId` set to the
    ///    original transaction's `id`.
    /// 3. Log the restatement for audit trail purposes.
    ///
    /// - Parameters:
    ///   - originalTransactionId: The primary key of the transaction to offset.
    ///   - offsettingEntry: The new transaction entry with negated amounts.
    ///     Its `restatementRefId` will be overridden to point to the original.
    /// - Returns: The persisted offsetting transaction with auto-generated `id`.
    /// - Throws: ``AppError/accountNotFound`` if the original transaction does
    ///   not exist, or database constraint / connection errors.
    public func createRestatement(
        originalTransactionId: UInt64,
        offsettingEntry: Transaction
    ) async throws -> Transaction {
        // 1. Verify the original transaction exists
        guard let original = try await findById(originalTransactionId) else {
            logger.warning(
                "Restatement failed — original transaction \(originalTransactionId) not found"
            )
            throw AppError.accountNotFound
        }

        // 2. Build the offsetting entry with the correct restatement reference
        let entryWithRef = Transaction(
            id: 0,
            accountId: offsettingEntry.accountId,
            instrumentId: offsettingEntry.instrumentId,
            quantity: offsettingEntry.quantity,
            assetType: offsettingEntry.assetType,
            ownershipPercentage: offsettingEntry.ownershipPercentage,
            debitAmount: offsettingEntry.debitAmount,
            creditAmount: offsettingEntry.creditAmount,
            restatementRefId: originalTransactionId,
            createdAt: Date()
        )

        // 3. Persist via the standard create path (which enforces Rule 5)
        let persisted = try await create(entryWithRef)

        logger.info(
            "Restatement created: new transaction \(persisted.id) offsets original \(original.id) for account \(original.accountId)"
        )

        return persisted
    }

    /// Retrieves all offsetting entries that reference a given original
    /// transaction.
    ///
    /// Results are ordered by `created_at ASC` (oldest first) so that the
    /// chronological sequence of restatements is preserved.
    ///
    /// - Parameter originalId: The primary key of the original transaction.
    /// - Returns: All offsetting entries for the original, or an empty array
    ///   if no restatements have been posted.
    /// - Throws: Database connection or query execution errors.
    public func findRestatements(
        forTransactionId originalId: UInt64
    ) async throws -> [Transaction] {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM transactions WHERE restatement_ref_id = \(bind: originalId) ORDER BY created_at"
            ).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    /// Returns the number of transactions for a specific account.
    ///
    /// Leverages the `idx_transactions_account` index for performance.
    ///
    /// - Parameter accountId: The account's primary key.
    /// - Returns: The total transaction count for the account.
    /// - Throws: Database connection or query execution errors.
    public func countByAccountId(_ accountId: UInt64) async throws -> Int {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT COUNT(*) AS cnt FROM transactions WHERE account_id = \(bind: accountId)"
            ).all()
            guard let row = rows.first else {
                return 0
            }
            return try row.decode(column: "cnt", as: Int.self)
        }
    }

    /// Returns the total number of transactions across all accounts.
    ///
    /// - Returns: The total transaction count.
    /// - Throws: Database connection or query execution errors.
    public func count() async throws -> Int {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT COUNT(*) AS cnt FROM transactions"
            ).all()
            guard let row = rows.first else {
                return 0
            }
            return try row.decode(column: "cnt", as: Int.self)
        }
    }

    // MARK: - Private Helpers

    /// Maps a SQL result row to a ``Transaction`` model instance.
    ///
    /// Decodes all ten columns from the `transactions` table into the
    /// corresponding Swift properties.  Nullable columns (`instrument_id`,
    /// `ownership_pct`, `restatement_ref_id`) are decoded as optionals.
    /// All financial fields use `Decimal` to preserve precision.
    ///
    /// - Parameter row: A SQL result row from a `transactions` table query.
    /// - Returns: A fully populated ``Transaction`` instance.
    /// - Throws: Decoding errors if a column is missing or has an
    ///   incompatible type.
    private func mapRow(_ row: any SQLRow) throws -> Transaction {
        Transaction(
            id: try row.decode(column: "id", as: UInt64.self),
            accountId: try row.decode(column: "account_id", as: UInt64.self),
            instrumentId: try row.decode(column: "instrument_id", as: UInt64?.self),
            quantity: try row.decode(column: "quantity", as: Decimal.self),
            assetType: try row.decode(column: "asset_type", as: String.self),
            ownershipPercentage: try row.decode(column: "ownership_pct", as: Decimal?.self),
            debitAmount: try row.decode(column: "debit_amount", as: Decimal.self),
            creditAmount: try row.decode(column: "credit_amount", as: Decimal.self),
            restatementRefId: try row.decode(column: "restatement_ref_id", as: UInt64?.self),
            createdAt: try row.decode(column: "created_at", as: Date.self)
        )
    }
}
