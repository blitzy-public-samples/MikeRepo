// DoubleEntryValidatorTests.swift
// WealthLedger — Unit Tests for DoubleEntryValidator
//
// Validates Rule 1: every set of debit/credit entries must sum to zero.
// Balanced entries pass silently; unbalanced entries throw AppError.unbalancedEntry.
//
// CRITICAL: All monetary amounts use Foundation.Decimal (base-10 exact arithmetic),
// matching MySQL DECIMAL(20,6) column precision. IEEE 754 Double/Float is NEVER used.
//   Decimal("0.1") + Decimal("0.2") == Decimal("0.3")  → TRUE  (correct)
//   0.1 + 0.2 == 0.3                                   → FALSE (IEEE 754 imprecision)
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LedgerEngine
@testable import Shared

// MARK: - DoubleEntryValidatorTests

/// Comprehensive test suite for ``DoubleEntryValidator``.
///
/// The validator is a pure, stateless struct with zero database dependencies.
/// Tests exercise both the primary ``DoubleEntryValidator/validate(debits:credits:)``
/// method and the convenience ``DoubleEntryValidator/validateTransaction(debitAmount:creditAmount:)``
/// wrapper, covering balanced entries (happy path), unbalanced entries (error path),
/// and edge cases (empty arrays, negative amounts, extreme precision, large values).
@Suite("DoubleEntryValidator Tests")
struct DoubleEntryValidatorTests {

    // MARK: - System Under Test

    /// Shared validator instance. Because `DoubleEntryValidator` is a zero-size
    /// stateless struct with no stored properties, a single shared instance is
    /// safe and identical in behavior to per-test instantiation.
    private let validator = DoubleEntryValidator()

    // MARK: - Balanced Entry Tests (Should NOT Throw)

    /// A single debit equal to a single credit is the most basic balanced entry.
    /// Also exercises the `validateTransaction` convenience method with the same
    /// values to ensure it delegates correctly.
    @Test("Balanced single debit-credit pair passes validation")
    func testBalancedSinglePair() throws {
        let debits: [Decimal] = [Decimal(100)]
        let credits: [Decimal] = [Decimal(100)]

        // Primary method — must not throw
        try validator.validate(debits: debits, credits: credits)

        // Convenience method — same balanced pair must also pass
        try validator.validateTransaction(debitAmount: Decimal(100), creditAmount: Decimal(100))
    }

    /// Both arrays empty means sum(debits) = 0 and sum(credits) = 0. The
    /// difference is zero, so the entry is trivially balanced.
    @Test("Empty debit and credit arrays are trivially balanced")
    func testEmptyArraysBalanced() throws {
        try validator.validate(debits: [], credits: [])
    }

    /// Two debits (30 + 70 = 100) matching one credit (100). Validates that
    /// many-to-one splits are accepted.
    @Test("Multiple debits summing to single credit passes validation")
    func testMultipleDebitsSingleCredit() throws {
        let debits: [Decimal] = [Decimal(30), Decimal(70)]
        let credits: [Decimal] = [Decimal(100)]

        try validator.validate(debits: debits, credits: credits)
    }

    /// One debit (100) matching two credits (40 + 60 = 100). Validates
    /// one-to-many splits are accepted.
    @Test("Single debit matching sum of multiple credits passes validation")
    func testSingleDebitMultipleCredits() throws {
        let debits: [Decimal] = [Decimal(100)]
        let credits: [Decimal] = [Decimal(40), Decimal(60)]

        try validator.validate(debits: debits, credits: credits)
    }

    /// Three debits (25 + 50 + 25 = 100) matching two credits (30 + 70 = 100).
    /// Validates arbitrary many-to-many splits.
    @Test("Multiple debits and credits with equal sums passes validation")
    func testMultipleDebitsAndCreditsBalanced() throws {
        let debits: [Decimal] = [Decimal(25), Decimal(50), Decimal(25)]
        let credits: [Decimal] = [Decimal(30), Decimal(70)]

        try validator.validate(debits: debits, credits: credits)
    }

    /// Negative amounts on both sides that are equal are mathematically
    /// balanced: -50 == -50.
    @Test("Negative amounts that balance are accepted")
    func testNegativeAmountsBalanced() throws {
        let debits: [Decimal] = [Decimal(-50)]
        let credits: [Decimal] = [Decimal(-50)]

        try validator.validate(debits: debits, credits: credits)
    }

    /// The classic floating-point trap: 0.1 + 0.2 != 0.3 in IEEE 754, but
    /// Decimal arithmetic is exact. This test proves the validator correctly
    /// considers 0.10 + 0.20 == 0.30 as balanced.
    @Test("Decimal precision amounts that balance pass validation")
    func testDecimalPrecisionBalanced() throws {
        // Decimal(string:) ensures exact base-10 representation
        let debits: [Decimal] = [Decimal(string: "0.10")!, Decimal(string: "0.20")!]
        let credits: [Decimal] = [Decimal(string: "0.30")!]

        try validator.validate(debits: debits, credits: credits)
    }

    /// Large values near the upper range of MySQL DECIMAL(20,6) must be handled
    /// correctly without overflow or precision loss.
    @Test("Large decimal values that balance pass validation")
    func testLargeValuesBalanced() throws {
        let debits: [Decimal] = [Decimal(string: "99999999999999.999999")!]
        let credits: [Decimal] = [Decimal(string: "99999999999999.999999")!]

        try validator.validate(debits: debits, credits: credits)
    }

    /// Zero debit and zero credit: 0 == 0 is balanced. This is distinct from
    /// the empty-arrays test because the arrays contain an explicit zero element.
    @Test("Zero debit and credit amounts are balanced")
    func testZeroAmountsBalanced() throws {
        let debits: [Decimal] = [Decimal.zero]
        let credits: [Decimal] = [Decimal.zero]

        try validator.validate(debits: debits, credits: credits)
    }

    // MARK: - Unbalanced Entry Tests (MUST Throw AppError.unbalancedEntry)

    /// Debit of 100 vs credit of 50 is a straightforward imbalance. Also
    /// exercises the convenience method to verify it rejects unbalanced pairs.
    @Test("Unbalanced debit-credit pair throws unbalancedEntry")
    func testUnbalancedPairThrows() throws {
        let debits: [Decimal] = [Decimal(100)]
        let credits: [Decimal] = [Decimal(50)]

        // Verify using do/catch for exact error case verification
        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }

        // Convenience method must also reject the same unbalanced pair
        do {
            try validator.validateTransaction(debitAmount: Decimal(100), creditAmount: Decimal(50))
            Issue.record("Expected AppError.unbalancedEntry from validateTransaction")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type from validateTransaction: \(type(of: error)) — \(error)")
        }
    }

    /// Non-zero debits with empty credits: sum(debits) = 100 != 0 = sum(credits).
    /// Single-sided debit entries are always unbalanced.
    @Test("Debits with empty credits array throws unbalancedEntry")
    func testDebitsOnlyThrows() throws {
        let debits: [Decimal] = [Decimal(100)]
        let credits: [Decimal] = []

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }

    /// Empty debits with non-zero credits: sum(debits) = 0 != 100 = sum(credits).
    /// Single-sided credit entries are always unbalanced.
    @Test("Credits with empty debits array throws unbalancedEntry")
    func testCreditsOnlyThrows() throws {
        let debits: [Decimal] = []
        let credits: [Decimal] = [Decimal(100)]

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }

    /// A one-cent difference (100.01 vs 100.00) MUST be detected. Decimal
    /// arithmetic catches this exactly; IEEE 754 might not in some rounding
    /// scenarios.
    @Test("Off by 0.01 throws unbalancedEntry")
    func testOffByOneCentThrows() throws {
        let debits: [Decimal] = [Decimal(string: "100.01")!]
        let credits: [Decimal] = [Decimal(string: "100.00")!]

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }

    /// Multiple entries where totals differ: debits = 25 + 50 = 75,
    /// credits = 30 + 40 = 70. The 5-unit gap must trigger rejection.
    @Test("Multiple entries that don't sum equally throw unbalancedEntry")
    func testMultipleEntriesUnbalancedThrows() throws {
        let debits: [Decimal] = [Decimal(25), Decimal(50)]
        let credits: [Decimal] = [Decimal(30), Decimal(40)]

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }

    /// Negative amounts that are NOT equal: -100 != -50. The validator must
    /// detect imbalances regardless of sign.
    @Test("Negative unbalanced entries throw unbalancedEntry")
    func testNegativeUnbalancedThrows() throws {
        let debits: [Decimal] = [Decimal(-100)]
        let credits: [Decimal] = [Decimal(-50)]

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }

    /// A difference of 0.000001 (one micro-unit) between debits and credits.
    /// Decimal arithmetic detects sub-cent differences that IEEE 754 Double
    /// would silently round away. This verifies financial-grade precision.
    @Test("Very small decimal difference throws unbalancedEntry")
    func testVerySmallDifferenceThrows() throws {
        let debits: [Decimal] = [Decimal(string: "1000000.000001")!]
        let credits: [Decimal] = [Decimal(string: "1000000.000000")!]

        do {
            try validator.validate(debits: debits, credits: credits)
            Issue.record("Expected AppError.unbalancedEntry to be thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Wrong error type: \(type(of: error)) — \(error)")
        }
    }
}
