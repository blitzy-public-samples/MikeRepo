// Tests/IntegrationTests/EndToEndWorkflowTests.swift
// WealthLedger — Gate 1 End-to-End Workflow Integration Tests
//
// The most critical integration test in the WealthLedger project. Exercises
// the complete module chain against a live MySQL `accounting_test` schema:
//
//     RBAC → AccountManagement → LedgerEngine → ValuationEngine → Persistence
//
// Gate 1 workflow:
// 1. Create a user (RBAC / AuthenticationService / PasswordHasher)
// 2. Create an account group (AccountManagement / AccountGroupService)
// 3. Assign entitlement with READ + CREATE + MODIFY (RBAC / EntitlementService)
// 4. Create an account with IANA timezone (AccountManagement / AccountService)
// 5. Post a balanced buy transaction — debit == credit (LedgerEngine / LedgerService)
// 6. Seed reference data with EOD prices (ReferenceDataService)
// 7. Run valuation using account timezone (ValuationEngine / ValuationService)
// 8. Verify cached valuation denormalization (Rule 11)
//
// RULES ENFORCED:
// - Rule 1:  Double-entry enforcement — debit/credit must sum to zero
// - Rule 2:  Transaction immutability — append-only, no UPDATE/DELETE
// - Rule 3:  Per-account valuation timezone — IANA string, not system clock
// - Rule 4:  Entitlement enforcement — READ permission required for data access
// - Rule 5:  Asset class guard — equities only
// - Rule 6:  Reference data simulation fidelity — non-null non-zero prices
// - Rule 8:  MySQLKit-only persistence — NO SwiftData anywhere
// - Rule 10: Schema referential integrity — all FK constraints satisfied
// - Rule 11: Cached valuation denormalization — atomic update in same TX
//
// GATE COMPLIANCE:
// - Gate 1:  End-to-end boundary verification against live MySQL
// - Gate 2:  Swift 6 strict concurrency — zero warnings, zero @unchecked Sendable
// - Gate 9:  Integration wiring — every module reachable and exercised
// - Gate 10: Test execution with `accounting_test` schema via TestDatabaseSetup
//
// Testing Framework: Swift Testing (@Suite, @Test, #expect, #require)
// NEVER: import XCTest, import SwiftData
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
import Logging
@testable import Persistence
@testable import AccountManagement
@testable import LedgerEngine
@testable import ValuationEngine
@testable import ReferenceDataService
@testable import RBAC
@testable import Shared

// MARK: - EndToEndWorkflowTests

/// Gate 1 end-to-end workflow test suite validating the complete module chain
/// against a live MySQL `accounting_test` schema.
///
/// Each test method is self-contained: it sets up the database, creates all
/// required entities from scratch, and performs full-stack assertions. Tests
/// are independent and can run in any order.
///
/// ## Sendable Safety (Gate 2)
///
/// This struct is a value type with zero stored properties, making it trivially
/// `Sendable`. All service and repository instances are created as local
/// variables within each test function — no shared mutable state exists.
///
/// ## Module Chain Coverage (Gate 9)
///
/// The primary test exercises every module in the application:
/// - **RBAC**: `AuthenticationService`, `EntitlementService`, `PasswordHasher`
/// - **AccountManagement**: `AccountService`, `AccountGroupService`
/// - **LedgerEngine**: `LedgerService`, `DoubleEntryValidator`
/// - **ValuationEngine**: `ValuationService`, `NAVCalculator`
/// - **Persistence**: All 7 repositories + `ConnectionPool` + `DatabaseManager`
/// - **Shared**: `AppError`, `AppConstants`
/// - **ReferenceDataService**: `ReferenceData` model for price verification
@Suite("End-to-End Workflow Tests — Gate 1")
struct EndToEndWorkflowTests {

    // MARK: - Gate 1 Primary Test

    /// Executes the complete Gate 1 end-to-end workflow against live MySQL.
    ///
    /// Steps:
    /// 1. Create user with bcrypt-hashed password
    /// 2. Create account group
    /// 3. Assign READ + CREATE + MODIFY entitlement
    /// 4. Create account with IANA timezone "America/New_York" and fund type ETF
    /// 5. Seed reference data with specific EOD bid/ask prices
    /// 6. Post balanced buy transaction (100 shares, debit == credit)
    /// 7. Run valuation — verify NAV = Σ(qty × midpoint) + cash
    /// 8. Verify cached valuation amount and date on accounts table (Rule 11)
    ///
    /// All assertions use `#expect` (Swift Testing) — never XCTAssert.
    @Test("Gate 1: Complete end-to-end workflow — create account → post transaction → run valuation → verify")
    func testEndToEndWorkflow() async throws {
        // ── Database Setup (Gate 10) ────────────────────────────────────
        // Initialize accounting_test schema with all 8 migrations applied.
        // cleanAllTables ensures test isolation from prior runs.
        try await TestDatabaseSetup.setUp()
        try await TestDatabaseSetup.cleanAllTables()

        let pool = TestDatabaseSetup.connectionPool!
        // Verify DatabaseManager is available (Gate 10 infrastructure)
        let dbManager = TestDatabaseSetup.databaseManager
        #expect(dbManager != nil, "DatabaseManager must be initialized by TestDatabaseSetup")
        let logger = Logger(label: "test.e2e.workflow")

        // ── Step 1: Create User (RBAC) ─────────────────────────────────
        // AuthenticationService hashes password with bcrypt via PasswordHasher.
        // UserRepository persists user with hashed password to MySQL.
        let userRepo = UserRepository(pool: pool, logger: logger)
        let passwordHasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )

        let user: RBAC.User = try await authService.createUser(
            username: "e2e_test_user",
            password: "SecurePass123!"
        )
        #expect(user.id != 0, "User must have a non-zero ID after creation")
        #expect(user.username == "e2e_test_user")

        // ── Step 2: Create Account Group (AccountManagement) ───────────
        // Account groups provide the FK target for accounts and the scope
        // unit for RBAC entitlements (Rule 4).
        let accountGroupRepo = AccountGroupRepository(pool: pool, logger: logger)
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )

        let group: AccountManagement.AccountGroup = try await accountGroupService.createGroup(
            name: "E2E Test Group"
        )
        #expect(group.id != 0, "Account group must have a non-zero ID after creation")
        #expect(group.groupName == "E2E Test Group")

        // ── Step 3: Assign Entitlement — READ + CREATE + MODIFY (Rule 4) ─
        // EntitlementService manages per-user per-group permission flags.
        // The test user needs CREATE to make accounts and transactions,
        // READ to query them, and MODIFY for completeness.
        let entitlementRepo = EntitlementRepository(pool: pool, logger: logger)
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )

        try await entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        // Verify entitlement was persisted correctly
        let hasRead = await entitlementService.checkPermission(
            userId: user.id,
            accountGroupId: group.id,
            permission: "READ"
        )
        #expect(hasRead == true, "User must have READ permission after assignment")

        let hasCreate = await entitlementService.checkPermission(
            userId: user.id,
            accountGroupId: group.id,
            permission: "CREATE"
        )
        #expect(hasCreate == true, "User must have CREATE permission after assignment")

        let hasModify = await entitlementService.checkPermission(
            userId: user.id,
            accountGroupId: group.id,
            permission: "MODIFY"
        )
        #expect(hasModify == true, "User must have MODIFY permission after assignment")

        // Verify entitlement model properties (Rule 4 FK integrity)
        // Entitlement links a userId to an accountGroupId with permission flags.
        let storedEntitlement: Persistence.Entitlement? = try await entitlementRepo.findByUserAndGroup(
            userId: user.id,
            accountGroupId: group.id
        )
        #expect(storedEntitlement != nil, "Entitlement must be persisted")
        #expect(storedEntitlement!.userId == user.id,
                "Entitlement.userId must reference the created user (Rule 10)")
        #expect(storedEntitlement!.accountGroupId == group.id,
                "Entitlement.accountGroupId must reference the created group (Rule 10)")

        // ── Step 4: Create Account — Rule 3 (timezone), Rule 4 (entitlement) ─
        // AccountService validates entitlement (Rule 4) and timezone (Rule 3)
        // internally before delegating to AccountRepository.
        let accountRepo = AccountRepository(pool: pool, logger: logger)
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )

        let newAccount = AccountManagement.Account(
            id: 0,
            name: "E2E Test Fund",
            fundType: .etf,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: "daily",
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: .active,
            accountGroupId: group.id,
            createdAt: Date()
        )
        let account: AccountManagement.Account = try await accountService.createAccount(
            newAccount,
            userId: user.id
        )
        #expect(account.id != 0, "Account must have a non-zero ID after creation")
        #expect(account.valuationTimezone == "America/New_York",
                "Account must store the IANA timezone (Rule 3)")
        #expect(account.fundType == .etf, "Account fund type must be ETF")
        #expect(account.status == .active, "Account must be active")

        // ── Step 5: Seed Reference Data (Rule 6) ──────────────────────
        // Insert a synthetic NYSE equity record with specific EOD bid/ask
        // prices for deterministic NAV calculation.
        // EOD midpoint = (150.00 + 151.00) / 2 = 150.50
        let refDataRepo = ReferenceDataRepository(pool: pool, logger: logger)

        // Use a stable market date for consistency across insert and query
        let marketDate = Date()

        let refData = Persistence.ReferenceData(
            id: 0,
            ticker: "AAPL",
            name: "Apple Inc.",
            sodBid: Decimal(string: "148.50")!,
            sodAsk: Decimal(string: "149.00")!,
            eodBid: Decimal(string: "150.00")!,
            eodAsk: Decimal(string: "151.00")!,
            marketDate: marketDate
        )
        let createdRefData: Persistence.ReferenceData = try await refDataRepo.create(refData)
        #expect(createdRefData.id != 0, "Reference data must have a non-zero ID after creation")
        #expect(createdRefData.eodBid > 0, "EOD bid must be non-zero (Rule 6)")
        #expect(createdRefData.eodAsk > 0, "EOD ask must be non-zero (Rule 6)")

        // Verify reference data can be retrieved by ticker and date
        let fetchedRefData = try await refDataRepo.findByTickerAndDate(
            ticker: "AAPL",
            marketDate: marketDate
        )
        #expect(fetchedRefData != nil, "Reference data must be retrievable for valuation")
        #expect(fetchedRefData!.eodBid > 0, "Fetched EOD bid must be non-zero (Rule 6)")
        #expect(fetchedRefData!.eodAsk > 0, "Fetched EOD ask must be non-zero (Rule 6)")

        // ── Step 6: Post Balanced Buy Transaction (Rule 1, 2, 5) ──────
        // Buy 100 shares at $150.50 midpoint:
        //   Debit  (asset increase):  15050.00
        //   Credit (cash decrease):   15050.00
        //   Sum = 0 (Rule 1 satisfied)
        // Asset type must be "equity" (Rule 5).
        let transactionRepo = TransactionRepository(pool: pool, logger: logger)
        let positionRepo = PositionRepository(pool: pool, logger: logger)
        let doubleEntryValidator = DoubleEntryValidator()
        let ledgerService = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: doubleEntryValidator,
            entitlementService: entitlementService
        )

        let transactionAmount = Decimal(15050)
        let transaction: LedgerEngine.Transaction = try await ledgerService.postTransaction(
            userId: user.id,
            accountId: account.id,
            accountGroupId: group.id,
            instrumentId: createdRefData.id,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: transactionAmount,
            creditAmount: transactionAmount
        )
        #expect(transaction.id != 0, "Transaction must have a non-zero ID after creation")
        #expect(transaction.accountId == account.id, "Transaction must reference the correct account")
        #expect(transaction.debitAmount == transactionAmount, "Debit amount must match")
        #expect(transaction.creditAmount == transactionAmount, "Credit amount must match")
        #expect(transaction.assetType == "equity", "Asset type must be equity (Rule 5)")

        // Verify position was created by the buy transaction
        let positions = try await positionRepo.findByAccountId(account.id)
        #expect(positions.count >= 1, "At least one position must exist after buy transaction")

        // Verify position properties (Rule 5: equity only, Rule 10: FK integrity)
        let position = positions[0]
        #expect(position.accountId == account.id,
                "Position must reference the correct account (Rule 10)")
        #expect(position.instrumentId == createdRefData.id,
                "Position must reference the correct instrument (Rule 10)")
        #expect(position.quantity == Decimal(100),
                "Position quantity must match the buy transaction quantity")
        #expect(position.assetType == "equity",
                "Position asset type must be equity (Rule 5)")

        // ── Step 7: Run Valuation (Rule 3, Rule 11) ───────────────────
        // NAV = Σ(quantity × EOD midpoint) + cash_balance
        //     = 100 × ((150.00 + 151.00) / 2) + 0
        //     = 100 × 150.50 + 0
        //     = 15050.00
        let navCalculator = NAVCalculator()
        let valuationService = ValuationService(
            accountRepository: accountRepo,
            positionRepository: positionRepo,
            referenceDataRepository: refDataRepo,
            navCalculator: navCalculator,
            connectionPool: pool,
            logger: logger
        )

        let valuations: [Valuation] = try await valuationService.runValuation(
            for: [account.id],
            marketDate: marketDate
        )
        #expect(valuations.count == 1, "One valuation expected for one account")

        let valuation = valuations[0]
        // Expected NAV: qty(100) × midpoint((150.00 + 151.00)/2 = 150.50) + cash(0)
        // Cash position price is fixed at AppConstants.cashPrice = 1.00 (Rule: cash price)
        // With zero cash balance, cash contribution = 0 × AppConstants.cashPrice = 0
        let expectedEodMidpoint = (Decimal(string: "150.00")! + Decimal(string: "151.00")!) / Decimal(2)
        let cashContribution = Decimal(0) * AppConstants.cashPrice  // 0 cash balance
        let expectedNAV = Decimal(100) * expectedEodMidpoint + cashContribution
        #expect(valuation.valueAmount == expectedNAV,
                "NAV must equal Σ(qty × EOD midpoint) + cash = \(expectedNAV)")
        #expect(valuation.timezone == "America/New_York",
                "Valuation must use account's stored IANA timezone (Rule 3)")
        #expect(valuation.accountId == account.id,
                "Valuation must reference the correct account")
        // Verify value date is populated (Rule 3: timezone-aware value date)
        let valueDateTimestamp = valuation.valueDate.timeIntervalSince1970
        #expect(valueDateTimestamp > 0,
                "Valuation value date must be a valid date after epoch")

        // Verify batch size constant is consistent with Rule 7 memory cap
        #expect(AppConstants.batchSize == 1000,
                "Batch size must be 1000 per Rule 7 memory cap")

        // ── Step 8: Verify Cached Valuation (Rule 11) ─────────────────
        // The accounts table must have cached_valuation_amount and
        // cached_value_date updated atomically within the same DB transaction
        // as the valuation completion.
        let updatedAccount: Persistence.Account? = try await accountRepo.findById(account.id)
        #expect(updatedAccount != nil, "Account must still exist after valuation")

        let verifiedAccount = updatedAccount!
        #expect(verifiedAccount.cachedValuationAmount != nil,
                "Cached valuation amount must be set after valuation (Rule 11)")
        #expect(verifiedAccount.cachedValuationAmount == expectedNAV,
                "Cached valuation amount must match computed NAV (Rule 11)")
        #expect(verifiedAccount.cachedValueDate != nil,
                "Cached value date must be set after valuation (Rule 11)")

        // ── Cleanup (Gate 10) ──────────────────────────────────────────
        // Tear down the test schema to release MySQL resources.
        try await TestDatabaseSetup.tearDown()
    }

    // MARK: - Supplemental: Unbalanced Entry Rejection (Rule 1)

    /// Verifies that an unbalanced transaction (debit ≠ credit) is rejected
    /// with `AppError.unbalancedEntry` before any database write occurs.
    ///
    /// This test validates Rule 1 (Double-Entry Enforcement): every ledger
    /// write must produce balanced debit/credit pairs summing to zero.
    @Test("Gate 1 supplemental: Unbalanced entry is rejected (Rule 1)")
    func testUnbalancedEntryRejected() async throws {
        // ── Database Setup ──────────────────────────────────────────────
        try await TestDatabaseSetup.setUp()
        try await TestDatabaseSetup.cleanAllTables()

        let pool = TestDatabaseSetup.connectionPool!
        let logger = Logger(label: "test.e2e.unbalanced")

        // ── Create prerequisite entities ────────────────────────────────
        // User, group, entitlement, account — all required for Rule 4
        // entitlement checks that LedgerService performs before Rule 1.
        let userRepo = UserRepository(pool: pool, logger: logger)
        let passwordHasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )
        let user: RBAC.User = try await authService.createUser(
            username: "unbalanced_test_user",
            password: "SecurePass123!"
        )

        let accountGroupRepo = AccountGroupRepository(pool: pool, logger: logger)
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let group: AccountManagement.AccountGroup = try await accountGroupService.createGroup(
            name: "Unbalanced Test Group"
        )

        let entitlementRepo = EntitlementRepository(pool: pool, logger: logger)
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )
        try await entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        let accountRepo = AccountRepository(pool: pool, logger: logger)
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )
        let newAccount = AccountManagement.Account(
            id: 0,
            name: "Unbalanced Test Fund",
            fundType: .etf,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: nil,
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: .active,
            accountGroupId: group.id,
            createdAt: Date()
        )
        let account: AccountManagement.Account = try await accountService.createAccount(
            newAccount,
            userId: user.id
        )

        // Seed reference data for the instrument
        let refDataRepo = ReferenceDataRepository(pool: pool, logger: logger)
        let refData = Persistence.ReferenceData(
            id: 0,
            ticker: "MSFT",
            name: "Microsoft Corp",
            sodBid: Decimal(200),
            sodAsk: Decimal(201),
            eodBid: Decimal(200),
            eodAsk: Decimal(201),
            marketDate: Date()
        )
        let createdRefData: Persistence.ReferenceData = try await refDataRepo.create(refData)

        // ── Build LedgerService ─────────────────────────────────────────
        let transactionRepo = TransactionRepository(pool: pool, logger: logger)
        let positionRepo = PositionRepository(pool: pool, logger: logger)
        let doubleEntryValidator = DoubleEntryValidator()
        let ledgerService = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: doubleEntryValidator,
            entitlementService: entitlementService
        )

        // ── Attempt unbalanced transaction ──────────────────────────────
        // Debit 10,000 ≠ Credit 5,000 → must throw AppError.unbalancedEntry (Rule 1)
        do {
            _ = try await ledgerService.postTransaction(
                userId: user.id,
                accountId: account.id,
                accountGroupId: group.id,
                instrumentId: createdRefData.id,
                quantity: Decimal(50),
                assetType: "equity",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(10000),
                creditAmount: Decimal(5000)
            )
            Issue.record("Expected AppError.unbalancedEntry but no error was thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry,
                    "Unbalanced debit/credit must throw .unbalancedEntry (Rule 1)")
        } catch {
            Issue.record("Expected AppError.unbalancedEntry but got unexpected error: \(error)")
        }
    }

    // MARK: - Supplemental: Non-Equity Rejection (Rule 5)

    /// Verifies that a non-equity asset type is rejected with
    /// `AppError.invalidAssetClass` before any database write occurs.
    ///
    /// This test validates Rule 5 (Asset Class Guard): the application must
    /// reject creation of any position or transaction for a non-equity
    /// instrument at the application layer.
    @Test("Gate 1 supplemental: Non-equity instrument is rejected (Rule 5)")
    func testNonEquityRejected() async throws {
        // ── Database Setup ──────────────────────────────────────────────
        try await TestDatabaseSetup.setUp()
        try await TestDatabaseSetup.cleanAllTables()

        let pool = TestDatabaseSetup.connectionPool!
        let logger = Logger(label: "test.e2e.nonequity")

        // ── Create prerequisite entities ────────────────────────────────
        let userRepo = UserRepository(pool: pool, logger: logger)
        let passwordHasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )
        let user: RBAC.User = try await authService.createUser(
            username: "nonequity_test_user",
            password: "SecurePass123!"
        )

        let accountGroupRepo = AccountGroupRepository(pool: pool, logger: logger)
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let group: AccountManagement.AccountGroup = try await accountGroupService.createGroup(
            name: "NonEquity Test Group"
        )

        let entitlementRepo = EntitlementRepository(pool: pool, logger: logger)
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )
        try await entitlementService.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: false
        )

        let accountRepo = AccountRepository(pool: pool, logger: logger)
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )
        let newAccount = AccountManagement.Account(
            id: 0,
            name: "NonEquity Test Fund",
            fundType: .etf,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: nil,
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: .active,
            accountGroupId: group.id,
            createdAt: Date()
        )
        let account: AccountManagement.Account = try await accountService.createAccount(
            newAccount,
            userId: user.id
        )

        // ── Build LedgerService ─────────────────────────────────────────
        let transactionRepo = TransactionRepository(pool: pool, logger: logger)
        let positionRepo = PositionRepository(pool: pool, logger: logger)
        let doubleEntryValidator = DoubleEntryValidator()
        let ledgerService = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: doubleEntryValidator,
            entitlementService: entitlementService
        )

        // ── Attempt non-equity transaction ──────────────────────────────
        // Asset type "fixed_income" must be rejected (Rule 5)
        // Even though debit == credit (balanced), the asset class guard
        // fires BEFORE double-entry validation.
        do {
            _ = try await ledgerService.postTransaction(
                userId: user.id,
                accountId: account.id,
                accountGroupId: group.id,
                instrumentId: nil,
                quantity: Decimal(50),
                assetType: "fixed_income",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(10000),
                creditAmount: Decimal(10000)
            )
            Issue.record("Expected AppError.invalidAssetClass but no error was thrown")
        } catch let error as AppError {
            #expect(error == .invalidAssetClass,
                    "Non-equity asset type must throw .invalidAssetClass (Rule 5)")
        } catch {
            Issue.record("Expected AppError.invalidAssetClass but got unexpected error: \(error)")
        }
    }
}
