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
/// Conforms to ``Error`` (for Swift error-handling semantics), ``Sendable``
/// (for Swift 6 strict concurrency safety), and ``Equatable`` (for assertion
/// ergonomics in tests). All associated values are `Sendable` and `Equatable`
/// value types, so conformance synthesis is safe with no `@unchecked` annotations.
public enum AppError: Error, Sendable, Equatable {

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

    // MARK: - Entity Lookups (Transactions)

    /// Transaction lookup failure.
    ///
    /// Thrown when a requested transaction identifier does not correspond to any
    /// existing record in the database. Used by restatement operations that must
    /// reference an existing original transaction via foreign key.
    ///
    /// Consumers: ``TransactionRepository``, ``LedgerService``.
    case transactionNotFound

    // MARK: - Repository Operations

    /// Operation not permitted on this repository.
    ///
    /// Thrown when a repository method is invoked that the specific repository
    /// does not support. For example, a read-only repository (such as
    /// ``TransactionRepository``, which is append-only per Rule 2) may throw
    /// this error for delete operations.
    ///
    /// This error is also the recommended default for protocol-required methods
    /// that a conforming repository intentionally does not implement.
    ///
    /// Consumers: ``RepositoryProtocol`` conformances, ``TransactionRepository``.
    case operationNotPermitted

    // MARK: - Data Access

    /// Generic data-access failure.
    ///
    /// Thrown when a database query succeeds at the protocol level but the
    /// result cannot be mapped to the expected domain model — for example,
    /// when a required column is missing from a result row, when
    /// `LAST_INSERT_ID()` returns an unexpected value, or when a type
    /// conversion fails during row mapping.
    ///
    /// The associated `String` carries a human-readable description of
    /// the failure context for diagnostic logging.
    ///
    /// Consumers: All repository classes in the Persistence module.
    case dataAccessFailed(String)

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
