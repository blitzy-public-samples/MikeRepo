#if canImport(SwiftUI)
// Sources/WealthLedgerApp/WealthLedgerApp.swift
// WealthLedger — @main Application Entry Point
//
// Root `App` struct for the WealthLedger macOS desktop application. This is the
// single entry point that bootstraps all infrastructure and presents the UI:
//
//   1. Creates `DatabaseManager` with localhost-only MySQL configuration (Rule 9).
//   2. Creates `DependencyContainer` wiring all six business modules (Gate 9).
//   3. Creates `AppState` for reactive UI state management.
//   4. Presents `MainNavigationView` as the root scene, passing all services
//      via constructor injection.
//   5. Runs database initialization (migrations, connectivity) asynchronously
//      via the `.task` modifier to avoid blocking the main thread.
//
// Rule 8  — MySQLKit-only persistence. Zero SwiftData imports. Verified by:
//           `grep -r "import SwiftData"` returning zero results.
// Rule 9  — Offline runtime. Database connection targets localhost:3306 only.
//           Zero external network calls. App functions with network adapter disabled.
// Gate 2  — Swift 6 strict concurrency. Zero warnings, zero `@unchecked Sendable`,
//           zero warning suppressions, zero `// swiftlint:disable` directives.
// Gate 9  — Integration wiring verification. All six business modules are reachable
//           from @main through DependencyContainer → MainNavigationView → child views:
//             • AccountManagement  → container.accountService, container.accountGroupService
//             • LedgerEngine       → container.ledgerService
//             • ValuationEngine    → container.valuationService
//             • ReferenceDataService → container.referenceDataService
//             • JobScheduler       → container.jobSchedulerService
//             • RBAC               → container.authenticationService, container.entitlementService
//
// Concurrency Safety:
//   - `WealthLedgerApp` is a struct conforming to `App` — implicitly `@MainActor`
//     isolated in Swift 6, making all property access and body evaluation safe.
//   - `@State private var appState`: `AppState` is `@Observable @MainActor` — the
//     standard SwiftUI pattern for observable state owned by the app root.
//   - `let container`: `DependencyContainer` is `Sendable` with exclusively `let`
//     properties — safe to capture in the `.task` closure and pass across isolation.
//   - The `.task` closure inherits `@MainActor` isolation from the enclosing view
//     context, so `appState` mutations after `await` are safe.
//
// SPDX-License-Identifier: MIT

import SwiftUI
import Persistence
import UILayer

// MARK: - WealthLedgerApp

/// The `@main` entry point for the WealthLedger macOS desktop application.
///
/// `WealthLedgerApp` is a SwiftUI `App` struct that initializes all infrastructure
/// and presents the root navigation view. It serves as the integration hub connecting
/// the persistence layer, all six business modules, and the four-screen UI.
///
/// ## Initialization Sequence
///
/// 1. `init()` creates `DatabaseManager` with localhost MySQL configuration and
///    environment-variable credentials (with sensible defaults for development).
/// 2. `init()` creates `DependencyContainer`, which constructs all repositories,
///    services, and cross-module wiring in bottom-up dependency order.
/// 3. `body` presents `MainNavigationView` with all eight services injected via
///    constructor parameters, and injects `AppState` and `DependencyContainer`
///    into the SwiftUI environment for any views that access them via environment.
/// 4. The `.task` modifier triggers asynchronous database initialization (health
///    check + ordered SQL migrations) after the UI appears, updating `AppState`
///    with the result.
///
/// ## Gate 9 Compliance
///
/// All six business modules are reachable from this `@main` entry point:
///
/// | Module              | Service(s)                                       | UI Path                          |
/// |---------------------|--------------------------------------------------|----------------------------------|
/// | AccountManagement   | `accountService`, `accountGroupService`           | SearchView, AdminView            |
/// | LedgerEngine        | `ledgerService`                                   | AccountsViewerView               |
/// | ValuationEngine     | `valuationService`                                | AccountsViewerView               |
/// | ReferenceDataService| `referenceDataService`                            | AccountsViewerView, JobScheduler |
/// | JobScheduler        | `jobSchedulerService`                             | JobSchedulerView                 |
/// | RBAC                | `authenticationService`, `entitlementService`     | All views (login gate + RBAC)    |
///
/// ## Environment Injection
///
/// - `.environment(appState)` — `AppState` injected as `@Observable` for child views
///   using `@Environment(AppState.self)`.
/// - `.environment(\.dependencyContainer, container)` — `DependencyContainer` injected
///   via custom `EnvironmentKey` for views using `@Environment(\.dependencyContainer)`.
@main
struct WealthLedgerApp: App {

    // MARK: - State Properties

    /// Observable application state holding the current user session, selected accounts,
    /// navigation path, initialization status, and global error message.
    ///
    /// Created with default values (no user, no selection, not initialized). Injected
    /// into the SwiftUI environment via `.environment(appState)` so all child views
    /// can access reactive state through `@Environment(AppState.self)`.
    ///
    /// `@State` ensures SwiftUI persists this instance across view identity changes.
    /// `AppState` is `@Observable @MainActor` — the standard SwiftUI 5.9+ pattern.
    @State private var appState = AppState()

    /// Central dependency injection container providing access to all module services,
    /// repositories, and infrastructure components.
    ///
    /// Created once during `init()` with the `DatabaseManager` instance. All stored
    /// properties are immutable (`let`), making `DependencyContainer` thread-safe
    /// (`Sendable`) and suitable for capture in async closures.
    ///
    /// Stored as `let` because `DependencyContainer` is a `Sendable` final class
    /// with exclusively immutable properties — it never changes after construction.
    let container: DependencyContainer

    // MARK: - Initializer

    /// Creates the application entry point, initializing database configuration and
    /// all module services.
    ///
    /// The initialization sequence:
    /// 1. Reads database credentials from environment variables with development defaults.
    /// 2. Creates `DatabaseManager` targeting localhost:3306 (Rule 9 — offline runtime).
    /// 3. Creates `DependencyContainer` which constructs all repositories and services
    ///    in correct dependency order (Gate 9 — integration wiring).
    ///
    /// No database connection is established during `init()` — connectivity and
    /// migrations are deferred to the async `.task` modifier in `body` to avoid
    /// blocking the main thread during application launch.
    init() {
        // Read database credentials from environment variables.
        // Defaults match the development setup from Scripts/setup_database.sh
        // and the setup agent's MySQL configuration.
        let dbUsername = ProcessInfo.processInfo.environment["DB_USERNAME"] ?? "wealthledger"
        let dbPassword = ProcessInfo.processInfo.environment["DB_PASSWORD"] ?? "wealthledger_pass"
        let dbName = ProcessInfo.processInfo.environment["DB_NAME"] ?? "wealth_ledger"

        // Create the database manager with localhost-only configuration.
        // Rule 9 — Offline Runtime: hostname is always "localhost", port is always 3306.
        // No external network calls are made. The application functions with the
        // network adapter disabled.
        let databaseManager = DatabaseManager(
            hostname: "localhost",
            port: 3306,
            username: dbUsername,
            password: dbPassword,
            database: dbName
        )

        // Create the dependency container, wiring all module services.
        // Gate 9 — Integration Wiring: DependencyContainer constructs and registers
        // all repositories, RBAC services, AccountManagement, LedgerEngine,
        // ValuationEngine, ReferenceDataService, and JobScheduler in bottom-up
        // dependency order. Every business module is reachable through this container.
        self.container = DependencyContainer(databaseManager: databaseManager)
    }

    // MARK: - Scene

    /// The root scene presenting the application's navigation structure.
    ///
    /// Configures a `WindowGroup` containing `MainNavigationView` as the root view.
    /// All eight services are passed to `MainNavigationView` via constructor injection
    /// (avoiding circular dependencies between WealthLedgerApp and UILayer modules).
    ///
    /// Environment injection provides `AppState` and `DependencyContainer` to any
    /// descendant view that accesses them via SwiftUI environment.
    ///
    /// The `.task` modifier triggers asynchronous database initialization after the
    /// UI appears, updating `AppState.isInitialized` on success or
    /// `AppState.errorMessage` on failure.
    var body: some Scene {
        WindowGroup {
            MainNavigationView(
                authenticationService: container.authenticationService,
                entitlementService: container.entitlementService,
                accountService: container.accountService,
                accountGroupService: container.accountGroupService,
                valuationService: container.valuationService,
                ledgerService: container.ledgerService,
                referenceDataService: container.referenceDataService,
                jobSchedulerService: container.jobSchedulerService
            )
            .environment(appState)
            .environment(\.dependencyContainer, container)
            .task {
                // Asynchronous database initialization — runs after the UI appears
                // to avoid blocking the main thread during application launch.
                //
                // DatabaseManager.initialize() performs two steps:
                //   1. Health check — executes SELECT 1 to verify MySQL connectivity.
                //   2. Migration execution — runs pending SQL scripts from
                //      Resources/Migrations/ in numerical order (001 → 008).
                //
                // On success, AppState.isInitialized is set to true, enabling
                // screens to transition from loading state to interactive state.
                //
                // On failure, AppState.errorMessage is set with the error description,
                // allowing the UI to display an appropriate error banner or alert.
                // The application remains running so the user can retry or diagnose.
                do {
                    try await container.databaseManager.initialize()
                    appState.isInitialized = true
                } catch {
                    appState.errorMessage =
                        "Database initialization failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

#else
// ──────────────────────────────────────────────────────────────────────────────
// Non-macOS Platform Stub (Linux CI)
// ──────────────────────────────────────────────────────────────────────────────
//
// WealthLedger is a macOS desktop application requiring SwiftUI, which is not
// available on Linux. This stub entry point allows the executable target to
// compile and link on Linux for CI/CD validation (swift build, swift test).
//
// The actual application logic resides in the #if canImport(SwiftUI) branch above.
// Running this executable on Linux exits gracefully with an informational message.

import Foundation

@main
struct WealthLedgerApp {

    /// Stub entry point for non-macOS platforms.
    ///
    /// Prints an informational message and exits cleanly. This is intentionally
    /// non-crashing (unlike `fatalError`) to prevent CI failures if the executable
    /// is accidentally invoked during automated testing.
    static func main() {
        print("WealthLedger is a macOS desktop application requiring SwiftUI.")
        print("This executable is not supported on the current platform.")
        print("Use 'swift build' and 'swift test' for CI validation.")
    }
}

#endif
