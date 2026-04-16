-- Migration 004: Create Accounts Table
-- Central entity for institutional and wealth management accounts.
-- Supports 100,000 accounts with cached valuation (Rule 11),
-- per-account IANA timezone (Rule 3), and fund type classification.
-- FK to account_groups (Rule 10).

CREATE TABLE IF NOT EXISTS accounts (
    id                       BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    account_name             VARCHAR(255)    NOT NULL CHECK (CHAR_LENGTH(account_name) > 0),
    account_group_id         BIGINT UNSIGNED NOT NULL,
    fund_type                ENUM('open_mutual_fund', 'closed_mutual_fund', 'etf', 'hedge_fund', 'sma', 'uma') NOT NULL,
    account_status           ENUM('active', 'inactive', 'pending', 'suspended') NOT NULL DEFAULT 'pending',
    ownership_details        TEXT,
    valuation_timezone       VARCHAR(64)     NOT NULL DEFAULT 'America/New_York',
    valuation_schedule       VARCHAR(255),
    cached_valuation_amount  DECIMAL(20,6)   DEFAULT NULL,
    cached_value_date        DATE            DEFAULT NULL,
    created_at               TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT fk_accounts_account_group FOREIGN KEY (account_group_id) REFERENCES account_groups(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
