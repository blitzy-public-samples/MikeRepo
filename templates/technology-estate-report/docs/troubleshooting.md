# Troubleshooting & Failure Handling — Technology Estate Report Template

## 1. Overview

This document is the **canonical Failure-Mode-to-Cell-Value mapping** for the Technology Estate Report
Blitzy prompt template package. It enumerates every failure mode the template can encounter at run time and
specifies the exact cell value that surfaces in the rendered PDF for each. Per
[Rule R2](../template.md#r2--facet-completeness), every matrix cell in every PDF MUST be either a graded
value (`A`, `B`, `C`, `D`, `F`) or the literal `Insufficient Data` (capital I, capital D, single space) or
the literal `Grade: TBD — definition pending` (Complexity facet only, per
[Rule R5](../template.md#r5--complexity-placeholder-integrity)). Empty cells are prohibited; omitted cells
are prohibited; whitespace-only cells are prohibited.

Per [Gate 2](../template.md#612-gate-2--zero-warning-build), every failure mode MUST surface as an explicit
cell value — silent omission, suppressed warning, or empty cell is a failing state. The grading engine is
responsible for emitting the persistence-layer enum value `InsufficientData` (PascalCase, single token per
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.grade.enum`)
whenever a failure prevents normal grading; the PDF renderer translates this enum value to the rendered cell
text `Insufficient Data` (with single space, capital letters per the verbatim Rule R2 surface). The
two-string convention — single-token PascalCase in the persistence record and human-readable two-word string
at render time — is preserved exactly as documented in
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.grade` and in
[`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format.

This document is the **single canonical reference** for what surfaces as `Insufficient Data` and what does
not. Per the AAP § 0.10.2 "No Redundancy Rule," [`./facets.md`](./facets.md),
[`./grading-engine.md`](./grading-engine.md), [`./api-integrations.md`](./api-integrations.md), and
[`./pdf-output.md`](./pdf-output.md) reference [§ 2 Failure-Mode-to-Cell-Value
Mapping](#2-failure-mode-to-cell-value-mapping) below rather than duplicate the failure-mode list. The
verbatim text of Rule R2 and Gate 2 lives only in [`../template.md`](../template.md) §§ 5.2 and 6.1.2; this
document cites those locations and does not duplicate the verbatim prose.

## 2. Failure-Mode-to-Cell-Value Mapping

This section is the **canonical mapping** of every failure mode the template can encounter to its
documented cell value and persistence-layer enum value. Cross-references from
[`./facets.md`](./facets.md), [`./grading-engine.md`](./grading-engine.md),
[`./api-integrations.md`](./api-integrations.md), and [`./pdf-output.md`](./pdf-output.md) point at this
table rather than duplicate it. Any future failure-mode addition MUST be added here first; the addition is
recorded in [`../CHANGELOG.md`](../CHANGELOG.md) per [§ 9.3 Reporting a New Failure
Mode](#93-reporting-a-new-failure-mode) below.

The table is read column-by-column as follows: **Facet** identifies which of the four facets (or "All
facets" / "Grading engine") the failure pertains to; **Failure Mode** is the human-readable description of
the condition; **Detection Signal** is the technical signal the template uses to recognize the condition;
**Cell Value** is the literal text that the PDF renderer writes into the matrix cell per
[`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format; **Persistence `grade`** is the value written
into the `grade` field of the persistence record per
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.grade.enum`.

| Facet | Failure Mode | Detection Signal | Cell Value | Persistence `grade` |
|---|---|---|---|---|
| Tech Stack | Repository has zero source files | File listing returns 0 files matching any tracked extension | `Insufficient Data` | `InsufficientData` |
| Tech Stack | Repository tree fetch fails (404, 401, persistent 5xx) | HTTP error from GitHub/GitLab tree API after retries | `Insufficient Data` | `InsufficientData` |
| Tech Stack | All detected files are below the language threshold | Every language < `facets.tech_stack.language_threshold` (default 5%) per [`../config/facets.yaml`](../config/facets.yaml) | Cell renders `Other: 100%` (this is NOT a failure; this is a low-signal but valid state) | (normal grade) |
| Maturity | No dependency manifests detected in the repository | File listing returns 0 manifest files (`package.json`, `requirements.txt`, `pom.xml`, `go.mod`, `Gemfile`, `Cargo.toml`, etc.) | `Insufficient Data` | `InsufficientData` |
| Maturity | All endoflife.date lookups fail (persistent 5xx or network error after retries) | Every endoflife.date request returns failure | `Insufficient Data` | `InsufficientData` |
| Maturity | Some endoflife.date lookups fail but at least one succeeds | Partial failure | (normal grade) — surface failed products in `raw_data.unknown_eol_products[]` per [`./facets.md`](./facets.md) § Maturity Summary | (normal grade) |
| Maturity | endoflife.date returns 404 for a product (product not tracked) | HTTP 404 | (normal grade) — record product as `eol_unknown` per [`./facets.md`](./facets.md) § Maturity Summary § Product Slug Resolution | (normal grade) |
| Maturity | Manifest parse error (corrupt JSON/XML/TOML) | Parser exception | `Insufficient Data` if ALL manifests fail; partial success per [§ 6 Manifest Parse Errors](#6-manifest-parse-errors) below | `InsufficientData` (full failure) |
| Security | SBOM generation fails for ALL ecosystems present | All per-ecosystem CycloneDX generators error out | `Insufficient Data` | `InsufficientData` |
| Security | Both NVD AND OSV are unreachable after retries | All HTTP requests fail | `Insufficient Data` | `InsufficientData` |
| Security | Only NVD reachable | NVD succeeds, OSV fails | (normal grade) — `scan_metadata.sources: ["NVD"]` per [Rule R9](../template.md#r9--cve-attribution) | (normal grade) |
| Security | Only OSV reachable | OSV succeeds, NVD fails | (normal grade) — `scan_metadata.sources: ["OSV"]` per [Rule R9](../template.md#r9--cve-attribution) | (normal grade) |
| Security | NVD rate-limited (HTTP 429) | After all retries exhausted on NVD | Treat as NVD-unreachable; surface partial-coverage per the two rows above | (normal or `InsufficientData`) |
| Security | No dependencies in the repository (no manifests) | SBOM contains 0 components | (normal grade) — render `0 CVEs` cell with full severity-tier zeros per [Rule R4](../template.md#r4--cve-severity-breakdown) | (normal grade) |
| Complexity (locked) | Rubric has empty `complexity: []` array | User-supplied rubric per [Rule R5](../template.md#r5--complexity-placeholder-integrity) | `Grade: TBD — definition pending` + raw metrics line | `TBD` |
| Complexity (unlocked) | Git log retrieval fails | Cannot compute contributor count | `Insufficient Data` | `InsufficientData` |
| Complexity (unlocked) | LOC counter fails for all source files | Tokei/cloc errors | `Insufficient Data` | `InsufficientData` |
| All facets | Authentication failure (HTTP 401) on GitHub/GitLab | Token invalid/expired | Per-application failure: ALL four cells render `Insufficient Data` for the affected application | `InsufficientData` per facet |
| All facets | Repository not found (HTTP 404) on GitHub/GitLab | Repo does not exist or token lacks access | Per-application failure: ALL four cells render `Insufficient Data` for the affected application | `InsufficientData` per facet |
| All facets | Repository archived | GitHub `archived: true` | (normal grade) — proceed; the archived flag is informational only | (normal grade) |
| Grading engine | Rubric is missing the facet entry | `rubric.<facet>` is absent | Validation error before grading; abort run with explicit error message | (run aborted) |
| Grading engine | Rubric is malformed (schema validation failure) | JSON Schema validation fails on [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) | Validation error before grading; abort run with explicit error message | (run aborted) |
| Grading engine | Per-facet raw data has no rubric match | All A–F entries non-matching, AND raw data is present | Emit grade `F` (catch-all worst grade) per [`./grading-engine.md`](./grading-engine.md) § 4.2 | `F` |

### 2.1 Distinction: Facet-Level vs. Application-Level `Insufficient Data`

Two failure modes in the table produce **per-application** (i.e., row-wide) `Insufficient Data` rather than
per-cell (i.e., single-facet) `Insufficient Data`:

- **Authentication failure (HTTP 401) on GitHub/GitLab** — when the source-control API rejects the token,
  no source artifacts can be retrieved for the affected application; ALL FOUR facets (`tech_stack`,
  `maturity`, `security`, `complexity`) render `Insufficient Data` for that application's row.
- **Repository not found (HTTP 404) on GitHub/GitLab** — when the API returns 404, the application's
  artifacts are unavailable for the same reason; ALL FOUR cells render `Insufficient Data`.

All other failure modes in the table affect a **single facet cell** while leaving the other three facets'
cells in their normal state. For example, a CVE database double-failure surfaces `Insufficient Data` only in
the Security column for the affected application; Tech Stack, Maturity, and Complexity for the same
application remain populated with their normal grades. This per-cell-vs-per-row distinction is operationally
important when reviewers diagnose `Insufficient Data` cells: a row whose four cells are ALL `Insufficient
Data` indicates an upstream ingestion failure (auth or 404), while a row with only one or two `Insufficient
Data` cells indicates a per-facet failure that can be diagnosed in isolation per [§ 9.2 Reproducing a
Failure](#92-reproducing-a-failure) below.

### 2.2 Distinction: `TBD` vs. `Insufficient Data` for Complexity

Per [Rule R5](../template.md#r5--complexity-placeholder-integrity), the Complexity column has TWO valid
non-graded states that are NOT interchangeable:

- **`TBD`** — emitted when the user-supplied rubric has an empty `complexity: []` array (the canonical
  "rubric not provided" state). The cell renders the literal `Grade: TBD — definition pending` followed by
  the raw proxy metrics line (LOC, file count, contributor count). The persistence record stores
  `grade: "TBD"`. Per [Rule R5](../template.md#r5--complexity-placeholder-integrity), the column MUST NOT
  be removed, collapsed, or backfilled with an inferred grade until an explicit Complexity rubric is
  supplied.
- **`InsufficientData`** — emitted when the data needed to compute the raw proxy metrics is unavailable
  (e.g., git log retrieval fails, LOC counter errors on all files). The cell renders `Insufficient Data`.
  The persistence record stores `grade: "InsufficientData"`.

The semantic difference is **rubric availability** vs. **data availability**: `TBD` means "the author has
not yet supplied the rubric for this facet"; `Insufficient Data` means "the underlying source data needed
to compute the facet is unavailable for this application." Reviewers diagnosing a Complexity cell SHOULD
inspect the rubric document first to determine which case applies, then follow the [§ 9.2 Reproducing a
Failure](#92-reproducing-a-failure) procedure.

### 2.3 Distinction: `N/A` vs. `Insufficient Data`

The persistence-layer enum admits both `N/A` and `InsufficientData` as documented in
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.grade.enum`.
They mean different things:

- **`N/A`** — surfaces in the **prior-grade slot** of a current-run cell when no prior persistence record
  exists for the `(application_id, facet)` pair. Per [Rule R3](../template.md#r3--grade-history-fidelity),
  the prior-grade slot of a first-run cell renders `N/A`. This is NOT a failure state; it is the canonical
  rendering for net-new repositories per [Rule R10](../template.md#r10--new-repo-compatibility).
- **`InsufficientData`** — surfaces in the **current-grade slot** when source data is unavailable for the
  current run. The cell text is `Insufficient Data` per Rule R2.

A cell may render BOTH a current-grade `Insufficient Data` and a prior-grade `N/A` simultaneously when a
net-new repository's first run encounters a failure: the current-grade slot is `Insufficient Data`, the
prior-grade slot is `N/A`, and the persistence record has `grade: "InsufficientData"` for the current run.
The next run's prior-grade slot will then render `Insufficient Data` (or, equivalently, the prior-grade
slot of that subsequent run will inherit the prior `InsufficientData` enum from the just-persisted record);
the two-step rendering follows the canonical [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format
contract.

## 3. Insufficient Data Cell Rendering Rules

The literal cell value emitted by the PDF renderer is `Insufficient Data` (capital I, capital D, single
space, no surrounding punctuation). The string is the verbatim Rule R2 surface; it MUST NOT be
abbreviated, capitalized differently, or stylistically reformatted (e.g., `INSUFFICIENT DATA`,
`insufficient data`, `Insufficient_Data`, or `[Insufficient Data]` are all non-conformant).

### 3.1 Cell Layout for `Insufficient Data`

Per [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format:

- The `Insufficient Data` cell value occupies the **entire cell text**; the prior-grade segment
  (`prev: ... | <ISO 8601 date>`) is **suppressed** for visual clarity. A missing current grade does not
  imply a missing prior-grade record (the persistence layer may still hold one), but the convention is to
  suppress the prior segment so the reviewer's eye is drawn to the current-run failure rather than to a
  potentially stale prior-run grade. The full prior-grade record remains queryable via the persistence
  layer; suppression applies only to the rendered cell text.
- The cell text MAY be styled with secondary color or italic emphasis to distinguish it visually from
  graded cells (`A`, `B`, `C`, `D`, `F`) and from `N/A` cells. Styling is a renderer concern and is NOT
  part of the canonical Rule R2 surface; reviewers MUST NOT reject a PDF for missing styling so long as
  the literal text `Insufficient Data` appears in the cell.
- The cell MUST NOT be empty, whitespace-only, or replaced with a placeholder glyph (e.g., `—`, `…`,
  `???`). Replacement glyphs violate Rule R2 and are a Gate 2 failing state per [§ 8 Output and
  Logging](#8-output-and-logging) below.

### 3.2 Persistence Record for `Insufficient Data`

The persistence record for an `Insufficient Data` result has `grade: "InsufficientData"` per
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.grade.enum`.
The persistence layer preserves the failure outcome for audit purposes; the next run can render the prior
grade as `Insufficient Data` in the prior-grade slot when the prior record's `grade` was
`InsufficientData`.

The two-string convention — `InsufficientData` in the persistence record and `Insufficient Data` in the
PDF — is intentional: the persistence enum is a single-token PascalCase identifier suitable for
machine-readable storage (and aligned with the JSON Schema enum constraint), while the rendered cell text
is the human-readable two-word string mandated by Rule R2. The mapping between the two is bidirectional
and deterministic: `InsufficientData` ↔ `Insufficient Data`. The persistence-to-render translation is
performed by the PDF renderer per [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format.

### 3.3 No Silent Omission Per Gate 2

Per [Gate 2](../template.md#612-gate-2--zero-warning-build), an empty cell, a missing cell, or a cell
containing whitespace-only is a **failing state**. Reviewers SHOULD verify in every generated PDF that all
4 × N cells (4 facets × N applications in scope) contain non-empty text from the closed set:

- One of the five letter grades: `A`, `B`, `C`, `D`, `F` (with an inline prior-grade segment per Rule R3)
- The literal `Insufficient Data` (per Rule R2)
- The literal `Grade: TBD — definition pending` (Complexity facet only, per Rule R5)

Any cell whose rendered text is outside this closed set is a Gate 2 violation; reviewers capture the
offending cell coordinate (row label, column label) and remediate per [§ 9.2 Reproducing a
Failure](#92-reproducing-a-failure) below. The Gate 2 verification procedure for this assertion is in
[`./validation.md`](./validation.md) § Gate 2.

## 4. Common Authentication Failures

This section enumerates the authentication-failure modes the template can encounter on the four
external APIs (GitHub, GitLab, NVD, plus repository-not-found from either source-control host) and the
remediation steps for each. Authoritative HTTP status code semantics for each external API are documented
in [`./api-integrations.md`](./api-integrations.md); this section is the operational runbook the report
author follows when one of these failures occurs.

### 4.1 GitHub Token Invalid (HTTP 401)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 401` and a body
  containing `"message": "Bad credentials"` from `api.github.com`.
- **Causes:** the GitHub PAT has expired, has been revoked, has been malformed during transcription
  (e.g., trailing whitespace, missing prefix), or the token was generated for a different GitHub account
  than the one whose repositories are in scope.
- **Remediation:** regenerate the GitHub PAT per [`./usage.md`](./usage.md) § 3 Provisioning Credentials;
  ensure the `repo` scope (classic) or the `Contents: Read-only` permission (fine-grained) is granted;
  verify the token by issuing the canonical token-verification probe documented in
  [`./api-integrations.md`](./api-integrations.md) § 2.10 Token Verification Probe. A successful probe
  returns the authenticated user's profile JSON with `login` and `id` keys; a failed probe returns `401`
  and the regenerated token must itself be regenerated.
- **Cell impact:** ALL FOUR cells for the affected application(s) render `Insufficient Data` per the
  per-application failure rule in [§ 2.1](#21-distinction-facet-level-vs-application-level-insufficient-data).
  The affected application(s) are exactly those repositories the failed token was used to access; other
  applications in the same run scope (e.g., GitLab-hosted repositories accessed via `GITLAB_TOKEN`) are
  unaffected.

### 4.2 GitHub Token Insufficient Scope (HTTP 403)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 403` and a body
  containing `"message": "Resource not accessible"` from `api.github.com`.
- **Causes:** the token lacks the `repo` scope (classic) or the equivalent fine-grained permission; the
  authenticating user lacks read access to the target repository (e.g., the repository is private and the
  user is not a member of the owning organization); or the token's owning user has been removed from the
  owning organization since the token was minted.
- **Remediation:** regenerate the token with the `repo` scope (classic) or `Contents: Read-only`
  (fine-grained) per [`./usage.md`](./usage.md) § 3.1, OR confirm that the user account associated with
  the token has access to every repository in the run scope (the GitHub UI's "Your repositories" listing
  is the canonical reference). For GitHub Enterprise installations, also verify the user has not been
  externally collaborator-restricted on the affected repositories.
- **Cell impact:** ALL FOUR cells for each affected application render `Insufficient Data`. The
  per-affected-repository scope of this failure is narrower than § 4.1: a single token may have access to
  some repositories but not others; the failure surfaces only on the inaccessible subset.

### 4.3 GitLab Token Invalid (HTTP 401)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 401` and a body
  containing `"message": "401 Unauthorized"` from `gitlab.com/api/v4` (or the configured self-hosted
  GitLab host).
- **Causes:** the GitLab PAT has expired, has been revoked, or has been malformed during transcription.
- **Remediation:** regenerate the GitLab PAT per [`./usage.md`](./usage.md) § 3 Provisioning Credentials;
  ensure the `read_api` and `read_repository` scopes are granted; verify by issuing the canonical
  token-verification probe documented in [`./api-integrations.md`](./api-integrations.md) § 3.10 Token
  Verification Probe. A successful probe returns the authenticated user's profile JSON with `username` and
  `id` keys; a failed probe returns `401` and the token must itself be regenerated.
- **Cell impact:** ALL FOUR cells for each affected GitLab application render `Insufficient Data`.
  GitHub-hosted applications in the same run scope are unaffected.

### 4.4 GitLab Token Insufficient Scope (HTTP 403)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 403` and a body
  containing `"message": "403 Forbidden"` from `gitlab.com/api/v4`.
- **Causes:** the token lacks `read_repository` (the canonical scope for repository tree access) or
  `read_api` (the canonical scope for project metadata access); or the authenticating user lacks
  membership in the target project's group hierarchy.
- **Remediation:** regenerate the token with both `read_api` and `read_repository` per
  [`./usage.md`](./usage.md) § 3.2, OR confirm project membership for the authenticating user (Project
  Members → Verify or Invite). For self-hosted GitLab CE/EE installations, also verify the project's
  visibility level (Private vs. Internal vs. Public) matches the user's authentication context.
- **Cell impact:** ALL FOUR cells for each inaccessible application render `Insufficient Data`. As with
  § 4.2, the per-affected-project scope of this failure is narrower than the token-invalid case.

### 4.5 NVD API Key Invalid (HTTP 403)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 403` and a
  response body indicating an invalid API key from `services.nvd.nist.gov`.
- **Causes:** the NVD API key has expired, has been revoked, or has been malformed; the key was issued
  for a different NIST email address than the one currently in use.
- **Remediation:** re-request an NVD API key from the NIST registration portal; provision the new key
  via the `NVD_API_KEY` environment variable per [`./api-integrations.md`](./api-integrations.md) § 5.4.
  The template tolerates an absent `NVD_API_KEY` (it simply uses the lower 5/30s rate limit per
  [§ 5.3 NVD Rate Limit](#53-nvd-rate-limit-530s-without-key-5030s-with-key) below) but does NOT tolerate
  an invalid key — an invalid key is treated as a hard authentication failure.
- **Cell impact:** the Security cell MAY render `Insufficient Data` if the NVD failure combines with an
  OSV unreachability to produce dual-source failure per [§ 2 Failure-Mode-to-Cell-Value
  Mapping](#2-failure-mode-to-cell-value-mapping) above; otherwise the run proceeds with OSV-only
  sourcing and `scan_metadata.sources: ["OSV"]` per [Rule R9](../template.md#r9--cve-attribution).

### 4.6 Repository Not Found (HTTP 404)

- **Symptoms:** the structured log records `severity: error` events with `http_status: 404` from
  `GET /repos/{org}/{repo}` (GitHub) or `GET /api/v4/projects/:id` (GitLab).
- **Causes:** the repository does not exist at the referenced `org/repo` path; the token does not have
  visibility into a private repository (GitHub returns 404 rather than 403 for private repositories the
  caller cannot see, to avoid leaking the existence of private repositories); a typo in the
  `application_id` (e.g., `my-org/my repo` with a literal space, or `MyOrg/myrepo` with mismatched case
  on a case-sensitive backend).
- **Remediation:** verify the `application_id` matches the canonical `org/repo` form per
  [Rule R7](../template.md#r7--application-identity-stability) and the `application_id` regex in
  [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) (`^[a-zA-Z0-9][a-zA-Z0-9._-]*\/[a-zA-Z0-9][a-zA-Z0-9._-]*$`);
  verify the token has access to the repository per § 4.2 / § 4.4 above. For GitHub, also confirm the
  organization name has not been changed (org renames preserve the redirect for the org's namespace but
  not necessarily for downstream API paths; see § 4.7 below).
- **Cell impact:** ALL FOUR cells for the affected application render `Insufficient Data`.

### 4.7 Repository Renamed

- **Symptoms:** the structured log records HTTP 301 or 302 redirect responses from
  `GET /repos/{old-org}/{old-repo}` (GitHub) or `GET /api/v4/projects/:id` (GitLab) when the API still
  honors the old name. After GitHub's redirect grace period expires, the old name returns 404 instead
  per § 4.6.
- **Causes:** the repository was renamed (or transferred to a different organization) since prior runs
  of the template; prior persistence records reference the old `application_id`.
- **Remediation:** per [`./grade-history.md`](./grade-history.md) § 2 Storage Key, the report author has
  TWO options:
  1. **Migrate prior records** — copy the prior records' `(facet, run_date, grade, ...)` values from the
     old `application_id` to the new `application_id`, preserving each run's date and grade. This
     preserves grade history continuity per [Rule R7](../template.md#r7--application-identity-stability)
     verification ("grade history for a repo is continuous across three sequential runs"). The migration
     procedure is itself a documented breach of the immutability contract per [Rule
     R3](../template.md#r3--grade-history-fidelity) and MUST be documented in
     [`../CHANGELOG.md`](../CHANGELOG.md) as a one-time corrective action with the rationale (the
     repository was renamed) and the affected `application_id` pair recorded.
  2. **Accept the discontinuity** — leave the old records untouched (immutability preserved) and let the
     new `application_id` start fresh with `prev: N/A` per [Rule R10](../template.md#r10--new-repo-compatibility).
     This is the lower-friction option and is appropriate when the prior history is not operationally
     critical; it preserves the immutability contract from
     [`./grade-history.md`](./grade-history.md) § 3 unconditionally.
- **Cell impact:** prior records remain immutable per [Rule R3](../template.md#r3--grade-history-fidelity)
  regardless of which option is chosen. The new `application_id` has no prior records on its first
  appearance and renders `prev: N/A` for all four facets in its first PDF row.

## 5. Rate-Limit Recovery

This section documents the rate-limit semantics for each of the five external APIs the template invokes
and the recovery procedure for each. Authoritative rate-limit values, retry semantics, and base URLs are
documented in [`./api-integrations.md`](./api-integrations.md); this section is the operational runbook
the report author follows when a rate-limit-induced failure occurs. Rate-limit failures that are
recovered transparently (via the documented retry semantics) do NOT surface as `Insufficient Data` cells;
only persistent rate-limit failures (where all retries have been exhausted) do.

### 5.1 GitHub Rate Limit (5,000/hour)

- **Symptoms:** `HTTP 403 API rate limit exceeded for user ID <id>` from `api.github.com`; the response
  carries `X-RateLimit-Remaining: 0` and `X-RateLimit-Reset: <unix-epoch-seconds>` headers.
- **Recovery (automatic):** the template sleeps until the timestamp in `X-RateLimit-Reset` and then
  retries the failed request. The sleep duration is at most 1 hour (the GitHub rate-limit window). The
  template implements this automatically per [`./api-integrations.md`](./api-integrations.md) § 2.7.
- **Operational guidance:** large run scopes (more than approximately 20 repositories with deep
  histories) MAY exhaust the 5,000 / hour budget. Mitigation options:
  - **Schedule runs during off-peak hours** to avoid contending with other automation that shares the
    PAT.
  - **Use a GitHub App installation token** instead of a PAT; installation tokens have higher
    per-installation rate limits (currently 15,000 / hour per repository).
  - **Reduce the run scope** by excluding repositories from low-priority portions of the portfolio per
    [`./usage.md`](./usage.md) § 4.5.
  Persistent failures across the rate-limit window expiry constitute application-level failures per
  § 4.1; the affected applications' cells render `Insufficient Data`.

### 5.2 GitLab Rate Limit (2,000/min)

- **Symptoms:** `HTTP 429 Too Many Requests` from `gitlab.com/api/v4` (or the configured self-hosted
  GitLab); the response carries a `Retry-After: <seconds>` header.
- **Recovery (automatic):** the template sleeps for the indicated number of seconds and then retries
  the failed request. The sleep duration is at most 60 seconds (the GitLab rate-limit window). The
  template implements this automatically per [`./api-integrations.md`](./api-integrations.md) § 3.7.
- **Operational guidance:** the GitLab.com rate limit (2,000 requests per minute per user) is
  substantially higher than GitHub's per-user limit and is rarely exhausted by typical run scopes;
  self-hosted GitLab installations MAY have lower configured limits. If persistent rate-limit failures
  occur, consult the affected GitLab installation's administrator for the configured limits and consider
  scheduling adjustments. Persistent failures constitute application-level failures per § 4.3.

### 5.3 NVD Rate Limit (5/30s without key, 50/30s with key)

- **Symptoms:** `HTTP 429` from `services.nvd.nist.gov`; the response indicates rate-limit exhaustion.
- **Recovery (automatic):** the template sleeps for 30 seconds (one rate-limit window) and retries the
  failed request, up to a maximum of 3 retries. After 3 retries the failure is considered persistent and
  the NVD source is treated as unreachable per [§ 2 Failure-Mode-to-Cell-Value
  Mapping](#2-failure-mode-to-cell-value-mapping); the run continues with OSV-only sources per
  [Rule R9](../template.md#r9--cve-attribution).
- **Strong recommendation:** provision `NVD_API_KEY` for any run scope with more than approximately 20
  unique CPEs (Common Platform Enumerations — the per-component identifiers the CVE pipeline queries).
  Without the key, the NVD CVE API enforces a 5 requests / 30-second window limit; large run scopes will
  hit this limit repeatedly, and the cumulative 30-second-per-window sleep can add many minutes to the
  total scan time. With the key, the limit rises to 50 requests / 30-second window, an order-of-magnitude
  improvement that typically eliminates rate-limit-induced sleeps for run scopes up to several hundred
  repositories. Per [`./api-integrations.md`](./api-integrations.md) §§ 5.4 and 5.6.

### 5.4 OSV Rate Limit

- **Symptoms:** OSV does not publish a numeric rate limit per [`./api-integrations.md`](./api-integrations.md)
  § 6.6; under aggressive scanning the API MAY return HTTP 5xx or transient network errors.
- **Recovery (automatic):** the template applies exponential backoff (1 second, 2 seconds, 4 seconds;
  maximum 3 retries) for transient OSV failures. Persistent failures across all retries are considered
  hard failures and the OSV source is treated as unreachable; the run continues with NVD-only sources
  per [Rule R9](../template.md#r9--cve-attribution), or surfaces `Insufficient Data` if NVD is also
  unreachable.
- **Operational guidance:** prefer the batched endpoint `POST /v1/querybatch` over the per-package
  endpoint `POST /v1/query` per [`./api-integrations.md`](./api-integrations.md) § 6.8. The batched
  endpoint accepts up to 1,000 queries in a single request and is approximately 3× faster than the
  per-package endpoint per the latency improvements documented in
  [`./api-integrations.md`](./api-integrations.md) § 6.7. Using the batched endpoint reduces the total
  request count and minimizes the probability of hitting transient-failure conditions.

### 5.5 endoflife.date Politeness

- **Symptoms:** endoflife.date does not publish a numeric rate limit, but the API is implemented as
  static JSON via CDN; under aggressive scanning the CDN MAY return HTTP 5xx responses or unusually slow
  response times.
- **Recovery (automatic):** the template applies a 1-second pacing between sequential requests per
  [`./api-integrations.md`](./api-integrations.md) § 4.6; this is the canonical politeness convention
  and is configured via `facets.maturity.request_pacing_seconds` in
  [`../config/facets.yaml`](../config/facets.yaml). Transient failures retry up to 3 times with
  exponential backoff (1 second, 2 seconds, 4 seconds).
- **Operational guidance:** the endoflife.date API is unauthenticated and free per
  [`./api-integrations.md`](./api-integrations.md) § 4. It is also a Beta API with breaking-change risk
  per the beta-status caveat in [`./api-integrations.md`](./api-integrations.md) § 4. If the API
  experiences a breaking change between runs, the template's Maturity facet MAY surface `Insufficient
  Data` for affected products until [`./api-integrations.md`](./api-integrations.md) is updated to the
  new contract; reviewers MUST inspect the structured log for `severity: warning` events from the
  `maturity-analyzer` component to detect this case.

## 6. Manifest Parse Errors

This section documents the manifest-parse-error failure mode for the Maturity and Security facets and
the per-manifest resilience rule that prevents a single corrupt manifest from aborting the entire facet.

### 6.1 Corrupt or Malformed Manifests

- **Symptoms:** the structured log records `severity: warning` events with a parser exception payload
  (e.g., `json.JSONDecodeError`, `xml.etree.ElementTree.ParseError`, `yaml.YAMLError`, or
  `tomllib.TOMLDecodeError`) and the affected manifest's path.
- **Causes:** hand-edited manifests with syntax errors (missing brackets, trailing commas, unbalanced
  quotes); merge conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) committed accidentally; binary
  content in a text file (e.g., a Git LFS pointer that should have been resolved before commit);
  encoding issues (UTF-8 BOM in a file the parser does not tolerate, or a file saved as UTF-16 instead
  of UTF-8).
- **Detection scope:** manifest parsing is performed by both the Maturity facet (which extracts library
  and runtime versions) and the Security facet (which feeds the SBOM generation pipeline per
  [`./facets.md`](./facets.md) § Security Summary § SBOM Generation). A single corrupt manifest may
  affect both facets simultaneously.

### 6.2 Per-Manifest Resilience

A single corrupt manifest does **NOT** abort the entire facet for the affected application. The Maturity
and Security facets continue processing the other manifests in the same repository; the failed manifest
is recorded in the per-facet `raw_data.parse_failures[]` list per
[`./facets.md`](./facets.md) § Maturity Summary and § Security Summary. The structured log records one
`severity: warning` event per failed manifest with the manifest path and the parser exception text.

This resilience is operationally important for monorepos and multi-language repositories where one
ecosystem's lockfile may be corrupted while the others remain valid; the report still produces a useful
grade for the un-affected ecosystems and surfaces the corrupt manifest's path so the report author can
fix it offline.

### 6.3 Full-Failure Threshold

If **ALL** manifests in a repository fail to parse, the affected facet renders `Insufficient Data` per
[§ 2 Failure-Mode-to-Cell-Value Mapping](#2-failure-mode-to-cell-value-mapping) above. The threshold is
unambiguous: zero successful manifest parses for a facet's data sources means the facet has no input
data and Rule R2 mandates the `Insufficient Data` rendering.

The full-failure threshold applies independently per facet. A repository with all `package.json` files
corrupted but a valid `pom.xml` MAY produce a Maturity grade from the Java ecosystem alone, while the
Security facet (which depends on the SBOM pipeline) MAY also produce a grade if the Maven CycloneDX
generator succeeds where the npm generator failed. Reviewers diagnosing a repository-wide
`Insufficient Data` for one facet but not another SHOULD inspect the per-facet
`raw_data.parse_failures[]` list per [§ 9.2 Reproducing a Failure](#92-reproducing-a-failure) below.

### 6.4 Recommendation

Authors of repositories with frequent manifest parse failures SHOULD add a manifest-validation CI step
at PR-time so corrupt manifests are caught before merge. The template **does NOT** modify the source
repository; the corrective action is the responsibility of the repository's author. Common
manifest-validation tools include:

- `npx package-json-validator` for `package.json`
- `python -m json.tool < <file>` for any JSON manifest
- `pip-compile --dry-run` or `pip check` for `requirements.txt` (which is line-format and
  validates differently from JSON)
- `mvn validate` for `pom.xml`
- `gradle dependencies` (dry-run) for `build.gradle`
- `dotnet restore --no-cache` (dry-run) for `.csproj`
- `go mod verify` for `go.mod`
- `cargo verify-project` for `Cargo.toml`
- `bundle check --dry-run` for `Gemfile.lock`

Per the Boundaries & Preservation contract in [`../template.md`](../template.md) § 4, this template does
not author or modify CI configurations in the ingested repositories; the recommendation here is offered
to repository authors as a downstream remediation rather than as a template responsibility.

## 7. SBOM Generation Failures

This section documents the SBOM-generation-failure modes for the Security facet and the per-ecosystem
resilience rule that prevents a single ecosystem's generator failure from aborting the entire Security
facet.

### 7.1 Per-Ecosystem Generator Failures

Each ecosystem (npm, pip, Maven, Gradle, .NET, Go, Cargo, RubyGems, etc.) uses its own CycloneDX
generator per [`./facets.md`](./facets.md) § Security Summary § SBOM Generation. A failure of one
ecosystem's generator does NOT abort the entire Security facet; the Security facet continues with the
SBOMs produced by the other ecosystems present in the same repository.

Per-ecosystem generator failures are recorded in the structured log as `severity: warning` events with
the ecosystem name (`npm`, `pip`, `maven`, `gradle`, `dotnet`, `go`, `cargo`, `ruby`, etc.), the
generator command that failed, and the generator's stderr output. The events are also recorded in the
Security facet's `raw_data.sbom_failures[]` list for inclusion in the persistence record per
[`./facets.md`](./facets.md) § Security Summary § Raw Data.

### 7.2 Multi-Ecosystem Repositories

For repositories with multiple ecosystems (typical of monorepos and microservice meta-repositories), the
**partial-success outcome is the norm**, not an exception. Successful ecosystem generators contribute
their components to the consolidated SBOM; failed generators are recorded in
`raw_data.sbom_failures[]` and the Security facet's CVE counts reflect only the components from
successful generators. The Security cell renders a normal grade (one of `A`, `B`, `C`, `D`, `F`) as long
as AT LEAST ONE ecosystem generator succeeded AND the downstream CVE pipeline (NVD or OSV) was reachable
per [§ 5.3 NVD Rate Limit](#53-nvd-rate-limit-530s-without-key-5030s-with-key) and [§ 5.4 OSV Rate
Limit](#54-osv-rate-limit) above.

Reviewers MUST be aware that the Security grade in this partial-success case reflects the **partial
SBOM**, NOT the full repository: an `A` grade for Security with `raw_data.sbom_failures[]` listing the
npm generator means "no Critical/High CVEs in the components the generator could enumerate," not "no
Critical/High CVEs in the whole repository." Reviewers SHOULD inspect `raw_data.sbom_failures[]` when
assessing the cell's confidence, and remediate the failed generator(s) before relying on the grade for
high-stakes decisions.

### 7.3 Universal Failure (cdxgen Fallback)

When per-ecosystem generators fail entirely (every ecosystem present in the repository produces a
failed SBOM), the multi-language fallback `cdxgen` per [`./facets.md`](./facets.md) § Security Summary
MAY produce a coarser SBOM by analyzing the source tree directly rather than parsing
ecosystem-specific lockfiles. The fallback is invoked automatically by the Security facet pipeline
when all per-ecosystem generators have failed.

If `cdxgen` also fails (e.g., due to source-tree complexity exceeding the fallback's capacity, or due
to runtime errors in the fallback itself), the repository's Security facet renders
`Insufficient Data` per [§ 2 Failure-Mode-to-Cell-Value
Mapping](#2-failure-mode-to-cell-value-mapping). The cdxgen-fallback failure is recorded in
`raw_data.sbom_failures[]` with the entry `ecosystem: cdxgen-fallback` to distinguish it from
per-ecosystem failures.

### 7.4 Common Failure Causes

The following are the most frequently observed causes of SBOM-generation failures across ecosystems.
Each cause has its own remediation; reviewers diagnosing a Security `Insufficient Data` cell SHOULD
inspect the structured log's SBOM-failure events first to identify which cause applies.

- **Missing build artifacts** — many CycloneDX generators (notably the Maven plugin and the .NET tool)
  require the project to be built before SBOM generation can succeed. A project ingested without its
  `target/` directory (Maven) or without `bin/`/`obj/` directories (.NET) MAY fail the SBOM step. The
  template does NOT attempt to build ingested projects; the build is the responsibility of the
  repository's CI pipeline.
- **Lockfile out of sync with manifest** — when `package-lock.json` references packages not in
  `package.json`, or when `Gemfile.lock` references gems not in `Gemfile`, the SBOM generator MAY abort
  rather than emit a partial SBOM. The remediation is to regenerate the lockfile in the ingested
  repository (`npm install`, `bundle install`, etc.) and re-run the template.
- **Non-public dependencies the generator cannot resolve** — when a project depends on packages from
  a private registry (an internal Artifactory, a corporate npm registry, a private GitHub Packages
  feed) that the SBOM generator cannot access without authentication, the SBOM generator MAY fail or
  produce a partial SBOM. The template does not provision private-registry credentials; if private
  dependencies are unavoidable, the repository's CI pipeline should generate the CycloneDX SBOM in
  advance and commit it to the repository as a `.cdx.json` artifact, which the template will consume
  in preference to running the generator from source.
- **Generator version drift** — when the SBOM generator's pinned version (per
  [`./api-integrations.md`](./api-integrations.md) § SBOM Generation) is out of step with the
  manifest format the repository uses (e.g., a newer `package-lock.json` lockfile version 3 vs. an
  older generator that supports only version 2), the generator MAY fail with an unsupported-format
  error. The remediation is to update the generator pin in
  [`./api-integrations.md`](./api-integrations.md) and re-run the template.

## 8. Output and Logging

This section documents the structured-log conventions the template emits and the no-silent-suppression
rule that binds Gate 2 to the structured log.

### 8.1 Run Log Format

The template emits structured logs as **newline-delimited JSON** (sometimes called "JSONL" or "ndjson")
per the convention documented in [`./architecture.md`](./architecture.md) § Component Boundaries. One
JSON record is emitted per significant event; each record includes at minimum the following fields:

- **`timestamp`** — ISO 8601 datetime in UTC (e.g., `2025-10-01T12:34:56.789Z`).
- **`severity`** — one of `error`, `warning`, `info`, `debug`. The validation harness's Gate 2 assertion
  (per [`./validation.md`](./validation.md) § Gate 2) inspects all `severity: warning` and
  `severity: error` records.
- **`component`** — the analysis component emitting the record (one of `tech-stack-detector`,
  `maturity-analyzer`, `cve-scanner`, `complexity-extractor`, `grading-engine`,
  `grade-persistence-store`, `pdf-renderer`, or `template-orchestrator`). The component names mirror the
  seven analysis components enumerated in [`../template.md`](../template.md) § 7 Architecture &
  Component Reachability.
- **`application_id`** — the `org/repo` identifier of the repository being processed (when applicable;
  template-orchestrator events MAY omit this field for run-level events).
- **`facet`** — the facet identifier (when applicable; one of `tech_stack`, `maturity`, `security`,
  `complexity`).
- **`run_date`** — the ISO 8601 datetime of the run that emitted the record. This matches the
  `run_date` field of the corresponding persistence records per
  [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.run_date`.
- **`event_type`** — a short event identifier (e.g., `manifest_parse_failed`, `cve_lookup_succeeded`,
  `rate_limit_retry`, `grade_emitted`). The full event-type vocabulary is documented in
  [`./architecture.md`](./architecture.md) § Component Boundaries.
- **`message`** — a human-readable description of the event.
- **Additional event-specific fields** — e.g., `http_status`, `retry_attempt`, `manifest_path`,
  `package_name`, `cve_id`, depending on the event type.

A representative `severity: warning` record from a Security facet CVE-lookup retry:

```text
{
  "timestamp": "2025-10-01T12:34:56.789Z",
  "severity": "warning",
  "component": "cve-scanner",
  "application_id": "acme-inc/acme-api",
  "facet": "security",
  "run_date": "2025-10-01T12:00:00Z",
  "event_type": "rate_limit_retry",
  "message": "NVD rate limit hit; retrying after 30s",
  "http_status": 429,
  "retry_attempt": 1
}
```

### 8.2 No Silent Suppression Per Gate 2

Per [Gate 2](../template.md#612-gate-2--zero-warning-build), every error, warning, or unexpected
condition encountered during a run MUST appear in the structured log AND, when the condition affects a
matrix cell, MUST also surface in the rendered PDF as an `Insufficient Data` cell per
[§ 2 Failure-Mode-to-Cell-Value Mapping](#2-failure-mode-to-cell-value-mapping). The grading engine,
the facet analyzers, and the PDF renderer MUST NOT swallow exceptions silently; every caught
exception is either:

- **Recoverable** — the operation retries per [§ 5 Rate-Limit Recovery](#5-rate-limit-recovery), and
  the failure is recorded as `severity: warning` with `event_type` indicating the retry; OR
- **Persistent** — the operation has exhausted all retries OR encountered a non-recoverable error
  (e.g., HTTP 401, schema validation failure), and the failure is recorded as `severity: error` AND the
  affected matrix cell renders `Insufficient Data` (or, for application-level failures, all four cells
  render `Insufficient Data` per [§ 2.1](#21-distinction-facet-level-vs-application-level-insufficient-data)).

A `severity: warning` record without a corresponding `Insufficient Data` cell is **acceptable** when
the warning was followed by a successful retry — the recoverable path. A `severity: error` record
without a corresponding `Insufficient Data` cell is **a Gate 2 violation** — the persistent path
silently dropped the failure rather than surfacing it.

### 8.3 Reviewer Procedure

After every run, the reviewer SHOULD perform the following discoverability check to verify Gate 2
compliance:

1. **Locate the structured log** at the path emitted by the run (default
   `~/blitzy-reports/structured.log.jsonl`; configurable per [`./usage.md`](./usage.md) § 6.3).
2. **Filter for non-info events:**

   ```bash
   jq 'select(.severity == "warning" or .severity == "error")' \
     ~/blitzy-reports/structured.log.jsonl
   ```

3. **For each `severity: error` record**, locate the corresponding cell in the rendered PDF using
   `(application_id, facet)` from the record. Confirm the cell renders `Insufficient Data` (or, for
   application-level failures, all four cells of the application's row). Discrepancies (an error
   record without a visible `Insufficient Data` cell) indicate a Gate 2 violation; the reviewer
   captures the offending log record's identifier and the PDF cell coordinate for remediation.
4. **For each `severity: warning` record**, confirm one of the following: (a) a subsequent record for
   the same `(application_id, facet, event_type)` records a successful retry (the warning was
   transient), OR (b) the corresponding cell renders `Insufficient Data` (the warning was the final
   step before persistence). A warning without either conclusion indicates a silent suppression and
   is also a Gate 2 violation.
5. **For runs with no `severity: warning` or `severity: error` records**, Gate 2 passes trivially. Note
   that this trivial pass implies no failure modes were exercised by the test repository scope;
   reviewers MAY choose to run validation against a deliberately failure-inducing scope to exercise
   the `Insufficient Data` rendering path per [`./validation.md`](./validation.md) § Gate 2 § Counter-Example.

The Gate 2 verification procedure is the canonical realization of the no-silent-suppression rule; the
underlying contract is documented verbatim in [`../template.md`](../template.md) § 6.1.2.

## 9. Diagnostic Runbooks

This section documents the three operational runbooks the report author follows when diagnosing a
failure: locating a smoke-test repository, reproducing a specific cell's `Insufficient Data` rendering,
and reporting a previously-undocumented failure mode.

### 9.1 Smoke Test Repository Pointer

For Gate 1 Live Smoke Test per [`./validation.md`](./validation.md) § Gate 1, use a small designated
test repository with deterministic content. The recommended properties of a smoke-test repository are:

- **Public** — to avoid token-scope variability and to keep the smoke test reproducible across reviewers
  without coordinating private-access permissions.
- **Small but realistic** — at least one source file, at least one dependency manifest in a supported
  ecosystem, and OPTIONALLY at least one IaC configuration file.
- **At least one CVE-affected dependency in the lockfile** — to exercise the CVE Scanner end-to-end.
  Without this property, the Security facet cannot demonstrate non-zero severity-tier counts and
  Gate 1's "at least one graded cell" criterion may rely solely on Tech Stack and Maturity grades.

The exact test-repository pointer for the package's validation harness is captured in
[`../config/facets.yaml`](../config/facets.yaml) under the configurable convention key
`validation.gate1_test_repo`; when that key is absent, the validator defaults to the most minimal
smoke-test target. The trade-off of using a minimal target (e.g., `octocat/Hello-World`) is that it
has no dependency manifest and therefore exercises only the Tech Stack and Complexity facets; Maturity
and Security cells will render `Insufficient Data` because the underlying data sources (manifests for
EOL lookup, manifests for SBOM generation) are absent. Reviewers running Gate 1 against the minimal
target SHOULD treat the partial cell population as expected and validate the at-least-one-graded-cell
criterion against the Tech Stack or Complexity columns.

### 9.2 Reproducing a Failure

To reproduce an `Insufficient Data` cell from a recent run for diagnostic purposes:

1. **Identify the `(application_id, facet, run_date)` triple** from the persistence record. The
   `application_id` is the row label in the PDF (`org/repo`); the `facet` is the column label
   (`tech_stack`, `maturity`, `security`, or `complexity`); the `run_date` is the date in the PDF's
   header or footer (the canonical run-date capture is in [`./usage.md`](./usage.md) § 6.5 Run Date
   Capture).
2. **Inspect the structured log** for events matching the triple. Filter the log for the affected
   `(application_id, facet)` pair:

   ```bash
   jq --arg app "acme-inc/acme-api" --arg facet "security" \
     'select(.application_id == $app and .facet == $facet)' \
     ~/blitzy-reports/structured.log.jsonl
   ```

3. **Re-run the template with verbose logging** enabled and a single-repository scope containing only
   the affected `application_id`, per [`./usage.md`](./usage.md) § 9.2 (Verbose Logging — When to Use
   Debug):

   ```bash
   export BLITZY_LOG_LEVEL=debug
   blitzy invoke templates/technology-estate-report \
     --rubric ~/rubrics/portfolio-rubric.yaml \
     --scope ~/scopes/single-repo.yaml \
     --output ~/reports/diagnosis.pdf
   ```

   The `BLITZY_LOG_LEVEL=debug` environment variable is the canonical verbose-logging switch
   documented in [`./usage.md`](./usage.md) § 9.1 Log Levels. Debug-level logging adds per-API-call
   traces, per-record persistence events, and grading-engine evaluation traces; these are voluminous
   but necessary for cell-level diagnosis.
4. **Cross-reference the failure mode** against [§ 2 Failure-Mode-to-Cell-Value
   Mapping](#2-failure-mode-to-cell-value-mapping) above to confirm the correct classification.
   Common reproduction outcomes:
   - **Rate-limit-induced** — the debug log shows repeated `rate_limit_retry` events; remediate per
     [§ 5](#5-rate-limit-recovery) (typically by provisioning `NVD_API_KEY` for NVD failures).
   - **Manifest parse error** — the debug log shows `manifest_parse_failed` events with a manifest
     path; remediate by fixing the manifest in the source repository per [§ 6.4
     Recommendation](#64-recommendation).
   - **Authentication failure** — the debug log shows `http_status: 401` or `403` events; remediate
     per [§ 4 Common Authentication Failures](#4-common-authentication-failures).
   - **No source data** — the debug log shows the affected facet's analyzer emitted zero records
     (e.g., the Maturity analyzer found zero manifest files); remediate by confirming the repository
     actually contains the expected data sources, or accept the `Insufficient Data` rendering as a
     true reflection of unavailable data per [Rule R2](../template.md#r2--facet-completeness).
5. **Apply the documented remediation** and re-run the full run scope. If the cell still renders
   `Insufficient Data` after remediation, the failure mode may be a previously-undocumented
   condition; proceed to [§ 9.3 Reporting a New Failure
   Mode](#93-reporting-a-new-failure-mode) below.

### 9.3 Reporting a New Failure Mode

If a failure mode is encountered that is NOT in [§ 2 Failure-Mode-to-Cell-Value
Mapping](#2-failure-mode-to-cell-value-mapping), this is a documentation gap and the new mode MUST be
added to this document. The reviewer SHOULD:

1. **Capture the structured log lines** that record the failure, including the `severity`,
   `component`, `event_type`, `message`, and any additional event-specific fields. Save them to a file
   for inclusion in the documentation update PR.
2. **Capture the cell rendering** in the affected PDF. Note the cell coordinate (row label = `org/repo`,
   column label = facet display name) and the literal text rendered in the cell.
3. **Open a PR** adding the new failure mode to [§ 2 Failure-Mode-to-Cell-Value
   Mapping](#2-failure-mode-to-cell-value-mapping) above. The PR MUST include:
   - A new row in the table with the five canonical columns (Facet, Failure Mode, Detection Signal,
     Cell Value, Persistence `grade`).
   - An entry in [`../CHANGELOG.md`](../CHANGELOG.md) recording the addition with the date, the
     PR number, and the rationale.
   - When the new failure mode requires a new `event_type` in the structured log, an addition to
     [`./architecture.md`](./architecture.md) § Component Boundaries documenting the new
     `event_type`.
4. **Verify the documentation update** renders correctly via a Markdown preview before merging the PR.

The PR review process is governed by the documentation-quality criteria in the AAP § 0.7.2 Documentation
Quality Criteria; reviewers SHOULD confirm that the new failure mode does not duplicate an existing row
(per the AAP § 0.10.2 "No Redundancy Rule") and that the cell value choice is consistent with the
distinctions in [§ 2.1](#21-distinction-facet-level-vs-application-level-insufficient-data),
[§ 2.2](#22-distinction-tbd-vs-insufficient-data-for-complexity), and
[§ 2.3](#23-distinction-na-vs-insufficient-data) above.

## 10. Cross-References

This document references the following package-internal artifacts. Every link is a relative path
**within** [`templates/technology-estate-report/`](..); no link reaches outside this directory per the
standalone-package property of [`../template.md`](../template.md) § 4 Boundaries & Preservation.

- [`../template.md`](../template.md) — canonical, verbatim
  [Rules R2](../template.md#r2--facet-completeness), [R5](../template.md#r5--complexity-placeholder-integrity),
  [R6](../template.md#r6--saas-data-sourcing), [R7](../template.md#r7--application-identity-stability),
  [R9](../template.md#r9--cve-attribution), and [R10](../template.md#r10--new-repo-compatibility);
  canonical, verbatim [Gate 2](../template.md#612-gate-2--zero-warning-build).
- [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) — the `grade` enum
  including `InsufficientData`, `TBD`, and `N/A`; the `application_id` regex (Rule R7); the
  `scan_metadata` security-attribution conditional (Rule R9).
- [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) — the rubric document JSON Schema;
  malformed-rubric failure mode references this schema for validation.
- [`../config/facets.yaml`](../config/facets.yaml) — the per-facet feature flags, the
  `severity_tier_labels`, the `validation.gate1_test_repo` smoke-test pointer, and the
  `facets.maturity.request_pacing_seconds` endoflife.date pacing convention.
- [`../CHANGELOG.md`](../CHANGELOG.md) — versioned record of failure-mode additions and other
  documentation changes per [§ 9.3 Reporting a New Failure
  Mode](#93-reporting-a-new-failure-mode).
- [`./facets.md`](./facets.md) — per-facet Insufficient Data conditions, per-facet `raw_data` shapes,
  CVSS-to-severity-tier mapping, SBOM generation per ecosystem, and Maturity product-slug resolution.
- [`./grading-engine.md`](./grading-engine.md) — rubric validation, the F catch-all rule for
  unmatched-rubric-with-data, and the Complexity Lock contract per Rule R5.
- [`./grade-history.md`](./grade-history.md) — storage key shape, immutability contract, and the
  `N/A` rendering rule for first-run pairs.
- [`./pdf-output.md`](./pdf-output.md) — the canonical Cell Rendering Format consumer, including the
  `Insufficient Data` cell layout (suppressed prior-grade segment) and the
  `Grade: TBD — definition pending` Complexity placeholder layout.
- [`./api-integrations.md`](./api-integrations.md) — base URLs, authentication, rate-limit semantics,
  and HTTP error response codes for each external API (GitHub, GitLab, endoflife.date, NVD, OSV);
  R6 network-egress allow-list; R9 attribution rule.
- [`./architecture.md`](./architecture.md) — component log conventions, the `event_type` vocabulary,
  and the seven-component reachability matrix referenced by Gate 9.
- [`./usage.md`](./usage.md) — credential provisioning runbooks, verbose-logging instructions
  (`BLITZY_LOG_LEVEL=debug`), the run-scope conventions, and the run-date capture procedure.
- [`./validation.md`](./validation.md) — Gate 1 Live Smoke Test, Gate 2 zero-warning contract
  (which inspects the structured log per [§ 8.3 Reviewer Procedure](#83-reviewer-procedure) above),
  and the single-command execution path.
