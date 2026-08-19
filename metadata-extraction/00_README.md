# Corewell Health — Snowflake Metadata Extraction Pack

**Prepared by TEKsystems Team (TGS)** · Corewell Health Snowflake DD&A · v1.1

Read-only metadata extraction to establish the current-state baseline for the
Strategy & Market Intelligence data model engagement.

---

## Confirmed since v1.0 (2026-08-19 call)

Five facts were confirmed that change how these scripts classify objects:

1. **Shared is views** over Gold, built for reporting.
2. **Gold holds actual data, with history** (durable, not pass-through).
3. **Database naming is `<ENV>_<LAYER>_<DOMAIN>`** for Bronze/Silver/Gold —
   e.g. `DEV_BRONZE_MHA`, `DEV_SILVER_MHA`, `DEV_GOLD_MHA` — and `<SH>_<DOMAIN>`
   for Shared, e.g. `SH_MHA`. **Layer and domain live in the database name, not
   the schema name.** Scripts `01`, `04`, and `07` have been rewritten to parse
   this pattern directly (`REGEXP_SUBSTR` on `DATABASE_NAME`) instead of
   guessing from schema names — the earlier schema-based heuristic was wrong
   for this account and has been replaced, not just supplemented.
4. **The Shared views carry no filtering logic** — confirmed as
   `CREATE VIEW ... AS SELECT * FROM GOLD...` with no `WHERE`, no masking
   expressions in the view body itself.
5. **Masking/RLS policies exist but are not yet confirmed** as correctly
   attached or enforced.

**Facts 4 + 5 together are the most urgent open item.** A bare view has no
protection of its own — whatever governs PHI exposure at Shared must come
entirely from Snowflake policy objects attached upstream, and that attachment
is unverified. Until `03` Blocks 3 and 5 are run, **treat PHI protection at
Shared as unconfirmed, not as present.**

**Open question for Tim Burer:** does `SH_<DOMAIN>` (no env prefix) mean one
Shared database serves all environments, or is this simply the only Shared
example seen so far and a per-env pattern exists elsewhere? `01` Block 2b
surfaces every Shared database found so this can be checked directly.

---

## What this is for

Corewell confirmed in discovery that **no formal data model exists today**. Before a
conceptual/logical model can be designed across **Epic**, **MHA Claims** and **Strata**,
we need an accurate picture of what is physically in Snowflake now — objects, columns,
grain candidates, sensitive data, governance controls, and what is actually being used.

These scripts produce that picture without touching any row-level data.

## Safety

- **Every script in `01`–`07` is read-only metadata only.** No DDL, no DML, no `SELECT`
  against business tables. They read `SNOWFLAKE.ACCOUNT_USAGE` and `INFORMATION_SCHEMA`.
- **No PHI or PII is returned** by scripts `01`–`07`. Column *names* are returned;
  column *values* are not.
- `08_optional_data_profiling.sql` **does** read table data and is **opt-in only** —
  do not run it without Corewell's explicit approval. See the warning in that file.

## Privileges required

| Script | Needs | Notes |
|---|---|---|
| `01`–`07` | `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database | Usually granted to `ACCOUNTADMIN`; can be granted to a read-only analyst role |
| `04` (access history) | Snowflake **Enterprise Edition** or higher | `ACCESS_HISTORY` is not available on Standard |
| `08` | `SELECT` on the profiled tables | Opt-in only |

To grant a dedicated role rather than using `ACCOUNTADMIN`:

```sql
-- Run as ACCOUNTADMIN
CREATE ROLE IF NOT EXISTS DDA_METADATA_READER;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE DDA_METADATA_READER;
GRANT ROLE DDA_METADATA_READER TO USER <analyst_user>;
```

## Before you run

Each script has a **CONFIGURE** block at the top. Set the database-name pattern that
matches Corewell's environments, for example:

```sql
SET DB_PATTERN = '%';        -- all databases
-- SET DB_PATTERN = 'PROD%'; -- production only
```

Layer and domain classification (Bronze/Silver/Gold/Shared × MHA/Epic/Strata/...)
is now derived from the **confirmed** `<ENV>_<LAYER>_<DOMAIN>` / `<SH>_<DOMAIN>`
database naming pattern in `01`, `04`, and `07`. If any database doesn't match
this pattern, it falls into an `UNCLASSIFIED` bucket in the results rather than
being silently mis-tagged — check that bucket for anything unexpected (it may
mean a domain besides MHA uses different conventions, worth flagging).

## Execution order — updated priority given the 08-19 findings

| # | Script | Answers | Priority |
|---|---|---|---|
| 01 | `01_object_inventory.sql` | What exists, how big; **Block 2b: domain × layer × env coverage matrix** — tests whether Bronze/Silver/Gold are siloed per domain | **Run first** |
| 03 | `03_governance_security.sql` | Masking, row access, tags, roles, grants — **Blocks 3 & 5 resolve the unconfirmed-policy question directly** | **Run second, most urgent** |
| 02 | `02_column_profiling.sql` | What columns exist, candidate keys/grain, **PHI/PII candidates** | |
| 04 | `04_lineage_dependencies.sql` | Dependencies; **now checks both layer-skips and cross-domain edges** — confirms Shared reads only Gold, and whether any domain already crosses into another | |
| 05 | `05_usage_activity.sql` | What is actually queried; what is dead; what it costs | |
| 06 | `06_pipeline_freshness.sql` | Load history (Fivetran/GoAnywhere), tasks, staleness | |
| 07 | `07_environment_drift.sql` | Dev vs Prod differences — **use Blocks 2b/3b/4b**, which pair databases by layer+domain automatically | |
| 08 | `08_optional_data_profiling.sql` | **Opt-in.** Real cardinality/null rates for grain confirmation | |

## ACCOUNT_USAGE latency

`ACCOUNT_USAGE` views lag real time — typically **45 minutes to 3 hours**, and up to
**24 hours** for some views. `INFORMATION_SCHEMA` is real-time but scoped to a single
database and has shorter retention. Where a script offers both, the `ACCOUNT_USAGE`
version is preferred for completeness and the `INFORMATION_SCHEMA` version is provided
as a fallback if `SNOWFLAKE` database access is not granted.

## Returning results

Run each numbered query block separately in Snowsight and export via
**Results → Download → CSV**. Name files `<script>_<block>.csv`, e.g. `02_04_phi_candidates.csv`.

Please return, at minimum:

1. `01` — all blocks, **especially 2b** (domain × layer × env coverage matrix)
2. `03` — all blocks, **especially 3 & 5** (policy attachment + unprotected PHI — resolves the open item from the 08-19 call)
3. `02` — blocks 1, 4, 5 (columns, PHI candidates, key candidates)
4. `04` — block 2 and the cross-domain edges query (confirms Shared→Gold-only and domain silo)
5. `06` — block 2 (load history — confirms Fivetran/GoAnywhere behaviour)

If any script fails on privileges, send the error text rather than the results and we
will supply a reduced-scope version.

## Open items these scripts are designed to resolve

- **Are masking/RLS policies actually attached to Gold/Shared objects?** — the
  single most urgent question after the 08-19 call. `03` Blocks 3 & 5.
- **Is `SH_<DOMAIN>` environment-agnostic**, or does a per-env Shared pattern
  exist elsewhere? `01` Block 2b.
- **Are Bronze/Silver/Gold genuinely siloed per domain**, with zero cross-domain
  conformance today? `01` Block 2b, `04`'s cross-domain edges query.
- Whether Epic lands via **Clarity** or **Caboodle** (visible in source object naming — `01`, `06`)
- Purpose of the **`Common`** and **`Workspace`** schemas seen in the architecture diagram — do
  they exist in this account at all, or were they specific to the diagram's illustrative example? (`01`, `05`)
- Whether BI tools read only from **Shared**, or reach into Gold/Silver directly (`04`, `05`)
- Grain of Epic vs MHA vs Strata objects, for the conceptual model (`02`, `08`)
- Dev vs Prod completeness — Prod was described as most complete (`07`)

---

*Questions on any script: TEKsystems Team.*
