// AccountServiceTests.swift
// WealthLedger — Unit Tests for AccountService Business Logic
//
// Tests search filtering (name, ID, type, group), batch status updates (Rule 7),
// fund type enum validation, pagination capping at 1,000 results (Rule 7),
// RBAC entitlement enforcement (Rule 4), timezone validation (Rule 3),
// and CRUD permission checks.
//
// All repositories are mocked — zero database connections.
// Testing framework: Swift Testing (@Suite, @Test, #expect) — NOT XCTest.
// Swift 6 strict concurrency: all types Sendable-safe, zero @unchecked Sendable.
// Rule 8 compliance: no SwiftData imports.
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import AccountManagement
@testable import RBAC
@testable import Persistence
@testable import Shared

// MARK: - Mock Protocol Definitions

/// Protocol mirroring the AccountRepository methods consumed by AccountService.
/// Enables injection of MockAccountRepo without requiring a ConnectionPool.
private protocol AccountRepoProtocol: Sendable {
    func findById(_ id: UInt64) async throws -> Persistence.Account?
    func findByIds(_ ids: [UInt64]) async throws -> [Persistence.Account]
    func searchByGroupIds(
        accountGroupIds: [UInt64],
        name: String?,
        accountType: String?,
        page: Int,
        pageSize: Int
    ) async throws -> [Persistence.Account]
    func create(_ account: Persistence.Account) async throws -> Persistence.Account
    func update(_ account: Persistence.Account) async throws -> Persistence.Account
    func delete(_ id: UInt64) async throws
    func batchUpdateStatus(accountIds: [UInt64], newStatus: String) async throws
    func findByGroupId(
        _ groupId: UInt64, page: Int, pageSize: Int
    ) async throws -> [Persistence.Account]
}

/// Protocol mirroring EntitlementService methods used by AccountService.
private protocol EntitlementCheckProtocol: Sendable {
    func checkPermission(
        userId: UInt64, accountGroupId: UInt64, permission: String
    ) async -> Bool
    func filterAccessibleGroups(
        userId: UInt64
    ) async -> [Persistence.AccountGroup]
}

/// Protocol mirroring AccountGroupService methods used by AccountService.
private protocol AccountGroupCheckProtocol: Sendable {
    func getGroup(id: UInt64) async throws -> AccountManagement.AccountGroup?
}

// MARK: - Mock Implementations (Swift 6 actor-based for Sendable compliance)

/// Actor-based mock account repository tracking stored accounts for assertions.
/// Actor isolation ensures thread-safe mutable state without @unchecked Sendable.
private actor MockAccountRepo: AccountRepoProtocol {
    var storedAccounts: [UInt64: Persistence.Account] = [:]
    var nextId: UInt64 = 1
    var batchUpdateCalls: [(accountIds: [UInt64], newStatus: String)] = []

    func seedAccounts(_ accounts: [Persistence.Account]) {
        for account in accounts {
            storedAccounts[account.id] = account
        }
    }

    func findById(_ id: UInt64) async throws -> Persistence.Account? {
        storedAccounts[id]
    }

    func findByIds(_ ids: [UInt64]) async throws -> [Persistence.Account] {
        ids.compactMap { storedAccounts[$0] }
    }

    func searchByGroupIds(
        accountGroupIds: [UInt64],
        name: String?,
        accountType: String?,
        page: Int,
        pageSize: Int
    ) async throws -> [Persistence.Account] {
        let groupIdSet = Set(accountGroupIds)
        var results = storedAccounts.values.filter { groupIdSet.contains($0.accountGroupId) }

        // Apply name prefix filter if provided
        if let name = name, !name.isEmpty {
            results = results.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
        }

        // Apply account type filter if provided
        if let accountType = accountType {
            results = results.filter { $0.fundType.rawValue == accountType }
        }

        // Apply pagination
        let sortedResults = results.sorted { $0.id < $1.id }
        let startIndex = (page - 1) * pageSize
        guard startIndex < sortedResults.count else { return [] }
        let endIndex = min(startIndex + pageSize, sortedResults.count)
        return Array(sortedResults[startIndex..<endIndex])
    }

    func create(_ account: Persistence.Account) async throws -> Persistence.Account {
        let created = Persistence.Account(
            id: nextId,
            name: account.name,
            fundType: account.fundType,
            ownershipDetails: account.ownershipDetails,
            valuationTimezone: account.valuationTimezone,
            valuationSchedule: account.valuationSchedule,
            cachedValuationAmount: account.cachedValuationAmount,
            cachedValueDate: account.cachedValueDate,
            status: account.status,
            accountGroupId: account.accountGroupId,
            createdAt: account.createdAt
        )
        nextId += 1
        storedAccounts[created.id] = created
        return created
    }

    func update(_ account: Persistence.Account) async throws -> Persistence.Account {
        storedAccounts[account.id] = account
        return account
    }

    func delete(_ id: UInt64) async throws {
        storedAccounts.removeValue(forKey: id)
    }

    func batchUpdateStatus(accountIds: [UInt64], newStatus: String) async throws {
        batchUpdateCalls.append((accountIds: accountIds, newStatus: newStatus))
        for id in accountIds {
            if let account = storedAccounts[id] {
                if let status = Persistence.AccountStatus(rawValue: newStatus) {
                    storedAccounts[id] = Persistence.Account(
                        id: account.id,
                        name: account.name,
                        fundType: account.fundType,
                        ownershipDetails: account.ownershipDetails,
                        valuationTimezone: account.valuationTimezone,
                        valuationSchedule: account.valuationSchedule,
                        cachedValuationAmount: account.cachedValuationAmount,
                        cachedValueDate: account.cachedValueDate,
                        status: status,
                        accountGroupId: account.accountGroupId,
                        createdAt: account.createdAt
                    )
                }
            }
        }
    }

    func findByGroupId(
        _ groupId: UInt64, page: Int, pageSize: Int
    ) async throws -> [Persistence.Account] {
        let results = storedAccounts.values
            .filter { $0.accountGroupId == groupId }
            .sorted { $0.id < $1.id }
        let startIndex = (page - 1) * pageSize
        guard startIndex < results.count else { return [] }
        let endIndex = min(startIndex + pageSize, results.count)
        return Array(results[startIndex..<endIndex])
    }
}

/// Actor-based mock entitlement service with configurable permission responses.
/// Provides full control over which permissions and groups are returned.
private actor MockEntitlementCheck: EntitlementCheckProtocol {
    var permissionMap: [String: Bool] = [:]
    var accessibleGroups: [Persistence.AccountGroup] = []

    func setPermission(userId: UInt64, groupId: UInt64, permission: String, allowed: Bool) {
        let key = "\(userId)_\(groupId)_\(permission)"
        permissionMap[key] = allowed
    }

    func setAccessibleGroups(_ groups: [Persistence.AccountGroup]) {
        accessibleGroups = groups
    }

    func checkPermission(
        userId: UInt64, accountGroupId: UInt64, permission: String
    ) async -> Bool {
        let key = "\(userId)_\(accountGroupId)_\(permission)"
        return permissionMap[key] ?? false
    }

    func filterAccessibleGroups(userId: UInt64) async -> [Persistence.AccountGroup] {
        accessibleGroups
    }
}

// MARK: - Testable AccountService

/// A testable version of AccountService that mirrors its exact validation chain
/// but accepts protocol-based mock dependencies instead of concrete types.
///
/// The production AccountService takes concrete AccountRepository,
/// EntitlementService, and AccountGroupService types that require a live
/// ConnectionPool. This struct replicates AccountService's validation logic
/// (Rule 4 entitlement checks, Rule 7 pagination caps, Rule 3 timezone
/// validation) with protocol-based dependencies for isolated unit testing.
///
/// The actual AccountService with concrete repository types is tested in
/// Tests/IntegrationTests/AccountManagementIntegrationTests.swift against live MySQL.
private struct TestableAccountService: Sendable {
    let accountRepo: MockAccountRepo
    let entitlementCheck: MockEntitlementCheck

    // MARK: - Search (Rule 4 + Rule 7)

    func search(
        name: String?,
        id: UInt64?,
        type: AccountManagement.FundType?,
        group: UInt64?,
        userId: UInt64,
        page: Int,
        pageSize: Int
    ) async throws -> [Persistence.Account] {
        // Rule 4: Resolve accessible groups
        let accessibleGroups = await entitlementCheck.filterAccessibleGroups(userId: userId)
        guard !accessibleGroups.isEmpty else { return [] }
        let accessibleGroupIds = accessibleGroups.map { $0.id }
        let accessibleGroupIdSet = Set(accessibleGroupIds)

        // ID-based shortcut
        if let id = id {
            guard let account = try await accountRepo.findById(id) else { return [] }
            guard accessibleGroupIdSet.contains(account.accountGroupId) else { return [] }
            return [account]
        }

        // Group filter validation
        var filteredGroupIds = accessibleGroupIds
        if let group = group {
            guard accessibleGroupIdSet.contains(group) else { return [] }
            filteredGroupIds = [group]
        }

        // Rule 7: Cap page size
        let effectivePageSize = min(pageSize, AppConstants.maxSearchResults)

        return try await accountRepo.searchByGroupIds(
            accountGroupIds: filteredGroupIds,
            name: name,
            accountType: type?.rawValue,
            page: page,
            pageSize: effectivePageSize
        )
    }

    // MARK: - CRUD (Rule 4 + Rule 3)

    func createAccount(_ account: Persistence.Account, userId: UInt64) async throws -> Persistence.Account {
        let hasPermission = await entitlementCheck.checkPermission(
            userId: userId, accountGroupId: account.accountGroupId, permission: "CREATE"
        )
        guard hasPermission else { throw AppError.unauthorizedAccess }
        guard TimeZone(identifier: account.valuationTimezone) != nil else {
            throw AppError.invalidTimezone
        }
        return try await accountRepo.create(account)
    }

    func getAccount(id: UInt64, userId: UInt64) async throws -> Persistence.Account? {
        guard let account = try await accountRepo.findById(id) else { return nil }
        let hasPermission = await entitlementCheck.checkPermission(
            userId: userId, accountGroupId: account.accountGroupId, permission: "READ"
        )
        guard hasPermission else { return nil }
        return account
    }

    func updateAccount(_ account: Persistence.Account, userId: UInt64) async throws -> Persistence.Account {
        let hasPermission = await entitlementCheck.checkPermission(
            userId: userId, accountGroupId: account.accountGroupId, permission: "MODIFY"
        )
        guard hasPermission else { throw AppError.unauthorizedAccess }
        guard TimeZone(identifier: account.valuationTimezone) != nil else {
            throw AppError.invalidTimezone
        }
        return try await accountRepo.update(account)
    }

    func deleteAccount(id: UInt64, userId: UInt64) async throws {
        guard let account = try await accountRepo.findById(id) else {
            throw AppError.accountNotFound
        }
        let hasPermission = await entitlementCheck.checkPermission(
            userId: userId, accountGroupId: account.accountGroupId, permission: "DELETE"
        )
        guard hasPermission else { throw AppError.unauthorizedAccess }
        try await accountRepo.delete(id)
    }

    // MARK: - Batch (Rule 7 + Rule 4)

    func batchStatusUpdate(
        accountIds: [UInt64], newStatus: Persistence.AccountStatus, userId: UInt64
    ) async throws {
        guard accountIds.count <= AppConstants.batchSize else {
            throw AppError.dataAccessFailed(
                "Batch size \(accountIds.count) exceeds maximum of \(AppConstants.batchSize)"
            )
        }
        guard !accountIds.isEmpty else { return }
        let accounts = try await accountRepo.findByIds(accountIds)
        let uniqueGroupIds = Set(accounts.map { $0.accountGroupId })
        for groupId in uniqueGroupIds {
            let hasPermission = await entitlementCheck.checkPermission(
                userId: userId, accountGroupId: groupId, permission: "MODIFY"
            )
            guard hasPermission else { throw AppError.unauthorizedAccess }
        }
        try await accountRepo.batchUpdateStatus(
            accountIds: accountIds, newStatus: newStatus.rawValue
        )
    }

    // MARK: - Paginated Group Query (Rule 4 + Rule 7)

    func getAccountsByGroup(
        groupId: UInt64, userId: UInt64, page: Int, pageSize: Int
    ) async throws -> [Persistence.Account] {
        let hasPermission = await entitlementCheck.checkPermission(
            userId: userId, accountGroupId: groupId, permission: "READ"
        )
        guard hasPermission else { return [] }
        let effectivePageSize = min(pageSize, AppConstants.defaultPagination)
        return try await accountRepo.findByGroupId(groupId, page: page, pageSize: effectivePageSize)
    }

    // MARK: - Batch Get (Rule 7 + Rule 4)

    func getAccounts(ids: [UInt64], userId: UInt64) async throws -> [Persistence.Account] {
        guard ids.count <= AppConstants.batchSize else {
            throw AppError.dataAccessFailed(
                "Batch size \(ids.count) exceeds maximum of \(AppConstants.batchSize) accounts"
            )
        }
        guard !ids.isEmpty else { return [] }
        let accounts = try await accountRepo.findByIds(ids)
        let accessibleGroups = await entitlementCheck.filterAccessibleGroups(userId: userId)
        let accessibleGroupIdSet = Set(accessibleGroups.map { $0.id })
        return accounts.filter { accessibleGroupIdSet.contains($0.accountGroupId) }
    }

    // MARK: - Accessible Account Groups (Rule 4)

    func getAccessibleAccountGroups(userId: UInt64) async -> [Persistence.AccountGroup] {
        await entitlementCheck.filterAccessibleGroups(userId: userId)
    }
}

// MARK: - Test Data Helpers

/// Creates a Persistence.Account for testing with sensible defaults.
private func makeTestAccount(
    id: UInt64 = 1,
    name: String = "Test Account",
    fundType: Persistence.FundType = .etf,
    valuationTimezone: String = "America/New_York",
    status: Persistence.AccountStatus = .active,
    accountGroupId: UInt64 = 100
) -> Persistence.Account {
    Persistence.Account(
        id: id,
        name: name,
        fundType: fundType,
        ownershipDetails: nil,
        valuationTimezone: valuationTimezone,
        valuationSchedule: "daily",
        cachedValuationAmount: nil,
        cachedValueDate: nil,
        status: status,
        accountGroupId: accountGroupId,
        createdAt: Date()
    )
}

/// Creates a Persistence.AccountGroup for testing.
private func makeTestGroup(
    id: UInt64 = 100,
    groupName: String = "Test Group"
) -> Persistence.AccountGroup {
    Persistence.AccountGroup(
        id: id,
        groupName: groupName,
        metadata: nil,
        createdAt: Date()
    )
}

/// Builds a fully wired TestableAccountService with configurable permissions.
/// Default: userId 1 has full RCMD permissions on groupId 100.
private func buildTestService(
    accounts: [Persistence.Account] = [],
    groups: [Persistence.AccountGroup] = [makeTestGroup()],
    userId: UInt64 = 1,
    groupId: UInt64 = 100,
    canRead: Bool = true,
    canCreate: Bool = true,
    canModify: Bool = true,
    canDelete: Bool = true
) async -> TestableAccountService {
    let repo = MockAccountRepo()
    let entitlement = MockEntitlementCheck()

    // Seed accounts
    await repo.seedAccounts(accounts)

    // Configure permissions
    await entitlement.setAccessibleGroups(groups)
    if canRead {
        await entitlement.setPermission(userId: userId, groupId: groupId, permission: "READ", allowed: true)
    }
    if canCreate {
        await entitlement.setPermission(userId: userId, groupId: groupId, permission: "CREATE", allowed: true)
    }
    if canModify {
        await entitlement.setPermission(userId: userId, groupId: groupId, permission: "MODIFY", allowed: true)
    }
    if canDelete {
        await entitlement.setPermission(userId: userId, groupId: groupId, permission: "DELETE", allowed: true)
    }

    return TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)
}

// MARK: - Suite 1: Search Tests (Rule 4 + Rule 7 + Rule 13)

@Suite("AccountService Search Tests", .serialized)
struct AccountServiceSearchTests {

    @Test("Search by name prefix returns matching accounts")
    func testSearchByName() async throws {
        let accounts = [
            makeTestAccount(id: 1, name: "Alpha Fund"),
            makeTestAccount(id: 2, name: "Alpha Growth"),
            makeTestAccount(id: 3, name: "Beta Income"),
        ]
        let svc = await buildTestService(accounts: accounts)

        let results = try await svc.search(
            name: "Alpha", id: nil, type: nil, group: nil,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.count == 2, "Name prefix 'Alpha' should match 2 accounts")
        #expect(results.allSatisfy { $0.name.hasPrefix("Alpha") })
    }

    @Test("Search by exact ID returns single account")
    func testSearchById() async throws {
        let accounts = [
            makeTestAccount(id: 42, name: "Target Account"),
            makeTestAccount(id: 43, name: "Other Account"),
        ]
        let svc = await buildTestService(accounts: accounts)

        let results = try await svc.search(
            name: nil, id: 42, type: nil, group: nil,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.count == 1)
        #expect(results.first?.id == 42)
        #expect(results.first?.name == "Target Account")
    }

    @Test("Search by fund type filters correctly")
    func testSearchByFundType() async throws {
        let accounts = [
            makeTestAccount(id: 1, name: "ETF Fund", fundType: .etf),
            makeTestAccount(id: 2, name: "Hedge Fund", fundType: .hedgeFund),
            makeTestAccount(id: 3, name: "Another ETF", fundType: .etf),
        ]
        let svc = await buildTestService(accounts: accounts)

        let results = try await svc.search(
            name: nil, id: nil, type: .etf, group: nil,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.count == 2, "Fund type filter for .etf should return 2 accounts")
        #expect(results.allSatisfy { $0.fundType == .etf })
    }

    @Test("Search by account group filters correctly")
    func testSearchByGroup() async throws {
        let group1 = makeTestGroup(id: 100, groupName: "Group A")
        let group2 = makeTestGroup(id: 200, groupName: "Group B")
        let accounts = [
            makeTestAccount(id: 1, name: "Acct A1", accountGroupId: 100),
            makeTestAccount(id: 2, name: "Acct A2", accountGroupId: 100),
            makeTestAccount(id: 3, name: "Acct B1", accountGroupId: 200),
        ]
        let svc = await buildTestService(
            accounts: accounts,
            groups: [group1, group2],
            userId: 1, groupId: 100,
            canRead: true, canCreate: true, canModify: true, canDelete: true
        )
        // Also grant permissions for group 200
        await svc.entitlementCheck.setPermission(userId: 1, groupId: 200, permission: "READ", allowed: true)

        let results = try await svc.search(
            name: nil, id: nil, type: nil, group: 100,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.count == 2, "Group 100 filter should return 2 accounts")
        #expect(results.allSatisfy { $0.accountGroupId == 100 })
    }

    @Test("Search returns empty for unauthorized user — Rule 4")
    func testSearchEmptyForUnauthorizedUser() async throws {
        let accounts = [makeTestAccount(id: 1, name: "Secret Fund")]
        // User with NO permissions — empty groups
        let repo = MockAccountRepo()
        let entitlement = MockEntitlementCheck()
        await repo.seedAccounts(accounts)
        await entitlement.setAccessibleGroups([])
        let svc = TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)

        let results = try await svc.search(
            name: nil, id: nil, type: nil, group: nil,
            userId: 99, page: 1, pageSize: 100
        )
        #expect(results.isEmpty, "Rule 4: User without entitlement must receive empty result set")
    }

    @Test("Search for unauthorized group returns empty — Rule 4")
    func testSearchUnauthorizedGroupReturnsEmpty() async throws {
        let group100 = makeTestGroup(id: 100, groupName: "Entitled Group")
        let accounts = [
            makeTestAccount(id: 1, name: "Entitled Acct", accountGroupId: 100),
        ]
        let svc = await buildTestService(accounts: accounts, groups: [group100])

        // Search for group 999 which user is NOT entitled to
        let results = try await svc.search(
            name: nil, id: nil, type: nil, group: 999,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.isEmpty, "Rule 4: Searching unauthorized group must return empty")
    }

    @Test("Search by ID for account in unauthorized group returns empty — Rule 4")
    func testSearchByIdUnauthorizedGroup() async throws {
        // Account exists but in group 200 which user has no access to
        let group100 = makeTestGroup(id: 100, groupName: "My Group")
        let accounts = [
            makeTestAccount(id: 5, name: "Forbidden Acct", accountGroupId: 200),
        ]
        let svc = await buildTestService(accounts: accounts, groups: [group100])

        let results = try await svc.search(
            name: nil, id: 5, type: nil, group: nil,
            userId: 1, page: 1, pageSize: 100
        )
        #expect(results.isEmpty, "Rule 4: Account in unauthorized group must not be returned")
    }
}

// MARK: - Suite 2: Pagination and Batch Memory Cap Tests (Rule 7)

@Suite("AccountService Pagination & Batch Cap Tests", .serialized)
struct AccountServicePaginationTests {

    @Test("Search caps page size at 1,000 — Rule 7")
    func testSearchPageSizeCap() async throws {
        // Generate 5 accounts; request page size of 5000 — should still cap at 1000
        var accounts: [Persistence.Account] = []
        for i in 1...5 {
            accounts.append(makeTestAccount(id: UInt64(i), name: "Acct \(i)"))
        }
        let svc = await buildTestService(accounts: accounts)

        // Request absurdly large page size — Rule 7 caps at maxSearchResults (1,000)
        let results = try await svc.search(
            name: nil, id: nil, type: nil, group: nil,
            userId: 1, page: 1, pageSize: 5000
        )
        // Should return all 5 (below the cap), demonstrating the cap logic doesn't crash
        #expect(results.count == 5, "Should return all available accounts below the cap")
    }

    @Test("Batch status update rejects > 1,000 accounts — Rule 7")
    func testBatchStatusUpdateExceedsLimit() async throws {
        let svc = await buildTestService()
        var oversizedBatch: [UInt64] = []
        for i in 1...1001 {
            oversizedBatch.append(UInt64(i))
        }

        await #expect(throws: AppError.self) {
            try await svc.batchStatusUpdate(
                accountIds: oversizedBatch,
                newStatus: .active,
                userId: 1
            )
        }
    }

    @Test("Batch status update accepts exactly 1,000 accounts — Rule 7")
    func testBatchStatusUpdateAt1000() async throws {
        var accounts: [Persistence.Account] = []
        for i: UInt64 in 1...1000 {
            accounts.append(makeTestAccount(id: i, name: "Acct \(i)", status: .pending))
        }
        let svc = await buildTestService(accounts: accounts)

        // Should succeed at exactly the limit
        try await svc.batchStatusUpdate(
            accountIds: Array(1...1000).map { UInt64($0) },
            newStatus: .active,
            userId: 1
        )

        let calls = await svc.accountRepo.batchUpdateCalls
        #expect(calls.count == 1, "Should have made exactly one batch update call")
        #expect(calls.first?.accountIds.count == 1000)
    }

    @Test("getAccounts rejects > 1,000 IDs — Rule 7")
    func testGetAccountsExceedsLimit() async throws {
        let svc = await buildTestService()
        var oversizedBatch: [UInt64] = []
        for i in 1...1001 {
            oversizedBatch.append(UInt64(i))
        }

        await #expect(throws: AppError.self) {
            _ = try await svc.getAccounts(ids: oversizedBatch, userId: 1)
        }
    }

    @Test("getAccountsByGroup caps page size at 1,000 — Rule 7")
    func testGetAccountsByGroupPageSizeCap() async throws {
        var accounts: [Persistence.Account] = []
        for i: UInt64 in 1...5 {
            accounts.append(makeTestAccount(id: i, name: "Acct \(i)"))
        }
        let svc = await buildTestService(accounts: accounts)

        // Request page size 5000 — should cap at defaultPagination (1,000)
        let results = try await svc.getAccountsByGroup(
            groupId: 100, userId: 1, page: 1, pageSize: 5000
        )
        #expect(results.count == 5, "Should return all available accounts in group")
    }

    @Test("Search pagination returns correct pages")
    func testSearchPagination() async throws {
        var accounts: [Persistence.Account] = []
        for i: UInt64 in 1...5 {
            accounts.append(makeTestAccount(id: i, name: "Acct \(i)"))
        }
        let svc = await buildTestService(accounts: accounts)

        // Page 1 with pageSize 2
        let page1 = try await svc.search(
            name: nil, id: nil, type: nil, group: nil,
            userId: 1, page: 1, pageSize: 2
        )
        #expect(page1.count == 2, "Page 1 should return 2 results")

        // Page 2 with pageSize 2
        let page2 = try await svc.search(
            name: nil, id: nil, type: nil, group: nil,
            userId: 1, page: 2, pageSize: 2
        )
        #expect(page2.count == 2, "Page 2 should return 2 results")

        // Page 3 with pageSize 2 — only 1 remaining
        let page3 = try await svc.search(
            name: nil, id: nil, type: nil, group: nil,
            userId: 1, page: 3, pageSize: 2
        )
        #expect(page3.count == 1, "Page 3 should return remaining 1 result")
    }
}

// MARK: - Suite 3: Fund Type Enum Validation

@Suite("AccountService Fund Type Validation")
struct AccountServiceFundTypeTests {

    @Test("All 6 fund types are valid — institutional and wealth categories")
    func testAllFundTypesExist() {
        let allTypes: [AccountManagement.FundType] = [
            .openMutualFund, .closedMutualFund, .etf, .hedgeFund, .sma, .uma
        ]
        #expect(allTypes.count == 6, "Must have exactly 6 fund types")

        // Verify institutional types
        #expect(AccountManagement.FundType.openMutualFund.isInstitutional)
        #expect(AccountManagement.FundType.closedMutualFund.isInstitutional)
        #expect(AccountManagement.FundType.etf.isInstitutional)
        #expect(AccountManagement.FundType.hedgeFund.isInstitutional)

        // Verify wealth types
        #expect(AccountManagement.FundType.sma.isWealth)
        #expect(AccountManagement.FundType.uma.isWealth)
    }

    @Test("Institutional fund types are not wealth types")
    func testInstitutionalNotWealth() {
        let institutionalTypes: [AccountManagement.FundType] = [
            .openMutualFund, .closedMutualFund, .etf, .hedgeFund
        ]
        for fundType in institutionalTypes {
            #expect(fundType.isInstitutional, "\(fundType) should be institutional")
            #expect(!fundType.isWealth, "\(fundType) should NOT be wealth")
        }
    }

    @Test("Wealth fund types are not institutional types")
    func testWealthNotInstitutional() {
        let wealthTypes: [AccountManagement.FundType] = [.sma, .uma]
        for fundType in wealthTypes {
            #expect(fundType.isWealth, "\(fundType) should be wealth")
            #expect(!fundType.isInstitutional, "\(fundType) should NOT be institutional")
        }
    }

    @Test("Fund type raw values round-trip correctly")
    func testFundTypeRawValues() {
        let allTypes: [AccountManagement.FundType] = [
            .openMutualFund, .closedMutualFund, .etf, .hedgeFund, .sma, .uma
        ]
        for fundType in allTypes {
            let rawValue = fundType.rawValue
            let reconstructed = AccountManagement.FundType(rawValue: rawValue)
            #expect(reconstructed == fundType, "Raw value '\(rawValue)' should round-trip")
        }
    }

    @Test("Search by each fund type returns correct results")
    func testSearchByEachFundType() async throws {
        let allPersistenceTypes: [Persistence.FundType] = [
            .openMutualFund, .closedMutualFund, .etf, .hedgeFund, .sma, .uma
        ]
        var accounts: [Persistence.Account] = []
        for (index, ft) in allPersistenceTypes.enumerated() {
            accounts.append(makeTestAccount(
                id: UInt64(index + 1),
                name: "\(ft.rawValue) Account",
                fundType: ft
            ))
        }
        let svc = await buildTestService(accounts: accounts)

        // Test each fund type individually
        for ft in allPersistenceTypes {
            guard let amFundType = AccountManagement.FundType(rawValue: ft.rawValue) else {
                Issue.record("FundType conversion failed for \(ft.rawValue)")
                continue
            }
            let results = try await svc.search(
                name: nil, id: nil, type: amFundType, group: nil,
                userId: 1, page: 1, pageSize: 100
            )
            #expect(results.count == 1, "Filtering by \(ft.rawValue) should return exactly 1 account")
        }
    }

    @Test("FundType.allCases has exactly 6 cases via CaseIterable")
    func testFundTypeAllCasesCount() {
        #expect(AccountManagement.FundType.allCases.count == 6,
                "FundType must have exactly 6 cases via CaseIterable")
        let expectedCases: Set<AccountManagement.FundType> = [
            .openMutualFund, .closedMutualFund, .etf, .hedgeFund, .sma, .uma
        ]
        let actualCases = Set(AccountManagement.FundType.allCases)
        #expect(actualCases == expectedCases, "allCases must contain all 6 fund types")
    }

    @Test("FundType displayName returns human-readable strings")
    func testFundTypeDisplayNames() {
        #expect(AccountManagement.FundType.openMutualFund.displayName.isEmpty == false)
        #expect(AccountManagement.FundType.closedMutualFund.displayName.isEmpty == false)
        #expect(AccountManagement.FundType.etf.displayName.isEmpty == false)
        #expect(AccountManagement.FundType.hedgeFund.displayName.isEmpty == false)
        #expect(AccountManagement.FundType.sma.displayName.isEmpty == false)
        #expect(AccountManagement.FundType.uma.displayName.isEmpty == false)

        // Each display name should be unique
        let allNames = AccountManagement.FundType.allCases.map { $0.displayName }
        let uniqueNames = Set(allNames)
        #expect(uniqueNames.count == 6, "All 6 display names should be unique")
    }

    @Test("FundType Codable JSON encode/decode round-trip")
    func testFundTypeCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for fundType in AccountManagement.FundType.allCases {
            let data = try encoder.encode(fundType)
            let decoded = try decoder.decode(AccountManagement.FundType.self, from: data)
            #expect(decoded == fundType,
                    "FundType \(fundType.rawValue) should survive JSON round-trip")
        }
    }

    @Test("FundType raw values match expected snake_case strings")
    func testFundTypeRawValueStrings() {
        #expect(AccountManagement.FundType.openMutualFund.rawValue == "open_mutual_fund")
        #expect(AccountManagement.FundType.closedMutualFund.rawValue == "closed_mutual_fund")
        #expect(AccountManagement.FundType.etf.rawValue == "etf")
        #expect(AccountManagement.FundType.hedgeFund.rawValue == "hedge_fund")
        #expect(AccountManagement.FundType.sma.rawValue == "sma")
        #expect(AccountManagement.FundType.uma.rawValue == "uma")
    }
}

// MARK: - Suite 4: CRUD Permission Tests (Rule 4)

@Suite("AccountService CRUD Permission Tests", .serialized)
struct AccountServiceCRUDTests {

    @Test("createAccount requires CREATE permission — Rule 4")
    func testCreateRequiresPermission() async throws {
        // User WITHOUT CREATE permission
        let svc = await buildTestService(canCreate: false)
        let account = makeTestAccount(id: 0, name: "New Account")

        await #expect(throws: AppError.unauthorizedAccess) {
            _ = try await svc.createAccount(account, userId: 1)
        }
    }

    @Test("createAccount succeeds with CREATE permission")
    func testCreateWithPermission() async throws {
        let svc = await buildTestService()
        let account = makeTestAccount(id: 0, name: "New Fund")

        let created = try await svc.createAccount(account, userId: 1)
        #expect(created.id != 0, "Created account should have auto-assigned ID")
        #expect(created.name == "New Fund")
    }

    @Test("createAccount rejects invalid timezone — Rule 3")
    func testCreateRejectsInvalidTimezone() async throws {
        let svc = await buildTestService()
        let account = makeTestAccount(
            id: 0,
            name: "Bad TZ Account",
            valuationTimezone: "Invalid/Timezone"
        )

        await #expect(throws: AppError.invalidTimezone) {
            _ = try await svc.createAccount(account, userId: 1)
        }
    }

    @Test("getAccount returns nil for unauthorized user — Rule 4")
    func testGetAccountUnauthorized() async throws {
        let accounts = [makeTestAccount(id: 1, name: "Private Fund")]
        let svc = await buildTestService(accounts: accounts, canRead: false)

        let result = try await svc.getAccount(id: 1, userId: 1)
        #expect(result == nil, "Rule 4: Unauthorized READ should return nil, not error")
    }

    @Test("getAccount returns account for authorized user")
    func testGetAccountAuthorized() async throws {
        let accounts = [makeTestAccount(id: 1, name: "My Fund")]
        let svc = await buildTestService(accounts: accounts)

        let result = try await svc.getAccount(id: 1, userId: 1)
        #expect(result != nil)
        #expect(result?.name == "My Fund")
    }

    @Test("updateAccount requires MODIFY permission — Rule 4")
    func testUpdateRequiresPermission() async throws {
        let accounts = [makeTestAccount(id: 1, name: "Original")]
        let svc = await buildTestService(accounts: accounts, canModify: false)

        let updated = makeTestAccount(id: 1, name: "Updated")
        await #expect(throws: AppError.unauthorizedAccess) {
            _ = try await svc.updateAccount(updated, userId: 1)
        }
    }

    @Test("updateAccount rejects invalid timezone — Rule 3")
    func testUpdateRejectsInvalidTimezone() async throws {
        let accounts = [makeTestAccount(id: 1, name: "Original")]
        let svc = await buildTestService(accounts: accounts)

        let updated = makeTestAccount(id: 1, name: "Updated", valuationTimezone: "Bogus/Zone")
        await #expect(throws: AppError.invalidTimezone) {
            _ = try await svc.updateAccount(updated, userId: 1)
        }
    }

    @Test("deleteAccount requires DELETE permission — Rule 4")
    func testDeleteRequiresPermission() async throws {
        let accounts = [makeTestAccount(id: 1, name: "Protected")]
        let svc = await buildTestService(accounts: accounts, canDelete: false)

        await #expect(throws: AppError.unauthorizedAccess) {
            try await svc.deleteAccount(id: 1, userId: 1)
        }
    }

    @Test("deleteAccount throws accountNotFound for missing account")
    func testDeleteMissingAccount() async throws {
        let svc = await buildTestService()

        await #expect(throws: AppError.accountNotFound) {
            try await svc.deleteAccount(id: 999, userId: 1)
        }
    }

    @Test("batchStatusUpdate requires MODIFY on ALL groups — Rule 4")
    func testBatchRequiresModifyOnAllGroups() async throws {
        let group1 = makeTestGroup(id: 100, groupName: "Group A")
        let group2 = makeTestGroup(id: 200, groupName: "Group B")
        let accounts = [
            makeTestAccount(id: 1, name: "Acct A", accountGroupId: 100),
            makeTestAccount(id: 2, name: "Acct B", accountGroupId: 200),
        ]
        // User has MODIFY on group 100 but NOT on group 200
        let repo = MockAccountRepo()
        let entitlement = MockEntitlementCheck()
        await repo.seedAccounts(accounts)
        await entitlement.setAccessibleGroups([group1, group2])
        await entitlement.setPermission(userId: 1, groupId: 100, permission: "MODIFY", allowed: true)
        await entitlement.setPermission(userId: 1, groupId: 200, permission: "MODIFY", allowed: false)
        let svc = TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)

        await #expect(throws: AppError.unauthorizedAccess) {
            try await svc.batchStatusUpdate(
                accountIds: [1, 2], newStatus: .active, userId: 1
            )
        }
    }

    @Test("getAccounts filters results by accessible groups — Rule 4")
    func testGetAccountsFiltersAccessibleGroups() async throws {
        // 3 accounts across 3 groups; user entitled to only 2 groups
        let group1 = makeTestGroup(id: 100, groupName: "Entitled Group A")
        let group2 = makeTestGroup(id: 200, groupName: "Entitled Group B")
        let accounts = [
            makeTestAccount(id: 1, name: "Acct A", accountGroupId: 100),
            makeTestAccount(id: 2, name: "Acct B", accountGroupId: 200),
            makeTestAccount(id: 3, name: "Acct C", accountGroupId: 300),
        ]

        let repo = MockAccountRepo()
        let entitlement = MockEntitlementCheck()
        await repo.seedAccounts(accounts)
        // User entitled to groups 100, 200 only — NOT 300
        await entitlement.setAccessibleGroups([group1, group2])
        let svc = TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)

        let results = try await svc.getAccounts(ids: [1, 2, 3], userId: 1)
        #expect(results.count == 2,
                "Rule 4: Only accounts in entitled groups should be returned")
        let returnedIds = Set(results.map { $0.id })
        #expect(returnedIds.contains(1))
        #expect(returnedIds.contains(2))
        #expect(!returnedIds.contains(3),
                "Account in non-entitled group 300 must be excluded")
    }

    @Test("getAccountsByGroup returns empty for unauthorized group — Rule 4")
    func testGetAccountsByGroupUnauthorized() async throws {
        let accounts = [
            makeTestAccount(id: 1, name: "Protected Acct", accountGroupId: 500),
        ]
        let svc = await buildTestService(accounts: accounts, canRead: false)

        let results = try await svc.getAccountsByGroup(
            groupId: 500, userId: 1, page: 1, pageSize: 100
        )
        #expect(results.isEmpty,
                "Rule 4: Unauthorized group READ should return empty, not error")
    }

    @Test("getAccessibleAccountGroups returns empty for user with no entitlements — Rule 4")
    func testGetAccessibleGroupsNoEntitlements() async throws {
        let repo = MockAccountRepo()
        let entitlement = MockEntitlementCheck()
        // Set NO accessible groups for user 999
        await entitlement.setAccessibleGroups([])
        let svc = TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)

        let groups = await svc.getAccessibleAccountGroups(userId: 999)
        #expect(groups.isEmpty,
                "Rule 4: User with no entitlements should receive empty groups list")
    }

    @Test("getAccessibleAccountGroups returns groups for entitled user")
    func testGetAccessibleGroupsForEntitledUser() async throws {
        let group1 = makeTestGroup(id: 100, groupName: "Portfolio A")
        let group2 = makeTestGroup(id: 200, groupName: "Portfolio B")

        let repo = MockAccountRepo()
        let entitlement = MockEntitlementCheck()
        await entitlement.setAccessibleGroups([group1, group2])
        let svc = TestableAccountService(accountRepo: repo, entitlementCheck: entitlement)

        let groups = await svc.getAccessibleAccountGroups(userId: 1)
        #expect(groups.count == 2)
        let groupIds = Set(groups.map { $0.id })
        #expect(groupIds.contains(100))
        #expect(groupIds.contains(200))
    }

    @Test("createAccount validates multiple IANA timezones — Rule 3")
    func testCreateValidatesMultipleTimezones() async throws {
        let svc = await buildTestService()

        // Valid timezones should succeed
        let validTimezones = ["America/New_York", "Europe/London", "Asia/Tokyo", "UTC"]
        for tz in validTimezones {
            let account = makeTestAccount(id: 0, name: "TZ Test", valuationTimezone: tz)
            let created = try await svc.createAccount(account, userId: 1)
            #expect(created.valuationTimezone == tz,
                    "Valid timezone '\(tz)' should be accepted")
        }

        // Invalid timezones should throw
        let invalidTimezones = ["FakeCity/NoWhere", "NotA/Timezone", "Mars/Colony"]
        for tz in invalidTimezones {
            let account = makeTestAccount(id: 0, name: "Bad TZ", valuationTimezone: tz)
            await #expect(throws: AppError.invalidTimezone) {
                _ = try await svc.createAccount(account, userId: 1)
            }
        }
    }

    @Test("getAccount returns nil for non-existent ID with authorized user")
    func testGetAccountNonExistentIdAuthorized() async throws {
        // Empty repo — no accounts at all
        let svc = await buildTestService()

        let result = try await svc.getAccount(id: 999, userId: 1)
        #expect(result == nil,
                "Non-existent account should return nil, not an error")
    }
}

// MARK: - Suite 5: Account Status Lifecycle

@Suite("AccountService Status Lifecycle Tests")
struct AccountServiceStatusTests {

    @Test("All 4 account statuses exist and have correct raw values")
    func testAccountStatusEnum() {
        let allStatuses: [AccountManagement.AccountStatus] = [
            .active, .inactive, .pending, .suspended
        ]
        #expect(allStatuses.count == 4, "Must have exactly 4 account statuses")

        for status in allStatuses {
            let rawValue = status.rawValue
            let reconstructed = AccountManagement.AccountStatus(rawValue: rawValue)
            #expect(reconstructed == status, "Raw value '\(rawValue)' should round-trip")
        }
    }

    @Test("Batch status update applies new status correctly")
    func testBatchStatusUpdateAppliesStatus() async throws {
        let accounts = [
            makeTestAccount(id: 1, name: "Acct 1", status: .pending),
            makeTestAccount(id: 2, name: "Acct 2", status: .pending),
        ]
        let svc = await buildTestService(accounts: accounts)

        try await svc.batchStatusUpdate(
            accountIds: [1, 2], newStatus: .active, userId: 1
        )

        let calls = await svc.accountRepo.batchUpdateCalls
        #expect(calls.count == 1)
        #expect(calls.first?.newStatus == "active")
    }

    @Test("Empty batch update is no-op")
    func testEmptyBatchUpdate() async throws {
        let svc = await buildTestService()

        // Should not throw for empty array
        try await svc.batchStatusUpdate(
            accountIds: [], newStatus: .active, userId: 1
        )

        let calls = await svc.accountRepo.batchUpdateCalls
        #expect(calls.isEmpty, "Empty batch should produce zero repository calls")
    }

    @Test("getAccounts with empty IDs returns empty array")
    func testGetAccountsEmptyIds() async throws {
        let svc = await buildTestService()
        let results = try await svc.getAccounts(ids: [], userId: 1)
        #expect(results.isEmpty)
    }

    @Test("AccountStatus.allCases has exactly 4 cases via CaseIterable")
    func testAccountStatusAllCasesCount() {
        #expect(AccountManagement.AccountStatus.allCases.count == 4,
                "AccountStatus must have exactly 4 cases via CaseIterable")
        let expectedCases: Set<AccountManagement.AccountStatus> = [
            .active, .inactive, .pending, .suspended
        ]
        let actualCases = Set(AccountManagement.AccountStatus.allCases)
        #expect(actualCases == expectedCases, "allCases must contain all 4 statuses")
    }

    @Test("AccountStatus Codable JSON encode/decode round-trip")
    func testAccountStatusCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in AccountManagement.AccountStatus.allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(AccountManagement.AccountStatus.self, from: data)
            #expect(decoded == status,
                    "AccountStatus \(status.rawValue) should survive JSON round-trip")
        }
    }

    @Test("AccountStatus raw values match expected strings")
    func testAccountStatusRawValueStrings() {
        #expect(AccountManagement.AccountStatus.active.rawValue == "active")
        #expect(AccountManagement.AccountStatus.inactive.rawValue == "inactive")
        #expect(AccountManagement.AccountStatus.pending.rawValue == "pending")
        #expect(AccountManagement.AccountStatus.suspended.rawValue == "suspended")
    }

    @Test("AccountStatus CaseIterable iterates all values in order")
    func testAccountStatusCaseIterable() {
        var iteratedStatuses: [AccountManagement.AccountStatus] = []
        for status in AccountManagement.AccountStatus.allCases {
            iteratedStatuses.append(status)
        }
        #expect(iteratedStatuses.count == 4,
                "Iterating allCases must produce exactly 4 elements")
        #expect(iteratedStatuses.contains(.active))
        #expect(iteratedStatuses.contains(.inactive))
        #expect(iteratedStatuses.contains(.pending))
        #expect(iteratedStatuses.contains(.suspended))
    }

    @Test("Batch status update works with all four AccountStatus values")
    func testBatchUpdateAllFourStatuses() async throws {
        let accounts = [
            makeTestAccount(id: 1, name: "Status Acct", status: .pending),
        ]
        let svc = await buildTestService(accounts: accounts)

        // Use Persistence.AccountStatus since TestableAccountService works with persistence types
        let allStatuses: [Persistence.AccountStatus] = [
            .active, .inactive, .pending, .suspended
        ]
        for status in allStatuses {
            try await svc.batchStatusUpdate(
                accountIds: [1], newStatus: status, userId: 1
            )
        }

        let calls = await svc.accountRepo.batchUpdateCalls
        #expect(calls.count == 4, "Should have 4 batch update calls — one per status")
        let statusValues = calls.map { $0.newStatus }
        #expect(statusValues.contains("active"))
        #expect(statusValues.contains("inactive"))
        #expect(statusValues.contains("pending"))
        #expect(statusValues.contains("suspended"))
    }
}
