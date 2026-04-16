// Sources/WealthLedgerApp/DependencyContainer.swift
// WealthLedger — Service Locator for Dependency Injection
//
// Central dependency injection container that registers all module services,
// repositories, and infrastructure components. This class is the integration
// hub connecting all nine library modules and making them accessible to the
// SwiftUI environment for the four application screens.
//
// Gate 9  — Every business module is registered and accessible from this container.
// Rule 4  — EntitlementService injected into AccountService and LedgerService.
// Rule 1  — DoubleEntryValidator injected into LedgerService.
// Rule 8  — NO SwiftData. MySQLKit-only persistence via repositories.
// Rule 11 — AccountRepository + ConnectionPool injected into ValuationService.
// Gate 2  — Swift 6 strict concurrency: final class with let-only properties.
//           Zero @unchecked Sendable. Zero warning suppressions.
//
// SPDX-License-Identifier: MIT

import Foundation
import Logging

#if canImport(SwiftUI)
import SwiftUI
#endif

import Persistence
import AccountManagement
import LedgerEngine
import ValuationEngine
import Shared

// Selective imports to avoid ReferenceData type name collisions between
// Persistence.ReferenceData and ReferenceDataService.ReferenceData.
// The module and the primary service class share the same name, so we
// use module-qualified imports for disambiguation.
import struct ReferenceDataService.CSVParser
import struct ReferenceDataService.CSVExporter
import class ReferenceDataService.ReferenceDataService

import class JobScheduler.JobSchedulerService
import class JobScheduler.ReportGenerator

import class RBAC.AuthenticationService
import class RBAC.EntitlementService
import struct RBAC.PasswordHasher

// MARK: - DependencyContainer

/// Central service locator that registers all module services for dependency injection.
///
/// `DependencyContainer` constructs and wires together all infrastructure components,
/// repositories, and service classes in correct dependency order (bottom-up). It serves
/// as the single source of truth for service instances throughout the application.
///
/// ## Gate 9 — Integration Wiring Verification
///
/// Every one of the six business modules is registered and accessible:
/// 1. **AccountManagement** → `AccountService`, `AccountGroupService`
/// 2. **LedgerEngine** → `LedgerService` (with `DoubleEntryValidator`)
/// 3. **ValuationEngine** → `ValuationService` (with `NAVCalculator`)
/// 4. **ReferenceDataService** → `ReferenceDataService`, `CSVParser`, `CSVExporter`
/// 5. **JobScheduler** → `JobSchedulerService`, `ReportGenerator`
/// 6. **RBAC** → `AuthenticationService`, `EntitlementService`, `PasswordHasher`
///
/// Plus all 7 repositories and infrastructure (DatabaseManager, ConnectionPool).
///
/// ## Thread Safety (Gate 2)
///
/// This class is `final` with exclusively `let` properties. All stored types
/// are `Sendable`-conforming (final classes with `let` properties, actors,
/// value types). Zero `@unchecked Sendable` annotations.
///
/// ## SwiftUI Environment Integration
///
/// On platforms where SwiftUI is available, `DependencyContainer` is injected
/// into the SwiftUI environment via a custom `EnvironmentKey`. Views access
/// it with `@Environment(\.dependencyContainer)`.
///
/// ## Wiring Order
///
/// ```
/// 1. ConnectionPool (from DatabaseManager.pool)
/// 2. All 7 Repositories (each takes ConnectionPool)
/// 3. RBAC: PasswordHasher → AuthenticationService, EntitlementService
/// 4. AccountManagement: AccountGroupService, AccountService
/// 5. LedgerEngine: DoubleEntryValidator → LedgerService
/// 6. ValuationEngine: NAVCalculator → ValuationService
/// 7. ReferenceDataService: CSVParser, CSVExporter → ReferenceDataService
/// 8. JobScheduler: ReportGenerator → JobSchedulerService
/// ```
public final class DependencyContainer: Sendable {

    // MARK: - Infrastructure

    /// Core database manager providing MySQLKit configuration, EventLoopGroup
    /// lifecycle, and access to the ConnectionPool.
    public let databaseManager: DatabaseManager

    /// AsyncKit-based connection pool for managed MySQL connections.
    /// Derived from `databaseManager.pool` during initialization.
    public let connectionPool: ConnectionPool

    // MARK: - Repositories (7 total — one per primary entity table)

    /// Account table CRUD, search, batch operations, cached valuation updates.
    public let accountRepository: AccountRepository

    /// Append-only transaction inserts (Rule 2: no UPDATE/DELETE).
    public let transactionRepository: TransactionRepository

    /// Position CRUD with FK enforcement to accounts and reference_data.
    public let positionRepository: PositionRepository

    /// User CRUD with password hash storage.
    public let userRepository: UserRepository

    /// Entitlement CRUD and permission flag queries.
    public let entitlementRepository: EntitlementRepository

    /// Account group CRUD.
    public let accountGroupRepository: AccountGroupRepository

    /// Reference data bulk insert and EOD price queries.
    public let referenceDataRepository: ReferenceDataRepository

    // MARK: - RBAC Services (cross-cutting, wired first)

    /// Stateless bcrypt hashing wrapper (BCryptSwift).
    public let passwordHasher: PasswordHasher

    /// Local authentication: username/password verification against bcrypt hashes.
    public let authenticationService: AuthenticationService

    /// Cross-cutting entitlement enforcement (Rule 4).
    public let entitlementService: EntitlementService

    // MARK: - AccountManagement Services

    /// Account group CRUD operations.
    public let accountGroupService: AccountGroupService

    /// Account CRUD, search with pagination, batch status updates.
    /// Enforces entitlement checks per Rule 4.
    public let accountService: AccountService

    // MARK: - LedgerEngine Services

    /// Transaction posting with double-entry validation and restatement.
    public let ledgerService: LedgerService

    // MARK: - ValuationEngine Services

    /// Pure NAV calculation engine: Σ(qty × EOD midpoint) + cash_balance.
    public let navCalculator: NAVCalculator

    /// Batch valuation orchestrator with timezone-aware value dates (Rule 3)
    /// and atomic cached valuation denormalization (Rule 11).
    public let valuationService: ValuationService

    // MARK: - ReferenceDataService Services

    /// Stateless CSV parser with column validation and streaming.
    public let csvParser: CSVParser

    /// Stateless CSV exporter with RFC 4180 formatting.
    public let csvExporter: CSVExporter

    /// Reference data query, management, and CSV ingestion service.
    /// Module-qualified type: `ReferenceDataService.ReferenceDataService`
    /// to resolve the module/class name collision.
    public let referenceDataService: ReferenceDataService

    // MARK: - JobScheduler Services

    /// Paginated CSV report generator with configurable field selection.
    public let reportGenerator: ReportGenerator

    /// Job lifecycle management: creation, manual execution, status tracking.
    public let jobSchedulerService: JobSchedulerService

    // MARK: - Initializer (Bottom-Up Wiring)

    /// Creates a new `DependencyContainer` by constructing and wiring all services.
    ///
    /// The wiring order follows the module dependency graph from bottom (infrastructure)
    /// to top (job scheduler). Each service receives only its declared dependencies.
    ///
    /// - Parameter databaseManager: The initialized database manager providing
    ///   the connection pool and migration infrastructure.
    public init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.connectionPool = databaseManager.pool

        // ──────────────────────────────────────────────────
        // 1. Repositories (depend on ConnectionPool only)
        // ──────────────────────────────────────────────────

        let accountRepo = AccountRepository(pool: connectionPool)
        let transactionRepo = TransactionRepository(pool: connectionPool)
        let positionRepo = PositionRepository(pool: connectionPool)
        let userRepo = UserRepository(pool: connectionPool)
        let entitlementRepo = EntitlementRepository(pool: connectionPool)
        let accountGroupRepo = AccountGroupRepository(pool: connectionPool)
        let referenceDataRepo = ReferenceDataRepository(pool: connectionPool)

        self.accountRepository = accountRepo
        self.transactionRepository = transactionRepo
        self.positionRepository = positionRepo
        self.userRepository = userRepo
        self.entitlementRepository = entitlementRepo
        self.accountGroupRepository = accountGroupRepo
        self.referenceDataRepository = referenceDataRepo

        // ──────────────────────────────────────────────────
        // 2. RBAC Services (depend on repositories)
        // ──────────────────────────────────────────────────

        let hasher = PasswordHasher()
        let authService = AuthenticationService(
            userRepository: userRepo,
            passwordHasher: hasher
        )
        let entService = EntitlementService(
            entitlementRepository: entitlementRepo,
            accountGroupRepository: accountGroupRepo
        )

        self.passwordHasher = hasher
        self.authenticationService = authService
        self.entitlementService = entService

        // ──────────────────────────────────────────────────
        // 3. AccountManagement Services (depend on repositories + EntitlementService for Rule 4)
        // ──────────────────────────────────────────────────

        let acctGroupService = AccountGroupService(
            accountGroupRepository: accountGroupRepo
        )
        let acctService = AccountService(
            accountRepository: accountRepo,
            entitlementService: entService,
            accountGroupService: acctGroupService
        )

        self.accountGroupService = acctGroupService
        self.accountService = acctService

        // ──────────────────────────────────────────────────
        // 4. LedgerEngine Services (depend on repositories + DoubleEntryValidator + EntitlementService)
        // ──────────────────────────────────────────────────

        let validator = DoubleEntryValidator()
        let ledger = LedgerService(
            transactionRepository: transactionRepo,
            positionRepository: positionRepo,
            doubleEntryValidator: validator,
            entitlementService: entService
        )

        self.ledgerService = ledger

        // ──────────────────────────────────────────────────
        // 5. ValuationEngine Services (depend on repositories + NAVCalculator + ConnectionPool)
        // ──────────────────────────────────────────────────

        let calculator = NAVCalculator()
        let valService = ValuationService(
            accountRepository: accountRepo,
            positionRepository: positionRepo,
            referenceDataRepository: referenceDataRepo,
            navCalculator: calculator,
            connectionPool: connectionPool
        )

        self.navCalculator = calculator
        self.valuationService = valService

        // ──────────────────────────────────────────────────
        // 6. ReferenceDataService Services (depend on repositories + CSVParser)
        // ──────────────────────────────────────────────────

        let parser = CSVParser()
        let exporter = CSVExporter()
        let refDataService = ReferenceDataService(
            repository: referenceDataRepo,
            csvParser: parser
        )

        self.csvParser = parser
        self.csvExporter = exporter
        self.referenceDataService = refDataService

        // ──────────────────────────────────────────────────
        // 7. JobScheduler Services (depend on multiple modules — wired last)
        // ──────────────────────────────────────────────────

        let reportGen = ReportGenerator(
            accountService: acctService,
            valuationService: valService,
            csvExporter: exporter
        )
        let jobService = JobSchedulerService(
            reportGenerator: reportGen,
            csvParser: parser,
            referenceDataService: refDataService,
            accountService: acctService,
            valuationService: valService
        )

        self.reportGenerator = reportGen
        self.jobSchedulerService = jobService
    }
}

// MARK: - SwiftUI Environment Integration

#if canImport(SwiftUI)

/// Custom environment key for injecting `DependencyContainer` into SwiftUI views.
///
/// Usage in SwiftUI views:
/// ```swift
/// @Environment(\.dependencyContainer) var container
/// ```
///
/// Set in the root scene:
/// ```swift
/// WindowGroup {
///     MainNavigationView()
///         .environment(\.dependencyContainer, container)
/// }
/// ```
private struct DependencyContainerKey: EnvironmentKey {
    static let defaultValue: DependencyContainer? = nil
}

extension EnvironmentValues {
    /// The shared dependency container providing access to all module services.
    ///
    /// Set at the root of the SwiftUI view hierarchy and accessed by any
    /// descendant view that needs to interact with backend services.
    public var dependencyContainer: DependencyContainer? {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }
}

#endif
