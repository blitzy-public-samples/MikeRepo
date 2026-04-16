// Sources/ValuationEngine/Services/ValuationService.swift
//
// Batch NAV valuation orchestrator for the WealthLedger general ledger
// accounting engine. Loads account positions, retrieves EOD prices,
// invokes NAVCalculator for per-account NAV computation, and writes
// cached valuation results atomically to the accounts table.
//
// RULE ENFORCEMENT:
// - Rule 3:  Per-account IANA timezone for value date computation
// - Rule 7:  Batch memory cap at 1,000 accounts per page
// - Rule 8:  MySQLKit-only persistence (no SwiftData)
// - Rule 11: Atomic cached valuation denormalization via withTransaction
// - Rule 13: Performance — 1,000 accounts under 30 seconds
// - Gate 2:  Swift 6 strict concurrency — zero warnings

import Foundation
import Logging
import Shared

// Selective imports from Persistence to avoid ReferenceData name collision
// with the ReferenceDataService module's ReferenceData struct. This mirrors
// the import pattern used by NAVCalculator.swift which does
// `import struct Persistence.Position` instead of `import Persistence`.
import struct Persistence.Account
import struct Persistence.Position
import class Persistence.AccountRepository
import class Persistence.PositionRepository
import class Persistence.ReferenceDataRepository
import class Persistence.ConnectionPool

// Full module import for ReferenceData model type. Because we did NOT import
// the full Persistence module above, 'ReferenceData' here unambiguously refers
// to ReferenceDataService's ReferenceData struct (the type NAVCalculator expects).
import ReferenceDataService

// MARK: - ValuationService

/// Orchestrates per-account closed-book NAV valuation with timezone-aware
/// value date computation and atomic cached valuation denormalization.
///
/// The `ValuationService` performs the following workflow for each account:
/// 1. Load the account's positions via ``PositionRepository``
/// 2. Retrieve EOD prices from ``ReferenceDataRepository`` for the market date
/// 3. Invoke ``NAVCalculator/computeNAV(positions:referenceData:cashBalance:)``
///    to compute the account value
/// 4. Compute the value date using the account's stored IANA timezone (Rule 3)
/// 5. Write the cached valuation amount and value date atomically (Rule 11)
///
/// Batch operations paginate at ``AppConstants/batchSize`` (1,000) accounts
/// per page to enforce Rule 7 (batch memory cap).
///
/// ## Sendable Safety
///
/// This class is `Sendable` by construction: it is `final` and all stored
/// properties are immutable `let` bindings of `Sendable`-conforming types.
/// No `@unchecked Sendable` annotation is required (Gate 2 compliance).
///
/// ## Cross-Module Type Mapping
///
/// Repository methods return `Persistence.ReferenceData`, but ``NAVCalculator``
/// expects `ReferenceDataService.ReferenceData`. The private helper
/// ``buildReferenceDataLookup(for:)`` performs the conversion, building a
/// dictionary keyed by reference data ID for O(1) price lookup during NAV
/// computation. Both types share identical stored properties.
public final class ValuationService: Sendable {

    // MARK: - Dependencies (all immutable for Sendable safety)

    /// Repository for account CRUD and cached valuation updates (Rule 11).
    private let accountRepository: AccountRepository

    /// Repository for loading account positions.
    private let positionRepository: PositionRepository

    /// Repository for retrieving EOD reference data prices.
    private let referenceDataRepository: ReferenceDataRepository

    /// Pure NAV calculation engine implementing the formula:
    /// `Σ(quantity × EOD midpoint) + cash_balance`.
    private let navCalculator: NAVCalculator

    /// Actor-based connection pool for transactional operations ensuring atomic
    /// cached valuation writes (Rule 11).
    private let connectionPool: ConnectionPool

    /// Structured logger for progress tracking and debugging.
    private let logger: Logger

    // MARK: - Initialization

    /// Creates a new `ValuationService` with all required dependencies injected.
    ///
    /// All parameters are retained as immutable `let` bindings for thread safety
    /// and `Sendable` compliance. The logger defaults to a descriptive label if
    /// not provided.
    ///
    /// - Parameters:
    ///   - accountRepository: Repository for account data and cached valuation updates.
    ///   - positionRepository: Repository for loading account positions.
    ///   - referenceDataRepository: Repository for retrieving EOD prices by market date.
    ///   - navCalculator: Pure NAV calculation engine.
    ///   - connectionPool: Actor-based connection pool for transactional operations (Rule 11).
    ///   - logger: Structured logger for operational visibility.
    public init(
        accountRepository: AccountRepository,
        positionRepository: PositionRepository,
        referenceDataRepository: ReferenceDataRepository,
        navCalculator: NAVCalculator,
        connectionPool: ConnectionPool,
        logger: Logger = Logger(label: "valuation-engine.valuation-service")
    ) {
        self.accountRepository = accountRepository
        self.positionRepository = positionRepository
        self.referenceDataRepository = referenceDataRepository
        self.navCalculator = navCalculator
        self.connectionPool = connectionPool
        self.logger = logger
    }

    // MARK: - Public API

    /// Runs NAV valuation for a specified list of account IDs on a given market date.
    ///
    /// This method enforces several critical rules:
    /// - **Rule 7**: Account IDs are processed in batches of ``AppConstants/batchSize``
    ///   (1,000) to cap memory usage. No more than 1,000 account records exist in memory
    ///   simultaneously.
    /// - **Rule 3**: Value dates are computed using each account's stored IANA timezone,
    ///   never the system clock timezone. Two accounts in different timezones may produce
    ///   distinct value dates for the same UTC instant.
    /// - **Rule 11**: Cached valuation amounts and value dates are written atomically
    ///   within a single DB transaction per batch via ``ConnectionPool/withTransaction(_:)``.
    /// - **Rule 13**: EOD reference data is loaded once and reused across all batches.
    ///   Positions are loaded in batch via ``PositionRepository/findByAccountIds(_:)``
    ///   to minimize DB round-trips for the 30-second performance target.
    ///
    /// - Parameters:
    ///   - accountIds: Array of account primary keys to value. Empty array returns
    ///     empty results without executing any queries.
    ///   - marketDate: The market date for EOD price retrieval.
    /// - Returns: Array of ``Valuation`` results, one per successfully valued account.
    /// - Throws: ``AppError/accountNotFound`` if an account ID doesn't exist,
    ///   ``AppError/invalidTimezone`` if an account has an invalid IANA timezone string,
    ///   or database errors from repository operations.
    public func runValuation(
        for accountIds: [UInt64],
        marketDate: Date
    ) async throws -> [Valuation] {
        // Short-circuit: empty input produces empty output
        guard !accountIds.isEmpty else {
            logger.info("runValuation called with empty account IDs — returning empty results")
            return []
        }

        logger.info("Starting valuation for \(accountIds.count) accounts on market date \(marketDate)")
        let startTime = Date()

        // Load EOD reference data once for the entire valuation run (Rule 13 efficiency).
        // Converts Persistence.ReferenceData to ReferenceDataService.ReferenceData for
        // compatibility with NAVCalculator's expected parameter type.
        let referenceDataLookup = try await buildReferenceDataLookup(for: marketDate)
        logger.info("Loaded \(referenceDataLookup.count) reference data entries for market date")

        var allResults: [Valuation] = []

        // Rule 7: Paginate at AppConstants.batchSize (1,000) accounts per batch.
        let totalBatches = (accountIds.count + AppConstants.batchSize - 1) / AppConstants.batchSize

        var batchNumber = 0
        var batchStart = 0
        while batchStart < accountIds.count {
            batchNumber += 1
            let batchEnd = min(batchStart + AppConstants.batchSize, accountIds.count)
            let batchIds = Array(accountIds[batchStart..<batchEnd])

            logger.info("Processing batch \(batchNumber) of \(totalBatches): \(batchIds.count) accounts")

            // Load accounts for this batch (capped at batchSize by AccountRepository)
            let accounts = try await accountRepository.findByIds(batchIds)

            // Load all positions for this batch's accounts
            let positions = try await positionRepository.findByAccountIds(batchIds)

            // Compute valuations for this batch — pure computation, no DB calls
            let batchValuations = try valuateAccountBatch(
                accounts: accounts,
                positions: positions,
                referenceDataLookup: referenceDataLookup
            )

            // Rule 11: Write cached valuations atomically within a single DB transaction.
            try await writeCachedValuationsAtomically(batchValuations)

            allResults.append(contentsOf: batchValuations)
            logger.info("Batch \(batchNumber) complete: \(batchValuations.count) accounts valued")

            batchStart = batchEnd
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedFmt = String(format: "%.2f", elapsed)
        logger.info("Valuation complete: \(allResults.count) accounts valued in \(elapsedFmt)s")

        return allResults
    }

    /// Runs NAV valuation for the entire account universe with pagination.
    ///
    /// Paginates through all accounts at ``AppConstants/batchSize`` (1,000) per page
    /// (Rule 7), loading reference data once for the market date. Each page of accounts
    /// is valued and its cached results are written atomically (Rule 11).
    ///
    /// For a universe of 100,000 accounts, this method executes approximately 100
    /// paginated page loads plus per-batch position loads and valuation computations.
    /// Reference data is loaded once and reused across all pages (Rule 13).
    ///
    /// - Parameter marketDate: The market date for EOD price retrieval.
    /// - Returns: Array of ``Valuation`` results for all accounts in the universe.
    /// - Throws: ``AppError/invalidTimezone`` if any account has an invalid timezone,
    ///   or database errors from repository operations.
    public func runValuationForAllAccounts(
        marketDate: Date
    ) async throws -> [Valuation] {
        logger.info("Starting full-universe valuation for market date \(marketDate)")
        let startTime = Date()

        // Load EOD reference data once for the entire run (Rule 13 efficiency).
        let referenceDataLookup = try await buildReferenceDataLookup(for: marketDate)
        logger.info("Loaded \(referenceDataLookup.count) reference data entries for market date")

        var allResults: [Valuation] = []
        var page = 1
        let pageSize = AppConstants.batchSize  // Rule 7: 1,000 accounts per page

        // Paginate through the entire account universe until an empty page
        // signals no more accounts remain.
        while true {
            logger.info("Loading account page \(page) (pageSize=\(pageSize))")

            // Load a page of accounts ordered by ID ascending
            let accounts = try await accountRepository.findAll(page: page, pageSize: pageSize)

            // Empty page signals we have reached the end of the account universe
            if accounts.isEmpty {
                logger.info("Reached end of account universe at page \(page)")
                break
            }

            // Extract account IDs for batch position loading
            let accountIds = accounts.map { $0.id }

            // Load all positions for this page of accounts
            let positions = try await positionRepository.findByAccountIds(accountIds)

            // Compute valuations — pure computation using preloaded reference data
            let pageValuations = try valuateAccountBatch(
                accounts: accounts,
                positions: positions,
                referenceDataLookup: referenceDataLookup
            )

            // Rule 11: Atomic cached valuation write within a single transaction
            try await writeCachedValuationsAtomically(pageValuations)

            let totalSoFar = allResults.count + pageValuations.count
            allResults.append(contentsOf: pageValuations)
            logger.info("Page \(page) complete: \(pageValuations.count) accounts valued (total so far: \(totalSoFar))")

            page += 1
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedFmt = String(format: "%.2f", elapsed)
        logger.info("Full-universe valuation complete: \(allResults.count) accounts valued in \(elapsedFmt)s")

        return allResults
    }

    /// Runs NAV valuation for a single account.
    ///
    /// Convenience method for valuing one account. Loads the account, its positions,
    /// and EOD reference data, then computes NAV and writes the cached valuation
    /// atomically (Rule 11). Uses the account's stored IANA timezone for value date
    /// computation (Rule 3).
    ///
    /// - Parameters:
    ///   - accountId: The primary key of the account to value.
    ///   - marketDate: The market date for EOD price retrieval.
    /// - Returns: The ``Valuation`` result for the specified account.
    /// - Throws: ``AppError/accountNotFound`` if the account ID doesn't exist,
    ///   ``AppError/invalidTimezone`` if the account has an invalid IANA timezone,
    ///   or database errors from repository operations.
    public func runSingleAccountValuation(
        accountId: UInt64,
        marketDate: Date
    ) async throws -> Valuation {
        logger.info("Starting single-account valuation for account \(accountId) on market date \(marketDate)")
        let startTime = Date()

        // Load the account by ID — throw if not found
        let accounts = try await accountRepository.findByIds([accountId])
        guard let account = accounts.first else {
            logger.error("Account \(accountId) not found")
            throw AppError.accountNotFound
        }

        // Load all positions for this account
        let positions = try await positionRepository.findByAccountId(accountId)

        // Load EOD reference data for the market date, converting
        // Persistence.ReferenceData to ReferenceDataService.ReferenceData
        let referenceDataLookup = try await buildReferenceDataLookup(for: marketDate)

        // Separate cash positions and compute cash balance
        let cashBalance = extractCashBalance(from: positions)

        // Delegate NAV computation to the pure calculation engine.
        // NAVCalculator expects Persistence.Position (matches repository output)
        // and ReferenceDataService.ReferenceData (converted in buildReferenceDataLookup).
        let navAmount = navCalculator.computeNAV(
            positions: positions,
            referenceData: referenceDataLookup,
            cashBalance: cashBalance
        )

        // Rule 3: Compute value date using the account's stored IANA timezone.
        // NEVER use TimeZone.current or Calendar.current.
        let valueDate = try computeValueDate(for: account)

        let valuation = Valuation(
            accountId: account.id,
            valueAmount: navAmount,
            valueDate: valueDate,
            timezone: account.valuationTimezone,
            positionsValued: positions.count
        )

        // Rule 11: Atomic cached valuation write within a DB transaction
        try await writeCachedValuationsAtomically([valuation])

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedStr = String(format: "%.3f", elapsed)
        logger.info("Single-account valuation complete for account \(accountId): value=\(navAmount), tz=\(account.valuationTimezone), positions=\(positions.count), elapsed=\(elapsedStr)s")

        return valuation
    }

    // MARK: - Private Helpers

    /// Valuates a batch of accounts against preloaded reference data.
    ///
    /// Groups positions by account ID, computes NAV per account via ``NAVCalculator``,
    /// and derives timezone-aware value dates using each account's stored IANA timezone
    /// (Rule 3). This is a pure computation method with no database calls — all data
    /// must be preloaded by the caller.
    ///
    /// - Parameters:
    ///   - accounts: Already-loaded batch of accounts (max 1,000 per Rule 7).
    ///   - positions: All positions for the batch, loaded via
    ///     ``PositionRepository/findByAccountIds(_:)``.
    ///   - referenceDataLookup: Preloaded EOD reference data dictionary keyed by
    ///     instrument ID, using ``ReferenceData`` type from the ReferenceDataService module.
    /// - Returns: Array of ``Valuation`` results, one per account.
    /// - Throws: ``AppError/invalidTimezone`` if any account has an invalid timezone.
    private func valuateAccountBatch(
        accounts: [Account],
        positions: [Position],
        referenceDataLookup: [UInt64: ReferenceData]
    ) throws -> [Valuation] {
        // Group positions by accountId for O(1) lookup per account.
        // This avoids repeated linear scans through the full position list.
        var positionsByAccount: [UInt64: [Position]] = [:]
        for position in positions {
            positionsByAccount[position.accountId, default: []].append(position)
        }

        var valuations: [Valuation] = []
        valuations.reserveCapacity(accounts.count)

        for account in accounts {
            let accountPositions = positionsByAccount[account.id] ?? []

            // Separate cash positions from equity positions for NAV computation.
            // Cash positions are valued at AppConstants.cashPrice (1.00).
            let cashBalance = extractCashBalance(from: accountPositions)

            // Delegate NAV computation to NAVCalculator.
            // The calculator iterates equity positions, computes midpoints from
            // reference data, and adds the cash balance. Positions without
            // matching reference data are skipped gracefully.
            let navAmount = navCalculator.computeNAV(
                positions: accountPositions,
                referenceData: referenceDataLookup,
                cashBalance: cashBalance
            )

            // Rule 3: Compute value date using the account's stored IANA timezone.
            // Each account may have a different timezone (e.g., "America/New_York"
            // vs "Europe/London"), producing distinct value dates for the same
            // UTC instant when the clock falls between their midnight boundaries.
            let valueDate = try computeValueDate(for: account)

            let valuation = Valuation(
                accountId: account.id,
                valueAmount: navAmount,
                valueDate: valueDate,
                timezone: account.valuationTimezone,
                positionsValued: accountPositions.count
            )

            valuations.append(valuation)

            logger.debug("Valued account \(account.id): NAV=\(navAmount), date=\(valueDate), tz=\(account.valuationTimezone), positions=\(accountPositions.count)")
        }

        return valuations
    }

    /// Writes cached valuation results atomically to the accounts table.
    ///
    /// **Rule 11 — Cached Valuation Denormalization (CRITICAL)**:
    /// All updates within a batch are executed within a single DB transaction
    /// via ``ConnectionPool/withTransaction(_:)``. This ensures that either all
    /// cached values are updated or none are, maintaining consistency between
    /// the valuation results and the accounts table.
    ///
    /// The method captures only `Sendable` local bindings in the `@Sendable`
    /// closure to satisfy Swift 6 strict concurrency requirements (Gate 2).
    ///
    /// - Parameter valuations: Array of ``Valuation`` results to cache.
    ///   Empty arrays are handled with a short-circuit return.
    /// - Throws: Database constraint or execution errors propagated from
    ///   ``AccountRepository/updateCachedValuation(accountId:valuationAmount:valueDate:on:)``.
    private func writeCachedValuationsAtomically(
        _ valuations: [Valuation]
    ) async throws {
        // Short-circuit: nothing to write
        guard !valuations.isEmpty else { return }

        // Capture immutable Sendable bindings for the @Sendable @escaping closure.
        // Swift 6 strict concurrency requires all captured values to be Sendable.
        // [Valuation] is Sendable (Valuation: Sendable struct).
        // AccountRepository is Sendable (final class with let properties).
        // Logger is Sendable (swift-log guarantee).
        let valuationsToWrite = valuations
        let accountRepo = self.accountRepository
        let log = self.logger

        try await connectionPool.withTransaction { database in
            for valuation in valuationsToWrite {
                try await accountRepo.updateCachedValuation(
                    accountId: valuation.accountId,
                    valuationAmount: valuation.valueAmount,
                    valueDate: valuation.valueDate,
                    on: database
                )
            }
            log.debug("Atomic cached valuation write completed for \(valuationsToWrite.count) accounts")
        }
    }

    /// Builds a reference data lookup dictionary for a given market date.
    ///
    /// Loads all reference data entries from ``ReferenceDataRepository`` for the
    /// specified market date, then converts each Persistence-layer reference data
    /// entry to ``ReferenceData`` (the ReferenceDataService module type expected by
    /// ``NAVCalculator``).
    ///
    /// The resulting dictionary is keyed by reference data ID (`UInt64`) for O(1)
    /// price lookup during NAV computation. This avoids repeated database queries
    /// per instrument during batch valuation (Rule 13 performance optimization).
    ///
    /// Both the Persistence and ReferenceDataService ReferenceData types share
    /// identical stored properties (`id`, `ticker`, `name`, `sodBid`, `sodAsk`,
    /// `eodBid`, `eodAsk`, `marketDate`), making conversion straightforward.
    ///
    /// - Parameter marketDate: The market date for which to load EOD prices.
    /// - Returns: Dictionary mapping reference data ID to ``ReferenceData``.
    /// - Throws: Database errors from the repository query.
    private func buildReferenceDataLookup(
        for marketDate: Date
    ) async throws -> [UInt64: ReferenceData] {
        // Load all reference data for the market date from the Persistence layer.
        // The return type is inferred as [Persistence.ReferenceData] from the
        // repository method signature. We use type inference to avoid needing
        // to explicitly name the Persistence.ReferenceData type.
        let dbRefData = try await referenceDataRepository.findByDate(marketDate)

        // Convert each Persistence-layer entry to ReferenceDataService.ReferenceData
        // and build the dictionary keyed by ID for O(1) lookup during NAV computation.
        var lookup: [UInt64: ReferenceData] = [:]
        lookup.reserveCapacity(dbRefData.count)

        for entry in dbRefData {
            let serviceEntry = ReferenceData(
                id: entry.id,
                ticker: entry.ticker,
                name: entry.name,
                sodBid: entry.sodBid,
                sodAsk: entry.sodAsk,
                eodBid: entry.eodBid,
                eodAsk: entry.eodAsk,
                marketDate: entry.marketDate
            )
            lookup[entry.id] = serviceEntry
        }

        return lookup
    }

    /// Computes the value date for an account using its stored IANA timezone.
    ///
    /// **Rule 3 — Per-Account Valuation Timezone (CRITICAL)**:
    /// This method MUST use the account's stored IANA timezone string — never
    /// `TimeZone.current`, `Calendar.current`, or any system-derived timezone.
    ///
    /// Delegates to ``Date/valueDateForTimezone(_:)`` from the `Shared` module,
    /// which creates a fresh `Calendar(identifier: .gregorian)`, sets its timezone
    /// from the account's IANA string, extracts year/month/day components, and
    /// returns the start-of-day `Date` in that timezone.
    ///
    /// **Verification**: Two accounts configured for `"America/New_York"` and
    /// `"Europe/London"` will produce distinct value dates when the current UTC
    /// time falls between midnight London and midnight New York.
    ///
    /// - Parameter account: The account whose stored timezone determines the value date.
    /// - Returns: The computed value date in the account's timezone.
    /// - Throws: ``AppError/invalidTimezone`` if the account's IANA timezone string
    ///   cannot be resolved to a valid `TimeZone`.
    private func computeValueDate(for account: Account) throws -> Date {
        do {
            // Rule 3: Use the account's stored IANA timezone string exclusively.
            // The valueDateForTimezone method creates a fresh Calendar with
            // .gregorian identifier and sets its timezone — never using the
            // system default timezone.
            return try Date().valueDateForTimezone(account.valuationTimezone)
        } catch {
            // Map DateTimezoneError.invalidTimezone(String) to the domain-specific
            // AppError.invalidTimezone for consistent error handling across modules.
            logger.error("Invalid timezone '\(account.valuationTimezone)' for account \(account.id): \(error)")
            throw AppError.invalidTimezone
        }
    }

    /// Extracts the cash balance from a set of positions.
    ///
    /// Cash positions are identified by an `assetType` value of `"cash"`
    /// (case-insensitive comparison). The cash balance is the sum of all cash
    /// position quantities multiplied by ``AppConstants/cashPrice`` (fixed at 1.00),
    /// as specified by the closed-book NAV formula.
    ///
    /// If no cash positions exist (e.g., when Rule 5 restricts all positions to
    /// equities), the cash balance defaults to `Decimal.zero`. This ensures the
    /// NAV formula gracefully handles accounts with only equity positions:
    /// `NAV = Σ(quantity × EOD midpoint) + 0`.
    ///
    /// - Parameter positions: Array of positions for a single account.
    /// - Returns: The computed cash balance as a `Decimal`.
    private func extractCashBalance(from positions: [Position]) -> Decimal {
        var cashBalance = Decimal.zero
        for position in positions {
            if position.assetType.lowercased() == "cash" {
                // Cash positions are valued at the fixed cash price (1.00).
                // Value = quantity × cashPrice = quantity × 1.00 = quantity.
                cashBalance += position.quantity * AppConstants.cashPrice
            }
        }
        return cashBalance
    }
}
