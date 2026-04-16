#if canImport(SwiftUI)
// EntitlementFormView.swift
// WealthLedger — UILayer Module
//
// Reusable SwiftUI form component for assigning READ/CREATE/MODIFY/DELETE (RCMD)
// entitlement permissions per user-group pair. Used by AdminView in the
// entitlement assignment section.
//
// The four permission toggles map directly to the Entitlement model's boolean
// properties (canRead, canCreate, canModify, canDelete) from the RBAC module.
// The username and groupName display fields correspond to the User.username and
// AccountGroup.groupName properties from their respective modules.
//
// Rule 4 (Entitlement Enforcement): This form allows admins to assign or modify
// the four permission flags for a specific user-group pair. The parent view
// (AdminView) owns the state and submits changes via EntitlementService.
//
// Rule 8 (MySQLKit-Only Persistence): No SwiftData, MySQLKit, or Persistence
// module imports. Views interact with services only.
//
// Swift 6 Strict Concurrency (Gate 2): Zero @unchecked Sendable annotations,
// zero warning suppressions. SwiftUI View conformance provides @MainActor
// isolation. @Binding properties are @MainActor-isolated and safe for SwiftUI.

import SwiftUI
import RBAC
import AccountManagement

// MARK: - EntitlementFormView

/// Reusable permission toggle form for assigning READ/CREATE/MODIFY/DELETE
/// entitlements per user-group pair.
///
/// Displays four checkbox toggles — one for each permission flag — and shows
/// the current permission state. Allows admins to toggle individual permissions.
/// The parent view (`AdminView`) owns the state via `@State` properties and
/// passes them as `@Binding` to this form.
///
/// Used by `AdminView` in the entitlement assignment section.
///
/// The four permission flags correspond to `Entitlement` model properties:
/// - `canRead` → READ toggle
/// - `canCreate` → CREATE toggle
/// - `canModify` → MODIFY toggle
/// - `canDelete` → DELETE toggle
///
/// ## Usage
/// ```swift
/// @State private var readPerm = false
/// @State private var createPerm = false
/// @State private var modifyPerm = false
/// @State private var deletePerm = false
///
/// EntitlementFormView(
///     canRead: $readPerm,
///     canCreate: $createPerm,
///     canModify: $modifyPerm,
///     canDelete: $deletePerm,
///     username: "admin_user",
///     groupName: "US Equity Funds"
/// )
/// ```
///
/// ## Design Decisions
/// - Individual `@Binding Bool` parameters (not a whole `Entitlement` binding)
///   because the parent view constructs the `Entitlement` from these flags plus
///   additional context (userId, accountGroupId).
/// - `username` and `groupName` are immutable display-only context strings (`let`).
/// - Toggle style is `.checkbox` — native macOS checkbox style appropriate for
///   permission flag assignment.
///
/// ## Sendable Safety
/// - `struct` conforming to `View` — `@MainActor`-isolated in Swift 6.
/// - `@Binding` properties are `@MainActor`-isolated — safe within SwiftUI.
/// - `username` and `groupName` are immutable `String` values — `Sendable`.
/// - No async operations, no task creation.
/// - Zero `@unchecked Sendable` annotations.
public struct EntitlementFormView: View {

    // MARK: - Permission Bindings

    /// Whether the user has READ permission for the account group.
    ///
    /// Maps to `Entitlement.canRead`. When `true`, the user is permitted to view
    /// accounts and related data within the associated account group. When `false`,
    /// all queries for that group return an empty result set for the user (Rule 4).
    @Binding public var canRead: Bool

    /// Whether the user has CREATE permission for the account group.
    ///
    /// Maps to `Entitlement.canCreate`. When `true`, the user is permitted to create
    /// new accounts, transactions, and other records within the associated group.
    @Binding public var canCreate: Bool

    /// Whether the user has MODIFY permission for the account group.
    ///
    /// Maps to `Entitlement.canModify`. When `true`, the user is permitted to update
    /// existing accounts and records within the associated group (excluding
    /// transaction immutability per Rule 2).
    @Binding public var canModify: Bool

    /// Whether the user has DELETE permission for the account group.
    ///
    /// Maps to `Entitlement.canDelete`. When `true`, the user is permitted to remove
    /// records (where allowed by business rules) within the associated group.
    @Binding public var canDelete: Bool

    // MARK: - Display Context

    /// The username being assigned permissions (display-only).
    ///
    /// Corresponds to `User.username` from the RBAC module. Shown in the form
    /// header to provide context for which user the permissions apply to.
    public let username: String

    /// The account group name being assigned permissions (display-only).
    ///
    /// Corresponds to `AccountGroup.groupName` from the AccountManagement module.
    /// Shown in the form header to provide context for which group the permissions
    /// apply to.
    public let groupName: String

    // MARK: - Initializer

    /// Creates a new `EntitlementFormView` with bindings to permission flags and
    /// display context for the user-group pair.
    ///
    /// - Parameters:
    ///   - canRead: Binding to the READ permission flag.
    ///   - canCreate: Binding to the CREATE permission flag.
    ///   - canModify: Binding to the MODIFY permission flag.
    ///   - canDelete: Binding to the DELETE permission flag.
    ///   - username: The username being assigned permissions (display-only).
    ///   - groupName: The account group name being assigned permissions (display-only).
    public init(
        canRead: Binding<Bool>,
        canCreate: Binding<Bool>,
        canModify: Binding<Bool>,
        canDelete: Binding<Bool>,
        username: String,
        groupName: String
    ) {
        self._canRead = canRead
        self._canCreate = canCreate
        self._canModify = canModify
        self._canDelete = canDelete
        self.username = username
        self.groupName = groupName
    }

    // MARK: - Body

    /// The view body renders a vertical layout with a header showing the
    /// user-group pair context, followed by a GroupBox containing four
    /// checkbox toggles for READ, CREATE, MODIFY, and DELETE permissions.
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: user × group context
            Text("\(username) \u{2192} \(groupName)")
                .font(.headline)
                .accessibilityLabel(
                    "Permissions for \(username) on \(groupName)"
                )

            // Permission toggles wrapped in a labeled GroupBox
            GroupBox(label: Text("Permissions").font(.subheadline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("READ", isOn: $canRead)
                        .accessibilityHint(
                            "Enables viewing accounts in this group"
                        )

                    Toggle("CREATE", isOn: $canCreate)
                        .accessibilityHint(
                            "Enables creating records in this group"
                        )

                    Toggle("MODIFY", isOn: $canModify)
                        .accessibilityHint(
                            "Enables modifying records in this group"
                        )

                    Toggle("DELETE", isOn: $canDelete)
                        .accessibilityHint(
                            "Enables deleting records in this group"
                        )
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 4)
            }
        }
        .padding(8)
    }
}
#endif
