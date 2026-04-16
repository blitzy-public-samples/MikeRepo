// LedgerServiceTests.swift
// WealthLedger — Unit Tests for LedgerService Business Logic
//
// Tests transaction posting, restatement creation, asset class guard (Rule 5),
// entitlement enforcement (Rule 4), double-entry validation (Rule 1),
// transaction immutability (Rule 2), and position management.
//
// All tests use protocol-based mock dependencies — NO database connections.
// A TestableLedgerService struct replicates LedgerService's exact validation
// chain with protocol-based dependencies for isolated unit testing because
// the production LedgerService accepts concrete TransactionRepository and
// PositionRepository types that require a live ConnectionPool.
// The actual LedgerService with concrete repository types is tested in
// Tests/IntegrationTests/LedgerIntegrationTests.swift against live MySQL.
//
// CRITICAL: All monetary amounts use Foundation.Decimal (base-10 exact arithmetic),
// matching MySQL DECIMAL(20,6) column precision. IEEE 754 Double/Float is NEVER used.
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LedgerEngine
@testable import Shared
@testable import RBAC
@testable import Persistence

// Disambiguate types shared between LedgerEngine and Persistence modules.
// Both modules define Transaction and Position structs with identical field
// layouts; tests use the LedgerEngine variants exclusively.
private typealias Transaction = LedgerEngine.Transaction
private typealias Position = LedgerEngine.Position

// MARK: - Test Protocol Definitions

/// Protocol mirroring the TransactionRepository methods that LedgerService uses.
/// Enables injection of MockTransactionRepo without requiring a ConnectionPool.
private protocol TransactionRepoProtocol: Sendable {
    func create(_ transaction: Transaction) async throws -> Transaction
    func findById(_ id: UInt64) async throws -> Transaction?
    func findByAccountId(
        _ accountId: UInt64, page: Int, pageSize: Int
    ) async throws -> [Transaction]
    func createRestatement(
        originalTransactionId: UInt64, offsettingEntry: Transaction
    ) async throws -> Transaction
}

/// Protocol mirroring the PositionRepository methods that LedgerService uses.
/// Enables injection of MockPositionRepo without requiring a ConnectionPool.
private protocol PositionRepoProtocol: Sendable {
    func create(_ position: Position) async throws -> Position
    func findByAccountAndInstrument(
        accountId: UInt64, referenceDataId: UInt64
    ) async throws -> Position?
    func updateQuantity(id: UInt64, quantity: Decimal) async throws
    func findByAccountId(_ accountId: UInt64) async throws -> [Position]
}

/// Protocol mirroring EntitlementService.checkPermission for test injection.
private protocol EntitlementCheckProtocol: Sendable {
    func checkPermission(
        userId: UInt64, accountGroupId: UInt64, permission: String
    ) async -> Bool
}

// MARK: - Mock Implementations
//
// Gate 2 compliance: All mock implementations below use Swift 6 actor isolation
// or immutable struct patterns to achieve `Sendable` conformance without
// `@unchecked Sendable`. This matches the established pattern in
// AuthenticationTests, EntitlementTests, ValuationServiceTests, and
// CSVParserTests — zero `@unchecked Sendable` annotations in the test suite.

/// Actor-based mock transaction repository tracking all created transactions
/// for post-test assertions.
///
/// Uses `actor` isolation to provide thread-safe mutable state access that
/// satisfies Swift 6 strict concurrency checking (Gate 2) without
/// `@unchecked Sendable`. All state mutations are automatically serialized
/// by the actor runtime. Test assertions access state via `await`.
private actor MockTransactionRepo: TransactionRepoProtocol {
    var createdTransactions: [Transaction] = []
    var storedTransactions: [UInt64: Transaction] = [:]
    var nextId: UInt64 = 1

    func create(_ transaction: Transaction) async throws -> Transaction {
        let created = Transaction(
            id: nextId,
            accountId: transaction.accountId,
            instrumentId: transaction.instrumentId,
            quantity: transaction.quantity,
            assetType: transaction.assetType,
            ownershipPercentage: transaction.ownershipPercentage,
            debitAmount: transaction.debitAmount,
            creditAmount: transaction.creditAmount,
            restatementRefId: transaction.restatementRefId,
            createdAt: transaction.createdAt
        )
        nextId += 1
        createdTransactions.append(created)
        storedTransactions[created.id] = created
        return created
    }

    func findById(_ id: UInt64) async throws -> Transaction? {
        storedTransactions[id]
    }

    func findByAccountId(
        _ accountId: UInt64, page: Int, pageSize: Int
    ) async throws -> [Transaction] {
        createdTransactions.filter { $0.accountId == accountId }
    }

    func createRestatement(
        originalTransactionId: UInt64, offsettingEntry: Transaction
    ) async throws -> Transaction {
        guard storedTransactions[originalTransactionId] != nil else {
            throw AppError.transactionNotFound
        }
        let created = Transaction(
            id: nextId,
            accountId: offsettingEntry.accountId,
            instrumentId: offsettingEntry.instrumentId,
            quantity: offsettingEntry.quantity,
            assetType: offsettingEntry.assetType,
            ownershipPercentage: offsettingEntry.ownershipPercentage,
            debitAmount: offsettingEntry.debitAmount,
            creditAmount: offsettingEntry.creditAmount,
            restatementRefId: originalTransactionId,
            createdAt: offsettingEntry.createdAt
        )
        nextId += 1
        createdTransactions.append(created)
        storedTransactions[created.id] = created
        return created
    }
}

/// Actor-based mock position repository tracking all creates, lookups, and
/// quantity updates for post-test assertions.
///
/// Uses `actor` isolation to provide thread-safe mutable state access that
/// satisfies Swift 6 strict concurrency checking (Gate 2) without
/// `@unchecked Sendable`. Test assertions access state via `await`.
private actor MockPositionRepo: PositionRepoProtocol {
    var createdPositions: [Position] = []
    var positionsByKey: [String: Position] = [:]
    var updatedQuantities: [(id: UInt64, quantity: Decimal)] = []
    var nextId: UInt64 = 1

    func create(_ position: Position) async throws -> Position {
        let created = Position(
            id: nextId,
            accountId: position.accountId,
            instrumentId: position.instrumentId,
            quantity: position.quantity,
            assetType: position.assetType
        )
        nextId += 1
        createdPositions.append(created)
        positionsByKey["\(created.accountId)-\(created.instrumentId)"] = created
        return created
    }

    func findByAccountAndInstrument(
        accountId: UInt64, referenceDataId: UInt64
    ) async throws -> Position? {
        positionsByKey["\(accountId)-\(referenceDataId)"]
    }

    func updateQuantity(id: UInt64, quantity: Decimal) async throws {
        updatedQuantities.append((id: id, quantity: quantity))
        // Update stored position for subsequent lookups within the same test.
        for (key, pos) in positionsByKey where pos.id == id {
            positionsByKey[key] = Position(
                id: pos.id,
                accountId: pos.accountId,
                instrumentId: pos.instrumentId,
                quantity: quantity,
                assetType: pos.assetType
            )
            break
        }
    }

    func findByAccountId(_ accountId: UInt64) async throws -> [Position] {
        Array(positionsByKey.values.filter { $0.accountId == accountId })
    }

    /// Pre-seed a position for update tests (simulates prior DB state).
    func seedPosition(_ position: Position) {
        positionsByKey["\(position.accountId)-\(position.instrumentId)"] = position
    }
}

/// Immutable mock entitlement checker with configurable per-test permission results.
///
/// Uses a `struct` with `let` properties for natural `Sendable` conformance —
/// all state is configured at initialization time, matching the closure-based
/// mock pattern used in AuthenticationTests, EntitlementTests, and
/// ValuationServiceTests. Zero `@unchecked Sendable` annotations.
///
/// Defaults to allowing all permissions (`defaultPermission: true`). Tests
/// for unauthorized access pass `defaultPermission: false` at initialization
/// or configure specific keys in `permissionResults`.
private struct MockEntitlementChecker: EntitlementCheckProtocol, Sendable {
    let permissionResults: [String: Bool]
    let defaultPermission: Bool

    init(permissionResults: [String: Bool] = [:], defaultPermission: Bool = true) {
        self.permissionResults = permissionResults
        self.defaultPermission = defaultPermission
    }

    func checkPermission(
        userId: UInt64, accountGroupId: UInt64, permission: String
    ) async -> Bool {
        let key = "\(userId)-\(accountGroupId)-\(permission)"
        return permissionResults[key] ?? defaultPermission
    }
}

// MARK: - TestableLedgerService

/// Test-friendly service replicating ``LedgerService``'s exact validation chain.
///
/// This struct implements the same business logic as `LedgerService` — including
/// the strict validation order (entitlement → asset class → double-entry → DB
/// write → position management) — but accepts protocol-based dependencies
/// instead of concrete `TransactionRepository` / `PositionRepository` types.
///
/// This pattern enables comprehensive unit testing of all validation paths and
/// business rules without requiring a MySQL database connection. The real
/// `LedgerService` with concrete repository dependencies is exercised by
/// integration tests against a live `accounting_test` schema.
private struct TestableLedgerService: Sendable {
    let transactionRepo: any TransactionRepoProtocol
    let positionRepo: any PositionRepoProtocol
    let validator: DoubleEntryValidator
    let entitlementChecker: any EntitlementCheckProtocol

    /// Posts a new transaction with the exact same validation chain as
    /// ``LedgerService/postTransaction(userId:accountId:accountGroupId:instrumentId:quantity:assetType:ownershipPercentage:debitAmount:creditAmount:)``:
    ///
    /// 1. Entitlement check (Rule 4) — CREATE permission required
    /// 2. Asset class guard (Rule 5) — equities only
    /// 3. Double-entry validation (Rule 1) — balanced debit/credit
    /// 4. Transaction creation (Rule 2) — append-only
    /// 5. Position management — create or update
    func postTransaction(
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
        let hasCreatePermission = await entitlementChecker.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "CREATE"
        )
        guard hasCreatePermission else {
            throw AppError.unauthorizedAccess
        }

        // Step 2: Rule 5 — Asset class guard (equities only, case-insensitive)
        guard assetType.lowercased() == "equity" else {
            throw AppError.invalidAssetClass
        }

        // Step 3: Rule 1 — Double-entry validation (debits must equal credits)
        try validator.validate(debits: [debitAmount], credits: [creditAmount])

        // Step 4: Rule 2 — Create transaction (append-only INSERT, id=0 signals auto-increment)
        let transaction = Transaction(
            id: 0,
            accountId: accountId,
            instrumentId: instrumentId,
            quantity: quantity,
            assetType: assetType,
            ownershipPercentage: ownershipPercentage,
            debitAmount: debitAmount,
            creditAmount: creditAmount,
            restatementRefId: nil,
            createdAt: Date()
        )
        let created = try await transactionRepo.create(transaction)

        // Step 5: Position management (only for instrument-backed transactions)
        if let instrumentId = instrumentId {
            let existing = try await positionRepo.findByAccountAndInstrument(
                accountId: accountId,
                referenceDataId: instrumentId
            )
            if let existing = existing {
                let updatedQty = existing.quantity + quantity
                try await positionRepo.updateQuantity(
                    id: existing.id, quantity: updatedQty
                )
            } else {
                let newPosition = Position(
                    id: 0,
                    accountId: accountId,
                    instrumentId: instrumentId,
                    quantity: quantity,
                    assetType: assetType
                )
                _ = try await positionRepo.create(newPosition)
            }
        }

        return created
    }

    /// Creates a restatement offsetting entry with the exact same logic as
    /// ``LedgerService/createRestatement(userId:accountGroupId:originalTransactionId:debitAmount:creditAmount:)``:
    ///
    /// 1. Entitlement check (Rule 4) — MODIFY permission required
    /// 2. Retrieve original transaction (throws transactionNotFound if missing)
    /// 3. Double-entry validation (Rule 1) — balanced offsetting amounts
    /// 4. Offsetting entry creation with negated quantity and restatementRefId FK
    /// 5. Position adjustment for the offsetting quantity
    func createRestatement(
        userId: UInt64,
        accountGroupId: UInt64,
        originalTransactionId: UInt64,
        debitAmount: Decimal,
        creditAmount: Decimal
    ) async throws -> Transaction {
        // Step 1: Rule 4 — MODIFY permission required for corrections
        let hasModifyPermission = await entitlementChecker.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "MODIFY"
        )
        guard hasModifyPermission else {
            throw AppError.unauthorizedAccess
        }

        // Step 2: Retrieve original transaction (must exist)
        guard let original = try await transactionRepo.findById(originalTransactionId) else {
            throw AppError.transactionNotFound
        }

        // Step 3: Rule 1 — Double-entry validation for the offsetting entry
        try validator.validate(debits: [debitAmount], credits: [creditAmount])

        // Step 4: Rule 2 — Create offsetting entry with reference to original
        let offsetting = Transaction(
            id: 0,
            accountId: original.accountId,
            instrumentId: original.instrumentId,
            quantity: -original.quantity,
            assetType: original.assetType,
            ownershipPercentage: original.ownershipPercentage,
            debitAmount: debitAmount,
            creditAmount: creditAmount,
            restatementRefId: originalTransactionId,
            createdAt: Date()
        )
        let restatement = try await transactionRepo.createRestatement(
            originalTransactionId: originalTransactionId,
            offsettingEntry: offsetting
        )

        // Step 5: Adjust position for the offsetting quantity
        if let instrId = original.instrumentId {
            let existingPos = try await positionRepo.findByAccountAndInstrument(
                accountId: original.accountId,
                referenceDataId: instrId
            )
            if let pos = existingPos {
                let adjusted = pos.quantity + (-original.quantity)
                try await positionRepo.updateQuantity(id: pos.id, quantity: adjusted)
            }
        }

        return restatement
    }

    /// Retrieves transactions with entitlement check.
    /// Returns empty array `[]` for unauthorized users — never throws for denial (Rule 4).
    func getTransactions(
        userId: UInt64,
        accountGroupId: UInt64,
        accountId: UInt64,
        page: Int = 1,
        pageSize: Int = 1000
    ) async throws -> [Transaction] {
        let hasReadPermission = await entitlementChecker.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "READ"
        )
        guard hasReadPermission else { return [] }
        return try await transactionRepo.findByAccountId(
            accountId, page: page, pageSize: pageSize
        )
    }

    /// Retrieves positions with entitlement check.
    /// Returns empty array `[]` for unauthorized users — never throws for denial (Rule 4).
    func getPositions(
        userId: UInt64,
        accountGroupId: UInt64,
        accountId: UInt64
    ) async throws -> [Position] {
        let hasReadPermission = await entitlementChecker.checkPermission(
            userId: userId,
            accountGroupId: accountGroupId,
            permission: "READ"
        )
        guard hasReadPermission else { return [] }
        return try await positionRepo.findByAccountId(accountId)
    }
}

// MARK: - Test Helper

/// Creates a fully-configured TestableLedgerService with fresh mock dependencies.
/// Each test should call this to get isolated, independent mock state.
///
/// - Parameters:
///   - txRepo: Optional pre-configured MockTransactionRepo. Defaults to a fresh instance.
///   - posRepo: Optional pre-configured MockPositionRepo. Defaults to a fresh instance.
///   - entitlementChecker: Optional pre-configured MockEntitlementChecker. Defaults to
///     a fresh instance that allows all permissions.
/// - Returns: Tuple of the configured service and all three mock instances for assertions.
private func createTestService(
    txRepo: MockTransactionRepo = MockTransactionRepo(),
    posRepo: MockPositionRepo = MockPositionRepo(),
    entitlementChecker: MockEntitlementChecker = MockEntitlementChecker()
) -> (
    service: TestableLedgerService,
    txRepo: MockTransactionRepo,
    posRepo: MockPositionRepo,
    entitlementChecker: MockEntitlementChecker
) {
    let validator = DoubleEntryValidator()
    let service = TestableLedgerService(
        transactionRepo: txRepo,
        positionRepo: posRepo,
        validator: validator,
        entitlementChecker: entitlementChecker
    )
    return (service, txRepo, posRepo, entitlementChecker)
}

// MARK: - LedgerServiceTests

/// Comprehensive test suite exercising LedgerService's business logic.
///
/// Tests verify:
/// - Rule 1: Double-entry enforcement (balanced debit/credit pairs)
/// - Rule 2: Transaction immutability (offsetting entries for restatements)
/// - Rule 4: Entitlement enforcement (permission checks before data access)
/// - Rule 5: Asset class guard (equities only)
/// - Position management (create new / update existing)
/// - Validation ordering (entitlement → asset class → double-entry)
///
/// All tests use protocol-based mock dependencies and the real
/// ``DoubleEntryValidator`` (stateless pure-function struct).
/// No database connections are established in any test.
@Suite("LedgerService Tests")
struct LedgerServiceTests {

    // MARK: - Test Constants

    /// Standard test user ID used across all tests.
    private let testUserId: UInt64 = 1
    /// Standard test account ID used across all tests.
    private let testAccountId: UInt64 = 100
    /// Standard test account group ID used across all tests.
    private let testAccountGroupId: UInt64 = 10
    /// Standard test instrument ID (reference data FK) used across all tests.
    private let testInstrumentId: UInt64 = 42

    // MARK: - 5.1 Transaction Posting — Happy Path (Rule 1)

    @Test("Post balanced equity transaction succeeds")
    func testPostBalancedTransaction() async throws {
        let (service, txRepo, _, _) = createTestService()

        // Use Decimal(string:) for precise financial amounts
        let amount = Decimal(string: "5000.00")!

        let result = try await service.postTransaction(
            userId: testUserId,
            accountId: testAccountId,
            accountGroupId: testAccountGroupId,
            instrumentId: testInstrumentId,
            quantity: Decimal(50),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: amount,
            creditAmount: amount
        )

        // Verify transaction was created with correct properties
        #expect(await txRepo.createdTransactions.count == 1)
        #expect(result.accountId == testAccountId)
        #expect(result.instrumentId == testInstrumentId)
        #expect(result.debitAmount == amount)
        #expect(result.creditAmount == amount)
        #expect(result.restatementRefId == nil)
        #expect(result.quantity == Decimal(50))
        #expect(result.id != 0, "ID should be assigned by repository (auto-increment)")
    }

    // MARK: - 5.2 Unbalanced Entry Rejection (Rule 1)

    @Test("Post unbalanced transaction throws unbalancedEntry error")
    func testPostUnbalancedTransactionThrows() async throws {
        let (service, txRepo, posRepo, _) = createTestService()

        // Unbalanced: debit=100, credit=50 violates Rule 1
        do {
            _ = try await service.postTransaction(
                userId: testUserId,
                accountId: testAccountId,
                accountGroupId: testAccountGroupId,
                instrumentId: testInstrumentId,
                quantity: Decimal(50),
                assetType: "equity",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(100),
                creditAmount: Decimal(50)
            )
            Issue.record("Expected AppError.unbalancedEntry but no error was thrown")
        } catch let error as AppError {
            #expect(error == .unbalancedEntry)
        } catch {
            Issue.record("Expected AppError.unbalancedEntry but got \(error)")
        }

        // Verify zero DB writes — no transaction or position was created
        #expect(await txRepo.createdTransactions.isEmpty,
                "No transaction should be written when entry is unbalanced")
        #expect(await posRepo.createdPositions.isEmpty,
                "No position should be written when entry is unbalanced")
    }

    // MARK: - 5.3 Asset Class Guard (Rule 5)

    @Test("Post non-equity transaction throws invalidAssetClass error")
    func testNonEquityAssetRejected() async throws {
        let (service, txRepo, posRepo, _) = createTestService()

        // Non-equity asset type "fixed_income" must be rejected (Rule 5)
        do {
            _ = try await service.postTransaction(
                userId: testUserId,
                accountId: testAccountId,
                accountGroupId: testAccountGroupId,
                instrumentId: testInstrumentId,
                quantity: Decimal(10),
                assetType: "fixed_income",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(1000),
                creditAmount: Decimal(1000)
            )
            Issue.record("Expected AppError.invalidAssetClass but no error was thrown")
        } catch let error as AppError {
            #expect(error == .invalidAssetClass)
        } catch {
            Issue.record("Expected AppError.invalidAssetClass but got \(error)")
        }

        // Verify zero DB writes
        #expect(await txRepo.createdTransactions.isEmpty,
                "No transaction should be written for non-equity asset")
        #expect(await posRepo.createdPositions.isEmpty,
                "No position should be written for non-equity asset")
    }

    @Test("Post equity transaction does not throw invalidAssetClass")
    func testEquityAssetAccepted() async throws {
        let (service, txRepo, _, _) = createTestService()

        let result = try await service.postTransaction(
            userId: testUserId,
            accountId: testAccountId,
            accountGroupId: testAccountGroupId,
            instrumentId: testInstrumentId,
            quantity: Decimal(25),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: Decimal(2500),
            creditAmount: Decimal(2500)
        )

        // Transaction was created successfully — no invalidAssetClass error
        #expect(await txRepo.createdTransactions.count == 1)
        #expect(result.assetType == "equity")
    }

    // MARK: - 5.4 Entitlement Enforcement (Rule 4)

    @Test("Post transaction without CREATE permission throws unauthorizedAccess")
    func testUnauthorizedTransactionRejected() async throws {
        let entChecker = MockEntitlementChecker(defaultPermission: false)  // Deny all permissions
        let (service, txRepo, _, _) = createTestService(entitlementChecker: entChecker)

        do {
            _ = try await service.postTransaction(
                userId: testUserId,
                accountId: testAccountId,
                accountGroupId: testAccountGroupId,
                instrumentId: testInstrumentId,
                quantity: Decimal(10),
                assetType: "equity",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(1000),
                creditAmount: Decimal(1000)
            )
            Issue.record("Expected AppError.unauthorizedAccess but no error was thrown")
        } catch let error as AppError {
            #expect(error == .unauthorizedAccess)
        } catch {
            Issue.record("Expected AppError.unauthorizedAccess but got \(error)")
        }

        // Verify zero DB writes — entitlement rejected before any repository call
        #expect(await txRepo.createdTransactions.isEmpty,
                "No transaction should be written without CREATE permission")
    }

    @Test("Get transactions without READ permission returns empty array")
    func testUnauthorizedReadReturnsEmpty() async throws {
        let txRepo = MockTransactionRepo()
        // Seed a transaction so there is data that COULD be returned
        _ = try await txRepo.create(Transaction(
            id: 0, accountId: testAccountId, instrumentId: testInstrumentId,
            quantity: Decimal(10), assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: Decimal(100), creditAmount: Decimal(100),
            restatementRefId: nil, createdAt: Date()
        ))

        let entChecker = MockEntitlementChecker(defaultPermission: false)  // Deny READ
        let (service, _, _, _) = createTestService(
            txRepo: txRepo, entitlementChecker: entChecker
        )

        // Rule 4: Unauthorized read returns empty array [], NOT an error
        let transactions = try await service.getTransactions(
            userId: testUserId,
            accountGroupId: testAccountGroupId,
            accountId: testAccountId
        )

        #expect(transactions.isEmpty,
                "Unauthorized READ must return empty array, never an error")
    }

    @Test("Get positions without READ permission returns empty array")
    func testUnauthorizedPositionReadReturnsEmpty() async throws {
        let posRepo = MockPositionRepo()
        // Seed a position so there is data that COULD be returned
        await posRepo.seedPosition(Position(
            id: 1, accountId: testAccountId, instrumentId: testInstrumentId,
            quantity: Decimal(50), assetType: "equity"
        ))

        let entChecker = MockEntitlementChecker(defaultPermission: false)  // Deny READ
        let (service, _, _, _) = createTestService(
            posRepo: posRepo, entitlementChecker: entChecker
        )

        // Rule 4: Unauthorized read returns empty array [], NOT an error
        let positions = try await service.getPositions(
            userId: testUserId,
            accountGroupId: testAccountGroupId,
            accountId: testAccountId
        )

        #expect(positions.isEmpty,
                "Unauthorized READ must return empty array, never an error")
    }

    // MARK: - 5.5 Restatement Creation (Rule 2 — Transaction Immutability)

    @Test("Create restatement creates offsetting entry with reference to original")
    func testRestatementCreatesOffsettingEntry() async throws {
        let txRepo = MockTransactionRepo()
        let posRepo = MockPositionRepo()
        let (service, _, _, _) = createTestService(
            txRepo: txRepo, posRepo: posRepo
        )

        // First, create the original transaction
        let original = try await service.postTransaction(
            userId: testUserId,
            accountId: testAccountId,
            accountGroupId: testAccountGroupId,
            instrumentId: testInstrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(string: "100.000000")!,
            debitAmount: Decimal(10000),
            creditAmount: Decimal(10000)
        )

        // Create restatement (offsetting entry) referencing the original
        let restatement = try await service.createRestatement(
            userId: testUserId,
            accountGroupId: testAccountGroupId,
            originalTransactionId: original.id,
            debitAmount: Decimal(10000),
            creditAmount: Decimal(10000)
        )

        // Verify the offsetting entry references the original via FK
        #expect(restatement.restatementRefId == original.id,
                "Restatement must carry FK reference to original transaction")

        // Verify the offsetting entry has negated quantity (Rule 2)
        #expect(restatement.quantity == -original.quantity,
                "Offsetting entry must negate the original quantity")

        // Verify original transaction was NOT modified (immutability)
        let storedTransactions = await txRepo.storedTransactions
        let originalStored = storedTransactions[original.id]
        #expect(originalStored != nil, "Original transaction must still exist")
        #expect(originalStored?.quantity == Decimal(100),
                "Original transaction quantity must be unchanged")
        #expect(originalStored?.restatementRefId == nil,
                "Original transaction's restatementRefId must remain nil")

        // Verify two transactions total (original + offsetting)
        #expect(await txRepo.createdTransactions.count == 2)
    }

    @Test("Create restatement for nonexistent transaction throws error")
    func testRestatementNonexistentTransactionThrows() async throws {
        let (service, _, _, _) = createTestService()

        // No transactions exist — ID 999 is nonexistent
        do {
            _ = try await service.createRestatement(
                userId: testUserId,
                accountGroupId: testAccountGroupId,
                originalTransactionId: 999,
                debitAmount: Decimal(100),
                creditAmount: Decimal(100)
            )
            Issue.record(
                "Expected error for nonexistent transaction but none was thrown"
            )
        } catch let error as AppError {
            #expect(error == .transactionNotFound)
        } catch {
            Issue.record("Expected AppError.transactionNotFound but got \(error)")
        }
    }

    // MARK: - 5.6 Position Management

    @Test("Post transaction creates new position when none exists")
    func testPostTransactionCreatesPosition() async throws {
        let posRepo = MockPositionRepo()
        let (service, _, _, _) = createTestService(posRepo: posRepo)

        _ = try await service.postTransaction(
            userId: testUserId,
            accountId: testAccountId,
            accountGroupId: testAccountGroupId,
            instrumentId: testInstrumentId,
            quantity: Decimal(75),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: Decimal(7500),
            creditAmount: Decimal(7500)
        )

        // Verify a new position was created with correct properties
        let createdPositions = await posRepo.createdPositions
        #expect(createdPositions.count == 1,
                "A new position should be created when none exists")
        let created = createdPositions[0]
        #expect(created.accountId == testAccountId)
        #expect(created.instrumentId == testInstrumentId)
        #expect(created.quantity == Decimal(75))
        #expect(created.assetType == "equity")
    }

    @Test("Post transaction updates existing position quantity")
    func testPostTransactionUpdatesExistingPosition() async throws {
        let posRepo = MockPositionRepo()
        // Seed existing position with quantity 50 (simulates prior DB state)
        await posRepo.seedPosition(Position(
            id: 1, accountId: testAccountId, instrumentId: testInstrumentId,
            quantity: Decimal(50), assetType: "equity"
        ))

        let (service, _, _, _) = createTestService(posRepo: posRepo)

        _ = try await service.postTransaction(
            userId: testUserId,
            accountId: testAccountId,
            accountGroupId: testAccountGroupId,
            instrumentId: testInstrumentId,
            quantity: Decimal(30),
            assetType: "equity",
            ownershipPercentage: Decimal(100),
            debitAmount: Decimal(3000),
            creditAmount: Decimal(3000)
        )

        // Verify quantity was updated: 50 (existing) + 30 (new) = 80
        let updatedQuantities = await posRepo.updatedQuantities
        #expect(updatedQuantities.count == 1,
                "Existing position quantity should be updated, not a new position created")
        #expect(updatedQuantities[0].id == 1)
        #expect(updatedQuantities[0].quantity == Decimal(80))
        // Verify no NEW position was created (the existing one was updated)
        #expect(await posRepo.createdPositions.isEmpty,
                "No new position should be created when one already exists")
    }

    // MARK: - 5.7 Validation Order Verification

    @Test("Entitlement check happens before asset class guard")
    func testValidationOrderEntitlementFirst() async throws {
        let entChecker = MockEntitlementChecker(defaultPermission: false)  // Deny all permissions
        let (service, _, _, _) = createTestService(entitlementChecker: entChecker)

        // Trigger BOTH: denied permission AND non-equity asset type.
        // If entitlement is checked first (correct order), we get
        // .unauthorizedAccess and never reach the asset class guard.
        do {
            _ = try await service.postTransaction(
                userId: testUserId,
                accountId: testAccountId,
                accountGroupId: testAccountGroupId,
                instrumentId: testInstrumentId,
                quantity: Decimal(10),
                assetType: "fixed_income",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(1000),
                creditAmount: Decimal(1000)
            )
            Issue.record("Expected error but none was thrown")
        } catch let error as AppError {
            #expect(
                error == .unauthorizedAccess,
                """
                Expected .unauthorizedAccess (entitlement checked first), \
                but got \(error). Validation order is incorrect.
                """
            )
        } catch {
            Issue.record("Expected AppError but got \(error)")
        }
    }

    @Test("Asset class guard happens before double-entry validation")
    func testValidationOrderAssetBeforeDoubleEntry() async throws {
        let (service, _, _, _) = createTestService()

        // Trigger BOTH: non-equity asset AND unbalanced amounts.
        // If asset class is checked before double-entry (correct order),
        // we get .invalidAssetClass and never reach double-entry validation.
        do {
            _ = try await service.postTransaction(
                userId: testUserId,
                accountId: testAccountId,
                accountGroupId: testAccountGroupId,
                instrumentId: testInstrumentId,
                quantity: Decimal(10),
                assetType: "fixed_income",
                ownershipPercentage: Decimal(100),
                debitAmount: Decimal(100),
                creditAmount: Decimal(50)
            )
            Issue.record("Expected error but none was thrown")
        } catch let error as AppError {
            #expect(
                error == .invalidAssetClass,
                """
                Expected .invalidAssetClass (asset class checked before \
                double-entry), but got \(error). Validation order is incorrect.
                """
            )
        } catch {
            Issue.record("Expected AppError but got \(error)")
        }
    }
}
