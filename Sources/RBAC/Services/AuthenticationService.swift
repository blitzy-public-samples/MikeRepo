// AuthenticationService.swift
// WealthLedger - RBAC Module
//
// Provides local authentication for the WealthLedger application: user login via
// bcrypt-hashed password verification and user creation with duplicate detection.
//
// This service is STATELESS — it does not store session state. Session management
// (current user tracking) is handled by AppState (@Observable class holding
// currentUser: User?). The flow is:
//   1. UI calls authenticationService.login(username:password:)
//   2. If a User is returned, UI sets appState.currentUser = user
//   3. If nil is returned, UI shows "login failed"
//   4. Navigation is gated on appState.currentUser != nil
//
// Dependency Delegation:
//   - Password hashing/verification → PasswordHasher (wraps BCryptSwift)
//   - Database operations → UserRepository (wraps MySQLKit)
//   - This file does NOT import BCryptSwift or MySQLKit directly
//
// Type Conversion Note:
//   Both the RBAC module and the Persistence module define a public `User` struct
//   with identical structure (id, username, passwordHash). This duplication exists
//   to avoid a circular dependency (RBAC → Persistence → RBAC). UserRepository
//   methods return `Persistence.User`, while AuthenticationService's public API
//   exposes `RBAC.User` (the local module's type). Conversion between the two is
//   performed via straightforward property mapping.
//
// Swift 6 Strict Concurrency (Gate 2):
//   AuthenticationService is a `final class` with only `let` stored properties,
//   both of which are themselves `Sendable` (UserRepository is a Sendable final
//   class; PasswordHasher is a Sendable struct). No `@unchecked Sendable` or
//   warning suppressions are needed.
//
// Security Design:
//   - Plaintext passwords are NEVER stored — only bcrypt hashes
//   - login() returns nil for both "user not found" and "wrong password" — callers
//     cannot distinguish between the two, preventing username enumeration attacks
//   - Infrastructure failures (DB errors) propagate as thrown errors
//   - AppError.duplicateUser propagates from UserRepository on UNIQUE constraint
//     violation during createUser()
//
// Rule 8 Compliance: No SwiftData imports.
// Rule 9 Compliance: No network calls — local MySQL only (delegated to UserRepository).
//
// Consumers:
//   - DependencyContainer — registers this service with injected dependencies
//   - AdminView — calls createUser() for user creation form
//   - MainNavigationView — calls login() for authentication gating
//   - AppState — stores the User returned by login()

import Foundation
import Persistence
import Shared

// MARK: - AuthenticationService

/// Local authentication service for the WealthLedger RBAC system.
///
/// `AuthenticationService` manages two core operations:
/// 1. **Login** — Authenticates a user by verifying the provided plaintext password
///    against the bcrypt hash stored in the MySQL `users` table.
/// 2. **User Creation** — Creates a new user with a bcrypt-hashed password, rejecting
///    duplicate usernames via MySQL UNIQUE constraint enforcement.
///
/// The service delegates all cryptographic operations to ``PasswordHasher`` and all
/// database operations to ``UserRepository``, keeping itself free of direct framework
/// dependencies on BCryptSwift or MySQLKit.
///
/// ## Thread Safety (Swift 6 Strict Concurrency — Gate 2)
///
/// This class is declared `final` with only immutable (`let`) stored properties that
/// are themselves `Sendable`:
/// - `userRepository: any UserRepositoryProtocol` — a `Sendable` existential
/// - `passwordHasher: PasswordHasher` — a `Sendable` struct
///
/// No `@unchecked Sendable` annotations or warning suppressions are used. All methods
/// are `async throws`, compatible with structured concurrency.
///
/// ## Error Contract
///
/// - `login(username:password:)` returns `nil` for authentication failures and throws
///   only on infrastructure errors (database connectivity, query execution).
/// - `createUser(username:password:)` throws `AppError.duplicateUser` (propagated from
///   `UserRepository`) when the username already exists in the database.
/// - `listUsers()` throws only on infrastructure errors.
///
/// ## Usage
/// ```swift
/// let authService = AuthenticationService(
///     userRepository: userRepo,
///     passwordHasher: PasswordHasher()
/// )
///
/// // Login
/// if let user = try await authService.login(username: "admin", password: "secret") {
///     appState.currentUser = user
/// }
///
/// // Create user
/// let newUser = try await authService.createUser(username: "analyst", password: "secure123")
/// ```
public final class AuthenticationService: Sendable {

    // MARK: - Properties

    /// Persistence layer for user records, injected via protocol for testability.
    ///
    /// Provides `findByUsername(_:)` for authentication lookup and `create(_:)` for
    /// new user persistence. Handles MySQL duplicate key errors (code 1062) and
    /// throws `AppError.duplicateUser` for existing usernames.
    ///
    /// Returns `Persistence.User` instances which are converted to `RBAC.User`
    /// before being exposed through the public API.
    ///
    /// Accepts any type conforming to ``UserRepositoryProtocol`` — the concrete
    /// ``UserRepository`` for production use, or a mock for unit testing.
    private let userRepository: any UserRepositoryProtocol

    /// Bcrypt password hashing and verification service.
    ///
    /// Provides `hash(_:)` for generating bcrypt hashes during user creation and
    /// `verify(_:against:)` for password verification during login. Encapsulates
    /// all BCryptSwift interactions — this class never imports BCryptSwift directly.
    private let passwordHasher: PasswordHasher

    // MARK: - Initializer

    /// Creates a new `AuthenticationService` with the given dependencies.
    ///
    /// Both dependencies are injected by ``DependencyContainer`` during application
    /// startup. No global state or singletons are used.
    ///
    /// - Parameters:
    ///   - userRepository: Any type conforming to ``UserRepositoryProtocol`` for
    ///     user persistence operations. Use ``UserRepository`` for production and
    ///     a mock implementation for testing.
    ///   - passwordHasher: The bcrypt hashing service for password operations.
    public init(userRepository: any UserRepositoryProtocol, passwordHasher: PasswordHasher) {
        self.userRepository = userRepository
        self.passwordHasher = passwordHasher
    }

    // MARK: - Authentication

    /// Authenticates a user by verifying the provided password against the stored
    /// bcrypt hash.
    ///
    /// This method performs a two-step authentication flow:
    /// 1. Looks up the user by username via ``UserRepository/findByUsername(_:)``.
    /// 2. Verifies the plaintext password against the stored bcrypt hash via
    ///    ``PasswordHasher/verify(_:against:)``.
    ///
    /// Returns `nil` for **all** authentication failures — both "user not found"
    /// and "wrong password" — to prevent username enumeration attacks. Only
    /// infrastructure failures (database connectivity, query execution errors)
    /// are thrown as errors.
    ///
    /// The returned ``User`` object is the session identity used by `AppState.currentUser`
    /// to gate navigation and track the current session.
    ///
    /// - Parameters:
    ///   - username: The username to authenticate.
    ///   - password: The plaintext password to verify against the stored bcrypt hash.
    ///
    /// - Returns: The authenticated ``User`` on success, or `nil` if authentication
    ///   fails (user not found or password mismatch).
    ///
    /// - Throws: Database connectivity or query execution errors (infrastructure
    ///   failures only — authentication failures return `nil`).
    public func login(username: String, password: String) async throws -> User? {
        // Step 1: Retrieve the user record from MySQL via UserRepository.
        // UserRepository.findByUsername returns Persistence.User? (different module type).
        guard let persistedUser = try await userRepository.findByUsername(username) else {
            // User not found — return nil, do NOT throw an error.
            // This prevents username enumeration by keeping the response identical
            // to a wrong-password scenario.
            return nil
        }

        // Step 2: Convert Persistence.User to RBAC.User for domain operations.
        // Both types are structurally identical but nominally different across modules.
        let user = AuthenticationService.convertUser(persistedUser)

        // Step 3: Verify the plaintext password against the stored bcrypt hash.
        // PasswordHasher.verify performs constant-time comparison (timing-attack safe).
        guard passwordHasher.verify(password, against: user.passwordHash) else {
            // Wrong password — return nil, same response as user-not-found.
            return nil
        }

        // Authentication successful — return the RBAC.User for session identity.
        return user
    }

    // MARK: - User Management

    /// Creates a new user with a bcrypt-hashed password.
    ///
    /// This method performs the following steps:
    /// 1. Hashes the plaintext password via ``PasswordHasher/hash(_:)`` to generate
    ///    the bcrypt hash **before** creating any User struct.
    /// 2. Creates a `Persistence.User` instance with the hashed password and passes
    ///    it to ``UserRepository/create(_:)`` for MySQL insertion.
    /// 3. Returns the created ``User`` with the database-assigned auto-increment ID.
    ///
    /// ## Duplicate Username Handling
    ///
    /// If the username already exists, `UserRepository.create(_:)` catches MySQL
    /// error code 1062 (ER_DUP_ENTRY) and throws `AppError.duplicateUser`. This
    /// error propagates through `createUser()` to the caller (typically `AdminView`)
    /// for user-facing error display.
    ///
    /// ## Security
    ///
    /// - The plaintext password is **never** stored in any User struct or property.
    /// - bcrypt hash is generated **before** the User struct is created.
    /// - BCryptSwift handles salt generation internally — no manual salt management.
    /// - The bcrypt output format (`$2a$12$...`, ~60 chars) fits within
    ///   `VARCHAR(255)` in the `users.password_hash` column.
    ///
    /// - Parameters:
    ///   - username: The unique username for the new user. Must not already exist
    ///     in the database (enforced by MySQL UNIQUE constraint).
    ///   - password: The plaintext password to hash and store.
    ///
    /// - Returns: The created ``User`` with the database-assigned ID.
    ///
    /// - Throws: `AppError.duplicateUser` if the username already exists.
    ///   Other MySQL errors propagate as-is for infrastructure failure handling.
    public func createUser(username: String, password: String) async throws -> User {
        // Step 0: Validate input — reject empty or whitespace-only usernames
        // and empty passwords at the service layer. The DB enforces NOT NULL
        // and UNIQUE, but an empty string passes both constraints, so we must
        // guard against it here before any hashing or persistence occurs.
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw AppError.dataAccessFailed("Username must not be empty or whitespace-only")
        }
        guard !password.isEmpty else {
            throw AppError.dataAccessFailed("Password must not be empty")
        }

        // Step 1: Hash the plaintext password BEFORE creating any User struct.
        // This ensures the plaintext password is never stored in a User instance.
        let hashedPassword = passwordHasher.hash(password)

        // Step 2: Create a Persistence.User for the repository.
        // Uses the module-qualified type to distinguish from RBAC.User.
        // The id defaults to 0 — MySQL assigns the actual auto-increment ID.
        let newPersistenceUser = Persistence.User(
            username: username,
            passwordHash: hashedPassword
        )

        // Step 3: Persist the user via UserRepository.
        // UserRepository.create handles duplicate detection:
        //   - MySQL UNIQUE constraint on username → error code 1062
        //   - Caught by UserRepository → thrown as AppError.duplicateUser
        let createdPersistenceUser = try await userRepository.create(newPersistenceUser)

        // Step 4: Convert Persistence.User (with DB-assigned ID) to RBAC.User.
        return AuthenticationService.convertUser(createdPersistenceUser)
    }

    /// Lists all registered users in the system.
    ///
    /// Retrieves users from the database with pagination enforced per Rule 7
    /// (Batch Memory Cap: no more than 1,000 records loaded simultaneously).
    /// With the system designed for approximately 300 registered users, a single
    /// page of 1,000 records is sufficient to return all users.
    ///
    /// This method is consumed by `AdminView` to populate the user list for
    /// entitlement assignment operations.
    ///
    /// - Returns: An array of all registered ``User`` instances, up to the
    ///   Rule 7 batch memory cap of 1,000 records.
    ///
    /// - Throws: Database connectivity or query execution errors.
    public func listUsers() async throws -> [User] {
        // Rule 7: Batch memory cap — paginate at 1,000 records per page.
        // With ~300 registered users, page 1 at pageSize 1,000 returns all users.
        let persistedUsers = try await userRepository.findAll(page: 1, pageSize: 1_000)

        // Convert [Persistence.User] to [RBAC.User] for the public API.
        return persistedUsers.map { AuthenticationService.convertUser($0) }
    }

    // MARK: - Private Helpers

    /// Converts a `Persistence.User` to an `RBAC.User`.
    ///
    /// Both the RBAC and Persistence modules define a `User` struct with identical
    /// structure (`id: UInt64`, `username: String`, `passwordHash: String`). This
    /// duplication exists to avoid a circular module dependency (RBAC → Persistence
    /// → RBAC). This helper performs the straightforward property-to-property mapping.
    ///
    /// Declared `static` to allow safe invocation from `@Sendable` contexts without
    /// capturing `self`, and to avoid actor-isolation concerns.
    ///
    /// - Parameter persistenceUser: The user instance from the Persistence module.
    /// - Returns: An equivalent user instance in the RBAC module's type system.
    private static func convertUser(_ persistenceUser: Persistence.User) -> User {
        User(
            id: persistenceUser.id,
            username: persistenceUser.username,
            passwordHash: persistenceUser.passwordHash
        )
    }
}
