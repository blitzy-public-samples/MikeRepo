// DoubleEntryValidator.swift
// WealthLedger - LedgerEngine Module
//
// Pure double-entry validation service enforcing Rule 1: every set of
// debit/credit entries must sum to zero before any database write occurs.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared

// MARK: - DoubleEntryValidator

/// Validates that double-entry accounting entries are balanced.
///
/// Every set of debit/credit entries must sum to zero (total debits must equal
/// total credits). This validator is the gatekeeper for **Rule 1 — Double-Entry
/// Enforcement** and is called **before** every transaction write. If entries are
/// unbalanced, ``AppError/unbalancedEntry`` is thrown and no database write
/// occurs.
///
/// ## Design Rationale
///
/// - **Stateless `struct`**: The validator carries no stored properties and
///   performs pure computation. A value type is preferred over a reference type
///   because it is lightweight, trivially ``Sendable``, and free of heap
///   allocation overhead.
/// - **`Decimal` arithmetic**: All monetary calculations use Foundation's
///   `Decimal` type for exact base-10 arithmetic, matching the MySQL
///   `DECIMAL(20,6)` column type. This avoids IEEE 754 floating-point precision
///   errors that would cause balanced entries to appear unbalanced.
/// - **Swift 6 strict concurrency (Gate 2)**: The struct has no stored
///   properties and all methods are pure functions — it is trivially `Sendable`
///   with zero `@unchecked Sendable` annotations required.
///
/// ## Usage
///
/// ```swift
/// let validator = DoubleEntryValidator()
///
/// // Balanced entries — passes silently
/// try validator.validate(debits: [Decimal(100)], credits: [Decimal(100)])
///
/// // Unbalanced entries — throws AppError.unbalancedEntry
/// try validator.validate(debits: [Decimal(100)], credits: [Decimal(50)])
/// ```
///
/// ## Consumers
///
/// - ``LedgerService``: Calls ``validate(debits:credits:)`` in
///   `postTransaction()` and `createRestatement()` before any database write.
public struct DoubleEntryValidator: Sendable {

    // MARK: - Initialization

    /// Creates a new `DoubleEntryValidator` instance.
    ///
    /// The validator is completely stateless — initialization requires no
    /// parameters and allocates no resources.
    public init() {}

    // MARK: - Primary Validation

    /// Validates that debit and credit amounts are balanced (sum to zero
    /// difference).
    ///
    /// The fundamental double-entry accounting constraint requires that the sum
    /// of all debit amounts equals the sum of all credit amounts for every
    /// transaction set. This method enforces that constraint using exact
    /// `Decimal` arithmetic.
    ///
    /// - Parameters:
    ///   - debits: Array of debit amounts for the transaction set. Each element
    ///     represents one debit leg of the entry.
    ///   - credits: Array of credit amounts for the transaction set. Each
    ///     element represents one credit leg of the entry.
    /// - Throws: ``AppError/unbalancedEntry`` if `sum(debits) != sum(credits)`.
    ///
    /// Call this method **before** every transaction write to enforce Rule 1
    /// (Double-Entry Enforcement). An empty set of debits and credits is
    /// considered balanced (`0 == 0`).
    ///
    /// ## Edge Cases
    ///
    /// | Debits | Credits | Result |
    /// |--------|---------|--------|
    /// | `[]` | `[]` | Valid (0 == 0) |
    /// | `[100]` | `[100]` | Valid |
    /// | `[30, 70]` | `[100]` | Valid (100 == 100) |
    /// | `[100]` | `[50]` | Throws `unbalancedEntry` |
    /// | `[-50]` | `[-50]` | Valid (-50 == -50) |
    public func validate(debits: [Decimal], credits: [Decimal]) throws {
        let totalDebits = debits.reduce(Decimal.zero, +)
        let totalCredits = credits.reduce(Decimal.zero, +)

        guard totalDebits == totalCredits else {
            throw AppError.unbalancedEntry
        }
    }

    // MARK: - Convenience Validation

    /// Convenience method to validate a single transaction's debit and credit
    /// amounts.
    ///
    /// This is a lightweight wrapper around ``validate(debits:credits:)`` for
    /// the common case where a transaction has exactly one debit leg and one
    /// credit leg. It delegates entirely to the primary validation method.
    ///
    /// - Parameters:
    ///   - debitAmount: The debit amount of the transaction.
    ///   - creditAmount: The credit amount of the transaction.
    /// - Throws: ``AppError/unbalancedEntry`` if `debitAmount != creditAmount`.
    ///
    /// Used by `LedgerService.postTransaction()` for single-pair validation.
    public func validateTransaction(debitAmount: Decimal, creditAmount: Decimal) throws {
        try validate(debits: [debitAmount], credits: [creditAmount])
    }
}
