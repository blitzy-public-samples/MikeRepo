// Tests/IntegrationTests/ValuationIntegrationTests.swift
//
// Valuation Engine Integration Tests
//
// Tests the valuation engine against a live MySQL `accounting_test` schema.
// Validates NAV formula correctness, timezone-aware value date computation (Rule 3),
// cached valuation denormalization (Rule 11), and cash balance handling.
//
// Rule 3:  Each account stores its own IANA timezone; ValuationEngine MUST use it.
// Rule 8:  MySQLKit-only persistence — NO SwiftData anywhere.
// Rule 11: cached_valuation_amount and cached_value_date updated atomically.
// Gate 2:  Swift 6 strict concurrency — zero warnings, zero @unchecked Sendable.
// Gate 10: Tests execute against the `accounting_test` schema via TestDatabaseSetup.

import Testing
import Foundation
@testable import Persistence
@testable import ValuationEngine
@testable import AccountManagement
@testable import LedgerEngine
@testable import ReferenceDataService
@testable import RBAC
@testable import Shared

// MARK: - Valuation Integration Test Suite

/// Integration test suite for the ValuationEngine module exercising NAV calculation,
/// timezone-aware value date computation, and atomic cached valuation writes against
/// a live MySQL `accounting_test` schema.
///
/// Validates:
/// - NAV formula: `Σ(quantity × EOD midpoint) + cash_balance` with midpoint = `(eod_bid + eod_ask) / 2`
/// - Multiple positions aggregated correctly
/// - **Rule 3**: Two accounts with different IANA timezones produce timezone-correct value dates
/// - **Rule 3**: ValuationEngine uses account's stored timezone, never the system clock
/// - **Rule 11**: `cached_valuation_amount` and `cached_value_date` updated atomically
/// - Cached valuation updates correctly on subsequent runs
/// - Cash balance included with fixed price `AppConstants.cashPrice` (1.00)
/// - Empty account valuation returns zero
///
/// The `.serialized` trait ensures sequential test execution to prevent race conditions
/// on shared MySQL state.
@Suite("Valuation Integration Tests", .serialized)
struct ValuationIntegrationTests {

    // MARK: - Service Factory

    /// Constructs all services and repositories wired to the test database connection pool.
    ///
    /// Returns a named tuple containing every service and repository needed for
    /// valuation integration testing: the ValuationService under test, supporting
    /// repositories for test fixture creation, and LedgerService for posting
    /// transactions that create positions.
    private func buildServices() -> (
        valuationService: ValuationService,
        accountRepo: AccountRepository,
        positionRepo: PositionRepository,
        refDataRepo: ReferenceDataRepository,
        accountGroupRepo: AccountGroupRepository,
        userRepo: UserRepository,
        entitlementRepo: EntitlementRepository,
        ledgerService: LedgerService,
        pool: ConnectionPool
    ) {
        let pool = TestDatabaseSetup.connectionPool!

        // Persistence-layer repositories
        let accountRepo = AccountRepository(pool: pool)
        let positionRepo = PositionRepository(pool: pool)
        let refDataRepo = ReferenceDataRepository(pool: pool)
        let accountGroupRepo = AccountGroupRepository(pool: pool)
        let userRepo = UserRepository(pool: pool)
        let entitlementRepo = EntitlementRepository(pool: pool)
        let transactionRepo = TransactionRepository(pool: pool)

        // Pure calculators (stateless, Sendable)
        let navCalculator = NAVCalculator()
        let doubleEntryValidator = DoubleEntryValidator()

        // RBAC services
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )

        // AccountManagement services (wired for completeness; not called directly)
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let _ = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )

        // Primary service under test
        let valuationService = ValuationService(
            accountRepository: accountRepo,
            positionRepository: positionRepo,
            referenceDataRepository: refDataRepo,
            navCalculator: navCalculator,
            connectionPool: pool
        )

        // LedgerService for posting transactions that create positions
        let ledgerService = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: doubleEntryValidator,
            entitlementService: entitlementService
        )

        return (
            valuationService, accountRepo, positionRepo, refDataRepo,
            accountGroupRepo, userRepo, entitlementRepo, ledgerService, pool
        )
    }

    // MARK: - Database Preparation

    /// Ensures the test database schema exists and all tables are clean.
    ///
    /// Called at the start of every test function. Lazily initialises
    /// the `accounting_test` schema on first call, then truncates only
    /// the tables used by this valuation test suite.
    private func prepareDatabase() async throws {
        if TestDatabaseSetup.connectionPool == nil {
            try await TestDatabaseSetup.setUp()
        }
        try await cleanValuationTables()
    }

    /// Truncates only the tables used by valuation integration tests.
    ///
    /// Tables cleaned (in reverse-FK dependency order):
    /// - transactions, positions, accounts, reference_data, entitlements,
    ///   account_groups, users
    ///
    /// FK checks are temporarily disabled for safe truncation regardless of order.
    private func cleanValuationTables() async throws {
        guard let pool = TestDatabaseSetup.connectionPool else { return }
        try await pool.withConnection { db in
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE transactions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE positions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE reference_data").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    // MARK: - Date Helper

    /// Creates a clean UTC midnight `Date` for a given calendar date.
    ///
    /// Used to construct deterministic market dates for reference data creation
    /// and valuation queries. The UTC timezone ensures consistent formatting by
    /// `ReferenceDataRepository`'s `mysqlDate()` helper.
    private func makeMarketDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Prerequisite Helpers

    /// Creates the minimum prerequisite data for a valuation test:
    /// a user, an account group, an entitlement (READ + CREATE), and an account.
    ///
    /// - Parameters:
    ///   - s: The service tuple from `buildServices()`.
    ///   - timezone: IANA timezone string for the account (Rule 3).
    ///   - fundType: Fund type classification for the account.
    ///   - suffix: A unique suffix to prevent name collisions across tests.
    /// - Returns: Tuple of created entity IDs for use in subsequent test steps.
    private func createPrerequisites(
        _ s: (
            valuationService: ValuationService,
            accountRepo: AccountRepository,
            positionRepo: PositionRepository,
            refDataRepo: ReferenceDataRepository,
            accountGroupRepo: AccountGroupRepository,
            userRepo: UserRepository,
            entitlementRepo: EntitlementRepository,
            ledgerService: LedgerService,
            pool: ConnectionPool
        ),
        timezone: String = "America/New_York",
        fundType: Persistence.FundType = .etf,
        suffix: String = "A"
    ) async throws -> (userId: UInt64, groupId: UInt64, accountId: UInt64) {
        // Create user (password hash is a dummy bcrypt value; login is not tested here)
        let user = try await s.userRepo.create(
            Persistence.User(
                id: 0,
                username: "val_user_\(suffix)",
                passwordHash: "$2b$12$dummyhashforvaluationtestuser00"
            )
        )

        // Create account group (FK prerequisite for accounts and entitlements)
        let group = try await s.accountGroupRepo.create(
            Persistence.AccountGroup(
                id: 0,
                groupName: "ValGroup_\(suffix)",
                metadata: nil,
                createdAt: Date()
            )
        )

        // Create entitlement with READ + CREATE permissions
        // (CREATE required by LedgerService.postTransaction entitlement check)
        _ = try await s.entitlementRepo.create(
            Persistence.Entitlement(
                id: 0,
                userId: user.id,
                accountGroupId: group.id,
                canRead: true,
                canCreate: true,
                canModify: false,
                canDelete: false
            )
        )

        // Create account with specified timezone and fund type
        let account = try await s.accountRepo.create(
            Persistence.Account(
                id: 0,
                name: "ValAccount_\(suffix)",
                fundType: fundType,
                ownershipDetails: nil,
                valuationTimezone: timezone,
                valuationSchedule: nil,
                cachedValuationAmount: nil,
                cachedValueDate: nil,
                status: .active,
                accountGroupId: group.id,
                createdAt: Date()
            )
        )

        return (user.id, group.id, account.id)
    }

    // MARK: - Test 1: NAV Formula Correctness

    /// Validates the core NAV formula: `Σ(quantity × EOD midpoint) + cash_balance`
    /// where EOD midpoint = `(eod_bid + eod_ask) / 2`.
    ///
    /// Posts a buy transaction via LedgerService (full integration path) to create
    /// a position of 200 shares with known EOD prices, then verifies the computed
    /// NAV matches the hand-calculated expected value.
    @Test("NAV formula: Σ(qty × EOD midpoint) + cash_balance")
    func testNAVFormulaCorrectness() async throws {
        try await prepareDatabase()
        let s = buildServices()

        // Create prerequisites with timezone "America/New_York"
        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "NAV1")
        let marketDate = makeMarketDate(year: 2024, month: 6, day: 15)

        // Create reference data: eod_bid=100.00, eod_ask=102.00 → midpoint=101.00
        let refData = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0,
                ticker: "AAPL",
                name: "Apple Inc",
                sodBid: Decimal(99),
                sodAsk: Decimal(101),
                eodBid: Decimal(100),
                eodAsk: Decimal(102),
                marketDate: marketDate
            )
        )

        // Post buy transaction: 200 shares of AAPL (balanced debit/credit)
        // LedgerService validates double-entry (Rule 1) and creates position as side effect
        _ = try await s.ledgerService.postTransaction(
            userId: prereqs.userId,
            accountId: prereqs.accountId,
            accountGroupId: prereqs.groupId,
            instrumentId: refData.id,
            quantity: Decimal(200),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: Decimal(20200),
            creditAmount: Decimal(20200)
        )

        // Run valuation
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )

        // Verify NAV formula: 200 × ((100 + 102) / 2) = 200 × 101 = 20200.00
        let expectedMidpoint = Decimal.midpoint(bid: Decimal(100), ask: Decimal(102))
        let expectedNAV = Decimal(200) * expectedMidpoint
        #expect(expectedMidpoint == Decimal(101), "Midpoint should be 101.00")
        #expect(valuation.valueAmount == expectedNAV,
            "NAV should be 20200.00 but got \(valuation.valueAmount)")
        #expect(valuation.accountId == prereqs.accountId,
            "Valuation account ID should match")
        #expect(valuation.positionsValued == 1,
            "Should have valued 1 position")
    }

    // MARK: - Test 2: NAV with Multiple Positions

    /// Validates that NAV correctly aggregates across multiple instrument positions.
    ///
    /// Creates two instruments with different EOD prices and verifies the total
    /// NAV equals the sum of individual position values.
    @Test("NAV calculation with multiple instrument positions")
    func testNAVMultiplePositions() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "NAV2")
        let marketDate = makeMarketDate(year: 2024, month: 6, day: 15)

        // Instrument A: eod_bid=50, eod_ask=52 → midpoint=51
        let refA = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "MSFT", name: "Microsoft Corp",
                sodBid: Decimal(49), sodAsk: Decimal(51),
                eodBid: Decimal(50), eodAsk: Decimal(52),
                marketDate: marketDate
            )
        )

        // Instrument B: eod_bid=200, eod_ask=204 → midpoint=202
        let refB = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "GOOG", name: "Alphabet Inc",
                sodBid: Decimal(199), sodAsk: Decimal(203),
                eodBid: Decimal(200), eodAsk: Decimal(204),
                marketDate: marketDate
            )
        )

        // Create positions: 100 of A, 50 of B
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refA.id, quantity: Decimal(100), assetType: "equity"
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refB.id, quantity: Decimal(50), assetType: "equity"
            )
        )

        // Run valuation
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )

        // Expected: (100 × 51) + (50 × 202) = 5100 + 10100 = 15200.00
        let midA = Decimal.midpoint(bid: Decimal(50), ask: Decimal(52))
        let midB = Decimal.midpoint(bid: Decimal(200), ask: Decimal(204))
        let expectedNAV = Decimal(100) * midA + Decimal(50) * midB

        #expect(midA == Decimal(51), "Instrument A midpoint should be 51")
        #expect(midB == Decimal(202), "Instrument B midpoint should be 202")
        #expect(valuation.valueAmount == expectedNAV,
            "NAV should be 15200.00 but got \(valuation.valueAmount)")
        #expect(valuation.positionsValued == 2,
            "Should have valued 2 positions")
    }

    // MARK: - Test 3: Timezone Distinct Value Dates (Rule 3)

    /// **Critical Rule 3 Test**: Two accounts with different IANA timezones
    /// must produce value dates computed from their respective stored timezones.
    ///
    /// Creates one account in `America/New_York` and another in `Europe/London`,
    /// runs valuation for both, and verifies:
    /// 1. Each valuation's `timezone` field matches the account's stored timezone.
    /// 2. Value dates are computed using the account timezone, not the system clock.
    /// 3. The `valueDateForTimezone` utility function produces consistent results.
    @Test("Two accounts with different timezones produce distinct value dates (Rule 3)")
    func testTimezoneDistinctValueDates() async throws {
        try await prepareDatabase()
        let s = buildServices()

        // Create two accounts with different IANA timezones
        let prereqs1 = try await createPrerequisites(
            s, timezone: "America/New_York", fundType: .etf, suffix: "TZ_NY"
        )
        let prereqs2 = try await createPrerequisites(
            s, timezone: "Europe/London", fundType: .openMutualFund, suffix: "TZ_LDN"
        )

        let marketDate = makeMarketDate(year: 2024, month: 6, day: 15)

        // Create shared reference data for both accounts
        let refData = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "IBM", name: "IBM Corp",
                sodBid: Decimal(140), sodAsk: Decimal(142),
                eodBid: Decimal(145), eodAsk: Decimal(147),
                marketDate: marketDate
            )
        )

        // Create positions for both accounts
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs1.accountId,
                instrumentId: refData.id, quantity: Decimal(10), assetType: "equity"
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs2.accountId,
                instrumentId: refData.id, quantity: Decimal(10), assetType: "equity"
            )
        )

        // Run batch valuation for both accounts
        let valuations = try await s.valuationService.runValuation(
            for: [prereqs1.accountId, prereqs2.accountId],
            marketDate: marketDate
        )

        // Locate each valuation by account ID
        let val1 = valuations.first { $0.accountId == prereqs1.accountId }
        let val2 = valuations.first { $0.accountId == prereqs2.accountId }
        #expect(val1 != nil, "Should have a valuation for NY account")
        #expect(val2 != nil, "Should have a valuation for London account")

        guard let nyValuation = val1, let londonValuation = val2 else { return }

        // CRITICAL Rule 3 verification:
        // Each valuation must carry the account's stored IANA timezone — NOT the system clock timezone
        #expect(nyValuation.timezone == "America/New_York",
            "NY valuation timezone must be America/New_York, got \(nyValuation.timezone)")
        #expect(londonValuation.timezone == "Europe/London",
            "London valuation timezone must be Europe/London, got \(londonValuation.timezone)")

        // Independently compute expected value dates using the same utility
        // that ValuationService uses internally
        let now = Date()
        let expectedNYDate = try now.valueDateForTimezone("America/New_York")
        let expectedLondonDate = try now.valueDateForTimezone("Europe/London")

        // Value dates must match timezone-aware computation
        // (both calls happen within milliseconds, so calendar dates are identical
        // unless the test runs at the exact instant of midnight crossing)
        #expect(nyValuation.valueDate == expectedNYDate,
            "NY value date should match timezone-aware computation")
        #expect(londonValuation.valueDate == expectedLondonDate,
            "London value date should match timezone-aware computation")

        // Both accounts have the same positions, so NAV should be identical
        let expectedMidpoint = Decimal.midpoint(bid: Decimal(145), ask: Decimal(147))
        let expectedNAV = Decimal(10) * expectedMidpoint
        #expect(nyValuation.valueAmount == expectedNAV,
            "NY NAV should match expected value")
        #expect(londonValuation.valueAmount == expectedNAV,
            "London NAV should match expected value")
    }

    // MARK: - Test 4: Cached Valuation Atomic Write (Rule 11)

    /// **Critical Rule 11 Test**: After running valuation, the `accounts` table row
    /// must reflect the correct `cached_valuation_amount` and `cached_value_date`,
    /// updated atomically within the same DB transaction as the valuation write.
    ///
    /// Verifies the before-and-after state of the account record to confirm that
    /// cached values are nil before first valuation and correctly populated after.
    @Test("Cached valuation amount and date updated atomically in accounts table (Rule 11)")
    func testCachedValuationAtomic() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "CACHE1")
        let marketDate = makeMarketDate(year: 2024, month: 7, day: 1)

        // Verify initial state: cached valuation fields are nil (no valuation run yet)
        let accountBefore = try await s.accountRepo.findById(prereqs.accountId)
        #expect(accountBefore != nil, "Account should exist")
        #expect(accountBefore?.cachedValuationAmount == nil,
            "Cached valuation amount should be nil before first valuation")
        #expect(accountBefore?.cachedValueDate == nil,
            "Cached value date should be nil before first valuation")

        // Create reference data and position
        let refData = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "TSLA", name: "Tesla Inc",
                sodBid: Decimal(240), sodAsk: Decimal(242),
                eodBid: Decimal(250), eodAsk: Decimal(252),
                marketDate: marketDate
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refData.id, quantity: Decimal(50), assetType: "equity"
            )
        )

        // Run valuation
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )

        // Expected NAV: 50 × ((250 + 252) / 2) = 50 × 251 = 12550.00
        let expectedNAV = Decimal(50) * Decimal.midpoint(bid: Decimal(250), ask: Decimal(252))
        #expect(valuation.valueAmount == expectedNAV,
            "NAV should be 12550.00")

        // Re-read the account from the database — Rule 11 atomic verification
        let accountAfter = try await s.accountRepo.findById(prereqs.accountId)
        #expect(accountAfter != nil, "Account should still exist after valuation")
        #expect(accountAfter?.cachedValuationAmount == expectedNAV,
            "Cached valuation amount should equal computed NAV (\(expectedNAV)) after valuation run")
        #expect(accountAfter?.cachedValueDate != nil,
            "Cached value date must be non-nil after valuation run")

        // Compare cached value date with valuation date at calendar-day granularity.
        // MySQL DATE columns store only year-month-day (no time/timezone); when read
        // back, the Date is midnight UTC. The valuation value date carries the account
        // timezone offset (e.g., midnight EDT = 04:00 UTC). Both represent the same
        // calendar day in UTC, so we compare using Calendar.isDate(_:inSameDayAs:).
        if let cachedDate = accountAfter?.cachedValueDate {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            #expect(utcCalendar.isDate(cachedDate, inSameDayAs: valuation.valueDate),
                "Cached value date (\(cachedDate)) must be same calendar day (UTC) as valuation value date (\(valuation.valueDate))")
        }
    }

    // MARK: - Test 5: Valuation Uses Account Timezone (Rule 3)

    /// **Rule 3 Test**: Verifies that ValuationEngine uses the account's stored
    /// IANA timezone string (`Asia/Tokyo`, UTC+9) — never the system clock timezone.
    ///
    /// The Valuation result must carry `timezone == "Asia/Tokyo"` and the value date
    /// must be computed relative to that timezone.
    @Test("ValuationEngine uses account's stored timezone — never system clock (Rule 3)")
    func testValuationUsesAccountTimezone() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(
            s, timezone: "Asia/Tokyo", fundType: .openMutualFund, suffix: "TZ_TOK"
        )
        let marketDate = makeMarketDate(year: 2024, month: 8, day: 10)

        // Create reference data and position
        let refData = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "NVDA", name: "NVIDIA Corp",
                sodBid: Decimal(110), sodAsk: Decimal(112),
                eodBid: Decimal(115), eodAsk: Decimal(117),
                marketDate: marketDate
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refData.id, quantity: Decimal(80), assetType: "equity"
            )
        )

        // Run valuation
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )

        // Verify timezone is the account's stored value, not the system default
        #expect(valuation.timezone == "Asia/Tokyo",
            "Valuation must use account timezone 'Asia/Tokyo', got '\(valuation.timezone)'")

        // Verify value date matches independent computation with Asia/Tokyo
        let now = Date()
        let expectedTokyoDate = try now.valueDateForTimezone("Asia/Tokyo")
        #expect(valuation.valueDate == expectedTokyoDate,
            "Value date must be computed using Asia/Tokyo timezone")

        // The system timezone is typically UTC on CI — verify it's NOT being used
        let systemTimezone = TimeZone.current.identifier
        if systemTimezone != "Asia/Tokyo" {
            // If system TZ differs from account TZ, the timezone field
            // should still be the account's timezone, not the system's
            #expect(valuation.timezone != systemTimezone,
                "Valuation timezone must not be the system clock timezone (\(systemTimezone))")
        }

        // Verify NAV correctness: 80 × ((115 + 117) / 2) = 80 × 116 = 9280.00
        let expectedNAV = Decimal(80) * Decimal.midpoint(bid: Decimal(115), ask: Decimal(117))
        #expect(valuation.valueAmount == expectedNAV,
            "NAV should be 9280.00 but got \(valuation.valueAmount)")
    }

    // MARK: - Test 6: Cached Valuation Updated on Rerun

    /// Verifies that `cached_valuation_amount` and `cached_value_date` are updated
    /// correctly when a second valuation is run after adding additional positions.
    ///
    /// Flow:
    /// 1. Create account with 1 position → run valuation → verify cached NAV = X
    /// 2. Add a second position → run valuation again → verify cached NAV = Y (Y > X)
    @Test("Cached valuation updates correctly on subsequent valuation runs")
    func testCachedValuationUpdatesOnRerun() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "RERUN")
        let marketDate = makeMarketDate(year: 2024, month: 9, day: 1)

        // Create first instrument and position
        let refA = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "META", name: "Meta Platforms",
                sodBid: Decimal(310), sodAsk: Decimal(312),
                eodBid: Decimal(320), eodAsk: Decimal(322),
                marketDate: marketDate
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refA.id, quantity: Decimal(30), assetType: "equity"
            )
        )

        // First valuation: 30 × ((320 + 322) / 2) = 30 × 321 = 9630.00
        let val1 = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )
        let expectedNAV1 = Decimal(30) * Decimal.midpoint(bid: Decimal(320), ask: Decimal(322))
        #expect(val1.valueAmount == expectedNAV1,
            "First valuation NAV should be 9630.00")

        // Verify cached value after first run
        let accountAfter1 = try await s.accountRepo.findById(prereqs.accountId)
        #expect(accountAfter1?.cachedValuationAmount == expectedNAV1,
            "Cached valuation after first run should be 9630.00")

        // Add second instrument and position
        let refB = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "AMZN", name: "Amazon.com Inc",
                sodBid: Decimal(180), sodAsk: Decimal(182),
                eodBid: Decimal(185), eodAsk: Decimal(187),
                marketDate: marketDate
            )
        )
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: refB.id, quantity: Decimal(20), assetType: "equity"
            )
        )

        // Second valuation includes both positions:
        // 30 × 321 + 20 × ((185 + 187) / 2) = 9630 + 20 × 186 = 9630 + 3720 = 13350.00
        let val2 = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )
        let expectedNAV2 = expectedNAV1 + Decimal(20) * Decimal.midpoint(
            bid: Decimal(185), ask: Decimal(187)
        )
        #expect(val2.valueAmount == expectedNAV2,
            "Second valuation NAV should be 13350.00 but got \(val2.valueAmount)")
        #expect(val2.valueAmount > val1.valueAmount,
            "Second valuation should be higher than first after adding positions")

        // Verify cached value updated to new amount
        let accountAfter2 = try await s.accountRepo.findById(prereqs.accountId)
        #expect(accountAfter2?.cachedValuationAmount == expectedNAV2,
            "Cached valuation after second run should be updated to \(expectedNAV2)")
    }

    // MARK: - Test 7: NAV with Cash Balance

    /// Validates that NAV correctly includes cash balance where cash price
    /// is fixed at `AppConstants.cashPrice` (1.00).
    ///
    /// Since the positions table ENUM only allows 'equity' by default,
    /// this test temporarily alters the table to permit 'cash' positions,
    /// then reverts the schema change after the test.
    ///
    /// Expected formula: `NAV = Σ(qty × midpoint) + cash_balance × 1.00`
    @Test("NAV includes cash balance with cash price fixed at 1.00")
    func testNAVWithCashBalance() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "CASH")
        let valuationMarketDate = makeMarketDate(year: 2024, month: 6, day: 15)

        // Create equity reference data for the valuation market date
        let equityRef = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "JPM", name: "JPMorgan Chase",
                sodBid: Decimal(190), sodAsk: Decimal(192),
                eodBid: Decimal(195), eodAsk: Decimal(197),
                marketDate: valuationMarketDate
            )
        )

        // Create a dummy reference_data entry for the cash instrument (FK requirement).
        // Use a DIFFERENT market date so it is NOT included in the NAV midpoint loop lookup
        let cashMarketDate = makeMarketDate(year: 2024, month: 1, day: 1)
        let cashRef = try await s.refDataRepo.create(
            Persistence.ReferenceData(
                id: 0, ticker: "CASH_USD", name: "US Dollar Cash",
                sodBid: Decimal(1), sodAsk: Decimal(1),
                eodBid: Decimal(1), eodAsk: Decimal(1),
                marketDate: cashMarketDate
            )
        )

        // Create equity position using the repository
        _ = try await s.positionRepo.create(
            Persistence.Position(
                id: 0, accountId: prereqs.accountId,
                instrumentId: equityRef.id, quantity: Decimal(100), assetType: "equity"
            )
        )

        // ALTER TABLE to allow 'cash' in the asset_type ENUM, then insert cash position
        // via raw SQL, since PositionRepository.create() enforces equity-only (Rule 5)
        try await s.pool.withConnection { db in
            _ = try await db.simpleQuery(
                "ALTER TABLE positions MODIFY COLUMN asset_type ENUM('equity','cash') NOT NULL DEFAULT 'equity'"
            ).get()
            _ = try await db.simpleQuery(
                "INSERT INTO positions (account_id, instrument_id, quantity, asset_type) " +
                "VALUES (\(prereqs.accountId), \(cashRef.id), 5000.000000, 'cash')"
            ).get()
        }

        // Run valuation on the equity market date
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: valuationMarketDate
        )

        // Expected NAV:
        // Equity value: 100 × ((195 + 197) / 2) = 100 × 196 = 19600
        // Cash balance: 5000 (quantity) × cashPrice(1.0) = 5000
        // Total NAV = 19600 + 5000 = 24600.00
        //
        // Note: cashPrice is applied once when extracting the cash balance
        // (quantity × cashPrice). The resulting balance is added directly
        // to the equity value — no second multiplication by cashPrice.
        let equityMidpoint = Decimal.midpoint(bid: Decimal(195), ask: Decimal(197))
        let equityValue = Decimal(100) * equityMidpoint
        let cashBalance = Decimal(5000) * AppConstants.cashPrice
        let expectedNAV = equityValue + cashBalance

        #expect(equityMidpoint == Decimal(196), "Equity midpoint should be 196")
        #expect(AppConstants.cashPrice == Decimal(1), "Cash price must be fixed at 1.00")
        #expect(valuation.valueAmount == expectedNAV,
            "NAV should include cash balance: expected \(expectedNAV), got \(valuation.valueAmount)")

        // Revert ENUM to original schema to not affect other tests
        try await s.pool.withConnection { db in
            // Remove the cash position first (FK constraint)
            _ = try await db.simpleQuery(
                "DELETE FROM positions WHERE asset_type = 'cash' AND account_id = \(prereqs.accountId)"
            ).get()
            _ = try await db.simpleQuery(
                "ALTER TABLE positions MODIFY COLUMN asset_type ENUM('equity') NOT NULL DEFAULT 'equity'"
            ).get()
        }
    }

    // MARK: - Test 8: Empty Account Valuation

    /// Validates that valuation of an account with no positions returns zero NAV
    /// and correctly updates the cached valuation fields to zero.
    @Test("Valuation of account with no positions returns zero")
    func testEmptyAccountValuation() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let prereqs = try await createPrerequisites(s, timezone: "America/New_York", suffix: "EMPTY")
        let marketDate = makeMarketDate(year: 2024, month: 10, day: 1)

        // Run valuation on an account with no positions
        let valuation = try await s.valuationService.runSingleAccountValuation(
            accountId: prereqs.accountId,
            marketDate: marketDate
        )

        // Verify zero NAV
        #expect(valuation.valueAmount == Decimal.zero,
            "Empty account NAV should be zero but got \(valuation.valueAmount)")
        #expect(valuation.positionsValued == 0,
            "Empty account should have 0 positions valued")
        #expect(valuation.accountId == prereqs.accountId,
            "Valuation account ID must match")
        #expect(valuation.timezone == "America/New_York",
            "Timezone must match account setting even with no positions")

        // Verify cached valuation is updated to zero (Rule 11 — atomic write even for zero)
        let accountAfter = try await s.accountRepo.findById(prereqs.accountId)
        #expect(accountAfter != nil, "Account should exist after empty valuation")
        #expect(accountAfter?.cachedValuationAmount == Decimal.zero,
            "Cached valuation amount should be zero after empty valuation")
        #expect(accountAfter?.cachedValueDate != nil,
            "Cached value date should be set even for zero-NAV valuation")
    }
}
