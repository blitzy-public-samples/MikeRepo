// CSVParserTests.swift
// Tests/UnitTests/ReferenceDataTests/CSVParserTests.swift
//
// Comprehensive unit tests for CSVParser — validates CSV parsing, column
// validation, error handling, edge cases, and pagination support.
//
// Testing framework: Swift Testing (@Suite, @Test, #expect) — NO XCTest.
// All tests are pure unit tests — no MySQL connections or repository calls.
// Temporary CSV files are created per-test with unique UUIDs and cleaned up.
//
// Rules enforced:
//   Rule 6  — Non-null, non-zero price fields
//   Rule 7  — Batch memory cap (1,000 records per page)
//   Rule 8  — No SwiftData anywhere
//   Gate 2  — Swift 6 strict concurrency, zero warnings

import Testing
import Foundation
@testable import ReferenceDataService

// MARK: - CSVParserTests

/// Comprehensive test suite for ``CSVParser`` validating header parsing,
/// row extraction, error handling, edge cases, and large-file pagination.
///
/// Uses `struct` (not class) for trivial `Sendable` conformance under
/// Swift 6 strict concurrency. All state is either `let` or local to
/// each test function — zero shared mutable state.
@Suite("CSVParser Tests")
struct CSVParserTests {

    /// The parser instance under test — stateless value type, trivially Sendable.
    let parser = CSVParser()

    // MARK: - Helper Methods

    /// Creates a temporary CSV file with the given content and returns its path.
    ///
    /// Each file gets a UUID-based name to prevent cross-test interference
    /// when tests run concurrently. The caller is responsible for cleanup
    /// via ``removeTempFile(at:)``.
    ///
    /// - Parameter content: The raw CSV string to write.
    /// - Returns: Absolute path to the temporary file.
    /// - Throws: File I/O errors if the temp directory is not writable.
    private func createTempCSVFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).csv"
        let filePath = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    /// Removes a temporary file if it exists. Silently ignores failures
    /// (e.g. if the file was already deleted or never created).
    private func removeTempFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Standard valid CSV header for reference data with all 7 required columns.
    private var validHeader: String {
        "ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date"
    }

    /// Generates a valid CSV data row with realistic NYSE equity data.
    ///
    /// All default values produce a row that passes every CSVParser validation:
    /// ticker is 3-5 uppercase letters, prices are positive Decimals, date is
    /// yyyy-MM-dd format.
    private func validRow(
        ticker: String = "AAPL",
        name: String = "Apple Inc.",
        sodBid: String = "149.50",
        sodAsk: String = "150.00",
        eodBid: String = "151.00",
        eodAsk: String = "151.50",
        marketDate: String = "2026-04-14"
    ) -> String {
        "\(ticker),\(name),\(sodBid),\(sodAsk),\(eodBid),\(eodAsk),\(marketDate)"
    }

    /// Generates a valid NYSE-style ticker symbol from an index.
    ///
    /// Produces unique 3-letter uppercase ASCII tickers by encoding the index
    /// in base-26 (A=0, B=1, ..., Z=25). Supports up to 17,576 unique tickers.
    ///
    /// - Parameter index: Zero-based index (0 → "AAA", 1 → "AAB", ...).
    /// - Returns: A 3-character uppercase ticker string.
    private func generateTicker(for index: Int) -> String {
        let c0 = UnicodeScalar(UInt8(65 + (index / 676) % 26))
        let c1 = UnicodeScalar(UInt8(65 + (index / 26) % 26))
        let c2 = UnicodeScalar(UInt8(65 + index % 26))
        return String(c0) + String(c1) + String(c2)
    }

    // =========================================================================
    // MARK: - Phase 4: Header Validation Tests
    // =========================================================================

    @Test("Valid header with all required columns is accepted")
    func testValidHeaderAccepted() throws {
        let headers = [
            "ticker", "name", "sod_bid", "sod_ask",
            "eod_bid", "eod_ask", "market_date",
        ]
        let columnMap = try parser.validateReferenceDataHeaders(headers)
        #expect(columnMap.count == 7)
        #expect(columnMap["ticker"] == 0)
        #expect(columnMap["name"] == 1)
        #expect(columnMap["sod_bid"] == 2)
        #expect(columnMap["sod_ask"] == 3)
        #expect(columnMap["eod_bid"] == 4)
        #expect(columnMap["eod_ask"] == 5)
        #expect(columnMap["market_date"] == 6)
    }

    @Test("Headers in different order are correctly mapped")
    func testHeaderDifferentOrder() throws {
        let headers = [
            "market_date", "eod_ask", "eod_bid",
            "sod_ask", "sod_bid", "name", "ticker",
        ]
        let columnMap = try parser.validateReferenceDataHeaders(headers)
        #expect(columnMap["market_date"] == 0)
        #expect(columnMap["eod_ask"] == 1)
        #expect(columnMap["eod_bid"] == 2)
        #expect(columnMap["sod_ask"] == 3)
        #expect(columnMap["sod_bid"] == 4)
        #expect(columnMap["name"] == 5)
        #expect(columnMap["ticker"] == 6)
    }

    @Test("Headers with extra whitespace are trimmed and accepted")
    func testHeaderWithWhitespace() throws {
        let headers = [
            " ticker ", " name", "sod_bid ",
            " sod_ask ", "eod_bid", "eod_ask", "market_date",
        ]
        let columnMap = try parser.validateReferenceDataHeaders(headers)
        #expect(columnMap.count == 7)
        #expect(columnMap["ticker"] != nil)
        #expect(columnMap["name"] != nil)
        #expect(columnMap["sod_ask"] != nil)
    }

    @Test("Missing required column throws error")
    func testMissingRequiredColumn() throws {
        // Missing market_date — only 6 of 7 required columns
        let headers = [
            "ticker", "name", "sod_bid", "sod_ask", "eod_bid", "eod_ask",
        ]
        #expect(throws: (any Error).self) {
            try parser.validateReferenceDataHeaders(headers)
        }
    }

    @Test("Column names are matched case-insensitively")
    func testHeaderCaseInsensitive() throws {
        let headers = [
            "TICKER", "Name", "SOD_BID", "sod_ask",
            "Eod_Bid", "EOD_ASK", "Market_Date",
        ]
        let columnMap = try parser.validateReferenceDataHeaders(headers)
        #expect(columnMap.count == 7)
        #expect(columnMap["ticker"] != nil)
        #expect(columnMap["market_date"] != nil)
    }

    @Test("Completely wrong headers throws error")
    func testWrongHeaders() throws {
        let headers = ["col1", "col2", "col3"]
        #expect(throws: (any Error).self) {
            try parser.validateReferenceDataHeaders(headers)
        }
    }

    @Test("Empty headers array throws error")
    func testEmptyHeaders() throws {
        let headers: [String] = []
        #expect(throws: (any Error).self) {
            try parser.validateReferenceDataHeaders(headers)
        }
    }

    // =========================================================================
    // MARK: - Phase 5: Row Parsing and Full CSV File Parsing
    // =========================================================================

    @Test("Parse a valid reference data CSV file with multiple rows")
    func testParseValidCSV() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,149.50,150.00,151.00,151.50,2026-04-14
        MSFT,Microsoft Corporation,380.00,380.50,382.00,382.50,2026-04-14
        GOOG,Alphabet Inc.,175.00,175.50,176.00,176.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 3)
        #expect(records[0].ticker == "AAPL")
        #expect(records[0].name == "Apple Inc.")
        #expect(records[0].sodBid == Decimal(string: "149.50"))
        #expect(records[0].sodAsk == Decimal(string: "150.00"))
        #expect(records[0].eodBid == Decimal(string: "151.00"))
        #expect(records[0].eodAsk == Decimal(string: "151.50"))
        #expect(records[1].ticker == "MSFT")
        #expect(records[2].ticker == "GOOG")
    }

    @Test("Parse a valid single-row CSV file")
    func testParseSingleRow() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        TSLA,Tesla Inc.,180.00,180.50,182.00,182.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        #expect(records[0].ticker == "TSLA")
        #expect(records[0].name == "Tesla Inc.")
    }

    @Test("Parsed fields have correct Decimal types for prices")
    func testParsedFieldTypes() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,149.500000,150.000000,151.000000,151.500000,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        // Verify Decimal precision is preserved — trailing zeros do not affect
        // numeric equality.
        let record = records[0]
        #expect(record.sodBid == Decimal(string: "149.500000"))
        #expect(record.sodAsk == Decimal(string: "150.000000"))
        #expect(record.eodBid == Decimal(string: "151.000000"))
        #expect(record.eodAsk == Decimal(string: "151.500000"))
    }

    // =========================================================================
    // MARK: - Phase 6: Malformed CSV Handling
    // =========================================================================

    @Test("Non-numeric price field throws error")
    func testInvalidPriceField() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,NOT_A_NUMBER,150.00,151.00,151.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("Zero price field throws error per Rule 6")
    func testZeroPriceField() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,0.00,150.00,151.00,151.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("Invalid date format throws error")
    func testInvalidDateFormat() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,149.50,150.00,151.00,151.50,14-04-2026
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("Row with fewer columns than expected throws error")
    func testMalformedRowMissingFields() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,149.50,150.00
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("CSV with incorrect header throws error")
    func testIncorrectHeader() throws {
        let csvContent = """
        symbol,company,open_bid,open_ask,close_bid,close_ask,date
        AAPL,Apple Inc.,149.50,150.00,151.00,151.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("Negative price values throw error")
    func testNegativePriceValues() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,-149.50,150.00,151.00,151.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    // =========================================================================
    // MARK: - Phase 7: Empty File Handling
    // =========================================================================

    @Test("Empty file throws CSVParseError gracefully")
    func testEmptyFile() throws {
        let csvContent = ""
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        // Empty file produces zero lines → CSVParser throws .emptyFile.
        // We accept either an empty result or a descriptive CSVParseError.
        do {
            let records = try parser.parseReferenceDataCSV(at: filePath)
            #expect(records.isEmpty)
        } catch {
            #expect(error is CSVParser.CSVParseError)
        }
    }

    @Test("CSV with only header row throws emptyFile error")
    func testHeaderOnlyFile() throws {
        let csvContent = "ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date\n"
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        // The implementation considers a header-only file as having no data,
        // and throws CSVParseError.emptyFile rather than returning an empty array.
        #expect(throws: CSVParser.CSVParseError.self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    // =========================================================================
    // MARK: - Phase 8: File Not Found
    // =========================================================================

    @Test("Non-existent file path throws fileNotFound error")
    func testFileNotFound() throws {
        let nonExistentPath = "/tmp/non_existent_\(UUID().uuidString).csv"
        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: nonExistentPath)
        }
    }

    // =========================================================================
    // MARK: - Phase 9: Edge Cases
    // =========================================================================

    @Test("Quoted fields containing commas are parsed correctly")
    func testQuotedFieldsWithCommas() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        BRK,"Berkshire Hathaway, Inc.",300.00,300.50,302.00,302.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        #expect(records[0].name == "Berkshire Hathaway, Inc.")
        #expect(records[0].ticker == "BRK")
    }

    @Test("Extra whitespace in field values is trimmed")
    func testExtraWhitespaceInFields() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
         AAPL , Apple Inc. , 149.50 , 150.00 , 151.00 , 151.50 , 2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        #expect(records[0].ticker == "AAPL")
        #expect(records[0].name == "Apple Inc.")
    }

    @Test("Special characters in company name are preserved")
    func testSpecialCharactersInName() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        ACME,"ACME Corp. & Partners (Ltd.)",100.00,100.50,102.00,102.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        #expect(records[0].name == "ACME Corp. & Partners (Ltd.)")
    }

    @Test("Escaped double quotes inside quoted fields are handled")
    func testEscapedDoubleQuotes() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        TEST,"Company ""Nickname"" Inc.",100.00,100.50,102.00,102.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1)
        #expect(records[0].name.contains("Nickname"))
    }

    @Test("CSV with CRLF line endings is parsed correctly")
    func testCRLFLineEndings() throws {
        // Explicitly build CRLF-terminated content (not using multi-line literal
        // because Swift normalises line endings within string literals).
        let csvContent =
            "ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date\r\n"
            + "AAPL,Apple Inc.,149.50,150.00,151.00,151.50,2026-04-14\r\n"
            + "MSFT,Microsoft Corporation,380.00,380.50,382.00,382.50,2026-04-14\r\n"
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 2)
        #expect(records[0].ticker == "AAPL")
        #expect(records[1].ticker == "MSFT")
    }

    // =========================================================================
    // MARK: - Phase 10: Large File Pagination (Rule 7)
    // =========================================================================

    @Test("CSV with over 1000 rows is parsed successfully with pagination support")
    func testLargeCSVPagination() throws {
        // Generate 1,500 rows with valid 3-letter uppercase tickers.
        // CSVParser internally batches at AppConstants.batchSize (1,000).
        var lines = [validHeader]
        for i in 0..<1500 {
            let ticker = generateTicker(for: i)
            let base = Decimal(100) + Decimal(i) / Decimal(100)
            let baseStr = "\(base)"
            let askStr = "\(base + Decimal(string: "0.50")!)"
            let eodBidStr = "\(base + Decimal(1))"
            let eodAskStr = "\(base + Decimal(string: "1.50")!)"
            lines.append(
                "\(ticker),Company \(i),\(baseStr),\(askStr),"
                    + "\(eodBidStr),\(eodAskStr),2026-04-14"
            )
        }
        let csvContent = lines.joined(separator: "\n")
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 1500)
        #expect(records[0].ticker == "AAA")
        #expect(records[1499].ticker == generateTicker(for: 1499))
    }

    @Test("CSV with exactly 500 rows (Rule 6 minimum) parses successfully")
    func testMinimumReferenceDataCount() throws {
        var lines = [validHeader]
        for i in 0..<500 {
            let ticker = generateTicker(for: i)
            let base = Decimal(50) + Decimal(i) / Decimal(10)
            let baseStr = "\(base)"
            let askStr = "\(base + Decimal(string: "0.50")!)"
            let eodBidStr = "\(base + Decimal(1))"
            let eodAskStr = "\(base + Decimal(string: "1.50")!)"
            lines.append(
                "\(ticker),Synthetic Corp \(i),\(baseStr),\(askStr),"
                    + "\(eodBidStr),\(eodAskStr),2026-04-14"
            )
        }
        let csvContent = lines.joined(separator: "\n")
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let records = try parser.parseReferenceDataCSV(at: filePath)
        #expect(records.count == 500)
    }

    // =========================================================================
    // MARK: - Phase 11: Generic CSV Parsing (parseCSV)
    // =========================================================================

    @Test("Generic parseCSV returns correct headers and rows")
    func testGenericCSVParsing() throws {
        let csvContent = """
        col_a,col_b,col_c
        val1,val2,val3
        val4,val5,val6
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        let result = try parser.parseCSV(at: filePath)
        #expect(result.headers == ["col_a", "col_b", "col_c"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["val1", "val2", "val3"])
        #expect(result.rows[1] == ["val4", "val5", "val6"])
    }

    // =========================================================================
    // MARK: - Phase 12: Multiple Price Validation Errors
    // =========================================================================

    @Test("All-zero price fields are rejected")
    func testAllZeroPrices() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        ZERO,Zero Corp,0.00,0.00,0.00,0.00,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }

    @Test("Empty string in price field throws error")
    func testEmptyPriceField() throws {
        let csvContent = """
        ticker,name,sod_bid,sod_ask,eod_bid,eod_ask,market_date
        AAPL,Apple Inc.,,150.00,151.00,151.50,2026-04-14
        """
        let filePath = try createTempCSVFile(content: csvContent)
        defer { removeTempFile(at: filePath) }

        #expect(throws: (any Error).self) {
            try parser.parseReferenceDataCSV(at: filePath)
        }
    }
}
