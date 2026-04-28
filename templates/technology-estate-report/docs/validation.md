# Validation Harness — Technology Estate Report Template

## 1. Overview

This document is the **single canonical reference** for executing the validation suite that proves the
Technology Estate Report Blitzy prompt template package is delivery-ready. The validation suite is the
operational realization of the contracts in [`../template.md`](../template.md): every Validation Gate and every
Domain-Specific Success Criterion specified by the user requirements has its single-command execution path,
its assertion procedure, and its artifact retention policy documented here. No other file in the package
contains these procedures as primary content; the rules and gates themselves are reproduced verbatim only in
[`../template.md`](../template.md) §§ 5 and 6 per the AAP § 0.10.2 "No Redundancy Rule".

The validation suite is composed of **five validation gates plus five domain-specific success criteria**, for
a total of **10 acceptance items** (counting each gate as one acceptance item even when it contains internal
sub-items). All 10 items must pass for delivery acceptance; partial passes do NOT constitute acceptance. The
seven analysis components named in [Gate 9](#5-gate-9--integration-wiring-verification) — Tech Stack Detector,
Maturity Analyzer, CVE Scanner, Complexity Extractor, Grading Engine, Grade Persistence Store, and PDF
Renderer — are each exercised by at least one end-to-end test; the canonical mapping is in
[`./architecture.md`](./architecture.md) § 6 Component Reachability Matrix and is reproduced as a working
checklist in [§ 5.3 Component Reachability Matrix](#53-component-reachability-matrix) and [§ 10
Gate-to-Component Cross-Reference Matrix](#10-gate-to-component-cross-reference-matrix) below.

Per Gate 10, the entire suite has a **single-command execution path** documented in [§ 8 Single-Command
Execution Path Summary](#8-single-command-execution-path-summary). Each individual gate and each individual
criterion also has its own subcommand flag for targeted execution during incremental development; the
subcommand inventory is in [§ 8.2 Per-Gate Subcommands](#82-per-gate-subcommands).

> **Important reading note for reviewers.** The user-supplied gate numbering is **non-consecutive**: the
> validation framework defines exactly **Gate 1, Gate 2, Gate 8, Gate 9, and Gate 10**. This is intentional and
> originates from the user prompt § 6 Validation Framework (reproduced verbatim in
> [`../template.md`](../template.md) § 6.1). **Do NOT renumber to consecutive 1-5; do NOT invent intermediate
> Gates 3–7 or trailing Gates 11+.** The non-consecutive numbering is also preserved in
> [`../template.md`](../template.md) § 6.1, [`./architecture.md`](./architecture.md) § 6, and every other
> document in this package.

## 2. Gate 1 — End-to-End Boundary Verification

### 2.1 Statement (Cited)

The canonical, verbatim text of Gate 1 is in [`../template.md`](../template.md) § 6.1.1 (the user-supplied
prompt § 6 Validation Framework). This document does **not** duplicate the verbatim text per the AAP § 0.10.2
"No Redundancy Rule"; it cites the canonical location and operationalizes via procedure and assertion.

### 2.2 Acceptance Criteria

Gate 1 passes when ALL of the following are true:

- The template processes **at least one real GitHub or GitLab repository** — NOT a mock dataset, NOT a stub,
  NOT a fixture. The verbatim Gate 1 text in [`../template.md`](../template.md) § 6.1.1 explicitly disqualifies
  mock or stub datasets.
- The output PDF contains **all four facet columns populated** for the test repository per
  [Rule R2](../template.md#r2--facet-completeness) (facet completeness). The four columns appear in canonical
  order — Tech Stack Summary | Maturity Summary | Security Summary | Complexity Summary — per
  [`./pdf-output.md`](./pdf-output.md) § Matrix Table Columns.
- The output PDF contains **at least one graded cell** — that is, at least one cell whose rendered value is one
  of the letter grades `A`, `B`, `C`, `D`, or `F` (NOT every cell is `Insufficient Data`, and NOT every cell is
  `Grade: TBD — definition pending`). This is the verbatim Gate 1 acceptance phrase "at least one graded cell".
- The verification artifact is the **generated PDF file** from the live repository, retained at the path
  documented in [§ 6.5 Artifact Retention](#65-artifact-retention).

### 2.3 Test Repository

The Gate 1 live smoke test requires a designated, deterministic test repository. The recommended properties
are:

- **Public** — to avoid token-scope variability and to keep the smoke test reproducible across reviewers
  without coordinating private-access permissions.
- **Small but realistic** — the repository should contain at least one source file, at least one dependency
  manifest in a supported ecosystem (e.g., `requirements.txt`, `package.json`, `pom.xml`, `go.mod`, `Gemfile`,
  `Pipfile`, `build.gradle`, `.csproj`, or `Cargo.toml` per [`./facets.md`](./facets.md) § Tech Stack Summary),
  and OPTIONALLY at least one IaC configuration file.
- **At least one CVE-affected dependency in its lockfile** — to exercise the CVE Scanner end-to-end. Without
  this property, the Security facet cannot demonstrate non-zero severity-tier counts and Gate 1's "at least one
  graded cell" criterion may rely solely on Tech Stack and Maturity grades.

The exact test-repository pointer is captured in [`../config/facets.yaml`](../config/facets.yaml) under the
configurable convention key `validation.gate1_test_repo`. When that key is absent, the validator defaults to
the most minimal smoke-test target: `octocat/Hello-World` on GitHub. Operational guidance for choosing and
swapping the smoke-test target — including the trade-off that `octocat/Hello-World` has no dependency manifest
and therefore exercises the Tech Stack and Complexity facets but not Maturity or Security — is in
[`./troubleshooting.md`](./troubleshooting.md) § 9.1 Smoke Test Repository Pointer.

### 2.4 Single-Command Execution

```bash
blitzy validate templates/technology-estate-report --gate gate1
```

This subcommand is part of the canonical single-command suite documented in
[§ 8 Single-Command Execution Path Summary](#8-single-command-execution-path-summary); reviewers may run it in
isolation during incremental development, or run the full suite per § 8.1.

### 2.5 Reviewer Verification Procedure

1. Provision `GITHUB_TOKEN` per [`./usage.md`](./usage.md) § 3 (and `GITLAB_TOKEN` and/or `NVD_API_KEY` if the
   chosen test repository requires them).
2. Run the command in [§ 2.4 Single-Command Execution](#24-single-command-execution).
3. Locate the generated PDF at the default output path
   `~/blitzy-reports/gate1-<run_date_iso>.pdf`. The exact path is also emitted to stdout by the validator and
   recorded in the run's structured log; the configurable output directory is documented in
   [`./usage.md`](./usage.md) § 6.3.
4. Open the PDF and assert each of the following:
   - **Page 1** contains the heading "Executive Summary" — this is the
     [Rule R8](../template.md#r8--pdf-section-order) verification, also exercised by
     [Gate 8 Item 1](#43-item-1-live-smoke-test).
   - **Page 2 onward** contains the Application Matrix Table with at least one row.
   - That row has all four facet cells populated — this is the
     [Rule R2](../template.md#r2--facet-completeness) verification.
   - At least one cell among the four facet cells contains a letter grade in the set `{A, B, C, D, F}`.
5. Capture the PDF as the Gate 1 verification artifact; retain per
   [§ 6.5 Artifact Retention](#65-artifact-retention).

### 2.6 Failure Mode

Gate 1 fails when any of the following is true:

- The PDF cannot be generated.
- Fewer than four facet columns appear in the matrix table.
- No graded cell appears in the matrix (every cell is `Insufficient Data`, `N/A`, or
  `Grade: TBD — definition pending`).

When Gate 1 fails, the reviewer SHOULD inspect the structured log per
[`./troubleshooting.md`](./troubleshooting.md) § 8.1 (log-record retrieval) and remediate per the
Failure-Mode-to-Cell-Value mapping in [`./troubleshooting.md`](./troubleshooting.md) § 2. Common remediation
paths include re-provisioning credentials per [`./usage.md`](./usage.md) § 3, switching the
`validation.gate1_test_repo` pointer in [`../config/facets.yaml`](../config/facets.yaml) to a repository with a
non-empty dependency manifest, or enabling `NVD_API_KEY` to lift the NVD CVE API rate limit per
[`./api-integrations.md`](./api-integrations.md) § 5.

## 3. Gate 2 — Zero-Warning Build

### 3.1 Statement (Cited)

The canonical, verbatim text of Gate 2 is in [`../template.md`](../template.md) § 6.1.2. This document does
**not** duplicate the verbatim text; it cites the canonical location and operationalizes via procedure and
assertion.

### 3.2 Acceptance Criteria

Gate 2 passes when ALL of the following are true:

- The template execution log contains **zero records with `severity: error`**.
- The template execution log contains **zero records with `severity: warning`**.
- Every potential failure that the verbatim Gate 2 text enumerates — CVE database lookup failure, manifest
  parse error, grade computation warning, and any other failure mode in
  [`./troubleshooting.md`](./troubleshooting.md) § 2 — surfaces as an **explicit `Insufficient Data` cell** in
  the rendered PDF, NOT as a silent omission, NOT as a suppressed warning.
- The Failure-Mode-to-Cell-Value mapping in [`./troubleshooting.md`](./troubleshooting.md) § 2 is the canonical
  inventory of what surfaces as `Insufficient Data`; Gate 2 verifies that the running template adheres to that
  inventory.

### 3.3 Single-Command Execution

```bash
blitzy validate templates/technology-estate-report --gate gate2
```

The command runs the template against the same Gate 1 test repository per [§ 2.3 Test
Repository](#23-test-repository) and captures the structured log. The Gate 2 assertion runs over the captured
log; no additional repository ingestion is required beyond the Gate 1 invocation.

### 3.4 Reviewer Verification Procedure

1. Run the command in [§ 3.3 Single-Command Execution](#33-single-command-execution).
2. Inspect the structured log for any record with `severity: error` or `severity: warning`. The validator
   emits the log path to stdout and stores it under the run's output directory per
   [`./usage.md`](./usage.md) § 6.3.
3. For each `severity: error` or `severity: warning` record (if any), confirm that the corresponding cell in
   the PDF renders the literal value `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md)
   § 2. The mapping is one-to-one: one log record per failed `(application_id, facet)` pair, one
   `Insufficient Data` cell per failed pair.
4. If a `severity: error` or `severity: warning` record does NOT correspond to a visible `Insufficient Data`
   cell, **Gate 2 fails** (silent suppression detected). The reviewer captures the offending log record
   identifier and the PDF cell coordinate for remediation.
5. If no `severity: error` or `severity: warning` records exist, Gate 2 passes trivially. Note that this
   trivial pass implies that no failure modes were exercised by the test repository; reviewers may choose to
   run Gate 2 against a deliberately failure-inducing repository scope to exercise the
   `Insufficient Data` rendering path; see [§ 3.5 Counter-Example (What Gate 2 Catches)](#35-counter-example-what-gate-2-catches).

### 3.5 Counter-Example (What Gate 2 Catches)

Consider a CVE Scanner that encounters HTTP 5xx from BOTH the NVD CVE API v2.0 AND the OSV API v1
simultaneously for a given `(application_id, facet=security)` lookup. Per
[`./troubleshooting.md`](./troubleshooting.md) § 2 and the dual-source-failure rule in
[`./facets.md`](./facets.md) § Security Summary, this double-failure MUST render the Security cell as
`Insufficient Data`. If the CVE Scanner instead emits a normal letter grade (e.g., `B`) with empty
severity-tier counts in `raw_data.severity_counts`, **Gate 2 fails**: the failure was silently suppressed; the
reviewer is presented with a graded cell whose underlying data is incomplete. This counter-example is the
canonical illustration of why Gate 2's no-silent-suppression assertion is independent of the existence of
`severity: error` log records — a graded cell with empty raw data is itself a Gate 2 violation regardless of
log severity.

## 4. Gate 8 — Integration Sign-Off Checklist

### 4.1 Statement (Cited)

The canonical, verbatim text of Gate 8 is in [`../template.md`](../template.md) § 6.1.3. This document does
**not** duplicate the verbatim text; it cites the canonical location and operationalizes via procedure and
assertion.

Gate 8 is **independent of unit-test pass rate** — it is an integration-level sign-off. A package whose unit
tests all pass MAY still fail Gate 8 if any of the four sign-off items below fails; conversely, a package whose
unit-test suite reports a flaky failure MAY still pass Gate 8 if the four sign-off items are independently
verified. This independence is the verbatim Gate 8 modifier "(independent of unit test pass rate)" reproduced
in [`../template.md`](../template.md) § 6.1.3.

### 4.2 The Four Items

Gate 8 has exactly four sub-items, each operationalized in its own subsection below. The four items appear in
the canonical user-supplied order:

1. **Live smoke test** — § 4.3
2. **API contract verification** — § 4.4
3. **Grade history verification** — § 4.5
4. **Rubric verification** — § 4.6

### 4.3 Item 1: Live Smoke Test

This item re-runs Gate 1 per [§ 2 Gate 1 — End-to-End Boundary
Verification](#2-gate-1--end-to-end-boundary-verification). Gate 1's verification artifact (the generated PDF
from the live test repository) is also the verification artifact for Gate 8 Item 1; the two checks share an
artifact even though they are recorded as distinct acceptance items.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --gate gate8.item1
```

The reviewer verification procedure for Gate 8 Item 1 is identical to [§ 2.5 Reviewer Verification
Procedure](#25-reviewer-verification-procedure) for Gate 1. To minimize redundancy, Gate 8 Item 1 MAY reuse the
artifact from a recently-passed Gate 1 run rather than re-invoking the template; the reviewer records this
reuse explicitly in the Gate 8 sign-off log so that audit trails remain unambiguous.

### 4.4 Item 2: API Contract Verification

For each external API documented in [`./api-integrations.md`](./api-integrations.md), Gate 8 Item 2 confirms
that the actual response shape returned by the live API matches the documented contract. The five external APIs
in scope are:

- **GitHub REST API** — [`./api-integrations.md`](./api-integrations.md) § GitHub
- **GitLab REST API** — [`./api-integrations.md`](./api-integrations.md) § GitLab
- **endoflife.date API v1** — [`./api-integrations.md`](./api-integrations.md) § endoflife.date API v1
- **NVD CVE API v2.0** — [`./api-integrations.md`](./api-integrations.md) § NVD CVE API v2.0
- **OSV API v1** — [`./api-integrations.md`](./api-integrations.md) § OSV API v1

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --gate gate8.item2
```

Reviewer Verification Procedure:

1. Provision `GITHUB_TOKEN` per [`./usage.md`](./usage.md) § 3 (and optionally `GITLAB_TOKEN` and
   `NVD_API_KEY` if the chosen test scope exercises those APIs).
2. Run the command in [§ 4.4 Item 2: API Contract Verification](#44-item-2-api-contract-verification). The
   command issues one canonical request to each external API. Suggested canonical requests (the validator
   selects equivalent endpoints if the underlying API documentation has updated):
   - `GET https://api.github.com/repos/octocat/Hello-World` (GitHub REST API)
   - `GET https://gitlab.com/api/v4/projects/<known-public-project-id>` (GitLab REST API; SKIP if no
     `GITLAB_TOKEN` provisioned)
   - `GET https://endoflife.date/api/v1/products/python/` (endoflife.date API v1)
   - `GET https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2017-5638` (NVD CVE API v2.0; the
     CVE-2017-5638 record is a stable, well-known Apache Struts vulnerability suitable as a test query)
   - `POST https://api.osv.dev/v1/query` with body `{"package":{"name":"log4j","ecosystem":"Maven"},"version":"2.14.0"}`
     (OSV API v1)
3. For each response, assert that the documented JSON keys per [`./api-integrations.md`](./api-integrations.md)
   are present and have the documented types. Specifically: the validator expects the contract-documented
   top-level keys, the documented enumerations for status/severity fields, and the documented date-time
   formats (ISO 8601 / RFC 3339).
4. If any response shape has changed — for example, a breaking change in the endoflife.date API v1 per its
   beta-status caveat noted in [`./api-integrations.md`](./api-integrations.md) § endoflife.date API v1 —
   **Gate 8 Item 2 fails** and [`./api-integrations.md`](./api-integrations.md) MUST be updated to reflect the
   new contract before re-running. The Gate 8 Item 2 failure log records the API name, the offending response
   path, and the diff between expected and actual shapes.

### 4.5 Item 3: Grade History Verification

This item operationalizes the multi-run continuity contract documented in [`./grade-history.md`](./grade-history.md)
§ 8 Worked Example: Three Sequential Runs and is the canonical realization of [Domain Success Criterion 4 —
Grade History Continuous Across Three Sequential Runs](#75-criterion-4--grade-history-continuous-across-three-sequential-runs)
(per [Rule R7](../template.md#r7--application-identity-stability) verification "grade history for a repo is
continuous across three sequential runs with no duplicate or orphaned entries").

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --gate gate8.item3
```

Reviewer Verification Procedure:

1. Run the command in [§ 4.5 Item 3: Grade History Verification](#45-item-3-grade-history-verification). The
   command internally invokes the template **three times** against the SAME test repository scope, with three
   distinct `run_date` values supplied as ISO 8601 datetimes (e.g., `2025-09-01T08:00:00Z`,
   `2025-10-01T08:00:00Z`, `2025-11-01T08:00:00Z`). The validator may use the live wall-clock instead, with
   the three runs separated by enough wall-clock time to produce distinct ISO 8601 datetimes; the choice is
   operational and either approach satisfies Gate 8 Item 3.
2. Inspect the persistence store. Assert that **exactly 12 records exist**: 1 test repository × 4 facets ×
   3 runs = 12 records. The persistence record schema and the storage key shape are in
   [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) and
   [`./grade-history.md`](./grade-history.md) § 2 Storage Key.
3. Assert that each `(application_id, facet)` pair has exactly **3 records with distinct `run_date` values**.
   No `(application_id, facet)` pair is missing a record from any of the three runs (continuity), and no
   `(application_id, facet, run_date)` tuple appears twice (no duplicates).
4. Open the third PDF (the most recent run). Assert that each of its four matrix cells renders the prior grade
   in the format `<current> ← prev: <prior_grade> | <prior_run_date>` per
   [Rule R3](../template.md#r3--grade-history-fidelity) and the verbatim cell-format example
   `B  ←  prev: C  |  2025-10-01` reproduced in [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format —
   where `<prior_grade>` and `<prior_run_date>` match the second run's persistence record for the same
   `(application_id, facet)` pair.
5. If any of the three assertions fails (record count ≠ 12, or any `(application_id, facet)` pair has fewer
   than 3 distinct `run_date` records, or the third PDF's prior-grade slot does not match the second run's
   persistence record), Gate 8 Item 3 fails. The reviewer records the offending pair and the diff for
   remediation per [`./grade-history.md`](./grade-history.md) § 3 Immutability Contract.

### 4.6 Item 4: Rubric Verification

This item operationalizes the verbatim verification clause of
[Rule R1](../template.md#r1--rubric-editability): "generating a report with two different rubric inputs for
the same dataset produces two different grade outputs". The canonical procedure is documented in
[`./grading-engine.md`](./grading-engine.md) § 6 R1 Verification Procedure; this section binds the procedure
to a single-command execution path and an integration-level assertion suitable for Gate 8 sign-off.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --gate gate8.item4
```

Reviewer Verification Procedure:

1. Run the command in [§ 4.6 Item 4: Rubric Verification](#46-item-4-rubric-verification). The command
   internally invokes the template **twice** against the SAME test repository scope, with **two different
   rubric files** that differ in at least one threshold for a facet whose raw data straddles the changed
   threshold:
   - `rubric-A.yaml` — the canonical example rubric in
     [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml).
   - `rubric-B.yaml` — a rubric derived from `rubric-A.yaml` with at least one threshold tightened or loosened
     so that the test repository's raw data falls into a different grade tier.
   The exact rubric difference convention is documented in [`./grading-engine.md`](./grading-engine.md) § 6.
2. Compare the two PDFs. Assert that **at least one `(application, facet)` cell** displays a different letter
   grade between the two runs. The validator reports the diff coordinates and the two grade letters in its
   stdout.
3. If both PDFs are byte-identical (other than the run-date timestamps embedded in the PDF metadata and the
   prior-grade slots), **Gate 8 Item 4 fails** — the rubric is being ignored or the engine is hardcoding
   thresholds, which is a [Rule R1](../template.md#r1--rubric-editability) violation. The reviewer records
   the byte-identical-PDFs finding and remediates per [`./grading-engine.md`](./grading-engine.md) § 6 R1
   Verification Procedure.

### 4.7 All Four Items Required

Gate 8 passes when ALL FOUR items pass. Partial passes (e.g., Items 1, 2, 3 pass but Item 4 fails) are
recorded individually but **do NOT constitute Gate 8 acceptance**. The validator's pass/fail summary at the
end of `--gate gate8` reports each item separately and emits an aggregate `Gate 8: PASS` only when all four
items pass.

## 5. Gate 9 — Integration Wiring Verification

### 5.1 Statement (Cited)

The canonical, verbatim text of Gate 9 is in [`../template.md`](../template.md) § 6.1.4. This document does
**not** duplicate the verbatim text; it cites the canonical location and operationalizes via procedure and
assertion.

The verbatim Gate 9 text contains the critical clause: components that pass unit tests in isolation but are
NOT wired into the execution path do **NOT count as delivered**. Gate 9 is the integration-wiring assertion
that prevents this failure mode by requiring every named analysis component to be exercised by at least one
end-to-end test that traverses the full chain from template invocation to PDF output.

### 5.2 The Seven Components

Gate 9 covers exactly **seven analysis components** in the canonical order from
[`../template.md`](../template.md) § 7 Architecture & Component Reachability and
[`./architecture.md`](./architecture.md) § 3 Component Inventory:

1. **Tech Stack Detector**
2. **Maturity Analyzer**
3. **CVE Scanner**
4. **Complexity Extractor**
5. **Grading Engine**
6. **Grade Persistence Store**
7. **PDF Renderer**

The seven names are preserved exactly as user-stated; the snake-case facet identifiers (`tech_stack`,
`maturity`, `security`, `complexity`) used in [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json)
and [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) are the persistence-layer keys that map
to the first four components above.

### 5.3 Component Reachability Matrix

The canonical reachability matrix is maintained in [`./architecture.md`](./architecture.md) § 6 Component
Reachability Matrix; this section reproduces the test-ID mapping for direct reviewer reference:

| Component               | End-to-End Test ID    |
|-------------------------|-----------------------|
| Tech Stack Detector     | `e2e-tech-stack`      |
| Maturity Analyzer       | `e2e-maturity`        |
| CVE Scanner             | `e2e-cve-scanner`     |
| Complexity Extractor    | `e2e-complexity`      |
| Grading Engine          | `e2e-grading-engine`  |
| Grade Persistence Store | `e2e-grade-history`   |
| PDF Renderer            | `e2e-pdf-render`      |

Each test ID corresponds to an end-to-end test that traverses the **full execution chain from template
invocation to PDF output**, exercising the named component as part of the chain. A test that exercises ONLY
the named component in isolation — e.g., a unit test that calls the Tech Stack Detector directly without
invoking the template entry point — does NOT satisfy Gate 9; the verbatim Gate 9 text is unambiguous on this
point.

### 5.4 Single-Command Execution

```bash
blitzy validate templates/technology-estate-report --gate gate9
```

The command runs all seven `e2e-*` tests in sequence against the same Gate 1 test repository per
[§ 2.3 Test Repository](#23-test-repository). The seven tests share the underlying repository scope but each
asserts on a different aspect of the run — the named component's contribution to the final PDF or to the
intermediate persistence record.

### 5.5 Reviewer Verification Procedure

1. Run the command in [§ 5.4 Single-Command Execution](#54-single-command-execution).
2. For each of the seven test IDs, assert ALL of the following:
   - The test **starts at the template entry point** ([`../template.md`](../template.md)). The validator
     records the test's invocation path; the path MUST begin at template.md.
   - The test **traverses the full execution chain to the PDF Renderer**. The validator confirms that the
     PDF Renderer is the last component executed and that the test produces a PDF artifact OR a persistence
     record whose downstream renderer call is verifiable.
   - The named component **is exercised during the run**. Verification is by structured-log records that
     mention the component's name (e.g., `component=tech-stack-detector` log entries) OR by the cell content
     in the rendered PDF reflecting the component's output (e.g., a non-empty Tech Stack Summary cell
     demonstrates the Tech Stack Detector ran).
   - The test produces a **verifiable artifact** on success: a PDF file (for tests whose downstream
     renderer call completes) or a persistence record (for the Grade Persistence Store test, whose downstream
     renderer call is the next-run's lookup).
3. If any of the seven components passes ONLY via unit test (not end-to-end), **Gate 9 fails** per the verbatim
   Gate 9 requirement. The reviewer captures the offending component name and the missing test-ID for
   remediation.
4. Capture the seven test outcome records as the Gate 9 verification artifact; retain per
   [§ 6.5 Artifact Retention](#65-artifact-retention).

### 5.6 Acceptance Criteria

Gate 9 passes when ALL of the following are true:

- All seven `e2e-*` tests pass.
- Each test demonstrably exercises the named component within an end-to-end chain (per the verification
  procedure above).
- No component is "isolated only" (passing unit tests but not wired into the execution path).

Partial passes are recorded but do NOT constitute Gate 9 acceptance.


## 6. Gate 10 — Test Execution Binding

### 6.1 Statement (Cited)

The canonical, verbatim text of Gate 10 is in [`../template.md`](../template.md) § 6.1.5. This document does
**not** duplicate the verbatim text; it cites the canonical location and operationalizes via procedure and
assertion.

The verbatim Gate 10 text contains the critical clause: tests **without a documented execution path** do NOT
constitute passing validation. Gate 10 is the discoverability contract that ensures every assertion in this
package can be independently re-run by a reviewer using only this document, the credential names in
[`./usage.md`](./usage.md) § 3, and a Bash shell.

### 6.2 Acceptance Criteria

Gate 10 passes when ALL of the following are true:

- All validation tests in this document have a **single-command execution path** that:
  1. Provisions required credentials by referencing the env-var names `GITHUB_TOKEN`, `GITLAB_TOKEN`, and
     `NVD_API_KEY` (the canonical credential references in [`../template.md`](../template.md) § 8 and
     [`./usage.md`](./usage.md) § 3 — never literal secret values).
  2. Runs the template against a **designated test repository** (per [§ 2.3 Test
     Repository](#23-test-repository); the pointer is in [`../config/facets.yaml`](../config/facets.yaml)
     `validation.gate1_test_repo`).
  3. Asserts on the **generated PDF content** per the per-gate verification procedures in §§ 2.5, 4.3, 4.4,
     4.5, 4.6, 5.5 above.
- The single-command execution path runs ALL gates and ALL criteria in sequence and emits a unified pass/fail
  summary (per [§ 6.4 Reviewer Verification
  Procedure](#64-reviewer-verification-procedure)).
- The single-command execution path has a stable, documented invocation that does NOT depend on undocumented
  environment configuration beyond the three named credentials.

### 6.3 The Single-Command Execution Path

The canonical single-command execution path required by Gate 10 — the operational realization of the entire
validation suite — is:

```bash
blitzy validate templates/technology-estate-report
```

This command runs the entire validation suite in sequence: Gates 1, 2, 8 (all four items), 9, and 10 (the
self-referential check that the command itself ran), plus all five Domain-Specific Success Criteria from § 7
below. At the end of the run, the command emits a single pass/fail summary line.

Required environment variables:

```bash
export GITHUB_TOKEN="<gha_or_pat>"   # required for GitHub source repos
export GITLAB_TOKEN="<glpat>"        # optional; required only if GitLab repos in test scope
export NVD_API_KEY="<nvd_key>"       # optional; strongly recommended to lift NVD rate limits
```

Cross-reference [`./usage.md`](./usage.md) § 3 for credential provisioning runbooks (how to create a GitHub
PAT, how to mint a GitLab PAT, how to register for an NVD API key) and [`./api-integrations.md`](./api-integrations.md)
§ 4–§ 6 for the rate-limit and retry semantics that explain why `NVD_API_KEY` is strongly recommended.

> **Security note:** Per the AAP § 0.10.2 "No Redundancy Rule" and the package-wide convention, this document
> never includes literal secret values. The `<gha_or_pat>`, `<glpat>`, and `<nvd_key>` placeholders above are
> placeholder text — reviewers replace them with values sourced from their organization's secrets store, never
> committed to the repository.

### 6.4 Reviewer Verification Procedure

1. Provision the three credentials per [§ 6.3 The Single-Command Execution Path](#63-the-single-command-execution-path)
   and [`./usage.md`](./usage.md) § 3. Confirm via `printenv GITHUB_TOKEN | head -c 8` (or equivalent) that
   the env vars are set in the current shell; never echo full token values.
2. Run the single command in [§ 6.3](#63-the-single-command-execution-path).
3. Assert that the command emits a final summary line `Validation: PASS` with all 10 acceptance items marked
   passing (or an equivalent format documented by the validator's stdout contract). The 10 acceptance items
   are: Gate 1, Gate 2, Gate 8 (one aggregate item; the four sub-items are reported individually but
   summarized at the gate level), Gate 9, Gate 10 (self-referential), and Domain Criteria 1, 2, 3, 4, 5.
4. If any item fails, the command emits `Validation: FAIL` with the failing item names. The reviewer remediates
   per the per-gate failure-mode notes in §§ 2.6, 3.5, 4.7, 5.6 and the per-criterion verification procedures
   in §§ 7.2 through 7.6.
5. The command's exit code is non-zero on FAIL and zero on PASS; reviewers integrating the suite into CI
   pipelines may rely on the exit code as the canonical pass/fail signal.

### 6.5 Artifact Retention

- The **PDF artifacts** from the run (one per gate that produces a PDF — Gate 1, Gate 8 Items 1 and 4, the
  three Gate 8 Item 3 sequential runs, and the seven Gate 9 `e2e-*` tests where each produces a PDF) are
  retained at the path documented in the run's structured log. The default base path is
  `~/blitzy-reports/validation-<run_date_iso>/`; the configurable output directory is documented in
  [`./usage.md`](./usage.md) § 6.3.
- The **structured log** itself — a JSON or JSONL file emitted to the run directory — is retained for at least
  the duration that the persistence store retains records. The exact retention window is an organizational
  policy concern and is NOT specified by this template; reviewers SHOULD consult their organization's audit
  retention policy.
- The **Gate 8 Item 3 persistence records** (the 12 records produced by the three sequential runs) are
  retained in the persistence store per [`./grade-history.md`](./grade-history.md) § 3 Immutability Contract;
  no validator action is required to retain them beyond running the suite.
- The **Gate 9 outcome records** (one per `e2e-*` test) are retained in the run's structured log under the
  dedicated `gate_9_outcomes` JSON key; the exact JSON shape is documented in [`./usage.md`](./usage.md) § 6.3.

This template does NOT enforce retention beyond emitting artifacts to a configurable output directory.
Operational concerns (offsite backup, encryption at rest, retention windows) are external to this template.

## 7. Domain-Specific Success Criteria

### 7.1 Statement (Cited)

The canonical, verbatim text of the five Domain-Specific Success Criteria is in
[`../template.md`](../template.md) § 6.2. This document does **not** duplicate the verbatim text; it cites the
canonical location and operationalizes each criterion via procedure and assertion.

The five criteria are reproduced below as **ID labels only** (one short label per criterion); the full
verbatim user prose remains in [`../template.md`](../template.md) § 6.2:

- **Criterion 1** — Every Repository in Scope Produces a Populated Matrix Row (§ 7.2)
- **Criterion 2** — Maturity Grade Correctly Reflects EOL Status (§ 7.3)
- **Criterion 3** — Security Summary CVE Counts Match NVD/OSV Lookup (§ 7.4)
- **Criterion 4** — Grade History Continuous Across Three Sequential Runs (§ 7.5)
- **Criterion 5** — Executive Summary Distribution Counts Match Sum of Individual Application Grades (§ 7.6)

### 7.2 Criterion 1 — Every Repository in Scope Produces a Populated Matrix Row

**Operationalization:** for every `application_id` in the run scope, the matrix table in the rendered PDF
contains exactly one row for that application. No repository is silently dropped from the matrix; no
repository is duplicated as multiple rows.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --criterion criterion1
```

Reviewer Verification Procedure:

1. Inspect the run scope file (e.g., `~/scopes/test-scope.yaml`) — the file that lists the `org/repo` entries
   passed to the template invocation. The convention for scope files is documented in
   [`./usage.md`](./usage.md) § 4.
2. Inspect the generated PDF's Application Matrix Table; count the rows.
3. Assert that the matrix row count **equals** the scope file entry count (no missing rows; no extra rows).
4. Assert that **every** scope entry's `org/repo` appears in the Application column of the matrix exactly
   once (no duplicates; no missing entries).
5. Cross-reference: [Rule R2](../template.md#r2--facet-completeness) (facet completeness within the row) and
   [Rule R7](../template.md#r7--application-identity-stability) (identity stability of the row label —
   `org/repo` is the canonical row identifier).

### 7.3 Criterion 2 — Maturity Grade Correctly Reflects EOL Status

**Operationalization:** for each repository in the run scope, the Maturity facet's underlying
technical-debt score correctly reflects the endoflife.date EOL status for ALL detected runtimes and
libraries — i.e., a runtime that endoflife.date reports as past its EOL date appears in the Maturity facet's
`raw_data.eol_runtimes[]` list, and the technical-debt score is non-zero whenever any EOL runtime is detected.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --criterion criterion2
```

Reviewer Verification Procedure:

1. The validator inspects the test repository's manifests and identifies a **known-EOL runtime** — for
   example, Python 2.7 (EOL 2020-01-01), Node.js 12 (EOL 2022-04-30), or Java 8 (EOL varies by vendor; OpenJDK
   8 EOL was 2023-11). Each of these is past its EOL date per endoflife.date and is suitable as a positive
   test case.
2. The validator queries endoflife.date directly per [`./api-integrations.md`](./api-integrations.md) § 4
   endoflife.date API v1 and confirms `eol: <past date>` for the chosen runtime — i.e., the API returns a
   date string that is strictly less than the current date.
3. The validator runs the template and inspects the run's `raw_data` for the Maturity facet of the test
   repository (the `raw_data` object in the persistence record per
   [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.raw_data`).
4. Assert: the technical-debt score reflects the EOL runtime — specifically,
   `raw_data.technical_debt_score > 0` AND the EOL runtime appears in `raw_data.eol_runtimes[]` with the
   `endoflife.date` lookup result attached.
5. Cross-reference: [Rule R2](../template.md#r2--facet-completeness) (the cell renders a grade or
   `Insufficient Data`, not a silent `B`) and [`./facets.md`](./facets.md) § Maturity Summary (the canonical
   detection algorithm and per-runtime slug resolution rules).

### 7.4 Criterion 3 — Security Summary CVE Counts Match NVD/OSV Lookup

**Operationalization:** for a known-vulnerable dependency version present in the test repository, the
Security facet's per-severity-tier CVE counts match the counts returned by direct queries to the NVD CVE API
v2.0 and the OSV API v1, after deduplication per [`./facets.md`](./facets.md) § Security Summary §
Deduplication.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --criterion criterion3
```

Reviewer Verification Procedure:

1. The validator identifies a **known-vulnerable dependency** in the test repository — for example,
   `log4j-core 2.14.0` in a Maven `pom.xml`, which has multiple Critical CVEs (including CVE-2021-44228 /
   "Log4Shell"). Equivalent stable test cases include `Django 1.11.0` (Python) and `lodash 4.17.10`
   (npm); the validator selects whichever is present in the test repository's manifest.
2. The validator queries NVD and OSV directly per [`./api-integrations.md`](./api-integrations.md) §§ 5, 6
   and records the per-severity CVE counts (Critical, High, Medium, Low, plus total) per
   [Rule R4](../template.md#r4--cve-severity-breakdown). The per-severity tier mapping (CVSS v3.1 base score
   to tier label) is in [`./facets.md`](./facets.md) § Security Summary § Severity Tier Counting and is
   reproduced as a Mermaid diagram there.
3. The validator runs the template and inspects the run's Security facet `raw_data` for the test
   repository's persistence record.
4. Assert: the per-severity counts in `raw_data.severity_counts` (or the equivalent canonical field name per
   [`./facets.md`](./facets.md) § Security Summary) **match** the directly-queried counts after applying the
   NVD-OSV deduplication rule. Per the deduplication rule in [`./facets.md`](./facets.md) § Security Summary §
   Deduplication, a CVE that appears in BOTH NVD and OSV is counted once, NOT twice; equivalent CVEs across
   the two databases are merged by CVE ID.
5. Assert: `scan_metadata.timestamp` (ISO 8601 datetime) and `scan_metadata.sources` (a list containing one
   or more of `NVD`, `OSV`) are present in the persistence record per
   [Rule R9](../template.md#r9--cve-attribution) and the schema constraint in
   [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json)
   `allOf[security-attribution-conditional]`.
6. Cross-reference: [Rule R4](../template.md#r4--cve-severity-breakdown) (severity breakdown),
   [Rule R9](../template.md#r9--cve-attribution) (attribution), and [`./facets.md`](./facets.md) §
   Security Summary (the canonical detection and counting algorithm).

### 7.5 Criterion 4 — Grade History Continuous Across Three Sequential Runs

**Operationalization:** per [`./grade-history.md`](./grade-history.md) § 8 Worked Example, run the template
three times against the same scope; assert grade-history continuity per
[Rule R3](../template.md#r3--grade-history-fidelity) (grade history fidelity) and the immutability contract
in [`./grade-history.md`](./grade-history.md) § 3 Immutability Contract.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --criterion criterion4
```

This criterion **shares the implementation** with [Gate 8 Item 3](#45-item-3-grade-history-verification); the
validator MAY reuse the Gate 8 Item 3 verification artifacts (the 12 persistence records and the third PDF)
rather than re-invoking three sequential runs. The reviewer records this reuse explicitly in the Criterion 4
sign-off log so that audit trails remain unambiguous.

Reviewer Verification Procedure: see [§ 4.5 Reviewer Verification
Procedure](#45-item-3-grade-history-verification) for the canonical step-by-step.

Cross-reference: [Rule R3](../template.md#r3--grade-history-fidelity) (grade history fidelity),
[Rule R7](../template.md#r7--application-identity-stability) (identity stability),
[Rule R10](../template.md#r10--new-repo-compatibility) (new repo compatibility), and
[`./grade-history.md`](./grade-history.md) § 3 Immutability Contract.

### 7.6 Criterion 5 — Executive Summary Distribution Counts Match Sum of Individual Application Grades

**Operationalization:** per [`./executive-summary.md`](./executive-summary.md) § 3 Grade Distribution per
Facet, the sum of `distribution[f][*]` over all eight grade values (`A`, `B`, `C`, `D`, `F`, `TBD`, `N/A`,
`InsufficientData`) equals `total_applications` for every facet `f` in the four-facet set
{`tech_stack`, `maturity`, `security`, `complexity`}; AND the per-facet, per-grade counts in the Executive
Summary match the per-facet, per-grade tally in the Application Matrix Table for each facet column.

Single-command execution:

```bash
blitzy validate templates/technology-estate-report --criterion criterion5
```

Reviewer Verification Procedure:

1. Inspect the generated PDF's Executive Summary, specifically the "A–F grade distribution per facet" content
   item (per [`../template.md`](../template.md) § 3.5 Executive Summary).
2. For each of the four facets, sum the eight grade-distribution counts (the count of `A` plus the count of
   `B` plus … plus the count of `InsufficientData`).
3. Assert: for every facet `f`, the sum equals the count printed in "Total applications in scope" (the first
   content item of the Executive Summary).
4. For each facet, count the matrix-table rows by their facet-cell grade letter — i.e., walk the Application
   Matrix Table column-by-column and tally the cell values into the eight grade buckets per facet.
5. Assert: for every facet `f`, the per-facet, per-grade counts in the Executive Summary match the per-facet,
   per-grade tally derived from the matrix table. A mismatch (e.g., the Executive Summary reports 3 `A` grades
   for Maturity but the matrix table has 4 rows with `A` in the Maturity column) is a Criterion 5 failure.
6. Cross-reference: [Rule R2](../template.md#r2--facet-completeness) (every cell counted, none silently
   omitted; the eight-bucket tally MUST sum to the total) and [`./executive-summary.md`](./executive-summary.md)
   § 3.2 Computation (the canonical aggregation formula).

### 7.7 All Five Criteria Required

Delivery acceptance requires **ALL FIVE criteria** to pass in addition to all five gates. Partial passes are
recorded individually but do NOT constitute acceptance. The single-command path in
[§ 6.3](#63-the-single-command-execution-path) runs all 10 acceptance items (5 gates plus 5 criteria) in
sequence and emits a unified pass/fail summary.


## 8. Single-Command Execution Path Summary

### 8.1 The Canonical Command

The canonical Gate 10 single-command execution path — the operational realization of the entire validation
suite — is:

```bash
blitzy validate templates/technology-estate-report
```

With required environment variables provisioned per [`./usage.md`](./usage.md) § 3:

```bash
export GITHUB_TOKEN="..."   # required
export GITLAB_TOKEN="..."   # optional; required only if GitLab repos in test scope
export NVD_API_KEY="..."    # optional but strongly recommended
```

The `"..."` placeholders above are intentional; reviewers replace them with values sourced from their
organization's secrets store. This document never includes literal secret values.

When invoked with no flags, the command runs ALL gates (1, 2, 8, 9, 10) and ALL criteria (1, 2, 3, 4, 5) in
sequence, emits per-gate and per-criterion pass/fail summaries to stdout, and writes a JSON summary report
plus the per-gate artifacts to the run's output directory. The command's exit code is non-zero on any failure
and zero only when every gate and every criterion passes.

### 8.2 Per-Gate Subcommands

Each gate and each criterion has a dedicated subcommand flag for targeted execution during incremental
development. The complete subcommand inventory:

| Gate / Criterion              | Subcommand Flag         |
|-------------------------------|-------------------------|
| Gate 1 (Live Smoke)           | `--gate gate1`          |
| Gate 2 (Zero-Warning)         | `--gate gate2`          |
| Gate 8 Item 1                 | `--gate gate8.item1`    |
| Gate 8 Item 2                 | `--gate gate8.item2`    |
| Gate 8 Item 3                 | `--gate gate8.item3`    |
| Gate 8 Item 4                 | `--gate gate8.item4`    |
| Gate 9                        | `--gate gate9`          |
| Criterion 1                   | `--criterion criterion1`|
| Criterion 2                   | `--criterion criterion2`|
| Criterion 3                   | `--criterion criterion3`|
| Criterion 4                   | `--criterion criterion4`|
| Criterion 5                   | `--criterion criterion5`|
| All (Gate 10 single-command)  | _(no flag — runs everything)_ |

Note: there is no dedicated `--gate gate10` subcommand. Gate 10 is the **self-referential** assertion that the
single-command path itself exists and runs to completion; the single-command path with no flags satisfies
Gate 10 automatically. Reviewers verifying Gate 10 in isolation confirm that the no-flag invocation runs and
emits a valid summary; the verification is documented in [§ 6.4 Reviewer Verification
Procedure](#64-reviewer-verification-procedure).

### 8.3 Output Artifacts

The single-command path emits the following artifacts to the run's output directory (default
`~/blitzy-reports/validation-<run_date_iso>/`; configurable per [`./usage.md`](./usage.md) § 6.3):

- **`summary.json`** — a JSON document with one record per gate and one record per criterion, each carrying
  `pass | fail`, the per-item assertion outcomes, the artifact path(s), and the wall-clock duration.
- **`gate1-<run_date_iso>.pdf`** — the Gate 1 live smoke test PDF.
- **`gate8-item1-<run_date_iso>.pdf`** — the Gate 8 Item 1 PDF (MAY be the same artifact as Gate 1 per
  [§ 4.3 Item 1: Live Smoke Test](#43-item-1-live-smoke-test)).
- **`gate8-item3-runN-<run_date_iso>.pdf`** for `N ∈ {1, 2, 3}` — the three sequential Gate 8 Item 3 PDFs.
- **`gate8-item4-rubricA-<run_date_iso>.pdf`** and **`gate8-item4-rubricB-<run_date_iso>.pdf`** — the two
  rubric-comparison PDFs.
- **`gate9-<test_id>-<run_date_iso>.pdf`** for each of the seven `e2e-*` test IDs — one PDF per Gate 9
  end-to-end test (test IDs are listed in [§ 5.3 Component Reachability
  Matrix](#53-component-reachability-matrix)).
- **`structured.log.jsonl`** — the structured log emitted by the run, one JSONL record per log entry. Records
  include per-component invocation entries, per-API call entries (rate-limit headers, retry attempts), and
  per-record persistence entries.
- **`gate_9_outcomes.json`** — the seven Gate 9 outcome records (one per `e2e-*` test).

The per-criterion subcommand invocations write artifacts with the prefix `criterionN-<run_date_iso>-` for
`N ∈ {1, 2, 3, 4, 5}` to the same output directory.

## 9. Rule-to-Doc Cross-Reference Matrix

Per the AAP § 0.10.2 "Rule-to-Doc Cross-Reference Rule," every rule in the canonical R1–R10 set MUST be
cross-referenced from the document(s) that operationalize it AND the document that verifies it. The matrix
below is the canonical artifact that proves every rule has a documentation home and a verification procedure.

| Rule                                                                       | Operationalizing Document(s)                                                                                                              | Verification Procedure Document                                                                       |
|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| [R1](../template.md#r1--rubric-editability) (Rubric editability)           | [`./grading-engine.md`](./grading-engine.md), [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json), [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) | [Gate 8 Item 4](#46-item-4-rubric-verification)                                                       |
| [R2](../template.md#r2--facet-completeness) (Facet completeness)           | [`./facets.md`](./facets.md), [`./pdf-output.md`](./pdf-output.md), [`./troubleshooting.md`](./troubleshooting.md)                        | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Domain Criterion 1](#72-criterion-1--every-repository-in-scope-produces-a-populated-matrix-row) |
| [R3](../template.md#r3--grade-history-fidelity) (Grade history fidelity)   | [`./grade-history.md`](./grade-history.md), [`./pdf-output.md`](./pdf-output.md)                                                          | [Gate 8 Item 3](#45-item-3-grade-history-verification), [Domain Criterion 4](#75-criterion-4--grade-history-continuous-across-three-sequential-runs) |
| [R4](../template.md#r4--cve-severity-breakdown) (CVE severity breakdown)   | [`./facets.md`](./facets.md) § Security Summary, [`./api-integrations.md`](./api-integrations.md) § 5                                     | [Domain Criterion 3](#74-criterion-3--security-summary-cve-counts-match-nvdosv-lookup)                |
| [R5](../template.md#r5--complexity-placeholder-integrity) (Complexity placeholder) | [`./facets.md`](./facets.md) § Complexity, [`./pdf-output.md`](./pdf-output.md) § 5.4, [`./grading-engine.md`](./grading-engine.md) § 5 | [Gate 1](#2-gate-1--end-to-end-boundary-verification)                                                 |
| [R6](../template.md#r6--saas-data-sourcing) (SaaS data sourcing)           | [`./api-integrations.md`](./api-integrations.md) § 7 (allow-list)                                                                         | [Gate 1](#2-gate-1--end-to-end-boundary-verification) — egress observability                          |
| [R7](../template.md#r7--application-identity-stability) (Identity stability) | [`./grade-history.md`](./grade-history.md) § 2 Storage Key                                                                              | [Domain Criterion 4](#75-criterion-4--grade-history-continuous-across-three-sequential-runs)          |
| [R8](../template.md#r8--pdf-section-order) (PDF section order)             | [`./pdf-output.md`](./pdf-output.md) § 2                                                                                                  | [Gate 8 Item 1](#43-item-1-live-smoke-test)                                                           |
| [R9](../template.md#r9--cve-attribution) (CVE attribution)                 | [`./api-integrations.md`](./api-integrations.md) § 8, [`./facets.md`](./facets.md) § Security Summary                                     | [Domain Criterion 3](#74-criterion-3--security-summary-cve-counts-match-nvdosv-lookup)                |
| [R10](../template.md#r10--new-repo-compatibility) (New repo compatibility) | [`./grade-history.md`](./grade-history.md) § 6                                                                                            | [Gate 8 Item 3](#45-item-3-grade-history-verification), [Domain Criterion 4](#75-criterion-4--grade-history-continuous-across-three-sequential-runs) |

## 10. Gate-to-Component Cross-Reference Matrix

The Component Reachability Matrix in [§ 5.3](#53-component-reachability-matrix) is augmented here with the
gates and criteria that exercise each of the seven analysis components. This matrix is the canonical artifact
that proves every component is wired into AT LEAST one end-to-end test (per Gate 9) AND that the component's
contribution to the validation suite is observable via the running gates and criteria.

| Component                | Exercised By Gate(s)                                                                                                                  | Exercised By Criterion(a)                                                              |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| Tech Stack Detector      | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-tech-stack`)         | [Criterion 1](#72-criterion-1--every-repository-in-scope-produces-a-populated-matrix-row) |
| Maturity Analyzer        | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-maturity`)            | [Criterion 2](#73-criterion-2--maturity-grade-correctly-reflects-eol-status)              |
| CVE Scanner              | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-cve-scanner`)         | [Criterion 3](#74-criterion-3--security-summary-cve-counts-match-nvdosv-lookup)           |
| Complexity Extractor     | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-complexity`)          | [Criterion 1](#72-criterion-1--every-repository-in-scope-produces-a-populated-matrix-row) |
| Grading Engine           | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 8 Item 4](#46-item-4-rubric-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-grading-engine`) | [Criterion 1](#72-criterion-1--every-repository-in-scope-produces-a-populated-matrix-row), [Criterion 5](#76-criterion-5--executive-summary-distribution-counts-match-sum-of-individual-application-grades) |
| Grade Persistence Store  | [Gate 8 Item 3](#45-item-3-grade-history-verification), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-grade-history`)     | [Criterion 4](#75-criterion-4--grade-history-continuous-across-three-sequential-runs)     |
| PDF Renderer             | [Gate 1](#2-gate-1--end-to-end-boundary-verification), [Gate 8 Item 1](#43-item-1-live-smoke-test), [Gate 9](#5-gate-9--integration-wiring-verification) (`e2e-pdf-render`) | [Criterion 5](#76-criterion-5--executive-summary-distribution-counts-match-sum-of-individual-application-grades) |

Every one of the seven components is exercised by AT LEAST one gate and AT LEAST one criterion (with the
single exception of the Grade Persistence Store, whose contribution to the rendered PDF is indirect — the
Store is exercised by Gate 8 Item 3 and Gate 9's `e2e-grade-history`, and its output is the prior-grade
display verified by Criterion 4). No component is "isolated only" per the verbatim Gate 9 acceptance
criterion in [§ 5.6](#56-acceptance-criteria).

## 11. Acceptance Summary

Delivery is accepted when ALL of the following pass:

- [Gate 1 — End-to-End Boundary Verification](#2-gate-1--end-to-end-boundary-verification) (§ 2)
- [Gate 2 — Zero-Warning Build](#3-gate-2--zero-warning-build) (§ 3)
- [Gate 8 — Integration Sign-Off Checklist](#4-gate-8--integration-sign-off-checklist) — Items 1, 2, 3, 4
  (§§ 4.3, 4.4, 4.5, 4.6)
- [Gate 9 — Integration Wiring Verification](#5-gate-9--integration-wiring-verification) — all seven
  `e2e-*` tests (§ 5)
- [Gate 10 — Test Execution Binding](#6-gate-10--test-execution-binding) — single-command path runs to
  completion (§ 6)
- [Domain Criterion 1](#72-criterion-1--every-repository-in-scope-produces-a-populated-matrix-row) (§ 7.2)
- [Domain Criterion 2](#73-criterion-2--maturity-grade-correctly-reflects-eol-status) (§ 7.3)
- [Domain Criterion 3](#74-criterion-3--security-summary-cve-counts-match-nvdosv-lookup) (§ 7.4)
- [Domain Criterion 4](#75-criterion-4--grade-history-continuous-across-three-sequential-runs) (§ 7.5)
- [Domain Criterion 5](#76-criterion-5--executive-summary-distribution-counts-match-sum-of-individual-application-grades)
  (§ 7.6)

**Total: 10 acceptance items** — 5 gates (each gate counted as one acceptance item, with Gate 8's four sub-items
and Gate 9's seven sub-tests aggregated to the gate level for acceptance) plus 5 domain success criteria.
Running the canonical single-command path per [§ 6.3](#63-the-single-command-execution-path) covers all 10
items in sequence and emits a unified pass/fail summary.

**Partial passes do NOT constitute acceptance.** A delivery with 9 of 10 items passing is rejected; the
delivery cycle re-opens with remediation against the failing item. The validator's exit code is the canonical
machine-readable acceptance signal: zero on full acceptance, non-zero on any failure.

## 12. Cross-References

This document references the following package-internal artifacts. Every link is a relative path **within**
[`templates/technology-estate-report/`](..); no link reaches outside this directory per the
standalone-package property of [`../template.md`](../template.md) § 4 Boundaries & Preservation.

- [`../template.md`](../template.md) — canonical Rules R1–R10; canonical Gates 1, 2, 8, 9, 10; canonical
  Domain Success Criteria 1–5 (verbatim user prose lives here)
- [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) — rubric input contract; Gate 8 Item 4
- [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) — persistence record
  contract; Gate 8 Item 3, Criterion 4
- [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) — intermediate report data
  contract; Gate 1
- [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) — Gate 8 Item 4 rubric A
- [`../config/facets.yaml`](../config/facets.yaml) — `validation.gate1_test_repo` pointer for Gate 1's
  designated test repository
- [`./architecture.md`](./architecture.md) — component inventory diagram, single-repository run sequence
  diagram, and the canonical seven-component reachability matrix; Gate 9
- [`./facets.md`](./facets.md) — per-facet detection and counting algorithms; Criterion 2 (Maturity EOL
  detection), Criterion 3 (Security severity counting and deduplication)
- [`./grading-engine.md`](./grading-engine.md) — rubric verification procedure; Gate 8 Item 4
- [`./grade-history.md`](./grade-history.md) — storage key, immutability contract, and three-run worked
  example; Gate 8 Item 3, Criterion 4
- [`./executive-summary.md`](./executive-summary.md) — portfolio-level aggregation and per-facet distribution
  computation; Criterion 5
- [`./pdf-output.md`](./pdf-output.md) — Rule R8 section ordering, Rule R3 cell-rendering format; Gate 8
  Item 1
- [`./api-integrations.md`](./api-integrations.md) — GitHub, GitLab, endoflife.date, NVD CVE, OSV API
  contracts; Gate 8 Item 2
- [`./troubleshooting.md`](./troubleshooting.md) — Failure-Mode-to-Cell-Value mapping and structured-log
  retrieval; Gate 2
- [`./usage.md`](./usage.md) — credential provisioning, scope file convention, output directory
  configuration; Gate 10

This concludes the canonical operational reference for the Technology Estate Report Blitzy prompt template
package validation harness.
