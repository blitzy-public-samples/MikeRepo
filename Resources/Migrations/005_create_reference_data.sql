-- Migration 005: Create Reference Data Table
-- Stores simulated NYSE equity data with 6 price fields per security.
-- Minimum 500 synthetic securities (Rule 6).
-- EOD prices used by NAVCalculator for valuation.
-- Referenced by: positions (migration 006), transactions (migration 007).

CREATE TABLE IF NOT EXISTS reference_data (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticker      VARCHAR(10)     NOT NULL,
    name        VARCHAR(255)    NOT NULL,
    sod_bid     DECIMAL(20,6)   NOT NULL,
    sod_ask     DECIMAL(20,6)   NOT NULL,
    eod_bid     DECIMAL(20,6)   NOT NULL,
    eod_ask     DECIMAL(20,6)   NOT NULL,
    market_date DATE            NOT NULL,
    created_at  TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE KEY uk_reference_data_ticker_date (ticker, market_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
