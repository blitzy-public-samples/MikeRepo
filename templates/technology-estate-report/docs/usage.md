# Usage Guide — Technology Estate Report Template

## 1. Overview

This guide is the **end-to-end author workflow reference** for the Technology Estate Report Blitzy prompt
template package. It walks the report author — typically a CIO/CTO delegate, a platform-engineering lead, or
an enterprise-architecture analyst — through the five-step workflow that produces a recurring CIO/CTO-facing
PDF Technology Estate Report from a defined portfolio of GitHub and/or GitLab repositories. The five steps
are: **provision credentials → specify repository scope → author rubric → invoke template → retrieve PDF**.
Each step is documented in its own numbered section below; each step is independent and may be revisited
between runs without disrupting the others.

The template is invoked from the Blitzy CLI or Blitzy web UI; the **exact invocation command depends on the
Blitzy environment** in which it runs. Refer to the Blitzy environment's own documentation for the canonical
invocation surface (CLI subcommand name, web-UI button, API endpoint, scheduled-job entry point). This guide
documents the **inputs the template expects** regardless of the invocation surface — the rubric document, the
run scope, and the credentials — so that a report author can prepare those inputs once and use them across any
Blitzy invocation surface available to their organization.

The template is **standalone**: per [`../template.md`](../template.md) § 4 Boundaries & Preservation, it has no
dependency on any other Blitzy flow or template, and it consumes the existing Blitzy ingestion pipeline strictly
**read-only**. The author does NOT need to wire this template into any other flow; running the template
produces a single PDF artifact and one or more grade-history persistence records (per
[`./grade-history.md`](./grade-history.md) § 2 Storage Key), and nothing else. Per [Rule R10](../template.md#r10--new-repo-compatibility)
and [Rule R7](../template.md#r7--application-identity-stability), the **same execution path** handles both
first-run repositories and recurring-run repositories; the report author does NOT distinguish between these
cases at the invocation level.

The canonical, verbatim text of all rules and gates referenced from this guide is in
[`../template.md`](../template.md) §§ 5 and 6. Per the AAP § 0.10.2 "No Redundancy Rule," this guide does NOT
duplicate verbatim rule text; it cites the canonical location and operationalizes the workflow.

## 2. Prerequisites

Before beginning the workflow, confirm the following prerequisites are in place. Each prerequisite is
operationalized in the corresponding step in §§ 3–7 below.

- **Blitzy environment access** — the report author has access to a Blitzy environment that can invoke this
  template. This guide does not document how to provision the Blitzy environment itself; consult the Blitzy
  environment's own documentation for that. The minimum Blitzy capabilities required are: an invocation
  surface (CLI, web UI, or API), the ability to set environment variables on the invocation, and read access
  to the network hosts in the egress allow-list documented in [`./api-integrations.md`](./api-integrations.md)
  § Network Egress Allow-List.

- **Source-control credentials** — the author has Personal Access Tokens (PATs) or equivalent credentials for
  the source-control hosts whose repositories will appear in the run scope:

  - **GitHub** — a PAT (fine-grained or classic) with `repo` scope per [`./api-integrations.md`](./api-integrations.md)
    § 2.5. Required when ANY repository in the run scope is hosted on GitHub or GitHub Enterprise.
  - **GitLab** — a PAT with `read_api` and `read_repository` scopes per [`./api-integrations.md`](./api-integrations.md)
    § 3.5. Required when ANY repository in the run scope is hosted on GitLab.com or a self-hosted GitLab
    instance.

- **NVD API key (optional but strongly recommended)** — the author OPTIONALLY has an NVD API key per
  [`./api-integrations.md`](./api-integrations.md) § 5.4. Without the key, the NVD CVE API enforces a rate
  limit of 5 requests per 30-second window; with the key, the limit rises to 50 requests per 30-second
  window. For run scopes containing more than approximately five repositories, or for repositories with
  large dependency manifests, provisioning the NVD API key is strongly recommended to avoid rate-limit
  failures that would surface as `Insufficient Data` cells per [Rule R2](../template.md#r2--facet-completeness).

- **Repository scope** — the author has a list of `org/repo` identifiers (per [Rule R7](../template.md#r7--application-identity-stability))
  to include in the run scope. Each identifier is a stable application key; the same `org/repo` value
  identifies the same application across all runs and is the join key into the grade history persistence
  store per [`./grade-history.md`](./grade-history.md) § 2 Storage Key.

- **Rubric (optional for first run)** — the author optionally has an A–F rubric authored per
  [Rule R1](../template.md#r1--rubric-editability). For a first run, the author MAY copy the production-ready
  example at [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) without modification; for
  subsequent runs, the author iterates on the rubric per § 5.4 below.

## 3. Step 1: Provisioning Credentials

This step provisions the credentials the template uses to authenticate to its read-only data sources. All
credentials are passed to the template via **environment variables**; per [`./configuration.md`](./configuration.md)
§ 5 and [`./api-integrations.md`](./api-integrations.md) § 9, **no credential values appear in any file in
this package** — this guide and every other document references credentials by env-var name only.

### 3.1 GitHub PAT

To provision the GitHub Personal Access Token, follow these steps:

1. Sign in to GitHub.
2. Open **Settings → Developer settings → Personal access tokens → Fine-grained tokens** (recommended) or
   **Classic tokens**.
3. Generate a new token. Grant `Contents: Read-only` for fine-grained tokens, or the `repo` scope for classic
   tokens. Set the expiration per organizational policy (typically 90 days; coordinate with your organization's
   credential-rotation cadence per [`./api-integrations.md`](./api-integrations.md) § 9).
4. Copy the token value. **GitHub displays the token value only once** — if you navigate away without copying
   it, you must regenerate the token.
5. Provision the token as the environment variable `GITHUB_TOKEN`:

   ```bash
   export GITHUB_TOKEN="ghp_<example_placeholder>"
   ```

6. Verify the token works by issuing a probe request to the GitHub user endpoint:

   ```bash
   curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
   ```

   The response should be a JSON object with the authenticated user's profile. A `401 Unauthorized` response
   indicates the token is invalid or expired; a `403 Forbidden` indicates insufficient scope; a successful
   response confirms the token is correctly provisioned for repository ingestion.

### 3.2 GitLab PAT

To provision the GitLab Personal Access Token, follow these steps:

1. Sign in to GitLab.com (or your organization's self-hosted GitLab instance).
2. Open **User Settings → Access Tokens**.
3. Create a new token. Grant the scopes `read_api` and `read_repository`. Set the expiration per organizational
   policy.
4. Copy the token value. (As with GitHub, the value is shown only once.)
5. Provision the token as the environment variable `GITLAB_TOKEN`:

   ```bash
   export GITLAB_TOKEN="glpat-<example_placeholder>"
   ```

6. Verify the token works by issuing a probe request to the GitLab user endpoint:

   ```bash
   curl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" https://gitlab.com/api/v4/user
   ```

   The response should be a JSON object with the authenticated user's profile. A `401 Unauthorized` response
   indicates the token is invalid or expired; a `403 Forbidden` indicates insufficient scope. For self-hosted
   GitLab CE installations, replace `https://gitlab.com` with your instance's base URL; the per-entry scope
   override convention for self-hosted instances is documented in [`./configuration.md`](./configuration.md).

### 3.3 NVD API Key (Optional but Recommended)

The NVD CVE API rate limit is 5 requests per 30-second window without an API key, and 50 requests per
30-second window with an API key. For any run scope larger than a handful of small repositories, provisioning
the NVD API key is strongly recommended to avoid rate-limit-induced `Insufficient Data` cells in the Security
facet column. To provision the key, follow these steps:

1. Visit the NVD API Key request page. The canonical URL is documented in [`./api-integrations.md`](./api-integrations.md)
   § 5.
2. Submit the request form. The key is delivered by email; delivery typically takes a few minutes to a few
   hours.
3. Provision the key as the environment variable `NVD_API_KEY`:

   ```bash
   export NVD_API_KEY="<example_placeholder>"
   ```

The template detects the presence of `NVD_API_KEY` automatically; no other configuration is required. When
the key is absent, the template falls back to the unauthenticated rate limit and may surface
`Insufficient Data` cells for the Security facet of repositories whose dependency lookups exceed the limit;
this is the documented Gate 2 zero-warning behavior per [`./troubleshooting.md`](./troubleshooting.md) § 2
(Failure-Mode-to-Cell-Value Mapping).

### 3.4 Credential Hygiene

Per [`./configuration.md`](./configuration.md) § 5 and [`./api-integrations.md`](./api-integrations.md) § 9,
credential values **never** appear in any file in this package — only the env-var names appear. Apply the
same discipline to your own working files:

- **Store credentials in a secret manager.** Use GitHub Encrypted Secrets, GitLab CI Variables, AWS Secrets
  Manager, HashiCorp Vault, Azure Key Vault, GCP Secret Manager, or the equivalent in your organization. Do
  NOT commit credentials to any repository — including private repositories — and do NOT paste credentials
  into shared chat channels.
- **Avoid shell history.** When exporting credentials interactively, use techniques that bypass shell history
  (e.g., a leading space in `bash` configured with `HISTCONTROL=ignorespace`, or a sourced file in a tmpfs
  mount). Alternatively, configure your secret manager to inject credentials directly into the Blitzy
  invocation environment without exposing them to the shell.
- **Rotate credentials.** Rotate the GitHub PAT, GitLab PAT, and NVD API key on the cadence documented in
  [`./api-integrations.md`](./api-integrations.md) § 9 (typically aligned with organizational credential
  policies). Update the env vars on every Blitzy invocation surface that uses them; expired credentials
  surface as `Insufficient Data` cells in the next run per [Rule R2](../template.md#r2--facet-completeness).
- **Use least privilege.** Grant the minimum scopes required: `Contents: Read-only` (or `repo`) for GitHub;
  `read_api` and `read_repository` for GitLab. The template never writes to source-control repositories and
  never modifies the Blitzy ingestion pipeline per [`../template.md`](../template.md) § 4 Boundaries &
  Preservation.

## 4. Step 2: Specifying Repository Scope

This step defines the **run scope** — the list of `org/repo` identifiers that the template will analyze in the
current run. The run scope is the primary input governing which repositories appear as rows in the rendered
PDF's Application Matrix Table per [`./pdf-output.md`](./pdf-output.md) § 4 Matrix Table Columns.

### 4.1 Scope Format

The run scope is a list of `org/repo` identifiers per [Rule R7](../template.md#r7--application-identity-stability).
Each identifier MUST match the regex `^[a-zA-Z0-9][a-zA-Z0-9._-]*\/[a-zA-Z0-9][a-zA-Z0-9._-]*$` documented in
[`./grade-history.md`](./grade-history.md) § 2 Storage Key. The identifier is **case-sensitive** and is the
canonical join key into the grade history persistence store; per [Rule R7](../template.md#r7--application-identity-stability),
the identifier format is stable across all runs and MUST NOT change between runs for the same repository.

### 4.2 YAML Scope File Example

Authors typically supply the run scope as a YAML file. The conventional structure is:

```yaml
run_scope:
  - acme-inc/acme-api
  - acme-inc/data-pipeline
  - acme-inc/customer-portal
  - internal-tools/log-aggregator
  - legacy/acme-monolith
```

The file may be named anything; conventional names include `scope.yaml`, `run-scope.yaml`, or
`q4-2025-scope.yaml`. Save the file to a path you control (e.g., `~/scopes/q4-2025-scope.yaml`); the path is
passed to the Blitzy invocation per § 6.2 below.

### 4.3 Mixing GitHub and GitLab in One Scope

When the run scope contains both GitHub and GitLab repositories, **both** `GITHUB_TOKEN` and `GITLAB_TOKEN`
MUST be provisioned per § 3 above. The template auto-detects the host per repository entry: if the
`org/repo` resolves on `api.github.com`, the GitHub token is used; if it resolves on `gitlab.com/api/v4`, the
GitLab token is used. The optional per-entry `host:` override convention for self-hosted GitHub Enterprise or
GitLab CE installations is documented in [`./configuration.md`](./configuration.md); for the simple case
(public GitHub.com plus public GitLab.com), no per-entry override is required.

### 4.4 Heterogeneous Scope (Rule R10)

The run scope MAY mix repositories that have prior runs (recurring) with repositories that have no prior run
(net-new). Per [Rule R10](../template.md#r10--new-repo-compatibility), the template handles this transparently:

- **Net-new repositories** (no prior persistence record for any of their four facets) produce `prev: N/A`
  cells per [Rule R3](../template.md#r3--grade-history-fidelity) and [Rule R10](../template.md#r10--new-repo-compatibility).
- **Recurring repositories** (with at least one prior persistence record) produce
  `prev: <grade> | <ISO 8601 date>` cells per [Rule R3](../template.md#r3--grade-history-fidelity) — the
  canonical verbatim cell-format example is `B  ←  prev: C  |  2025-10-01` and is reproduced in
  [`./pdf-output.md`](./pdf-output.md) § 5 Cell Rendering Format.

The author does NOT need to flag net-new repositories explicitly; the template detects the absence of a prior
persistence record and renders `N/A` automatically. Cross-reference [`./grade-history.md`](./grade-history.md)
§ 6 Heterogeneous Scope Handling for the underlying detection flow.

### 4.5 Excluding Repositories

To temporarily exclude a repository from the current run scope, simply remove its entry from the scope file.
Note the following consequences per [Rule R3](../template.md#r3--grade-history-fidelity) immutability and
[Rule R7](../template.md#r7--application-identity-stability) identity stability:

- Excluded repositories' **prior records remain in the persistence store** (immutability per Rule R3); the
  records are not deleted or hidden.
- Excluded repositories simply do not appear as rows in the next PDF's Application Matrix Table.
- When an excluded repository is later re-added to scope, its **prior history is preserved** because the
  `org/repo` identity key is stable per Rule R7. The next run will render the prior grade and ISO 8601 date
  inline per Rule R3.

In other words, exclusion is a scope decision, not a deletion; the persistence store is append-only per
[`./grade-history.md`](./grade-history.md) § 3 Immutability Contract.

## 5. Step 3: Authoring a Rubric

This step authors the **A–F grading rubric** that the grading engine consumes to convert raw facet data into
letter grades. Per [Rule R1](../template.md#r1--rubric-editability), the rubric is supplied by the report
author **at generation time**; no grade thresholds are hardcoded in the template. The rubric is the author's
editable control surface, and per Rule R1's verification clause, two different rubric inputs against the same
dataset produce two different grade outputs.

### 5.1 Starting from the Example

The fastest path to a working rubric is to copy one of the worked examples bundled with this package and
customize per facet:

- **[`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml)** — the **production-ready** example.
  Contains annotated thresholds for all four facets and is suitable as a baseline for organizations that have
  not yet defined their own grading standards. Copy this file to a path you control (e.g.,
  `~/rubrics/portfolio-rubric.yaml`) and edit per § 5.2 below.
- **[`../config/rubric-example.yaml`](../config/rubric-example.yaml)** — the **configuration worked example**.
  Contains illustrative thresholds and demonstrates the canonical `complexity: []` empty-array initial state
  per [Rule R5](../template.md#r5--complexity-placeholder-integrity). This file is intended for documentation
  and validation purposes.

Both files validate against the JSON Schema at [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json)
(JSON Schema Draft 2020-12). The rubric document MAY be authored as YAML or JSON; YAML is parsed to JSON
before validation.

### 5.2 Authoring Procedure

Follow these steps to author a rubric for your organization:

1. **Decide the A–F threshold for each facet** per your organization's standards. Consult subject-matter
   experts (security, platform engineering, enterprise architecture) on what constitutes an A vs. an F for
   each facet. Document the rationale alongside the rubric in your organization's standards repository.
2. **For each of the four facets** `[tech_stack, maturity, security, complexity]`, write 3–5 rubric entries
   with a `grade` field (one of `A`, `B`, `C`, `D`, `F`) and a `criteria` field (a free-form string
   describing the rubric criterion). The structural shape of each entry is enforced by the JSON Schema; the
   semantic content of the `criteria` string is entirely user-authored per Rule R1.
3. **Per [Rule R5](../template.md#r5--complexity-placeholder-integrity), leave `complexity: []`** UNTIL your
   organization defines a Complexity rubric. While `complexity: []`, the grading engine emits `TBD` and the
   PDF renderer renders the literal placeholder `Grade: TBD — definition pending` alongside the raw proxy
   metrics (LOC, file count, contributor count). Per [`./grading-engine.md`](./grading-engine.md) § 5
   Complexity Lock, the column MUST NOT be removed, collapsed, or backfilled with an inferred grade.
4. **Validate the YAML** against [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) before
   invoking the template. The validation procedure is documented in [`./grading-engine.md`](./grading-engine.md)
   § 2 Rubric Input Format. A rubric that fails schema validation produces a fast-fail error at template
   invocation time, before any repository ingestion is performed.
5. **Save the YAML file** to a path you control (e.g., `~/rubrics/portfolio-rubric.yaml`). The path is passed
   to the Blitzy invocation per § 6.2 below.

### 5.3 Worked Example: Maturity Grade A

Per [`./grading-engine.md`](./grading-engine.md) § 3.1, the user-supplied verbatim example shows the simplest
possible Maturity rubric entry: `"No library out of support = A for Maturity"`. The corresponding YAML
fragment is:

```yaml
maturity:
  - grade: A
    criteria: "No library out of support"
```

This fragment appears under the top-level `rubric:` key in a complete rubric document — see
[`../config/rubric-example.yaml`](../config/rubric-example.yaml) for the full structural envelope. The
`criteria` string `"No library out of support"` is the verbatim user-supplied antecedent; the grade
assignment `= A for Maturity` is encoded structurally by placement under the `maturity` key with `grade: A`.

### 5.4 Iteration

The rubric is the author's editable control surface per [Rule R1](../template.md#r1--rubric-editability).
Authors typically iterate between runs:

1. Run with rubric A.
2. Review the PDF.
3. Adjust thresholds in the YAML — typically by tightening or loosening the `criteria` strings, or by adding
   or removing rubric entries to refine the A–F bands.
4. Run with rubric A' (the adjusted version) against the same scope.
5. Compare the two PDFs.

Per Rule R1's verification clause, two different rubrics for the same dataset produce different grade
outputs — that is, the grading engine is deterministic given the same `(raw data, rubric)` pair, so any
difference in PDF output between the two runs is attributable to the rubric change alone.

### 5.5 Cross-Reference

For the complete grading-engine semantics (rubric input format, evaluation procedure, R1 verification
procedure, Complexity lock), see [`./grading-engine.md`](./grading-engine.md). For the JSON Schema
contract that constrains the rubric document, see [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json).
For the canonical configuration worked example, see [`../config/rubric-example.yaml`](../config/rubric-example.yaml).

## 6. Step 4: Invoking the Template

This step invokes the template against your run scope and rubric, producing the PDF artifact and the run's
persistence records. The exact invocation surface is environment-dependent; this section documents the
**inputs** the template expects so that the author can prepare them once and use them across any Blitzy
invocation surface.

### 6.1 Generic Invocation Shape

The exact invocation command depends on the Blitzy environment in which the template runs. Regardless of
invocation surface, the template expects three inputs:

1. **The run scope** — from § 4 (a YAML file listing the `org/repo` identifiers).
2. **The rubric** — from § 5 (a YAML or JSON file conforming to [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json)).
3. **The credentials** — from § 3 (environment variables `GITHUB_TOKEN`, optionally `GITLAB_TOKEN`, and
   optionally `NVD_API_KEY`).

Refer to your Blitzy environment's documentation for the canonical invocation command (CLI subcommand name,
web-UI button, API endpoint, scheduled-job entry point). The template itself is the canonical Blitzy prompt
in [`../template.md`](../template.md); the Blitzy environment dispatches to that prompt with the three inputs
above.

### 6.2 Example Invocation (Pseudo-CLI)

A representative invocation under a CLI-style Blitzy environment is:

```bash
blitzy invoke templates/technology-estate-report \
  --rubric ~/rubrics/portfolio-rubric.yaml \
  --scope ~/scopes/q4-2025-scope.yaml \
  --output ~/reports/q4-2025-report.pdf
```

The `--rubric` flag points at the rubric YAML authored in § 5; the `--scope` flag points at the scope YAML
authored in § 4; the `--output` flag specifies the destination path for the rendered PDF. The actual flag
names and the subcommand spelling are environment-specific; the example above is a pseudo-CLI illustration
only. For the canonical single-command execution path used by the validation harness (Gate 10), see
[`./validation.md`](./validation.md) § Single-Command Execution Path Summary.

### 6.3 Required Environment Variables at Invocation Time

The following environment variables are consumed at invocation time. Each variable is provisioned per § 3
above; this section is the consolidated reference for the invocation-time environment.

```bash
GITHUB_TOKEN          # required if scope includes GitHub repos
GITLAB_TOKEN          # required if scope includes GitLab repos
NVD_API_KEY           # optional; strongly recommended for any non-trivial scope
```

In addition, the following optional environment variables control logging and output behavior:

```bash
BLITZY_LOG_LEVEL      # one of {error, warning, info, debug}; default info
BLITZY_OUTPUT_DIR     # output directory for the PDF and structured log; defaults per Blitzy environment
```

The `BLITZY_LOG_LEVEL` variable is documented in § 9 below. The `BLITZY_OUTPUT_DIR` variable controls the
destination directory for the rendered PDF, the run's structured log, and the validation harness artifacts
documented in [`./validation.md`](./validation.md) § Artifact Retention; when unset, the Blitzy environment's
default output directory is used (typically `~/blitzy-reports/` or equivalent — consult the Blitzy
environment's documentation).

### 6.4 First Run vs. Recurring Run

The invocation is **identical** for first runs and recurring runs per [Rule R10](../template.md#r10--new-repo-compatibility).
The author does NOT supply a flag indicating whether this is a first run or a recurring run; the template
automatically inspects the grade history persistence store and renders prior-grade values per
[Rule R3](../template.md#r3--grade-history-fidelity):

- For each `(application_id, facet)` pair with a prior persistence record, the cell renders
  `<current> ← prev: <prior_grade> | <prior_run_date_iso>`.
- For each `(application_id, facet)` pair with no prior persistence record, the cell renders
  `<current> ← prev: N/A`.

This single-execution-path property is the operational realization of Rule R10's "heterogeneous scope"
requirement and is exercised by the [Gate 8 Item 3](./validation.md#45-item-3-grade-history-verification)
three-sequential-runs verification.

### 6.5 Run Date Capture

At invocation time, the template captures `run_date` as the **current ISO 8601 datetime in UTC** (e.g.,
`2025-10-01T08:00:00Z`). This `run_date` is propagated to every persistence record produced by the run per
[`./grade-history.md`](./grade-history.md) § 2 Storage Key, which uses the tuple
`(application_id, facet, run_date)` as the unique persistence key.

The captured `run_date` is also embedded in:

- The default PDF output filename (per § 7.1 below).
- The structured log records emitted during the run (per § 9 below).
- The validation harness output directory naming convention per [`./validation.md`](./validation.md)
  § Artifact Retention.

The `run_date` is recorded once at the start of the run and is identical across all per-facet, per-application
records produced by that run; this guarantees the per-run join-key consistency required by [Rule R3](../template.md#r3--grade-history-fidelity)
and [Rule R7](../template.md#r7--application-identity-stability).

## 7. Step 5: Retrieving the PDF

This step retrieves and validates the rendered PDF artifact. Per [Rule R8](../template.md#r8--pdf-section-order),
the PDF contains exactly two sections in fixed order: an Executive Summary on page 1, followed by the
Application Matrix Table on page 2 onward.

### 7.1 Output Location

The PDF is written to the path specified by `--output` (or the equivalent flag in your Blitzy environment),
or — if `--output` is omitted — to a default location under `BLITZY_OUTPUT_DIR` (or the Blitzy environment's
own default output directory).

The conventional default filename is `technology-estate-report_{run_date_iso}.pdf` — for example,
`technology-estate-report_2025-10-01T08-00-00Z.pdf`. Note that **colons in the timestamp are replaced with
hyphens** for filesystem compatibility (POSIX filenames disallow `:` on some platforms; Windows disallows it
universally), so the rendered filename uses `T08-00-00Z` rather than the canonical `T08:00:00Z` form found in
the persistence records and logs.

The validation harness writes its artifacts under a dedicated subdirectory per
[`./validation.md`](./validation.md) § Artifact Retention; see that section for the validation-specific
naming convention.

### 7.2 Inspecting the PDF

Open the rendered PDF in any PDF viewer (Adobe Acrobat, Apple Preview, Firefox, Chrome, etc.). The expected
content is:

- **Page 1** contains the **Executive Summary** per [Rule R8](../template.md#r8--pdf-section-order). The
  content list — total applications in scope, A–F grade distribution per facet, top Critical/High CVE
  findings, highest-maturity-risk applications, and net grade improvement/regression trends versus the prior
  run — is documented in [`./pdf-output.md`](./pdf-output.md) § 3 Executive Summary Content. The aggregation
  rules underlying each content item are in [`./executive-summary.md`](./executive-summary.md).
- **Page 2 onward** contains the **Application Matrix Table** with one row per repository in the run scope.
  The four columns appear in canonical order — Tech Stack Summary | Maturity Summary | Security Summary |
  Complexity Summary — per [`./pdf-output.md`](./pdf-output.md) § 4 Matrix Table Columns.
- **Each cell** renders per the format documented in [`./pdf-output.md`](./pdf-output.md) § 5 Cell Rendering
  Format. The canonical verbatim cell-format example is `B  ←  prev: C  |  2025-10-01` (preserved exactly,
  including the two spaces around the `←` arrow and the two spaces around the `|` pipe).

### 7.3 Validating the PDF

For Gate 1 Live Smoke Test verification, follow the canonical procedure in [`./validation.md`](./validation.md)
§ Gate 1. For routine inspections, confirm each of the following at-a-glance properties:

- **All 4×N cells are non-empty** per [Rule R2](../template.md#r2--facet-completeness) — every cell in every
  row and every column displays a value drawn from the closed set documented in [`./pdf-output.md`](./pdf-output.md)
  § 5 Cell Rendering Format. No empty cell appears anywhere in the matrix table.
- **Page 1 contains the Executive Summary** heading per [Rule R8](../template.md#r8--pdf-section-order). The
  matrix table does NOT begin on page 1.
- **Recurring-run cells** show `prev: <grade> | <ISO 8601 date>` per [Rule R3](../template.md#r3--grade-history-fidelity).
- **Net-new repository cells** show `prev: N/A` per [Rule R10](../template.md#r10--new-repo-compatibility).
- **The Complexity column** shows the literal label `Grade: TBD — definition pending` until the rubric is
  unlocked per [Rule R5](../template.md#r5--complexity-placeholder-integrity). The column is always present
  (never removed, collapsed, or backfilled with an inferred grade).
- **The Security column footer or per-cell metadata** shows the scan timestamp (ISO 8601) and the source
  database label (`NVD`, `OSV`, or both) per [Rule R9](../template.md#r9--cve-attribution).

If any of the above checks fails, consult [`./troubleshooting.md`](./troubleshooting.md) § 2
Failure-Mode-to-Cell-Value Mapping for diagnosis and remediation. Validation failures are documented as
Gate 1 or Gate 2 failures and have remediation paths in [`./validation.md`](./validation.md).

## 8. Recurring Run Scheduling

This step is OPTIONAL but recommended: schedule recurring invocations of the template so that the grade
history accumulates and the executive summary's trend-versus-prior-run content has data to report against.
Per [`../template.md`](../template.md) § 2 Task Context, **reports are cumulative** — recurring runs are the
mechanism by which the package delivers ongoing CIO/CTO visibility into the technology estate.

### 8.1 Cadence

The typical cadence for the Technology Estate Report is **monthly or quarterly**, matching most
organizations' CIO/CTO board reporting cycles. The template imposes no cadence requirement of its own; per
[Rule R3](../template.md#r3--grade-history-fidelity), `run_date` is captured on each invocation regardless of
cadence, so the persistence store accumulates records on whatever cadence the author chooses.

For organizations with active development on many repositories, a more frequent cadence (weekly or even
daily) MAY be useful to detect short-term regressions. For organizations with stable estates, a less frequent
cadence (semi-annually, annually) MAY be sufficient. The cadence is a scheduling decision, not a template
configuration.

### 8.2 Scheduled Invocations

Schedule the invocation via:

- **The Blitzy environment's built-in scheduler**, when available. Consult the Blitzy environment's own
  documentation for its scheduling surface.
- **An external scheduler**, when the Blitzy environment does not provide one or when organizational policy
  prefers a centralized scheduler. Common external schedulers include:
  - `cron` on a Linux host with credentials sourced from a secret manager.
  - GitHub Actions scheduled workflows (`on: schedule`).
  - GitLab CI scheduled pipelines.
  - AWS EventBridge rules invoking a Lambda or ECS task.
  - Azure Logic Apps or Azure Automation runbooks.
  - GCP Cloud Scheduler invoking a Cloud Run job.
  - HashiCorp Nomad periodic jobs, Kubernetes CronJobs, or equivalent orchestrator-native primitives.

Each scheduled run consumes the **same scope file and rubric file** as the prior run, unless those files have
been edited between runs. Updates to the scope file (e.g., adding a new repository per § 4.4) or the rubric
file (e.g., tightening a Maturity threshold per § 5.4) take effect on the **next scheduled run** — there is
no separate migration step.

### 8.3 Handling Scope Changes Between Runs

Per [Rule R10](../template.md#r10--new-repo-compatibility), scope additions are handled transparently:

- **Adding a repository to the scope file** between runs causes the new repository to appear as a new row in
  the next PDF's matrix table, with `prev: N/A` cells per [Rule R3](../template.md#r3--grade-history-fidelity).
- **Removing a repository from the scope file** between runs causes the removed repository to NOT appear in
  the next PDF's matrix table. Its prior persistence records remain in the store per
  [`./grade-history.md`](./grade-history.md) § 3 Immutability Contract; if the repository is later re-added
  to scope, its prior history is preserved and rendered inline per Rule R3.
- **Renaming a repository** (changing its `org/repo` identifier) is a [Rule R7](../template.md#r7--application-identity-stability)
  violation and is NOT supported by the template's automatic identity resolution. If a repository is renamed
  on its source-control host, the author has two options: (a) treat the renamed repository as a net-new
  application (it appears with `prev: N/A` and accumulates fresh history under the new identifier), or (b)
  perform a manual one-time migration of the prior persistence records to the new identifier. Option (b) is
  outside the template's automated workflow; consult [`./grade-history.md`](./grade-history.md) for migration
  considerations and document the migration in your organization's audit trail.

### 8.4 Rubric Changes Between Runs

Per [Rule R1](../template.md#r1--rubric-editability), rubric changes affect only the **current** run's
grades. Prior persistence records remain in their original form, storing the grade emitted at the original
run's rubric. This has an important implication for trend computation:

> The trend-versus-prior-run content item in the Executive Summary (per [`./executive-summary.md`](./executive-summary.md)
> § 6) MAY show apparent regressions or improvements that are due to **rubric changes** rather than substantive
> application changes.

For example, tightening a Security threshold so that "at most 5 High CVEs" maps to grade B (rather than the
prior rubric's grade A) will appear as a portfolio-wide regression in Security grades, even though no
actual application code or dependency has changed. When making material rubric changes between runs,
document the change in the executive summary's trend section if relevant to the audience, OR coordinate with
your CIO/CTO reviewer to interpret the trend in light of the rubric revision.

The persistence store retains every per-run grade indefinitely per [`./grade-history.md`](./grade-history.md)
§ 3, so the audit trail of "this run used rubric X, that run used rubric Y" is recoverable from the store
plus the rubric files retained alongside it.

## 9. Verbose Logging

The template emits structured logs during each run; these logs are the primary diagnostic surface for
investigating `Insufficient Data` cells, rate-limit failures, manifest parse errors, and other failure modes.

### 9.1 Log Levels

The environment variable `BLITZY_LOG_LEVEL` controls log verbosity. Valid values, in increasing order of
detail:

- **`error`** — only errors. Use for production runs where stdout/stderr noise must be minimized.
- **`warning`** — errors plus warnings. **Default for production runs** in many Blitzy environments.
- **`info`** — adds high-level progress events (per-repository start/finish, per-facet start/finish,
  per-API call summaries). **Default for interactive runs.**
- **`debug`** — adds per-API-call traces (request URL, response status, rate-limit headers, retry attempts),
  per-record persistence events, and grading-engine evaluation traces. Voluminous; not recommended for
  routine production runs.

### 9.2 When to Use Debug

Per [`./troubleshooting.md`](./troubleshooting.md) § 9.2 Reproducing a Failure, debug-level logging is the
primary diagnostic mode for investigating a specific cell's `Insufficient Data` rendering. The recommended
diagnostic procedure is:

1. Identify the `(application_id, facet)` pair from the PDF cell that rendered `Insufficient Data`.
2. Reduce the run scope to a **single-repository scope** containing only the affected `application_id`.
3. Set `BLITZY_LOG_LEVEL=debug` and re-run the template:

   ```bash
   export BLITZY_LOG_LEVEL=debug
   blitzy invoke templates/technology-estate-report \
     --rubric ~/rubrics/portfolio-rubric.yaml \
     --scope ~/scopes/single-repo.yaml \
     --output ~/reports/diagnosis.pdf
   ```

4. Inspect the structured log for events matching the affected facet (e.g., search for
   `"facet": "security"` records when investigating a Security `Insufficient Data` cell).
5. Cross-reference the failure mode against [`./troubleshooting.md`](./troubleshooting.md) § 2
   Failure-Mode-to-Cell-Value Mapping for the documented remediation.

### 9.3 Log Format

Per [`./architecture.md`](./architecture.md) § Component Boundaries, logs are emitted as **structured JSON
records, one per line** (newline-delimited JSON, sometimes called "JSONL" or "ndjson"). Each record contains
at minimum:

- `timestamp` — ISO 8601 datetime in UTC.
- `severity` — one of `error`, `warning`, `info`, `debug`.
- `component` — the analysis component emitting the record (e.g., `tech-stack-detector`, `cve-scanner`,
  `grading-engine`).
- `application_id` — the `org/repo` identifier of the repository being processed (when applicable).
- `facet` — the facet identifier (when applicable; one of `tech_stack`, `maturity`, `security`, `complexity`).
- `message` — a human-readable description of the event.
- Additional fields specific to the event type (e.g., `http_status`, `retry_attempt`, `manifest_path`).

Structured JSON logs may be filtered with `jq` for diagnosis, e.g.:

```bash
jq 'select(.severity == "warning" or .severity == "error")' ~/blitzy-reports/structured.log.jsonl
```

The validation harness (Gate 2) asserts that no `severity: error` or `severity: warning` records correspond
to silent failures — every such record MUST surface as an explicit `Insufficient Data` cell in the rendered
PDF per [`./validation.md`](./validation.md) § Gate 2.

## 10. Common Workflows

This section assembles end-to-end procedures for the four most frequent author actions. Each procedure
references the underlying step sections (§§ 3–9) for detail.

### 10.1 First-Time Setup for a New Portfolio

When establishing the Technology Estate Report for a new portfolio (an organization that has not previously
used this template), follow these steps:

1. **Provision GitHub PAT** (and `GITLAB_TOKEN` if applicable, and `NVD_API_KEY` for any non-trivial scope)
   per § 3.
2. **Prepare the scope YAML** listing all repositories to track per § 4. For a first portfolio, err on the
   side of inclusion — repositories that do not require ongoing tracking can be removed from scope later
   without disrupting the persistence store per § 4.5.
3. **Author the rubric** by copying [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) to
   your working location and customizing per § 5. For organizations that have not yet defined their own
   grading standards, the production-ready example is suitable as a baseline. Per [Rule R5](../template.md#r5--complexity-placeholder-integrity),
   leave `complexity: []` until the organization defines a Complexity rubric.
4. **Invoke the template** per § 6. The first run will produce a PDF where every cell shows `prev: N/A` per
   [Rule R3](../template.md#r3--grade-history-fidelity), because no prior persistence records exist.
5. **Review the PDF** per § 7. Confirm the at-a-glance properties (all cells populated, Executive Summary on
   page 1, Complexity locked to TBD, Security cells include scan attribution).
6. **Schedule recurring invocations** per § 8 to begin accumulating grade history and unlock the
   trend-versus-prior-run content in subsequent Executive Summaries.

### 10.2 Adding a New Repository to a Recurring Run

When adding a new repository to an established recurring run (a portfolio that already has prior runs in the
persistence store), follow these steps:

1. **Append the new `org/repo`** to the scope YAML file per § 4.4. The scope file is a simple list; just add
   one new entry.
2. **Invoke the template normally** per § 6 — there is **no migration step** required per [Rule R10](../template.md#r10--new-repo-compatibility).
   The same execution path that handled the prior recurring runs handles the new repository.
3. **The new repo's row in the next PDF** will show `prev: N/A` for all four facets per
   [Rule R3](../template.md#r3--grade-history-fidelity), because no prior persistence records exist for that
   `application_id`.
4. **Subsequent runs** will show the new repo's grade history accumulating, starting with the grade emitted
   by the run that added it. Per [`./grade-history.md`](./grade-history.md) § 6 Heterogeneous Scope
   Handling, the new repository's history is independent of every other repository's history; existing
   repositories' histories are not disrupted.

### 10.3 Refining the Rubric Iteratively

When iterating on the rubric to align grade emissions with executive expectations, follow these steps:

1. **Run with rubric A**; inspect the PDF per § 7.
2. **Identify cells where the grade does not align** with executive expectations — for example, an
   application that the CIO considers high-risk but received a B grade for Security.
3. **Adjust the rubric thresholds** in the YAML per § 5.4. Typical adjustments tighten or loosen `criteria`
   strings, or add new `grade` entries to refine the A–F bands.
4. **Run again with rubric B** (the adjusted version) against the same scope; inspect the new PDF.
5. **Compare the two PDFs.** Per [Rule R1](../template.md#r1--rubric-editability), the grading engine is
   deterministic given the same `(raw data, rubric)` pair; differences in PDF output between the two runs
   are entirely attributable to the rubric change.
6. **The persistence store retains all per-run grades** per [Rule R3](../template.md#r3--grade-history-fidelity),
   so trend computation per [`./executive-summary.md`](./executive-summary.md) § 6 will reflect the rubric
   change alongside any substantive application changes — see § 8.4 above for the implication and the
   recommendation to document material rubric changes in the executive summary trend section.

### 10.4 Investigating an Insufficient Data Cell

When a matrix cell renders `Insufficient Data` and the author wants to diagnose the cause, follow these
steps:

1. **Identify the `(application_id, facet)` pair** from the PDF cell that rendered `Insufficient Data`. The
   row label is the `application_id` (`org/repo`); the column label is the facet (Tech Stack, Maturity,
   Security, or Complexity).
2. **Re-run with `BLITZY_LOG_LEVEL=debug`** and a single-repository scope containing only the affected
   `application_id`:

   ```bash
   export BLITZY_LOG_LEVEL=debug
   blitzy invoke templates/technology-estate-report \
     --rubric ~/rubrics/portfolio-rubric.yaml \
     --scope ~/scopes/single-repo.yaml \
     --output ~/reports/diagnosis.pdf
   ```

3. **Inspect the structured log** for the corresponding facet's events per § 9.3. Look for records with
   `severity: warning` or `severity: error` that mention the affected `(application_id, facet)` pair. The
   `message` and `component` fields identify the failing analysis component (tech-stack-detector,
   maturity-analyzer, cve-scanner, complexity-extractor) and the failure cause.
4. **Cross-reference the failure mode** against [`./troubleshooting.md`](./troubleshooting.md) § 2
   Failure-Mode-to-Cell-Value Mapping. Common failure modes include: rate-limit-induced API failure (NVD
   without `NVD_API_KEY`), manifest parse error (malformed `package.json` or equivalent), endoflife.date
   product-slug resolution miss, missing IaC configuration, and missing git history.
5. **Apply the documented remediation** and re-run. Common remediations include: provisioning `NVD_API_KEY`,
   correcting the malformed manifest, refreshing expired credentials per § 3.4, or accepting the
   `Insufficient Data` rendering as a true reflection of unavailable source data per [Rule R2](../template.md#r2--facet-completeness).

## 11. Cross-References

This document references the following package-internal artifacts. Every link is a relative path **within**
[`templates/technology-estate-report/`](..); no link reaches outside this directory per the standalone-package
property of [`../template.md`](../template.md) § 4 Boundaries & Preservation.

- [`../README.md`](../README.md) — package overview, file map, and canonical glossary (terms `facet`,
  `application`, `run`, `rubric`, `grade history`).
- [`../template.md`](../template.md) — canonical Rules R1, R2, R3, R5, R7, R8, R9, R10 (verbatim user prose
  lives here); canonical Validation Gates 1, 2, 8, 9, 10.
- [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) — production-ready example rubric
  covering all four facets.
- [`../config/rubric-example.yaml`](../config/rubric-example.yaml) — configuration worked example with
  `complexity: []` per Rule R5.
- [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) — JSON Schema (Draft 2020-12) for the
  user-supplied rubric document.
- [`./grading-engine.md`](./grading-engine.md) — rubric input format, evaluation procedure, R1 verification
  procedure, Complexity Lock.
- [`./grade-history.md`](./grade-history.md) — storage key (`application_id`, `facet`, `run_date`),
  immutability contract, retrieval and prior-grade lookup, heterogeneous-scope handling, new-repository
  onboarding.
- [`./api-integrations.md`](./api-integrations.md) — credential provisioning references (GitHub PAT scope,
  GitLab PAT scope, NVD API key registration), credential rotation cadence, network-egress allow-list
  ([Rule R6](../template.md#r6--saas-data-sourcing)), R9 attribution rule.
- [`./pdf-output.md`](./pdf-output.md) — PDF section ordering ([Rule R8](../template.md#r8--pdf-section-order)),
  matrix table column order, cell-rendering format (canonical verbatim example
  `B  ←  prev: C  |  2025-10-01`).
- [`./executive-summary.md`](./executive-summary.md) — portfolio-level aggregation rules, including
  trend-versus-prior-run computation referenced from § 8.4.
- [`./troubleshooting.md`](./troubleshooting.md) — Failure-Mode-to-Cell-Value mapping, debug-level
  reproduction procedure, structured-log retrieval.
- [`./validation.md`](./validation.md) — Gate 1 Live Smoke Test, Gate 2 zero-warning contract, Gate 8
  integration sign-off checklist, Gate 9 component-reachability matrix, Gate 10 single-command execution
  path.
- [`./configuration.md`](./configuration.md) — configuration file reference, including the no-credential-values
  rule (§ 5) and the per-entry `host:` override convention for self-hosted GitHub Enterprise / GitLab CE.
- [`./architecture.md`](./architecture.md) — component data-flow diagram, structured-log conventions
  (referenced in § 9.3).

This document does not reproduce verbatim rule text or verbatim gate text; per the AAP § 0.10.2 "No
Redundancy Rule," the canonical verbatim text lives only in [`../template.md`](../template.md) §§ 5 and 6.
