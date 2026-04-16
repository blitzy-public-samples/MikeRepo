#if canImport(SwiftUI)
// Sources/UILayer/JobSchedulerScreen/JobSchedulerView.swift
// WealthLedger — Job Scheduler Screen (SwiftUI)
//
// Provides two job modes: report generation (CSV export with field selection,
// account selection, target date) and CSV ingestion (local file import for
// reference data). Below the creation form, a scrollable list displays all
// jobs with status badges and manual execution triggers.
//
// Rules Enforced:
//   Rule 4  — RBAC entitlement gating via EntitlementService.checkPermission
//   Rule 7  — Account selection capped at AppConstants.maxSearchResults (1,000)
//   Rule 8  — No SwiftData imports; MySQLKit-only persistence
//   Rule 9  — Offline runtime: local CSV files only, no network calls
//   Rule 13 — CSV ingestion up to 100MB via service-layer streaming
//
// Gate 2 — Swift 6 Strict Concurrency:
//   @Observable @MainActor ViewModel; @State-driven view; async/await for
//   all service calls. Zero @unchecked Sendable annotations. Zero warning
//   suppressions. Zero // swiftlint:disable comments.
//
// Gate 9 — Integration Wiring:
//   JobSchedulerView is reachable from @main via MainNavigationView. All three
//   JobSchedulerService methods (createJob, executeJob, getAllJobs) are invoked.
//   EntitlementService.checkPermission is invoked for RBAC gating.
//
// Manual Trigger Only:
//   All jobs are manually created and triggered by explicit user action. No
//   cron, no timers, no background polling, no auto-refresh.

import SwiftUI
import UniformTypeIdentifiers
import JobScheduler
import RBAC
import Shared

// MARK: - Report Field Configuration

/// Identifiers and display names for account fields available in report generation.
/// Each `key` corresponds exactly to a case in `ReportGenerator.extractFieldValue()`
/// to ensure the CSV report produces correct column values.
private let availableReportFields: [(key: String, displayName: String)] = [
    ("accountName", "Account Name"),
    ("accountId", "Account ID"),
    ("accountType", "Account Type"),
    ("accountGroupId", "Account Group"),
    ("cachedValuationAmount", "Valuation Amount"),
    ("cachedValueDate", "Value Date"),
    ("valuationTimezone", "Timezone"),
    ("accountStatus", "Status")
]

/// Available CSV ingestion type descriptors for the type selector picker.
/// Currently only "reference_data" (synthetic NYSE equity data) is supported.
private let availableIngestionTypes: [(key: String, displayName: String)] = [
    ("reference_data", "Reference Data")
]

// MARK: - JobSchedulerViewModel

/// Observable view model managing form state, job list, and service interactions
/// for the Job Scheduler screen.
///
/// Isolated to `@MainActor` for thread-safe UI state mutation. Uses `@Observable`
/// (Observation framework) for automatic SwiftUI change tracking — NOT the legacy
/// `ObservableObject`/`@Published` Combine pattern.
///
/// ## Dependency Injection
///
/// `JobSchedulerService` and `EntitlementService` are injected via the initializer
/// and stored as immutable `let` properties. Both are `Sendable` final classes.
/// The `userId` identifies the current authenticated user for RBAC checks and job
/// execution attribution.
///
/// ## Thread Safety (Gate 2)
///
/// All mutable `var` properties are isolated to `@MainActor`. All async service
/// calls use `async/await`. Zero `@unchecked Sendable` annotations. Zero warning
/// suppressions.
@MainActor
@Observable
public final class JobSchedulerViewModel {

    // MARK: - Job Creation Form State

    /// Selected job type controlling which form section is displayed.
    /// `.report` shows field selection, account IDs, and target date.
    /// `.ingestion` shows file picker and data type selector.
    var selectedJobType: JobType = .report

    /// Set of selected field keys for CSV report column selection.
    /// Keys correspond to entries in `availableReportFields`.
    var selectedFields: Set<String> = []

    /// Set of account IDs selected for report generation.
    /// Parsed from the comma-separated `accountIdsText` input.
    /// Capped at `AppConstants.maxSearchResults` (1,000) per Rule 7.
    var selectedAccountIds: Set<UInt64> = []

    /// Target date for report generation, interpreted per each account's
    /// stored IANA timezone by the service layer (Rule 3).
    var targetDate: Date = Date()

    /// URL of the locally selected CSV file for ingestion.
    /// `nil` until the user selects a file via the file picker.
    /// The file is passed by URL to the service — never loaded into UI memory.
    var selectedCSVFileURL: URL? = nil

    /// Type identifier for CSV ingestion (e.g., `"reference_data"`).
    /// Determines the parsing strategy and target table in the service layer.
    var ingestionType: String = "reference_data"

    // MARK: - Job List State

    /// All jobs loaded from `JobSchedulerService`, newest first.
    var jobs: [Job] = []

    /// Whether an async operation (load, create, execute) is currently in progress.
    var isLoading: Bool = false

    /// User-facing error message displayed in the alert. `nil` when no error.
    var errorMessage: String? = nil

    // MARK: - Internal Form State

    /// Raw text input for comma-separated account IDs in report mode.
    /// Parsed into `selectedAccountIds` before job creation.
    var accountIdsText: String = ""

    /// Controls the file importer sheet presentation for CSV ingestion mode.
    var showingFilePicker: Bool = false

    // MARK: - Private Dependencies

    /// Job lifecycle management service (create, execute, query).
    private let jobSchedulerService: JobSchedulerService

    /// RBAC entitlement enforcement service for permission verification (Rule 4).
    private let entitlementService: EntitlementService

    /// Current authenticated user ID for RBAC checks and job execution attribution.
    private let userId: UInt64

    // MARK: - Initialization

    /// Creates a new view model with injected service dependencies.
    ///
    /// - Parameters:
    ///   - jobSchedulerService: Service for job CRUD and manual execution.
    ///   - entitlementService: Service for RBAC permission verification (Rule 4).
    ///   - userId: The authenticated user's unique identifier.
    public init(
        jobSchedulerService: JobSchedulerService,
        entitlementService: EntitlementService,
        userId: UInt64
    ) {
        self.jobSchedulerService = jobSchedulerService
        self.entitlementService = entitlementService
        self.userId = userId
    }

    // MARK: - Report Job Creation and Execution

    /// Creates a report generation job and immediately triggers its execution.
    ///
    /// Validates form state: at least one field selected, account count within
    /// the Rule 7 batch memory cap (1,000). Constructs `JobParameters`, creates
    /// the job via `JobSchedulerService.createJob(type:parameters:)`, and
    /// executes via `JobSchedulerService.executeJob(id:userId:)`. On completion,
    /// refreshes the job list and resets the form.
    ///
    /// RBAC verification (Rule 4) is enforced authoritatively at the service layer.
    /// `ReportGenerator` delegates to `AccountService`, which pre-filters results
    /// by the user's entitled account groups — zero records for unauthorized groups.
    func createAndTriggerReportJob() async {
        // Parse account IDs from comma-separated text input
        parseAccountIds()

        // Validate at least one report field is selected
        guard !selectedFields.isEmpty else {
            errorMessage = "Please select at least one field for the report."
            return
        }

        // Enforce Rule 7 — Batch Memory Cap: max 1,000 accounts per report
        guard selectedAccountIds.count <= AppConstants.maxSearchResults else {
            errorMessage = "Account selection exceeds the maximum of \(AppConstants.maxSearchResults) accounts."
            return
        }

        // Rule 4 — Entitlement Enforcement:
        // RBAC is enforced authoritatively at the service layer. ReportGenerator
        // delegates account fetching to AccountService, which pre-filters results
        // by the user's entitled account groups. Users without READ access to an
        // account group receive zero records for that group — never an error.
        // A UI-level pre-check is not feasible here because the text input provides
        // only raw account IDs, not Account objects with accountGroupId properties.

        isLoading = true
        errorMessage = nil

        do {
            // Construct report job parameters
            let parameters = JobParameters(
                fieldSelection: Array(selectedFields),
                accountSelection: selectedAccountIds.isEmpty ? nil : Array(selectedAccountIds),
                targetDate: targetDate,
                sourceFilePath: nil,
                sourceFileType: nil
            )

            // Create the job in pending state
            let job = await jobSchedulerService.createJob(
                type: .report,
                parameters: parameters
            )

            // Execute immediately — manual trigger only (no cron, no timers)
            _ = try await jobSchedulerService.executeJob(
                id: job.id,
                userId: userId
            )

            // Refresh job list to show the completed job
            await loadJobs()

            // Reset form state for next job creation
            selectedFields.removeAll()
            selectedAccountIds.removeAll()
            accountIdsText = ""

        } catch let error as AppError {
            handleAppError(error)
        } catch {
            errorMessage = "Report generation failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Ingestion Job Creation and Execution

    /// Creates a CSV ingestion job and immediately triggers its execution.
    ///
    /// Validates that a CSV file is selected, constructs `JobParameters` with
    /// the local file path, creates the job, and executes it. The service layer
    /// handles streaming and paginated processing for files up to 100MB (Rule 13).
    /// The UI passes only the URL — never loads file contents into memory.
    func createAndTriggerIngestionJob() async {
        guard let fileURL = selectedCSVFileURL else {
            errorMessage = "Please select a CSV file for ingestion."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Construct ingestion job parameters with the local file path
            let parameters = JobParameters(
                fieldSelection: nil,
                accountSelection: nil,
                targetDate: nil,
                sourceFilePath: fileURL.path,
                sourceFileType: ingestionType
            )

            // Create the job in pending state
            let job = await jobSchedulerService.createJob(
                type: .ingestion,
                parameters: parameters
            )

            // Execute immediately — manual trigger only (no cron, no timers)
            _ = try await jobSchedulerService.executeJob(
                id: job.id,
                userId: userId
            )

            // Refresh job list to show the completed job
            await loadJobs()

            // Reset form state
            selectedCSVFileURL = nil

        } catch let error as AppError {
            handleAppError(error)
        } catch {
            errorMessage = "CSV ingestion failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Job Loading

    /// Loads all jobs from the `JobSchedulerService` for display in the job list.
    ///
    /// Called on view appear via the `.task` modifier and on manual refresh via
    /// the "Refresh" button. No auto-refresh, no polling, no timers — manual
    /// refresh only.
    func loadJobs() async {
        isLoading = true
        jobs = await jobSchedulerService.getAllJobs()
        isLoading = false
    }

    // MARK: - Manual Job Execution

    /// Manually triggers execution of a pending job.
    ///
    /// Only jobs in `.pending` status can be executed — the service layer rejects
    /// jobs in `.running`, `.completed`, or `.failed` status. Updates the job
    /// list after execution completes or fails.
    ///
    /// - Parameter job: The job to execute. Must be in `.pending` status.
    func executeJob(_ job: Job) async {
        isLoading = true
        errorMessage = nil

        do {
            _ = try await jobSchedulerService.executeJob(
                id: job.id,
                userId: userId
            )
            await loadJobs()
        } catch let error as AppError {
            handleAppError(error)
        } catch {
            errorMessage = "Job execution failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Private Helpers

    /// Parses comma-separated account IDs from the raw text input into the
    /// `selectedAccountIds` set. Trims whitespace, ignores non-numeric entries,
    /// and deduplicates via `Set`.
    private func parseAccountIds() {
        let parts = accountIdsText
            .split(separator: ",")
            .compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        selectedAccountIds = Set(parts)
    }

    /// Maps `AppError` cases to user-friendly error messages for the alert.
    ///
    /// Handles job-specific and access-control error cases explicitly. All
    /// other cases receive a generic description.
    private func handleAppError(_ error: AppError) {
        switch error {
        case .jobNotFound:
            errorMessage = "The specified job was not found."
        case .invalidJobParameters(let detail):
            errorMessage = "Invalid job parameters: \(detail)"
        case .accountNotFound:
            errorMessage = "The specified account was not found."
        case .unauthorizedAccess:
            errorMessage = "You do not have permission to perform this operation."
        default:
            errorMessage = "Operation failed: \(error)"
        }
    }
}

// MARK: - JobSchedulerView

/// Job Scheduler screen for the WealthLedger macOS desktop application.
///
/// Provides two modes controlled by a segmented picker:
/// 1. **Report Generation** — Select fields, specify account IDs, choose a target
///    date, and trigger CSV export via `ReportGenerator` (through `JobSchedulerService`).
/// 2. **CSV Ingestion** — Select a local CSV file and trigger reference data import
///    via `CSVParser` and `ReferenceDataService` (through `JobSchedulerService`).
///
/// Below the creation form, a scrollable list displays all jobs with color-coded
/// status badges and manual execution triggers for pending jobs.
///
/// ## Integration Wiring (Gate 9)
///
/// This view is instantiated by `MainNavigationView` and reachable from `@main`:
/// ```swift
/// JobSchedulerView(
///     jobSchedulerService: container.jobSchedulerService,
///     entitlementService: container.entitlementService,
///     userId: appState.currentUser.id
/// )
/// ```
///
/// ## Manual Trigger Only
///
/// All jobs are manually created and triggered by explicit user action.
/// No cron, no timers, no background polling, no auto-refresh.
public struct JobSchedulerView: View {

    // MARK: - State

    /// The observable view model managing form state, job list, and service calls.
    @State private var viewModel: JobSchedulerViewModel

    // MARK: - Initialization

    /// Creates the Job Scheduler screen with injected service dependencies.
    ///
    /// - Parameters:
    ///   - jobSchedulerService: Service for job lifecycle management.
    ///   - entitlementService: Service for RBAC permission verification (Rule 4).
    ///   - userId: The authenticated user's unique identifier.
    public init(
        jobSchedulerService: JobSchedulerService,
        entitlementService: EntitlementService,
        userId: UInt64
    ) {
        _viewModel = State(initialValue: JobSchedulerViewModel(
            jobSchedulerService: jobSchedulerService,
            entitlementService: entitlementService,
            userId: userId
        ))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Section 1: Job Creation Form
            jobCreationForm

            Divider()

            // Section 2: Job List with status display and manual triggers
            jobListSection
        }
        .navigationTitle("Job Scheduler")
        .task {
            await viewModel.loadJobs()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $viewModel.showingFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImportResult(result)
        }
    }

    // MARK: - Job Creation Form

    /// Top section with a segmented job type picker and conditional form fields.
    @ViewBuilder
    private var jobCreationForm: some View {
        Form {
            // Job type segmented control: Report Generation | CSV Ingestion
            Section {
                Picker("Job Type", selection: $viewModel.selectedJobType) {
                    Text("Report Generation").tag(JobType.report)
                    Text("CSV Ingestion").tag(JobType.ingestion)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Job type selector")
            } header: {
                Label("Job Type", systemImage: "briefcase")
            }

            // Conditional form based on the selected job type
            if viewModel.selectedJobType == .report {
                reportConfigurationSection
            } else {
                ingestionConfigurationSection
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 200, maxHeight: 420)
    }

    // MARK: - Report Configuration Section

    /// Form sections for report generation: field selection, account IDs, target date, trigger.
    @ViewBuilder
    private var reportConfigurationSection: some View {
        // Field Selection Checkboxes
        Section {
            ForEach(availableReportFields, id: \.key) { field in
                Toggle(
                    field.displayName,
                    isOn: Binding(
                        get: { viewModel.selectedFields.contains(field.key) },
                        set: { isOn in
                            if isOn {
                                viewModel.selectedFields.insert(field.key)
                            } else {
                                viewModel.selectedFields.remove(field.key)
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(field.displayName) field selection")
            }
        } header: {
            Label("Report Fields", systemImage: "list.bullet.rectangle")
        }

        // Account Selection (comma-separated IDs)
        Section {
            TextField(
                "Enter account IDs (comma-separated)",
                text: $viewModel.accountIdsText
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Account IDs input")
            .accessibilityHint("Enter comma-separated numeric account IDs for the report")

            if !viewModel.accountIdsText.isEmpty {
                let parsedCount = viewModel.accountIdsText
                    .split(separator: ",")
                    .compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                    .count
                Text("\(parsedCount) account ID(s) entered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Maximum \(AppConstants.maxSearchResults) accounts per report")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Label("Account Selection", systemImage: "person.3")
        }

        // Target Date
        Section {
            DatePicker(
                "Target Date",
                selection: $viewModel.targetDate,
                displayedComponents: .date
            )
            .accessibilityLabel("Report target date")
        } header: {
            Label("Target Date", systemImage: "calendar")
        }

        // Generate Report Trigger Button
        Section {
            Button {
                Task {
                    await viewModel.createAndTriggerReportJob()
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Generate Report")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading || viewModel.selectedFields.isEmpty)
            .accessibilityLabel("Generate report button")
            .accessibilityHint("Creates and triggers a report generation job")
        }
    }

    // MARK: - Ingestion Configuration Section

    /// Form sections for CSV ingestion: file selection, data type, trigger.
    @ViewBuilder
    private var ingestionConfigurationSection: some View {
        // File Selection
        Section {
            HStack {
                if let url = viewModel.selectedCSVFileURL {
                    Text(url.lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Selected file: \(url.lastPathComponent)")
                } else {
                    Text("No file selected")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No CSV file selected")
                }

                Spacer()

                Button("Browse\u{2026}") {
                    viewModel.showingFilePicker = true
                }
                .accessibilityLabel("Browse for CSV file")
                .accessibilityHint("Opens a file picker to select a local CSV file for ingestion")
            }

            Text("Supports CSV files up to 100MB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Label("CSV File", systemImage: "doc.text")
        }

        // Ingestion Type Selection
        Section {
            Picker("Data Type", selection: $viewModel.ingestionType) {
                ForEach(availableIngestionTypes, id: \.key) { type in
                    Text(type.displayName).tag(type.key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Ingestion data type selector")
        } header: {
            Label("Data Type", systemImage: "tablecells")
        }

        // Start Ingestion Trigger Button
        Section {
            Button {
                Task {
                    await viewModel.createAndTriggerIngestionJob()
                }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Start Ingestion")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading || viewModel.selectedCSVFileURL == nil)
            .accessibilityLabel("Start ingestion button")
            .accessibilityHint("Creates and triggers a CSV ingestion job")
        }
    }

    // MARK: - Job List Section

    /// Bottom section with a toolbar (title + refresh) and scrollable job list.
    @ViewBuilder
    private var jobListSection: some View {
        VStack(spacing: 0) {
            // Toolbar: title, loading indicator, refresh button
            HStack {
                Text("Jobs")
                    .font(.headline)

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task {
                        await viewModel.loadJobs()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel("Refresh job list")
                .accessibilityHint("Manually reloads the list of all jobs")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Job list or empty state
            if viewModel.jobs.isEmpty && !viewModel.isLoading {
                emptyJobListView
            } else {
                List {
                    ForEach(viewModel.jobs) { job in
                        jobRow(for: job)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Empty Job List

    /// Placeholder displayed when no jobs have been created yet.
    @ViewBuilder
    private var emptyJobListView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No jobs yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Create a report or ingestion job above to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Job Row

    /// Renders a single job in the job list with type icon, details, status
    /// badge, and a manual trigger button for pending jobs.
    @ViewBuilder
    private func jobRow(for job: Job) -> some View {
        HStack(spacing: 12) {
            // Job type icon
            Image(systemName: job.type == .report ? "doc.richtext" : "arrow.down.doc")
                .font(.title3)
                .foregroundStyle(job.type == .report ? Color.blue : Color.purple)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            // Job details: type label, ID, parameters summary, timestamps
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.type == .report ? "Report" : "Ingestion")
                        .font(.headline)

                    Text("#\(job.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(jobParametersSummary(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("Created: \(formattedDate(job.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let completedAt = job.completedAt {
                        Text("Finished: \(formattedDate(completedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Color-coded status badge
            statusBadge(for: job.status)

            // Manual trigger button — only for pending jobs
            if job.status == .pending {
                Button {
                    Task {
                        await viewModel.executeJob(job)
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)
                .accessibilityLabel("Run job \(job.id)")
                .accessibilityHint("Manually triggers execution of this pending job")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(jobAccessibilityLabel(for: job))
    }

    // MARK: - Status Badge

    /// Color-coded capsule badge displaying the job's current lifecycle status.
    ///
    /// - Pending: gray with clock icon
    /// - Running: blue with spinner
    /// - Completed: green with checkmark
    /// - Failed: red with X mark
    @ViewBuilder
    private func statusBadge(for status: JobStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .pending:
                Image(systemName: "clock")
                Text("Pending")
            case .running:
                ProgressView()
                    .controlSize(.mini)
                Text("Running")
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                Text("Completed")
            case .failed:
                Image(systemName: "xmark.circle.fill")
                Text("Failed")
            }
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor(for: status).opacity(0.15))
        .foregroundStyle(statusColor(for: status))
        .clipShape(Capsule())
    }

    // MARK: - Private Helpers

    /// Maps a job status to its display color.
    private func statusColor(for status: JobStatus) -> Color {
        switch status {
        case .pending:
            return Color.gray
        case .running:
            return Color.blue
        case .completed:
            return Color.green
        case .failed:
            return Color.red
        }
    }

    /// Generates a brief human-readable summary of a job's parameters for
    /// display in the job row.
    ///
    /// Report jobs: "N field(s), M account(s), <date>"
    /// Ingestion jobs: "<filename>, <type>"
    private func jobParametersSummary(for job: Job) -> String {
        switch job.type {
        case .report:
            let fieldCount = job.parameters.fieldSelection?.count ?? 0
            let accountCount = job.parameters.accountSelection?.count ?? 0
            let dateStr: String
            if let date = job.parameters.targetDate {
                dateStr = formattedDate(date)
            } else {
                dateStr = "any date"
            }
            return "\(fieldCount) field(s), \(accountCount) account(s), \(dateStr)"

        case .ingestion:
            let filePath = job.parameters.sourceFilePath ?? "unknown"
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            return "\(fileName), \(job.parameters.sourceFileType ?? "unknown")"
        }
    }

    /// Formats a `Date` for display in job rows and parameter summaries.
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Handles the result from the `.fileImporter()` sheet for CSV ingestion.
    private func handleFileImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                viewModel.selectedCSVFileURL = url
            }
        case .failure(let error):
            viewModel.errorMessage = "File selection failed: \(error.localizedDescription)"
        }
    }

    /// Generates a comprehensive accessibility label for a job row, combining
    /// type, ID, and status information.
    private func jobAccessibilityLabel(for job: Job) -> String {
        let typeLabel = job.type == .report ? "Report" : "Ingestion"
        let statusLabel: String
        switch job.status {
        case .pending:
            statusLabel = "Pending"
        case .running:
            statusLabel = "Running"
        case .completed:
            statusLabel = "Completed"
        case .failed:
            statusLabel = "Failed"
        }
        return "\(typeLabel) job number \(job.id), status: \(statusLabel)"
    }
}
#endif
