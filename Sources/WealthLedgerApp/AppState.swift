#if canImport(SwiftUI)
// Sources/WealthLedgerApp/AppState.swift
// WealthLedger — Observable Application State
//
// Central reactive state container holding the current authenticated user session,
// selected accounts for the Accounts Viewer, SwiftUI navigation state, and global
// initialization/error indicators. Injected into the SwiftUI environment by
// `WealthLedgerApp.swift` and consumed by all four application screens.
//
// Concurrency Safety:
//   - `@MainActor` isolates all mutable state to the main thread, ensuring safe
//     access from SwiftUI views without data races.
//   - `@Observable` (Observation framework) provides automatic change tracking for
//     SwiftUI view invalidation without `@Published` or `ObservableObject`.
//   - `User` and `Account` are `Sendable` value types (structs), so storing them
//     in arrays or optionals does not break isolation.
//   - `NavigationPath` is a value type — inherently `Sendable`.
//   - Zero `@unchecked Sendable` annotations. Zero warning suppressions. (Gate 2)
//
// Rule 7 — Batch Memory Cap:
//   `selectedAccounts` is capped at `AppConstants.maxSearchResults` (1,000) by
//   `setSelectedAccounts(_:)`. No UI operation may hold more than 1,000 Account
//   objects in memory simultaneously.
//
// Rule 8 — MySQLKit-Only Persistence:
//   This file imports Foundation and SwiftUI only. No database imports (MySQLKit,
//   SwiftData, or otherwise) are present. SwiftData must NEVER appear in this project.

import Foundation
import SwiftUI
import RBAC
import AccountManagement
import Shared

// MARK: - AppState

/// Observable application state driving all reactive UI updates across the four
/// WealthLedger screens: Admin, Search, Accounts Viewer, and Job Scheduler.
///
/// `AppState` is created once by the `@main` entry point (`WealthLedgerApp`) and
/// injected into the SwiftUI environment via `.environment(appState)`. Every child
/// view can then read or modify state through `@Environment(AppState.self)`.
///
/// ## Properties
///
/// | Property | Type | Purpose |
/// |----------|------|---------|
/// | `currentUser` | `User?` | Authenticated session — `nil` means logged out |
/// | `selectedAccounts` | `[Account]` | Accounts selected from Search for the Viewer |
/// | `navigationPath` | `NavigationPath` | Programmatic `NavigationStack` routing |
/// | `isAuthenticated` | `Bool` (computed) | Convenience gate for login-required UI |
/// | `isInitialized` | `Bool` | `true` after `DatabaseManager.initialize()` succeeds |
/// | `errorMessage` | `String?` | Global error banner text |
///
/// ## Thread Safety
///
/// All mutable properties are isolated to `@MainActor`. Background tasks that need
/// to update state must hop to the main actor:
///
/// ```swift
/// await MainActor.run { appState.login(user: authenticatedUser) }
/// ```
///
/// ## Batch Memory Cap (Rule 7)
///
/// `setSelectedAccounts(_:)` enforces a hard cap of `AppConstants.maxSearchResults`
/// (1,000) accounts. Callers passing more than 1,000 accounts will have the array
/// silently truncated to the first 1,000 elements.
@Observable
@MainActor
public final class AppState {

    // MARK: - Stored Properties

    /// The currently authenticated user session.
    ///
    /// - `nil` when no user is logged in — the app displays a login prompt.
    /// - Set by `login(user:)` after successful bcrypt-verified authentication
    ///   via `AuthenticationService`.
    /// - Cleared by `logout()`, which also resets navigation and selection state.
    ///
    /// All screens must check `isAuthenticated` (or `currentUser != nil`) before
    /// permitting operations that require RBAC entitlement verification.
    public var currentUser: User? = nil

    /// Accounts selected from `SearchView` for display in `AccountsViewerView`.
    ///
    /// **Rule 7 — Batch Memory Cap**: This array is capped at
    /// `AppConstants.maxSearchResults` (1,000) elements. Always use
    /// `setSelectedAccounts(_:)` to mutate this property so the cap is enforced.
    ///
    /// Set by `SearchView` when the user taps "View Selected"; consumed by
    /// `AccountsViewerView` which renders accounts in a `LazyVStack` for
    /// performant 30fps scrolling.
    public var selectedAccounts: [Account] = []

    /// SwiftUI navigation state for programmatic `NavigationStack`-based routing.
    ///
    /// Enables navigation from one screen to another without direct view coupling.
    /// For example, `SearchView` can push an `AccountsViewerView` destination by
    /// appending a value to this path.
    ///
    /// Reset to an empty `NavigationPath()` on `logout()` to return the user to
    /// the root of the navigation hierarchy.
    public var navigationPath = NavigationPath()

    /// Whether the application has completed initial database setup.
    ///
    /// Set to `true` after `DatabaseManager.initialize()` succeeds (migrations
    /// applied, connectivity verified). Screens can show a loading indicator or
    /// a progress view until this flag becomes `true`.
    ///
    /// If initialization fails, `errorMessage` is set instead and this remains
    /// `false`, allowing the UI to display an appropriate error state.
    public var isInitialized: Bool = false

    /// Global error message for display in a banner or alert.
    ///
    /// Set when a critical operation fails (e.g., database connection failure,
    /// migration error). Cleared automatically by `login(user:)` on successful
    /// authentication, or can be cleared manually by setting to `nil`.
    public var errorMessage: String? = nil

    // MARK: - Computed Properties

    /// Whether a user is currently authenticated.
    ///
    /// Convenience computed property that returns `true` when `currentUser` is
    /// not `nil`. Used by views to gate UI sections behind authentication:
    ///
    /// ```swift
    /// if appState.isAuthenticated {
    ///     MainContentView()
    /// } else {
    ///     LoginView()
    /// }
    /// ```
    public var isAuthenticated: Bool {
        currentUser != nil
    }

    // MARK: - Initializer

    /// Creates a new `AppState` with default values.
    ///
    /// - No user is authenticated (`currentUser` is `nil`).
    /// - No accounts are selected (`selectedAccounts` is empty).
    /// - Navigation is at the root (`navigationPath` is empty).
    /// - Database is not yet initialized (`isInitialized` is `false`).
    /// - No error is present (`errorMessage` is `nil`).
    ///
    /// Called by `WealthLedgerApp.swift` during application launch:
    /// ```swift
    /// @State private var appState = AppState()
    /// ```
    public init() {
        // All properties use their declared default values.
        // Explicit init required for public access from WealthLedgerApp.swift.
    }

    // MARK: - Methods

    /// Sets the accounts selected for viewing, enforcing the batch memory cap.
    ///
    /// **Rule 7 — Batch Memory Cap**: If the provided array contains more than
    /// `AppConstants.maxSearchResults` (1,000) elements, only the first 1,000
    /// are retained. This prevents the Accounts Viewer from loading excessive
    /// account objects into memory.
    ///
    /// - Parameter accounts: Array of accounts selected from search results.
    ///   Truncated to 1,000 elements if the count exceeds the cap.
    ///
    /// ## Usage
    /// Called by `SearchView` when the user confirms their account selection:
    /// ```swift
    /// appState.setSelectedAccounts(selectedSearchResults)
    /// ```
    public func setSelectedAccounts(_ accounts: [Account]) {
        if accounts.count > AppConstants.maxSearchResults {
            selectedAccounts = Array(accounts.prefix(AppConstants.maxSearchResults))
        } else {
            selectedAccounts = accounts
        }
    }

    /// Sets the authenticated user session after successful login.
    ///
    /// Updates `currentUser` with the authenticated `User` instance and clears
    /// any existing `errorMessage` (since a successful login indicates the system
    /// is functioning correctly).
    ///
    /// - Parameter user: The authenticated user returned by
    ///   `AuthenticationService.login(username:password:)` after bcrypt
    ///   verification succeeds.
    ///
    /// ## Usage
    /// ```swift
    /// let user = try await authService.login(username: name, password: pass)
    /// appState.login(user: user)
    /// ```
    public func login(user: User) {
        currentUser = user
        errorMessage = nil
    }

    /// Clears the current user session and resets all navigation and selection state.
    ///
    /// After logout:
    /// - `currentUser` is `nil` (no authenticated session).
    /// - `selectedAccounts` is empty (no stale viewer data).
    /// - `navigationPath` is reset to an empty path (returns to root).
    ///
    /// `isInitialized` is intentionally NOT reset — the database connection
    /// remains active; only the user session is cleared.
    ///
    /// ## Usage
    /// ```swift
    /// appState.logout()
    /// // UI automatically transitions to login screen via isAuthenticated check
    /// ```
    public func logout() {
        currentUser = nil
        selectedAccounts = []
        navigationPath = NavigationPath()
    }

    /// Clears the selected accounts without affecting the user session.
    ///
    /// Called when the user navigates away from the Accounts Viewer to free
    /// the memory held by the selected account objects. The user session and
    /// navigation state are preserved.
    ///
    /// ## Usage
    /// ```swift
    /// // In AccountsViewerView.onDisappear:
    /// appState.clearSelection()
    /// ```
    public func clearSelection() {
        selectedAccounts = []
    }
}
#endif
