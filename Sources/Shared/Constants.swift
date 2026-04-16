// Sources/Shared/Constants.swift
// WealthLedger — Application-Wide Constants
//
// Defines critical constants enforcing batch memory caps, search result limits,
// pagination defaults, and the fixed cash price used in NAV calculations.
// All values are immutable and Sendable-safe for Swift 6 strict concurrency.

import Foundation

/// Application-wide constants for the WealthLedger accounting engine.
///
/// `AppConstants` is a caseless enum used as a namespace to prevent instantiation.
/// It is trivially `Sendable` because it has no stored cases or mutable state.
/// All constants are `public static let` properties, making them accessible
/// from every module in the project: AccountManagement, LedgerEngine,
/// ValuationEngine, ReferenceDataService, JobScheduler, RBAC, UILayer,
/// Persistence, and SeedTool.
public enum AppConstants {

    // MARK: - Batch & Pagination Limits

    /// Maximum number of account records loaded into memory per batch operation.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: no UI operation may load more than
    /// 1,000 account records into memory simultaneously. Background jobs that
    /// process accounts in bulk must paginate at this size or fewer per page.
    ///
    /// - Value: `1_000`
    public static let batchSize: Int = 1_000

    /// Maximum number of search results returned in a single query.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: search results are capped at 1,000
    /// records. The `AccountService.search()` method uses this value as an upper
    /// bound on the SQL `LIMIT` clause to prevent loading excessive records.
    ///
    /// - Value: `1_000`
    public static let maxSearchResults: Int = 1_000

    /// Default page size for all paginated database queries.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: pagination at 1,000 records or fewer
    /// per page. Used by repository classes in the Persistence module when executing
    /// paginated `SELECT` queries and by the `ValuationService` when batching
    /// valuation runs.
    ///
    /// - Value: `1_000`
    public static let defaultPagination: Int = 1_000

    // MARK: - Financial Constants

    /// Fixed price for cash positions in NAV calculations.
    ///
    /// The valuation formula is `Σ(quantity × EOD midpoint) + cash_balance`, where
    /// the cash position price is always fixed at `1.00`. This constant uses
    /// `Decimal` (not `Double` or `Float`) to ensure exact decimal arithmetic
    /// required for institutional-grade financial calculations.
    ///
    /// - Value: `Decimal(1)` (exactly `1.00`)
    public static let cashPrice: Decimal = Decimal(1)
}
