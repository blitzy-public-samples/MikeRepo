-- Migration 008: Create Indexes
-- Creates composite and single-column indexes for search optimization
-- and performance thresholds (Rule 13).
-- Depends on: 001-007 (all tables must exist)
--
-- Index naming convention: idx_[tablename]_[column(s)]
-- All indexes use the default B-tree algorithm (MySQL 8.0 InnoDB).
--
-- Idempotency: The MigrationManager tracks applied migrations in the
-- _migrations table, so this script is only executed once per schema.
-- Direct CREATE INDEX statements are used because MySQL 8.0 does not
-- support CREATE INDEX IF NOT EXISTS, and the PREPARE/EXECUTE dynamic
-- SQL approach is incompatible with the MySQL binary protocol used by
-- MySQLKit/SQLKit.

-- ============================================================================
-- ACCOUNTS TABLE INDEXES
-- Supports Rule 13: Full-universe search across 100,000 accounts in < 2 seconds.
-- ============================================================================

-- idx_accounts_name: Partial name match using LIKE 'prefix%' leverages B-tree prefix scanning.
CREATE INDEX idx_accounts_name ON accounts (account_name);

-- idx_accounts_fund_type: Fund type filtering (open_mutual_fund, closed_mutual_fund, etf, hedge_fund, sma, uma).
CREATE INDEX idx_accounts_fund_type ON accounts (fund_type);

-- idx_accounts_group: Account group filtering and entitlement-scoped queries.
-- Complements FK fk_accounts_account_group from migration 004.
CREATE INDEX idx_accounts_group ON accounts (account_group_id);

-- idx_accounts_status: Status-based filtering (active, inactive, pending, suspended).
CREATE INDEX idx_accounts_status ON accounts (account_status);

-- ============================================================================
-- POSITIONS TABLE INDEXES
-- Supports per-account position lookups for valuation and Accounts Viewer.
-- ============================================================================

-- idx_positions_account: Per-account position retrieval for NAV valuation and UI display.
-- Complements FK fk_positions_account from migration 006.
CREATE INDEX idx_positions_account ON positions (account_id);

-- idx_positions_instrument: Instrument-based lookups for cross-account position aggregation.
-- Complements FK fk_positions_instrument from migration 006.
CREATE INDEX idx_positions_instrument ON positions (instrument_id);

-- ============================================================================
-- TRANSACTIONS TABLE INDEXES
-- Supports per-account transaction history and time-range queries on the
-- immutable append-only ledger (Rule 1, Rule 2).
-- ============================================================================

-- idx_transactions_account: Per-account transaction history retrieval.
-- Complements FK fk_transactions_account from migration 007.
CREATE INDEX idx_transactions_account ON transactions (account_id);

-- idx_transactions_created: Time-range queries on the immutable transaction log.
CREATE INDEX idx_transactions_created ON transactions (created_at);

-- ============================================================================
-- REFERENCE DATA TABLE INDEXES
-- Supports ticker-based and date-based EOD price lookups for valuation.
-- ============================================================================

-- idx_reference_data_ticker: Single-column ticker index for ticker-only lookups.
CREATE INDEX idx_reference_data_ticker ON reference_data (ticker);

-- idx_reference_data_date: Single-column date index for date-range queries.
CREATE INDEX idx_reference_data_date ON reference_data (market_date);

-- idx_reference_data_ticker_date: Composite covering index for the most common valuation
-- query pattern: SELECT eod_bid, eod_ask FROM reference_data WHERE ticker = ? AND market_date = ?
CREATE INDEX idx_reference_data_ticker_date ON reference_data (ticker, market_date);

-- ============================================================================
-- ENTITLEMENTS TABLE INDEXES
-- Supports per-user and per-group entitlement queries for RBAC (Rule 4).
-- ============================================================================

-- idx_entitlements_user: Per-user entitlement lookups (e.g., "what groups can this user access?").
-- Complements UNIQUE KEY uk_entitlements_user_group from migration 003.
CREATE INDEX idx_entitlements_user ON entitlements (user_id);

-- idx_entitlements_group: Per-group entitlement lookups (e.g., "which users have access to this group?").
-- Complements FK fk_entitlements_account_group from migration 003.
CREATE INDEX idx_entitlements_group ON entitlements (account_group_id);
