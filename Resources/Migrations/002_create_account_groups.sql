-- Migration 002: Create Account Groups Table
-- Organizes accounts into logical groups for RBAC scoping.
-- Referenced by: entitlements (migration 003), accounts (migration 004).

CREATE TABLE IF NOT EXISTS account_groups (
    id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    group_name VARCHAR(255) NOT NULL,
    metadata   JSON DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
