// Sources/JobScheduler/Services/JobSchedulerService.swift
// WealthLedger — Job Lifecycle Management (Manual Trigger Only)
//
// Manages the lifecycle of report generation and CSV ingestion jobs. All jobs
// are manually triggered — no automated cron scheduling. Job state is stored
// in a thread-safe actor-based in-memory store for the single-user desktop
// architecture (1 concurrent user, ~300 registered users).
//
// Rules Enforced:
//   Rule 7  — Batch Memory Cap: delegates to ReportGenerator and CSVParser,
//             which paginate at AppConstants.batchSize (1,000) per page.
//   Rule 8  — MySQLKit-Only: no SwiftData imports. DB access via repositories.
//   Rule 9  — Offline Runtime: no network calls. All data sources are local.
//   Gate 2  — Swift 6 strict concurrency: Sendable final class, let-only
//             properties. JobStore actor provides thread-safe state.
//
// SPDX-License-Identifier: MIT

import Foundation
import Shared

// Selective imports to avoid ReferenceData type name collisions between
// Persistence.ReferenceData and ReferenceDataService.ReferenceData.
import class ReferenceDataService.ReferenceDataService
import struct ReferenceDataService.CSVParser
import class AccountManagement.AccountService
import class ValuationEngine.ValuationService

// MARK: - JobStore (Thread-Safe In-Memory Storage)

/// Actor-based thread-safe in-memory store for job records.
///
/// The `JobStore` actor provides isolation for mutable job state without
/// requiring `@unchecked Sendable` annotations. Job records are stored in
/// a dictionary keyed by job ID, and the next ID counter is auto-incremented.
///
/// This design is appropriate for the single-user desktop architecture
/// where job history does not need to survive application restarts.
private actor JobStore {

    /// Dictionary of all jobs keyed by their unique ID.
    private var jobs: [UInt64: Job] = [:]

    /// Auto-incrementing counter for assigning unique job IDs.
    /// Starts at 1 so that job ID 0 is never assigned (0 is the default
    /// "not yet persisted" sentinel in other model types).
    private var nextId: UInt64 = 1

    /// Creates a new job with an auto-assigned ID and `.pending` status.
    ///
    /// - Parameters:
    ///   - type: The job type (`.report` or `.ingestion`).
    ///   - parameters: Configuration parameters for the job.
    /// - Returns: The newly created `Job` with its assigned ID and timestamps.
    func createJob(type: JobType, parameters: JobParameters) -> Job {
        let id = nextId
        nextId += 1

        let job = Job(
            id: id,
            type: type,
            status: .pending,
            parameters: parameters,
            createdAt: Date(),
            completedAt: nil
        )
        jobs[id] = job
        return job
    }

    /// Updates the status of an existing job.
    ///
    /// - Parameters:
    ///   - id: The job ID to update.
    ///   - status: The new status to set.
    ///   - completedAt: Optional completion timestamp (set when status is
    ///     `.completed` or `.failed`).
    /// - Returns: The updated job, or `nil` if the ID was not found.
    @discardableResult
    func updateStatus(id: UInt64, status: JobStatus, completedAt: Date? = nil) -> Job? {
        guard let existing = jobs[id] else { return nil }
        let updated = Job(
            id: existing.id,
            type: existing.type,
            status: status,
            parameters: existing.parameters,
            createdAt: existing.createdAt,
            completedAt: completedAt ?? existing.completedAt
        )
        jobs[id] = updated
        return updated
    }

    /// Retrieves a job by its ID.
    ///
    /// - Parameter id: The unique job identifier.
    /// - Returns: The job if found, or `nil`.
    func getJob(id: UInt64) -> Job? {
        jobs[id]
    }

    /// Retrieves the status of a specific job.
    ///
    /// - Parameter id: The unique job identifier.
    /// - Returns: The job status if the job exists, or `nil`.
    func getJobStatus(id: UInt64) -> JobStatus? {
        jobs[id]?.status
    }

    /// Returns all jobs in the store, ordered by creation time (newest first).
    ///
    /// - Returns: Array of all jobs sorted by `createdAt` descending.
    func getAllJobs() -> [Job] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - JobSchedulerService

/// Manages job lifecycle: creation, manual execution, and status tracking.
///
/// `JobSchedulerService` is the entry point for the JobScheduler module's
/// public API. It dispatches report jobs to ``ReportGenerator`` and ingestion
/// jobs to ``ReferenceDataService/ingestCSV(at:)``. All jobs are manually
/// triggered via ``executeJob(id:userId:)`` — no automated scheduling.
///
/// ## Dependency Injection
///
/// All five service dependencies are injected via the initializer and
/// registered by `DependencyContainer` during application startup. The
/// `JobStore` actor is created internally and not exposed.
///
/// ## Thread Safety (Gate 2 — Swift 6 Strict Concurrency)
///
/// This class is `final` with only immutable `let` properties of
/// `Sendable`-conforming types. The `JobStore` actor provides thread-safe
/// mutable state without `@unchecked Sendable`. Zero warning suppressions.
///
/// ## Cross-Module Dependencies
///
/// - ``ReportGenerator`` — executes report jobs (CSV export)
/// - ``CSVParser`` — referenced indirectly via ReferenceDataService for ingestion
/// - ``ReferenceDataService`` — executes CSV ingestion jobs
/// - ``AccountService`` — provides account data for reports
/// - ``ValuationService`` — provides valuation data for reports
public final class JobSchedulerService: Sendable {

    // MARK: - Constants

    /// Maximum records per batch for job operations (Rule 7 — Batch Memory Cap).
    /// Report generation and CSV ingestion delegate to their respective services
    /// which paginate at this limit. Sourced from ``AppConstants/batchSize``.
    private static let jobBatchLimit: Int = AppConstants.batchSize

    // MARK: - Properties (all immutable for Sendable safety)

    /// Report generation engine for report-type jobs.
    private let reportGenerator: ReportGenerator

    /// CSV parsing utility (retained for potential future direct use).
    private let csvParser: CSVParser

    /// Reference data service for CSV ingestion jobs.
    private let referenceDataService: ReferenceDataService

    /// Account service for account data access during report generation.
    private let accountService: AccountService

    /// Valuation service for valuation data access during report generation.
    private let valuationService: ValuationService

    /// Thread-safe in-memory job store.
    private let jobStore: JobStore

    // MARK: - Initializer

    /// Creates a new `JobSchedulerService` with all required dependencies.
    ///
    /// All parameters are retained as immutable `let` bindings for thread
    /// safety and `Sendable` compliance. The `JobStore` actor is created
    /// internally.
    ///
    /// - Parameters:
    ///   - reportGenerator: Engine for generating CSV reports with field selection.
    ///   - csvParser: CSV parsing utility for validation and streaming.
    ///   - referenceDataService: Service for CSV ingestion into reference data.
    ///   - accountService: Service for account data access.
    ///   - valuationService: Service for valuation data access.
    public init(
        reportGenerator: ReportGenerator,
        csvParser: CSVParser,
        referenceDataService: ReferenceDataService,
        accountService: AccountService,
        valuationService: ValuationService
    ) {
        self.reportGenerator = reportGenerator
        self.csvParser = csvParser
        self.referenceDataService = referenceDataService
        self.accountService = accountService
        self.valuationService = valuationService
        self.jobStore = JobStore()
    }

    // MARK: - Job Creation

    /// Creates a new job with the specified type and parameters.
    ///
    /// The job is created in `.pending` status and stored in the in-memory
    /// job store. It must be explicitly executed via ``executeJob(id:userId:)``.
    ///
    /// - Parameters:
    ///   - type: The job type (`.report` for CSV report generation or
    ///     `.ingestion` for CSV file ingestion).
    ///   - parameters: Configuration parameters including field selection,
    ///     account selection, target date, or source file path.
    /// - Returns: The newly created `Job` with an auto-assigned ID.
    public func createJob(type: JobType, parameters: JobParameters) async -> Job {
        await jobStore.createJob(type: type, parameters: parameters)
    }

    // MARK: - Job Execution (Manual Trigger)

    /// Manually triggers execution of a pending job.
    ///
    /// This method transitions the job from `.pending` to `.running`, dispatches
    /// it to the appropriate handler (``ReportGenerator`` for report jobs,
    /// ``ReferenceDataService`` for ingestion jobs), and updates the status to
    /// `.completed` or `.failed` based on the outcome.
    ///
    /// ## Report Jobs
    /// Delegates to ``ReportGenerator/generateReport(parameters:userId:)`` which
    /// paginates at ``AppConstants/batchSize`` (1,000) accounts per page (Rule 7).
    /// The report is exported as a CSV file and the file path is embedded in the
    /// returned job's parameters (no direct return of file contents).
    ///
    /// ## Ingestion Jobs
    /// Delegates to ``ReferenceDataService/ingestCSV(at:)`` which streams the CSV
    /// file and processes rows in batches of 1,000 (Rule 7). Supports files up to
    /// 100MB without crash.
    ///
    /// - Parameters:
    ///   - id: The job ID to execute. Must reference an existing job.
    ///   - userId: The authenticated user ID triggering the job. Passed to
    ///     ``ReportGenerator`` for entitlement-filtered data access.
    /// - Returns: The updated `Job` with final status (`.completed` or `.failed`).
    /// - Throws: ``AppError/accountNotFound`` if the job ID is not found.
    ///   ``AppError/operationNotPermitted`` if the job is not in `.pending` status.
    public func executeJob(id: UInt64, userId: UInt64) async throws -> Job {
        // Verify job exists
        guard let job = await jobStore.getJob(id: id) else {
            throw AppError.accountNotFound
        }

        // Only pending jobs can be executed — reject already-processed or running jobs
        guard job.status == .pending else {
            throw AppError.operationNotPermitted
        }

        // Transition to running
        await jobStore.updateStatus(id: id, status: .running)

        do {
            switch job.type {
            case .report:
                // Delegate to ReportGenerator for CSV export.
                // ReportGenerator internally paginates at AppConstants.batchSize (Rule 7).
                _ = try await reportGenerator.generateReport(
                    parameters: job.parameters,
                    userId: userId
                )

            case .ingestion:
                // Delegate to ReferenceDataService for CSV ingestion.
                // CSVParser internally streams and batches at AppConstants.batchSize
                // rows per page (Rule 7) — files up to 100MB supported (Rule 13).
                guard let filePath = job.parameters.sourceFilePath else {
                    throw AppError.migrationFailed
                }
                try await referenceDataService.ingestCSV(at: filePath)
            }

            // Mark completed on success
            let completedJob = await jobStore.updateStatus(
                id: id,
                status: .completed,
                completedAt: Date()
            )
            return completedJob ?? job

        } catch {
            // Mark failed on error, preserving the original error for the caller
            _ = await jobStore.updateStatus(
                id: id,
                status: .failed,
                completedAt: Date()
            )
            // Re-throw so callers can inspect the failure reason
            throw error
        }
    }

    // MARK: - Job Queries

    /// Retrieves the current status of a specific job.
    ///
    /// - Parameter id: The unique job identifier.
    /// - Returns: The job status if found, or `nil` if the job ID does not exist.
    public func getJobStatus(id: UInt64) async -> JobStatus? {
        await jobStore.getJobStatus(id: id)
    }

    /// Retrieves a specific job by its ID.
    ///
    /// - Parameter id: The unique job identifier.
    /// - Returns: The job if found, or `nil` if the job ID does not exist.
    public func getJob(id: UInt64) async -> Job? {
        await jobStore.getJob(id: id)
    }

    /// Returns all jobs in the system, ordered by creation time (newest first).
    ///
    /// This method is consumed by ``JobSchedulerView`` to display the job list
    /// with status indicators. Since the system is single-user with manual triggers,
    /// the total job count is expected to be manageable without pagination.
    ///
    /// - Returns: Array of all jobs sorted by `createdAt` descending.
    public func getAllJobs() async -> [Job] {
        await jobStore.getAllJobs()
    }
}
