// Sources/Shared/Errors/AppError.swift
// WealthLedger — Typed Domain-Specific Error Hierarchy
//
// SPDX-License-Identifier: MIT

import Foundation

/// Typed error hierarchy for all domain-specific error handling across WealthLedger.
///
/// Each case maps to a specific business rule or validation constraint defined in the
/// application requirements. This enum is the single source of truth for categorised
/// errors thrown by every business-logic module: AccountManagement, LedgerEngine,
/// ValuationEngine, RBAC, Persistence, JobScheduler, and ReferenceDataService.
///
/// Conforms to both ``Error`` (for Swift error-handling semantics) and ``Sendable``
/// (for Swift 6 strict concurrency safety). Because every case is a simple enum value
/// with no associated storage, `Sendable` conformance is trivially safe — no
/// `@unchecked Sendable` annotations are required.
public enum AppError: Error, Sendable {

    // MARK: - Ledger Rules

    /// Rule 1 — Double-entry enforcement failure.
    ///
    /// Thrown when a set of debit/credit pairs does not sum to zero.
    /// Every ledger write must produce balanced pairs; unbalanced entries are
    /// rejected at the application layer **before** any database write occurs.
    ///
    /// Consumers: ``DoubleEntryValidator``, ``LedgerService``.
    case unbalancedEntry

    // MARK: - Access Control

    /// Rule 4 — Entitlement enforcement failure.
    ///
    /// Thrown when a user lacks the required entitlement
    /// (READ / CREATE / MODIFY / DELETE) for the requested operation on an
    /// account group.
    ///
    /// **Important:** For *read* operations the system returns an empty result
    /// set rather than throwing this error, in accordance with Rule 4. This case
    /// is reserved for *write* operations where explicit permission is mandatory.
    ///
    /// Consumers: ``EntitlementService``, ``AccountService``, ``LedgerService``,
    /// and UI-layer screens.
    case unauthorizedAccess

    // MARK: - Asset Validation

    /// Rule 5 — Asset-class guard failure.
    ///
    /// Thrown when an attempt is made to create a position or transaction for a
    /// non-equity instrument. Only equities are supported; all other asset
    /// classes are rejected at the application layer with zero database writes.
    ///
    /// Consumers: ``LedgerService``, ``PositionRepository``.
    case invalidAssetClass

    // MARK: - Entity Lookups

    /// Account lookup failure.
    ///
    /// Thrown when a requested account identifier does not correspond to any
    /// existing record in the database.
    ///
    /// Consumers: ``AccountService``, ``ValuationService``, ``LedgerService``.
    case accountNotFound

    // MARK: - User Management

    /// Duplicate-user creation failure.
    ///
    /// Thrown when an attempt is made to create a user with a username that
    /// already exists in the system.
    ///
    /// Consumers: ``AuthenticationService``.
    case duplicateUser

    // MARK: - Timezone Validation

    /// Rule 3 — Invalid IANA timezone string.
    ///
    /// Thrown when an account supplies a timezone identifier that cannot be
    /// resolved to a valid ``TimeZone`` instance. The ``ValuationEngine``
    /// requires each account to store a valid IANA timezone for value-date
    /// computation; an invalid string prevents valuation from proceeding.
    ///
    /// Consumers: ``ValuationService``, ``AccountService``.
    case invalidTimezone

    // MARK: - Persistence Infrastructure

    /// Database migration failure.
    ///
    /// Thrown when a SQL migration script cannot be applied to the database.
    /// This typically indicates a DDL error, a constraint conflict, or a
    /// connectivity issue during schema bootstrapping.
    ///
    /// Consumers: ``MigrationManager``.
    case migrationFailed
}
