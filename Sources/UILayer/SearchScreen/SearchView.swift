#if canImport(SwiftUI)
// Sources/UILayer/SearchScreen/SearchView.swift
// WealthLedger — Search Screen for Multi-Criteria Account Search
//
// Provides multi-criteria account search with entitlement-aware results (Rule 4),
// batch memory cap enforcement (Rule 7), and multi-selection for navigation
// to the Accounts Viewer screen. No direct database or RBAC imports — all
// entitlement enforcement is delegated to AccountService.
//
// Rule 4:  Entitled groups populated via getAccessibleAccountGroups; search results
//          filtered by AccountService internally — empty result for no access.
// Rule 7:  Search results capped at AppConstants.maxSearchResults (1,000).
// Rule 8:  No import SwiftData, no import MySQLKit, no import Persistence.
// Rule 13: Search delegates to indexed repository queries via AccountService.
// Gate 2:  Swift 6 strict concurrency — zero warnings, zero @unchecked Sendable.

import SwiftUI
import AccountManagement
import Shared

// MARK: - SearchView

/// Search screen for multi-criteria account search with entitlement-aware results.
///
/// Provides four search filter fields:
/// 1. **Account name** — partial match via text input (delegates to `LIKE 'prefix%'`)
/// 2. **Account ID** — exact match via text input (parsed to `UInt64`)
/// 3. **Account type** — dropdown from ``FundType`` enum (all 6 cases via `CaseIterable`)
/// 4. **Account group** — dropdown populated from entitled groups only (Rule 4)
///
/// Search results display in a scrollable `List` capped at 1,000 records (Rule 7).
/// Users can multi-select accounts (up to 1,000) and navigate to the Accounts Viewer
/// by setting the ``accountsForViewer`` binding.
///
/// ## Entitlement Enforcement (Rule 4)
///
/// The account group dropdown is populated exclusively from groups the current user
/// has READ access to, via ``AccountService/getAccessibleAccountGroups(userId:)``.
/// Search results are filtered internally by ``AccountService/search(name:id:type:group:userId:page:pageSize:)``
/// — users without READ access to a group receive zero records for that group.
/// No explicit RBAC code exists in this view.
///
/// ## Batch Memory Cap (Rule 7)
///
/// The `pageSize` parameter passed to ``AccountService/search`` is always
/// ``AppConstants/maxSearchResults`` (1,000). Multi-selection is inherently
/// capped since results cannot exceed 1,000 rows.
///
/// ## Concurrency Safety (Gate 2)
///
/// `SearchView` is a `struct` conforming to SwiftUI `View`, which is
/// `@MainActor`-isolated by default in Swift 6. All `@State` and `@Binding`
/// properties are `@MainActor`-isolated. The injected ``AccountService`` is
/// `Sendable` (`public final class` with immutable `let` properties). All
/// model types (``Account``, ``AccountGroup``, ``FundType``) are `Sendable`
/// value types. Zero `@unchecked Sendable` annotations or warning suppressions.
///
/// ## Consumer Usage
///
/// ```swift
/// SearchView(
///     accountService: container.accountService,
///     userId: appState.currentUser!.id,
///     accountsForViewer: $accountsForViewer
/// )
/// ```
public struct SearchView: View {

    // MARK: - Dependencies

    /// The account service for search operations and accessible group queries.
    ///
    /// ``AccountService`` is `Sendable` (`public final class` with immutable
    /// `let` properties), safe to hold as a stored property in this `@MainActor`
    /// view. All search and group loading calls are delegated to this service.
    private let accountService: AccountService

    /// The current authenticated user's ID for entitlement scoping.
    ///
    /// Passed to every ``AccountService`` method to ensure Rule 4 compliance.
    /// `UInt64` is `Sendable` — safe across concurrency boundaries.
    private let userId: UInt64

    /// Binding to the parent's selected accounts array for navigation to AccountsViewerView.
    ///
    /// When the user taps "View Selected", this binding is populated with the
    /// selected ``Account`` objects. The parent ``MainNavigationView`` reacts to
    /// this change and navigates to the Accounts Viewer screen.
    @Binding private var accountsForViewer: [Account]

    // MARK: - Search Filter State

    /// Text input for partial account name match.
    ///
    /// Passed as the `name` parameter to ``AccountService/search``. The repository
    /// layer translates this to a `LIKE 'prefix%'` query with a B-tree index
    /// for sub-2-second performance across 100,000 accounts (Rule 13).
    @State private var searchName: String = ""

    /// Text input for exact account ID match.
    ///
    /// Parsed from `String` to `UInt64?` before passing to ``AccountService/search``.
    /// If the string is empty or not a valid unsigned integer, `nil` is passed
    /// (search by other criteria only).
    @State private var searchId: String = ""

    /// Selected fund type filter (`nil` means all types).
    ///
    /// Bound to the account type ``Picker``. `FundType.allCases` populates all
    /// 6 options; `nil` (tagged as `FundType?.none`) represents "All Types".
    @State private var selectedFundType: FundType? = nil

    /// Selected account group filter (`nil` means all entitled groups).
    ///
    /// Bound to the account group ``Picker`` populated from ``accessibleGroups``.
    /// `nil` (tagged as `UInt64?.none`) represents "All Groups".
    @State private var selectedGroupId: UInt64? = nil

    // MARK: - Results and Selection State

    /// Search results returned from ``AccountService/search``, capped at 1,000 (Rule 7).
    ///
    /// Cleared and repopulated on each search execution. The `List` iterates
    /// over this array using ``Account/id`` for `Identifiable` conformance.
    @State private var searchResults: [Account] = []

    /// Set of selected account IDs for multi-select. Maximum 1,000 (Rule 7).
    ///
    /// Bound to `List(selection:)` for built-in macOS multi-select support
    /// (Cmd+Click, Shift+Click). Cleared on each new search.
    @State private var selectedAccountIds: Set<UInt64> = []

    /// Account groups the current user has READ access to (populated on appear).
    ///
    /// Loaded asynchronously via ``loadAccessibleGroups()`` in the `.task` modifier.
    /// Populates the account group ``Picker`` dropdown — only entitled groups are
    /// shown (Rule 4).
    @State private var accessibleGroups: [AccountGroup] = []

    /// Whether a search operation is currently in progress.
    ///
    /// Controls the loading indicator display and disables the search button
    /// to prevent duplicate requests.
    @State private var isSearching: Bool = false

    /// Error message to display in an alert (if any infrastructure error occurs).
    ///
    /// Set when ``AccountService/search`` throws an error. Cleared when the
    /// user dismisses the alert or starts a new search.
    @State private var errorMessage: String? = nil

    // MARK: - Initializer

    /// Creates a new search view with the required dependencies.
    ///
    /// - Parameters:
    ///   - accountService: Service for account search and accessible group queries.
    ///     Must be a `Sendable` instance (``AccountService`` is `public final class`
    ///     with immutable `let` properties).
    ///   - userId: The current authenticated user's ID for entitlement scoping.
    ///   - accountsForViewer: Binding to the parent's selected accounts array.
    ///     Populated when the user taps "View Selected" to navigate to AccountsViewerView.
    public init(
        accountService: AccountService,
        userId: UInt64,
        accountsForViewer: Binding<[Account]>
    ) {
        self.accountService = accountService
        self.userId = userId
        self._accountsForViewer = accountsForViewer
    }

    // MARK: - Body

    /// The main view body composing search filters, results toolbar, and results list.
    ///
    /// Layout structure (top to bottom):
    /// 1. Search filters section — four filter fields and search button
    /// 2. Divider
    /// 3. Results toolbar — result count, selection count, Select All/Deselect All, View Selected
    /// 4. Divider
    /// 5. Results list — scrollable `List` with multi-select, or loading/empty states
    ///
    /// The `.task` modifier loads accessible account groups on appear. The `.alert`
    /// modifier displays error messages from failed search operations.
    public var body: some View {
        VStack(spacing: 0) {
            searchFiltersSection

            Divider()

            resultsToolbar

            Divider()

            resultsList
        }
        .navigationTitle("Search Accounts")
        .task {
            await loadAccessibleGroups()
        }
        .alert("Error", isPresented: errorAlertBinding) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Computed Bindings

    /// Binding that converts the optional `errorMessage` to a `Bool` for `.alert(isPresented:)`.
    ///
    /// - `get`: Returns `true` when `errorMessage` is non-nil.
    /// - `set`: Clears `errorMessage` when the alert is dismissed (set to `false`).
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )
    }

    // MARK: - Search Filters Section

    /// Form-like section with four search filter fields and a search button.
    ///
    /// Top row: Account Name (partial match text field) + Account ID (exact match text field).
    /// Bottom row: Account Type (FundType picker) + Account Group (entitled groups picker) + Search button.
    ///
    /// Both text fields support `onSubmit` for Enter-key triggered search.
    @ViewBuilder
    private var searchFiltersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: Name and ID text fields
            HStack(spacing: 16) {
                // Account Name — text field for partial match
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search by name...", text: $searchName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task {
                                await performSearch()
                            }
                        }
                }

                // Account ID — text field for exact match
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Exact ID...", text: $searchId)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task {
                                await performSearch()
                            }
                        }
                }
            }

            // Bottom row: Type picker, Group picker, Search button
            HStack(spacing: 16) {
                // Account Type — Picker dropdown from FundType enum (6 cases)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Type", selection: $selectedFundType) {
                        Text("All Types").tag(FundType?.none)
                        ForEach(FundType.allCases, id: \.self) { fundType in
                            Text(fundType.displayName).tag(FundType?.some(fundType))
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Account Group — Picker dropdown from entitled groups only (Rule 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Group", selection: $selectedGroupId) {
                        Text("All Groups").tag(UInt64?.none)
                        ForEach(accessibleGroups) { group in
                            Text(group.groupName).tag(UInt64?.some(group.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Spacer()

                // Search button — triggers performSearch() async
                Button {
                    Task {
                        await performSearch()
                    }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching)
            }
        }
        .padding()
    }

    // MARK: - Results Toolbar

    /// Toolbar displaying result count, selection count, bulk selection buttons,
    /// and the "View Selected" navigation button.
    ///
    /// Layout: [result count] [selection count] — [Select All] [Deselect All] [View Selected]
    @ViewBuilder
    private var resultsToolbar: some View {
        HStack {
            // Result count
            Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Selection count (shown only when selection is non-empty)
            if !selectedAccountIds.isEmpty {
                Text("• \(selectedAccountIds.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            Spacer()

            // Select All / Deselect All buttons (shown only when results exist)
            if !searchResults.isEmpty {
                Button("Select All") {
                    selectAll()
                }
                .disabled(selectedAccountIds.count == searchResults.count)

                Button("Deselect All") {
                    selectedAccountIds.removeAll()
                }
                .disabled(selectedAccountIds.isEmpty)
            }

            // View Selected button — navigates to Accounts Viewer
            Button(action: viewSelected) {
                Label("View Selected", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedAccountIds.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Results List

    /// Scrollable list of search results with macOS multi-select support.
    ///
    /// Displays one of three states:
    /// 1. **Loading** — `ProgressView` with "Searching..." text during async search.
    /// 2. **Empty** — `ContentUnavailableView` when no results match the criteria.
    /// 3. **Results** — `List` with `selection` binding for Cmd+Click / Shift+Click
    ///    multi-selection. Each row uses ``AccountRowView`` for consistent display.
    @ViewBuilder
    private var resultsList: some View {
        if isSearching {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try adjusting your search criteria")
            )
        } else {
            List(searchResults, selection: $selectedAccountIds) { account in
                AccountRowView(account: account)
                    .tag(account.id)
            }
        }
    }

    // MARK: - Async Methods

    /// Loads account groups accessible to the current user on view appear.
    ///
    /// Called from the `.task` modifier, which runs once when the view appears.
    /// Populates ``accessibleGroups`` for the account group ``Picker`` dropdown.
    ///
    /// ``AccountService/getAccessibleAccountGroups(userId:)`` is non-throwing
    /// and returns an empty array if the user has no entitled groups (Rule 4).
    private func loadAccessibleGroups() async {
        let groups = await accountService.getAccessibleAccountGroups(userId: userId)
        accessibleGroups = groups
    }

    /// Executes a multi-criteria search with the current filter values.
    ///
    /// Called from the search button action and text field `onSubmit` handlers.
    ///
    /// ## Workflow
    /// 1. Sets ``isSearching`` to `true` and clears previous errors and selection.
    /// 2. Parses ``searchId`` from `String` to `UInt64?` (nil if empty or invalid).
    /// 3. Calls ``AccountService/search(name:id:type:group:userId:page:pageSize:)``
    ///    with `pageSize` set to ``AppConstants/maxSearchResults`` (1,000) for Rule 7.
    /// 4. Entitlement enforcement is handled internally by AccountService (Rule 4).
    /// 5. On success, populates ``searchResults``. On failure, sets ``errorMessage``
    ///    and clears results.
    /// 6. Sets ``isSearching`` to `false`.
    private func performSearch() async {
        isSearching = true
        errorMessage = nil
        selectedAccountIds.removeAll()

        do {
            // Parse account ID from string input (nil if empty or not a valid UInt64)
            let accountId: UInt64? = searchId.isEmpty ? nil : UInt64(searchId)

            // Execute search with entitlement enforcement (Rule 4) and memory cap (Rule 7)
            let results = try await accountService.search(
                name: searchName.isEmpty ? nil : searchName,
                id: accountId,
                type: selectedFundType,
                group: selectedGroupId,
                userId: userId,
                page: 1,
                pageSize: AppConstants.maxSearchResults
            )

            searchResults = results
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            searchResults = []
        }

        isSearching = false
    }

    // MARK: - Selection Methods

    /// Selects all visible search results (up to 1,000 per Rule 7).
    ///
    /// Since ``searchResults`` is already capped at ``AppConstants/maxSearchResults``
    /// (1,000), selecting all is always within the batch memory cap.
    private func selectAll() {
        selectedAccountIds = Set(searchResults.map(\.id))
    }

    /// Navigates to the Accounts Viewer with the currently selected accounts.
    ///
    /// Filters ``searchResults`` to only the accounts whose IDs are in
    /// ``selectedAccountIds``, then sets the ``accountsForViewer`` binding.
    /// The parent ``MainNavigationView`` reacts to this change and navigates
    /// to ``AccountsViewerView``.
    ///
    /// Maximum 1,000 selected accounts (Rule 7) — inherently enforced since
    /// search results cannot exceed 1,000 rows.
    private func viewSelected() {
        let selectedAccounts = searchResults.filter { selectedAccountIds.contains($0.id) }
        accountsForViewer = selectedAccounts
    }
}
#endif
