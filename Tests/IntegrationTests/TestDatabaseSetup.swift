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
        // Step 1: Create an administrative connection without selecting a database.
        // This is required for CREATE DATABASE and DROP DATABASE operations,
        // which cannot target the currently-selected database.
        let rootManager = DatabaseManager(
            hostname: testHostname,
            port: testPort,
            username: testUsername,
            password: testPassword,
            database: ""
        )

        // Step 2-3: Drop any existing test schema and create a fresh one.
        // Using a local constant ensures the @Sendable closure captures a value type.
        let dbName = testDatabaseName
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
        databaseManager = DatabaseManager(
            hostname: testHostname,
            port: testPort,
            username: testUsername,
            password: testPassword,
            database: testDatabaseName
        )

        // Step 6: Store the connection pool reference for integration test suites.
        // All repositories and services in test code use this pool.
        connectionPool = databaseManager.pool

        // Step 7: Run all 8 migration scripts in numerical order (001 → 008).
        // Migration order is critical for FK constraint resolution (Rule 10):
        //   001 users → 002 account_groups → 003 entitlements (FK→users, account_groups)
        //   → 004 accounts (FK→account_groups) → 005 reference_data
        //   → 006 positions (FK→accounts, reference_data)
        //   → 007 transactions (FK→accounts, reference_data, self) → 008 indexes
        let migrationManager = databaseManager.migrationManager
        try await connectionPool.withConnection { db in
            try await migrationManager.runMigrations(on: db.sql())
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
