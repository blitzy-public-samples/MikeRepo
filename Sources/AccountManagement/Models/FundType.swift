// Sources/AccountManagement/Models/FundType.swift
// WealthLedger — Fund Type Classification Enum
//
// Defines the complete investment product universe for institutional and wealth accounts.
// Raw values map directly to the MySQL ENUM column in the accounts table (migration 004).

import Foundation

/// Fund type classification covering institutional and wealth account categories.
///
/// This enum defines the complete investment product universe for WealthLedger:
/// - **Institutional**: Open/closed mutual funds, ETFs, hedge funds
/// - **Wealth**: Separately managed accounts (SMAs), unified managed accounts (UMAs)
///
/// Raw values map directly to MySQL ENUM values in the `accounts` table (migration 004):
/// ```sql
/// fund_type ENUM('open_mutual_fund', 'closed_mutual_fund', 'etf', 'hedge_fund', 'sma', 'uma')
/// ```
///
/// Conforms to:
/// - `String` raw value for MySQL ENUM mapping
/// - `Sendable` for Swift 6 strict concurrency safety (trivially satisfied as a value type)
/// - `Codable` for automatic serialization/deserialization via `String` raw value
/// - `CaseIterable` for UI dropdown population and iteration
/// - `Hashable` (implicit via `String` raw value) for use in sets and dictionary keys
public enum FundType: String, Sendable, Codable, CaseIterable {

    // MARK: - Institutional Account Types

    /// Open-end mutual fund — shares are continuously issued and redeemed at NAV.
    /// Investors buy and sell shares directly with the fund at end-of-day NAV.
    case openMutualFund = "open_mutual_fund"

    /// Closed-end mutual fund — fixed number of shares traded on an exchange.
    /// Share price may trade at a premium or discount to the fund's NAV.
    case closedMutualFund = "closed_mutual_fund"

    /// Exchange-traded fund — basket of securities traded on an exchange like individual stocks.
    /// Provides intraday liquidity with market-price execution.
    case etf = "etf"

    /// Hedge fund — pooled investment vehicle using alternative strategies for institutional investors.
    /// Typically employs leverage, derivatives, or short selling.
    case hedgeFund = "hedge_fund"

    // MARK: - Wealth Account Types

    /// Separately managed account — individually owned portfolio managed by a professional.
    /// The investor owns the underlying securities directly, not shares in a pooled vehicle.
    case sma = "sma"

    /// Unified managed account — single account combining multiple investment strategies.
    /// Integrates separately managed accounts, mutual funds, and ETFs in one custodial account.
    case uma = "uma"
}

// MARK: - Category Classification

extension FundType {

    /// Whether this fund type falls under the Institutional category.
    ///
    /// Institutional fund types include:
    /// - Open-end mutual funds (`.openMutualFund`)
    /// - Closed-end mutual funds (`.closedMutualFund`)
    /// - Exchange-traded funds (`.etf`)
    /// - Hedge funds (`.hedgeFund`)
    ///
    /// This property is useful for filtering accounts by category in `AccountService` search
    /// and for grouping in the SearchView type dropdown.
    public var isInstitutional: Bool {
        switch self {
        case .openMutualFund, .closedMutualFund, .etf, .hedgeFund:
            return true
        case .sma, .uma:
            return false
        }
    }

    /// Whether this fund type falls under the Wealth category.
    ///
    /// Wealth fund types include:
    /// - Separately managed accounts (`.sma`)
    /// - Unified managed accounts (`.uma`)
    ///
    /// This is the logical complement of ``isInstitutional``.
    public var isWealth: Bool {
        !isInstitutional
    }
}

// MARK: - Display Support

extension FundType {

    /// Human-readable display name for UI presentation.
    ///
    /// Used by SearchView type dropdown and AccountsViewerView to render
    /// fund type labels in a user-friendly format.
    ///
    /// | Case | Display Name |
    /// |------|-------------|
    /// | `.openMutualFund` | "Open Mutual Fund" |
    /// | `.closedMutualFund` | "Closed Mutual Fund" |
    /// | `.etf` | "ETF" |
    /// | `.hedgeFund` | "Hedge Fund" |
    /// | `.sma` | "Separately Managed Account" |
    /// | `.uma` | "Unified Managed Account" |
    public var displayName: String {
        switch self {
        case .openMutualFund:
            return "Open Mutual Fund"
        case .closedMutualFund:
            return "Closed Mutual Fund"
        case .etf:
            return "ETF"
        case .hedgeFund:
            return "Hedge Fund"
        case .sma:
            return "Separately Managed Account"
        case .uma:
            return "Unified Managed Account"
        }
    }
}
