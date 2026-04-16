#if canImport(SwiftUI)
// Sources/UILayer/Navigation/MainNavigationView.swift
// WealthLedger — Root Navigation View
//
// The primary SwiftUI scene content presented by `WealthLedgerApp.swift` (the @main
// entry point). Provides sidebar-based navigation to all four application screens
// and implements a login gate to enforce authentication.
//
// Architecture — Circular Dependency Avoidance:
//   The UILayer module CANNOT import WealthLedgerApp (that would create a circular
//   dependency: WealthLedgerApp → UILayer → WealthLedgerApp). Therefore this view
//   does NOT reference AppState or DependencyContainer directly. Instead:
//     - Individual services are injected via init parameters by WealthLedgerApp.swift.
//     - Auth state (currentUser) and selection state (accountsForViewer) are managed
//       locally via @State properties within this view.
//   This matches the injection pattern established by all four child views (AdminView,
//   SearchView, AccountsViewerView, JobSchedulerView).
//
// Rule 4 (Entitlement Enforcement):
//   Authentication is a prerequisite for all subsequent entitlement checks. Login
//   gating ensures all four screens require a valid User before any data access.
//   Users without READ access to account groups receive empty result sets (enforced
//   by child views and their injected services).
//
// Rule 7 (Batch Memory Cap):
//   The accountsForViewer array passed to AccountsViewerView is derived from
//   SearchView selections which are capped at AppConstants.maxSearchResults (1,000).
//   No UI operation loads more than 1,000 account records into memory.
//
// Rule 8 (MySQLKit-Only Persistence):
//   This file imports ONLY SwiftUI plus business logic modules. Absolutely NO
//   SwiftData, MySQLKit, SQLKit, AsyncKit, or Persistence imports. Views interact
//   with services only — never repositories or database connections directly.
//
// Rule 9 (Offline Runtime):
//   No network calls. All data access flows through local MySQL via injected services.
//
// Swift 6 Strict Concurrency (Gate 2):
//   MainNavigationView is a struct conforming to View — automatically @MainActor
//   isolated in Swift 6. All @State properties are value types or Sendable types.
//   Service properties are Sendable final classes (let-bound). LoginView is a
//   private View struct with the same isolation guarantees. NavigationTab enum is
//   implicitly Sendable (raw-value enum with no stored properties). Zero
//   @unchecked Sendable annotations. Zero warning suppressions. All async operations
//   use Task {} within button actions.
//
// Gate 9 (Integration Wiring):
//   MainNavigationView is the root scene presented by @main. All four screens are
//   reachable from this view: AdminView (admin tab), SearchView (search tab),
//   AccountsViewerView (accounts viewer tab), JobSchedulerView (job scheduler tab).
//   Each screen receives its required services via constructor injection from the
//   services held by this view.
//
// Consumers:
//   - WealthLedgerApp.swift — instantiates MainNavigationView with all services
//     obtained from DependencyContainer:
//       MainNavigationView(
//           authenticationService: container.authenticationService,
//           entitlementService: container.entitlementService,
//           accountService: container.accountService,
//           accountGroupService: container.accountGroupService,
//           valuationService: container.valuationService,
//           ledgerService: container.ledgerService,
//           referenceDataService: container.referenceDataService,
//           jobSchedulerService: container.jobSchedulerService
//       )

import SwiftUI
import RBAC
import AccountManagement
import ValuationEngine
import LedgerEngine
import ReferenceDataService
import JobScheduler

// MARK: - NavigationTab

/// Represents the four main navigation destinations in the WealthLedger application.
///
/// Each case maps to one of the four SwiftUI screens defined in the UILayer module.
/// The enum provides display metadata (``title``, ``systemImage``) for sidebar
/// rendering and conforms to `CaseIterable` for iteration, `Identifiable` for
/// SwiftUI `List` compatibility, and is implicitly `Sendable` as a raw-value enum
/// with no stored properties.
///
/// ## Cases
///
/// | Case | Screen | SF Symbol |
/// |------|--------|-----------|
/// | ``admin`` | ``AdminView`` | `person.badge.shield.checkmark` |
/// | ``search`` | ``SearchView`` | `magnifyingglass` |
/// | ``accountsViewer`` | ``AccountsViewerView`` | `list.bullet.rectangle` |
/// | ``jobScheduler`` | ``JobSchedulerView`` | `clock.arrow.circlepath` |
public enum NavigationTab: String, CaseIterable, Identifiable, Sendable {

    /// Admin screen — user creation, account group creation, entitlement assignment.
    case admin

    /// Search screen — multi-criteria account search with entitlement-aware results.
    case search

    /// Accounts Viewer — scrollable LazyVStack of selected accounts with positions.
    case accountsViewer

    /// Job Scheduler — report generation and CSV ingestion job management.
    case jobScheduler

    // MARK: - Identifiable

    /// Unique identifier derived from the raw string value.
    public var id: String { rawValue }

    // MARK: - Display Metadata

    /// Human-readable display name for sidebar labels.
    public var title: String {
        switch self {
        case .admin:
            return "Admin"
        case .search:
            return "Search"
        case .accountsViewer:
            return "Accounts Viewer"
        case .jobScheduler:
            return "Job Scheduler"
        }
    }

    /// SF Symbol name for sidebar icons.
    ///
    /// All symbols are available on macOS 14+ (Sonoma) and later, which satisfies
    /// the project's `.macOS(.v15)` minimum deployment target.
    public var systemImage: String {
        switch self {
        case .admin:
            return "person.badge.shield.checkmark"
        case .search:
            return "magnifyingglass"
        case .accountsViewer:
            return "list.bullet.rectangle"
        case .jobScheduler:
            return "clock.arrow.circlepath"
        }
    }
}

// MARK: - LoginView (Private)

/// Authentication gate view displayed when no user is logged in.
///
/// Presents a centered login form with username and password fields, a login button,
/// and error feedback. On successful authentication via ``AuthenticationService``,
/// sets the bound `currentUser` property to trigger the parent view's transition
/// to the authenticated navigation structure.
///
/// ## Concurrency Safety
///
/// `LoginView` is a private `struct` conforming to `View` — `@MainActor`-isolated
/// by default in Swift 6. All `@State` properties are value types (`String`, `Bool`,
/// `Optional<String>`). The `Task {}` block in the login button action inherits
/// `@MainActor` isolation from the enclosing view context. The
/// ``AuthenticationService`` is a `Sendable` final class — safe to call from the
/// main actor.
private struct LoginView: View {

    // MARK: - Dependencies

    /// Authentication service providing bcrypt-verified login.
    ///
    /// Injected by the parent ``MainNavigationView``. Calls
    /// `login(username:password:)` which returns `User?` — `nil` for failed
    /// authentication, a populated `User` on success.
    let authenticationService: AuthenticationService

    /// Two-way binding to the parent view's current user state.
    ///
    /// Set to the authenticated ``User`` on successful login, which causes
    /// ``MainNavigationView`` to re-evaluate its body and transition from
    /// the login screen to the authenticated ``NavigationSplitView``.
    @Binding var currentUser: User?

    // MARK: - Form State

    /// Username text field input.
    @State private var username: String = ""

    /// Password secure field input (never displayed as plain text).
    @State private var password: String = ""

    /// Error message displayed below the form on authentication failure.
    /// `nil` when no error is present.
    @State private var errorMessage: String? = nil

    /// Whether a login operation is currently in progress.
    /// Disables the login button and shows a progress indicator.
    @State private var isLoggingIn: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            // App branding section
            VStack(spacing: 8) {
                Image(systemName: "building.columns")
                    .font(.system(size: 48))
                    .foregroundStyle(.accentColor)
                    .accessibilityHidden(true)

                Text("WealthLedger")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("General Ledger Accounting Engine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            // Credential input fields
            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .accessibilityLabel("Username")

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .accessibilityLabel("Password")
            }

            // Error feedback
            if let errorText = errorMessage {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Login error: \(errorText)")
            }

            // Login action button
            Button {
                Task {
                    await performLogin()
                }
            } label: {
                Group {
                    if isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Log In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(isLoggingIn ? "Logging in" : "Log In")
        }
        .frame(maxWidth: 300)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Login Action

    /// Executes the login flow via ``AuthenticationService``.
    ///
    /// Sets `isLoggingIn` to true during the operation, clears previous error
    /// messages, and handles both authentication failures (nil return → user-facing
    /// message) and infrastructure errors (thrown errors → localized description).
    ///
    /// On success, sets `currentUser` via the binding, which triggers the parent
    /// view to transition to the authenticated NavigationSplitView.
    private func performLogin() async {
        isLoggingIn = true
        errorMessage = nil

        do {
            let authenticatedUser = try await authenticationService.login(
                username: username,
                password: password
            )
            if let user = authenticatedUser {
                // Authentication succeeded — set the bound user to trigger
                // the parent view's transition to the navigation structure.
                currentUser = user
            } else {
                // AuthenticationService returns nil for both "user not found"
                // and "wrong password" to prevent username enumeration attacks.
                errorMessage = "Invalid username or password"
            }
        } catch {
            // Infrastructure failure (database connectivity, query error).
            // Display localized error description to the user.
            errorMessage = "Login failed: \(error.localizedDescription)"
        }

        isLoggingIn = false
    }
}

// MARK: - MainNavigationView

/// Root navigation view for the WealthLedger macOS desktop application.
///
/// `MainNavigationView` is the primary scene content presented by the `@main` entry
/// point. It implements two visual states:
///
/// 1. **Unauthenticated** — displays ``LoginView`` for credential entry.
/// 2. **Authenticated** — displays a ``NavigationSplitView`` with a sidebar listing
///    all four navigation tabs and a detail area rendering the selected screen.
///
/// ## Dependency Injection
///
/// All eight services are injected via the public initializer by the `@main` entry
/// point (`WealthLedgerApp.swift`), which obtains them from `DependencyContainer`.
/// This view then distributes individual services to child views via their
/// respective constructors — no global state, no singletons, no environment objects.
///
/// ## Authentication Gate (Rule 4 Prerequisite)
///
/// The `currentUser` state property controls which visual state is displayed.
/// When `nil`, the login form is shown; when populated, the navigation structure
/// is rendered. All four screens require authentication, ensuring RBAC entitlement
/// checks have a valid user identity available.
///
/// ## Search → Accounts Viewer Navigation
///
/// When ``SearchView`` populates the `accountsForViewer` binding (user taps "View
/// Selected"), an `onChange` modifier automatically switches `selectedTab` to
/// `.accountsViewer`, providing seamless navigation from search results to the
/// accounts detail view.
///
/// ## Concurrency Safety (Gate 2)
///
/// - Struct conforming to `View` → `@MainActor`-isolated by default.
/// - All `@State` properties → value types or `Sendable` types.
/// - Service properties (`let`) → `Sendable` final classes.
/// - Zero `@unchecked Sendable`. Zero warning suppressions.
///
/// ## Usage
/// ```swift
/// MainNavigationView(
///     authenticationService: container.authenticationService,
///     entitlementService: container.entitlementService,
///     accountService: container.accountService,
///     accountGroupService: container.accountGroupService,
///     valuationService: container.valuationService,
///     ledgerService: container.ledgerService,
///     referenceDataService: container.referenceDataService,
///     jobSchedulerService: container.jobSchedulerService
/// )
/// ```
public struct MainNavigationView: View {

    // MARK: - Service Dependencies (Injected by WealthLedgerApp)

    /// Local authentication service for the login form.
    ///
    /// Provides `login(username:password:)` returning `User?`. Passed to
    /// ``LoginView`` for credential verification and to ``AdminView`` for
    /// user creation (via `createUser(username:password:)`).
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let authenticationService: AuthenticationService

    /// Cross-cutting entitlement enforcement service (Rule 4).
    ///
    /// Passed to ``AdminView`` (entitlement assignment), ``AccountsViewerView``
    /// (permission verification), and ``JobSchedulerView`` (RBAC gating).
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let entitlementService: EntitlementService

    /// Account CRUD, search, and batch operations service.
    ///
    /// Passed to ``SearchView`` (multi-criteria search) and
    /// ``AccountsViewerView`` (account data loading).
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let accountService: AccountService

    /// Account group CRUD service.
    ///
    /// Passed to ``AdminView`` for group creation and listing.
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let accountGroupService: AccountGroupService

    /// Batch valuation orchestration service with timezone-aware value dates.
    ///
    /// Passed to ``AccountsViewerView`` for on-demand NAV recomputation.
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let valuationService: ValuationService

    /// Transaction posting and position retrieval service.
    ///
    /// Passed to ``AccountsViewerView`` for per-account position fetching.
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let ledgerService: LedgerService

    /// Reference data query and instrument price lookup service.
    ///
    /// Passed to ``AccountsViewerView`` for instrument price resolution in
    /// position detail views.
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let referenceDataService: ReferenceDataService

    /// Job lifecycle management service for report generation and CSV ingestion.
    ///
    /// Passed to ``JobSchedulerView`` for job creation and manual execution.
    ///
    /// `Sendable` final class — safe to hold as a `let` property.
    let jobSchedulerService: JobSchedulerService

    // MARK: - View State

    /// The currently authenticated user, or `nil` when no user is logged in.
    ///
    /// Controls the authentication gate:
    /// - `nil` → ``LoginView`` is displayed.
    /// - Non-nil → ``NavigationSplitView`` with sidebar and detail area.
    ///
    /// Set by ``LoginView`` on successful authentication; cleared by ``logout()``.
    /// `User` is a `Sendable` value type — safe for `@State` storage.
    @State private var currentUser: User? = nil

    /// The currently selected navigation tab in the sidebar.
    ///
    /// Optional to support macOS `NavigationSplitView` single-selection semantics.
    /// Defaults to `.search` on initial load and after logout. Automatically
    /// switches to `.accountsViewer` when accounts are selected from SearchView.
    @State private var selectedTab: NavigationTab? = .search

    /// Accounts selected from ``SearchView`` for display in ``AccountsViewerView``.
    ///
    /// Populated via a `@Binding` passed to ``SearchView``. When the user taps
    /// "View Selected" in the search results, this array is populated and the
    /// `onChange` modifier automatically navigates to the Accounts Viewer tab.
    ///
    /// Capped at 1,000 accounts by SearchView (Rule 7). Cleared on logout.
    @State private var accountsForViewer: [Account] = []

    // MARK: - Initializer

    /// Creates the root navigation view with all required service dependencies.
    ///
    /// All services are obtained from `DependencyContainer` by the `@main` entry
    /// point and passed here via constructor injection. This view distributes
    /// individual services to child views as needed.
    ///
    /// - Parameters:
    ///   - authenticationService: Service for login and user creation.
    ///   - entitlementService: Cross-cutting RBAC enforcement (Rule 4).
    ///   - accountService: Account CRUD and search operations.
    ///   - accountGroupService: Account group CRUD operations.
    ///   - valuationService: NAV valuation with timezone awareness (Rule 3).
    ///   - ledgerService: Transaction posting and position retrieval.
    ///   - referenceDataService: Instrument price lookups.
    ///   - jobSchedulerService: Job lifecycle management.
    public init(
        authenticationService: AuthenticationService,
        entitlementService: EntitlementService,
        accountService: AccountService,
        accountGroupService: AccountGroupService,
        valuationService: ValuationService,
        ledgerService: LedgerService,
        referenceDataService: ReferenceDataService,
        jobSchedulerService: JobSchedulerService
    ) {
        self.authenticationService = authenticationService
        self.entitlementService = entitlementService
        self.accountService = accountService
        self.accountGroupService = accountGroupService
        self.valuationService = valuationService
        self.ledgerService = ledgerService
        self.referenceDataService = referenceDataService
        self.jobSchedulerService = jobSchedulerService
    }

    // MARK: - Body

    /// The root view body implementing the authentication gate and navigation structure.
    ///
    /// Displays one of two states:
    /// 1. **Unauthenticated** (`currentUser == nil`): Centered ``LoginView`` form.
    /// 2. **Authenticated** (`currentUser != nil`): ``NavigationSplitView`` with
    ///    sidebar tab list and detail area rendering the selected screen.
    ///
    /// Minimum window size of 800×600 ensures all screens have adequate space.
    public var body: some View {
        Group {
            if let user = currentUser {
                authenticatedContent(user: user)
            } else {
                LoginView(
                    authenticationService: authenticationService,
                    currentUser: $currentUser
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Authenticated Navigation Structure

    /// Builds the main navigation layout shown after successful authentication.
    ///
    /// Uses ``NavigationSplitView`` — the standard macOS sidebar navigation pattern.
    /// The sidebar lists all four ``NavigationTab`` cases with icons and labels.
    /// The detail area renders the selected screen with injected service dependencies.
    ///
    /// Includes:
    /// - Toolbar "Log Out" button to return to the login screen.
    /// - `onChange` modifier to auto-navigate to Accounts Viewer when accounts are
    ///   selected from SearchView.
    ///
    /// - Parameter user: The authenticated user for service calls and display.
    @ViewBuilder
    private func authenticatedContent(user: User) -> some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent(user: user)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Text(user.username)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    logoutButton
                }
            }
        }
        .onChange(of: accountsForViewer) { _, newValue in
            // Auto-navigate to the Accounts Viewer tab when the user selects
            // accounts from the SearchView's "View Selected" action.
            if !newValue.isEmpty {
                selectedTab = .accountsViewer
            }
        }
    }

    // MARK: - Sidebar Content

    /// Sidebar list rendering all four navigation tabs with icons and labels.
    ///
    /// Uses `NavigationTab.allCases` for iteration and binds to `$selectedTab`
    /// for single-selection. The `.navigationTitle` provides the app name in the
    /// sidebar header area.
    @ViewBuilder
    private var sidebarContent: some View {
        List(NavigationTab.allCases, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .tag(tab)
        }
        .navigationTitle("WealthLedger")
        .listStyle(.sidebar)
    }

    // MARK: - Detail Content

    /// Renders the appropriate screen for the currently selected navigation tab.
    ///
    /// Each screen receives its required services via constructor injection from
    /// the services held by this view. The `user.id` provides the authenticated
    /// user identity for entitlement-scoped operations (Rule 4).
    ///
    /// When no tab is selected (initial state edge case), a placeholder is shown.
    ///
    /// - Parameter user: The authenticated user for service calls.
    @ViewBuilder
    private func detailContent(user: User) -> some View {
        if let tab = selectedTab {
            switch tab {
            case .admin:
                AdminView(
                    authenticationService: authenticationService,
                    entitlementService: entitlementService,
                    accountGroupService: accountGroupService,
                    currentUserId: user.id
                )

            case .search:
                SearchView(
                    accountService: accountService,
                    userId: user.id,
                    accountsForViewer: $accountsForViewer
                )

            case .accountsViewer:
                AccountsViewerView(
                    accountService: accountService,
                    valuationService: valuationService,
                    ledgerService: ledgerService,
                    referenceDataService: referenceDataService,
                    entitlementService: entitlementService,
                    selectedAccountIds: accountsForViewer.map(\.id),
                    userId: user.id
                )

            case .jobScheduler:
                JobSchedulerView(
                    jobSchedulerService: jobSchedulerService,
                    entitlementService: entitlementService,
                    userId: user.id
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Screen",
                systemImage: "sidebar.left",
                description: Text("Choose a screen from the sidebar to get started.")
            )
        }
    }

    // MARK: - Logout

    /// Toolbar button that clears the user session and returns to the login screen.
    ///
    /// Resets all navigation and selection state:
    /// - `currentUser` → `nil` (triggers LoginView display)
    /// - `accountsForViewer` → empty (clears stale viewer data)
    /// - `selectedTab` → `.search` (default tab for next session)
    private var logoutButton: some View {
        Button {
            logout()
        } label: {
            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .help("Log out of WealthLedger")
        .accessibilityLabel("Log Out")
    }

    /// Clears the user session and resets all state to defaults.
    ///
    /// Called by the logout toolbar button. The `currentUser = nil` assignment
    /// causes the view body to re-evaluate and display ``LoginView`` instead of
    /// the ``NavigationSplitView``.
    private func logout() {
        currentUser = nil
        accountsForViewer = []
        selectedTab = .search
    }
}

#endif
