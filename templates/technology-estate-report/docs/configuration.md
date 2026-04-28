# Configuration Reference — Technology Estate Report Template

## 1. Overview

This document is the **single canonical reference** for every configuration surface of the Technology
Estate Report Blitzy prompt template package. The template's configuration surfaces are the three files in
[`../config/`](../config/): [`facets.yaml`](../config/facets.yaml),
[`rubric-example.yaml`](../config/rubric-example.yaml), and
[`allow-list.yaml`](../config/allow-list.yaml). Each file is authoritative for its own concern — per-facet
feature flags, severity-tier mapping, "Insufficient Data" conditions, and cell-rendering literals
(`facets.yaml`); the worked-example A–F rubric input format (`rubric-example.yaml`); and the network-egress
allow-list enforcing [Rule R6](../template.md#r6--saas-data-sourcing) (`allow-list.yaml`).

The intended modification cadence varies by file. [`../config/facets.yaml`](../config/facets.yaml) is rarely
modified — only when the CVSS-to-severity-tier mapping is revised, when a per-facet "Insufficient Data"
condition is amended, or when a Rule-R3/R4/R5 verbatim surface (cell format, severity tier labels,
placeholder label) is intentionally evolved with a corresponding [`../CHANGELOG.md`](../CHANGELOG.md) entry
and version bump. [`../config/rubric-example.yaml`](../config/rubric-example.yaml) is the worked-example
template that report authors copy and customize per run; the production-ready example with annotated
thresholds for all four facets is [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml).
[`../config/allow-list.yaml`](../config/allow-list.yaml) is **operationally-controlled** and modified only
via PR with security-reviewer sign-off because adding or removing hosts has security and compliance
implications under [Rule R6](../template.md#r6--saas-data-sourcing).

All three YAML files use **UTF-8 encoding**, **double-quoted strings** preferred over unquoted strings (to
avoid YAML 1.1 implicit type coercions on values like `Yes`, `No`, `On`, `Off`, and unquoted version
numbers), and **2-space indentation**. The YAML files themselves carry inline comments at every section but
the **prose explanation, type system, default values, and modification-cadence guidance live here**. Per the
AAP § 0.10.2 "No Redundancy Rule," the verbatim text of [Rules R1–R10](../template.md#5-rules) lives in
[`../template.md`](../template.md) and is referenced — not duplicated — from this document.

Three principles govern this reference:

- **Verbatim Rule surfaces are byte-for-byte invariant.** Configuration values that encode a verbatim Rule
  R3, R4, or R5 surface (the cell-rendering format `B  ←  prev: C  |  2025-10-01`; the severity tier labels
  `Critical`, `High`, `Medium`, `Low`; the Complexity placeholder `Grade: TBD — definition pending`) are
  marked **DO NOT alter** in their respective sections below. Modifying these values silently will break
  Rule conformance and Gate 8 verification.
- **Cross-file consistency is enforced operationally**, not by a build step. § 6.3 below enumerates the
  invariants that authors and reviewers MUST hand-verify when editing any of the three YAML files.
- **Credentials never appear in any committed file.** All authentication tokens are passed at run time as
  environment variables per [`./usage.md`](./usage.md) § Provisioning Credentials and
  [`./api-integrations.md`](./api-integrations.md) § 9. § 5 below documents only the env-var **names**; no
  example values approximate any real token.

## 2. `../config/facets.yaml` — Per-Facet Configuration

### 2.1 File Purpose

[`../config/facets.yaml`](../config/facets.yaml) encodes the **per-facet feature flags**, the
**canonical CVSS v3.1 base-score-to-severity-tier mapping** per [Rule R4](../template.md#r4--cve-severity-breakdown),
the **per-facet "Insufficient Data" threshold conditions** per [Rule R2](../template.md#r2--facet-completeness)
and [Gate 2](../template.md#612-gate-2--zero-warning-build), the **Complexity placeholder configuration**
per [Rule R5](../template.md#r5--complexity-placeholder-integrity), and the **default cell-rendering
literals** consumed by the PDF renderer (per [Rule R3](../template.md#r3--grade-history-fidelity)). It is
referenced at run time by every analysis component (tech stack detector, maturity analyzer, CVE scanner,
complexity extractor, grading engine, PDF renderer) and is rarely modified.

This file is the **single source of truth** for the CVSS-to-severity mapping and the cell-rendering
literals; [`./facets.md`](./facets.md), [`./pdf-output.md`](./pdf-output.md),
[`./troubleshooting.md`](./troubleshooting.md), and the schema files reference these values rather than
duplicating them.

### 2.2 Top-Level Keys

| Key | Type | Required | Description |
|---|---|---|---|
| `version` | string | yes | Semver version of this configuration file (e.g., `"0.1.0"`); incremented on schema or default-value changes per § 7 below. |
| `description` | string (block scalar) | yes | Short human-readable description anchoring the file to its rule operationalization (R2, R4, R5) and to this reference document. |
| `facets` | object | yes | Per-facet sub-objects keyed by the four canonical facet identifiers in `[tech_stack, maturity, security, complexity]`. The four sub-keys appear in canonical column order matching the matrix-table column order in [`./pdf-output.md`](./pdf-output.md). |
| `severity_tier_mapping` | object | yes | The canonical CVSS v3.1 base-score-to-tier table. Single source of truth for the CVSS-to-severity translation per [Rule R4](../template.md#r4--cve-severity-breakdown). |
| `severity_tier_labels` | array of strings | yes | The canonical highest-severity-first label ordering used by the PDF renderer for column ordering within the Security cell. Mirrors `severity_tier_mapping.tiers[].name` exactly. |
| `rendering_defaults` | object | yes | The cell-rendering format strings, glyph encodings, ISO 8601 date format, and special-state literals (`Insufficient Data`, `N/A`, `Grade: TBD — definition pending`) consumed by the PDF renderer. |
| `references` | object | yes | Package-internal documentation links that consume or describe this file. All paths are relative to the location of `facets.yaml` and resolve within the package. |

### 2.3 `facets.tech_stack`

The Tech Stack Summary facet (column 1 of the matrix table). Detection sources are source files, dependency
manifests, and IaC configurations per [`./facets.md`](./facets.md) § Tech Stack Summary.

- `enabled` (boolean): Master enable/disable for the facet. Default `true`. Per [Rule R2](../template.md#r2--facet-completeness),
  every facet column is present in every report run; this flag SHOULD remain `true` in any production
  configuration. When `false`, every Tech Stack cell renders `Insufficient Data` per [Rule R2](../template.md#r2--facet-completeness)
  rather than being silently omitted (Gate 2).
- `display_name` (string): Human-readable column header for the Tech Stack facet. Default `"Tech Stack
  Summary"` (verbatim from the user prompt's matrix-table column-order specification).
- `column_order` (integer): Position of this facet in the matrix table; default `1`. The four facets
  appear in canonical order `tech_stack` (1), `maturity` (2), `security` (3), `complexity` (4) per
  [`./pdf-output.md`](./pdf-output.md) § 4 Matrix Table Columns. **DO NOT alter** without a corresponding
  PDF-output specification revision.
- `data_sources` (array of strings): Logical data sources consumed by the Tech Stack detector. Default
  `[source_files, dependency_manifests, iac_configs]`.
- `insufficient_data_conditions` (array of strings): Human-readable conditions under which the Tech Stack
  cell renders `Insufficient Data` per [Rule R2](../template.md#r2--facet-completeness). The default
  conditions are: `"No source files detected"`, `"No dependency manifests detected"`, and `"All three
  sub-detectors (language, cloud, vendor/framework) failed"`.
- `facet_anchor` (string): GitHub-Markdown anchor fragment for cross-document linking. Default
  `"#tech-stack-summary"`. Mirrors the fragment portion of `documentation:` below.
- `documentation` (string): Relative-path link to the canonical detection-rule documentation in
  [`./facets.md`](./facets.md). Default `"../docs/facets.md#tech-stack-summary"`.
- `language_detection` (object): Sub-configuration for language detection.
  - `metric` (enum string): One of `file_count_share`, `byte_count_share`, `loc_share`. Default
    `file_count_share`. Per [`./facets.md`](./facets.md) § Tech Stack Summary § Language Detection,
    file-count share is the canonical metric.
  - `min_file_count` (integer): Minimum number of files matched against an extension before the language
    is reported. Default `1`.
  - `description` (string): Block-scalar prose linking back to [`./facets.md`](./facets.md).
- `cloud_provider_detection` (object): Sub-configuration for cloud provider identification from IaC files.
  - `iac_resource_type_namespaces` (object): Per-cloud arrays of IaC resource-type prefix patterns
    (Terraform `aws_*`, `azurerm_*`, `google_*`; CloudFormation `AWS::*`; Azure ARM `Microsoft.*`).
    Authors who add a new cloud SHOULD add a new key alongside `aws`, `azure`, `gcp` and document the
    rationale in [`../CHANGELOG.md`](../CHANGELOG.md).
  - `helm_chart_annotations` (array of strings): Helm chart annotation keys consulted for cloud-provider
    metadata. Default `["app.kubernetes.io/cloud", "cloud.provider"]`.
  - `description` (string): Block-scalar prose linking back to [`./facets.md`](./facets.md) § Cloud
    Provider Identification.

### 2.4 `facets.maturity`

The Maturity Summary facet (column 2 of the matrix table). Detection sources are dependency manifests and
runtime declarations per [`./facets.md`](./facets.md) § Maturity Summary.

- `enabled` (boolean): Master enable/disable. Default `true`. Same Rule R2 reasoning as
  `tech_stack.enabled`.
- `display_name` (string): Default `"Maturity Summary"` (verbatim).
- `column_order` (integer): Default `2`. **DO NOT alter** without a corresponding PDF-output
  specification revision.
- `data_sources` (array of strings): Default `[dependency_manifests, runtime_declarations]`.
- `insufficient_data_conditions` (array of strings): Default conditions are: `"No dependency manifests or
  runtime declarations detected"`, `"endoflife.date does not track any of the detected products (no slug
  resolution)"`, and `"endoflife.date API persistently unreachable after retries (per Gate 2, surface as
  Insufficient Data)"`. Per [Rule R2](../template.md#r2--facet-completeness), each condition maps to the
  cell value `Insufficient Data` rather than a silent omission.
- `facet_anchor` (string): Default `"#maturity-summary"`.
- `documentation` (string): Default `"../docs/facets.md#maturity-summary"`.
- `eol_lookup` (object): Sub-configuration for the endoflife.date EOL lookup.
  - `provider` (string): Default `"endoflife.date"`. **DO NOT alter** in v0.1.0; only one EOL data
    provider is supported per [`./api-integrations.md`](./api-integrations.md) § endoflife.date API v1.
  - `api_version` (string): Default `"v1"`. MUST agree with [`./api-integrations.md`](./api-integrations.md)
    § endoflife.date API v1; cf. § 6.3 Cross-File Consistency below.
  - `slug_resolution_table_documentation` (string): Relative-path link to the product-slug-to-product-name
    resolution table. Default `"../docs/facets.md#maturity-summary-product-slug-resolution"`.
  - `description` (string): Block-scalar prose linking back to [`./facets.md`](./facets.md).
- `technical_debt_score` (object): Sub-configuration for the Maturity rubric input.
  - `formula` (string): Documents the canonical formula. Default
    `"out_of_support_dependencies / total_tracked_dependencies"`. The score is consumed by the rubric per
    [Rule R1](../template.md#r1--rubric-editability) — the user-supplied rubric defines the score-to-grade
    thresholds at generation time; this configuration value documents the score formula but does NOT encode
    threshold values.
  - `range` (array of two numbers): Closed interval the score lies in. Default `[0.0, 1.0]`.
  - `description` (string): Block-scalar prose tying the score formula to [Rule R1](../template.md#r1--rubric-editability)
    and [`./grading-engine.md`](./grading-engine.md).

### 2.5 `facets.security`

The Security Summary facet (column 3 of the matrix table). Detection source is dependency manifests
(transformed into a CycloneDX SBOM and queried against NVD and OSV) per
[`./facets.md`](./facets.md) § Security Summary and [`./api-integrations.md`](./api-integrations.md)
§§ NVD/OSV.

- `enabled` (boolean): Master enable/disable. Default `true`.
- `display_name` (string): Default `"Security Summary"` (verbatim).
- `column_order` (integer): Default `3`. **DO NOT alter** without a corresponding PDF-output
  specification revision.
- `data_sources` (array of strings): Default `[dependency_manifests]`.
- `insufficient_data_conditions` (array of strings): Default conditions are: `"SBOM generation failed for
  all detected ecosystems"`, `"Both NVD and OSV CVE databases persistently unreachable after retries"`, and
  `"No dependency manifests detected"`.
- `facet_anchor` (string): Default `"#security-summary"`.
- `documentation` (string): Default `"../docs/facets.md#security-summary"`.
- `sbom_generation` (object): Sub-configuration for CycloneDX SBOM generation.
  - `format` (enum string): Default `"cyclonedx"`. **DO NOT alter** in v0.1.0; CycloneDX is the
    package-of-record vendor-neutral SBOM format per
    [`./api-integrations.md`](./api-integrations.md) § SBOM Generation.
  - `description` (string): Block-scalar prose linking back to
    [`./api-integrations.md`](./api-integrations.md) § SBOM Generation.
- `cve_lookup` (object): Sub-configuration for CVE record retrieval.
  - `primary_source` (enum string): Default `"NVD"`. **DO NOT alter** without first updating
    [`./api-integrations.md`](./api-integrations.md) § NVD CVE API v2.0.
  - `secondary_source` (enum string): Default `"OSV"`. Used for cross-reference and alternate coverage
    per [`./api-integrations.md`](./api-integrations.md) § OSV API v1.
  - `dedup_strategy` (enum string): Default `"by_cve_id"`. The CVE deduplication strategy when both NVD
    and OSV report the same CVE; on conflict the NVD CVSS score is preferred per
    [`./facets.md`](./facets.md) § Security Summary § Deduplication.
  - `attribution_required` (boolean): Default `true`. **DO NOT alter** — this flag enforces
    [Rule R9](../template.md#r9--cve-attribution): every CVE result records `scan_timestamp` (ISO 8601)
    and `source_database_label` (`NVD`, `OSV`, or both).
  - `description` (string): Block-scalar prose linking back to
    [`./api-integrations.md`](./api-integrations.md) §§ NVD/OSV.
- `severity_tier_counting` (object): Sub-configuration for severity-tier counting per
  [Rule R4](../template.md#r4--cve-severity-breakdown).
  - `tiers` (array of strings): Default `[Critical, High, Medium, Low]`. **DO NOT alter** —
    this is the verbatim [Rule R4](../template.md#r4--cve-severity-breakdown) surface (capital first
    letter); cf. § 6.3 Cross-File Consistency below.
  - `total_required` (boolean): Default `true`. **DO NOT alter** — Rule R4 mandates "four severity
    labels + total" for every Security Summary cell.
  - `description` (string): Block-scalar prose linking back to [Rule R4](../template.md#r4--cve-severity-breakdown).

### 2.6 `facets.complexity`

The Complexity Summary facet (column 4 of the matrix table). Locked to the placeholder
`Grade: TBD — definition pending` until the user supplies a Complexity rubric per
[Rule R5](../template.md#r5--complexity-placeholder-integrity).

- `enabled` (boolean): Master enable/disable. Default `true`. **DO NOT set to `false`** —
  [Rule R5](../template.md#r5--complexity-placeholder-integrity) mandates that the Complexity column
  is present in every run.
- `display_name` (string): Default `"Complexity Summary"` (verbatim).
- `column_order` (integer): Default `4`. **DO NOT alter** without a corresponding PDF-output
  specification revision.
- `data_sources` (array of strings): Default `[source_files, git_history]`.
- `insufficient_data_conditions` (array of strings): Default conditions are: `"No source files
  detected"` and `"git history unavailable (e.g., shallow clone or fetch failure)"`. Both conditions apply
  only when the Complexity facet is **unlocked** (i.e., when the user has supplied a non-empty Complexity
  rubric); while the facet is locked per [Rule R5](../template.md#r5--complexity-placeholder-integrity), the
  cell renders the placeholder regardless of data availability.
- `facet_anchor` (string): Default `"#complexity-summary"`.
- `documentation` (string): Default `"../docs/facets.md#complexity-summary"`.
- `placeholder_label` (string): Default `"Grade: TBD — definition pending"` (em-dash U+2014 EM DASH;
  UTF-8 byte sequence `0xE2 0x80 0x94`). **DO NOT alter** — this is the verbatim
  [Rule R5](../template.md#r5--complexity-placeholder-integrity) surface; cf. § 6.3 Cross-File
  Consistency below. Authors editing this value MUST verify the em-dash glyph survives copy/paste; many
  editors silently transliterate to a hyphen-minus (U+002D) or en-dash (U+2013).
- `placeholder_locked_until_rubric_supplied` (boolean): Default `true`. **DO NOT alter** in v0.1.0 — the
  Complexity facet ships locked per [Rule R5](../template.md#r5--complexity-placeholder-integrity).
  Setting to `false` requires that the Complexity rubric in the user-supplied rubric document is non-empty;
  see [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) for the unlocked-state worked
  example.
- `raw_proxy_metrics` (object): Sub-configuration for the three raw proxy metrics rendered alongside the
  Complexity placeholder per [Rule R5](../template.md#r5--complexity-placeholder-integrity)
  ("LOC, file count, contributor count").
  - `loc.metric` (string): Default `"lines_of_code"`.
  - `loc.description` (string): Default `"Total lines of code across all detected source files. Counts
    non-blank, non-comment lines."`
  - `file_count.metric` (string): Default `"file_count"`.
  - `file_count.description` (string): Default `"Total count of source files."`
  - `contributor_count.metric` (string): Default `"distinct_contributors"`.
  - `contributor_count.description` (string): Default `"Distinct contributor count derived from git
    history."`
- `complexity_lock_description` (string, block scalar): Verbatim restatement of
  [Rule R5](../template.md#r5--complexity-placeholder-integrity) for in-file documentation. **DO NOT
  alter** — modifying this prose silently would create rule-text drift between this file and
  [`../template.md`](../template.md) § 5 Rules.

### 2.7 `severity_tier_mapping` (Top-Level)

The canonical CVSS v3.1 base-score-to-severity-tier table per [Rule R4](../template.md#r4--cve-severity-breakdown).
This object is the **single source of truth** for the CVSS-to-severity translation; no other file in the
package duplicates these ranges.

- `cvss_version` (string): Default `"3.1"`. The CVSS version is **quoted as a string** to prevent YAML
  interpretation as a float (`3.1` would otherwise be parsed as a YAML float and stringified inconsistently
  across YAML parsers). **DO NOT alter** without first updating [`./api-integrations.md`](./api-integrations.md)
  § NVD CVE API v2.0.
- `description` (string, block scalar): Block-scalar prose tying the table to [Rule R4](../template.md#r4--cve-severity-breakdown)
  and [`./facets.md`](./facets.md) § Security Summary § CVSS-to-Severity Mapping.
- `tiers` (array of objects): The four severity tiers in highest-severity-first order
  (Critical → High → Medium → Low). Each tier object has:
  - `name` (enum string): One of `Critical`, `High`, `Medium`, `Low` (capital first letter). **DO NOT
    alter** — this is the verbatim [Rule R4](../template.md#r4--cve-severity-breakdown) surface.
  - `min` (number): Inclusive lower bound of the CVSS v3.1 base score range.
  - `max` (number): Inclusive upper bound of the CVSS v3.1 base score range.
  - `description` (string): Per-tier human-readable description.

  The canonical default ranges align with NIST's published CVSS v3.1 severity rating system:

  ```yaml
  tiers:
    - name: Critical
      min: 9.0
      max: 10.0
    - name: High
      min: 7.0
      max: 8.9
    - name: Medium
      min: 4.0
      max: 6.9
    - name: Low
      min: 0.1
      max: 3.9
  ```

  Authors who alter this mapping MUST ensure the four ranges are non-overlapping and cover the full
  `0.1`–`10.0` score band. Scores below `0.1` or with `baseSeverity: NONE` are EXCLUDED from severity tier
  counts and surface as `Insufficient Data` per `none_handling` below and per [`./facets.md`](./facets.md)
  § Security Summary § CVSS-to-Severity Tier Mapping.
- `none_handling` (object): Sub-configuration for CVE records without a CVSS v3.1 base score.
  - `condition` (string): Default `"CVE record has no CVSS v3.1 base score"`.
  - `outcome` (enum string): Default `"insufficient_data"`. Per [Rule R2](../template.md#r2--facet-completeness)
    and [Gate 2](../template.md#612-gate-2--zero-warning-build), an unscored CVE record is not silently
    dropped; it is recorded under an "unscored" bucket and surfaces as `Insufficient Data` if it is the
    only available signal for the facet.
  - `description` (string, block scalar): Block-scalar prose tying the handling to
    [Rule R2](../template.md#r2--facet-completeness) and [Gate 2](../template.md#612-gate-2--zero-warning-build).

### 2.8 `severity_tier_labels` (Top-Level)

The canonical highest-severity-first label ordering. Default `["Critical", "High", "Medium", "Low"]`.
**DO NOT alter** — this is the verbatim [Rule R4](../template.md#r4--cve-severity-breakdown) surface
(capital first letter, exact spelling). MUST equal `severity_tier_mapping.tiers[].name` byte-for-byte; cf.
§ 6.3 Cross-File Consistency below.

This top-level array is exposed alongside `severity_tier_mapping.tiers[].name` so that downstream consumers
(the executive summary aggregator's grade-distribution counter; the PDF renderer's column ordering within
the Security cell) can read just the labels without traversing the full tier-range mapping. The two
locations MUST stay byte-for-byte synchronized.

### 2.9 `rendering_defaults` (Top-Level)

The cell-rendering format strings, glyph encodings, ISO 8601 date format, and special-state literals
consumed by the PDF renderer. This object is the **single source of truth** for the verbatim
[Rule R3](../template.md#r3--grade-history-fidelity), [Rule R2](../template.md#r2--facet-completeness),
and [Rule R5](../template.md#r5--complexity-placeholder-integrity) surfaces; the PDF renderer reads these
literals from this file rather than embedding them in code.

- `cell_format` (string): The inline cell-rendering format with placeholders. Default
  `"{current_grade}  ←  prev: {prior_grade}  |  {prior_run_date}"`. **DO NOT alter** — this is the verbatim
  [Rule R3](../template.md#r3--grade-history-fidelity) surface as illustrated by the user-supplied worked
  example `B  ←  prev: C  |  2025-10-01`. The format string preserves **two spaces** around the `←`
  (U+2190 LEFTWARDS ARROW) and **two spaces** around the `|` (U+007C ASCII pipe). See
  [`./pdf-output.md`](./pdf-output.md) § 5 Cell Rendering Format.
- `cell_format_first_run` (string): The first-run format used when no prior record exists for an
  `(application_id, facet)` pair. Default `"{current_grade}  ←  prev: N/A"`. **DO NOT alter** — this is
  the verbatim [Rule R3](../template.md#r3--grade-history-fidelity) + [Rule R10](../template.md#r10--new-repo-compatibility)
  surface. The first-run format omits the date segment because no prior `run_date` exists.
- `insufficient_data_value` (string): Default `"Insufficient Data"` (capital I, capital D, single ASCII
  space between the two words). **DO NOT alter** — this is the verbatim [Rule R2](../template.md#r2--facet-completeness)
  surface. See [`./troubleshooting.md`](./troubleshooting.md) § Failure-Mode-to-Cell-Value Mapping.
- `na_value` (string): Default `"N/A"` (capital N, ASCII slash, capital A). **DO NOT alter** — this is
  the verbatim [Rule R3](../template.md#r3--grade-history-fidelity) "N/A" rendering for the prior-grade
  slot when no prior run exists.
- `tbd_placeholder_label` (string): Default `"Grade: TBD — definition pending"` (em-dash U+2014). **DO
  NOT alter** — this is the verbatim [Rule R5](../template.md#r5--complexity-placeholder-integrity)
  surface and MUST equal `facets.complexity.placeholder_label` byte-for-byte; cf. § 6.3 Cross-File
  Consistency below.
- `arrow_glyph` (string): Default `"←"` (U+2190 LEFTWARDS ARROW; UTF-8 byte sequence `0xE2 0x86 0x90`).
  **DO NOT alter** — required by `cell_format` above. Authors editing this value MUST verify the arrow
  glyph survives copy/paste; many editors silently transliterate to ASCII `<-`.
- `pipe_glyph` (string): Default `"|"` (U+007C ASCII PIPE). Used as the date-separator in
  `cell_format`.
- `em_dash_glyph` (string): Default `"—"` (U+2014 EM DASH; UTF-8 byte sequence `0xE2 0x80 0x94`).
  Used in `tbd_placeholder_label` and `facets.complexity.placeholder_label`. **DO NOT alter** — same
  copy-paste caveat as `arrow_glyph`; many editors silently transliterate U+2014 to U+002D HYPHEN-MINUS or
  U+2013 EN DASH.
- `iso_8601_date_format` (string): Default `"YYYY-MM-DD"`. Used by `cell_format` for the
  `{prior_run_date}` placeholder and by the grade-history persistence layer for the `run_date` field. Per
  [Rule R3](../template.md#r3--grade-history-fidelity) and [Rule R9](../template.md#r9--cve-attribution),
  ISO 8601 is the mandated date format.
- `description` (string, block scalar): Block-scalar prose tying the rendering literals to
  [Rules R2, R3, R5](../template.md#5-rules) and [`./pdf-output.md`](./pdf-output.md).

### 2.10 `references` (Top-Level)

Package-internal documentation links that consume or describe this file. All paths are relative to the
location of `facets.yaml` (i.e., `templates/technology-estate-report/config/`) and resolve within the
package. Default keys are `documentation`, `facets_documentation`, `pdf_output_documentation`,
`troubleshooting`, `api_integrations`, `template_entry_point`, `rule_r2_canonical_text`,
`rule_r4_canonical_text`, and `rule_r5_canonical_text`. No path reaches outside the package per the AAP
§ 0.10.2 "Standalone Package Rule"; no external URL appears in this file.

### 2.11 Worked Example

A minimal but complete YAML excerpt showing the top-level shape of `facets.yaml`. The full canonical file
is [`../config/facets.yaml`](../config/facets.yaml); the excerpt below shows the structure only:

```yaml
---
version: "0.1.0"

description: >-
  Canonical per-facet configuration for the Technology Estate Report Blitzy
  prompt template package.

facets:
  tech_stack:
    enabled: true
    display_name: "Tech Stack Summary"
    column_order: 1
    data_sources: [source_files, dependency_manifests, iac_configs]
    insufficient_data_conditions:
      - "No source files detected"
      - "No dependency manifests detected"
      - "All three sub-detectors (language, cloud, vendor/framework) failed"
    facet_anchor: "#tech-stack-summary"
    documentation: "../docs/facets.md#tech-stack-summary"

  maturity:
    enabled: true
    display_name: "Maturity Summary"
    column_order: 2
    # ... (see ../config/facets.yaml for full content)

  security:
    enabled: true
    display_name: "Security Summary"
    column_order: 3
    severity_tier_counting:
      tiers: ["Critical", "High", "Medium", "Low"]
      total_required: true
    # ... (see ../config/facets.yaml for full content)

  complexity:
    enabled: true
    display_name: "Complexity Summary"
    column_order: 4
    placeholder_label: "Grade: TBD — definition pending"
    placeholder_locked_until_rubric_supplied: true
    # ... (see ../config/facets.yaml for full content)

severity_tier_mapping:
  cvss_version: "3.1"
  tiers:
    - name: "Critical"
      min: 9.0
      max: 10.0
    - name: "High"
      min: 7.0
      max: 8.9
    - name: "Medium"
      min: 4.0
      max: 6.9
    - name: "Low"
      min: 0.1
      max: 3.9
  none_handling:
    condition: "CVE record has no CVSS v3.1 base score"
    outcome: "insufficient_data"

severity_tier_labels: ["Critical", "High", "Medium", "Low"]

rendering_defaults:
  cell_format: "{current_grade}  ←  prev: {prior_grade}  |  {prior_run_date}"
  cell_format_first_run: "{current_grade}  ←  prev: N/A"
  insufficient_data_value: "Insufficient Data"
  na_value: "N/A"
  tbd_placeholder_label: "Grade: TBD — definition pending"
  arrow_glyph: "←"
  pipe_glyph: "|"
  em_dash_glyph: "—"
  iso_8601_date_format: "YYYY-MM-DD"

references:
  documentation: "../docs/configuration.md"
  template_entry_point: "../template.md"
```


## 3. `../config/rubric-example.yaml` — Worked Example Rubric

### 3.1 File Purpose

[`../config/rubric-example.yaml`](../config/rubric-example.yaml) is a **minimal, illustrative worked
example A–F rubric** demonstrating the structural shape of the user-supplied rubric input consumed by the
template at generation time per [Rule R1](../template.md#r1--rubric-editability). It is the canonical
"config-style" example intended for documentation, validation, and "first-touch" learning purposes; it is
NOT the production-ready rubric. The production-ready example with annotated thresholds for all four
facets is [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml).

**Critical:** in this configuration example the `complexity` array is intentionally `[]` (empty) per
[Rule R5](../template.md#r5--complexity-placeholder-integrity)'s prohibition on backfilled Complexity
grades. Authoring any Complexity entry in this configuration file — even illustrative — would conflict
with [Rule R5](../template.md#r5--complexity-placeholder-integrity). The companion
[`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) MAY contain a non-empty Complexity
rubric demonstrating the unlocked state.

The file is consumed in two ways:

1. **As a structural template:** report authors copy the file as a starting point, customize the
   per-facet `criteria` strings to encode their organization-specific A–F thresholds, and supply the
   resulting rubric to the template at run time per [`./usage.md`](./usage.md) § Authoring a Rubric.
2. **As a validation fixture:** the file MUST validate against
   [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) (JSON Schema Draft 2020-12); failure of
   that validation surfaces during the validation harness procedure documented in
   [`./validation.md`](./validation.md) § Gate 8 Rubric Verification.

### 3.2 Top-Level Shape

The structural contract is defined by [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json)
(Draft 2020-12; `$id` `urn:blitzy:technology-estate-report:rubric:v0.1.0`). The top-level `rubric` object
has four required keys (`tech_stack`, `maturity`, `security`, `complexity`); each is an array of
`{ grade, criteria, notes? }` objects. The four facet keys MUST all be present per
[Rule R2](../template.md#r2--facet-completeness) — even an empty Complexity rubric MUST be present as an
empty array `[]` per [Rule R5](../template.md#r5--complexity-placeholder-integrity). The order of facet
keys mirrors the matrix-table column order specified in [`./pdf-output.md`](./pdf-output.md) § 4 Matrix
Table Columns: Tech Stack Summary | Maturity Summary | Security Summary | Complexity Summary.

### 3.3 Field Reference

| Key Path | Type | Required | Description |
|---|---|---|---|
| `rubric` | object | yes | Top-level container holding one rubric per facet. |
| `rubric.tech_stack` | array of `rubricEntry` | yes; `minItems: 1` | Rubric entries for the Tech Stack Summary facet. Per the JSON Schema `#/$defs/facetRubric`. |
| `rubric.maturity` | array of `rubricEntry` | yes; `minItems: 1` | Rubric entries for the Maturity Summary facet. Per the JSON Schema `#/$defs/facetRubric`. |
| `rubric.security` | array of `rubricEntry` | yes; `minItems: 1` | Rubric entries for the Security Summary facet. Per the JSON Schema `#/$defs/facetRubric`. |
| `rubric.complexity` | array of `rubricEntry` | yes; `minItems: 0` | Rubric entries for the Complexity Summary facet. Permitted to be empty (`[]`) per [Rule R5](../template.md#r5--complexity-placeholder-integrity); per the JSON Schema `#/$defs/facetRubricComplexity`. |
| `rubric.<facet>[].grade` | enum string `[A, B, C, D, F]` | yes | The letter grade emitted when the entry's `criteria` matches the per-application raw data. The enum **deliberately excludes** the special downstream values `TBD`, `N/A`, and `Insufficient Data` because those values are emitted by the grading engine, the persistence layer, and the PDF renderer based on data-availability conditions and the Rule R5 Complexity-lock — they are NEVER supplied by the rubric author. |
| `rubric.<facet>[].criteria` | string; `minLength: 1` | yes | Author-supplied prose criteria evaluated by the grading engine per [`./grading-engine.md`](./grading-engine.md). Per [Rule R1](../template.md#r1--rubric-editability), thresholds are NOT hardcoded in the template — the author authors free-form criteria here referring to the per-facet raw data described in [`./facets.md`](./facets.md). The string MUST be non-empty. |
| `rubric.<facet>[].notes` | string | optional | Optional human-readable notes for the rubric author's reference (rationale, change log, links to internal review documents). Not consumed by the grading engine and not propagated to the rendered PDF or to the grade-history persistence layer. |

The rubric document MAY be authored as YAML or JSON; a YAML document is parsed to JSON before validation
against the schema. Per [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json),
`additionalProperties` is `false` at every level — adding fields beyond `grade`, `criteria`, and `notes`
MUST cause validation to fail.

### 3.4 Maturity Verbatim Example

The user-supplied verbatim Maturity grade-A example **"No library out of support = A for Maturity"** is
preserved exactly in [`../config/rubric-example.yaml`](../config/rubric-example.yaml) under the
`rubric.maturity` array. The decomposition into the YAML structure is:

- The antecedent text **"No library out of support"** becomes the `criteria` string of the grade-A entry.
- The grade assignment **"= A for Maturity"** is encoded structurally by placement of the entry under the
  `rubric.maturity` array and the `grade: A` key.

The canonical decomposition documentation lives in [`./grading-engine.md`](./grading-engine.md) § 3
Authoring a Rubric. This file references that location and does not duplicate the rubric-authoring prose
per the AAP § 0.10.2 "No Redundancy Rule." See also
[`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) for the production-ready expansion of
all four facet rubrics.

### 3.5 Authoring Workflow

The report author produces a per-run rubric by following this procedure:

1. Copy [`../config/rubric-example.yaml`](../config/rubric-example.yaml) as a starting structural
   template.
2. Replace the illustrative `criteria` strings with organization-specific thresholds for the
   `tech_stack`, `maturity`, and `security` facets. Optionally add a `notes` field per entry for internal
   review traceability.
3. **For the Complexity facet:** leave `complexity: []` empty to keep the placeholder lock per
   [Rule R5](../template.md#r5--complexity-placeholder-integrity), OR populate it with explicit threshold
   entries to unlock the Complexity column. See
   [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) for the production-ready
   unlocked-state example.
4. Validate the resulting document against
   [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) using any JSON Schema Draft 2020-12
   validator (e.g., `ajv-cli`). The validation procedure is documented in
   [`./grading-engine.md`](./grading-engine.md) § Validation and runs as part of
   [`./validation.md`](./validation.md) § Gate 8 Rubric Verification.
5. Supply the validated rubric to the template at run time per [`./usage.md`](./usage.md) § Authoring a
   Rubric.



## 4. `../config/allow-list.yaml` — Network Egress Allow-List

### 4.1 File Purpose

[`../config/allow-list.yaml`](../config/allow-list.yaml) is the **canonical, authoritative, machine-readable
allow-list** of outbound HTTP/HTTPS hosts the template is permitted to call at run time. It operationalizes
[Rule R6](../template.md#r6--saas-data-sourcing) — *SaaS license data MUST be sourced exclusively from
manifests tracked in the repository; no live SaaS vendor API calls are permitted in v1*. Any host NOT
enumerated under `allowed_hosts` is implicitly **denied**; the binding rule is the
`everything_else_default_deny` catch-all in `denied_categories`.

This file is **operationally-controlled** — modifications require a PR and security-reviewer sign-off
because adding or removing hosts has security and compliance implications under
[Rule R6](../template.md#r6--saas-data-sourcing). PR reviewers MUST reject any allow-list change that
adds a SaaS vendor host or any host outside the documented purpose categories (source repository ingestion,
EOL lookup, CVE lookup); see § 4.7 below.

The canonical external-API contract details (base URL, auth, rate-limit semantics, retry rules) live in
[`./api-integrations.md`](./api-integrations.md) per the AAP § 0.10.2 "Citation Inline Rule"; this file
references that document rather than duplicating contract text.

### 4.2 Top-Level Keys

| Key | Type | Required | Description |
|---|---|---|---|
| `version` | string | yes | Semver version of this allow-list (e.g., `"0.1.0"`); incremented per change per § 7 below. |
| `description` | string (block scalar) | yes | Short human-readable description anchoring the file to its [Rule R6](../template.md#r6--saas-data-sourcing) operationalization and to this reference document. |
| `allowed_hosts` | array of objects | yes | Exhaustive enumeration of permitted upstream hosts in canonical order. The five default hosts are documented in § 4.4 below. |
| `denied_categories` | array of objects | yes | Illustrative reminders of forbidden host categories (SaaS vendors, cloud billing APIs, CMDB, runtime monitoring) plus the binding `everything_else_default_deny` catch-all. The named categories are illustrative; the binding rule is the catch-all default-deny. |
| `enforcement` | object | yes | Operational enforcement configuration: `mode: default_deny`, match strategy, on-violation behavior, audit-log requirement. |
| `references` | object | yes | Package-internal documentation links that consume or describe this file. |

### 4.3 Allowed Host Object Shape

Each entry under `allowed_hosts` MUST conform to this shape:

| Sub-Key | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Stable, machine-readable identifier for the host (e.g., `github_api`, `nvd_cve_api`). Used for cross-document linking and audit-log tagging. |
| `host` | string | yes | The hostname or hostname-with-path-prefix (e.g., `api.github.com`, `gitlab.com/api/v4`, `services.nvd.nist.gov`). |
| `purpose` | string | yes | Human-readable purpose tied to one of the documented purpose categories (source repository ingestion, EOL lookup, CVE lookup). |
| `consumed_by` | array of strings | yes | Logical components that consume this host (e.g., `[ingestion]`, `[security]`, `[maturity]`). |
| `auth` | object | yes | Authentication metadata. `auth.required` (boolean) indicates whether authentication is required; `auth.env_var` (string, optional) names the environment variable holding the credential (e.g., `GITHUB_TOKEN`, `GITLAB_TOKEN`, `NVD_API_KEY`). No credential **values** appear in this file — only env-var **names**. |
| `rate_limit` | string | yes | Human-readable rate-limit description and retry/backoff guidance, with cross-reference to the canonical contract in [`./api-integrations.md`](./api-integrations.md). |
| `documentation` | string | yes | Relative-path link to the canonical API contract section in [`./api-integrations.md`](./api-integrations.md). |

### 4.4 Default Hosts

The five canonical default hosts in canonical order (matching the order in
[`./api-integrations.md`](./api-integrations.md) § Network Egress Allow-List):

| Order | `id` | `host` | Purpose | `auth.required` | `auth.env_var` |
|---|---|---|---|---|---|
| 1 | `github_api` | `api.github.com` | Source repository ingestion (read-only) | `true` | `GITHUB_TOKEN` |
| 2 | `gitlab_api` | `gitlab.com/api/v4` | Source repository ingestion (read-only) | `true` | `GITLAB_TOKEN` |
| 3 | `eol_api` | `endoflife.date` | Maturity Summary EOL lookup (endoflife.date API v1, beta) | `false` | (none) |
| 4 | `nvd_cve_api` | `services.nvd.nist.gov` | Security Summary primary CVE source (NVD CVE API v2.0) | `false` (optional `NVD_API_KEY` raises rate limit from 5 to 50 requests per 30-second window) | `NVD_API_KEY` (optional) |
| 5 | `osv_api` | `api.osv.dev` | Security Summary alternate / cross-reference CVE source (OSV API v1) | `false` | (none) |

The five hosts MUST appear in this canonical order in
[`../config/allow-list.yaml`](../config/allow-list.yaml). The list is a **superset constraint** — at least
these five entries MUST be present in any conforming `allow-list.yaml`; additional entries (e.g., for
self-hosted GitHub Enterprise or GitLab CE per § 4.6 below) MAY be added.

### 4.5 Implicit Deny

Any outbound host NOT in `allowed_hosts` is **implicitly denied** by the
`everything_else_default_deny` catch-all under `denied_categories`. The named entries under
`denied_categories` (SaaS vendor endpoints, cloud billing APIs, CMDB / ServiceNow integrations, runtime
monitoring) are **illustrative reminders** for the most likely categories of accidental opt-in; they are
NOT exhaustive. The binding rule is the catch-all: any host not present in `allowed_hosts` is denied.

The template MUST be invoked with **network-egress enforcement enabled** (e.g., via egress proxy, network
policy, or host firewall) for the allow-list to be operationally enforceable. Without enforcement, the
file functions as a documentation contract only. The validation harness verification procedure is
documented in [`./validation.md`](./validation.md) § Gate 1 Live Smoke Test.

Per [Rule R2](../template.md#r2--facet-completeness) and
[Gate 2](../template.md#612-gate-2--zero-warning-build), a denied request MUST surface as an explicit
`Insufficient Data` cell value with an audit-log entry — never as a silent omission or suppressed error.
The `enforcement.on_violation` field encodes this contract as `surface_insufficient_data`.

### 4.6 Customizing for Self-Hosted Instances

When a report author scopes repositories on a self-hosted **GitHub Enterprise** or **GitLab CE/EE**
instance, the corresponding host is added as an additional entry under `allowed_hosts`. The five canonical
default hosts MUST remain present (per the superset constraint in § 4.4) — the customization adds new
hosts without removing any. Example:

```yaml
allowed_hosts:
  # ... five canonical default hosts (api.github.com, gitlab.com/api/v4,
  # endoflife.date, services.nvd.nist.gov, api.osv.dev) appear first ...

  - id: github_enterprise_api
    host: "github.acme.example.com/api/v3"
    purpose: "Source repository ingestion (GitHub Enterprise read-only)"
    consumed_by: [ingestion]
    auth:
      required: true
      env_var: GITHUB_TOKEN
    rate_limit: "Authenticated rate limit applies; treat 429 as retryable per ../docs/api-integrations.md § GitHub API."
    documentation: "../docs/api-integrations.md#github-api"

  - id: gitlab_self_hosted_api
    host: "gitlab.acme.example.com/api/v4"
    purpose: "Source repository ingestion (self-hosted GitLab read-only)"
    consumed_by: [ingestion]
    auth:
      required: true
      env_var: GITLAB_TOKEN
    rate_limit: "Authenticated rate limit applies; treat 429 as retryable per ../docs/api-integrations.md § GitLab API."
    documentation: "../docs/api-integrations.md#gitlab-api"
```

When mixing public and self-hosted instances in the same run scope, the same `GITHUB_TOKEN` /
`GITLAB_TOKEN` env var MAY hold a token valid for both — or the customization MAY introduce
instance-specific env-var names (e.g., `GITHUB_ENTERPRISE_TOKEN`) at the cost of a configuration-coupling
update in [`./api-integrations.md`](./api-integrations.md) § 9 Credential Provisioning.

### 4.7 Adding Other Hosts is Prohibited

Per [Rule R6](../template.md#r6--saas-data-sourcing), **no SaaS vendor host** may be added to
`allowed_hosts`. Examples of prohibited additions (illustrative, NOT exhaustive — listed in
[`../config/allow-list.yaml`](../config/allow-list.yaml) under `denied_categories.saas_vendor_endpoints`):

- Salesforce (`login.salesforce.com`, `*.my.salesforce.com`)
- ServiceNow (`*.service-now.com`)
- Workday (`api.workday.com`)
- Zendesk (`*.zendesk.com`)
- Slack (`api.slack.com`)
- Atlassian (`api.atlassian.com`)
- Okta (`*.okta.com`)

Additional categories of explicitly out-of-scope hosts (also in `denied_categories`):

- **Cloud billing APIs** — `ce.us-east-1.amazonaws.com`, `consumption.azure.com`,
  `cloudbilling.googleapis.com`. Cost data is excluded from v1 per
  [`../template.md`](../template.md) § 4 Boundaries & Preservation.
- **CMDB / ServiceNow integrations** — `*.service-now.com`, `cmdb.*`. CMDB enrichment is excluded from v1.
- **Runtime monitoring** — `api.datadoghq.com`, `api.newrelic.com`, `*.signalfx.com`, `api.honeycomb.io`.
  Operational telemetry is excluded from v1.

PR reviewers MUST reject any allow-list change that adds:

- A SaaS vendor host (any of the patterns enumerated under
  `denied_categories.saas_vendor_endpoints`) — direct violation of
  [Rule R6](../template.md#r6--saas-data-sourcing).
- A cloud billing API, CMDB, or runtime monitoring host — direct violation of
  [`../template.md`](../template.md) § 4 Boundaries & Preservation.
- Any host outside the three documented purpose categories (source repository ingestion, EOL lookup,
  CVE lookup) — implicit violation of the minimal-change mandate.

The PR description MUST cite the [Rule R6](../template.md#r6--saas-data-sourcing) implication of the
change and link to the corresponding [`../CHANGELOG.md`](../CHANGELOG.md) entry.



## 5. Credential Provisioning (Env Vars Only)

The template consumes three environment variables for credentials. **No credential values appear in any
committed config file or documentation file** in this package — only env-var **names** appear in
[`../config/allow-list.yaml`](../config/allow-list.yaml) (under each host's `auth.env_var` field) and in
the documentation prose. The runtime environment is responsible for materializing the credential values
into the env vars before invoking the template.

| Env Var | Required? | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | Required when GitHub repositories are in scope | GitHub Personal Access Token (classic or fine-grained) or GitHub App installation token. Permits read-only repository access for the ingestion pipeline. See [`./api-integrations.md`](./api-integrations.md) § GitHub API for the required scopes. |
| `GITLAB_TOKEN` | Required when GitLab repositories are in scope | GitLab Personal Access Token or Project Access Token. Permits read-only repository access for the ingestion pipeline. See [`./api-integrations.md`](./api-integrations.md) § GitLab API for the required scopes. |
| `NVD_API_KEY` | Optional but strongly recommended | NVD CVE API v2.0 API key. Without an API key, NVD enforces a rate limit of 5 requests per 30-second window; with an API key, the limit is raised to 50 requests per 30-second window. Without this key, large repository scopes may exceed the rate limit and surface as `Insufficient Data` per [Rule R2](../template.md#r2--facet-completeness) — never as a silent omission per [Gate 2](../template.md#612-gate-2--zero-warning-build). See [`./api-integrations.md`](./api-integrations.md) § NVD CVE API v2.0 § Authentication for the API-key request procedure. |

The end-to-end provisioning runbook lives in [`./usage.md`](./usage.md) § Provisioning Credentials and
[`./api-integrations.md`](./api-integrations.md) § 9 Credential Provisioning. The single-command
validation harness (Gate 10) provisions these credentials and runs the template against a designated test
repository — see [`./validation.md`](./validation.md) § Single-Command Execution Path.

The provisioning examples below use **placeholder values** that are NOT real tokens; the literal angle
brackets `<` `>` are visual markers indicating that the runtime environment substitutes a real value.
**Never commit real token values to any file in this repository.**

```bash
# Placeholder values shown — the runtime environment substitutes real tokens.
export GITHUB_TOKEN="ghp_<example_placeholder>"
export GITLAB_TOKEN="glpat-<example_placeholder>"
export NVD_API_KEY="<example_placeholder>"
```

When running in CI, the equivalent provisioning is supplied via the CI platform's secrets store
(GitHub Actions `secrets.GITHUB_TOKEN`, GitLab CI `CI_JOB_TOKEN` or masked variables, etc.); see
[`./usage.md`](./usage.md) § Provisioning Credentials for platform-specific examples. The validation
harness's single-command execution path documented in [`./validation.md`](./validation.md) § Gate 10
expects the three env vars to be present in the executing shell.

## 6. Validation

### 6.1 YAML Parsing

All three configuration files (`facets.yaml`, `rubric-example.yaml`, `allow-list.yaml`) MUST parse with
any conformant YAML 1.2 parser. Authors SHOULD run `yamllint` (or any equivalent YAML linter) before
committing any change. Recommended invocation:

```bash
yamllint -d "{extends: default, rules: {line-length: {max: 200}}}" templates/technology-estate-report/config/
```

The `line-length: max: 200` override allows the long block-scalar descriptions used throughout the YAML
files for inline rule operationalization documentation. The default `line-length: 80` would surface
spurious warnings on those descriptions.

### 6.2 JSON Schema Validation

A user-supplied rubric document — including the worked example
[`../config/rubric-example.yaml`](../config/rubric-example.yaml) and the production-ready example
[`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) — MUST validate against
[`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) (JSON Schema Draft 2020-12). The validation
procedure is documented in [`./grading-engine.md`](./grading-engine.md) § Validation and runs as part of
[`./validation.md`](./validation.md) § Gate 8 Rubric Verification.

The recommended validator is `ajv-cli` (or any equivalent JSON Schema Draft 2020-12 validator) with
Draft 2020-12 support enabled:

```bash
# Convert YAML rubric to JSON, then validate against the schema.
yq -o=json eval templates/technology-estate-report/config/rubric-example.yaml \
  | ajv validate \
      --spec=draft2020 \
      -s templates/technology-estate-report/schemas/rubric.schema.json \
      -d /dev/stdin
```

A schema-validation failure (e.g., a rubric entry missing the required `criteria` field, or a `grade`
value outside the `[A, B, C, D, F]` enum) MUST cause Gate 8 Rubric Verification to fail; the run aborts
with an explicit error message per [`./troubleshooting.md`](./troubleshooting.md) § Failure-Mode-to-Cell-Value
Mapping (row "Grading engine — Rubric is malformed (schema validation failure)").

### 6.3 Cross-File Consistency

The following invariants MUST hold across the three configuration files. These are operational invariants
that prevent configuration drift; reviewers MUST hand-verify them when editing any of the files. Build-time
enforcement is documented as a future enhancement in [`../CHANGELOG.md`](../CHANGELOG.md).

**Invariant 1 — Severity tier labels are byte-for-byte identical across three locations:**

- `facets.yaml` `severity_tier_labels` (top-level)
- `facets.yaml` `severity_tier_mapping.tiers[].name`
- `facets.yaml` `facets.security.severity_tier_counting.tiers`

All three locations MUST contain `["Critical", "High", "Medium", "Low"]` byte-for-byte (capital first
letter, no abbreviation, no translation). This is the verbatim
[Rule R4](../template.md#r4--cve-severity-breakdown) surface. Any divergence among the three locations is
a Rule R4 verification failure.

**Invariant 2 — Complexity placeholder label is byte-for-byte identical across two locations:**

- `facets.yaml` `facets.complexity.placeholder_label`
- `facets.yaml` `rendering_defaults.tbd_placeholder_label`

Both MUST contain `"Grade: TBD — definition pending"` byte-for-byte (em-dash U+2014; UTF-8
`0xE2 0x80 0x94`). This is the verbatim [Rule R5](../template.md#r5--complexity-placeholder-integrity)
surface. Reviewers editing either field MUST verify the em-dash glyph survives copy/paste; many editors
silently transliterate U+2014 to U+002D HYPHEN-MINUS or U+2013 EN DASH.

**Invariant 3 — Cell-rendering literals match `[`./pdf-output.md`](./pdf-output.md)` § 5 Cell Rendering
Format byte-for-byte:**

- `facets.yaml` `rendering_defaults.cell_format` MUST equal
  `"{current_grade}  ←  prev: {prior_grade}  |  {prior_run_date}"` (two ASCII spaces around the `←`
  arrow; two ASCII spaces around the `|` pipe). This is the verbatim
  [Rule R3](../template.md#r3--grade-history-fidelity) surface.
- `facets.yaml` `rendering_defaults.cell_format_first_run` MUST equal
  `"{current_grade}  ←  prev: N/A"` (verbatim [Rule R3](../template.md#r3--grade-history-fidelity) +
  [Rule R10](../template.md#r10--new-repo-compatibility) surface).
- `facets.yaml` `rendering_defaults.insufficient_data_value` MUST equal `"Insufficient Data"` (capital I,
  capital D, single ASCII space; verbatim [Rule R2](../template.md#r2--facet-completeness) surface).
- `facets.yaml` `rendering_defaults.na_value` MUST equal `"N/A"` (capital N, ASCII slash, capital A;
  verbatim [Rule R3](../template.md#r3--grade-history-fidelity) surface).

**Invariant 4 — Allow-list contains the five canonical default hosts:**

`allow-list.yaml` `allowed_hosts[*].host` MUST include all five canonical default hosts in canonical
order:

1. `api.github.com`
2. `gitlab.com/api/v4`
3. `endoflife.date`
4. `services.nvd.nist.gov`
5. `api.osv.dev`

Additional hosts (e.g., self-hosted GitHub Enterprise or GitLab CE per § 4.6) MAY appear after the five
canonical entries, but the five MUST remain present. The order in
[`./api-integrations.md`](./api-integrations.md) § 7 Network Egress Allow-List MUST equal this order.

**Invariant 5 — API version pins are stable:**

Per [Rule R7](../template.md#r7--application-identity-stability) (analogously applied to API versioning),
the API versions referenced across the package MUST be stable across runs. The canonical version pins
are:

- GitHub API: REST v3 (and optionally GraphQL v4) per
  [`./api-integrations.md`](./api-integrations.md) § GitHub API
- GitLab API: v4 per [`./api-integrations.md`](./api-integrations.md) § GitLab API
- endoflife.date API: v1 (Beta) per [`./api-integrations.md`](./api-integrations.md) § endoflife.date
  API v1
- NVD CVE API: v2.0 per [`./api-integrations.md`](./api-integrations.md) § NVD CVE API v2.0
- OSV API: v1 per [`./api-integrations.md`](./api-integrations.md) § OSV API v1

Authors who introduce a version migration MUST update [`./api-integrations.md`](./api-integrations.md),
[`../config/allow-list.yaml`](../config/allow-list.yaml) (under each host's `documentation` reference and
`rate_limit` description), and [`../CHANGELOG.md`](../CHANGELOG.md) atomically in a single PR.

**Invariant 6 — Insufficient Data conditions are documented in `[`./troubleshooting.md`](./troubleshooting.md)`:**

Every condition listed under `facets.<facet>.insufficient_data_conditions` in
[`../config/facets.yaml`](../config/facets.yaml) MUST appear as a row in
[`./troubleshooting.md`](./troubleshooting.md) § 2 Failure-Mode-to-Cell-Value Mapping with the literal
cell value `Insufficient Data` and the persistence-layer enum `InsufficientData`. Adding a new condition
to one location without the other is a [Rule R2](../template.md#r2--facet-completeness) +
[Gate 2](../template.md#612-gate-2--zero-warning-build) verification failure.



## 7. Modification Cadence and Change Control

The four configuration-related artifacts in the package have distinct modification cadences and
change-control requirements:

| File | Cadence | Change-Control Requirements |
|---|---|---|
| [`../config/facets.yaml`](../config/facets.yaml) | Modified rarely. Changes are limited to: (a) CVSS-to-severity tier threshold adjustments (extremely rare; aligned with NIST CVSS revisions); (b) per-facet `insufficient_data_conditions` enumeration; (c) glyph encoding fixes if a UTF-8 transliteration error is detected. | Version-bump `version: "x.y.z"` per change. Add a [`../CHANGELOG.md`](../CHANGELOG.md) entry. Verbatim Rule R3/R4/R5 surfaces (§ 6.3 Invariants 1, 2, 3) MUST NOT be altered without an explicit user request and a corresponding update to [`../template.md`](../template.md). |
| [`../config/rubric-example.yaml`](../config/rubric-example.yaml) | Modified to add new worked examples for facets, refine illustrative `criteria` strings for clarity, or add per-entry `notes` for documentation purposes. | Version-bump per change. The `complexity: []` array MUST remain empty in this file (Rule R5); the production-ready example with non-empty `complexity` lives in [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml). MUST validate against [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) after any change. |
| [`../config/allow-list.yaml`](../config/allow-list.yaml) | Modified only via PR with **security reviewer sign-off**. Changes are limited to: (a) adding self-hosted GitHub Enterprise / GitLab CE hosts per § 4.6; (b) extending the `denied_categories` examples list with new SaaS vendor patterns to reject; (c) tightening the `enforcement` configuration. | Version-bump per change. PR description MUST cite the [Rule R6](../template.md#r6--saas-data-sourcing) implication of the change. Adding any SaaS vendor host or any host outside the documented purpose categories (source repository ingestion, EOL lookup, CVE lookup) is **prohibited** per § 4.7. Add a [`../CHANGELOG.md`](../CHANGELOG.md) entry. |
| [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) | Modified freely as the production-ready example evolves. Not version-pinned. | MUST validate against [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json). The production-ready example MAY contain a non-empty `complexity` array demonstrating the unlocked state per Rule R5. Changes are documented inline as YAML comments rather than in a separate changelog entry. |

For all four files, **never commit credential values** — only env-var **names**. The single source of
authentication metadata is [`../config/allow-list.yaml`](../config/allow-list.yaml) under each host's
`auth.env_var` field.

When making a change that affects multiple files (e.g., adding a sixth severity tier, which would touch
`facets.yaml` `severity_tier_mapping`, `facets.yaml` `severity_tier_labels`, `facets.yaml`
`facets.security.severity_tier_counting.tiers`, [`./facets.md`](./facets.md) § Security Summary § Severity
Tier Counting, [`./pdf-output.md`](./pdf-output.md), [`../template.md`](../template.md) § 5 Rules R4, and
[`../schemas/report-output.schema.json`](../schemas/report-output.schema.json)), the change MUST be
**atomic** — submitted as a single PR — and the PR description MUST enumerate every file touched and the
[Rule R4](../template.md#r4--cve-severity-breakdown) re-verification path. The single-source-of-truth
principle (`facets.yaml` is canonical for the CVSS-to-severity mapping; the PDF renderer reads the
literals from there rather than embedding them in code) is the design intent that makes such atomic
changes possible.

## 8. Cross-References

The following relative-path links are made outbound from this document, listed for reviewer convenience.
All links resolve within [`templates/technology-estate-report/`](../) per the AAP § 0.10.2 "Standalone
Package Rule"; no link reaches outside the package directory.

**Canonical rule text and template entry point:**

- [`../template.md`](../template.md) — canonical, verbatim text of all Rules R1–R10 and Validation Gates;
  this document references rules R1, R2, R3, R4, R5, R6, R7, R9, R10 and Gates 1, 2, 8, 10.

**Configuration files (the documented surfaces):**

- [`../config/facets.yaml`](../config/facets.yaml) — canonical machine-readable per-facet configuration,
  CVSS-to-severity mapping, and rendering defaults.
- [`../config/rubric-example.yaml`](../config/rubric-example.yaml) — canonical machine-readable
  worked-example rubric (with `complexity: []` per Rule R5).
- [`../config/allow-list.yaml`](../config/allow-list.yaml) — canonical machine-readable network-egress
  allow-list (operationalizes Rule R6).

**Schema and example artifacts:**

- [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) — JSON Schema (Draft 2020-12) for the
  rubric input format.
- [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) — production-ready example rubric
  (MAY contain a non-empty `complexity` array per Rule R5 unlocked state).

**Documentation pages:**

- [`./facets.md`](./facets.md) — per-facet detection algorithms; consumes the per-facet feature flags and
  the CVSS-to-severity mapping documented in § 2 above.
- [`./grading-engine.md`](./grading-engine.md) — rubric format and evaluation procedure; consumes the
  rubric input format documented in § 3 above.
- [`./pdf-output.md`](./pdf-output.md) — PDF section ordering and cell-rendering format; consumes the
  cell-rendering literals from `rendering_defaults` documented in § 2.9 above.
- [`./executive-summary.md`](./executive-summary.md) — portfolio-level aggregation rules; uses the same
  ISO 8601 date format documented in § 2.9 above.
- [`./api-integrations.md`](./api-integrations.md) — GitHub, GitLab, endoflife.date, NVD, OSV API
  contracts; canonical home of the per-API rate-limit and authentication contracts referenced from § 4
  Allow-List above.
- [`./troubleshooting.md`](./troubleshooting.md) — failure-mode-to-cell-value mapping; consumes the
  per-facet `insufficient_data_conditions` documented in § 2 above (Cross-File Consistency Invariant 6).
- [`./validation.md`](./validation.md) — Gate 1, 2, 8, 9, 10 procedures; § 6.2 above's JSON Schema
  validation procedure runs as part of Gate 8 Rubric Verification.
- [`./usage.md`](./usage.md) — author workflow including credential provisioning (the runbook for the
  env vars documented in § 5 above).

**Package overview and change history:**

- [`../README.md`](../README.md) — package overview and glossary.
- [`../CHANGELOG.md`](../CHANGELOG.md) — versioned change history; every modification documented in § 7
  above is recorded here with the corresponding rule/gate identifier where applicable.
