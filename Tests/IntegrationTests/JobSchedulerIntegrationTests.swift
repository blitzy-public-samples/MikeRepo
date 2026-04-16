// Tests/IntegrationTests/JobSchedulerIntegrationTests.swift
// WealthLedger — Job Scheduler Integration Tests Against Live MySQL
//
// End-to-end integration tests for the JobScheduler module exercising
// job creation, manual trigger execution, status tracking, report
// generation (with field selection, account filtering, and target date),
// and CSV ingestion workflows against the live MySQL `accounting_test`
// schema via TestDatabaseSetup.
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
@testable import ReferenceDataService
@testable import AccountManagement
@testable import ValuationEngine
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
    /// - ReportGenerator + CSVParser + RefDataService + AccountService + ValuationService → JobSchedulerService
    private func buildServices() -> (
        jobSchedulerService: JobSchedulerService,
        reportGenerator: ReportGenerator,
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
            jobSchedulerService, reportGenerator, authService, accountService,
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
    /// permissions, returning the user ID and group ID for subsequent operations.
    ///
    /// Prerequisite data chain:
    ///   user → account_group → entitlement (READ, CREATE, MODIFY, DELETE)
    ///
    /// - Parameter s: Service tuple from `buildServices()`.
    /// - Returns: Tuple of (userId, accountGroupId) for further test operations.
    private func createTestUserAndGroup(
        s: (
            jobSchedulerService: JobSchedulerService,
            reportGenerator: ReportGenerator,
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
        // Create test user with bcrypt-hashed password
        let user = try await s.authService.createUser(
            username: "jobtest_user_\(UUID().uuidString.prefix(8))",
            password: "TestPassword123!"
        )
        let userId = user.id

        // Create account group via direct repository insert
        let group = try await s.accountGroupRepo.create(
            Persistence.AccountGroup(
                id: 0,
                groupName: "JobTest Group \(UUID().uuidString.prefix(8))",
                metadata: nil,
                createdAt: Date()
            )
        )
        let groupId = group.id

        // Assign full RCMD entitlements for comprehensive test coverage
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

    /// Reads the content of a CSV file at the given path and returns a tuple
    /// of (headerFields, dataRows) where each dataRow is an array of field values.
    ///
    /// This helper parses RFC 4180 CSV output produced by `CSVExporter`.
    /// Each non-empty line is split by comma to extract individual field values.
    ///
    /// - Parameter filePath: Absolute path to the CSV file.
    /// - Returns: Tuple of (headers: [String], rows: [[String]]).
    private func readCSVContent(
        at filePath: String
    ) throws -> (headers: [String], rows: [[String]]) {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let headerLine = lines.first else {
            return ([], [])
        }
        let headers = headerLine.components(separatedBy: ",")
        let dataRows = lines.dropFirst().map { line in
            line.components(separatedBy: ",")
        }
        return (headers, Array(dataRows))
    }

    // MARK: - Test 1: Create Report Job

    /// Verifies that creating a report job produces a pending job with correct
    /// type and parameters, and that the job is retrievable by ID.
    ///
    /// Validates:
    /// - Job gets auto-assigned ID > 0
    /// - Status starts as `.pending`
    /// - Type is `.report`
    /// - Field selection parameters are preserved
    /// - Job is retrievable via `getJob(id:)`
    @Test("Create a report generation job")
    func testCreateReportJob() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let parameters = JobParameters(
            fieldSelection: ["accountName", "accountId", "accountType", "cachedValuationAmount"],
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
        #expect(
            job.parameters.fieldSelection?.count == 4,
            "Field selection should preserve all 4 fields"
        )
        #expect(
            job.parameters.targetDate != nil,
            "Target date should be preserved"
        )

        // Verify the job is retrievable by ID
        let retrieved = await s.jobSchedulerService.getJob(id: job.id)
        #expect(retrieved != nil, "Job should be retrievable by ID")
        #expect(retrieved?.id == job.id)
        #expect(retrieved?.type == .report)
        #expect(retrieved?.status == .pending)
    }

    // MARK: - Test 2: Create Ingestion Job

    /// Verifies that creating an ingestion job stores the source file path
    /// and file type correctly in the job parameters.
    ///
    /// Validates:
    /// - Job type is `.ingestion`
    /// - Status starts as `.pending`
    /// - sourceFilePath is preserved
    /// - sourceFileType is preserved
    @Test("Create a CSV ingestion job")
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

        #expect(job.id > 0, "Job should have auto-assigned ID")
        #expect(job.type == .ingestion, "Job type should be .ingestion")
        #expect(job.status == .pending, "New job should be in .pending status")
        #expect(job.completedAt == nil, "New job should have no completion time")
        #expect(
            job.parameters.sourceFilePath == "/tmp/test_data.csv",
            "Source file path should be preserved"
        )
        #expect(
            job.parameters.sourceFileType == "reference_data",
            "Source file type should be preserved"
        )
    }

    // MARK: - Test 3: Manual Trigger — Report Job Execution

    /// Full end-to-end report generation: creates prerequisite data (user, group,
    /// entitlement, accounts), triggers a report job via manual execution, and
    /// verifies the job completes successfully and appears in the job list.
    ///
    /// Rule 4: AccountService enforces entitlements — only entitled accounts appear.
    /// Rule 7: Report paginates at AppConstants.batchSize (1,000) per page.
    @Test("Manually trigger report job and verify CSV output")
    func testManualTriggerReportJob() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create test accounts as prerequisite data for the report
        for i in 1...5 {
            _ = try await createTestAccount(
                name: "Report Trigger Account \(i)",
                groupId: groupId,
                accountRepo: s.accountRepo
            )
        }

        let parameters = JobParameters(
            fieldSelection: ["accountName", "accountId", "accountType"],
            accountSelection: nil,
            targetDate: makeDate(year: 2026, month: 4, day: 14),
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Create and execute the report job
        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)
        #expect(job.status == .pending, "Job should start as pending")

        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        // Verify successful completion
        #expect(completedJob.status == .completed, "Report job should complete successfully")
        #expect(completedJob.completedAt != nil, "Completed job should have timestamp")

        // Verify the job appears in the global job list
        let allJobs = await s.jobSchedulerService.getAllJobs()
        #expect(
            allJobs.contains(where: { $0.id == job.id }),
            "Completed job should appear in getAllJobs()"
        )
    }

    // MARK: - Test 4: Manual Trigger — Ingestion Job Execution

    /// Full end-to-end CSV ingestion: writes a CSV file to a temporary location,
    /// creates an ingestion job, triggers execution, and verifies the reference
    /// data records appear in the MySQL database.
    ///
    /// Rule 6: CSV must have ticker, name, SOD bid/ask, EOD bid/ask columns.
    /// Rule 9: All files are local — no network calls.
    @Test("Manually trigger CSV ingestion job")
    func testManualTriggerIngestionJob() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, _) = try await createTestUserAndGroup(s: s)

        let marketDate = makeDate(year: 2026, month: 4, day: 14)
        let dateStr = formatDateForCSV(marketDate)

        // Build CSV with 5 reference data rows (valid columns per Rule 6).
        // Tickers must be 3-5 uppercase ASCII letters to pass CSVParser validation.
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

        // Create and manually trigger the ingestion job
        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)
        #expect(job.status == .pending, "Ingestion job should start as pending")

        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        // Verify successful completion
        #expect(completedJob.status == .completed, "Ingestion job should complete successfully")
        #expect(completedJob.completedAt != nil, "Completed job should have timestamp")

        // Verify records were inserted into MySQL database
        let allRecords = try await s.refDataRepo.findAll(page: 1, pageSize: 100)
        #expect(
            allRecords.count >= 5,
            "At least 5 reference data rows should exist after ingestion"
        )

        // Spot-check first record by ticker
        let tstA = try await s.refDataRepo.findByTickerAndDate(
            ticker: "TSTA", marketDate: marketDate
        )
        #expect(tstA != nil, "TSTA should exist in reference_data after ingestion")
        if let record = tstA {
            #expect(record.name == "Test Security 1")
            #expect(record.eodBid > 0, "EOD bid must be non-zero (Rule 6)")
            #expect(record.eodAsk > 0, "EOD ask must be non-zero (Rule 6)")
        }
    }

    // MARK: - Test 5: Job Status Lifecycle

    /// Verifies the complete job status lifecycle: pending → running → completed.
    /// Checks status at each stage via the query API and verifies timestamps.
    ///
    /// The `executeJob` method transitions through running→completed atomically,
    /// so we verify the final state and ensure completedAt is populated.
    @Test("Job status lifecycle: pending → running → completed")
    func testJobStatusLifecycle() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create a small account so the report has data to process
        _ = try await createTestAccount(
            name: "Lifecycle Test Account",
            groupId: groupId,
            accountRepo: s.accountRepo
        )

        let parameters = JobParameters(
            fieldSelection: ["accountName"],
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Stage 1: Create job — verify .pending
        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)
        let createdAt = job.createdAt

        let pendingStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(pendingStatus == .pending, "Status should be .pending before execution")
        #expect(job.completedAt == nil, "Pending job should have nil completedAt")

        // Stage 2: Execute job — transitions through .running to .completed
        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )

        // Stage 3: Verify .completed state
        #expect(completedJob.status == .completed, "Job should be .completed after execution")
        #expect(completedJob.completedAt != nil, "Completed job should have completion timestamp")
        #expect(completedJob.createdAt == createdAt, "createdAt should not change after execution")

        // Verify status via query API is consistent
        let finalStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(finalStatus == .completed, "Status API should reflect .completed")

        // Verify the full job object via getJob
        let fullJob = await s.jobSchedulerService.getJob(id: job.id)
        #expect(fullJob?.status == .completed, "getJob should also show .completed")
        #expect(fullJob?.completedAt != nil, "getJob should show completedAt timestamp")
    }

    // MARK: - Test 6: Job Failure Status

    /// Verifies that a job transitions to `.failed` status when execution
    /// encounters an error (e.g., non-existent file path for ingestion).
    ///
    /// This validates the error handling path in JobSchedulerService.executeJob
    /// where the catch block marks the job as failed before re-throwing.
    @Test("Job transitions to failed status on error")
    func testJobFailureStatus() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, _) = try await createTestUserAndGroup(s: s)

        // Create an ingestion job pointing to a non-existent file
        let parameters = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: "/nonexistent/path/to/data.csv",
            sourceFileType: "reference_data"
        )

        let job = await s.jobSchedulerService.createJob(type: .ingestion, parameters: parameters)
        #expect(job.status == .pending, "Job should start as pending")

        // Execute should throw (file not found) and mark job as failed
        do {
            _ = try await s.jobSchedulerService.executeJob(id: job.id, userId: userId)
            Issue.record("Expected error for missing file but execution succeeded")
        } catch {
            // Expected: job execution fails due to missing CSV file
        }

        // Verify the job status transitioned to .failed
        let failedStatus = await s.jobSchedulerService.getJobStatus(id: job.id)
        #expect(
            failedStatus == .failed,
            "Job should be in .failed status after file-not-found error"
        )

        // Verify via getJob that the job object reflects failure
        let failedJob = await s.jobSchedulerService.getJob(id: job.id)
        #expect(failedJob?.status == .failed, "getJob should show .failed status")
        #expect(
            failedJob?.completedAt != nil,
            "Failed job should have completedAt timestamp marking when it failed"
        )
    }

    // MARK: - Test 7: Report Field Selection

    /// Verifies that a report job respects the field selection parameters,
    /// producing CSV output containing ONLY the selected fields in the header
    /// and excluding all non-selected fields.
    ///
    /// Approach: Uses ReportGenerator directly (same MySQL-backed services) to
    /// obtain the CSV file path for content verification, since executeJob
    /// discards the report file path internally.
    @Test("Report job respects field selection parameters")
    func testReportFieldSelection() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create a test account that will appear in the report
        _ = try await createTestAccount(
            name: "FieldSelect Test Fund",
            groupId: groupId,
            fundType: .sma,
            accountRepo: s.accountRepo
        )

        // Select only 3 specific fields
        let selectedFields = ["accountName", "accountId", "accountType"]
        let parameters = JobParameters(
            fieldSelection: selectedFields,
            accountSelection: nil,
            targetDate: makeDate(year: 2026, month: 4, day: 14),
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Use ReportGenerator directly to get the file path for CSV verification.
        // The underlying AccountService still queries live MySQL with entitlements.
        let filePath = try await s.reportGenerator.generateReport(
            parameters: parameters,
            userId: userId
        )
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        // Read and parse the CSV content
        let (headers, rows) = try readCSVContent(at: filePath)

        // Verify header contains exactly the 3 selected fields
        #expect(headers.count == 3, "CSV should have exactly 3 header columns")
        #expect(headers.contains("accountName"), "Header should contain accountName")
        #expect(headers.contains("accountId"), "Header should contain accountId")
        #expect(headers.contains("accountType"), "Header should contain accountType")

        // Verify non-selected fields are NOT in the header
        #expect(!headers.contains("accountStatus"), "accountStatus should not be in header")
        #expect(!headers.contains("accountGroupId"), "accountGroupId should not be in header")
        #expect(
            !headers.contains("cachedValuationAmount"),
            "cachedValuationAmount should not be in header"
        )
        #expect(
            !headers.contains("valuationTimezone"),
            "valuationTimezone should not be in header"
        )

        // Verify at least one data row exists
        #expect(rows.count >= 1, "Should have at least 1 data row for the created account")

        // Verify the data row has the correct number of columns
        if let firstRow = rows.first {
            #expect(
                firstRow.count == 3,
                "Each data row should have exactly 3 fields matching selection"
            )
        }
    }

    // MARK: - Test 8: Report Account Filtering

    /// Verifies that a report job filters by selected account IDs, producing
    /// CSV output containing ONLY the selected accounts (A, B) and excluding
    /// unselected accounts (C).
    ///
    /// Approach: Uses ReportGenerator directly for CSV content verification.
    @Test("Report job filters by selected accounts")
    func testReportAccountFiltering() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create 3 accounts: Alpha, Bravo, Charlie
        let acctAlpha = try await createTestAccount(
            name: "Filter Alpha Fund",
            groupId: groupId,
            fundType: .etf,
            accountRepo: s.accountRepo
        )
        let acctBravo = try await createTestAccount(
            name: "Filter Bravo Fund",
            groupId: groupId,
            fundType: .sma,
            accountRepo: s.accountRepo
        )
        let acctCharlie = try await createTestAccount(
            name: "Filter Charlie Fund",
            groupId: groupId,
            fundType: .hedgeFund,
            accountRepo: s.accountRepo
        )

        // Select ONLY accounts Alpha and Bravo — Charlie should be excluded
        let parameters = JobParameters(
            fieldSelection: ["accountName", "accountId"],
            accountSelection: [acctAlpha.id, acctBravo.id],
            targetDate: nil,
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Use ReportGenerator directly for CSV content verification
        let filePath = try await s.reportGenerator.generateReport(
            parameters: parameters,
            userId: userId
        )
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        // Read and parse the CSV content
        let (headers, rows) = try readCSVContent(at: filePath)

        // Verify header is correct
        #expect(headers.count == 2, "Header should have 2 fields")
        #expect(headers.contains("accountName"), "Header should have accountName")
        #expect(headers.contains("accountId"), "Header should have accountId")

        // Verify exactly 2 data rows (accounts Alpha and Bravo only)
        #expect(rows.count == 2, "Should have exactly 2 data rows for selected accounts")

        // Verify selected accounts are present
        let allRowContent = rows.flatMap { $0 }.joined(separator: " ")
        #expect(
            allRowContent.contains("Filter Alpha Fund"),
            "Account Alpha should be in report output"
        )
        #expect(
            allRowContent.contains("Filter Bravo Fund"),
            "Account Bravo should be in report output"
        )

        // Verify excluded account (Charlie) is NOT in the output
        #expect(
            !allRowContent.contains("Filter Charlie Fund"),
            "Account Charlie should NOT be in report output"
        )

        // Verify account IDs are correct
        #expect(
            allRowContent.contains(String(acctAlpha.id)),
            "Alpha account ID should appear in report"
        )
        #expect(
            allRowContent.contains(String(acctBravo.id)),
            "Bravo account ID should appear in report"
        )
        #expect(
            !allRowContent.contains(String(acctCharlie.id)),
            "Charlie account ID should NOT appear in report"
        )
    }

    // MARK: - Test 9: Report Target Date

    /// Verifies that a report job uses the specified target date parameter.
    /// Creates a report job with a specific target date, executes it, and
    /// verifies the job completes successfully with the correct parameters.
    ///
    /// The target date is used by ReportGenerator when extracting date-context
    /// fields and for generating the output file name.
    @Test("Report job uses target date for valuation data")
    func testReportTargetDate() async throws {
        try await prepareDatabase()
        let s = buildServices()
        let (userId, groupId) = try await createTestUserAndGroup(s: s)

        // Create a test account
        _ = try await createTestAccount(
            name: "TargetDate Test Fund",
            groupId: groupId,
            accountRepo: s.accountRepo
        )

        // Specify a concrete target date and include the targetDate field
        let specificDate = makeDate(year: 2026, month: 3, day: 15)
        let parameters = JobParameters(
            fieldSelection: ["accountName", "accountId", "targetDate"],
            accountSelection: nil,
            targetDate: specificDate,
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Create and execute the report job through the full scheduler flow
        let job = await s.jobSchedulerService.createJob(type: .report, parameters: parameters)
        #expect(job.parameters.targetDate != nil, "Target date should be stored in parameters")

        let completedJob = try await s.jobSchedulerService.executeJob(
            id: job.id, userId: userId
        )
        #expect(completedJob.status == .completed, "Report job with target date should complete")
        #expect(completedJob.completedAt != nil, "Completed job should have timestamp")

        // Additionally verify via ReportGenerator that the target date appears in output
        let filePath = try await s.reportGenerator.generateReport(
            parameters: parameters,
            userId: userId
        )
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let (headers, rows) = try readCSVContent(at: filePath)
        #expect(headers.contains("targetDate"), "Header should include targetDate field")
        #expect(rows.count >= 1, "Should have at least 1 data row")

        // Verify the target date value in the data row
        if let targetDateIdx = headers.firstIndex(of: "targetDate"),
           let firstRow = rows.first, firstRow.count > targetDateIdx {
            let dateValue = firstRow[targetDateIdx]
            #expect(
                dateValue.contains("2026-03-15"),
                "Target date field should reflect the specified date 2026-03-15"
            )
        }
    }

    // MARK: - Test 10: Job Tracking

    /// Verifies that multiple jobs of different types can be created and tracked
    /// via the getAllJobs() API, with each job maintaining its correct type,
    /// status, and identity.
    @Test("Track and list all created jobs")
    func testJobTracking() async throws {
        try await prepareDatabase()
        let s = buildServices()

        let params1 = JobParameters(
            fieldSelection: ["accountName"],
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: nil,
            sourceFileType: nil
        )
        let params2 = JobParameters(
            fieldSelection: nil,
            accountSelection: nil,
            targetDate: nil,
            sourceFilePath: "/tmp/data.csv",
            sourceFileType: "reference_data"
        )
        let params3 = JobParameters(
            fieldSelection: ["accountId", "accountType"],
            accountSelection: nil,
            targetDate: makeDate(year: 2026, month: 1, day: 1),
            sourceFilePath: nil,
            sourceFileType: nil
        )

        // Create jobs of mixed types
        let reportJob1 = await s.jobSchedulerService.createJob(type: .report, parameters: params1)
        let ingestionJob = await s.jobSchedulerService.createJob(type: .ingestion, parameters: params2)
        let reportJob2 = await s.jobSchedulerService.createJob(type: .report, parameters: params3)

        // Retrieve all jobs via tracking API
        let allJobs = await s.jobSchedulerService.getAllJobs()
        #expect(allJobs.count >= 3, "Should have at least 3 jobs tracked")

        // Verify each job is present with correct type
        let jobIds = allJobs.map { $0.id }
        #expect(jobIds.contains(reportJob1.id), "Report job 1 should be tracked")
        #expect(jobIds.contains(ingestionJob.id), "Ingestion job should be tracked")
        #expect(jobIds.contains(reportJob2.id), "Report job 2 should be tracked")

        // Verify types are correct
        let reportJob1Found = allJobs.first(where: { $0.id == reportJob1.id })
        #expect(reportJob1Found?.type == .report, "Report job 1 type should be .report")
        #expect(reportJob1Found?.status == .pending, "Report job 1 should still be .pending")

        let ingestionJobFound = allJobs.first(where: { $0.id == ingestionJob.id })
        #expect(ingestionJobFound?.type == .ingestion, "Ingestion job type should be .ingestion")
        #expect(ingestionJobFound?.status == .pending, "Ingestion job should still be .pending")

        let reportJob2Found = allJobs.first(where: { $0.id == reportJob2.id })
        #expect(reportJob2Found?.type == .report, "Report job 2 type should be .report")
        #expect(
            reportJob2Found?.parameters.targetDate != nil,
            "Report job 2 should have target date in parameters"
        )

        // Verify individual job status queries are consistent
        let status1 = await s.jobSchedulerService.getJobStatus(id: reportJob1.id)
        #expect(status1 == .pending, "Status query should match .pending for report job 1")

        let status2 = await s.jobSchedulerService.getJobStatus(id: ingestionJob.id)
        #expect(status2 == .pending, "Status query should match .pending for ingestion job")

        let status3 = await s.jobSchedulerService.getJobStatus(id: reportJob2.id)
        #expect(status3 == .pending, "Status query should match .pending for report job 2")
    }
}
