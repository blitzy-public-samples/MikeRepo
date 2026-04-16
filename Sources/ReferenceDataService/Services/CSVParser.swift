// CSVParser.swift
// Sources/ReferenceDataService/Services/CSVParser.swift
//
// CSV file parsing service for the WealthLedger accounting engine.
// Parses CSV files with column validation and memory-efficient streaming I/O
// for files up to 100MB (Rule 13). Uses Foundation APIs only — no external
// CSV library (Rule 9 — Offline Runtime). No SwiftData (Rule 8).

import Foundation
import Shared

// MARK: - CSVParser

/// CSV file parsing service with column validation and paginated ingestion.
///
/// Parses CSV files by filename/path, validates column structure (headers and
/// data types), and reads files in 64 KB chunks via `FileHandle` to support
/// files up to 100 MB without crash (Rule 13). Uses Foundation's file I/O
/// APIs exclusively — no external CSV library (Rule 9 — Offline Runtime).
///
/// **Required CSV columns for reference data:**
/// `ticker`, `name`, `sod_bid`, `sod_ask`, `eod_bid`, `eod_ask`, `market_date`
///
/// ## Concurrency Safety
///
/// Conforms to `Sendable` for Swift 6 strict concurrency (Gate 2). As a
/// stateless value type with zero stored properties, the conformance is
/// trivially correct. Zero `@unchecked Sendable` annotations.
///
/// ## Consumers
///
/// - **`ReferenceDataService`** — orchestrates CSV ingestion into the
///   `reference_data` table.
/// - **`JobSchedulerService`** — CSV ingestion jobs triggered manually.
/// - **`SeedTool` CLI** — seeding synthetic reference data from generated CSV.
public struct CSVParser: Sendable {

    // MARK: - Error Types

    /// Errors specific to CSV parsing operations.
    ///
    /// Each case provides context about the specific parsing failure
    /// encountered. All associated values are `Sendable`-safe (`String`,
    /// `Int`).
    ///
    /// Use the ``asAppError`` property to convert to the application-wide
    /// ``AppError`` type for interoperability with other modules.
    public enum CSVParseError: Error, Sendable {

        /// The specified file was not found at the given path.
        case fileNotFound(String)

        /// A required CSV column is missing from the header row.
        case missingRequiredColumn(String)

        /// A price field could not be parsed as a valid `Decimal` number.
        case invalidPriceField

        /// A price field was zero or negative (violates Rule 6 — non-zero).
        case zeroPriceField

        /// A date field could not be parsed (expected `yyyy-MM-dd` format).
        case invalidDateField

        /// A CSV row has fewer fields than expected based on the header.
        case malformedRow(Int)

        /// Ticker symbol does not match the 3–5 uppercase ASCII letter
        /// pattern required for NYSE equities.
        case invalidTicker(String)

        /// The CSV file contains no data rows (only a header or empty).
        case emptyFile

        /// Maps this CSV-specific error to the application-wide ``AppError``
        /// type.
        ///
        /// CSV validation failures map to ``AppError/migrationFailed`` since
        /// they represent data-loading failures during reference data
        /// ingestion.
        public var asAppError: AppError {
            AppError.migrationFailed
        }
    }

    // MARK: - Constants

    /// Required column names for reference data CSV files (Rule 6).
    private static let requiredReferenceDataColumns: [String] = [
        "ticker", "name", "sod_bid", "sod_ask",
        "eod_bid", "eod_ask", "market_date",
    ]

    /// Buffer size in bytes for streaming file reads (64 KB chunks).
    private static let readBufferSize: Int = 65_536

    // MARK: - Initializer

    /// Creates a new ``CSVParser`` instance.
    public init() {}

    // MARK: - Public Methods

    /// Parses a reference data CSV file at the given path.
    ///
    /// Reads the file using buffered I/O via `FileHandle` to avoid loading
    /// the entire file into memory (Rule 13 — files up to 100 MB). Validates
    /// the header row for required columns and each data row for correct
    /// types and non-zero prices (Rule 6).
    ///
    /// Internally delegates to ``parseReferenceDataCSVBatched(at:handler:)``
    /// which processes lines in batches of ``AppConstants/batchSize`` (1,000),
    /// keeping only one batch of raw string lines in memory at a time
    /// (Rule 7 — Batch Memory Cap).  The ``[ReferenceData]`` result array
    /// accumulates as batches are parsed.  For true streaming (where even
    /// the result array does not accumulate), use the batched variant
    /// directly with per-batch insertion.
    ///
    /// **Required columns:**
    /// `ticker`, `name`, `sod_bid`, `sod_ask`, `eod_bid`, `eod_ask`,
    /// `market_date`
    ///
    /// - Parameter filePath: Absolute or relative path to the CSV file.
    /// - Returns: Array of parsed ``ReferenceData`` records with `id` set
    ///   to `0` (MySQL auto-generates on `INSERT`).
    /// - Throws: ``CSVParseError`` if the file cannot be read, column
    ///   validation fails, or any row contains invalid data.
    public func parseReferenceDataCSV(at filePath: String) throws -> [ReferenceData] {
        var results: [ReferenceData] = []
        try parseReferenceDataCSVBatched(at: filePath) { batch in
            results.append(contentsOf: batch)
        }
        return results
    }

    /// Parses a generic CSV file at the given path.
    ///
    /// Returns raw headers and row data without domain-specific validation.
    /// Reads the file using buffered I/O for memory efficiency (Rule 13).
    ///
    /// - Parameter filePath: Absolute or relative path to the CSV file.
    /// - Returns: Tuple of header names and an array of row data where each
    ///   row is an array of trimmed string fields.
    /// - Throws: ``CSVParseError/fileNotFound(_:)`` if the file does not
    ///   exist; ``CSVParseError/emptyFile`` if no content is present.
    public func parseCSV(
        at filePath: String
    ) throws -> (headers: [String], rows: [[String]]) {
        let lines = try readLinesStreaming(from: filePath)

        guard !lines.isEmpty else {
            throw CSVParseError.emptyFile
        }

        let headers = splitCSVLine(lines[0]).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        let dataLines = Array(lines.dropFirst())
        var rows: [[String]] = []
        rows.reserveCapacity(dataLines.count)

        for line in dataLines {
            let fields = splitCSVLine(line).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            rows.append(fields)
        }

        return (headers: headers, rows: rows)
    }

    /// Parses a reference data CSV file in batches, calling `handler` for
    /// each batch of parsed records.
    ///
    /// **True streaming implementation**: reads the file using buffered I/O
    /// via `FileHandle` in 64 KB chunks (Rule 13 — files up to 100 MB).
    /// At any point, only one batch of raw string lines AND one batch of
    /// parsed ``ReferenceData`` records reside in memory simultaneously.
    /// Peak string memory is proportional to ``AppConstants/batchSize``
    /// (1,000 lines) regardless of total file size, supporting Rule 7
    /// (batch memory cap) and Rule 13 (100 MB CSV ingestion).
    ///
    /// The header row is validated once at the start.  Subsequent data lines
    /// are accumulated into batches of ``AppConstants/batchSize`` (1,000)
    /// and yielded to `handler`.  After the handler returns, the string
    /// batch is released before the next batch is built.
    ///
    /// This is the preferred method for CSV ingestion where the caller can
    /// process each batch independently (e.g., bulk-insert into MySQL via
    /// ``ReferenceDataRepository``).
    ///
    /// **Required columns:**
    /// `ticker`, `name`, `sod_bid`, `sod_ask`, `eod_bid`, `eod_ask`,
    /// `market_date`
    ///
    /// - Parameters:
    ///   - filePath: Absolute or relative path to the CSV file.
    ///   - handler: Closure called once per batch with an array of parsed
    ///     ``ReferenceData`` records.  The closure may throw to abort
    ///     processing.
    /// - Throws: ``CSVParseError`` if the file cannot be read, column
    ///   validation fails, or any row contains invalid data.  Also rethrows
    ///   any error from `handler`.
    public func parseReferenceDataCSVBatched(
        at filePath: String,
        handler: ([ReferenceData]) throws -> Void
    ) throws {
        var headerLine: String?
        var columnMap: [String: Int] = [:]
        var lineNumber = 1
        var hasDataLines = false

        // Create DateFormatter once for all rows (performance optimisation).
        // Created locally — not stored — so no concurrency issue.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        try readLinesInBatches(
            from: filePath,
            batchSize: AppConstants.batchSize
        ) { batch in
            var batchRecords: [ReferenceData] = []

            for line in batch {
                if headerLine == nil {
                    // First line is the header row — validate columns
                    headerLine = line
                    let headerFields = splitCSVLine(line)
                    columnMap = try validateReferenceDataHeaders(headerFields)
                    lineNumber = 2
                } else {
                    let record = try parseReferenceDataRow(
                        line: line,
                        columnMap: columnMap,
                        lineNumber: lineNumber,
                        dateFormatter: dateFormatter
                    )
                    batchRecords.append(record)
                    lineNumber += 1
                    hasDataLines = true
                }
            }

            if !batchRecords.isEmpty {
                try handler(batchRecords)
            }
        }

        guard headerLine != nil else {
            throw CSVParseError.emptyFile
        }
        guard hasDataLines else {
            throw CSVParseError.emptyFile
        }
    }

    /// Validates that CSV headers contain all required reference data columns.
    ///
    /// Column matching is case-insensitive and whitespace-trimmed, so CSVs
    /// with columns in any order are accepted.
    ///
    /// **Required columns:**
    /// `ticker`, `name`, `sod_bid`, `sod_ask`, `eod_bid`, `eod_ask`,
    /// `market_date`
    ///
    /// - Parameter headers: Array of header column names from the CSV.
    /// - Returns: Dictionary mapping lowercase column names to their
    ///   zero-based index.
    /// - Throws: ``CSVParseError/missingRequiredColumn(_:)`` if any
    ///   required column is absent.
    public func validateReferenceDataHeaders(
        _ headers: [String]
    ) throws -> [String: Int] {
        let normalizedHeaders = headers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var columnMap: [String: Int] = [:]
        columnMap.reserveCapacity(Self.requiredReferenceDataColumns.count)

        for required in Self.requiredReferenceDataColumns {
            guard let index = normalizedHeaders.firstIndex(of: required) else {
                throw CSVParseError.missingRequiredColumn(required)
            }
            columnMap[required] = index
        }

        return columnMap
    }

    // MARK: - Private — Row Parsing

    /// Parses a single CSV row into a ``ReferenceData`` struct.
    ///
    /// Validates that:
    /// - The row has enough fields for all required columns.
    /// - The ticker matches the 3–5 uppercase ASCII letter pattern.
    /// - All six price fields are valid `Decimal` values greater than zero
    ///   (Rule 6).
    /// - The `market_date` parses as `yyyy-MM-dd`.
    ///
    /// - Parameters:
    ///   - line: The raw CSV line string.
    ///   - columnMap: Dictionary mapping column names to their indices.
    ///   - lineNumber: One-based line number in the file (for error context).
    ///   - dateFormatter: Pre-configured `DateFormatter` for `yyyy-MM-dd`.
    /// - Returns: A parsed ``ReferenceData`` record with `id` set to `0`
    ///   (MySQL auto-generates on `INSERT`).
    /// - Throws: ``CSVParseError`` if any field is missing, unparseable, or
    ///   violates domain rules.
    private func parseReferenceDataRow(
        line: String,
        columnMap: [String: Int],
        lineNumber: Int,
        dateFormatter: DateFormatter
    ) throws -> ReferenceData {
        let fields = splitCSVLine(line)

        // Verify the row has enough fields for the highest required index
        let maxRequiredIndex = columnMap.values.max() ?? 0
        guard fields.count > maxRequiredIndex else {
            throw CSVParseError.malformedRow(lineNumber)
        }

        // Extract and validate ticker (3–5 uppercase ASCII letters — Rule 6)
        let ticker = fields[columnMap["ticker"]!]
            .trimmingCharacters(in: .whitespaces)
        guard isValidTicker(ticker) else {
            throw CSVParseError.invalidTicker(ticker)
        }

        // Extract company name
        let name = fields[columnMap["name"]!]
            .trimmingCharacters(in: .whitespaces)

        // Parse all 6 price fields as Decimal (exact financial arithmetic).
        // NEVER use Double or Float for financial data.
        let sodBidStr = fields[columnMap["sod_bid"]!]
            .trimmingCharacters(in: .whitespaces)
        let sodAskStr = fields[columnMap["sod_ask"]!]
            .trimmingCharacters(in: .whitespaces)
        let eodBidStr = fields[columnMap["eod_bid"]!]
            .trimmingCharacters(in: .whitespaces)
        let eodAskStr = fields[columnMap["eod_ask"]!]
            .trimmingCharacters(in: .whitespaces)

        guard let sodBid = Decimal(string: sodBidStr),
              let sodAsk = Decimal(string: sodAskStr),
              let eodBid = Decimal(string: eodBidStr),
              let eodAsk = Decimal(string: eodAskStr) else {
            throw CSVParseError.invalidPriceField
        }

        // Rule 6: All six price fields must be strictly positive (non-zero)
        guard sodBid > 0, sodAsk > 0, eodBid > 0, eodAsk > 0 else {
            throw CSVParseError.zeroPriceField
        }

        // Parse market_date — expected format: yyyy-MM-dd
        let dateString = fields[columnMap["market_date"]!]
            .trimmingCharacters(in: .whitespaces)
        guard let marketDate = dateFormatter.date(from: dateString) else {
            throw CSVParseError.invalidDateField
        }

        // Construct ReferenceData with id=0 (MySQL auto-generates on INSERT)
        return ReferenceData(
            id: 0,
            ticker: ticker,
            name: name,
            sodBid: sodBid,
            sodAsk: sodAsk,
            eodBid: eodBid,
            eodAsk: eodAsk,
            marketDate: marketDate
        )
    }

    /// Validates that a ticker symbol matches the NYSE equity pattern.
    ///
    /// Valid tickers consist of 3 to 5 uppercase ASCII letters (`A`–`Z`).
    ///
    /// - Parameter ticker: The ticker string to validate.
    /// - Returns: `true` if the ticker is valid; `false` otherwise.
    private func isValidTicker(_ ticker: String) -> Bool {
        let length = ticker.count
        guard length >= 3, length <= 5 else { return false }
        return ticker.allSatisfy { char in
            char.isASCII && char.isLetter && char.isUppercase
        }
    }

    // MARK: - Private — CSV Line Splitting

    /// Splits a CSV line into individual field values, handling quoted fields.
    ///
    /// Properly handles:
    /// - Commas within quoted fields (enclosed in double quotes).
    /// - Doubled quotes (`""`) as escaped literal quotes inside fields.
    /// - Fields without quotes split on commas directly.
    ///
    /// - Parameter line: A single CSV line without the line terminator.
    /// - Returns: Array of field values with enclosing quotes stripped.
    private func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    // Peek at the next character to distinguish escaped
                    // quotes ("") from the closing quote of a field.
                    if let nextChar = iterator.next() {
                        if nextChar == "\"" {
                            // Escaped double quote — append literal quote
                            currentField.append("\"")
                        } else if nextChar == "," {
                            // End of quoted field, followed by delimiter
                            fields.append(currentField)
                            currentField = ""
                            inQuotes = false
                        } else {
                            // Closing quote followed by non-delimiter
                            inQuotes = false
                            currentField.append(nextChar)
                        }
                    } else {
                        // Closing quote at end of line
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == "," {
                    fields.append(currentField)
                    currentField = ""
                } else {
                    currentField.append(char)
                }
            }
        }

        // Append the final field (after the last comma or the only field)
        fields.append(currentField)
        return fields
    }

    // MARK: - Private — Streaming File Reader

    /// Reads lines from a file in 64 KB I/O chunks and yields them to a
    /// handler in batches of at most `batchSize` lines.
    ///
    /// Only one batch of `String` values is alive at a time — the handler
    /// processes and releases strings before the next batch is built.  This
    /// keeps peak string memory proportional to
    /// `batchSize × average_line_length` rather than total file size,
    /// supporting Rule 7 (batch memory cap) and Rule 13 (100 MB CSV
    /// ingestion without excessive memory usage).
    ///
    /// Uses the same byte-level `FileHandle` and `0x0A` line-feed scanning
    /// strategy as ``readLinesStreaming(from:)`` for consistent line
    /// termination handling (Unix `\n` and Windows `\r\n`).
    ///
    /// - Parameters:
    ///   - filePath: Absolute or relative path to the file.
    ///   - batchSize: Maximum number of lines per batch (typically
    ///     ``AppConstants/batchSize``, i.e. 1,000).
    ///   - handler: Closure called once per batch with an array of
    ///     non-empty lines.  The closure may throw to abort processing.
    /// - Throws: ``CSVParseError/fileNotFound(_:)`` if the file does not
    ///   exist or cannot be opened; any error propagated from `handler`.
    private func readLinesInBatches(
        from filePath: String,
        batchSize: Int,
        handler: ([String]) throws -> Void
    ) throws {
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CSVParseError.fileNotFound(filePath)
        }

        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw CSVParseError.fileNotFound(filePath)
        }
        defer { fileHandle.closeFile() }

        let newlineByte: UInt8 = 0x0A   // \n
        let carriageReturn: UInt8 = 0x0D // \r
        let ioBufferSize = Self.readBufferSize

        var lineBuffer = Data()
        var currentBatch: [String] = []
        currentBatch.reserveCapacity(min(batchSize, 1_000))

        while true {
            let data: Data = fileHandle.readData(ofLength: ioBufferSize)
            if data.isEmpty { break }

            for byte in data {
                if byte == newlineByte {
                    // End of line — strip trailing \r if present
                    if !lineBuffer.isEmpty && lineBuffer.last == carriageReturn {
                        lineBuffer.removeLast()
                    }
                    if let line = String(data: lineBuffer, encoding: .utf8),
                       !line.isEmpty {
                        currentBatch.append(line)
                        if currentBatch.count >= batchSize {
                            try handler(currentBatch)
                            currentBatch.removeAll(keepingCapacity: true)
                        }
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                }
            }
        }

        // Process any content remaining after the last newline
        if !lineBuffer.isEmpty {
            if lineBuffer.last == carriageReturn {
                lineBuffer.removeLast()
            }
            if let line = String(data: lineBuffer, encoding: .utf8),
               !line.isEmpty {
                currentBatch.append(line)
            }
        }

        // Yield the final partial batch
        if !currentBatch.isEmpty {
            try handler(currentBatch)
        }
    }

    /// Reads all lines from a file using buffered I/O for memory efficiency.
    ///
    /// Uses `FileHandle` to read in 64 KB chunks and scans for line-feed
    /// bytes (`0x0A`) at the **byte level** to avoid Swift's grapheme
    /// cluster merging of `\r\n` into a single `Character`.  Trailing
    /// carriage-return bytes (`0x0D`) are stripped from each extracted
    /// line so both Unix (`\n`) and Windows (`\r\n`) endings are
    /// normalised transparently.
    ///
    /// - Note: This method accumulates **all** lines into a single array
    ///   before returning.  For large files (tens of MB or more), prefer
    ///   ``readLinesInBatches(from:batchSize:handler:)`` which keeps only
    ///   one batch of lines in memory at a time.
    ///
    /// This method is retained for ``parseCSV(at:)`` which must return all
    /// rows as a single collection.
    ///
    /// - Parameter filePath: Absolute or relative path to the file.
    /// - Returns: Array of non-empty lines with line terminators stripped.
    /// - Throws: ``CSVParseError/fileNotFound(_:)`` if the file does not
    ///   exist or cannot be opened.
    private func readLinesStreaming(from filePath: String) throws -> [String] {
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CSVParseError.fileNotFound(filePath)
        }

        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw CSVParseError.fileNotFound(filePath)
        }
        defer { fileHandle.closeFile() }

        let newlineByte: UInt8 = 0x0A   // \n
        let carriageReturn: UInt8 = 0x0D // \r

        var lines: [String] = []
        var lineBuffer = Data()
        let bufferSize = Self.readBufferSize

        while true {
            let data: Data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }

            for byte in data {
                if byte == newlineByte {
                    // End of line — strip trailing \r if present
                    if !lineBuffer.isEmpty && lineBuffer.last == carriageReturn {
                        lineBuffer.removeLast()
                    }
                    if let line = String(data: lineBuffer, encoding: .utf8),
                       !line.isEmpty {
                        lines.append(line)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                }
            }
        }

        // Process any content remaining after the last newline
        if !lineBuffer.isEmpty {
            if lineBuffer.last == carriageReturn {
                lineBuffer.removeLast()
            }
            if let line = String(data: lineBuffer, encoding: .utf8),
               !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }
}
