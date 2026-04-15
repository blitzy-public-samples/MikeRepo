// ReferenceData.swift
// Sources/ReferenceDataService/Models/ReferenceData.swift
//
// NYSE equity reference data model for the WealthLedger accounting engine.
// Foundational type consumed by ReferenceDataService, ValuationEngine, and
// Persistence modules.
//
// Each record represents one NYSE equity security on one market date with
// six price fields (SOD bid/ask, EOD bid/ask) using Decimal for exact
// financial arithmetic matching MySQL DECIMAL(20,6) columns.

import Foundation
import Shared

// MARK: - ReferenceData

/// Represents a single NYSE equity reference data record containing price
/// information for a specific market date.
///
/// This is the foundational data model for the `ReferenceDataService` module.
/// Each record contains six price fields (SOD bid/ask, EOD bid/ask) for one
/// equity security on one market date. All price fields use `Decimal` for
/// exact financial arithmetic matching the MySQL `DECIMAL(20,6)` column type
/// defined in `005_create_reference_data.sql`.
///
/// ## Consumers
///
/// - **ReferenceDataService**: `CSVParser`, `CSVExporter`,
///   `SyntheticDataGenerator`, `ReferenceDataService` all operate on this type.
/// - **ValuationEngine**: `NAVCalculator` uses `eodMidpoint` in the valuation
///   formula `Σ(quantity × EOD midpoint) + cash balance`.
/// - **Persistence**: `ReferenceDataRepository` maps MySQL rows to and from
///   this struct.
///
/// ## Concurrency Safety
///
/// Conforms to `Sendable` for Swift 6 strict concurrency (Gate 2).
/// As a pure value type with all `Sendable`-conforming stored properties
/// (`UInt64`, `String`, `Decimal`, `Date`) and no mutable state, the
/// conformance is trivially correct.
///
/// ## MySQL Schema Alignment
///
/// | Swift Property | MySQL Column   | MySQL Type                              |
/// |---------------|----------------|-----------------------------------------|
/// | `id`          | `id`           | `BIGINT UNSIGNED AUTO_INCREMENT PK`     |
/// | `ticker`      | `ticker`       | `VARCHAR(10) NOT NULL`                  |
/// | `name`        | `name`         | `VARCHAR(255) NOT NULL`                 |
/// | `sodBid`      | `sod_bid`      | `DECIMAL(20,6) NOT NULL`                |
/// | `sodAsk`      | `sod_ask`      | `DECIMAL(20,6) NOT NULL`                |
/// | `eodBid`      | `eod_bid`      | `DECIMAL(20,6) NOT NULL`                |
/// | `eodAsk`      | `eod_ask`      | `DECIMAL(20,6) NOT NULL`                |
/// | `marketDate`  | `market_date`  | `DATE NOT NULL`                         |
public struct ReferenceData: Sendable, Equatable, Hashable {

    // MARK: - Stored Properties

    /// Unique identifier assigned by MySQL on insert.
    ///
    /// Corresponds to `BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY` in the
    /// `reference_data` table. Always present when reading from the database.
    public let id: UInt64

    /// NYSE equity ticker symbol, typically 3–5 uppercase letters.
    ///
    /// Examples: `"AAPL"`, `"MSFT"`, `"GOOG"`.
    /// Stored as `VARCHAR(10) NOT NULL` in MySQL.
    public let ticker: String

    /// Human-readable company name.
    ///
    /// Examples: `"Apple Inc."`, `"Microsoft Corporation"`.
    /// Stored as `VARCHAR(255) NOT NULL` in MySQL.
    public let name: String

    /// Start-of-day bid price.
    ///
    /// Uses `Decimal` for exact financial arithmetic matching the MySQL
    /// `DECIMAL(20,6)` column type. Must be non-null and non-zero when
    /// populated (Rule 6 — Reference Data Simulation Fidelity).
    public let sodBid: Decimal

    /// Start-of-day ask price.
    ///
    /// Uses `Decimal` for exact financial arithmetic matching the MySQL
    /// `DECIMAL(20,6)` column type. Must be non-null and non-zero when
    /// populated (Rule 6 — Reference Data Simulation Fidelity).
    public let sodAsk: Decimal

    /// End-of-day bid price.
    ///
    /// Uses `Decimal` for exact financial arithmetic matching the MySQL
    /// `DECIMAL(20,6)` column type. Must be non-null and non-zero when
    /// populated (Rule 6 — Reference Data Simulation Fidelity).
    public let eodBid: Decimal

    /// End-of-day ask price.
    ///
    /// Uses `Decimal` for exact financial arithmetic matching the MySQL
    /// `DECIMAL(20,6)` column type. Must be non-null and non-zero when
    /// populated (Rule 6 — Reference Data Simulation Fidelity).
    public let eodAsk: Decimal

    /// The market date for this price record.
    ///
    /// Stored as `DATE NOT NULL` in MySQL. Represents the trading day for
    /// which the SOD and EOD prices apply.
    public let marketDate: Date

    // MARK: - Computed Properties

    /// End-of-day midpoint price: `(eodBid + eodAsk) / 2`.
    ///
    /// Computed using `Decimal.midpoint(bid:ask:)` from the `Shared` module's
    /// `Decimal+Currency` extension, ensuring exact decimal arithmetic with no
    /// floating-point rounding.
    ///
    /// This value is consumed by `NAVCalculator` in the `ValuationEngine`
    /// module for the NAV valuation formula:
    ///
    /// ```
    /// NAV = Σ(quantity × EOD midpoint) + cash balance
    /// ```
    public var eodMidpoint: Decimal {
        Decimal.midpoint(bid: eodBid, ask: eodAsk)
    }

    /// Start-of-day midpoint price: `(sodBid + sodAsk) / 2`.
    ///
    /// Computed using `Decimal.midpoint(bid:ask:)` from the `Shared` module's
    /// `Decimal+Currency` extension, ensuring exact decimal arithmetic with no
    /// floating-point rounding.
    public var sodMidpoint: Decimal {
        Decimal.midpoint(bid: sodBid, ask: sodAsk)
    }

    // MARK: - Initializer

    /// Creates a new reference data record.
    ///
    /// All six price fields (`sodBid`, `sodAsk`, `eodBid`, `eodAsk`) should
    /// be non-zero when representing valid market data (Rule 6).
    ///
    /// - Parameters:
    ///   - id: Unique identifier (`BIGINT UNSIGNED` in MySQL).
    ///   - ticker: NYSE equity ticker symbol (3–5 uppercase letters).
    ///   - name: Human-readable company name.
    ///   - sodBid: Start-of-day bid price (`DECIMAL(20,6)` in MySQL).
    ///   - sodAsk: Start-of-day ask price (`DECIMAL(20,6)` in MySQL).
    ///   - eodBid: End-of-day bid price (`DECIMAL(20,6)` in MySQL).
    ///   - eodAsk: End-of-day ask price (`DECIMAL(20,6)` in MySQL).
    ///   - marketDate: The trading date for this price record.
    public init(
        id: UInt64,
        ticker: String,
        name: String,
        sodBid: Decimal,
        sodAsk: Decimal,
        eodBid: Decimal,
        eodAsk: Decimal,
        marketDate: Date
    ) {
        self.id = id
        self.ticker = ticker
        self.name = name
        self.sodBid = sodBid
        self.sodAsk = sodAsk
        self.eodBid = eodBid
        self.eodAsk = eodAsk
        self.marketDate = marketDate
    }
}
