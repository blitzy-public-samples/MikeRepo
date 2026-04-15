// EntitlementService.swift
// WealthLedger - RBAC Module
//
// Central entitlement enforcement service — the cross-cutting concern invoked by
// AccountService, LedgerService, and all UI screens to enforce per-user
// per-account-group permissions (READ / CREATE / MODIFY / DELETE).
//
// Rule 4 (Entitlement Enforcement):
//   All data reads must verify user-group entitlement before returning records.
//   Users without READ access to an account group receive an empty result set —
//   NOT an error. checkPermission() returns Bool (never throws for missing
//   permissions). filterAccessibleGroups() returns [] for users with no entitled
//   groups.
//
// Rule 8 (MySQLKit-Only Persistence):
//   This service does NOT import MySQLKit or SwiftData. All database operations
//   are delegated to the injected repository instances.
//
// Rule 9 (Offline Runtime):
//   No network calls. All data access flows through local MySQL via repositories.
//
// Swift 6 Strict Concurrency (Gate 2):
//   This class is a `final class` conforming to `Sendable`. All stored properties
//   are immutable (`let`) references to `Sendable`-conforming repository types.
//   Zero `@unchecked Sendable` annotations. Zero warning suppressions.
//
// Type Conversion Note:
//   Both the RBAC module and the Persistence module define a public `Entitlement`
//   struct with identical structure (id, userId, accountGroupId, canRead, canCreate,
//   canModify, canDelete). This duplication exists to avoid a circular dependency
//   (RBAC → Persistence → RBAC). EntitlementRepository methods return
//   `Persistence.Entitlement`, while EntitlementService's public API exposes
//   `RBAC.Entitlement` (the local module's type, unqualified `Entitlement`).
//   Conversion between the two is performed via straightforward property mapping
//   in the private `convertEntitlement(_:)` helper, following the same pattern
//   used by AuthenticationService for User type conversion.
//   `AccountGroup` is unambiguous — only the Persistence module exports it within
//   the RBAC dependency graph (RBAC does not depend on AccountManagement).

import Foundation
import Persistence

// MARK: - EntitlementService

/// Entitlement query and enforcement service for the WealthLedger RBAC system.
///
/// `EntitlementService` is the **single point of enforcement** for Rule 4
/// (Entitlement Enforcement). Every data access path — whether through
/// `AccountService`, `LedgerService`, or a SwiftUI view — must route through
/// this service to verify user-group permissions before exposing records.
///
/// ## Rule 4 — Entitlement Enforcement (Critical)
///
/// - `checkPermission(userId:accountGroupId:permission:)` returns `false` for
///   unauthorized access — **never throws** for missing permissions.
/// - `filterAccessibleGroups(userId:)` returns an empty array for users with no
///   entitled groups — **never throws** for authorization failures.
/// - Infrastructure failures (database errors) are caught internally and result
///   in "no access" (false / empty) rather than propagated exceptions.
///
/// ## Dependency Injection
///
/// Both `EntitlementRepository` and `AccountGroupRepository` are injected via the
/// initializer. This service has no global state and no singleton patterns.
/// Registration and injection are managed by `DependencyContainer`.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// This class is `final` with only immutable `let` properties of `Sendable`-
/// conforming types. It satisfies `Sendable` without `@unchecked` annotations.
///
/// ## Cross-Module Consumers
///
/// - **AccountService** — calls `filterAccessibleGroups` before every search and
///   `checkPermission` before CRUD operations.
/// - **LedgerService** — calls `checkPermission` before posting transactions.
/// - **AdminView** — calls `assignEntitlement`, `getEntitlements`, `revokeEntitlement`.
/// - **SearchView** — relies on `AccountService` which delegates to this service.
/// - **AccountsViewerView** — entitlement-gates all displayed data.
/// - **JobSchedulerView** — entitlement-gates job operations.
/// - **DependencyContainer** — registers and injects this service.
public final class EntitlementService: Sendable {

    // MARK: - Properties

    /// Repository for entitlement CRUD and permission queries.
    ///
    /// Provides `findByUserAndGroup`, `findByUserId`, `create`,
    /// `updatePermissions`, `deleteByUserAndGroup`, and `findByAccountGroupId`.
    /// All database interaction is delegated to this repository — no direct
    /// MySQLKit usage in this service.
    ///
    /// Typed as `any EntitlementRepositoryProtocol` to support dependency
    /// injection of both the production ``EntitlementRepository`` and
    /// lightweight mock implementations in unit tests.
    private let entitlementRepository: any EntitlementRepositoryProtocol

    /// Repository for resolving account group objects from IDs.
    ///
    /// Used exclusively by `filterAccessibleGroups` to convert entitlement
    /// account group IDs into fully resolved `AccountGroup` instances via
    /// `findByIds`.
    ///
    /// Typed as `any AccountGroupRepositoryProtocol` to support dependency
    /// injection of both the production ``AccountGroupRepository`` and
    /// lightweight mock implementations in unit tests.
    private let accountGroupRepository: any AccountGroupRepositoryProtocol

    // MARK: - Initializer

    /// Creates a new `EntitlementService` with the required repository dependencies.
    ///
    /// Both repositories are injected by `DependencyContainer` during application
    /// startup. No global state or singleton patterns are used.
    ///
    /// - Parameters:
    ///   - entitlementRepository: The persistence layer for entitlement records.
    ///   - accountGroupRepository: The persistence layer for account group records,
    ///     used to resolve entitled group objects.
    public init(
        entitlementRepository: any EntitlementRepositoryProtocol,
        accountGroupRepository: any AccountGroupRepositoryProtocol
    ) {
        self.entitlementRepository = entitlementRepository
        self.accountGroupRepository = accountGroupRepository
    }

    // MARK: - Permission Checking (Rule 4 — Core Enforcement)

    /// Checks whether a user has a specific permission for an account group.
    ///
    /// This is the primary enforcement method for Rule 4 (Entitlement
    /// Enforcement). It is called by `AccountService` and `LedgerService` before
    /// every data access or mutation operation.
    ///
    /// **Critical Rule 4 Behavior**: This method **never throws** for
    /// unauthorized access. It returns `false` in all denial scenarios:
    /// - No entitlement record exists for the user-group pair → `false`
    /// - The entitlement exists but the requested permission is denied → `false`
    /// - An unknown permission string is provided → `false`
    /// - A database or infrastructure error occurs → `false`
    ///
    /// This design ensures that callers never need to distinguish between
    /// "unauthorized" and "error" — both result in denial, maintaining the
    /// Rule 4 invariant that unauthorized access produces empty results, not
    /// exceptions.
    ///
    /// - Parameters:
    ///   - userId: The unique identifier of the user requesting access.
    ///   - accountGroupId: The unique identifier of the target account group.
    ///   - permission: The permission to check. Recognized values (case-insensitive):
    ///     `"READ"`, `"CREATE"`, `"MODIFY"`, `"DELETE"`.
    /// - Returns: `true` if the user has the requested permission for the account
    ///   group, `false` otherwise.
    public func checkPermission(
        userId: UInt64,
        accountGroupId: UInt64,
        permission: String
    ) async -> Bool {
        do {
            // Query the entitlement record for this user-group pair
            guard let entitlement = try await entitlementRepository.findByUserAndGroup(
                userId: userId,
                accountGroupId: accountGroupId
            ) else {
                // No entitlement record exists → no access (Rule 4)
                return false
            }

            // Evaluate the requested permission flag (case-insensitive)
            switch permission.uppercased() {
            case "READ":
                return entitlement.canRead
            case "CREATE":
                return entitlement.canCreate
            case "MODIFY":
                return entitlement.canModify
            case "DELETE":
                return entitlement.canDelete
            default:
                // Unknown permission string → no access
                return false
            }
        } catch {
            // Infrastructure failure (DB error, connection issue, etc.)
            // Rule 4: deny access rather than propagating errors
            return false
        }
    }

    // MARK: - Accessible Group Filtering (Rule 4 — Search Pre-Filter)

    /// Returns all account groups that a user has READ access to.
    ///
    /// Used by `AccountService.search()` to restrict search results to only
    /// those account groups the authenticated user is entitled to view. This
    /// is the primary pre-filter mechanism for Rule 4 compliance across all
    /// search and listing operations.
    ///
    /// **Critical Rule 4 Behavior**: This method **never throws** for
    /// authorization failures. It returns an empty array in all denial
    /// scenarios:
    /// - The user has no entitlement records → `[]`
    /// - The user has entitlements but none with READ access → `[]`
    /// - A database or infrastructure error occurs → `[]`
    ///
    /// The method resolves entitlement account group IDs into fully hydrated
    /// `AccountGroup` objects via `AccountGroupRepository.findByIds`, enabling
    /// callers to display group names and metadata without additional queries.
    ///
    /// - Parameter userId: The unique identifier of the user whose accessible
    ///   groups are being queried.
    /// - Returns: An array of `AccountGroup` objects the user has READ access to.
    ///   Returns an empty array if the user has no readable groups or if an
    ///   error occurs.
    public func filterAccessibleGroups(userId: UInt64) async -> [AccountGroup] {
        do {
            // Retrieve all entitlements for this user
            let entitlements = try await entitlementRepository.findByUserId(userId)

            // Filter to only those entitlements that grant READ access
            let readableGroupIds = entitlements
                .filter { $0.canRead }
                .map { $0.accountGroupId }

            // Short-circuit: no readable groups means empty result (Rule 4)
            guard !readableGroupIds.isEmpty else {
                return []
            }

            // Resolve account group IDs to full AccountGroup objects
            let groups = try await accountGroupRepository.findByIds(readableGroupIds)
            return groups
        } catch {
            // Infrastructure failure → return empty array (Rule 4)
            return []
        }
    }

    // MARK: - Entitlement Assignment (Admin Operations)

    /// Assigns or updates entitlement permissions for a user-group pair.
    ///
    /// This method implements upsert semantics: if an entitlement record already
    /// exists for the specified user-group pair, its permission flags are updated
    /// in place. If no record exists, a new entitlement is created.
    ///
    /// Used by `AdminView` when administrators assign or modify permissions for
    /// a user's access to an account group.
    ///
    /// **Unlike read methods**, this method **does throw** on failure. Write
    /// operations must report errors so administrators can address issues
    /// (e.g., FK constraint violations for nonexistent users or groups).
    ///
    /// - Parameters:
    ///   - userId: The unique identifier of the user receiving the entitlement.
    ///   - accountGroupId: The unique identifier of the target account group.
    ///   - canRead: Whether the user is granted READ access to the group.
    ///   - canCreate: Whether the user is granted CREATE access to the group.
    ///   - canModify: Whether the user is granted MODIFY access to the group.
    ///   - canDelete: Whether the user is granted DELETE access to the group.
    /// - Throws: Database errors including FK constraint violations if the
    ///   referenced user or account group does not exist.
    public func assignEntitlement(
        userId: UInt64,
        accountGroupId: UInt64,
        canRead: Bool,
        canCreate: Bool,
        canModify: Bool,
        canDelete: Bool
    ) async throws {
        // Check if an entitlement already exists for this user-group pair
        if let existing = try await entitlementRepository.findByUserAndGroup(
            userId: userId,
            accountGroupId: accountGroupId
        ) {
            // Update existing entitlement's permission flags in place
            try await entitlementRepository.updatePermissions(
                id: existing.id,
                canRead: canRead,
                canCreate: canCreate,
                canModify: canModify,
                canDelete: canDelete
            )
        } else {
            // Create a new entitlement record for this user-group pair.
            // Uses Persistence.Entitlement (qualified) because the repository's
            // create method accepts its own module's Entitlement type.
            let newEntitlement = Persistence.Entitlement(
                userId: userId,
                accountGroupId: accountGroupId,
                canRead: canRead,
                canCreate: canCreate,
                canModify: canModify,
                canDelete: canDelete
            )
            _ = try await entitlementRepository.create(newEntitlement)
        }
    }

    // MARK: - Entitlement Queries (Admin Display)

    /// Retrieves all entitlements for a specific user.
    ///
    /// Returns the complete set of entitlement records associated with the given
    /// user, including all account groups and their permission flags. Used by
    /// `AdminView` to display the current permission assignments for a user.
    ///
    /// Results are converted from the Persistence module's `Entitlement` type to
    /// the RBAC module's local `Entitlement` type, following the same conversion
    /// pattern established by `AuthenticationService` for `User` types.
    ///
    /// The returned entitlements are ordered by `accountGroupId` ascending, as
    /// determined by the repository layer.
    ///
    /// - Parameter userId: The unique identifier of the user whose entitlements
    ///   are being queried.
    /// - Returns: An array of `RBAC.Entitlement` records for the user. Returns an
    ///   empty array if the user has no entitlements.
    /// - Throws: Database errors if the query cannot be executed.
    public func getEntitlements(userId: UInt64) async throws -> [Entitlement] {
        let persisted = try await entitlementRepository.findByUserId(userId)
        return persisted.map { EntitlementService.convertEntitlement($0) }
    }

    /// Retrieves all entitlements for a specific account group.
    ///
    /// Returns the complete set of entitlement records associated with the given
    /// account group, including all users and their permission flags. Used by
    /// `AdminView` to display which users have access to a particular group and
    /// what permission levels they hold.
    ///
    /// Results are converted from the Persistence module's `Entitlement` type to
    /// the RBAC module's local `Entitlement` type, following the same conversion
    /// pattern established by `AuthenticationService` for `User` types.
    ///
    /// The returned entitlements are ordered by `userId` ascending, as determined
    /// by the repository layer.
    ///
    /// - Parameter accountGroupId: The unique identifier of the account group
    ///   whose entitlements are being queried.
    /// - Returns: An array of `RBAC.Entitlement` records for the account group.
    ///   Returns an empty array if no users have entitlements for this group.
    /// - Throws: Database errors if the query cannot be executed.
    public func getEntitlements(accountGroupId: UInt64) async throws -> [Entitlement] {
        let persisted = try await entitlementRepository.findByAccountGroupId(accountGroupId)
        return persisted.map { EntitlementService.convertEntitlement($0) }
    }

    // MARK: - Entitlement Revocation (Admin Operations)

    /// Removes all entitlement permissions for a user-group pair.
    ///
    /// Completely revokes a user's access to the specified account group by
    /// deleting the entitlement record. After revocation, `checkPermission`
    /// for this user-group pair will return `false` for all permission types,
    /// and `filterAccessibleGroups` will no longer include this group.
    ///
    /// Used by `AdminView` when administrators revoke a user's access to an
    /// account group entirely.
    ///
    /// If no entitlement exists for the given user-group pair, the operation
    /// completes silently (DELETE with no matching rows is a no-op in MySQL).
    ///
    /// - Parameters:
    ///   - userId: The unique identifier of the user whose entitlement is
    ///     being revoked.
    ///   - accountGroupId: The unique identifier of the account group from
    ///     which access is being revoked.
    /// - Throws: Database errors if the deletion cannot be executed.
    public func revokeEntitlement(
        userId: UInt64,
        accountGroupId: UInt64
    ) async throws {
        try await entitlementRepository.deleteByUserAndGroup(
            userId: userId,
            accountGroupId: accountGroupId
        )
    }

    // MARK: - Type Conversion (Persistence → RBAC)

    /// Converts a `Persistence.Entitlement` to the RBAC module's local
    /// `Entitlement` type.
    ///
    /// This follows the same cross-module type conversion pattern established
    /// by `AuthenticationService.convertUser(_:)`. The Persistence module defines
    /// its own `Entitlement` struct to avoid circular dependencies, and this
    /// helper bridges the two structurally identical types so the RBAC module's
    /// public API exposes only its own `Entitlement` type.
    ///
    /// - Parameter persisted: The entitlement record as returned by the
    ///   `EntitlementRepository`.
    /// - Returns: An `RBAC.Entitlement` with all properties copied from the
    ///   Persistence record.
    private static func convertEntitlement(
        _ persisted: Persistence.Entitlement
    ) -> Entitlement {
        Entitlement(
            id: persisted.id,
            userId: persisted.userId,
            accountGroupId: persisted.accountGroupId,
            canRead: persisted.canRead,
            canCreate: persisted.canCreate,
            canModify: persisted.canModify,
            canDelete: persisted.canDelete
        )
    }
}
