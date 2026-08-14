/* ============================================================================
   05 · USAGE & ACTIVITY
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Distinguish what is genuinely used from what merely exists, identify
            the real reporting consumers, and baseline compute cost.
   READS    SNOWFLAKE.ACCOUNT_USAGE (query metadata only — no result data)
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
SET DB_PATTERN    = '%';
SET LOOKBACK_DAYS = 90;


/* ---------------------------------------------------------------------------
   BLOCK 1 · Query volume by user, role and client application
   Identifies the actual consumer population, including BI service accounts.
   --------------------------------------------------------------------------- */
SELECT
    USER_NAME,
    ROLE_NAME,
    COALESCE(CLIENT_APPLICATION_ID, 'UNKNOWN') AS client_application,
    WAREHOUSE_NAME,
    COUNT(*)                                   AS query_count,
    ROUND(SUM(TOTAL_ELAPSED_TIME)/1000/60, 1)  AS total_minutes,
    ROUND(AVG(TOTAL_ELAPSED_TIME)/1000, 2)     AS avg_seconds,
    MIN(START_TIME)                            AS first_seen,
    MAX(START_TIME)                            AS last_seen
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
GROUP BY ALL
ORDER BY query_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Query volume by database and schema
   Shows which layers carry real workload.
   --------------------------------------------------------------------------- */
SELECT
    DATABASE_NAME,
    SCHEMA_NAME,
    COUNT(*)                                   AS query_count,
    COUNT(DISTINCT USER_NAME)                  AS distinct_users,
    COUNT(DISTINCT ROLE_NAME)                  AS distinct_roles,
    ROUND(SUM(TOTAL_ELAPSED_TIME)/1000/60, 1)  AS total_minutes,
    ROUND(SUM(BYTES_SCANNED)/POWER(1024,3), 2) AS gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND DATABASE_NAME LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY query_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 3 · Warehouse credit consumption
   Baseline compute spend by warehouse, for the FinOps section of the report.
   --------------------------------------------------------------------------- */
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('week', START_TIME)             AS week,
    ROUND(SUM(CREDITS_USED), 2)                AS credits_used,
    ROUND(SUM(CREDITS_USED_COMPUTE), 2)        AS credits_compute,
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 2) AS credits_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY WAREHOUSE_NAME, week;

-- Warehouse configuration
SHOW WAREHOUSES;
SELECT "name", "size", "min_cluster_count", "max_cluster_count",
       "auto_suspend", "auto_resume", "scaling_policy", "type",
       "owner", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";


/* ---------------------------------------------------------------------------
   BLOCK 4 · Most expensive queries
   Feeds the performance-optimisation findings.
   --------------------------------------------------------------------------- */
SELECT
    QUERY_ID,
    USER_NAME,
    ROLE_NAME,
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    DATABASE_NAME,
    SCHEMA_NAME,
    QUERY_TYPE,
    ROUND(TOTAL_ELAPSED_TIME/1000, 1)          AS elapsed_seconds,
    ROUND(EXECUTION_TIME/1000, 1)              AS execution_seconds,
    ROUND(QUEUED_OVERLOAD_TIME/1000, 1)        AS queued_seconds,
    ROUND(BYTES_SCANNED/POWER(1024,3), 2)      AS gb_scanned,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(100.0 * PARTITIONS_SCANNED
          / NULLIF(PARTITIONS_TOTAL,0), 1)     AS pct_partitions_scanned,  -- low = good pruning
    BYTES_SPILLED_TO_LOCAL_STORAGE,
    BYTES_SPILLED_TO_REMOTE_STORAGE,
    START_TIME,
    LEFT(QUERY_TEXT, 500)                      AS query_text_truncated
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND TOTAL_ELAPSED_TIME > 60000              -- longer than 60 seconds
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 200;


/* ---------------------------------------------------------------------------
   BLOCK 5 · Failed and cancelled queries
   Surfaces pipeline reliability problems and permission friction.
   --------------------------------------------------------------------------- */
SELECT
    ERROR_CODE,
    ERROR_MESSAGE,
    COUNT(*)                                   AS occurrences,
    COUNT(DISTINCT USER_NAME)                  AS affected_users,
    MIN(START_TIME)                            AS first_seen,
    MAX(START_TIME)                            AS last_seen
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS IN ('FAIL','FAILED_WITH_ERROR','CANCELLED')
GROUP BY ALL
ORDER BY occurrences DESC
LIMIT 100;


/* ---------------------------------------------------------------------------
   BLOCK 6 · UNUSED OBJECTS   ** informs model rationalisation **
   Tables never read in the lookback window. Requires Enterprise Edition for
   ACCESS_HISTORY; without it, use LAST_ALTERED from script 01 as a proxy.
   --------------------------------------------------------------------------- */
WITH accessed AS (
    SELECT DISTINCT UPPER(obj.value:objectName::STRING) AS object_fqn
    FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
         LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) obj
    WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
)
SELECT
    t.TABLE_CATALOG                            AS database_name,
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.TABLE_TYPE,
    t.ROW_COUNT,
    ROUND(t.BYTES/POWER(1024,3), 3)            AS gb,
    t.CREATED,
    t.LAST_ALTERED,
    DATEDIFF('day', t.LAST_ALTERED, CURRENT_TIMESTAMP()) AS days_stale,
    'NOT READ IN LAST ' || $LOOKBACK_DAYS || ' DAYS' AS finding
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
LEFT JOIN accessed a
       ON a.object_fqn = UPPER(t.TABLE_CATALOG || '.' || t.TABLE_SCHEMA || '.' || t.TABLE_NAME)
WHERE t.DELETED IS NULL
  AND t.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND t.TABLE_CATALOG LIKE $DB_PATTERN
  AND a.object_fqn IS NULL
ORDER BY gb DESC NULLS LAST;


/* ---------------------------------------------------------------------------
   BLOCK 7 · Most-read objects — the de facto reporting surface
   In the absence of a documented model, the objects people actually query are
   the best available statement of what the business considers important.
   --------------------------------------------------------------------------- */
SELECT
    obj.value:objectName::STRING               AS object_fqn,
    obj.value:objectDomain::STRING             AS object_type,
    COUNT(*)                                   AS read_events,
    COUNT(DISTINCT ah.USER_NAME)               AS distinct_users,
    COUNT(DISTINCT qh.ROLE_NAME)               AS distinct_roles,
    MIN(ah.QUERY_START_TIME)                   AS first_read,
    MAX(ah.QUERY_START_TIME)                   AS last_read
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
  ON qh.QUERY_ID = ah.QUERY_ID,
     LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) obj
WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY read_events DESC
LIMIT 300;


/* ---------------------------------------------------------------------------
   BLOCK 8 · Login history — access patterns and authentication method
   Confirms SSO adoption and identifies service accounts.
   --------------------------------------------------------------------------- */
SELECT
    USER_NAME,
    FIRST_AUTHENTICATION_FACTOR,
    SECOND_AUTHENTICATION_FACTOR,
    COALESCE(CLIENT_IP, 'n/a')                 AS client_ip,
    REPORTED_CLIENT_TYPE,
    COUNT(*)                                   AS login_count,
    COUNT_IF(IS_SUCCESS = 'NO')                AS failed_logins,
    MIN(EVENT_TIMESTAMP)                       AS first_login,
    MAX(EVENT_TIMESTAMP)                       AS last_login
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE EVENT_TIMESTAMP >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY login_count DESC;
