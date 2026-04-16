// Sources/Persistence/Repositories/AccountGroupRepository.swift
// WealthLedger — Account Group Repository for MySQL account_groups Table
//
// Provides full CRUD operations for the account_groups table, including paginated
// listing, exact name lookup for duplicate validation, batch ID lookup for
// entitlement resolution, and total count. Used by AccountGroupService in the
// AccountManagement module and referenced by AdminView for group management.
//
// Rule 7: Batch memory cap — findAll pagination capped at 1,000.
// Rule 8: MySQLKit-only persistence — NO SwiftData.
// Rule 10: Schema referential integrity — account_groups has typed PK,
//          referenced by accounts and entitlements via FK.
//
// SPDX-License-Identifier: MIT

import Foundation
import MySQLKit
import MySQLNIO
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - AccountGroup Model

/// Account group data model for organizing accounts into logical groupings.
///
/// Maps directly to the MySQL `account_groups` table defined in migration
/// `Resources/Migrations/002_create_account_groups.sql`.
///
/// This struct is defined in the Persistence module to enable `AccountGroupRepository`
/// to implement `RepositoryProtocol` with concrete type binding, since the
/// Persistence module cannot import AccountManagement (which would create a circular
/// dependency: AccountManagement → Persistence → AccountManagement).
///
/// ## MySQL Column Mapping
///
/// | Swift Property | MySQL Column | MySQL Type                                     |
/// |----------------|--------------|------------------------------------------------|
/// | `id`           | `id`         | `BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY`   |
/// | `groupName`    | `group_name` | `VARCHAR(255) NOT NULL`                        |
/// | `metadata`     | `metadata`   | `JSON DEFAULT NULL`                            |
/// | `createdAt`    | `created_at` | `TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP` |
///
/// ## Sendable Safety
///
/// All stored properties are immutable `let` values of `Sendable`-conforming types
/// (`UInt64`, `String`, `String?`, `Date`). Automatic `Sendable` conformance is safe.
public struct AccountGroup: Sendable, Equatable, Hashable, Codable {

    /// Unique identifier for the account group (MySQL BIGINT UNSIGNED AUTO_INCREMENT).
    public let id: UInt64

    /// Human-readable name of the account group.
    ///
    /// Maps to `group_name VARCHAR(255) NOT NULL`. Examples: "US Equity Funds",
    /// "European SMAs", "Hedge Fund Portfolio". Used in RBAC entitlement assignment
    /// and search filtering.
    public let groupName: String

    /// Optional JSON metadata for flexible group-level attributes.
    ///
    /// Maps to `metadata JSON DEFAULT NULL`. Stored as an optional `String`;
    /// the MySQL column accepts JSON-formatted text. When `nil`, no metadata
    /// is associated with the group.
    public let metadata: String?

    /// Timestamp indicating when the account group was created.
    ///
    /// Maps to `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`.
    /// Populated by MySQL on insert when not explicitly provided.
    public let createdAt: Date

    /// Creates a new `AccountGroup` instance with the specified properties.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (MySQL BIGINT UNSIGNED).
    ///   - groupName: Human-readable name of the account group.
    ///   - metadata: Optional JSON string containing group metadata.
    ///   - createdAt: Timestamp of when the group was created.
    public init(
        id: UInt64,
        groupName: String,
        metadata: String?,
        createdAt: Date
    ) {
        self.id = id
        self.groupName = groupName
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

// MARK: - AccountGroupRepositoryProtocol

/// Protocol defining the methods that ``EntitlementService`` requires from an
/// account group data access layer.
///
/// This protocol enables dependency injection and testability: production code
/// uses ``AccountGroupRepository`` (backed by MySQL), while unit tests inject
/// lightweight mock implementations with zero database connections.
///
/// Inherits ``Sendable`` to satisfy Swift 6 strict concurrency requirements
/// when stored as `any AccountGroupRepositoryProtocol` in a `Sendable` class.
public protocol AccountGroupRepositoryProtocol: Sendable {

    /// Finds multiple account groups by their primary key IDs.
    /// Returns only the groups that exist; missing IDs are silently omitted.
    func findByIds(_ ids: [UInt64]) async throws -> [AccountGroup]
}

// MARK: - AccountGroupServiceRepositoryProtocol

/// Broader protocol defining the full set of repository methods that
/// ``AccountGroupService`` requires for complete CRUD operations, search,
/// and count queries.
///
/// This protocol extends ``AccountGroupRepositoryProtocol`` (which provides
/// `findByIds` for ``EntitlementService``) with the additional methods needed
/// by ``AccountGroupService``: `create`, `findById`, `findAll`, `update`,
/// `delete`, `findByName`, and `count`.
///
/// ## Dependency Injection Pattern
///
/// Follows the same protocol-based DI convention used by ``EntitlementService``
/// (with ``EntitlementRepositoryProtocol``) and ``AuthenticationService``
/// (with ``UserRepositoryProtocol``). Production code injects
/// ``AccountGroupRepository``; unit tests inject lightweight mock
/// implementations with zero database connections.
///
/// Inherits ``Sendable`` via ``AccountGroupRepositoryProtocol`` to satisfy
/// Swift 6 strict concurrency requirements (Gate 2).
public protocol AccountGroupServiceRepositoryProtocol: AccountGroupRepositoryProtocol {

    /// Creates a new account group in the data store.
    ///
    /// - Parameter entity: The account group to insert (the `id` field may be
    ///   ignored if the backing store auto-generates IDs).
    /// - Returns: The created account group with the store-assigned ID populated.
    func create(_ entity: AccountGroup) async throws -> AccountGroup

    /// Retrieves a single account group by its primary key.
    ///
    /// - Parameter id: The account group's unique ID.
    /// - Returns: The matching account group, or `nil` if not found.
    func findById(_ id: UInt64) async throws -> AccountGroup?

    /// Retrieves a paginated list of all account groups.
    ///
    /// - Parameters:
    ///   - page: 1-based page number.
    ///   - pageSize: Maximum records per page (capped at 1,000 per Rule 7).
    /// - Returns: Array of account groups for the requested page.
    func findAll(page: Int, pageSize: Int) async throws -> [AccountGroup]

    /// Updates an existing account group.
    ///
    /// - Parameter entity: The account group with updated fields.
    /// - Returns: The updated account group.
    func update(_ entity: AccountGroup) async throws -> AccountGroup

    /// Deletes an account group by its primary key.
    ///
    /// - Parameter id: The primary key of the account group to delete.
    func delete(_ id: UInt64) async throws

    /// Finds a single account group by exact name match.
    ///
    /// - Parameter name: The group name to search for (exact match).
    /// - Returns: The matching account group, or `nil` if not found.
    func findByName(_ name: String) async throws -> AccountGroup?

    /// Returns the total count of account groups in the data store.
    ///
    /// - Returns: The total number of account groups.
    func count() async throws -> Int
}

// MARK: - AccountGroupRepository

/// Repository for the `account_groups` table providing complete CRUD operations,
/// exact name lookup for duplicate validation, batch ID lookup for entitlement
/// resolution, and total count.
///
/// Conforms to `RepositoryProtocol` with `AccountGroup` as Entity and `UInt64`
/// as EntityID.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// All stored properties are immutable (`let`). `ConnectionPool` is an actor
/// (inherently `Sendable`). `Logger` from swift-log is `Sendable`. The class is
/// declared as `final class ... Sendable` without `@unchecked` since all invariants
/// are satisfied by construction.
///
/// ## Rule 8 — MySQLKit-Only Persistence
///
/// All database operations use MySQLKit/MySQLNIO exclusively. No SwiftData imports.
///
/// ## Rule 7 — Batch Memory Cap
///
/// `findAll` enforces a maximum page size of `AppConstants.defaultPagination` (1,000).
/// `findByIds` caps at `AppConstants.batchSize` (1,000) IDs per query.
///
/// ## Rule 10 — Schema Referential Integrity
///
/// The `account_groups` table has a `BIGINT UNSIGNED AUTO_INCREMENT` primary key.
/// The `accounts` and `entitlements` tables reference `account_groups` via FK.
/// Deleting an account group may fail with a FK constraint error if other tables
/// still reference the group.
public final class AccountGroupRepository: RepositoryProtocol, AccountGroupServiceRepositoryProtocol, Sendable {

    public typealias Entity = AccountGroup
    public typealias EntityID = UInt64

    /// AsyncKit-based MySQL connection pool injected via dependency injection.
    private let pool: ConnectionPool

    /// Structured logger for repository operations.
    private let logger: Logger

    /// Creates a new `AccountGroupRepository` with the given connection pool.
    ///
    /// - Parameters:
    ///   - pool: The connection pool for database operations.
    ///   - logger: Structured logger. Defaults to label `"persistence.account-group-repository"`.
    public init(
        pool: ConnectionPool,
        logger: Logger = Logger(label: "persistence.account-group-repository")
    ) {
        self.pool = pool
        self.logger = logger
    }

    // MARK: - RepositoryProtocol Conformance

    /// Retrieves an account group by its primary key.
    ///
    /// Executes a parameterized `SELECT` on the `account_groups` table matching
    /// the given `id`. Returns `nil` when no group exists with that identifier.
    ///
    /// - Parameter id: The account group's unique identifier (BIGINT UNSIGNED).
    /// - Returns: The matching `AccountGroup`, or `nil` if not found.
    public func findById(_ id: UInt64) async throws -> AccountGroup? {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Finding account group by id: \(id)")
            let rows = try await db.query(
                "SELECT id, group_name, metadata, created_at FROM account_groups WHERE id = ?",
                [MySQLData(int: Int(id))]
            ).get()
            guard let row = rows.first else {
                return nil
            }
            return try AccountGroupRepository.mapRow(row)
        }
    }

    /// Retrieves a paginated list of account groups ordered by ID ascending.
    ///
    /// Enforces Rule 7: page size is capped at `AppConstants.defaultPagination` (1,000).
    /// Pages are 1-based; page values less than 1 are clamped to 1.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Values < 1 are clamped to 1.
    ///   - pageSize: Maximum records per page. Values > 1,000 are clamped to 1,000.
    ///               Values < 1 are clamped to 1.
    /// - Returns: Array of account groups for the requested page, may be empty.
    public func findAll(page: Int, pageSize: Int) async throws -> [AccountGroup] {
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let effectivePage = max(page, 1)
        let offset = (effectivePage - 1) * effectivePageSize
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Finding all account groups: page=\(effectivePage), pageSize=\(effectivePageSize), offset=\(offset)")
            let rows = try await db.query(
                "SELECT id, group_name, metadata, created_at FROM account_groups ORDER BY id ASC LIMIT ? OFFSET ?",
                [MySQLData(int: effectivePageSize), MySQLData(int: offset)]
            ).get()
            return try rows.map { try AccountGroupRepository.mapRow($0) }
        }
    }

    /// Creates a new account group in the database.
    ///
    /// Inserts a row into the `account_groups` table with the provided group name
    /// and optional metadata. The auto-generated ID is retrieved via
    /// `LAST_INSERT_ID()` on the same connection to guarantee correctness.
    /// The `created_at` timestamp is populated by MySQL via `DEFAULT CURRENT_TIMESTAMP`.
    ///
    /// - Parameter entity: The account group to create. The `id` field is ignored;
    ///                     MySQL generates the auto-increment ID.
    /// - Returns: The created account group with the auto-generated ID populated.
    public func create(_ entity: AccountGroup) async throws -> AccountGroup {
        let groupName = entity.groupName
        let metadata = entity.metadata
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Creating account group with name: \(groupName)")

            // Build binds: group_name is required; metadata may be NULL
            let metadataBind: MySQLData = metadata.map { MySQLData(string: $0) } ?? .null

            _ = try await db.query(
                "INSERT INTO account_groups (group_name, metadata) VALUES (?, ?)",
                [MySQLData(string: groupName), metadataBind]
            ).get()

            // Retrieve the auto-generated ID on the same connection
            let idRows = try await db.query(
                "SELECT LAST_INSERT_ID() AS insert_id"
            ).get()
            guard let insertId = idRows.first?.column("insert_id")?.uint64 else {
                logger.error("Failed to retrieve LAST_INSERT_ID after account group creation for name: \(groupName)")
                throw AppError.dataAccessFailed("LAST_INSERT_ID returned nil after account group creation for name: \(groupName)")
            }

            logger.info("Created account group '\(groupName)' with id: \(insertId)")
            return AccountGroup(
                id: insertId,
                groupName: groupName,
                metadata: metadata,
                createdAt: Date()
            )
        }
    }

    /// Deletes an account group by primary key.
    ///
    /// Removes the corresponding row from the `account_groups` table.
    ///
    /// - Important: This operation may fail with a foreign key constraint error
    ///   if the `accounts` or `entitlements` tables still reference this group.
    ///   Callers should remove associated accounts and entitlements before
    ///   deleting the group.
    ///
    /// - Parameter id: The account group's unique identifier.
    public func delete(_ id: UInt64) async throws {
        let logger = self.logger
        try await pool.withConnection { db in
            logger.info("Deleting account group with id: \(id)")
            _ = try await db.query(
                "DELETE FROM account_groups WHERE id = ?",
                [MySQLData(int: Int(id))]
            ).get()
            logger.info("Deleted account group with id: \(id)")
        }
    }

    // MARK: - Domain-Specific Methods

    /// Updates an existing account group's name and metadata.
    ///
    /// The group is identified by `entity.id`; both `group_name` and `metadata`
    /// columns are updated. The `created_at` column is not modified.
    ///
    /// - Parameter entity: The account group with updated values. The `id` must
    ///                     correspond to an existing row.
    /// - Returns: The updated account group entity (echoed back with the same values).
    public func update(_ entity: AccountGroup) async throws -> AccountGroup {
        let entityId = entity.id
        let groupName = entity.groupName
        let metadata = entity.metadata
        let logger = self.logger

        try await pool.withConnection { db in
            logger.info("Updating account group with id: \(entityId)")
            let metadataBind: MySQLData = metadata.map { MySQLData(string: $0) } ?? .null
            _ = try await db.query(
                "UPDATE account_groups SET group_name = ?, metadata = ? WHERE id = ?",
                [
                    MySQLData(string: groupName),
                    metadataBind,
                    MySQLData(int: Int(entityId)),
                ]
            ).get()
            logger.info("Updated account group with id: \(entityId)")
        }
        return entity
    }

    /// Finds an account group by exact name match.
    ///
    /// Used for duplicate name validation before creating a new group.
    /// The match is case-sensitive against the `group_name` column.
    ///
    /// - Parameter name: The group name to search for.
    /// - Returns: The matching `AccountGroup`, or `nil` if no group has that name.
    public func findByName(_ name: String) async throws -> AccountGroup? {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Finding account group by name: \(name)")
            let rows = try await db.query(
                "SELECT id, group_name, metadata, created_at FROM account_groups WHERE group_name = ?",
                [MySQLData(string: name)]
            ).get()
            guard let row = rows.first else {
                return nil
            }
            return try AccountGroupRepository.mapRow(row)
        }
    }

    /// Retrieves account groups matching a list of IDs.
    ///
    /// Constructs a parameterized `IN` clause dynamically based on the array
    /// length. Used by `EntitlementService` to resolve account group names for
    /// a user's entitled groups.
    ///
    /// Enforces Rule 7: the input array is capped at `AppConstants.batchSize`
    /// (1,000) IDs per query. Excess IDs beyond the cap are silently dropped.
    ///
    /// - Parameter ids: Array of account group IDs to retrieve. Empty array
    ///                  returns an empty result without executing a query.
    /// - Returns: Array of matching account groups ordered by ID ascending.
    public func findByIds(_ ids: [UInt64]) async throws -> [AccountGroup] {
        // Short-circuit: empty input produces empty output, no DB query needed
        guard !ids.isEmpty else {
            return []
        }

        // Enforce Rule 7 batch memory cap — take at most batchSize IDs
        let cappedIds = Array(ids.prefix(AppConstants.batchSize))
        let logger = self.logger

        return try await pool.withConnection { db in
            logger.info("Finding account groups by \(cappedIds.count) ids")

            // Build parameterized IN clause: "?, ?, ?, ..."
            let placeholders = cappedIds.map { _ in "?" }.joined(separator: ", ")
            let binds = cappedIds.map { MySQLData(int: Int($0)) }
            let sql = "SELECT id, group_name, metadata, created_at FROM account_groups WHERE id IN (\(placeholders)) ORDER BY id ASC"

            let rows = try await db.query(sql, binds).get()
            return try rows.map { try AccountGroupRepository.mapRow($0) }
        }
    }

    /// Returns the total number of account groups in the database.
    ///
    /// - Returns: Total count as an `Int`.
    public func count() async throws -> Int {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Counting total account groups")
            let rows = try await db.query("SELECT COUNT(*) AS cnt FROM account_groups").get()
            guard let countData = rows.first?.column("cnt") else {
                return 0
            }
            // MySQL COUNT returns BIGINT; handle both Int and UInt64 decoding paths
            if let intCount = countData.int {
                return intCount
            }
            if let uint64Count = countData.uint64 {
                return Int(uint64Count)
            }
            return 0
        }
    }

    // MARK: - Private Helpers

    /// Maps a MySQL result row to an `AccountGroup` model.
    ///
    /// Extracts `id` (BIGINT UNSIGNED), `group_name` (VARCHAR), `metadata`
    /// (JSON, nullable), and `created_at` (TIMESTAMP) columns from the row.
    ///
    /// This method is `static` to allow safe invocation from `@Sendable`
    /// closures passed to the connection pool without capturing `self`.
    ///
    /// - Parameter row: The MySQL result row containing the expected columns.
    /// - Returns: The mapped `AccountGroup` instance.
    /// - Throws: `AppError.dataAccessFailed` if required columns (`id`,
    ///           `group_name`, `created_at`) are missing or cannot be decoded.
    private static func mapRow(_ row: MySQLRow) throws -> AccountGroup {
        guard let id = row.column("id")?.uint64,
              let groupName = row.column("group_name")?.string,
              let createdAt = row.column("created_at")?.date else {
            throw AppError.dataAccessFailed("Failed to map account group row: missing or invalid columns (id, group_name, created_at)")
        }
        // metadata is nullable JSON — .string returns nil for SQL NULL
        let metadata = row.column("metadata")?.string
        return AccountGroup(
            id: id,
            groupName: groupName,
            metadata: metadata,
            createdAt: createdAt
        )
    }
}
