// SyntheticDataGenerator.swift
// Sources/ReferenceDataService/Generators/SyntheticDataGenerator.swift
//
// Generates 500+ synthetic NYSE equity reference data records for seeding
// the `reference_data` MySQL table. All data is algorithmically generated
// — zero real or external market data is used (Rule 9 — Offline Runtime).
//
// Prices use Decimal arithmetic exclusively for exact financial precision
// matching MySQL DECIMAL(20,6) columns (Rule 6 — Simulation Fidelity).

import Foundation

// MARK: - SyntheticDataGenerator

/// Generates synthetic NYSE equity reference data for populating the
/// `reference_data` table.
///
/// Produces at least 500 synthetic securities, each with a unique ticker
/// symbol (3–5 uppercase letters), a realistic company name, and four stored
/// price fields (SOD bid/ask, EOD bid/ask). All data is generated
/// algorithmically using local random number generation — no real or
/// external market data is used (Rule 9).
///
/// ## Usage
///
/// ```swift
/// let generator = SyntheticDataGenerator()
/// let records = generator.generate(marketDate: someDate)
/// // records.count >= 500
/// ```
///
/// ## Concurrency Safety
///
/// Conforms to `Sendable` for Swift 6 strict concurrency (Gate 2).
/// The struct has zero stored properties and all methods are pure functions
/// operating on local variables only — trivially `Sendable`.
public struct SyntheticDataGenerator: Sendable {

    // MARK: - Word Pools for Company Name Generation

    /// Prefix words for realistic company name generation (40 entries).
    private static let prefixWords: [String] = [
        "Alpha", "Beta", "Global", "Pacific", "Atlantic",
        "Northern", "Southern", "Eastern", "Western", "United",
        "National", "American", "Liberty", "Summit", "Pinnacle",
        "Meridian", "Horizon", "Apex", "Vertex", "Nexus",
        "Quantum", "Sterling", "Premier", "Vanguard", "Frontier",
        "Dynasty", "Cascade", "Evergreen", "Ironwood", "Silverstone",
        "Cobalt", "Titan", "Atlas", "Phoenix", "Orion",
        "Zenith", "Eclipse", "Nova", "Solaris", "Crimson"
    ]

    /// Suffix words for realistic company name generation (25 entries).
    private static let suffixWords: [String] = [
        "Industries", "Holdings", "Corp", "Group", "Technologies",
        "Systems", "Solutions", "Partners", "Capital", "Ventures",
        "Dynamics", "Enterprises", "Networks", "Resources", "International",
        "Pharmaceuticals", "Biotech", "Energy", "Financial", "Logistics",
        "Media", "Materials", "Services", "Analytics", "Robotics"
    ]

    /// Entity type suffixes for company names (6 entries).
    private static let entityTypes: [String] = [
        "Inc.", "Corp.", "Ltd.", "Co.", "LLC", "PLC"
    ]

    /// Uppercase ASCII letter codes for ticker symbol generation.
    /// Precomputed for efficient random character selection.
    private static let uppercaseLetters: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Minimum number of synthetic securities to generate (Rule 6).
    private static let minimumSecurityCount: Int = 500

    /// Minimum price floor in cents to ensure all prices are positive and
    /// non-zero after clamping. Represents $0.01.
    private static let minimumPriceCents: Int = 1

    // MARK: - Initializer

    /// Creates a new synthetic data generator.
    ///
    /// The generator is stateless — all randomness is local to each
    /// invocation of ``generate(marketDate:)``.
    public init() {}

    // MARK: - Public API

    /// Generates an array of at least 500 synthetic NYSE equity reference
    /// data records.
    ///
    /// Each record has a unique ticker symbol (3–5 uppercase letters), a
    /// realistic company name, and four stored price fields (SOD bid/ask,
    /// EOD bid/ask) computed using exact `Decimal` arithmetic. All six
    /// logical price fields (including the two computed midpoints on
    /// `ReferenceData`) are guaranteed non-null and non-zero.
    ///
    /// Price generation uses `Int.random(in:)` converted to `Decimal` to
    /// avoid floating-point imprecision — `Double.random` is never used.
    ///
    /// - Parameter marketDate: The market date to assign to all generated
    ///   records. Defaults to the current date.
    /// - Returns: An array of `ReferenceData` records with `.count >= 500`.
    ///   Every record satisfies:
    ///   - `sodBid > 0`
    ///   - `sodAsk >= sodBid`
    ///   - `eodBid > 0`
    ///   - `eodAsk >= eodBid`
    public func generate(marketDate: Date = Date()) -> [ReferenceData] {
        let minimumCount = SyntheticDataGenerator.minimumSecurityCount
        var existingTickers = Set<String>()
        existingTickers.reserveCapacity(minimumCount)
        var records: [ReferenceData] = []
        records.reserveCapacity(minimumCount)

        while records.count < minimumCount {
            let ticker = generateTicker(existingTickers: &existingTickers)
            let name = generateCompanyName()
            let prices = generatePrices()

            let record = ReferenceData(
                id: 0, // Placeholder — MySQL AUTO_INCREMENT assigns actual ID
                ticker: ticker,
                name: name,
                sodBid: prices.sodBid,
                sodAsk: prices.sodAsk,
                eodBid: prices.eodBid,
                eodAsk: prices.eodAsk,
                marketDate: marketDate
            )
            records.append(record)
        }

        return records
    }

    // MARK: - Private Helpers

    /// Generates a random unique ticker symbol of 3–5 uppercase letters.
    ///
    /// Uses a `Set<String>` to guarantee uniqueness across all generated
    /// tickers. The ticker space (26^3 + 26^4 + 26^5 ≈ 12.4 million
    /// combinations) vastly exceeds the 500-record minimum, so collisions
    /// are extremely rare but correctly handled via retry.
    ///
    /// - Parameter existingTickers: A set tracking all previously generated
    ///   tickers. The new ticker is inserted before returning.
    /// - Returns: A unique ticker string of 3–5 uppercase ASCII letters.
    private func generateTicker(existingTickers: inout Set<String>) -> String {
        let letters = SyntheticDataGenerator.uppercaseLetters
        let letterCount = letters.count

        while true {
            // Random length between 3 and 5 inclusive
            let length = Int.random(in: 3...5)
            var ticker = ""
            ticker.reserveCapacity(length)

            for _ in 0..<length {
                let index = Int.random(in: 0..<letterCount)
                ticker.append(letters[index])
            }

            // Only accept if unique
            if existingTickers.insert(ticker).inserted {
                return ticker
            }
            // Collision — retry with a new random ticker
        }
    }

    /// Generates a random realistic-sounding company name.
    ///
    /// Combines a randomly selected prefix word, suffix word, and entity
    /// type into the format `"{Prefix} {Suffix}, {Entity}"`.
    ///
    /// Examples: `"Quantum Technologies, Inc."`, `"Atlas Capital, Corp."`
    ///
    /// - Returns: A company name string.
    private func generateCompanyName() -> String {
        let prefixes = SyntheticDataGenerator.prefixWords
        let suffixes = SyntheticDataGenerator.suffixWords
        let entities = SyntheticDataGenerator.entityTypes

        let prefix = prefixes[Int.random(in: 0..<prefixes.count)]
        let suffix = suffixes[Int.random(in: 0..<suffixes.count)]
        let entity = entities[Int.random(in: 0..<entities.count)]

        return "\(prefix) \(suffix), \(entity)"
    }

    /// Generates a set of four stored price fields (SOD bid/ask, EOD
    /// bid/ask) as exact `Decimal` values.
    ///
    /// **Arithmetic strategy**: All intermediate calculations use
    /// `Int.random(in:)` converted to `Decimal` via integer division —
    /// `Double.random` is never used, preventing floating-point imprecision.
    ///
    /// **Price invariants guaranteed**:
    /// - `sodBid > 0`
    /// - `sodAsk >= sodBid` (ask is bid + positive spread)
    /// - `eodBid > 0` (clamped to minimum $0.01)
    /// - `eodAsk >= eodBid` (ask is bid + positive spread)
    ///
    /// - Returns: A named tuple of the four price fields.
    private func generatePrices() -> (
        sodBid: Decimal,
        sodAsk: Decimal,
        eodBid: Decimal,
        eodAsk: Decimal
    ) {
        let oneHundred = Decimal(100)
        let minimumPrice = Decimal(SyntheticDataGenerator.minimumPriceCents) / oneHundred // 0.01

        // Base price: random value in $5.00–$500.00 range (integer cents)
        let baseCents = Int.random(in: 500...50_000)
        let basePrice = Decimal(baseCents) / oneHundred

        // SOD spread: $0.01–$0.50 (ask is always >= bid)
        let sodSpreadCents = Int.random(in: 1...50)
        let sodSpread = Decimal(sodSpreadCents) / oneHundred

        let sodBid = basePrice
        let sodAsk = basePrice + sodSpread

        // Daily price movement: -$5.00 to +$5.00
        let movementCents = Int.random(in: -500...500)
        let movement = Decimal(movementCents) / oneHundred

        // EOD bid: SOD bid + movement, clamped to minimum $0.01
        var eodBid = sodBid + movement
        if eodBid < minimumPrice {
            eodBid = minimumPrice
        }

        // EOD spread: $0.01–$0.50 (ask is always >= bid)
        let eodSpreadCents = Int.random(in: 1...50)
        let eodSpread = Decimal(eodSpreadCents) / oneHundred

        let eodAsk = eodBid + eodSpread

        return (sodBid: sodBid, sodAsk: sodAsk, eodBid: eodBid, eodAsk: eodAsk)
    }
}
