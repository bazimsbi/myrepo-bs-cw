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
   BLOCK 2 · Schema detail with inferred environment and layer
   NOTE: the CASE expressions below encode assumed naming conventions.
         Adjust to Corewell's actual convention before relying on the rollups.
   --------------------------------------------------------------------------- */
WITH layer_map AS (
    SELECT
        s.CATALOG_NAME                      AS database_name,
        s.SCHEMA_NAME,
        s.SCHEMA_OWNER,
        s.IS_TRANSIENT,
        s.RETENTION_TIME,
        s.CREATED,
        s.LAST_ALTERED,
        s.COMMENT,
        CASE
            WHEN UPPER(s.CATALOG_NAME) LIKE '%PROD%' THEN 'PROD'
            WHEN UPPER(s.CATALOG_NAME) LIKE '%TEST%'
              OR UPPER(s.CATALOG_NAME) LIKE '%QA%'   THEN 'TEST'
            WHEN UPPER(s.CATALOG_NAME) LIKE '%DEV%'  THEN 'DEV'
            WHEN UPPER(s.CATALOG_NAME) LIKE '%SAND%' THEN 'SANDBOX'
            ELSE 'UNCLASSIFIED'
        END                                 AS env,
        CASE
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%BRONZE%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%RAW%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%LAND%'    THEN 'BRONZE'
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%SILVER%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%STAGE%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%CLEAN%'   THEN 'SILVER'
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%GOLD%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%MART%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%DW%'      THEN 'GOLD'
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%SHARE%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%REPORT%'
              OR UPPER(s.SCHEMA_NAME) LIKE '%CONSUM%'  THEN 'SHARED'
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%COMMON%'  THEN 'COMMON'
            WHEN UPPER(s.SCHEMA_NAME) LIKE '%WORK%'    THEN 'WORKSPACE'
            ELSE 'OTHER'
        END                                 AS layer
    FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA s
    WHERE s.DELETED IS NULL
      AND s.SCHEMA_NAME <> 'INFORMATION_SCHEMA'
      AND s.CATALOG_NAME LIKE $DB_PATTERN
)
SELECT *
FROM layer_map
ORDER BY env, layer, database_name, SCHEMA_NAME;


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
