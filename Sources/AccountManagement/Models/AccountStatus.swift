// Sources/AccountManagement/Models/AccountStatus.swift
// WealthLedger — Account Lifecycle Status Enum
//
// SPDX-License-Identifier: MIT

import Foundation

/// Account lifecycle status indicating the current operational state of an account.
///
/// The four states represent the complete lifecycle of an institutional or wealth
/// management account within the WealthLedger system:
///
/// - ``active``: Fully operational — transactions, valuations, and reporting are permitted.
/// - ``inactive``: Temporarily deactivated — historical data retained, no new transactions.
/// - ``pending``: Awaiting activation or approval — default status for newly created accounts.
/// - ``suspended``: Restricted due to compliance, regulatory, or administrative action.
///
/// ## MySQL ENUM Mapping
///
/// Raw values map directly to the MySQL `account_status` ENUM column in the `accounts`
/// table (migration `004_create_accounts.sql`):
///
/// ```sql
/// account_status ENUM('active', 'inactive', 'pending', 'suspended') NOT NULL DEFAULT 'pending'
/// ```
///
/// ## Batch Status Updates (Rule 7)
///
/// This enum supports batch status updates for up to 1,000 accounts simultaneously.
/// The batch memory cap is enforced by ``AccountService``, not by this type.
///
/// ## Concurrency Safety
///
/// `AccountStatus` is a `String`-backed enum (value type) and is trivially `Sendable`.
/// No `@unchecked Sendable` annotations or warning suppressions are required.
public enum AccountStatus: String, Sendable, Codable, CaseIterable {

    /// Account is fully operational and available for transactions, valuations, and reporting.
    ///
    /// Active accounts participate in valuation runs, appear in search results
    /// (subject to entitlement checks), and accept new ledger entries.
    case active = "active"

    /// Account is temporarily deactivated. No new transactions are permitted,
    /// but historical data is retained and accessible for reporting.
    ///
    /// An inactive account can be reactivated by changing its status back to ``active``.
    case inactive = "inactive"

    /// Account has been created but is awaiting activation or approval.
    ///
    /// This is the **default status** for newly created accounts, matching the MySQL
    /// column default: `DEFAULT 'pending'`. Pending accounts do not participate in
    /// valuation runs until activated.
    case pending = "pending"

    /// Account is suspended due to compliance, regulatory, or administrative action.
    ///
    /// Suspension is stricter than ``inactive`` — a suspended account may require
    /// additional review or approval before reactivation. Suspended accounts do not
    /// participate in valuation runs and do not accept new transactions.
    case suspended = "suspended"
}
