// Sources/AccountManagement/Models/Account.swift
// WealthLedger — Core Account Data Model
//
// Central entity representing institutional and wealth management accounts.
// Maps directly to the MySQL `accounts` table (migration 004_create_accounts.sql).

import Foundation

/// Core account data model representing institutional and wealth management accounts.
///
/// `Account` is the central entity in the WealthLedger system, modeling the complete lifecycle
/// of institutional fund accounts (open/closed mutual funds, ETFs, hedge funds) and wealth
/// management accounts (separately managed accounts, unified managed accounts).
///
/// ## MySQL Table Mapping
///
/// Every property maps to a column in the `accounts` table defined by migration
/// `004_create_accounts.sql`. The ``CodingKeys`` enum translates between Swift camelCase
/// property names and MySQL snake_case column names for serialization.
///
/// ## Per-Account Valuation Timezone (Rule 3)
///
/// Each account stores its own IANA timezone identifier in ``valuationTimezone``
/// (e.g., `"America/New_York"`, `"Europe/London"`). The `ValuationEngine` module **must**
/// use this stored timezone when computing value dates — never the system clock timezone
/// (`TimeZone.current`). This ensures that two accounts configured for different timezones
/// produce distinct value dates for the same calendar instant.
///
/// ## Cached Valuation Denormalization (Rule 11)
///
/// ``cachedValuationAmount`` and ``cachedValueDate`` store the most recent NAV valuation
/// result, updated atomically within the same database transaction as each valuation run
/// completion. Both properties are `nil` until the first valuation is performed for the
/// account. This denormalization avoids expensive joins when displaying account values
/// in the Accounts Viewer screen.
///
/// ## RBAC Entitlement Scoping (Rule 4)
///
/// Every account belongs to exactly one ``AccountGroup`` via ``accountGroupId``. The RBAC
/// module uses this foreign key to determine which users have READ/CREATE/MODIFY/DELETE
/// access. Users without READ permission for an account's group receive an empty result
/// set — not an error.
///
/// ## Concurrency Safety (Gate 2)
///
/// `Account` is a value type (`struct`) with all properties declared as `let` and composed
/// entirely of `Sendable` types (`UInt64`, `String`, `String?`, `Decimal?`, `Date?`,
/// ``FundType``, ``AccountStatus``). It conforms to `Sendable` without any `@unchecked`
/// annotations, satisfying Swift 6 strict concurrency requirements with zero warnings.
///
/// ## Protocol Conformances
///
/// - `Sendable`: Safe to pass across concurrency domains (value type, immutable).
/// - `Codable`: Automatic serialization/deserialization using ``CodingKeys`` mapping.
/// - `Identifiable`: Satisfied by the ``id`` property (`UInt64`).
/// - `Equatable`: Auto-synthesized for all stored properties.
public struct Account: Sendable, Codable, Identifiable, Equatable {

    // MARK: - Primary Key

    /// Unique account identifier.
    ///
    /// Maps to MySQL column: `id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY`.
    /// `UInt64` matches the MySQL `BIGINT UNSIGNED` type exactly.
    public let id: UInt64

    // MARK: - Core Properties

    /// Human-readable account name.
    ///
    /// Maps to MySQL column: `account_name VARCHAR(255) NOT NULL`.
    /// Searchable by partial name match using `LIKE 'prefix%'` with a B-tree index
    /// (`idx_accounts_name`) to meet the 2-second search threshold across 100,000 accounts.
    public let name: String

    /// Fund type classification determining the account's investment product category.
    ///
    /// Maps to MySQL column:
    /// `fund_type ENUM('open_mutual_fund', 'closed_mutual_fund', 'etf', 'hedge_fund', 'sma', 'uma') NOT NULL`.
    ///
    /// Institutional types: ``FundType/openMutualFund``, ``FundType/closedMutualFund``,
    /// ``FundType/etf``, ``FundType/hedgeFund``.
    /// Wealth types: ``FundType/sma``, ``FundType/uma``.
    public let fundType: FundType

    /// Optional freeform ownership information for the account.
    ///
    /// Maps to MySQL column: `ownership_details TEXT`.
    /// May include beneficial owner details, custody arrangements, or other
    /// account-specific ownership metadata. `nil` when not provided.
    public let ownershipDetails: String?

    // MARK: - Valuation Configuration

    /// IANA timezone identifier governing this account's valuation date computation.
    ///
    /// Maps to MySQL column: `valuation_timezone VARCHAR(64) NOT NULL DEFAULT 'America/New_York'`.
    ///
    /// **Rule 3 — Per-Account Valuation Timezone**: The `ValuationEngine` must use this
    /// stored timezone when computing value dates — never `TimeZone.current` or any
    /// system-level timezone. For example, an account with `valuationTimezone` set to
    /// `"America/New_York"` and another set to `"Europe/London"` will produce distinct
    /// value dates for the same UTC instant.
    ///
    /// Valid values are IANA timezone identifiers such as `"America/New_York"`,
    /// `"Europe/London"`, `"Asia/Tokyo"`, or `"US/Eastern"`.
    public let valuationTimezone: String

    /// Optional schedule description for when valuations should be performed.
    ///
    /// Maps to MySQL column: `valuation_schedule VARCHAR(255)`.
    /// Descriptive values such as `"daily"`, `"weekly"`, or `"monthly"`.
    /// `nil` when no specific schedule is defined.
    public let valuationSchedule: String?

    // MARK: - Cached Valuation (Rule 11)

    /// Cached latest NAV (Net Asset Value) valuation amount.
    ///
    /// Maps to MySQL column: `cached_valuation_amount DECIMAL(20,6) DEFAULT NULL`.
    ///
    /// **Rule 11 — Cached Valuation Denormalization**: Updated atomically within the same
    /// database transaction as each valuation run completion by the `ValuationEngine`.
    /// The NAV formula is: `Σ(quantity × EOD midpoint) + cash_balance`, where EOD midpoint
    /// equals `(bid + ask) / 2` and cash position price is fixed at `1.00`.
    ///
    /// `nil` until the first valuation is performed for this account.
    public let cachedValuationAmount: Decimal?

    /// Cached date of the latest valuation result.
    ///
    /// Maps to MySQL column: `cached_value_date DATE DEFAULT NULL`.
    ///
    /// **Rule 11 — Cached Valuation Denormalization**: Updated atomically within the same
    /// database transaction as the corresponding ``cachedValuationAmount``. The date
    /// reflects the value date computed using the account's ``valuationTimezone``, not
    /// the system clock timezone.
    ///
    /// `nil` until the first valuation is performed for this account.
    public let cachedValueDate: Date?

    // MARK: - Status and Grouping

    /// Current lifecycle status of the account.
    ///
    /// Maps to MySQL column: `account_status ENUM('active', 'inactive', 'pending', 'suspended') NOT NULL DEFAULT 'pending'`.
    ///
    /// Status values:
    /// - ``AccountStatus/active``: Fully operational — transactions, valuations, and reporting permitted.
    /// - ``AccountStatus/inactive``: Temporarily deactivated — historical data retained.
    /// - ``AccountStatus/pending``: Awaiting activation or approval (default for new accounts).
    /// - ``AccountStatus/suspended``: Restricted due to compliance or administrative action.
    ///
    /// Batch status updates for up to 1,000 accounts are supported via `AccountService`.
    public let status: AccountStatus

    /// Foreign key linking this account to its parent account group.
    ///
    /// Maps to MySQL column: `account_group_id BIGINT UNSIGNED NOT NULL`
    /// with a foreign key constraint referencing `account_groups(id)`.
    ///
    /// **Rule 4 — Entitlement Enforcement**: Every account belongs to exactly one account
    /// group. The RBAC module uses this relationship to determine per-user entitlements
    /// (READ/CREATE/MODIFY/DELETE). Users without READ access to the group receive zero
    /// records — not an error.
    public let accountGroupId: UInt64

    // MARK: - Audit

    /// Timestamp when this account was created.
    ///
    /// Maps to MySQL column: `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`.
    /// Automatically set by MySQL on row insertion; provided as a read-only property
    /// for display and audit purposes.
    public let createdAt: Date

    // MARK: - CodingKeys

    /// Maps Swift camelCase property names to MySQL snake_case column names.
    ///
    /// Used by `Codable` conformance for automatic serialization and deserialization
    /// when reading from or writing to the MySQL database via the persistence layer.
    enum CodingKeys: String, CodingKey {
        case id
        case name = "account_name"
        case fundType = "fund_type"
        case ownershipDetails = "ownership_details"
        case valuationTimezone = "valuation_timezone"
        case valuationSchedule = "valuation_schedule"
        case cachedValuationAmount = "cached_valuation_amount"
        case cachedValueDate = "cached_value_date"
        case status = "account_status"
        case accountGroupId = "account_group_id"
        case createdAt = "created_at"
    }

    // MARK: - Initializer

    /// Creates a new `Account` instance with all required and optional properties.
    ///
    /// - Parameters:
    ///   - id: Unique account identifier (MySQL `BIGINT UNSIGNED AUTO_INCREMENT`).
    ///   - name: Human-readable account name (MySQL `VARCHAR(255)`).
    ///   - fundType: Fund type classification from ``FundType`` enum.
    ///   - ownershipDetails: Optional freeform ownership information. Pass `nil` if not applicable.
    ///   - valuationTimezone: IANA timezone identifier (e.g., `"America/New_York"`).
    ///     The `ValuationEngine` uses this timezone exclusively for value date computation (Rule 3).
    ///   - valuationSchedule: Optional valuation schedule description (e.g., `"daily"`).
    ///   - cachedValuationAmount: Cached latest NAV amount. Pass `nil` for new accounts
    ///     that have not yet been valued (Rule 11).
    ///   - cachedValueDate: Cached latest valuation date. Pass `nil` for new accounts
    ///     that have not yet been valued (Rule 11).
    ///   - status: Account lifecycle status from ``AccountStatus`` enum.
    ///   - accountGroupId: Foreign key to the parent account group (for RBAC scoping).
    ///   - createdAt: Timestamp of account creation.
    public init(
        id: UInt64,
        name: String,
        fundType: FundType,
        ownershipDetails: String?,
        valuationTimezone: String,
        valuationSchedule: String?,
        cachedValuationAmount: Decimal?,
        cachedValueDate: Date?,
        status: AccountStatus,
        accountGroupId: UInt64,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.fundType = fundType
        self.ownershipDetails = ownershipDetails
        self.valuationTimezone = valuationTimezone
        self.valuationSchedule = valuationSchedule
        self.cachedValuationAmount = cachedValuationAmount
        self.cachedValueDate = cachedValueDate
        self.status = status
        self.accountGroupId = accountGroupId
        self.createdAt = createdAt
    }
}
