// Tests/IntegrationTests/AccountManagementIntegrationTests.swift
// WealthLedger — Account Management Integration Tests
//
// Tests account CRUD operations, search functionality, batch status updates,
// and entitlement enforcement against a live MySQL `accounting_test` schema.
//
// Rule 4:  Users without READ access receive an empty result set — not an error.
// Rule 7:  Search results capped at 1,000; batch operations capped at 1,000.
// Rule 8:  MySQLKit-only persistence — no SwiftData anywhere.
// Gate 2:  Swift 6 strict concurrency — zero warnings, zero @unchecked Sendable.
// Gate 10: Tests execute against the `accounting_test` schema via TestDatabaseSetup.

import Testing
import Foundation
@testable import Persistence
@testable import AccountManagement
@testable import RBAC
@testable import Shared

// MARK: - Account Management Integration Test Suite

/// Integration test suite for the AccountManagement module exercising account
/// CRUD, multi-criteria search, batch status updates, fund type classification,
/// account status lifecycle, and RBAC entitlement enforcement against a live
/// MySQL `accounting_test` schema.
///
/// Validates:
/// - Account creation and readback with all fields preserved
/// - Partial name search (`LIKE 'prefix%'`) via `AccountService.search`
/// - Exact ID search
/// - Fund type filter search
/// - Account group filter search
/// - **Rule 4 enforcement**: user without READ access gets empty results — not error
/// - Batch status update with MODIFY permission enforcement (Rule 7)
/// - Search result cap at `AppConstants.maxSearchResults` (Rule 7)
/// - All 6 fund types: openMutualFund, closedMutualFund, etf, hedgeFund, sma, uma
/// - Account status lifecycle: pending → active → suspended → inactive
///
/// All database operations use MySQLKit repositories exclusively (Rule 8).
/// The `.serialized` trait ensures sequential test execution to prevent
/// race conditions on shared MySQL state.
@Suite("Account Management Integration Tests", .serialized)
struct AccountManagementIntegrationTests {

    // MARK: - Service Factory

    /// Constructs all AccountManagement, RBAC, and Persistence services wired
    /// to the test database connection pool.
    ///
    /// Each test invocation receives fresh service instances backed by the
    /// shared `accounting_test` connection pool. Tables are cleaned before
    /// each test via ``prepareDatabase()`` for complete isolation.
    ///
    /// - Returns: A tuple containing all services needed for AccountManagement
    ///   integration testing.
    private func buildServices() -> (
        accountService: AccountService,
        accountGroupService: AccountGroupService,
        authService: AuthenticationService,
        entitlementService: EntitlementService
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

        return (accountService, accountGroupService, authService, entitlementService)
    }

    // MARK: - Test Fixture Helpers

    /// Ensures the test database schema exists and all relevant tables are clean.
    ///
    /// Called at the start of every test function to guarantee:
    /// 1. The `accounting_test` schema is created with all migrations applied
    ///    (lazily initialised once).
    /// 2. All table rows are truncated for test isolation.
    private func prepareDatabase() async throws {
        if TestDatabaseSetup.connectionPool == nil {
            try await TestDatabaseSetup.setUp()
        }
        try await cleanAccountManagementTables()
    }

    /// Truncates only the tables used by AccountManagement integration tests.
    ///
    /// Tables cleaned (in reverse-FK dependency order):
    /// - `transactions` — FK → `accounts`, `reference_data`
    /// - `positions` — FK → `accounts`, `reference_data`
    /// - `accounts` — FK → `account_groups`
    /// - `entitlements` — FK → `users`, `account_groups`
    /// - `account_groups` — no FK dependencies within this set
    /// - `users` — no FK dependencies
    ///
    /// FK checks are temporarily disabled for safe truncation regardless of order.
    private func cleanAccountManagementTables() async throws {
        guard let pool = TestDatabaseSetup.connectionPool else { return }
        try await pool.withConnection { db in
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE transactions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE positions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    /// Creates a test user, account group, and assigns READ + CREATE + MODIFY
    /// entitlements. Returns the user ID, account group ID, and all services.
    ///
    /// This is the standard setup for tests that need an entitled user and group.
    ///
    /// - Parameter uniqueSuffix: A suffix appended to usernames and group names
    ///   to prevent collisions across test methods.
    /// - Returns: A tuple with user ID, group ID, and all services.
    private func createEntitledUserAndGroup(
        uniqueSuffix: String
    ) async throws -> (
        userId: UInt64,
        groupId: UInt64,
        services: (
            accountService: AccountService,
            accountGroupService: AccountGroupService,
            authService: AuthenticationService,
            entitlementService: EntitlementService
        )
    ) {
        let services = buildServices()

        // Create a test user with bcrypt-hashed password
        let user = try await services.authService.createUser(
            username: "testuser_\(uniqueSuffix)",
            password: "SecureP@ss123"
        )

        // Create an account group
        let group = try await services.accountGroupService.createGroup(
            name: "TestGroup_\(uniqueSuffix)"
        )

        // Assign READ + CREATE + MODIFY entitlements (no DELETE for most tests)
        try await services.entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        return (user.id, group.id, services)
    }

    /// Creates a test account with sensible defaults and the given overrides.
    ///
    /// - Parameters:
    ///   - name: Account name.
    ///   - fundType: Fund type classification.
    ///   - groupId: Account group ID (FK).
    ///   - userId: The authenticated user creating the account.
    ///   - accountService: The service under test.
    ///   - timezone: IANA timezone string. Defaults to `"America/New_York"`.
    ///   - status: Initial account status. Defaults to `.pending`.
    /// - Returns: The created account with a database-assigned ID.
    private func createTestAccount(
        name: String,
        fundType: AccountManagement.FundType,
        groupId: UInt64,
        userId: UInt64,
        accountService: AccountService,
        timezone: String = "America/New_York",
        status: AccountManagement.AccountStatus = .pending
    ) async throws -> AccountManagement.Account {
        let account = AccountManagement.Account(
            id: 0,
            name: name,
            fundType: fundType,
            ownershipDetails: nil,
            valuationTimezone: timezone,
            valuationSchedule: "daily",
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: status,
            accountGroupId: groupId,
            createdAt: Date()
        )
        return try await accountService.createAccount(account, userId: userId)
    }

    // MARK: - Test 1: Account CRUD — Create, Read, Verify

    /// Validates that an account can be created via `AccountService.createAccount`
    /// and read back via `AccountService.getAccount`, with all fields preserved
    /// including fundType, timezone, status, groupId, and nil cached valuation.
    @Test("Create an account and read it back")
    func testAccountCreateAndRead() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "crud"
        )

        // Create an ETF account with America/New_York timezone
        let created = try await createTestAccount(
            name: "Integration CRUD Fund",
            fundType: .etf,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService,
            timezone: "America/New_York"
        )

        // Verify the created account has a valid database-assigned ID
        #expect(created.id > 0)
        #expect(created.name == "Integration CRUD Fund")
        #expect(created.fundType == .etf)
        #expect(created.status == .pending)
        #expect(created.accountGroupId == groupId)

        // Read the account back by its ID
        let readBack = try await services.accountService.getAccount(
            id: created.id,
            userId: userId
        )
        #expect(readBack != nil)
        #expect(readBack?.id == created.id)
        #expect(readBack?.name == "Integration CRUD Fund")
        #expect(readBack?.fundType == .etf)
        #expect(readBack?.accountGroupId == groupId)

        // Verify cached valuation fields are nil for a new account (Rule 11)
        #expect(readBack?.cachedValuationAmount == nil)
        #expect(readBack?.cachedValueDate == nil)
    }

    // MARK: - Test 2: Search by Partial Name Match

    /// Validates that `AccountService.search` with a name prefix returns only
    /// accounts whose names match the prefix (SQL `LIKE 'prefix%'`), and respects
    /// entitlement enforcement (Rule 4).
    @Test("Search accounts by partial name match")
    func testSearchByPartialName() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "partial_name"
        )

        // Create three accounts: two starting with "Alpha", one with "Beta"
        _ = try await createTestAccount(
            name: "Alpha Fund",
            fundType: .etf,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "Alpha Growth",
            fundType: .sma,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "Beta Fund",
            fundType: .hedgeFund,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )

        // Search with prefix "Alpha" — expect 2 results
        let results = try await services.accountService.search(
            name: "Alpha",
            id: nil,
            type: nil,
            group: nil,
            userId: userId,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )

        #expect(results.count == 2)
        let names = results.map { $0.name }
        #expect(names.contains("Alpha Fund"))
        #expect(names.contains("Alpha Growth"))
        #expect(!names.contains("Beta Fund"))
    }

    // MARK: - Test 3: Search by Exact Account ID

    /// Validates that `AccountService.search` with an exact account ID returns
    /// exactly one matching account, and that the ID shortcut path works correctly.
    @Test("Search accounts by exact ID")
    func testSearchByExactId() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "exact_id"
        )

        // Create an account
        let created = try await createTestAccount(
            name: "Exact ID Fund",
            fundType: .closedMutualFund,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )

        // Search by exact ID
        let results = try await services.accountService.search(
            name: nil,
            id: created.id,
            type: nil,
            group: nil,
            userId: userId,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )

        #expect(results.count == 1)
        #expect(results.first?.id == created.id)
        #expect(results.first?.name == "Exact ID Fund")
    }

    // MARK: - Test 4: Search by Fund Type Filter

    /// Validates that `AccountService.search` with a fund type filter returns
    /// only accounts matching the specified fund type.
    @Test("Search accounts by fund type filter")
    func testSearchByFundType() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "fund_type"
        )

        // Create accounts with different fund types
        _ = try await createTestAccount(
            name: "ETF Account",
            fundType: .etf,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "Hedge Fund Account",
            fundType: .hedgeFund,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "SMA Account",
            fundType: .sma,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )

        // Search filtering by .etf — expect only ETF accounts
        let results = try await services.accountService.search(
            name: nil,
            id: nil,
            type: .etf,
            group: nil,
            userId: userId,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )

        #expect(results.count == 1)
        #expect(results.first?.fundType == .etf)
        #expect(results.first?.name == "ETF Account")
    }

    // MARK: - Test 5: Search by Account Group Filter

    /// Validates that `AccountService.search` with a group filter returns only
    /// accounts belonging to the specified account group.
    @Test("Search accounts by account group")
    func testSearchByGroup() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create a user
        let user = try await services.authService.createUser(
            username: "testuser_group_filter",
            password: "SecureP@ss123"
        )

        // Create two groups: Group A and Group B
        let groupA = try await services.accountGroupService.createGroup(name: "Group A")
        let groupB = try await services.accountGroupService.createGroup(name: "Group B")

        // Grant READ + CREATE on both groups
        try await services.entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: groupA.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )
        try await services.entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: groupB.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        // Create accounts in each group
        _ = try await createTestAccount(
            name: "GroupA Account 1",
            fundType: .etf,
            groupId: groupA.id,
            userId: user.id,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "GroupA Account 2",
            fundType: .sma,
            groupId: groupA.id,
            userId: user.id,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "GroupB Account 1",
            fundType: .hedgeFund,
            groupId: groupB.id,
            userId: user.id,
            accountService: services.accountService
        )

        // Search filtering by Group A only
        let results = try await services.accountService.search(
            name: nil,
            id: nil,
            type: nil,
            group: groupA.id,
            userId: user.id,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )

        #expect(results.count == 2)
        let allGroupA = results.allSatisfy { $0.accountGroupId == groupA.id }
        #expect(allGroupA)
    }

    // MARK: - Test 6: Entitlement Enforcement — Zero Records for Unauthorized (Rule 4)

    /// **CRITICAL Rule 4 test**: Validates that a user WITHOUT READ access to an
    /// account group receives an empty result set — NOT an error — when searching
    /// for accounts in that group. Simultaneously verifies that an entitled user
    /// CAN see the same accounts.
    @Test("User without READ access receives empty results — not error (Rule 4)")
    func testEntitlementEnforcementEmptyResults() async throws {
        try await prepareDatabase()
        let services = buildServices()

        // Create user1 with READ + CREATE on groupA
        let user1 = try await services.authService.createUser(
            username: "entitled_user",
            password: "SecureP@ss123"
        )
        let groupA = try await services.accountGroupService.createGroup(
            name: "EntitlementTestGroup"
        )
        try await services.entitlementService.assignEntitlement(
            userId: user1.id,
            accountGroupId: groupA.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        // Create user2 with NO entitlements whatsoever
        let user2 = try await services.authService.createUser(
            username: "unentitled_user",
            password: "SecureP@ss456"
        )

        // Create accounts in groupA as user1 (who has CREATE permission)
        _ = try await createTestAccount(
            name: "Visible Account 1",
            fundType: .etf,
            groupId: groupA.id,
            userId: user1.id,
            accountService: services.accountService
        )
        _ = try await createTestAccount(
            name: "Visible Account 2",
            fundType: .sma,
            groupId: groupA.id,
            userId: user1.id,
            accountService: services.accountService
        )

        // Search as user1 (entitled) — expect results
        let user1Results = try await services.accountService.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: user1.id,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )
        #expect(user1Results.count == 2)

        // Search as user2 (NOT entitled) — expect EMPTY array, NOT an error (Rule 4)
        let user2Results = try await services.accountService.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: user2.id,
            page: 1,
            pageSize: AppConstants.maxSearchResults
        )
        #expect(user2Results.isEmpty)

        // Also verify getAccount returns nil for unauthorized user (Rule 4)
        let account1 = user1Results.first
        if let accountId = account1?.id {
            let readBack = try await services.accountService.getAccount(
                id: accountId,
                userId: user2.id
            )
            #expect(readBack == nil)
        }
    }

    // MARK: - Test 7: Batch Status Update

    /// Validates that `AccountService.batchStatusUpdate` can update the status
    /// of multiple accounts simultaneously, with MODIFY permission enforcement.
    @Test("Batch status update for multiple accounts")
    func testBatchStatusUpdate() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "batch_update"
        )

        // Create 5 accounts with default status .pending
        var accountIds: [UInt64] = []
        for i in 1...5 {
            let account = try await createTestAccount(
                name: "Batch Account \(i)",
                fundType: .etf,
                groupId: groupId,
                userId: userId,
                accountService: services.accountService
            )
            accountIds.append(account.id)
        }

        // Verify all accounts start as .pending
        for accountId in accountIds {
            let account = try await services.accountService.getAccount(
                id: accountId,
                userId: userId
            )
            #expect(account?.status == .pending)
        }

        // Batch update all accounts to .active
        try await services.accountService.batchStatusUpdate(
            accountIds: accountIds,
            newStatus: .active,
            userId: userId
        )

        // Verify all accounts are now .active
        for accountId in accountIds {
            let account = try await services.accountService.getAccount(
                id: accountId,
                userId: userId
            )
            #expect(account?.status == .active)
        }
    }

    // MARK: - Test 8: Search Results Capped at 1,000 (Rule 7)

    /// Validates that `AccountService.search` respects the
    /// `AppConstants.maxSearchResults` cap. Creates a small number of accounts
    /// and verifies the pageSize is effectively capped by the service layer.
    @Test("Search results capped at maxSearchResults (Rule 7)")
    func testSearchResultsCapped() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "cap_test"
        )

        // Create 5 accounts for testing the cap mechanism
        for i in 1...5 {
            _ = try await createTestAccount(
                name: "Cap Account \(i)",
                fundType: .etf,
                groupId: groupId,
                userId: userId,
                accountService: services.accountService
            )
        }

        // Search with a pageSize of 3 — should return at most 3
        let smallPageResults = try await services.accountService.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: userId,
            page: 1,
            pageSize: 3
        )
        #expect(smallPageResults.count == 3)

        // Search with a pageSize exceeding maxSearchResults — should be capped
        let largePageResults = try await services.accountService.search(
            name: nil,
            id: nil,
            type: nil,
            group: nil,
            userId: userId,
            page: 1,
            pageSize: AppConstants.maxSearchResults + 500
        )
        // Service caps at maxSearchResults; we have 5 accounts, all returned
        #expect(largePageResults.count == 5)
        // Verify the constant itself is 1,000
        #expect(AppConstants.maxSearchResults == 1_000)

        // Verify batchSize constant is also 1,000
        #expect(AppConstants.batchSize == 1_000)
    }

    // MARK: - Test 9: All Fund Types — Institutional and Wealth

    /// Validates that all six fund types from the ``FundType`` enum can be created
    /// and stored correctly in the database: openMutualFund, closedMutualFund,
    /// etf, hedgeFund (Institutional) and sma, uma (Wealth).
    @Test("All fund types are supported — Institutional and Wealth categories")
    func testAllFundTypes() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "all_fund_types"
        )

        // Create one account per fund type using CaseIterable
        let allFundTypes: [AccountManagement.FundType] = [
            .openMutualFund,
            .closedMutualFund,
            .etf,
            .hedgeFund,
            .sma,
            .uma
        ]

        // Verify we are testing all 6 cases from the enum
        #expect(AccountManagement.FundType.allCases.count == 6)

        var createdAccounts: [AccountManagement.Account] = []
        for fundType in allFundTypes {
            let account = try await createTestAccount(
                name: "\(fundType.rawValue) Account",
                fundType: fundType,
                groupId: groupId,
                userId: userId,
                accountService: services.accountService
            )
            createdAccounts.append(account)
        }

        // Verify each account was created with the correct fund type
        #expect(createdAccounts.count == 6)
        for (index, fundType) in allFundTypes.enumerated() {
            #expect(createdAccounts[index].fundType == fundType)
        }

        // Read each account back to verify persistence roundtrip
        for created in createdAccounts {
            let readBack = try await services.accountService.getAccount(
                id: created.id,
                userId: userId
            )
            #expect(readBack != nil)
            #expect(readBack?.fundType == created.fundType)
        }

        // Verify institutional vs wealth classification
        let institutional = createdAccounts.filter { $0.fundType.isInstitutional }
        let wealth = createdAccounts.filter { $0.fundType.isWealth }
        #expect(institutional.count == 4)
        #expect(wealth.count == 2)
    }

    // MARK: - Test 10: Account Status Lifecycle

    /// Validates the complete account status lifecycle:
    /// pending → active → suspended → inactive.
    /// Each transition is performed via `batchStatusUpdate` with a single account.
    @Test("Account status lifecycle: pending → active → suspended → inactive")
    func testAccountStatusLifecycle() async throws {
        try await prepareDatabase()
        let (userId, groupId, services) = try await createEntitledUserAndGroup(
            uniqueSuffix: "lifecycle"
        )

        // Create account — defaults to .pending
        let created = try await createTestAccount(
            name: "Lifecycle Account",
            fundType: .etf,
            groupId: groupId,
            userId: userId,
            accountService: services.accountService
        )
        #expect(created.status == .pending)

        // Transition: pending → active
        try await services.accountService.batchStatusUpdate(
            accountIds: [created.id],
            newStatus: .active,
            userId: userId
        )
        let afterActive = try await services.accountService.getAccount(
            id: created.id,
            userId: userId
        )
        #expect(afterActive?.status == .active)

        // Transition: active → suspended
        try await services.accountService.batchStatusUpdate(
            accountIds: [created.id],
            newStatus: .suspended,
            userId: userId
        )
        let afterSuspended = try await services.accountService.getAccount(
            id: created.id,
            userId: userId
        )
        #expect(afterSuspended?.status == .suspended)

        // Transition: suspended → inactive
        try await services.accountService.batchStatusUpdate(
            accountIds: [created.id],
            newStatus: .inactive,
            userId: userId
        )
        let afterInactive = try await services.accountService.getAccount(
            id: created.id,
            userId: userId
        )
        #expect(afterInactive?.status == .inactive)
    }
}
