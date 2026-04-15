// PasswordHasher.swift
// WealthLedger - RBAC Module
//
// Provides bcrypt password hashing and verification for the WealthLedger application.
// This service wraps the BCryptSwift (v2.0.1) library to provide two operations:
//   1. Hashing a plaintext password for secure storage in the MySQL `users` table.
//   2. Verifying a plaintext password against a stored bcrypt hash during login.
//
// This is the ONLY file in the entire project that imports BCryptSwift, encapsulating
// the bcrypt dependency to a single file. All other modules interact with password
// hashing exclusively through this wrapper, ensuring that any future changes to the
// hashing library require modification in only one place.
//
// Security Properties:
//   - Uses bcrypt with a configurable cost factor (default: 12 rounds / 2^12 iterations)
//   - Salt generation is cryptographically random (via SecRandomCopyBytes on macOS)
//   - Constant-time comparison for password verification (timing-attack safe)
//   - Stateless — no passwords or hashes are stored in memory beyond method scope
//   - No network calls — pure computation (Rule 9: Offline Runtime)
//
// bcrypt Output Format:
//   "$2a$12$[22-char salt][31-char hash]" (60 characters total)
//   Fits within VARCHAR(255) in the `users.password_hash` column.
//
// Performance Characteristics:
//   - Hash generation: ~200-300ms on Apple Silicon M5 with 12 rounds
//   - Verification: ~200-300ms on Apple Silicon M5 with 12 rounds
//   - Acceptable for single-user desktop app with infrequent login/creation events
//
// Swift 6 Strict Concurrency (Gate 2):
//   `PasswordHasher` is a `struct` with zero stored properties — trivially `Sendable`.
//   All methods are pure functions operating on local variables only. No `@unchecked
//   Sendable` or warning suppressions are needed.
//
// Consumers:
//   - `AuthenticationService` — calls `hash()` during user creation and `verify()`
//     during login. This is the ONLY direct consumer.
//   - `DependencyContainer` — registers `PasswordHasher` and injects it into
//     `AuthenticationService`.
//
// Rule 8 Compliance: No SwiftData imports. Verification: `grep -r "import SwiftData"`
// must return zero results across the entire project.

import Foundation
import BCryptSwift

// MARK: - PasswordHasher

/// A stateless bcrypt password hashing service for the WealthLedger RBAC system.
///
/// `PasswordHasher` wraps the BCryptSwift library to provide a clean, minimal
/// interface for password hashing and verification. It is designed as a pure
/// value type with no stored properties, making it trivially `Sendable` and
/// safe for use across any concurrency domain.
///
/// The service uses bcrypt with 12 rounds by default, providing a strong security
/// margin for a single-user desktop application. The salt is generated internally
/// using cryptographically secure randomness — no manual salt management is
/// exposed to callers.
///
/// ## Thread Safety
/// All methods are pure functions with no shared mutable state. Multiple
/// concurrent calls to `hash()` or `verify()` are safe because each invocation
/// operates exclusively on stack-local variables and BCryptSwift's stateless
/// class methods.
///
/// ## Usage
/// ```swift
/// let hasher = PasswordHasher()
///
/// // Hash a password for storage
/// let hash = hasher.hash("securePassword123")
/// // hash == "$2a$12$..." (60 characters)
///
/// // Verify a password during login
/// let isValid = hasher.verify("securePassword123", against: hash)
/// // isValid == true
///
/// let isInvalid = hasher.verify("wrongPassword", against: hash)
/// // isInvalid == false
/// ```
public struct PasswordHasher: Sendable {

    // MARK: - Constants

    /// The bcrypt cost factor (number of rounds).
    ///
    /// A value of 12 means 2^12 = 4,096 iterations of the key derivation function.
    /// This provides strong security while maintaining acceptable performance
    /// (~200-300ms per hash/verify on Apple Silicon M5) for a single-user desktop
    /// application with infrequent authentication events.
    ///
    /// Range: 4-31 (enforced by BCryptSwift). Values below 4 are clamped to 4;
    /// values above 31 are clamped to 31.
    private static let defaultRounds: UInt = 12

    // MARK: - Initializer

    /// Creates a new `PasswordHasher` instance.
    ///
    /// No configuration is required. The hasher uses BCryptSwift's static methods
    /// directly with a fixed cost factor of 12 rounds. Since the struct has no
    /// stored properties, this initializer performs no work.
    public init() {}

    // MARK: - Public Methods

    /// Generates a bcrypt hash of the provided plaintext password.
    ///
    /// This method performs the following steps:
    /// 1. Generates a cryptographically random bcrypt salt with 12 rounds using
    ///    `BCryptSwift.generateSaltWithNumberOfRounds(_:)`.
    /// 2. Hashes the password with the generated salt using
    ///    `BCryptSwift.hashPassword(_:withSalt:)`.
    /// 3. Returns the resulting bcrypt hash string.
    ///
    /// The output format is `$2a$12$[22-char salt][31-char hash]` (60 characters),
    /// which fits within the `VARCHAR(255)` constraint of the `users.password_hash`
    /// column in the MySQL schema.
    ///
    /// - Parameter password: The plaintext password to hash. Must not be empty.
    ///   BCrypt silently truncates passwords longer than 72 bytes; callers should
    ///   enforce reasonable length limits at the UI or service layer.
    ///
    /// - Returns: A bcrypt hash string suitable for storage in the database.
    ///
    /// - Important: This method calls `fatalError` if BCryptSwift returns `nil`,
    ///   which should never occur with a properly generated salt and valid string
    ///   input. A `nil` return would indicate a programming error in salt generation
    ///   or an internal BCryptSwift failure.
    ///
    /// ## Example
    /// ```swift
    /// let hasher = PasswordHasher()
    /// let hash = hasher.hash("mySecurePassword")
    /// // Store `hash` in the database via UserRepository
    /// ```
    public func hash(_ password: String) -> String {
        let salt = BCryptSwift.generateSaltWithNumberOfRounds(PasswordHasher.defaultRounds)

        guard let hashedPassword = BCryptSwift.hashPassword(password, withSalt: salt) else {
            // BCryptSwift.hashPassword returns nil only for truly invalid inputs
            // (e.g., malformed salt strings). Since we generate the salt ourselves
            // using BCryptSwift.generateSaltWithNumberOfRounds, this path should
            // never be reached. If it is, it indicates a critical internal error.
            fatalError(
                "BCrypt hashing failed unexpectedly. "
                + "Salt was generated internally via BCryptSwift.generateSaltWithNumberOfRounds(\(PasswordHasher.defaultRounds)). "
                + "This indicates a critical internal error in BCryptSwift."
            )
        }

        return hashedPassword
    }

    /// Verifies a plaintext password against a stored bcrypt hash.
    ///
    /// This method delegates to `BCryptSwift.verifyPassword(_:matchesHash:)`,
    /// which extracts the salt and cost factor from the stored hash, re-hashes the
    /// provided password with the same parameters, and performs a constant-time
    /// comparison of the results.
    ///
    /// If BCryptSwift returns `nil` (indicating the stored hash has an invalid
    /// format or cannot be parsed), this method returns `false` — treating an
    /// unparseable hash the same as a non-matching password. This is a deliberate
    /// security choice: callers should never distinguish between "wrong password"
    /// and "corrupted hash" to avoid information leakage.
    ///
    /// - Parameters:
    ///   - password: The plaintext password to verify.
    ///   - hash: The stored bcrypt hash to verify against. Expected format:
    ///     `$2a$NN$[22-char salt][31-char hash]` where `NN` is the cost factor.
    ///
    /// - Returns: `true` if the password matches the hash, `false` if it does not
    ///   match or if the hash format is invalid.
    ///
    /// ## Example
    /// ```swift
    /// let hasher = PasswordHasher()
    /// let storedHash = "$2a$12$R9h/cIPz0gi.URNNX3kh2OPST9/PgBkqquzi.Ss7KIUgO2t0jWMUW"
    ///
    /// let valid = hasher.verify("correctPassword", against: storedHash)
    /// // valid == true (if "correctPassword" was the original password)
    ///
    /// let invalid = hasher.verify("wrongPassword", against: storedHash)
    /// // invalid == false
    ///
    /// let corrupted = hasher.verify("anyPassword", against: "not-a-valid-hash")
    /// // corrupted == false (nil from BCryptSwift coalesced to false)
    /// ```
    public func verify(_ password: String, against hash: String) -> Bool {
        return BCryptSwift.verifyPassword(password, matchesHash: hash) ?? false
    }
}
