// Sources/Persistence/Repositories/PositionRepository.swift
// WealthLedger — Position Table CRUD Repository with Asset Class Guard
//
// Provides CRUD operations for the `positions` MySQL table with foreign key
// enforcement to `accounts` and `reference_data` tables, and asset type
// validation enforcing the equities-only constraint (Rule 5) at the
// application layer. Used by LedgerService for position management and
// ValuationService for loading account positions during NAV calculation.
//
// SPDX-License-Identifier: MIT

import Foundation
import MySQLKit
import MySQLNIO
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - Position Model (Persistence-Layer Definition)

/// Represents an account's holding of a specific instrument.
///
/// This struct is defined within the Persistence module because the
/// LedgerEngine module depends on Persistence — not vice versa. Defining
/// Position here avoids a circular module dependency while providing a
/// concrete `Entity` type for ``RepositoryProtocol`` conformance.
///
/// The struct mirrors the MySQL `positions` table schema exactly:
///
/// | Swift Property  | MySQL Column      | MySQL Type                     |
/// |-----------------|-------------------|--------------------------------|
/// | `id`            | `id`              | BIGINT UNSIGNED AUTO_INCREMENT |
/// | `accountId`     | `account_id`      | BIGINT UNSIGNED NOT NULL       |
/// | `instrumentId`  | `instrument_id`   | BIGINT UNSIGNED NOT NULL       |
/// | `quantity`       | `quantity`         | DECIMAL(20,6) NOT NULL         |
/// | `assetType`     | `asset_type`      | ENUM('equity') NOT NULL        |
///
/// ## Rules Compliance
///
/// - **Rule 5 (Asset Class Guard)**: `assetType` is validated before INSERT.
/// - **Rule 8 (MySQLKit-Only)**: Only `Foundation` is imported — no SwiftData.
/// - **Rule 10 (Schema Referential Integrity)**: Foreign keys to `accounts`
///   and `reference_data` are enforced at the MySQL DDL level.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: All stored properties are value
///   types, making this struct naturally `Sendable`.
public struct Position: Sendable, Equatable, Identifiable {

    // MARK: - Primary Key

    /// Unique identifier for this position.
    ///
    /// Maps to `positions.id` (BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY).
    /// A value of `0` indicates the entity has not yet been persisted; the
    /// database assigns the actual identifier on INSERT.
    public let id: UInt64

    // MARK: - Foreign Keys

    /// The account that holds this position.
    ///
    /// Maps to `positions.account_id` (BIGINT UNSIGNED NOT NULL, FK → `accounts.id`).
    public let accountId: UInt64

    /// The instrument (security) this position represents.
    ///
    /// Maps to `positions.instrument_id` (BIGINT UNSIGNED NOT NULL,
    /// FK → `reference_data.id`). Used by ValuationEngine to look up EOD
    /// bid/ask prices for NAV calculation.
    public let instrumentId: UInt64

    // MARK: - Financial Fields

    /// Number of units or shares held in this position.
    ///
    /// Maps to `positions.quantity` (DECIMAL(20,6) NOT NULL DEFAULT 0.000000).
    /// Uses `Decimal` (not `Double` or `Float`) to avoid floating-point
    /// rounding errors unacceptable in accounting calculations.
    public let quantity: Decimal

    // MARK: - Asset Classification

    /// The asset class of the instrument held in this position.
    ///
    /// Maps to `positions.asset_type` (ENUM('equity') NOT NULL DEFAULT 'equity').
    /// Per Rule 5, only `"equity"` is permitted. Validation is enforced at the
    /// repository layer in ``PositionRepository/create(_:)``.
    public let assetType: String

    // MARK: - Initializer

    /// Creates a new position instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (0 for new entities).
    ///   - accountId: The owning account's identifier (FK → `accounts.id`).
    ///   - instrumentId: The instrument identifier (FK → `reference_data.id`).
    ///   - quantity: Number of units/shares held. Must use `Decimal` for
    ///     financial precision.
    ///   - assetType: The asset class — must be `"equity"` per Rule 5.
    public init(
        id: UInt64,
        accountId: UInt64,
        instrumentId: UInt64,
        quantity: Decimal,
        assetType: String
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.quantity = quantity
        self.assetType = assetType
    }
}

// MARK: - PositionRepository

/// Repository for the `positions` MySQL table providing CRUD operations with
/// foreign key enforcement and asset class validation.
///
/// ``PositionRepository`` is the data-access layer for all position-related
/// persistence. It is consumed by:
/// - ``LedgerService`` — to create, update, and query positions when
///   processing buy/sell transactions.
/// - ``ValuationService`` — to load all positions for an account (or batch
///   of accounts) during NAV calculation.
///
/// ## Rules Compliance
///
/// - **Rule 5 (Asset Class Guard)**: ``create(_:)`` validates that
///   `assetType` is `"equity"` before any INSERT. Non-equity types are
///   rejected with ``AppError/invalidAssetClass`` and zero database writes.
/// - **Rule 7 (Batch Memory Cap)**: ``findAll(page:pageSize:)`` enforces a
///   maximum page size of ``AppConstants/defaultPagination`` (1,000).
///   ``findByAccountIds(_:)`` limits input to ``AppConstants/batchSize``
///   (1,000) account IDs per query.
/// - **Rule 8 (MySQLKit-Only)**: All queries use MySQLKit/SQLKit. No SwiftData.
/// - **Rule 10 (Schema Referential Integrity)**: FK constraints on `account_id`
///   and `instrument_id` are enforced at the MySQL DDL level; the repository
///   delegates FK validation to the database engine.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: This is a `final class` with
///   only immutable `let` stored properties of `Sendable` types (`ConnectionPool`
///   is an actor; `Logger` is `Sendable`). Conforms to `Sendable` transitively
///   via ``RepositoryProtocol``.
public final class PositionRepository: RepositoryProtocol {

    // MARK: - Associated Types

    /// The entity type managed by this repository.
    public typealias Entity = Position

    /// The primary key type for positions.
    public typealias EntityID = UInt64

    // MARK: - Properties

    /// AsyncKit-based connection pool for executing all database queries.
    /// Injected via constructor for dependency injection and testability.
    private let pool: ConnectionPool

    /// Structured logger for repository lifecycle events, including asset
    /// class validation rejections (Rule 5), query execution tracing, batch
    /// operation progress, and error diagnostics.
    private let logger: Logger

    // MARK: - Constants

    /// Set of valid asset type strings accepted by the ``create(_:)`` method.
    /// Any asset type not in this set is rejected per Rule 5 (Asset Class Guard).
    private static let validAssetTypes: Set<String> = ["equity"]

    /// Standard SELECT column list for the `positions` table.
    /// Centralised here to guarantee consistent column ordering across all
    /// query methods and to avoid typos in repeated SQL fragments.
    private static let selectColumns: String =
        "id, account_id, instrument_id, quantity, asset_type"

    // MARK: - Initializer

    /// Creates a new position repository backed by the given connection pool.
    ///
    /// - Parameters:
    ///   - pool: The ``ConnectionPool`` actor providing managed MySQL connections.
    ///   - logger: Structured logger. Defaults to label `"persistence.position-repository"`.
    public init(
        pool: ConnectionPool,
        logger: Logger = Logger(label: "persistence.position-repository")
    ) {
        self.pool = pool
        self.logger = logger
    }

    // MARK: - RepositoryProtocol — Read Operations

    /// Retrieves a single position by its primary key.
    ///
    /// Executes a parameterised `SELECT` against `positions.id`. Returns `nil`
    /// when no row matches — this is not treated as an error condition.
    ///
    /// - Parameter id: The position's primary key.
    /// - Returns: The matching ``Position``, or `nil` if not found.
    /// - Throws: Database connection or query execution errors.
    public func findById(_ id: UInt64) async throws -> Position? {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM positions WHERE id = \(bind: id)"
            ).all()
            guard let row = rows.first else {
                return nil
            }
            return try self.mapRow(row)
        }
    }

    /// Retrieves a paginated list of positions ordered by primary key.
    ///
    /// Enforces Rule 7 (Batch Memory Cap) by capping `pageSize` at
    /// ``AppConstants/defaultPagination`` (1,000). Pages are 1-based:
    /// page 1 returns the first `pageSize` records.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Values below 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Clamped to [1, 1000].
    /// - Returns: An array of positions for the requested page, or an empty
    ///   array if the page is beyond available data.
    /// - Throws: Database connection or query execution errors.
    public func findAll(page: Int, pageSize: Int) async throws -> [Position] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize

        return try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM positions ORDER BY id LIMIT \(bind: effectivePageSize) OFFSET \(bind: offset)"
            ).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    // MARK: - RepositoryProtocol — Write Operations

    /// Creates a new position in the database.
    ///
    /// **Rule 5 — Asset Class Guard**: Before any database write, this method
    /// validates that `entity.assetType` is an allowed equity type. If the
    /// asset type is not `"equity"`, the method throws
    /// ``AppError/invalidAssetClass`` with zero database writes.
    ///
    /// The method executes the INSERT and retrieves the auto-generated primary
    /// key via `LAST_INSERT_ID()` on the same connection to guarantee correctness.
    ///
    /// FK constraints on `account_id` → `accounts.id` and `instrument_id` →
    /// `reference_data.id` are enforced by the MySQL schema (Rule 10).
    ///
    /// - Parameter entity: The position to insert. The `id` field is ignored;
    ///   the database assigns the identifier.
    /// - Returns: The created position with the auto-generated `id` populated.
    /// - Throws: ``AppError/invalidAssetClass`` for non-equity asset types,
    ///   or database constraint/connection errors.
    public func create(_ entity: Position) async throws -> Position {
        // Rule 5: Asset Class Guard — equities only.
        // This is the repository-layer second line of defense after the service layer.
        guard Self.validAssetTypes.contains(entity.assetType.lowercased()) else {
            logger.warning(
                "Asset class guard rejected non-equity type: '\(entity.assetType)' for account \(entity.accountId)"
            )
            throw AppError.invalidAssetClass
        }

        let accountId = entity.accountId
        let instrumentId = entity.instrumentId
        let quantity = entity.quantity
        let assetType = entity.assetType

        return try await pool.withConnection { db in
            let sqlDb = db.sql()

            // INSERT the new position row
            try await sqlDb.raw(
                "INSERT INTO positions (account_id, instrument_id, quantity, asset_type) VALUES (\(bind: accountId), \(bind: instrumentId), \(bind: quantity), \(bind: assetType))"
            ).run()

            // Retrieve the auto-generated primary key on the same connection
            let idRows = try await sqlDb.raw(
                "SELECT LAST_INSERT_ID() AS insert_id"
            ).all()
            guard let idRow = idRows.first else {
                throw AppError.operationNotPermitted
            }
            let newId = try idRow.decode(column: "insert_id", as: UInt64.self)

            return Position(
                id: newId,
                accountId: accountId,
                instrumentId: instrumentId,
                quantity: quantity,
                assetType: assetType
            )
        }

    }

    /// Deletes a position by its primary key.
    ///
    /// Executes `DELETE FROM positions WHERE id = ?`. If no row matches the
    /// given identifier, the operation completes silently (no error).
    ///
    /// - Parameter id: The primary key of the position to delete.
    /// - Throws: FK constraint violations or database connection errors.
    public func delete(_ id: UInt64) async throws {
        try await pool.withConnection { db in
            try await db.sql().raw(
                "DELETE FROM positions WHERE id = \(bind: id)"
            ).run()
        }
    }

    // MARK: - Domain-Specific Query Methods

    /// Retrieves all positions for a single account.
    ///
    /// This is the **primary method for ValuationEngine** — loads positions
    /// held by an account for NAV calculation:
    /// `Σ(quantity × EOD midpoint) + cash_balance`.
    ///
    /// Results are ordered by `instrument_id` for deterministic output and
    /// capped at ``AppConstants/defaultPagination`` (1,000) records as a
    /// defensive guard (Rule 7 — Batch Memory Cap).
    /// The query leverages the `idx_positions_account` index from migration 008.
    ///
    /// - Parameter accountId: The owning account's primary key.
    /// - Returns: All positions for the account, or an empty array if none exist.
    /// - Throws: Database connection or query execution errors.
    public func findByAccountId(_ accountId: UInt64) async throws -> [Position] {
        let limit = AppConstants.defaultPagination
        return try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM positions WHERE account_id = \(bind: accountId) ORDER BY instrument_id LIMIT \(bind: limit)"
            ).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    /// Retrieves positions for multiple accounts in a single query.
    ///
    /// **Used for batch valuation** — loads positions for up to
    /// ``AppConstants/batchSize`` (1,000) accounts in one database round-trip.
    /// If more than 1,000 account IDs are provided, only the first 1,000 are
    /// queried (Rule 7 enforcement).
    ///
    /// Results are ordered by `account_id, instrument_id` so that positions
    /// for each account appear contiguously, enabling efficient grouping by
    /// the calling service.
    ///
    /// - Parameter accountIds: Array of account primary keys to query.
    /// - Returns: All positions for the specified accounts. Returns an empty
    ///   array if `accountIds` is empty or no positions exist.
    /// - Throws: Database connection or query execution errors.
    public func findByAccountIds(_ accountIds: [UInt64]) async throws -> [Position] {
        guard !accountIds.isEmpty else {
            return []
        }

        // Rule 7: Limit to batchSize account IDs per query
        let limitedIds = Array(accountIds.prefix(AppConstants.batchSize))
        if accountIds.count > AppConstants.batchSize {
            logger.info(
                "Batch position query truncated from \(accountIds.count) to \(AppConstants.batchSize) account IDs (Rule 7)"
            )
        }

        return try await pool.withConnection { db in
            let sqlDb = db.sql()

            // Build parameterised IN clause dynamically
            var query: SQLQueryString = "SELECT \(unsafeRaw: Self.selectColumns) FROM positions WHERE account_id IN ("
            for (index, accountId) in limitedIds.enumerated() {
                if index > 0 {
                    query += ","
                }
                query += "\(bind: accountId)"
            }
            query += ") ORDER BY account_id, instrument_id"

            let rows = try await sqlDb.raw(query).all()
            return try rows.map { try self.mapRow($0) }
        }
    }

    /// Retrieves a position for a specific account and instrument combination.
    ///
    /// Uses the unique key `uk_positions_account_instrument (account_id, instrument_id)`
    /// from migration 006 for efficient single-row lookup.
    ///
    /// **Used by LedgerService** to check whether a position already exists
    /// before creating a new one or updating an existing position's quantity
    /// (e.g., additional buy transaction for the same instrument).
    ///
    /// - Parameters:
    ///   - accountId: The owning account's primary key.
    ///   - referenceDataId: The instrument's primary key (FK → `reference_data.id`).
    /// - Returns: The matching position, or `nil` if no position exists for
    ///   this account–instrument pair.
    /// - Throws: Database connection or query execution errors.
    public func findByAccountAndInstrument(
        accountId: UInt64,
        referenceDataId: UInt64
    ) async throws -> Position? {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT \(unsafeRaw: Self.selectColumns) FROM positions WHERE account_id = \(bind: accountId) AND instrument_id = \(bind: referenceDataId)"
            ).all()
            guard let row = rows.first else {
                return nil
            }
            return try self.mapRow(row)
        }
    }

    /// Updates the quantity of an existing position.
    ///
    /// Executes `UPDATE positions SET quantity = ? WHERE id = ?`. This method
    /// uses `Decimal` for the quantity parameter to maintain financial precision
    /// matching the MySQL `DECIMAL(20,6)` column type.
    ///
    /// Used when adding to an existing position (e.g., a subsequent buy
    /// transaction for the same instrument in the same account).
    ///
    /// - Parameters:
    ///   - id: The position's primary key.
    ///   - quantity: The new quantity value.
    /// - Throws: Database connection or query execution errors.
    public func updateQuantity(id: UInt64, quantity: Decimal) async throws {
        try await pool.withConnection { db in
            try await db.sql().raw(
                "UPDATE positions SET quantity = \(bind: quantity) WHERE id = \(bind: id)"
            ).run()
        }
    }

    /// Deletes all positions for a given account.
    ///
    /// Executes `DELETE FROM positions WHERE account_id = ?`. Used in account
    /// cleanup scenarios where all holdings must be removed.
    ///
    /// - Parameter accountId: The account whose positions should be deleted.
    /// - Throws: FK constraint violations or database connection errors.
    public func deleteByAccountId(_ accountId: UInt64) async throws {
        try await pool.withConnection { db in
            try await db.sql().raw(
                "DELETE FROM positions WHERE account_id = \(bind: accountId)"
            ).run()
        }
    }

    /// Returns the total number of positions across all accounts.
    ///
    /// Executes `SELECT COUNT(*) FROM positions`.
    ///
    /// - Returns: The total position count.
    /// - Throws: Database connection or query execution errors.
    public func count() async throws -> Int {
        try await pool.withConnection { db in
            let rows = try await db.sql().raw(
                "SELECT COUNT(*) AS cnt FROM positions"
            ).all()
            guard let row = rows.first else {
                return 0
            }
            return try row.decode(column: "cnt", as: Int.self)
        }
    }

    // MARK: - Private Helpers

    /// Maps a SQL result row to a ``Position`` model instance.
    ///
    /// Decodes all five columns from the `positions` table into the
    /// corresponding Swift properties. Uses `Decimal` for the `quantity`
    /// column to preserve financial precision.
    ///
    /// - Parameter row: A SQL result row from a `positions` table query.
    /// - Returns: A fully populated ``Position`` instance.
    /// - Throws: Decoding errors if a column is missing or has an
    ///   incompatible type.
    private func mapRow(_ row: any SQLRow) throws -> Position {
        Position(
            id: try row.decode(column: "id", as: UInt64.self),
            accountId: try row.decode(column: "account_id", as: UInt64.self),
            instrumentId: try row.decode(column: "instrument_id", as: UInt64.self),
            quantity: try row.decode(column: "quantity", as: Decimal.self),
            assetType: try row.decode(column: "asset_type", as: String.self)
        )
    }
}
