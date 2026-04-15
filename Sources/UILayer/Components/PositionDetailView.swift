#if canImport(SwiftUI)
// PositionDetailView.swift
// Sources/UILayer/Components/PositionDetailView.swift
//
// Expandable position detail view component for the WealthLedger accounting engine.
// Displays per-position breakdown of an account's holdings: ticker symbol, instrument
// name, quantity, EOD midpoint price, and market value (quantity × midpoint).
//
// This component is used by AccountsViewerView when an account row is expanded to
// reveal the positions held by that account. Designed for use within LazyVStack
// for 30fps scrolling performance (Rule 7 + Rule 13).
//
// SPDX-License-Identifier: MIT

import SwiftUI
import LedgerEngine
import ReferenceDataService
import Shared

// MARK: - PositionDisplayItem

/// A paired position and its reference data prepared for display purposes.
///
/// Combines data from a ``Position`` (quantity, ID) and its corresponding
/// ``ReferenceData`` (ticker, name, EOD prices) into a single display-ready
/// value type. Pre-computes ``marketValue`` at initialization time to avoid
/// repeated calculations during SwiftUI view body evaluation.
///
/// ## Valuation Formula Context
///
/// Each position's market value is computed as:
/// ```
/// marketValue = quantity × EOD midpoint
/// ```
/// where `EOD midpoint = (EOD_bid + EOD_ask) / 2`.
///
/// The aggregate NAV for an account is `Σ(marketValue) + cash balance`,
/// computed by ``NAVCalculator`` in the ``ValuationEngine`` module.
///
/// ## Concurrency Safety
///
/// Conforms to ``Sendable`` for Swift 6 strict concurrency (Gate 2).
/// All stored properties are `Sendable`-conforming value types (`UInt64`,
/// `String`, `Decimal`), making the conformance trivially correct with zero
/// `@unchecked Sendable` annotations.
///
/// ## Identifiable Conformance
///
/// Conforms to ``Identifiable`` via the ``id`` property (sourced from
/// ``Position.id``) to enable direct use with SwiftUI's `ForEach`.
public struct PositionDisplayItem: Identifiable, Sendable {

    // MARK: - Stored Properties

    /// Unique identifier for this display item, sourced from ``Position.id``.
    ///
    /// Maps to `positions.id` (BIGINT UNSIGNED) in the MySQL schema.
    /// Enables ``Identifiable`` conformance for `ForEach` usage in SwiftUI.
    public let id: UInt64

    /// NYSE equity ticker symbol (e.g., "AAPL", "MSFT", "GOOG").
    ///
    /// Sourced from ``ReferenceData.ticker``. Displayed as the primary
    /// identifier in each position row with semibold weight.
    public let ticker: String

    /// Human-readable company name (e.g., "Apple Inc.", "Microsoft Corporation").
    ///
    /// Sourced from ``ReferenceData.name``. Displayed as secondary context
    /// text alongside the ticker symbol.
    public let instrumentName: String

    /// Number of units/shares held in this position.
    ///
    /// Sourced from ``Position.quantity``. Uses `Decimal` for exact financial
    /// arithmetic — never `Double` or `Float`. A positive value represents
    /// a long position; zero represents a fully liquidated holding.
    public let quantity: Decimal

    /// End-of-day midpoint price: `(EOD_bid + EOD_ask) / 2`.
    ///
    /// Sourced from ``ReferenceData.eodMidpoint``, which internally uses
    /// `Decimal.midpoint(bid:ask:)` from the `Shared` module for exact
    /// decimal arithmetic with no floating-point rounding.
    public let eodMidpoint: Decimal

    /// Pre-computed market value: `quantity × eodMidpoint`.
    ///
    /// Calculated once at initialization to avoid repeated computation
    /// during SwiftUI view body evaluation, supporting 30fps scrolling
    /// performance within `LazyVStack`.
    public let marketValue: Decimal

    // MARK: - Initializer

    /// Creates a new display item by pairing a position with its reference data.
    ///
    /// Pre-computes ``marketValue`` as `position.quantity * referenceData.eodMidpoint`
    /// at initialization time for optimal view rendering performance.
    ///
    /// - Parameters:
    ///   - position: The account position providing `id` and `quantity`.
    ///   - referenceData: The instrument's reference data providing `ticker`,
    ///     `name`, and `eodMidpoint` (computed from EOD bid/ask prices).
    public init(position: Position, referenceData: ReferenceData) {
        self.id = position.id
        self.ticker = referenceData.ticker
        self.instrumentName = referenceData.name
        self.quantity = position.quantity
        self.eodMidpoint = referenceData.eodMidpoint
        self.marketValue = position.quantity * referenceData.eodMidpoint
    }
}

// MARK: - PositionDetailView

/// Expandable position list view showing instrument details per account.
///
/// Displays each position's:
/// - Instrument ticker symbol (e.g., "AAPL") — semibold, fixed-width for alignment
/// - Instrument name (e.g., "Apple Inc.") — secondary text, single line
/// - Quantity held (e.g., "150") — monospaced digits for alignment
/// - Current midpoint price: `(EOD_bid + EOD_ask) / 2` — monospaced digits
/// - Market value: `quantity × EOD midpoint` — currency formatted
///
/// ## Usage Context
///
/// Used by ``AccountsViewerView`` when expanding an account row to reveal
/// the positions held by that account:
///
/// ```swift
/// DisclosureGroup("Positions") {
///     PositionDetailView(positions: displayItems)
/// }
/// ```
///
/// ## Performance
///
/// Designed for use within `LazyVStack` for 30fps scrolling performance.
/// All expensive computations (market value, midpoint) are pre-computed
/// in ``PositionDisplayItem`` at initialization time.
///
/// ## Empty State
///
/// When `positions` is empty, displays an italicized "No positions" message
/// instead of an empty container, following defensive UI patterns.
///
/// ## Concurrency Safety
///
/// SwiftUI `View` conformance provides `@MainActor` isolation in Swift 6.
/// All stored properties are `Sendable` value types. No mutable state,
/// no async operations. Zero `@unchecked Sendable` annotations.
public struct PositionDetailView: View {

    // MARK: - Properties

    /// The list of positions with reference data to display.
    ///
    /// Each item contains pre-computed display values sourced from
    /// ``Position`` and ``ReferenceData`` model types. The array may be
    /// empty, in which case a "No positions" placeholder is shown.
    public let positions: [PositionDisplayItem]

    // MARK: - Initializer

    /// Creates a position detail view with the given display items.
    ///
    /// - Parameter positions: An array of ``PositionDisplayItem`` values
    ///   to render. Pass an empty array to show the empty state.
    public init(positions: [PositionDisplayItem]) {
        self.positions = positions
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if positions.isEmpty {
                Text("No positions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(positions) { item in
                    positionRow(item)
                }
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 4)
    }

    // MARK: - Position Row

    /// Renders a single position row displaying ticker, name, quantity,
    /// midpoint price, and market value in a horizontal layout.
    ///
    /// - Parameter item: The position display item to render.
    /// - Returns: A horizontal stack containing the position's details.
    @ViewBuilder
    private func positionRow(_ item: PositionDisplayItem) -> some View {
        HStack(spacing: 12) {
            // Ticker symbol — semibold, fixed width for column alignment
            Text(item.ticker)
                .font(.body)
                .fontWeight(.semibold)
                .frame(width: 60, alignment: .leading)

            // Instrument name — secondary text, truncated to single line
            Text(item.instrumentName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Quantity — monospaced digits for tabular alignment
            Text("Qty: \(formattedQuantity(item.quantity))")
                .font(.caption)
                .monospacedDigit()

            // Midpoint price — monospaced digits for tabular alignment
            Text("Mid: \(formattedPrice(item.eodMidpoint))")
                .font(.caption)
                .monospacedDigit()

            // Market value — currency formatted, right-aligned fixed width
            Text(formattedAmount(item.marketValue))
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting Helpers

    /// Formats a Decimal amount as a USD currency string.
    ///
    /// Uses `NumberFormatter` with `.currency` style and "USD" currency code.
    /// Output examples: "$15,234.50", "$0.00", "-$1,200.00".
    ///
    /// - Parameter amount: The decimal amount to format.
    /// - Returns: A currency-formatted string, or "$0.00" if formatting fails.
    private func formattedAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    /// Formats a Decimal price value with 2–4 decimal places.
    ///
    /// Uses `NumberFormatter` with `.decimal` style for price display.
    /// Output examples: "152.50", "1,234.5678", "0.01".
    ///
    /// - Parameter price: The decimal price to format.
    /// - Returns: A decimal-formatted string, or "0.00" if formatting fails.
    private func formattedPrice(_ price: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 2
        return formatter.string(from: price as NSDecimalNumber) ?? "0.00"
    }

    /// Formats a Decimal quantity with up to 6 decimal places.
    ///
    /// Uses `NumberFormatter` with `.decimal` style for quantity display.
    /// Trailing zeros are removed (minimumFractionDigits = 0).
    /// Output examples: "150", "1,000.5", "0.123456".
    ///
    /// - Parameter quantity: The decimal quantity to format.
    /// - Returns: A decimal-formatted string, or "0" if formatting fails.
    private func formattedQuantity(_ quantity: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        return formatter.string(from: quantity as NSDecimalNumber) ?? "0"
    }
}
#endif
