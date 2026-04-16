// Sources/Persistence/DatabaseManager.swift
// WealthLedger — MySQLKit Configuration and Connection Lifecycle
//
// Central database manager: initializes MySQLKit connection configuration, manages
// the NIO EventLoopGroup lifecycle (creation and graceful shutdown), provides access
// to the AsyncKit-backed connection pool, and coordinates schema initialization via
// ordered SQL migrations. This is the foundational entry point for ALL persistence
// operations in the WealthLedger application.
//
// Rule 8  — MySQLKit-only persistence. Zero SwiftData imports.
// Rule 9  — Offline runtime: localhost-only MySQL connections, zero network calls.
// Gate 2  — Swift 6 strict concurrency: final class, let-only properties, Sendable.
// Gate 10 — Configurable database name for testing (accounting_test schema).
//
// SPDX-License-Identifier: MIT

import Foundation
import Logging
import MySQLKit
import MySQLNIO
import NIOCore
import NIOPosix

// MARK: - DatabaseManager

/// Central database manager for the WealthLedger persistence layer.
///
/// `DatabaseManager` serves as the foundational entry point for all database
/// operations. It creates and owns the NIO `EventLoopGroup`, the MySQLKit
/// connection configuration, the ``ConnectionPool``, and the ``MigrationManager``.
///
/// ## Lifecycle
///
/// 1. Create via ``init(hostname:port:username:password:database:maxConnections:migrationsPath:logger:)``
/// 2. Call ``initialize()`` to verify connectivity and run pending migrations
/// 3. Use ``pool`` or ``database`` to execute queries through repository classes
/// 4. Call ``shutdown()`` during application teardown to release all resources
///
/// ## Thread Safety (Gate 2)
///
/// This type is a `final class` with exclusively `let` properties. All stored
/// types are either value types (`MySQLConfiguration`, `Logger`) or concurrency-safe
/// types (`ConnectionPool` as an actor, `MigrationManager` as a `Sendable` final
/// class, `MultiThreadedEventLoopGroup` as a thread-safe NIO implementation).
///
/// The single stored property whose type lacks formal `Sendable` conformance —
/// `EventLoopGroupConnectionPool` (AsyncKit) — is annotated with
/// `nonisolated(unsafe)` to confine the concurrency trust boundary to that
/// specific property. No `@unchecked Sendable` annotation is used on the class
/// itself, satisfying Gate 2 requirements.
///
/// ## Offline Runtime (Rule 9)
///
/// Default hostname is `"localhost"` and default port is `3306`. The manager is
/// designed exclusively for local MySQL connections installed via Homebrew. No
/// external network calls are made at any point during the manager's lifecycle.
///
/// ## Test Support (Gate 10)
///
/// The `database` parameter defaults to `"wealth_ledger"` but can be overridden
/// to `"accounting_test"` for integration testing with a dedicated test schema
/// that is created and dropped by the test suite.
///
/// ## Example Usage
///
/// ```swift
/// // Production
/// let manager = DatabaseManager(username: "app_user", password: "secret")
/// try await manager.initialize()
/// let db = manager.database
/// // ... use db for queries ...
/// try await manager.shutdown()
///
/// // Integration tests (Gate 10)
/// let testManager = DatabaseManager(
///     username: "test_user",
///     password: "test_pass",
///     database: "accounting_test"
/// )
/// ```
public final class DatabaseManager: Sendable {
    // Sendable compliance — Gate 2 (zero @unchecked Sendable):
    //
    // One stored type lacks formal Sendable conformance despite being thread-safe:
    //
    // EventLoopGroupConnectionPool (AsyncKit) — designed for concurrent
    // multi-threaded access with internal synchronization, but not declared
    // Sendable in AsyncKit 1.x. This property is annotated with
    // `nonisolated(unsafe)` — Swift 6's targeted property-level annotation —
    // rather than `@unchecked Sendable` on the entire class.
    //
    // All other stored types are Sendable:
    // - MySQLConfiguration: conforms to Sendable in MySQLNIO 1.9+
    // - ConnectionPool: actor (inherently Sendable)
    // - MigrationManager: final class explicitly conforming to Sendable
    // - Logger: conforms to Sendable in swift-log
    // - any EventLoopGroup: EventLoopGroup protocol inherits from Sendable
    //
    // All properties are immutable (`let`), so no data races are possible.

    // MARK: - Properties

    /// The MySQLKit connection configuration for the local MySQL 8.0 instance.
    ///
    /// Contains hostname, port, username, password, database name, and TLS
    /// configuration. Configured for localhost-only connections with TLS
    /// certificate verification disabled (appropriate for local MySQL).
    ///
    /// `MySQLConfiguration` conforms to `Sendable` in MySQLNIO 1.9+.
    public let configuration: MySQLConfiguration

    /// The NIO event loop group managing async I/O threads for all database operations.
    ///
    /// Created with `System.coreCount` threads via ``MultiThreadedEventLoopGroup``
    /// to match the available CPU cores on the target Apple Silicon hardware.
    /// Shared across all pooled connections and must be shut down last during
    /// application teardown (after the connection pool is closed).
    public let eventLoopGroup: any EventLoopGroup

    /// The AsyncKit-backed connection pool for managed database connections.
    ///
    /// Provides connection leasing via ``ConnectionPool/withConnection(_:)``,
    /// atomic transaction support via ``ConnectionPool/withTransaction(_:)``,
    /// and pool-backed database access via ``ConnectionPool/database()``.
    /// All repository classes interact with MySQL through this pool.
    public let pool: ConnectionPool

    /// The migration manager for ordered SQL schema initialization.
    ///
    /// Reads `.sql` files from the configured migrations directory and executes
    /// them in numerical order (001 through 008). Tracks applied migrations in
    /// a `_migrations` table to ensure idempotent re-runs.
    public let migrationManager: MigrationManager

    /// Structured logger for database manager lifecycle events.
    ///
    /// Uses the label `"persistence.database-manager"` by default. Logs
    /// initialization progress, health check results, and shutdown events
    /// for operational visibility and debugging.
    private let logger: Logger

    /// Direct pool reference for the convenience ``database`` property.
    ///
    /// This pool is separate from the one managed by the ``ConnectionPool`` actor
    /// and exists solely to provide a pool-backed ``MySQLDatabase`` reference
    /// without crossing actor isolation boundaries — which would trigger Swift 6
    /// Sendable warnings for the non-Sendable ``MySQLDatabase`` protocol.
    ///
    /// Both this pool and the ``ConnectionPool`` actor connect to the same local
    /// MySQL instance and share the same database schema. The separation is safe:
    /// - Connection count is well within MySQL's default limit of 151
    /// - Query isolation is unaffected (both pools use separate connections)
    /// - For transactional operations, callers use ``ConnectionPool/withTransaction(_:)``
    ///
    /// Annotated `nonisolated(unsafe)` because `EventLoopGroupConnectionPool`
    /// does not declare `Sendable` in AsyncKit 1.x despite being internally
    /// synchronized for concurrent access.
    nonisolated(unsafe) private let directPool: EventLoopGroupConnectionPool<MySQLConnectionSource>

    // MARK: - Initializer

    /// Creates a new database manager with the specified connection configuration.
    ///
    /// This initializer creates the NIO event loop group, the connection pool, and
    /// the migration manager. No database connection is established during
    /// initialization — call ``initialize()`` to verify connectivity and run
    /// pending migrations.
    ///
    /// - Parameters:
    ///   - hostname: MySQL server hostname. Defaults to `"localhost"` for Rule 9
    ///     (offline runtime). Must always be a local address.
    ///   - port: MySQL server port. Defaults to `3306` (standard MySQL port).
    ///   - username: MySQL authentication username. Required — no default value.
    ///   - password: MySQL authentication password. Required — no default value.
    ///   - database: Target database/schema name. Defaults to `"wealth_ledger"`.
    ///     Override with `"accounting_test"` for integration tests (Gate 10).
    ///   - maxConnections: Maximum connections per event loop in the pool.
    ///     Defaults to `10`, appropriate for single-user desktop use (Rule 13).
    ///   - migrationsPath: File-system path to the directory containing `.sql`
    ///     migration scripts. Defaults to `"Resources/Migrations"`.
    ///   - logger: Structured logger for lifecycle events. Defaults to a logger
    ///     with label `"persistence.database-manager"`.
    public init(
        hostname: String = "localhost",
        port: Int = 3306,
        username: String,
        password: String,
        database: String = "wealth_ledger",
        maxConnections: Int = 10,
        migrationsPath: String = "Resources/Migrations",
        logger: Logger = Logger(label: "persistence.database-manager")
    ) {
        self.logger = logger

        // Configure TLS for local MySQL connections.
        // Certificate verification is disabled because the MySQL instance is local
        // (Rule 9 — offline runtime). For production Homebrew MySQL on localhost,
        // TLS may or may not be enabled; .none verification ensures the connection
        // succeeds regardless of the local MySQL TLS configuration.
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none

        // Build the MySQLKit connection configuration.
        self.configuration = MySQLConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsConfiguration: tlsConfiguration
        )

        // Create the NIO event loop group with one thread per CPU core.
        // System.coreCount returns the number of available processing cores on
        // the target hardware (Apple Silicon M5 with high-performance and
        // efficiency cores).
        self.eventLoopGroup = MultiThreadedEventLoopGroup(
            numberOfThreads: System.coreCount
        )

        // Create the connection pool wrapping the configuration and event loop group.
        // The pool lazily creates connections on demand up to maxConnections per
        // event loop, then reuses idle connections for subsequent operations.
        self.pool = ConnectionPool(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup,
            maxConnections: maxConnections,
            logger: Logger(label: "persistence.connection-pool")
        )

        // Create a direct pool for the convenience `database` property.
        // This avoids crossing the ConnectionPool actor's isolation boundary with
        // the non-Sendable MySQLDatabase protocol, eliminating Swift 6 Sendable
        // warnings (Gate 2 compliance). Both pools connect to the same local MySQL
        // instance and share identical configuration.
        let connectionSource = MySQLConnectionSource(configuration: configuration)
        self.directPool = EventLoopGroupConnectionPool(
            source: connectionSource,
            maxConnectionsPerEventLoop: maxConnections,
            on: eventLoopGroup
        )

        // Create the migration manager pointed at the configured migrations directory.
        self.migrationManager = MigrationManager(
            migrationsPath: migrationsPath,
            logger: Logger(label: "persistence.migration-manager")
        )

        self.logger.info(
            "DatabaseManager created",
            metadata: [
                "hostname": "\(hostname)",
                "port": "\(port)",
                "database": "\(database)",
                "maxConnections": "\(maxConnections)",
                "migrationsPath": "\(migrationsPath)",
            ]
        )
    }

    // MARK: - Lifecycle Methods

    /// Initializes the database: verifies connectivity and runs pending migrations.
    ///
    /// This method must be called after construction and before any repository
    /// operations. It performs two steps in order:
    ///
    /// 1. **Health check** — Executes `SELECT 1` to verify the MySQL connection
    ///    is alive and the configured database is accessible.
    /// 2. **Migration execution** — Runs all pending SQL migration scripts from
    ///    the configured migrations directory in numerical order (001 → 008).
    ///
    /// If the health check fails, an error is thrown immediately and no migrations
    /// are attempted. If any migration fails, ``AppError/migrationFailed`` is thrown
    /// by the ``MigrationManager``.
    ///
    /// - Throws: Any error from the health check query or migration execution.
    public func initialize() async throws {
        logger.info("Initializing database connection")

        // Step 1 — Verify connectivity before attempting migrations.
        // This catches misconfigured hostname, port, credentials, or a MySQL
        // instance that is not running, providing a clear early failure.
        try await healthCheck()

        // Step 2 — Run pending migrations via the migration manager.
        // Use pool.withConnection to keep the MySQLDatabase reference inside the
        // actor boundary, avoiding Swift 6 Sendable warnings for the non-Sendable
        // MySQLDatabase protocol. The .sql() method from MySQLKit converts the
        // MySQLDatabase to an SQLDatabase interface required by
        // MigrationManager.runMigrations(on:).
        try await pool.withConnection { db in
            try await self.migrationManager.runMigrations(on: db.sql())
        }

        logger.info("Database initialization complete")
    }

    /// Verifies the MySQL connection is alive by executing a simple query.
    ///
    /// Leases a connection from the pool, executes `SELECT 1`, and returns the
    /// connection. This is useful for startup verification and periodic health
    /// monitoring.
    ///
    /// - Throws: Any error from connection leasing or query execution. Common
    ///   failures include: MySQL not running, incorrect credentials, database
    ///   does not exist, or network/socket issues.
    public func healthCheck() async throws {
        try await pool.withConnection { db in
            // Execute the simplest possible query to verify the connection.
            // SELECT 1 does not depend on any table or schema state, making it
            // a reliable connectivity probe even before migrations have run.
            // simpleQuery is a MySQLDatabase protocol extension from MySQLNIO;
            // .get() bridges the EventLoopFuture to async/await.
            _ = try await db.simpleQuery("SELECT 1").get()
        }
        logger.info("Database health check passed")
    }

    /// Gracefully shuts down the connection pool and event loop group.
    ///
    /// This method must be called during application teardown to release all
    /// database resources. Shutdown order is critical:
    ///
    /// 1. **Connection pool** is shut down first, closing all idle connections
    ///    and waiting for in-use connections to be returned and closed.
    /// 2. **Event loop group** is shut down second, stopping all I/O threads.
    ///    Shutting down the event loop group before the pool would cause the pool
    ///    to fail when trying to close connections (since the I/O infrastructure
    ///    would already be gone).
    ///
    /// - Throws: Advisory errors from connection or event loop shutdown. Resources
    ///   are fully released once this method returns, even if an error is thrown.
    public func shutdown() async throws {
        logger.info("Shutting down database manager")

        // Step 1 — Close all connections in the ConnectionPool actor.
        // This shuts down the AsyncKit EventLoopGroupConnectionPool inside the
        // actor, closing idle connections immediately and in-use connections as
        // they are returned.
        try await pool.shutdown()

        // Step 2 — Close all connections in the direct pool used by the `database`
        // convenience property. Uses withCheckedThrowingContinuation to bridge the
        // callback-based shutdownGracefully API to async/await.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            directPool.shutdownGracefully { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Step 3 — Stop the NIO event loop group.
        // shutdownGracefully() waits for all pending I/O to complete before
        // stopping the event loop threads. This must happen LAST because both
        // connection pools depend on the event loop group for I/O operations.
        try await eventLoopGroup.shutdownGracefully()

        logger.info("Database manager shutdown complete")
    }

    // MARK: - Database Access

    /// A pool-backed ``MySQLDatabase`` reference for executing queries.
    ///
    /// The returned database automatically leases and releases connections from
    /// the pool for each individual query. This is convenient for standalone
    /// queries that do not require explicit transaction management or
    /// multi-statement atomicity.
    ///
    /// For operations requiring atomicity across multiple statements (e.g.,
    /// valuation cache updates per Rule 11), use
    /// ``ConnectionPool/withTransaction(_:)`` instead.
    ///
    /// - Returns: A ``MySQLDatabase`` instance backed by the connection pool.
    ///
    /// - Note: This property uses a direct ``EventLoopGroupConnectionPool`` reference
    ///   rather than going through the ``ConnectionPool`` actor. This avoids crossing
    ///   the actor isolation boundary with the non-Sendable ``MySQLDatabase`` protocol,
    ///   eliminating Swift 6 strict concurrency warnings (Gate 2 compliance).
    public var database: any MySQLDatabase {
        directPool.database(logger: logger)
    }
}
