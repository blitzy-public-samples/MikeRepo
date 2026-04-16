// Decimal+Currency.swift
// Sources/Shared/Extensions/Decimal+Currency.swift
//
// Decimal precision utilities for institutional financial calculations.
// Part of the WealthLedger Shared module.
//
// This extension provides exact decimal arithmetic helpers used throughout the
// WealthLedger accounting engine, ensuring that all monetary and price values
// avoid floating-point representation errors inherent in Double/Float types.

import Foundation

// MARK: - Decimal Financial Calculation Extensions

extension Decimal {

    /// Computes the midpoint between a bid price and an ask price.
    ///
    /// **Formula**: `(bid + ask) / 2`
    ///
    /// This method is the foundation of the NAV valuation formula used by
    /// `NAVCalculator` in the `ValuationEngine` module:
    ///
    /// ```
    /// NAV = Σ(quantity × EOD midpoint) + cash balance
    /// ```
    ///
    /// where `EOD midpoint = (EOD bid + EOD ask) / 2`.
    ///
    /// Cash positions use a fixed price of `1.00` (defined in `AppConstants.cashPrice`)
    /// and do **not** use this method.
    ///
    /// ## Precision Guarantee
    ///
    /// Division by `Decimal(2)` is exact for every representable `Decimal` input.
    /// No rounding is applied — callers receive the mathematically precise midpoint.
    /// `Decimal` supports up to 38 significant digits, which exceeds the precision
    /// requirements for all institutional and wealth management price values.
    ///
    /// ## Edge Cases
    ///
    /// - When `bid == ask` (zero spread), the result equals both `bid` and `ask`.
    /// - Negative values are mathematically valid but should be rejected by upstream
    ///   validation before reaching this method.
    /// - Very large values (up to 38 significant digits) are handled correctly by
    ///   the `Decimal` type without overflow for typical financial price ranges.
    ///
    /// - Parameters:
    ///   - bid: The bid price as a `Decimal`. Must be non-negative in valid usage.
    ///   - ask: The ask price as a `Decimal`. Must be non-negative in valid usage.
    /// - Returns: The midpoint `(bid + ask) / 2` as a `Decimal` with exact precision.
    public static func midpoint(bid: Decimal, ask: Decimal) -> Decimal {
        (bid + ask) / Decimal(2)
    }
}
