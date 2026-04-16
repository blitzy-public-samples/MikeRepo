// NAVCalculator.swift
// Sources/ValuationEngine/Services/NAVCalculator.swift
//
// Pure NAV (Net Asset Value) calculation engine for the WealthLedger accounting system.
// Part of the ValuationEngine module.
//
// This struct implements the core NAV valuation formula:
//   NAV = Σ(quantity × EOD midpoint) + cash_balance
// where EOD midpoint = (eod_bid + eod_ask) / 2 and cash price = 1.00.
//
// Design principles:
// - Stateless and side-effect-free: all computation is from inputs to output.
// - No database access: all data is provided as parameters by the caller.
// - Deterministic: identical inputs always produce identical outputs.
// - All financial values use Decimal exclusively — never Double or Float.
// - Sendable for Swift 6 strict concurrency (Gate 2): zero mutable state.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared
import struct Persistence.Position
import ReferenceDataService

// MARK: - NAVCalculator

/// Pure NAV (Net Asset Value) calculation engine with no database access or side effects.
///
/// Computes account value using the closed-book NAV formula:
///
/// ```
/// NAV = Σ(quantity × EOD midpoint) + cash_balance
/// ```
///
/// where:
/// - **EOD midpoint** = `(eod_bid + eod_ask) / 2`, computed via
///   `Decimal.midpoint(bid:ask:)` from the `Shared` module's `Decimal+Currency`
///   extension, ensuring exact decimal arithmetic with no floating-point rounding.
/// - **Cash price** is fixed at `AppConstants.cashPrice` (`Decimal(1)`) from the
///   `Shared` module's `Constants.swift`.
///
/// ## Usage
///
/// `NAVCalculator` is consumed by ``ValuationService`` which loads position and
/// reference data from the database, invokes this calculator, and writes the
/// cached result atomically back to the `accounts` table.
///
/// ```swift
/// let calculator = NAVCalculator()
/// let nav = calculator.computeNAV(
///     positions: positions,
///     referenceData: refDataLookup,
///     cashBalance: account.cashBalance ?? Decimal.zero
/// )
/// ```
///
/// ## Concurrency Safety
///
/// `NAVCalculator` is a value-type `struct` with **zero stored properties**,
/// making it trivially `Sendable` under Swift 6 strict concurrency rules.
/// All methods are pure functions operating exclusively on their parameters
/// and returning value types. No `@unchecked Sendable` annotations are used.
///
/// ## Financial Precision
///
/// Every variable, parameter, and return value in this type uses `Decimal`
/// exclusively. No `Double`, `Float`, or `CGFloat` is used for any value
/// that participates in the NAV calculation, ensuring exact decimal arithmetic
/// required for institutional accounting.
///
/// ## Rules Compliance
///
/// - **Rule 8 (MySQLKit-Only / No SwiftData)**: This file imports only
///   `Foundation`, `Shared`, `Persistence.Position`, and `ReferenceDataService`.
///   No `SwiftData`, `MySQLKit`, `MySQLNIO`, or `SQLKit` imports.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: Zero `@unchecked Sendable`,
///   zero warning suppressions. Trivially `Sendable` as a stateless struct.
public struct NAVCalculator: Sendable {

    // MARK: - Initialization

    /// Creates a new `NAVCalculator` instance.
    ///
    /// `NAVCalculator` is stateless — no configuration is required.
    /// Each instance behaves identically because all computation depends
    /// solely on method parameters.
    public init() {}

    // MARK: - Core NAV Computation

    /// Computes the Net Asset Value (NAV) for a single account.
    ///
    /// The NAV formula is:
    ///
    /// ```
    /// NAV = Σ(quantity × EOD midpoint) + cash_value
    /// ```
    ///
    /// where `cash_value = cashBalance × AppConstants.cashPrice` (fixed at `1.00`).
    ///
    /// ## Computation Steps
    ///
    /// For each position in `positions`:
    /// 1. Look up the instrument's reference data in `referenceData` by
    ///    `position.instrumentId` (O(1) dictionary lookup).
    /// 2. Compute the EOD midpoint: `(eod_bid + eod_ask) / 2` using
    ///    `Decimal.midpoint(bid:ask:)`.
    /// 3. Compute the position value: `quantity × midpoint`.
    /// 4. Accumulate into the running total.
    ///
    /// Then add the cash value: `cashBalance × AppConstants.cashPrice`.
    ///
    /// ## Edge Cases
    ///
    /// - **Empty positions array**: Returns `cashBalance × AppConstants.cashPrice`
    ///   (the account's entire value is its cash balance).
    /// - **Missing reference data for a position**: That position is gracefully
    ///   skipped. The caller (``ValuationService``) should ensure all instruments
    ///   have reference data loaded.
    /// - **Zero cash balance**: The cash component contributes `Decimal.zero` to
    ///   the total NAV.
    /// - **Zero quantity position**: Contributes `Decimal.zero` to the total
    ///   (fully liquidated holding).
    ///
    /// - Parameters:
    ///   - positions: Array of ``Position`` objects for the account. Each position
    ///     represents a holding of an equity instrument with a `quantity` and
    ///     `instrumentId` (FK to `reference_data.id`).
    ///   - referenceData: Dictionary mapping reference data ID (`UInt64`) to
    ///     ``ReferenceData`` for O(1) EOD price lookup. Keyed by `ReferenceData.id`.
    ///   - cashBalance: The account's cash balance as `Decimal`. The cash position
    ///     is priced at `AppConstants.cashPrice` (fixed at `1.00`).
    /// - Returns: The computed NAV as a `Decimal` value with exact precision.
    public func computeNAV(
        positions: [Position],
        referenceData: [UInt64: ReferenceData],
        cashBalance: Decimal
    ) -> Decimal {
        // Accumulate the sum of all position values: Σ(quantity × EOD midpoint)
        var totalPositionValue: Decimal = Decimal.zero

        for position in positions {
            // O(1) lookup of EOD prices for this position's instrument.
            // Position.instrumentId is a FK to reference_data.id.
            guard let instrumentData = referenceData[position.instrumentId] else {
                // Reference data not found for this instrument — skip gracefully.
                // The caller (ValuationService) should ensure all instruments have
                // reference data loaded for the target market date.
                continue
            }

            // Compute EOD midpoint: (eod_bid + eod_ask) / 2
            // Uses Decimal.midpoint(bid:ask:) from Shared/Extensions/Decimal+Currency.swift
            // which performs exact division by Decimal(2).
            let midpoint: Decimal = Decimal.midpoint(bid: instrumentData.eodBid, ask: instrumentData.eodAsk)

            // Compute position value: quantity × midpoint
            // Both operands are Decimal, producing an exact Decimal result.
            let positionValue: Decimal = position.quantity * midpoint

            // Accumulate into the running total
            totalPositionValue += positionValue
        }

        // Compute cash value: cashBalance × AppConstants.cashPrice (fixed at 1.00).
        // Even though multiplying by 1.00 is mathematically a no-op, explicitly
        // using AppConstants.cashPrice documents the pricing model intent and
        // ensures consistency with the specification.
        let cashValue: Decimal = cashBalance * AppConstants.cashPrice

        // NAV = Σ(position values) + cash value
        return totalPositionValue + cashValue
    }

    // MARK: - Single Position Valuation

    /// Computes the value of a single position.
    ///
    /// Formula: `quantity × EOD midpoint` where midpoint = `(eod_bid + eod_ask) / 2`.
    ///
    /// This method is useful for:
    /// - Decomposing NAV into per-position contributions for display in the
    ///   Accounts Viewer's position detail view.
    /// - Unit testing individual position valuations in isolation.
    ///
    /// - Parameters:
    ///   - position: The ``Position`` to value, providing `quantity` for the
    ///     multiplication.
    ///   - referenceData: The instrument's ``ReferenceData`` containing `eodBid`
    ///     and `eodAsk` for midpoint computation.
    /// - Returns: The position value as `Decimal`: `quantity × (eodBid + eodAsk) / 2`.
    public func computePositionValue(
        position: Position,
        referenceData: ReferenceData
    ) -> Decimal {
        // Compute EOD midpoint using exact Decimal arithmetic
        let midpoint: Decimal = Decimal.midpoint(bid: referenceData.eodBid, ask: referenceData.eodAsk)

        // Position value = quantity × midpoint
        return position.quantity * midpoint
    }

    // MARK: - Midpoint Computation

    /// Convenience method to compute the EOD midpoint price for a single instrument.
    ///
    /// Formula: `(bid + ask) / 2`
    ///
    /// Delegates to `Decimal.midpoint(bid:ask:)` from the `Shared` module's
    /// `Decimal+Currency` extension, which performs exact division by `Decimal(2)`.
    ///
    /// This method is useful for callers that need the midpoint without
    /// constructing a full ``Position`` or ``ReferenceData`` object.
    ///
    /// - Parameters:
    ///   - bid: The bid price as `Decimal`.
    ///   - ask: The ask price as `Decimal`.
    /// - Returns: The midpoint price `(bid + ask) / 2` as `Decimal` with exact precision.
    public func computeMidpoint(bid: Decimal, ask: Decimal) -> Decimal {
        Decimal.midpoint(bid: bid, ask: ask)
    }
}
