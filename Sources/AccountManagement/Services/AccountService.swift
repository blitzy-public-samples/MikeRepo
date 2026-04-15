// Sources/AccountManagement/Services/AccountService.swift
// WealthLedger — Account CRUD, Search, and Batch Operations with Entitlement Enforcement
//
// Primary service class for the AccountManagement module. Every public method
// enforces RBAC entitlement checks (Rule 4) through the injected EntitlementService,
// batch memory caps (Rule 7) via AppConstants, and delegates all persistence
// operations to AccountRepository (Rule 8 — MySQLKit-only).
//
// Rule 4:  READ → empty result; WRITE → throw AppError.unauthorizedAccess
// Rule 7:  No operation loads more than 1,000 account records simultaneously
// Rule 13: Search delegates to indexed repository queries for sub-2-second response
//
// SPDX-License-Identifier: MIT

import Foundation
import Persistence
import RBAC
import Shared

// MARK: - AccountService

/// Primary service class for account CRUD operations, multi-criteria search,
/// and batch status updates in the WealthLedger application.
///
/// This service is the central business logic layer for the AccountManagement module.
/// Every public method enforces RBAC entitlement checks (Rule 4) through the injected
/// ``EntitlementService``, batch memory caps (Rule 7) via ``AppConstants``, and
/// delegates all persistence operations to ``AccountRepository`` (Rule 8 — MySQLKit-only).
///
/// ## Rule 4 — Entitlement Enforcement (Critical)
///
/// Every method that returns account data first verifies the user's group-level
/// permissions via ``EntitlementService``. The enforcement pattern is:
/// - **READ operations** (`search`, `getAccount`, `getAccounts`, `getAccountsByGroup`):
///   Return an empty result set — never an error — when the user lacks READ permission.
/// - **WRITE operations** (`createAccount`, `updateAccount`, `deleteAccount`,
///   `batchStatusUpdate`): Throw ``AppError/unauthorizedAccess`` when the user lacks
///   the required permission (CREATE / MODIFY / DELETE).
///
/// ## Rule 7 — Batch Memory Cap
///
/// - Search results capped at ``AppConstants/maxSearchResults`` (1,000).
/// - Batch operations capped at ``AppConstants/batchSize`` (1,000).
/// - Paginated queries default to ``AppConstants/defaultPagination`` (1,000).
///
/// ## Rule 13 — Performance Thresholds
///
/// Full-universe search of 100,000 accounts completes in under 2 seconds by
/// delegating to ``AccountRepository/searchByGroupIds(accountGroupIds:name:accountType:page:pageSize:)``
/// which leverages MySQL composite B-tree indexes.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// This class is `public final class` with only immutable `let` properties of
/// `Sendable`-conforming types (`AccountRepository`, `EntitlementService`,
/// `AccountGroupService`). It conforms to `Sendable` without `@unchecked`
/// annotations. All methods are `async throws`, compatible with structured concurrency.
/// Zero warning suppressions.
///
/// ## Cross-Module Type Conversion
///
/// The Persistence module defines its own `Account`, `FundType`, and `AccountStatus`
/// types to avoid a circular module dependency (AccountManagement → Persistence →
/// AccountManagement). This service bridges the module boundary by converting between
/// `Persistence.Account` (returned by the repository) and `AccountManagement.Account`
/// (the domain model exposed by this module's public API). Both type families share
/// identical properties and raw values; conversion is lossless.
///
/// ## Consumers
///
/// - ``SearchView`` — calls ``search(name:id:type:group:userId:page:pageSize:)`` and
///   ``getAccessibleAccountGroups(userId:)``
/// - ``AccountsViewerView`` — calls ``getAccounts(ids:userId:)``
/// - ``AdminView`` — calls ``createAccount(_:userId:)``
/// - ``JobSchedulerService`` — calls ``search(name:id:type:group:userId:page:pageSize:)``
/// - ``DependencyContainer`` — registers this service with injected dependencies
public final class AccountService: Sendable {

    // MARK: - Properties

    /// Repository for account table persistence operations.
    ///
    /// Provides `findById`, `findByIds`, `findAll`, `create`, `update`, `delete`,
    /// `search`, `searchByGroupIds`, `batchUpdateStatus`, `findByGroupId`, and
    /// cached valuation update methods. All database interaction is delegated to
    /// this repository — no direct MySQLKit usage in this service (Rule 8).
    private let accountRepository: AccountRepository

    /// RBAC entitlement enforcement service.
    ///
    /// Provides `checkPermission(userId:accountGroupId:permission:)` and
    /// `filterAccessibleGroups(userId:)`. Called before every data access or
    /// mutation operation to enforce Rule 4. Never throws for unauthorized access;
    /// returns `false` or empty arrays instead.
    private let entitlementService: EntitlementService

    /// Account group CRUD service.
    ///
    /// Stored as a dependency for account group-related operations needed during
    /// account creation and group-scoped queries.
    private let accountGroupService: AccountGroupService

    // MARK: - Initializer

    /// Creates a new ``AccountService`` with the required dependencies.
    ///
    /// All dependencies are injected by ``DependencyContainer`` during application
    /// startup. No global state, no singletons.
    ///
    /// - Parameters:
    ///   - accountRepository: Repository for account database operations.
    ///   - entitlementService: Service for RBAC permission checks (Rule 4).
    ///   - accountGroupService: Service for account group CRUD operations.
    public init(
        accountRepository: AccountRepository,
        entitlementService: EntitlementService,
        accountGroupService: AccountGroupService
    ) {
        self.accountRepository = accountRepository
        self.entitlementService = entitlementService
        self.accountGroupService = accountGroupService
    }

    // MARK: - Search Methods (Rule 4 + Rule 7 + Rule 13)

    /// Multi-criteria search with entitlement enforcement.
    ///
    /// This is the primary search path for ``SearchView``. It enforces Rule 4 by
    /// first resolving the user's accessible account groups, then restricting search
    /// results to those groups only. If the user has no entitled groups, an empty
    /// result set is returned immediately — never an error.
    ///
    /// ## Search Paths
    ///
    /// - **ID-based search** (`id` is non-nil): Performs a direct `findById` lookup,
    ///   verifies the account's group is in the user's accessible groups, and returns
    ///   `[account]` or `[]`. Other filter parameters are ignored.
    /// - **Criteria-based search** (`id` is nil): Delegates to
    ///   ``AccountRepository/searchByGroupIds(accountGroupIds:name:accountType:page:pageSize:)``
    ///   which leverages MySQL B-tree indexes for sub-2-second performance across
    ///   100,000 accounts (Rule 13).
    ///
    /// ## Rules Enforced
    ///
    /// - Rule 4: Only accounts in entitled groups are returned; empty result for no access.
    /// - Rule 7: Page size capped at ``AppConstants/maxSearchResults`` (1,000).
    /// - Rule 13: Delegated to indexed repository queries for performance.
    ///
    /// - Parameters:
    ///   - name: Optional account name prefix for partial match (`LIKE 'prefix%'`).
    ///   - id: Optional exact account ID for direct lookup (takes priority over
    ///     other filters).
    ///   - type: Optional fund type filter.
    ///   - group: Optional account group ID filter (must be in user's entitled groups).
    ///   - userId: The authenticated user's ID for entitlement verification.
    ///   - page: 1-based page number.
    ///   - pageSize: Maximum records per page (capped at ``AppConstants/maxSearchResults``).
    /// - Returns: Matching accounts the user is entitled to view. Empty if no access
    ///   or no results match.
    /// - Throws: Database errors propagated from the repository layer.
    public func search(
        name: String?,
        id: UInt64?,
        type: FundType?,
        group: UInt64?,
        userId: UInt64,
        page: Int,
        pageSize: Int
    ) async throws -> [Account] {
        // Rule 4: Resolve accessible groups before any data query
        let accessibleGroups = await entitlementService.filterAccessibleGroups(userId: userId)
        guard !accessibleGroups.isEmpty else {
            // User has no entitled groups → empty result (Rule 4)
            return []
        }
        let accessibleGroupIds = accessibleGroups.map { $0.id }
        let accessibleGroupIdSet = Set(accessibleGroupIds)

        // ID-based shortcut path: exact account lookup with entitlement verification
        if let id = id {
            guard let persistenceAccount = try await accountRepository.findById(id) else {
                return []
            }
            guard accessibleGroupIdSet.contains(persistenceAccount.accountGroupId) else {
                // Account exists but user is not entitled to its group (Rule 4)
                return []
            }
            return [Self.toDomain(persistenceAccount)]
        }

        // Group filter validation: if a specific group is requested, verify entitlement
        var filteredGroupIds = accessibleGroupIds
        if let group = group {
            guard accessibleGroupIdSet.contains(group) else {
                // User requested a group they are not entitled to (Rule 4)
                return []
            }
            filteredGroupIds = [group]
        }

        // Rule 7: Cap page size at maxSearchResults (1,000)
        let effectivePageSize = min(pageSize, AppConstants.maxSearchResults)

        // Rule 13: Delegate to indexed repository search
        let results = try await accountRepository.searchByGroupIds(
            accountGroupIds: filteredGroupIds,
            name: name,
            accountType: type?.rawValue,
            page: page,
            pageSize: effectivePageSize
        )

        return results.map { Self.toDomain($0) }
    }

    /// Loads specific accounts by IDs with entitlement enforcement.
    ///
    /// Used by ``AccountsViewerView`` to display selected accounts. Each returned
    /// account is verified against the user's entitled groups. Accounts in
    /// non-entitled groups are silently excluded from the result (Rule 4).
    ///
    /// - Parameters:
    ///   - ids: Account IDs to retrieve. Must not exceed ``AppConstants/batchSize``
    ///     (1,000) per Rule 7.
    ///   - userId: The authenticated user's ID for entitlement verification.
    /// - Returns: Entitled accounts matching the given IDs. Empty if no entitlement
    ///   or no matches.
    /// - Throws: ``AppError/dataAccessFailed(_:)`` if `ids.count` exceeds
    ///   ``AppConstants/batchSize``. Database errors from the repository layer.
    public func getAccounts(ids: [UInt64], userId: UInt64) async throws -> [Account] {
        // Rule 7: Validate batch size does not exceed memory cap
        guard ids.count <= AppConstants.batchSize else {
            throw AppError.dataAccessFailed(
                "Batch size \(ids.count) exceeds maximum of \(AppConstants.batchSize) accounts"
            )
        }

        // Short-circuit: empty input produces empty output
        guard !ids.isEmpty else {
            return []
        }

        // Load accounts from repository
        let persistenceAccounts = try await accountRepository.findByIds(ids)

        // Rule 4: Get accessible groups and filter results
        let accessibleGroups = await entitlementService.filterAccessibleGroups(userId: userId)
        let accessibleGroupIdSet = Set(accessibleGroups.map { $0.id })

        // Filter to only accounts in entitled groups
        let entitled = persistenceAccounts.filter { accessibleGroupIdSet.contains($0.accountGroupId) }
        return entitled.map { Self.toDomain($0) }
    }

    // MARK: - CRUD Operations (Rule 4 Write Path)

    /// Creates a new account with CREATE permission check.
    ///
    /// Validates:
    /// 1. **Rule 4**: User has CREATE permission on the account's group → throws
    ///    ``AppError/unauthorizedAccess`` if denied.
    /// 2. **Rule 3**: The IANA timezone string resolves to a valid ``TimeZone`` →
    ///    throws ``AppError/invalidTimezone`` if invalid.
    ///
    /// Fund type validation (Rule 5) is inherently satisfied because all ``FundType``
    /// cases are equity-oriented (open/closed mutual funds, ETFs, hedge funds, SMAs, UMAs).
    ///
    /// - Parameters:
    ///   - account: The account to create. The `id` field is ignored; MySQL generates
    ///     the auto-increment ID.
    ///   - userId: The authenticated user's ID for permission verification.
    /// - Returns: The created account with the database-assigned ID populated.
    /// - Throws: ``AppError/unauthorizedAccess`` if the user lacks CREATE permission,
    ///           ``AppError/invalidTimezone`` if the IANA timezone is invalid.
    ///           Database errors propagated from the repository layer.
    public func createAccount(_ account: Account, userId: UInt64) async throws -> Account {
        // Rule 4: Check CREATE permission on the account's group
        let hasPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: account.accountGroupId,
            permission: "CREATE"
        )
        guard hasPermission else {
            throw AppError.unauthorizedAccess
        }

        // Rule 3: Validate IANA timezone string
        guard TimeZone(identifier: account.valuationTimezone) != nil else {
            throw AppError.invalidTimezone
        }

        // Delegate to repository with type conversion
        let persistenceAccount = Self.toPersistence(account)
        let created = try await accountRepository.create(persistenceAccount)
        return Self.toDomain(created)
    }

    /// Reads a single account by ID with READ permission check.
    ///
    /// **Rule 4**: Returns `nil` (not an error) when the user lacks READ permission
    /// for the account's group, or when the account does not exist.
    ///
    /// - Parameters:
    ///   - id: The unique account identifier.
    ///   - userId: The authenticated user's ID for permission verification.
    /// - Returns: The account if found and the user is entitled, `nil` otherwise.
    /// - Throws: Database errors propagated from the repository layer.
    public func getAccount(id: UInt64, userId: UInt64) async throws -> Account? {
        guard let persistenceAccount = try await accountRepository.findById(id) else {
            return nil
        }

        // Rule 4: Check READ permission — return nil if denied (not error)
        let hasPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: persistenceAccount.accountGroupId,
            permission: "READ"
        )
        guard hasPermission else {
            return nil
        }

        return Self.toDomain(persistenceAccount)
    }

    /// Updates account details with MODIFY permission check.
    ///
    /// Validates:
    /// 1. **Rule 4**: User has MODIFY permission on the account's group → throws
    ///    ``AppError/unauthorizedAccess`` if denied.
    /// 2. **Rule 3**: The IANA timezone string resolves to a valid ``TimeZone`` →
    ///    throws ``AppError/invalidTimezone`` if invalid.
    ///
    /// - Parameters:
    ///   - account: The account with updated values. The ``Account/id`` must correspond
    ///     to an existing row in the `accounts` table.
    ///   - userId: The authenticated user's ID for permission verification.
    /// - Returns: The updated account entity.
    /// - Throws: ``AppError/unauthorizedAccess`` if the user lacks MODIFY permission,
    ///           ``AppError/invalidTimezone`` if the IANA timezone is invalid.
    ///           Database errors propagated from the repository layer.
    public func updateAccount(_ account: Account, userId: UInt64) async throws -> Account {
        // Rule 4: Check MODIFY permission on the account's group
        let hasPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: account.accountGroupId,
            permission: "MODIFY"
        )
        guard hasPermission else {
            throw AppError.unauthorizedAccess
        }

        // Rule 3: Validate IANA timezone string
        guard TimeZone(identifier: account.valuationTimezone) != nil else {
            throw AppError.invalidTimezone
        }

        // Delegate to repository with type conversion
        let persistenceAccount = Self.toPersistence(account)
        let updated = try await accountRepository.update(persistenceAccount)
        return Self.toDomain(updated)
    }

    /// Deletes an account with DELETE permission check.
    ///
    /// Verifies the account exists before checking permissions. If the account
    /// does not exist, throws ``AppError/accountNotFound`` before any permission
    /// check occurs.
    ///
    /// **Rule 4**: Throws ``AppError/unauthorizedAccess`` if the user lacks DELETE
    /// permission on the account's group.
    ///
    /// - Parameters:
    ///   - id: The unique account identifier to delete.
    ///   - userId: The authenticated user's ID for permission verification.
    /// - Throws: ``AppError/accountNotFound`` if no account exists with the given ID,
    ///           ``AppError/unauthorizedAccess`` if the user lacks DELETE permission.
    ///           FK constraint violations if positions or transactions reference this
    ///           account. Database errors propagated from the repository layer.
    public func deleteAccount(id: UInt64, userId: UInt64) async throws {
        // Verify account exists
        guard let persistenceAccount = try await accountRepository.findById(id) else {
            throw AppError.accountNotFound
        }

        // Rule 4: Check DELETE permission on the account's group
        let hasPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: persistenceAccount.accountGroupId,
            permission: "DELETE"
        )
        guard hasPermission else {
            throw AppError.unauthorizedAccess
        }

        try await accountRepository.delete(id)
    }

    // MARK: - Batch Status Update (Rule 7)

    /// Batch update status for up to 1,000 accounts simultaneously.
    ///
    /// Enforces Rule 7 (Batch Memory Cap): rejects requests exceeding
    /// ``AppConstants/batchSize`` (1,000) account IDs. Enforces Rule 4 by
    /// checking MODIFY permission for every unique account group in the batch.
    /// If **any** group check fails, the entire batch is rejected.
    ///
    /// The ``AccountStatus/rawValue`` is passed to the repository for the MySQL
    /// ENUM column update (lowercase string matching MySQL ENUM values).
    ///
    /// - Parameters:
    ///   - accountIds: Account IDs to update. Must not exceed ``AppConstants/batchSize``.
    ///   - newStatus: The new lifecycle status to apply.
    ///   - userId: The authenticated user's ID for permission verification.
    /// - Throws: ``AppError/dataAccessFailed(_:)`` if batch exceeds size limit,
    ///           ``AppError/unauthorizedAccess`` if lacking MODIFY on any group.
    ///           Database errors propagated from the repository layer.
    public func batchStatusUpdate(
        accountIds: [UInt64],
        newStatus: AccountStatus,
        userId: UInt64
    ) async throws {
        // Rule 7: Validate batch size does not exceed memory cap
        guard accountIds.count <= AppConstants.batchSize else {
            throw AppError.dataAccessFailed(
                "Batch size \(accountIds.count) exceeds maximum of \(AppConstants.batchSize)"
            )
        }

        // Short-circuit: nothing to update
        guard !accountIds.isEmpty else {
            return
        }

        // Load accounts to determine their groups for permission checks
        let accounts = try await accountRepository.findByIds(accountIds)

        // Collect unique account group IDs from the batch
        let uniqueGroupIds = Set(accounts.map { $0.accountGroupId })

        // Rule 4: Check MODIFY permission for each unique group in the batch
        for groupId in uniqueGroupIds {
            let hasPermission = await entitlementService.checkPermission(
                userId: userId,
                accountGroupId: groupId,
                permission: "MODIFY"
            )
            guard hasPermission else {
                throw AppError.unauthorizedAccess
            }
        }

        // Delegate to repository for transactional batch update
        try await accountRepository.batchUpdateStatus(
            accountIds: accountIds,
            newStatus: newStatus.rawValue
        )
    }

    // MARK: - Helper / Convenience Methods

    /// Retrieves paginated accounts by group with entitlement enforcement.
    ///
    /// **Rule 4**: Returns an empty array (not an error) if the user lacks READ
    /// permission on the requested group. **Rule 7**: Page size is capped at
    /// ``AppConstants/defaultPagination`` (1,000).
    ///
    /// - Parameters:
    ///   - groupId: The account group to query.
    ///   - userId: The authenticated user's ID for permission verification.
    ///   - page: 1-based page number.
    ///   - pageSize: Maximum records per page (capped at ``AppConstants/defaultPagination``).
    /// - Returns: Accounts in the specified group the user is entitled to read.
    /// - Throws: Database errors propagated from the repository layer.
    public func getAccountsByGroup(
        groupId: UInt64,
        userId: UInt64,
        page: Int,
        pageSize: Int
    ) async throws -> [Account] {
        // Rule 4: Check READ permission for the requested group
        let hasPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: groupId,
            permission: "READ"
        )
        guard hasPermission else {
            return []
        }

        // Rule 7: Cap page size at defaultPagination (1,000)
        let effectivePageSize = min(pageSize, AppConstants.defaultPagination)

        let results = try await accountRepository.findByGroupId(
            groupId,
            page: page,
            pageSize: effectivePageSize
        )

        return results.map { Self.toDomain($0) }
    }

    /// Returns all account groups accessible to a user.
    ///
    /// Used by ``SearchView`` to populate the group dropdown filter. Returns
    /// an empty array if the user has no entitled groups (Rule 4: empty, not error).
    ///
    /// Delegates to ``EntitlementService/filterAccessibleGroups(userId:)`` which
    /// never throws for authorization failures.
    ///
    /// - Parameter userId: The authenticated user's ID.
    /// - Returns: Account groups the user has READ access to. May be empty.
    public func getAccessibleAccountGroups(userId: UInt64) async -> [AccountGroup] {
        let persistenceGroups = await entitlementService.filterAccessibleGroups(userId: userId)
        return persistenceGroups.map { Self.groupToDomain($0) }
    }

    // MARK: - Private Type Conversion Helpers

    /// Converts a Persistence-layer ``Persistence/Account`` to the AccountManagement
    /// domain ``Account``.
    ///
    /// Both modules define `Account`, `FundType`, and `AccountStatus` with identical
    /// properties and raw values to avoid circular module dependencies. This method
    /// bridges the boundary losslessly. Declared `static` to avoid capturing `self`
    /// and to maintain `@Sendable` safety in async contexts.
    ///
    /// - Parameter p: The Persistence-module account entity.
    /// - Returns: The corresponding AccountManagement domain account entity.
    private static func toDomain(_ p: Persistence.Account) -> Account {
        // Convert Persistence.FundType → AccountManagement.FundType via raw value
        guard let fundType = FundType(rawValue: p.fundType.rawValue) else {
            preconditionFailure(
                "Persistence.FundType raw value '\(p.fundType.rawValue)' has no matching "
                + "AccountManagement.FundType case — enum definitions are out of sync"
            )
        }
        // Convert Persistence.AccountStatus → AccountManagement.AccountStatus via raw value
        guard let status = AccountStatus(rawValue: p.status.rawValue) else {
            preconditionFailure(
                "Persistence.AccountStatus raw value '\(p.status.rawValue)' has no matching "
                + "AccountManagement.AccountStatus case — enum definitions are out of sync"
            )
        }

        return Account(
            id: p.id,
            name: p.name,
            fundType: fundType,
            ownershipDetails: p.ownershipDetails,
            valuationTimezone: p.valuationTimezone,
            valuationSchedule: p.valuationSchedule,
            cachedValuationAmount: p.cachedValuationAmount,
            cachedValueDate: p.cachedValueDate,
            status: status,
            accountGroupId: p.accountGroupId,
            createdAt: p.createdAt
        )
    }

    /// Converts an AccountManagement domain ``Account`` to the Persistence-layer
    /// ``Persistence/Account``.
    ///
    /// Used when passing domain model objects to repository write methods (`create`,
    /// `update`). Declared `static` for `@Sendable` safety.
    ///
    /// - Parameter d: The AccountManagement domain account entity.
    /// - Returns: The corresponding Persistence-module account entity.
    private static func toPersistence(_ d: Account) -> Persistence.Account {
        guard let fundType = Persistence.FundType(rawValue: d.fundType.rawValue) else {
            preconditionFailure(
                "AccountManagement.FundType raw value '\(d.fundType.rawValue)' has no matching "
                + "Persistence.FundType case — enum definitions are out of sync"
            )
        }
        guard let status = Persistence.AccountStatus(rawValue: d.status.rawValue) else {
            preconditionFailure(
                "AccountManagement.AccountStatus raw value '\(d.status.rawValue)' has no matching "
                + "Persistence.AccountStatus case — enum definitions are out of sync"
            )
        }

        return Persistence.Account(
            id: d.id,
            name: d.name,
            fundType: fundType,
            ownershipDetails: d.ownershipDetails,
            valuationTimezone: d.valuationTimezone,
            valuationSchedule: d.valuationSchedule,
            cachedValuationAmount: d.cachedValuationAmount,
            cachedValueDate: d.cachedValueDate,
            status: status,
            accountGroupId: d.accountGroupId,
            createdAt: d.createdAt
        )
    }

    /// Converts a Persistence-layer ``Persistence/AccountGroup`` to the
    /// AccountManagement domain ``AccountGroup``.
    ///
    /// Used by ``getAccessibleAccountGroups(userId:)`` to convert the groups returned
    /// by ``EntitlementService/filterAccessibleGroups(userId:)`` (which returns
    /// `[Persistence.AccountGroup]`) into the domain model exposed by this module.
    ///
    /// - Parameter p: The Persistence-module account group entity.
    /// - Returns: The corresponding AccountManagement domain account group entity.
    private static func groupToDomain(_ p: Persistence.AccountGroup) -> AccountGroup {
        AccountGroup(
            id: p.id,
            groupName: p.groupName,
            metadata: p.metadata,
            createdAt: p.createdAt
        )
    }
}
