// LedgerService.swift
// WealthLedger - LedgerEngine Module
//
// Primary service class orchestrating general ledger transaction posting,
// restatement creation, and position management for the double-entry
// accounting system. This is the central business logic coordinator for the
// LedgerEngine module.
//
// Rules Enforced:
//   Rule 1 (Double-Entry Enforcement): DoubleEntryValidator.validate() is
//          called BEFORE every transaction write to ensure balanced entries.
//   Rule 2 (Transaction Immutability): ZERO UPDATE/DELETE on transactions.
//          Only transactionRepository.create() (INSERT) is used. Restatements
//          create NEW offsetting entries referencing the original via FK.
//   Rule 4 (Entitlement Enforcement): entitlementService.checkPermission() is
//          called before every operation. Write ops throw unauthorizedAccess;
//          read ops return empty arrays for unauthorized users.
//   Rule 5 (Asset Class Guard): assetType validated as "equity" before any
//          DB write in postTransaction(). Non-equity rejected immediately.
//   Rule 7 (Batch Memory Cap): Pagination at AppConstants.defaultPagination
//          (1,000) records per page for getTransactions().
//   Rule 8 (MySQLKit-Only): No SwiftData anywhere. DB access via repositories.
//
// Swift 6 Strict Concurrency (Gate 2):
//   This class is `final` with only immutable `let` properties of `Sendable`-
//   conforming types. Conforms to `Sendable` without `@unchecked` annotations.
//   Zero warning suppressions.
//
// Type Conversion Note:
//   Both the LedgerEngine module and the Persistence module define public
//   `Transaction` and `Position` structs with near-identical structure. This
//   duplication exists to avoid a circular dependency (Persistence defines
//   them for repository use; LedgerEngine defines them for service consumers).
//   Conversion between the two is performed via private helper methods,
//   following the same pattern used by EntitlementService for the Entitlement
//   type.
//
// SPDX-License-Identifier: MIT

import Foundation
import Persistence
import RBAC
import Shared

// MARK: - LedgerService

/// Primary service for the general ledger accounting engine.
///
/// `LedgerService` is the central orchestrator for all ledger operations:
/// posting new transactions with double-entry validation, creating restatement
/// offsetting entries (never modifying originals), and retrieving transaction
/// history and positions with entitlement enforcement.
///
/// ## Dependency Injection
///
/// All four dependencies are injected via the initializer and registered by
/// `DependencyContainer` during application startup. No global state, no
/// singletons.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// This class is `final` with only immutable `let` properties of `Sendable`-
/// conforming types:
/// - `TransactionRepository` conforms to `Sendable` via `RepositoryProtocol`
/// - `PositionRepository` conforms to `Sendable` via `RepositoryProtocol`
/// - `DoubleEntryValidator` is a `Sendable` struct (stateless, zero properties)
/// - `EntitlementService` is a `Sendable` final class
///
/// ## Cross-Module Consumers
///
/// - **DependencyContainer** — registers this service with all 4 dependencies
/// - **AccountsViewerView** — displays transaction history and positions
/// - **LedgerServiceTests** — unit tests
/// - **LedgerIntegrationTests** — integration tests against live MySQL
/// - **EndToEndWorkflowTests** — Gate 1 end-to-end verification
public final class LedgerService: Sendable {

    // MARK: - Properties

    /// Append-only transaction persistence layer.
    ///
    /// Provides `create(_:)` (the ONLY write operation), `findById(_:)`,
    /// `findByAccountId(_:page:pageSize:)`, and
    /// `createRestatement(originalTransactionId:offsettingEntry:)`.
    /// Per Rule 2, this repository has NO update or delete methods for the
    /// transactions table.
    private let transactionRepository: TransactionRepository

    /// Position CRUD persistence layer with FK enforcement.
    ///
    /// Provides `create(_:)`, `findByAccountAndInstrument(accountId:referenceDataId:)`,
    /// `updateQuantity(id:quantity:)`, and `findByAccountId(_:)`.
    /// Used for creating new positions and adjusting existing position quantities
    /// when transactions are posted or restated.
    private let positionRepository: PositionRepository

    /// Pure double-entry validation enforcing Rule 1.
    ///
    /// `validate(debits:credits:)` is called BEFORE every transaction write to
    /// ensure balanced debit/credit pairs summing to zero. Throws
    /// `AppError.unbalancedEntry` for unbalanced entries, preventing any DB write.
    private let doubleEntryValidator: DoubleEntryValidator

    /// Cross-cutting entitlement enforcement enforcing Rule 4.
    ///
    /// `checkPermission(userId:accountGroupId:permission:)` is called before
    /// every operation. For write operations (CREATE, MODIFY), unauthorized
    /// access throws `AppError.unauthorizedAccess`. For read operations (READ),
    /// unauthorized access returns empty arrays (never throws).
    private let entitlementService: EntitlementService

    // MARK: - Initializer

    /// Creates a new `LedgerService` with all required dependencies.
    ///
    /// All four dependencies are injected by `DependencyContainer` during
    /// application startup. No global state or singleton patterns are used.
    ///
    /// - Parameters:
    ///   - transactionRepository: Append-only transaction persistence (Rule 2).
    ///   - positionRepository: Position CRUD with FK enforcement.
    ///   - doubleEntryValidator: Double-entry balance validation (Rule 1).
    ///   - entitlementService: Permission verification (Rule 4).
    public init(
        transactionRepository: TransactionRepository,
        positionRepository: PositionRepository,
        doubleEntryValidator: DoubleEntryValidator,
        entitlementService: EntitlementService
    ) {
        self.transactionRepository = transactionRepository
        self.positionRepository = positionRepository
        self.doubleEntryValidator = doubleEntryValidator
        self.entitlementService = entitlementService
    }

    // MARK: - Transaction Posting (Rule 1, 2, 4, 5)

    /// Posts a new transaction to the general ledger with full rule enforcement.
    ///
    /// Execution order (STRICT — each step gates the next):
    /// 1. **Entitlement check** (Rule 4) — verifies CREATE permission
    /// 2. **Asset class guard** (Rule 5) — rejects non-equity instruments
    /// 3. **Double-entry validation** (Rule 1) — ensures balanced debit/credit
    /// 4. **Transaction creation** (Rule 2) — append-only INSERT via repository
    /// 5. **Position management** — creates or updates instrument position
    ///
    /// - Parameters:
    ///   - userId: The authenticated user performing the operation.
    ///   - accountId: The target account for this transaction.
    ///   - accountGroupId: The account group for entitlement verification.
    ///   - instrumentId: The instrument (security) FK, or `nil` for cash-only.
    ///   - quantity: Number of units/shares. Uses `Decimal` for precision.
    ///   - assetType: Must be `"equity"` (case-insensitive). Rule 5 rejects all others.
    ///   - ownershipPercentage: Ownership percentage for this entry.
    ///   - debitAmount: Debit component. Must equal `creditAmount` (Rule 1).
    ///   - creditAmount: Credit component. Must equal `debitAmount` (Rule 1).
    /// - Returns: The created transaction with database-assigned ID.
    /// - Throws:
    ///   - `AppError.unauthorizedAccess` if the user lacks CREATE permission (Rule 4).
    ///   - `AppError.invalidAssetClass` if `assetType` is not `"equity"` (Rule 5).
    ///   - `AppError.unbalancedEntry` if `debitAmount != creditAmount` (Rule 1).
    ///   - Database constraint or connection errors from the persistence layer.
    public func postTransaction(
        userId: UInt64,
        accountId: UInt64,
        accountGroupId: UInt64,
        instrumentId: UInt64?,
        quantity: Decimal,
        assetType: String,
        ownershipPercentage: Decimal,
        debitAmount: Decimal,
        creditAmount: Decimal
    ) async throws -> Transaction {

        // Step 1: Rule 4 — Entitlement check (CREATE permission required)
        // All write operations enforce entitlement checks before any DB interaction.
        let hasCreatePermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "CREATE"
        )
        guard hasCreatePermission else {
            throw AppError.unauthorizedAccess
        }

        // Step 2: Rule 5 — Asset class guard (equities only)
        // Reject any non-equity instrument BEFORE double-entry validation
        // and BEFORE any DB write. Case-insensitive comparison.
        guard assetType.lowercased() == "equity" else {
            throw AppError.invalidAssetClass
        }

        // Step 3: Rule 1 — Double-entry validation (must balance)
        // DoubleEntryValidator throws AppError.unbalancedEntry if
        // sum(debits) != sum(credits). Called BEFORE any DB write.
        try doubleEntryValidator.validate(
            debits: [debitAmount],
            credits: [creditAmount]
        )

        // Step 4: Rule 2 — Create transaction (append-only INSERT)
        // Construct a Persistence.Transaction for the repository. The id field
        // is 0 (placeholder) — the database assigns the actual ID via
        // AUTO_INCREMENT. restatementRefId is nil — this is an original entry.
        let persistenceTransaction = Persistence.Transaction(
            id: 0,
            accountId: accountId,
            instrumentId: instrumentId,
            quantity: quantity,
            assetType: assetType,
            ownershipPercentage: ownershipPercentage,
            debitAmount: debitAmount,
            creditAmount: creditAmount,
            description: nil,
            restatementRefId: nil,
            createdAt: Date()
        )
        let createdPersistenceTransaction = try await transactionRepository.create(
            persistenceTransaction
        )

        // Step 5: Create or update position (only for instrument-backed transactions)
        // Cash-only transactions (instrumentId == nil) do not affect positions.
        if let instrumentId = instrumentId {
            let existingPosition = try await positionRepository.findByAccountAndInstrument(
                accountId: accountId,
                referenceDataId: instrumentId
            )
            if let existing = existingPosition {
                // Position exists — add transaction quantity to existing quantity
                let updatedQuantity = existing.quantity + quantity
                try await positionRepository.updateQuantity(
                    id: existing.id,
                    quantity: updatedQuantity
                )
            } else {
                // No position exists — create a new one
                let newPosition = Persistence.Position(
                    id: 0,
                    accountId: accountId,
                    instrumentId: instrumentId,
                    quantity: quantity,
                    assetType: assetType
                )
                _ = try await positionRepository.create(newPosition)
            }
        }

        // Step 6: Convert Persistence.Transaction → LedgerEngine.Transaction
        return convertFromPersistenceTransaction(createdPersistenceTransaction)
    }

    // MARK: - Restatement Creation (Rule 1, 2, 4)

    /// Creates an offsetting restatement entry that corrects an original transaction.
    ///
    /// **CRITICAL Rule 2**: The original transaction is NEVER modified. A new
    /// offsetting entry is created that references the original via
    /// `restatementRefId` foreign key. The offsetting entry's quantity is the
    /// negation of the original's quantity to reverse the original position impact.
    ///
    /// Execution order:
    /// 1. **Entitlement check** (Rule 4) — verifies MODIFY permission
    /// 2. **Original retrieval** — fetches original transaction for properties
    /// 3. **Double-entry validation** (Rule 1) — ensures offsetting entry balances
    /// 4. **Offsetting entry creation** (Rule 2) — new INSERT with restatementRefId
    /// 5. **Position adjustment** — adjusts position quantity for the reversal
    ///
    /// - Parameters:
    ///   - userId: The authenticated user performing the restatement.
    ///   - accountGroupId: The account group for entitlement verification.
    ///   - originalTransactionId: The PK of the transaction to correct.
    ///   - debitAmount: Corrective debit amount. Must equal `creditAmount` (Rule 1).
    ///   - creditAmount: Corrective credit amount. Must equal `debitAmount` (Rule 1).
    /// - Returns: The created offsetting transaction with database-assigned ID.
    /// - Throws:
    ///   - `AppError.unauthorizedAccess` if the user lacks MODIFY permission (Rule 4).
    ///   - `AppError.transactionNotFound` if the original transaction does not exist.
    ///   - `AppError.unbalancedEntry` if `debitAmount != creditAmount` (Rule 1).
    ///   - Database constraint or connection errors from the persistence layer.
    public func createRestatement(
        userId: UInt64,
        accountGroupId: UInt64,
        originalTransactionId: UInt64,
        debitAmount: Decimal,
        creditAmount: Decimal
    ) async throws -> Transaction {

        // Step 1: Rule 4 — Entitlement check (MODIFY permission required)
        // Restatements require MODIFY permission on the account group.
        let hasModifyPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "MODIFY"
        )
        guard hasModifyPermission else {
            throw AppError.unauthorizedAccess
        }

        // Step 2: Retrieve the original transaction
        // We need its properties (accountId, instrumentId, quantity, assetType,
        // ownershipPercentage) to construct the offsetting entry.
        guard let originalPersistence = try await transactionRepository.findById(
            originalTransactionId
        ) else {
            throw AppError.transactionNotFound
        }

        // Step 3: Rule 1 — Double-entry validation for the offsetting entry
        try doubleEntryValidator.validate(
            debits: [debitAmount],
            credits: [creditAmount]
        )

        // Step 4: Rule 2 — Create offsetting entry (NEVER modify original)
        // The offsetting entry references the original via restatementRefId FK.
        // The quantity is negated to reverse the original position impact.
        let offsettingEntry = Persistence.Transaction(
            id: 0,
            accountId: originalPersistence.accountId,
            instrumentId: originalPersistence.instrumentId,
            quantity: -originalPersistence.quantity,
            assetType: originalPersistence.assetType,
            ownershipPercentage: originalPersistence.ownershipPercentage,
            debitAmount: debitAmount,
            creditAmount: creditAmount,
            description: nil,
            restatementRefId: originalTransactionId,
            createdAt: Date()
        )
        let restatementPersistence = try await transactionRepository.createRestatement(
            originalTransactionId: originalTransactionId,
            offsettingEntry: offsettingEntry
        )

        // Step 5: Adjust position quantity to reflect the reversal
        // Only applicable for instrument-backed transactions.
        if let instrumentId = originalPersistence.instrumentId {
            let existingPosition = try await positionRepository.findByAccountAndInstrument(
                accountId: originalPersistence.accountId,
                referenceDataId: instrumentId
            )
            if let position = existingPosition {
                // Subtract the original quantity (add the negated quantity)
                let adjustedQuantity = position.quantity + (-originalPersistence.quantity)
                try await positionRepository.updateQuantity(
                    id: position.id,
                    quantity: adjustedQuantity
                )
            }
        }

        // Step 6: Convert Persistence.Transaction → LedgerEngine.Transaction
        return convertFromPersistenceTransaction(restatementPersistence)
    }

    // MARK: - Transaction Retrieval (Rule 4, Rule 7)

    /// Retrieves paginated transaction history for an account with entitlement checks.
    ///
    /// **Rule 4**: Returns an empty array `[]` for unauthorized READ access —
    /// never throws for permission denial. This ensures users without READ
    /// entitlement receive zero records, not an error.
    ///
    /// **Rule 7**: Pagination defaults to `AppConstants.defaultPagination` (1,000)
    /// records per page to enforce the batch memory cap.
    ///
    /// - Parameters:
    ///   - userId: The authenticated user requesting transaction history.
    ///   - accountGroupId: The account group for entitlement verification.
    ///   - accountId: The account whose transactions to retrieve.
    ///   - page: 1-based page number. Defaults to `1`.
    ///   - pageSize: Records per page. Defaults to `AppConstants.defaultPagination` (1,000).
    /// - Returns: Paginated transaction history, or empty array if unauthorized.
    /// - Throws: Database connection or query execution errors (never for
    ///   authorization failures — those return `[]`).
    public func getTransactions(
        userId: UInt64,
        accountGroupId: UInt64,
        accountId: UInt64,
        page: Int = 1,
        pageSize: Int = AppConstants.defaultPagination
    ) async throws -> [Transaction] {

        // Rule 4: Entitlement check — unauthorized reads return empty, never throw
        let hasReadPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "READ"
        )
        guard hasReadPermission else {
            return []
        }

        // Retrieve paginated transactions from repository
        let persistenceTransactions = try await transactionRepository.findByAccountId(
            accountId,
            page: page,
            pageSize: pageSize
        )

        // Convert Persistence.Transaction array → LedgerEngine.Transaction array
        return persistenceTransactions.map { convertFromPersistenceTransaction($0) }
    }

    // MARK: - Position Retrieval (Rule 4)

    /// Retrieves all positions for an account with entitlement checks.
    ///
    /// **Rule 4**: Returns an empty array `[]` for unauthorized READ access —
    /// never throws for permission denial. This ensures users without READ
    /// entitlement receive zero records, not an error.
    ///
    /// - Parameters:
    ///   - userId: The authenticated user requesting positions.
    ///   - accountGroupId: The account group for entitlement verification.
    ///   - accountId: The account whose positions to retrieve.
    /// - Returns: All positions for the account, or empty array if unauthorized.
    /// - Throws: Database connection or query execution errors (never for
    ///   authorization failures — those return `[]`).
    public func getPositions(
        userId: UInt64,
        accountGroupId: UInt64,
        accountId: UInt64
    ) async throws -> [Position] {

        // Rule 4: Entitlement check — unauthorized reads return empty, never throw
        let hasReadPermission = await entitlementService.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "READ"
        )
        guard hasReadPermission else {
            return []
        }

        // Retrieve all positions for the account from repository
        let persistencePositions = try await positionRepository.findByAccountId(accountId)

        // Convert Persistence.Position array → LedgerEngine.Position array
        return persistencePositions.map { convertFromPersistencePosition($0) }
    }

    // MARK: - Private Type Conversion Helpers

    /// Converts a `Persistence.Transaction` to a `LedgerEngine.Transaction`.
    ///
    /// The Persistence module defines its own `Transaction` struct to avoid a
    /// circular dependency (Persistence → LedgerEngine → Persistence). This
    /// helper maps all common properties, dropping the `description` field
    /// which exists only in the Persistence variant.
    ///
    /// - Parameter persistenceTransaction: The Persistence module's transaction.
    /// - Returns: The equivalent LedgerEngine module transaction.
    private func convertFromPersistenceTransaction(
        _ persistenceTransaction: Persistence.Transaction
    ) -> Transaction {
        Transaction(
            id: persistenceTransaction.id,
            accountId: persistenceTransaction.accountId,
            instrumentId: persistenceTransaction.instrumentId,
            quantity: persistenceTransaction.quantity,
            assetType: persistenceTransaction.assetType,
            ownershipPercentage: persistenceTransaction.ownershipPercentage,
            debitAmount: persistenceTransaction.debitAmount,
            creditAmount: persistenceTransaction.creditAmount,
            restatementRefId: persistenceTransaction.restatementRefId,
            createdAt: persistenceTransaction.createdAt
        )
    }

    /// Converts a `Persistence.Position` to a `LedgerEngine.Position`.
    ///
    /// The Persistence module defines its own `Position` struct to avoid a
    /// circular dependency. Both types have identical properties, so conversion
    /// is a straightforward property-by-property mapping.
    ///
    /// - Parameter persistencePosition: The Persistence module's position.
    /// - Returns: The equivalent LedgerEngine module position.
    private func convertFromPersistencePosition(
        _ persistencePosition: Persistence.Position
    ) -> Position {
        Position(
            id: persistencePosition.id,
            accountId: persistencePosition.accountId,
            instrumentId: persistencePosition.instrumentId,
            quantity: persistencePosition.quantity,
            assetType: persistencePosition.assetType
        )
    }
}
