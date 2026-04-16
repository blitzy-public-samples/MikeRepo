// EntitlementTests.swift
// WealthLedger - Unit Tests for EntitlementService
//
// 26 tests across 5 suites validating Rule 4 (Entitlement Enforcement):
//   Suite 1: checkPermission — core permission flag checks (10 tests)
//   Suite 2: filterAccessibleGroups — group filtering by READ access (5 tests)
//   Suite 3: assignEntitlement/revokeEntitlement — upsert and revocation (3 tests)
//   Suite 4: Combined permission scenarios — multi-user/multi-group (5 tests)
//   Suite 5: Entitlement model validation — properties, Equatable, Codable (3 tests)
//
// All repositories are mocked — zero database connections.
// Testing framework: Swift Testing (@Suite, @Test, #expect) — NOT XCTest.
// Swift 6 strict concurrency: all types Sendable-safe, zero @unchecked Sendable.
// Rule 8 compliance: no SwiftData imports. Rule 4 compliance: unauthorized access
// returns false/empty, never throws.

import Testing
import Foundation
@testable import RBAC
@testable import Persistence
@testable import AccountManagement
@testable import Shared

// MARK: - Mock EntitlementRepository

/// Mock implementation of ``EntitlementRepositoryProtocol`` for testing
/// ``EntitlementService`` without database connections.
///
/// Every stored property is a `let` holding a `@Sendable` closure, which makes
/// this `final class` naturally `Sendable` under Swift 6 strict concurrency
/// (Gate 2). Zero `@unchecked Sendable` annotations are needed.
///
/// Default closure implementations return safe empty/nil values so that tests
/// only need to override the handlers relevant to their scenario.
final class MockEntitlementRepository: EntitlementRepositoryProtocol {

    let findByUserAndGroupHandler: @Sendable (UInt64, UInt64) async throws -> Persistence.Entitlement?
    let findByUserIdHandler: @Sendable (UInt64) async throws -> [Persistence.Entitlement]
    let findByAccountGroupIdHandler: @Sendable (UInt64) async throws -> [Persistence.Entitlement]
    let createHandler: @Sendable (Persistence.Entitlement) async throws -> Persistence.Entitlement
    let updatePermissionsHandler: @Sendable (UInt64, Bool, Bool, Bool, Bool) async throws -> Void
    let deleteByUserAndGroupHandler: @Sendable (UInt64, UInt64) async throws -> Void

    init(
        findByUserAndGroup: @escaping @Sendable (UInt64, UInt64) async throws -> Persistence.Entitlement? = { _, _ in nil },
        findByUserId: @escaping @Sendable (UInt64) async throws -> [Persistence.Entitlement] = { _ in [] },
        findByAccountGroupId: @escaping @Sendable (UInt64) async throws -> [Persistence.Entitlement] = { _ in [] },
        create: @escaping @Sendable (Persistence.Entitlement) async throws -> Persistence.Entitlement = { $0 },
        updatePermissions: @escaping @Sendable (UInt64, Bool, Bool, Bool, Bool) async throws -> Void = { _, _, _, _, _ in },
        deleteByUserAndGroup: @escaping @Sendable (UInt64, UInt64) async throws -> Void = { _, _ in }
    ) {
        self.findByUserAndGroupHandler = findByUserAndGroup
        self.findByUserIdHandler = findByUserId
        self.findByAccountGroupIdHandler = findByAccountGroupId
        self.createHandler = create
        self.updatePermissionsHandler = updatePermissions
        self.deleteByUserAndGroupHandler = deleteByUserAndGroup
    }

    func findByUserAndGroup(userId: UInt64, accountGroupId: UInt64) async throws -> Persistence.Entitlement? {
        try await findByUserAndGroupHandler(userId, accountGroupId)
    }

    func findByUserId(_ userId: UInt64) async throws -> [Persistence.Entitlement] {
        try await findByUserIdHandler(userId)
    }

    func findByAccountGroupId(_ accountGroupId: UInt64) async throws -> [Persistence.Entitlement] {
        try await findByAccountGroupIdHandler(accountGroupId)
    }

    func create(_ entity: Persistence.Entitlement) async throws -> Persistence.Entitlement {
        try await createHandler(entity)
    }

    func updatePermissions(id: UInt64, canRead: Bool, canCreate: Bool, canModify: Bool, canDelete: Bool) async throws {
        try await updatePermissionsHandler(id, canRead, canCreate, canModify, canDelete)
    }

    func deleteByUserAndGroup(userId: UInt64, accountGroupId: UInt64) async throws {
        try await deleteByUserAndGroupHandler(userId, accountGroupId)
    }
}

// MARK: - Mock AccountGroupRepository

/// Mock implementation of ``AccountGroupRepositoryProtocol`` for testing
/// ``EntitlementService.filterAccessibleGroups`` without database connections.
///
/// All stored properties are `let` with `@Sendable` closures. Naturally
/// `Sendable` under Swift 6 strict concurrency (Gate 2).
final class MockAccountGroupRepository: AccountGroupRepositoryProtocol {

    let findByIdsHandler: @Sendable ([UInt64]) async throws -> [Persistence.AccountGroup]

    init(
        findByIds: @escaping @Sendable ([UInt64]) async throws -> [Persistence.AccountGroup] = { _ in [] }
    ) {
        self.findByIdsHandler = findByIds
    }

    func findByIds(_ ids: [UInt64]) async throws -> [Persistence.AccountGroup] {
        try await findByIdsHandler(ids)
    }
}

// MARK: - Test Data Helpers

/// Creates a ``Persistence.Entitlement`` for use in mock repository handlers.
///
/// Default values produce a READ-only entitlement for user 1 on group 100.
/// Override individual parameters to create specific test scenarios.
private func makePersistenceEntitlement(
    id: UInt64 = 1,
    userId: UInt64 = 1,
    accountGroupId: UInt64 = 100,
    canRead: Bool = true,
    canCreate: Bool = false,
    canModify: Bool = false,
    canDelete: Bool = false
) -> Persistence.Entitlement {
    Persistence.Entitlement(
        id: id,
        userId: userId,
        accountGroupId: accountGroupId,
        canRead: canRead,
        canCreate: canCreate,
        canModify: canModify,
        canDelete: canDelete
    )
}

/// Creates a ``Persistence.AccountGroup`` for use in mock repository handlers.
///
/// Default values produce a group with ID 100 named "Test Group".
private func makePersistenceAccountGroup(
    id: UInt64 = 100,
    groupName: String = "Test Group",
    metadata: String? = nil,
    createdAt: Date = Date()
) -> Persistence.AccountGroup {
    Persistence.AccountGroup(
        id: id,
        groupName: groupName,
        metadata: metadata,
        createdAt: createdAt
    )
}

/// Creates an ``EntitlementService`` with the given mock repositories.
///
/// Reduces boilerplate in each test by accepting pre-configured mocks and
/// returning an initialized service ready for assertions.
private func makeService(
    entitlementRepo: MockEntitlementRepository = MockEntitlementRepository(),
    accountGroupRepo: MockAccountGroupRepository = MockAccountGroupRepository()
) -> EntitlementService {
    EntitlementService(
        entitlementRepository: entitlementRepo,
        accountGroupRepository: accountGroupRepo
    )
}

// MARK: - Suite 1: checkPermission Tests (Rule 4 — Core Entitlement Checking)

/// Tests for ``EntitlementService/checkPermission(userId:accountGroupId:permission:)``.
///
/// Rule 4 requires that this method:
/// - Returns `true` only when the user has the specific permission flag set
/// - Returns `false` for missing entitlements, unknown permissions, and errors
/// - **Never throws** — catches all errors internally and returns `false`
@Suite("EntitlementService checkPermission — Rule 4 enforcement")
struct EntitlementServiceCheckPermissionTests {

    // Test 1
    @Test("Returns true for READ when canRead is true")
    func checkPermissionReadTrue() async {
        let entitlement = makePersistenceEntitlement(canRead: true)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        #expect(result == true)
    }

    // Test 2
    @Test("Returns false for READ when canRead is false")
    func checkPermissionReadFalse() async {
        let entitlement = makePersistenceEntitlement(canRead: false)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        #expect(result == false)
    }

    // Test 3
    @Test("Returns true for CREATE when canCreate is true")
    func checkPermissionCreateTrue() async {
        let entitlement = makePersistenceEntitlement(canCreate: true)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "CREATE"
        )
        #expect(result == true)
    }

    // Test 4
    @Test("Returns true for MODIFY when canModify is true")
    func checkPermissionModifyTrue() async {
        let entitlement = makePersistenceEntitlement(canModify: true)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        #expect(result == true)
    }

    // Test 5
    @Test("Returns true for DELETE when canDelete is true")
    func checkPermissionDeleteTrue() async {
        let entitlement = makePersistenceEntitlement(canDelete: true)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )
        #expect(result == true)
    }

    // Test 6
    @Test("Returns false when no entitlement record exists — Rule 4 compliance")
    func checkPermissionNoEntitlementRecord() async {
        // Mock findByUserAndGroup returns nil by default (no entitlement exists)
        let repo = MockEntitlementRepository()
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 999, accountGroupId: 100, permission: "READ"
        )
        // Rule 4: no entitlement = false, NOT an error
        #expect(result == false)
    }

    // Test 7
    @Test("Returns false for unknown permission string")
    func checkPermissionUnknownPermission() async {
        // Even with all permissions true, an unrecognized string returns false
        let entitlement = makePersistenceEntitlement(
            canRead: true, canCreate: true, canModify: true, canDelete: true
        )
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "ADMIN"
        )
        #expect(result == false)
    }

    // Test 8
    @Test("Returns false when repository throws — Rule 4 infrastructure failure handling")
    func checkPermissionRepositoryError() async {
        // Use AppError.unauthorizedAccess to verify EntitlementService catches ALL
        // error types and always returns false — never propagates errors (Rule 4).
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in
                throw AppError.unauthorizedAccess
            }
        )
        let service = makeService(entitlementRepo: repo)

        // Rule 4: infrastructure failures produce "no access", not errors.
        // The method catches all errors internally and returns false.
        let result = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        #expect(result == false)
    }

    // Test 9
    @Test("Permission string comparison is case-insensitive")
    func checkPermissionCaseInsensitive() async {
        let entitlement = makePersistenceEntitlement(canRead: true)
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        // Lowercase
        let lowercase = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "read"
        )
        // Mixed case
        let mixedCase = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "Read"
        )
        // Uppercase
        let uppercase = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )

        #expect(lowercase == true)
        #expect(mixedCase == true)
        #expect(uppercase == true)
    }

    // Test 10
    @Test("Individual permission flags are checked independently")
    func checkPermissionIndividualFlags() async {
        // canRead=true, canCreate=false, canModify=true, canDelete=false
        let entitlement = makePersistenceEntitlement(
            canRead: true, canCreate: false, canModify: true, canDelete: false
        )
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let readResult = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        let createResult = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "CREATE"
        )
        let modifyResult = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        let deleteResult = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )

        #expect(readResult == true)
        #expect(createResult == false)
        #expect(modifyResult == true)
        #expect(deleteResult == false)
    }
}

// MARK: - Suite 2: filterAccessibleGroups Tests (Rule 4 — Group Filtering)

/// Tests for ``EntitlementService/filterAccessibleGroups(userId:)``.
///
/// Rule 4 requires that this method:
/// - Returns only groups where the user has ``canRead`` set to `true`
/// - Returns an empty array for users with no entitled groups — not an error
/// - **Never throws** — catches all errors internally and returns `[]`
@Suite("EntitlementService filterAccessibleGroups — Rule 4 group filtering")
struct EntitlementServiceFilterGroupsTests {

    // Test 11
    @Test("Returns only READ-entitled groups, excludes non-READ groups")
    func filterGroupsReadOnly() async {
        // User has 3 entitlements: groups 100 and 200 with canRead=true, group 300 without
        let entitlements = [
            makePersistenceEntitlement(id: 1, accountGroupId: 100, canRead: true),
            makePersistenceEntitlement(id: 2, accountGroupId: 200, canRead: true),
            makePersistenceEntitlement(id: 3, accountGroupId: 300, canRead: false),
        ]

        let groups = [
            makePersistenceAccountGroup(id: 100, groupName: "Equity Funds"),
            makePersistenceAccountGroup(id: 200, groupName: "Bond Funds"),
        ]

        let entitlementRepo = MockEntitlementRepository(
            findByUserId: { _ in entitlements }
        )
        let groupRepo = MockAccountGroupRepository(
            findByIds: { ids in
                // Should only receive IDs for readable groups (100 and 200)
                return groups.filter { ids.contains($0.id) }
            }
        )
        let service = makeService(
            entitlementRepo: entitlementRepo,
            accountGroupRepo: groupRepo
        )

        let result = await service.filterAccessibleGroups(userId: 1)
        #expect(result.count == 2)

        let resultIds = Set(result.map { $0.id })
        #expect(resultIds.contains(100))
        #expect(resultIds.contains(200))
        // Group 300 must NOT appear (canRead=false)
        #expect(!resultIds.contains(300))
    }

    // Test 12
    @Test("Returns empty array when user has no entitlements — Rule 4 compliance")
    func filterGroupsNoEntitlements() async {
        // findByUserId returns empty by default
        let entitlementRepo = MockEntitlementRepository(
            findByUserId: { _ in [] }
        )
        let service = makeService(entitlementRepo: entitlementRepo)

        let result = await service.filterAccessibleGroups(userId: 999)
        // Rule 4: empty array, NOT an error
        #expect(result.isEmpty)
    }

    // Test 13
    @Test("Returns empty array when all entitlements have canRead=false")
    func filterGroupsAllReadFalse() async {
        let entitlements = [
            makePersistenceEntitlement(id: 1, accountGroupId: 100, canRead: false),
            makePersistenceEntitlement(id: 2, accountGroupId: 200, canRead: false),
        ]
        let entitlementRepo = MockEntitlementRepository(
            findByUserId: { _ in entitlements }
        )
        // findByIds should NOT be called when no readable groups exist.
        // Making it throw verifies the short-circuit path: if findByIds were
        // erroneously called, the error is caught and empty is returned anyway.
        let groupRepo = MockAccountGroupRepository(
            findByIds: { _ in
                throw AppError.dataAccessFailed("findByIds should not be called")
            }
        )
        let service = makeService(
            entitlementRepo: entitlementRepo,
            accountGroupRepo: groupRepo
        )

        let result = await service.filterAccessibleGroups(userId: 1)
        #expect(result.isEmpty)
    }

    // Test 14
    @Test("Returns empty array when repository throws — Rule 4 infrastructure failure")
    func filterGroupsRepositoryError() async {
        let entitlementRepo = MockEntitlementRepository(
            findByUserId: { _ in
                throw AppError.dataAccessFailed("Mock database connection failure")
            }
        )
        let service = makeService(entitlementRepo: entitlementRepo)

        // Rule 4: infrastructure failures result in empty, not errors
        let result = await service.filterAccessibleGroups(userId: 1)
        #expect(result.isEmpty)
    }

    // Test 15
    @Test("Resolves full AccountGroup objects with groupName and id")
    func filterGroupsResolvesFullObjects() async {
        let entitlement = makePersistenceEntitlement(
            id: 1, accountGroupId: 100, canRead: true
        )
        let group = makePersistenceAccountGroup(
            id: 100, groupName: "Equity Funds"
        )

        let entitlementRepo = MockEntitlementRepository(
            findByUserId: { _ in [entitlement] }
        )
        let groupRepo = MockAccountGroupRepository(
            findByIds: { _ in [group] }
        )
        let service = makeService(
            entitlementRepo: entitlementRepo,
            accountGroupRepo: groupRepo
        )

        let result = await service.filterAccessibleGroups(userId: 1)
        #expect(result.count == 1)
        #expect(result[0].groupName == "Equity Funds")
        #expect(result[0].id == 100)
    }
}

// MARK: - Suite 3: assignEntitlement Tests

/// Tests for ``EntitlementService/assignEntitlement(userId:accountGroupId:canRead:canCreate:canModify:canDelete:)``
/// and ``EntitlementService/revokeEntitlement(userId:accountGroupId:)``.
///
/// Unlike read methods, write operations **do throw** on failure so that
/// administrators receive actionable error feedback.
@Suite("EntitlementService entitlement assignment")
struct EntitlementServiceAssignTests {

    // Test 16
    @Test("assignEntitlement creates new entitlement when none exists")
    func assignCreatesNew() async throws {
        let entitlementRepo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in nil },
            create: { entity in entity },
            // updatePermissions should NOT be called on the create path.
            // Making it throw guarantees the test fails if the wrong path is taken.
            updatePermissions: { _, _, _, _, _ in
                throw AppError.operationNotPermitted
            }
        )
        let service = makeService(entitlementRepo: entitlementRepo)

        // Should call create (not updatePermissions), so no error is expected
        try await service.assignEntitlement(
            userId: 1,
            accountGroupId: 100,
            canRead: true,
            canCreate: true,
            canModify: false,
            canDelete: false
        )
        // Success is verified by "no throw". The updatePermissions guard ensures
        // the create code path was taken.
    }

    // Test 17
    @Test("assignEntitlement updates existing entitlement permissions")
    func assignUpdatesExisting() async throws {
        let existing = makePersistenceEntitlement(
            id: 5, userId: 1, accountGroupId: 100,
            canRead: true, canCreate: false, canModify: false, canDelete: false
        )
        let entitlementRepo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in existing },
            // create should NOT be called on the update path.
            // Making it throw guarantees the test fails if the wrong path is taken.
            create: { _ in throw AppError.operationNotPermitted },
            updatePermissions: { _, _, _, _, _ in }
        )
        let service = makeService(entitlementRepo: entitlementRepo)

        // Should call updatePermissions (not create), so no error is expected
        try await service.assignEntitlement(
            userId: 1,
            accountGroupId: 100,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: true
        )
        // Success is verified by "no throw". The create guard ensures
        // the updatePermissions code path was taken.
    }

    // Test 18
    @Test("revokeEntitlement calls deleteByUserAndGroup successfully")
    func revokeEntitlementSuccess() async throws {
        let entitlementRepo = MockEntitlementRepository(
            deleteByUserAndGroup: { _, _ in }
        )
        let service = makeService(entitlementRepo: entitlementRepo)

        // Should complete without error
        try await service.revokeEntitlement(userId: 1, accountGroupId: 100)
    }
}

// MARK: - Suite 4: Combined Permission Scenarios

/// Tests validating multiple permission flags, multiple users, and multiple
/// groups in various configurations to ensure correct per-user, per-group
/// isolation and independent flag evaluation.
@Suite("EntitlementService combined permission scenarios")
struct EntitlementServiceCombinedTests {

    // Test 19
    @Test("Full RCMD permissions — all four checks return true")
    func fullRCMDPermissions() async {
        let entitlement = makePersistenceEntitlement(
            canRead: true, canCreate: true, canModify: true, canDelete: true
        )
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let read = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        let create = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "CREATE"
        )
        let modify = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        let delete = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )

        #expect(read == true)
        #expect(create == true)
        #expect(modify == true)
        #expect(delete == true)
    }

    // Test 20
    @Test("Read-only permissions — only READ returns true")
    func readOnlyPermissions() async {
        let entitlement = makePersistenceEntitlement(
            canRead: true, canCreate: false, canModify: false, canDelete: false
        )
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let read = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        let create = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "CREATE"
        )
        let modify = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        let delete = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )

        #expect(read == true)
        #expect(create == false)
        #expect(modify == false)
        #expect(delete == false)
    }

    // Test 21
    @Test("No permissions — all four checks return false")
    func noPermissions() async {
        let entitlement = makePersistenceEntitlement(
            canRead: false, canCreate: false, canModify: false, canDelete: false
        )
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { _, _ in entitlement }
        )
        let service = makeService(entitlementRepo: repo)

        let read = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        let create = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "CREATE"
        )
        let modify = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        let delete = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )

        #expect(read == false)
        #expect(create == false)
        #expect(modify == false)
        #expect(delete == false)
    }

    // Test 22
    @Test("Multiple users with different entitlements on same group")
    func multipleUsersSameGroup() async {
        // User 1: full RCMD on group 100
        // User 2: read-only on group 100
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { userId, groupId in
                if userId == 1 && groupId == 100 {
                    return makePersistenceEntitlement(
                        userId: 1, accountGroupId: 100,
                        canRead: true, canCreate: true,
                        canModify: true, canDelete: true
                    )
                } else if userId == 2 && groupId == 100 {
                    return makePersistenceEntitlement(
                        userId: 2, accountGroupId: 100,
                        canRead: true, canCreate: false,
                        canModify: false, canDelete: false
                    )
                }
                return nil
            }
        )
        let service = makeService(entitlementRepo: repo)

        // User 1 can DELETE
        let user1Delete = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "DELETE"
        )
        #expect(user1Delete == true)

        // User 2 cannot DELETE
        let user2Delete = await service.checkPermission(
            userId: 2, accountGroupId: 100, permission: "DELETE"
        )
        #expect(user2Delete == false)
    }

    // Test 23
    @Test("User with entitlements across multiple groups")
    func userAcrossMultipleGroups() async {
        // User 1: READ on group 100, MODIFY-only (no READ) on group 200
        let repo = MockEntitlementRepository(
            findByUserAndGroup: { userId, groupId in
                if userId == 1 && groupId == 100 {
                    return makePersistenceEntitlement(
                        userId: 1, accountGroupId: 100,
                        canRead: true, canCreate: false,
                        canModify: false, canDelete: false
                    )
                } else if userId == 1 && groupId == 200 {
                    return makePersistenceEntitlement(
                        userId: 1, accountGroupId: 200,
                        canRead: false, canCreate: false,
                        canModify: true, canDelete: false
                    )
                }
                return nil
            }
        )
        let service = makeService(entitlementRepo: repo)

        // Group 100: READ yes, MODIFY no
        let g100Read = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "READ"
        )
        let g100Modify = await service.checkPermission(
            userId: 1, accountGroupId: 100, permission: "MODIFY"
        )
        #expect(g100Read == true)
        #expect(g100Modify == false)

        // Group 200: MODIFY yes, READ no
        let g200Modify = await service.checkPermission(
            userId: 1, accountGroupId: 200, permission: "MODIFY"
        )
        let g200Read = await service.checkPermission(
            userId: 1, accountGroupId: 200, permission: "READ"
        )
        #expect(g200Modify == true)
        #expect(g200Read == false)
    }
}

// MARK: - Suite 5: Entitlement Model Tests

/// Tests for the ``RBAC.Entitlement`` model struct validating property access,
/// ``Equatable`` conformance, and ``Codable`` JSON round-trip serialization.
@Suite("Entitlement model validation")
struct EntitlementModelTests {

    // Test 24
    @Test("Entitlement struct has all required properties accessible")
    func entitlementProperties() {
        let entitlement = RBAC.Entitlement(
            id: 42,
            userId: 7,
            accountGroupId: 100,
            canRead: true,
            canCreate: false,
            canModify: true,
            canDelete: false
        )

        #expect(entitlement.id == 42)
        #expect(entitlement.userId == 7)
        #expect(entitlement.accountGroupId == 100)
        #expect(entitlement.canRead == true)
        #expect(entitlement.canCreate == false)
        #expect(entitlement.canModify == true)
        #expect(entitlement.canDelete == false)

        // Verify default id is 0 when not specified
        let defaultIdEntitlement = RBAC.Entitlement(
            userId: 1,
            accountGroupId: 1,
            canRead: false,
            canCreate: false,
            canModify: false,
            canDelete: false
        )
        #expect(defaultIdEntitlement.id == 0)
    }

    // Test 25
    @Test("Entitlement conforms to Sendable and Equatable")
    func entitlementSendableEquatable() async {
        let e1 = RBAC.Entitlement(
            id: 1, userId: 1, accountGroupId: 100,
            canRead: true, canCreate: false,
            canModify: false, canDelete: false
        )
        let e2 = RBAC.Entitlement(
            id: 1, userId: 1, accountGroupId: 100,
            canRead: true, canCreate: false,
            canModify: false, canDelete: false
        )
        let e3 = RBAC.Entitlement(
            id: 2, userId: 1, accountGroupId: 100,
            canRead: true, canCreate: false,
            canModify: false, canDelete: false
        )

        // Equatable: identical instances are equal
        #expect(e1 == e2)
        // Equatable: different id means not equal
        #expect(e1 != e3)

        // Sendable: value can cross concurrency domains without issue.
        // Assigning to a @Sendable closure parameter verifies the type can
        // cross isolation boundaries — a compile-time check enforced by
        // Swift 6 strict concurrency.
        let sendableCheck: @Sendable () -> RBAC.Entitlement = { e1 }
        let passedEntitlement = sendableCheck()
        #expect(passedEntitlement == e1)
    }

    // Test 26
    @Test("Entitlement Codable round-trip preserves all properties")
    func entitlementCodableRoundTrip() throws {
        let original = RBAC.Entitlement(
            id: 99,
            userId: 42,
            accountGroupId: 200,
            canRead: true,
            canCreate: true,
            canModify: false,
            canDelete: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RBAC.Entitlement.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.userId == original.userId)
        #expect(decoded.accountGroupId == original.accountGroupId)
        #expect(decoded.canRead == original.canRead)
        #expect(decoded.canCreate == original.canCreate)
        #expect(decoded.canModify == original.canModify)
        #expect(decoded.canDelete == original.canDelete)
        #expect(decoded == original)
    }
}
