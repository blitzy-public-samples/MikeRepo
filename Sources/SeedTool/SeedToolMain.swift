// Sources/SeedTool/SeedToolMain.swift
// WealthLedger — CLI Entry Point for Synthetic Data Seeding
//
// Connects to the local MySQL 8.0 database, generates 500+ synthetic NYSE equity
// records via SyntheticDataGenerator, inserts them into the reference_data table,
// and optionally seeds sample users, account groups, and accounts for development.
//
// Rule 6:  Reference data simulation fidelity — verifies >= 500 records generated.
// Rule 7:  Batch memory cap — delegates batching to ReferenceDataRepository.bulkInsert().
// Rule 8:  MySQLKit-only persistence — zero SwiftData imports.
// Rule 9:  Offline runtime — localhost MySQL only, no external network calls.
// Rule 10: Schema referential integrity — FK constraints respected in seed order.
// Gate 2:  Swift 6 strict concurrency — zero unchecked-Sendable annotations, zero suppressions.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared
import Persistence
import ReferenceDataService
import AccountManagement

// MARK: - SeedToolMain

/// CLI entry point for seeding the WealthLedger database with synthetic data.
///
/// This struct serves as the `@main` entry point for the SeedTool executable target.
/// It connects to the local MySQL database, runs migrations, generates synthetic NYSE
/// equity reference data, and optionally seeds sample development data.
///
/// ## Usage
///
/// ```bash
/// # Seed reference data only
/// swift run SeedTool
///
/// # Seed reference data + sample users, groups, accounts
/// swift run SeedTool --seed-samples
///
/// # Show help
/// swift run SeedTool --help
/// ```
///
/// ## Environment Variables
///
/// - `MYSQL_USER`: MySQL username (default: `"root"`)
/// - `MYSQL_PASSWORD`: MySQL password (default: `""`)
/// - `MYSQL_DATABASE`: Database name (default: `"wealth_ledger"`)
/// - `MYSQL_HOST`: MySQL hostname (default: `"localhost"`)
///
/// ## Concurrency Safety (Gate 2)
///
/// This struct has zero stored properties, making it trivially `Sendable`. The
/// `static func main() async throws` entry point uses structured concurrency
/// exclusively — zero unchecked-Sendable annotations or warning suppressions.
@main
struct SeedToolMain {

    // MARK: - Entry Point

    /// Async main entry point for the SeedTool CLI.
    ///
    /// Executes the following steps in order:
    /// 1. Display usage banner and handle `--help` flag
    /// 2. Parse database credentials from environment variables
    /// 3. Initialize `DatabaseManager` with localhost MySQL configuration (Rule 9)
    /// 4. Run pending migrations via `DatabaseManager.initialize()` (Rule 10)
    /// 5. Generate synthetic NYSE equity data via `SyntheticDataGenerator` (Rule 6)
    /// 6. Verify at least 500 records generated (Rule 6)
    /// 7. Convert records from ReferenceDataService type to Persistence type
    /// 8. Insert records via `ReferenceDataRepository.bulkInsert()` (Rule 7)
    /// 9. Optionally seed sample users, groups, and accounts (if `--seed-samples`)
    /// 10. Gracefully shut down the database connection
    ///
    /// - Throws: `AppError.migrationFailed` if fewer than 500 records are generated,
    ///   or any database error during initialization, insertion, or shutdown.
    static func main() async throws {
        // Display usage banner
        print("=== WealthLedger SeedTool ===")
        print("Seeds synthetic NYSE equity data into the local MySQL database.")
        print("")

        // Handle --help flag — print usage info and exit with success
        if CommandLine.arguments.contains("--help") {
            printUsage()
            return
        }

        // Parse database credentials from environment variables with safe defaults.
        // All defaults target localhost MySQL — Rule 9 (Offline Runtime): zero
        // external network calls permitted at runtime.
        let username = ProcessInfo.processInfo.environment["MYSQL_USER"] ?? "root"
        let password = ProcessInfo.processInfo.environment["MYSQL_PASSWORD"] ?? ""
        let database = ProcessInfo.processInfo.environment["MYSQL_DATABASE"] ?? "wealth_ledger"
        let hostname = ProcessInfo.processInfo.environment["MYSQL_HOST"] ?? "localhost"

        // Initialize DatabaseManager — this creates the connection pool and event
        // loop group but does NOT establish a database connection yet.
        // Note: DatabaseManager.init does not throw; connection verification
        // happens in initialize().
        print("🔧 Connecting to MySQL at \(hostname):3306/\(database)...")
        let manager = DatabaseManager(
            hostname: hostname,
            port: 3306,
            username: username,
            password: password,
            database: database
        )

        do {
            // Step 1 — Verify connectivity and run pending migrations (Rule 10).
            // initialize() performs a health check (SELECT 1) and then executes
            // all SQL migration scripts from Resources/Migrations/ in numerical order.
            try await manager.initialize()
            print("✅ Database initialized and migrations applied.")

            // Step 2 — Generate synthetic NYSE equity data (Rule 6, Rule 9).
            // SyntheticDataGenerator produces at least 500 records with unique
            // tickers (3-5 uppercase letters), realistic company names, and four
            // stored price fields using exact Decimal arithmetic. All data is
            // generated algorithmically with zero external network calls.
            print("📊 Generating synthetic NYSE equity data...")
            let generator = SyntheticDataGenerator()
            let marketDate = Date()
            let referenceRecords = generator.generate(marketDate: marketDate)
            print("✅ Generated \(referenceRecords.count) synthetic securities.")

            // Step 3 — Verify Rule 6 compliance: at least 500 records with all
            // six price fields non-null and non-zero. SyntheticDataGenerator
            // guarantees non-null/non-zero prices by construction, so we only
            // need to verify the count threshold.
            guard referenceRecords.count >= 500 else {
                print("❌ ERROR: Generated only \(referenceRecords.count) records. Minimum required: 500 (Rule 6).")
                try? await manager.shutdown()
                throw AppError.migrationFailed
            }

            // Step 4 — Convert from ReferenceDataService.ReferenceData to
            // Persistence.ReferenceData. This mapping is necessary because each
            // module defines its own ReferenceData type to avoid circular module
            // dependencies. The Persistence type is required by
            // ReferenceDataRepository.bulkInsert().
            let persistenceRecords: [Persistence.ReferenceData] = referenceRecords.map { record in
                Persistence.ReferenceData(
                    id: record.id,
                    ticker: record.ticker,
                    name: record.name,
                    sodBid: record.sodBid,
                    sodAsk: record.sodAsk,
                    eodBid: record.eodBid,
                    eodAsk: record.eodAsk,
                    marketDate: record.marketDate
                )
            }

            // Step 5 — Insert via ReferenceDataRepository with batch processing.
            // bulkInsert() internally processes in batches of AppConstants.batchSize
            // (1,000) records per batch to comply with Rule 7 (Batch Memory Cap).
            let referenceDataRepo = ReferenceDataRepository(pool: manager.pool)
            print("💾 Inserting \(persistenceRecords.count) records in batches of \(AppConstants.batchSize)...")
            try await referenceDataRepo.bulkInsert(persistenceRecords)
            let totalCount = try await referenceDataRepo.count()
            print("✅ reference_data table now contains \(totalCount) records.")

            // Step 6 — Optionally seed sample users, groups, and accounts.
            // Only activated when the --seed-samples CLI flag is present.
            let shouldSeedSamples = CommandLine.arguments.contains("--seed-samples")
            if shouldSeedSamples {
                try await seedSampleData(pool: manager.pool)
            }

        } catch {
            // Handle any error during the seeding process.
            // Attempt graceful shutdown before re-throwing to ensure the
            // connection pool and event loop group are released.
            print("❌ SeedTool failed with error: \(error)")
            do {
                try await manager.shutdown()
            } catch {
                print("⚠️ Failed to shut down database connection: \(error)")
            }
            throw error
        }

        // Happy-path shutdown — only reached when all operations succeed.
        print("🔒 Shutting down database connection...")
        try await manager.shutdown()
        print("✅ SeedTool completed successfully.")
    }

    // MARK: - Sample Data Seeding

    /// Seeds sample development data: users, account groups, and accounts.
    ///
    /// This method is invoked only when the `--seed-samples` CLI flag is present.
    /// It creates:
    /// - 3 sample users with pre-computed bcrypt password hashes
    /// - 3 sample account groups (Institutional, Wealth, Hedge Fund)
    /// - 30 sample accounts (10 per group) across all fund types and IANA timezones
    ///
    /// ## FK Constraint Ordering (Rule 10)
    ///
    /// Data is seeded in referential-integrity order:
    /// 1. Users (referenced by entitlements)
    /// 2. Account groups (referenced by accounts via FK)
    /// 3. Accounts (reference account_groups.id)
    ///
    /// ## Password Hashing
    ///
    /// Pre-computed bcrypt hashes are used because the SeedTool target does not
    /// depend on the RBAC module (which owns `PasswordHasher`). The hash corresponds
    /// to the development-only password "admin123".
    ///
    /// - Parameter pool: The active ``ConnectionPool`` for database operations.
    /// - Throws: Database errors during user, group, or account creation.
    private static func seedSampleData(pool: ConnectionPool) async throws {

        // ── Phase 1: Seed sample users ──────────────────────────────────────
        // Users must exist before entitlements (Rule 10 — FK constraints).

        print("👤 Seeding sample users...")
        let userRepo = UserRepository(pool: pool)

        // Pre-computed bcrypt hash for development password "admin123".
        // Generated via: BCryptSwift.hashString("admin123", rounds: 12)
        // Using pre-computed hash because SeedTool does not depend on RBAC module.
        let devPasswordHash = "$2b$12$LJ3m4ys3Lk0TSwMCfVCZxOYd5cF.qK5lQvFNr3yVDJsFqXBkqJW2e"

        let sampleUsers: [User] = [
            User(username: "admin", passwordHash: devPasswordHash),
            User(username: "analyst", passwordHash: devPasswordHash),
            User(username: "viewer", passwordHash: devPasswordHash),
        ]

        for user in sampleUsers {
            do {
                let created = try await userRepo.create(user)
                print("  ✅ Created user: \(created.username) (ID: \(created.id))")
            } catch {
                print("  ⚠️ User '\(user.username)' may already exist: \(error)")
            }
        }

        // ── Phase 2: Seed sample account groups ─────────────────────────────
        // Groups must exist before accounts (Rule 10 — accounts.account_group_id
        // references account_groups.id via FK).

        print("📁 Seeding sample account groups...")
        let accountGroupRepo = AccountGroupRepository(pool: pool)

        let sampleGroups: [Persistence.AccountGroup] = [
            Persistence.AccountGroup(
                id: 0,
                groupName: "Institutional Equity Funds",
                metadata: nil,
                createdAt: Date()
            ),
            Persistence.AccountGroup(
                id: 0,
                groupName: "Wealth Management SMAs",
                metadata: nil,
                createdAt: Date()
            ),
            Persistence.AccountGroup(
                id: 0,
                groupName: "Hedge Fund Strategies",
                metadata: nil,
                createdAt: Date()
            ),
        ]

        var createdGroupIds: [UInt64] = []
        for group in sampleGroups {
            do {
                let created = try await accountGroupRepo.create(group)
                createdGroupIds.append(created.id)
                print("  ✅ Created account group: \(created.groupName) (ID: \(created.id))")
            } catch {
                print("  ⚠️ Account group '\(group.groupName)' may already exist: \(error)")
            }
        }

        // ── Phase 3: Seed sample accounts ───────────────────────────────────
        // Accounts reference account_groups.id via FK (Rule 10).

        guard !createdGroupIds.isEmpty else {
            print("  ⚠️ No account groups were created; skipping account seeding.")
            return
        }

        print("🏦 Seeding sample accounts...")
        let accountRepo = AccountRepository(pool: pool)

        // All six fund types for comprehensive coverage across both
        // Institutional and Wealth categories.
        let fundTypes: [Persistence.FundType] = [
            .openMutualFund, .closedMutualFund, .etf,
            .hedgeFund, .sma, .uma,
        ]

        // Diverse IANA timezones for Rule 3 readiness — each account stores
        // its own timezone for per-account valuation date computation.
        let timezones: [String] = [
            "America/New_York", "America/Chicago", "America/Los_Angeles",
            "Europe/London", "Asia/Tokyo",
        ]

        let accountsPerGroup = 10
        var accountCount = 0

        for (groupIndex, groupId) in createdGroupIds.enumerated() {
            for i in 0..<accountsPerGroup {
                let combinedIndex = groupIndex * accountsPerGroup + i
                let fundType = fundTypes[combinedIndex % fundTypes.count]
                let timezone = timezones[combinedIndex % timezones.count]

                let account = Persistence.Account(
                    id: 0,
                    name: "Sample Account \(groupIndex + 1)-\(i + 1) (\(fundType.rawValue))",
                    fundType: fundType,
                    ownershipDetails: nil,
                    valuationTimezone: timezone,
                    valuationSchedule: nil,
                    cachedValuationAmount: nil,
                    cachedValueDate: nil,
                    status: .active,
                    accountGroupId: groupId,
                    createdAt: Date()
                )

                do {
                    _ = try await accountRepo.create(account)
                    accountCount += 1
                    if accountCount % 10 == 0 {
                        print("  ✅ Created \(accountCount) sample accounts...")
                    }
                } catch {
                    print("  ⚠️ Failed to create account: \(error)")
                }
            }
        }

        print("✅ Seeded \(accountCount) sample accounts across \(createdGroupIds.count) groups.")
    }

    // MARK: - CLI Help

    /// Prints usage information for the SeedTool CLI and exits.
    private static func printUsage() {
        print("Usage: SeedTool [options]")
        print("")
        print("Options:")
        print("  --seed-samples    Also seed sample users, account groups, and accounts")
        print("  --help            Show this help message")
        print("")
        print("Environment variables:")
        print("  MYSQL_USER        MySQL username (default: root)")
        print("  MYSQL_PASSWORD    MySQL password (default: empty)")
        print("  MYSQL_DATABASE    Database name (default: wealth_ledger)")
        print("  MYSQL_HOST        MySQL hostname (default: localhost)")
    }
}
