-- Migration 003: Create Entitlements Table
-- Stores per-user per-account-group RBAC permissions.
-- Permission flags: READ, CREATE, MODIFY, DELETE (Rule 4).
-- FKs to users and account_groups (Rule 10).

CREATE TABLE IF NOT EXISTS entitlements (
    id               BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id          BIGINT UNSIGNED NOT NULL,
    account_group_id BIGINT UNSIGNED NOT NULL,
    can_read         BOOLEAN         NOT NULL DEFAULT FALSE,
    can_create       BOOLEAN         NOT NULL DEFAULT FALSE,
    can_modify       BOOLEAN         NOT NULL DEFAULT FALSE,
    can_delete       BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY uk_entitlements_user_group (user_id, account_group_id),

    CONSTRAINT fk_entitlements_user
        FOREIGN KEY (user_id) REFERENCES users(id),

    CONSTRAINT fk_entitlements_account_group
        FOREIGN KEY (account_group_id) REFERENCES account_groups(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
