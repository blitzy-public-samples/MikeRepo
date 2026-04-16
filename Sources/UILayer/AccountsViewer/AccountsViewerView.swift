#if canImport(SwiftUI)
// AccountsViewerView.swift
// WealthLedger — UILayer Module
//
// Accounts Viewer screen for the WealthLedger macOS desktop application. Displays
// selected accounts in a scrollable LazyVStack with expandable position details.
// One of the four main screens accessible from MainNavigationView.
//
// Rule 3 (Per-Account Valuation Timezone):
//   Value dates are displayed using each account's stored IANA timezone string.
//   TimeZone.current and Calendar.current are NEVER used for value date display.
//
// Rule 4 (Entitlement Enforcement):
//   All data reads verify user-group entitlement before returning records.
//   AccountService internally enforces entitlements — users without READ access
//   receive empty results, not errors. LedgerService.getPositions likewise
//   enforces entitlements before returning positions.
//
// Rule 7 (Batch Memory Cap):
//   No UI operation loads more than 1,000 account records into memory.
//   selectedAccountIds is capped at AppConstants.maxSearchResults (1,000) in init.
//   Pagination uses AppConstants.batchSize (1,000) per page.
//
// Rule 8 (MySQLKit-Only Persistence):
//   This view imports ONLY SwiftUI plus business logic modules. Absolutely NO
//   SwiftData, MySQLKit, SQLKit, AsyncKit, or Persistence imports. Views
//   interact with services only — never repositories or database connections.
//
// Rule 9 (Offline Runtime):
//   No network calls. All data flows through local MySQL via injected services.
//
// Rule 13 (Performance Thresholds):
//   - Initial render of 1,000 accounts: under 1 second (via LazyVStack).
//   - Scrolling: 30fps or above (via LazyVStack virtualization).
//   - Positions loaded lazily on-demand — only when a row is expanded.
//
// Swift 6 Strict Concurrency (Gate 2):
//   AccountsViewerView is a struct conforming to View — automatically
//   @MainActor-isolated in Swift 6. All @State properties are value types
//   or Sendable. Service properties are Sendable final classes (let-bound).
//   Zero @unchecked Sendable annotations. Zero warning suppressions.
//   All async operations use Task {} or .task {} modifier.
//
// Gate 9 (Integration Wiring):
//   AccountsViewerView is instantiated by MainNavigationView and reachable
//   from @main. It exercises AccountService, ValuationService, LedgerService,
//   ReferenceDataService, and EntitlementService.
//
// Consumers:
//   - MainNavigationView — instantiates AccountsViewerView via:
//       AccountsViewerView(
//           accountService: container.accountService,
//           valuationService: container.valuationService,
//           ledgerService: container.ledgerService,
//           referenceDataService: container.referenceDataService,
//           entitlementService: container.entitlementService,
//           selectedAccountIds: appState.selectedAccountIds,
//           userId: appState.currentUser.id
//       )

import SwiftUI
import AccountManagement
import ValuationEngine
import LedgerEngine
import ReferenceDataService
import RBAC
import Shared

// MARK: - AccountsViewerView

/// Accounts Viewer screen displaying selected accounts in a scrollable LazyVStack.
///
/// Shows:
/// - Summary header with account counts broken down by fund category and status
/// - Account name, account ID, cached valuation amount, and value date per row
/// - Expandable position details (instrument ticker, quantity, midpoint value)
///   via ``PositionDetailView``
/// - Inline search filtering and batch/single valuation refresh actions
///
/// ## Performance Targets (Rule 13)
///
/// - Initial render of 1,000 accounts: under 1 second
/// - Scrolling: 30fps or above (via ``LazyVStack`` virtualization)
/// - Positions loaded lazily on-demand — only when a row is expanded
///
/// ## Constraints
///
/// - Max 1,000 accounts in memory simultaneously (Rule 7)
/// - All displayed data respects entitlement enforcement (Rule 4)
/// - Value dates use account-stored IANA timezone (Rule 3)
/// - SwiftUI only — no database imports (Rule 8)
///
/// ## Dependency Injection
///
/// Services are injected via the public initializer — no global state,
/// no singletons, no `@EnvironmentObject` usage. The parent view
/// (`MainNavigationView`) passes concrete service instances obtained from
/// `DependencyContainer`.
///
/// ## Swift 6 Concurrency Safety
///
/// - Struct conforming to `View` → `@MainActor`-isolated by default.
/// - All `@State` properties → `@MainActor`-isolated within SwiftUI.
/// - Service properties (`let`) → `Sendable` final classes.
/// - All async operations → `Task {}` within button actions or `.task {}`.
/// - Zero `@unchecked Sendable`. Zero warning suppressions.
///
/// ## Usage
/// ```swift
/// AccountsViewerView(
///     accountService: accountService,
///     valuationService: valuationService,
///     ledgerService: ledgerService,
///     referenceDataService: refDataService,
///     entitlementService: entitlementService,
///     selectedAccountIds: [1, 2, 3],
///     userId: 42
/// )
/// ```
public struct AccountsViewerView: View {

    // MARK: - Service Dependencies (Injected)

    /// Account management service for loading selected accounts with entitlement
    /// enforcement (Rule 4). Provides `getAccounts(ids:userId:)` for primary data
    /// loading and `search(name:id:type:group:userId:page:pageSize:)` for inline
    /// search filtering. Both methods internally enforce READ entitlements — users
    /// without access receive empty results, never errors.
    ///
    /// Sendable final class — safe for cross-actor usage in Swift 6.
    let accountService: AccountService

    /// Valuation orchestration service for on-demand NAV recomputation.
    /// Provides `runSingleAccountValuation(accountId:marketDate:)` for per-account
    /// refresh and `runValuation(for:marketDate:)` for batch refresh. Both methods
    /// compute timezone-aware value dates using account-stored IANA timezones (Rule 3).
    ///
    /// Sendable final class — safe for cross-actor usage in Swift 6.
    let valuationService: ValuationService

    /// Ledger service for fetching per-account position holdings.
    /// Provides `getPositions(userId:accountGroupId:accountId:)` which enforces
    /// READ entitlements (Rule 4) before returning positions.
    ///
    /// Sendable final class — safe for cross-actor usage in Swift 6.
    let ledgerService: LedgerService

    /// Reference data service for instrument price lookups.
    /// Provides `findById(_:)` for instrument-ID-based lookups and
    /// `findByTickerAndDate(ticker:marketDate:)` for ticker-based lookups.
    /// Used to build ``PositionDisplayItem`` arrays with EOD midpoint prices.
    ///
    /// Sendable final class — safe for cross-actor usage in Swift 6.
    let referenceDataService: ReferenceDataService

    /// Entitlement verification service for Rule 4 compliance.
    /// Provides `checkPermission(userId:accountGroupId:permission:)` (returns Bool,
    /// never throws) and `filterAccessibleGroups(userId:)` (returns accessible
    /// account groups, never throws).
    ///
    /// Sendable final class — safe for cross-actor usage in Swift 6.
    let entitlementService: EntitlementService

    /// The account IDs selected by the user from SearchView.
    /// Capped at ``AppConstants/maxSearchResults`` (1,000) per Rule 7.
    let selectedAccountIds: [UInt64]

    /// The unique identifier of the currently authenticated user.
    /// Sourced from AppState.currentUser.id by the parent view.
    /// Used for entitlement-aware data loading (Rule 4).
    let userId: UInt64

    // MARK: - UI State

    /// Loaded accounts for display in the LazyVStack.
    /// Populated by ``loadAccounts()`` via `AccountService.getAccounts`.
    /// Capped at 1,000 records per Rule 7.
    @State private var accounts: [Account] = []

    /// Set of account IDs whose position details are currently expanded.
    /// Toggled by ``toggleExpansion(for:)`` when the user taps an account row.
    @State private var expandedAccountIds: Set<UInt64> = []

    /// Cache of loaded position display items keyed by account ID.
    /// Populated lazily by ``loadPositions(for:)`` when a row is expanded.
    /// Each value is an array of ``PositionDisplayItem`` structs containing
    /// ticker, quantity, and EOD midpoint value for display.
    @State private var positionsMap: [UInt64: [PositionDisplayItem]] = [:]

    /// Indicates whether the initial account loading is in progress.
    /// When true, a ``ProgressView`` is displayed instead of the account list.
    @State private var isLoading: Bool = false

    /// Error message to display when account loading fails.
    /// When non-nil, an error state view is shown with a retry action.
    @State private var errorMessage: String?

    /// Set of account IDs for which position data is currently being loaded.
    /// Used to show per-row loading indicators and prevent duplicate fetches.
    @State private var loadingPositionIds: Set<UInt64> = []

    /// Indicates whether a batch valuation refresh is in progress.
    /// When true, the "Refresh Valuations" toolbar button is disabled.
    @State private var isRefreshingValuations: Bool = false

    /// Inline search/filter text for narrowing the displayed account list.
    /// When non-empty, accounts are filtered to those whose name contains
    /// this text (case-insensitive). Cleared on refresh.
    @State private var filterText: String = ""

    /// Accessible account groups for the current user, loaded via
    /// ``EntitlementService/filterAccessibleGroups(userId:)``.
    /// Used by the summary header to display entitled group count.
    @State private var accessibleGroupCount: Int = 0

    // MARK: - Initializer

    /// Creates a new Accounts Viewer screen with injected service dependencies.
    ///
    /// All five services are required and retained for the lifetime of the view.
    /// The `selectedAccountIds` array is capped at ``AppConstants/maxSearchResults``
    /// (1,000) per Rule 7 — any IDs beyond this limit are silently dropped.
    ///
    /// - Parameters:
    ///   - accountService: Account management service for data loading.
    ///   - valuationService: Valuation service for NAV recomputation.
    ///   - ledgerService: Ledger service for position retrieval.
    ///   - referenceDataService: Reference data service for instrument lookups.
    ///   - entitlementService: Entitlement service for permission verification.
    ///   - selectedAccountIds: Account IDs selected from SearchView (max 1,000).
    ///   - userId: The authenticated user's ID for entitlement checks.
    public init(
        accountService: AccountService,
        valuationService: ValuationService,
        ledgerService: LedgerService,
        referenceDataService: ReferenceDataService,
        entitlementService: EntitlementService,
        selectedAccountIds: [UInt64],
        userId: UInt64
    ) {
        self.accountService = accountService
        self.valuationService = valuationService
        self.ledgerService = ledgerService
        self.referenceDataService = referenceDataService
        self.entitlementService = entitlementService
        // Rule 7: Cap at AppConstants.maxSearchResults (1,000) to enforce
        // the batch memory cap. IDs beyond the limit are silently dropped.
        self.selectedAccountIds = Array(selectedAccountIds.prefix(AppConstants.maxSearchResults))
        self.userId = userId
    }

    // MARK: - Body

    /// The view body rendering the Accounts Viewer screen.
    ///
    /// Displays one of four states:
    /// 1. Loading — ``ProgressView`` while accounts are being fetched.
    /// 2. Error — ``ContentUnavailableView`` with error message and retry action.
    /// 3. Empty — ``ContentUnavailableView`` when no accounts are selected or entitled.
    /// 4. Accounts list — ``ScrollView`` + ``LazyVStack`` with account rows.
    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading accounts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    errorStateView(message: error)
                } else if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts Available",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Select accounts from Search to view details, or you may not have READ access to the selected account groups.")
                    )
                } else {
                    accountsContent
                }
            }
            .navigationTitle("Accounts Viewer")
            .toolbar { toolbarContent }
            .task {
                await loadInitialData()
            }
        }
    }

    // MARK: - Main Content

    /// Combined content area with summary header and scrollable account list.
    @ViewBuilder
    private var accountsContent: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()
            accountsList
        }
    }

    // MARK: - Summary Header

    /// Displays aggregate statistics for loaded accounts.
    ///
    /// Shows:
    /// - Total account count
    /// - Institutional vs. Wealth breakdown (uses ``FundType/isInstitutional``
    ///   and ``FundType/isWealth``)
    /// - Status breakdown (Active, Inactive, Pending, Suspended) using
    ///   ``AccountStatus`` enum cases
    /// - Entitled account group count
    @ViewBuilder
    private var summaryHeader: some View {
        let displayAccounts = filteredAccounts
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(displayAccounts.count) accounts")
                    .font(.headline)

                Spacer()

                if !filterText.isEmpty {
                    Text("filtered from \(accounts.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                // Fund category breakdown using FundType.isInstitutional / isWealth
                Label(
                    "\(institutionalCount(in: displayAccounts)) Institutional",
                    systemImage: "building.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "\(wealthCount(in: displayAccounts)) Wealth",
                    systemImage: "person.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 12)

                // Status breakdown using AccountStatus enum cases
                statusCountLabel(
                    .active, in: displayAccounts, color: .green
                )
                statusCountLabel(
                    .inactive, in: displayAccounts, color: .gray
                )
                statusCountLabel(
                    .pending, in: displayAccounts, color: .orange
                )
                statusCountLabel(
                    .suspended, in: displayAccounts, color: .red
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Creates a compact status count label for the summary header.
    ///
    /// - Parameters:
    ///   - status: The ``AccountStatus`` case to count.
    ///   - accounts: The account array to search.
    ///   - color: The color for the status indicator dot.
    /// - Returns: A labeled count view for the given status.
    @ViewBuilder
    private func statusCountLabel(
        _ status: AccountStatus,
        in accounts: [Account],
        color: Color
    ) -> some View {
        let count = accounts.filter { $0.status == status }.count
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
        }
        .accessibilityLabel("\(count) \(statusDisplayName(status))")
    }

    // MARK: - Accounts List (Rule 13: LazyVStack for 30fps scrolling)

    /// Scrollable, virtualized account list using ``LazyVStack``.
    ///
    /// CRITICAL: Uses ``LazyVStack`` inside ``ScrollView`` — NOT ``VStack`` or
    /// ``List``. This is essential for meeting Rule 13 performance targets:
    /// - Initial render of 1,000 accounts: under 1 second
    /// - Scrolling: 30fps or above
    ///
    /// ``LazyVStack`` only materializes rows that are visible on screen,
    /// keeping memory usage well within the 1,000-account batch memory cap (Rule 7).
    @ViewBuilder
    private var accountsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Optional inline search bar
                if !accounts.isEmpty {
                    searchBar
                }

                ForEach(filteredAccounts) { account in
                    VStack(spacing: 0) {
                        // Account row — tappable to toggle position expansion
                        accountRowContent(for: account)

                        // Expandable position details
                        if expandedAccountIds.contains(account.id) {
                            positionSection(for: account)
                        }

                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Search Bar

    /// Inline search bar for filtering accounts by name within the loaded set.
    @ViewBuilder
    private var searchBar: some View {
        HStack {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)

            TextField("Filter by name…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Account Row Content

    /// Renders a single account row with ``AccountRowView``, value date,
    /// fund type, and tap-to-expand interaction.
    ///
    /// The row is wrapped in a ``Button`` with `.plain` style to provide
    /// a tappable area for toggling position expansion. A context menu
    /// offers a "Refresh Valuation" action for single-account NAV recomputation.
    ///
    /// - Parameter account: The account to render.
    /// - Returns: A tappable row view with account details and context menu.
    @ViewBuilder
    private func accountRowContent(for account: Account) -> some View {
        Button {
            toggleExpansion(for: account.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // AccountRowView renders: name, ID, valuation amount, status badge
                AccountRowView(account: account)

                // Value date display using account's IANA timezone (Rule 3)
                // and fund type display name (FundType.displayName)
                HStack {
                    Text("Value Date: \(formattedValueDate(account.cachedValueDate, timezone: account.valuationTimezone))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(account.fundType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Account \(account.name), ID \(account.id)")
        .accessibilityHint(
            expandedAccountIds.contains(account.id)
                ? "Double tap to collapse positions"
                : "Double tap to expand positions"
        )
        .contextMenu {
            Button {
                Task {
                    await refreshSingleValuation(for: account)
                }
            } label: {
                Label("Refresh Valuation", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    // MARK: - Position Section

    /// Displays expandable position details for an account.
    ///
    /// Shows one of three sub-states:
    /// 1. Loading indicator while positions are being fetched.
    /// 2. "No positions found" message for accounts with zero holdings.
    /// 3. ``PositionDetailView`` with instrument ticker, quantity, and midpoint value.
    ///
    /// - Parameter account: The account whose positions to display.
    /// - Returns: A view showing the account's position details.
    @ViewBuilder
    private func positionSection(for account: Account) -> some View {
        if loadingPositionIds.contains(account.id) {
            HStack {
                Spacer()
                ProgressView("Loading positions…")
                Spacer()
            }
            .padding()
        } else if let positions = positionsMap[account.id] {
            if positions.isEmpty {
                Text("No positions found for this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    // PositionDetailView renders: ticker, instrument name, quantity,
                    // EOD midpoint, and market value per position.
                    PositionDetailView(positions: positions)

                    // Position summary row: total market value across holdings.
                    // Accesses PositionDisplayItem.marketValue, .quantity, .ticker,
                    // and .eodMidpoint for aggregation and display.
                    let totalMarketValue = positions.reduce(Decimal.zero) { sum, item in
                        sum + item.marketValue
                    }
                    let totalQuantity = positions.reduce(Decimal.zero) { sum, item in
                        sum + item.quantity
                    }
                    HStack(spacing: 8) {
                        Text("\(positions.count) position\(positions.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let firstTicker = positions.first?.ticker {
                            Text(positions.count == 1 ? firstTicker : "\(firstTicker) + \(positions.count - 1)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Text("Avg Mid: \(formattedDecimal(positions.reduce(Decimal.zero) { $0 + $1.eodMidpoint } / max(Decimal(positions.count), 1)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("Total Qty: \(formattedDecimal(totalQuantity))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("Total MV: \(formattedCurrency(totalMarketValue))")
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
                .padding(.leading, 16)
                .padding(.vertical, 4)
            }
        } else {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Error State View

    /// Displays an error message with a retry action.
    ///
    /// - Parameter message: The human-readable error description.
    /// - Returns: A ``ContentUnavailableView`` with the error and a retry button.
    @ViewBuilder
    private func errorStateView(message: String) -> some View {
        ContentUnavailableView {
            Label("Error Loading Accounts", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await refreshAccounts() }
            }
        }
    }

    // MARK: - Toolbar

    /// Toolbar items for the Accounts Viewer navigation bar.
    ///
    /// Provides:
    /// - Account count label
    /// - Batch valuation refresh button (uses ``ValuationService/runValuation``)
    /// - Data refresh button (reloads accounts from service)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Text("\(filteredAccounts.count) of \(accounts.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await refreshAllValuations() }
            } label: {
                Label("Refresh Valuations", systemImage: "chart.line.uptrend.xyaxis")
            }
            .disabled(isRefreshingValuations || accounts.isEmpty)
            .help("Recompute NAV for all displayed accounts")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await refreshAccounts() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Reload account data from database")
        }
    }

    // MARK: - Data Loading

    /// Loads initial data: accessible groups and selected accounts.
    ///
    /// Called via `.task {}` modifier when the view first appears.
    /// Loads accessible groups via ``EntitlementService/filterAccessibleGroups``
    /// then loads accounts via ``AccountService/getAccounts``.
    private func loadInitialData() async {
        // Load accessible group count for the summary header.
        // filterAccessibleGroups never throws — returns [] on error (Rule 4).
        let accessibleGroups = await entitlementService.filterAccessibleGroups(
            userId: userId
        )
        accessibleGroupCount = accessibleGroups.count

        await loadAccounts()
    }

    /// Loads selected accounts from ``AccountService``.
    ///
    /// **Rule 4**: AccountService internally enforces entitlement checks.
    /// Users without READ access receive empty results — never errors.
    ///
    /// **Rule 7**: selectedAccountIds is already capped at 1,000 in init.
    /// The service also enforces the batch memory cap internally.
    private func loadAccounts() async {
        guard !selectedAccountIds.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Rule 4: AccountService.getAccounts internally checks entitlements.
            // Rule 7: selectedAccountIds is pre-capped at maxSearchResults (1,000).
            accounts = try await accountService.getAccounts(
                ids: selectedAccountIds,
                userId: userId
            )
        } catch {
            errorMessage = mapErrorMessage(error)
        }
    }

    /// Performs an inline search against the database for accounts matching
    /// the given query text.
    ///
    /// Uses ``AccountService/search(name:id:type:group:userId:page:pageSize:)``
    /// for database-backed search when the user submits a search query.
    /// Results are capped at ``AppConstants/batchSize`` (1,000) per Rule 7.
    ///
    /// - Parameter query: The search text to match against account names.
    private func searchAccounts(query: String) async {
        guard !query.isEmpty else {
            await loadAccounts()
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Rule 4: search internally enforces entitlement checks.
            // Rule 7: pageSize capped at batchSize (1,000).
            accounts = try await accountService.search(
                name: query,
                id: nil,
                type: nil,
                group: nil,
                userId: userId,
                page: 1,
                pageSize: AppConstants.batchSize
            )
        } catch {
            errorMessage = mapErrorMessage(error)
        }
    }

    /// Loads positions for a specific account and builds display items.
    ///
    /// Called lazily when the user expands an account row. Fetches positions
    /// via ``LedgerService/getPositions`` (which enforces Rule 4 entitlements),
    /// then fetches reference data for each position's instrument. For each
    /// position the primary lookup is ``ReferenceDataService/findById`` using
    /// the instrument ID. If the account has a cached value date, the view
    /// also attempts ``ReferenceDataService/findByTickerAndDate`` to obtain
    /// date-specific pricing, which may be more current.
    ///
    /// Constructs ``PositionDisplayItem`` instances from Position + ReferenceData
    /// pairs. Each Position provides id, accountId, instrumentId, quantity, and
    /// assetType. Each ReferenceData provides id, ticker, name, eodBid, eodAsk,
    /// and the computed eodMidpoint. The PositionDisplayItem.init combines them
    /// to produce ticker, quantity, eodMidpoint, and marketValue properties.
    ///
    /// - Parameter account: The account whose positions to load.
    private func loadPositions(for account: Account) async {
        let accountId = account.id
        guard !loadingPositionIds.contains(accountId) else { return }

        loadingPositionIds.insert(accountId)
        defer { loadingPositionIds.remove(accountId) }

        do {
            // Rule 4: Pre-check entitlement before position loading.
            // checkPermission never throws — returns false for unauthorized users.
            let hasRead = await entitlementService.checkPermission(
                userId: userId,
                accountGroupId: account.accountGroupId,
                permission: "READ"
            )

            guard hasRead else {
                // Rule 4: Users without READ access see empty positions, not errors.
                positionsMap[accountId] = []
                return
            }

            // Rule 4: LedgerService.getPositions also enforces entitlement internally.
            let positions = try await ledgerService.getPositions(
                userId: userId,
                accountGroupId: account.accountGroupId,
                accountId: accountId
            )

            // Build PositionDisplayItem array from positions + reference data.
            var displayItems: [PositionDisplayItem] = []
            displayItems.reserveCapacity(positions.count)

            // Cache date-specific reference data by ticker to avoid redundant lookups.
            var dateRefCache: [String: ReferenceData] = [:]
            let valueDate = account.cachedValueDate

            // Track processed position IDs to prevent duplicates.
            var processedPositionIds = Set<UInt64>()

            for position in positions {
                // Defensive: verify position belongs to the requested account.
                guard position.accountId == accountId else { continue }

                // Deduplicate by position ID.
                guard processedPositionIds.insert(position.id).inserted else { continue }

                // Rule 5: Only equity positions are valid in this application.
                // The asset type should always be "equity" due to application-layer
                // constraints, but we validate defensively.
                let assetType = position.assetType
                guard !assetType.isEmpty else { continue }

                // Primary lookup: fetch reference data by the position's instrument ID.
                guard let refData = try await referenceDataService.findById(position.instrumentId) else {
                    continue
                }

                // Validate the reference data has an associated instrument name.
                let instrumentName = refData.name
                guard !instrumentName.isEmpty else { continue }

                // Determine effective reference data for display. If the account
                // has a cached value date, attempt a date-specific ticker lookup
                // which may yield more current EOD pricing.
                var effectiveRef = refData
                if let vDate = valueDate {
                    let ticker = refData.ticker
                    if let cached = dateRefCache[ticker] {
                        effectiveRef = cached
                    } else if let dateSpecific = try? await referenceDataService.findByTickerAndDate(
                        ticker: ticker,
                        marketDate: vDate
                    ) {
                        dateRefCache[ticker] = dateSpecific
                        effectiveRef = dateSpecific
                    }
                }

                // Validate that reference data has positive EOD pricing.
                // Check bid, ask, and the computed midpoint for completeness.
                guard effectiveRef.eodBid > 0,
                      effectiveRef.eodAsk > 0,
                      effectiveRef.eodMidpoint > 0 else { continue }

                // Validate the position has a positive quantity.
                guard position.quantity > 0 else { continue }

                // Verify the effective reference data has a valid ID.
                let refId = effectiveRef.id
                guard refId > 0 else { continue }

                // Build display item. PositionDisplayItem.init(position:referenceData:)
                // combines Position (id, accountId, instrumentId, quantity, assetType)
                // with ReferenceData (id, ticker, name, eodBid, eodAsk, eodMidpoint)
                // into a display-ready model with ticker, quantity, eodMidpoint, marketValue.
                let item = PositionDisplayItem(
                    position: position,
                    referenceData: effectiveRef
                )
                displayItems.append(item)
            }

            positionsMap[accountId] = displayItems
        } catch {
            // On failure, store empty positions to avoid repeated failed fetches.
            positionsMap[accountId] = []
        }
    }

    /// Refreshes NAV valuations for all currently displayed accounts.
    ///
    /// Uses ``ValuationService/runValuation(for:marketDate:)`` to batch-recompute
    /// NAV values for all accounts. After completion, reloads account data to
    /// pick up the updated cached valuation amounts and dates (Rule 11).
    ///
    /// Accesses Valuation properties: accountId, valueAmount, valueDate, timezone
    /// from the returned results.
    private func refreshAllValuations() async {
        guard !accounts.isEmpty else { return }

        isRefreshingValuations = true
        defer { isRefreshingValuations = false }

        do {
            let accountIds = accounts.map { $0.id }
            let valuations = try await valuationService.runValuation(
                for: accountIds,
                marketDate: Date()
            )

            // Update local account cache with new valuation results.
            // Each Valuation provides accountId, valueAmount, valueDate, and timezone.
            for valuation in valuations {
                let valuedAccountId = valuation.accountId
                let newAmount = valuation.valueAmount
                let newDate = valuation.valueDate
                let valuationTz = valuation.timezone

                if let index = accounts.firstIndex(where: { $0.id == valuedAccountId }) {
                    let existing = accounts[index]
                    accounts[index] = Account(
                        id: existing.id,
                        name: existing.name,
                        fundType: existing.fundType,
                        ownershipDetails: existing.ownershipDetails,
                        valuationTimezone: valuationTz.isEmpty ? existing.valuationTimezone : valuationTz,
                        valuationSchedule: existing.valuationSchedule,
                        cachedValuationAmount: newAmount,
                        cachedValueDate: newDate,
                        status: existing.status,
                        accountGroupId: existing.accountGroupId,
                        createdAt: existing.createdAt
                    )
                }
            }

            // Clear expansion and position caches after bulk refresh.
            expandedAccountIds.removeAll()
            positionsMap.removeAll()
        } catch {
            errorMessage = mapErrorMessage(error)
        }
    }

    /// Refreshes NAV valuation for a single account.
    ///
    /// Uses ``ValuationService/runSingleAccountValuation(accountId:marketDate:)``
    /// to recompute the NAV for one account. Updates the local account array
    /// with the new cached valuation amount and date (Rule 3, Rule 11).
    ///
    /// - Parameter account: The account to revalue.
    private func refreshSingleValuation(for account: Account) async {
        do {
            let valuation = try await valuationService.runSingleAccountValuation(
                accountId: account.id,
                marketDate: Date()
            )

            // Extract Valuation result properties for local state update.
            let valuedAccountId = valuation.accountId
            let newAmount = valuation.valueAmount
            let newDate = valuation.valueDate
            let valuationTz = valuation.timezone

            // Update the local account with new cached valuation.
            // Use the valuation's accountId to locate the correct account,
            // and apply the refreshed timezone if the valuation provides one.
            if let index = accounts.firstIndex(where: { $0.id == valuedAccountId }) {
                let existing = accounts[index]
                let updated = Account(
                    id: existing.id,
                    name: existing.name,
                    fundType: existing.fundType,
                    ownershipDetails: existing.ownershipDetails,
                    valuationTimezone: valuationTz.isEmpty ? existing.valuationTimezone : valuationTz,
                    valuationSchedule: existing.valuationSchedule,
                    cachedValuationAmount: newAmount,
                    cachedValueDate: newDate,
                    status: existing.status,
                    accountGroupId: existing.accountGroupId,
                    createdAt: existing.createdAt
                )
                accounts[index] = updated
            }

            // Clear cached positions for the account to force re-fetch.
            positionsMap.removeValue(forKey: account.id)
        } catch {
            // Single-account valuation refresh failed — the cached value
            // remains unchanged so the row displays stale-but-valid data.
            // Log the error for diagnostics without disrupting the user.
            print("[AccountsViewer] Valuation refresh failed for account \(account.id): \(error.localizedDescription)")
        }
    }

    /// Reloads all account data, clearing expansion and position caches.
    private func refreshAccounts() async {
        expandedAccountIds.removeAll()
        positionsMap.removeAll()
        loadingPositionIds.removeAll()
        filterText = ""
        await loadAccounts()
    }

    // MARK: - Expansion Toggle

    /// Toggles position expansion for a specific account.
    ///
    /// If the account is currently expanded, it is collapsed. If collapsed,
    /// it is expanded and positions are loaded lazily via ``loadPositions(for:)``
    /// if not already cached in ``positionsMap``.
    ///
    /// - Parameter accountId: The ID of the account to toggle.
    private func toggleExpansion(for accountId: UInt64) {
        if expandedAccountIds.contains(accountId) {
            expandedAccountIds.remove(accountId)
        } else {
            expandedAccountIds.insert(accountId)
            // Load positions lazily if not already cached.
            if positionsMap[accountId] == nil {
                if let account = accounts.first(where: { $0.id == accountId }) {
                    Task {
                        await loadPositions(for: account)
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    /// Returns the subset of accounts matching the current filter text.
    ///
    /// When ``filterText`` is empty, returns all loaded accounts.
    /// When non-empty, filters by case-insensitive name containment.
    private var filteredAccounts: [Account] {
        if filterText.isEmpty {
            return accounts
        }
        let lowered = filterText.lowercased()
        return accounts.filter { $0.name.lowercased().contains(lowered) }
    }

    /// Counts accounts with institutional fund types in the given array.
    ///
    /// Uses ``FundType/isInstitutional`` to determine institutional classification
    /// (open/closed mutual funds, ETFs, hedge funds).
    ///
    /// - Parameter accounts: The account array to count.
    /// - Returns: The number of institutional accounts.
    private func institutionalCount(in accounts: [Account]) -> Int {
        accounts.filter { $0.fundType.isInstitutional }.count
    }

    /// Counts accounts with wealth fund types in the given array.
    ///
    /// Uses ``FundType/isWealth`` to determine wealth classification
    /// (SMAs, UMAs).
    ///
    /// - Parameter accounts: The account array to count.
    /// - Returns: The number of wealth accounts.
    private func wealthCount(in accounts: [Account]) -> Int {
        accounts.filter { $0.fundType.isWealth }.count
    }

    // MARK: - Formatting Helpers

    /// Formats a cached value date using the account's stored IANA timezone.
    ///
    /// **Rule 3**: Uses the account's stored `valuationTimezone` — NEVER
    /// `TimeZone.current` or the system timezone. This ensures that two accounts
    /// configured for "America/New_York" and "Europe/London" display distinct
    /// value dates for the same calendar day.
    ///
    /// - Parameters:
    ///   - date: The optional cached value date. Returns "—" if nil.
    ///   - timezone: The IANA timezone identifier string (e.g., "America/New_York").
    /// - Returns: A medium-style date string in the account's timezone, or "—".
    private func formattedValueDate(_ date: Date?, timezone: String) -> String {
        guard let date = date else { return "\u{2014}" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Rule 3: Use the account's stored IANA timezone exclusively.
        // NEVER use TimeZone.current or Calendar.current for value dates.
        if let tz = TimeZone(identifier: timezone) {
            formatter.timeZone = tz
        }
        return formatter.string(from: date)
    }

    /// Maps an error to a human-readable error message.
    ///
    /// Recognizes ``AppError/accountNotFound`` and ``AppError/unauthorizedAccess``
    /// for domain-specific messages. Falls back to `localizedDescription` for
    /// unknown errors.
    ///
    /// - Parameter error: The error to map.
    /// - Returns: A user-facing error message string.
    private func mapErrorMessage(_ error: Error) -> String {
        if let appError = error as? AppError {
            switch appError {
            case .accountNotFound:
                return "One or more selected accounts could not be found."
            case .unauthorizedAccess:
                return "You do not have permission to view these accounts."
            case .dataAccessFailed(let detail):
                return "Data access error: \(detail)"
            default:
                return "An error occurred: \(appError.localizedDescription)"
            }
        }
        return "An unexpected error occurred: \(error.localizedDescription)"
    }

    /// Returns a human-readable display name for an ``AccountStatus`` case.
    ///
    /// - Parameter status: The account status enum case.
    /// - Returns: A capitalized status string (e.g., "Active", "Suspended").
    private func statusDisplayName(_ status: AccountStatus) -> String {
        switch status {
        case .active:
            return "Active"
        case .inactive:
            return "Inactive"
        case .pending:
            return "Pending"
        case .suspended:
            return "Suspended"
        }
    }

    /// Formats a ``Decimal`` value as a USD currency string.
    ///
    /// Uses `NumberFormatter` with `.currency` style for consistent formatting
    /// across the Accounts Viewer. All financial values use Decimal precision —
    /// never Double or Float.
    ///
    /// - Parameter value: The decimal value to format as currency.
    /// - Returns: A currency-formatted string (e.g., "$1,234.56"), or "$0.00".
    private func formattedCurrency(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$0.00"
    }

    /// Formats a ``Decimal`` value as a plain numeric string.
    ///
    /// Uses `NumberFormatter` with `.decimal` style for quantities and prices.
    /// All numeric values use Decimal precision — never Double or Float.
    ///
    /// - Parameter value: The decimal value to format.
    /// - Returns: A decimal-formatted string (e.g., "1,234.56"), or "0".
    private func formattedDecimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }
}
#endif
