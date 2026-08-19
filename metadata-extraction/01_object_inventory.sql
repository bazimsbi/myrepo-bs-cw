/* ============================================================================
   01 · OBJECT INVENTORY
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  What exists in Snowflake today: databases, schemas, tables, views,
            row counts, storage, and how objects map to the medallion layers.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   RETURNS  No PHI/PII. Object and column names only.
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
-- Adjust to scope the extract. '%' = everything.
SET DB_PATTERN = '%';


/* ---------------------------------------------------------------------------
   BLOCK 1 · Database and schema inventory
   Establishes the environment topology (Dev / Test / Prod) and layer schemas.
   --------------------------------------------------------------------------- */
SELECT
    d.DATABASE_NAME,
    d.DATABASE_OWNER,
    d.IS_TRANSIENT,
    d.RETENTION_TIME                       AS time_travel_days,
    d.CREATED,
    d.LAST_ALTERED,
    d.COMMENT,
    COUNT(s.SCHEMA_NAME)                   AS schema_count
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES d
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA s
       ON s.CATALOG_NAME = d.DATABASE_NAME
      AND s.DELETED IS NULL
      AND s.SCHEMA_NAME <> 'INFORMATION_SCHEMA'
WHERE d.DELETED IS NULL
  AND d.DATABASE_NAME LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY d.DATABASE_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Database naming decode — CONFIRMED convention (2026-08-19 call)

   Corewell confirmed the pattern is <ENV>_<LAYER>_<DOMAIN> for Bronze/Silver/
   Gold databases (e.g. DEV_BRONZE_MHA, DEV_SILVER_MHA, DEV_GOLD_MHA), and a
   separate <SH>_<DOMAIN> pattern for Shared (e.g. SH_MHA) that appears to drop
   the environment segment — OPEN QUESTION: confirm whether SH_<DOMAIN> is
   truly environment-agnostic (one Shared database serving Dev/Test/Prod) or
   whether SH_MHA is just this account's only example so far and a PROD_ or
   per-env Shared convention exists elsewhere. Ask Tim Burer directly.

   This replaces the earlier schema-name-based guess (layer lived in the
   SCHEMA under a shared database) — that assumption was wrong. Layer and
   domain are both encoded in the DATABASE name; schemas within each database
   are expected to be flatter (confirm during this pass).
   --------------------------------------------------------------------------- */
WITH parsed AS (
    SELECT
        d.DATABASE_NAME,
        d.DATABASE_OWNER,
        d.IS_TRANSIENT,
        d.RETENTION_TIME                    AS time_travel_days,
        d.CREATED,
        d.LAST_ALTERED,
        d.COMMENT,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '^[A-Z]+', 1, 1)
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$'
                THEN NULL   -- env not encoded in this pattern — see note above
            ELSE NULL
        END                                  AS env,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '(BRONZE|SILVER|GOLD)', 1, 1)
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$' THEN 'SHARED'
            ELSE NULL
        END                                  AS layer,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '[^_]+$')
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '^SH_(.+)$', 1, 1, 'e')
            ELSE NULL
        END                                  AS domain,
        IFF(d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$|^SH_.+$',
            'MATCHED', 'UNCLASSIFIED — review naming')  AS convention_match
    FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES d
    WHERE d.DELETED IS NULL
      AND d.DATABASE_NAME LIKE $DB_PATTERN
)
SELECT * FROM parsed
ORDER BY convention_match, domain, layer, env;


/* ---------------------------------------------------------------------------
   BLOCK 2b · DOMAIN × LAYER × ENVIRONMENT COVERAGE MATRIX   ** key output **

   Directly tests the hypothesis raised on the 2026-08-19 call: that Bronze/
   Silver/Gold are siloed per source domain (MHA, and presumably EPIC, STRATA,
   TRILLIANT...) with no cross-domain conformed layer today. One row per
   domain; Y/N per layer/env combination found. A domain with Bronze+Silver+
   Gold but every other domain missing entirely confirms the silo is real and
   MHA-only so far; multiple domains each with their own complete Bronze→Gold
   stack confirms the silo pattern is systemic, not MHA-specific.
   --------------------------------------------------------------------------- */
WITH parsed AS (
    SELECT
        d.DATABASE_NAME,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '^[A-Z]+', 1, 1)
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$' THEN '(unscoped)'
            ELSE 'UNCLASSIFIED'
        END AS env,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '(BRONZE|SILVER|GOLD)', 1, 1)
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$' THEN 'SHARED'
            ELSE 'UNCLASSIFIED'
        END AS layer,
        CASE
            WHEN d.DATABASE_NAME REGEXP '^(DEV|TEST|QA|PROD)_(BRONZE|SILVER|GOLD)_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '[^_]+$')
            WHEN d.DATABASE_NAME REGEXP '^SH_.+$'
                THEN REGEXP_SUBSTR(d.DATABASE_NAME, '^SH_(.+)$', 1, 1, 'e')
            ELSE 'UNCLASSIFIED'
        END AS domain
    FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES d
    WHERE d.DELETED IS NULL
      AND d.DATABASE_NAME LIKE $DB_PATTERN
)
SELECT
    domain,
    env,
    MAX(IFF(layer = 'BRONZE', 'Y', 'N')) AS has_bronze,
    MAX(IFF(layer = 'SILVER', 'Y', 'N')) AS has_silver,
    MAX(IFF(layer = 'GOLD',   'Y', 'N')) AS has_gold,
    MAX(IFF(layer = 'SHARED', 'Y', 'N')) AS has_shared,
    COUNT(*)                             AS databases_found
FROM parsed
WHERE domain <> 'UNCLASSIFIED'
GROUP BY ALL
ORDER BY domain, env;


/* ---------------------------------------------------------------------------
   BLOCK 3 · Full table and view inventory with row counts and storage
   The core baseline artefact. Large result — export to CSV.
   --------------------------------------------------------------------------- */
SELECT
    t.TABLE_CATALOG                         AS database_name,
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.TABLE_TYPE,                            -- BASE TABLE / VIEW / MATERIALIZED VIEW
    t.IS_TRANSIENT,
    t.CLUSTERING_KEY,
    t.ROW_COUNT,
    t.BYTES,
    ROUND(t.BYTES / POWER(1024, 3), 3)      AS gb,
    t.RETENTION_TIME                        AS time_travel_days,
    t.CREATED,
    t.LAST_ALTERED,
    DATEDIFF('day', t.LAST_ALTERED, CURRENT_TIMESTAMP())
                                            AS days_since_last_altered,
    t.TABLE_OWNER,
    t.COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
WHERE t.DELETED IS NULL
  AND t.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND t.TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY t.TABLE_CATALOG, t.TABLE_SCHEMA, t.TABLE_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 4 · Rollup — object count and volume by database / schema
   The one-page summary for the readout deck.
   --------------------------------------------------------------------------- */
SELECT
    t.TABLE_CATALOG                          AS database_name,
    t.TABLE_SCHEMA,
    COUNT(*)                                 AS object_count,
    COUNT_IF(t.TABLE_TYPE = 'BASE TABLE')    AS tables,
    COUNT_IF(t.TABLE_TYPE = 'VIEW')          AS views,
    COUNT_IF(t.TABLE_TYPE = 'MATERIALIZED VIEW') AS materialized_views,
    COUNT_IF(t.IS_TRANSIENT = 'YES')         AS transient_objects,
    SUM(t.ROW_COUNT)                         AS total_rows,
    ROUND(SUM(t.BYTES) / POWER(1024, 3), 2)  AS total_gb,
    MAX(t.LAST_ALTERED)                      AS most_recent_change
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
WHERE t.DELETED IS NULL
  AND t.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND t.TABLE_CATALOG LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY total_gb DESC NULLS LAST;


/* ---------------------------------------------------------------------------
   BLOCK 5 · Source-system footprint (Epic / MHA / Strata)
   Identifies which objects trace to each of the three confirmed sources, and
   whether Epic arrives via CLARITY or CABOODLE — an open question from discovery.
   --------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%CABOODLE%' THEN 'EPIC — Caboodle'
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%CLARITY%'  THEN 'EPIC — Clarity'
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%EPIC%'     THEN 'EPIC — other'
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%MHA%'      THEN 'MHA CLAIMS'
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%STRATA%'   THEN 'STRATA'
        WHEN UPPER(t.TABLE_SCHEMA || '.' || t.TABLE_NAME) LIKE '%PRIORITY%' THEN 'PRIORITY HEALTH'
        ELSE 'UNATTRIBUTED'
    END                                      AS source_system,
    t.TABLE_CATALOG                          AS database_name,
    t.TABLE_SCHEMA,
    COUNT(*)                                 AS object_count,
    SUM(t.ROW_COUNT)                         AS total_rows,
    ROUND(SUM(t.BYTES) / POWER(1024, 3), 2)  AS total_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
WHERE t.DELETED IS NULL
  AND t.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND t.TABLE_CATALOG LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY source_system, total_gb DESC NULLS LAST;


/* ---------------------------------------------------------------------------
   BLOCK 6 · Non-standard object types
   Confirms the discovery statement that no lakehouse / open table format is in
   use. Expect zero rows for external and Iceberg tables.
   --------------------------------------------------------------------------- */
-- External tables
SELECT 'EXTERNAL TABLE' AS object_class, TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME,
       ROW_COUNT, BYTES, LAST_ALTERED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND TABLE_TYPE = 'EXTERNAL TABLE'
  AND TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY object_class, TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME;

-- Dynamic tables and Iceberg tables — version-safe via SHOW.
-- (The IS_DYNAMIC column is not present on all Snowflake versions, so these
--  are queried with SHOW rather than ACCOUNT_USAGE.)
SHOW DYNAMIC TABLES IN ACCOUNT;
SHOW ICEBERG TABLES IN ACCOUNT;


/* ---------------------------------------------------------------------------
   BLOCK 7 · Inbound data shares
   Strata was described as arriving via Snowflake Data Share — this confirms it
   and reveals any other shares in use.
   --------------------------------------------------------------------------- */
SHOW SHARES;
-- Then inspect the result set:
SELECT "name", "kind", "database_name", "owner", "comment", "created_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "kind", "name";


/* ---------------------------------------------------------------------------
   BLOCK 8 · Storage detail including Time Travel and Fail-safe
   Shows the true storage cost profile per table.
   --------------------------------------------------------------------------- */
SELECT
    TABLE_CATALOG                            AS database_name,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROUND(ACTIVE_BYTES      / POWER(1024,3), 3) AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024,3), 3) AS time_travel_gb,
    ROUND(FAILSAFE_BYTES    / POWER(1024,3), 3) AS failsafe_gb,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES)
          / POWER(1024,3), 3)                   AS total_gb,
    IS_TRANSIENT,
    DELETED,
    TABLE_CREATED,
    TABLE_DROPPED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE DELETED = FALSE
  AND TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY total_gb DESC NULLS LAST
LIMIT 500;


/* ---------------------------------------------------------------------------
   FALLBACK · If IMPORTED PRIVILEGES on SNOWFLAKE is not granted
   Run per database, replacing <DB>. Real-time but single-database scope.
   --------------------------------------------------------------------------- */
-- USE DATABASE <DB>;
-- SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE,
--        ROW_COUNT, BYTES, CREATED, LAST_ALTERED, COMMENT
-- FROM   INFORMATION_SCHEMA.TABLES
-- WHERE  TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
-- ORDER BY TABLE_SCHEMA, TABLE_NAME;
