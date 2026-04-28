# Executive Summary Aggregation — Technology Estate Report Template

## 1. Overview

The Executive Summary is the **portfolio-level rollup** rendered on page 1 of the PDF Technology Estate Report. Per [Rule R8](../template.md#r8--pdf-section-order) (verbatim text in [`../template.md`](../template.md) § 5 Rules), the Executive Summary MUST precede the Application Matrix Table; the Matrix Table MUST NOT be the first content element. This document specifies the deterministic aggregation rules that compute the Executive Summary's content; the rendering layout (page geometry, fonts, repeating headers, page break behavior) is documented in [`./pdf-output.md`](./pdf-output.md) § 6 Page Layout.

The Executive Summary is computed from the **same per-`(application_id, facet, run_date)` records** that drive the Matrix Table per [`./grade-history.md`](./grade-history.md) and [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json). Both the Executive Summary and the Matrix Table read the persistence-layer records produced by the four facet analyzers (Tech Stack, Maturity, Security, Complexity) and the grading engine; the Executive Summary aggregates portfolio-wide while the Matrix Table renders per-application. This shared data source guarantees that the Domain Success Criterion *"Executive summary renders correct portfolio-level grade distribution counts matching the sum of individual application grades"* (per [`../template.md`](../template.md) § 6.2 Domain-Specific Success Criteria) is operationalized as a **direct sum**: the histogram counts in [§ 3 Grade Distribution per Facet](#3-grade-distribution-per-facet) are exactly the column-wise tallies of the per-application grades rendered in the Matrix Table.

The five sub-sections of the Executive Summary, in canonical order, are: **Total Applications In Scope** ([§ 2](#2-total-applications-in-scope)), **Grade Distribution per Facet** ([§ 3](#3-grade-distribution-per-facet)), **Top Critical / High CVE Findings** ([§ 4](#4-top-critical--high-cve-findings)), **Highest Maturity Risk Applications** ([§ 5](#5-highest-maturity-risk-applications)), and **Trend versus Prior Run** ([§ 6](#6-trend-versus-prior-run)). These five sub-sections are the **complete inventory** authorized by [`../template.md`](../template.md) § 3.5 Executive Summary; **no sixth sub-section is added** by this template (per the minimal-change mandate documented in [`../template.md`](../template.md) § 4 Boundaries & Preservation). Per the AAP § 0.10.2 "CIO/CTO Audience Language Rule," all rendered labels and prose in the Executive Summary use **business-outcome language**; technical jargon (CVSS scoring, SBOM tooling, CPE strings, NVD/OSV transport details, manifest parsing, lockfile resolution) is reserved for the implementation-facing pages such as [`./facets.md`](./facets.md), [`./api-integrations.md`](./api-integrations.md), and [`./grading-engine.md`](./grading-engine.md). The canonical conformance label inventory is enumerated in [§ 8 CIO/CTO Audience Language Conformance](#8-ciocto-audience-language-conformance).

## 2. Total Applications In Scope

### 2.1 Definition

**Total Applications In Scope** is the count of distinct `application_id` values present in the current run scope. Per [Rule R7](../template.md#r7--application-identity-stability), the canonical `application_id` form is the repository full name `org/repo` and the same repository MUST resolve to the same `application_id` across all runs. The run scope is the list of repositories provided to the template invocation as documented in [`./usage.md`](./usage.md) § Specifying Repository Scope; per [Rule R10](../template.md#r10--new-repo-compatibility), the run scope MAY be a heterogeneous mix of previously-ingested repositories and net-new repositories.

### 2.2 Computation

```text
total_applications = COUNT(DISTINCT application_id) WHERE run_date = <current_run_date>
```

The canonical computation counts each repository **exactly once** regardless of whether the repository is a previously-ingested repository (i.e., has prior records in the persistence layer for one or more `(application_id, facet)` pairs) or a net-new repository (i.e., has zero prior records per [Rule R10](../template.md#r10--new-repo-compatibility)). The `total_applications` value is also exactly equal to the length of the top-level `matrix` array per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/properties/matrix` (the `minItems: 0` constraint admits the empty-scope case).

### 2.3 Rendering

The rendered value on page 1 is a plain integer presented as `Total Applications In Scope: N` where `N` is the computed count. Use the singular form `Total Applications In Scope: 1` (singular noun) when the count is exactly 1 and the plural form `Total Applications In Scope: N` for all other counts (including 0). Worked examples:

```text
Total Applications In Scope: 24
```

```text
Total Applications In Scope: 1
```

```text
Total Applications In Scope: 0
```

### 2.4 Edge Cases

- **Empty run scope** (`total_applications == 0`) is a legal degenerate case admitted by the schema (`minItems: 0` on the `matrix` array per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json)). The PDF still renders with all five Executive Summary sub-sections present; each sub-section emits its zero-state literal text per the per-sub-section edge-case rules below. This guarantees that [Gate 2](../template.md#612-gate-2--zero-warning-build) (zero-warning build) is preserved even for an empty-scope invocation.
- **Invalid run scope** (e.g., a run scope with non-canonical `application_id` values that fail the `^[a-zA-Z0-9][a-zA-Z0-9._-]*\/[a-zA-Z0-9][a-zA-Z0-9._-]*$` regex per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json)) is rejected by the validation harness per [`./validation.md`](./validation.md) § Gate 10 before PDF generation begins. The template MUST NOT attempt to render a PDF when the run scope contains a malformed `application_id`; the validation harness emits an error and exits.

## 3. Grade Distribution per Facet

### 3.1 Definition

**Grade Distribution per Facet** is, for each of the four canonical facets in canonical order `[tech_stack, maturity, security, complexity]`, the count of applications in the current run that received each permitted current-grade value. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/gradeHistogram`, the histogram contains exactly **seven required count buckets**: `A`, `B`, `C`, `D`, `F`, `TBD`, `InsufficientData`.

The `N/A` value is **deliberately excluded** from the histogram. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/cellGrade` and `#/$defs/priorCellGrade`, `N/A` is **exclusively a prior-grade value** ([Rule R3](../template.md#r3--grade-history-fidelity)) used to denote the absence of a prior run record for an `(application_id, facet)` pair; it is never a current-grade value emitted by the grading engine. The persistence layer schema [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) admits `N/A` in the `grade` enum as a record of "no prior run" but the report-output histogram aggregates only current-run grades and therefore excludes `N/A` from its bucket inventory.

### 3.2 Computation

```text
For each facet f in [tech_stack, maturity, security, complexity]:
  For each grade g in [A, B, C, D, F, TBD, InsufficientData]:
    distribution[f][g] = COUNT(records WHERE facet = f
                                          AND run_date = <current_run_date>
                                          AND grade = g)
```

**Sum invariant.** For every facet `f`, the sum of `distribution[f][*]` over all seven buckets equals `total_applications`:

```text
distribution[f].A + distribution[f].B + distribution[f].C
  + distribution[f].D + distribution[f].F + distribution[f].TBD
  + distribution[f].InsufficientData == total_applications
```

This invariant is the structural operationalization of the Domain Success Criterion *"Executive summary renders correct portfolio-level grade distribution counts matching the sum of individual application grades"* per [`../template.md`](../template.md) § 6.2. The validation harness asserts this invariant per facet for every report run; see [`./validation.md`](./validation.md) § Domain Success Criteria.

### 3.3 Rendering

The Executive Summary renders one row per facet, listing all seven grade buckets with their counts. The rendered label uses business-outcome language (per AAP § 0.10.2 "CIO/CTO Audience Language Rule"); the rendered grade-bucket label `Insufficient Data` (capital I, capital D, single ASCII space) maps to the schema enum identifier `InsufficientData` per [`./pdf-output.md`](./pdf-output.md) § 5.3. Suggested layout for page 1:

```text
Grade Distribution per Facet:
Tech Stack:  A:8  B:9  C:5  D:1  F:0  TBD:0  Insufficient Data:1
Maturity:    A:5  B:8  C:7  D:3  F:1  TBD:0  Insufficient Data:0
Security:    A:3  B:6  C:8  D:5  F:2  TBD:0  Insufficient Data:0
Complexity:  A:0  B:0  C:0  D:0  F:0  TBD:24 Insufficient Data:0
```

Per [Rule R5](../template.md#r5--complexity-placeholder-integrity) (Complexity placeholder integrity), the canonical initial state of the Complexity row is `TBD: <total_applications>` for all applications because no Complexity rubric has been supplied; this is the **expected and correct rendering** until the user provides a Complexity rubric. The Complexity row's letter-grade buckets (`A`, `B`, `C`, `D`, `F`) MUST all be 0 while the Complexity Lock is active; a non-zero letter-grade count on the Complexity row indicates the Lock has been disabled (which is permitted only after a Complexity rubric is supplied per [`./grading-engine.md`](./grading-engine.md) § Complexity Lock).

### 3.4 Zero Values

Display `0` for grade buckets with zero applications; do **NOT** omit the bucket, do **NOT** render `—` (em-dash) or `N/A` for zero. The full seven-value histogram is always rendered for every facet — this is the canonical structural form per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/gradeHistogram` (which marks all seven keys as `required`), and it preserves [Gate 2](../template.md#612-gate-2--zero-warning-build) (zero-warning build) by ensuring deterministic rendering regardless of which buckets are populated for a given run.

### 3.5 Empty Scope

When `total_applications == 0`, every histogram bucket is `0` for every facet. The rendered Executive Summary still includes the four-facet histogram with all-zero counts:

```text
Grade Distribution per Facet:
Tech Stack:  A:0  B:0  C:0  D:0  F:0  TBD:0  Insufficient Data:0
Maturity:    A:0  B:0  C:0  D:0  F:0  TBD:0  Insufficient Data:0
Security:    A:0  B:0  C:0  D:0  F:0  TBD:0  Insufficient Data:0
Complexity:  A:0  B:0  C:0  D:0  F:0  TBD:0  Insufficient Data:0
```

This preserves the structural form across run states and guarantees that a reader of an empty-scope PDF receives a coherent (if vacuous) Executive Summary rather than a missing or malformed sub-section.

## 4. Top Critical / High CVE Findings

### 4.1 Definition

**Top Critical / High CVE Findings** is a ranked list of the most severe CVE findings across the run scope, drawn from the Security facet's per-application raw data. Per [Rule R4](../template.md#r4--cve-severity-breakdown) (CVE severity breakdown), only the `Critical` and `High` severity tiers are eligible for promotion to this portfolio-level list — `Medium` and `Low` findings are reflected in the per-application Security cell `severity_counts` per [`./pdf-output.md`](./pdf-output.md) § 5.5 but are **NOT** promoted to this list. This filtering matches `../schemas/report-output.schema.json#/$defs/cveFinding/properties/severity` whose enum is restricted to `[Critical, High]`.

### 4.2 Source Data

For each application in scope, the Security facet's `raw_data.cves` array of CVE records (per [`./facets.md`](./facets.md) § Security Summary) provides the input for this list. Each CVE record contains:

- `cve_id` — the canonical CVE identifier in the form `CVE-YYYY-NNNNN` (per `../schemas/report-output.schema.json#/$defs/cveFinding/properties/cve_id`)
- `severity` — one of `Critical`, `High`, `Medium`, `Low` per [Rule R4](../template.md#r4--cve-severity-breakdown) (only `Critical` and `High` are eligible here)
- `cvss_score` — numeric CVSS v3.1 base score in `[0.0, 10.0]`, optional but strongly recommended for ranking
- `package` — the affected dependency name (e.g., `log4j-core`, `openssl`, `requests`), optional
- `version` — the affected package version, optional
- `application_id` — the canonical `org/repo` identifier of the application that produced this CVE (per [Rule R7](../template.md#r7--application-identity-stability))
- `scan_metadata` — the scan timestamp and source database label per [Rule R9](../template.md#r9--cve-attribution); REQUIRED on every record

### 4.3 Ranking

Sort the `Critical` and `High` CVE records globally across the run scope by:

1. **Severity tier descending** — `Critical` first, then `High`. (`Medium` and `Low` are excluded from the list as documented in [§ 4.1](#41-definition).)
2. **CVSS score descending** — within each severity tier, the highest `cvss_score` is ranked first. CVE records missing a `cvss_score` are sorted **after** records with a known score within the same severity tier.
3. **`application_id` ascending** — lexicographic ASCII ordering on the canonical `org/repo` string, used as the first deterministic tie-breaker when severity and CVSS score are equal.
4. **`cve_id` ascending** — lexicographic ASCII ordering on the canonical `CVE-YYYY-NNNNN` string, used as the second deterministic tie-breaker when severity, CVSS score, and `application_id` are all equal.

The fourfold sort key guarantees that two runs over the same data set produce **byte-identical** Top CVE lists; this determinism is one of the assertions in [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) (Live smoke test) per [`./validation.md`](./validation.md) § Gate 8.

### 4.4 Limit

Render the **top 10** records by default. The default cap is `top_cve_limit = 10`; the configuration override path is documented in [`./configuration.md`](./configuration.md) and the default lives in [`../config/facets.yaml`](../config/facets.yaml) at the configuration key `executive_summary.top_cve_limit`. The cap MAY be overridden by the report author at generation time to a smaller value (e.g., `top_cve_limit = 5` for a one-page Executive Summary) or a larger value (e.g., `top_cve_limit = 25` for a portfolio with many Critical findings).

The cap applies **after sorting**; if the run scope contains fewer than 10 `Critical`+`High` records total, render all of them and do **NOT** pad the list with zero rows or filler entries. The minimum list length is 0 (when no `Critical` or `High` findings exist in the run scope per [§ 4.6 Edge Cases](#46-edge-cases)); the maximum list length is `top_cve_limit`.

### 4.5 Rendering

A short table with five columns; the column header labels use business-outcome language per AAP § 0.10.2 "CIO/CTO Audience Language Rule":

| Column | Header Label | Source Field |
|---|---|---|
| 1 | `Rank` | array index + 1 (rendered 1, 2, 3, …) |
| 2 | `CVE ID` | `cve_id` |
| 3 | `Severity` | `severity` |
| 4 | `CVSS` | `cvss_score` (rendered to one decimal place) |
| 5 | `Application` | `application_id` (in canonical `org/repo` form per [Rule R7](../template.md#r7--application-identity-stability)) |
| 6 | `Package` | `package` followed by ` @ ` and `version` when both are available |

The `Rank` column is implicit from the array order of `top_critical_high_cve_findings` per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/executiveSummary/properties/top_critical_high_cve_findings`; the schema does NOT carry a `rank` field on each finding object (the schema's `additionalProperties: false` constraint excludes such a field). The PDF renderer derives the rank from array index at render time.

Worked example with three findings:

```text
Top Critical / High CVE Findings:
1. CVE-2024-12345  Critical  9.8  acme-inc/acme-api    log4j @ 2.14.0
2. CVE-2024-22222  Critical  9.1  internal/payments    openssl @ 1.1.0
3. CVE-2024-44444  High      8.7  acme-inc/acme-api    nginx @ 1.18.0
...
```

The column delimiter in the rendered table is implementation-defined by the PDF renderer (typically a fixed-width column rendering rather than ASCII art); the example above uses spaces for readability. The column header labels (`Rank`, `CVE ID`, `Severity`, `CVSS`, `Application`, `Package`) are preserved exactly as stated in the table above.

### 4.6 Edge Cases

- **Application with `Insufficient Data` Security cell:** If the Security cell rendered `Insufficient Data` for an application (per [Rule R2](../template.md#r2--facet-completeness) and [`./pdf-output.md`](./pdf-output.md) § 5.3), that application's CVE records are absent from this list (the application produces zero entries here). The application's row in the Matrix Table still renders the `Insufficient Data` literal as required by [Rule R2](../template.md#r2--facet-completeness); the absence here is a downstream consequence, not a separate omission.
- **Zero `Critical` or `High` findings in scope:** If the total `Critical`+`High` count across all applications in scope is zero, render the literal text `No Critical or High CVE findings in current run scope.` instead of an empty table. This is the canonical zero-state literal for this sub-section.
- **Ties beyond the cap:** When `top_cve_limit` boundary falls within a tie group (e.g., positions 10 and 11 have identical sort keys), the deterministic tie-breakers in [§ 4.3](#43-ranking) (`application_id` then `cve_id`) ensure a stable cut. The 11th record is excluded; this is acceptable because the deterministic tie-breakers guarantee the same record is excluded across any two runs with the same data.

### 4.7 Attribution Per Rule R9

Per [Rule R9](../template.md#r9--cve-attribution), every CVE entry in this list carries the scan timestamp (ISO 8601) and the source database (`NVD`, `OSV`, or both). The schema enforces this structurally via the required `scan_metadata` property on every `cveFinding` per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/cveFinding`; a `cveFinding` without a `scan_metadata` object is a schema validation failure.

Two equivalent rendering options are permitted; both satisfy [Rule R9](../template.md#r9--cve-attribution) verification (*"each Security Summary cell or report footnote contains timestamp and database label"*):

- **Per-row attribution:** each row in the rendered table carries an additional column or annotation with the scan timestamp and source database label. Example: `1. CVE-2024-12345  Critical  9.8  acme-inc/acme-api  log4j @ 2.14.0  [Scanned 2025-10-01T08:00:00Z; NVD, OSV]`. This option is verbose but unambiguous.
- **Aggregated footnote:** a page-level footnote at the bottom of the Executive Summary (or the Top CVE Findings sub-section) declares the scan attribution that applies to all rows. Example: `Scan timestamps: 2025-10-01T08:00:00Z. Sources: NVD, OSV.`. This option requires that **every** record in the rendered list shares the **same** `scan_metadata` (timestamp and sources); when records have heterogeneous attribution, the aggregated footnote variant is **NOT** valid and the per-row attribution MUST be used instead.

The per-row scan attribution is **always traceable** in the underlying data layer regardless of which rendering option is chosen: the `scan_metadata` object is present on every `cveFinding` per the schema, and the per-row attribution is also present on the corresponding Matrix Table Security cell per [`./pdf-output.md`](./pdf-output.md) § 5.5.

## 5. Highest Maturity Risk Applications

### 5.1 Definition

**Highest Maturity Risk Applications** is a ranked list of applications whose Maturity facet indicates the highest technical-debt or end-of-life risk, drawn from the Maturity facet's per-application raw data per [`./facets.md`](./facets.md) § Maturity Summary. The list is intended for CIO/CTO consumption to highlight the applications most exposed to runtime obsolescence and unsupported-library risk; it is the portfolio-level analog of the per-application Maturity grade rendered on each Matrix Table row.

### 5.2 Source Data

For each application in scope, the Maturity facet's raw data provides the inputs for this list. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/maturityRiskApplication`, the canonical scoring inputs for portfolio-level ranking are:

- `application_id` — the canonical `org/repo` identifier of the application (per [Rule R7](../template.md#r7--application-identity-stability))
- `risk_score` — a number in the closed interval `[0.0, 1.0]` representing the proportion of out-of-support dependencies relative to the total endoflife.date-tracked dependencies; computed as `out_of_support_count / total_tracked_count` when `total_tracked_count > 0`, or `0.0` by convention when `total_tracked_count == 0`
- `out_of_support_count` — count of detected dependencies whose installed version is past its EOL date per the endoflife.date API v1 lookup ([`./api-integrations.md`](./api-integrations.md) § endoflife.date API v1)
- `total_tracked_count` — count of detected dependencies that endoflife.date tracks (i.e., have a recognized product slug in the endoflife.date catalog)

The `risk_score` is the canonical sort key for portfolio-level ranking. The corresponding application's Maturity grade (`A`, `B`, `C`, `D`, `F`, `TBD`, or `InsufficientData`) is **NOT** stored on the `maturityRiskApplication` object directly per the schema's `additionalProperties: false` constraint; the rendering layer derives the displayed Maturity grade by looking up the same `application_id` in the `matrix` array's corresponding `maturity.current_grade` field.

### 5.3 Ranking

Sort the in-scope applications by:

1. **`risk_score` descending** — the highest proportion of out-of-support dependencies is ranked first. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/maturityRiskApplication/properties/risk_score`, the score range is `[0.0, 1.0]` where `1.0` represents 100% of tracked dependencies past EOL.
2. **`out_of_support_count` descending** — within the same `risk_score`, the application with the larger raw count of out-of-support dependencies is ranked first. This tie-breaker is meaningful when two applications have the same proportion (e.g., 1/2 and 5/10 both yield `risk_score = 0.5`); the application with 5 out-of-support dependencies is ranked above the application with 1.
3. **`application_id` ascending** — lexicographic ASCII ordering on the canonical `org/repo` string, used as the second deterministic tie-breaker when `risk_score` and `out_of_support_count` are equal.

The threefold sort key guarantees that two runs over the same data set produce **byte-identical** Highest Maturity Risk lists; this determinism is one of the assertions in [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) (Live smoke test) per [`./validation.md`](./validation.md) § Gate 8.

### 5.4 Limit

Render the **top 5** applications by default. The default cap is `top_maturity_limit = 5`; the configuration override path is documented in [`./configuration.md`](./configuration.md) and the default lives in [`../config/facets.yaml`](../config/facets.yaml) at the configuration key `executive_summary.top_maturity_limit`. The cap MAY be overridden by the report author at generation time to a smaller value (e.g., `top_maturity_limit = 3` for a one-page Executive Summary) or a larger value (e.g., `top_maturity_limit = 10` for a portfolio with broad EOL exposure).

The cap applies **after sorting**; if the run scope contains fewer than 5 applications with `risk_score > 0` total, render all of them and do **NOT** pad the list with zero-risk-score applications or filler entries. The minimum list length is 0 (when no applications have detected EOL exposure per [§ 5.6 Edge Cases](#56-edge-cases)); the maximum list length is `top_maturity_limit`.

### 5.5 Rendering

A short table with five columns; the column header labels use business-outcome language per AAP § 0.10.2 "CIO/CTO Audience Language Rule":

| Column | Header Label | Source Field |
|---|---|---|
| 1 | `Rank` | array index + 1 (rendered 1, 2, 3, …) |
| 2 | `Application` | `application_id` (in canonical `org/repo` form per [Rule R7](../template.md#r7--application-identity-stability)) |
| 3 | `Maturity Grade` | the corresponding `matrix[i].maturity.current_grade` for the same `application_id` |
| 4 | `Technical Debt Score` | `risk_score` (rendered to two decimal places) |
| 5 | `EOL Runtimes` | `out_of_support_count` followed by an explanatory list of the affected runtime/library names |

The `Rank` column is implicit from the array order of `highest_maturity_risk_applications` per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/executiveSummary/properties/highest_maturity_risk_applications`; the schema does NOT carry a `rank` field on each application object (the schema's `additionalProperties: false` constraint excludes such a field). The PDF renderer derives the rank from array index at render time.

The `Maturity Grade` column is rendered using the **business-outcome label** `Maturity Grade` (per AAP § 0.10.2 "CIO/CTO Audience Language Rule") even though the underlying data field is named `maturity.current_grade` in the schema. The `Technical Debt Score` column is rendered using the **business-outcome label** `Technical Debt Score` even though the underlying data field is named `risk_score`. This labeling separation is documented in [§ 8 CIO/CTO Audience Language Conformance](#8-ciocto-audience-language-conformance).

Worked example with two applications at top of ranking:

```text
Highest Maturity Risk Applications:
1. legacy/acme-monolith     F  0.78  3 EOL runtimes (Node.js 12, Python 2.7, Java 8)
2. acme-inc/data-pipeline   D  0.45  1 EOL runtime  (Python 3.6)
...
```

The column delimiter in the rendered table is implementation-defined by the PDF renderer (typically a fixed-width column rendering rather than ASCII art); the example above uses spaces for readability. The `EOL Runtimes` column displays the count followed by a parenthesized list of runtime and library names sourced from the per-application Maturity facet raw data ([`./facets.md`](./facets.md) § Maturity Summary); when the count exceeds 3 names, the list MAY be truncated with a trailing "…and N more" suffix to preserve readability.

### 5.6 Edge Cases

- **Application with `Insufficient Data` Maturity cell:** If the Maturity cell rendered `Insufficient Data` for an application (per [Rule R2](../template.md#r2--facet-completeness) and [`./pdf-output.md`](./pdf-output.md) § 5.3), that application is **absent** from this list. No `risk_score` is computable when the underlying endoflife.date lookup or the dependency manifest parsing failed; the application contributes zero entries here. The application's row in the Matrix Table still renders the `Insufficient Data` literal as required by [Rule R2](../template.md#r2--facet-completeness).
- **Zero applications with detected maturity risk:** If the count of applications with `risk_score > 0` is zero (i.e., every application has zero out-of-support dependencies, which would yield Maturity grade A across the portfolio under a typical rubric), render the literal text `No applications with detected maturity risk in current run scope.` instead of an empty table. This is the canonical zero-state literal for this sub-section.
- **Application with `risk_score == 0`** but with non-zero `total_tracked_count`: this application has tracked dependencies all of which are within support; it is **NOT** included in the Highest Maturity Risk list because the list ranks applications with **detected** maturity risk. The application's Maturity grade in the Matrix Table is determined by the user-supplied rubric and may be `A` (typical case) or another letter depending on the rubric's thresholds; the rubric application is independent of the portfolio-level "highest risk" ranking documented here.
- **Ties beyond the cap:** When `top_maturity_limit` boundary falls within a tie group (e.g., positions 5 and 6 have identical sort keys), the deterministic tie-breakers in [§ 5.3](#53-ranking) (`out_of_support_count` then `application_id`) ensure a stable cut. The 6th record is excluded; this is acceptable because the deterministic tie-breakers guarantee the same record is excluded across any two runs with the same data.

## 6. Trend versus Prior Run

### 6.1 Definition

**Trend versus Prior Run** is, for each facet, the portfolio-level aggregation of per-application grade changes versus that application's prior run. Per [`../template.md`](../template.md) § 3.5 Executive Summary, the user-prompt content list calls this *"Net grade improvement/regression trends versus the prior run"*; this document operationalizes that bullet with deterministic per-`(application_id, facet)` delta computation and a four-bucket portfolio aggregation.

The trend computation depends on the prior-grade lookup documented in [`./grade-history.md`](./grade-history.md) § Retrieval Procedure; the same lookup populates the inline `prev: <grade> | <ISO date>` segment on each Matrix Table cell per [Rule R3](../template.md#r3--grade-history-fidelity) and [`./pdf-output.md`](./pdf-output.md) § 5.1. There is **one** prior-grade lookup per `(application_id, facet)` pair per run; the Executive Summary's trend computation and the Matrix Table's cell rendering both consume the same lookup result.

### 6.2 Grade Ordering for Delta Computation

Establish a numeric **grade ordinal** for the five A–F letter grades for the purpose of delta math:

| Grade | Ordinal |
|---|---|
| `A` | `4` |
| `B` | `3` |
| `C` | `2` |
| `D` | `1` |
| `F` | `0` |

Higher ordinals are **better** grades; A is the best (ordinal 4), F is the worst (ordinal 0). This convention matches the canonical letter-grade ordering documented in [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun/description` (*"the canonical convention is that A is the best grade and F is the worst"*) and is consistent with conventional academic letter grading.

The grade ordinal is a **computational convenience** for delta math in this document only. The grade-history persistence layer per [`./grade-history.md`](./grade-history.md) does NOT store ordinals; it stores the letter-grade enum value per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json). The rendering layer per [`./pdf-output.md`](./pdf-output.md) does NOT render ordinals; it renders the letter grade. The ordinal mapping is strictly internal to the trend computation and is not surfaced anywhere else in the package.

**Special grade values are EXCLUDED from delta computation.** The values `TBD`, `N/A`, and `InsufficientData` do not have an ordinal and yield no delta when present in either the current or the prior run for an `(application_id, facet)` pair. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun/description`:

- A pair where **either** the current grade or the prior grade is `TBD` or `InsufficientData` is counted as `unchanged` when both are equal special values, or as `no_prior_run` when the prior grade is `N/A`.
- A pair where the prior grade is `N/A` (per [Rule R3](../template.md#r3--grade-history-fidelity), no prior run record exists) is counted as `no_prior_run` regardless of the current grade.

### 6.3 Per-(Application, Facet) Delta

For each `(application_id, facet)` pair where **both** the current run **and** the immediately prior run have an A–F letter grade (i.e., neither is `TBD`, `N/A`, nor `InsufficientData`):

```text
delta[application_id][facet] = current_grade_ordinal - prior_grade_ordinal
```

Worked examples:

- Prior `C` (ordinal 2) → Current `B` (ordinal 3): `delta = +1` (improvement)
- Prior `B` (ordinal 3) → Current `B` (ordinal 3): `delta = 0` (no change)
- Prior `A` (ordinal 4) → Current `C` (ordinal 2): `delta = -2` (regression)
- Prior `F` (ordinal 0) → Current `D` (ordinal 1): `delta = +1` (improvement)

A **positive** delta is an improvement (current grade is better than prior grade); a **negative** delta is a regression (current grade is worse than prior grade); a **zero** delta is no change. Pairs with at least one special-value grade are excluded from the delta computation and are tallied separately per [§ 6.4 Portfolio-Level Aggregation](#64-portfolio-level-aggregation).

### 6.4 Portfolio-Level Aggregation

For each facet, count how many `(application_id, facet)` pairs fall into each of four mutually exclusive and collectively exhaustive buckets:

```text
For each facet f in [tech_stack, maturity, security, complexity]:
  net_improvements[f] = COUNT(pairs WHERE facet = f
                                      AND both current and prior are A-F
                                      AND delta > 0)
  net_regressions[f]  = COUNT(pairs WHERE facet = f
                                      AND both current and prior are A-F
                                      AND delta < 0)
  unchanged[f]        = COUNT(pairs WHERE facet = f
                                      AND (
                                        (both current and prior are A-F AND delta == 0)
                                        OR
                                        (current and prior are equal special values
                                         like TBD-TBD, InsufficientData-InsufficientData)
                                      ))
  no_prior_run[f]     = COUNT(pairs WHERE facet = f
                                      AND prior_grade == N/A)
```

The four bucket names match the schema field names in [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun/required`: `net_improvements`, `net_regressions`, `unchanged`, `no_prior_run`. The rendered labels in the PDF use business-outcome language per AAP § 0.10.2 "CIO/CTO Audience Language Rule"; the mapping is documented in [§ 6.5 Rendering](#65-rendering) and the canonical conformance label inventory is in [§ 8 CIO/CTO Audience Language Conformance](#8-ciocto-audience-language-conformance).

**Sum invariant.** For every facet `f`:

```text
net_improvements[f] + net_regressions[f] + unchanged[f] + no_prior_run[f]
  == total_applications
```

Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun/description`, the four buckets are *"mutually exclusive and collectively exhaustive: every (application, facet) pair in the run scope contributes exactly one count to exactly one bucket"*. The validation harness asserts this invariant per facet for every report run; see [`./validation.md`](./validation.md) § Domain Success Criteria.

Note that the schema's description observes that *"the sum of all four counts equals total_applications × 4 (four facets per application)"* when summed across all four facets together; this document presents the per-facet sum invariant which is the per-row form of that aggregate.

### 6.5 Rendering

One row per facet showing the four counts. The rendered labels use business-outcome language per AAP § 0.10.2 "CIO/CTO Audience Language Rule"; the mapping from schema field name to rendered label is:

| Schema Field | Rendered Label |
|---|---|
| `net_improvements` | `Improved` |
| `net_regressions` | `Regressed` |
| `unchanged` | `No Change` |
| `no_prior_run` | `No Baseline` |

Worked example for a 24-application portfolio with two prior runs of recent recurring history:

```text
Trend vs Prior Run:
Tech Stack:  Improved: 3   Regressed: 1   No Change: 19   No Baseline: 1
Maturity:    Improved: 2   Regressed: 4   No Change: 18   No Baseline: 0
Security:    Improved: 5   Regressed: 2   No Change: 16   No Baseline: 1
Complexity:  Improved: 0   Regressed: 0   No Change: 0    No Baseline: 24   (Complexity Lock active — Rule R5)
```

Per [Rule R5](../template.md#r5--complexity-placeholder-integrity) (Complexity Lock), when the Complexity Lock is active (i.e., the user-supplied rubric document conforming to [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) has `complexity: []` or omits the `complexity` key entirely), every `(application_id, complexity)` pair has current grade `TBD` and the prior grade — when one exists — is also typically `TBD`. These pairs are tallied as `unchanged` when prior is also `TBD` or as `no_prior_run` when this is the first ever run for the application. The render MUST include the parenthetical note `(Complexity Lock active — Rule R5)` adjacent to the Complexity row when all 24 applications appear in the union of `unchanged` and `no_prior_run` buckets and the `Improved` and `Regressed` counts are both 0; this annotation explains the all-zero-delta state to a CIO/CTO reader. The em-dash glyph in `Complexity Lock active — Rule R5` is U+2014 (UTF-8 `0xE2 0x80 0x94`); preserve the byte sequence verbatim.

### 6.6 First Run of Entire Portfolio

When this is the first run of the template (no prior records exist for any application in the persistence layer), all four `Improved`/`Regressed`/`No Change` counts are `0` for every facet and `No Baseline` equals `total_applications` for every facet. Render the literal text on a single line replacing the four-column table:

```text
Trend vs Prior Run:
No prior run available; baseline established by current run.
```

This zero-state literal is canonical for the first-run case and is the deterministic alternative to rendering a four-row table of all-zero / all-`total_applications` values. The literal text is preserved byte-for-byte; do **NOT** alter it to `"No prior run history; ..."` or `"... establishes the baseline"` or any other paraphrase.

### 6.7 Heterogeneous Scope (Rule R10)

Per [Rule R10](../template.md#r10--new-repo-compatibility) (new repo compatibility), a single run scope MAY contain a heterogeneous mix of previously-ingested repositories (which have prior records in the persistence layer) and net-new repositories (which have zero prior records). Each net-new repository contributes exactly four `(application_id, facet)` pairs to the `no_prior_run` bucket — one per facet — because the prior-grade lookup returns `N/A` for every `(application_id, facet)` pair where the application has no record in the persistence layer.

Worked example: a run scope with 23 previously-ingested repositories and 1 net-new repository. The net-new repository contributes 1 pair to each facet's `no_prior_run` bucket; the previously-ingested repositories distribute across `net_improvements`, `net_regressions`, `unchanged`, and `no_prior_run` per their per-facet delta. The aggregate `no_prior_run` count for any facet is the sum of: (a) net-new applications (1) + (b) previously-ingested applications whose `(application_id, facet)` pair has no prior record (0 in the typical case where existing applications have history across all four facets, but possibly non-zero if a facet was added after the application's first run).

The heterogeneous-scope flow is documented in [`./grade-history.md`](./grade-history.md) § Heterogeneous Scope; the new-repository onboarding procedure is documented in [`./grade-history.md`](./grade-history.md) § New Repository Onboarding.

### 6.8 Cross-Reference

The trend computation depends on the **retrieval procedure** documented in [`./grade-history.md`](./grade-history.md) § Retrieval. The prior-grade lookup invoked here is the **same** lookup used to render the inline `prev: <grade> | <ISO date>` segment on each Matrix Table cell per [Rule R3](../template.md#r3--grade-history-fidelity) and [`./pdf-output.md`](./pdf-output.md) § 5.1; the lookup is invoked once per `(application_id, facet)` pair per run and its result is consumed by both the Executive Summary's trend aggregation and the Matrix Table's per-cell rendering.

## 7. Determinism and Idempotency

All five sub-sections specified above ([§ 2 Total Applications](#2-total-applications-in-scope), [§ 3 Grade Distribution](#3-grade-distribution-per-facet), [§ 4 Top CVE](#4-top-critical--high-cve-findings), [§ 5 Highest Maturity Risk](#5-highest-maturity-risk-applications), [§ 6 Trend](#6-trend-versus-prior-run)) are computed as **pure functions** of the persistence-store records and the run scope. Given the same inputs (the same set of persistence records keyed by `(application_id, facet, run_date)` and the same run scope list), the same Executive Summary content is produced — byte-for-byte identical — across any number of independent runs of this aggregation procedure.

The deterministic ranking properties of [§ 4 Top CVE](#4-top-critical--high-cve-findings) and [§ 5 Highest Maturity Risk](#5-highest-maturity-risk-applications) are operationalized by the following sort-key contracts:

- **Top CVE Findings** ([§ 4.3](#43-ranking)): four-key sort `(severity desc, cvss_score desc, application_id asc, cve_id asc)`. The two trailing tie-breakers (`application_id` and `cve_id`) ensure a stable cut at the `top_cve_limit` boundary regardless of input ordering.
- **Highest Maturity Risk** ([§ 5.3](#53-ranking)): three-key sort `(risk_score desc, out_of_support_count desc, application_id asc)`. The trailing tie-breaker (`application_id`) ensures a stable cut at the `top_maturity_limit` boundary regardless of input ordering.

The `top_cve_limit` (default 10 per [§ 4.4](#44-limit)) and `top_maturity_limit` (default 5 per [§ 5.4](#54-limit)) are both **stable, deterministic** sort/limit operations — given the same input set, the same configured limit produces the same prefix of the sorted array. Configuration overrides per [`./configuration.md`](./configuration.md) preserve this property: changing the limit produces a different prefix length but the prefix itself is byte-stable.

The grade-distribution histogram ([§ 3](#3-grade-distribution-per-facet)) and the trend aggregation ([§ 6](#6-trend-versus-prior-run)) are both **pure counts** over the persistence-record set; counts are commutative and associative, so the order of iteration over records does not affect the output.

This determinism is required by [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) (Live smoke test) — see [`./validation.md`](./validation.md) § Gate 8 for the canonical assertion procedure — and supports the Domain Success Criterion *"Executive summary renders correct portfolio-level grade distribution counts matching the sum of individual application grades"* per [`../template.md`](../template.md) § 6.2 Domain-Specific Success Criteria. The validation harness re-runs the aggregation procedure twice over the same input set and asserts that the two outputs are byte-identical; any divergence is a [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) failure.

## 8. CIO/CTO Audience Language Conformance

Per AAP § 0.10.2 "CIO/CTO Audience Language Rule," the rendered Executive Summary on page 1 uses **business-outcome language**; technical jargon is reserved for the implementation-facing pages such as [`./facets.md`](./facets.md), [`./api-integrations.md`](./api-integrations.md), and [`./grading-engine.md`](./grading-engine.md). This section enumerates the canonical labels used in the rendered Executive Summary and contrasts them with the implementation-facing forms that MUST NOT appear in the PDF.

### 8.1 Sub-Section Heading Labels

The five sub-section headings in the rendered Executive Summary are:

| Canonical Rendered Heading | Implementation-Facing Form (NOT used in PDF) |
|---|---|
| `Total Applications In Scope` | "application count", "scope size", "in-scope repos" |
| `Grade Distribution per Facet` | "facet histogram", "grade tally", "per-facet count" |
| `Top Critical / High CVE Findings` | "vulnerability list", "CVE backlog", "high-severity exposure" |
| `Highest Maturity Risk Applications` | "tech debt list", "EOL exposure", "stale dependency report" |
| `Trend vs Prior Run` | "delta report", "diff summary", "regression analysis" |

The rendered headings are preserved exactly as shown (capital first letter on each significant word, ASCII spaces between words, no abbreviations). The four-bucket trend rendering uses `Improved`, `Regressed`, `No Change`, `No Baseline` per [§ 6.5](#65-rendering); these labels are the rendering-layer mapping of the schema field names `net_improvements`, `net_regressions`, `unchanged`, `no_prior_run`.

### 8.2 Excluded Technical Terminology

The following technical terms MUST NOT appear in the rendered Executive Summary on page 1:

- **CVSS** — reserved for implementation-facing pages ([`./facets.md`](./facets.md), [`./api-integrations.md`](./api-integrations.md))
- **SBOM** — reserved for implementation-facing pages ([`./facets.md`](./facets.md))
- **CPE** — reserved for implementation-facing pages
- **Manifest** / **lockfile** — reserved for implementation-facing pages ([`./facets.md`](./facets.md))
- **NVD** / **OSV** — admitted in the Executive Summary **only** as the source-database label in the per-row or aggregated scan-attribution per [Rule R9](../template.md#r9--cve-attribution) and [§ 4.7 Attribution Per Rule R9](#47-attribution-per-rule-r9); MUST NOT appear in any other context
- **endoflife.date** — reserved for implementation-facing pages ([`./facets.md`](./facets.md), [`./api-integrations.md`](./api-integrations.md))
- **`application_id`** — the rendered form is `Application` per [Rule R7](../template.md#r7--application-identity-stability); the schema-field form `application_id` MUST NOT appear in the PDF (the rendered value `org/repo` is shown without the field-name prefix)

The technical terms above MAY appear in **this document** because this document is implementation-facing (the audience is the template authors and Blitzy execution engine). They MAY also appear in [`./facets.md`](./facets.md), [`./api-integrations.md`](./api-integrations.md), [`./grading-engine.md`](./grading-engine.md), and the schema files. The constraint is specifically on the rendered PDF page 1 content.

### 8.3 Admitted Business-Outcome Phrasing

The following phrasings are admitted and recommended for the rendered Executive Summary prose:

- "Out-of-support dependencies" instead of "EOL dependencies" or "stale libraries"
- "Critical security findings" instead of "Critical CVEs" (the CVE token is permitted in the Top CVE Findings sub-section's table because the column header `CVE ID` references the canonical CVE identifier format, but is otherwise reserved for implementation-facing pages)
- "Improved versus prior run" instead of "Positive delta"
- "No baseline established" instead of "No prior persistence record"
- "Insufficient data" instead of "Manifest parse error" or "API lookup failure"

The validation harness does NOT structurally enforce these phrasings — they are an editorial convention. Per [Gate 1](../template.md#611-gate-1--end-to-end-boundary-verification) (live smoke test), the generated PDF is reviewed by a CIO/CTO-level reviewer who confirms the language conforms to this convention; per [`./validation.md`](./validation.md) § Gate 1, this review is part of the manual sign-off step.

## 9. Schema Reference

The Executive Summary's data structure is defined as part of [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) (JSON Schema Draft 2020-12). The top-level schema has three required properties: `report_metadata`, `executive_summary`, and `matrix`; this document's outputs populate the `executive_summary` object. The canonical machine-readable contract for every field referenced in [§ 2](#2-total-applications-in-scope) through [§ 6](#6-trend-versus-prior-run) lives in that schema; this document specifies the **computation rules** that produce the values, while the schema specifies the **shape constraints** that the values must satisfy.

The relevant schema definitions:

- `#/$defs/executiveSummary` — the top-level Executive Summary object with five required properties: `total_applications`, `grade_distribution`, `top_critical_high_cve_findings`, `highest_maturity_risk_applications`, `trend_versus_prior_run`
- `#/$defs/gradeDistributionByFacet` — the per-facet histogram container with four required keys (`tech_stack`, `maturity`, `security`, `complexity`) in canonical column order
- `#/$defs/gradeHistogram` — the seven-bucket count container for one facet (`A`, `B`, `C`, `D`, `F`, `TBD`, `InsufficientData`); `N/A` is **NOT** a valid bucket per [§ 3.1](#31-definition)
- `#/$defs/cveFinding` — one entry in the `top_critical_high_cve_findings` array; `severity` is restricted to `[Critical, High]`; `scan_metadata` is REQUIRED per [Rule R9](../template.md#r9--cve-attribution)
- `#/$defs/maturityRiskApplication` — one entry in the `highest_maturity_risk_applications` array; required fields are `application_id` and `risk_score`; optional fields are `out_of_support_count` and `total_tracked_count`
- `#/$defs/trendVersusPriorRun` — the four-bucket trend aggregation with required keys `net_improvements`, `net_regressions`, `unchanged`, `no_prior_run`

A worked example JSON fragment showing the `executive_summary` object shape; the fragment validates against [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) and shows the canonical field-name conventions. Note that field names use the schema's snake_case identifiers (e.g., `top_critical_high_cve_findings`, `highest_maturity_risk_applications`, `trend_versus_prior_run`); rendered labels in the PDF use business-outcome language per [§ 8 CIO/CTO Audience Language Conformance](#8-ciocto-audience-language-conformance):

```json
{
  "executive_summary": {
    "total_applications": 24,
    "grade_distribution": {
      "tech_stack": { "A": 8, "B": 9, "C": 5, "D": 1, "F": 0, "TBD": 0, "InsufficientData": 1 },
      "maturity":   { "A": 5, "B": 8, "C": 7, "D": 3, "F": 1, "TBD": 0, "InsufficientData": 0 },
      "security":   { "A": 3, "B": 6, "C": 8, "D": 5, "F": 2, "TBD": 0, "InsufficientData": 0 },
      "complexity": { "A": 0, "B": 0, "C": 0, "D": 0, "F": 0, "TBD": 24, "InsufficientData": 0 }
    },
    "top_critical_high_cve_findings": [
      {
        "application_id": "acme-inc/acme-api",
        "cve_id": "CVE-2024-12345",
        "severity": "Critical",
        "cvss_score": 9.8,
        "package": "log4j-core",
        "version": "2.14.0",
        "scan_metadata": {
          "timestamp": "2025-10-01T08:00:00Z",
          "sources": ["NVD", "OSV"]
        }
      },
      {
        "application_id": "internal-tools/payments",
        "cve_id": "CVE-2024-22222",
        "severity": "Critical",
        "cvss_score": 9.1,
        "package": "openssl",
        "version": "1.1.0",
        "scan_metadata": {
          "timestamp": "2025-10-01T08:00:00Z",
          "sources": ["NVD", "OSV"]
        }
      },
      {
        "application_id": "acme-inc/acme-api",
        "cve_id": "CVE-2024-44444",
        "severity": "High",
        "cvss_score": 8.7,
        "package": "nginx",
        "version": "1.18.0",
        "scan_metadata": {
          "timestamp": "2025-10-01T08:00:00Z",
          "sources": ["NVD"]
        }
      }
    ],
    "highest_maturity_risk_applications": [
      {
        "application_id": "legacy/acme-monolith",
        "risk_score": 0.78,
        "out_of_support_count": 3,
        "total_tracked_count": 4
      },
      {
        "application_id": "acme-inc/data-pipeline",
        "risk_score": 0.45,
        "out_of_support_count": 1,
        "total_tracked_count": 2
      }
    ],
    "trend_versus_prior_run": {
      "net_improvements": 10,
      "net_regressions":  7,
      "unchanged":        53,
      "no_prior_run":     26
    }
  }
}
```

**Notes on the example fragment:**

- The `grade_distribution` per facet contains exactly **seven** keys per `#/$defs/gradeHistogram`; `N/A` is intentionally absent because it is exclusively a prior-grade value per [Rule R3](../template.md#r3--grade-history-fidelity) and [§ 3.1 Definition](#31-definition).
- For each facet, the seven-bucket sum equals `total_applications = 24`: Tech Stack `8+9+5+1+0+0+1 = 24`; Maturity `5+8+7+3+1+0+0 = 24`; Security `3+6+8+5+2+0+0 = 24`; Complexity `0+0+0+0+0+24+0 = 24`. This satisfies the sum invariant in [§ 3.2](#32-computation).
- The `top_critical_high_cve_findings` array contains three entries (the run scope happened to have only three Critical/High findings in this example, all under `top_cve_limit = 10`). Each entry has the required `scan_metadata` per [Rule R9](../template.md#r9--cve-attribution) and the required `severity` restricted to `[Critical, High]` per [Rule R4](../template.md#r4--cve-severity-breakdown).
- The `highest_maturity_risk_applications` array contains two entries (the run scope happened to have only two applications with detected `risk_score > 0`, both under `top_maturity_limit = 5`). Each entry carries the required `application_id` and `risk_score` per `#/$defs/maturityRiskApplication`; the optional `out_of_support_count` and `total_tracked_count` are populated in this example for CIO/CTO-facing readability.
- The `trend_versus_prior_run` object satisfies the per-facet sum invariant `net_improvements + net_regressions + unchanged + no_prior_run == total_applications` summed across all four facets: `10 + 7 + 53 + 26 = 96 = 24 × 4`. Per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun/description`, the totals across all four facets sum to `total_applications × 4`.
- The schema's `additionalProperties: false` constraint on every nested object excludes any field not enumerated above; in particular, no `rank` field appears on `cveFinding` or `maturityRiskApplication` objects (the rank is derived from array index at render time per [§ 4.5](#45-rendering) and [§ 5.5](#55-rendering)), and no `maturity_grade` field appears on `maturityRiskApplication` objects (the rendered Maturity Grade column is derived from the corresponding `matrix[i].maturity.current_grade` per [§ 5.5](#55-rendering)).

The complete top-level report-output object additionally includes `report_metadata` (the run's `run_date`, `template_version`, and optional `rubric_id` per `#/$defs/reportMetadata`) and `matrix` (the array of one matrix row per repository per `#/$defs/matrixRow`); those properties are documented in [`./pdf-output.md`](./pdf-output.md) and [`./grade-history.md`](./grade-history.md) respectively and are NOT computed by this document's aggregation procedure.

## 10. Cross-References

This document maintains the following outbound relative-path links; all resolve within the package per AAP § 0.10.2 "Standalone Package Rule" — no link reaches outside [`templates/technology-estate-report/`](..). The list is for reviewer convenience and is the canonical inventory of cross-references made by this file:

- [`../template.md`](../template.md) — § 3.5 Executive Summary canonical content list; § 5 Rules R3, R4, R5, R7, R8, R9, R10; § 6 Domain-Specific Success Criteria
- [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) — intermediate report data structure; canonical contract for `executive_summary`, `matrix`, `report_metadata`
- [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) — per-`(application_id, facet, run_date)` persistence record contract
- [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) — user-supplied rubric contract referenced from [§ 6.5](#65-rendering) for the Complexity Lock condition
- [`../config/facets.yaml`](../config/facets.yaml) — default `top_cve_limit` and `top_maturity_limit` configuration keys (under `executive_summary` namespace per [§ 4.4](#44-limit) and [§ 5.4](#54-limit))
- [`./facets.md`](./facets.md) — per-facet raw data sources (Tech Stack, Maturity, Security, Complexity); the Top CVE Findings list draws from § Security Summary; the Highest Maturity Risk list draws from § Maturity Summary
- [`./grading-engine.md`](./grading-engine.md) — grade emission per facet; the Complexity Lock per [Rule R5](../template.md#r5--complexity-placeholder-integrity) is documented there
- [`./grade-history.md`](./grade-history.md) — retrieval procedure for prior-grade lookup; heterogeneous-scope handling per [Rule R10](../template.md#r10--new-repo-compatibility); new-repository onboarding
- [`./pdf-output.md`](./pdf-output.md) — rendering of the Executive Summary on page 1 per [Rule R8](../template.md#r8--pdf-section-order); cell-rendering format for the Matrix Table that complements the Executive Summary
- [`./api-integrations.md`](./api-integrations.md) — endoflife.date, NVD, OSV API contracts; canonical [Rule R9](../template.md#r9--cve-attribution) attribution rule
- [`./configuration.md`](./configuration.md) — configuration override procedure for `top_cve_limit` and `top_maturity_limit` per [§ 4.4](#44-limit) and [§ 5.4](#54-limit)
- [`./troubleshooting.md`](./troubleshooting.md) — failure-mode-to-`Insufficient Data` mapping; relevant when applications produce `Insufficient Data` cells that affect the Top CVE list ([§ 4.6](#46-edge-cases)) and the Highest Maturity Risk list ([§ 5.6](#56-edge-cases))
- [`./usage.md`](./usage.md) — author workflow including specifying repository scope; relevant to [§ 2.1 Definition](#21-definition) of Total Applications In Scope
- [`./validation.md`](./validation.md) — [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) portfolio-level distribution count assertion; Domain Success Criterion 5 verification (*"Executive summary renders correct portfolio-level grade distribution counts matching the sum of individual application grades"*); [Gate 1](../template.md#611-gate-1--end-to-end-boundary-verification) live smoke test sign-off
