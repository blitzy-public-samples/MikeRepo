-- Migration 007: Create Transactions Table
-- Append-only immutable transaction log for the general ledger.
-- Corrections via offsetting entries only (Rule 1, Rule 2).
-- No UPDATE or DELETE permitted at application layer.
-- FKs to accounts (004), reference_data (005), and self-referencing for restatements.

CREATE TABLE IF NOT EXISTS transactions (
    id                  BIGINT UNSIGNED     AUTO_INCREMENT PRIMARY KEY,
    account_id          BIGINT UNSIGNED     NOT NULL,
    instrument_id       BIGINT UNSIGNED     DEFAULT NULL,
    quantity            DECIMAL(20,6)       NOT NULL,
    asset_type          ENUM('equity')      NOT NULL DEFAULT 'equity',
    ownership_pct       DECIMAL(10,6)       DEFAULT NULL,
    debit_amount        DECIMAL(20,6)       NOT NULL DEFAULT 0.000000,
    credit_amount       DECIMAL(20,6)       NOT NULL DEFAULT 0.000000,
    restatement_ref_id  BIGINT UNSIGNED     DEFAULT NULL,
    description         VARCHAR(500)        DEFAULT NULL,
    created_at          TIMESTAMP           NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_transactions_account     FOREIGN KEY (account_id)         REFERENCES accounts(id),
    CONSTRAINT fk_transactions_instrument  FOREIGN KEY (instrument_id)      REFERENCES reference_data(id),
    CONSTRAINT fk_transactions_restatement FOREIGN KEY (restatement_ref_id) REFERENCES transactions(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
