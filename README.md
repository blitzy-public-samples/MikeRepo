# WealthLedger

WealthLedger is a standalone macOS desktop application that provides a general ledger accounting engine purpose-built for institutional and wealth management accounts. It supports a universe of 100,000 accounts spanning institutional fund types (open/closed mutual funds, ETFs, hedge funds) and wealth account types (separately managed accounts, unified managed accounts).

Built with Swift 6.3, SwiftUI, and MySQLKit against a local MySQL 8.0 database, WealthLedger operates entirely offline with zero network dependencies at runtime. Target hardware: Apple Silicon M5, 16GB RAM, macOS Tahoe.

---

## Architecture Overview

WealthLedger follows a modular architecture with clear separation of concerns across eleven Swift modules:

- **AccountManagement** — Account CRUD operations, full-universe search with pagination, batch status updates (up to 1,000 accounts simultaneously), and fund type management. Supports institutional types (open/closed mutual funds, ETFs, hedge funds) and wealth types (SMAs, UMAs). Each account carries a lifecycle status of Active, Inactive, Pending, or Suspended.

- **LedgerEngine** — Double-entry credit/debit system with an immutable transaction log. Every ledger write produces balanced debit/credit pairs summing to zero. Restatements are performed exclusively through offsetting entries that reference the original transaction via foreign key. No UPDATE or DELETE operations are permitted on the transactions table.

- **ValuationEngine** — Per-account closed-book NAV valuation computed as `Σ(quantity × EOD midpoint) + cash balance`, where EOD midpoint equals `(bid + ask) / 2` and cash position price is fixed at `1.00`. Each account stores its own IANA timezone string and valuation schedule; the ValuationEngine uses exclusively the account's stored timezone — never the system clock timezone.

- **ReferenceDataService** — Simulated NYSE equity data with a minimum of 500 synthetic securities. Each record contains ticker, name, SOD bid, SOD ask, EOD bid, and EOD ask fields. Includes CSV parsing and export capabilities, plus a synthetic data generator. No real or externally sourced market data is required or permitted.

- **JobScheduler** — Manually triggered report generation (field selection, account selection, target date, CSV export) and CSV ingestion jobs. No automated cron scheduling.

- **RBAC** — Role-based access control with bcrypt-based local authentication and per-user, per-account-group entitlements (READ, CREATE, MODIFY, DELETE). All data reads verify user-group entitlement before returning records. Users without READ access receive an empty result set — not an error.

- **UILayer** — Four SwiftUI screens: Admin (user creation, account group creation, entitlement assignment), Search (name/ID/type/group with up to 1,000 results), Accounts Viewer (scrollable list of selected accounts with values, positions, and value dates), and Job Scheduler (create and manually trigger report and CSV ingestion jobs).

- **Persistence** — MySQLKit-based data access layer with AsyncKit connection pooling, ordered SQL migration management, and seven repository classes (Account, Transaction, Position, User, Entitlement, AccountGroup, ReferenceData).

- **Shared** — Cross-cutting utilities including Date+Timezone extensions, Decimal+Currency precision helpers, a generic repository protocol, application-wide constants, and a typed error hierarchy.

- **SeedTool** — CLI executable target for generating and seeding 500+ synthetic NYSE equity records into the reference_data table.

- **WealthLedgerApp** — The `@main` entry point that initializes the database connection, registers all services in a dependency container, and launches the root SwiftUI navigation view.

---

## Build Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Xcode** | 26.4 | Includes Swift 6.3 and macOS 26.4 SDK |
| **MySQL** | 8.0 | Installed via Homebrew: `brew install mysql@8.0` |
| **macOS** | Tahoe (version 26) | Apple Silicon required |

> **Note:** WealthLedger has no network dependencies at runtime. All data sources — MySQL database and CSV files — are local. The application functions with the network adapter disabled.

---

## Database Setup

Follow these steps to initialize the local MySQL database:

1. **Install MySQL 8.0:**

   ```bash
   brew install mysql@8.0
   ```

2. **Start the MySQL service:**

   ```bash
   brew services start mysql@8.0
   ```

3. **Run the setup script:**

   ```bash
   chmod +x ./Scripts/setup_database.sh
   ./Scripts/setup_database.sh
   ```

   This creates the `wealth_ledger` database and executes all 8 migration scripts in order:
   - `001_create_users.sql` — Users table with bcrypt password column
   - `002_create_account_groups.sql` — Account groups table
   - `003_create_entitlements.sql` — Entitlements with FK constraints to users and account_groups
   - `004_create_accounts.sql` — Accounts with fund type, IANA timezone, cached valuation, status
   - `005_create_reference_data.sql` — Reference data with ticker and six price columns
   - `006_create_positions.sql` — Positions with FK constraints to accounts and reference_data
   - `007_create_transactions.sql` — Immutable transactions with restatement FK
   - `008_create_indexes.sql` — Composite indexes for search performance optimization

> **Integration tests** use a dedicated `accounting_test` schema that is created and dropped automatically by `TestDatabaseSetup.swift`. No manual setup is required for the test database.

---

## Configuration

### Database Credentials

Both the setup script (`Scripts/setup_database.sh`) and the application (`WealthLedgerApp.swift`) read database credentials from the **same** environment variables. If no environment variables are set, both use identical built-in defaults so that the documented setup workflow works out of the box.

| Environment Variable | Default Value | Description |
|---------------------|---------------|-------------|
| `DB_USERNAME` | `wealthledger` | MySQL username for the application database user |
| `DB_PASSWORD` | `wealthledger_pass` | MySQL password for the application database user |
| `DB_NAME` | `wealth_ledger` | MySQL database name |
| `DB_HOST` | `localhost` | MySQL server hostname (always localhost for offline operation) |
| `DB_PORT` | `3306` | MySQL server port |

**Using defaults (recommended for local development):**

No environment variable configuration is needed. Simply run the setup script and then launch the application:

```bash
./Scripts/setup_database.sh
swift run WealthLedgerApp
```

The setup script creates the MySQL user `wealthledger` with password `wealthledger_pass` and grants it full privileges on the `wealth_ledger` database. The application connects using the same credentials by default.

**Customizing credentials:**

To use custom database credentials, export the environment variables before running both the setup script and the application:

```bash
export DB_USERNAME="my_custom_user"
export DB_PASSWORD="my_custom_password"
export DB_NAME="my_custom_db"

./Scripts/setup_database.sh    # Creates the DB and user with custom credentials
swift run WealthLedgerApp      # Connects using the same custom credentials
```

---

## Building and Running

### Build

```bash
swift build
```

Or open `Package.swift` in Xcode 26.4 and build the `WealthLedgerApp` scheme.

Swift 6 strict concurrency checking is enabled. The build must produce zero warnings — no `@unchecked Sendable` or warning suppressions are permitted.

### Run the Application

```bash
swift run WealthLedgerApp
```

### Seed Reference Data

Generate and insert 500+ synthetic NYSE equity records into the database:

```bash
swift run SeedTool
```

The SeedTool produces synthetic tickers, company names, and six price fields (SOD bid, SOD ask, EOD bid, EOD ask) for each security.

---

## Running Tests

### Full Test Suite

```bash
xcodebuild test -scheme WealthLedgerApp -destination 'platform=macOS'
```

### Unit Tests

Located in `Tests/UnitTests/`. These test pure business logic with no database dependencies:

- `DoubleEntryValidatorTests` — Balanced/unbalanced entry rejection
- `LedgerServiceTests` — Transaction creation and restatement logic
- `NAVCalculatorTests` — NAV formula: `Σ(qty × midpoint) + cash`
- `ValuationServiceTests` — Timezone-aware valuation date computation
- `AuthenticationTests` — bcrypt hash/verify cycle
- `EntitlementTests` — Permission flag checks
- `AccountServiceTests` — Search, status updates, CRUD
- `CSVParserTests` — CSV parsing and column validation

### Integration Tests

Located in `Tests/IntegrationTests/`. These exercise the full call chain against a live MySQL `accounting_test` schema:

- `EndToEndWorkflowTests` — Create account → post transaction → run valuation → verify in viewer
- `AccountManagementIntegrationTests` — Account CRUD against live MySQL
- `LedgerIntegrationTests` — Transaction posting against live MySQL
- `ValuationIntegrationTests` — Valuation run with timezone verification
- `RBACIntegrationTests` — Entitlement enforcement against live MySQL
- `ReferenceDataIntegrationTests` — CSV ingestion and reference data seeding
- `JobSchedulerIntegrationTests` — Job creation and execution against live MySQL

The test database (`accounting_test`) is created and torn down automatically by `TestDatabaseSetup.swift`.

---

## Project Structure

```
Sources/
├── WealthLedgerApp/        # @main entry point, app state, dependency container
├── AccountManagement/      # Account models and services
│   ├── Models/             # Account, AccountGroup, AccountStatus, FundType
│   └── Services/           # AccountService, AccountGroupService
├── LedgerEngine/           # Transaction and position models, ledger service
│   ├── Models/             # Transaction, Position
│   └── Services/           # LedgerService, DoubleEntryValidator
├── ValuationEngine/        # NAV calculator, valuation service
│   ├── Models/             # Valuation
│   └── Services/           # ValuationService, NAVCalculator
├── ReferenceDataService/   # Reference data, CSV parser/exporter, data generator
│   ├── Models/             # ReferenceData
│   ├── Services/           # ReferenceDataService, CSVParser, CSVExporter
│   └── Generators/         # SyntheticDataGenerator
├── JobScheduler/           # Job models and scheduler service
│   ├── Models/             # Job
│   └── Services/           # JobSchedulerService, ReportGenerator
├── RBAC/                   # User, entitlement models, auth services
│   ├── Models/             # User, Entitlement
│   └── Services/           # AuthenticationService, EntitlementService, PasswordHasher
├── UILayer/                # SwiftUI screens and components
│   ├── Navigation/         # MainNavigationView
│   ├── AdminScreen/        # AdminView
│   ├── SearchScreen/       # SearchView
│   ├── AccountsViewer/     # AccountsViewerView
│   ├── JobSchedulerScreen/ # JobSchedulerView
│   └── Components/         # AccountRowView, PositionDetailView, EntitlementFormView
├── Persistence/            # DatabaseManager, ConnectionPool, Repositories
│   └── Repositories/       # 7 repository classes
├── Shared/                 # Extensions, protocols, constants, errors
│   ├── Extensions/         # Date+Timezone, Decimal+Currency
│   ├── Protocols/          # RepositoryProtocol
│   └── Errors/             # AppError
└── SeedTool/               # CLI synthetic data generator

Resources/
└── Migrations/             # 8 SQL DDL migration scripts (001 through 008)

Tests/
├── UnitTests/              # 8 unit test files
│   ├── LedgerEngineTests/
│   ├── ValuationEngineTests/
│   ├── RBACTests/
│   ├── AccountManagementTests/
│   └── ReferenceDataTests/
└── IntegrationTests/       # 9 integration test files

Scripts/
└── setup_database.sh       # MySQL initialization and migration script

Docs/
├── architecture.md         # Module dependency diagram and data flow
├── database_schema.md      # ERD, table definitions, FK map, index strategy
└── user_guide.md           # Screen-by-screen user guide
```

---

## Key Constraints

| Constraint | Description |
|------------|-------------|
| **MySQLKit-only persistence** | SwiftData must not appear anywhere in the project. All database interactions use MySQLKit via Swift Package Manager. Verification: `grep -r "import SwiftData"` returns zero results. |
| **Offline runtime** | The application functions with the network adapter disabled. All data sources (MySQL, CSV files) are local. Zero network dependencies at runtime. |
| **Equities-only asset class** | The application rejects creation of any position or transaction for a non-equity instrument at the application layer. |
| **Swift 6 strict concurrency** | The build produces zero warnings with Swift 6 strict concurrency checking enabled. No `@unchecked Sendable`, no warning suppressions. |
| **Batch memory cap** | No UI operation loads more than 1,000 account records into memory simultaneously. Background jobs paginate at 1,000 records or fewer per page. |
| **Schema referential integrity** | All inter-table relationships enforced via MySQL foreign key constraints. Each primary entity occupies a distinct table with a typed primary key. |
| **Double-entry enforcement** | Every ledger write produces balanced debit/credit pairs summing to zero. Unbalanced entries are rejected at the application layer before any database write. |
| **Transaction immutability** | The transactions table is not targeted by UPDATE or DELETE statements in application code. Corrections use offsetting entries referencing the original transaction ID via FK. |
| **Cached valuation denormalization** | The accounts table stores a cached latest valuation amount and value date, updated atomically within the same DB transaction as each valuation run completion. |
| **Single concurrent user** | Designed for 1 concurrent user at launch with 300 registered users. |

---

## Performance Thresholds

| Metric | Target |
|--------|--------|
| Full-universe search (100,000 accounts) | Under 2 seconds |
| Batch valuation (1,000 accounts) | Under 30 seconds |
| Accounts Viewer initial render (1,000 accounts) | Under 1 second |
| Accounts Viewer scrolling | 30 fps or above |
| CSV ingestion (up to 100 MB) | No crash, runs to completion |
| MySQL RAM footprint | Under 4 GB |

Target hardware: Apple Silicon M5, 16 GB RAM, macOS Tahoe.

---

## Dependencies

### Direct SPM Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [`vapor/mysql-kit`](https://github.com/vapor/mysql-kit) | 4.9.0+ | MySQL database driver — SQLKit query builder, MySQLNIO async protocol, AsyncKit connection pooling |
| [`wisetail/BCryptSwift`](https://github.com/wisetail/BCryptSwift) | 2.0.1+ | Pure Swift bcrypt password hashing — no external dependencies |

### Transitive Dependencies (resolved automatically by SPM)

| Package | Purpose |
|---------|---------|
| `vapor/mysql-nio` | Low-level async MySQL protocol implementation |
| `vapor/sql-kit` | SQL query builder abstraction |
| `vapor/async-kit` | Connection pooling (EventLoopGroupConnectionPool) |
| `apple/swift-crypto` | Cryptographic primitives for MySQL authentication |
| `apple/swift-nio` | Non-blocking event-driven networking foundation |
| `apple/swift-nio-ssl` | TLS support for MySQL connections |
| `apple/swift-log` | Structured logging API |
| `apple/swift-atomics` | Low-level atomic operations |
| `apple/swift-collections` | Ordered collections |

### Built-in Frameworks

| Framework | Usage |
|-----------|-------|
| SwiftUI (macOS 26 SDK) | All UI views and navigation |
| Foundation | Date, Decimal, UUID, TimeZone, file I/O |
| Swift Testing | Test framework (included with Swift 6.3 toolchain) |

### Local Infrastructure

| Software | Version | Installation |
|----------|---------|-------------|
| MySQL | 8.0 | `brew install mysql@8.0` |

---

## License

This project is proprietary software. All rights reserved.
