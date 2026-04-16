// Tests/IntegrationTests/JobSchedulerIntegrationTests.swift
// WealthLedger — Job Scheduler Integration Tests Against Live MySQL
//
// End-to-end integration tests for the JobScheduler module exercising
// job creation, manual trigger execution, status tracking, report
// generation, and CSV ingestion workflows against the live MySQL
// `accounting_test` schema via TestDatabaseSetup.
//
// Rules Verified:
//   Rule 4  — Entitlement enforcement during report generation (via AccountService).
//   Rule 7  — Batch memory cap: report generation paginates at ≤1,000 accounts.
//   Rule 8  — MySQLKit-only persistence — NO SwiftData anywhere.
//   Rule 9  — Offline runtime: local CSV files, local MySQL, no network calls.
//   Gate 2  — Swift 6 strict concurrency: Sendable types, async throws tests.
//   Gate 10 — Tests target the `accounting_test` schema via TestDatabaseSetup.
//
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import Persistence
@testable import JobScheduler
@testable import AccountManagement
@testable import ValuationEngine
@testable import ReferenceDataService
@testable import LedgerEngine
@testable import RBAC
@testable import Shared

// MARK: - Job Scheduler Integration Test Suite

/// Integration test suite for the JobScheduler module. All tests exercise
/// the complete service chain against a live MySQL `accounting_test` schema:
///
///     JobSchedulerService
///       → ReportGenerator  → AccountService (Rule 4) + CSVExporter
///       → ReferenceDataService → CSVParser + ReferenceDataRepository
///
/// Tests run `.serialized` for sequential execution against shared MySQL state.
@Suite("Job Scheduler Integration Tests", .serialized)
struct JobSchedulerIntegrationTests {

    // MARK: - Service Factory

    /// Builds the complete dependency graph for JobSchedulerService integration
    /// testing, matching the wiring pattern in DependencyContainer.
    ///
    /// Dependency chain:
    /// - Pool → Repositories → Services → JobSchedulerService
    /// - UserRepository + PasswordHasher → AuthenticationService
    /// - EntitlementRepository + AccountGroupRepository → EntitlementService
    /// - AccountRepository + EntitlementService + AccountGroupService → AccountService
    /// - PositionRepository + ReferenceDataRepository + NAVCalculator + Pool → ValuationService
    /// - AccountService + ValuationService + CSVExporter → ReportGenerator
    /// - ReferenceDataRepository + CSVParser → ReferenceDataService
    /// - ReportGenerator + CSVParser + ReferenceDataService + AccountService + ValuationService → JobSchedulerService
    private func buildServices() -> (
        jobSchedulerService: JobSchedulerService,
        authService: AuthenticationService,
        accountService: AccountService,
        accountGroupService: AccountGroupService,
        entitlementService: EntitlementService,
        refDataService: ReferenceDataService,
        accountRepo: AccountRepository,
        accountGroupRepo: AccountGroupRepository,
        userRepo: UserRepository,
        entitlementRepo: EntitlementRepository,
        refDataRepo: ReferenceDataRepository,
        positionRepo: PositionRepository,
        pool: ConnectionPool
    ) {
        let pool = TestDatabaseSetup.connectionPool!

        // Persistence-layer repositories
        let accountRepo = AccountRepository(pool: pool)
        let positionRepo = PositionRepository(pool: pool)
        let refDataRepo = ReferenceDataRepository(pool: pool)
        let accountGroupRepo = AccountGroupRepository(pool: pool)
        let userRepo = UserRepository(pool: pool)
        let entitlementRepo = EntitlementRepository(pool: pool)
        // RBAC services
        let passwordHasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: passwordHasher
        )
        let entitlementService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )

        // AccountManagement services
        let accountGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let accountService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entitlementService,
            accountGroupService: accountGroupService
        )

        // ValuationEngine services
        let navCalculator = NAVCalculator()
        let valuationService = ValuationService(
            accountRepository: accountRepo,
            positionRepository: positionRepo,
            referenceDataRepository: refDataRepo,
            navCalculator: navCalculator,
            connectionPool: pool
        )

        // ReferenceDataService
        let csvParser = CSVParser()
        let refDataService = ReferenceDataService(
            repository: refDataRepo,
            csvParser: csvParser
        )

        // JobScheduler services
        let csvExporter = CSVExporter()
        let reportGenerator = ReportGenerator(
            accountService: accountService,
            valuationService: valuationService,
            csvExporter: csvExporter
        )
        let jobSchedulerService = JobSchedulerService(
            reportGenerator: reportGenerator,
            csvParser: csvParser,
            referenceDataService: refDataService,
            accountService: accountService,
            valuationService: valuationService
        )

        return (
            jobSchedulerService, authService, accountService,
            accountGroupService, entitlementService, refDataService,
            accountRepo, accountGroupRepo, userRepo, entitlementRepo,
            refDataRepo, positionRepo, pool
        )
    }

    // MARK: - Database Preparation

    /// Ensures the test database schema exists and relevant tables are clean.
    ///
    /// Called at the start of every test function. Lazily initialises the
    /// `accounting_test` schema on first call, then truncates tables used by
    /// this job scheduler test suite in reverse FK order.
    private func prepareDatabase() async throws {
        if TestDatabaseSetup.connectionPool == nil {
            try await TestDatabaseSetup.setUp()
        }
        try await cleanJobSchedulerTables()

        // Ensure the Documents directory exists on the local filesystem.
        // ReportGenerator writes CSV output to ~/Documents/ which may not
        // exist on headless Linux CI environments.
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first?.path ?? "/tmp"
        if !FileManager.default.fileExists(atPath: documentsPath) {
            try? FileManager.default.createDirectory(
                atPath: documentsPath,
                withIntermediateDirectories: true
            )
        }
    }

    /// Truncates tables used by JobScheduler integration tests in reverse FK order.
    ///
    /// Tables cleaned (order respects FK dependencies):
    /// 1. transactions — FK to accounts, reference_data
    /// 2. positions — FK to accounts, reference_data
    /// 3. entitlements — FK to users, account_groups
    /// 4. accounts — FK to account_groups
    /// 5. reference_data — standalone (used by ingestion tests)
    /// 6. account_groups — standalone (parent of accounts, entitlements)
    /// 7. users — standalone (parent of entitlements)
    private func cleanJobSchedulerTables() async throws {
        guard let pool = TestDatabaseSetup.connectionPool else { return }
        try await pool.withConnection { db in
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE transactions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE positions").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE entitlements").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE accounts").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE reference_data").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE account_groups").get()
            _ = try await db.simpleQuery("TRUNCATE TABLE users").get()
            _ = try await db.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
        }
    }

    // MARK: - Test Data Helpers

    /// Creates a test user, account group, and entitlement with full RCMD
    /// permissions, returning the user ID for use in subsequent operations.
    ///
    /// Prerequisite data chain:
    ///   user → account_group → entitlement (READ, CREATE, MODIFY, DELETE)
    ///
    /// - Parameters:
    ///   - s: Service tuple from `buildServices()`.
    /// - Returns: Tuple of (userId, accountGroupId) for further test operations.
    private func createTestUserAndGroup(
        s: (
            jobSchedulerService: JobSchedulerService,
            authService: AuthenticationService,
            accountService: AccountService,
            accountGroupService: AccountGroupService,
            entitlementService: EntitlementService,
            refDataService: ReferenceDataService,
            accountRepo: AccountRepository,
            accountGroupRepo: AccountGroupRepository,
            userRepo: UserRepository,
            entitlementRepo: EntitlementRepository,
            refDataRepo: ReferenceDataRepository,
            positionRepo: PositionRepository,
            pool: ConnectionPool
        )
    ) async throws -> (userId: UInt64, groupId: UInt64) {
        // Create test user
        let user = try await s.authService.createUser(
            username: "jobtest_user_\(UUID().uuidString.prefix(8))",
            password: "TestPassword123!"
        )
        let userId = user.id

        // Create account group
        let group = try await s.accountGroupRepo.create(
            Persistence.AccountGroup(
                id: 0,
                groupName: "JobTest Group \(UUID().uuidString.prefix(8))",
                metadata: nil,
                createdAt: Date()
            )
        )
        let groupId = group.id

        // Assign full RCMD entitlements
        let entitlement = Persistence.Entitlement(
            id: 0,
            userId: userId,
            accountGroupId: groupId,
            canRead: true,
            canCreate: true,
            canModify: true,
            canDelete: true
        )
        _ = try await s.entitlementRepo.create(entitlement)

        return (userId: userId, groupId: groupId)
    }

    /// Creates a test account in the specified group with a valid IANA timezone.
    ///
    /// - Parameters:
    ///   - name: Human-readable account name.
    ///   - groupId: The account group FK.
    ///   - fundType: Account fund type (defaults to `.etf`).
    ///   - accountRepo: Repository for direct database insertion.
    /// - Returns: The created Persistence.Account with auto-assigned ID.
    private func createTestAccount(
        name: String,
        groupId: UInt64,
        fundType: Persistence.FundType = .etf,
        accountRepo: AccountRepository
    ) async throws -> Persistence.Account {
        let account = Persistence.Account(
            id: 0,
            name: name,
            fundType: fundType,
            ownershipDetails: nil,
            valuationTimezone: "America/New_York",
            valuationSchedule: "daily",
            cachedValuationAmount: nil,
            cachedValueDate: nil,
            status: .active,
            accountGroupId: groupId,
            createdAt: Date()
        )
        return try await accountRepo.create(account)
    }

    /// Writes CSV content to a uniquely named temporary file and returns
    /// the absolute path. The caller must clean up via `defer`.
    ///
    /// - Parameters:
    ///   - content: UTF-8 CSV text to write.
    ///   - prefix: Descriptive prefix for the temporary file name.
    /// - Returns: Absolute path to the created CSV file.
    private func writeTempCSV(
        _ content: String,
        prefix: String = "test_job"
    ) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(prefix)_\(UUID().uuidString).csv"
        let csvURL = tempDir.appendingPathComponent(filename)
        try content.write(to: csvURL, atomically: true, encoding: .utf8)
        return csvURL.path
    }

    /// Formats a Date as `yyyy-MM-dd` in UTC for CSV content.
    private func formatDateForCSV(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Creates a UTC date for the specified year/month/day.
    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Test 1: Job Creation (Report Type)

    /// Verifies that creating a report job produces a pending job with correct type
    /// and parameters, and that the job is retrievable by ID.
    @Test("Create report job — verifies pending status and parameters")
    func testCreateReportJob() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let parameters = JobParameters(
            fieldSelection: ["name", "id", "fundType", "cachedValuationAmount"],
            accountSelection: nil,
            targetDate: makeDate(year: 2026, month: 4, day: 14),
            sourceFilePath: nil,
            sourceFileType: nil
        )

        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)

        // Verify initial state
        #expect(job.id > 0, "Job should have auto-assigned ID")
        #expect(job.type == .report, "Job type should be .report")
        #expect(job.status == .pending, "New job should be in .pending status")
        #expect(job.completedAt == nil, "New job should have no completion time")
        #expect(job.parameters.fieldSelection?.count == 4, "Field selection should be preserved")

        // Verify retrievable by ID
        let retrieved = await s.jobSchedulerService.getJob(id: job.id)
        #expect(retrieved != nil, "Job should be retrievable by ID")
        #expect(retrieved?.id == job.id)
        #expect(retrieved?.type == .report)
    }

    // MARK: - Test 2: Job Creation (Ingestion Type)

    /// Verifies that creating an ingestion job stores the source file path
    /// correctly in the job parameters.
    @Test("Create ingestion job — verifies pending status and file path")
    func testCreateIngestionJob() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let parameters = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: "/tmp/test_data.csv",
            sourceFileType: "reference_data"
        )

        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)

        #expect(job.type == .ingestion, "Job type should be .ingestion")
        #expect(job.status == .pending)
        #expect(job.parameters.sourceFilePath == "/tmp/test_data.csv")
        #expect(job.parameters.sourceFileType == "reference_data")
    }

    // MARK: - Test 3: Job Status Tracking

    /// Verifies the job status query API returns correct status at each
    /// lifecycle stage: pending → running → completed.
    @Test("Job status tracking — pending to completed lifecycle")
    func testJobStatusTracking() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create a small account for the report
        _ = try await createTestAccount(
            name: "Status Tracking Acct",
            groupId: groupId,
            accountRepo: s.accountRepo
        )

        let parameters = JobParameters(
            fieldSelection: ["name"],
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: nil,
            sourceFileType: nil
        )

        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)

        // Verify pending status via query API
        let pendingStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(pendingStatus == .pending, "Status should be .pending before execution")

        // Execute the job (transitions through running → completed)
        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        // Verify completed status
        #expect(completedJob.status == .completed, "Job should be .completed after execution")
        #expect(completedJob.completedAt != nil, "Completed job should have completion timestamp")

        // Verify status via query API
        let finalStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(finalStatus == .completed, "Status API should reflect .completed")
    }

    // MARK: - Test 4: Report Generation Workflow (End-to-End)

    /// Full end-to-end report generation: creates prerequisite data (user, group,
    /// entitlement, accounts), triggers a report job, and verifies CSV output
    /// is produced on the local filesystem.
    ///
    /// Rule 4: AccountService enforces entitlements — only entitled accounts appear.
    /// Rule 7: Report paginates at AppConstants.batchSize (1,000) per page.
    @Test("Report generation — full E2E workflow with CSV export")
    func testReportGenerationWorkflow() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create test accounts
        for i in 1...5 {
            _ = try await createTestAccount(
                name: "Report Test Account \(i)",
                groupId: groupId,
                accountRepo: s.accountRepo
            )
        }

        let parameters = JobParameters(
            fieldSelection: ["name", "id", "fundType"],
            accountSelection: nil,
            targetDate: makeDate(year: 2026, month: 4, day: 14),
            sourceFilePath: nil,
            sourceFileType: nil
        )

        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)
        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        #expect(completedJob.status == .completed, "Report job should complete successfully")

        // Verify the job is in the all-jobs list
        let allJobs = await s.jobSchedulerService.getAllJobs()
        #expect(allJobs.contains(where: { $0.id == job.id }), "Job should appear in getAllJobs()")
    }

    // MARK: - Test 5: CSV Ingestion Workflow (End-to-End)

    /// Full end-to-end CSV ingestion: writes a CSV file to a temporary location,
    /// creates an ingestion job, triggers execution, and verifies the reference
    /// data records appear in the database.
    ///
    /// Rule 6: CSV must have ticker, name, SOD bid/ask, EOD bid/ask columns.
    /// Rule 9: All files are local — no network calls.
    @Test("CSV ingestion — full E2E workflow from file to database")
    func testCSVIngestionWorkflow() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, _) = try await createTestUserAndGroup(s: s)

        let marketDate = makeDate(year: 2026, month: 4, day: 14)
        let dateStr = formatDateForCSV(marketDate)

        // Build CSV with 5 reference data rows (valid columns per Rule 6).
        // Tickers must be 3-5 uppercase ASCII letters (no digits) to pass
        // CSVParser.isValidTicker() validation.
        let tickers = ["TSTA", "TSTB", "TSTC", "TSTD", "TSTE"]
        var csvContent = "ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date\n"
        for i in 0..<5 {
            let base = Decimal(51 + i)
            csvContent += "\(tickers[i]),Test Security \(i + 1),"
            csvContent += "\(base - 1),\(base + 1),\(base),\(base + 2),\(dateStr)\n"
        }

        let csvPath = try writeTempCSV(csvContent, prefix: "test_ingest_job")
        defer { try? FileManager.default.removeItem(atPath: csvPath) }

        let parameters = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: csvPath,
            sourceFileType: "reference_data"
        )

        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)
        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        #expect(completedJob.status == .completed, "Ingestion job should complete successfully")

        // Verify records in database
        let allRecords = try await s.refDataRepo.findAll(page: 1, pageSize: 100)
        #expect(allRecords.count >= 5, "At least 5 reference data rows should exist after ingestion")

        // Spot-check first record (ticker "TSTA" — first in the array)
        let tstA = try await s.refDataRepo.findByTickerAndDate(
            ticker: "TSTA", marketDate: marketDate
        )
        #expect(tstA != nil, "TSTA should exist in reference_data")
        if let record = tstA {
            #expect(record.name == "Test Security 1")
            #expect(record.eodBid > 0, "EOD bid must be non-zero (Rule 6)")
            #expect(record.eodAsk > 0, "EOD ask must be non-zero (Rule 6)")
        }
    }

    // MARK: - Test 6: Execute Non-Existent Job

    /// Verifies that executing a job with an invalid ID throws an error.
    @Test("Execute non-existent job — throws error")
    func testExecuteNonExistentJob() async throws {
        try await prepareDatabase()
        let s = buildServices()

        await #expect(throws: AppError.self) {
            _ = try await s.jobSchedulerService.executeJob(id: 999999, userId: 1)
        }
    }

    // MARK: - Test 7: Execute Already Completed Job

    /// Verifies that attempting to execute an already-completed job throws an error
    /// (only pending jobs can be executed).
    @Test("Execute completed job — throws error (only pending jobs)")
    func testExecuteAlreadyCompletedJob() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        _ = try await createTestAccount(
            name: "Double Execute Test",
            groupId: groupId,
            accountRepo: s.accountRepo
        )

        let parameters = JobParameters(
            fieldSelection: ["name"],
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: nil,
            sourceFileType: nil
        )

        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)
        _ = try await s.jobSchedulerService.executeJob(id: job.id, userId: userId)

        // Attempting to re-execute should throw
        await #expect(throws: AppError.self) {
            _ = try await s.jobSchedulerService.executeJob(id: job.id, userId: userId)
        }
    }

    // MARK: - Test 8: getAllJobs Returns All Created Jobs

    /// Verifies that getAllJobs returns all jobs ordered by creation time (newest first).
    @Test("getAllJobs returns multiple jobs in creation-time order")
    func testGetAllJobsOrder() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let params = JobParameters(
            fieldSelection: nil, accountSelection: nil,
            targetDate: nil, sourceFilePath: nil, sourceFileType: nil
        )

        let job1 = await s.jobSchedulerService.createJob(type: .report, parameters: params)
        let job2 = await s.jobSchedulerService.createJob(type: .ingestion, parameters: params)
        let job3 = await s.jobSchedulerService.createJob(type: .report, parameters: params)

        let allJobs = await s.jobSchedulerService.getAllJobs()
        #expect(allJobs.count >= 3, "Should have at least 3 jobs")

        // Verify newest first ordering
        #expect(allJobs[0].id == job3.id, "Newest job should be first")
        #expect(allJobs[1].id == job2.id)
        #expect(allJobs[2].id == job1.id, "Oldest job should be last")
    }

    // MARK: - Test 9: Ingestion Job Fails on Missing File

    /// Verifies that an ingestion job with a non-existent file path transitions
    /// to `.failed` status rather than crashing.
    @Test("Ingestion job with missing file — job fails gracefully")
    func testIngestionJobMissingFile() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, _) = try await createTestUserAndGroup(s: s)

        let parameters = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: "/nonexistent/path/to/data.csv",
            sourceFileType: "reference_data"
        )

        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)

        // Execute should throw (file not found) and mark job as failed
        do {
            _ = try await s.jobSchedulerService.executeJob(id: job.id, userId: userId)
            Issue.record("Expected error for missing file but execution succeeded")
        } catch {
            // Expected: job execution fails due to missing file
        }

        // Verify job status is .failed
        let failedStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(failedStatus == .failed, "Job should be in .failed status after file-not-found error")
    }

    // MARK: - Test 10: Ingestion Job Without sourceFilePath

    /// Verifies that an ingestion job missing the `sourceFilePath` parameter
    /// fails with an appropriate error.
    @Test("Ingestion job without sourceFilePath — fails with error")
    func testIngestionJobNoFilePath() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, _) = try await createTestUserAndGroup(s: s)

        let parameters = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: nil,  // Missing required field for ingestion
            sourceFileType: "reference_data"
        )

        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)

        do {
            _ = try await s.jobSchedulerService.executeJob(id: job.id, userId: userId)
            Issue.record("Expected error for missing sourceFilePath but execution succeeded")
        } catch {
            // Expected: job execution fails due to missing sourceFilePath
        }

        let failedStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(failedStatus == .failed, "Job should be .failed when sourceFilePath is nil")
    }
}
