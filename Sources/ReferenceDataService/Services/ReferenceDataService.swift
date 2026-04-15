// ReferenceDataService.swift
// Sources/ReferenceDataService/Services/ReferenceDataService.swift
//
// Reference data query and management service for the WealthLedger accounting engine.
// Delegates all persistence to `ReferenceDataRepository` from the Persistence module
// and orchestrates CSV ingestion workflows via `CSVParser`.
//
// Rule 6: Reference data simulation fidelity — supports 500+ synthetic NYSE equity records.
// Rule 7: Batch memory cap — pagination clamped at AppConstants.defaultPagination (1,000).
// Rule 8: MySQLKit-only persistence — NO SwiftData; persistence via repository pattern.
// Rule 9: Offline runtime — no network calls; all data from local MySQL and filesystem.
// Gate 2: Swift 6 strict concurrency — Sendable final class with let-only properties.

import Foundation
import Persistence
import Shared

// MARK: - ReferenceDataService

/// Service layer for reference data query and management operations.
///
/// Delegates all database persistence to ``ReferenceDataRepository`` (from the
/// `Persistence` module) and orchestrates CSV ingestion via ``CSVParser`` (from
/// the same `ReferenceDataService` module). This service adds pagination clamping
/// (Rule 7) and CSV ingestion orchestration on top of the raw repository.
///
/// ## Type Bridging
///
/// The `Persistence` module defines its own `ReferenceData` struct to avoid a
/// circular dependency (ReferenceDataService → Persistence → ReferenceDataService).
/// This service converts between `Persistence.ReferenceData` (repository layer)
/// and the module-local ``ReferenceData`` (from `Models/ReferenceData.swift`)
/// transparently. Callers always interact with the module-local type.
///
/// ## Consumers
///
/// - **`ValuationEngine`** — EOD price lookups via ``findByTickerAndDate(ticker:marketDate:)``
///   and ``findByDate(_:)`` for batch valuation.
/// - **`JobSchedulerService`** — Reference data lifecycle management and CSV ingestion.
/// - **`DependencyContainer`** — Registers this service with injected dependencies.
///
/// ## Concurrency Safety (Gate 2)
///
/// Declared as `public final class` conforming to `Sendable`. Both stored properties
/// are `let`-bound and `Sendable`-conformant:
/// - ``ReferenceDataRepository`` is `Sendable` (final class with let properties).
/// - ``CSVParser`` is `Sendable` (stateless struct).
///
/// Zero `@unchecked Sendable` annotations. Zero `// swiftlint:disable` suppressions.
///
/// ## Rules Enforced
///
/// - **Rule 7 (Batch Memory Cap)**: ``listAll(page:pageSize:)`` clamps `pageSize`
///   to `AppConstants.defaultPagination` (1,000).
/// - **Rule 8 (MySQLKit-Only)**: No `import SwiftData`; persistence delegated to
///   repository.
/// - **Rule 9 (Offline Runtime)**: No network calls; data from local MySQL and
///   local filesystem only.
public final class ReferenceDataService: Sendable {

    // MARK: - Properties

    /// The repository for reference data persistence operations.
    ///
    /// Injected via ``init(repository:csvParser:)`` and used by all query and
    /// mutation methods. All database operations are delegated to this repository;
    /// the service layer never imports MySQLKit directly.
    private let repository: ReferenceDataRepository

    /// The CSV parser for file ingestion operations.
    ///
    /// Injected via ``init(repository:csvParser:)`` and used by
    /// ``ingestCSV(at:)`` to parse reference data CSV files before bulk
    /// inserting records into the database.
    private let csvParser: CSVParser

    // MARK: - Initializer

    /// Creates a new ``ReferenceDataService`` with injected dependencies.
    ///
    /// This initializer is called by ``DependencyContainer`` during application
    /// bootstrap. Both parameters are required and retained for the lifetime of
    /// the service instance.
    ///
    /// - Parameters:
    ///   - repository: The reference data repository for database operations.
    ///     Must be a fully initialized ``ReferenceDataRepository`` connected to
    ///     the MySQL `reference_data` table.
    ///   - csvParser: The CSV parser for file ingestion. Typically a default-
    ///     initialized ``CSVParser()`` instance.
    public init(repository: ReferenceDataRepository, csvParser: CSVParser) {
        self.repository = repository
        self.csvParser = csvParser
    }

    // MARK: - Query Methods

    /// Retrieves reference data for a specific ticker on a specific market date.
    ///
    /// Primary use case: ``ValuationEngine`` retrieves EOD prices for NAV
    /// calculation using the formula `Σ(quantity × EOD midpoint) + cash balance`.
    ///
    /// No entitlement check is required for reference data — it is shared global
    /// data accessible to all authenticated users.
    ///
    /// - Parameters:
    ///   - ticker: NYSE equity ticker symbol (e.g., `"AAPL"`).
    ///   - marketDate: The market date for which to retrieve price data.
    /// - Returns: The reference data record converted to the module-local
    ///   ``ReferenceData`` type, or `nil` if no record exists for the given
    ///   ticker and date combination.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func findByTickerAndDate(
        ticker: String,
        marketDate: Date
    ) async throws -> ReferenceData? {
        guard let persisted = try await repository.findByTickerAndDate(
            ticker: ticker,
            marketDate: marketDate
        ) else {
            return nil
        }
        return Self.toLocal(persisted)
    }

    /// Retrieves all reference data records for a specific ticker.
    ///
    /// Returns all market data records for a ticker, ordered by market date
    /// descending (newest first). Useful for viewing the price history of a
    /// single security across multiple trading days.
    ///
    /// - Parameter ticker: NYSE equity ticker symbol (e.g., `"MSFT"`).
    /// - Returns: All reference data records for the ticker, converted to the
    ///   module-local ``ReferenceData`` type and ordered by market date descending.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func findByTicker(_ ticker: String) async throws -> [ReferenceData] {
        let persisted = try await repository.findByTicker(ticker)
        return persisted.map { Self.toLocal($0) }
    }

    /// Retrieves all reference data records for a specific market date.
    ///
    /// Primary use case: ``ValuationEngine`` batch valuation — retrieves all
    /// EOD prices for a single valuation date in one query, avoiding per-ticker
    /// round-trips to the database.
    ///
    /// - Parameter marketDate: The market date for which to retrieve price data.
    /// - Returns: All reference data records for the date, converted to the
    ///   module-local ``ReferenceData`` type and ordered by ticker alphabetically.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func findByDate(_ marketDate: Date) async throws -> [ReferenceData] {
        let persisted = try await repository.findByDate(marketDate)
        return persisted.map { Self.toLocal($0) }
    }

    /// Retrieves a reference data record by its unique identifier.
    ///
    /// - Parameter id: The unique `BIGINT UNSIGNED` identifier of the reference
    ///   data record (auto-generated by MySQL on insert).
    /// - Returns: The reference data record converted to the module-local
    ///   ``ReferenceData`` type, or `nil` if no record exists with that ID.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func findById(_ id: UInt64) async throws -> ReferenceData? {
        guard let persisted = try await repository.findById(id) else {
            return nil
        }
        return Self.toLocal(persisted)
    }

    /// Lists all reference data records with pagination.
    ///
    /// Enforces **Rule 7 (Batch Memory Cap)**: the `pageSize` parameter is
    /// clamped to `AppConstants.defaultPagination` (1,000). Callers requesting
    /// more than 1,000 records per page will silently receive at most 1,000.
    ///
    /// - Parameters:
    ///   - page: The 1-based page number. Values below 1 are treated as page 1
    ///     by the underlying repository.
    ///   - pageSize: Maximum number of records per page. Clamped to
    ///     `AppConstants.defaultPagination` (1,000) to enforce Rule 7.
    ///     Defaults to 1,000.
    /// - Returns: A page of reference data records converted to the module-local
    ///   ``ReferenceData`` type.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func listAll(
        page: Int = 1,
        pageSize: Int = AppConstants.defaultPagination
    ) async throws -> [ReferenceData] {
        // Rule 7: clamp pageSize to the maximum allowed pagination size
        let clampedPageSize = min(pageSize, AppConstants.defaultPagination)
        let persisted = try await repository.findAll(
            page: page,
            pageSize: clampedPageSize
        )
        return persisted.map { Self.toLocal($0) }
    }

    // MARK: - Write Methods

    /// Creates a new reference data record.
    ///
    /// Delegates to ``ReferenceDataRepository/create(_:)`` which inserts the
    /// record into the MySQL `reference_data` table and returns the entity with
    /// the auto-generated `BIGINT UNSIGNED` primary key populated.
    ///
    /// - Parameter referenceData: The reference data to insert. The `id` field
    ///   is ignored — MySQL auto-generates the primary key on insert.
    /// - Returns: The created reference data record with the auto-generated ID
    ///   populated, converted to the module-local ``ReferenceData`` type.
    /// - Throws: Constraint violations, connection errors, or other persistence-
    ///   layer errors propagated from the repository.
    public func create(_ referenceData: ReferenceData) async throws -> ReferenceData {
        let persistenceEntity = Self.toPersistence(referenceData)
        let created = try await repository.create(persistenceEntity)
        return Self.toLocal(created)
    }

    /// Bulk inserts reference data records.
    ///
    /// Delegates to ``ReferenceDataRepository/bulkInsert(_:)`` which processes
    /// entities in batches of `AppConstants.batchSize` (1,000) to enforce
    /// **Rule 7 (Batch Memory Cap)**. Each batch is wrapped in a database
    /// transaction for atomicity.
    ///
    /// Used by CSV ingestion jobs to seed reference data from parsed CSV files.
    ///
    /// - Parameter entities: The reference data records to insert. The `id`
    ///   fields are ignored — MySQL auto-generates primary keys.
    /// - Throws: Constraint violations, connection errors, or other persistence-
    ///   layer errors propagated from the repository.
    public func bulkInsert(_ entities: [ReferenceData]) async throws {
        let persistenceEntities = entities.map { Self.toPersistence($0) }
        try await repository.bulkInsert(persistenceEntities)
    }

    /// Ingests reference data from a CSV file at the specified path.
    ///
    /// Orchestrates the complete CSV ingestion workflow:
    /// 1. Parses the CSV file using ``CSVParser/parseReferenceDataCSV(at:)``
    ///    with column validation (ticker, name, sod_bid, sod_ask, eod_bid,
    ///    eod_ask, market_date).
    /// 2. Converts parsed records from module-local ``ReferenceData`` to
    ///    `Persistence.ReferenceData` for the repository layer.
    /// 3. Bulk inserts all records via ``ReferenceDataRepository/bulkInsert(_:)``
    ///    in batches of 1,000 (Rule 7).
    ///
    /// Supports files up to 100 MB without crash (Rule 13) via `CSVParser`'s
    /// buffered I/O implementation using `FileHandle` with 64 KB read chunks.
    ///
    /// **Rule 9 (Offline Runtime)**: The file path must reference a local
    /// filesystem path. No network URLs are supported.
    ///
    /// - Parameter filePath: Absolute or relative path to the CSV file on the
    ///   local filesystem.
    /// - Throws: ``CSVParser/CSVParseError`` if the file cannot be read, column
    ///   validation fails, or any row contains invalid data. Database errors
    ///   from the repository if bulk insertion fails.
    public func ingestCSV(at filePath: String) async throws {
        // Step 1: Parse CSV file — returns module-local ReferenceData records
        let records = try csvParser.parseReferenceDataCSV(at: filePath)

        // Step 2: Convert to Persistence module types and bulk insert
        let persistenceRecords = records.map { Self.toPersistence($0) }
        try await repository.bulkInsert(persistenceRecords)
    }

    /// Deletes a reference data record by its unique identifier.
    ///
    /// Delegates directly to ``ReferenceDataRepository/delete(_:)`` which
    /// executes `DELETE FROM reference_data WHERE id = ?`.
    ///
    /// - Parameter id: The unique `BIGINT UNSIGNED` identifier of the record
    ///   to delete.
    /// - Throws: Foreign key constraint violations (if positions reference this
    ///   record), connection errors, or other persistence-layer errors.
    public func delete(_ id: UInt64) async throws {
        try await repository.delete(id)
    }

    /// Returns the total number of reference data records in the database.
    ///
    /// Delegates to ``ReferenceDataRepository/count()`` which executes
    /// `SELECT COUNT(*) FROM reference_data`.
    ///
    /// Used for **Rule 6** verification: the seed script must produce at least
    /// 500 rows in the `reference_data` table.
    ///
    /// - Returns: The total count of reference data records.
    /// - Throws: Database connection or query execution errors propagated from
    ///   the repository layer.
    public func count() async throws -> Int {
        try await repository.count()
    }

    // MARK: - Private Type Conversion Helpers

    /// Converts a `Persistence.ReferenceData` entity to the module-local
    /// ``ReferenceData`` type.
    ///
    /// This conversion bridges the type boundary between the `Persistence`
    /// module (which defines its own `ReferenceData` to avoid circular
    /// dependencies) and the `ReferenceDataService` module's model type.
    ///
    /// Declared as `static` to allow safe invocation from `@Sendable` contexts
    /// without capturing `self`.
    ///
    /// - Parameter entity: The Persistence module's reference data entity.
    /// - Returns: An equivalent module-local ``ReferenceData`` instance.
    private static func toLocal(
        _ entity: Persistence.ReferenceData
    ) -> ReferenceData {
        ReferenceData(
            id: entity.id,
            ticker: entity.ticker,
            name: entity.name,
            sodBid: entity.sodBid,
            sodAsk: entity.sodAsk,
            eodBid: entity.eodBid,
            eodAsk: entity.eodAsk,
            marketDate: entity.marketDate
        )
    }

    /// Converts a module-local ``ReferenceData`` entity to the
    /// `Persistence.ReferenceData` type for repository operations.
    ///
    /// This conversion bridges the type boundary when passing data from the
    /// service layer to the `Persistence` module's ``ReferenceDataRepository``.
    ///
    /// Declared as `static` to allow safe invocation from `@Sendable` contexts
    /// without capturing `self`.
    ///
    /// - Parameter entity: The module-local reference data entity.
    /// - Returns: An equivalent `Persistence.ReferenceData` instance.
    private static func toPersistence(
        _ entity: ReferenceData
    ) -> Persistence.ReferenceData {
        Persistence.ReferenceData(
            id: entity.id,
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
