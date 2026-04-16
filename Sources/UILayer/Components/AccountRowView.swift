#if canImport(SwiftUI)
// Sources/UILayer/Components/AccountRowView.swift
// WealthLedger — Reusable Account Row Component
//
// Displays a single account in scrollable lists throughout the application.
// Used by SearchView (search results) and AccountsViewerView (selected accounts).

import SwiftUI
import AccountManagement

// MARK: - AccountRowView

/// Reusable row component for displaying a single account in scrollable lists.
///
/// Renders a horizontal layout showing:
/// - **Account name** — primary headline text (single line, truncated if needed)
/// - **Account ID** — secondary caption text with monospaced digits
/// - **Cached valuation amount** — right-aligned, USD currency formatted (or "—" if nil)
/// - **Status badge** — color-coded capsule based on ``AccountStatus``
///
/// ## Usage
///
/// Used by both ``SearchView`` (search results list) and ``AccountsViewerView``
/// (selected accounts scrollable list). Designed for use inside `LazyVStack`
/// to achieve 30fps scrolling performance with up to 1,000 visible accounts.
///
/// ```swift
/// LazyVStack {
///     ForEach(accounts) { account in
///         AccountRowView(account: account)
///     }
/// }
/// ```
///
/// ## Concurrency Safety (Gate 2)
///
/// `AccountRowView` is a value-type `struct` conforming to SwiftUI `View`.
/// SwiftUI views are `@MainActor`-isolated by default in Swift 6. The sole
/// stored property ``account`` is an immutable `let` of type ``Account``,
/// which is itself a `Sendable` value type. No mutable state (`@State`,
/// `@StateObject`) is used — this is a stateless display component. Zero
/// `@unchecked Sendable` annotations are required.
///
/// ## Performance (Rule 7 + Rule 13)
///
/// This component is lightweight by design. The `body` computed property
/// performs only layout composition, string interpolation, and a single
/// `NumberFormatter` allocation for currency display. No database queries,
/// no async operations, and no expensive computations occur during rendering.
/// When used inside `LazyVStack`, only visible rows are materialized,
/// keeping memory usage well within the 1,000-account batch memory cap.
public struct AccountRowView: View {

    // MARK: - Properties

    /// The account to display in this row.
    ///
    /// Immutable value passed from the parent view. ``Account`` is a `Sendable`
    /// struct with all properties declared as `let`, composed entirely of
    /// `Sendable` types (`UInt64`, `String`, `Decimal?`, ``AccountStatus``, etc.).
    public let account: Account

    // MARK: - Initializer

    /// Creates a new account row view for the specified account.
    ///
    /// - Parameter account: The ``Account`` value to render. The view reads
    ///   ``Account/name``, ``Account/id``, ``Account/cachedValuationAmount``,
    ///   and ``Account/status`` for display.
    public init(account: Account) {
        self.account = account
    }

    // MARK: - Body

    /// The view body rendering account information in a horizontal layout.
    ///
    /// Layout structure:
    /// ```
    /// ┌──────────────────────────────────────────────────────────┐
    /// │  Account Name                            $1,234,567.89  │
    /// │  ID: 12345                                    ● Active  │
    /// └──────────────────────────────────────────────────────────┘
    /// ```
    ///
    /// Left section (`VStack`, leading-aligned):
    /// - Account name as headline text (single line, truncated)
    /// - Account ID as caption text with monospaced digits
    ///
    /// Right section (`VStack`, trailing-aligned):
    /// - Cached valuation amount formatted as USD currency (or em-dash if nil)
    /// - Color-coded status badge in a capsule shape
    public var body: some View {
        HStack(spacing: 12) {
            // Left section: Name and ID
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name)
                    .font(.headline)
                    .lineLimit(1)

                Text("ID: \(account.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            // Right section: Valuation amount and status badge
            VStack(alignment: .trailing, spacing: 4) {
                valuationAmountText
                statusBadge
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: - Subviews

    /// Displays the cached valuation amount formatted as USD currency,
    /// or an em-dash placeholder when no valuation has been computed yet.
    @ViewBuilder
    private var valuationAmountText: some View {
        if let amount = account.cachedValuationAmount {
            Text(formattedAmount(amount))
                .font(.body)
                .monospacedDigit()
        } else {
            Text("\u{2014}")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    /// Color-coded status badge displayed as text inside a capsule shape.
    ///
    /// Color mapping:
    /// - ``AccountStatus/active`` → green
    /// - ``AccountStatus/inactive`` → gray
    /// - ``AccountStatus/pending`` → orange
    /// - ``AccountStatus/suspended`` → red
    ///
    /// The badge uses a semi-transparent background (`opacity(0.15)`) with
    /// solid foreground text in the status color, enclosed in a `Capsule` clip shape.
    @ViewBuilder
    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    // MARK: - Computed Properties

    /// Maps the account's lifecycle status to a display color.
    ///
    /// - `active` → `.green` (fully operational)
    /// - `inactive` → `.gray` (temporarily deactivated)
    /// - `pending` → `.orange` (awaiting activation)
    /// - `suspended` → `.red` (restricted by compliance/admin action)
    private var statusColor: Color {
        switch account.status {
        case .active:
            return .green
        case .inactive:
            return .gray
        case .pending:
            return .orange
        case .suspended:
            return .red
        }
    }

    /// Maps the account's lifecycle status to a human-readable text label.
    private var statusText: String {
        switch account.status {
        case .active:
            return "Active"
        case .inactive:
            return "Inactive"
        case .pending:
            return "Pending"
        case .suspended:
            return "Suspended"
        }
    }

    // MARK: - Formatting

    /// Formats a `Decimal` amount as a USD currency string.
    ///
    /// Uses `NumberFormatter` with `.currency` style, `"USD"` currency code,
    /// and exactly 2 fraction digits. Returns `"$0.00"` as a fallback if
    /// formatting fails.
    ///
    /// - Parameter amount: The `Decimal` value to format.
    /// - Returns: A currency-formatted string such as `"$1,234,567.89"`.
    ///
    /// - Note: `NumberFormatter` allocation within this method is acceptable
    ///   for `LazyVStack` usage since only visible rows invoke `body`. If
    ///   profiling reveals this as a bottleneck, a `nonisolated(unsafe) static`
    ///   formatter can be introduced.
    private func formattedAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
#endif
