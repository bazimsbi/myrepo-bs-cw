/* ============================================================================
   06 · PIPELINE & DATA FRESHNESS
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Confirm how data actually arrives — Fivetran (Epic, daily
            replication), GoAnywhere (MHA flat files), Strata (data share) —
            and measure freshness, load reliability and archival behaviour.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
SET DB_PATTERN    = '%';
SET LOOKBACK_DAYS = 90;


/* ---------------------------------------------------------------------------
   BLOCK 1 · Table freshness — when was each object last written
   Identifies stale Bronze objects and confirms daily-replication cadence.
   --------------------------------------------------------------------------- */
SELECT
    TABLE_CATALOG                              AS database_name,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROW_COUNT,
    ROUND(BYTES/POWER(1024,3), 3)              AS gb,
    LAST_ALTERED,
    DATEDIFF('hour', LAST_ALTERED, CURRENT_TIMESTAMP()) AS hours_since_change,
    CASE
        WHEN DATEDIFF('hour', LAST_ALTERED, CURRENT_TIMESTAMP()) <= 26  THEN 'FRESH (daily)'
        WHEN DATEDIFF('day',  LAST_ALTERED, CURRENT_TIMESTAMP()) <= 7   THEN 'WEEKLY'
        WHEN DATEDIFF('day',  LAST_ALTERED, CURRENT_TIMESTAMP()) <= 31  THEN 'MONTHLY'
        WHEN DATEDIFF('day',  LAST_ALTERED, CURRENT_TIMESTAMP()) <= 90  THEN 'STALE (1-3 months)'
        ELSE 'DORMANT (>3 months)'
    END                                        AS freshness_band
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY hours_since_change;

-- Freshness rollup by schema
SELECT
    TABLE_CATALOG AS database_name,
    TABLE_SCHEMA,
    COUNT(*)                                                             AS tables,
    COUNT_IF(DATEDIFF('hour', LAST_ALTERED, CURRENT_TIMESTAMP()) <= 26)  AS fresh_daily,
    COUNT_IF(DATEDIFF('day',  LAST_ALTERED, CURRENT_TIMESTAMP()) > 90)   AS dormant,
    MAX(LAST_ALTERED)                                                    AS most_recent_load
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND TABLE_CATALOG LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY database_name, TABLE_SCHEMA;


/* ---------------------------------------------------------------------------
   BLOCK 2 · COPY / file load history   ** confirms GoAnywhere behaviour **
   Discovery described: files land in a directory, GoAnywhere detects and loads
   to Bronze, source files are archived. This shows the resulting COPY activity,
   file naming, volumes and error rates.
   --------------------------------------------------------------------------- */
SELECT
    LAST_LOAD_TIME::DATE                       AS load_date,
    TABLE_CATALOG_NAME                         AS database_name,
    TABLE_SCHEMA_NAME,
    TABLE_NAME,
    STAGE_LOCATION,
    COUNT(*)                                   AS files_loaded,
    SUM(ROW_COUNT)                             AS rows_loaded,
    SUM(ROW_PARSED)                            AS rows_parsed,
    SUM(ERROR_COUNT)                           AS error_count,
    ROUND(SUM(FILE_SIZE)/POWER(1024,2), 2)     AS total_mb,
    COUNT_IF(STATUS <> 'LOADED')               AS non_success_loads
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE LAST_LOAD_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND TABLE_CATALOG_NAME LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY load_date DESC, rows_loaded DESC;

-- Individual file-level detail, including failures
SELECT
    LAST_LOAD_TIME,
    TABLE_CATALOG_NAME AS database_name,
    TABLE_SCHEMA_NAME,
    TABLE_NAME,
    FILE_NAME,
    STAGE_LOCATION,
    ROW_COUNT,
    ROW_PARSED,
    FILE_SIZE,
    ERROR_COUNT,
    ERROR_LIMIT,
    FIRST_ERROR_MESSAGE,
    STATUS,
    PIPE_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE LAST_LOAD_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND (STATUS <> 'LOADED' OR ERROR_COUNT > 0)
ORDER BY LAST_LOAD_TIME DESC
LIMIT 500;


/* ---------------------------------------------------------------------------
   BLOCK 3 · Snowpipe usage
   Confirms whether ingestion is COPY-driven (GoAnywhere calling COPY) or
   pipe-driven (auto-ingest). Empty results indicate no Snowpipe in use.
   --------------------------------------------------------------------------- */
SELECT
    PIPE_NAME,
    DATE_TRUNC('day', START_TIME)              AS day,
    SUM(CREDITS_USED)                          AS credits_used,
    SUM(BYTES_INSERTED)                        AS bytes_inserted,
    SUM(FILES_INSERTED)                        AS files_inserted
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY day DESC, credits_used DESC;

SHOW PIPES;
SHOW STAGES;


/* ---------------------------------------------------------------------------
   BLOCK 4 · Task execution history
   Native Snowflake scheduling, if any. Note that Astronomer/Airflow
   orchestration will NOT appear here — it drives dbt externally.
   --------------------------------------------------------------------------- */
SELECT
    NAME                                       AS task_name,
    DATABASE_NAME,
    SCHEMA_NAME,
    STATE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    DATEDIFF('second', SCHEDULED_TIME, COMPLETED_TIME) AS duration_seconds,
    ERROR_CODE,
    ERROR_MESSAGE,
    LEFT(QUERY_TEXT, 300)                      AS query_text_truncated
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE SCHEDULED_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
ORDER BY SCHEDULED_TIME DESC
LIMIT 500;

-- Task reliability rollup
SELECT
    NAME AS task_name, DATABASE_NAME, SCHEMA_NAME,
    COUNT(*)                                   AS runs,
    COUNT_IF(STATE = 'SUCCEEDED')              AS succeeded,
    COUNT_IF(STATE = 'FAILED')                 AS failed,
    ROUND(100.0 * COUNT_IF(STATE='FAILED') / NULLIF(COUNT(*),0), 1) AS pct_failed
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE SCHEDULED_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY failed DESC, runs DESC;


/* ---------------------------------------------------------------------------
   BLOCK 5 · Write activity by object — which pipelines are actually running
   Derived from DML in query history. Reveals the dbt/Fivetran write pattern
   and the load window.
   --------------------------------------------------------------------------- */
SELECT
    DATABASE_NAME,
    SCHEMA_NAME,
    QUERY_TYPE,                                -- INSERT / MERGE / CREATE_TABLE_AS_SELECT / DELETE
    USER_NAME,
    ROLE_NAME,
    COALESCE(CLIENT_APPLICATION_ID, 'UNKNOWN') AS client_application,
    COUNT(*)                                   AS statements,
    SUM(ROWS_INSERTED)                         AS rows_inserted,
    SUM(ROWS_UPDATED)                          AS rows_updated,
    SUM(ROWS_DELETED)                          AS rows_deleted,
    MIN(START_TIME)                            AS first_run,
    MAX(START_TIME)                            AS last_run
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND QUERY_TYPE IN ('INSERT','MERGE','UPDATE','DELETE',
                     'CREATE_TABLE_AS_SELECT','COPY','TRUNCATE_TABLE')
  AND DATABASE_NAME LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY statements DESC;


/* ---------------------------------------------------------------------------
   BLOCK 6 · Load window profile — when does the daily batch actually run
   Useful for SLA definition and for planning the future model's refresh.
   --------------------------------------------------------------------------- */
SELECT
    HOUR(START_TIME)                           AS hour_of_day_utc,
    COUNT(*)                                   AS write_statements,
    SUM(ROWS_INSERTED + ROWS_UPDATED)          AS rows_written,
    ROUND(AVG(TOTAL_ELAPSED_TIME)/1000, 1)     AS avg_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND QUERY_TYPE IN ('INSERT','MERGE','COPY','CREATE_TABLE_AS_SELECT')
GROUP BY ALL
ORDER BY hour_of_day_utc;
