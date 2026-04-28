# Sample PDF Mockup — Technology Estate Report

> **Package:** `technology-estate-report v0.1.0`  
> **File:** `examples/sample-pdf-mockup.md`  
> **Scenario:** Run 3 of the worked example documented in [`../docs/grade-history.md`](../docs/grade-history.md) § 8 (`run_date` `2025-11-01T08:00:00Z`, 2 applications in scope).  
> **Schema reference:** [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) (`$id`: `urn:blitzy:technology-estate-report:report-output:v0.1.0`).

## Purpose

This file is the canonical Markdown mockup of the rendered PDF artifact produced by the Technology Estate Report template. It illustrates a single illustrative report run end-to-end so that template authors and reviewers can see, in one place, how every cell state, every section, and every layout rule renders. The mockup is intentionally a worked example: the underlying values come from a deterministic three-run scenario that ties together [`./sample-rubric.yaml`](./sample-rubric.yaml) (the rubric in force) and [`./grade-history-example.json`](./grade-history-example.json) (the persistence records that supply prior-grade values).

Use this document as the visual reference whenever the cell-format rules in [`../docs/pdf-output.md`](../docs/pdf-output.md) § 5 need to be cross-checked against an actual rendered output. The PDF that the Blitzy execution engine produces at runtime should match the section ordering, column ordering, and cell rendering shown below byte-for-byte modulo the page-delimiter annotations (which are mockup wrapper content, not in-PDF content).

## Operationalized Rules

The table below enumerates which template Rules from [`../template.md`](../template.md) § Rules are demonstrated by which sections of this mockup. A reviewer can verify each Rule by inspecting the cited mockup section.

| Rule | Where shown in the mockup |
|---|---|
| R2 (facet completeness) | Every matrix row has all four facet cells (no empty/absent cells); see Application Matrix Table |
| R3 (grade history fidelity) | Every cell shows `current ← prev: prior \| ISO 8601 date`; first-run cells show `prev: N/A` |
| R4 (CVE severity breakdown) | Security cell shows Critical / High / Medium / Low + total counts |
| R5 (Complexity placeholder) | Complexity cell shows `Grade: TBD — definition pending` + raw proxy metrics (LOC, file count, contributor count) |
| R7 (application identity stability) | Every row's first column shows `org/repo` key |
| R8 (PDF section order) | Page 1 contains Executive Summary; Matrix Table begins on Page 2 |
| R9 (CVE attribution) | Every Security cell shows scan timestamp + source database label |
| R10 (new repo compatibility) | Run 3 includes a repo whose first ingestion was Run 2 (still showing prev grade from Run 2); also illustrates an "Insufficient Data" cell recovery path |

---

## Mockup Conventions

This section explains how the rendered PDF is represented textually in this Markdown mockup. Read this section before encountering the simulated content in subsequent sections so that the visual conventions are unambiguous.

### Wrapper vs. In-PDF Content

The Markdown content of this file is divided into two kinds of content:

- **Wrapper content** — paragraphs, tables, and headings that exist *only* in this Markdown file and *not* in the rendered PDF. Wrapper content describes, annotates, or cross-references the in-PDF content. The Document Header, Mockup Conventions, Footnotes & Attribution (insofar as it explains what the reader is looking at), and Cross-References sections are all wrapper content.
- **In-PDF content** — the simulated text that would appear inside the actual rendered PDF page area. In-PDF content begins with a `─── BEGIN PDF PAGE N ───` marker and ends with a matching `─── END PDF PAGE N ───` marker. Between those markers, the content is rendered as Markdown blockquotes (each line prefixed with `> `) so that a reviewer reading the Markdown can visually distinguish in-PDF content from wrapper content at a glance.

The blockquote prefixes and the `BEGIN/END PDF PAGE N` markers do **not** appear in the actual rendered PDF. They are documentation conventions used in this Markdown mockup only.

### Cell-Rendering Rules

The four rendering rules below cover the four cell shapes that can appear in the matrix table. Each rule's worked example is presented in canonical form per [`../docs/pdf-output.md`](../docs/pdf-output.md) § 5.

- **Standard cell with prior grade (Rule R3)** — the canonical shape. The current grade appears first, followed by two spaces, followed by the leftwards-arrow character `←` (Unicode U+2190), followed by two spaces, followed by `prev:` and one space, followed by the prior grade letter, followed by two spaces, followed by the ASCII pipe `|`, followed by two spaces, followed by the prior run date in ISO 8601 (`YYYY-MM-DD`) form. The verbatim user-prompt example is reproduced in this exact form below — pipes are unescaped because this paragraph is prose, not a Markdown table:

  ```text
  B  ←  prev: C  |  2025-10-01
  ```

- **First-run cell — no prior history (Rule R10)** — when no prior run has produced a record for this `(application_id, facet)` pair, the prior-grade slot renders the literal `N/A` and the date is omitted. Example:

  ```text
  B  ←  prev: N/A
  ```

- **Insufficient Data cell (Rule R2 + Gate 2)** — when the underlying data sources for a facet were unavailable or incomplete, the cell renders the literal `Insufficient Data` with no current/prev modifiers. The failure reason is surfaced via a footnote reference that points to the Footnotes & Attribution section. A bare cell of this shape never silently omits the failure — Gate 2 prohibits silent suppression. Example:

  ```text
  Insufficient Data
  ```

- **Complexity locked cell (Rule R5)** — the Complexity column is locked to the verbatim placeholder string until a rubric is supplied. The cell renders two lines: the placeholder label followed by the raw proxy metrics. The `—` character is the Unicode em-dash U+2014, not a hyphen-minus and not an en-dash. Example:

  ```text
  Grade: TBD — definition pending
  LOC: 12,450 | Files: 187 | Contributors: 8
  ```

### Security Cell Content (Rule R4 + Rule R9)

The Security cell is the only cell that renders three lines instead of one. Line 1 is the standard cell rendering (Rule R3). Line 2 is the four-tier severity breakdown plus the total count (Rule R4). Line 3 is the scan timestamp in ISO 8601 datetime form plus the source database label (Rule R9). The severity tier names use the canonical capitalization `Critical`, `High`, `Medium`, `Low` per the [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `severityTier` enum. The source label values are uppercase `NVD`, `OSV`, or both joined as `NVD, OSV`. Example:

```text
C  ←  prev: D  |  2025-10-01
Critical: 0 | High: 4 | Medium: 8 | Low: 11 | Total: 23
Scan: 2025-11-01T08:01:58Z | Source: NVD, OSV
```

### Pipe Escaping Note

Markdown tables use the bare pipe character `|` as the column separator. Where cell-format text appears inside a Markdown table cell in the simulated Application Matrix Table further below, every embedded pipe is escaped as `\|` so the table parses correctly. In the actual rendered PDF, every pipe is the bare ASCII `|` character — the escaping is purely a Markdown rendering necessity for this mockup file. The verbatim user-prompt example `B  ←  prev: C  |  2025-10-01` therefore appears in two forms in this file: the unescaped form in this conventions section (because this is prose, not a table) and an escaped form (`B  ←  prev: C  \|  2025-10-01`) inside table cells.

---

## PAGE 1 — Executive Summary

> **PAGE 1 — Executive Summary** (begins below)
>
> ──────────────────── BEGIN PDF PAGE 1 ────────────────────
>
> # Technology Estate Report
>
> **Run date:** 2025-11-01T08:00:00Z &nbsp;&nbsp;|&nbsp;&nbsp; **Run ID:** `run-2025-11-01-001` &nbsp;&nbsp;|&nbsp;&nbsp; **Audience:** CIO / CTO
>
> ## Executive Summary
>
> ### 1. Total Applications In Scope
>
> **2 applications** were processed in this run (run_date 2025-11-01T08:00:00Z). The count is the cardinality of the matrix's row set; each application is identified by its `org/repo` key per Rule R7 and contributes exactly one row to the Application Matrix Table on Page 2.
>
> ### 2. Grade Distribution per Facet
>
> Each cell below counts how many applications received that grade for the named facet in this run. Counts sum to the total applications in scope (**2**) for every facet column — this invariant is enforced per the Domain Success Criterion "Executive summary renders correct portfolio-level grade distribution counts matching the sum of individual application grades."
>
> | Grade | Tech Stack | Maturity | Security | Complexity |
> |---|---|---|---|---|
> | A | 1 | 1 | 0 | 0 |
> | B | 0 | 0 | 1 | 0 |
> | C | 1 | 1 | 1 | 0 |
> | D | 0 | 0 | 0 | 0 |
> | F | 0 | 0 | 0 | 0 |
> | TBD | 0 | 0 | 0 | 2 |
> | Insufficient Data | 0 | 0 | 0 | 0 |
>
> *Column-sum invariant:* Tech Stack 1+0+1+0+0+0+0 = 2 ✓ &nbsp;&nbsp;|&nbsp;&nbsp; Maturity 1+0+1+0+0+0+0 = 2 ✓ &nbsp;&nbsp;|&nbsp;&nbsp; Security 0+1+1+0+0+0+0 = 2 ✓ &nbsp;&nbsp;|&nbsp;&nbsp; Complexity 0+0+0+0+0+2+0 = 2 ✓
>
> ### 3. Top Critical / High CVE Findings
>
> The table below ranks the most-impactful Critical and High security findings across the portfolio. Findings are deduplicated by `(application_id, cve_id)` and ranked by severity (Critical before High) then by application name (alphabetical) per [`../docs/executive-summary.md`](../docs/executive-summary.md) § 4. The default top-N is 10; this run's portfolio surfaced 7 eligible findings, all of severity High — zero Critical findings were observed in Run 3.
>
> | Rank | Application | CVE ID | Severity | Affected Package | Source | Scan Date |
> |---|---|---|---|---|---|---|
> | 1 | acme-inc/acme-api | CVE-2024-37890 | High | ws@8.16.0 | OSV | 2025-11-01 |
> | 2 | acme-inc/acme-api | CVE-2024-21538 | High | cross-spawn@7.0.3 | NVD | 2025-11-01 |
> | 3 | acme-inc/acme-api | CVE-2024-39338 | High | axios@1.7.0 | OSV | 2025-11-01 |
> | 4 | acme-inc/acme-api | CVE-2024-29415 | High | ip@2.0.0 | NVD | 2025-11-01 |
> | 5 | internal-tools/log-aggregator | CVE-2024-47081 | High | requests@2.31.0 | NVD | 2025-11-01 |
> | 6 | internal-tools/log-aggregator | CVE-2024-47220 | High | jinja2@3.1.3 | OSV | 2025-11-01 |
> | 7 | internal-tools/log-aggregator | CVE-2024-22195 | High | werkzeug@3.0.1 | NVD | 2025-11-01 |
>
> *Portfolio note:* This run records zero Critical findings — illustrative of a portfolio that has resolved its highest-severity exposures but retains a backlog of High-severity findings that warrants targeted remediation.
>
> ### 4. Highest Maturity Risk Applications
>
> The table below ranks applications by maturity risk score, calculated per [`../docs/executive-summary.md`](../docs/executive-summary.md) § 5 (out-of-support dependency percentage combined with days-since-runtime-EOL). The default top-N is 5; this run has only 2 applications in scope so all are listed.
>
> | Rank | Application | Maturity Grade | EOL Dependencies | Out-of-Support % | Notes |
> |---|---|---|---|---|---|
> | 1 | internal-tools/log-aggregator | C | 12 of 99 | 12.1% | Recovered from D in Run 2 (Python 3.8 → 3.11 migration shipped) |
> | 2 | acme-inc/acme-api | A | 0 of 188 | 0.0% | Stable; 1 dependency entering 6-month EOL window |
>
> *Portfolio note:* The application carrying the highest maturity risk in this run is `internal-tools/log-aggregator` with 12 of 99 dependencies past their published end-of-support dates. The application has nonetheless improved from Run 2 (Maturity grade D → C) following the runtime upgrade.
>
> ### 5. Trend vs Prior Run
>
> The table below compares Run 3 grades (`2025-11-01`) against the most recent prior-run grades (`2025-10-01`) for every `(application_id, facet)` pair that has a prior record. Trend labels are drawn from [`../docs/executive-summary.md`](../docs/executive-summary.md) § 6.5 Rendering: `Improved`, `Regressed`, `No Change`, `No Baseline`. These labels map one-to-one to the schema's count-bucket field names `net_improvements`, `net_regressions`, `unchanged`, `no_prior_run` per [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) `#/$defs/trendVersusPriorRun` — the schema records aggregate counts at the portfolio level while the per-pair table below uses the canonical rendering labels for the same four buckets.
>
> | Application | Facet | Prior Grade (2025-10-01) | Current Grade (2025-11-01) | Trend |
> |---|---|---|---|---|
> | acme-inc/acme-api | Tech Stack | B | A | Improved |
> | acme-inc/acme-api | Maturity | B | A | Improved |
> | acme-inc/acme-api | Security | D | C | Improved |
> | acme-inc/acme-api | Complexity | TBD | TBD | No Change |
> | internal-tools/log-aggregator | Tech Stack | C | C | No Change |
> | internal-tools/log-aggregator | Maturity | D | C | Improved |
> | internal-tools/log-aggregator | Security | Insufficient Data | B | Improved |
> | internal-tools/log-aggregator | Complexity | TBD | TBD | No Change |
>
> **Net portfolio movement vs prior run:** 5 facet-application pairs Improved, 0 Regressed, 3 No Change. No regressions were observed in this run.
>
> ──────────────────── END PDF PAGE 1 ────────────────────

---

## PAGE 2+ — Application Matrix Table

Each row in the matrix below represents one application; cells render `current_grade ← prev: prior_grade | ISO 8601 date` per Rule R3. The `application_id` (`org/repo`) is the primary key per Rule R7. Each row's facet cells render in the canonical column order: **Tech Stack Summary | Maturity Summary | Security Summary | Complexity Summary**. The matrix begins on Page 2 — Page 1 contains exclusively the Executive Summary content above, per Rule R8.

> **PAGE 2+ — Application Matrix Table** (begins below)
>
> ──────────────────── BEGIN PDF PAGE 2 ────────────────────
>
> ## Application Matrix
>
> | Application | Tech Stack Summary | Maturity Summary | Security Summary | Complexity Summary |
> |---|---|---|---|---|
> | `acme-inc/acme-api` | A  ←  prev: B  \|  2025-10-01<br/>Modern, single-cloud, primary-language consolidation | A  ←  prev: B  \|  2025-10-01<br/>0 dependencies past EOL; runtime supported through 2026-04-30 | C  ←  prev: D  \|  2025-10-01<br/>Critical: 0 \| High: 4 \| Medium: 8 \| Low: 11 \| Total: 23<br/>Scan: 2025-11-01T08:01:58Z \| Source: NVD, OSV | Grade: TBD — definition pending<br/>LOC: 13,050 \| Files: 196 \| Contributors: 9 |
> | `internal-tools/log-aggregator` | C  ←  prev: C  \|  2025-10-01<br/>Mixed primary languages; multiple primary clouds (aws, gcp) | C  ←  prev: D  \|  2025-10-01<br/>12 of 99 dependencies past EOL; runtime upgraded to 3.11 in October | B  ←  prev: Insufficient Data  \|  2025-10-01<br/>Critical: 0 \| High: 3 \| Medium: 4 \| Low: 8 \| Total: 15<br/>Scan: 2025-11-01T08:03:22Z \| Source: NVD, OSV | Grade: TBD — definition pending<br/>LOC: 8,910 \| Files: 148 \| Contributors: 5 |
>
> ──────────────────── END PDF PAGE 2 ────────────────────

### Matrix Table Layout Notes

The mockup uses HTML `<br/>` tags inside Markdown table cells to approximate the line-wraps that the actual rendered PDF achieves with native table-cell layout. GitHub-Flavored Markdown supports inline HTML in table cells, so `<br/>` renders as a line break in any standard Markdown viewer.

Each cell carries one or two short business-outcome sublabel lines underneath the canonical Rule-R3 line. The sublabel text is intended to give a CIO/CTO reader a one-glance interpretation of the grade. The sublabel content is derived from the per-application `raw_data` block of the underlying [`./grade-history-example.json`](./grade-history-example.json) records and is documented per facet in [`../docs/facets.md`](../docs/facets.md).

The Security cell is the only cell that renders three lines per Rule R4 + Rule R9. Both Security cells in this run record zero Critical findings; the High-severity findings enumerated in Executive Summary § 3 sum to 4 (`acme-inc/acme-api`) plus 3 (`internal-tools/log-aggregator`) for a total of 7 — matching the seven rows in the Top CVE Findings table on Page 1 (Domain Success Criterion: "Security Summary CVE counts match NVD/OSV lookup for a known-vulnerable dependency version").

Both Complexity cells render the verbatim placeholder string `Grade: TBD — definition pending` followed by the raw proxy metrics (LOC, file count, contributor count). No A–F letter grade appears in either Complexity cell — Rule R5 prohibits backfill until an explicit Complexity rubric is supplied by the user.

Real rendered PDFs may apply cell coloring (green for A/B, amber for C, red for D/F, gray for `TBD` / `Insufficient Data`) as an optional treatment chosen by the PDF renderer at runtime. This Markdown mockup deliberately has no color so that a reviewer focuses on cell content and section ordering.

---

## Footnotes & Attribution

The footnotes & attribution section consolidates the per-cell scan metadata (already shown inline in the Application Matrix Table above) and any `Insufficient Data` failure-reason references. In the actual rendered PDF, this content appears either as a footnote block at the bottom of the matrix table or as a final page after the matrix, depending on the page layout chosen by the renderer.

### Scan Attribution Summary

Per Rule R9, every Security Summary result MUST include the scan timestamp (ISO 8601) and the source database (NVD, OSV, or both); undated or unattributed CVE counts are a failing state. The table below restates each application's scan metadata for at-a-glance auditability.

| Application | Scan Timestamp (ISO 8601) | Source Database |
|---|---|---|
| acme-inc/acme-api | 2025-11-01T08:01:58Z | NVD, OSV |
| internal-tools/log-aggregator | 2025-11-01T08:03:22Z | NVD, OSV |

### Run Scope

Per Rule R7, the same repository MUST resolve to the same `application_id` across all runs (`org/repo` form). Per Rule R10, template execution MUST succeed when a mix of previously-ingested repositories and net-new repositories appear in the same run. The table below shows each application's first-ever ingestion run and its history continuity status as of this run.

| Application | First-Ever Run | Latest Run | History Status |
|---|---|---|---|
| acme-inc/acme-api | 2025-09-01T08:00:00Z (Run 1) | 2025-11-01T08:00:00Z (Run 3) | Continuous: 3 sequential runs |
| internal-tools/log-aggregator | 2025-10-01T08:00:00Z (Run 2) | 2025-11-01T08:00:00Z (Run 3) | Continuous: 2 sequential runs (joined as net-new repo at Run 2) |

This run successfully processed 1 previously-ingested repository (`acme-inc/acme-api`, with continuous grade history since Run 1) and 1 application that joined the portfolio at Run 2 (`internal-tools/log-aggregator`, which received `prev: N/A` for its first-ever rendering and now carries a 1-run prior history into Run 3) — demonstrating Rule R10's heterogeneous-scope handling.

### Insufficient Data Recoveries

The `internal-tools/log-aggregator` Security cell illustrates the `Insufficient Data` recovery path required by Rule R2 and Gate 2. In Run 2, this cell rendered the literal `Insufficient Data` because the SBOM generation step timed out for the application's Python ecosystem manifests, preventing the CVE scanner from producing severity counts. The failure was surfaced as an explicit cell value (not a silent omission) per Gate 2's prohibition on suppressed errors, and the failure reason was persisted in the grade-history record.

In Run 3, the SBOM generation succeeded and the cell renders a `B` current grade with `Insufficient Data` in the prior-grade slot. The full recovery procedure — including how to diagnose the underlying failure, how to retry, and how the next run automatically picks up the recovered data — is documented in [`../docs/troubleshooting.md`](../docs/troubleshooting.md) § 7.3.

This is the only `Insufficient Data` recovery in this run; no other facet/application pair had an `Insufficient Data` prior grade that subsequently resolved.

---

## Cross-References & Related Files

This mockup integrates several artifacts in the template package. The bullets below enumerate the related files so a reviewer can navigate from this mockup to its upstream contracts and downstream documentation.

- Schema contract for the rendered PDF: [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) (`$id` `urn:blitzy:technology-estate-report:report-output:v0.1.0`)
- Source rubric used for the grading: [`./sample-rubric.yaml`](./sample-rubric.yaml) (production-ready example covering all four facets, with the Complexity facet rubric intentionally empty per Rule R5)
- Underlying grade history records used for prior-grade lookup: [`./grade-history-example.json`](./grade-history-example.json) (3 sequential runs of worked-example data; this mockup renders Run 3)
- Documentation of cell rendering format: [`../docs/pdf-output.md`](../docs/pdf-output.md) § 5
- Documentation of executive summary aggregation rules: [`../docs/executive-summary.md`](../docs/executive-summary.md) § 2-6
- Documentation of facet detection rules: [`../docs/facets.md`](../docs/facets.md)
- Documentation of grade history persistence and the worked example: [`../docs/grade-history.md`](../docs/grade-history.md) § 8
- Documentation of `Insufficient Data` cell handling: [`../docs/troubleshooting.md`](../docs/troubleshooting.md) § 3
- Operationalized rules: see [`../template.md`](../template.md) § Rules (R1–R10) and [`../docs/validation.md`](../docs/validation.md) for the verification procedures that enforce them

This mockup represents the rendered PDF artifact intended for CIO/CTO consumption. The actual PDF is produced by the Blitzy execution engine when the template at [`../template.md`](../template.md) is invoked per [`../docs/usage.md`](../docs/usage.md) § 6.
