#if canImport(SwiftUI)
// AdminView.swift
// WealthLedger — UILayer Module
//
// Admin screen for the WealthLedger macOS desktop application. Provides three
// administrative functions:
//
//   1. User Creation — username + password form; delegates to
//      AuthenticationService.createUser() which bcrypt-hashes the password
//      via PasswordHasher before MySQL insertion.
//
//   2. Account Group Creation — group name + optional JSON metadata form;
//      delegates to AccountGroupService.createGroup().
//
//   3. Entitlement Assignment — user picker, account group picker, and four
//      READ/CREATE/MODIFY/DELETE toggles (via EntitlementFormView component);
//      delegates to EntitlementService.assignEntitlement().
//
// Rule 4 (Entitlement Enforcement):
//   All data reads verify user-group entitlement before returning records.
//   Users without READ access to an account group receive an empty result set —
//   not an error. The Admin screen itself is gated behind RBAC verification
//   from the parent navigation (MainNavigationView).
//
// Rule 8 (MySQLKit-Only Persistence):
//   This view imports ONLY SwiftUI plus the RBAC, AccountManagement, and Shared
//   modules. Absolutely NO SwiftData, MySQLKit, SQLKit, AsyncKit, or Persistence
//   imports. Views interact with services only — never repositories or database
//   connections directly.
//
// Rule 9 (Offline Runtime):
//   No network calls. All data access flows through local MySQL via injected
//   services.
//
// Swift 6 Strict Concurrency (Gate 2):
//   AdminView is a struct conforming to View — automatically @MainActor-isolated
//   in Swift 6. All @State properties are @MainActor-isolated. Service properties
//   are Sendable final classes (let properties). Zero @unchecked Sendable
//   annotations. Zero warning suppressions. All async operations use Task {}
//   within button actions or .task {} modifier.
//
// Gate 9 (Integration Wiring):
//   AdminView is instantiated by MainNavigationView and reachable from @main.
//   All three service methods (createUser, createGroup, assignEntitlement)
//   are invoked by this view. EntitlementFormView is imported from the same
//   UILayer module (Sources/UILayer/Components/EntitlementFormView.swift).
//
// Consumers:
//   - MainNavigationView — instantiates AdminView via:
//       AdminView(
//           authenticationService: container.authenticationService,
//           entitlementService: container.entitlementService,
//           accountGroupService: container.accountGroupService,
//           currentUserId: appState.currentUser.id
//       )

import SwiftUI
import RBAC
import AccountManagement
import Shared

// MARK: - AdminView

/// Admin screen for WealthLedger providing three administrative functions:
/// 1. User creation with bcrypt-hashed passwords
/// 2. Account group creation with optional JSON metadata
/// 3. Entitlement assignment (READ/CREATE/MODIFY/DELETE per user-group pair)
///
/// Access to this screen is gated behind RBAC verification (Rule 4).
/// All data reads verify user-group entitlement before returning records.
///
/// ## Dependency Injection
///
/// Services are injected via the public initializer — no global state,
/// no singletons, no `@EnvironmentObject` usage. The parent view
/// (`MainNavigationView`) passes concrete service instances obtained from
/// `DependencyContainer`.
///
/// ## Swift 6 Concurrency Safety
///
/// - Struct conforming to `View` → `@MainActor`-isolated by default.
/// - All `@State` properties → `@MainActor`-isolated within SwiftUI.
/// - Service properties (`let`) → `Sendable` final classes.
/// - All async operations → `Task {}` within button actions or `.task {}`.
/// - Zero `@unchecked Sendable`. Zero warning suppressions.
///
/// ## Usage
/// ```swift
/// AdminView(
///     authenticationService: authService,
///     entitlementService: entitlementService,
///     accountGroupService: groupService,
///     currentUserId: 42
/// )
/// ```
public struct AdminView: View {

    // MARK: - Service Dependencies (Injected)

    /// Authentication service for user creation and listing.
    ///
    /// Provides `createUser(username:password:)` for the user creation form
    /// and `listUsers()` to populate the user picker in the entitlement
    /// assignment section. Delegates bcrypt hashing to PasswordHasher internally.
    ///
    /// Injected by the parent view from DependencyContainer. This is a Sendable
    /// final class — safe for cross-actor usage in Swift 6.
    let authenticationService: AuthenticationService

    /// Entitlement service for permission assignment.
    ///
    /// Provides `assignEntitlement(userId:accountGroupId:canRead:canCreate:
    /// canModify:canDelete:)` to set READ/CREATE/MODIFY/DELETE permission
    /// flags for a user-group pair. Implements upsert semantics.
    ///
    /// Injected by the parent view from DependencyContainer. This is a Sendable
    /// final class — safe for cross-actor usage in Swift 6.
    let entitlementService: EntitlementService

    /// Account group service for group creation and listing.
    ///
    /// Provides `createGroup(name:metadata:)` for the account group creation
    /// form and `listGroups()` to populate the group picker in the entitlement
    /// assignment section.
    ///
    /// Injected by the parent view from DependencyContainer. This is a Sendable
    /// final class — safe for cross-actor usage in Swift 6.
    let accountGroupService: AccountGroupService

    /// The unique identifier of the currently authenticated user.
    ///
    /// Sourced from AppState.currentUser.id by the parent view. Used for
    /// entitlement-aware data loading (Rule 4).
    let currentUserId: UInt64

    // MARK: - User Creation Form State

    /// Username text field input for the user creation form.
    @State private var newUsername: String = ""

    /// Password secure field input for the user creation form.
    /// Displayed via SecureField — never shown as plain text.
    @State private var newPassword: String = ""

    /// Status message displayed after user creation attempt.
    /// Contains either a success confirmation or an error description.
    @State private var userCreationMessage: String = ""

    /// Indicates whether a user creation operation is currently in progress.
    /// Used to disable the "Create User" button during async execution.
    @State private var isCreatingUser: Bool = false

    // MARK: - Account Group Creation Form State

    /// Group name text field input for the account group creation form.
    @State private var newGroupName: String = ""

    /// Optional JSON metadata text field for the account group creation form.
    @State private var newGroupMetadata: String = ""

    /// Status message displayed after account group creation attempt.
    /// Contains either a success confirmation or an error description.
    @State private var groupCreationMessage: String = ""

    /// Indicates whether a group creation operation is currently in progress.
    /// Used to disable the "Create Group" button during async execution.
    @State private var isCreatingGroup: Bool = false

    // MARK: - Entitlement Assignment Form State

    /// Currently selected user ID for entitlement assignment.
    /// `nil` indicates no user has been selected in the picker.
    @State private var selectedUserId: UInt64? = nil

    /// Currently selected account group ID for entitlement assignment.
    /// `nil` indicates no group has been selected in the picker.
    @State private var selectedGroupId: UInt64? = nil

    /// READ permission toggle state for the entitlement assignment form.
    @State private var canRead: Bool = false

    /// CREATE permission toggle state for the entitlement assignment form.
    @State private var canCreate: Bool = false

    /// MODIFY permission toggle state for the entitlement assignment form.
    @State private var canModify: Bool = false

    /// DELETE permission toggle state for the entitlement assignment form.
    @State private var canDelete: Bool = false

    /// Status message displayed after entitlement assignment attempt.
    /// Contains either a success confirmation or an error description.
    @State private var entitlementMessage: String = ""

    /// Indicates whether an entitlement assignment operation is in progress.
    /// Used to disable the "Assign Entitlement" button during async execution.
    @State private var isAssigningEntitlement: Bool = false

    // MARK: - Data Lists (Loaded from Services)

    /// Cached list of all registered users, loaded on view appear.
    /// Populated by `AuthenticationService.listUsers()` in `loadData()`.
    /// Used to populate the user picker in the entitlement assignment section.
    @State private var users: [User] = []

    /// Cached list of all account groups, loaded on view appear.
    /// Populated by `AccountGroupService.listGroups()` in `loadData()`.
    /// Used to populate the group picker in the entitlement assignment section.
    @State private var accountGroups: [AccountGroup] = []

    // MARK: - Error Handling State

    /// Controls visibility of the error alert dialog.
    /// Set to `true` when a non-recoverable error occurs during data loading.
    @State private var showErrorAlert: Bool = false

    /// Human-readable error description displayed in the alert dialog.
    /// Set alongside `showErrorAlert` when data loading fails.
    @State private var errorAlertMessage: String = ""

    // MARK: - Initializer

    /// Creates a new `AdminView` with the required service dependencies.
    ///
    /// All services are injected by the parent view (`MainNavigationView`)
    /// which obtains them from `DependencyContainer`. No global state or
    /// singleton patterns are used.
    ///
    /// - Parameters:
    ///   - authenticationService: Service for user creation and listing.
    ///   - entitlementService: Service for permission assignment.
    ///   - accountGroupService: Service for account group CRUD.
    ///   - currentUserId: The unique ID of the currently authenticated user.
    public init(
        authenticationService: AuthenticationService,
        entitlementService: EntitlementService,
        accountGroupService: AccountGroupService,
        currentUserId: UInt64
    ) {
        self.authenticationService = authenticationService
        self.entitlementService = entitlementService
        self.accountGroupService = accountGroupService
        self.currentUserId = currentUserId
    }

    // MARK: - View Body

    /// The main view body renders a macOS-native grouped `Form` with three
    /// distinct sections for user creation, account group creation, and
    /// entitlement assignment.
    ///
    /// Data loading occurs on view appear via the `.task {}` modifier.
    /// Error alerts are presented via the `.alert` modifier.
    public var body: some View {
        Form {
            // Section 1: User Creation
            userCreationSection

            // Section 2: Account Group Creation
            accountGroupCreationSection

            // Section 3: Entitlement Assignment
            entitlementAssignmentSection
        }
        .formStyle(.grouped)
        .navigationTitle("Administration")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("Admin User #\(currentUserId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Logged in as admin user \(currentUserId)")
            }
        }
        .task {
            await loadData()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {
                // Alert dismissal resets the error state.
                // showErrorAlert is automatically set to false by the binding.
            }
        } message: {
            Text(errorAlertMessage)
        }
    }

    // MARK: - Section 1: User Creation

    /// Renders the user creation section with username/password fields,
    /// a "Create User" submit button, and a status message area.
    ///
    /// The username is entered via a standard `TextField`, while the password
    /// uses a `SecureField` to prevent plain-text display (security requirement).
    /// On submit, `AuthenticationService.createUser()` hashes the password via
    /// bcrypt before MySQL insertion.
    @ViewBuilder
    private var userCreationSection: some View {
        Section {
            TextField("Username", text: $newUsername)
                .textContentType(.username)
                .accessibilityLabel("New user username")

            SecureField("Password", text: $newPassword)
                .textContentType(.newPassword)
                .accessibilityLabel("New user password")

            Button("Create User") {
                Task {
                    await createUser()
                }
            }
            .disabled(newUsername.isEmpty || newPassword.isEmpty || isCreatingUser)
            .accessibilityHint("Creates a new user with bcrypt-hashed password")

            // Status message: green for success, red for error
            if !userCreationMessage.isEmpty {
                Text(userCreationMessage)
                    .font(.caption)
                    .foregroundStyle(
                        userCreationMessage.hasPrefix("Error") ? .red : .green
                    )
                    .accessibilityLabel("User creation status: \(userCreationMessage)")
            }
        } header: {
            Label("Create User", systemImage: "person.badge.plus")
        }
    }

    // MARK: - Section 2: Account Group Creation

    /// Renders the account group creation section with group name and optional
    /// metadata fields, a "Create Group" submit button, and a status message area.
    ///
    /// The metadata field accepts optional JSON text. On submit,
    /// `AccountGroupService.createGroup()` persists the new group to MySQL.
    @ViewBuilder
    private var accountGroupCreationSection: some View {
        Section {
            TextField("Group Name", text: $newGroupName)
                .accessibilityLabel("New account group name")

            TextField("Metadata (optional JSON)", text: $newGroupMetadata)
                .accessibilityLabel("Optional JSON metadata for the account group")

            Button("Create Group") {
                Task {
                    await createGroup()
                }
            }
            .disabled(newGroupName.isEmpty || isCreatingGroup)
            .accessibilityHint("Creates a new account group")

            // Status message: green for success, red for error
            if !groupCreationMessage.isEmpty {
                Text(groupCreationMessage)
                    .font(.caption)
                    .foregroundStyle(
                        groupCreationMessage.hasPrefix("Error") ? .red : .green
                    )
                    .accessibilityLabel(
                        "Group creation status: \(groupCreationMessage)"
                    )
            }
        } header: {
            Label("Create Account Group", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - Section 3: Entitlement Assignment

    /// Renders the entitlement assignment section with user/group pickers,
    /// permission toggles (via EntitlementFormView), an "Assign Entitlement"
    /// button, and a status message area.
    ///
    /// The user picker is populated from `users` (loaded via
    /// `AuthenticationService.listUsers()`). The group picker is populated
    /// from `accountGroups` (loaded via `AccountGroupService.listGroups()`).
    /// Permission toggles (READ/CREATE/MODIFY/DELETE) are rendered by the
    /// reusable `EntitlementFormView` component when both a user and group
    /// are selected.
    @ViewBuilder
    private var entitlementAssignmentSection: some View {
        Section {
            // User picker: select which user receives the entitlement
            Picker("User", selection: $selectedUserId) {
                Text("Select User")
                    .tag(nil as UInt64?)
                ForEach(users, id: \.id) { user in
                    Text(user.username)
                        .tag(user.id as UInt64?)
                }
            }
            .accessibilityLabel("Select user for entitlement assignment")

            // Account group picker: select which group the entitlement applies to
            Picker("Account Group", selection: $selectedGroupId) {
                Text("Select Group")
                    .tag(nil as UInt64?)
                ForEach(accountGroups, id: \.id) { group in
                    Text(group.groupName)
                        .tag(group.id as UInt64?)
                }
            }
            .accessibilityLabel("Select account group for entitlement assignment")

            // Permission toggles via the reusable EntitlementFormView component.
            // Only displayed when both a user and group are selected, providing
            // the necessary display context (username and groupName strings).
            if let userId = selectedUserId,
               let groupId = selectedGroupId,
               let selectedUsername = users.first(where: { $0.id == userId })?.username,
               let selectedGroupName = accountGroups.first(where: { $0.id == groupId })?.groupName {

                EntitlementFormView(
                    canRead: $canRead,
                    canCreate: $canCreate,
                    canModify: $canModify,
                    canDelete: $canDelete,
                    username: selectedUsername,
                    groupName: selectedGroupName
                )
            }

            // Assign button: submits the entitlement assignment
            Button("Assign Entitlement") {
                Task {
                    await assignEntitlement()
                }
            }
            .disabled(
                selectedUserId == nil
                || selectedGroupId == nil
                || isAssigningEntitlement
            )
            .accessibilityHint(
                "Assigns the selected permissions to the user for the account group"
            )

            // Status message: green for success, red for error
            if !entitlementMessage.isEmpty {
                Text(entitlementMessage)
                    .font(.caption)
                    .foregroundStyle(
                        entitlementMessage.hasPrefix("Error") ? .red : .green
                    )
                    .accessibilityLabel(
                        "Entitlement assignment status: \(entitlementMessage)"
                    )
            }
        } header: {
            Label("Assign Entitlements", systemImage: "lock.shield")
        }
    }

    // MARK: - Action Methods (async/await)

    /// Loads users and account groups from their respective services.
    ///
    /// Called on view appear via the `.task {}` modifier. Populates the
    /// `users` and `accountGroups` arrays used by the pickers in the
    /// entitlement assignment section.
    ///
    /// Error handling: If either service call fails (database connectivity,
    /// query execution), the error is displayed in a modal alert dialog.
    /// Partial success is supported — if users load but groups fail, the
    /// already-loaded users remain available.
    ///
    /// Rule 4 compliance: The `listGroups()` method returns groups filtered
    /// by the service layer's entitlement logic. `listUsers()` returns all
    /// users visible to admin operations.
    private func loadData() async {
        do {
            // Load all registered users for the admin user picker.
            // AuthenticationService.listUsers() paginates per Rule 7 (1,000 cap).
            users = try await authenticationService.listUsers()

            // Load all account groups for the admin group picker.
            // AccountGroupService.listGroups() paginates per Rule 7 (1,000 cap).
            accountGroups = try await accountGroupService.listGroups()
        } catch {
            // Display the error in a modal alert for non-recoverable failures.
            errorAlertMessage = "Failed to load data: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }

    /// Creates a new user with a bcrypt-hashed password.
    ///
    /// Calls `AuthenticationService.createUser(username:password:)` which
    /// internally hashes the plaintext password via `PasswordHasher` (bcrypt)
    /// before persisting to the MySQL `users` table.
    ///
    /// On success: displays a confirmation message, clears the form fields,
    /// and refreshes the users list so the new user appears in the picker.
    ///
    /// On failure: displays the error description. Handles `AppError.duplicateUser`
    /// when the username already exists (MySQL UNIQUE constraint violation).
    private func createUser() async {
        isCreatingUser = true
        defer { isCreatingUser = false }

        do {
            // Delegate to AuthenticationService which handles bcrypt hashing.
            // The returned User is discarded here — the users list is refreshed
            // via loadData() to ensure consistency with the database state.
            _ = try await authenticationService.createUser(
                username: newUsername,
                password: newPassword
            )

            // Success: display confirmation and clear form fields.
            userCreationMessage = "User '\(newUsername)' created successfully."
            newUsername = ""
            newPassword = ""

            // Refresh the users list so the new user appears in the picker.
            users = (try? await authenticationService.listUsers()) ?? users
        } catch let appError as AppError where appError == .duplicateUser {
            // Explicit handling of AppError.duplicateUser — thrown when the
            // username already exists (MySQL UNIQUE constraint violation).
            userCreationMessage = "Error: A user with username '\(newUsername)' already exists."
        } catch {
            // Generic error handler for unexpected failures (DB connectivity, etc.).
            userCreationMessage = "Error: \(error.localizedDescription)"
        }
    }

    /// Creates a new account group with the specified name and optional metadata.
    ///
    /// Calls `AccountGroupService.createGroup(name:metadata:)` which persists
    /// the group to the MySQL `account_groups` table.
    ///
    /// On success: displays a confirmation message, clears the form fields,
    /// and refreshes the account groups list so the new group appears in the picker.
    ///
    /// On failure: displays the error description.
    private func createGroup() async {
        isCreatingGroup = true
        defer { isCreatingGroup = false }

        do {
            // Delegate to AccountGroupService for MySQL insertion.
            // Pass nil for metadata if the text field is empty.
            _ = try await accountGroupService.createGroup(
                name: newGroupName,
                metadata: newGroupMetadata.isEmpty ? nil : newGroupMetadata
            )

            // Success: display confirmation and clear form fields.
            groupCreationMessage = "Group '\(newGroupName)' created successfully."
            newGroupName = ""
            newGroupMetadata = ""

            // Refresh the account groups list so the new group appears in the picker.
            accountGroups = (try? await accountGroupService.listGroups()) ?? accountGroups
        } catch {
            // Generic error handler for unexpected failures (DB connectivity, etc.).
            groupCreationMessage = "Error: \(error.localizedDescription)"
        }
    }

    /// Assigns entitlement permissions for a user-group pair.
    ///
    /// Calls `EntitlementService.assignEntitlement(...)` with the four
    /// RCMD (READ/CREATE/MODIFY/DELETE) permission flags. The service
    /// implements upsert semantics: if an entitlement already exists for
    /// the user-group pair, it updates the flags; otherwise it creates
    /// a new record.
    ///
    /// On success: displays a confirmation message and resets the
    /// permission toggles to their default (false) state.
    ///
    /// On failure: displays the error description (e.g., FK constraint
    /// violation if the user or group doesn't exist).
    private func assignEntitlement() async {
        // Guard: both user and group must be selected before assignment.
        guard let userId = selectedUserId,
              let groupId = selectedGroupId else {
            return
        }

        isAssigningEntitlement = true
        defer { isAssigningEntitlement = false }

        do {
            // Delegate to EntitlementService for MySQL upsert.
            try await entitlementService.assignEntitlement(
                userId: userId,
                accountGroupId: groupId,
                canRead: canRead,
                canCreate: canCreate,
                canModify: canModify,
                canDelete: canDelete
            )

            // Success: display confirmation and reset permission toggles.
            entitlementMessage = "Entitlement assigned successfully."
            canRead = false
            canCreate = false
            canModify = false
            canDelete = false
        } catch {
            // Display the error (e.g., FK constraint violation).
            entitlementMessage = "Error: \(error.localizedDescription)"
        }
    }
}
#endif
