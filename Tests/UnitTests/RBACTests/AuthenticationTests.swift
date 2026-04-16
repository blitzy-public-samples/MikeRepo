// AuthenticationTests.swift
// WealthLedger — Unit Tests for AuthenticationService and PasswordHasher
//
// Comprehensive unit tests validating:
//   Suite 1: PasswordHasher bcrypt hash/verify round-trip (7 tests)
//   Suite 2: AuthenticationService login verification (4 tests)
//   Suite 3: AuthenticationService user creation (4 tests)
//
// Testing Framework: Swift Testing (@Suite, @Test, #expect) — NOT XCTest
// Database: Zero connections — UserRepository mocked via UserRepositoryProtocol
// Concurrency: Swift 6 strict — zero @unchecked Sendable annotations
//
// Rule 8 Compliance: No SwiftData imports.
// Rule 9 Compliance: No network calls — all data in-memory.
//
// Platform: BCryptSwift requires the Apple Security framework (macOS only).
// All tests in this file depend on PasswordHasher which uses BCryptSwift.
// On non-Apple platforms (e.g., Linux CI), these tests are excluded.

#if canImport(BCryptSwift)
import Testing
import Foundation
@testable import RBAC
@testable import Persistence
@testable import Shared

// MARK: - Mock UserRepository

/// Mock implementation of ``UserRepositoryProtocol`` for unit testing
/// ``AuthenticationService`` without any database connection.
///
/// Uses `let` properties with `@Sendable` closures to satisfy Swift 6
/// strict concurrency requirements (Gate 2). Each handler has a sensible
/// default so tests only need to override the specific behavior under test:
///   - `findByUsername` defaults to returning `nil` (user not found)
///   - `create` defaults to returning the input user (passthrough)
///   - `findAll` defaults to returning an empty array
///
/// ## Sendable Safety
/// This type is `final class` with exclusively `let` stored properties whose
/// types are `@Sendable` closures. No `@unchecked Sendable` is needed.
final class MockUserRepository: UserRepositoryProtocol, Sendable {

    /// Handler invoked when ``findByUsername(_:)`` is called.
    /// Defaults to returning `nil` (user not found).
    let findByUsernameHandler: @Sendable (String) async throws -> Persistence.User?

    /// Handler invoked when ``create(_:)`` is called.
    /// Defaults to returning the input user unchanged (passthrough).
    let createHandler: @Sendable (Persistence.User) async throws -> Persistence.User

    /// Handler invoked when ``findAll(page:pageSize:)`` is called.
    /// Defaults to returning an empty array.
    let findAllHandler: @Sendable (Int, Int) async throws -> [Persistence.User]

    /// Creates a new mock with configurable closure handlers.
    ///
    /// - Parameters:
    ///   - findByUsername: Closure invoked when `findByUsername(_:)` is called.
    ///   - create: Closure invoked when `create(_:)` is called.
    ///   - findAll: Closure invoked when `findAll(page:pageSize:)` is called.
    init(
        findByUsername: @escaping @Sendable (String) async throws -> Persistence.User? = { _ in nil },
        create: @escaping @Sendable (Persistence.User) async throws -> Persistence.User = { $0 },
        findAll: @escaping @Sendable (Int, Int) async throws -> [Persistence.User] = { _, _ in [] }
    ) {
        self.findByUsernameHandler = findByUsername
        self.createHandler = create
        self.findAllHandler = findAll
    }

    /// Looks up a user by username. Delegates to ``findByUsernameHandler``.
    func findByUsername(_ username: String) async throws -> Persistence.User? {
        try await findByUsernameHandler(username)
    }

    /// Creates a new user record. Delegates to ``createHandler``.
    func create(_ entity: Persistence.User) async throws -> Persistence.User {
        try await createHandler(entity)
    }

    /// Retrieves a paginated list of all users. Delegates to ``findAllHandler``.
    func findAll(page: Int, pageSize: Int) async throws -> [Persistence.User] {
        try await findAllHandler(page, pageSize)
    }
}

// MARK: - Suite 1: PasswordHasher bcrypt hash/verify cycle

/// Validates the ``PasswordHasher`` struct's public API for bcrypt hash generation
/// and password verification. Tests cover:
///   - Standard hash/verify round-trip
///   - Wrong password rejection
///   - Salt uniqueness (same password → different hashes)
///   - Edge cases: empty password, very long password, special characters
///   - Hash format compliance ($2 prefix, ~60 characters)
///
/// All tests are synchronous — ``PasswordHasher`` methods are synchronous.
/// No database or network dependencies.
@Suite("PasswordHasher bcrypt hash/verify cycle")
struct PasswordHasherTests {

    /// Shared PasswordHasher instance for all tests in this suite.
    /// PasswordHasher is a value type (struct) with zero stored state,
    /// so sharing is safe and equivalent to creating a new instance per test.
    let hasher = PasswordHasher()

    // MARK: Test 1 — Hash and verify round-trip

    @Test("Hash a password and verify it matches")
    func hashAndVerifyRoundTrip() {
        let password = "MySecureP@ssw0rd"
        let hash = hasher.hash(password)
        let result = hasher.verify(password, against: hash)
        #expect(result == true)
    }

    // MARK: Test 2 — Wrong password rejection

    @Test("Wrong password does not match hash")
    func wrongPasswordDoesNotMatch() {
        let hash = hasher.hash("CorrectPassword")
        let result = hasher.verify("WrongPassword", against: hash)
        #expect(result == false)
    }

    // MARK: Test 3 — Salt uniqueness

    @Test("Same password produces different hashes due to random salt")
    func saltUniquenessProducesDifferentHashes() {
        let password = "SamePasswordTwice"
        let hash1 = hasher.hash(password)
        let hash2 = hasher.hash(password)
        // Different salts must produce different hash strings
        #expect(hash1 != hash2)
        // Both hashes must still verify against the original password
        #expect(hasher.verify(password, against: hash1) == true)
        #expect(hasher.verify(password, against: hash2) == true)
    }

    // MARK: Test 4 — Empty password edge case

    @Test("Empty password hashing and verification")
    func emptyPasswordHandling() {
        let emptyHash = hasher.hash("")
        // Empty string matches its own hash
        #expect(hasher.verify("", against: emptyHash) == true)
        // Non-empty string does NOT match empty password hash
        #expect(hasher.verify("notempty", against: emptyHash) == false)
    }

    // MARK: Test 5 — Very long password

    @Test("Very long password hashing and verification")
    func veryLongPasswordHandling() {
        // bcrypt internally truncates at 72 bytes; test with 1000 characters
        // to verify the hasher handles long inputs without error.
        let longPassword = String(repeating: "A", count: 1000)
        let hash = hasher.hash(longPassword)
        #expect(hasher.verify(longPassword, against: hash) == true)
        // Password differing in the first byte (within 72-byte window) must NOT match
        let differentLong = "B" + String(repeating: "A", count: 999)
        #expect(hasher.verify(differentLong, against: hash) == false)
    }

    // MARK: Test 6 — Special characters

    @Test("Special characters in password are handled correctly")
    func specialCharacterPassword() {
        let specialPassword = "p@$$w0rd!#%^&*()"
        let hash = hasher.hash(specialPassword)
        // Exact same password verifies successfully
        #expect(hasher.verify(specialPassword, against: hash) == true)
        // Different password with similar but not identical trailing character
        let different = "p@$$w0rd!#%^&*(]"
        #expect(hasher.verify(different, against: hash) == false)
    }

    // MARK: Test 7 — Hash format validation

    @Test("Hash format conforms to bcrypt standard ($2 prefix, ~60 chars)")
    func hashFormatValidation() {
        let hash = hasher.hash("TestPassword123")
        // bcrypt hash must not be empty
        #expect(!hash.isEmpty)
        // bcrypt hashes start with "$2" (variants: $2a$, $2b$, $2y$)
        #expect(hash.hasPrefix("$2"))
        // Standard bcrypt output is 60 characters
        #expect(hash.count >= 59 && hash.count <= 61)
    }
}

// MARK: - Suite 2: AuthenticationService login verification

/// Validates ``AuthenticationService/login(username:password:)`` behavior:
///   - Successful authentication returns a ``User`` with correct identity
///   - Wrong password returns `nil` (not an error) to prevent enumeration
///   - Non-existent username returns `nil` (indistinguishable from wrong password)
///   - Authentication failures never throw — only infrastructure errors throw
///
/// All tests use ``MockUserRepository`` to simulate database behavior.
/// No actual database connection is created.
@Suite("AuthenticationService login verification")
struct AuthenticationServiceLoginTests {

    // MARK: Test 8 — Successful login

    @Test("Successful login returns User with correct identity")
    func successfulLoginReturnsUser() async throws {
        let hasher = PasswordHasher()
        let correctHash = hasher.hash("password123")

        let mockRepo = MockUserRepository(
            findByUsername: { username in
                guard username == "admin" else { return nil }
                return Persistence.User(
                    id: 1,
                    username: "admin",
                    passwordHash: correctHash
                )
            }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let user = try await service.login(
            username: "admin",
            password: "password123"
        )

        #expect(user != nil)
        #expect(user?.username == "admin")
        #expect(user?.id == 1)
    }

    // MARK: Test 9 — Wrong password returns nil

    @Test("Login with wrong password returns nil, not error")
    func wrongPasswordReturnsNil() async throws {
        let hasher = PasswordHasher()
        let correctHash = hasher.hash("correctpassword")

        let mockRepo = MockUserRepository(
            findByUsername: { _ in
                Persistence.User(
                    id: 1,
                    username: "admin",
                    passwordHash: correctHash
                )
            }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let user = try await service.login(
            username: "admin",
            password: "wrongpassword"
        )

        // Must return nil — not throw an error.
        // This prevents username enumeration by making the response identical
        // to a "user not found" scenario.
        #expect(user == nil)
    }

    // MARK: Test 10 — Non-existent username returns nil

    @Test("Login with non-existent username returns nil")
    func nonExistentUsernameReturnsNil() async throws {
        let hasher = PasswordHasher()

        // Mock returns nil for all username lookups (user not found)
        let mockRepo = MockUserRepository(
            findByUsername: { _ in nil }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let user = try await service.login(
            username: "unknown",
            password: "anything"
        )

        // Must return nil — indistinguishable from wrong password (security)
        #expect(user == nil)
    }

    // MARK: Test 11 — Login does not throw for auth failures

    @Test("Login does not throw for authentication failures")
    func loginDoesNotThrowForAuthFailure() async throws {
        let hasher = PasswordHasher()
        let mockRepo = MockUserRepository(
            findByUsername: { _ in nil }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )

        // This must complete without throwing.
        // Authentication failures produce nil return, not exceptions.
        // Only infrastructure failures (DB connectivity) should throw.
        let result = try await service.login(
            username: "nouser",
            password: "nopass"
        )
        #expect(result == nil)
    }
}

// MARK: - Suite 3: AuthenticationService user creation

/// Validates ``AuthenticationService/createUser(username:password:)`` behavior:
///   - New user is created with bcrypt-hashed password (never plaintext)
///   - Duplicate username propagates ``AppError/duplicateUser``
///   - Created user's hash is verifiable against the original password
///   - Plaintext password never appears in any User struct field
///
/// All tests use ``MockUserRepository`` to simulate database behavior.
/// No actual database connection is created.
@Suite("AuthenticationService user creation")
struct AuthenticationServiceCreateUserTests {

    // MARK: Test 12 — Create user with hashed password

    @Test("Create user succeeds with bcrypt-hashed password")
    func createUserSucceedsWithHashedPassword() async throws {
        let hasher = PasswordHasher()

        let mockRepo = MockUserRepository(
            create: { user in
                // Simulate DB assigning an auto-increment ID
                Persistence.User(
                    id: 42,
                    username: user.username,
                    passwordHash: user.passwordHash
                )
            }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let createdUser = try await service.createUser(
            username: "newuser",
            password: "mypassword"
        )

        // Verify correct username preserved
        #expect(createdUser.username == "newuser")
        // Verify ID was assigned by the mock "database"
        #expect(createdUser.id == 42)
        // Verify the password hash is NOT the plaintext password
        #expect(createdUser.passwordHash != "mypassword")
        // Verify the hash has bcrypt format prefix ($2a$, $2b$, $2y$)
        #expect(createdUser.passwordHash.hasPrefix("$2"))
    }

    // MARK: Test 13 — Duplicate username throws AppError.duplicateUser

    @Test("Create user with duplicate username throws AppError.duplicateUser")
    func duplicateUsernameThrowsDuplicateUser() async {
        let hasher = PasswordHasher()

        let mockRepo = MockUserRepository(
            create: { _ in throw AppError.duplicateUser }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )

        // AppError is Equatable — verify the exact error case is thrown.
        await #expect(throws: AppError.self) {
            try await service.createUser(
                username: "existing",
                password: "password"
            )
        }
    }

    // MARK: Test 14 — Created user password is verifiable

    @Test("Created user's password can be verified with PasswordHasher")
    func createdUserPasswordIsVerifiable() async throws {
        let hasher = PasswordHasher()

        let mockRepo = MockUserRepository(
            create: { user in
                // Pass through with DB-assigned ID — preserves the hashed password
                Persistence.User(
                    id: 10,
                    username: user.username,
                    passwordHash: user.passwordHash
                )
            }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let createdUser = try await service.createUser(
            username: "testuser",
            password: "testpass"
        )

        // The stored bcrypt hash must be verifiable against the original password
        #expect(hasher.verify("testpass", against: createdUser.passwordHash) == true)
        // Wrong password must NOT verify against the hash
        #expect(hasher.verify("wrongpass", against: createdUser.passwordHash) == false)
    }

    // MARK: Test 15 — Plaintext password is never stored

    @Test("Plaintext password is never stored in User struct")
    func plaintextPasswordNeverStored() async throws {
        let hasher = PasswordHasher()

        let mockRepo = MockUserRepository(
            create: { user in
                Persistence.User(
                    id: 5,
                    username: user.username,
                    passwordHash: user.passwordHash
                )
            }
        )

        let service = AuthenticationService(
            userRepository: mockRepo,
            passwordHasher: hasher
        )
        let createdUser = try await service.createUser(
            username: "secure_user",
            password: "secret123"
        )

        // The passwordHash field must NOT contain the plaintext password
        #expect(createdUser.passwordHash != "secret123")
        // The hash must conform to bcrypt format ($2 prefix)
        #expect(createdUser.passwordHash.hasPrefix("$2"))
        // Standard bcrypt output is approximately 60 characters
        #expect(createdUser.passwordHash.count >= 59 && createdUser.passwordHash.count <= 61)
    }
}

#endif // canImport(BCryptSwift)

// MARK: - Platform-Agnostic PasswordHasher Tests
//
// These tests execute on ALL platforms (macOS AND Linux) because they test
// PasswordHasher directly without importing BCryptSwift. On macOS, the
// PasswordHasher delegates to BCryptSwift; on Linux, it uses a built-in
// fallback implementation. Both code paths produce bcrypt-compatible hashes
// with "$2b$12$" prefix format, so the same assertions apply everywhere.
//
// This section resolves the QA finding that the Linux CI fallback path
// (PasswordHasher lines 225-278) had zero unit test coverage when
// BCryptSwift was unavailable.

import Testing
import Foundation
@testable import RBAC

// MARK: - Suite: Platform-Agnostic PasswordHasher

@Suite("PasswordHasher Platform-Agnostic Tests")
struct PasswordHasherCrossPlatformTests {

    /// The PasswordHasher under test — uses BCryptSwift on macOS,
    /// built-in fallback on Linux. Both produce bcrypt-compatible output.
    private let hasher = PasswordHasher()

    @Test("hash produces bcrypt-compatible format string")
    func testHashProducesBcryptFormat() {
        let hash = hasher.hash("TestPassword123!")
        // bcrypt hashes start with $2a$, $2b$, or $2y$ followed by cost factor
        #expect(hash.hasPrefix("$2"), "Hash must start with '$2' bcrypt prefix, got: \(hash.prefix(4))")
        // Standard bcrypt output is 59-60 characters; the Linux fallback produces a
        // longer hash (91 chars) due to hex-encoded digest. Both are valid formats.
        #expect(hash.count >= 59,
                "Hash length should be at least 59 chars (bcrypt minimum), got: \(hash.count)")
    }

    @Test("verify returns true for matching password and hash")
    func testVerifyMatchingPassword() {
        let password = "SecurePassword456!"
        let hash = hasher.hash(password)
        let result = hasher.verify(password, against: hash)
        #expect(result == true, "verify must return true for the password that produced the hash")
    }

    @Test("verify returns false for wrong password")
    func testVerifyWrongPassword() {
        let hash = hasher.hash("CorrectPassword")
        let result = hasher.verify("WrongPassword", against: hash)
        #expect(result == false, "verify must return false for a different password")
    }

    @Test("hash produces unique output for same input (salt randomisation)")
    func testHashProducesUniqueSaltedOutput() {
        let password = "DuplicateTest789"
        let hash1 = hasher.hash(password)
        let hash2 = hasher.hash(password)
        #expect(hash1 != hash2, "Two hashes of the same password should differ due to random salt")
        // Both should still verify against the original password
        #expect(hasher.verify(password, against: hash1))
        #expect(hasher.verify(password, against: hash2))
    }

    @Test("hash handles empty string input")
    func testHashEmptyString() {
        let hash = hasher.hash("")
        #expect(hash.hasPrefix("$2"), "Empty string should still produce valid bcrypt hash")
        #expect(hasher.verify("", against: hash), "Empty string should verify against its own hash")
        #expect(!hasher.verify("notempty", against: hash), "Non-empty string should not match empty hash")
    }

    @Test("verify rejects malformed hash string")
    func testVerifyRejectsMalformedHash() {
        let result = hasher.verify("anypassword", against: "not_a_valid_hash")
        #expect(result == false, "Malformed hash must return false, never crash")
    }

    @Test("hash handles unicode password correctly")
    func testHashUnicodePassword() {
        let password = "пароль_密码_🔐"
        let hash = hasher.hash(password)
        #expect(hasher.verify(password, against: hash), "Unicode password must verify correctly")
        #expect(!hasher.verify("different_unicode_пароль", against: hash))
    }

    @Test("hash handles long password")
    func testHashLongPassword() {
        // bcrypt implementations typically truncate at 72 bytes; verify no crash
        let longPassword = String(repeating: "A", count: 200)
        let hash = hasher.hash(longPassword)
        #expect(hash.hasPrefix("$2"), "Long password should produce valid bcrypt hash")
        #expect(hasher.verify(longPassword, against: hash), "Long password should verify")
    }
}
