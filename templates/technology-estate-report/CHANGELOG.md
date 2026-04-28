# Changelog

All notable changes to the Technology Estate Report Blitzy prompt template package are documented in this file.
The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this package adheres
to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

All dates in this file use ISO 8601 (`YYYY-MM-DD`) format per Rules R3 and R9.

## [Unreleased]

_No unreleased changes._

## [0.1.0] — 2025-01-01

<!-- The 2025-01-01 date is a placeholder for the initial-authoring entry and is to be updated to the actual
ISO 8601 release date at delivery time. -->

Initial authoring of the standalone Technology Estate Report Blitzy prompt template package. This release
establishes the canonical Blitzy-executable prompt, the JSON Schema contracts for the rubric, the grade-history
persistence record, and the intermediate report output; the package configuration files; the supporting reference
documentation; and the worked examples — all under a single self-contained directory at
`templates/technology-estate-report/` with no dependency on any other Blitzy flow or template.

### Added

- `README.md` — package overview, file map, glossary, "How the Pieces Fit Together" navigation diagram, conceptual
  quick-start, and at-a-glance summaries of the ten Rules and five Validation Gates.
- `template.md` — canonical Blitzy prompt template entry point reproducing the user-supplied Role Definition,
  Task Context, Technical Specifications, Boundaries & Preservation, Rules R1–R10, and Validation Gates 1, 2, 8, 9,
  and 10 verbatim.
- `schemas/rubric.schema.json` — JSON Schema (Draft 2020-12) for the user-supplied A–F rubric per facet (Rule R1).
- `schemas/grade-history.schema.json` — JSON Schema for the grade-history persistence record keyed by
  `(application_id, facet, run_date)` (Rules R3, R7, R10).
- `schemas/report-output.schema.json` — JSON Schema for the intermediate report data structure that drives PDF
  rendering.
- `config/facets.yaml` — per-facet feature flags and the CVSS-to-severity-tier mapping (Rule R4).
- `config/rubric-example.yaml` — worked example rubric covering all four facets, including the user-stated example
  "No library out of support = A for Maturity".
- `config/allow-list.yaml` — network-egress allow-list enumerating the only permitted external hosts and explicitly
  denying any SaaS vendor host (Rule R6).
- `docs/architecture.md` — component inventory diagram, single-repository run sequence diagram, and the
  seven-component reachability matrix (Gate 9).
- `docs/facets.md` — Tech Stack, Maturity, Security, and Complexity facet reference documentation including the
  CVSS-to-severity-tier mapping diagram and per-facet "Insufficient Data" conditions (Rule R2).
- `docs/grading-engine.md` — rubric input format, per-application/per-facet evaluation procedure, the Complexity-lock
  rule, and the Rule R1 verification procedure.
- `docs/grade-history.md` — storage key shape, immutability contract, retrieval semantics, the `N/A` rendering rule
  for first-run pairs, and the Rule R10 heterogeneous-scope flow (mixing previously-ingested and net-new repositories).
- `docs/executive-summary.md` — portfolio-level aggregation rules: total applications in scope, A–F grade distribution
  per facet, top Critical/High CVE findings, highest-maturity-risk applications, and net trend versus the prior run.
- `docs/pdf-output.md` — Rule R8 section ordering, matrix table column order, the cell-rendering format
  `B  ←  prev: C  |  2025-10-01` (preserved verbatim per Rule R3), the Complexity placeholder render contract per
  Rule R5, and the PDF section layout diagram.
- `docs/api-integrations.md` — GitHub, GitLab, endoflife.date v1, NVD CVE API v2.0, and OSV API v1 contracts;
  rate-limit and retry semantics; the Rule R6 network-egress allow-list; and the Rule R9 attribution rule (scan
  timestamp plus source database label).
- `docs/configuration.md` — configuration-file reference enumerating every key in `config/*.yaml` with default values
  and override procedures.
- `docs/troubleshooting.md` — failure-mode-to-`Insufficient Data` cell-value mapping, common authentication failures,
  and rate-limit recovery procedures (Rule R2; Gate 2).
- `docs/usage.md` — step-by-step author workflow: provision `GITHUB_TOKEN`/`GITLAB_TOKEN` (and optional
  `NVD_API_KEY`), author the rubric, invoke the template, and retrieve the PDF.
- `docs/validation.md` — Validation Gates 1, 2, 8, 9, and 10 procedures, the seven-component reachability matrix, the
  domain-specific success criteria as test assertions, and the single-command execution path required by Gate 10.
- `examples/sample-rubric.yaml` — production-ready example rubric covering all four facets with explanatory comments
  on each grade threshold.
- `examples/sample-pdf-mockup.md` — Markdown mockup of the rendered PDF showing the executive summary content and the
  four-column matrix with worked example rows demonstrating each cell-state (graded, `N/A`, `Insufficient Data`,
  `Grade: TBD — definition pending`).
- `examples/grade-history-example.json` — sample persistence records demonstrating a first-run record (no prior),
  a second-run record showing prior grade plus ISO 8601 date, and a net-new repository joining a recurring run
  (Rule R10).

[unreleased]: ./
[0.1.0]: ./
