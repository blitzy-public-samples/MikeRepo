// Tests/IntegrationTests/LedgerIntegrationTests.swift
//
// Integration tests for the LedgerEngine module against a live MySQL
// `accounting_test` schema. Validates:
//   - Rule 1:  Double-entry enforcement (balanced debit/credit pairs)
//   - Rule 2:  Transaction immutability (append-only, restatement via offsetting entries)
//   - Rule 5:  Asset class guard (reject non-equity instruments)
//   - Rule 10: Schema referential integrity (FK constraints on account, instrument)
//   - Position creation on first buy and quantity accumulation on additional buys
//
// Uses Swift Testing framework (NOT XCTest) per Gate 2 strict concurrency.
// All database operations use MySQLKit via repository layer (Rule 8 — NO SwiftData).

import Testing
import Foundation
import Logging
@testable import Persistence
@testable import LedgerEngine
@testable import AccountManagement
@testable import RBAC
@testable import Shared

// MARK: - Ledger Integration Test Suite

/// Integration tests for the general ledger engine, exercising transaction posting,
/// double-entry validation, restatement creation, asset class guards, FK integrity,
/// and position management against a live MySQL `accounting_test` database.
///
/// Each test function manages its own database state through `prepareDatabase()`:
/// 1. Lazily initializes the test schema once via `TestDatabaseSetup.setUp()`
/// 2. Truncates all relevant tables for test isolation
/// 3. Creates prerequisite fixtures (user, group, entitlement, account, instrument)
///
/// The suite is serialized (`.serialized`) to prevent concurrent MySQL operations
/// from interfering across tests — each test expects clean, deterministic state.
@Suite("Ledger Integration Tests", .serialized)
struct LedgerIntegrationTests {

    // MARK: - Service Factory

    /// Constructs all services and repositories needed for ledger integration tests.
    ///
    /// Returns a named tuple providing direct access to:
    /// - `ledger`: LedgerService under test (transaction posting, restatement)
    /// - `auth`: AuthenticationService for creating test users with bcrypt passwords
    /// - `entitlement`: EntitlementService for assigning RBAC permissions
    /// - `accountGroup`: AccountGroupService for creating account groups
    /// - `account`: AccountService for creating test accounts
    /// - `transactionRepo`: Direct TransactionRepository access for verification queries
    /// - `positionRepo`: Direct PositionRepository access for position verification
    /// - `refDataRepo`: Direct ReferenceDataRepository for creating test instruments
    private func buildServices() -> (
        ledger: LedgerService,
        auth: AuthenticationService,
        entitlement: EntitlementService,
        accountGroup: AccountGroupService,
        account: AccountService,
        transactionRepo: TransactionRepository,
        positionRepo: PositionRepository,
        refDataRepo: ReferenceDataRepository
    ) {
        let pool = TestDatabaseSetup.connectionPool!
        let logger = Logger(label: "ledger-integration-tests")

        // Initialize all repositories with the shared test connection pool
        let transactionRepo = TransactionRepository(pool: pool, logger: logger)
        let positionRepo = PositionRepository(pool: pool, logger: logger)
        let accountRepo = AccountRepository(pool: pool, logger: logger)
        let accountGroupRepo = AccountGroupRepository(pool: pool, logger: logger)
        let userRepo = UserRepository(pool: pool, logger: logger)
        let entitlementRepo = EntitlementRepository(pool: pool, logger: logger)
        let refDataRepo = ReferenceDataRepository(pool: pool, logger: logger)

        // Initialize stateless value-type dependencies
        let passwordHasher = PasswordHasher()
        let doubleEntryValidator = DoubleEntryValidator()

        // Wire services with their repository and service dependencies
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )
        let ledgerService = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: doubleEntryValidator,
            entitlementService: entitlementService
        )

        return (
            ledgerService,
            authService,
            entitlementService,
            accountGroupService,
            accountService,
            transactionRepo,
            positionRepo,
            refDataRepo
        )
    }

    // MARK: - Database Preparation

    /// Ensures the test database schema exists and all tables are clean.
    ///
    /// Called at the start of every test function to guarantee:
    /// 1. The `accounting_test` schema is created with all migrations applied
    ///    (lazily initialized once to avoid leaking DatabaseManagers).
    /// 2. All ledger-related table rows are truncated for test isolation.
    ///
    /// The lazy guard (`connectionPool == nil`) prevents calling `setUp()` on
    /// every test invocation, avoiding leaked NIO EventLoopGroup threads and
    /// MySQL connections until the process deadlocks.
    private func prepareDatabase() async throws {
        if TestDatabaseSetup.connectionPool == nil {
            try await TestDatabaseSetup.setUp()
        }
        try await cleanLedgerTables()
    }

    /// Truncates all tables used by ledger integration tests.
    ///
    /// Tables cleaned (in reverse-FK dependency order):
    /// - `transactions` — FK → accounts, reference_data, self-referencing restatement
    /// - `positions`    — FK → accounts, reference_data
    /// - `accounts`     — FK → account_groups
    /// - `reference_data` — referenced by positions, transactions
    /// - `entitlements` — FK → users, account_groups
    /// - `account_groups` — referenced by accounts, entitlements
    /// - `users`        — referenced by entitlements
    ///
    /// FK checks are temporarily disabled for safe truncation regardless of order.
    private func cleanLedgerTables() async throws {
        guard let pool = TestDatabaseSetup.connectionPool else { return }
        try await pool.withConnection { db in
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE transactions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE positions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE reference_data").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    // MARK: - Test Fixture Factory

    /// Holds database-assigned IDs for all prerequisite entities created
    /// before each ledger test. Every ledger test requires: a user (for RBAC),
    /// an account group, an entitlement linking the two, an account in that
    /// group, and at least one instrument (reference data) for FK references.
    private struct TestFixtures: Sendable {
        let userId: UInt64
        let accountGroupId: UInt64
        let accountId: UInt64
        let instrumentId: UInt64
    }

    /// Creates all prerequisite entities needed before ledger operations.
    ///
    /// Setup chain:
    /// 1. Create user via AuthenticationService (bcrypt-hashed password)
    /// 2. Create account group via AccountGroupService
    /// 3. Assign entitlements (READ + CREATE, optionally MODIFY) via EntitlementService
    /// 4. Create account in the group via AccountService (requires CREATE permission)
    /// 5. Create synthetic NYSE equity instrument via ReferenceDataRepository
    ///
    /// - Parameters:
    ///   - services: The service tuple from `buildServices()`.
    ///   - username: Unique username for the test user (prevents duplicate user errors
    ///     when running multiple tests in the same schema).
    ///   - groupName: Unique group name for the test account group.
    ///   - canModify: Whether to grant MODIFY permission (needed for restatement tests).
    /// - Returns: `TestFixtures` with database-assigned IDs for all created entities.
    private func createTestFixtures(
        services: (
            ledger: LedgerService,
            auth: AuthenticationService,
            entitlement: EntitlementService,
            accountGroup: AccountGroupService,
            account: AccountService,
            transactionRepo: TransactionRepository,
            positionRepo: PositionRepository,
            refDataRepo: ReferenceDataRepository
        ),
        username: String = "ledger_test_user",
        groupName: String = "Ledger Test Group",
        canModify: Bool = false
    ) async throws -> TestFixtures {
        // Step 1: Create user with bcrypt-hashed password
        let user = try await services.auth.createUser(
            username: username,
            password: "SecureTestP@ss1"
        )

        // Step 2: Create account group
        let group = try await services.accountGroup.createGroup(
            name: groupName
        )

        // Step 3: Assign RBAC entitlements — READ and CREATE are always required;
        // MODIFY is optional (used exclusively by restatement tests)
        try await services.entitlement.assignEntitlement(
            userId: user.id,
            accountGroupId: group.id,
            canRead: true,
            canCreate: true,
            canModify: canModify,
            canDelete: false
        )

        // Step 4: Create account in the group (requires CREATE permission).
        // Use module-qualified type to avoid ambiguity with Persistence.Account.
        let account = AccountManagement.Account(
            id: 0,
            name: "Ledger Integration Test Account",
            fundType: .etf,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: nil,
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: .active,
            accountGroupId: group.id,
            createdAt: Date()
        )
        let createdAccount = try await services.account.createAccount(
            account,
            userId: user.id
        )

        // Step 5: Create a synthetic NYSE equity instrument for transaction FK.
        // Use module-qualified type to clarify source module.
        let refData = Persistence.ReferenceData(
            id: 0,
            ticker: "AAPL",
            name: "Apple Inc.",
            sodBid: Decimal(string: "148.50")!,
            sodAsk: Decimal(string: "149.00")!,
            eodBid: Decimal(string: "150.00")!,
            eodAsk: Decimal(string: "150.50")!,
            marketDate: Date()
        )
        let createdRefData = try await services.refDataRepo.create(refData)

        return TestFixtures(
            userId: user.id,
            accountGroupId: group.id,
            accountId: createdAccount.id,
            instrumentId: createdRefData.id
        )
    }

    // MARK: - Test 1: Post Balanced Transaction (Rule 1)

    /// Validates that a balanced buy transaction (debit == credit) posts successfully,
    /// creating a transaction row in the database and a corresponding position.
    ///
    /// **Rule 1** verification: When debit equals credit, the double-entry validator
    /// allows the write. The transaction is persisted with correct amounts, and a
    /// position is created for the account+instrument pair.
    @Test("Post a balanced buy transaction with debit == credit")
    func testPostBalancedTransaction() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "balanced_txn_user"
        )

        // Post a balanced transaction: debit = credit = 10000.00
        let transaction = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Verify: Transaction was created with a database-assigned ID
        #expect(transaction.id > 0, "Transaction must have a database-assigned ID > 0")

        // Verify: Amounts match the input exactly
        #expect(
            transaction.debitAmount == Decimal(string: "10000.00")!,
            "Debit amount must match input"
        )
        #expect(
            transaction.creditAmount == Decimal(string: "10000.00")!,
            "Credit amount must match input"
        )

        // Verify: Transaction references the correct account and instrument
        #expect(transaction.accountId == fixtures.accountId, "Account ID must match")
        #expect(transaction.instrumentId == fixtures.instrumentId, "Instrument ID must match")

        // Verify: Quantity and asset type are correct
        #expect(transaction.quantity == Decimal(100), "Quantity must be 100")
        #expect(transaction.assetType == "equity", "Asset type must be equity")

        // Verify: Transaction exists in the database via direct repo query
        let dbTransaction = try await services.transactionRepo.findById(transaction.id)
        #expect(dbTransaction != nil, "Transaction must exist in database after posting")
    }

    // MARK: - Test 2: Reject Unbalanced Entry (Rule 1)

    /// Validates that an unbalanced entry (debit != credit) is rejected at the
    /// application layer BEFORE any database write occurs.
    ///
    /// **Rule 1** verification: The DoubleEntryValidator must throw
    /// `AppError.unbalancedEntry` when debit != credit, and no transaction row
    /// should exist in the database afterward.
    @Test("Reject unbalanced entry — debit != credit (Rule 1)")
    func testRejectUnbalancedEntry() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "unbalanced_user"
        )

        // Record the transaction count before the attempt
        let countBefore = try await services.transactionRepo.count()

        // Attempt to post an unbalanced transaction: debit 10000, credit 5000
        var threwUnbalancedError = false
        do {
            _ = try await services.ledger.postTransaction(
                userId: fixtures.userId,
                accountId: fixtures.accountId,
                accountGroupId: fixtures.accountGroupId,
                instrumentId: fixtures.instrumentId,
                quantity: Decimal(100),
                assetType: "equity",
                ownershipPercentage: Decimal(1),
                debitAmount: Decimal(string: "10000.00")!,
                creditAmount: Decimal(string: "5000.00")!
            )
        } catch {
            // Verify the error is specifically AppError.unbalancedEntry
            if case AppError.unbalancedEntry = error {
                threwUnbalancedError = true
            }
        }

        #expect(
            threwUnbalancedError,
            "Unbalanced entry (debit != credit) must throw AppError.unbalancedEntry"
        )

        // Verify: NO transaction row was created in the database
        let countAfter = try await services.transactionRepo.count()
        #expect(
            countAfter == countBefore,
            "Transaction count must not change after rejected unbalanced entry"
        )
    }

    // MARK: - Test 3: Transaction Immutability — Append Only (Rule 2)

    /// Validates that the transactions table is append-only: no UPDATE or DELETE
    /// operations are permitted. The TransactionRepository.delete() method always
    /// throws `AppError.operationNotPermitted`.
    ///
    /// **Rule 2** verification: After posting a transaction, the row is immutable.
    /// Attempting to delete it throws an error, and re-reading confirms all fields
    /// remain unchanged.
    @Test("Transactions table is append-only — no UPDATE or DELETE (Rule 2)")
    func testTransactionAppendOnly() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "immutable_user"
        )

        // Post a valid transaction
        let transaction = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(50),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "5000.00")!,
            creditAmount: Decimal(string: "5000.00")!
        )

        // Verify: Attempting to delete the transaction throws operationNotPermitted
        var threwOperationNotPermitted = false
        do {
            try await services.transactionRepo.delete(transaction.id)
        } catch {
            if case AppError.operationNotPermitted = error {
                threwOperationNotPermitted = true
            }
        }
        #expect(
            threwOperationNotPermitted,
            "Deleting a transaction must throw AppError.operationNotPermitted (Rule 2)"
        )

        // Verify: Transaction still exists in the database — unchanged
        let dbTransaction = try await services.transactionRepo.findById(transaction.id)
        #expect(dbTransaction != nil, "Transaction must still exist after failed delete")

        if let dbTxn = dbTransaction {
            #expect(dbTxn.accountId == fixtures.accountId, "Account ID must be unchanged")
            #expect(dbTxn.quantity == Decimal(50), "Quantity must be unchanged")
            #expect(
                dbTxn.debitAmount == Decimal(string: "5000.00")!,
                "Debit amount must be unchanged"
            )
            #expect(
                dbTxn.creditAmount == Decimal(string: "5000.00")!,
                "Credit amount must be unchanged"
            )
            #expect(dbTxn.assetType == "equity", "Asset type must be unchanged")
        }
    }

    // MARK: - Test 4: Restatement via Offsetting Entry (Rule 2)

    /// Validates that restatements are performed exclusively through offsetting
    /// entries that reference the original transaction via FK — never by modifying
    /// the original row.
    ///
    /// **Rule 2** verification:
    /// - The original transaction row remains COMPLETELY unchanged after restatement
    /// - A NEW offsetting entry row is created with `restatementRefId` pointing to
    ///   the original transaction's ID
    /// - The offsetting entry's quantity is the negation of the original's quantity
    @Test("Restatement creates offsetting entry referencing original (Rule 2)")
    func testRestatementOffsettingEntry() async throws {
        try await prepareDatabase()
        let services = buildServices()
        // MODIFY permission required for restatements
        let fixtures = try await createTestFixtures(
            services: services,
            username: "restatement_user",
            canModify: true
        )

        // Post the original transaction: 100 shares at 10000.00
        let original = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Record the count before restatement
        let countBeforeRestatement = try await services.transactionRepo.count()

        // Create restatement (reversal) — balanced offsetting entry
        let restatement = try await services.ledger.createRestatement(
            userId: fixtures.userId,
            accountGroupId: fixtures.accountGroupId,
            originalTransactionId: original.id,
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Verify: Restatement must add exactly one new row (offsetting entry)
        let countAfterRestatement = try await services.transactionRepo.count()
        #expect(
            countAfterRestatement == countBeforeRestatement + 1,
            "Restatement must add exactly one new row"
        )

        // Verify: Restatement has a database-assigned ID different from original
        #expect(restatement.id > 0, "Restatement must have a database-assigned ID")
        #expect(restatement.id != original.id, "Restatement ID must differ from original")

        // Verify: Restatement references the original transaction via FK
        #expect(
            restatement.restatementRefId == original.id,
            "Restatement restatementRefId must point to original transaction ID"
        )

        // Verify: Restatement quantity is the negation of the original
        #expect(
            restatement.quantity == -original.quantity,
            "Restatement quantity must negate the original"
        )

        // Verify: Original transaction is UNCHANGED after restatement
        let originalAfter = try await services.transactionRepo.findById(original.id)
        #expect(
            originalAfter != nil,
            "Original transaction must still exist after restatement"
        )
        if let orig = originalAfter {
            #expect(orig.quantity == Decimal(100), "Original quantity must be unchanged")
            #expect(
                orig.debitAmount == Decimal(string: "10000.00")!,
                "Original debit must be unchanged"
            )
            #expect(
                orig.creditAmount == Decimal(string: "10000.00")!,
                "Original credit must be unchanged"
            )
            #expect(
                orig.restatementRefId == nil,
                "Original must have nil restatementRefId"
            )
        }

        // Verify: findRestatements returns the offsetting entry
        let restatements = try await services.transactionRepo.findRestatements(
            forTransactionId: original.id
        )
        #expect(
            restatements.count == 1,
            "There must be exactly one restatement for the original"
        )
        if let firstRestatement = restatements.first {
            #expect(
                firstRestatement.id == restatement.id,
                "Found restatement ID must match the created restatement"
            )
        }
    }

    // MARK: - Test 5: Asset Class Guard — Reject Non-Equity (Rule 5)

    /// Validates that the application layer rejects any transaction for a non-equity
    /// instrument, throwing `AppError.invalidAssetClass` before any DB write.
    ///
    /// **Rule 5** verification: The asset type must be exactly "equity"
    /// (case-insensitive). Any other value (e.g., "fixed_income") is rejected
    /// at the LedgerService layer, and no transaction or position row is created.
    @Test("Reject non-equity instrument at application layer (Rule 5)")
    func testRejectNonEquityInstrument() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "non_equity_user"
        )

        // Record counts before the attempt
        let txnCountBefore = try await services.transactionRepo.count()

        // Attempt to post a transaction with a non-equity asset type
        var threwInvalidAssetClass = false
        do {
            _ = try await services.ledger.postTransaction(
                userId: fixtures.userId,
                accountId: fixtures.accountId,
                accountGroupId: fixtures.accountGroupId,
                instrumentId: fixtures.instrumentId,
                quantity: Decimal(100),
                assetType: "fixed_income",
                ownershipPercentage: Decimal(1),
                debitAmount: Decimal(string: "10000.00")!,
                creditAmount: Decimal(string: "10000.00")!
            )
        } catch {
            if case AppError.invalidAssetClass = error {
                threwInvalidAssetClass = true
            }
        }

        #expect(
            threwInvalidAssetClass,
            "Non-equity asset type must throw AppError.invalidAssetClass (Rule 5)"
        )

        // Verify: NO transaction row was created in the database
        let txnCountAfter = try await services.transactionRepo.count()
        #expect(
            txnCountAfter == txnCountBefore,
            "Transaction count must not change after rejected non-equity instrument"
        )

        // Verify: NO position was created for the non-equity instrument
        let positions = try await services.positionRepo.findByAccountId(fixtures.accountId)
        #expect(
            positions.isEmpty,
            "No position must exist after rejected non-equity transaction"
        )
    }

    // MARK: - Test 6: FK Integrity — Transaction → Account (Rule 10)

    /// Validates that a successfully posted transaction references a valid account
    /// via FK, and that attempting to post against a non-existent account ID triggers
    /// a database error from MySQL FK constraint enforcement.
    ///
    /// **Rule 10** verification: The `transactions.account_id` FK constraint is
    /// enforced by MySQL, ensuring referential integrity between transactions
    /// and accounts.
    @Test("Transaction references valid account via FK (Rule 10)")
    func testTransactionFKToAccount() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "fk_account_user"
        )

        // Post a transaction for a valid account
        let transaction = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(50),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "5000.00")!,
            creditAmount: Decimal(string: "5000.00")!
        )

        // Verify: Transaction accountId references the correct account
        #expect(
            transaction.accountId == fixtures.accountId,
            "Transaction account_id must match the valid account FK"
        )

        // Verify: Transaction exists in the database with correct FK reference
        let dbTransaction = try await services.transactionRepo.findById(transaction.id)
        #expect(dbTransaction != nil, "Transaction must exist in database")
        if let dbTxn = dbTransaction {
            #expect(
                dbTxn.accountId == fixtures.accountId,
                "DB transaction account_id must match the account FK"
            )
        }

        // Attempt to post a transaction for a non-existent account ID.
        // MySQL FK constraint should reject this — error surfaces as a DB error.
        let nonExistentAccountId: UInt64 = 999_999
        var fkViolationOccurred = false
        do {
            _ = try await services.ledger.postTransaction(
                userId: fixtures.userId,
                accountId: nonExistentAccountId,
                accountGroupId: fixtures.accountGroupId,
                instrumentId: fixtures.instrumentId,
                quantity: Decimal(10),
                assetType: "equity",
                ownershipPercentage: Decimal(1),
                debitAmount: Decimal(string: "1000.00")!,
                creditAmount: Decimal(string: "1000.00")!
            )
        } catch {
            // Any error (FK violation or data access failure) confirms constraint
            fkViolationOccurred = true
        }

        #expect(
            fkViolationOccurred,
            "Posting transaction for non-existent account must fail (FK constraint)"
        )
    }

    // MARK: - Test 7: FK Integrity — Transaction → Instrument (Rule 10)

    /// Validates that a successfully posted transaction references a valid instrument
    /// (reference_data) via FK, confirming referential integrity between
    /// `transactions.instrument_id` and `reference_data.id`.
    ///
    /// **Rule 10** verification: The FK constraint ensures transactions can only
    /// reference existing instruments in the reference_data table.
    @Test("Transaction references valid instrument via FK (Rule 10)")
    func testTransactionFKToInstrument() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "fk_instrument_user"
        )

        // Post a transaction with a valid instrumentId from reference_data
        let transaction = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(75),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "7500.00")!,
            creditAmount: Decimal(string: "7500.00")!
        )

        // Verify: Transaction instrumentId references the correct instrument
        #expect(
            transaction.instrumentId == fixtures.instrumentId,
            "Transaction instrument_id must match the reference_data FK"
        )

        // Verify via direct repo query
        let dbTransaction = try await services.transactionRepo.findById(transaction.id)
        #expect(dbTransaction != nil, "Transaction must exist in database")
        if let dbTxn = dbTransaction {
            #expect(
                dbTxn.instrumentId == fixtures.instrumentId,
                "DB transaction instrument_id must match the reference_data FK"
            )
        }
    }

    // MARK: - Test 8: Position Created on First Buy

    /// Validates that posting the first buy transaction for an account+instrument
    /// pair creates a new position row with the correct quantity and equity asset
    /// type.
    ///
    /// The LedgerService creates a position when no existing position exists for
    /// the given account + instrument combination (Rule 5: asset_type is equity).
    @Test("Position is created when first buy transaction is posted")
    func testPositionCreatedOnBuy() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "position_create_user"
        )

        // Verify: No positions exist before the transaction
        let positionsBefore = try await services.positionRepo.findByAccountId(
            fixtures.accountId
        )
        #expect(positionsBefore.isEmpty, "No positions should exist before first buy")

        // Post a buy transaction: 100 shares
        _ = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Verify: A position row now exists for the account+instrument
        let position = try await services.positionRepo.findByAccountAndInstrument(
            accountId: fixtures.accountId,
            referenceDataId: fixtures.instrumentId
        )
        #expect(
            position != nil,
            "Position must be created after first buy transaction"
        )

        if let pos = position {
            // Verify: Position quantity matches the transaction quantity
            #expect(
                pos.quantity == Decimal(100),
                "Position quantity must equal buy quantity (100)"
            )

            // Verify: Position asset type is equity (Rule 5)
            #expect(
                pos.assetType == "equity",
                "Position asset type must be equity (Rule 5)"
            )

            // Verify: Position references the correct account and instrument
            #expect(
                pos.accountId == fixtures.accountId,
                "Position account_id must match"
            )
            #expect(
                pos.instrumentId == fixtures.instrumentId,
                "Position instrument_id must match"
            )
        }
    }

    // MARK: - Test 9: Position Updated on Additional Buy

    /// Validates that posting an additional buy transaction for an existing
    /// account+instrument position UPDATES the position quantity (accumulates)
    /// rather than creating a separate position row.
    @Test("Position quantity updated on additional buy transaction")
    func testPositionUpdatedOnAdditionalBuy() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "position_update_user"
        )

        // Post first buy: 100 shares
        _ = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Verify initial position: 100 shares
        let positionAfterFirst = try await services.positionRepo.findByAccountAndInstrument(
            accountId: fixtures.accountId,
            referenceDataId: fixtures.instrumentId
        )
        #expect(positionAfterFirst != nil, "Position must exist after first buy")
        #expect(
            positionAfterFirst?.quantity == Decimal(100),
            "Position must have 100 shares after first buy"
        )

        // Post second buy: 50 additional shares
        _ = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(50),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "5000.00")!,
            creditAmount: Decimal(string: "5000.00")!
        )

        // Verify: Position quantity is now 150 (100 + 50)
        let positionAfterSecond = try await services.positionRepo.findByAccountAndInstrument(
            accountId: fixtures.accountId,
            referenceDataId: fixtures.instrumentId
        )
        #expect(
            positionAfterSecond != nil,
            "Position must still exist after second buy"
        )
        #expect(
            positionAfterSecond?.quantity == Decimal(150),
            "Position quantity must be 150 (100 + 50) after additional buy"
        )

        // Verify: Only ONE position row exists (additional buys update, not create)
        let allPositions = try await services.positionRepo.findByAccountId(
            fixtures.accountId
        )
        #expect(
            allPositions.count == 1,
            "Only one position row should exist for same account+instrument"
        )
    }

    // MARK: - Test 10: Multiple Transactions for Same Account

    /// Validates that multiple transactions posted to the same account are tracked
    /// as independent rows, each with correct FK references, amounts, and quantities.
    @Test("Multiple transactions for same account tracked independently")
    func testMultipleTransactionsPerAccount() async throws {
        try await prepareDatabase()
        let services = buildServices()
        let fixtures = try await createTestFixtures(
            services: services,
            username: "multi_txn_user"
        )

        // Create a second instrument for variety
        let refData2 = Persistence.ReferenceData(
            id: 0,
            ticker: "MSFT",
            name: "Microsoft Corp.",
            sodBid: Decimal(string: "380.00")!,
            sodAsk: Decimal(string: "380.50")!,
            eodBid: Decimal(string: "382.00")!,
            eodAsk: Decimal(string: "382.50")!,
            marketDate: Date()
        )
        let instrument2 = try await services.refDataRepo.create(refData2)

        // Post first transaction: 100 shares of AAPL
        let txn1 = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(100),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "10000.00")!,
            creditAmount: Decimal(string: "10000.00")!
        )

        // Post second transaction: 200 shares of MSFT
        let txn2 = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: instrument2.id,
            quantity: Decimal(200),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "20000.00")!,
            creditAmount: Decimal(string: "20000.00")!
        )

        // Post third transaction: 50 more shares of AAPL
        let txn3 = try await services.ledger.postTransaction(
            userId: fixtures.userId,
            accountId: fixtures.accountId,
            accountGroupId: fixtures.accountGroupId,
            instrumentId: fixtures.instrumentId,
            quantity: Decimal(50),
            assetType: "equity",
            ownershipPercentage: Decimal(1),
            debitAmount: Decimal(string: "5000.00")!,
            creditAmount: Decimal(string: "5000.00")!
        )

        // Verify: Three separate transaction rows exist with unique IDs
        #expect(txn1.id != txn2.id, "Transaction 1 and 2 must have different IDs")
        #expect(txn2.id != txn3.id, "Transaction 2 and 3 must have different IDs")
        #expect(txn1.id != txn3.id, "Transaction 1 and 3 must have different IDs")

        // Verify: All transactions reference the correct account
        #expect(txn1.accountId == fixtures.accountId, "Txn 1 account_id must match")
        #expect(txn2.accountId == fixtures.accountId, "Txn 2 account_id must match")
        #expect(txn3.accountId == fixtures.accountId, "Txn 3 account_id must match")

        // Verify: Each transaction has its own correct amounts
        #expect(
            txn1.debitAmount == Decimal(string: "10000.00")!,
            "Txn 1 debit must be 10000"
        )
        #expect(
            txn2.debitAmount == Decimal(string: "20000.00")!,
            "Txn 2 debit must be 20000"
        )
        #expect(
            txn3.debitAmount == Decimal(string: "5000.00")!,
            "Txn 3 debit must be 5000"
        )

        // Verify: Total transaction count for this account is 3
        let accountTxnCount = try await services.transactionRepo.countByAccountId(
            fixtures.accountId
        )
        #expect(
            accountTxnCount == 3,
            "Account must have exactly 3 transactions"
        )

        // Verify: Transactions are retrievable via LedgerService with READ permission
        let transactions = try await services.ledger.getTransactions(
            userId: fixtures.userId,
            accountGroupId: fixtures.accountGroupId,
            accountId: fixtures.accountId
        )
        #expect(
            transactions.count == 3,
            "getTransactions must return all 3 transactions for the account"
        )
    }
}
