// NAVCalculatorTests.swift
// Tests/UnitTests/ValuationEngineTests/NAVCalculatorTests.swift
//
// Comprehensive unit tests for NAVCalculator — the pure stateless NAV
// calculation engine in the ValuationEngine module.
//
// Validates the NAV formula:
//   NAV = Σ(quantity × EOD midpoint) + cash_balance
// where EOD midpoint = (eod_bid + eod_ask) / 2
// and cash price = AppConstants.cashPrice (fixed at Decimal(1)).
//
// All expected values are hand-calculated using exact Decimal arithmetic.
// Zero database dependencies — NAVCalculator is a pure in-memory calculator.
//
// Testing Framework: Swift Testing (@Suite, @Test, #expect)
// Concurrency: Swift 6 strict — all types are value-type structs (trivially Sendable)
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import ValuationEngine
@testable import Persistence
@testable import ReferenceDataService
@testable import Shared

// MARK: - Test Data Helpers

/// Creates a test ``Position`` with the given parameters.
///
/// Uses `Persistence.Position` — the same type that ``NAVCalculator``
/// expects in its `computeNAV(positions:referenceData:cashBalance:)` API.
///
/// - Parameters:
///   - id: Unique position identifier. Defaults to `1`.
///   - accountId: Owning account identifier. Defaults to `100`.
///   - instrumentId: Instrument / reference-data identifier used as the
///     dictionary lookup key in `computeNAV`. Defaults to `1`.
///   - quantity: Number of shares/units held. Must be `Decimal`.
///   - assetType: Asset class string. Defaults to `"equity"`.
/// - Returns: A fully initialised ``Position`` instance.
private func makePosition(
    id: UInt64 = 1,
    accountId: UInt64 = 100,
    instrumentId: UInt64 = 1,
    quantity: Decimal,
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

/// Creates a test ``ReferenceData`` with the given EOD price fields.
///
/// SOD bid/ask default to reasonable non-zero values since NAVCalculator
/// only uses the EOD fields for midpoint computation.
///
/// - Parameters:
///   - id: Unique reference-data identifier — must match the dictionary key
///     and `position.instrumentId`. Defaults to `1`.
///   - ticker: Ticker symbol string. Defaults to `"TEST"`.
///   - name: Company name string. Defaults to `"Test Corp"`.
///   - sodBid: Start-of-day bid. Defaults to `Decimal(100)`.
///   - sodAsk: Start-of-day ask. Defaults to `Decimal(101)`.
///   - eodBid: End-of-day bid — required for NAV calculation.
///   - eodAsk: End-of-day ask — required for NAV calculation.
///   - marketDate: Market date for this price record. Defaults to `Date()`.
/// - Returns: A fully initialised ``ReferenceData`` instance.
private func makeReferenceData(
    id: UInt64 = 1,
    ticker: String = "TEST",
    name: String = "Test Corp",
    sodBid: Decimal = Decimal(100),
    sodAsk: Decimal = Decimal(101),
    eodBid: Decimal,
    eodAsk: Decimal,
    marketDate: Date = Date()
) -> ReferenceData {
    ReferenceData(
        id: id,
        ticker: ticker,
        name: name,
        sodBid: sodBid,
        sodAsk: sodAsk,
        eodBid: eodBid,
        eodAsk: eodAsk,
        marketDate: marketDate
    )
}

// MARK: - Suite 1: Basic NAV Formula Validation

/// Tests the core NAV formula with straightforward inputs and hand-calculated
/// expected values. Verifies single-position, multi-position, and cash-only
/// scenarios produce correct results.
@Suite("NAVCalculator basic NAV formula validation")
struct NAVCalculatorBasicTests {

    /// **Test 1** — Single position with cash balance.
    ///
    /// Position: qty = 100, eodBid = 150, eodAsk = 152
    /// Midpoint = (150 + 152) / 2 = 151
    /// Position value = 100 × 151 = 15,100
    /// Cash value = 5,000 × 1.00 = 5,000
    /// **Expected NAV = 20,100**
    @Test("Single position with cash balance produces correct NAV")
    func singlePositionWithCash() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(100))
        let ref = makeReferenceData(id: 1, eodBid: Decimal(150), eodAsk: Decimal(152))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal(5000)
        )
        #expect(result == Decimal(20100))
    }

    /// **Test 2** — Multiple positions with cash balance.
    ///
    /// Position 1: qty = 100, eodBid = 152, eodAsk = 153 → mid = 152.5 → val = 15,250
    /// Position 2: qty = 50, eodBid = 402, eodAsk = 403 → mid = 402.5 → val = 20,125
    /// Cash = 10,000 × 1.00 = 10,000
    /// **Expected NAV = 45,375**
    @Test("Multiple positions with cash balance produces correct NAV")
    func multiplePositionsWithCash() {
        let calculator = NAVCalculator()
        let pos1 = makePosition(id: 1, instrumentId: 1, quantity: Decimal(100))
        let pos2 = makePosition(id: 2, instrumentId: 2, quantity: Decimal(50))
        let ref1 = makeReferenceData(id: 1, ticker: "AAPL", eodBid: Decimal(152), eodAsk: Decimal(153))
        let ref2 = makeReferenceData(id: 2, ticker: "MSFT", eodBid: Decimal(402), eodAsk: Decimal(403))
        let result = calculator.computeNAV(
            positions: [pos1, pos2],
            referenceData: [1: ref1, 2: ref2],
            cashBalance: Decimal(10000)
        )
        #expect(result == Decimal(45375))
    }

    /// **Test 3** — Cash price uses `AppConstants.cashPrice` (= 1.00).
    ///
    /// Verifies the constant is `Decimal(1)` and that a cash-only NAV with
    /// zero positions returns exactly the cash balance.
    /// Cash value = 25,000 × AppConstants.cashPrice = 25,000 × 1.00 = 25,000
    /// **Expected NAV = 25,000**
    @Test("Cash price uses AppConstants.cashPrice fixed at 1.00")
    func cashPriceUsesAppConstants() {
        // Verify the constant is correctly defined
        #expect(AppConstants.cashPrice == Decimal(1))

        let calculator = NAVCalculator()
        let result = calculator.computeNAV(
            positions: [],
            referenceData: [:],
            cashBalance: Decimal(25000)
        )
        #expect(result == Decimal(25000))
    }
}

// MARK: - Suite 2: Edge Cases

/// Tests boundary conditions and edge cases: zero inputs, missing data,
/// large position counts, and degenerate parameter combinations.
@Suite("NAVCalculator edge cases")
struct NAVCalculatorEdgeCaseTests {

    /// **Test 4** — Zero positions and zero cash produces zero NAV.
    @Test("Zero positions and zero cash returns zero NAV")
    func zeroPositionsZeroCash() {
        let calculator = NAVCalculator()
        let result = calculator.computeNAV(
            positions: [],
            referenceData: [:],
            cashBalance: Decimal.zero
        )
        #expect(result == Decimal.zero)
    }

    /// **Test 5** — Zero positions with positive cash balance (cash-only account).
    ///
    /// **Expected NAV = 50,000**
    @Test("Zero positions with positive cash returns cash-only NAV")
    func cashOnlyAccount() {
        let calculator = NAVCalculator()
        let result = calculator.computeNAV(
            positions: [],
            referenceData: [:],
            cashBalance: Decimal(50000)
        )
        #expect(result == Decimal(50000))
    }

    /// **Test 6** — Single position with zero cash.
    ///
    /// qty = 200, eodBid = 50, eodAsk = 52 → mid = 51 → val = 10,200
    /// Cash = 0
    /// **Expected NAV = 10,200**
    @Test("Single position with zero cash returns position value only")
    func singlePositionZeroCash() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(200))
        let ref = makeReferenceData(id: 1, eodBid: Decimal(50), eodAsk: Decimal(52))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal.zero
        )
        #expect(result == Decimal(10200))
    }

    /// **Test 7** — Position with zero quantity contributes zero.
    ///
    /// qty = 0, midpoint = 101 → posValue = 0
    /// Cash = 1,000
    /// **Expected NAV = 1,000**
    @Test("Position with zero quantity contributes zero to NAV")
    func zeroQuantityPosition() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal.zero)
        let ref = makeReferenceData(id: 1, eodBid: Decimal(100), eodAsk: Decimal(102))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal(1000)
        )
        #expect(result == Decimal(1000))
    }

    /// **Test 8** — Position with missing reference data is skipped gracefully.
    ///
    /// instrumentId = 999 has no matching entry in the referenceData dictionary.
    /// NAVCalculator skips it via `guard let` / `continue`.
    /// Cash = 500
    /// **Expected NAV = 500** (position contributes zero)
    @Test("Position with missing reference data is skipped gracefully")
    func missingReferenceData() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 999, quantity: Decimal(100))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [:],
            cashBalance: Decimal(500)
        )
        #expect(result == Decimal(500))
    }

    /// **Test 9** — Stress test with 100 positions.
    ///
    /// 100 positions, each qty = 10, eodBid = eodAsk = 100 → midpoint = 100
    /// Each value = 10 × 100 = 1,000
    /// Total = 100 × 1,000 = 100,000
    /// Cash = 0
    /// **Expected NAV = 100,000**
    @Test("Large number of positions (100) produces correct total")
    func stressTestManyPositions() {
        let calculator = NAVCalculator()
        var positions: [Position] = []
        var refData: [UInt64: ReferenceData] = [:]
        for i: UInt64 in 1 ... 100 {
            positions.append(
                makePosition(id: i, instrumentId: i, quantity: Decimal(10))
            )
            refData[i] = makeReferenceData(
                id: i,
                ticker: "T\(i)",
                eodBid: Decimal(100),
                eodAsk: Decimal(100)
            )
        }
        let result = calculator.computeNAV(
            positions: positions,
            referenceData: refData,
            cashBalance: Decimal.zero
        )
        #expect(result == Decimal(100_000))
    }
}

// MARK: - Suite 3: Decimal Precision Tests

/// Tests financial precision guarantees: fractional quantities, odd spreads,
/// institutional-scale values, penny stocks, and mixed-precision aggregation.
/// All expected values use `Decimal(string:)!` to avoid any `Double` conversion.
@Suite("NAVCalculator Decimal precision and financial accuracy")
struct NAVCalculatorPrecisionTests {

    /// **Test 10** — Fractional share quantities preserve exact Decimal precision.
    ///
    /// qty = 33.333333, eodBid = eodAsk = 100 → midpoint = 100
    /// posValue = 33.333333 × 100 = 3,333.3333
    /// Cash = 0.01
    /// **Expected NAV = 3,333.3433**
    @Test("Fractional share quantities preserve precision")
    func fractionalQuantity() {
        let calculator = NAVCalculator()
        let qty = Decimal(string: "33.333333")!
        let pos = makePosition(id: 1, instrumentId: 1, quantity: qty)
        let ref = makeReferenceData(id: 1, eodBid: Decimal(100), eodAsk: Decimal(100))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal(string: "0.01")!
        )
        #expect(result == Decimal(string: "3333.3433")!)
    }

    /// **Test 11** — Odd bid/ask spread produces an exact decimal midpoint.
    ///
    /// qty = 1, eodBid = 100.01, eodAsk = 100.02
    /// midpoint = (100.01 + 100.02) / 2 = 100.015
    /// posValue = 1 × 100.015 = 100.015
    /// Cash = 0
    /// **Expected NAV = 100.015**
    @Test("Odd bid/ask spread produces exact midpoint")
    func oddSpreadMidpoint() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(1))
        let ref = makeReferenceData(
            id: 1,
            eodBid: Decimal(string: "100.01")!,
            eodAsk: Decimal(string: "100.02")!
        )
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal.zero
        )
        #expect(result == Decimal(string: "100.015")!)
    }

    /// **Test 12** — Large institutional-scale values (half-billion NAV).
    ///
    /// qty = 1,000,000, eodBid = 500, eodAsk = 502 → mid = 501
    /// posValue = 1,000,000 × 501 = 501,000,000
    /// Cash = 10,000,000
    /// **Expected NAV = 511,000,000**
    @Test("Large institutional-scale values without overflow")
    func largeValues() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(1_000_000))
        let ref = makeReferenceData(id: 1, eodBid: Decimal(500), eodAsk: Decimal(502))
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal(10_000_000)
        )
        #expect(result == Decimal(511_000_000))
    }

    /// **Test 13** — Penny stock with very small values preserves precision.
    ///
    /// qty = 10,000, eodBid = 0.01, eodAsk = 0.03 → mid = 0.02
    /// posValue = 10,000 × 0.02 = 200
    /// Cash = 0.50
    /// **Expected NAV = 200.50**
    @Test("Very small penny stock values preserve precision")
    func smallValues() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(10_000))
        let ref = makeReferenceData(
            id: 1,
            eodBid: Decimal(string: "0.01")!,
            eodAsk: Decimal(string: "0.03")!
        )
        let result = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: Decimal(string: "0.5")!
        )
        #expect(result == Decimal(string: "200.5")!)
    }

    /// **Test 14** — Multiple positions with different precisions sum correctly.
    ///
    /// Position 1: qty = 100, eodBid = 152.123456, eodAsk = 152.234567
    ///   midpoint = (152.123456 + 152.234567) / 2 = 304.358023 / 2 = 152.1790115
    ///   posValue = 100 × 152.1790115 = 15,217.90115
    ///
    /// Position 2: qty = 50, eodBid = 399.99, eodAsk = 400.01
    ///   midpoint = (399.99 + 400.01) / 2 = 400.00
    ///   posValue = 50 × 400.00 = 20,000
    ///
    /// Cash = 1,234.56
    /// **Expected NAV = 15,217.90115 + 20,000 + 1,234.56 = 36,452.46115**
    @Test("Multiple positions with different precisions sum correctly")
    func mixedPrecisions() {
        let calculator = NAVCalculator()
        let pos1 = makePosition(id: 1, instrumentId: 1, quantity: Decimal(100))
        let pos2 = makePosition(id: 2, instrumentId: 2, quantity: Decimal(50))
        let ref1 = makeReferenceData(
            id: 1,
            ticker: "POS1",
            eodBid: Decimal(string: "152.123456")!,
            eodAsk: Decimal(string: "152.234567")!
        )
        let ref2 = makeReferenceData(
            id: 2,
            ticker: "POS2",
            eodBid: Decimal(string: "399.99")!,
            eodAsk: Decimal(string: "400.01")!
        )
        let result = calculator.computeNAV(
            positions: [pos1, pos2],
            referenceData: [1: ref1, 2: ref2],
            cashBalance: Decimal(string: "1234.56")!
        )
        #expect(result == Decimal(string: "36452.46115")!)
    }
}

// MARK: - Suite 4: NAVCalculator Instance and API Tests

/// Tests the NAVCalculator public API contract: initialiser, determinism,
/// and behaviour with degenerate inputs (empty arrays, empty dictionaries).
@Suite("NAVCalculator instance and API behavior")
struct NAVCalculatorAPITests {

    /// **Test 15** — NAVCalculator has a public no-argument initialiser.
    @Test("NAVCalculator can be initialized with no arguments")
    func initializerExists() {
        let calculator = NAVCalculator()
        // If compilation and execution reach here, the init exists and works.
        #expect(type(of: calculator) == NAVCalculator.self)
    }

    /// **Test 16** — `computeNAV` is deterministic: identical inputs → identical output.
    @Test("computeNAV is deterministic — same inputs produce same output")
    func determinism() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(50))
        let ref = makeReferenceData(id: 1, eodBid: Decimal(200), eodAsk: Decimal(204))
        let cash = Decimal(1000)

        let result1 = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: cash
        )
        let result2 = calculator.computeNAV(
            positions: [pos],
            referenceData: [1: ref],
            cashBalance: cash
        )
        #expect(result1 == result2)
    }

    /// **Test 17** — Empty positions array returns only cash value.
    @Test("Empty positions array returns only cash value")
    func emptyPositionsReturnsCash() {
        let calculator = NAVCalculator()
        let result = calculator.computeNAV(
            positions: [],
            referenceData: [:],
            cashBalance: Decimal(42)
        )
        #expect(result == Decimal(42))
    }

    /// **Test 18** — Empty referenceData with non-empty positions returns only cash.
    ///
    /// All positions are skipped because their `instrumentId` keys do not
    /// exist in the empty dictionary. NAV = cash balance only.
    @Test("Empty referenceData with non-empty positions returns only cash")
    func emptyRefDataReturnsCash() {
        let calculator = NAVCalculator()
        let pos1 = makePosition(id: 1, instrumentId: 1, quantity: Decimal(100))
        let pos2 = makePosition(id: 2, instrumentId: 2, quantity: Decimal(200))
        let result = calculator.computeNAV(
            positions: [pos1, pos2],
            referenceData: [:],
            cashBalance: Decimal(100)
        )
        #expect(result == Decimal(100))
    }
}

// MARK: - Suite 5: computePositionValue and computeMidpoint

/// Tests the public helper methods `computePositionValue(position:referenceData:)`
/// and `computeMidpoint(bid:ask:)` exposed by NAVCalculator. These are public
/// methods accessible via `@testable import ValuationEngine`.
@Suite("NAVCalculator helper methods")
struct NAVCalculatorHelperTests {

    /// **Test 19** — `computePositionValue` for a single position.
    ///
    /// qty = 100, eodBid = 150, eodAsk = 152 → midpoint = 151
    /// **Expected value = 100 × 151 = 15,100**
    @Test("computePositionValue returns correct single position value")
    func singlePositionValue() {
        let calculator = NAVCalculator()
        let pos = makePosition(id: 1, instrumentId: 1, quantity: Decimal(100))
        let ref = makeReferenceData(id: 1, eodBid: Decimal(150), eodAsk: Decimal(152))
        let result = calculator.computePositionValue(position: pos, referenceData: ref)
        #expect(result == Decimal(15100))
    }

    /// **Test 20** — `computeMidpoint` returns correct midpoint.
    ///
    /// bid = 100, ask = 102 → midpoint = 101
    @Test("computeMidpoint returns correct midpoint")
    func basicMidpoint() {
        let calculator = NAVCalculator()
        let result = calculator.computeMidpoint(bid: Decimal(100), ask: Decimal(102))
        #expect(result == Decimal(101))
    }

    /// **Test 21** — `computeMidpoint` with equal bid and ask (zero spread).
    ///
    /// bid = ask = 100 → midpoint = 100
    @Test("computeMidpoint with equal bid and ask returns same value")
    func zeroSpreadMidpoint() {
        let calculator = NAVCalculator()
        let result = calculator.computeMidpoint(bid: Decimal(100), ask: Decimal(100))
        #expect(result == Decimal(100))
    }

    /// **Test 22** — `computeMidpoint` with wide spread.
    ///
    /// bid = 90, ask = 110 → midpoint = 100
    @Test("computeMidpoint with wide spread returns correct midpoint")
    func wideSpreadMidpoint() {
        let calculator = NAVCalculator()
        let result = calculator.computeMidpoint(bid: Decimal(90), ask: Decimal(110))
        #expect(result == Decimal(100))
    }
}
