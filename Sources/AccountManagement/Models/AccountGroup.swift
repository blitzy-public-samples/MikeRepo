// Sources/AccountManagement/Models/AccountGroup.swift
// WealthLedger — Account Group Data Model
//
// SPDX-License-Identifier: UNLICENSED

import Foundation

// MARK: - AccountGroup

/// Account group data model for organizing accounts into logical groupings.
///
/// Account groups are the fundamental unit of RBAC entitlement scoping (Rule 4).
/// Users are granted READ, CREATE, MODIFY, and DELETE permissions per account group
/// via the ``Entitlement`` model in the RBAC module. Each account belongs to exactly
/// one account group, referenced through the `accountGroupId` foreign key on the
/// ``Account`` model.
///
/// ## MySQL Column Mapping
///
/// | Swift Property   | MySQL Column   | MySQL Type                                     |
/// |------------------|----------------|------------------------------------------------|
/// | `id`             | `id`           | `BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY`   |
/// | `groupName`      | `group_name`   | `VARCHAR(255) NOT NULL`                        |
/// | `metadata`       | `metadata`     | `JSON DEFAULT NULL`                            |
/// | `createdAt`      | `created_at`   | `TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP` |
///
/// Maps to the MySQL `account_groups` table defined in migration
/// `Resources/Migrations/002_create_account_groups.sql`.
///
/// ## Sendable Safety
///
/// This struct is a value type with all stored properties being `Sendable`-conforming
/// immutable values (`UInt64`, `String`, `String?`, `Date`). Automatic `Sendable`
/// conformance is safe with zero need for `@unchecked Sendable`.
///
/// ## Usage Example
///
/// ```swift
/// let group = AccountGroup(
///     id: 1,
///     groupName: "US Equity Funds",
///     metadata: "{\"region\": \"US\", \"category\": \"equity\"}",
///     createdAt: Date()
/// )
/// ```
public struct AccountGroup: Sendable, Codable, Identifiable, Equatable {

    // MARK: - Properties

    /// Unique identifier for the account group.
    ///
    /// Maps to `id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY` in the
    /// `account_groups` MySQL table. Type `UInt64` aligns with MySQL
    /// `BIGINT UNSIGNED` to support the full unsigned 64-bit range.
    public let id: UInt64

    /// Human-readable name of the account group.
    ///
    /// Maps to `group_name VARCHAR(255) NOT NULL` in the `account_groups` table.
    /// Examples: "US Equity Funds", "European SMAs", "Hedge Fund Portfolio".
    /// Used in RBAC entitlement assignment UI and search filtering.
    public let groupName: String

    /// Optional JSON metadata for flexible group-level attributes.
    ///
    /// Maps to `metadata JSON DEFAULT NULL` in the `account_groups` table.
    /// Stored as an optional `String` in Swift; the MySQL column accepts
    /// JSON-formatted text. When `nil`, no metadata is associated with
    /// the group.
    public let metadata: String?

    /// Timestamp indicating when the account group was created.
    ///
    /// Maps to `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`
    /// in the `account_groups` table. Populated by MySQL on insert when
    /// not explicitly provided.
    public let createdAt: Date

    // MARK: - Initializer

    /// Creates a new `AccountGroup` instance with the specified properties.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the account group (MySQL `BIGINT UNSIGNED`).
    ///   - groupName: Human-readable name of the account group.
    ///   - metadata: Optional JSON string containing group metadata.
    ///   - createdAt: Timestamp of when the group was created.
    public init(
        id: UInt64,
        groupName: String,
        metadata: String?,
        createdAt: Date
    ) {
        self.id = id
        self.groupName = groupName
        self.metadata = metadata
        self.createdAt = createdAt
    }

    // MARK: - CodingKeys

    /// Coding keys mapping Swift camelCase property names to MySQL snake_case
    /// column names for `Codable` serialization and deserialization.
    enum CodingKeys: String, CodingKey {
        case id
        case groupName = "group_name"
        case metadata
        case createdAt = "created_at"
    }
}
