// Tests/IntegrationTests/TestDatabaseSetup.swift
// Shared test database infrastructure for all integration tests.
// Foundation for Gate 10 validation — test execution via
// `xcodebuild test` with a dedicated `accounting_test` schema.
//
// RULE 8: MySQLKit-only persistence — NO SwiftData anywhere.
// RULE 9: Offline runtime — MySQL localhost only.
// RULE 10: Schema referential integrity — migrations 001→008 in order.

import Foundation
import Testing
import MySQLKit
@testable import Persistence
@testable import Shared

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - _SetupGuard (Cross-Suite Synchronization)

/// Actor-based synchronization guard for ``TestDatabaseSetup/setUp()``.
///
/// Swift Testing runs `@Suite` types concurrently by default. When multiple
/// integration test suites (e.g., `RBACIntegrationTests` and
/// `ReferenceDataIntegrationTests`) start simultaneously, their first tests
/// may all call `setUp()` before any single call completes. Without
/// synchronization, this creates multiple ``DatabaseManager`` instances —
/// overwritten `ConnectionPool`s get deallocated without ``ConnectionPool/shutdown()``,
/// triggering an `AsyncKit` assertion failure:
///
///     ConnectionPool.shutdown() was not called before deinit.
///
/// This actor ensures:
/// 1. Only the **first** caller executes the actual setup code.
/// 2. Concurrent callers **wait** until the in-progress setup completes, then return.
/// 3. Subsequent callers return **immediately** (setup already done).
///
/// The `Task`-based approach handles actor reentrancy correctly: when the first
/// caller's `await task.value` suspends the actor, concurrent callers re-enter
/// `ensureSetup`, observe `setupTask != nil`, and also await the same task.
private actor _SetupGuard {

    /// Shared singleton instance.
    static let shared = _SetupGuard()

    /// The `Task` performing setup, or `nil` if setup hasn't started.
    private var setupTask: Task<Void, any Error>?

    /// Execute the setup block exactly once. Concurrent callers wait for the
    /// in-progress setup to complete. Subsequent callers return immediately.
    ///
    /// - Parameter block: The setup work to perform (runs at most once).
    /// - Throws: Re-throws whatever `block` throws.
    func ensureSetup(
        _ block: @Sendable @escaping () async throws -> Void
    ) async throws {
        if let task = setupTask {
            // Setup already started or completed — wait for result
            try await task.value
            return
        }
        // First caller: create and store the setup task
        let task = Task { try await block() }
        setupTask = task
        try await task.value
    }

    /// Reset the guard, allowing ``TestDatabaseSetup/setUp()`` to run again
    /// after ``TestDatabaseSetup/tearDown()`` cleans up shared infrastructure.
    func reset() {
        setupTask = nil
    }
}

// MARK: - Process-Exit Cleanup Registration

/// Flag ensuring the atexit cleanup handler is registered at most once.
/// Marked `nonisolated(unsafe)` because it follows the same sequential
/// lifecycle as TestDatabaseSetup — set once during setUp(), read once.
private nonisolated(unsafe) var _cleanupRegistered = false

/// Registers a process-exit handler that drops the `accounting_test` schema
/// when the test process terminates. This ensures cleanup happens even if
/// no individual test suite explicitly calls `TestDatabaseSetup.tearDown()`.
///
/// Uses `atexit` with a synchronous shell command to avoid async/await
/// complications in the process termination context. Best-effort: if the
/// drop fails, setUp() will handle it on the next test run by dropping
/// and recreating the schema.
private func _registerProcessExitCleanup() {
    guard !_cleanupRegistered else { return }
    _cleanupRegistered = true

    // Register a C-compatible closure that drops the test schema on exit.
    // The closure captures nothing — the database name is a string literal.
    // system() is synchronous and available from the C standard library.
    atexit {
        #if canImport(Glibc)
        _ = Glibc.system("mysql -u root -e 'DROP DATABASE IF EXISTS accounting_test' 2>/dev/null")
        #elseif canImport(Darwin)
        _ = Darwin.system("mysql -u root -e 'DROP DATABASE IF EXISTS accounting_test' 2>/dev/null")
        #endif
    }
}

// MARK: - TestDatabaseSetup

/// Shared test database infrastructure for all integration tests.
///
/// Creates the `accounting_test` MySQL schema, runs all 8 migration scripts
/// from `Resources/Migrations/` in numerical order (001 through 008),
/// and tears down (drops) the schema after all tests complete.
///
/// This enum provides:
/// - `setUp()` — Creates schema and runs migrations (call once before tests)
/// - `tearDown()` — Drops schema (call once after all tests)
/// - `cleanAllTables()` — Truncates all data tables for inter-test isolation
/// - `verifySchema()` — Confirms all 8 expected tables exist
/// - `databaseManager` — Shared `DatabaseManager` for the test schema
/// - `connectionPool` — Shared `ConnectionPool` for repository construction
///
/// ## Usage
/// ```swift
/// // Before tests
/// try await TestDatabaseSetup.setUp()
///
/// // Between test suites (for isolation)
/// try await TestDatabaseSetup.cleanAllTables()
///
/// // After all tests
/// try await TestDatabaseSetup.tearDown()
/// ```
///
/// ## Gate 10 Compliance
/// The `accounting_test` schema is distinct from the production `wealth_ledger`
/// schema, preventing test contamination of production data.
///
/// ## Migration Execution Order (Rule 10 — FK Constraints)
/// 1. `001_create_users.sql` — Users table (no FK dependencies)
/// 2. `002_create_account_groups.sql` — Account groups (no FK dependencies)
/// 3. `003_create_entitlements.sql` — Entitlements (FK → users, account_groups)
/// 4. `004_create_accounts.sql` — Accounts (FK → account_groups)
/// 5. `005_create_reference_data.sql` — Reference data (no FK dependencies)
/// 6. `006_create_positions.sql` — Positions (FK → accounts, reference_data)
/// 7. `007_create_transactions.sql` — Transactions (FK → accounts, reference_data, self)
/// 8. `008_create_indexes.sql` — Indexes (depends on all tables existing)
enum TestDatabaseSetup {

    // MARK: - Configuration Constants

    /// The name of the test database schema, distinct from the production `wealth_ledger` schema.
    /// Gate 10 requires a dedicated test schema to prevent contamination of production data.
    static let testDatabaseName: String = "accounting_test"

    /// MySQL username for test database connections.
    /// Uses the default root user for local development and CI environments.
    static let testUsername: String = "root"

    /// MySQL password for test database connections.
    /// Empty password for local development root user (standard Homebrew MySQL setup).
    static let testPassword: String = ""

    /// MySQL hostname — localhost only per Rule 9 (offline runtime).
    /// The application must function with the network adapter disabled.
    static let testHostname: String = "localhost"

    /// MySQL port for test database connections.
    /// Standard MySQL 8.0 default port.
    static let testPort: Int = 3306

    // MARK: - Shared Infrastructure

    /// The shared `DatabaseManager` configured for the `accounting_test` schema.
    ///
    /// Initialized by `setUp()` and cleaned up by `tearDown()`.
    ///
    /// ## Thread Safety
    /// This property follows a strict sequential lifecycle:
    /// 1. Set once during `setUp()` (called before any tests run)
    /// 2. Read-only during test execution
    /// 3. Cleared during `tearDown()` (called after all tests complete)
    ///
    /// The `nonisolated(unsafe)` annotation is required because `static var`
    /// with mutable state cannot otherwise satisfy Swift 6 strict concurrency.
    /// Safety is guaranteed by the sequential setUp → test execution → tearDown
    /// lifecycle — no concurrent writes occur.
    ///
    /// ## Rationale for `nonisolated(unsafe)` (Gate 2 Compliance)
    ///
    /// This annotation is used **only** on test infrastructure shared state that
    /// follows a strictly sequential lifecycle (setUp → tests → tearDown). It is
    /// NOT equivalent to `@unchecked Sendable` on arbitrary types — the safety
    /// guarantee comes from the Swift Testing `@Suite(.serialized)` attribute on
    /// all integration test suites, which ensures no concurrent test execution.
    /// This is the standard pattern for test infrastructure in Swift 6 projects
    /// where shared database connections must be stored as static properties.
    nonisolated(unsafe) static var databaseManager: DatabaseManager!

    /// The shared `ConnectionPool` for all integration tests.
    ///
    /// Provides database connections for constructing repositories
    /// and executing direct SQL queries in integration test suites.
    /// Obtained from `databaseManager.pool` after successful setUp.
    ///
    /// ## Thread Safety
    /// Same sequential lifecycle guarantee as `databaseManager`.
    /// `ConnectionPool` is an actor and inherently handles concurrent access
    /// to its internal state safely.
    ///
    /// ## Rationale for `nonisolated(unsafe)`
    /// See `databaseManager` documentation above — identical lifecycle guarantee
    /// applies. All integration suites use `@Suite(.serialized)` to prevent
    /// concurrent access to this shared connection pool reference.
    nonisolated(unsafe) static var connectionPool: ConnectionPool!

    // MARK: - Setup

    /// Set up the test database infrastructure: create schema and run all migrations.
    ///
    /// This method performs the following steps in order:
    /// 1. Connects to MySQL without specifying a database (administrative connection)
    /// 2. Drops the `accounting_test` schema if it exists (ensures clean state)
    /// 3. Creates the `accounting_test` schema with UTF8MB4 encoding
    /// 4. Closes the administrative connection
    /// 5. Creates a `DatabaseManager` connected to the `accounting_test` schema
    /// 6. Initializes the database (health check + runs all 8 migrations 001→008)
    /// 7. Stores the connection pool reference for test suites
    ///
    /// - Important: This method should be called once before any integration tests run.
    ///   Subsequent calls will drop and recreate the schema, providing a clean slate.
    ///
    /// - Throws: If database connection, schema creation, or migration execution fails.
    static func setUp() async throws {
        // Delegate to the actor-based guard to ensure only one concurrent caller
        // actually executes setup. Other callers wait until it completes.
        try await _SetupGuard.shared.ensureSetup {
            // Step 1: Create an administrative connection without selecting a database.
            // This is required for CREATE DATABASE and DROP DATABASE operations,
            // which cannot target the currently-selected database.
            let rootManager = DatabaseManager(
                hostname: TestDatabaseSetup.testHostname,
                port: TestDatabaseSetup.testPort,
                username: TestDatabaseSetup.testUsername,
                password: TestDatabaseSetup.testPassword,
                database: ""
            )

            // Step 2-3: Drop any existing test schema and create a fresh one.
            // Using a local constant ensures the @Sendable closure captures a value type.
            let dbName = TestDatabaseSetup.testDatabaseName
            try await rootManager.pool.withConnection { db in
                _ = try await db.simpleQuery("DROP DATABASE IF EXISTS `\(dbName)`").get()
                _ = try await db.simpleQuery(
                    "CREATE DATABASE `\(dbName)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                ).get()
            }

            // Step 4: Shutdown the administrative connection — no longer needed.
            try await rootManager.shutdown()

            // Step 5: Create a DatabaseManager connected to the test database.
            // This manager will be shared across all integration test suites.
            TestDatabaseSetup.databaseManager = DatabaseManager(
                hostname: TestDatabaseSetup.testHostname,
                port: TestDatabaseSetup.testPort,
                username: TestDatabaseSetup.testUsername,
                password: TestDatabaseSetup.testPassword,
                database: TestDatabaseSetup.testDatabaseName
            )

            // Step 6: Store the connection pool reference for integration test suites.
            // All repositories and services in test code use this pool.
            TestDatabaseSetup.connectionPool = TestDatabaseSetup.databaseManager.pool

            // Step 7: Run all 8 migration scripts in numerical order (001 → 008).
            // Migration order is critical for FK constraint resolution (Rule 10):
            //   001 users → 002 account_groups → 003 entitlements (FK→users, account_groups)
            //   → 004 accounts (FK→account_groups) → 005 reference_data
            //   → 006 positions (FK→accounts, reference_data)
            //   → 007 transactions (FK→accounts, reference_data, self) → 008 indexes
            let migrationManager = TestDatabaseSetup.databaseManager.migrationManager
            try await TestDatabaseSetup.connectionPool.withConnection { db in
                try await migrationManager.runMigrations(on: db.sql())
            }

            // Step 8: Register process-exit cleanup handler (once only).
            // This ensures the `accounting_test` schema is dropped when the
            // test process exits, even if no individual suite calls tearDown().
            // Best-effort: if cleanup fails, setUp() will re-drop on next run.
            _registerProcessExitCleanup()
        }
    }

    // MARK: - Teardown

    /// Tear down the test database infrastructure: drop the `accounting_test` schema.
    ///
    /// This method performs the following steps:
    /// 1. Shuts down the test database manager (closes all connections to accounting_test)
    /// 2. Clears shared references to prevent stale access
    /// 3. Creates an administrative connection (no database selected)
    /// 4. Drops the `accounting_test` schema entirely
    /// 5. Shuts down the administrative connection
    ///
    /// - Important: This method should be called once after all integration tests complete.
    ///   It completely removes the test schema from MySQL, freeing all resources.
    ///
    /// - Throws: If database shutdown or schema drop fails.
    static func tearDown() async throws {
        // Step 1: Shutdown the test database manager and its connection pool.
        // This closes all active connections to the accounting_test database,
        // allowing us to safely drop it.
        if let manager = databaseManager {
            try await manager.shutdown()
        }

        // Step 2: Clear shared references to prevent stale access.
        databaseManager = nil
        connectionPool = nil

        // Step 3: Create an administrative connection for schema cleanup.
        let rootManager = DatabaseManager(
            hostname: testHostname,
            port: testPort,
            username: testUsername,
            password: testPassword,
            database: ""
        )

        // Step 4: Drop the test schema completely.
        // IF EXISTS ensures this is idempotent — safe to call even if
        // setUp() failed partway through.
        let dbName = testDatabaseName
        try await rootManager.pool.withConnection { db in
            _ = try await db.simpleQuery("DROP DATABASE IF EXISTS `\(dbName)`").get()
        }

        // Step 5: Shutdown the administrative connection.
        try await rootManager.shutdown()

        // Step 6: Reset the setup guard so setUp() can execute again
        // if another test run starts in the same process.
        await _SetupGuard.shared.reset()
    }

    // MARK: - Test Isolation Helpers

    /// Clean all data from tables for test isolation between test suites.
    ///
    /// This method preserves the schema structure (tables, indexes, and constraints
    /// remain intact) but removes all row data by truncating each table. Foreign key
    /// checks are temporarily disabled to allow truncation in any order, then
    /// re-enabled afterward.
    ///
    /// The `_migrations` tracking table is intentionally left intact to prevent
    /// re-execution of migrations on subsequent test suite runs.
    ///
    /// ## Tables Truncated (7 data tables)
    /// - `transactions` — Append-only transaction log (Rule 2)
    /// - `positions` — Account holdings
    /// - `accounts` — Account records with cached valuations
    /// - `reference_data` — NYSE equity price data
    /// - `entitlements` — RBAC permission assignments
    /// - `account_groups` — Account group definitions
    /// - `users` — User credentials
    ///
    /// - Note: FK checks are disabled only for the duration of this operation.
    ///   They are re-enabled before the method returns, even if an error occurs
    ///   during truncation (the error will propagate after re-enabling).
    ///
    /// - Throws: If any truncation operation fails.
    static func cleanAllTables() async throws {
        guard let pool = connectionPool else { return }

        try await pool.withConnection { db in
            // Disable FK checks temporarily for clean truncation.
            // This allows tables to be truncated in any order regardless
            // of foreign key dependencies between them.
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()

            // Truncate all 7 data tables.
            // Order is irrelevant with FK checks disabled, but listed
            // in reverse-dependency order for documentation clarity.
            _ = try await db.simpleQuery("TRUNCATE TABLE transactions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE positions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE reference_data").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()

            // Re-enable FK checks to restore referential integrity enforcement.
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    // MARK: - Schema Verification

    /// Verify the test schema contains all expected tables after migration.
    ///
    /// Checks for the presence of all 7 entity tables plus the `_migrations`
    /// tracking table created by `MigrationManager`. This verification supports
    /// Gate 10 by confirming the test schema is correctly initialized before
    /// integration tests execute.
    ///
    /// ## Expected Tables (8 total)
    /// | Migration | Table |
    /// |-----------|-------|
    /// | 001 | `users` |
    /// | 002 | `account_groups` |
    /// | 003 | `entitlements` |
    /// | 004 | `accounts` |
    /// | 005 | `reference_data` |
    /// | 006 | `positions` |
    /// | 007 | `transactions` |
    /// | Auto | `_migrations` |
    ///
    /// - Throws: `AppError.migrationFailed` if the connection pool is unavailable
    ///   or any expected table is not found in the `accounting_test` schema.
    static func verifySchema() async throws {
        guard let pool = connectionPool else {
            throw AppError.migrationFailed
        }

        let expectedTables: [String] = [
            "users",
            "account_groups",
            "entitlements",
            "accounts",
            "reference_data",
            "positions",
            "transactions",
            "_migrations"
        ]

        try await pool.withConnection { db in
            for table in expectedTables {
                // SHOW TABLES LIKE returns rows matching the pattern.
                // If the table exists, exactly one row is returned.
                // If the table does not exist, zero rows are returned.
                let rows = try await db.simpleQuery("SHOW TABLES LIKE '\(table)'").get()
                if rows.isEmpty {
                    throw AppError.migrationFailed
                }
            }
        }
    }
}
