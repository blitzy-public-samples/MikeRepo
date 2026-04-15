# WealthLedger User Guide

Welcome to **WealthLedger** — a macOS desktop application for managing institutional and wealth management accounts. WealthLedger provides a full-featured general ledger accounting engine with double-entry bookkeeping, per-account net asset value (NAV) valuation, role-based access control, and job scheduling for reports and data ingestion.

WealthLedger runs entirely offline. All of your data is stored in a local MySQL database on your machine — no internet connection is required or used at any point during normal operation. Every action you take in the application respects your assigned permissions: you will only see accounts and data for the account groups you have been granted access to.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Admin Screen](#admin-screen)
3. [Search Screen](#search-screen)
4. [Accounts Viewer](#accounts-viewer)
5. [Job Scheduler](#job-scheduler)
6. [Account Types Reference](#account-types-reference)
7. [Account Status Reference](#account-status-reference)
8. [Important Notes](#important-notes)
9. [Frequently Asked Questions](#frequently-asked-questions)

---

## Getting Started

### Prerequisites

Before using WealthLedger, ensure the following are in place:

- **macOS Tahoe** (version 26) or later
- **MySQL 8.0** installed and running locally (typically via Homebrew)
- The WealthLedger database has been initialized using the provided setup script (`Scripts/setup_database.sh`)
- An administrator has created your user account and assigned you the appropriate permissions

### Launching the Application

1. Open the **WealthLedger** application from your Applications folder or Launchpad.
2. The login screen appears immediately upon launch.

### Logging In

1. Enter your **Username** in the username field.
2. Enter your **Password** in the password field.
3. Click **Log In**.

Your password is securely verified against an encrypted hash stored in the database — your plain-text password is never stored anywhere. If your credentials are incorrect, an error message will appear. Contact your administrator if you have forgotten your password or need a new account.

### Navigating the Application

After a successful login, the main navigation panel appears. WealthLedger provides access to four screens via a sidebar or tab bar:

| Screen | Purpose |
|--------|---------|
| **Admin** | Manage users, account groups, and permissions |
| **Search** | Find and select accounts across the entire account universe |
| **Accounts Viewer** | View detailed account information, valuations, and positions |
| **Job Scheduler** | Create and run report generation and data ingestion jobs |

Click on any screen name in the navigation panel to switch between screens.

---

## Admin Screen

The Admin screen is your central hub for system administration. It is divided into three sections: **User Creation**, **Account Group Creation**, and **Entitlement Assignment**. Access to this screen requires appropriate administrative permissions.

### User Creation

Use this section to create new user accounts for people who need access to WealthLedger.

**Steps:**

1. Enter a **Username** in the text field. Usernames must be unique — you cannot create two users with the same username.
2. Enter a **Password** in the secure text field. Choose a strong password.
3. Click **Create User**.

**What happens:** The password is automatically encrypted before being stored. Plain-text passwords are never saved. If you try to create a user with a username that already exists, an error message will appear.

Once created, the new user can log in but will not be able to see any account data until you assign them the appropriate entitlements (see [Entitlement Assignment](#entitlement-assignment) below).

### Account Group Creation

Account groups are used to organize accounts and control who can access them. Every account belongs to exactly one account group.

**Steps:**

1. Enter a **Group Name** in the text field.
2. Optionally, enter additional **Metadata** describing the group in the text area.
3. Click **Create Group**.

**What happens:** The new account group is created and becomes available for assigning accounts and configuring user permissions.

### Entitlement Assignment

Entitlements control what each user can do within each account group. WealthLedger uses four permission levels, commonly abbreviated as **RCMD**:

| Permission | Abbreviation | What It Allows |
|-----------|--------------|----------------|
| **Read** | R | View accounts and their data within the group |
| **Create** | C | Create new accounts or entries within the group |
| **Modify** | M | Update existing accounts within the group |
| **Delete** | D | Remove accounts within the group |

**Steps:**

1. Select a **User** from the user dropdown.
2. Select an **Account Group** from the group dropdown.
3. Toggle the permission checkboxes for **Read**, **Create**, **Modify**, and **Delete** as needed.
4. Click **Assign**.

**Important notes:**

- Each user has one entitlement record per account group. If you reassign permissions for the same user-group pair, the existing permissions are updated.
- A user without **Read** permission for a group will see **zero records** from that group — the system will not display an error message; the data simply will not appear. This is by design for security.
- Users need at minimum **Read** permission to see any accounts in a group on the Search or Accounts Viewer screens.

---

## Search Screen

The Search screen lets you find accounts across the entire account universe (which can contain up to 100,000 accounts). Search results are returned quickly — typically in under 2 seconds even for the largest datasets.

### Search Fields

You can search using any combination of the following four fields:

| Field | How It Works |
|-------|-------------|
| **Account Name** | Partial match (prefix search). For example, typing "Blue" will find accounts named "BlueChip Fund", "Bluestone Capital", etc. |
| **Account ID** | Exact match on the account's unique identifier. Enter the full ID to find a specific account. |
| **Account Type** | Dropdown menu with the following options: Open Mutual Fund, Closed Mutual Fund, ETF, Hedge Fund, SMA, UMA (see [Account Types Reference](#account-types-reference) for details). |
| **Account Group** | Dropdown menu showing only the account groups you have **Read** permission for. Groups you do not have access to will not appear in this list. |

You can combine multiple fields to narrow your search. For example, you could search for all ETF accounts in a specific group whose names start with "Global".

### Viewing Search Results

- Matching accounts appear in a scrollable list below the search fields.
- Each result row shows the **Account Name**, **Account ID**, **Account Type**, **Status** (Active, Inactive, Pending, or Suspended), and **Account Group**.
- Results are automatically limited to a maximum of **1,000 accounts**. If your search matches more than 1,000 accounts, refine your criteria to narrow the results.

### Selecting Accounts for Viewing

1. Click on individual rows to **select** or **deselect** accounts. Selected rows are highlighted.
2. You can select up to **1,000 accounts** at a time.
3. Once you have made your selection, click the **"View Selected"** button.
4. You will be taken to the **Accounts Viewer** screen with your selected accounts loaded.

### About Entitlement Filtering

Your search results are automatically filtered based on your permissions:

- You will **only** see accounts belonging to groups where you have **Read** access.
- If you search for an account that exists but belongs to a group you lack Read permission for, it will **not** appear in your results. The system does not show an error — the account is simply excluded from the list.
- The **Account Group** dropdown only shows groups you are entitled to view.

---

## Accounts Viewer

The Accounts Viewer displays detailed information about the accounts you selected from the Search screen. It is designed for smooth, high-performance scrolling even when viewing up to 1,000 accounts simultaneously.

### Account List

The main view is a scrollable list where each row displays:

| Column | Description |
|--------|-------------|
| **Account Name** | The full name of the account |
| **Account ID** | The account's unique identifier |
| **Valuation Amount** | The most recently calculated net asset value, displayed as a currency amount |
| **Status** | A color-coded badge indicating the account's current status |
| **Value Date** | The date of the most recent valuation, shown in the account's own timezone |

**Status badge colors:**

| Status | Color |
|--------|-------|
| Active | Green |
| Inactive | Gray |
| Pending | Yellow |
| Suspended | Red |

### Viewing Position Details

Click on any account row to **expand** it and reveal the account's position details. Each position shows:

- **Instrument Ticker** — The stock ticker symbol (for example, "AAPL", "MSFT", "GOOG")
- **Quantity** — The number of shares or units held
- **Midpoint Value** — The per-position value calculated as: quantity multiplied by the end-of-day midpoint price

**How account values are calculated:**

The account's total valuation (NAV) is computed as:

> **Account Value = Sum of all (Quantity × End-of-Day Midpoint) + Cash Balance**

Where the end-of-day midpoint for each instrument is the average of the end-of-day bid and ask prices. Cash positions are always valued at 1.00 per unit.

### Understanding Value Dates and Timezones

Each account in WealthLedger has its own configured timezone (for example, "America/New_York" for US Eastern time, or "Europe/London" for UK time). This is important because:

- **Value dates are computed using the account's timezone, not your computer's local timezone.**
- This means two accounts may show different value dates for valuations that were run at the same moment, if those accounts are configured for different timezones.
- For example, a valuation run at 11 PM UTC on January 15 would produce a value date of January 15 for a London-timezone account, but January 15 for a New York-timezone account as well — unless the valuation crosses midnight in one timezone but not the other.

This design ensures that each account's valuation date accurately reflects the close of business in its own market timezone.

---

## Job Scheduler

The Job Scheduler screen allows you to create and manually run two types of jobs: **Report Generation** and **CSV Data Ingestion**. All jobs are triggered manually — there is no automatic or scheduled execution.

### Creating a Report Generation Job

Report jobs generate CSV files containing account and valuation data.

**Steps:**

1. Select **"Report"** as the job type.
2. **Select fields** to include in the report by checking the desired field checkboxes. Available fields include account name, account ID, valuation amount, positions, value date, and more.
3. **Select accounts** to include — you can search for and choose specific accounts or entire account groups.
4. **Pick a target date** — the date for which report data should be generated.
5. Click **"Create Job"**.

The job appears in the job list with a status of **Pending**.

### Creating a CSV Ingestion Job

Ingestion jobs import data from CSV files on your local machine into the database.

**Steps:**

1. Select **"Ingestion"** as the job type.
2. **Choose a CSV file** using the file picker. You can select files up to **100 MB** in size.
3. **Specify the data type** the CSV contains (for example, reference data or account data).
4. Click **"Create Job"**.

The job appears in the job list with a status of **Pending**.

### Running a Job

1. Find the job in the **Job List**.
2. Click the **"Run"** button next to any job with a **Pending** status.
3. The job status changes to **Running** while it executes.
4. When complete, the status changes to **Completed** (success) or **Failed** (error encountered).

Only jobs in the **Pending** state can be triggered. Jobs that have already been run (Completed or Failed) cannot be re-triggered.

### Job Status Tracking

The job list displays all created jobs with the following information:

| Column | Description |
|--------|-------------|
| **Job ID** | A unique identifier for the job |
| **Job Type** | Report or Ingestion |
| **Status** | Pending, Running, Completed, or Failed |
| **Created** | The date and time the job was created |
| **Completed** | The date and time the job finished (if applicable) |

**Job status definitions:**

| Status | Meaning |
|--------|---------|
| **Pending** | The job has been created and is waiting to be manually triggered |
| **Running** | The job is currently executing |
| **Completed** | The job finished successfully |
| **Failed** | The job encountered an error during execution |

**Note:** The job list does not auto-refresh. Interact with the screen (for example, click or scroll) to see updated statuses.

### Report Output

When a report job completes successfully, the generated CSV file is saved to your local file system. The CSV contains exactly the fields you selected during job creation, filtered to the accounts you specified, for the target date you chose.

### Large File Ingestion

CSV ingestion supports files up to **100 MB**. Large files are processed in batches of 1,000 rows at a time to ensure the application remains responsive and does not consume excessive memory. The CSV's column structure is validated before data is inserted — if columns do not match the expected format, the job will fail with a descriptive error.

---

## Account Types Reference

WealthLedger supports two broad categories of accounts: **Institutional** and **Wealth**. Within each category, there are specific fund types.

### Institutional Account Types

| Type | Description |
|------|-------------|
| **Open Mutual Fund** | A pooled investment fund that continuously accepts new investor subscriptions. The fund creates new shares for incoming investors. |
| **Closed Mutual Fund** | A fixed-capital investment fund with a set number of shares determined at launch. Shares trade on the secondary market. |
| **ETF (Exchange-Traded Fund)** | A fund that holds a basket of securities and trades on stock exchanges like an individual stock throughout the trading day. |
| **Hedge Fund** | An alternative investment fund that employs advanced strategies such as leverage, short selling, and derivatives to generate returns. |

### Wealth Account Types

| Type | Description |
|------|-------------|
| **SMA (Separately Managed Account)** | An individual investment account managed by a professional portfolio advisor. The investor directly owns the underlying securities. |
| **UMA (Unified Managed Account)** | A single account that combines multiple investment styles, strategies, or asset allocations into one unified structure, simplifying management and reporting. |

---

## Account Status Reference

Every account in WealthLedger has one of four lifecycle statuses. Administrators can update account statuses individually or in batches of up to 1,000 accounts at a time.

| Status | Color Badge | Description |
|--------|-------------|-------------|
| **Active** | 🟢 Green | The account is fully operational. It participates in valuations and can receive new transactions. |
| **Inactive** | ⚪ Gray | The account is dormant. No new transactions can be posted, but historical data remains accessible. |
| **Pending** | 🟡 Yellow | The account has been created but has not yet been activated. It is awaiting administrative approval or setup completion. |
| **Suspended** | 🔴 Red | The account has been temporarily frozen. No operations of any kind are permitted until the suspension is lifted. |

---

## Important Notes

### Permissions and Data Visibility

Your experience in WealthLedger is shaped by your entitlements (permissions). Key points to understand:

- **You can only see data from account groups where you have Read permission.** If you cannot find a particular account, it may be in a group you don't have access to.
- **Empty results are normal for restricted access.** The system does not tell you whether an account exists if you lack permission — you simply see an empty list. This is an intentional security measure.
- **Contact your administrator** to request additional permissions if you believe you need access to account groups not currently visible to you.

### Equities Only

WealthLedger is designed exclusively for **equity instruments** (stocks and equity funds). The application does not support fixed income, derivatives, digital assets, or other non-equity instrument types. Any attempt to create a position or transaction for a non-equity instrument will be rejected by the system.

### Offline Operation

WealthLedger operates entirely offline:

- **No internet connection** is required or used at any point during operation.
- All data (accounts, transactions, positions, reference data, users, and permissions) is stored in your **local MySQL database**.
- CSV files for import and export are read from and saved to your **local file system**.

You can use the application with your network adapter completely disabled.

### Data Integrity and Transaction History

WealthLedger uses a **double-entry accounting** system, which means:

- Every transaction produces balanced debit and credit entries that sum to zero. This is the gold standard for financial record-keeping.
- **Transactions are permanent and immutable.** Once a transaction is posted, it cannot be edited or deleted. If a correction is needed, the system creates a new **offsetting entry** that references the original transaction. This preserves a complete, auditable history of every change.
- This approach ensures that the transaction log serves as a reliable, tamper-evident audit trail of all financial activity.

### Display Limits

For performance and usability:

- Search results are limited to a maximum of **1,000 accounts** per query. Use specific search criteria to find the accounts you need.
- The Accounts Viewer displays up to **1,000 accounts** at a time. Select specific accounts from the Search screen rather than loading all accounts at once.
- Background jobs process data in batches to ensure the application remains responsive during large operations.

---

## Frequently Asked Questions

### Q: I searched for an account but it doesn't appear in my results. Why?

**A:** There are two possible reasons:

1. The account may not match your search criteria. Double-check your search fields and try broadening your filters.
2. The account may belong to an account group you do not have **Read** permission for. Contact your administrator to check your entitlements.

The system does not distinguish between these two cases in the search results — this is an intentional security feature.

### Q: Can I edit or delete a transaction?

**A:** No. Transactions in WealthLedger are permanent and cannot be modified or deleted. If a correction is needed, the system creates a new offsetting entry that reverses the original transaction's effect while preserving the full history. This ensures complete auditability.

### Q: Why do two accounts show different value dates for the same valuation run?

**A:** Each account has its own configured timezone. Value dates are determined based on the account's timezone, not your computer's local time. If two accounts are in different timezones, they may produce different value dates for valuations performed at the same moment.

### Q: How large of a CSV file can I import?

**A:** WealthLedger supports CSV files up to **100 MB**. Larger files should be split into smaller chunks before importing. The ingestion process handles large files by processing them in manageable batches.

### Q: Do I need an internet connection to use WealthLedger?

**A:** No. WealthLedger runs entirely offline using your local MySQL database. No internet connection is required or used at any point.

### Q: What is the maximum number of accounts I can view at once?

**A:** You can view up to **1,000 accounts** simultaneously in the Accounts Viewer. Use the Search screen to select the specific accounts you want to examine.

### Q: What types of instruments does WealthLedger support?

**A:** WealthLedger supports **equity instruments only**. This includes stocks and equity-based funds (mutual funds, ETFs, hedge funds, SMAs, UMAs). Fixed income, derivatives, and other asset classes are not supported.

### Q: How do I reset my password?

**A:** Contact your system administrator. They can create a new user account for you through the Admin screen. There is no self-service password reset feature.

### Q: Why are jobs not running automatically?

**A:** All jobs in WealthLedger are **manually triggered**. There is no automatic scheduling. You must click the "Run" button next to a pending job to execute it. This gives you full control over when data processing occurs.

---

*WealthLedger — Institutional and Wealth Management Accounting for macOS*
