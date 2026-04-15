-- Migration 008: Create Indexes (Idempotent)
-- Creates composite and single-column indexes for search optimization
-- and performance thresholds (Rule 13).
-- Depends on: 001-007 (all tables must exist)
--
-- Index naming convention: idx_[tablename]_[column(s)]
-- All indexes use the default B-tree algorithm (MySQL 8.0 InnoDB).
--
-- Idempotency: MySQL 8.0 does not support CREATE INDEX IF NOT EXISTS.
-- Each index creation is guarded by a conditional check against
-- INFORMATION_SCHEMA.STATISTICS so that re-running this script
-- (e.g., during manual database recovery or setup script re-runs)
-- produces zero errors. The pattern is:
--   1. SET @exists  = count of matching index rows in INFORMATION_SCHEMA.
--   2. SET @sql     = IF already present then no-op ELSE CREATE INDEX.
--   3. PREPARE / EXECUTE / DEALLOCATE the dynamic statement.

-- ============================================================================
-- ACCOUNTS TABLE INDEXES
-- Supports Rule 13: Full-universe search across 100,000 accounts in < 2 seconds.
-- ============================================================================

-- idx_accounts_name: Partial name match using LIKE 'prefix%' leverages B-tree prefix scanning.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND INDEX_NAME = 'idx_accounts_name');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_accounts_name ON accounts (account_name)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_accounts_fund_type: Fund type filtering (open_mutual_fund, closed_mutual_fund, etf, hedge_fund, sma, uma).
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND INDEX_NAME = 'idx_accounts_fund_type');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_accounts_fund_type ON accounts (fund_type)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_accounts_group: Account group filtering and entitlement-scoped queries.
-- Complements FK fk_accounts_account_group from migration 004.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND INDEX_NAME = 'idx_accounts_group');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_accounts_group ON accounts (account_group_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_accounts_status: Status-based filtering (active, inactive, pending, suspended).
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND INDEX_NAME = 'idx_accounts_status');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_accounts_status ON accounts (account_status)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================
-- POSITIONS TABLE INDEXES
-- Supports per-account position lookups for valuation and Accounts Viewer.
-- ============================================================================

-- idx_positions_account: Per-account position retrieval for NAV valuation and UI display.
-- Complements FK fk_positions_account from migration 006.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'positions' AND INDEX_NAME = 'idx_positions_account');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_positions_account ON positions (account_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_positions_instrument: Instrument-based lookups for cross-account position aggregation.
-- Complements FK fk_positions_instrument from migration 006.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'positions' AND INDEX_NAME = 'idx_positions_instrument');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_positions_instrument ON positions (instrument_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================
-- TRANSACTIONS TABLE INDEXES
-- Supports per-account transaction history and time-range queries on the
-- immutable append-only ledger (Rule 1, Rule 2).
-- ============================================================================

-- idx_transactions_account: Per-account transaction history retrieval.
-- Complements FK fk_transactions_account from migration 007.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'transactions' AND INDEX_NAME = 'idx_transactions_account');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_transactions_account ON transactions (account_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_transactions_created: Time-range queries on the immutable transaction log.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'transactions' AND INDEX_NAME = 'idx_transactions_created');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_transactions_created ON transactions (created_at)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================
-- REFERENCE DATA TABLE INDEXES
-- Supports ticker-based and date-based EOD price lookups for valuation.
-- ============================================================================

-- idx_reference_data_ticker: Single-column ticker index for ticker-only lookups.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reference_data' AND INDEX_NAME = 'idx_reference_data_ticker');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_reference_data_ticker ON reference_data (ticker)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_reference_data_date: Single-column date index for date-range queries.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reference_data' AND INDEX_NAME = 'idx_reference_data_date');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_reference_data_date ON reference_data (market_date)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_reference_data_ticker_date: Composite covering index for the most common valuation
-- query pattern: SELECT eod_bid, eod_ask FROM reference_data WHERE ticker = ? AND market_date = ?
-- This index satisfies the query without a table lookup when combined with
-- the UNIQUE KEY uk_reference_data_ticker_date from migration 005.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reference_data' AND INDEX_NAME = 'idx_reference_data_ticker_date');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_reference_data_ticker_date ON reference_data (ticker, market_date)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================
-- ENTITLEMENTS TABLE INDEXES
-- Supports per-user and per-group entitlement queries for RBAC (Rule 4).
-- ============================================================================

-- idx_entitlements_user: Per-user entitlement lookups (e.g., "what groups can this user access?").
-- Complements UNIQUE KEY uk_entitlements_user_group from migration 003.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'entitlements' AND INDEX_NAME = 'idx_entitlements_user');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_entitlements_user ON entitlements (user_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- idx_entitlements_group: Per-group entitlement lookups (e.g., "which users have access to this group?").
-- Complements FK fk_entitlements_account_group from migration 003.
SET @exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'entitlements' AND INDEX_NAME = 'idx_entitlements_group');
SET @sql = IF(@exists > 0, 'SELECT 1', 'CREATE INDEX idx_entitlements_group ON entitlements (account_group_id)');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
