// Sources/LedgerEngine/Models/Transaction.swift
// WealthLedger — General Ledger Accounting Engine
//
// Immutable transaction data model for the double-entry accounting system.
// This file is part of the LedgerEngine module.

import Foundation

/// Represents an immutable ledger transaction in the double-entry accounting system.
///
/// Each `Transaction` instance models a single entry in the append-only `transactions` table.
/// Transactions are **never** updated or deleted (Rule 2: Transaction Immutability).
/// Corrections are performed exclusively through offsetting entries that reference
/// the original transaction via ``restatementRefId``.
///
/// ## Double-Entry Accounting
///
/// Every transaction set posted to the ledger must satisfy the fundamental accounting equation:
/// the sum of all ``debitAmount`` values must equal the sum of all ``creditAmount`` values.
/// This invariant is enforced by `DoubleEntryValidator` before any database write.
///
/// ## Asset Class Restriction
///
/// Only equity instruments are permitted (Rule 5: Asset Class Guard). The ``assetType``
/// property must be `"equity"`. Non-equity instruments are rejected at the service layer
/// before reaching the persistence layer.
///
/// ## MySQL Column Mapping
///
/// This model maps to the `transactions` table defined in
/// `Resources/Migrations/007_create_transactions.sql`:
///
/// | Swift Property          | MySQL Column          | MySQL Type                          |
/// |-------------------------|-----------------------|-------------------------------------|
/// | ``id``                  | `id`                  | BIGINT UNSIGNED AUTO_INCREMENT PK   |
/// | ``accountId``           | `account_id`          | BIGINT UNSIGNED NOT NULL            |
/// | ``instrumentId``        | `instrument_id`       | BIGINT UNSIGNED (nullable)          |
/// | ``quantity``            | `quantity`            | DECIMAL(20,6) NOT NULL              |
/// | ``assetType``           | `asset_type`          | ENUM('equity') NOT NULL             |
/// | ``ownershipPercentage`` | `ownership_pct`       | DECIMAL(10,6)                       |
/// | ``debitAmount``         | `debit_amount`        | DECIMAL(20,6) NOT NULL              |
/// | ``creditAmount``        | `credit_amount`       | DECIMAL(20,6) NOT NULL              |
/// | ``restatementRefId``    | `restatement_ref_id`  | BIGINT UNSIGNED (nullable)          |
/// | ``createdAt``           | `created_at`          | TIMESTAMP NOT NULL                  |
///
/// ## Consumers
///
/// - `LedgerService` — creates transactions and validates double-entry balance
/// - `DoubleEntryValidator` — validates balanced debit/credit pairs
/// - `TransactionRepository` — append-only persistence operations
/// - `AccountsViewerView` — displays transaction history in the UI
public struct Transaction: Sendable, Equatable, Identifiable {

    // MARK: - Primary Key

    /// Unique identifier for this transaction.
    ///
    /// Maps to `transactions.id` (BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY).
    /// Assigned by the database upon insert and immutable thereafter.
    public let id: UInt64

    // MARK: - Foreign Keys

    /// The account this transaction belongs to.
    ///
    /// Maps to `transactions.account_id` (BIGINT UNSIGNED NOT NULL, FK → `accounts.id`).
    /// Every transaction must be associated with exactly one account.
    public let accountId: UInt64

    /// The instrument (security) involved in this transaction.
    ///
    /// Maps to `transactions.instrument_id` (BIGINT UNSIGNED, FK → `reference_data.id`).
    /// This field is optional (`nil`) for cash-only transactions that do not reference
    /// a specific instrument in the `reference_data` table.
    public let instrumentId: UInt64?

    // MARK: - Financial Fields

    /// Number of units or shares in this transaction.
    ///
    /// Maps to `transactions.quantity` (DECIMAL(20,6) NOT NULL).
    /// Uses `Decimal` for exact decimal arithmetic — never `Double` or `Float` — to
    /// prevent floating-point rounding errors in financial calculations.
    public let quantity: Decimal

    /// The asset class of the instrument.
    ///
    /// Maps to `transactions.asset_type` (ENUM('equity') NOT NULL DEFAULT 'equity').
    /// Must be `"equity"` — the application rejects all non-equity instruments at the
    /// service layer (Rule 5: Asset Class Guard).
    public let assetType: String

    /// Ownership percentage of the position, ranging from 0.0 to 100.0.
    ///
    /// Maps to `transactions.ownership_pct` (DECIMAL(10,6)).
    /// Uses `Decimal` for exact decimal arithmetic matching MySQL precision.
    public let ownershipPercentage: Decimal

    /// Debit amount for this ledger entry.
    ///
    /// Maps to `transactions.debit_amount` (DECIMAL(20,6) NOT NULL).
    /// In double-entry accounting, debits increase asset accounts and decrease
    /// liability/equity accounts. Uses `Decimal` for exact decimal arithmetic.
    public let debitAmount: Decimal

    /// Credit amount for this ledger entry.
    ///
    /// Maps to `transactions.credit_amount` (DECIMAL(20,6) NOT NULL).
    /// In double-entry accounting, credits decrease asset accounts and increase
    /// liability/equity accounts. Uses `Decimal` for exact decimal arithmetic.
    public let creditAmount: Decimal

    // MARK: - Restatement Reference

    /// Optional foreign key to the original transaction being corrected.
    ///
    /// Maps to `transactions.restatement_ref_id` (BIGINT UNSIGNED DEFAULT NULL,
    /// self-referencing FK → `transactions.id`).
    ///
    /// - When `nil`: this is an original transaction.
    /// - When populated: this is an offsetting/restatement entry that corrects the
    ///   referenced transaction.
    ///
    /// Per Rule 2 (Transaction Immutability), corrections never modify the original
    /// transaction row — they create new offsetting entries that reference the original
    /// via this foreign key.
    public let restatementRefId: UInt64?

    // MARK: - Timestamps

    /// Immutable creation timestamp for this transaction.
    ///
    /// Maps to `transactions.created_at` (TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP).
    /// This timestamp is set at insert time and is **never** updated, consistent with
    /// the append-only immutability guarantee (Rule 2).
    public let createdAt: Date

    // MARK: - Initializer

    /// Creates a new `Transaction` instance with all required fields.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (database-assigned primary key).
    ///   - accountId: Foreign key to the owning account.
    ///   - instrumentId: Optional foreign key to the instrument in reference data.
    ///     Pass `nil` for cash-only transactions.
    ///   - quantity: Number of units/shares (must use `Decimal` precision).
    ///   - assetType: Asset class — must be `"equity"` per Rule 5.
    ///   - ownershipPercentage: Ownership percentage (0.0–100.0).
    ///   - debitAmount: Debit amount for this entry (must use `Decimal` precision).
    ///   - creditAmount: Credit amount for this entry (must use `Decimal` precision).
    ///   - restatementRefId: Optional FK to the original transaction being corrected.
    ///     Pass `nil` for original transactions.
    ///   - createdAt: Immutable creation timestamp.
    public init(
        id: UInt64,
        accountId: UInt64,
        instrumentId: UInt64?,
        quantity: Decimal,
        assetType: String,
        ownershipPercentage: Decimal,
        debitAmount: Decimal,
        creditAmount: Decimal,
        restatementRefId: UInt64?,
        createdAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.quantity = quantity
        self.assetType = assetType
        self.ownershipPercentage = ownershipPercentage
        self.debitAmount = debitAmount
        self.creditAmount = creditAmount
        self.restatementRefId = restatementRefId
        self.createdAt = createdAt
    }
}
