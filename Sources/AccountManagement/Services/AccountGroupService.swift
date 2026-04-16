// Sources/AccountManagement/Services/AccountGroupService.swift
// WealthLedger — Account Group CRUD Service
//
// Provides service-layer operations for account group lifecycle management.
// Account groups are the organizational units used for RBAC entitlement scoping (Rule 4).
// All persistence operations are delegated to AccountGroupRepository in the Persistence module.
//
// Rule 7: Batch memory cap enforced — pagination capped at 1,000 records.
// Rule 8: MySQLKit-only persistence — NO SwiftData.
// Rule 9: Offline runtime — all operations are local MySQL only.
//
// SPDX-License-Identifier: MIT

import Foundation
import Persistence
import Shared

// MARK: - AccountGroupService

/// Service class for account group CRUD operations in the WealthLedger application.
///
/// Manages the lifecycle of account groups — the organizational units used for
/// RBAC entitlement scoping (Rule 4). Account groups are referenced by the ``Account``
/// model (via `accountGroupId` FK) and by the ``Entitlement`` model (for permission
/// assignments). This service is consumed by ``AdminView`` for group creation,
/// ``AccountService`` for group lookups, and ``DependencyContainer`` for registration.
///
/// ## Swift 6 Strict Concurrency (Gate 2)
///
/// Declared as `public final class` with a single immutable `let` property
/// (`accountGroupRepository: any AccountGroupServiceRepositoryProtocol`) which
/// is an existential of a `Sendable`-constrained protocol. No mutable state
/// exists. All methods are `async throws`, fully compatible with structured
/// concurrency. Zero `@unchecked Sendable` annotations.
///
/// ## Rule 7 — Batch Memory Cap
///
/// Paginated queries enforce a maximum page size of `AppConstants.defaultPagination`
/// (1,000). Batch ID lookups are capped at `AppConstants.batchSize` (1,000).
///
/// ## Rule 8 — MySQLKit-Only Persistence
///
/// All database access is delegated to ``AccountGroupRepository``. This service does
/// not import MySQLKit, SQLKit, or SwiftData.
///
/// ## Rule 9 — Offline Runtime
///
/// No network calls. All operations target the local MySQL instance via repository
/// delegation.
///
/// ## Type Conversion (Persistence ↔ AccountManagement)
///
/// The Persistence module defines its own `AccountGroup` struct to avoid a circular
/// module dependency (AccountManagement → Persistence → AccountManagement). This
/// service bridges the module boundary by converting between `Persistence.AccountGroup`
/// (used by the repository layer) and `AccountManagement.AccountGroup` (the domain
/// model exposed by this module's public API). Both types share identical properties;
/// conversion is lossless.
public final class AccountGroupService: Sendable {

    // MARK: - Properties

    /// Repository for account group persistence operations.
    ///
    /// Injected via ``DependencyContainer`` at application startup. Provides
    /// `findById`, `findAll`, `create`, `delete`, `update`, `findByName`,
    /// `findByIds`, and `count` methods against the MySQL `account_groups` table.
    ///
    /// Typed as `any AccountGroupServiceRepositoryProtocol` to support dependency
    /// injection of both the production ``AccountGroupRepository`` and lightweight
    /// mock implementations in unit tests — consistent with the protocol-based DI
    /// pattern used by ``EntitlementService`` (with ``EntitlementRepositoryProtocol``)
    /// and ``AuthenticationService`` (with ``UserRepositoryProtocol``).
    private let accountGroupRepository: any AccountGroupServiceRepositoryProtocol

    // MARK: - Initializer

    /// Creates a new ``AccountGroupService`` with the given repository dependency.
    ///
    /// - Parameter accountGroupRepository: The repository for account group database
    ///   operations. Injected by ``DependencyContainer`` at application startup.
    ///   Must conform to ``AccountGroupServiceRepositoryProtocol`` and `Sendable`.
    public init(accountGroupRepository: any AccountGroupServiceRepositoryProtocol) {
        self.accountGroupRepository = accountGroupRepository
    }

    // MARK: - CRUD Operations

    /// Creates a new account group with the specified name and optional metadata.
    ///
    /// Constructs a new ``AccountGroup`` model instance and delegates creation to the
    /// repository, which inserts a row into the `account_groups` table and returns
    /// the entity with the MySQL-generated auto-increment ID.
    ///
    /// The `id` field on the constructed model is set to `0` as a placeholder; MySQL
    /// generates the actual auto-increment value on insert. The `createdAt` timestamp
    /// is provided for consistency, though MySQL's `DEFAULT CURRENT_TIMESTAMP` may
    /// override it.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the account group (e.g., "US Equity Funds").
    ///   - metadata: Optional JSON string containing group-level metadata. Defaults to `nil`.
    /// - Returns: The created account group with the database-assigned ID populated.
    /// - Throws: Database errors propagated from the repository layer (e.g., unique
    ///   constraint violations, connection failures).
    public func createGroup(name: String, metadata: String? = nil) async throws -> AccountGroup {
        let persistenceGroup = Persistence.AccountGroup(
            id: 0,
            groupName: name,
            metadata: metadata,
            createdAt: Date()
        )
        let created = try await accountGroupRepository.create(persistenceGroup)
        return Self.toDomain(created)
    }

    /// Retrieves a single account group by its unique identifier.
    ///
    /// Delegates to ``AccountGroupRepository/findById(_:)`` which executes a parameterized
    /// `SELECT` on the `account_groups` table. Returns `nil` when no group exists with
    /// the given identifier.
    ///
    /// - Parameter id: The account group's unique ID (MySQL `BIGINT UNSIGNED`).
    /// - Returns: The matching ``AccountGroup``, or `nil` if no group exists with that ID.
    /// - Throws: Database errors propagated from the repository layer.
    public func getGroup(id: UInt64) async throws -> AccountGroup? {
        guard let found = try await accountGroupRepository.findById(id) else {
            return nil
        }
        return Self.toDomain(found)
    }

    /// Retrieves a paginated list of all account groups ordered by ID ascending.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: the effective page size is capped at
    /// ``AppConstants/defaultPagination`` (1,000) regardless of the requested `pageSize`.
    /// If a caller requests a page size greater than 1,000, it is silently clamped.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Defaults to `1`. Values less than 1 are clamped
    ///     to 1 by the repository layer.
    ///   - pageSize: Maximum records per page. Defaults to ``AppConstants/defaultPagination``
    ///     (1,000). Capped at 1,000 to enforce Rule 7.
    /// - Returns: Array of ``AccountGroup`` instances for the requested page. May be empty
    ///   if the page exceeds the total number of groups.
    /// - Throws: Database errors propagated from the repository layer.
    public func getAllGroups(
        page: Int = 1,
        pageSize: Int = AppConstants.defaultPagination
    ) async throws -> [AccountGroup] {
        let effectivePageSize = min(pageSize, AppConstants.defaultPagination)
        let results = try await accountGroupRepository.findAll(
            page: page,
            pageSize: effectivePageSize
        )
        return results.map { Self.toDomain($0) }
    }

    /// Convenience method to list the first page of account groups using default pagination.
    ///
    /// Equivalent to calling ``getAllGroups(page:pageSize:)`` with `page: 1` and
    /// `pageSize: AppConstants.defaultPagination` (1,000).
    ///
    /// - Returns: Array of up to ``AppConstants/defaultPagination`` (1,000) account groups.
    /// - Throws: Database errors propagated from the repository layer.
    public func listGroups() async throws -> [AccountGroup] {
        return try await getAllGroups(page: 1, pageSize: AppConstants.defaultPagination)
    }

    /// Updates an existing account group's name and/or metadata.
    ///
    /// Verifies the group exists in the database before applying the update. If no group
    /// is found with the given `group.id`, throws ``AppError/accountNotFound``.
    ///
    /// The `createdAt` timestamp is preserved from the original record; only `group_name`
    /// and `metadata` columns are updated in MySQL.
    ///
    /// - Parameter group: The ``AccountGroup`` with updated values. The ``AccountGroup/id``
    ///   must correspond to an existing row in the `account_groups` table.
    /// - Returns: The updated account group entity.
    /// - Throws: ``AppError/accountNotFound`` if no group exists with the given ID.
    ///           Database errors propagated from the repository layer.
    public func updateGroup(_ group: AccountGroup) async throws -> AccountGroup {
        guard try await accountGroupRepository.findById(group.id) != nil else {
            throw AppError.accountNotFound
        }
        let persistenceGroup = Self.toPersistence(group)
        let updated = try await accountGroupRepository.update(persistenceGroup)
        return Self.toDomain(updated)
    }

    /// Deletes an account group by its unique identifier.
    ///
    /// Delegates directly to ``AccountGroupRepository/delete(_:)`` which executes a
    /// `DELETE` statement on the `account_groups` table.
    ///
    /// - Important: This operation may fail with a MySQL foreign key constraint error
    ///   if the `accounts` or `entitlements` tables still reference this group. Such
    ///   errors propagate naturally to the caller; dependent records must be removed
    ///   before the group can be deleted.
    ///
    /// - Parameter id: The account group's unique identifier.
    /// - Throws: Database errors propagated from the repository layer, including FK
    ///   constraint violations if dependent records exist.
    public func deleteGroup(id: UInt64) async throws {
        try await accountGroupRepository.delete(id)
    }

    // MARK: - Query / Helper Methods

    /// Batch lookup of account groups by a list of IDs.
    ///
    /// Used by ``EntitlementService`` to resolve account group names for a user's
    /// entitled groups.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: if the number of IDs exceeds
    /// ``AppConstants/batchSize`` (1,000), only the first `batchSize` IDs are queried.
    /// Excess IDs beyond the cap are silently dropped. An empty input array returns an
    /// empty result without executing a database query.
    ///
    /// - Parameter ids: Array of account group IDs to retrieve. May be empty.
    /// - Returns: Array of matching ``AccountGroup`` instances. Empty if `ids` is empty
    ///   or no matches are found.
    /// - Throws: Database errors propagated from the repository layer.
    public func getGroupsByIds(_ ids: [UInt64]) async throws -> [AccountGroup] {
        guard !ids.isEmpty else {
            return []
        }
        let effectiveIds: [UInt64]
        if ids.count > AppConstants.batchSize {
            effectiveIds = Array(ids.prefix(AppConstants.batchSize))
        } else {
            effectiveIds = ids
        }
        let results = try await accountGroupRepository.findByIds(effectiveIds)
        return results.map { Self.toDomain($0) }
    }

    /// Finds an account group by exact name match.
    ///
    /// Used for duplicate name detection during group creation and for admin-level
    /// lookup operations. The match is case-sensitive against the `group_name` column
    /// in the `account_groups` table.
    ///
    /// - Parameter name: The group name to search for.
    /// - Returns: The matching ``AccountGroup``, or `nil` if no group has that name.
    /// - Throws: Database errors propagated from the repository layer.
    public func getGroupByName(_ name: String) async throws -> AccountGroup? {
        guard let found = try await accountGroupRepository.findByName(name) else {
            return nil
        }
        return Self.toDomain(found)
    }

    /// Returns the total number of account groups in the database.
    ///
    /// Delegates to ``AccountGroupRepository/count()`` which executes
    /// `SELECT COUNT(*) FROM account_groups`.
    ///
    /// - Returns: Total count of account groups as an `Int`.
    /// - Throws: Database errors propagated from the repository layer.
    public func getGroupCount() async throws -> Int {
        return try await accountGroupRepository.count()
    }

    // MARK: - Private Type Conversion Helpers

    /// Converts a Persistence-layer ``Persistence/AccountGroup`` to the domain-layer
    /// ``AccountGroup`` defined in the AccountManagement module.
    ///
    /// Both types share identical properties (`id`, `groupName`, `metadata`, `createdAt`);
    /// this conversion bridges the module boundary losslessly. The conversion is performed
    /// as a `static` method to avoid capturing `self` and to maintain `@Sendable` safety
    /// in async contexts.
    ///
    /// - Parameter persistence: The Persistence-module account group entity.
    /// - Returns: The corresponding AccountManagement-module account group entity.
    private static func toDomain(_ persistence: Persistence.AccountGroup) -> AccountGroup {
        AccountGroup(
            id: persistence.id,
            groupName: persistence.groupName,
            metadata: persistence.metadata,
            createdAt: persistence.createdAt
        )
    }

    /// Converts a domain-layer ``AccountGroup`` from the AccountManagement module
    /// to the Persistence-layer ``Persistence/AccountGroup``.
    ///
    /// Both types share identical properties (`id`, `groupName`, `metadata`, `createdAt`);
    /// this conversion bridges the module boundary losslessly. The conversion is performed
    /// as a `static` method to avoid capturing `self` and to maintain `@Sendable` safety
    /// in async contexts.
    ///
    /// - Parameter domain: The AccountManagement-module account group entity.
    /// - Returns: The corresponding Persistence-module account group entity.
    private static func toPersistence(_ domain: AccountGroup) -> Persistence.AccountGroup {
        Persistence.AccountGroup(
            id: domain.id,
            groupName: domain.groupName,
            metadata: domain.metadata,
            createdAt: domain.createdAt
        )
    }
}
