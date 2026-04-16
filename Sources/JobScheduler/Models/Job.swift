// Sources/JobScheduler/Models/Job.swift
// WealthLedger — Job Data Model with Associated Enums
//
// Defines the Job entity and all associated types for the JobScheduler module.
// Jobs represent manually triggered operations — either report generation
// (CSV export with field selection, account filtering, target date) or CSV
// file ingestion (parse and import reference data). No automated cron
// scheduling exists — all jobs are manually triggered by the user.

import Foundation

// MARK: - JobType

/// Defines the type of job that can be scheduled and executed.
///
/// Jobs are manually triggered — no automated cron scheduling exists.
/// - ``report``: CSV export with field selection, account filtering, and target date.
/// - ``ingestion``: Parse and import reference data from a local CSV file.
public enum JobType: String, Sendable, Codable, CaseIterable {
    /// Report generation job — CSV export with field selection, account filtering, and target date.
    case report = "report"

    /// CSV file ingestion job — parse and import reference data from a local CSV file.
    case ingestion = "ingestion"
}

// MARK: - JobStatus

/// Represents the lifecycle state of a job.
///
/// Jobs progress through states: pending → running → completed/failed.
/// All state transitions are managed by ``JobSchedulerService``.
///
/// Lifecycle flow:
/// ```
/// pending → running → completed
///                   → failed
/// ```
public enum JobStatus: String, Sendable, Codable, CaseIterable {
    /// Job has been created but not yet started execution.
    case pending = "pending"

    /// Job is currently executing.
    case running = "running"

    /// Job finished successfully.
    case completed = "completed"

    /// Job encountered an error during execution.
    case failed = "failed"
}

// MARK: - JobParameters

/// Typed parameters for job configuration.
///
/// For report jobs: ``fieldSelection``, ``accountSelection``, and ``targetDate`` are used.
/// For ingestion jobs: ``sourceFilePath`` and ``sourceFileType`` are used.
/// All fields are optional to accommodate both job types within a single structure.
///
/// Example usage for a report job:
/// ```swift
/// let reportParams = JobParameters(
///     fieldSelection: ["accountName", "value", "valueDate"],
///     accountSelection: [1001, 1002, 1003],
///     targetDate: Date(),
///     sourceFilePath: nil,
///     sourceFileType: nil
/// )
/// ```
///
/// Example usage for an ingestion job:
/// ```swift
/// let ingestionParams = JobParameters(
///     fieldSelection: nil,
///     accountSelection: nil,
///     targetDate: nil,
///     sourceFilePath: "/path/to/reference_data.csv",
///     sourceFileType: "reference_data"
/// )
/// ```
public struct JobParameters: Sendable, Codable, Equatable {
    /// Optional list of field names to include in report export.
    /// Used by report generation jobs for configurable column selection.
    /// Example: `["accountName", "accountId", "value", "valueDate"]`
    public let fieldSelection: [String]?

    /// Optional list of account IDs to filter the report.
    /// Used by report generation jobs for account-scoped reporting.
    /// Each ID corresponds to the `accounts.id` column (BIGINT UNSIGNED) in MySQL.
    /// Uses `UInt64` to match the BIGINT UNSIGNED type convention across all modules.
    public let accountSelection: [UInt64]?

    /// Optional target date for point-in-time reporting.
    /// Used by report generation jobs to specify the valuation date.
    /// The date is interpreted in each account's stored IANA timezone.
    public let targetDate: Date?

    /// Optional file path for CSV ingestion source.
    /// Used by ingestion jobs to locate the local CSV file on disk.
    /// Must be an absolute path or a path relative to the application's working directory.
    public let sourceFilePath: String?

    /// Optional type descriptor for CSV ingestion (e.g., `"reference_data"`).
    /// Used by ingestion jobs to determine the parsing strategy and target table.
    public let sourceFileType: String?

    /// Creates a new `JobParameters` instance.
    ///
    /// - Parameters:
    ///   - fieldSelection: Optional list of field names for report column selection.
    ///   - accountSelection: Optional list of account IDs for report filtering.
    ///   - targetDate: Optional target date for point-in-time reporting.
    ///   - sourceFilePath: Optional file path for CSV ingestion source.
    ///   - sourceFileType: Optional type descriptor for CSV ingestion parsing strategy.
    public init(
        fieldSelection: [String]?,
        accountSelection: [UInt64]?,
        targetDate: Date?,
        sourceFilePath: String?,
        sourceFileType: String?
    ) {
        self.fieldSelection = fieldSelection
        self.accountSelection = accountSelection
        self.targetDate = targetDate
        self.sourceFilePath = sourceFilePath
        self.sourceFileType = sourceFileType
    }
}

// MARK: - Job

/// Represents a schedulable job in the WealthLedger application.
///
/// Jobs are manually triggered operations — either report generation (CSV export)
/// or CSV file ingestion. No automated cron scheduling exists.
///
/// Job lifecycle: created (pending) → manually triggered (running) → completed or failed.
/// Jobs are managed by ``JobSchedulerService`` and displayed in ``JobSchedulerView``.
///
/// All properties are immutable (`let`) to ensure thread safety and value semantics
/// under Swift 6 strict concurrency.
///
/// The `id` property satisfies the ``Identifiable`` protocol requirement for SwiftUI
/// list rendering and diffing.
public struct Job: Sendable, Codable, Identifiable, Equatable {
    /// Unique job identifier, auto-incremented from the MySQL `jobs` table.
    /// Corresponds to `jobs.id` (BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY).
    /// Uses `UInt64` to match the BIGINT UNSIGNED type convention across all modules.
    public let id: UInt64

    /// The type of job: report generation or CSV ingestion.
    /// Determines which parameters are relevant and which execution path is taken.
    public let type: JobType

    /// Current lifecycle state of the job.
    /// Transitions: pending → running → completed or failed.
    public let status: JobStatus

    /// Typed job parameters containing field selection, account selection,
    /// target date, and source file information.
    /// Parameters are interpreted based on the ``type`` of the job.
    public let parameters: JobParameters

    /// Timestamp when the job was created.
    /// Set once at creation time and never modified.
    public let createdAt: Date

    /// Optional timestamp when the job completed or failed.
    /// `nil` while the job is in ``JobStatus/pending`` or ``JobStatus/running`` state.
    /// Set when the job transitions to ``JobStatus/completed`` or ``JobStatus/failed``.
    public let completedAt: Date?

    /// Creates a new `Job` instance.
    ///
    /// - Parameters:
    ///   - id: Unique job identifier from MySQL auto-increment.
    ///   - type: The type of job (report or ingestion).
    ///   - status: Current lifecycle state of the job.
    ///   - parameters: Typed job parameters for execution configuration.
    ///   - createdAt: Timestamp when the job was created.
    ///   - completedAt: Optional timestamp when the job completed or failed.
    public init(
        id: UInt64,
        type: JobType,
        status: JobStatus,
        parameters: JobParameters,
        createdAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.parameters = parameters
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
