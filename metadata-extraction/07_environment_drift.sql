/* ============================================================================
   07 · ENVIRONMENT DRIFT (DEV / TEST / PROD)
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Discovery stated environments are separated Dev/Test/Prod and that
            "Production is the most complete environment." These queries
            quantify that difference — which objects exist only in Prod, where
            schemas have drifted, and whether promotion is reliable.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
-- Set these to Corewell's actual database names before running.
SET DEV_DB  = 'DEV_DB';
SET TEST_DB = 'TEST_DB';
SET PROD_DB = 'PROD_DB';


/* ---------------------------------------------------------------------------
   BLOCK 1 · Environment size comparison
   The headline drift number.
   --------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN UPPER(TABLE_CATALOG) LIKE '%PROD%' THEN 'PROD'
        WHEN UPPER(TABLE_CATALOG) LIKE '%TEST%'
          OR UPPER(TABLE_CATALOG) LIKE '%QA%'   THEN 'TEST'
        WHEN UPPER(TABLE_CATALOG) LIKE '%DEV%'  THEN 'DEV'
        WHEN UPPER(TABLE_CATALOG) LIKE '%SAND%' THEN 'SANDBOX'
        ELSE 'UNCLASSIFIED'
    END                                        AS environment,
    TABLE_CATALOG                              AS database_name,
    COUNT(*)                                   AS object_count,
    COUNT(DISTINCT TABLE_SCHEMA)               AS schema_count,
    COUNT_IF(TABLE_TYPE = 'BASE TABLE')        AS tables,
    COUNT_IF(TABLE_TYPE = 'VIEW')              AS views,
    SUM(ROW_COUNT)                             AS total_rows,
    ROUND(SUM(BYTES)/POWER(1024,3), 2)         AS total_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
GROUP BY ALL
ORDER BY environment, database_name;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Objects in PROD but absent from DEV
   Quantifies "Production is the most complete environment" and identifies what
   a developer cannot exercise locally.
   --------------------------------------------------------------------------- */
WITH prod AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, ROW_COUNT
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE DELETED IS NULL AND TABLE_CATALOG = $PROD_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
),
dev AS (
    SELECT TABLE_SCHEMA, TABLE_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE DELETED IS NULL AND TABLE_CATALOG = $DEV_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
)
SELECT p.TABLE_SCHEMA, p.TABLE_NAME, p.TABLE_TYPE, p.ROW_COUNT,
       'IN PROD, MISSING FROM DEV' AS finding
FROM prod p
LEFT JOIN dev d
       ON d.TABLE_SCHEMA = p.TABLE_SCHEMA AND d.TABLE_NAME = p.TABLE_NAME
WHERE d.TABLE_NAME IS NULL
ORDER BY p.TABLE_SCHEMA, p.TABLE_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 3 · Objects in DEV but not yet promoted to PROD
   Work in flight, or abandoned development.
   --------------------------------------------------------------------------- */
WITH dev AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, ROW_COUNT, LAST_ALTERED
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE DELETED IS NULL AND TABLE_CATALOG = $DEV_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
),
prod AS (
    SELECT TABLE_SCHEMA, TABLE_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE DELETED IS NULL AND TABLE_CATALOG = $PROD_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
)
SELECT d.TABLE_SCHEMA, d.TABLE_NAME, d.TABLE_TYPE, d.ROW_COUNT, d.LAST_ALTERED,
       DATEDIFF('day', d.LAST_ALTERED, CURRENT_TIMESTAMP()) AS days_since_change,
       'IN DEV, NOT IN PROD' AS finding
FROM dev d
LEFT JOIN prod p
       ON p.TABLE_SCHEMA = d.TABLE_SCHEMA AND p.TABLE_NAME = d.TABLE_NAME
WHERE p.TABLE_NAME IS NULL
ORDER BY days_since_change DESC;


/* ---------------------------------------------------------------------------
   BLOCK 4 · Column-level schema drift between DEV and PROD
   Same table name, different shape — the failure mode that breaks promotion.
   --------------------------------------------------------------------------- */
WITH dev_cols AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, IS_NULLABLE
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS
    WHERE DELETED IS NULL AND TABLE_CATALOG = $DEV_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
),
prod_cols AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, IS_NULLABLE
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS
    WHERE DELETED IS NULL AND TABLE_CATALOG = $PROD_DB
      AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
)
SELECT
    COALESCE(d.TABLE_SCHEMA, p.TABLE_SCHEMA)   AS table_schema,
    COALESCE(d.TABLE_NAME,   p.TABLE_NAME)     AS table_name,
    COALESCE(d.COLUMN_NAME,  p.COLUMN_NAME)    AS column_name,
    d.DATA_TYPE                                AS dev_data_type,
    p.DATA_TYPE                                AS prod_data_type,
    d.IS_NULLABLE                              AS dev_nullable,
    p.IS_NULLABLE                              AS prod_nullable,
    CASE
        WHEN d.COLUMN_NAME IS NULL              THEN 'COLUMN ONLY IN PROD'
        WHEN p.COLUMN_NAME IS NULL              THEN 'COLUMN ONLY IN DEV'
        WHEN d.DATA_TYPE <> p.DATA_TYPE         THEN 'DATA TYPE MISMATCH'
        WHEN d.IS_NULLABLE <> p.IS_NULLABLE     THEN 'NULLABILITY MISMATCH'
    END                                        AS drift_type
FROM dev_cols d
FULL OUTER JOIN prod_cols p
       ON  p.TABLE_SCHEMA = d.TABLE_SCHEMA
       AND p.TABLE_NAME   = d.TABLE_NAME
       AND p.COLUMN_NAME  = d.COLUMN_NAME
WHERE d.COLUMN_NAME IS NULL
   OR p.COLUMN_NAME IS NULL
   OR d.DATA_TYPE   <> p.DATA_TYPE
   OR d.IS_NULLABLE <> p.IS_NULLABLE
ORDER BY drift_type, table_schema, table_name, column_name;


/* ---------------------------------------------------------------------------
   BLOCK 5 · Governance drift — policies applied in PROD but not lower envs
   A masking policy that exists only in Prod means developers work against
   unmasked data in Dev, which is a PHI exposure path.
   --------------------------------------------------------------------------- */
SELECT
    REF_DATABASE_NAME                          AS database_name,
    POLICY_KIND,
    POLICY_NAME,
    COUNT(*)                                   AS attachments,
    COUNT(DISTINCT REF_SCHEMA_NAME || '.' || REF_ENTITY_NAME) AS objects_protected
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
GROUP BY ALL
ORDER BY POLICY_KIND, database_name, POLICY_NAME;

-- Direct comparison: protected column counts per environment
SELECT
    CASE
        WHEN UPPER(REF_DATABASE_NAME) LIKE '%PROD%' THEN 'PROD'
        WHEN UPPER(REF_DATABASE_NAME) LIKE '%TEST%' THEN 'TEST'
        WHEN UPPER(REF_DATABASE_NAME) LIKE '%DEV%'  THEN 'DEV'
        ELSE 'OTHER'
    END                                        AS environment,
    POLICY_KIND,
    COUNT(DISTINCT REF_DATABASE_NAME || '.' || REF_SCHEMA_NAME || '.'
                   || REF_ENTITY_NAME || '.' || COALESCE(REF_COLUMN_NAME,''))
                                               AS protected_targets
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
GROUP BY ALL
ORDER BY POLICY_KIND, environment;


/* ---------------------------------------------------------------------------
   BLOCK 6 · Grant drift — role access differing across environments
   --------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN UPPER(TABLE_CATALOG) LIKE '%PROD%' THEN 'PROD'
        WHEN UPPER(TABLE_CATALOG) LIKE '%TEST%' THEN 'TEST'
        WHEN UPPER(TABLE_CATALOG) LIKE '%DEV%'  THEN 'DEV'
        ELSE 'OTHER'
    END                                        AS environment,
    GRANTEE_NAME                               AS role_name,
    PRIVILEGE,
    GRANTED_ON,
    COUNT(*)                                   AS grant_count
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE DELETED_ON IS NULL
  AND GRANTED_ON IN ('TABLE','VIEW','SCHEMA','DATABASE')
  AND TABLE_CATALOG IS NOT NULL
GROUP BY ALL
ORDER BY role_name, environment, GRANTED_ON;
