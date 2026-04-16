#!/bin/bash
set -euo pipefail

# =============================================================
# WealthLedger — MySQL 8.0 Database Setup Script
# =============================================================
# This script initializes the MySQL 8.0 database environment
# for the WealthLedger macOS desktop application.
#
# It performs the following steps:
#   1. Verifies Homebrew is installed
#   2. Installs MySQL 8.0 via Homebrew if not present
#   3. Starts the MySQL 8.0 service
#   4. Creates the 'wealth_ledger' database (utf8mb4)
#   5. Creates the application database user with privileges
#   6. Executes all SQL migration scripts in order (001-008)
#   7. Verifies all tables and foreign key constraints
#
# Prerequisites:
#   - macOS with Homebrew installed
#   - No network adapter required (offline operation)
#
# Usage:
#   chmod +x Scripts/setup_database.sh
#   ./Scripts/setup_database.sh
#
# Rules Enforced:
#   - Rule 8:  MySQLKit-only persistence (MySQL is the sole DB)
#   - Rule 9:  Offline runtime (all data sources are local)
#   - Rule 10: Schema referential integrity (FK constraints verified)
# =============================================================

# -------------------------------------------------------------
# Configuration Variables
# -------------------------------------------------------------
# Database connection parameters with environment variable overrides.
# Set DB_USERNAME, DB_PASSWORD, DB_NAME environment variables to
# customize, or use the defaults below. These MUST match the
# MySQLConfiguration in WealthLedgerApp.swift:
#   let dbUsername = ProcessInfo.processInfo.environment["DB_USERNAME"] ?? "wealthledger"
#   let dbPassword = ProcessInfo.processInfo.environment["DB_PASSWORD"] ?? "wealthledger_pass"
#   let dbName     = ProcessInfo.processInfo.environment["DB_NAME"]     ?? "wealth_ledger"
#
# The same environment variable names (DB_USERNAME, DB_PASSWORD, DB_NAME)
# are shared between this setup script and the application runtime to
# ensure credential consistency.
# -------------------------------------------------------------
DB_NAME="${DB_NAME:-wealth_ledger}"
DB_USER="${DB_USERNAME:-wealthledger}"
DB_PASSWORD="${DB_PASSWORD:-wealthledger_pass}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"

# -------------------------------------------------------------
# Script Directory Resolution
# -------------------------------------------------------------
# Resolve absolute paths so the script works correctly regardless
# of the working directory it is invoked from.
# SCRIPT_DIR  = directory containing this script (Scripts/)
# PROJECT_ROOT = repository root (one level above Scripts/)
# MIGRATIONS_DIR = path to the 8 SQL migration files
# -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$PROJECT_ROOT/Resources/Migrations"

# Maximum number of retries when waiting for MySQL to accept connections.
MAX_RETRIES=15
RETRY_INTERVAL=2

echo ""
echo "=============================================="
echo "  WealthLedger — MySQL 8.0 Database Setup"
echo "=============================================="
echo ""

# =============================================================
# Phase 1: MySQL 8.0 Installation Verification
# =============================================================

# --- 1.1 Check Homebrew Availability ---
# Homebrew is required for installing and managing MySQL 8.0
# on macOS. If it is not found, exit with instructions.
if ! command -v brew &> /dev/null; then
    echo "ERROR: Homebrew is not installed."
    echo "       Install from https://brew.sh and re-run this script."
    exit 1
fi
echo "✓ Homebrew is available"

# --- 1.2 Check / Install MySQL 8.0 ---
# The AAP mandates 'mysql@8.0' specifically — not the latest
# unversioned 'mysql' formula. This ensures MySQL 8.0.x.
if ! brew list mysql@8.0 &> /dev/null; then
    echo "  MySQL 8.0 is not installed. Installing via Homebrew..."
    brew install mysql@8.0
    echo "  ✓ MySQL 8.0 installed successfully"
else
    echo "✓ MySQL 8.0 is already installed"
fi

# --- 1.3 Start MySQL 8.0 Service ---
# Use Homebrew services to start the MySQL daemon. If the service
# is already running, this command is a no-op (idempotent).
echo "  Starting MySQL 8.0 service..."
brew services start mysql@8.0 || true
echo "✓ MySQL 8.0 service start requested"

# --- 1.4 Wait for MySQL to Accept Connections ---
# The MySQL server may take a few seconds to bind the socket and
# begin accepting connections after the service start command.
echo "  Waiting for MySQL to be ready..."
RETRIES=0
until mysql -u root -e "SELECT 1" &> /dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        echo "ERROR: MySQL did not become ready after $((MAX_RETRIES * RETRY_INTERVAL)) seconds."
        echo "       Check the MySQL error log: brew services log mysql@8.0"
        exit 1
    fi
    echo "  Waiting for MySQL to accept connections... (attempt ${RETRIES}/${MAX_RETRIES})"
    sleep "$RETRY_INTERVAL"
done
echo "✓ MySQL is accepting connections"

# =============================================================
# Phase 2: Database and User Creation
# =============================================================

echo ""
echo "Setting up database and user..."
echo "----------------------------------------------"

# --- 2.1 Create the 'wealth_ledger' Database ---
# Uses CREATE DATABASE IF NOT EXISTS for idempotency (safe to re-run).
# Character set utf8mb4 with utf8mb4_unicode_ci collation matches
# the ENGINE/CHARSET declarations in all migration scripts.
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
echo "✓ Database '${DB_NAME}' created (or already exists)"

# --- 2.2 Create the Application Database User ---
# CREATE USER IF NOT EXISTS ensures idempotency.
# GRANT ALL PRIVILEGES provides DDL (CREATE TABLE, CREATE INDEX)
# and DML (INSERT, SELECT, UPDATE, DELETE) access required by
# the migration scripts and application runtime.
mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';"
mysql -u root -e "FLUSH PRIVILEGES;"
echo "✓ Database user '${DB_USER}' created with ALL PRIVILEGES on '${DB_NAME}'"

# =============================================================
# Phase 3: Execute Migration Scripts (001-008)
# =============================================================

echo ""
echo "Checking migrations directory..."

# --- 3.1 Verify Migrations Directory Exists ---
if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo "ERROR: Migrations directory not found at:"
    echo "       $MIGRATIONS_DIR"
    echo "       Ensure you are running this script from the project repository."
    exit 1
fi
echo "✓ Migrations directory found at $MIGRATIONS_DIR"

# --- 3.2 Count Available Migrations ---
MIGRATION_COUNT=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name "*.sql" -type f | wc -l | tr -d ' ')
if [ "$MIGRATION_COUNT" -eq 0 ]; then
    echo "ERROR: No SQL migration files found in $MIGRATIONS_DIR"
    exit 1
fi
echo "✓ Found ${MIGRATION_COUNT} migration file(s)"

# --- 3.3 Create Migration Tracking Table ---
# Mirrors the _migrations tracking table created by the Swift MigrationManager
# (Sources/Persistence/MigrationManager.swift). Both the shell script and the
# Swift code use the same tracking table to guarantee idempotent migration
# execution regardless of which entry point runs first.
echo "  Ensuring migration tracking table exists..."
mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e \
    "CREATE TABLE IF NOT EXISTS _migrations (
        id INT AUTO_INCREMENT PRIMARY KEY,
        filename VARCHAR(255) UNIQUE NOT NULL,
        applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );" 2>&1
echo "✓ Migration tracking table ready"

# --- 3.4 Execute All Migration Scripts in Strict Numerical Order ---
# The sort command guarantees execution order: 001 → 002 → ... → 008.
# This ordering is critical because:
#   001_create_users.sql         — no dependencies
#   002_create_account_groups.sql — no dependencies
#   003_create_entitlements.sql  — FKs to users (001), account_groups (002)
#   004_create_accounts.sql      — FK to account_groups (002)
#   005_create_reference_data.sql — no dependencies
#   006_create_positions.sql     — FKs to accounts (004), reference_data (005)
#   007_create_transactions.sql  — FKs to accounts (004), reference_data (005), self-ref
#   008_create_indexes.sql       — all 7 tables must exist first
#
# Each migration is checked against the _migrations tracking table before
# execution. Already-applied migrations are skipped, making this script
# fully idempotent and safe to re-run.
echo ""
echo "Running database migrations..."
echo "=============================="

APPLIED_COUNT=0
SKIPPED_COUNT=0
for migration in $(find "$MIGRATIONS_DIR" -maxdepth 1 -name "*.sql" -type f | sort); do
    MIGRATION_NAME="$(basename "$migration")"

    # Check if this migration has already been applied by querying the
    # _migrations tracking table. This mirrors the skip logic in the Swift
    # MigrationManager.fetchAppliedMigrations(on:) method.
    ALREADY_APPLIED=$(mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -N -e \
        "SELECT COUNT(*) FROM _migrations WHERE filename = '${MIGRATION_NAME}';" 2>/dev/null)

    if [ "$ALREADY_APPLIED" -gt 0 ]; then
        echo "  Skipping (already applied): ${MIGRATION_NAME}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    echo "  Executing: ${MIGRATION_NAME}..."
    mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "$migration" 2>&1

    # Record the migration as applied in the tracking table.
    mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e \
        "INSERT INTO _migrations (filename) VALUES ('${MIGRATION_NAME}');" 2>&1
    echo "    ✓ ${MIGRATION_NAME} applied successfully"
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
done

echo "=============================="
echo "✓ Migrations complete — ${APPLIED_COUNT} applied, ${SKIPPED_COUNT} skipped (already applied)"

# =============================================================
# Phase 4: Verification
# =============================================================

echo ""
echo "Verifying database schema..."
echo "----------------------------------------------"

# --- 4.1 Verify All 7 Tables Were Created ---
# The 8 migration scripts create 7 tables (008 only creates indexes).
EXPECTED_TABLES=("users" "account_groups" "entitlements" "accounts" "reference_data" "positions" "transactions")
MISSING_TABLES=0

echo "  Checking tables..."
for table in "${EXPECTED_TABLES[@]}"; do
    result=$(mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -N -e "SHOW TABLES LIKE '${table}';" 2>/dev/null)
    if [ -z "$result" ]; then
        echo "    ✗ ERROR: Table '${table}' was NOT created!"
        MISSING_TABLES=$((MISSING_TABLES + 1))
    else
        echo "    ✓ Table '${table}' exists"
    fi
done

if [ "$MISSING_TABLES" -gt 0 ]; then
    echo ""
    echo "ERROR: ${MISSING_TABLES} table(s) are missing. Migration may have failed."
    exit 1
fi
echo "  ✓ All ${#EXPECTED_TABLES[@]} tables verified"

# --- 4.2 Verify Foreign Key Constraints (Rule 10) ---
# Rule 10 requires all inter-table relationships to be enforced via
# MySQL foreign key constraints. Expected FK counts:
#   entitlements: 2 FKs (user_id → users, account_group_id → account_groups)
#   accounts:     1 FK (account_group_id → account_groups)
#   positions:    2 FKs (account_id → accounts, instrument_id → reference_data)
#   transactions: 3 FKs (account_id → accounts, instrument_id → reference_data,
#                         restatement_ref_id → transactions)
echo ""
echo "  Checking foreign key constraints (Rule 10)..."

FK_TABLES=("entitlements" "accounts" "positions" "transactions")
declare -A EXPECTED_FK_COUNTS
EXPECTED_FK_COUNTS[entitlements]=2
EXPECTED_FK_COUNTS[accounts]=1
EXPECTED_FK_COUNTS[positions]=2
EXPECTED_FK_COUNTS[transactions]=3

FK_WARNINGS=0
for table in "${FK_TABLES[@]}"; do
    fk_count=$(mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "information_schema" -N -e \
        "SELECT COUNT(*) FROM TABLE_CONSTRAINTS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND CONSTRAINT_TYPE='FOREIGN KEY';" 2>/dev/null)

    expected="${EXPECTED_FK_COUNTS[$table]}"
    if [ "$fk_count" -eq 0 ]; then
        echo "    ✗ WARNING: No foreign key constraints found on table '${table}' (expected ${expected})"
        FK_WARNINGS=$((FK_WARNINGS + 1))
    elif [ "$fk_count" -lt "$expected" ]; then
        echo "    ⚠ Table '${table}' has ${fk_count} FK(s) but expected ${expected}"
        FK_WARNINGS=$((FK_WARNINGS + 1))
    else
        echo "    ✓ Table '${table}' has ${fk_count} foreign key constraint(s) (expected ${expected})"
    fi
done

if [ "$FK_WARNINGS" -gt 0 ]; then
    echo ""
    echo "  ⚠ ${FK_WARNINGS} table(s) have fewer FK constraints than expected."
    echo "    Review migration scripts for missing FOREIGN KEY declarations."
fi

# --- 4.3 Verify Indexes from Migration 008 ---
echo ""
echo "  Checking index creation..."
INDEX_COUNT=$(mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "information_schema" -N -e \
    "SELECT COUNT(*) FROM STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}';" 2>/dev/null)
echo "    ✓ Total indexes in '${DB_NAME}': ${INDEX_COUNT}"

# =============================================================
# Phase 5: Completion Summary
# =============================================================

echo ""
echo "=============================================="
echo "  WealthLedger Database Setup Complete!"
echo "=============================================="
echo ""
echo "  Database:           ${DB_NAME}"
echo "  Host:               ${DB_HOST}:${DB_PORT}"
echo "  User:               ${DB_USER}"
echo ""
echo "  Tables created:     ${#EXPECTED_TABLES[@]}"
echo "  Migrations applied: ${APPLIED_COUNT}"
echo "  Total indexes:      ${INDEX_COUNT}"
echo ""
echo "  You can now build and run the application:"
echo "    swift build"
echo "    swift run WealthLedgerApp"
echo ""
echo "  To seed reference data (500+ synthetic NYSE equities):"
echo "    swift run SeedTool"
echo ""
echo "=============================================="
