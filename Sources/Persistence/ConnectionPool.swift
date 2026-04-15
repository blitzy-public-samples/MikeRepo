// Sources/Persistence/ConnectionPool.swift
// WealthLedger — AsyncKit-Based Connection Pool Management
//
// Wraps AsyncKit's EventLoopGroupConnectionPool to provide managed MySQL connections
// for all repository operations, atomic transaction support (BEGIN/COMMIT/ROLLBACK),
// and graceful lifecycle management. Critical for Rule 11 (cached valuation
// denormalization) and Rule 8 (MySQLKit-only persistence).
//
// SPDX-License-Identifier: MIT

import AsyncKit
import MySQLKit
import MySQLNIO
import NIOCore
import Logging

/// Manages a pool of MySQL connections backed by AsyncKit's ``EventLoopGroupConnectionPool``.
///
/// `ConnectionPool` is the central connection management component for the WealthLedger
/// persistence layer. It leases connections on demand, supports atomic multi-statement
/// transactions (BEGIN / COMMIT / ROLLBACK), and gracefully shuts down all connections
/// during application teardown.
///
/// ## Thread Safety
///
/// This type is declared as an `actor`, providing Swift-native concurrency isolation
/// without requiring `@unchecked Sendable` (Rule 12 / Gate 2 compliance). The actor
/// boundary serializes access to the underlying ``EventLoopGroupConnectionPool``, which
/// does not formally declare `Sendable` conformance in AsyncKit. All public methods are
/// actor-isolated and must be called with `await`.
///
/// ## Rule 8 — MySQLKit-Only Persistence
///
/// This file uses MySQLKit and AsyncKit exclusively. No SwiftData imports exist.
///
/// ## Rule 11 — Cached Valuation Denormalization
///
/// The ``withTransaction(_:)`` method enables `ValuationService` to atomically write
/// valuation results **and** update `accounts.cached_valuation_amount` /
/// `accounts.cached_value_date` within the same MySQL transaction.
///
/// ## Rule 12 — Gate 2 Compliance
///
/// This actor uses no `@unchecked Sendable` annotations or warning suppressions.
/// Actor isolation provides safe concurrent access to the non-Sendable
/// ``EventLoopGroupConnectionPool`` without bypassing the Swift 6 strict concurrency checker.
///
/// ## Rule 13 — Performance
///
/// Default pool size of 10 connections per event loop is appropriate for the single-user
/// desktop architecture, while providing sufficient concurrency for batch operations
/// (1,000-account valuation under 30 seconds).
public actor ConnectionPool {

    // MARK: - Properties

    /// The AsyncKit connection pool wrapping MySQL connections.
    ///
    /// Manages connection leasing, returning, idle pruning, and lifecycle for all
    /// database operations. Connections are created on demand up to
    /// `maxConnectionsPerEventLoop`, then reused from the pool.
    private let pool: EventLoopGroupConnectionPool<MySQLConnectionSource>

    /// Shared NIO event loop group managing async I/O threads for pooled connections.
    ///
    /// Received from ``DatabaseManager`` to ensure a single event loop group is shared
    /// across the entire persistence layer. The event loop group determines the number
    /// of I/O threads available for concurrent database operations.
    private let eventLoopGroup: any EventLoopGroup

    /// Structured logger for connection pool lifecycle events.
    ///
    /// Uses the label `"persistence.connection-pool"` by default. Logs connection
    /// leasing, transaction boundaries, and shutdown events for operational visibility.
    private let logger: Logger

    // MARK: - Initializer

    /// Creates a new connection pool backed by AsyncKit's ``EventLoopGroupConnectionPool``.
    ///
    /// The pool lazily creates connections as needed up to `maxConnections` per event loop.
    /// Idle connections are retained for reuse, reducing the overhead of establishing new
    /// MySQL connections for each query.
    ///
    /// - Parameters:
    ///   - configuration: MySQLKit connection configuration for the local MySQL 8.0 instance.
    ///                    Typically configured with `hostname: "localhost"`, `port: 3306`,
    ///                    and `database: "wealth_ledger"` (or `"accounting_test"` for Gate 10).
    ///   - eventLoopGroup: Shared NIO event loop group received from ``DatabaseManager``.
    ///                     Determines the number of I/O threads for concurrent operations.
    ///   - maxConnections: Maximum connections per event loop. Defaults to `10`, which is
    ///                     appropriate for single-user desktop use (Rule 13) while supporting
    ///                     concurrent batch operations without bottleneck.
    ///   - logger: Structured logger for pool lifecycle events. Defaults to a logger with
    ///             label `"persistence.connection-pool"`.
    public init(
        configuration: MySQLConfiguration,
        eventLoopGroup: any EventLoopGroup,
        maxConnections: Int = 10,
        logger: Logger = Logger(label: "persistence.connection-pool")
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger

        let source = MySQLConnectionSource(configuration: configuration)
        self.pool = EventLoopGroupConnectionPool(
            source: source,
            maxConnectionsPerEventLoop: maxConnections,
            on: eventLoopGroup
        )
    }

    // MARK: - Connection Management

    /// Lease a managed MySQL connection from the pool and execute a closure.
    ///
    /// The connection is automatically returned to the pool after the closure completes,
    /// regardless of whether it succeeds or throws an error. This guarantees connections
    /// are never leaked, even under error conditions.
    ///
    /// ```swift
    /// let rows = try await pool.withConnection { db in
    ///     try await db.simpleQuery("SELECT * FROM accounts LIMIT 10").get()
    /// }
    /// ```
    ///
    /// - Parameter closure: An async closure receiving a ``MySQLDatabase`` reference
    ///   backed by a single pooled connection. The connection remains leased for the
    ///   entire duration of the closure.
    /// - Returns: The value produced by the closure.
    /// - Throws: Any error thrown by the closure. The connection is returned to the
    ///   pool before the error propagates.
    public func withConnection<T: Sendable>(
        _ closure: @Sendable @escaping (any MySQLDatabase) async throws -> T
    ) async throws -> T {
        let connection = try await pool.requestConnection(
            logger: logger
        ).get()
        do {
            let result = try await closure(connection)
            pool.releaseConnection(connection, logger: logger)
            return result
        } catch {
            pool.releaseConnection(connection, logger: logger)
            throw error
        }
    }

    // MARK: - Transaction Support

    /// Execute a closure within an atomic MySQL transaction (BEGIN / COMMIT / ROLLBACK).
    ///
    /// This method is **critical for Rule 11** (Cached Valuation Denormalization):
    /// ``ValuationService`` calls this to atomically write valuation results **and**
    /// update `accounts.cached_valuation_amount` / `accounts.cached_value_date`
    /// within a single database transaction.
    ///
    /// On success, the transaction is committed. On any failure, the transaction is
    /// rolled back before the error is re-thrown. The underlying connection is always
    /// returned to the pool regardless of outcome.
    ///
    /// ```swift
    /// try await pool.withTransaction { db in
    ///     // Insert valuation record
    ///     try await db.simpleQuery("INSERT INTO valuations ...").get()
    ///     // Atomically update cached valuation on the account
    ///     try await db.simpleQuery("UPDATE accounts SET ...").get()
    /// }
    /// ```
    ///
    /// - Parameter closure: An async closure to execute within the transaction boundary.
    ///   All database operations within the closure use the same connection and share
    ///   the same transaction context.
    /// - Returns: The value produced by the closure.
    /// - Throws: Any error thrown by the closure (after ROLLBACK completes).
    public func withTransaction<T: Sendable>(
        _ closure: @Sendable @escaping (any MySQLDatabase) async throws -> T
    ) async throws -> T {
        try await withConnection { database in
            // Begin the MySQL transaction
            _ = try await database.simpleQuery("BEGIN").get()
            do {
                let result = try await closure(database)
                // Commit on success
                _ = try await database.simpleQuery("COMMIT").get()
                return result
            } catch {
                // Rollback on failure — use try? to avoid masking the original error.
                // If ROLLBACK itself fails (e.g., connection dropped), the original
                // error from the closure is still propagated to the caller.
                _ = try? await database.simpleQuery("ROLLBACK").get()
                throw error
            }
        }
    }

    // MARK: - Simple Database Access

    /// Returns a pool-backed ``MySQLDatabase`` reference for simple non-transactional queries.
    ///
    /// The returned database automatically leases and releases connections from the pool
    /// for each individual query. This is convenient for standalone queries that do not
    /// require explicit transaction management or multi-statement atomicity.
    ///
    /// For operations requiring atomicity across multiple statements (e.g., valuation
    /// cache updates per Rule 11), use ``withTransaction(_:)`` instead.
    ///
    /// ```swift
    /// let db = pool.database()
    /// let rows = try await db.simpleQuery("SELECT COUNT(*) FROM accounts").get()
    /// ```
    ///
    /// - Returns: A ``MySQLDatabase`` instance backed by the connection pool.
    public func database() -> any MySQLDatabase {
        pool.database(logger: logger)
    }

    // MARK: - Lifecycle

    /// Gracefully shut down the connection pool, closing all connections.
    ///
    /// All available connections are closed immediately. Any connections currently
    /// in use are closed as soon as they are returned to the pool. Once shut down,
    /// the pool cannot be used to create new connections.
    ///
    /// This method must be called before the ``ConnectionPool`` instance is
    /// deinitialized. Failure to do so triggers an assertion in AsyncKit's
    /// ``EventLoopGroupConnectionPool`` deinit.
    ///
    /// Uses `shutdownGracefully` with a checked continuation instead of `shutdownAsync()`
    /// to avoid sending the actor-isolated pool reference across isolation boundaries.
    ///
    /// - Throws: Advisory errors from connection closure. The pool is always fully
    ///   shut down once this method returns, even if an error is thrown.
    public func shutdown() async throws {
        logger.info("Shutting down connection pool")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pool.shutdownGracefully { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        logger.info("Connection pool shutdown complete")
    }
}
