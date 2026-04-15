// Sources/Persistence/MigrationManager.swift
// WealthLedger — Ordered SQL Migration Execution
//
// Reads SQL migration files from a configurable directory (default: Resources/Migrations/),
// executes them in strict alphabetical (numerical) order against a MySQL database via SQLKit,
// and tracks applied migrations in a `_migrations` table to guarantee idempotent re-runs.
//
// Rule 8  — MySQLKit-only persistence. No SwiftData imports exist in this file.
// Rule 10 — Migrations execute in numerical order (001→008) so that FK references resolve.
// Gate 2  — Swift 6 strict concurrency: final class with let-only properties → Sendable.
//
// SPDX-License-Identifier: MIT

import Foundation
import MySQLKit
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - MigrationManager

/// Manages ordered execution of SQL migration scripts against a MySQL database.
///
/// `MigrationManager` provides the persistence layer's schema bootstrapping capability.
/// It discovers `.sql` files in a configurable directory, sorts them by filename
/// (zero-padded prefixes guarantee numerical ordering), and executes each one exactly
/// once. A lightweight `_migrations` tracking table is created automatically to record
/// which files have already been applied, making every invocation of
/// ``runMigrations(on:)`` fully idempotent.
///
/// ## Sendable Safety (Gate 2)
///
/// This type is a `final class` with exclusively `let` properties whose types
/// (`String`, `Logger`) are themselves `Sendable`. No mutable state is captured or
/// shared, and all public methods are `async throws`, executing on the caller's
/// cooperative thread pool. Zero `@unchecked Sendable` annotations are required.
///
/// ## Error Handling
///
/// Any failure during file reading or SQL execution causes the manager to throw
/// ``AppError/migrationFailed``. The failing migration's filename and underlying
/// error are logged at `.error` level before the throw, enabling quick diagnosis.
///
/// ## Expected Migration Files
///
/// The eight migration scripts that ship with WealthLedger are numbered `001` through
/// `008`. Execution order is critical because later scripts declare foreign-key
/// constraints that reference tables created by earlier scripts:
///
/// 1. `001_create_users.sql`
/// 2. `002_create_account_groups.sql`
/// 3. `003_create_entitlements.sql`   — FK → users, account_groups
/// 4. `004_create_accounts.sql`       — FK → account_groups
/// 5. `005_create_reference_data.sql`
/// 6. `006_create_positions.sql`      — FK → accounts, reference_data
/// 7. `007_create_transactions.sql`   — FK → accounts, self-reference for restatements
/// 8. `008_create_indexes.sql`        — composite indexes for search performance
public final class MigrationManager: Sendable {

    // MARK: - Properties

    /// File-system path to the directory containing `.sql` migration scripts.
    ///
    /// Defaults to `"Resources/Migrations"`, which is the standard location within the
    /// WealthLedger repository. Callers may supply a different path for integration
    /// testing or alternative deployment layouts.
    public let migrationsPath: String

    /// Structured logger used for migration lifecycle messages.
    ///
    /// Logs at `.info` for progress milestones (file discovery, skip, success) and at
    /// `.error` for failures. The default label is `"persistence.migration-manager"`.
    public let logger: Logger

    // MARK: - Initializer

    /// Creates a new migration manager.
    ///
    /// - Parameters:
    ///   - migrationsPath: Directory path containing `.sql` migration files.
    ///     Defaults to `"Resources/Migrations"`.
    ///   - logger: A `Logger` instance for structured migration logging.
    ///     Defaults to a logger labelled `"persistence.migration-manager"`.
    public init(
        migrationsPath: String = "Resources/Migrations",
        logger: Logger = Logger(label: "persistence.migration-manager")
    ) {
        self.migrationsPath = migrationsPath
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Discovers and executes all pending SQL migration scripts in numerical order.
    ///
    /// The method performs the following steps:
    /// 1. Ensures the `_migrations` tracking table exists (via `CREATE TABLE IF NOT EXISTS`).
    /// 2. Reads the migrations directory and sorts `.sql` filenames alphabetically.
    /// 3. Queries the tracking table for previously applied filenames.
    /// 4. For each unapplied file, reads its SQL content, splits it into individual
    ///    statements (delimited by `;`), executes each statement via ``SQLDatabase/raw(_:)``,
    ///    and records the filename in `_migrations`.
    /// 5. Already-applied files are silently skipped with an informational log.
    ///
    /// - Parameter database: An ``SQLDatabase`` connection (typically pool-backed) on
    ///   which migration DDL will be executed.
    /// - Throws: ``AppError/migrationFailed`` if any migration script cannot be read
    ///   or executed, or if the tracking table cannot be updated.
    public func runMigrations(on database: any SQLDatabase) async throws {
        logger.info("Starting migration run from path: \(migrationsPath)")

        // Step 1 — ensure the tracking table exists.
        try await createMigrationsTable(on: database)

        // Step 2 — discover and sort migration files.
        let sqlFiles = try discoverMigrationFiles()

        if sqlFiles.isEmpty {
            logger.info("No migration files found in \(migrationsPath)")
            return
        }

        logger.info("Discovered \(sqlFiles.count) migration file(s)")

        // Step 3 — determine which migrations have already been applied.
        let appliedFilenames = try await fetchAppliedMigrations(on: database)
        let appliedSet = Set(appliedFilenames)

        // Step 4 — execute each pending migration in order.
        var appliedCount = 0
        for filename in sqlFiles {
            if appliedSet.contains(filename) {
                logger.info("Skipping already applied migration: \(filename)")
                continue
            }

            try await executeMigration(filename: filename, on: database)
            appliedCount += 1
        }

        logger.info("Migration run complete — \(appliedCount) new migration(s) applied")
    }

    /// Returns a sorted list of filenames for all previously applied migrations.
    ///
    /// If the `_migrations` tracking table does not yet exist it is created automatically
    /// (via `CREATE TABLE IF NOT EXISTS`), and an empty array is returned.
    ///
    /// - Parameter database: An ``SQLDatabase`` connection to query.
    /// - Returns: An alphabetically sorted array of migration filenames that have been
    ///   recorded in the `_migrations` table.
    /// - Throws: ``AppError/migrationFailed`` if the tracking table cannot be queried.
    public func checkMigrationStatus(on database: any SQLDatabase) async throws -> [String] {
        try await createMigrationsTable(on: database)
        return try await fetchAppliedMigrations(on: database)
    }

    // MARK: - Private Helpers

    /// Creates the `_migrations` tracking table if it does not already exist.
    ///
    /// The table schema is intentionally minimal:
    /// - `id`         — auto-incrementing primary key (INT).
    /// - `filename`   — unique migration file name (VARCHAR 255).
    /// - `applied_at` — server-side timestamp recording when the migration was applied.
    ///
    /// Using `IF NOT EXISTS` makes every call idempotent and safe for concurrent or
    /// repeated invocations.
    private func createMigrationsTable(on database: any SQLDatabase) async throws {
        let ddl: SQLQueryString = """
            CREATE TABLE IF NOT EXISTS _migrations (
                id INT AUTO_INCREMENT PRIMARY KEY,
                filename VARCHAR(255) UNIQUE NOT NULL,
                applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        do {
            try await database.raw(ddl).run()
        } catch {
            logger.error("Failed to create _migrations tracking table: \(error)")
            throw AppError.migrationFailed
        }
    }

    /// Queries the `_migrations` table and returns all recorded filenames in sorted order.
    ///
    /// This is a private helper shared by ``runMigrations(on:)`` and
    /// ``checkMigrationStatus(on:)`` to avoid duplicating the query logic.
    private func fetchAppliedMigrations(on database: any SQLDatabase) async throws -> [String] {
        let selectQuery: SQLQueryString = "SELECT filename FROM _migrations ORDER BY filename"
        do {
            let rows = try await database.raw(selectQuery).all()
            return try rows.map { row in
                try row.decode(column: "filename", as: String.self)
            }
        } catch {
            logger.error("Failed to query applied migrations: \(error)")
            throw AppError.migrationFailed
        }
    }

    /// Discovers `.sql` files in the configured migrations directory.
    ///
    /// Files are filtered by the `.sql` extension and returned sorted alphabetically.
    /// Zero-padded numeric prefixes (e.g. `001_`, `002_`) guarantee that alphabetical
    /// ordering matches the intended execution sequence.
    ///
    /// - Returns: A sorted array of `.sql` filenames (basenames, not full paths).
    ///   Returns an empty array if the directory does not exist.
    /// - Throws: Re-throws `FileManager` errors if the directory exists but cannot
    ///   be read (permission issues, etc.).
    private func discoverMigrationFiles() throws -> [String] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: migrationsPath) else {
            logger.info("Migrations directory does not exist at path: \(migrationsPath)")
            return []
        }

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: migrationsPath)
        } catch {
            logger.error("Failed to list migrations directory at \(migrationsPath): \(error)")
            throw AppError.migrationFailed
        }

        let sqlFiles = contents
            .filter { $0.hasSuffix(".sql") }
            .sorted()

        return sqlFiles
    }

    /// Reads a single migration file, splits its SQL into individual statements, executes
    /// each statement against the database, and records the migration in the tracking table.
    ///
    /// - Parameters:
    ///   - filename: The basename of the `.sql` file (e.g. `"004_create_accounts.sql"`).
    ///   - database: An ``SQLDatabase`` connection for DDL execution.
    /// - Throws: ``AppError/migrationFailed`` on any I/O or SQL execution error.
    private func executeMigration(
        filename: String,
        on database: any SQLDatabase
    ) async throws {
        let filePath: String
        if migrationsPath.hasSuffix("/") {
            filePath = migrationsPath + filename
        } else {
            filePath = migrationsPath + "/" + filename
        }

        logger.info("Applying migration: \(filename)")

        // Read the SQL file content.
        let sqlContent: String
        do {
            sqlContent = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            logger.error("Failed to read migration file '\(filename)' at path \(filePath): \(error)")
            throw AppError.migrationFailed
        }

        // Split into individual statements and execute each one.
        let statements = splitSQLStatements(sqlContent)

        for statement in statements {
            do {
                try await database.raw(SQLQueryString(statement)).run()
            } catch {
                logger.error(
                    "Failed to execute statement in migration '\(filename)': \(error)"
                )
                throw AppError.migrationFailed
            }
        }

        // Record the migration as applied.
        do {
            let insertQuery: SQLQueryString =
                "INSERT INTO _migrations (filename) VALUES (\(bind: filename))"
            try await database.raw(insertQuery).run()
        } catch {
            logger.error("Failed to record migration '\(filename)' in tracking table: \(error)")
            throw AppError.migrationFailed
        }

        logger.info("Successfully applied migration: \(filename)")
    }

    /// Splits a block of SQL text into individual executable statements.
    ///
    /// Statements are delimited by semicolons (`;`). Leading and trailing whitespace
    /// is trimmed from each statement, and empty statements are discarded. This handles
    /// the common case of migration files that contain multiple `CREATE TABLE`, `CREATE
    /// INDEX`, or `ALTER TABLE` commands separated by semicolons.
    ///
    /// - Parameter sql: The raw SQL content read from a migration file.
    /// - Returns: An array of non-empty, trimmed SQL statements ready for execution.
    ///
    /// - Note: This splitter is intentionally simple, operating on the assumption that
    ///   migration DDL scripts do not contain semicolons within string literals or
    ///   comments that would cause incorrect splitting. This assumption holds for the
    ///   WealthLedger migration set (001–008), all of which consist exclusively of
    ///   `CREATE TABLE`, `CREATE INDEX`, and `INSERT` DDL/DML with no embedded
    ///   semicolons in data values.
    private func splitSQLStatements(_ sql: String) -> [String] {
        sql
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
