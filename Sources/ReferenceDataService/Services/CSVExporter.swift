// Sources/ReferenceDataService/Services/CSVExporter.swift
// WealthLedger — CSV Export Service
//
// Generates CSV-formatted output with configurable field selection and RFC 4180 compliant
// escaping. Consumed by ReportGenerator in the JobScheduler module for report generation jobs.
//
// Rules enforced:
//   Rule 7  — Batch Memory Cap: caller (ReportGenerator) paginates at 1,000 records
//   Rule 8  — MySQLKit-Only Persistence: no SwiftData imports; pure Foundation utility
//   Rule 9  — Offline Runtime: local filesystem I/O only; zero network dependencies
//   Gate 2  — Swift 6 strict concurrency: Sendable struct, zero warnings

import Foundation

/// CSV export service that generates CSV-formatted output with configurable field selection.
///
/// Handles proper CSV escaping per RFC 4180: commas, double quotes, and newlines within
/// field values are properly escaped. All methods are pure functions (except `writeCSVToFile`
/// which performs atomic file I/O) operating over `String` and `Data` types from Foundation.
///
/// This struct is stateless and trivially `Sendable`, satisfying Swift 6 strict concurrency
/// requirements with zero `@unchecked Sendable` annotations.
///
/// ## Usage
/// ```swift
/// let exporter = CSVExporter()
/// let csv = exporter.exportToCSV(
///     headers: ["ticker", "name", "eod_bid"],
///     rows: [["AAPL", "Apple Inc.", "151.00"]]
/// )
/// try exporter.writeCSVToFile(csvString: csv, to: "/path/to/output.csv")
/// ```
public struct CSVExporter: Sendable {

    // MARK: - Nested Types

    /// A descriptor for a single CSV column, pairing a header name with a value extraction closure.
    ///
    /// `FieldDescriptor` enables callers to specify exactly which columns to include in the CSV
    /// output and in what order. The `extractor` closure converts a record of type `T` into
    /// the string value for that column.
    ///
    /// - Note: Both `T` and the struct itself are constrained to `Sendable` for Swift 6 concurrency safety.
    ///
    /// ## Example
    /// ```swift
    /// let descriptor = CSVExporter.FieldDescriptor<MyRecord>(
    ///     header: "Name",
    ///     extractor: { $0.name }
    /// )
    /// ```
    public struct FieldDescriptor<T>: Sendable where T: Sendable {

        /// The column header name displayed in the first row of the CSV output.
        public let header: String

        /// Closure that extracts the string representation of this field from a record.
        ///
        /// Marked `@Sendable` to satisfy Swift 6 strict concurrency when the enclosing
        /// `FieldDescriptor` is passed across concurrency domains.
        public let extractor: @Sendable (T) -> String

        /// Creates a new field descriptor.
        ///
        /// - Parameters:
        ///   - header: Column header name that appears in the CSV header row.
        ///   - extractor: A `@Sendable` closure that extracts the column value from a record of type `T`.
        public init(header: String, extractor: @Sendable @escaping (T) -> String) {
            self.header = header
            self.extractor = extractor
        }
    }

    // MARK: - Initialization

    /// Creates a new `CSVExporter`.
    ///
    /// The exporter is stateless — this initializer takes no parameters and stores no properties.
    public init() {}

    // MARK: - Core Export Methods

    /// Exports data to CSV format with the given headers and rows.
    ///
    /// Produces a complete CSV string consisting of a header row followed by data rows.
    /// Each field is escaped per RFC 4180: fields containing commas, double quotes, or
    /// newline characters are enclosed in double quotes, and any embedded double quotes
    /// are doubled (`"` → `""`).
    ///
    /// - Parameters:
    ///   - headers: Column header names in the desired output order.
    ///   - rows: Array of rows, where each row is an array of string values positionally
    ///           matching the `headers` array. Rows with fewer values than headers will
    ///           produce shorter CSV lines; rows with more values will include the extra fields.
    /// - Returns: A complete CSV string including the header row and all data rows,
    ///            with each line terminated by a newline character (`\n`).
    public func exportToCSV(headers: [String], rows: [[String]]) -> String {
        // Pre-calculate approximate capacity to reduce reallocations for large datasets.
        // Estimate ~50 characters per field as a reasonable average for financial data.
        let estimatedFieldCount = headers.count
        let estimatedCapacity = (1 + rows.count) * estimatedFieldCount * 50
        var csv = ""
        csv.reserveCapacity(estimatedCapacity)

        // Write header row
        csv += headers.map { escapeCSVField($0) }.joined(separator: ",")
        csv += "\n"

        // Write data rows
        for row in rows {
            csv += row.map { escapeCSVField($0) }.joined(separator: ",")
            csv += "\n"
        }

        return csv
    }

    /// Exports data to CSV format and returns the result as UTF-8 encoded `Data`.
    ///
    /// This is a convenience wrapper around ``exportToCSV(headers:rows:)`` that converts
    /// the CSV string to `Data`, suitable for writing to disk via `FileManager` or
    /// transmitting as a byte buffer.
    ///
    /// - Parameters:
    ///   - headers: Column header names in the desired output order.
    ///   - rows: Array of rows, where each row is an array of string values.
    /// - Returns: UTF-8 encoded `Data` containing the complete CSV content.
    public func exportToCSVData(headers: [String], rows: [[String]]) -> Data {
        let csvString = exportToCSV(headers: headers, rows: rows)
        return Data(csvString.utf8)
    }

    /// Exports records to CSV with configurable field selection and ordering.
    ///
    /// This generic method enables the caller to specify exactly which columns to include
    /// and in what order by providing an array of ``FieldDescriptor`` instances. Each descriptor
    /// pairs a column header with a closure that extracts the field value from a record.
    ///
    /// This method supports the report generation job's field selection feature, where
    /// users choose which account/valuation fields to include in the exported CSV.
    ///
    /// - Parameters:
    ///   - records: Array of records to export. The generic type `T` must conform to `Sendable`.
    ///   - fields: Array of field descriptors defining columns and value extraction in the
    ///             desired output order.
    /// - Returns: A complete CSV string with only the selected fields, including header row.
    public func exportWithFieldSelection<T: Sendable>(
        records: [T],
        fields: [FieldDescriptor<T>]
    ) -> String {
        let headers = fields.map { $0.header }
        let rows: [[String]] = records.map { record in
            fields.map { field in field.extractor(record) }
        }
        return exportToCSV(headers: headers, rows: rows)
    }

    // MARK: - File I/O

    /// Writes CSV content to a file at the specified path.
    ///
    /// Uses atomic writing to prevent partial file corruption — the content is first written
    /// to a temporary file, then atomically moved to the target path. The file is encoded
    /// as UTF-8.
    ///
    /// - Parameters:
    ///   - csvString: The CSV-formatted string to write.
    ///   - filePath: Absolute or relative path for the output CSV file.
    /// - Throws: An error if the file cannot be written (e.g., invalid path, permission denied,
    ///           disk full).
    public func writeCSVToFile(csvString: String, to filePath: String) throws {
        try csvString.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Helpers

    /// Escapes a single CSV field value per RFC 4180.
    ///
    /// The escaping rules are:
    /// 1. If the field contains a comma (`,`), double quote (`"`), carriage return (`\r`),
    ///    or newline (`\n`), the entire field is enclosed in double quotes.
    /// 2. Any double quote characters within the field are escaped by doubling them (`"` → `""`).
    /// 3. Fields that do not contain any special characters are returned unmodified.
    ///
    /// - Parameter field: The raw field value to escape.
    /// - Returns: The properly escaped field value, ready for inclusion in a CSV row.
    private func escapeCSVField(_ field: String) -> String {
        // Check for characters that require quoting per RFC 4180
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")

        if needsQuoting {
            // Escape embedded double quotes by doubling them
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        return field
    }
}
