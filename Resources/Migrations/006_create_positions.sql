-- Migration 006: Create Positions Table
-- Tracks per-account instrument holdings.
-- Asset type restricted to equities only (Rule 5).
-- FKs to accounts and reference_data (Rule 10).

CREATE TABLE IF NOT EXISTS positions (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    account_id      BIGINT UNSIGNED     NOT NULL,
    instrument_id   BIGINT UNSIGNED     NOT NULL,
    quantity        DECIMAL(20,6)       NOT NULL DEFAULT 0.000000,
    asset_type      ENUM('equity')      NOT NULL DEFAULT 'equity',
    created_at      TIMESTAMP           NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP           NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT fk_positions_account    FOREIGN KEY (account_id)    REFERENCES accounts(id),
    CONSTRAINT fk_positions_instrument FOREIGN KEY (instrument_id) REFERENCES reference_data(id),

    UNIQUE KEY uk_positions_account_instrument (account_id, instrument_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
