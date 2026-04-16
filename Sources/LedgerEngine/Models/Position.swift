// Sources/LedgerEngine/Models/Position.swift
// WealthLedger — General Ledger Accounting Engine
//
// Position data model representing an account's holding of a specific instrument.
// Positions are created by LedgerService when buy transactions are posted and read
// by ValuationEngine for NAV calculation: Σ(quantity × EOD midpoint) + cash balance.
//
// SPDX-License-Identifier: MIT

import Foundation

/// Represents an account's holding of a specific instrument.
///
/// Each position tracks the quantity of a single equity instrument held by one account.
/// Positions are created by ``LedgerService`` when buy transactions are posted,
/// and quantities are updated when additional transactions affect the same instrument.
/// The ``ValuationEngine`` reads positions to compute NAV:
/// `Σ(quantity × EOD midpoint) + cash balance`.
///
/// ## MySQL Schema Mapping
///
/// This struct maps to the `positions` table defined in migration 006:
///
/// | Swift Property  | MySQL Column    | MySQL Type                    | Nullable |
/// |-----------------|-----------------|-------------------------------|----------|
/// | `id`            | `id`            | BIGINT UNSIGNED AUTO_INCREMENT| NO       |
/// | `accountId`     | `account_id`    | BIGINT UNSIGNED NOT NULL      | NO       |
/// | `instrumentId`  | `instrument_id` | BIGINT UNSIGNED NOT NULL      | NO       |
/// | `quantity`       | `quantity`       | DECIMAL(20,6) NOT NULL        | NO       |
/// | `assetType`     | `asset_type`    | ENUM('equity') NOT NULL       | NO       |
///
/// ## Rules Compliance
///
/// - **Rule 5 (Asset Class Guard)**: `assetType` documents the equities-only restriction.
///   Validation is enforced at the service layer (``LedgerService``) and repository layer.
/// - **Rule 8 (MySQLKit-Only)**: This file imports only `Foundation` — no `SwiftData`.
/// - **Gate 2 (Swift 6 Strict Concurrency)**: All stored properties are value types
///   (`UInt64`, `Decimal`, `String`), making this struct naturally `Sendable` with
///   zero `@unchecked Sendable` annotations.
/// - **Rule 10 (Schema Referential Integrity)**: Foreign keys to `accounts` and
///   `reference_data` are enforced at the MySQL schema level.
public struct Position: Sendable, Equatable, Identifiable {

    // MARK: - Primary Key

    /// Unique identifier for this position.
    ///
    /// Maps to `positions.id` (BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY).
    public let id: UInt64

    // MARK: - Foreign Keys

    /// The account that holds this position.
    ///
    /// Maps to `positions.account_id` (BIGINT UNSIGNED NOT NULL, FK → `accounts.id`).
    /// Every position belongs to exactly one account.
    public let accountId: UInt64

    /// The instrument (security) this position represents.
    ///
    /// Maps to `positions.instrument_id` (BIGINT UNSIGNED NOT NULL, FK → `reference_data.id`).
    /// Used by ``ValuationEngine`` to look up EOD bid/ask prices from the `reference_data` table
    /// for NAV calculation: `value = quantity × (EOD_bid + EOD_ask) / 2`.
    ///
    /// This field is non-optional — every position must reference a specific instrument.
    public let instrumentId: UInt64

    // MARK: - Financial Fields

    /// Number of units or shares held in this position.
    ///
    /// Maps to `positions.quantity` (DECIMAL(20,6) NOT NULL DEFAULT 0.000000).
    /// Used in NAV calculation: `value = quantity × EOD midpoint` for this instrument.
    ///
    /// - A positive value represents a long position.
    /// - Zero represents a fully liquidated holding.
    ///
    /// - Important: This field uses `Decimal` (not `Double` or `Float`) to avoid
    ///   floating-point rounding errors that are unacceptable in accounting calculations.
    public let quantity: Decimal

    // MARK: - Asset Classification

    /// The asset class of the instrument held in this position.
    ///
    /// Maps to `positions.asset_type` (ENUM('equity') NOT NULL DEFAULT 'equity').
    /// Per Rule 5 (Asset Class Guard), the application rejects creation of any position
    /// for a non-equity instrument. Validation is enforced at the service layer
    /// (``LedgerService``) and repository layer (``PositionRepository``).
    public let assetType: String

    // MARK: - Initializer

    /// Creates a new position instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (maps to `positions.id`).
    ///   - accountId: The owning account's identifier (FK → `accounts.id`).
    ///   - instrumentId: The referenced instrument's identifier (FK → `reference_data.id`).
    ///   - quantity: Number of units/shares held. Must use `Decimal` for financial precision.
    ///   - assetType: The asset class — must be `"equity"` per Rule 5.
    public init(
        id: UInt64,
        accountId: UInt64,
        instrumentId: UInt64,
        quantity: Decimal,
        assetType: String
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.quantity = quantity
        self.assetType = assetType
    }
}
