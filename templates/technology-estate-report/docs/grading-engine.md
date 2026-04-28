# Grading Engine — Technology Estate Report Template

## 1. Overview

The grading engine is the component that transforms per-facet raw analyzer outputs into the single A–F letter grade rendered in each cell of the Application Matrix Table of the Technology Estate Report PDF. It is a **pure function** of two inputs: (a) the per-facet raw outputs emitted by the four facet analyzers — Tech Stack Detector, Maturity Analyzer, CVE Scanner, and Complexity Extractor — documented in [`./facets.md`](./facets.md), and (b) the user-supplied A–F grading rubric documented in [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) and worked-example-illustrated in [`../config/rubric-example.yaml`](../config/rubric-example.yaml) and [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml). Per [Rule R1](../template.md#r1--rubric-editability) (verbatim text in [`../template.md`](../template.md) § 5; not duplicated here per the AAP § 0.10.2 "No Redundancy Rule"), no grade thresholds are hardcoded in the template — the rubric is the **single source of truth** for grade emission.

For each `(application, facet)` pair in scope, the engine emits exactly one of the following values, encoded in the persisted grade-history record's `grade` field per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json):

- **An A–F letter grade** in the set `{A, B, C, D, F}` — the standard outcome when the facet analyzer produced raw data and the rubric matched a grade entry. This is the value range supplied by the rubric author per [Rule R1](../template.md#r1--rubric-editability) and emitted by the engine when [§ 4.2 Rubric Application Algorithm](#42-rubric-application-algorithm) finds a matching entry.
- **`TBD`** — emitted exclusively for the Complexity facet when the supplied rubric's `complexity` array is empty (the canonical initial state per [`../config/rubric-example.yaml`](../config/rubric-example.yaml) and [Rule R5](../template.md#r5--complexity-placeholder-integrity)). The PDF renderer translates `TBD` into the literal placeholder label `Grade: TBD — definition pending` per [§ 5 Complexity Lock](#5-complexity-lock-rule-r5).
- **`InsufficientData`** — emitted when the facet analyzer's raw data is unavailable or the rubric cannot be applied (see [§ 7 Failure Modes & Insufficient Data](#7-failure-modes--insufficient-data)). The PDF renderer translates this value into the literal cell value `Insufficient Data` (capital I, capital D, single space) per [Rule R2](../template.md#r2--facet-completeness) and [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format.

A fourth special value — **`N/A`** — appears in the persisted grade-history record's enumeration but is **never** emitted by the grading engine as a current-run grade. It is reserved exclusively for the prior-grade slot of a rendered cell when no prior run exists for the `(application_id, facet)` pair, per [Rule R3](../template.md#r3--grade-history-fidelity) and [`./grade-history.md`](./grade-history.md) § Rendering. The grading engine produces only the **current-run** grade; the prior-grade slot is materialized at PDF rendering time from the persistence layer.

The engine's defining invariant is **determinism**: given the same `(raw_data, rubric)` input pair, the engine MUST emit the same grade. Determinism is the foundation of [Rule R1's verification clause](../template.md#r1--rubric-editability) — "generating a report with two different rubric inputs for the same dataset produces two different grade outputs" — because that clause is testable only when each input pair maps to exactly one output value. The verification procedure is documented in [§ 6 R1 Verification Procedure](#6-r1-verification-procedure); the contract surface is documented in [§ 4 Evaluation Procedure](#4-evaluation-procedure).

## 2. Rubric Input Format

The rubric input is a YAML or JSON document whose structural shape is encoded in [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) (JSON Schema Draft 2020-12). The schema's `$id` is `urn:blitzy:technology-estate-report:rubric:v0.1.0`. A YAML rubric is parsed to JSON and then validated against the schema before the engine accepts it as an input. A rubric document that fails schema validation surfaces as `InsufficientData` per [§ 7 Failure Modes & Insufficient Data](#7-failure-modes--insufficient-data) — never a silent omission, per [Rule R2](../template.md#r2--facet-completeness) and [Gate 2](../template.md#612-gate-2--zero-warning-build).

A minimal, illustrative rubric document has the following shape:

```yaml
rubric:
  tech_stack:
    - grade: A
      criteria: "Modern, supported tech stack on a single primary cloud."
    - grade: F
      criteria: "Deprecated language(s) or framework(s) with no active community."
  maturity:
    - grade: A
      criteria: "No library out of support"
    - grade: F
      criteria: "Majority of tracked dependencies are past EOL."
  security:
    - grade: A
      criteria: "Zero Critical CVEs and zero High CVEs."
    - grade: F
      criteria: "More than 5 Critical CVEs."
  complexity: []
```

The example above uses two-entry rubrics for brevity. Production rubrics typically supply one entry per A–F letter grade (five entries per facet); see [`../config/rubric-example.yaml`](../config/rubric-example.yaml) and [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) for full five-entry rubrics. The Complexity facet's rubric is intentionally an empty array in the example above per [Rule R5](../template.md#r5--complexity-placeholder-integrity) — see [§ 5 Complexity Lock](#5-complexity-lock-rule-r5) for the locked-state semantics.

### 2.1 Per-Key Reference

The table below enumerates every key the schema accepts, its type, whether it is required, and the documentation reference for its semantics. The canonical machine-readable contract is [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json); this table summarizes the structural surface for human readers.

| Key | Type | Required | Description |
|---|---|---|---|
| `rubric` | object | yes | Top-level container for the four facet rubrics. Encoded as the schema's only top-level required property. |
| `rubric.tech_stack` | array | yes | Tech Stack Summary rubric. At least 1 entry (`minItems: 1` per [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) `$defs.facetRubric`). |
| `rubric.maturity` | array | yes | Maturity Summary rubric. At least 1 entry (`minItems: 1`). |
| `rubric.security` | array | yes | Security Summary rubric. At least 1 entry (`minItems: 1`). |
| `rubric.complexity` | array | yes | Complexity Summary rubric. May be empty (`minItems: 0` per [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) `$defs.facetRubricComplexity`); the empty array `complexity: []` is the canonical initial state per [Rule R5](../template.md#r5--complexity-placeholder-integrity) and [`../config/rubric-example.yaml`](../config/rubric-example.yaml). |
| `rubric.<facet>[].grade` | string | yes | One of `A`, `B`, `C`, `D`, `F` (per [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) `$defs.rubricEntry.properties.grade.enum`). |
| `rubric.<facet>[].criteria` | string | yes | Author-supplied prose criteria evaluated by the grading engine per [§ 4.2 Rubric Application Algorithm](#42-rubric-application-algorithm). The string MUST be non-empty (`minLength: 1`). |
| `rubric.<facet>[].notes` | string | no | Optional human-readable notes. Not consumed by the grading engine; not propagated to the PDF or the persistence layer. |

### 2.2 Grade Enum: A–F Only

The rubric input schema's `grade` enum is **exactly** `[A, B, C, D, F]`. The schema deliberately excludes the special downstream values `TBD`, `N/A`, and `InsufficientData`. Those values are emitted by the grading engine and downstream renderers based on data-availability conditions and the [Rule R5](../template.md#r5--complexity-placeholder-integrity) Complexity-lock — they are NEVER supplied by the rubric author and MUST NOT appear in any rubric document. A rubric document containing a `grade` value outside `{A, B, C, D, F}` fails JSON Schema validation and surfaces as `InsufficientData` per [§ 7 Failure Modes & Insufficient Data](#7-failure-modes--insufficient-data).

The persisted grade-history record's `grade` field, by contrast, uses the broader enum `[A, B, C, D, F, TBD, N/A, InsufficientData]` per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) — it is the union of values the rubric author may supply and values the engine and the persistence layer may emit. The two enums are deliberately distinct: the input enum is what the user authors; the output enum is what the system records.

## 3. Authoring a Rubric

A rubric is **author-supplied at generation time** per [Rule R1](../template.md#r1--rubric-editability). The report author creates a YAML or JSON document conforming to [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json), passes it to the template invocation as the `rubric` input, and the engine consumes it for the duration of that single run. No rubric content is persisted by the engine itself — the rubric is a runtime input, not a configuration setting; subsequent runs may use the same rubric document or a different one. (The persisted artifacts of a run are the per-`(application, facet, run_date)` grade-history records documented in [`./grade-history.md`](./grade-history.md), not the rubric.)

### 3.1 Worked Example: Maturity

The user-supplied verbatim example for the Maturity facet is reproduced below in its original form per the AAP § 0.10.2 Verbatim Preservation Rule. The example demonstrates the **smallest possible** complete rubric entry for a single facet at a single grade.

> **Verbatim user-supplied example (preserved per AAP § 0.10.2 Verbatim Preservation Rule):**
>
> "No library out of support = A for Maturity"

This single sentence decomposes into the YAML rubric structure as follows:

- The antecedent — `"No library out of support"` — becomes the `criteria` field of a rubric entry. The `criteria` field is human-authored prose evaluated by the grading engine per [§ 4.2 Rubric Application Algorithm](#42-rubric-application-algorithm).
- The consequent — `"= A for Maturity"` — encodes structurally as the `grade: A` key on the rubric entry, and as the placement of the entry under the `maturity` key of the `rubric` container.

The resulting YAML fragment is:

```yaml
maturity:
  - grade: A
    criteria: "No library out of support"
```

The grading engine evaluates this entry against the per-application Maturity facet's manifest-derived **technical-debt score** (the fraction of dependencies past EOL per endoflife.date — see [`./facets.md`](./facets.md) § Maturity Summary and [`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.technical_debt_score`). When the technical-debt score is `0.0` — i.e., zero out-of-support dependencies — the rubric evaluation matches the criteria `"No library out of support"` and the engine emits grade `A` for the Maturity facet of that application.

This worked example is reproduced verbatim, in identical YAML form, in [`../config/rubric-example.yaml`](../config/rubric-example.yaml) and in [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml). Per the AAP § 0.10.2 No Redundancy Rule, the rubric documents are the canonical fixtures; this section documents the decomposition of the user-supplied sentence into that canonical form.

### 3.2 Authoring Per Facet

Rubric entries are author-supplied prose. The four facets each operate over different raw data — Tech Stack over language-share and IaC artifacts, Maturity over EOL status, Security over CVE counts, Complexity over LOC and contributor metrics — so the criteria language naturally varies per facet. The subsections below illustrate the kind of criteria language report authors typically write for each facet. The rubric author is free to write any criteria text; the schema constrains only the structural shape (`grade` enum, `criteria` non-empty string).

#### Tech Stack

Tech Stack criteria reference the per-application detection outputs documented in [`./facets.md`](./facets.md) § Tech Stack Summary: language % share by file count, cloud provider count and identification, and vendor/framework concentration extracted from dependency manifests. Illustrative examples:

```yaml
tech_stack:
  - grade: A
    criteria: "Modern, actively-supported tech stack on a single primary cloud; vendor and framework choices are well-known industry standards."
  - grade: C
    criteria: "Mixed tech stack with multiple legacy components OR multiple primary clouds; vendor/framework choices include at least one niche technology."
  - grade: F
    criteria: "Deprecated language(s) or framework(s) with no active community; cloud platform is end-of-support."
```

#### Maturity

Maturity criteria reference the per-application **technical-debt score**, EOL status counts, and runtime version staleness, all derived from manifest analysis and endoflife.date lookups per [`./facets.md`](./facets.md) § Maturity Summary. The verbatim user-supplied example is preserved at grade A:

```yaml
maturity:
  - grade: A
    criteria: "No library out of support"
  - grade: C
    criteria: "Between 10% and 25% of tracked dependencies are out of support per endoflife.date."
  - grade: F
    criteria: "Majority of tracked dependencies are past EOL per endoflife.date (more than 50%)."
```

#### Security

Security criteria reference the four CVE severity-tier counts (Critical, High, Medium, Low) and the total count per [Rule R4](../template.md#r4--cve-severity-breakdown). The CVSS-to-severity-tier mapping is the canonical table in [`../config/facets.yaml`](../config/facets.yaml) `severity_tier_mapping`; the rubric uses the tier names directly. Per [Rule R9](../template.md#r9--cve-attribution), every count is sourced from a scan with a recorded scan timestamp (ISO 8601) and source database label (NVD, OSV, or both) — see [`./facets.md`](./facets.md) § Security Summary and [`../docs/api-integrations.md`](./api-integrations.md). Illustrative examples:

```yaml
security:
  - grade: A
    criteria: "Zero Critical CVEs and zero High CVEs across all tracked dependencies."
  - grade: C
    criteria: "At most 1 Critical CVE OR at most 15 High CVEs."
  - grade: F
    criteria: "More than 5 Critical CVEs."
```

#### Complexity

The Complexity facet rubric is **locked to an empty array** in the canonical initial state per [Rule R5](../template.md#r5--complexity-placeholder-integrity) — see [§ 5 Complexity Lock](#5-complexity-lock-rule-r5) for the full lock semantics. While the array is empty, the engine emits `TBD` and the PDF renderer emits the literal placeholder label `Grade: TBD — definition pending`. The canonical empty-array example is in [`../config/rubric-example.yaml`](../config/rubric-example.yaml):

```yaml
complexity: []
```

When the report author later supplies explicit Complexity thresholds (the unlocked state per [§ 5.2 Unlocked State](#52-unlocked-state)), the entries follow the **same shape** as the other facet rubrics — one or more `{grade, criteria}` objects under the `complexity` key. The criteria typically reference the raw proxy metrics rendered alongside the Complexity cell per [`./facets.md`](./facets.md) § Complexity Summary: lines of code (LOC), file count, distinct contributor count from git history. An illustrative future-state Complexity rubric (NOT to be authored in [`../config/rubric-example.yaml`](../config/rubric-example.yaml) per [Rule R5](../template.md#r5--complexity-placeholder-integrity)) looks like:

```yaml
complexity:
  - grade: A
    criteria: "Under 10,000 LOC AND under 100 source files AND at least 3 active contributors."
  - grade: F
    criteria: "Over 500,000 LOC OR fewer than 1 active contributor in the past 12 months."
```

Authoring Complexity entries in the canonical initial-state file [`../config/rubric-example.yaml`](../config/rubric-example.yaml) — even illustrative — would conflict with [Rule R5](../template.md#r5--complexity-placeholder-integrity) and is prohibited; the example above is shown here for illustrative purposes only and lives in this documentation page exclusively.

### 3.3 File Locations

The rubric ecosystem is materialized in three files within the package; each plays a distinct role.

| File | Role | Complexity Rubric State |
|---|---|---|
| [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) | JSON Schema Draft 2020-12 contract — the single source of truth for the structural shape of the rubric document. `$id`: `urn:blitzy:technology-estate-report:rubric:v0.1.0`. | Schema admits `complexity: []` via `$defs.facetRubricComplexity` (`minItems: 0`); admits non-empty Complexity rubric via the same `rubricEntry` shape. |
| [`../config/rubric-example.yaml`](../config/rubric-example.yaml) | Worked CONFIG example — illustrative, minimal, and **canonical initial state** — intended for documentation, validation, and "first-touch" learning. The verbatim user-supplied example "No library out of support = A for Maturity" is preserved in this file. | Empty (`complexity: []`) per [Rule R5](../template.md#r5--complexity-placeholder-integrity). |
| [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) | Production-ready PRODUCTION example — covers all four facets with annotated thresholds; intended as a copy-edit starting point for the report author. | MAY include a non-empty Complexity rubric to demonstrate the [§ 5.2 Unlocked State](#52-unlocked-state); see the file itself for its rubric content. |

Cross-reference: the configuration documentation page [`./configuration.md`](./configuration.md) describes the configuration files of the package; this `grading-engine.md` page describes how the rubric is **applied** by the engine.


## 4. Evaluation Procedure

The evaluation procedure is the core algorithm of the grading engine. It is invoked once per template execution and produces one persistence record per `(application, facet)` pair in the run scope. The procedure is decomposed into the per-application, per-facet loop ([§ 4.1](#41-per-application-per-facet-loop)), the rubric-application algorithm that operates inside the loop body ([§ 4.2](#42-rubric-application-algorithm)), the determinism property that the algorithm honors ([§ 4.3](#43-determinism-property)), and the output format the procedure produces ([§ 4.4](#44-output-format)).

### 4.1 Per-Application, Per-Facet Loop

The procedure iterates over the run scope and emits one grade per `(application, facet)` pair. Pseudocode follows; the canonical implementation contract is the data flow described here.

1. **Receive inputs from the template entry point:**
   - `run_date` — an ISO 8601 datetime captured **once per run invocation** by [`../template.md`](../template.md) and propagated unchanged through the loop. All persistence records produced by this run share the same `run_date` per [`./grade-history.md`](./grade-history.md) § 2.3.
   - `rubric` — the user-supplied rubric document, already validated against [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json).
   - `repository_scope` — the ordered list of `application_id` values (each in `org/repo` form per [Rule R7](../template.md#r7--application-identity-stability)) to be processed in this run.
   - `analyzers` — the four facet analyzers, each returning the per-application raw data documented in [`./facets.md`](./facets.md). Per [Gate 9](../template.md#614-gate-9--integration-wiring-verification), every analyzer MUST be reachable from this loop and exercised by at least one end-to-end test.

2. **For each `application_id` in `repository_scope`:**
   1. **For each `facet` in the canonical order `[tech_stack, maturity, security, complexity]`:**
      1. **Retrieve raw data** from the corresponding analyzer for this `application_id`. Raw data is the per-facet output documented in [`./facets.md`](./facets.md): for Tech Stack, the language % share / cloud provider count / vendor-framework set; for Maturity, the technical-debt score and per-product EOL detail; for Security, the four severity-tier counts plus total plus scan metadata per [Rule R9](../template.md#r9--cve-attribution); for Complexity, the raw proxy metrics (LOC, file count, contributor count). If raw data is unavailable (the analyzer signaled failure or one of the facet's [`../config/facets.yaml`](../config/facets.yaml) `insufficient_data_conditions` triggered), record this fact for use in the rubric-application algorithm.
      2. **Look up the facet rubric** as `rubric.<facet>` from the user-supplied rubric document. For Complexity, this lookup yields either an empty array (locked state per [Rule R5](../template.md#r5--complexity-placeholder-integrity)) or a non-empty array (unlocked state).
      3. **Apply the rubric-application algorithm** ([§ 4.2](#42-rubric-application-algorithm)) using the raw data and the facet rubric as inputs. The algorithm emits exactly one of: an A–F letter grade; `TBD` (Complexity-only, locked state); `InsufficientData`.
      4. **Look up the prior grade** for `(application_id, facet)` from the persistence layer per [`./grade-history.md`](./grade-history.md) § 4 Retrieval Procedure. The prior grade is needed for the inline cell rendering at PDF time per [Rule R3](../template.md#r3--grade-history-fidelity); it is NOT consumed by the grading engine itself (the engine emits only the current-run grade — the prior grade is rendered by the PDF renderer per [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format). The current and prior grades together populate the rendered cell.
      5. **Persist the current run's grade record** by writing a new row to the persistence layer per [`./grade-history.md`](./grade-history.md) and per the schema [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json). The record's composite key is `(application_id, facet, run_date)`; the `grade` field carries the value emitted in step 3; the `scan_metadata` field carries the per-facet scan timestamp and source database labels for the Security facet per [Rule R9](../template.md#r9--cve-attribution).

3. **Emit the run's results** to the PDF renderer in the form of the report-output data structure documented in [`../schemas/report-output.schema.json`](../schemas/report-output.schema.json) and rendered into the PDF per [`./pdf-output.md`](./pdf-output.md).

The loop is the canonical execution point at which the seven analysis components — tech stack detector, maturity analyzer, CVE scanner, complexity extractor, grading engine, grade persistence store, PDF renderer — are wired together. Per [Gate 9](../template.md#614-gate-9--integration-wiring-verification), the component reachability matrix in [`./architecture.md`](./architecture.md) traces each component's reachability through this loop.

### 4.2 Rubric Application Algorithm

The rubric-application algorithm is the inner-loop operation that, given a facet's raw data and the corresponding rubric array, emits exactly one grade value. The algorithm is deliberately simple and deterministic; the bulk of grading semantics live in the **author-supplied** `criteria` strings, not in the algorithm itself.

#### 4.2.1 Algorithm for Tech Stack, Maturity, Security

For the three "always-rubric'd" facets — Tech Stack, Maturity, Security — the algorithm is:

1. **If raw data is unavailable** (the analyzer signaled failure or an `insufficient_data_conditions` from [`../config/facets.yaml`](../config/facets.yaml) triggered for this facet on this application), emit `InsufficientData` and stop. Do NOT consult the rubric. This is the [Rule R2](../template.md#r2--facet-completeness) failure-mode contract: failed-data-source cells render `Insufficient Data` rather than an inferred grade.
2. **Otherwise, iterate the rubric entries in canonical grade order** A → B → C → D → F. The canonical grade order is the natural order of the `grade` enum in [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json), reading from highest (`A`) to lowest (`F`). The rubric author SHOULD supply rubric entries in this order; the engine treats the order as canonical even if the rubric document supplies entries in a different order.
3. **For each rubric entry**, evaluate whether the raw data satisfies the entry's `criteria` text. Criteria evaluation is the application of the author-supplied prose criteria to the per-facet raw data; see [§ 4.2.3 Criteria Evaluation Semantics](#423-criteria-evaluation-semantics).
4. **Emit the first matching grade.** When the iteration finds a rubric entry whose `criteria` is satisfied, emit that entry's `grade` and stop.
5. **Catch-all fallback.** If the iteration completes without finding a matching entry — i.e., no rubric entry's `criteria` is satisfied by the raw data — emit grade `F`. This convention ("F is the catch-all worst grade") guarantees that every rubric application that operates on present raw data emits a defined grade, never an empty value. Authors can avoid the catch-all by ensuring their rubric's grade-F entry's `criteria` is unconditionally satisfied (e.g., `"Any application not matching grades A–D"`).

The "first matching grade" rule means rubric authors SHOULD write criteria from most-stringent (grade A) to least-stringent (grade F). A poorly-ordered rubric — for example, one whose grade-F criteria match every application — would emit grade F for every application even when the raw data would have matched a higher grade's criteria. The order of rubric entries in the YAML/JSON document is significant.

#### 4.2.2 Algorithm for Complexity

For the Complexity facet, the algorithm branches on the rubric's emptiness:

1. **If `rubric.complexity` is an empty array** (the locked state per [Rule R5](../template.md#r5--complexity-placeholder-integrity) and [§ 5.1 Locked State](#51-locked-state)), emit `TBD` and stop. Do NOT consult the raw data, do NOT iterate the (empty) rubric. The PDF renderer translates `TBD` into the literal placeholder label `Grade: TBD — definition pending` per [§ 5 Complexity Lock](#5-complexity-lock-rule-r5).
2. **If `rubric.complexity` is non-empty** (the unlocked state per [§ 5.2 Unlocked State](#52-unlocked-state)), apply the [§ 4.2.1 algorithm](#421-algorithm-for-tech-stack-maturity-security) above using `rubric.complexity` as the rubric and the Complexity raw data (LOC, file count, contributor count) as the input. The same emission rules apply: `InsufficientData` if raw data is unavailable; first matching grade otherwise; catch-all to grade `F` if no entry matches.

The branch is gated **purely** on the `rubric.complexity` array's emptiness — the engine does not infer a Complexity grade from raw data alone, ever. This is the structural realization of [Rule R5](../template.md#r5--complexity-placeholder-integrity)'s prohibition on backfill: as long as the user has not supplied an explicit Complexity rubric, the Complexity column renders the placeholder label; the moment the user supplies a rubric, Complexity becomes a normal A–F-graded facet.

#### 4.2.3 Criteria Evaluation Semantics

Each rubric entry's `criteria` is an author-supplied prose string evaluated by the grading engine against the per-application, per-facet raw data described in [`./facets.md`](./facets.md). Three observations on criteria evaluation are worth preserving here:

- **Criteria are author-authored, not engine-authored.** Per [Rule R1](../template.md#r1--rubric-editability), no thresholds are hardcoded in the template. The criteria text fully determines the grading semantics; the engine's role is to evaluate, not to interpret beyond what the criteria state.
- **Raw data is structured, not free-text.** Each facet's raw-data fields are documented in [`./facets.md`](./facets.md) and in [`../config/facets.yaml`](../config/facets.yaml) — language % share, technical-debt score, severity-tier counts, LOC, etc. Criteria are evaluated against these structured fields. Authors who write criteria referring to fields not present in the raw data — for example, criteria referencing runtime-monitoring data, which is excluded from the template per [`../template.md`](../template.md) § 4 Boundaries & Preservation — produce a non-matching rubric entry and fall through to the catch-all per [§ 4.2.1](#421-algorithm-for-tech-stack-maturity-security).
- **Criteria are deterministic.** Per [§ 4.3 Determinism Property](#43-determinism-property), the same `(raw_data, criteria)` pair MUST evaluate the same way on every invocation. The criteria text is plain prose authored by the report author; the engine's evaluation is the deterministic application of that prose to the structured raw data.

### 4.3 Determinism Property

The grading engine is deterministic: given the same `(raw_data, rubric)` input pair, the engine MUST emit the same grade. Two distinct invocations of the engine with byte-identical inputs MUST produce byte-identical persistence records (modulo only the `run_date` field, which by definition differs per run — see [`./grade-history.md`](./grade-history.md) § 2.3). The engine MUST NOT consult any external state (no live API calls, no random-number generators, no clock reads outside the propagated `run_date` value) during rubric evaluation.

Determinism is the **structural prerequisite** for [Rule R1's verification clause](../template.md#r1--rubric-editability) — "generating a report with two different rubric inputs for the same dataset produces two different grade outputs" — to be testable. The verification clause is meaningful only if the same rubric reliably produces the same grade for the same dataset; otherwise the test would be ambiguous (two runs with the same rubric could produce different grades, masking the rubric-driven difference). Determinism is also required for the [Rule R7](../template.md#r7--application-identity-stability) verification clause — "grade history for a repo is continuous across three sequential runs with no duplicate or orphaned entries" — to hold: the grade-history continuity check assumes that re-running the engine against unchanged raw data and an unchanged rubric yields the same grade as the prior run, so that any observed grade change is attributable to a change in the raw data, not to engine variability.

### 4.4 Output Format

The procedure's output is a set of persistence records, one per `(application_id, facet, run_date)` triple, conforming to [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json). Each record's `grade` field uses the enumeration `[A, B, C, D, F, TBD, N/A, InsufficientData]`. The grading engine itself emits values from the subset `{A, B, C, D, F, TBD, InsufficientData}`; the `N/A` value is **never** emitted by the engine as a current grade. `N/A` is reserved for the prior-grade slot of a rendered cell when no prior run exists for the `(application_id, facet)` pair, per [Rule R3](../template.md#r3--grade-history-fidelity) and [`./grade-history.md`](./grade-history.md) § 5 Rendering — it is materialized at PDF rendering time, not at grading time.

The cell-rendering format that combines a current-run grade record with a prior-run grade record into the verbatim cell text `B  ←  prev: C  |  2025-10-01` (per [Rule R3](../template.md#r3--grade-history-fidelity)) is documented in [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format. The grading engine produces the **inputs** to that rendering — current and prior grade records — but does not perform the rendering itself; rendering is a downstream concern of the PDF renderer per the Gate 9 component reachability matrix in [`./architecture.md`](./architecture.md).


## 5. Complexity Lock (Rule R5)

The Complexity facet has **distinct evaluation semantics** from the other three facets in service of [Rule R5](../template.md#r5--complexity-placeholder-integrity). The lock is the structural mechanism that prevents the engine from emitting a Complexity letter grade until the report author has supplied an explicit Complexity rubric. The lock has two states — locked and unlocked — and the transition between them is gated **purely** on the emptiness of the `rubric.complexity` array, not on raw data, not on configuration, not on a feature flag.

### 5.1 Locked State

When the supplied rubric's `complexity` array is empty (`complexity: []` — the canonical initial state per [`../config/rubric-example.yaml`](../config/rubric-example.yaml)), the grading engine emits `TBD` for the Complexity facet for every application in the run, regardless of the per-application Complexity raw-data values. This is the **default** state of the engine in v0.1.0 and is the default state for every report author who has not yet supplied a Complexity rubric.

The PDF renderer translates the engine's `TBD` emission into the literal placeholder label `Grade: TBD — definition pending` per [Rule R5](../template.md#r5--complexity-placeholder-integrity). The literal string is preserved **byte-for-byte** with the em-dash U+2014 wherever it appears: in this section, in [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format, in the Complexity cell of every rendered PDF, and in the canonical machine-readable copy at [`../config/facets.yaml`](../config/facets.yaml) `facets.complexity.placeholder_label` and [`../config/facets.yaml`](../config/facets.yaml) `rendering_defaults.tbd_placeholder_label`. The literal — `Grade: TBD — definition pending` — uses the em-dash character U+2014 (UTF-8 bytes `0xE2 0x80 0x94`), not a hyphen-minus and not an en-dash; verifying the byte sequence is part of the [§ 6 R1 Verification Procedure](#6-r1-verification-procedure) regression check and the validation harness in [`./validation.md`](./validation.md).

While the lock is engaged, the Complexity cell of every matrix row also renders the raw proxy metrics — LOC, file count, contributor count — alongside the placeholder label. The raw proxy metrics are emitted by the Complexity Extractor analyzer per [`./facets.md`](./facets.md) § Complexity Summary and are rendered into the Complexity cell by the PDF renderer per [`./pdf-output.md`](./pdf-output.md). The grading engine itself does NOT consume the raw proxy metrics in the locked state — it simply emits `TBD` for Complexity without consulting raw data — but the metrics ARE emitted by the analyzer and rendered in the cell by the PDF renderer regardless of lock state.

### 5.2 Unlocked State

When the supplied rubric's `complexity` array is **non-empty** — i.e., the report author has supplied at least one `{grade, criteria}` rubric entry under the `complexity` key — the engine evaluates Complexity in the same way as the other three facets per [§ 4.2.1 Algorithm for Tech Stack, Maturity, Security](#421-algorithm-for-tech-stack-maturity-security). The unlock condition is the **presence** of at least one rubric entry; the schema admits this transition automatically via [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) `$defs.facetRubricComplexity` (`minItems: 0`, items conform to the same `rubricEntry` shape).

The unlocked-state output is an A–F letter grade per application per the standard [§ 4.2.1 algorithm](#421-algorithm-for-tech-stack-maturity-security): catch-all to grade `F` if no entry matches; `InsufficientData` if Complexity raw data is unavailable. The PDF renderer renders the emitted grade in the Complexity cell using the standard cell-rendering format per [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format. The placeholder label `Grade: TBD — definition pending` MUST NOT be rendered in the unlocked state — it is the literal of the locked state and is not a valid render output once the rubric is supplied.

The transition from locked to unlocked happens at a **single point in time** for the entire portfolio: the first run after the report author supplies a non-empty Complexity rubric. Prior runs that emitted `TBD` for Complexity remain immutable in the persistence layer per [`./grade-history.md`](./grade-history.md) § 3 Immutability Contract; subsequent runs emit A–F grades. The Executive Summary trend computation in [`./executive-summary.md`](./executive-summary.md) § Trend versus Prior Run handles the locked-to-unlocked transition by treating the prior `TBD` grade as a non-comparable value (a `TBD → A`/`B`/`C`/`D`/`F` transition is not an "improvement" or "regression" — it is the **first defined Complexity grade** for that application).

### 5.3 Lock Rationale

The Complexity Lock structurally realizes [Rule R5](../template.md#r5--complexity-placeholder-integrity) (verbatim text in [`../template.md`](../template.md) § 5 R5; not duplicated here per the AAP § 0.10.2 No Redundancy Rule). The rule mandates that the Complexity column MUST be present in every run, MUST render the raw proxy metrics, and MUST NOT be removed, collapsed, or backfilled with an inferred grade until an explicit rubric is provided. Three structural commitments follow:

- **Column presence is unconditional.** The Complexity column MUST appear in every matrix row of every run per [Rule R2](../template.md#r2--facet-completeness) (no facet column may be omitted) and [Rule R5](../template.md#r5--complexity-placeholder-integrity) (no removal, no collapse). The locked state does not remove or hide the column; it renders the placeholder label in place of an A–F grade.
- **Raw proxy metrics are unconditional.** The raw proxy metrics — LOC, file count, contributor count — are rendered in every Complexity cell whether locked or unlocked, per [`./facets.md`](./facets.md) § Complexity Summary. The Complexity Extractor analyzer emits the metrics; the PDF renderer renders them; neither component is skipped in the locked state. This is the "MUST render raw proxy metrics" half of the [Rule R5](../template.md#r5--complexity-placeholder-integrity) clause.
- **No backfill, no inference.** The engine does NOT and MUST NOT infer a Complexity grade from the raw proxy metrics in the absence of a rubric. The locked-state algorithm in [§ 4.2.2 Algorithm for Complexity](#422-algorithm-for-complexity) emits `TBD` without consulting the raw data — exactly because consulting the raw data and emitting a heuristic A–F grade would be a backfill in the [Rule R5](../template.md#r5--complexity-placeholder-integrity) sense.

The canonical machine-readable source of truth for the placeholder label literal is [`../config/facets.yaml`](../config/facets.yaml) at two locations: `facets.complexity.placeholder_label` and `rendering_defaults.tbd_placeholder_label`. Both literals are byte-for-byte `Grade: TBD — definition pending` with em-dash U+2014. Any documentation or rendering location that emits the placeholder label MUST consume one of these two configuration values rather than embedding the literal in code or in another document.


## 6. R1 Verification Procedure

[Rule R1](../template.md#r1--rubric-editability) carries a verification clause that is reproduced verbatim below per the AAP § 0.10.2 Verbatim Preservation Rule:

> **Verification (verbatim from [`../template.md`](../template.md) § 5 R1):** generating a report with two different rubric inputs for the same dataset produces two different grade outputs

The verification procedure operationalizes this clause as a step-by-step test that a reviewer (or the validation harness in [`./validation.md`](./validation.md)) executes against a designated test repository. The procedure does not depend on any specific test repository's content — only on the engine's determinism property (per [§ 4.3](#43-determinism-property)) and on the engine's per-run consumption of a fresh rubric.

### 6.1 Procedure

1. **Fix the dataset and run with rubric A.** Designate a single test repository (a real GitHub or GitLab repository whose ingested artifacts are stable across the duration of the test) and capture its raw analyzer outputs at a fixed point in time. The "dataset" of the verification clause is this repository's ingested artifacts; per [Gate 1](../template.md#611-gate-1--end-to-end-boundary-verification), the repository MUST be a real repository (not a mock or stub). The validation harness in [`./validation.md`](./validation.md) § Single-Command Execution Path uses a designated test repository per [Gate 10](../template.md#615-gate-10--test-execution-binding); the same repository is appropriate for this verification. Generate a report against this repository using the [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) production-ready rubric (or any other valid rubric of the report author's choosing) — call this rubric A. Capture the per-`(application, facet)` grade outputs emitted by the engine, either by reading them from the persisted grade-history records per [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) or by inspecting the rendered PDF.

2. **Construct rubric B.** Construct a deliberately-different rubric — rubric B — by modifying rubric A in a way that is guaranteed to produce a different grade for at least one `(application, facet)` pair on the test repository. The simplest construction is to **invert** the grade thresholds of one facet: for example, take a copy of rubric A and swap the `criteria` text of the grade-A and grade-F entries of the Maturity rubric, so that the verbatim user example "No library out of support" now maps to grade `F` (rubric B's `maturity` grade-F entry) rather than grade `A` (rubric A's `maturity` grade-A entry). Other constructions are valid as long as they produce a different `(application, facet)` grade for at least one pair on the test repository — for example, tightening the grade-A threshold of the Security rubric from "Zero Critical CVEs and zero High CVEs" to "Zero Critical CVEs, zero High CVEs, and zero Medium CVEs" so that an application with even one Medium CVE that previously received grade A now falls through to a lower grade.

3. **Run with rubric B.** Generate a second report using rubric B against the **same** test repository. Use a `run_date` strictly later than the rubric A run's `run_date` so that the two runs produce distinct grade-history records per the unique-key constraint on `(application_id, facet, run_date)` documented in [`./grade-history.md`](./grade-history.md) § 2.4. Capture the per-`(application, facet)` grade outputs emitted by the engine in this second run.

4. **Compute and assert the grade-output diff.** Compute the diff of the per-`(application, facet)` grades between the rubric A run and the rubric B run; the diff is the set of `(application, facet)` pairs whose emitted grade differs between the two runs. The verification passes when the diff set is non-empty — i.e., **at least one `(application, facet)` grade differs between the two runs**. A diff of size zero indicates either that rubric A and rubric B are not effectively different on the test repository (in which case rubric B should be reconstructed in step 2 to produce a difference) or that the engine is not honoring the rubric (in which case [Rule R1](../template.md#r1--rubric-editability) is failing and the engine implementation MUST be debugged).

### 6.2 Cross-References to the Validation Framework

This procedure is part of the [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate) integration sign-off checklist — specifically the **Rubric verification** item. The single-command execution path that runs this procedure as part of the standard validation suite per [Gate 10](../template.md#615-gate-10--test-execution-binding) is documented in [`./validation.md`](./validation.md) § Single-Command Execution Path. The four-item Gate 8 checklist (Live smoke test, API contract verification, Grade history verification, Rubric verification) is documented in [`./validation.md`](./validation.md) § Gate 8.

The engine's [§ 4.3 Determinism Property](#43-determinism-property) is the structural prerequisite for this verification: the diff between the rubric A run and the rubric B run is a deterministic function of `(rubric A, rubric B, dataset)`, and re-running the procedure against the same triple MUST produce the same diff. If two executions of the procedure against the same triple produce different diffs, the engine's determinism is broken and both [Rule R1](../template.md#r1--rubric-editability) and [Rule R7](../template.md#r7--application-identity-stability) verifications are at risk.


## 7. Failure Modes & Insufficient Data

The grading engine emits the literal value `InsufficientData` (which the PDF renderer translates into the cell value `Insufficient Data` per [Rule R2](../template.md#r2--facet-completeness)) whenever a failure mode prevents the engine from emitting an A–F letter grade. The failure-mode contract is binding per [Gate 2](../template.md#612-gate-2--zero-warning-build): every failure surfaces as `Insufficient Data` rather than a silent omission, a suppressed error, or a default-grade fallback. This section enumerates the engine-side failure modes; the comprehensive failure-mode-to-cell-value mapping for all components in the package — including ingestion failures, network failures, and per-facet analyzer failures — lives in [`./troubleshooting.md`](./troubleshooting.md) § Failure-Mode-to-Cell-Value Mapping.

### 7.1 Failure Modes That Surface as `InsufficientData`

The engine emits `InsufficientData` for an `(application, facet)` pair when ANY of the following conditions hold:

- **Rubric is missing the facet entry.** The rubric document does not contain the required `rubric.<facet>` key for the facet being evaluated. This is a JSON Schema validation failure at the rubric document level — `rubric.required` in [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) lists all four facet keys, and a rubric document missing any of them fails schema validation. Per the [§ 4.1 Per-Application, Per-Facet Loop](#41-per-application-per-facet-loop), a rubric that fails schema validation is rejected at the start of the run and every facet of every application emits `InsufficientData`. The engine does not partially process a malformed rubric.
- **Rubric is malformed.** The rubric document fails JSON Schema validation against [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) for any reason other than a missing facet key — e.g., a `grade` value outside `{A, B, C, D, F}`, a `criteria` value of zero length, an unexpected top-level property — see the per-key reference in [§ 2.1](#21-per-key-reference) and the schema document itself. As above, schema validation failure at the rubric level rejects the rubric and emits `InsufficientData` for every `(application, facet)` pair in the run.
- **Per-facet raw data is absent.** The facet analyzer signaled failure or one of the [`../config/facets.yaml`](../config/facets.yaml) `insufficient_data_conditions` for the facet triggered for this application. The conditions are documented per facet:
  - **Tech Stack:** "No source files detected" / "No dependency manifests detected" / "All three sub-detectors (language, cloud, vendor/framework) failed" — see [`../config/facets.yaml`](../config/facets.yaml) `facets.tech_stack.insufficient_data_conditions`.
  - **Maturity:** "No dependency manifests or runtime declarations detected" / "endoflife.date does not track any of the detected products (no slug resolution)" / "endoflife.date API persistently unreachable after retries" — see [`../config/facets.yaml`](../config/facets.yaml) `facets.maturity.insufficient_data_conditions`.
  - **Security:** "SBOM generation failed for all detected ecosystems" / "Both NVD and OSV CVE databases persistently unreachable after retries" / "No dependency manifests detected" — see [`../config/facets.yaml`](../config/facets.yaml) `facets.security.insufficient_data_conditions`.
  - **Complexity:** "No source files detected" / "git history unavailable (e.g., shallow clone or fetch failure)" — see [`../config/facets.yaml`](../config/facets.yaml) `facets.complexity.insufficient_data_conditions`. Note that the Complexity insufficient-data conditions affect the rendering of the raw proxy metrics (LOC, file count, contributor count) but do NOT affect the grade emission while the Complexity rubric is locked: even when raw data is unavailable, the engine emits `TBD` per [§ 4.2.2 Algorithm for Complexity](#422-algorithm-for-complexity) — the locked-state algorithm does not consult raw data. In the unlocked state, however, absent Complexity raw data causes `InsufficientData` per [§ 4.2.1](#421-algorithm-for-tech-stack-maturity-security).
- **External API for a facet is persistently unreachable.** Specifically, the endoflife.date API for the Maturity facet, or **both** NVD and OSV for the Security facet (a single-source unreachable condition is recoverable by falling back to the other source per [`./api-integrations.md`](./api-integrations.md) § OSV API v1; only the both-unreachable condition is a Security failure). Per [Gate 2](../template.md#612-gate-2--zero-warning-build), API unreachability MUST surface as `InsufficientData` rather than a silent omission or a suppressed warning.

### 7.2 What `InsufficientData` Does Not Cover

The `InsufficientData` value is reserved for the failure modes enumerated in [§ 7.1](#71-failure-modes-that-surface-as-insufficientdata) above. Two cases that look adjacent are deliberately handled differently:

- **Catch-all rubric fall-through is grade `F`, not `InsufficientData`.** When raw data is **present** and the rubric iteration completes without any matching entry (per [§ 4.2.1](#421-algorithm-for-tech-stack-maturity-security) step 5), the engine emits grade `F` — the "catch-all worst grade" — rather than `InsufficientData`. The conceptual distinction is that `InsufficientData` means "the engine could not evaluate" while a catch-all-`F` means "the engine evaluated and found the application matches none of the author's grade-A through grade-D criteria, so by convention the application gets the worst defined grade." Authors who want to surface a fall-through as `InsufficientData` MUST not include any catch-all `criteria` and MUST instead let one of the [§ 7.1](#71-failure-modes-that-surface-as-insufficientdata) failure modes trigger.
- **Locked-state Complexity is `TBD`, not `InsufficientData`.** When the Complexity rubric is locked (empty array) per [Rule R5](../template.md#r5--complexity-placeholder-integrity), the engine emits `TBD`, not `InsufficientData`, even if Complexity raw data is unavailable. The locked-state branch in [§ 4.2.2](#422-algorithm-for-complexity) deliberately does not consult raw data — `TBD` reflects the **rubric author's** non-supply of a Complexity rubric, not a data-availability failure.

### 7.3 Cross-References to the Failure-Mode Inventory

The full failure-mode inventory — including failures that occur outside the grading engine (ingestion failures, repository-credential failures, PDF renderer failures) — is in [`./troubleshooting.md`](./troubleshooting.md) § Failure-Mode-to-Cell-Value Mapping. Per [Rule R2](../template.md#r2--facet-completeness), every failure of every kind MUST surface as a populated cell value: `Insufficient Data` for facet-data and engine failures (the grading engine's `InsufficientData` emission); `Grade: TBD — definition pending` for the Complexity locked state (the `TBD` emission); never an empty cell. Per [Gate 2](../template.md#612-gate-2--zero-warning-build), no failure is silently suppressed — all are surfaced via the cell-rendering literals documented in [`../config/facets.yaml`](../config/facets.yaml) `rendering_defaults` and [`./pdf-output.md`](./pdf-output.md) § Cell Rendering Format.

## 8. Cross-References

For reviewer convenience, the table below enumerates every relative-path link this document makes outbound. Every link resolves within the [`templates/technology-estate-report/`](../) package; no link reaches outside the package per the AAP § 0.10.2 Standalone Package Rule.

| Reference | Purpose |
|---|---|
| [`../template.md`](../template.md) | Canonical, verbatim text of [Rule R1](../template.md#r1--rubric-editability) (rubric editability), [Rule R2](../template.md#r2--facet-completeness) (facet completeness — `Insufficient Data` cell value), [Rule R3](../template.md#r3--grade-history-fidelity) (prior-grade `N/A` slot), [Rule R5](../template.md#r5--complexity-placeholder-integrity) (Complexity placeholder integrity), [Rule R7](../template.md#r7--application-identity-stability) (application identity stability), [Rule R9](../template.md#r9--cve-attribution) (CVE attribution); and the [Gate 1](../template.md#611-gate-1--end-to-end-boundary-verification), [Gate 2](../template.md#612-gate-2--zero-warning-build), [Gate 8](../template.md#613-gate-8--integration-sign-off-checklist-independent-of-unit-test-pass-rate), [Gate 9](../template.md#614-gate-9--integration-wiring-verification), and [Gate 10](../template.md#615-gate-10--test-execution-binding) validation gates. |
| [`../schemas/rubric.schema.json`](../schemas/rubric.schema.json) | JSON Schema Draft 2020-12 contract for the user-supplied rubric input. `$id`: `urn:blitzy:technology-estate-report:rubric:v0.1.0`. Encodes the structural shape of the `rubric` document: required `tech_stack`, `maturity`, `security`, `complexity` keys; `grade` enum `[A, B, C, D, F]`; `criteria` `minLength: 1`; `complexity` array `minItems: 0` per [Rule R5](../template.md#r5--complexity-placeholder-integrity). |
| [`../schemas/grade-history.schema.json`](../schemas/grade-history.schema.json) | JSON Schema for the persisted per-`(application_id, facet, run_date)` grade-history record. The `grade` field uses the broader enum `[A, B, C, D, F, TBD, N/A, InsufficientData]` (the union of values the rubric author may supply and values the engine and persistence layer may emit). |
| [`../examples/sample-rubric.yaml`](../examples/sample-rubric.yaml) | Production-ready rubric example covering all four facets — copy-edit starting point for the report author. Used as rubric A in the [§ 6 R1 Verification Procedure](#6-r1-verification-procedure). |
| [`../config/rubric-example.yaml`](../config/rubric-example.yaml) | Worked CONFIG example with `complexity: []` — the canonical initial state per [Rule R5](../template.md#r5--complexity-placeholder-integrity). Preserves the verbatim user-supplied example "No library out of support = A for Maturity" in the Maturity grade-A entry. |
| [`../config/facets.yaml`](../config/facets.yaml) | Canonical machine-readable source of truth for the placeholder label literal `Grade: TBD — definition pending` (`facets.complexity.placeholder_label` and `rendering_defaults.tbd_placeholder_label`); for the per-facet `insufficient_data_conditions`; and for the CVSS-to-severity-tier mapping consumed indirectly by the Security facet rubric. |
| [`./facets.md`](./facets.md) | Per-facet raw-data definitions. The grading engine consumes the per-application raw data emitted by the four facet analyzers documented here; rubric `criteria` text references the structured raw-data fields documented per facet. |
| [`./grade-history.md`](./grade-history.md) | Persistence layer documentation. Documents the storage key shape `(application_id, facet, run_date)`, the immutability contract, the retrieval procedure for prior-grade lookup, the rendering rule for the prior-grade slot of each cell (including the `N/A` rule when no prior run exists per [Rule R3](../template.md#r3--grade-history-fidelity)), the heterogeneous-scope flow per [Rule R10](../template.md#r10--new-repo-compatibility), and the new-repository onboarding procedure. |
| [`./pdf-output.md`](./pdf-output.md) | PDF output contract. Documents the cell-rendering format `B  ←  prev: C  |  2025-10-01` per [Rule R3](../template.md#r3--grade-history-fidelity), the placeholder label rendering for the Complexity locked state per [Rule R5](../template.md#r5--complexity-placeholder-integrity), and the `Insufficient Data` cell rendering per [Rule R2](../template.md#r2--facet-completeness). |
| [`./api-integrations.md`](./api-integrations.md) | External API contracts (GitHub, GitLab, endoflife.date, NVD CVE API v2.0, OSV API v1). Documents the rate-limit and retry semantics whose failure modes surface as `InsufficientData` per [§ 7 Failure Modes & Insufficient Data](#7-failure-modes--insufficient-data). |
| [`./architecture.md`](./architecture.md) | Component reachability matrix. Documents how the seven analysis components — including the grading engine — are wired together via the [§ 4.1 Per-Application, Per-Facet Loop](#41-per-application-per-facet-loop) entry point per [Gate 9](../template.md#614-gate-9--integration-wiring-verification). |
| [`./executive-summary.md`](./executive-summary.md) | Portfolio-level aggregation rules. Documents how the grading engine's per-application grade outputs are aggregated into the portfolio-level grade distribution and trend computations rendered on PDF page 1. |
| [`./validation.md`](./validation.md) | Validation harness procedures. Documents the Gate 8 four-item integration sign-off checklist (including the Rubric verification item that operationalizes [§ 6 R1 Verification Procedure](#6-r1-verification-procedure)) and the [Gate 10](../template.md#615-gate-10--test-execution-binding) single-command execution path. |
| [`./troubleshooting.md`](./troubleshooting.md) | Comprehensive failure-mode inventory. Documents the failure-mode-to-cell-value mapping for every failure mode in the package; the grading engine's failure modes per [§ 7](#7-failure-modes--insufficient-data) are a subset. |
| [`./configuration.md`](./configuration.md) | Configuration file reference. Documents the configuration files of the package, including the [`../config/rubric-example.yaml`](../config/rubric-example.yaml) worked example. |
