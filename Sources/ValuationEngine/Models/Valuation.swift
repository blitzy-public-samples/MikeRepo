// MARK: - Sources/ValuationEngine/Models/Valuation.swift
// WealthLedger — General Ledger Accounting Engine
// Valuation Result Data Model

import Foundation

/// Represents the result of a NAV (Net Asset Value) valuation computation for a single account.
///
/// The valuation formula is: `Σ(quantity × EOD midpoint) + cash_balance`
/// where EOD midpoint = `(bid + ask) / 2` and cash position price is fixed at `1.00`.
///
/// Each `Valuation` instance captures:
/// - The computed NAV amount using exact `Decimal` arithmetic (never `Double` or `Float`)
/// - The value date derived from the account's stored IANA timezone (Rule 3)
/// - The IANA timezone string used for the computation
/// - The number of equity positions included in the valuation
///
/// This is a value type (`struct`) that conforms to `Sendable` for Swift 6 strict
/// concurrency safety and `Equatable` for testing and comparison support.
///
/// **Rule 3 — Per-Account Valuation Timezone**: The `valueDate` and `timezone`
/// properties reflect the account's stored IANA timezone — never the system clock timezone.
///
/// **Rule 8 — MySQLKit-Only Persistence**: This file imports only `Foundation`.
/// No SwiftData, MySQLKit, or other external dependencies are used in this data model.
///
/// **Consumers**: `ValuationService` (creates instances), `AccountsViewerView` (reads for
/// display), `AccountRepository` (reads `valueAmount` and `valueDate` for cached
/// denormalization per Rule 11), and `ReportGenerator` (reads for CSV export).
public struct Valuation: Sendable, Equatable {

    // MARK: - Stored Properties

    /// The unique identifier of the account that was valued.
    ///
    /// This corresponds to the primary key in the `accounts` table and serves as
    /// a foreign key reference linking this valuation result back to its source account.
    public let accountId: UInt64

    /// The computed NAV value: `Σ(quantity × EOD midpoint) + cash_balance`.
    ///
    /// Uses `Decimal` type exclusively for financial precision — never `Double` or `Float`.
    /// EOD midpoint is computed as `(bid + ask) / 2` per the valuation formula.
    /// Cash position price is fixed at `1.00` (see `AppConstants.cashPrice` in Shared module).
    ///
    /// This value is also written to `accounts.cached_valuation_amount` atomically
    /// within the same database transaction as the valuation run completion (Rule 11).
    public let valueAmount: Decimal

    /// The valuation date computed using the account's stored IANA timezone (Rule 3).
    ///
    /// This date represents the calendar day in the account's timezone when the
    /// valuation was performed. Two accounts in different timezones (e.g.,
    /// `"America/New_York"` vs `"Europe/London"`) may produce different value dates
    /// for the same UTC instant.
    ///
    /// **Rule 3 enforcement**: This value is derived exclusively from the account's
    /// stored IANA timezone string — never from the system clock timezone.
    ///
    /// This value is also written to `accounts.cached_value_date` atomically
    /// within the same database transaction as the valuation run completion (Rule 11).
    public let valueDate: Date

    /// The IANA timezone string used for this valuation computation.
    ///
    /// Must match the account's stored timezone (e.g., `"America/New_York"`,
    /// `"Europe/London"`, `"Asia/Tokyo"`). Stored here for auditability and to
    /// document which timezone was applied when computing `valueDate`.
    ///
    /// **Rule 3**: This is the account's timezone, never the system clock timezone.
    public let timezone: String

    /// The count of positions included in this valuation computation.
    ///
    /// Represents the number of non-cash equity positions that contributed to the
    /// NAV calculation via the `Σ(quantity × EOD midpoint)` component. Cash balances
    /// are accounted for separately and are not counted in this total.
    public let positionsValued: Int

    // MARK: - Initialization

    /// Creates a new valuation result.
    ///
    /// All parameters are stored as immutable (`let`) properties, making each
    /// `Valuation` instance a frozen snapshot of the computation result.
    ///
    /// - Parameters:
    ///   - accountId: The unique identifier of the valued account (foreign key to `accounts` table).
    ///   - valueAmount: The computed NAV value using `Decimal` precision for exact financial arithmetic.
    ///   - valueDate: The valuation date in the account's IANA timezone (Rule 3).
    ///   - timezone: The IANA timezone string from the account's stored configuration (Rule 3).
    ///   - positionsValued: The number of non-cash equity positions included in the computation.
    public init(
        accountId: UInt64,
        valueAmount: Decimal,
        valueDate: Date,
        timezone: String,
        positionsValued: Int
    ) {
        self.accountId = accountId
        self.valueAmount = valueAmount
        self.valueDate = valueDate
        self.timezone = timezone
        self.positionsValued = positionsValued
    }
}
