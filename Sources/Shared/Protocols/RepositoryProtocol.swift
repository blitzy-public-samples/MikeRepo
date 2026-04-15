import Foundation

// MARK: - RepositoryProtocol

/// A generic repository protocol defining consistent data access patterns
/// for all persistence layer repositories in WealthLedger.
///
/// All seven repository classes in the Persistence module conform to this protocol:
/// - ``AccountRepository``
/// - ``TransactionRepository``
/// - ``PositionRepository``
/// - ``UserRepository``
/// - ``EntitlementRepository``
/// - ``AccountGroupRepository``
/// - ``ReferenceDataRepository``
///
/// ## Pagination Enforcement (Rule 7 — Batch Memory Cap)
///
/// The ``findAll(page:pageSize:)`` method enforces the batch memory cap of
/// 1,000 records per operation. No query path is permitted to bypass pagination.
/// Callers should pass `AppConstants.defaultPagination` (1,000) as the `pageSize`
/// to respect Rule 7.
///
/// ## Transaction Immutability (Rule 2)
///
/// ``TransactionRepository`` must **not** perform actual deletions. Its ``delete(_:)``
/// implementation should throw an appropriate error (e.g., `AppError.operationNotPermitted`)
/// to enforce the append-only nature of the transactions table. Corrections use
/// offsetting entries referencing the original transaction ID via foreign key.
///
/// ## Concurrency Safety
///
/// This protocol conforms to `Sendable` and constrains both associated types to
/// `Sendable`, ensuring full compatibility with Swift 6 strict concurrency checking
/// (Gate 2). No `@unchecked Sendable` annotations or warning suppressions are used.
public protocol RepositoryProtocol: Sendable {

    /// The entity type managed by this repository.
    ///
    /// Constrained to `Sendable` for Swift 6 strict concurrency safety.
    /// Examples: `Account`, `User`, `Transaction`, `Position`, `Entitlement`,
    /// `AccountGroup`, `ReferenceData`.
    associatedtype Entity: Sendable

    /// The type used for the entity's primary key.
    ///
    /// Constrained to `Sendable` for Swift 6 strict concurrency safety.
    /// Typically `Int64` or `UInt64` matching MySQL `BIGINT UNSIGNED AUTO_INCREMENT`
    /// primary keys, though the protocol imposes no specific concrete type.
    associatedtype EntityID: Sendable

    // MARK: - Read Operations

    /// Retrieves a single entity by its primary key.
    ///
    /// Returns `nil` when no entity matches the given identifier — this is not
    /// treated as an error condition. All database communication is asynchronous
    /// via MySQLKit; network or query failures surface as thrown errors.
    ///
    /// - Parameter id: The primary key of the entity to find.
    /// - Returns: The matching entity, or `nil` if not found.
    /// - Throws: Database connection errors, query execution failures, or
    ///   other persistence-layer errors.
    func findById(_ id: EntityID) async throws -> Entity?

    /// Retrieves a paginated list of entities.
    ///
    /// This is the **mandatory** pagination mechanism enforcing Rule 7 (Batch Memory
    /// Cap). No UI operation may load more than 1,000 account records into memory
    /// simultaneously, and background jobs must paginate at 1,000 records or fewer
    /// per page.
    ///
    /// Callers should supply `AppConstants.defaultPagination` (1,000) as the
    /// `pageSize` argument unless a smaller page is explicitly required.
    ///
    /// - Parameters:
    ///   - page: The 1-based page number. Page 1 returns the first `pageSize` records,
    ///     page 2 returns the next `pageSize` records, and so on.
    ///   - pageSize: The maximum number of records per page. Should not exceed 1,000
    ///     per Rule 7 to enforce the batch memory cap.
    /// - Returns: An array of entities for the requested page. Returns an empty array
    ///   when the page is beyond the available data.
    /// - Throws: Database connection errors, query execution failures, or
    ///   other persistence-layer errors.
    func findAll(page: Int, pageSize: Int) async throws -> [Entity]

    // MARK: - Write Operations

    /// Creates a new entity in the data store.
    ///
    /// Inserts a new row into the corresponding MySQL table. The returned entity
    /// may differ from the input — for example, when the database assigns an
    /// auto-generated primary key (`BIGINT UNSIGNED AUTO_INCREMENT`).
    ///
    /// - Parameter entity: The entity to insert.
    /// - Returns: The created entity, potentially with an auto-generated identifier
    ///   populated.
    /// - Throws: Constraint violations (e.g., unique key, foreign key), connection
    ///   errors, or other persistence-layer errors.
    func create(_ entity: Entity) async throws -> Entity

    /// Deletes an entity by its primary key.
    ///
    /// Removes the corresponding row from the MySQL table.
    ///
    /// - Important: ``TransactionRepository`` must **not** perform actual deletions
    ///   per Rule 2 (Transaction Immutability). Its conforming implementation should
    ///   throw an error to enforce the append-only nature of the transactions table.
    ///   Corrections are performed exclusively through offsetting entries.
    ///
    /// - Parameter id: The primary key of the entity to delete.
    /// - Throws: Foreign key constraint violations, entity not found, operation not
    ///   permitted (for immutable tables), or other persistence-layer errors.
    func delete(_ id: EntityID) async throws
}
