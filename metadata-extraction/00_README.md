# Corewell Health — Snowflake Metadata Extraction Pack

**Prepared by TEKsystems Team (TGS)** · Corewell Health Snowflake DD&A · v1.0

Read-only metadata extraction to establish the current-state baseline for the
Strategy & Market Intelligence data model engagement.

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

Layer classification (Bronze / Silver / Gold / Shared) is derived from schema and
database naming. If Corewell's naming differs, adjust the `CASE` expression in the
`layer_map` CTE — it appears in `01` and is reused conceptually elsewhere.

## Execution order

| # | Script | Answers |
|---|---|---|
| 01 | `01_object_inventory.sql` | What exists, how big, in which layer and environment |
| 02 | `02_column_profiling.sql` | What columns exist, candidate keys/grain, **PHI/PII candidates** |
| 03 | `03_governance_security.sql` | Masking, row access, tags, roles, grants |
| 04 | `04_lineage_dependencies.sql` | What depends on what; source→report paths |
| 05 | `05_usage_activity.sql` | What is actually queried; what is dead; what it costs |
| 06 | `06_pipeline_freshness.sql` | Load history (Fivetran/GoAnywhere), tasks, staleness |
| 07 | `07_environment_drift.sql` | Dev vs Test vs Prod differences |
| 08 | `08_optional_data_profiling.sql` | **Opt-in.** Real cardinality/null rates for grain confirmation |

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

1. `01` — all blocks (baseline inventory)
2. `02` — blocks 1, 4, 5 (columns, PHI candidates, key candidates)
3. `03` — all blocks (governance — needed for the Tim Burer session)
4. `06` — block 2 (load history — confirms Fivetran/GoAnywhere behaviour)

If any script fails on privileges, send the error text rather than the results and we
will supply a reduced-scope version.

## Open items these scripts are designed to resolve

- Whether Epic lands via **Clarity** or **Caboodle** (visible in source object naming — `01`, `06`)
- Purpose of the **`Common`** and **`Workspace`** schemas seen in the architecture diagram (`01`, `05`)
- Whether **masking is role-based or tag-based**, and where it is enforced (`03`)
- Whether BI tools read only from **Shared**, or reach into Gold/Silver directly (`04`, `05`)
- Grain of Epic vs MHA vs Strata objects, for the conceptual model (`02`, `08`)
- Dev/Test/Prod completeness — Prod was described as most complete (`07`)

---

*Questions on any script: TEKsystems Team.*
