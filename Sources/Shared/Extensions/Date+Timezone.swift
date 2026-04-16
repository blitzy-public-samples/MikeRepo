// Sources/Shared/Extensions/Date+Timezone.swift
// WealthLedger — Date Utilities for Timezone-Aware Value Date Computation
//
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - DateTimezoneError

/// Errors related to timezone operations on ``Date`` values.
///
/// This dedicated error type is used by the ``Date`` timezone extension methods
/// to signal validation failures — primarily when an account's stored IANA
/// timezone identifier cannot be resolved to a valid ``TimeZone`` instance.
///
/// Callers in ``ValuationEngine`` or other modules can catch
/// ``DateTimezoneError/invalidTimezone(_:)`` and map it to ``AppError/invalidTimezone``
/// if a unified error type is preferred at a higher layer.
///
/// Conforms to both ``Error`` (for Swift error-handling semantics) and ``Sendable``
/// (for Swift 6 strict concurrency safety). Because the only associated value is
/// ``String`` — a value type that is inherently ``Sendable`` — conformance is
/// trivially safe with no `@unchecked Sendable` annotations required.
public enum DateTimezoneError: Error, Sendable {

    /// The provided IANA timezone identifier is not recognised by Foundation.
    ///
    /// The associated ``String`` value contains the exact identifier that failed
    /// validation, enabling callers to produce informative diagnostic messages.
    ///
    /// Example identifiers that would trigger this error:
    /// - `"Invalid/Timezone"`
    /// - `""` (empty string)
    /// - `"Foo"` (not a valid IANA zone)
    case invalidTimezone(String)
}

// MARK: - Date + Timezone Extension

/// Extension on ``Date`` providing timezone-aware value-date computation for
/// the WealthLedger valuation engine.
///
/// ## Rule 3 — Per-Account Valuation Timezone (Highest Priority)
///
/// Each account stores its own IANA timezone string (e.g. `"America/New_York"`,
/// `"Europe/London"`) and its own valuation schedule. The ``ValuationEngine``
/// **must** use the account's stored timezone — never the system clock timezone.
///
/// ### Verification
///
/// Two accounts configured for `"America/New_York"` and `"Europe/London"` must
/// produce **distinct** value dates when the UTC clock falls between midnight
/// London time and midnight New York time. For example, at
/// `2024-01-15T03:00:00Z`:
///
/// | Account Timezone   | Local Time | Calendar Date | Value Date |
/// |--------------------|------------|---------------|------------|
/// | Europe/London      | 03:00      | January 15    | Jan 15     |
/// | America/New_York   | 22:00 (Jan 14) | January 14 | Jan 14  |
///
/// ### Design Principles
///
/// - **NEVER** use ``TimeZone/current`` — it returns the system's timezone.
/// - **NEVER** use ``Calendar/current`` — it inherits the system's timezone.
/// - **ALWAYS** create ``Calendar(identifier: .gregorian)`` fresh.
/// - **ALWAYS** set ``Calendar/timeZone`` explicitly from the account's IANA string.
/// - **ALWAYS** accept the timezone as a ``String`` parameter (matching the MySQL
///   `VARCHAR` column type used to store account timezones).
///
/// All methods are **pure functions** — stateless, side-effect-free, and
/// ``Sendable``-safe by construction. ``Date`` is a value type conforming to
/// ``Sendable``; extensions on it inherit that safety.
extension Date {

    // MARK: Primary Value-Date Method

    /// Computes the **value date** for a given IANA timezone.
    ///
    /// The value date is the calendar date (start of day) derived from this
    /// ``Date`` instance as observed in the specified IANA timezone. This ensures
    /// that the ``ValuationEngine`` uses each account's stored timezone — never
    /// the system clock timezone (Rule 3: Per-Account Valuation Timezone).
    ///
    /// ### Algorithm
    ///
    /// 1. Validate the IANA string by attempting ``TimeZone(identifier:)``.
    ///    If it returns `nil`, throw ``DateTimezoneError/invalidTimezone(_:)``.
    /// 2. Create a fresh ``Calendar(identifier: .gregorian)`` and set its
    ///    ``Calendar/timeZone`` to the resolved timezone.
    /// 3. Extract the year, month, and day components from `self` using the
    ///    account's calendar.
    /// 4. Reconstruct and return a ``Date`` representing the start of that
    ///    calendar day in the account's timezone.
    ///
    /// ### Example
    ///
    /// ```swift
    /// // UTC instant: 2024-01-15 03:00:00 UTC
    /// let utcInstant: Date = ...
    ///
    /// // London (UTC+0 in January): January 15 start-of-day
    /// let londonDate = try utcInstant.valueDateForTimezone("Europe/London")
    ///
    /// // New York (UTC-5 in January): January 14 start-of-day
    /// let nyDate = try utcInstant.valueDateForTimezone("America/New_York")
    ///
    /// // londonDate != nyDate — Rule 3 verified
    /// ```
    ///
    /// - Parameter iana: An IANA timezone identifier string (e.g.
    ///   `"America/New_York"`, `"Europe/London"`, `"Asia/Tokyo"`). Must map to a
    ///   valid Foundation ``TimeZone`` identifier.
    /// - Returns: A ``Date`` representing the start of the calendar day in the
    ///   specified timezone. The returned ``Date`` is an absolute point in time
    ///   corresponding to `00:00:00` on the calendar date as observed in the
    ///   given timezone.
    /// - Throws: ``DateTimezoneError/invalidTimezone(_:)`` if the IANA string
    ///   does not resolve to a valid ``TimeZone``.
    public func valueDateForTimezone(_ iana: String) throws -> Date {
        // Step 1: Resolve the IANA identifier to a TimeZone.
        // TimeZone(identifier:) returns nil for unrecognised identifiers.
        guard let timeZone = TimeZone(identifier: iana) else {
            throw DateTimezoneError.invalidTimezone(iana)
        }

        // Step 2: Create a fresh Gregorian calendar with the account's timezone.
        // CRITICAL: We deliberately avoid Calendar.current which would use the
        //           system timezone — violating Rule 3.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Step 3: Extract the year/month/day as seen in the account's timezone.
        let components = calendar.dateComponents([.year, .month, .day], from: self)

        // Step 4: Reconstruct the start-of-day Date in the account's timezone.
        // calendar.date(from:) returns nil only when components are contradictory
        // (e.g. month 13), which cannot happen since we extracted them from a
        // valid Date above. The guard is retained for defensive correctness.
        guard let startOfDay = calendar.date(from: components) else {
            throw DateTimezoneError.invalidTimezone(iana)
        }

        return startOfDay
    }

    // MARK: Utility Helper

    /// Converts an IANA timezone identifier string to a Foundation ``TimeZone``.
    ///
    /// This is a thin convenience wrapper around ``TimeZone(identifier:)`` that
    /// allows callers to validate an IANA string without needing to know the
    /// Foundation API directly.
    ///
    /// ### Example
    ///
    /// ```swift
    /// if let tz = Date.timeZoneFromIANA("America/New_York") {
    ///     // Valid timezone — proceed with timezone-aware operations
    /// } else {
    ///     // Invalid identifier — handle gracefully
    /// }
    /// ```
    ///
    /// - Parameter iana: An IANA timezone identifier (e.g. `"America/New_York"`,
    ///   `"Europe/London"`, `"UTC"`).
    /// - Returns: The corresponding ``TimeZone``, or `nil` if the identifier is
    ///   not recognised by Foundation's timezone database.
    public static func timeZoneFromIANA(_ iana: String) -> TimeZone? {
        TimeZone(identifier: iana)
    }
}
