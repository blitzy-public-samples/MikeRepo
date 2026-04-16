// Sources/Persistence/Repositories/ReferenceDataRepository.swift
// WealthLedger — Reference Data Repository for MySQL reference_data Table
//
// Provides CRUD operations for the reference_data table, bulk insert for CSV ingestion
// (paginated at 1,000 records per batch per Rule 7), and domain-specific lookups by
// ticker and market date used by ValuationEngine for EOD price retrieval.
//
// Rule 8: MySQLKit-only persistence — NO SwiftData.
// Rule 7: Batch memory cap — findAll pagination capped at 1,000; bulkInsert batched at 1,000.
// Rule 6: Reference data simulation fidelity — stores ticker, name, 6 price fields, market_date.
// Rule 10: Schema referential integrity — reference_data has typed BIGINT UNSIGNED AUTO_INCREMENT PK.

import Foundation
import MySQLKit
import MySQLNIO
import SQLKit
import NIOCore
import Logging
import Shared

// MARK: - ReferenceData Model (Persistence Module Local)

/// Reference data entity representing a row in the `reference_data` MySQL table.
///
/// This struct is defined in the Persistence module to enable `ReferenceDataRepository`
/// to implement `RepositoryProtocol` with concrete type binding, since the Persistence
/// module cannot import ReferenceDataService (which would create a circular dependency:
/// ReferenceDataService → Persistence → ReferenceDataService).
///
/// Maps to MySQL DDL in `005_create_reference_data.sql`:
/// - `id`          → BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY
/// - `ticker`      → VARCHAR — NYSE equity ticker symbol
/// - `name`        → VARCHAR — Security display name
/// - `sod_bid`     → DECIMAL(20,6) — Start-of-day bid price
/// - `sod_ask`     → DECIMAL(20,6) — Start-of-day ask price
/// - `eod_bid`     → DECIMAL(20,6) — End-of-day bid price
/// - `eod_ask`     → DECIMAL(20,6) — End-of-day ask price
/// - `market_date` → DATE — Market date for this price record
public struct ReferenceData: Sendable, Equatable, Hashable, Codable {

    /// Auto-generated primary key (BIGINT UNSIGNED AUTO_INCREMENT).
    public let id: UInt64

    /// NYSE equity ticker symbol (e.g., "AAPL", "MSFT").
    public let ticker: String

    /// Security display name (e.g., "Apple Inc.", "Microsoft Corporation").
    public let name: String

    /// Start-of-day bid price stored as DECIMAL(20,6). Uses `Decimal` for precision.
    public let sodBid: Decimal

    /// Start-of-day ask price stored as DECIMAL(20,6). Uses `Decimal` for precision.
    public let sodAsk: Decimal

    /// End-of-day bid price stored as DECIMAL(20,6). Uses `Decimal` for precision.
    public let eodBid: Decimal

    /// End-of-day ask price stored as DECIMAL(20,6). Uses `Decimal` for precision.
    public let eodAsk: Decimal

    /// Market date for this price record (MySQL DATE column).
    public let marketDate: Date

    /// Memberwise initializer for creating `ReferenceData` instances.
    ///
    /// - Parameters:
    ///   - id: Primary key. Pass `0` for new records — the database assigns the real ID.
    ///   - ticker: NYSE equity ticker symbol.
    ///   - name: Security display name.
    ///   - sodBid: Start-of-day bid price.
    ///   - sodAsk: Start-of-day ask price.
    ///   - eodBid: End-of-day bid price.
    ///   - eodAsk: End-of-day ask price.
    ///   - marketDate: Market date for this price record.
    public init(
        id: UInt64,
        ticker: String,
        name: String,
        sodBid: Decimal,
        sodAsk: Decimal,
        eodBid: Decimal,
        eodAsk: Decimal,
        marketDate: Date
    ) {
        self.id = id
        self.ticker = ticker
        self.name = name
        self.sodBid = sodBid
        self.sodAsk = sodAsk
        self.eodBid = eodBid
        self.eodAsk = eodAsk
        self.marketDate = marketDate
    }
}

// MARK: - ReferenceDataRepository

/// Repository for the `reference_data` MySQL table providing CRUD operations,
/// bulk insert for CSV ingestion, and domain-specific lookups by ticker and market date.
///
/// Conforms to `RepositoryProtocol` with `Entity = ReferenceData` and `EntityID = UInt64`.
/// All database operations use MySQLKit exclusively (Rule 8 — no SwiftData).
///
/// ## Batch Memory Cap (Rule 7)
/// - `findAll(page:pageSize:)` paginates with a maximum of `AppConstants.defaultPagination` (1,000).
/// - `bulkInsert(_:)` processes entities in batches of `AppConstants.batchSize` (1,000).
///
/// ## Reference Data Fidelity (Rule 6)
/// - Stores all six price fields (SOD bid/ask, EOD bid/ask) as `Decimal` mapped to MySQL DECIMAL(20,6).
/// - The seed script is expected to produce at least 500 records; `count()` verifies this.
///
/// ## Sendable Safety (Gate 2)
/// - Declared as `public final class` with `let` properties only.
/// - `ConnectionPool` is an `actor` (inherently `Sendable`), and `Logger` is a value type.
/// - No `@unchecked Sendable` annotation needed; no warning suppressions.
/// - Static helper methods (`mapRow`, `makeBindings`) avoid capturing `self` in `@Sendable` closures.
public final class ReferenceDataRepository: RepositoryProtocol, Sendable {

    public typealias Entity = ReferenceData
    public typealias EntityID = UInt64

    /// AsyncKit-based MySQL connection pool, injected via constructor for dependency injection.
    private let pool: ConnectionPool

    /// Structured logger for operation tracing and bulk insert progress tracking.
    private let logger: Logger

    /// Initializes the repository with a connection pool and optional logger.
    ///
    /// - Parameters:
    ///   - pool: The AsyncKit-based MySQL connection pool for all database operations.
    ///   - logger: A structured logger instance. Defaults to label `"persistence.reference-data-repository"`.
    public init(
        pool: ConnectionPool,
        logger: Logger = Logger(label: "persistence.reference-data-repository")
    ) {
        self.pool = pool
        self.logger = logger
    }

    // MARK: - RepositoryProtocol Conformance

    /// Finds a reference data record by its primary key.
    ///
    /// Executes `SELECT ... FROM reference_data WHERE id = ?` with a parameterized bind.
    ///
    /// - Parameter id: The `BIGINT UNSIGNED` primary key of the record.
    /// - Returns: The matching `ReferenceData` instance, or `nil` if no record exists with that ID.
    /// - Throws: `AppError.migrationFailed` if the returned row cannot be decoded (schema mismatch).
    public func findById(_ id: UInt64) async throws -> ReferenceData? {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Finding reference data by id: \(id)")
            let rows = try await db.query(
                """
                SELECT id, ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date \
                FROM reference_data WHERE id = ?
                """,
                [MySQLData(int: Int(id))]
            ).get()
            guard let row = rows.first else {
                return nil
            }
            return try ReferenceDataRepository.mapRow(row)
        }
    }

    /// Retrieves a paginated list of reference data records ordered by ID.
    ///
    /// Pagination enforces Rule 7 (batch memory cap): page size is clamped to a maximum
    /// of `AppConstants.defaultPagination` (1,000) records per page.
    ///
    /// - Parameters:
    ///   - page: 1-based page number. Values below 1 are treated as page 1.
    ///   - pageSize: Number of records per page. Clamped to the range `[1, AppConstants.defaultPagination]`.
    ///               Defaults to `AppConstants.defaultPagination` (1,000).
    /// - Returns: An array of `ReferenceData` records for the requested page.
    /// - Throws: `AppError.migrationFailed` if any row cannot be decoded.
    public func findAll(
        page: Int = 1,
        pageSize: Int = AppConstants.defaultPagination
    ) async throws -> [ReferenceData] {
        let logger = self.logger
        let effectivePage = max(page, 1)
        let effectivePageSize = min(max(pageSize, 1), AppConstants.defaultPagination)
        let offset = (effectivePage - 1) * effectivePageSize

        return try await pool.withConnection { db in
            logger.info("Finding all reference data — page: \(effectivePage), pageSize: \(effectivePageSize), offset: \(offset)")
            let rows = try await db.query(
                """
                SELECT id, ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date \
                FROM reference_data ORDER BY id LIMIT ? OFFSET ?
                """,
                [MySQLData(int: effectivePageSize), MySQLData(int: offset)]
            ).get()
            return try rows.map { try ReferenceDataRepository.mapRow($0) }
        }
    }

    /// Creates a new reference data record in the database.
    ///
    /// Inserts the record and retrieves the auto-generated ID via `SELECT LAST_INSERT_ID()`
    /// on the same connection to guarantee correctness.
    ///
    /// - Parameter entity: The `ReferenceData` to insert. The `id` field is ignored (auto-generated).
    /// - Returns: A new `ReferenceData` instance with the auto-generated ID populated.
    /// - Throws: `AppError.migrationFailed` if `LAST_INSERT_ID()` cannot be retrieved.
    public func create(_ entity: ReferenceData) async throws -> ReferenceData {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Creating reference data record for ticker: \(entity.ticker)")

            let sql = """
                INSERT INTO reference_data \
                (ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date) \
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            let bindings = ReferenceDataRepository.makeBindings(for: entity)
            _ = try await db.query(sql, bindings).get()

            // Retrieve the auto-generated ID on the same connection
            let idRows = try await db.query(
                "SELECT LAST_INSERT_ID() AS insert_id", []
            ).get()
            guard let insertIdRow = idRows.first,
                  let insertId = insertIdRow.column("insert_id")?.uint64 else {
                throw AppError.migrationFailed
            }

            return ReferenceData(
                id: insertId,
                ticker: entity.ticker,
                name: entity.name,
                sodBid: entity.sodBid,
                sodAsk: entity.sodAsk,
                eodBid: entity.eodBid,
                eodAsk: entity.eodAsk,
                marketDate: entity.marketDate
            )
        }
    }

    /// Deletes a reference data record by its primary key.
    ///
    /// - Parameter id: The primary key of the record to delete.
    public func delete(_ id: UInt64) async throws {
        let logger = self.logger
        try await pool.withConnection { db in
            logger.info("Deleting reference data with id: \(id)")
            _ = try await db.query(
                "DELETE FROM reference_data WHERE id = ?",
                [MySQLData(int: Int(id))]
            ).get()
        }
    }

    /// Deletes all reference data records from the table.
    ///
    /// Used by `SeedTool` with the `--force` flag to clear existing reference data
    /// before re-seeding. Uses `DELETE FROM` (not `TRUNCATE`) to respect FK constraints
    /// from the `positions` table — if positions reference existing reference data,
    /// MySQL will reject the delete with a foreign-key violation error, preventing
    /// silent data loss in dependent tables.
    ///
    /// - Throws: Database errors including FK constraint violations if positions
    ///   reference existing reference data records.
    public func deleteAll() async throws {
        let logger = self.logger
        try await pool.withConnection { db in
            logger.info("Deleting all reference data records")
            _ = try await db.query("DELETE FROM reference_data", []).get()
            logger.info("All reference data records deleted")
        }
    }

    // MARK: - Domain-Specific Methods

    /// Inserts reference data records in batches for CSV ingestion.
    ///
    /// Processes entities in batches of `AppConstants.batchSize` (1,000) to enforce
    /// Rule 7 (batch memory cap). Each batch is wrapped in a database transaction via
    /// `pool.withTransaction` for atomicity — if any row in a batch fails, only that
    /// batch is rolled back. This supports CSV files up to 100MB without memory exhaustion.
    ///
    /// Uses multi-row `INSERT INTO ... VALUES (...), (...), ...` for each batch to
    /// minimize round-trips to MySQL.
    ///
    /// - Parameter entities: The array of `ReferenceData` records to insert.
    ///   The `id` fields are ignored (auto-generated).
    public func bulkInsert(_ entities: [ReferenceData]) async throws {
        guard !entities.isEmpty else { return }

        let totalCount = entities.count
        let batchSize = AppConstants.batchSize
        let logger = self.logger
        let totalBatches = (totalCount + batchSize - 1) / batchSize

        logger.info("Starting bulk insert of \(totalCount) records in \(totalBatches) batches of up to \(batchSize)")

        for startIndex in stride(from: 0, to: totalCount, by: batchSize) {
            let endIndex = min(startIndex + batchSize, totalCount)
            let batch = Array(entities[startIndex..<endIndex])
            let batchNumber = (startIndex / batchSize) + 1

            try await pool.withTransaction { db in
                // Build multi-row INSERT for the batch
                let placeholders = batch.map { _ in "(?, ?, ?, ?, ?, ?, ?)" }
                    .joined(separator: ", ")
                let sql = """
                    INSERT INTO reference_data \
                    (ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date) \
                    VALUES \(placeholders)
                    """

                // Construct all parameter bindings for the batch
                var bindings: [MySQLData] = []
                bindings.reserveCapacity(batch.count * 7)
                for entity in batch {
                    bindings.append(contentsOf: ReferenceDataRepository.makeBindings(for: entity))
                }

                _ = try await db.query(sql, bindings).get()
                logger.info("Bulk insert batch \(batchNumber)/\(totalBatches): inserted \(batch.count) records")
            }
        }

        logger.info("Bulk insert complete: \(totalCount) total records inserted across \(totalBatches) batches")
    }

    /// Finds a reference data record by ticker symbol and market date.
    ///
    /// Used by `ValuationEngine` to retrieve EOD prices for NAV calculation:
    /// `Σ(quantity × (eod_bid + eod_ask) / 2) + cash_balance`.
    ///
    /// - Parameters:
    ///   - ticker: The ticker symbol to match exactly.
    ///   - marketDate: The market date to match exactly.
    /// - Returns: The matching `ReferenceData`, or `nil` if no record exists.
    /// - Throws: `AppError.migrationFailed` if the row cannot be decoded.
    public func findByTickerAndDate(
        ticker: String,
        marketDate: Date
    ) async throws -> ReferenceData? {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Finding reference data for ticker: \(ticker), date: \(marketDate)")
            let rows = try await db.query(
                """
                SELECT id, ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date \
                FROM reference_data WHERE ticker = ? AND market_date = ?
                """,
                [MySQLData(string: ticker), ReferenceDataRepository.mysqlDate(marketDate)]
            ).get()
            guard let row = rows.first else {
                return nil
            }
            return try ReferenceDataRepository.mapRow(row)
        }
    }

    /// Finds reference data records for a given ticker, ordered by market date descending.
    ///
    /// Returns the price history for a single security across available market dates,
    /// capped at ``AppConstants/defaultPagination`` (1,000) records as a defensive
    /// guard (Rule 7 — Batch Memory Cap).
    ///
    /// - Parameter ticker: The ticker symbol to match exactly.
    /// - Returns: An array of `ReferenceData` records ordered by market date descending (newest first).
    /// - Throws: `AppError.migrationFailed` if any row cannot be decoded.
    public func findByTicker(_ ticker: String) async throws -> [ReferenceData] {
        let logger = self.logger
        let limit = AppConstants.defaultPagination
        return try await pool.withConnection { db in
            logger.info("Finding reference data for ticker: \(ticker) (limit \(limit))")
            let rows = try await db.query(
                """
                SELECT id, ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date \
                FROM reference_data WHERE ticker = ? ORDER BY market_date DESC LIMIT ?
                """,
                [MySQLData(string: ticker), MySQLData(int: limit)]
            ).get()
            return try rows.map { try ReferenceDataRepository.mapRow($0) }
        }
    }

    /// Finds reference data records for a given market date, ordered by ticker alphabetically.
    ///
    /// Used by `ValuationEngine` during batch valuation to retrieve all EOD prices for a
    /// valuation date in a single query, avoiding per-ticker round-trips.
    /// Capped at ``AppConstants/defaultPagination`` (1,000) records as a defensive
    /// guard (Rule 7 — Batch Memory Cap).
    ///
    /// - Parameter marketDate: The market date to match exactly.
    /// - Returns: An array of `ReferenceData` records for the given date, ordered by ticker.
    /// - Throws: `AppError.migrationFailed` if any row cannot be decoded.
    public func findByDate(_ marketDate: Date) async throws -> [ReferenceData] {
        let logger = self.logger
        let limit = AppConstants.defaultPagination
        return try await pool.withConnection { db in
            logger.info("Finding reference data for date: \(marketDate) (limit \(limit))")
            let rows = try await db.query(
                """
                SELECT id, ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date \
                FROM reference_data WHERE market_date = ? ORDER BY ticker LIMIT ?
                """,
                [ReferenceDataRepository.mysqlDate(marketDate), MySQLData(int: limit)]
            ).get()
            return try rows.map { try ReferenceDataRepository.mapRow($0) }
        }
    }

    /// Returns the total count of reference data records.
    ///
    /// Used to verify Rule 6: the seed script must produce at least 500 rows in `reference_data`.
    ///
    /// - Returns: The total number of reference data records in the table.
    public func count() async throws -> Int {
        let logger = self.logger
        return try await pool.withConnection { db in
            logger.info("Counting reference data records")
            let rows = try await db.query(
                "SELECT COUNT(*) AS cnt FROM reference_data", []
            ).get()
            guard let row = rows.first,
                  let cnt = row.column("cnt")?.int else {
                return 0
            }
            return cnt
        }
    }

    // MARK: - Private Helpers

    /// Maps a `MySQLRow` to a `ReferenceData` entity.
    ///
    /// Declared as `static` to allow safe invocation from `@Sendable` closures
    /// without capturing `self`. Throws `AppError.migrationFailed` if any required
    /// column is missing or cannot be decoded, indicating a schema mismatch between
    /// the application and the MySQL `reference_data` table.
    ///
    /// All six price fields are decoded via `MySQLData.decimal`, which correctly
    /// handles the MySQL `NEWDECIMAL` wire type in binary protocol format by reading
    /// the buffer as a string and converting to `Decimal`. Using `.string` would
    /// return `nil` for `NEWDECIMAL` columns because `MySQLData.string` only handles
    /// VARCHAR/STRING types in binary format — never `Double` or `Float`.
    ///
    /// - Parameter row: A MySQL result row from a SELECT query.
    /// - Returns: A fully populated `ReferenceData` instance.
    /// - Throws: `AppError.migrationFailed` if required columns are missing.
    private static func mapRow(_ row: MySQLRow) throws -> ReferenceData {
        guard let id = row.column("id")?.uint64,
              let ticker = row.column("ticker")?.string,
              let name = row.column("name")?.string,
              let sodBid = row.column("sod_bid")?.decimal,
              let sodAsk = row.column("sod_ask")?.decimal,
              let eodBid = row.column("eod_bid")?.decimal,
              let eodAsk = row.column("eod_ask")?.decimal,
              let marketDate = row.column("market_date")?.date else {
            throw AppError.migrationFailed
        }
        return ReferenceData(
            id: id,
            ticker: ticker,
            name: name,
            sodBid: sodBid,
            sodAsk: sodAsk,
            eodBid: eodBid,
            eodAsk: eodAsk,
            marketDate: marketDate
        )
    }

    /// Constructs `MySQLData` bindings for a `ReferenceData` entity's mutable fields
    /// (excluding the auto-generated `id`).
    ///
    /// Used by both `create(_:)` and `bulkInsert(_:)` to ensure consistent binding
    /// order matching the column list: `ticker, name, sod_bid, sod_ask, eod_bid, eod_ask, market_date`.
    ///
    /// `Decimal` values are converted to their string description for MySQL DECIMAL(20,6)
    /// columns. The `Decimal.description` property uses an invariant (US) locale with a
    /// dot decimal separator, which matches MySQL's expected format.
    ///
    /// - Parameter entity: The reference data entity to create bindings for.
    /// - Returns: An array of 7 `MySQLData` values in column insertion order.
    private static func makeBindings(for entity: ReferenceData) -> [MySQLData] {
        [
            MySQLData(string: entity.ticker),
            MySQLData(string: entity.name),
            MySQLData(string: "\(entity.sodBid)"),
            MySQLData(string: "\(entity.sodAsk)"),
            MySQLData(string: "\(entity.eodBid)"),
            MySQLData(string: "\(entity.eodAsk)"),
            mysqlDate(entity.marketDate)
        ]
    }

    /// Converts a Swift `Date` to a `MySQLData` string formatted as `YYYY-MM-DD` for MySQL DATE columns.
    ///
    /// Uses `Calendar` (a value type, safe in `@Sendable` static context) with UTC timezone
    /// to extract year, month, and day components. This avoids timezone-related date shifting
    /// and ensures exact DATE comparison in `WHERE market_date = ?` queries.
    ///
    /// - Parameter date: The Swift `Date` to convert.
    /// - Returns: A `MySQLData` string value formatted as `"YYYY-MM-DD"`.
    private static func mysqlDate(_ date: Date) -> MySQLData {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let formatted = String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
        return MySQLData(string: formatted)
    }
}
