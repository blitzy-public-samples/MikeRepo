// Tests/IntegrationTests/RBACIntegrationTests.swift
//
// RBAC Entitlement Integration Tests
//
// Tests entitlement enforcement, user creation with bcrypt password hashing,
// login verification, and entitlement CRUD against a live MySQL `accounting_test` schema.
//
// Rule 4:  Users without READ access receive an empty result set — not an error.
// Rule 8:  MySQLKit-only persistence — no SwiftData anywhere in the project.
// Gate 2:  Swift 6 strict concurrency — zero warnings, zero @unchecked Sendable.
// Gate 10: Tests execute against the `accounting_test` schema via TestDatabaseSetup.

import Testing
import Foundation
@testable import Persistence
@testable import RBAC
@testable import AccountManagement
@testable import Shared

// MARK: - RBAC Integration Test Suite

/// Integration test suite for the RBAC module exercising user management,
/// authentication, and entitlement enforcement against a live MySQL
/// `accounting_test` schema.
///
/// Validates:
/// - User creation with bcrypt password hashing via `AuthenticationService`
/// - Login success and failure paths with bcrypt verification
/// - Duplicate username rejection with `AppError.duplicateUser`
/// - Entitlement assignment with individual READ/CREATE/MODIFY/DELETE flags
/// - **Rule 4 enforcement**: users without READ access receive empty result sets
/// - Entitlement revocation and full lifecycle management
/// - Accessible group filtering per user
/// - Entitlement isolation across independent user-group pairs
///
/// All database operations use MySQLKit repositories exclusively (Rule 8).
/// The `.serialized` trait ensures sequential test execution to prevent
/// race conditions on shared MySQL state.
@Suite("RBAC Integration Tests", .serialized)
struct RBACIntegrationTests {

    // MARK: - Service Factory

    /// Constructs all RBAC and AccountManagement services wired to the test
    /// database connection pool.
    ///
    /// Each test invocation receives fresh service instances backed by the
    /// shared `accounting_test` connection pool. Tables are cleaned before
    /// each test via ``prepareDatabase()`` for complete isolation.
    ///
    /// - Returns: A tuple containing all services needed for RBAC integration
    ///   testing: authentication, entitlement, account group, and account services.
    private func buildServices() -> (
        auth: AuthenticationService,
        entitlement: EntitlementService,
        accountGroup: AccountGroupService,
        account: AccountService
    ) {
        let pool = TestDatabaseSetup.connectionPool!

        // Persistence-layer repositories
        let userRepo = UserRepository(pool: pool)
        let entitlementRepo = EntitlementRepository(pool: pool)
        let accountGroupRepo = AccountGroupRepository(pool: pool)
        let accountRepo = AccountRepository(pool: pool)

        // RBAC services
        let passwordHasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )

        // AccountManagement services
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )

        return (authService, entitlementService, accountGroupService, accountService)
    }

    /// Ensures the test database schema exists and all tables are clean.
    ///
    /// Called at the start of every test function to guarantee:
    /// 1. The `accounting_test` schema is created with all migrations applied
    ///    (lazily initialised once — avoids leaking DatabaseManagers).
    /// 2. All table rows are truncated for test isolation.
    ///
    /// The lazy guard (`connectionPool == nil`) prevents calling `setUp()` on every
    /// test invocation, which would create a new `DatabaseManager` without shutting
    /// down the previous one — leaking NIO `EventLoopGroup` threads and MySQL
    /// connections until the process deadlocks.
    private func prepareDatabase() async throws {
        if TestDatabaseSetup.connectionPool == nil {
            try await TestDatabaseSetup.setUp()
        }
        // Clean ONLY the tables this RBAC test suite uses, not all tables.
        // This prevents cross-suite interference when Swift Testing runs
        // integration test suites concurrently — ReferenceData tests use
        // `reference_data` and RBAC tests use `users`, `entitlements`,
        // `account_groups`, and `accounts`. Truncating only our tables
        // avoids wiping data mid-test in another suite.
        try await cleanRBACTables()
    }

    /// Truncates only the tables used by RBAC integration tests.
    ///
    /// Tables cleaned (in reverse-FK dependency order):
    /// - `accounts` — FK → `account_groups` (used in entitlement enforcement test)
    /// - `entitlements` — FK → `users`, `account_groups`
    /// - `account_groups` — no FK dependencies within this set
    /// - `users` — no FK dependencies
    ///
    /// FK checks are temporarily disabled for safe truncation regardless of order.
    private func cleanRBACTables() async throws {
        guard let pool = TestDatabaseSetup.connectionPool else { return }
        try await pool.withConnection { db in
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    // MARK: - Test 1: User Creation with bcrypt Hashed Password

    /// Validates that `AuthenticationService.createUser` stores a bcrypt-hashed
    /// password — never the plaintext password — and returns a user with a
    /// database-assigned identifier.
    @Test("Create user with bcrypt-hashed password")
    func testUserCreation() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user through AuthenticationService
        let user = try await services.auth.createUser(
            username: "rbac_test_user",
            password: "SecureP@ss123"
        )

        // Verify user was created with a valid database-assigned ID
        #expect(user.id > 0, "User should have a database-assigned ID greater than zero")

        // Verify username matches the input exactly
        #expect(user.username == "rbac_test_user", "Username should match the input")

        // Verify password is stored as a bcrypt hash, NOT plaintext
        #expect(
            user.passwordHash != "SecureP@ss123",
            "Password must not be stored in plaintext"
        )

        // Verify the hash starts with "$2" — the bcrypt algorithm identifier
        // bcrypt hashes always begin with $2a$, $2b$, or $2y$ followed by cost factor
        #expect(
            user.passwordHash.hasPrefix("$2"),
            "Password hash must start with '$2' (bcrypt identifier), got prefix: \(String(user.passwordHash.prefix(4)))"
        )
    }

    // MARK: - Test 2: Login Success with Correct Password

    /// Validates that `AuthenticationService.login` succeeds when provided with
    /// the correct username and password combination, returning the authenticated
    /// user with matching credentials.
    @Test("Login succeeds with correct password")
    func testLoginSuccess() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user with a known password
        let created = try await services.auth.createUser(
            username: "login_success_user",
            password: "CorrectPassword1!"
        )

        // Login with the correct password
        let loggedIn = try await services.auth.login(
            username: "login_success_user",
            password: "CorrectPassword1!"
        )

        // Verify login returned a user (not nil)
        #expect(loggedIn != nil, "Login with correct password must return a User")

        // Verify the returned user identity matches the created user
        if let loggedIn = loggedIn {
            #expect(
                loggedIn.id == created.id,
                "Logged-in user ID must match created user ID"
            )
            #expect(
                loggedIn.username == "login_success_user",
                "Logged-in username must match"
            )
        }
    }

    // MARK: - Test 3: Login Failure with Incorrect Password

    /// Validates that `AuthenticationService.login` returns `nil` when the
    /// password is incorrect, without throwing an error. This confirms that
    /// authentication failures are handled gracefully as expected.
    @Test("Login fails with incorrect password")
    func testLoginFailure() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user with a known password
        _ = try await services.auth.createUser(
            username: "login_fail_user",
            password: "RealPassword1!"
        )

        // Attempt login with the WRONG password
        let result = try await services.auth.login(
            username: "login_fail_user",
            password: "WrongPassword999!"
        )

        // Verify login returned nil (authentication failure — not an error)
        #expect(result == nil, "Login with incorrect password must return nil")
    }

    // MARK: - Test 4: Duplicate Username Rejection

    /// Validates that attempting to create a user with an already-existing username
    /// throws `AppError.duplicateUser`. This tests the uniqueness constraint on the
    /// `users.username` column and its propagation through the service layer.
    @Test("Reject duplicate username creation")
    func testDuplicateUsernameRejection() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create the first user successfully
        _ = try await services.auth.createUser(
            username: "duplicate_user",
            password: "FirstPass1!"
        )

        // Attempt to create another user with the exact same username
        var threwDuplicateError = false
        do {
            _ = try await services.auth.createUser(
                username: "duplicate_user",
                password: "SecondPass2!"
            )
        } catch {
            // Verify the error is specifically AppError.duplicateUser
            if case AppError.duplicateUser = error {
                threwDuplicateError = true
            }
        }

        #expect(
            threwDuplicateError,
            "Creating a user with a duplicate username must throw AppError.duplicateUser"
        )
    }

    // MARK: - Test 5: Assign Entitlement (RCMD Permissions)

    /// Validates that `EntitlementService.assignEntitlement` correctly persists
    /// individual READ/CREATE/MODIFY/DELETE permission flags for a user-group pair,
    /// and that `checkPermission` accurately reports each flag's state.
    @Test("Assign READ/CREATE/MODIFY/DELETE entitlement per user-group pair")
    func testAssignEntitlement() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user and an account group as test fixtures
        let user = try await services.auth.createUser(
            username: "entitlement_user",
            password: "EntPass1!"
        )
        let group = try await services.accountGroup.createGroup(
            name: "Entitlement Test Group"
        )

        // Assign specific permissions: READ=true, CREATE=true, MODIFY=false, DELETE=false
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: false,
            canDelete: false
        )

        // Verify each permission flag individually via checkPermission
        // checkPermission is `async` only (not throws) — returns false on error
        let canRead = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(canRead == true, "User should have READ permission")

        let canCreate = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "CREATE"
        )
        #expect(canCreate == true, "User should have CREATE permission")

        let canModify = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "MODIFY"
        )
        #expect(canModify == false, "User should NOT have MODIFY permission")

        let canDelete = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "DELETE"
        )
        #expect(canDelete == false, "User should NOT have DELETE permission")
    }

    // MARK: - Test 6: Entitlement Enforcement — Empty Results (Rule 4)

    /// **Rule 4 — Core Enforcement Test**
    ///
    /// Validates that a user without READ access to any account group receives
    /// an **empty result set** when searching for accounts — NOT an error, NOT a
    /// partial result. This is the fundamental RBAC contract specified by Rule 4.
    ///
    /// Simultaneously verifies that a user WITH READ access receives the expected
    /// account records from the same data set.
    @Test("User without READ access receives zero records — not error (Rule 4)")
    func testEntitlementEnforcementEmptyResults() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create two users: user1 (entitled), user2 (no entitlements)
        let user1 = try await services.auth.createUser(
            username: "entitled_user",
            password: "EntUser1!"
        )
        let user2 = try await services.auth.createUser(
            username: "no_entitlement_user",
            password: "NoEnt2!"
        )

        // Create an account group
        let group = try await services.accountGroup.createGroup(
            name: "Rule4 Test Group"
        )

        // Assign user1 READ + CREATE permissions on the group
        try await services.entitlement.assignEntitlement(
            userId: user1.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: false,
            canDelete: false
        )
        // user2 intentionally receives NO entitlements whatsoever

        // Create a test account in the group (as user1 who has CREATE permission)
        let testAccount = AccountManagement.Account(
            id: 0,
            name: "Rule4 Test Account",
            fundType: AccountManagement.FundType.etf,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: nil,
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: AccountManagement.AccountStatus.active,
            accountGroupId: group.id,
            createdAt: Date()
        )
        _ = try await services.account.createAccount(testAccount, userId: user1.id)

        // CRITICAL — Rule 4 Verification:
        // Query accounts as user2 (NO entitlements) → MUST receive EMPTY array, NOT an error
        let user2Results = try await services.account.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: user2.id,
            page: 1,
            pageSize: 1000
        )
        #expect(
            user2Results.isEmpty,
            "Rule 4: User without READ access MUST receive an empty result set, not an error. Got \(user2Results.count) records."
        )

        // Verify the entitled user (user1) DOES see the account
        let user1Results = try await services.account.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: user1.id,
            page: 1,
            pageSize: 1000
        )
        #expect(
            !user1Results.isEmpty,
            "User with READ access should receive account results"
        )
        #expect(
            user1Results.count >= 1,
            "User with READ should see at least the one created account"
        )
    }

    // MARK: - Test 7: Revoke Entitlement

    /// Validates that revoking an entitlement via `EntitlementService.revokeEntitlement`
    /// removes all permissions for the user-group pair. After revocation,
    /// `checkPermission` must return `false` for all permission types.
    @Test("Revoke entitlement and verify access removed")
    func testRevokeEntitlement() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create user and group fixtures
        let user = try await services.auth.createUser(
            username: "revoke_test_user",
            password: "RevokePass1!"
        )
        let group = try await services.accountGroup.createGroup(
            name: "Revoke Test Group"
        )

        // Assign READ entitlement
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: false,
            canModify: false,
            canDelete: false
        )

        // Verify user has READ permission BEFORE revocation
        let beforeRevoke = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(beforeRevoke == true, "User should have READ before revocation")

        // Revoke the entire entitlement record
        try await services.entitlement.revokeEntitlement(
            userId: user.id,
            accountGroupId: group.id
        )

        // Verify user NO LONGER has READ permission after revocation
        let afterRevoke = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(afterRevoke == false, "User should NOT have READ after revocation")
    }

    // MARK: - Test 8: Filter Accessible Groups

    /// Validates that `EntitlementService.filterAccessibleGroups` returns only the
    /// account groups for which the user has been granted READ permission. Groups
    /// without any entitlement for the user must be excluded from the result.
    @Test("Filter accessible groups returns only entitled groups")
    func testFilterAccessibleGroups() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user
        let user = try await services.auth.createUser(
            username: "filter_groups_user",
            password: "FilterPass1!"
        )

        // Create two account groups
        let groupA = try await services.accountGroup.createGroup(
            name: "Accessible Group A"
        )
        let groupB = try await services.accountGroup.createGroup(
            name: "Inaccessible Group B"
        )

        // Assign READ permission to user for groupA ONLY
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: groupA.id,
            canRead: true,
            canCreate: false,
            canModify: false,
            canDelete: false
        )
        // user intentionally has NO entitlements for groupB

        // Filter accessible groups for the user
        // filterAccessibleGroups is `async` only (not throws) — returns [] on error
        let accessibleGroups = await services.entitlement.filterAccessibleGroups(
            userId: user.id
        )

        // Extract IDs for comparison (avoids cross-module type mismatch)
        let accessibleIds = accessibleGroups.map { $0.id }

        // Verify only groupA is included
        #expect(
            accessibleIds.contains(groupA.id),
            "Accessible groups should include groupA (user has READ)"
        )
        #expect(
            !accessibleIds.contains(groupB.id),
            "Accessible groups should NOT include groupB (user has no entitlement)"
        )
        #expect(
            accessibleGroups.count == 1,
            "User should have access to exactly 1 group, got \(accessibleGroups.count)"
        )
    }

    // MARK: - Test 9: Entitlement Isolation Across User-Group Pairs

    /// Validates that entitlements are strictly isolated per user-group pair.
    /// User1's entitlement on GroupA must not grant any access to GroupB, and
    /// User2's entitlement on GroupB must not grant any access to GroupA.
    @Test("Entitlements are isolated per user-group pair")
    func testEntitlementIsolation() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create two independent users
        let user1 = try await services.auth.createUser(
            username: "isolation_user1",
            password: "IsoPass1!"
        )
        let user2 = try await services.auth.createUser(
            username: "isolation_user2",
            password: "IsoPass2!"
        )

        // Create two independent account groups
        let groupA = try await services.accountGroup.createGroup(
            name: "Isolation Group A"
        )
        let groupB = try await services.accountGroup.createGroup(
            name: "Isolation Group B"
        )

        // Assign: user1 → groupA (READ), user2 → groupB (READ)
        try await services.entitlement.assignEntitlement(
            userId: user1.id,
            accountGroupId: groupA.id,
            canRead: true,
            canCreate: false,
            canModify: false,
            canDelete: false
        )
        try await services.entitlement.assignEntitlement(
            userId: user2.id,
            accountGroupId: groupB.id,
            canRead: true,
            canCreate: false,
            canModify: false,
            canDelete: false
        )

        // Verify user1 can read groupA but NOT groupB
        let user1ReadA = await services.entitlement.checkPermission(
            userId: user1.id, accountGroupId: groupA.id, permission: "READ"
        )
        #expect(user1ReadA == true, "User1 should have READ on groupA")

        let user1ReadB = await services.entitlement.checkPermission(
            userId: user1.id, accountGroupId: groupB.id, permission: "READ"
        )
        #expect(user1ReadB == false, "User1 should NOT have READ on groupB")

        // Verify user2 can read groupB but NOT groupA
        let user2ReadB = await services.entitlement.checkPermission(
            userId: user2.id, accountGroupId: groupB.id, permission: "READ"
        )
        #expect(user2ReadB == true, "User2 should have READ on groupB")

        let user2ReadA = await services.entitlement.checkPermission(
            userId: user2.id, accountGroupId: groupA.id, permission: "READ"
        )
        #expect(user2ReadA == false, "User2 should NOT have READ on groupA")

        // Cross-verify isolation via filterAccessibleGroups
        let user1Groups = await services.entitlement.filterAccessibleGroups(
            userId: user1.id
        )
        let user1GroupIds = user1Groups.map { $0.id }
        #expect(
            user1GroupIds.contains(groupA.id),
            "User1 accessible groups should include groupA"
        )
        #expect(
            !user1GroupIds.contains(groupB.id),
            "User1 accessible groups should NOT include groupB"
        )

        let user2Groups = await services.entitlement.filterAccessibleGroups(
            userId: user2.id
        )
        let user2GroupIds = user2Groups.map { $0.id }
        #expect(
            user2GroupIds.contains(groupB.id),
            "User2 accessible groups should include groupB"
        )
        #expect(
            !user2GroupIds.contains(groupA.id),
            "User2 accessible groups should NOT include groupA"
        )
    }

    // MARK: - Test 10: Full Entitlement Lifecycle

    /// Validates the complete entitlement lifecycle through three phases:
    /// 1. **Assign** — Grant READ-only permission
    /// 2. **Modify** — Add CREATE permission (upsert semantics)
    /// 3. **Revoke** — Remove all permissions
    ///
    /// Each phase verifies the precise permission state via `checkPermission`
    /// and `filterAccessibleGroups`.
    @Test("Full entitlement lifecycle: assign → modify → revoke")
    func testEntitlementLifecycle() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create user and group fixtures
        let user = try await services.auth.createUser(
            username: "lifecycle_user",
            password: "LifePass1!"
        )
        let group = try await services.accountGroup.createGroup(
            name: "Lifecycle Test Group"
        )

        // ── Phase 1: Assign READ only ──────────────────────────────────
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: false,
            canModify: false,
            canDelete: false
        )

        // Verify: READ=true, CREATE=false
        var hasRead = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(hasRead == true, "Phase 1: User should have READ")

        var hasCreate = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "CREATE"
        )
        #expect(hasCreate == false, "Phase 1: User should NOT have CREATE")

        var hasModify = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "MODIFY"
        )
        #expect(hasModify == false, "Phase 1: User should NOT have MODIFY")

        var hasDelete = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "DELETE"
        )
        #expect(hasDelete == false, "Phase 1: User should NOT have DELETE")

        // ── Phase 2: Modify — add CREATE permission (upsert) ──────────
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: false,
            canDelete: false
        )

        // Verify: READ=true, CREATE=true, MODIFY=false, DELETE=false
        hasRead = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(hasRead == true, "Phase 2: User should still have READ")

        hasCreate = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "CREATE"
        )
        #expect(hasCreate == true, "Phase 2: User should now have CREATE")

        hasModify = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "MODIFY"
        )
        #expect(hasModify == false, "Phase 2: User should NOT have MODIFY")

        hasDelete = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "DELETE"
        )
        #expect(hasDelete == false, "Phase 2: User should NOT have DELETE")

        // Verify group is accessible
        let midLifecycleGroups = await services.entitlement.filterAccessibleGroups(
            userId: user.id
        )
        #expect(
            midLifecycleGroups.count == 1,
            "Phase 2: User should have exactly 1 accessible group"
        )

        // ── Phase 3: Revoke all permissions ───────────────────────────
        try await services.entitlement.revokeEntitlement(
            userId: user.id,
            accountGroupId: group.id
        )

        // Verify: all permissions revoked
        hasRead = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "READ"
        )
        #expect(hasRead == false, "Phase 3: User should NOT have READ after revocation")

        hasCreate = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "CREATE"
        )
        #expect(hasCreate == false, "Phase 3: User should NOT have CREATE after revocation")

        hasModify = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "MODIFY"
        )
        #expect(hasModify == false, "Phase 3: User should NOT have MODIFY after revocation")

        hasDelete = await services.entitlement.checkPermission(
            userId: user.id, accountGroupId: group.id, permission: "DELETE"
        )
        #expect(hasDelete == false, "Phase 3: User should NOT have DELETE after revocation")

        // Verify no accessible groups remain
        let postRevokeGroups = await services.entitlement.filterAccessibleGroups(
            userId: user.id
        )
        #expect(
            postRevokeGroups.isEmpty,
            "Phase 3: After full revocation, user should have zero accessible groups"
        )
    }
}
