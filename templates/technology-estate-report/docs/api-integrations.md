# External API Integrations — Technology Estate Report Template

## 1. Overview

The Technology Estate Report Blitzy prompt template is a **read-only consumer** of exactly five external services:
**GitHub** (source repository ingestion), **GitLab** (source repository ingestion), **endoflife.date** (Maturity facet
EOL lookup), **NVD CVE API v2.0** (Security facet primary CVE source), and **OSV API v1** (Security facet alternate /
cross-reference CVE source). All other outbound network calls are **forbidden** per
[Rule R6 in `../template.md` § 5](../template.md#r6--saas-data-sourcing). Specifically, live SaaS vendor API calls
(Salesforce, ServiceNow, Workday, Zendesk, Slack admin APIs, Atlassian APIs, Okta APIs, and any other SaaS vendor
endpoint) are **NOT permitted in v1**; SaaS license data MUST be sourced exclusively from manifests tracked in the
ingested repository (`package.json`, `requirements.txt`, `pom.xml`, `go.mod`, `Gemfile`, `Pipfile`, `build.gradle`,
`.csproj`, `Cargo.toml`, plus repository-tracked SaaS-config files such as `.salesforce.json` if present).

The **network-egress allow-list** in [`../config/allow-list.yaml`](../config/allow-list.yaml) is the canonical
machine-readable control surface that enforces Rule R6 — see [§ 7 Network Egress Allow-List
(Rule R6)](#7-network-egress-allow-list-rule-r6) below for the human-readable form. Every external dependency in this
document is documented with its base URL, authentication method, rate limit, retry semantics, version-of-record, and
endpoint inventory. Per the AAP § 0.10.2 "Citation Inline Rule," this document is the **canonical home** of all external
API URLs and contract details for the package; other documents reference this file rather than duplicate the URLs.

Per [Rule R9 in `../template.md` § 5](../template.md#r9--cve-attribution), every Security Summary result emitted by the
CVE Scanner (which uses NVD and OSV) MUST carry the scan timestamp (ISO 8601) and the source database label
(`NVD`, `OSV`, or both). The structural shape of this attribution is encoded in
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.scan_metadata`, and the
operational rules for Security cell rendering and edge cases are documented in
[§ 8 R9 Attribution Rule](#8-r9-attribution-rule) below.

## 2. GitHub API

### 2.1 Purpose

The GitHub API is consumed for **source repository ingestion** — retrieval of repository artifacts (source files,
dependency manifests, IaC configurations, Dockerfiles, git log) for the four facet analyzers (Tech Stack, Maturity,
Security, Complexity) per [`../template.md` § 3.1 Ingestion](../template.md#31-ingestion). The template performs
**read-only** operations against the API; no `write`, `admin`, or `delete` operations are issued under any
circumstance.

### 2.2 Base URL

The base URL for the public GitHub.com API is:

```text
https://api.github.com
```

GitHub Enterprise Server installations use the form `<enterprise_host>/api/v3` for REST and
`<enterprise_host>/api/graphql` for GraphQL; the host portion is configured per the run-scope specification in
[`./usage.md`](./usage.md) § Run Scope Specification and is added to the network-egress allow-list in
[`../config/allow-list.yaml`](../config/allow-list.yaml) `allowed_hosts[id=github_api].host` for that deployment.

### 2.3 API Versions Used

The template uses **REST API v3** as the default for read endpoints and **GraphQL API v4** for bulk metadata queries
and rate-efficient batch retrieval. Both API versions are stable and covered by GitHub's published deprecation policy;
endpoint-level deprecation notices appear in the standard `Sunset` and `Deprecation` HTTP response headers per RFC
8594, and the template logs a `severity: warning` event when a deprecated endpoint is invoked.

### 2.4 Authentication

Authentication is required for every request. Two token types are supported:

- **Personal Access Token (PAT)** — classic or fine-grained; the token is passed in the `Authorization` HTTP header in
  the form `Authorization: Bearer <token>`. The token is provisioned at run time as the environment variable
  `GITHUB_TOKEN`; see [`./usage.md`](./usage.md) § Provisioning Credentials for the step-by-step provisioning runbook.
- **GitHub App installation token** — the token is passed in the same header form as a PAT. Installation tokens are
  preferred for high-volume run scopes because their per-installation rate limits are higher than per-user PAT limits.

The template **MUST NOT** be invoked without `GITHUB_TOKEN` set when the run scope contains GitHub repositories;
unauthenticated requests are rejected with HTTP 401 and surface as `Insufficient Data` per
[`./troubleshooting.md`](./troubleshooting.md) § 4.1.

### 2.5 Required Scopes

The minimum set of GitHub OAuth scopes required by the template:

- **Classic PAT:** `repo` (read access to repositories in the run scope, including private repositories the report
  author has access to).
- **Fine-grained PAT:** `Contents: Read-only` plus `Metadata: Read-only` for each repository in the run scope.

No `write`, `admin`, `delete`, `workflow`, or `packages` scopes are required and the template **MUST NOT** be invoked
with a token that grants any write or admin scope (defense-in-depth against credential mishandling).

### 2.6 Rate Limits

GitHub enforces the following authenticated per-user rate limits as of API v3 / v4:

- **REST API v3:** 5,000 requests per hour per authenticated user.
- **GraphQL API v4:** 5,000 points per hour, where each query consumes a variable number of points based on the size of
  the requested object graph (typically 1–10 points per query for repository-metadata queries).

The typical request budget per repository for a single run is approximately 6–10 REST requests plus 1 GraphQL query —
metadata, tree, contributors, and per-manifest content fetches. A 100-repository run scope typically consumes
600–1,000 REST requests, well within the 5,000 / hour budget. Run scopes exceeding 500 repositories SHOULD use a GitHub
App installation token (per § 2.4) or be split across multiple runs to remain within the rate-limit budget.

### 2.7 Retry Semantics

The template treats HTTP responses according to the following table:

| HTTP Status | Condition | Retry Behavior |
|---|---|---|
| 200, 201, 304 | Success or not-modified | Proceed |
| 403 with `X-RateLimit-Remaining: 0` | Rate limit exceeded (legacy GitHub form) | Sleep until `X-RateLimit-Reset` header (Unix epoch seconds), then retry |
| 429 | Rate limit exceeded (modern HTTP form) | Sleep until `X-RateLimit-Reset` header (Unix epoch seconds), then retry |
| 502, 503, 504 | Transient server error | Exponential backoff (1s, 2s, 4s, 8s; max 4 retries; jitter ±10%) |
| 401 | Authentication failure | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.1 |
| 403 (without rate-limit headers) | Insufficient scope | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.2 |
| 404 | Repository not found / not accessible | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.6 |
| Other 4xx | Malformed request | Do NOT retry; surface as `Insufficient Data` |

Per [Gate 2 in `../template.md` § 6.1.2](../template.md#612-gate-2--zero-warning-build), every persistent failure
surfaces as an explicit `Insufficient Data` cell — silent omission is a failing state.

### 2.8 Endpoints Used

| Endpoint | Purpose | Consumed By |
|---|---|---|
| `GET /repos/{org}/{repo}` | Repository metadata (default branch, language stats, archived status) | Tech Stack, Maturity, Security, Complexity |
| `GET /repos/{org}/{repo}/git/trees/{branch}?recursive=1` | Full file listing | Tech Stack, Maturity, Security, Complexity |
| `GET /repos/{org}/{repo}/contents/{path}` | File contents (manifests, IaC files, source files) | Tech Stack, Maturity, Security |
| `GET /repos/{org}/{repo}/contributors` | Contributor count | Complexity |
| `GET /repos/{org}/{repo}/stats/contributors` | Alternate contributor enumeration with per-week aggregates | Complexity |

A representative request and response for the metadata endpoint:

```http
GET /repos/acme-inc/acme-api HTTP/1.1
Host: api.github.com
Authorization: Bearer <GITHUB_TOKEN>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
X-RateLimit-Limit: 5000
X-RateLimit-Remaining: 4999
X-RateLimit-Reset: 1759320000

{
  "id": 123456789,
  "name": "acme-api",
  "full_name": "acme-inc/acme-api",
  "default_branch": "main",
  "archived": false,
  "language": "TypeScript"
}
```

### 2.9 Reference Documentation

Authoritative GitHub REST API reference: `https://docs.github.com/en/rest`.
Authoritative GitHub GraphQL API reference: `https://docs.github.com/en/graphql`.

### 2.10 Token Verification Probe

The canonical operational command for verifying that a `GITHUB_TOKEN` is correctly provisioned and grants the required
read scope is the authenticated `GET /user` probe against the base URL documented in § 2.2. The canonical command form is:

```bash
curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
```

A successful probe returns the authenticated user's profile JSON with `login` and `id` keys. A `401 Unauthorized`
response indicates the token is invalid or expired; a `403 Forbidden` response indicates insufficient scope. This
command is referenced by:

- [`./usage.md`](./usage.md) § 3 Provisioning Credentials (token-provisioning workflow)
- [`./troubleshooting.md`](./troubleshooting.md) § 4.1 GitHub Token Invalid (HTTP 401) (diagnostic recovery)

For GitHub Enterprise Server installations, replace the `https://api.github.com` host portion with the
`<enterprise_host>/api/v3` base URL configured per § 2.2 and added to the network-egress allow-list per
[`../config/allow-list.yaml`](../config/allow-list.yaml) `allowed_hosts[id=github_api].host`.

### 2.11 Canonical Test Endpoint (Gate 8 Item 2)

The canonical request used by [Gate 8 Item 2 — API Contract Verification](./validation.md#44-item-2-api-contract-verification)
to verify the GitHub REST API contract is the repository-metadata endpoint against the well-known stable repository
`octocat/Hello-World`:

```text
GET https://api.github.com/repos/octocat/Hello-World
```

The response shape MUST contain the contract-documented top-level keys `id`, `name`, `full_name`, `default_branch`,
`archived`, and `language` (per the representative response in § 2.8). A response that lacks any of these keys, or
that returns a status other than `200 OK`, fails Gate 8 Item 2 and triggers a contract update per § 2.8.

## 3. GitLab API

### 3.1 Purpose

The GitLab API is consumed for **source repository ingestion** (the same purpose as GitHub per § 2.1) for repositories
hosted on GitLab.com or self-hosted GitLab instances. The template performs **read-only** operations against the API;
no write or admin operations are issued.

### 3.2 Base URL

The base URL for the public GitLab.com API is:

```text
https://gitlab.com/api/v4
```

Self-hosted GitLab Community Edition (CE) and Enterprise Edition (EE) installations use the form
`<gitlab_host>/api/v4`; the host portion is configured per the run-scope specification in
[`./usage.md`](./usage.md) and is added to the network-egress allow-list in
[`../config/allow-list.yaml`](../config/allow-list.yaml) `allowed_hosts[id=gitlab_api].host` for that deployment.

### 3.3 API Version Used

The template uses **REST API v4**. GitLab's REST API v4 is the current stable version; earlier versions (v3) are no
longer supported by GitLab and are not consumed by this template.

### 3.4 Authentication

Authentication is required for every request. Three token types are supported:

- **Personal Access Token (PAT)** — issued by an individual user; the token is passed in the `PRIVATE-TOKEN` HTTP header
  in the form `PRIVATE-TOKEN: <token>`. The token is provisioned at run time as the environment variable
  `GITLAB_TOKEN`; see [`./usage.md`](./usage.md) § Provisioning Credentials.
- **Project Access Token** — scoped to a single GitLab project; passed in the same header form.
- **Group Access Token** — scoped to a GitLab group hierarchy; passed in the same header form.

The template **MUST NOT** be invoked without `GITLAB_TOKEN` set when the run scope contains GitLab repositories.

### 3.5 Required Scopes

The minimum set of GitLab token scopes required by the template:

- **`read_api`** — read access to project metadata.
- **`read_repository`** — read access to repository tree and file contents.

No write scopes (`api`, `write_repository`, `sudo`) are required and the template MUST NOT be invoked with a token
that grants any write or admin scope.

### 3.6 Rate Limits

GitLab.com enforces the following default authenticated per-user rate limit:

- **GitLab.com:** 2,000 requests per minute per authenticated user.

Self-hosted GitLab CE/EE installations MAY have lower configured limits per the installation's `Application settings →
Network → User and IP rate limits` policy; the template treats the rate-limit response uniformly regardless of the
configured numeric limit (per § 3.7 below).

The typical request budget per repository for a single run is approximately 5–8 REST requests — project metadata, tree,
file contents, and contributors. A 100-repository run scope typically consumes 500–800 requests, well below the
2,000-per-minute budget on GitLab.com.

### 3.7 Retry Semantics

The template treats GitLab HTTP responses according to the following table:

| HTTP Status | Condition | Retry Behavior |
|---|---|---|
| 200, 201, 304 | Success or not-modified | Proceed |
| 429 with `Retry-After: <seconds>` | Rate limit exceeded | Sleep for the indicated number of seconds, then retry |
| 502, 503, 504 | Transient server error | Exponential backoff (1s, 2s, 4s, 8s; max 4 retries; jitter ±10%) |
| 401 | Authentication failure | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.3 |
| 403 | Insufficient scope | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.4 |
| 404 | Project not found / not accessible | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 4.6 |
| Other 4xx | Malformed request | Do NOT retry; surface as `Insufficient Data` |

### 3.8 Endpoints Used

| Endpoint | Purpose | Consumed By |
|---|---|---|
| `GET /projects/:id` | Project metadata (URL-encoded `org/repo` becomes the project id, e.g., `acme-inc%2Facme-api`) | Tech Stack, Maturity, Security, Complexity |
| `GET /projects/:id/repository/tree?recursive=true` | File listing | Tech Stack, Maturity, Security, Complexity |
| `GET /projects/:id/repository/files/:file_path/raw` | File contents | Tech Stack, Maturity, Security |
| `GET /projects/:id/repository/contributors` | Contributor count | Complexity |

The `:id` path segment is the URL-encoded project full path. For the repository `acme-inc/acme-api`, the path-encoded
form is `acme-inc%2Facme-api` (the `/` separator is encoded as `%2F` per RFC 3986). The numeric project ID MAY also be
used in place of the path-encoded form when known; the template prefers the path-encoded form for stability across
project transfers.

A representative request:

```http
GET /api/v4/projects/acme-inc%2Facme-api HTTP/1.1
Host: gitlab.com
PRIVATE-TOKEN: <GITLAB_TOKEN>
Accept: application/json
```

### 3.9 Reference Documentation

Authoritative GitLab REST API reference: `https://docs.gitlab.com/ee/api/`.

### 3.10 Token Verification Probe

The canonical operational command for verifying that a `GITLAB_TOKEN` is correctly provisioned and grants the required
read scopes is the authenticated `GET /api/v4/user` probe against the base URL documented in § 3.2. The canonical
command form for GitLab.com is:

```bash
curl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" https://gitlab.com/api/v4/user
```

A successful probe returns the authenticated user's profile JSON with `username` and `id` keys. A `401 Unauthorized`
response indicates the token is invalid or expired; a `403 Forbidden` response indicates insufficient scope. This
command is referenced by:

- [`./usage.md`](./usage.md) § 3.2 GitLab PAT (token-provisioning workflow)
- [`./troubleshooting.md`](./troubleshooting.md) § 4.3 GitLab Token Invalid (HTTP 401) (diagnostic recovery)

For self-hosted GitLab CE/EE installations, replace the `https://gitlab.com` host portion with your instance's base URL
(per § 3.2) and add the host to the network-egress allow-list per
[`../config/allow-list.yaml`](../config/allow-list.yaml) `allowed_hosts[id=gitlab_api].host` for that deployment.

### 3.11 Canonical Test Endpoint (Gate 8 Item 2)

The canonical request used by [Gate 8 Item 2 — API Contract Verification](./validation.md#44-item-2-api-contract-verification)
to verify the GitLab REST API contract is the project-metadata endpoint against a known-public GitLab.com project:

```text
GET https://gitlab.com/api/v4/projects/<known-public-project-id>
```

The `<known-public-project-id>` placeholder is the URL-encoded project ID of any public GitLab.com project (the
canonical form is `org%2Frepo`, e.g., `gitlab-org%2Fgitlab`). The response shape MUST contain the contract-documented
top-level keys `id`, `name`, `path_with_namespace`, `default_branch`, `archived`, and `visibility` per § 3.8. A
response that lacks any of these keys, or that returns a status other than `200 OK`, fails Gate 8 Item 2.

## 4. endoflife.date API v1

### 4.1 Purpose

The endoflife.date API v1 is consumed for **library and runtime end-of-life (EOL) status lookup** for the **Maturity
Summary facet**. The Maturity facet uses the API to determine, for each detected runtime and library version, whether
the version is currently supported by its vendor or is past its EOL date. The per-product EOL outcome feeds the
technical-debt score (`out_of_support_dependencies / total_tracked_dependencies`) per
[`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.technical_debt_score`, which the user-supplied rubric
then translates to an A–F Maturity grade per [Rule R1 in `../template.md` § 5](../template.md#r1--rubric-editability).

### 4.2 Base URL

The base URL for the endoflife.date API v1 is:

```text
https://endoflife.date/api/v1
```

The v1 path prefix is the documented stable path on the API site; see § 4.5 below for the beta-status caveat.

### 4.3 API Version Used

The template uses **API v1** at the `https://endoflife.date/api/v1/` path. The version pin is captured in the
machine-readable form in [`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.eol_lookup.api_version: v1`
and in [§ 10 Version Pinning Note](#10-version-pinning-note) below.

### 4.4 Authentication

**None required.** The endoflife.date API is open and unauthenticated; no API key, no OAuth flow, and no signed
request is required. No credential is provisioned for this API in any environment.

### 4.5 Beta Status Caveat

The endoflife.date API v1 is currently in **Beta**, and breaking changes may occur. The template treats the v1
contract as stable for the purpose of this package version (`v0.1.0`), but reviewers MUST be aware that a future
endoflife.date API release MAY introduce breaking changes that require updates to this document and to
[`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.eol_lookup.api_version`. The reference documentation
site for the v1 API is:

```text
https://endoflife.date/docs/api/v1/
```

When a breaking change is detected (e.g., the response shape changes, an endpoint moves, or the v1 path is deprecated
in favor of a v2), the package maintainer SHOULD update this document, the `facets.maturity.eol_lookup.api_version` pin
in [`../config/facets.yaml`](../config/facets.yaml), and record the change in
[`../CHANGELOG.md`](../CHANGELOG.md) per [§ 10 Version Pinning Note](#10-version-pinning-note) below.

### 4.6 Rate Limits

No published numeric rate limit. The endoflife.date API is implemented as static JSON files served via a CDN, so
practical rate limits are very high and a typical run scope (hundreds of products, single run) does not approach any
operational throttle. The template implements a defensive **1-second-between-requests** pacing convention when scanning
many products in sequence; this convention is configured via
[`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.request_pacing_seconds` and is documented in
[`./troubleshooting.md`](./troubleshooting.md) § 5.5 endoflife.date Politeness.

### 4.7 Retry Semantics

The template treats endoflife.date HTTP responses according to the following table:

| HTTP Status | Condition | Retry Behavior |
|---|---|---|
| 200, 304 | Success or not-modified | Proceed |
| 502, 503, 504 | Transient CDN error | Exponential backoff (1s, 2s, 4s; max 3 retries) |
| Network error / timeout | Transient transport failure | Exponential backoff (1s, 2s, 4s; max 3 retries) |
| 404 | Product not tracked by endoflife.date | Do NOT retry; record product as `eol_unknown` per [`./facets.md`](./facets.md) § Maturity Summary |
| Other 4xx | Malformed request | Do NOT retry; surface as a parse failure |

A 404 response for a `GET /products/{product}` request is **not alone** a sufficient condition to render the Maturity
cell as `Insufficient Data` — the technical-debt score may still be computable from the products that ARE tracked. The
404'd product is recorded under the per-application `raw_data.unknown_eol_products[]` list per
[`./facets.md`](./facets.md) § Maturity Summary, and the structured log records a `severity: warning` event with the
product slug. Per [`./troubleshooting.md`](./troubleshooting.md) § 2 Failure-Mode-to-Cell-Value Mapping, the Maturity
cell renders `Insufficient Data` only when ALL endoflife.date lookups fail (persistent 5xx or network error after
retries) OR when no manifests are present in the repository.

### 4.8 Endpoints Used

| Endpoint | Purpose | Consumed By |
|---|---|---|
| `GET /products/{product}` | Product metadata + complete release list for a product (e.g., `/products/python`, `/products/nodejs`, `/products/postgresql`) | Maturity |
| `GET /products/{product}/releases/{name}` | Specific release data (e.g., `/products/python/releases/3.10`) | Maturity |

The `{product}` path segment is the endoflife.date product slug (lowercase, hyphenated where applicable). The
`{name}` path segment is the release identifier as it appears in the v1 schema's `result.releases[].name` field
(e.g., `"3.10"` for Python 3.10, `"18"` for Node.js 18, `"15"` for PostgreSQL 15). The product slug resolution
table — mapping a detected runtime or library to its endoflife.date slug — is documented in
[`./facets.md`](./facets.md) § Maturity Summary § Product Slug Resolution.

### 4.9 Response Format

The response is JSON. The endoflife.date v1 API returns a **wrapped envelope object** (it is *not* a top-level array;
this is a key contract change from the pre-v1 API). The envelope contains response-level metadata plus a `result`
object whose shape varies by endpoint.

#### 4.9.1 Envelope (Top-Level Keys)

Every v1 response is a JSON object with these top-level keys:

- **`schema_version`** — the endoflife.date v1 schema version string (e.g., `"1.2.1"`); incremented when the v1
  schema evolves
- **`generated_at`** — ISO 8601 timestamp recording when this response payload was generated by the upstream CDN
- **`last_modified`** — ISO 8601 timestamp recording when the underlying product data was last modified.
  **Present in `GET /products/{product}` responses; MAY be absent from single-release responses.**
- **`result`** — the response payload object, whose shape depends on the endpoint (see § 4.9.2 and § 4.9.3 below)

#### 4.9.2 `result` Shape for `GET /products/{product}`

For the product-level endpoint, `result` is an **object** (not an array) with these keys:

- **`name`** — the canonical product slug (matches the path segment, e.g., `"python"`)
- **`label`** — the human-readable product name (e.g., `"Python"`)
- **`aliases`**, **`category`**, **`tags`**, **`versionCommand`**, **`identifiers`**, **`labels`**, **`links`** —
  metadata about the product (descriptive only; not consumed by the Maturity facet)
- **`releases`** — an **array** of release-entry objects, each with the per-release keys documented in § 4.9.3 below

#### 4.9.3 Release Entry Keys (within `result.releases[]` or as the singular `result` for `GET /releases/{name}`)

Each release entry contains the following keys:

- **`name`** — the release identifier (e.g., `"3.10"` for Python 3.10, `"18"` for Node.js 18). This replaces the
  pre-v1 API's `cycle` key.
- **`label`** — human-readable release label; usually identical to `name`
- **`codename`** — release codename (nullable; e.g., Ubuntu releases have codenames like `"jammy"`)
- **`releaseDate`** — ISO 8601 date of the release's initial publication
- **`isEol`** — **boolean** indicating whether the release has reached End-of-Life **as of `generated_at`**.
  This replaces the pre-v1 API's dual-typed `eol` field (which was either `false` or an ISO date string).
  The Maturity facet checks `isEol` directly: `true` means the runtime is past EOL.
- **`eolFrom`** — ISO 8601 date string identifying when the release reaches (or reached) EOL. Present whenever
  the EOL date is known; may be absent for releases with no published EOL date. The Maturity facet uses
  `eolFrom` to compute "approaching EOL" warnings (e.g., within 90 days of EOL) per
  [`./facets.md`](./facets.md) § Maturity Summary § EOL Lookup.
- **`isEoas`** — boolean indicating whether the release has reached End-of-Active-Support (a milestone that
  precedes full EOL for some products). New in v1; absent in the pre-v1 API.
- **`eoasFrom`** — ISO 8601 date string identifying when the release reaches (or reached) End-of-Active-Support
- **`isLts`** — **boolean** indicating long-term support designation. This replaces the pre-v1 API's `lts` boolean.
- **`ltsFrom`** — ISO 8601 date string identifying when the release became LTS (nullable)
- **`isMaintained`** — boolean indicating whether the release is currently receiving any form of maintenance
  (broader than `!isEol`; a release may be EOL but still receive paid extended support, in which case
  `isMaintained` MAY be `true`). New in v1; absent in the pre-v1 API.
- **`latest`** — an **object** describing the latest patch-level release within this release line. This replaces
  the pre-v1 API's `latest` string. The object contains:
  - **`name`** — the latest patch version string (e.g., `"3.10.20"` for Python 3.10's latest patch)
  - **`date`** — ISO 8601 date the latest patch was published
  - **`link`** — direct download link to the latest patch (often a vendor release-notes URL)
- **`custom`** — object containing product-specific metadata that varies by product (e.g., for Python releases:
  `{"pep": "PEP-0745"}`). The Maturity facet does not consume `custom` content; it is preserved for diagnostics.

#### 4.9.4 `result` Shape for `GET /products/{product}/releases/{name}`

For the single-release endpoint, `result` is the **release-entry object directly** (not nested under `releases[]`).
The shape of the object is identical to the per-release entry described in § 4.9.3 above. Note: the wrapping envelope
for the single-release endpoint typically does NOT include `last_modified` at the top level (only `schema_version`,
`generated_at`, and `result`).

#### 4.9.5 EOL Detection by the Maturity Facet

The Maturity facet's EOL determination uses the v1 schema as follows:

1. Issue `GET /products/{product}` for the detected runtime/library product slug
2. Locate the release entry within `result.releases[]` whose `name` matches the detected version's release line
3. EOL status is determined by `isEol` (boolean) — `true` ⇒ past EOL; `false` ⇒ supported
4. The exact EOL date (when known) is read from `eolFrom`
5. If `result.releases[]` does NOT contain a matching entry, the runtime is recorded as `eol_unknown` per
   [`./facets.md`](./facets.md) § Maturity Summary

Reading `isEol` (boolean) instead of the pre-v1 `eol` field (which was either `false` or an ISO date string)
removes the ambiguous dual-typed parsing; reading `eolFrom` (ISO date string) gives the date directly.

#### 4.9.6 Representative Response Excerpts

A representative `GET /products/python` response (truncated to two release entries for brevity):

```json
{
  "schema_version": "1.2.1",
  "generated_at": "2026-04-28T02:37:03+00:00",
  "last_modified": "2026-04-09T00:10:12+00:00",
  "result": {
    "name": "python",
    "label": "Python",
    "category": "lang",
    "tags": ["lang", "google"],
    "aliases": [],
    "releases": [
      {
        "name": "3.14",
        "codename": null,
        "label": "3.14",
        "releaseDate": "2025-10-07",
        "isLts": false,
        "ltsFrom": null,
        "isEoas": false,
        "eoasFrom": "2027-10-01",
        "isEol": false,
        "eolFrom": "2030-10-31",
        "isMaintained": true,
        "latest": {
          "name": "3.14.4",
          "date": "2026-04-07",
          "link": "https://www.python.org/downloads/release/python-3144/"
        },
        "custom": { "pep": "PEP-0745" }
      },
      {
        "name": "3.10",
        "codename": null,
        "label": "3.10",
        "releaseDate": "2021-10-04",
        "isLts": false,
        "ltsFrom": null,
        "isEoas": true,
        "eoasFrom": "2023-04-05",
        "isEol": false,
        "eolFrom": "2026-10-31",
        "isMaintained": true,
        "latest": {
          "name": "3.10.20",
          "date": "2026-03-03",
          "link": "https://www.python.org/downloads/release/python-31020/"
        },
        "custom": { "pep": "PEP-0619" }
      }
    ]
  }
}
```

A representative `GET /products/python/releases/3.10` response:

```json
{
  "schema_version": "1.2.1",
  "generated_at": "2026-04-28T02:37:03+00:00",
  "result": {
    "name": "3.10",
    "codename": null,
    "label": "3.10",
    "releaseDate": "2021-10-04",
    "isLts": false,
    "ltsFrom": null,
    "isEoas": true,
    "eoasFrom": "2023-04-05",
    "isEol": false,
    "eolFrom": "2026-10-31",
    "isMaintained": true,
    "latest": {
      "name": "3.10.20",
      "date": "2026-03-03",
      "link": "https://www.python.org/downloads/release/python-31020/"
    },
    "custom": { "pep": "PEP-0619" }
  }
}
```

#### 4.9.7 Migration Note (pre-v1 → v1)

For maintainers who previously consumed the pre-v1 endoflife.date API (which returned a flat top-level array of
release entries with keys `cycle`, `eol` (boolean OR date string), `latest` (string), and `lts` (boolean)), the
v1 contract differs as follows:

| Pre-v1 Key | v1 Replacement | Notes |
|---|---|---|
| top-level array | wrapped object with `result.releases[]` | All v1 responses are envelope objects |
| `cycle` | `result.releases[].name` | Renamed |
| `eol` (boolean OR ISO date) | `result.releases[].isEol` (boolean) + `result.releases[].eolFrom` (ISO date) | Split into two unambiguously-typed fields |
| `latest` (string) | `result.releases[].latest` (object: `{name, date, link}`) | Promoted to object |
| `lts` (boolean) | `result.releases[].isLts` (boolean) + `result.releases[].ltsFrom` (ISO date) | Split into two fields |
| (no equivalent) | `result.releases[].isEoas` + `result.releases[].eoasFrom` | New: end-of-active-support milestone |
| (no equivalent) | `result.releases[].isMaintained` | New: broader-than-EOL maintenance signal |
| (no equivalent) | `result.releases[].label`, `result.releases[].codename`, `result.releases[].custom` | New: descriptive metadata |

### 4.10 Reference Documentation

Authoritative endoflife.date API v1 reference: `https://endoflife.date/docs/api/v1/`.

### 4.11 Canonical Test Endpoint (Gate 8 Item 2)

The canonical request used by [Gate 8 Item 2 — API Contract Verification](./validation.md#44-item-2-api-contract-verification)
to verify the endoflife.date API v1 contract is the product endpoint for the well-known stable product `python`:

```text
GET https://endoflife.date/api/v1/products/python/
```

The response MUST be a JSON object (not a top-level array) and MUST contain the v1 envelope keys per § 4.9.1
(at minimum `schema_version`, `generated_at`, and `result`). The `result` object MUST contain a `releases` array
per § 4.9.2, and each entry within `result.releases[]` MUST contain the v1 release keys per § 4.9.3 (at minimum
`name`, `isEol`, `eolFrom`, and `latest` as an object). A response that:

- returns a status other than `200 OK`,
- is a top-level array (the pre-v1 shape),
- lacks the `result` envelope key,
- lacks `result.releases[]`, OR
- contains release entries missing `name`, `isEol`, or `latest` (as an object),

fails Gate 8 Item 2 — and given the API beta-status caveat per § 4.5, also triggers a contract update review and
a re-pinning event per [§ 10 Version Pinning Note](#10-version-pinning-note) below.

## 5. NVD CVE API v2.0

### 5.1 Purpose

The NVD CVE API v2.0 is consumed for **CVE record retrieval** for the **Security Summary facet**. The CVE Scanner
queries NVD to retrieve the authoritative CVSS v3.1 base score for each CVE that affects a component in the
repository's CycloneDX SBOM. The CVSS-to-severity-tier mapping (Critical, High, Medium, Low) per
[Rule R4 in `../template.md` § 5](../template.md#r4--cve-severity-breakdown) and per
[`../config/facets.yaml`](../config/facets.yaml) `severity_tier_mapping` translates each CVE's base score into the
severity tier counted in the Security cell.

### 5.2 Base URL

The base URL for the NVD CVE API is:

```text
https://services.nvd.nist.gov
```

### 5.3 API Version Used

The template uses **NVD Vulnerability API v2.0** and the companion **NVD Product API v2.0**. Both v2.0 APIs are the
current versions of record; **NVD CVE API v1.0 is deprecated** and the template MUST NOT be configured to use the v1.0
endpoints.

### 5.4 Authentication

Authentication is **optional** but **strongly recommended** for any non-trivial run because of the dramatic
rate-limit difference (see § 5.6). The API key is provided in the `apiKey` HTTP request header in the form
`apiKey: <key>`. The key is provisioned at run time as the environment variable `NVD_API_KEY`; see
[`./usage.md`](./usage.md) § Provisioning Credentials for the step-by-step provisioning runbook (the key is requested
free of charge from the NIST registration portal).

The template tolerates an absent `NVD_API_KEY` (it simply uses the lower 5/30s rate limit per § 5.6 below) but does
NOT tolerate an invalid key — an invalid key (HTTP 403) is treated as a hard authentication failure and surfaces per
[`./troubleshooting.md`](./troubleshooting.md) § 4.5.

### 5.5 Endpoints Used

| Endpoint | Purpose | Consumed By |
|---|---|---|
| `GET /rest/json/cves/2.0` | CVE search; supports query parameters `cpeName` (CPE 2.3 form), `cveId`, `keywordSearch`, `pubStartDate` / `pubEndDate`, plus pagination via `startIndex` and `resultsPerPage` | Security |
| `GET /rest/json/cpes/2.0` | CPE search (used to resolve a `package@version` to its CPE 2.3 identifier) | Security |

A representative CVE search request by CPE name:

```http
GET /rest/json/cves/2.0?cpeName=cpe%3A2.3%3Aa%3Aapache%3Alog4j%3A2.14.1%3A%2A%3A%2A%3A%2A%3A%2A%3A%2A%3A%2A%3A%2A&resultsPerPage=2000&startIndex=0 HTTP/1.1
Host: services.nvd.nist.gov
apiKey: <NVD_API_KEY>
Accept: application/json
```

### 5.6 Rate Limits

The NVD enforces the following rate limits per the public-facing rate-limit policy:

- **WITHOUT API key:** **5 requests per 30-second window**.
- **WITH API key:** **50 requests per 30-second window**.

The 10× rate-limit increase with API key is the rationale for the strong recommendation in § 5.4. For run scopes with
more than approximately 20 unique CPEs, the un-keyed 5/30s budget is regularly exhausted and the cumulative
30-second-per-window sleep can add many minutes to total scan time. With the key, the limit rises to 50/30s, which
typically eliminates rate-limit-induced sleeps for run scopes up to several hundred repositories.

### 5.7 Retry Semantics

The template treats NVD HTTP responses according to the following table:

| HTTP Status | Condition | Retry Behavior |
|---|---|---|
| 200 | Success | Proceed |
| 429 | Rate limit exceeded | Sleep for 30 seconds (one rate-limit window), then retry; max 3 retries |
| 502, 503, 504 | Transient server error | Exponential backoff (1s, 2s, 4s; max 3 retries) |
| 403 | Invalid API key | Do NOT retry; surface as authentication failure per [`./troubleshooting.md`](./troubleshooting.md) § 4.5 |
| Network error / timeout | Transient transport failure | Exponential backoff (1s, 2s, 4s; max 3 retries) |

NVD migrated from HTTP 403 "Forbidden by Administrative Rules" to HTTP 429 for rate-limit responses; the template
handles both codes uniformly to remain compatible with any response form the API may emit. After 3 retries the failure
is considered persistent and the NVD source is treated as unreachable per
[`./troubleshooting.md`](./troubleshooting.md) § 5.3; the run continues with OSV-only sources per
[Rule R9](../template.md#r9--cve-attribution), or surfaces `Insufficient Data` if OSV is also unreachable.

### 5.8 Pagination

The CVE search endpoint uses **offset-based pagination** via two query parameters:

- **`startIndex`** — zero-based starting index of the result window (default `0`).
- **`resultsPerPage`** — page size (default `2000`, maximum `2000`).

The CVE Scanner per [`./facets.md`](./facets.md) § Security Summary iterates with `startIndex += resultsPerPage` until
the response's `totalResults` is reached. Each successive page is a new HTTP request that counts against the
rate-limit budget per § 5.6, so large CVE-record windows benefit substantially from `NVD_API_KEY`.

### 5.9 Batched-Query Strategy

NVD does **NOT** support batched multi-CVE or multi-CPE requests; **one HTTP request per CPE** is required. This
constraint is operationally significant for the CVE Scanner: a repository with N unique components in its SBOM
requires N CPE-resolution requests to `/rest/json/cpes/2.0` followed by approximately N CVE-search requests to
`/rest/json/cves/2.0`. For run scopes with hundreds of unique components, the request count can easily approach
the rate-limit budget, which is why `NVD_API_KEY` is **strongly recommended** for any non-trivial run scope.

The CVE Scanner schedules requests within the rate-limit budget by:

1. Deduplicating CPEs across all repositories in the run scope before issuing requests
2. Caching CVE-search responses by CPE for the duration of the run (one CPE resolves to a stable list of CVEs at any
   given moment; the cached response is reused for every repository that uses the same component)
3. Honoring the documented 1-window sleep after a 429 response per § 5.7

### 5.10 Response Format

The response is JSON. For a `GET /rest/json/cves/2.0` request, the body contains the following top-level fields plus a
`vulnerabilities[]` array of CVE records:

- **`resultsPerPage`** — page size of this response
- **`startIndex`** — start index of this response
- **`totalResults`** — total count of matching CVE records (used for pagination per § 5.8)
- **`vulnerabilities[]`** — array of CVE records

Each CVE record under `vulnerabilities[].cve` contains:

- **`id`** — the CVE identifier (e.g., `CVE-2021-44228`)
- **`metrics.cvssMetricV31[0].cvssData.baseScore`** — the **CVSS v3.1 base score** (numeric, 0.0–10.0); used for
  severity tier mapping per [`./facets.md`](./facets.md) § Security Summary § CVSS-to-Severity Mapping
- **`metrics.cvssMetricV31[0].cvssData.baseSeverity`** — the string severity label (`CRITICAL`, `HIGH`, `MEDIUM`,
  `LOW`, `NONE`) emitted by the NVD CVSS calculator. The template's CVSS-to-tier mapping in
  [`../config/facets.yaml`](../config/facets.yaml) `severity_tier_mapping` is the canonical authority; the NVD-emitted
  `baseSeverity` is captured in the persistence record's `raw_data` for cross-reference but is not used to bucket the
  CVE.
- **`published`** — ISO 8601 datetime of the CVE's first publication
- **`lastModified`** — ISO 8601 datetime of the most recent CVE record update
- **`descriptions[0].value`** — human-readable description (the first English description, by convention)

A representative CVE-record excerpt:

```json
{
  "vulnerabilities": [
    {
      "cve": {
        "id": "CVE-2021-44228",
        "published": "2021-12-10T10:15:09.143",
        "lastModified": "2024-04-16T17:34:18.087",
        "metrics": {
          "cvssMetricV31": [
            {
              "cvssData": {
                "version": "3.1",
                "baseScore": 10.0,
                "baseSeverity": "CRITICAL"
              }
            }
          ]
        },
        "descriptions": [
          { "lang": "en", "value": "Apache Log4j2 ... allows attackers to execute arbitrary code ..." }
        ]
      }
    }
  ]
}
```

### 5.11 Reference Documentation

Authoritative NVD CVE API v2.0 reference: `https://nvd.nist.gov/developers/vulnerabilities`.

### 5.12 Canonical Test Endpoint (Gate 8 Item 2)

The canonical request used by [Gate 8 Item 2 — API Contract Verification](./validation.md#44-item-2-api-contract-verification)
to verify the NVD CVE API v2.0 contract is the single-CVE retrieval for the well-known stable Apache Struts
vulnerability `CVE-2017-5638`:

```text
GET https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2017-5638
```

The CVE-2017-5638 record is a stable, well-known vulnerability suitable as a test query because its CVSS v3.1 base
score and severity classification are settled. The response shape MUST contain the contract-documented top-level keys
`vulnerabilities[]`, `resultsPerPage`, and `totalResults` per § 5.10. A response that lacks any of these keys, or that
returns a status other than `200 OK`, fails Gate 8 Item 2.

## 6. OSV API v1

### 6.1 Purpose

The OSV (Open Source Vulnerabilities) API v1 is consumed for **CVE record retrieval** as the **alternate /
cross-reference source** for the **Security Summary facet**. The CVE Scanner uses OSV in concert with NVD per the
deduplication rule documented in [`./facets.md`](./facets.md) § Security Summary § Deduplication: each unique CVE
identifier (e.g., `CVE-2021-44228`) is counted at most once even when it is reported by both databases. OSV is also
queried directly by package name and version (without an intermediate CPE-resolution step), which makes it a faster
and more accurate match for ecosystem-native package identifiers (npm, PyPI, Maven, Go modules, RubyGems, NuGet,
crates.io, Packagist, Pub).

### 6.2 Base URL

The base URL for the OSV API v1 is:

```text
https://api.osv.dev
```

### 6.3 API Version Used

The template uses **OSV API v1** at the `/v1/` path prefix. The version pin is documented in
[§ 10 Version Pinning Note](#10-version-pinning-note) below.

### 6.4 Authentication

**None required.** The OSV API is open and unauthenticated; no API key, no OAuth flow, and no signed request is
required. No credential is provisioned for this API in any environment.

### 6.5 Endpoints Used

| Endpoint | Purpose | Consumed By |
|---|---|---|
| `POST /v1/query` | Single-package vulnerability lookup | Security |
| `POST /v1/querybatch` | **Preferred** — batched lookup; up to 1000 query objects per request body | Security |
| `GET /v1/vulns/{id}` | Single-vulnerability detail by ID (e.g., `GHSA-xxxx-xxxx-xxxx`) | Security |

A representative `POST /v1/query` request for a single package:

```http
POST /v1/query HTTP/1.1
Host: api.osv.dev
Content-Type: application/json

{
  "package": { "name": "log4j-core", "ecosystem": "Maven" },
  "version": "2.14.1"
}
```

A representative `POST /v1/querybatch` request for multiple packages in one call:

```http
POST /v1/querybatch HTTP/1.1
Host: api.osv.dev
Content-Type: application/json

{
  "queries": [
    { "package": { "name": "log4j-core", "ecosystem": "Maven" }, "version": "2.14.1" },
    { "package": { "name": "lodash", "ecosystem": "npm" }, "version": "4.17.20" },
    { "package": { "name": "django", "ecosystem": "PyPI" }, "version": "3.2.4" }
  ]
}
```

### 6.6 Rate Limits and Transport

There is **no published numeric rate limit** on the OSV API itself. However, the API enforces a **response size limit
of 32 MiB when using HTTP/1.1**; HTTP/2 has no response size limit. Because batched queries (§ 6.8) frequently produce
responses larger than 32 MiB for run scopes containing many dependencies, the **CVE Scanner SHOULD use HTTP/2** for
all OSV requests. The HTTP transport version is configured via
[`../config/facets.yaml`](../config/facets.yaml) `facets.security.cve_lookup.osv_http_version: 2` (default `2`).

### 6.7 Retry Semantics

The template treats OSV HTTP responses according to the following table:

| HTTP Status | Condition | Retry Behavior |
|---|---|---|
| 200 | Success | Proceed |
| 502, 503, 504 | Transient server error | Exponential backoff (1s, 2s, 4s; max 3 retries) |
| Network error / timeout | Transient transport failure | Exponential backoff (1s, 2s, 4s; max 3 retries) |
| 4xx | Malformed request | Do NOT retry; surface as `Insufficient Data` per [`./troubleshooting.md`](./troubleshooting.md) § 5.4 |

After 3 retries the failure is considered persistent and the OSV source is treated as unreachable per
[`./troubleshooting.md`](./troubleshooting.md) § 5.4; the run continues with NVD-only sources, or surfaces
`Insufficient Data` if NVD is also unreachable per [Rule R2 in `../template.md` § 5](../template.md#r2--facet-completeness).

### 6.8 Batched-Query Strategy

The CVE Scanner **SHOULD use `POST /v1/querybatch`** whenever the run scope contains more than approximately 10
dependencies. The endpoint accepts up to **1000 query objects per request body**; the CVE Scanner chunks larger
dependency lists into 1000-query batches and issues them sequentially.

Per the OSV team's published latency benchmarks, the relative throughput of the three endpoints is approximately:

- `POST /v1/querybatch` — **~3× faster** than `POST /v1/query` per record
- `POST /v1/query` — **~2.5× faster** than `GET /v1/vulns/{id}` per record

For the typical run scope (50–500 repositories with 10–500 dependencies each), `POST /v1/querybatch` reduces total OSV
scan time from minutes to seconds. The CVE Scanner uses `GET /v1/vulns/{id}` only for the rare case of a one-off
lookup of a specific known vulnerability ID returned from a prior batch.

### 6.9 Response Format

The response is JSON. For a `POST /v1/query` request, the body contains a `vulns[]` array of vulnerability records.
For a `POST /v1/querybatch` request, the body contains a `results[]` array, one entry per query in the request, each
containing its own `vulns[]` array.

Each vulnerability record contains:

- **`id`** — the OSV vulnerability identifier (typically a database-prefixed ID such as `GHSA-xxxx-xxxx-xxxx`,
  `PYSEC-2021-99`, or `RUSTSEC-2021-0001`)
- **`aliases[]`** — an array of cross-reference identifiers (e.g., `CVE-2021-44228`, `GHSA-jfh8-c2jp-5v3q`) used by
  the CVE Scanner to deduplicate against NVD per [`./facets.md`](./facets.md) § Security Summary § Deduplication
- **`summary`** — short human-readable summary
- **`severity[]`** — array of severity entries; each contains `type` (e.g., `CVSS_V3`) and `score` (CVSS vector
  string or numeric base score). The Security facet prefers `CVSS_V3` entries for tier mapping
- **`affected[]`** — array of affected-package entries, each containing `package` (name + ecosystem) and `ranges` (the
  affected-version intervals)
- **`published`** — ISO 8601 datetime of the vulnerability's first publication
- **`modified`** — ISO 8601 datetime of the most recent record update

A representative response excerpt:

```json
{
  "vulns": [
    {
      "id": "GHSA-jfh8-c2jp-5v3q",
      "aliases": ["CVE-2021-44228"],
      "summary": "Remote code execution in Log4j",
      "severity": [
        { "type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H" }
      ],
      "affected": [
        {
          "package": { "name": "org.apache.logging.log4j:log4j-core", "ecosystem": "Maven" },
          "ranges": [{ "type": "ECOSYSTEM", "events": [{ "introduced": "2.0.0" }, { "fixed": "2.17.0" }] }]
        }
      ],
      "published": "2021-12-10T00:00:00Z",
      "modified": "2024-04-16T00:00:00Z"
    }
  ]
}
```

### 6.10 Reference Documentation

Authoritative OSV API v1 reference: `https://google.github.io/osv.dev/api/`.

### 6.11 Canonical Test Endpoint (Gate 8 Item 2)

The canonical request used by [Gate 8 Item 2 — API Contract Verification](./validation.md#44-item-2-api-contract-verification)
to verify the OSV API v1 contract is the `POST /v1/query` single-package vulnerability lookup for a well-known
stable vulnerable package:

```text
POST https://api.osv.dev/v1/query
Content-Type: application/json

{
  "package": { "name": "log4j", "ecosystem": "Maven" },
  "version": "2.14.0"
}
```

The Maven `log4j` 2.14.0 record is a stable, well-known vulnerable version (Log4Shell / CVE-2021-44228 family)
suitable as a test query. The response shape MUST contain the contract-documented top-level `vulns[]` array, with
each entry containing `id`, `summary`, and `severity[]` per § 6.9. A response that lacks the `vulns[]` array
structure, or that returns a status other than `200 OK`, fails Gate 8 Item 2.

## 7. Network Egress Allow-List (Rule R6)

[Rule R6 in `../template.md` § 5](../template.md#r6--saas-data-sourcing) mandates that SaaS license data MUST be
sourced exclusively from manifests tracked in the repository and that **no live SaaS vendor API calls are permitted in
v1**. This rule is operationalized through a **strict outbound network-egress allow-list**: every outbound HTTP(S)
connection MUST resolve to a host enumerated below, and any other host is a runtime violation.

The canonical machine-readable allow-list is in [`../config/allow-list.yaml`](../config/allow-list.yaml). The
human-readable form below is **byte-for-byte consistent** with that file's `allowed_hosts[]` array; any divergence
between the two views is a documentation defect that MUST be corrected by updating both this section and
[`../config/allow-list.yaml`](../config/allow-list.yaml) together.

### 7.1 Allowed Hosts (Canonical Order)

| # | Host | Purpose | Authentication |
|---|---|---|---|
| 1 | `api.github.com` (and GitHub Enterprise hosts) | Source repository ingestion — GitHub | `GITHUB_TOKEN` |
| 2 | `gitlab.com/api/v4` (and self-hosted GitLab hosts) | Source repository ingestion — GitLab | `GITLAB_TOKEN` |
| 3 | `endoflife.date` | Maturity facet — EOL lookup | None |
| 4 | `services.nvd.nist.gov` | Security facet — NVD CVE lookup | `NVD_API_KEY` (optional) |
| 5 | `api.osv.dev` | Security facet — OSV CVE lookup | None |

The five hosts above and only the five hosts above are reachable from a compliant template execution. The host order
in this table matches the order of `allowed_hosts[]` entries in [`../config/allow-list.yaml`](../config/allow-list.yaml).

### 7.2 Explicit Deny Clauses

Per [`../config/allow-list.yaml`](../config/allow-list.yaml) `denied_categories[]`, the template **MUST NOT** issue
outbound requests to any of the following categories of host. These are not exhaustive enumerations — they are
illustrative categories enforced by the catch-all `everything_else_default_deny` rule (per § 7.3 below).

| Denied Category | Examples | Rationale |
|---|---|---|
| **SaaS vendor endpoints** | Salesforce (`*.salesforce.com`, `*.force.com`), ServiceNow (`*.service-now.com`), Workday (`*.workday.com`), Zendesk (`*.zendesk.com`), Slack admin APIs, Atlassian APIs (Jira/Confluence), Okta APIs, GitHub Apps marketplace, monday.com, Asana, Smartsheet, Tableau, PowerBI, Mixpanel, Segment, Stripe Dashboard | Rule R6 — SaaS license data MUST be sourced exclusively from manifests tracked in the repository |
| **Cloud billing / cost APIs** | AWS Cost Explorer, AWS Cost and Usage Report, Azure Cost Management, GCP Billing | [`../template.md` § 4 Boundaries & Preservation](../template.md#4-boundaries--preservation) — live cloud billing APIs are out of scope |
| **CMDB / ServiceNow integrations** | Any CMDB host, ServiceNow CMDB module endpoints | Out of scope per [`../template.md` § 4](../template.md#4-boundaries--preservation) |
| **Runtime monitoring data** | Datadog, New Relic, Splunk, Dynatrace, AppDynamics, Sumo Logic, PagerDuty | Out of scope per [`../template.md` § 4](../template.md#4-boundaries--preservation) — the template ingests source repositories only |
| **Everything else (default-deny)** | Any host not listed in § 7.1 | Default-deny posture: anything not explicitly allowed is denied |

SaaS license data — when discoverable — is derived ONLY from repository-tracked manifests such as `package.json`,
`requirements.txt`, `pom.xml`, `go.mod`, `Gemfile`, `Pipfile`, `build.gradle`, `.csproj`, `Cargo.toml`, plus
repository-tracked SaaS-config files (e.g., `.salesforce.json`, `manifest.yml`, `force-app/`) when present. The
template **MUST NOT** call out to a SaaS vendor host to enrich, validate, or supplement this data.

### 7.3 Enforcement Mode

Per [`../config/allow-list.yaml`](../config/allow-list.yaml) `enforcement`:

- **`mode: default_deny`** — anything not explicitly allowed is denied
- **`match_strategy: hostname_or_prefix`** — the hostname (and optional URL prefix for `gitlab.com/api/v4`) is matched
  against the allow-list; a matching entry is required for the request to proceed
- **`on_violation: surface_insufficient_data`** — when the template attempts an outbound request to a denied host,
  the request is blocked, the affected facet cell renders `Insufficient Data` per
  [Rule R2 in `../template.md` § 5](../template.md#r2--facet-completeness), and the structured log records a
  `severity: error` violation event with the requested host
- **`audit_log_required: true`** — every outbound request (allowed or denied) is recorded in the structured audit log
  for review during Gate 1 Live Smoke Test (per [`./validation.md`](./validation.md) § Gate 1)

### 7.4 R6 Verification Procedure

Per the verbatim verification clause in [`../template.md` § 5 R6](../template.md#r6--saas-data-sourcing), Rule R6 is
verified by the assertion:

> *"template execution produces no outbound calls to SaaS vendor endpoints"*

The verification is performed during the Gate 1 Live Smoke Test (per [`./validation.md`](./validation.md) § Gate 1) by:

1. Enabling the network-egress audit log (`audit_log_required: true` is the default; no extra configuration required)
2. Running the template against the designated test repository
3. Extracting the per-host outbound request count from the audit log
4. Asserting that **every** outbound host appears in the § 7.1 allow-list
5. Asserting that **no** outbound host appears in any of the § 7.2 denied categories

Any violation — including a single outbound request to a non-allow-listed host — is a Gate 1 failure and MUST be
remediated before the package is delivered.


## 8. R9 Attribution Rule

[Rule R9 in `../template.md` § 5](../template.md#r9--cve-attribution) mandates that every Security Summary result MUST
carry the **scan timestamp** (ISO 8601) and the **source database** label (`NVD`, `OSV`, or both). Undated or
unattributed CVE counts are a failing state. This section operationalizes Rule R9 by specifying the structural shape
of the attribution metadata, the rendering format on the PDF, and the deterministic edge-case behavior when one or
both sources fail.

### 8.1 Scan Metadata Structure

The CVE Scanner per [`./facets.md`](./facets.md) § Security Summary records a `scan_metadata` object alongside every
emitted Security grade. The schema is encoded in
[`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) `properties.scan_metadata` (which
references `$defs/scanMetadata`); the human-readable shape is:

```json
{
  "scan_metadata": {
    "timestamp": "2025-10-01T08:00:00Z",
    "sources": ["NVD", "OSV"]
  }
}
```

Field semantics:

- **`timestamp`** — ISO 8601 datetime of the wall-clock time at which the CVE lookup completed for this application.
  Encoded as `YYYY-MM-DDThh:mm:ssZ` for UTC (`Z` suffix), or with explicit offset `YYYY-MM-DDThh:mm:ss±hh:mm`. The
  field is `required: true` per the schema. Resolution is to the second; sub-second precision is not retained.
- **`sources`** — array of database identifiers; each element MUST be one of the literal strings `"NVD"` or `"OSV"`
  (uppercase, exact casing). Constraints encoded in the schema:
  - `minItems: 1`
  - `maxItems: 2`
  - `uniqueItems: true`
  - `items.enum: ["NVD", "OSV"]`

When the security grade is emitted (i.e., the cell is NOT `Insufficient Data`), the schema-level `allOf` conditional
in [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) requires `scan_metadata` whenever
`facet == "security"` and `grade ∈ {A, B, C, D, F}`.

### 8.2 PDF Rendering Format

The scan attribution is rendered in the PDF Security cell per
[`./pdf-output.md`](./pdf-output.md) § 5.5 Security Cell with Severity Tier Counts. Two layout options are documented:

**Option A — Per-cell attribution (default):** Each Security cell carries its own attribution line directly below
the severity tier counts. Example layout:

```text
B  ←  prev: C  |  2025-09-01
Critical: 0 | High: 1 | Medium: 3 | Low: 5 | Total: 9
Scan: 2025-10-01T08:00:00Z | Source: NVD, OSV
```

**Option B — Aggregated footnote (allowed when uniform):** When ALL Security cells in a single run share the
identical scan timestamp AND the identical sources array, a **single page-level footnote** MAY replace the per-cell
attribution lines provided that every Security cell remains traceable to its underlying `scan_metadata` via the
persistence record per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json). Example
footnote:

```text
* All Security results scanned at 2025-10-01T08:00:00Z. Sources: NVD, OSV.
```

The aggregated-footnote option is a CIO/CTO readability optimization for the case where the entire run completed
within a small time window; the per-cell option remains the canonical default.

### 8.3 Source Combinations and Edge Cases

The `sources` array reflects the actual databases that returned data for the application's CVE scan. The four
possible states are:

| State | `sources` value | Trigger |
|---|---|---|
| Both sources returned data | `["NVD", "OSV"]` | NVD and OSV both responded successfully (200 OK with vulnerability records OR with empty `vulnerabilities[]` / `vulns[]`) |
| Only NVD returned data | `["NVD"]` | OSV failed (persistent 5xx, network error, HTTP/2 negotiation failure) OR returned no records (which is recorded as an empty array, not a failure) AND NVD succeeded |
| Only OSV returned data | `["OSV"]` | NVD failed (persistent 5xx, persistent 429 after retries, invalid `NVD_API_KEY`) AND OSV succeeded |
| BOTH failed | (no `scan_metadata` emitted) | Both NVD AND OSV were unreachable after retries; the cell renders `Insufficient Data` per Rule R2 and the persistence record is emitted with `grade: "InsufficientData"` and no `scan_metadata` (per the schema's conditional `allOf`) |

The `sources` array MUST contain exactly the database identifiers that contributed records to the cell. A source that
failed entirely is omitted from `sources`. A source that succeeded but returned no records (e.g., NVD reports zero
CVEs for the application's components) is **included** in `sources` because it contributed an authoritative
"zero CVEs" observation.

### 8.4 R9 Verification Procedure

Per the verbatim verification clause in [`../template.md` § 5 R9](../template.md#r9--cve-attribution), Rule R9 is
verified by the assertion:

> *"each Security Summary cell or report footnote contains timestamp and database label"*

The verification is performed during the Gate 8 integration sign-off checklist (per
[`./validation.md`](./validation.md) § Gate 8) by:

1. Generating a report against a designated test repository with at least one populated Security cell
2. Inspecting the PDF for **every** Security cell (or the page footnote, when Option B per § 8.2 is in use):
   - Each cell or footnote MUST display an ISO 8601 timestamp
   - Each cell or footnote MUST display at least one of the literal labels `NVD` or `OSV`
3. Inspecting the corresponding persistence records via [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json):
   - Every record with `facet == "security"` and `grade ∈ {A, B, C, D, F}` MUST include a `scan_metadata` object
     with `timestamp` and `sources` populated per § 8.1
4. Asserting that no Security cell exists in the PDF without an associated attribution

Any Security result without timestamp or source label is a Rule R9 failure and a Gate 8 failure. The remediation is
to re-run the CVE Scanner with audit logging enabled, identify the missing-attribution code path, and ensure the
`scan_metadata` is constructed and persisted at the same code site that constructs the security `grade`.


## 9. Credential Provisioning

The template consumes exactly **three credential environment variables** at run time. **No secret values appear in
this documentation, in [`../config/`](../config/), or in any committed artifact**; credentials are supplied
exclusively via the run environment.

### 9.1 Required and Optional Environment Variables

| Environment Variable | Required When | Purpose | Source API |
|---|---|---|---|
| `GITHUB_TOKEN` | Run scope contains GitHub repositories | Authenticated read access to repository contents | § 2 GitHub API |
| `GITLAB_TOKEN` | Run scope contains GitLab repositories | Authenticated read access to project contents | § 3 GitLab API |
| `NVD_API_KEY` | Optional — strongly recommended for any non-trivial run | Raises NVD rate limit from 5/30s to 50/30s | § 5 NVD CVE API v2.0 |

Cross-reference [`./usage.md`](./usage.md) § Provisioning Credentials for the step-by-step provisioning runbook
(token issuance, scope selection, environment-variable export, secret-store integration).

### 9.2 Token Forms and Header Conventions

| Variable | Token Forms Accepted | HTTP Header |
|---|---|---|
| `GITHUB_TOKEN` | Classic Personal Access Token (PAT); fine-grained PAT; GitHub App installation token | `Authorization: Bearer <token>` |
| `GITLAB_TOKEN` | Personal Access Token; Project Access Token; Group Access Token | `PRIVATE-TOKEN: <token>` |
| `NVD_API_KEY` | NIST-issued NVD API key (free of charge; UUID-form string) | `apiKey: <key>` |

The header forms above are the wire-level forms that the template's HTTP client emits. Reviewers and operators
SHOULD NOT see token values in any log, audit trail, or persistence record; if a token value appears anywhere other
than the in-memory HTTP request, that is an information-disclosure defect.

### 9.3 Credential Rotation Guidance

| Variable | Rotation Cadence | Rotation Trigger |
|---|---|---|
| `GITHUB_TOKEN` | Every **90 days** or per organizational policy | Suspected compromise; PAT expiration; user offboarding; scope reduction |
| `GITLAB_TOKEN` | Every **90 days** or per organizational policy | Suspected compromise; PAT expiration; user offboarding; scope reduction |
| `NVD_API_KEY` | On demand | NVD does not enforce expiration; rotate if compromise is suspected |

For PATs, prefer the **shortest practical expiration** consistent with operational continuity (the GitHub fine-grained
PAT and GitLab PAT models allow author-time expiration selection of 7, 30, 60, 90, or 365 days). For installation
tokens (GitHub App), the token lifetime is 1 hour and is refreshed automatically by the App's authentication flow;
no manual rotation is required.

### 9.4 Credential Hygiene

The template package does NOT manage secret storage; credential storage and access control are the operator's
responsibility. Recommended practices:

- Source `GITHUB_TOKEN`, `GITLAB_TOKEN`, and `NVD_API_KEY` from a dedicated secret manager (HashiCorp Vault, AWS
  Secrets Manager, Azure Key Vault, GCP Secret Manager, 1Password, or equivalent)
- Inject the secrets into the run environment at process-start time only; do NOT write secrets to disk
- Set per-token least-privilege scopes per § 2.5, § 3.5
- Enable secret-scanning protections (e.g., GitHub secret scanning, GitGuardian) on the package's hosting repository
  to catch any inadvertent secret commit

## 10. Version Pinning Note

The API versions referenced throughout this document are pinned at the documentation level and at the configuration
level. The two views MUST agree at all times; any divergence is a documentation defect that MUST be remediated by a
single PR that updates both views together.

### 10.1 Documentation-Level Pins

The version-of-record for each external API as of this package version (`v0.1.0`):

| API | Documented Version | Documented At |
|---|---|---|
| GitHub API | REST v3, GraphQL v4 | § 2.3 |
| GitLab API | REST v4 | § 3.3 |
| endoflife.date API | v1 (Beta) | § 4.3, § 4.5 |
| NVD CVE API | v2.0 (Vulnerability API + Product API) | § 5.3 |
| OSV API | v1 | § 6.3 |

### 10.2 Configuration-Level Pins

The machine-readable version touchpoints in [`../config/facets.yaml`](../config/facets.yaml) that MUST agree with the
documentation-level pins above:

| Configuration Key | Pinned Value | Documentation Cross-Reference |
|---|---|---|
| `facets.maturity.eol_lookup.api_version` | `v1` | § 4.3, § 4.5 |
| `facets.security.cve_lookup.primary_source` | `NVD` (paired with NVD API v2.0 path `/rest/json/cves/2.0/`) | § 5.2, § 5.3, § 5.5 |
| `facets.security.cve_lookup.secondary_source` | `OSV` (paired with OSV API v1 path `/v1/...`) | § 6.2, § 6.3, § 6.5 |

The GitHub and GitLab API versions are documented in this file only (they are not separately pinned in
[`../config/facets.yaml`](../config/facets.yaml) for package version `v0.1.0`); a future package release MAY add
explicit `apis.github.version` and `apis.gitlab.version` keys to [`../config/facets.yaml`](../config/facets.yaml) if
runtime selection between GraphQL and REST or between API versions becomes configurable.

### 10.3 Version-Pin Update Procedure

Any change to a documented or configured API version MUST follow this procedure:

1. Update the version pin in this document (the relevant `### N.3 API Version Used` sub-section)
2. Update the corresponding key in [`../config/facets.yaml`](../config/facets.yaml) per § 10.2
3. Update [`../config/allow-list.yaml`](../config/allow-list.yaml) `allowed_hosts[]` if the version change introduces
   a new hostname or path prefix
4. Record the change in [`../CHANGELOG.md`](../CHANGELOG.md) with the date (ISO 8601), the affected API, the prior
   pinned version, the new pinned version, and a brief rationale
5. Re-run the Gate 1 Live Smoke Test per [`./validation.md`](./validation.md) § Gate 1 to confirm continued
   compatibility
6. Re-run the Gate 8 integration sign-off checklist per [`./validation.md`](./validation.md) § Gate 8 to confirm the
   API contract verification still passes

The endoflife.date API v1 Beta-status caveat (§ 4.5) is a known maintenance hazard: future maintainers MUST monitor
the endoflife.date project's announcements and treat any Beta-to-stable transition or v1-to-v2 migration as a
mandatory version-pin update event.

## 11. SBOM Generation

### 11.1 Purpose

SBOM generation is the **local, pre-CVE-lookup** stage of the Security Summary facet pipeline. The Security facet
detects each repository's per-ecosystem dependency manifests, invokes the appropriate per-ecosystem CycloneDX
generator to produce a Software Bill of Materials (SBOM), and then feeds the resulting SBOM components to the NVD
(§ 5) and OSV (§ 6) CVE-lookup APIs to count CVEs by severity tier per Rule R4. The detection-and-generation rules
are documented in [`./facets.md`](./facets.md) § Security Summary; this section is the canonical home of the
**version-pin contract** for the SBOM tooling per AAP § 0.6.1, which mandates that SBOM-generator versions are
recorded here and updated via PRs to this document only.

### 11.2 Output Format — CycloneDX 1.7

The SBOM output format is **CycloneDX 1.7** (the current default specification version, also adopted as the
ECMA-424 standard). CycloneDX 1.7 is consumed natively by both the NVD CVE API v2.0 (§ 5) workflow and the OSV API
v1 (§ 6) `osv-scanner` tooling, removing any need for format conversion between SBOM generation and CVE lookup.

The CycloneDX 1.7 schema and JSON/XML reference documents are published at:

```text
https://cyclonedx.org/specification/overview/
```

The generated SBOM JSON is stored in the per-application `raw_data.sbom_json` field (in-memory only — the SBOM is
not persisted to the grade history per [`./grade-history.md`](./grade-history.md)) and is then submitted to the
CVE-lookup APIs per § 5 (NVD) and § 6 (OSV).

### 11.3 Per-Ecosystem Generator Selection

The Security facet selects an SBOM generator based on the dependency manifests detected in the repository. Each
generator consumes the manifests of one ecosystem and emits a CycloneDX-1.7-conforming JSON SBOM. The version pins
below are the **minimum supported versions** for this package (`v0.1.0`); maintainers MUST NOT downgrade below
these pins because each minimum version corresponds to a published CVE fix as documented in § 11.4.

| Ecosystem | Generator | Manifest Inputs | Pinned Version (minimum) | Distribution |
|---|---|---|---|---|
| npm / Node.js | `@cyclonedx/cyclonedx-npm` | `package.json`, `package-lock.json` | `4.2.1` or later | npm registry (`@cyclonedx/cyclonedx-npm`) |
| Python | `cyclonedx-bom` (formerly `cyclonedx-py`) | `requirements.txt`, `Pipfile.lock`, `poetry.lock` | `7.2.2` or later | PyPI (`cyclonedx-bom`) |
| Maven / Java | `org.cyclonedx:cyclonedx-maven-plugin` | `pom.xml` | `2.9.1` or later **AND** transitive `org.cyclonedx:cyclonedx-core-java` MUST be `11.0.1` or later (see § 11.4 — CVE-2025-64518) | Maven Central |
| Gradle / Java/Kotlin | `org.cyclonedx.bom` Gradle plugin | `build.gradle`, `build.gradle.kts` | `3.0.2` or later (bundles `cyclonedx-core-java` `11.0.1`+ per upstream release `cyclonedx-gradle-plugin-3.0.2`) | Gradle Plugin Portal |
| .NET / dotnet | `CycloneDX` dotnet tool | `.csproj`, `packages.lock.json` | `4.0.0` or later | NuGet / `dotnet tool` |
| Go | `cyclonedx-gomod` | `go.mod`, `go.sum` | `1.7.0` or later | `github.com/CycloneDX/cyclonedx-gomod` |
| Rust / Cargo | `cargo-cyclonedx` | `Cargo.toml`, `Cargo.lock` | `0.5.7` or later | crates.io |
| Multi-language fallback | `cdxgen` | any of the above | **`11.1.7` or later** (see § 11.4 — CVE-2024-50611) | npm (`@cyclonedx/cdxgen`) OR container `ghcr.io/cyclonedx/cdxgen:v11.1.7` (or later tag) |

Ecosystem detection rules (which generator runs for which manifest combination) are documented in
[`./facets.md`](./facets.md) § Security Summary § SBOM Generation. The Security facet's manifest-detection logic
selects the most-specific generator for each ecosystem detected; if multiple ecosystems are detected in a single
repository, multiple generators run in sequence and their CycloneDX outputs are merged into a single SBOM before
CVE lookup.

#### 11.3.1 cdxgen Container Image Path

cdxgen is an OWASP / CycloneDX-community SBOM generator. The active project source is mirrored at both
`github.com/cdxgen/cdxgen` (current README and code) and `github.com/CycloneDX/cdxgen` (issue tracker; under repo
migration to the OWASP organization at the time of authoring). Regardless of source-repo URL, the canonical
container image registry path published by the upstream maintainers — and used in every `docker run` example in the
upstream README — is:

```text
ghcr.io/cyclonedx/cdxgen:<tag>
```

Two ancillary runtime variants are also published under the same namespace and may be substituted by maintainers
who require an alternative JavaScript runtime: `ghcr.io/cyclonedx/cdxgen-deno:<tag>` (Deno) and
`ghcr.io/cyclonedx/cdxgen-bun:<tag>` (Bun). The corresponding npm distribution is `@cyclonedx/cdxgen` (i.e., the
package, the container image, and the registry organization are all under the `cyclonedx/` namespace —
**not** under a `cdxgen/` GHCR namespace).

Maintainers MUST pin a specific image tag (e.g., `v11.1.7` or later) rather than `latest` or `master`, because
floating tags will silently shift over time and could re-introduce a fixed CVE if the upstream tag is ever rolled
back. Per AAP § 0.10.2 "Verbatim Preservation Rule," the registry path documented above is the authoritative
reference and matches the SBOM Generation table in [`./facets.md`](./facets.md) § Security Summary as well as the
package-of-record version pin documented in § 11.3 of this document.

### 11.4 Vulnerability Mitigation Pins

The minimum-version pins in § 11.3 above each correspond to a published CVE fix. Maintainers reviewing this section
during a version-bump PR MUST verify (a) that the new pinned version remains AT OR ABOVE the minimum, and (b) that
no new CVE has been disclosed against the new version. The CVE inventory below is the as-of-authoring snapshot;
maintainers SHOULD re-verify against the vendor's GitHub Advisory feed or the OSV database (§ 6) at the time of
each pin update.

#### 11.4.1 cdxgen — CVE-2024-50611 (Code Injection via Untrusted Build Files)

- **Affected component**: `@cyclonedx/cdxgen` (npm) and `ghcr.io/cyclonedx/cdxgen` (container image)
- **CVE**: CVE-2024-50611 (GHSA-hxf3-vgpm-fv9p)
- **Severity**: HIGH (CVSS v3.1 7.2 per OSV; reported as 8.6 by some downstream sources)
- **CWE**: CWE-94 — Improper Control of Generation of Code ('Code Injection')
- **Affected versions**: cdxgen versions through `10.10.7` (inclusive)
- **Fix version**: cdxgen `11.1.7` or later (introduces a "secure mode" gated by the Node.js permission model)
- **Trust-boundary note**: cdxgen processes **untrusted ingested repository content** as part of its standard
  operating mode; specifically, it invokes package-manager commands (`npm install`, `mvn`, `gradle`, `sbt`, etc.)
  whose default behavior includes executing scripts declared in build files (e.g., `package.json` `scripts.preinstall`,
  `build.gradle.kts` build logic). Versions through 10.10.7 had no sandbox between cdxgen's command execution and
  these script hooks, so a malicious ingested repository could achieve code execution in the SBOM-generation
  environment. Version 11.1.7 introduces opt-in Node.js permission constraints that restrict cdxgen's filesystem
  and child-process privileges; the package is configured to use these constraints in [`./facets.md`](./facets.md)
  § Security Summary § SBOM Generation.
- **Defensive mitigations REQUIRED in addition to the version pin** (per upstream guidance):
  1. Run cdxgen via the container image with limited volume mounts (avoid `-v /tmp:/tmp` and `-v $HOME:$HOME`),
     a randomized `TMPDIR`, and a dedicated seccomp profile
  2. Pass `--no-install-deps` or `--lifecycle pre-build` to prevent cdxgen from triggering `npm install`,
     `mvn package`, or equivalent install-time hooks
  3. Never run cdxgen with `sudo` or administrative privileges
  4. Treat ingested repositories as untrusted by default (which is the standing assumption of this template per
     [`../template.md`](../template.md) § 4 Boundaries & Preservation)

#### 11.4.2 cyclonedx-maven-plugin — Transitive CVE-2025-64518 (XML External Entity Injection)

- **Affected transitive component**: `org.cyclonedx:cyclonedx-core-java`, bundled by `cyclonedx-maven-plugin`
- **CVE**: CVE-2025-64518 (GHSA-6fhj-vr9j-g45r)
- **Severity**: HIGH (CVSS v3.1 8.6; reported by the NVD and CycloneDX security advisory)
- **CWE**: CWE-611 — Improper Restriction of XML External Entity Reference (XXE)
- **Affected versions**: `cyclonedx-core-java` versions from `2.1.0` through (but not including) `11.0.1`
- **Fix version**: `cyclonedx-core-java` `11.0.1` or later (configures the XML `Validator` securely; this fix
  completes the partial fix from CVE-2024-38374 / GHSA-683x-4444-jxh8 which addressed XML parsing but not validation)
- **Plugin pin**: `cyclonedx-maven-plugin` `2.9.1` or later. The `2.9.1` plugin release transitively bundles a
  `cyclonedx-core-java` build that is at or beyond `11.0.1`. Maintainers MUST verify the bundled
  `cyclonedx-core-java` version using `mvn dependency:tree -Dincludes=org.cyclonedx:cyclonedx-core-java` against the
  pinned plugin version and re-pin the plugin upward if the bundled core-java version regresses below `11.0.1`.
  Plugin versions `2.8.0` and earlier (which bundle vulnerable `cyclonedx-core-java` builds) MUST NOT be used.
- **Trust-boundary note**: The XXE vector is exercised whenever `cyclonedx-core-java` is asked to validate an XML
  CycloneDX BOM, which can occur when ingested repositories supply pre-existing CycloneDX XML BOMs that the Security
  facet re-validates before merging. JSON BOMs are unaffected. Per upstream workaround guidance: applications can
  reject XML CycloneDX inputs entirely as a defense-in-depth measure if the package is pinned to `cyclonedx-core-java`
  versions `<11.0.1` for any reason.

#### 11.4.3 cyclonedx-gradle-plugin — Same Transitive CVE-2025-64518

- **Affected transitive component**: `org.cyclonedx:cyclonedx-core-java` bundled by `cyclonedx-gradle-plugin`
- **Plugin pin**: `cyclonedx-gradle-plugin` `3.0.2` or later. The upstream `cyclonedx-gradle-plugin-3.0.2` release
  notes confirm that this version explicitly upgrades the transitive `cyclonedx-core-java` from `11.0.0` to `11.0.1`,
  closing CVE-2025-64518. Plugin versions before `3.0.2` MUST NOT be used.

### 11.5 Pin-Update Procedure

When a new CVE is disclosed against any pinned generator OR when a new minor/major version of any generator is
released, follow this procedure (mirrors the API-version pin update procedure in § 10.3):

1. Update the pinned-version table in § 11.3 above with the new minimum version
2. Add a § 11.4.X subsection documenting the new CVE (if applicable) with severity, affected versions, fix version,
   and trust-boundary note
3. Update the generator-selection table in [`./facets.md`](./facets.md) § Security Summary § SBOM Generation with
   the new version (the SBOM Generation table in `facets.md` is the user-facing reference; this section is the
   maintainer-facing reference per AAP § 0.6.1)
4. Update [`../config/facets.yaml`](../config/facets.yaml) `facets.security.sbom_generation` configuration if any
   per-generator runtime flag changes are required (e.g., new `--no-install-deps`-style mitigation flag introduced
   by a generator update)
5. Record the change in [`../CHANGELOG.md`](../CHANGELOG.md) with the date (ISO 8601), the affected generator,
   the prior pin, the new pin, the CVE identifier (if applicable), and a brief rationale
6. Re-run the Gate 1 Live Smoke Test per [`./validation.md`](./validation.md) § Gate 1 with the updated pins to
   confirm the SBOM generator still produces parseable CycloneDX 1.7 output
7. Re-run the Gate 8 Item 3 — Grade History Verification per [`./validation.md`](./validation.md) § Gate 8 to confirm
   that the CVE-count outputs from NVD (§ 5) and OSV (§ 6) remain stable for known-vulnerable test fixtures

### 11.6 Reference Documentation

Authoritative CycloneDX BOM Standard 1.7 specification: `https://cyclonedx.org/specification/overview/`.
Authoritative CycloneDX tooling registry (per-ecosystem generators): `https://cyclonedx.org/tool-center/`.
The cdxgen project home is `https://github.com/CycloneDX/cdxgen`; the cyclonedx-maven-plugin home is
`https://github.com/CycloneDX/cyclonedx-maven-plugin`; the cyclonedx-gradle-plugin home is
`https://github.com/CycloneDX/cyclonedx-gradle-plugin`. CVE records are sourced from the GitHub Advisory Database
and re-verifiable via NVD (§ 5) and OSV (§ 6).

## 12. Cross-References

This document is the canonical home of all external API URLs and contract details for the package per AAP § 0.10.2
"Citation Inline Rule." The relative-path links below enumerate every outbound cross-reference made by this document
for reviewer convenience:

### 12.1 Canonical Sources Referenced

- [`../template.md`](../template.md) — canonical, verbatim Rule R6 (SaaS data sourcing) and Rule R9 (CVE attribution);
  [§ 4 Boundaries & Preservation](../template.md#4-boundaries--preservation); ingestion contract in § 3.1; canonical
  Rules R1, R2, R4 cited throughout
- [`../config/allow-list.yaml`](../config/allow-list.yaml) — canonical machine-readable network-egress allow-list and
  denied categories enforced at runtime
- [`../config/facets.yaml`](../config/facets.yaml) — machine-readable version pins for `apis.*`,
  `facets.security.sbom_generation`, and the `severity_tier_mapping`, `apis_*`, and
  `facets.security.cve_lookup.*` configuration consumed by the CVE Scanner and the SBOM Generation pipeline
- [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) — `properties.scan_metadata` schema
  referenced by the Rule R9 attribution shape in § 8
- [`../CHANGELOG.md`](../CHANGELOG.md) — versioned record of API version-pin updates per § 10.3 and SBOM-generator
  pin updates per § 11.5

### 12.2 Sibling Documentation Pages Referenced

- [`./facets.md`](./facets.md) — Security Summary facet's CVE pipeline that consumes NVD (§ 5) and OSV (§ 6); SBOM
  Generation user-facing reference (§ 11 here is the maintainer-facing version-pin reference); Maturity Summary
  facet's EOL pipeline that consumes endoflife.date (§ 4); Tech Stack and Complexity facets' artifact source
  is GitHub/GitLab data only
- [`./pdf-output.md`](./pdf-output.md) — Security cell rendering format with Rule R9 attribution per § 8.2
- [`./troubleshooting.md`](./troubleshooting.md) — failure-mode-to-cell-value mapping for each external API per
  §§ 4 (authentication failures), 5 (rate-limit recovery), 6 (manifest parse), 7 (SBOM generation)
- [`./usage.md`](./usage.md) — credential provisioning workflow referenced from § 2.4, § 3.4, § 5.4, § 9.1
- [`./validation.md`](./validation.md) — Gate 1 Live Smoke Test (Rule R6 verification per § 7.4); Gate 8 integration
  sign-off (Rule R9 verification per § 8.4); Gate 2 zero-warning build (referenced from retry semantics tables)

### 12.3 No Outbound Links Beyond the Package

Per the AAP § 0.10.2 "Standalone Package Rule," every link in this document is a relative path within
`templates/technology-estate-report/`. No link reaches outside this directory. External API URLs (e.g.,
`https://api.github.com`, `https://services.nvd.nist.gov`, `https://cyclonedx.org`) appear exclusively as
**literal text in code fences or prose** for documentation purposes; they are NOT clickable Markdown links and
they MUST NOT appear elsewhere in the package as primary content.
