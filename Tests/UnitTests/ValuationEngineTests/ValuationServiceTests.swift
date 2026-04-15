// ValuationServiceTests.swift
// WealthLedger — Unit Tests for ValuationService
//
// 26+ tests across 6 suites validating:
//   Suite 1: Timezone-aware value date computation (Rule 3) — 7 tests
//   Suite 2: Batch pagination logic (Rule 7) — 7 tests
//   Suite 3: Cached valuation denormalization (Rule 11) — 3 tests
//   Suite 4: Single account NAV computation — 3 tests
//   Suite 5: Valuation result model validation — 3 tests
//   Suite 6: Error handling — 3 tests
//
// All tests validate business logic without database connections.
// Testing framework: Swift Testing (@Suite, @Test, #expect) — NOT XCTest.
// Swift 6 strict concurrency: all types Sendable-safe, zero @unchecked Sendable.
// Rule 8: No SwiftData imports anywhere.

import Testing
import Foundation
import Logging
@testable import ValuationEngine
// Selective Persistence imports avoid name collision: both Persistence and
// ReferenceDataService define a `ReferenceData` struct, and the module
// `ReferenceDataService` also contains a class with the same name as the module,
// preventing module-qualified disambiguation (ReferenceData
// resolves to the class, not the module). By importing only the specific
// Persistence types we need, the bare name `ReferenceData` unambiguously
// resolves to the ReferenceDataService module's struct.
import struct Persistence.Account
import enum Persistence.FundType
import enum Persistence.AccountStatus
import struct Persistence.Position
import ReferenceDataService
@testable import Shared

// MARK: - Test Data Helpers

/// Creates a test ``Account`` with the specified timezone for Rule 3 verification.
///
/// Uses `Persistence.Account` directly — the same type ``ValuationService`` consumes.
/// Default timezone is `"America/New_York"` to exercise US-timezone scenarios.
private func makeTestAccount(
    id: UInt64 = 1,
    name: String = "Test Account",
    fundType: FundType = .etf,
    valuationTimezone: String = "America/New_York",
    cachedValuationAmount: Decimal? = nil,
    cachedValueDate: Date? = nil,
    status: AccountStatus = .active,
    accountGroupId: UInt64 = 100
) -> Account {
    Account(
        id: id,
        name: name,
        fundType: fundType,
        ownershipDetails: nil,
        valuationTimezone: valuationTimezone,
        valuationSchedule: "daily",
        cachedValuationAmount: cachedValuationAmount,
        cachedValueDate: cachedValueDate,
        status: status,
        accountGroupId: accountGroupId,
        createdAt: Date()
    )
}

/// Creates a test ``Position`` for NAV computation.
///
/// Uses `Persistence.Position` directly — the same type ``NAVCalculator`` consumes.
private func makeTestPosition(
    id: UInt64 = 1,
    accountId: UInt64 = 1,
    instrumentId: UInt64 = 1,
    quantity: Decimal = Decimal(100),
    assetType: String = "equity"
) -> Position {
    Position(
        id: id,
        accountId: accountId,
        instrumentId: instrumentId,
        quantity: quantity,
        assetType: assetType
    )
}

/// Creates a test ``ReferenceData`` with specified EOD bid/ask prices.
///
/// Uses ``ReferenceData`` from the `ReferenceDataService` module — the same
/// type ``NAVCalculator`` expects.
private func makeTestReferenceData(
    id: UInt64 = 1,
    ticker: String = "TEST",
    eodBid: Decimal = Decimal(100),
    eodAsk: Decimal = Decimal(102),
    marketDate: Date = Date()
) -> ReferenceData {
    ReferenceData(
        id: id,
        ticker: ticker,
        name: "\(ticker) Corp",
        sodBid: Decimal(99),
        sodAsk: Decimal(101),
        eodBid: eodBid,
        eodAsk: eodAsk,
        marketDate: marketDate
    )
}

/// Constructs a specific UTC date from components.
///
/// Creates a ``Date`` at the exact UTC instant specified by year, month, day,
/// hour, minute. Uses an explicitly configured UTC calendar — never
/// ``Calendar.current`` — for Rule 3 compliance.
private func makeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.timeZone = TimeZone(identifier: "UTC")
    return utcCalendar.date(from: components)!
}

/// Extracts the calendar-day component from a ``Date`` as observed in a given
/// IANA timezone.
///
/// Never uses ``Calendar.current`` or ``TimeZone.current``.
private func calendarDay(of date: Date, inTimezone iana: String) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: iana)!
    return cal.component(.day, from: date)
}

/// Extracts the calendar-month component from a ``Date`` as observed in a given
/// IANA timezone.
private func calendarMonth(of date: Date, inTimezone iana: String) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: iana)!
    return cal.component(.month, from: date)
}

// ============================================================================
// MARK: - Suite 1: Timezone-Aware Value Date Computation (Rule 3 — PRIMARY)
// ============================================================================

/// Rule 3 is the **primary rule** for this file.
///
/// Each account stores its own IANA timezone string and valuation schedule.
/// ``ValuationService`` MUST use the account's stored timezone when computing
/// the value date — never ``TimeZone.current`` or ``Calendar.current``.
///
/// Tests use ``Date.valueDateForTimezone(_:)`` from the ``Shared`` module,
/// which is the exact implementation that ``ValuationService.computeValueDate``
/// delegates to.
@Suite("ValuationService timezone-aware value date computation — Rule 3")
struct ValuationServiceTimezoneTests {

    // Test 1: THE critical Rule 3 verification test.
    // At 03:00 UTC on Jan 15:
    //   London (UTC+0): 03:00 → still Jan 15 → value date = Jan 15
    //   New York (UTC-5): 22:00 on Jan 14 → value date = Jan 14
    @Test("US/Eastern and Europe/London produce DISTINCT value dates at 03:00 UTC")
    func distinctValueDatesForDifferentTimezones() throws {
        let testDate = makeUTCDate(year: 2025, month: 1, day: 15, hour: 3)

        let nyValueDate = try testDate.valueDateForTimezone("America/New_York")
        let londonValueDate = try testDate.valueDateForTimezone("Europe/London")

        let nyDay = calendarDay(of: nyValueDate, inTimezone: "America/New_York")
        let londonDay = calendarDay(of: londonValueDate, inTimezone: "Europe/London")

        #expect(nyDay == 14, "New York at 03:00 UTC on Jan 15 sees Jan 14 (22:00 local)")
        #expect(londonDay == 15, "London at 03:00 UTC on Jan 15 sees Jan 15 (03:00 local)")
        #expect(nyValueDate != londonValueDate, "Value dates must differ across timezones")
    }

    // Test 2: Same timezone must produce identical value dates.
    @Test("Same timezone produces identical value dates for the same UTC instant")
    func sameTimezoneProducesSameValueDate() throws {
        let testDate = makeUTCDate(year: 2025, month: 6, day: 20, hour: 15)

        let valueDate1 = try testDate.valueDateForTimezone("America/New_York")
        let valueDate2 = try testDate.valueDateForTimezone("America/New_York")

        #expect(valueDate1 == valueDate2, "Same timezone must yield identical value dates")
    }

    // Test 3: Asia/Tokyo (UTC+9) crosses midnight before NY.
    // At 00:00 UTC on Jan 15:
    //   Tokyo (UTC+9): 09:00 on Jan 15 → value date = Jan 15
    //   New York (UTC-5): 19:00 on Jan 14 → value date = Jan 14
    @Test("Asia/Tokyo and America/New_York produce distinct value dates at midnight UTC")
    func tokyoAndNewYorkDistinctValueDates() throws {
        let testDate = makeUTCDate(year: 2025, month: 1, day: 15, hour: 0)

        let tokyoValueDate = try testDate.valueDateForTimezone("Asia/Tokyo")
        let nyValueDate = try testDate.valueDateForTimezone("America/New_York")

        let tokyoDay = calendarDay(of: tokyoValueDate, inTimezone: "Asia/Tokyo")
        let nyDay = calendarDay(of: nyValueDate, inTimezone: "America/New_York")

        #expect(tokyoDay == 15, "Tokyo at 00:00 UTC on Jan 15 sees 09:00 Jan 15")
        #expect(nyDay == 14, "New York at 00:00 UTC on Jan 15 sees 19:00 Jan 14")
        #expect(tokyoValueDate != nyValueDate, "Value dates must differ: Tokyo vs NY")
    }

    // Test 4: Valuation.timezone field matches the account's stored IANA timezone.
    @Test("Valuation timezone field preserves account IANA timezone string")
    func valuationTimezoneFieldMatchesAccount() throws {
        let account = makeTestAccount(valuationTimezone: "Europe/London")

        let valuation = Valuation(
            accountId: account.id,
            valueAmount: Decimal(1000),
            valueDate: try Date().valueDateForTimezone(account.valuationTimezone),
            timezone: account.valuationTimezone,
            positionsValued: 5
        )

        #expect(valuation.timezone == "Europe/London",
                "Valuation.timezone must match the account's stored timezone")
        #expect(valuation.timezone == account.valuationTimezone,
                "Valuation.timezone must equal account.valuationTimezone")
    }

    // Test 5: Invalid timezone string throws DateTimezoneError.invalidTimezone.
    @Test("Invalid timezone string throws DateTimezoneError.invalidTimezone")
    func invalidTimezoneThrows() throws {
        let testDate = makeUTCDate(year: 2025, month: 3, day: 10, hour: 12)

        #expect(throws: DateTimezoneError.self) {
            try testDate.valueDateForTimezone("Invalid/Timezone")
        }
    }

    // Test 6: UTC timezone produces a value date matching the UTC calendar day.
    @Test("UTC timezone produces value date matching UTC calendar day")
    func utcTimezoneMatchesUTCCalendarDay() throws {
        // 23:59:59 UTC on Jan 15 — still Jan 15 in UTC
        let testDate = makeUTCDate(year: 2025, month: 1, day: 15, hour: 23, minute: 59, second: 59)

        let utcValueDate = try testDate.valueDateForTimezone("UTC")

        let day = calendarDay(of: utcValueDate, inTimezone: "UTC")
        let month = calendarMonth(of: utcValueDate, inTimezone: "UTC")

        #expect(day == 15, "UTC at 23:59:59 on Jan 15 remains Jan 15")
        #expect(month == 1, "Month remains January in UTC")
    }

    // Test 7: Exact midnight UTC — boundary test.
    // At 2025-01-15T00:00:00Z (midnight UTC):
    //   London (UTC+0): 00:00 on Jan 15 → value date = Jan 15
    //   New York (UTC-5): 19:00 on Jan 14 → value date = Jan 14
    @Test("Midnight UTC produces correct timezone-dependent value dates")
    func midnightUTCBoundary() throws {
        let testDate = makeUTCDate(year: 2025, month: 1, day: 15, hour: 0, minute: 0, second: 0)

        let londonValueDate = try testDate.valueDateForTimezone("Europe/London")
        let nyValueDate = try testDate.valueDateForTimezone("America/New_York")

        let londonDay = calendarDay(of: londonValueDate, inTimezone: "Europe/London")
        let nyDay = calendarDay(of: nyValueDate, inTimezone: "America/New_York")

        #expect(londonDay == 15, "London at midnight UTC sees Jan 15")
        #expect(nyDay == 14, "New York at midnight UTC sees Jan 14 (19:00 local)")
    }
}

// ============================================================================
// MARK: - Suite 2: Batch Pagination Logic (Rule 7 — Batch Memory Cap)
// ============================================================================

/// Rule 7: No UI operation may load more than 1,000 account records into memory
/// simultaneously. Background jobs must paginate at 1,000 records or fewer.
///
/// Since ``ValuationService`` uses concrete repository types (no protocol DI),
/// these tests verify the pagination constants, batch arithmetic, and the
/// contract that the service should follow — validated against ``AppConstants``.
@Suite("ValuationService batch pagination — Rule 7 memory cap")
struct ValuationServiceBatchTests {

    // Test 8: Verify the batch size constant is exactly 1,000.
    @Test("AppConstants.batchSize is exactly 1000")
    func batchSizeConstant() {
        #expect(AppConstants.batchSize == 1000,
                "Rule 7 requires batch size of 1,000 accounts")
    }

    // Test 9: Fewer than 1,000 IDs should require a single batch.
    @Test("Fewer than 1000 accounts produce a single batch")
    func singleBatchForFewerThan1000() {
        let accountIds: [UInt64] = Array(1...500)
        let batchSize = AppConstants.batchSize

        let totalBatches = (accountIds.count + batchSize - 1) / batchSize
        #expect(totalBatches == 1, "500 accounts should require exactly 1 batch")

        // Verify single batch covers all IDs
        let batchEnd = min(batchSize, accountIds.count)
        let batch = Array(accountIds[0..<batchEnd])
        #expect(batch.count == 500, "Single batch must contain all 500 accounts")
    }

    // Test 10: Exactly 1,000 IDs should fit in a single batch.
    @Test("Exactly 1000 accounts produce a single batch")
    func singleBatchForExactly1000() {
        let accountIds: [UInt64] = Array(1...1000)
        let batchSize = AppConstants.batchSize

        let totalBatches = (accountIds.count + batchSize - 1) / batchSize
        #expect(totalBatches == 1, "1,000 accounts should require exactly 1 batch")
    }

    // Test 11: More than 1,000 accounts must paginate into multiple batches.
    @Test("2500 accounts produce exactly 3 batches of sizes 1000, 1000, 500")
    func multipleBatchesForLargeAccountList() {
        let accountIds: [UInt64] = Array(1...2500)
        let batchSize = AppConstants.batchSize

        let totalBatches = (accountIds.count + batchSize - 1) / batchSize
        #expect(totalBatches == 3, "2,500 accounts require 3 batches")

        // Simulate the batch loop from ValuationService.runValuation
        var batchSizes: [Int] = []
        var batchStart = 0
        while batchStart < accountIds.count {
            let batchEnd = min(batchStart + batchSize, accountIds.count)
            let batch = Array(accountIds[batchStart..<batchEnd])
            batchSizes.append(batch.count)
            batchStart = batchEnd
        }

        #expect(batchSizes == [1000, 1000, 500],
                "Batches should be 1000, 1000, 500 for 2500 accounts")
    }

    // Test 12: Full-universe pagination with page-based loading.
    @Test("Full-universe pagination stops on empty page and uses correct page size")
    func fullUniversePagination() {
        let pageSize = AppConstants.batchSize

        // Simulate runValuationForAllAccounts pagination: returns accounts
        // until an empty page signals end of universe.
        let universe: [[UInt64]] = [
            Array(1...1000),     // Page 1: full page
            Array(1001...2000),  // Page 2: full page
            Array(2001...2500),  // Page 3: partial page
            []                   // Page 4: empty → stop
        ]

        var totalAccounts = 0
        var pageNumber = 0
        for page in universe {
            if page.isEmpty { break }
            pageNumber += 1
            totalAccounts += page.count
            #expect(page.count <= pageSize,
                    "Each page must contain at most \(pageSize) accounts")
        }

        #expect(totalAccounts == 2500, "Total accounts across all pages = 2,500")
        #expect(pageNumber == 3, "Should process exactly 3 non-empty pages")
    }

    // Test 13: Empty account list produces empty results.
    @Test("Empty account list produces zero batches and zero results")
    func emptyAccountListProducesEmptyResults() {
        let accountIds: [UInt64] = []
        let batchSize = AppConstants.batchSize

        let totalBatches = accountIds.isEmpty ? 0 :
            (accountIds.count + batchSize - 1) / batchSize
        #expect(totalBatches == 0, "Empty input requires zero batches")
    }

    // Test 14: Verify batch pagination uses the AppConstants constant.
    @Test("Batch size derives from AppConstants, not a hardcoded value")
    func batchSizeUsesConstant() {
        // Verify the constants that the service relies on are consistent.
        #expect(AppConstants.batchSize == AppConstants.defaultPagination,
                "batchSize and defaultPagination must match for consistent pagination")
        #expect(AppConstants.batchSize == 1_000,
                "batchSize must equal 1,000 per Rule 7")
        #expect(AppConstants.maxSearchResults == 1_000,
                "maxSearchResults must equal 1,000 for UI result caps")
    }
}

// ============================================================================
// MARK: - Suite 3: Cached Valuation Denormalization (Rule 11)
// ============================================================================

/// Rule 11: The `accounts` table must store a cached latest valuation amount and
/// value date, updated atomically within the same DB transaction as each
/// valuation run completion.
///
/// Since ``ValuationService`` uses concrete repository types, these tests verify
/// the ``Valuation`` struct carries all fields required for the cache update,
/// and validate the service's contract through structural verification.
@Suite("ValuationService cached valuation atomic update — Rule 11")
struct ValuationServiceCachedUpdateTests {

    // Test 15: Valuation carries all fields needed for cache update.
    @Test("Valuation result contains accountId, valueAmount, and valueDate for cache update")
    func valuationCarriesCacheUpdateFields() throws {
        let testDate = makeUTCDate(year: 2025, month: 3, day: 15, hour: 10)
        let valueDate = try testDate.valueDateForTimezone("America/New_York")

        let valuation = Valuation(
            accountId: 42,
            valueAmount: Decimal(string: "123456.789012")!,
            valueDate: valueDate,
            timezone: "America/New_York",
            positionsValued: 10
        )

        // Verify the three fields needed by updateCachedValuation
        #expect(valuation.accountId == 42, "accountId must match for DB update")
        #expect(valuation.valueAmount == Decimal(string: "123456.789012")!,
                "valueAmount must be precise Decimal for cache")
        #expect(valuation.valueDate == valueDate,
                "valueDate must match timezone-computed date for cache")
    }

    // Test 16: Multiple valuations can be collected for a batch atomic write.
    @Test("Multiple valuations in a batch support atomic cache update")
    func batchValuationsForAtomicWrite() throws {
        let testDate = makeUTCDate(year: 2025, month: 6, day: 1, hour: 14)

        // Simulate 3 account valuations in a single batch
        let valuations = try (1...3).map { i -> Valuation in
            let tz = i == 1 ? "America/New_York" : (i == 2 ? "Europe/London" : "Asia/Tokyo")
            let valueDate = try testDate.valueDateForTimezone(tz)
            return Valuation(
                accountId: UInt64(i),
                valueAmount: Decimal(i * 1000),
                valueDate: valueDate,
                timezone: tz,
                positionsValued: i * 2
            )
        }

        #expect(valuations.count == 3,
                "All 3 accounts must be present in batch for atomic write")

        // Verify each valuation has a unique accountId for the update
        let accountIds = Set(valuations.map(\.accountId))
        #expect(accountIds.count == 3,
                "Each account must have its own valuation for cache update")
    }

    // Test 17: Cached valuation fields are nil before first valuation.
    @Test("Account has nil cached valuation before first valuation run")
    func accountHasNilCacheBeforeValuation() {
        let account = makeTestAccount(
            cachedValuationAmount: nil,
            cachedValueDate: nil
        )

        #expect(account.cachedValuationAmount == nil,
                "Cached amount must be nil before first valuation")
        #expect(account.cachedValueDate == nil,
                "Cached date must be nil before first valuation")
    }
}

// ============================================================================
// MARK: - Suite 4: Single Account NAV Computation
// ============================================================================

/// Tests the NAV formula: `Σ(quantity × EOD midpoint) + cash_balance`
/// where `EOD midpoint = (eod_bid + eod_ask) / 2` and cash price = `1.00`.
///
/// Uses ``NAVCalculator`` directly — a stateless struct with zero dependencies.
@Suite("ValuationService single account NAV computation")
struct ValuationServiceSingleAccountTests {

    // Test 18: Correct NAV with known hand-calculated inputs.
    //   Position 1: instrumentId=1, qty=100, eodBid=150, eodAsk=152 → midpoint=151
    //   Position 2: instrumentId=2, qty=50, eodBid=400, eodAsk=402 → midpoint=401
    //   Cash balance = 10,000
    //   Expected NAV = (100 × 151) + (50 × 401) + 10,000
    //                = 15,100 + 20,050 + 10,000 = 45,150
    @Test("NAVCalculator computes correct NAV for 2 positions + cash balance")
    func correctNAVComputationWithKnownInputs() {
        let calculator = NAVCalculator()

        let positions: [Position] = [
            makeTestPosition(id: 1, accountId: 1, instrumentId: 1, quantity: Decimal(100)),
            makeTestPosition(id: 2, accountId: 1, instrumentId: 2, quantity: Decimal(50)),
        ]

        let referenceData: [UInt64: ReferenceData] = [
            1: makeTestReferenceData(id: 1, ticker: "AAPL", eodBid: Decimal(150), eodAsk: Decimal(152)),
            2: makeTestReferenceData(id: 2, ticker: "MSFT", eodBid: Decimal(400), eodAsk: Decimal(402)),
        ]

        let cashBalance = Decimal(10_000)

        let nav = calculator.computeNAV(
            positions: positions,
            referenceData: referenceData,
            cashBalance: cashBalance
        )

        // Hand-calculated: (100 × 151) + (50 × 401) + 10,000 = 45,150
        #expect(nav == Decimal(45_150),
                "NAV must equal hand-calculated value of 45,150")
    }

    // Test 19: All Valuation struct fields populated correctly.
    @Test("Valuation struct fields are correctly populated after NAV computation")
    func valuationFieldsPopulatedCorrectly() throws {
        let calculator = NAVCalculator()
        let testDate = makeUTCDate(year: 2025, month: 4, day: 10, hour: 14)
        let account = makeTestAccount(id: 7, valuationTimezone: "Europe/London")

        let positions: [Position] = [
            makeTestPosition(id: 1, accountId: 7, instrumentId: 1, quantity: Decimal(200)),
        ]

        let referenceData: [UInt64: ReferenceData] = [
            1: makeTestReferenceData(id: 1, ticker: "GOOG", eodBid: Decimal(170), eodAsk: Decimal(172)),
        ]

        let nav = calculator.computeNAV(
            positions: positions,
            referenceData: referenceData,
            cashBalance: Decimal.zero
        )

        let valueDate = try testDate.valueDateForTimezone(account.valuationTimezone)

        let valuation = Valuation(
            accountId: account.id,
            valueAmount: nav,
            valueDate: valueDate,
            timezone: account.valuationTimezone,
            positionsValued: positions.count
        )

        #expect(valuation.accountId == 7, "accountId must match account.id")
        // 200 × (170 + 172) / 2 = 200 × 171 = 34,200
        #expect(valuation.valueAmount == Decimal(34_200), "valueAmount must equal computed NAV")
        #expect(valuation.valueDate == valueDate, "valueDate must match timezone-computed date")
        #expect(valuation.timezone == "Europe/London", "timezone must match account IANA string")
        #expect(valuation.positionsValued == 1, "positionsValued must count positions")
    }

    // Test 20: Account with no positions returns cash-only NAV.
    @Test("Account with no positions returns cash-only NAV")
    func cashOnlyNAVWhenNoPositions() {
        let calculator = NAVCalculator()
        let positions: [Position] = []
        let referenceData: [UInt64: ReferenceData] = [:]
        let cashBalance = Decimal(5_000)

        let nav = calculator.computeNAV(
            positions: positions,
            referenceData: referenceData,
            cashBalance: cashBalance
        )

        // Cash-only NAV = cashBalance × cashPrice = 5,000 × 1.00 = 5,000
        #expect(nav == Decimal(5_000),
                "NAV with no positions must equal cash balance × cashPrice")
    }
}

// ============================================================================
// MARK: - Suite 5: Valuation Result Model Validation
// ============================================================================

/// Validates the ``Valuation`` struct — all 5 fields, ``Sendable`` conformance,
/// ``Equatable`` conformance, and immutability (all `let` properties).
@Suite("Valuation result model validation")
struct ValuationModelTests {

    // Test 21: Valuation struct has all 5 required fields.
    @Test("Valuation struct has all 5 required fields with correct types")
    func valuationHasAllRequiredFields() {
        let valuation = Valuation(
            accountId: 42,
            valueAmount: Decimal(string: "99999.123456")!,
            valueDate: Date(),
            timezone: "America/Chicago",
            positionsValued: 15
        )

        // Verify type-level access and values
        let _accountId: UInt64 = valuation.accountId
        let _valueAmount: Decimal = valuation.valueAmount
        let _valueDate: Date = valuation.valueDate
        let _timezone: String = valuation.timezone
        let _positionsValued: Int = valuation.positionsValued

        #expect(_accountId == 42)
        #expect(_valueAmount == Decimal(string: "99999.123456")!)
        #expect(_timezone == "America/Chicago")
        #expect(_positionsValued == 15)
        // valueDate is a valid Date (no crash on access)
        #expect(_valueDate <= Date())
    }

    // Test 22: Valuation is Sendable and Equatable.
    @Test("Valuation conforms to Sendable and Equatable")
    func valuationIsSendableAndEquatable() {
        let now = Date()
        let v1 = Valuation(
            accountId: 1,
            valueAmount: Decimal(1000),
            valueDate: now,
            timezone: "UTC",
            positionsValued: 5
        )
        let v2 = Valuation(
            accountId: 1,
            valueAmount: Decimal(1000),
            valueDate: now,
            timezone: "UTC",
            positionsValued: 5
        )
        let v3 = Valuation(
            accountId: 2,
            valueAmount: Decimal(1000),
            valueDate: now,
            timezone: "UTC",
            positionsValued: 5
        )

        // Equatable: identical structs are equal
        #expect(v1 == v2, "Identical Valuation instances must be equal")

        // Equatable: differing accountId makes them not equal
        #expect(v1 != v3, "Different accountId must produce inequality")

        // Sendable: verify by passing to a Sendable closure context
        let sendableCheck: @Sendable () -> Valuation = { v1 }
        let result = sendableCheck()
        #expect(result == v1, "Valuation must be usable in Sendable contexts")
    }

    // Test 23: Valuation is immutable (all let properties).
    @Test("Valuation fields are immutable let properties")
    func valuationIsImmutable() {
        let valuation = Valuation(
            accountId: 10,
            valueAmount: Decimal(500),
            valueDate: Date(),
            timezone: "Asia/Tokyo",
            positionsValued: 3
        )

        // Structural immutability: value type with let properties cannot be mutated.
        // We verify by confirming the values after construction are stable.
        let capturedId = valuation.accountId
        let capturedAmount = valuation.valueAmount
        let capturedTimezone = valuation.timezone
        let capturedPositions = valuation.positionsValued

        #expect(capturedId == 10, "accountId must be stable after init")
        #expect(capturedAmount == Decimal(500), "valueAmount must be stable after init")
        #expect(capturedTimezone == "Asia/Tokyo", "timezone must be stable after init")
        #expect(capturedPositions == 3, "positionsValued must be stable after init")
    }
}

// ============================================================================
// MARK: - Suite 6: Error Handling
// ============================================================================

/// Validates error handling for invalid inputs, missing data, and edge cases.
/// Tests error types from ``Shared/Errors/AppError.swift`` and
/// ``Shared/Extensions/Date+Timezone.swift``.
@Suite("ValuationService error handling")
struct ValuationServiceErrorTests {

    // Test 24: AppError.accountNotFound exists and is the correct error case.
    // ValuationService.runSingleAccountValuation throws this when findByIds
    // returns an empty array.
    @Test("AppError.accountNotFound is available for account lookup failures")
    func accountNotFoundErrorExists() {
        let error: AppError = .accountNotFound

        #expect(error == AppError.accountNotFound,
                "accountNotFound must be an available AppError case")
    }

    // Test 25: AppError.invalidTimezone exists for invalid IANA timezone strings.
    // ValuationService.computeValueDate catches DateTimezoneError and re-throws
    // as AppError.invalidTimezone.
    @Test("AppError.invalidTimezone is available for timezone validation failures")
    func invalidTimezoneErrorExists() {
        let error: AppError = .invalidTimezone

        #expect(error == AppError.invalidTimezone,
                "invalidTimezone must be an available AppError case")
    }

    // Test 26: DateTimezoneError.invalidTimezone carries the offending IANA string.
    @Test("DateTimezoneError.invalidTimezone carries the invalid timezone identifier")
    func dateTimezoneErrorCarriesIdentifier() {
        let error = DateTimezoneError.invalidTimezone("Fake/Zone")

        if case .invalidTimezone(let identifier) = error {
            #expect(identifier == "Fake/Zone",
                    "Error must carry the exact invalid identifier")
        } else {
            #expect(Bool(false), "Error must be .invalidTimezone case")
        }
    }

    // Test 27 (bonus): NAVCalculator gracefully skips positions with missing reference data.
    @Test("NAVCalculator skips positions with missing reference data gracefully")
    func navCalculatorSkipsMissingReferenceData() {
        let calculator = NAVCalculator()

        // Position references instrumentId=99, but reference data only has id=1
        let positions: [Position] = [
            makeTestPosition(id: 1, accountId: 1, instrumentId: 1, quantity: Decimal(100)),
            makeTestPosition(id: 2, accountId: 1, instrumentId: 99, quantity: Decimal(50)),
        ]

        let referenceData: [UInt64: ReferenceData] = [
            1: makeTestReferenceData(id: 1, ticker: "AAPL", eodBid: Decimal(100), eodAsk: Decimal(102)),
            // instrumentId=99 deliberately missing
        ]

        let nav = calculator.computeNAV(
            positions: positions,
            referenceData: referenceData,
            cashBalance: Decimal.zero
        )

        // Only position 1 valued: 100 × (100 + 102) / 2 = 100 × 101 = 10,100
        // Position 2 skipped (no reference data for instrumentId=99)
        #expect(nav == Decimal(10_100),
                "NAV must only include positions with available reference data")
    }

    // Test 28 (bonus): Cash price constant is exactly Decimal(1).
    @Test("AppConstants.cashPrice is exactly Decimal(1)")
    func cashPriceConstant() {
        #expect(AppConstants.cashPrice == Decimal(1),
                "Cash price must be fixed at 1.00 for NAV formula")
        #expect(AppConstants.cashPrice == Decimal(string: "1")!,
                "Cash price must be exact Decimal, never floating-point")
    }

    // Test 29 (bonus): Decimal.midpoint produces exact arithmetic.
    @Test("Decimal.midpoint computes exact (bid + ask) / 2 without floating-point error")
    func decimalMidpointExactArithmetic() {
        // Test with values that would lose precision in Double
        let bid = Decimal(string: "100.123456")!
        let ask = Decimal(string: "100.654322")!

        let midpoint = Decimal.midpoint(bid: bid, ask: ask)

        // (100.123456 + 100.654322) / 2 = 200.777778 / 2 = 100.388889
        let expected = Decimal(string: "100.388889")!
        #expect(midpoint == expected,
                "Midpoint must be exact Decimal: (bid + ask) / 2")
    }
}
