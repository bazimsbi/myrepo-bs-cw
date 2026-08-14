/* ============================================================================
   04 · LINEAGE & DEPENDENCIES
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Reconstruct source-to-report lineage. Discovery flagged "limited
            visibility into source-to-report lineage" as a risk; these queries
            rebuild it from Snowflake's own metadata.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
            ACCESS_HISTORY requires Enterprise Edition or higher
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
SET DB_PATTERN  = '%';
SET LOOKBACK_DAYS = 90;


/* ---------------------------------------------------------------------------
   BLOCK 1 · Declared object dependencies (view → underlying tables)
   Static lineage: what an object is DEFINED on.
   --------------------------------------------------------------------------- */
SELECT
    REFERENCING_DATABASE                 AS child_database,
    REFERENCING_SCHEMA                   AS child_schema,
    REFERENCING_OBJECT_NAME              AS child_object,
    REFERENCING_OBJECT_DOMAIN            AS child_type,
    REFERENCED_DATABASE                  AS parent_database,
    REFERENCED_SCHEMA                    AS parent_schema,
    REFERENCED_OBJECT_NAME               AS parent_object,
    REFERENCED_OBJECT_DOMAIN             AS parent_type
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE REFERENCING_DATABASE LIKE $DB_PATTERN
ORDER BY child_database, child_schema, child_object, parent_schema, parent_object;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Cross-layer dependency map   ** key architectural finding **
   Classifies each dependency edge by the layers it connects, then flags edges
   that skip the medallion progression (e.g. SHARED reading straight from
   BRONZE, or a report object reading SILVER).

   This is the query that confirms or refutes whether Shared is genuinely the
   only consumption layer.
   --------------------------------------------------------------------------- */
WITH layered AS (
    SELECT
        REFERENCING_DATABASE   AS child_db,
        REFERENCING_SCHEMA     AS child_schema,
        REFERENCING_OBJECT_NAME AS child_object,
        REFERENCED_DATABASE    AS parent_db,
        REFERENCED_SCHEMA      AS parent_schema,
        REFERENCED_OBJECT_NAME AS parent_object,
        CASE
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(BRONZE|RAW|LAND).*'      THEN 1
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(SILVER|STAGE|CLEAN).*'   THEN 2
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(GOLD|MART|DW).*'         THEN 3
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(SHARE|REPORT|CONSUM).*'  THEN 4
            ELSE 0
        END AS child_layer,
        CASE
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(BRONZE|RAW|LAND).*'       THEN 1
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(SILVER|STAGE|CLEAN).*'    THEN 2
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(GOLD|MART|DW).*'          THEN 3
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(SHARE|REPORT|CONSUM).*'   THEN 4
            ELSE 0
        END AS parent_layer
    FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
    WHERE REFERENCING_DATABASE LIKE $DB_PATTERN
)
SELECT
    child_layer, parent_layer,
    CASE
        WHEN child_layer = 0 OR parent_layer = 0        THEN 'UNCLASSIFIED SCHEMA'
        WHEN child_layer = parent_layer                 THEN 'INTRA-LAYER'
        WHEN child_layer = parent_layer + 1             THEN 'NORMAL PROGRESSION'
        WHEN child_layer > parent_layer + 1             THEN 'LAYER SKIP — review'
        ELSE 'REVERSE FLOW — review'
    END                                                 AS edge_classification,
    COUNT(*)                                            AS edge_count
FROM layered
GROUP BY ALL
ORDER BY edge_classification, edge_count DESC;

-- The individual layer-skipping edges, for follow-up
WITH layered AS (
    SELECT
        REFERENCING_DATABASE AS child_db, REFERENCING_SCHEMA AS child_schema,
        REFERENCING_OBJECT_NAME AS child_object,
        REFERENCED_DATABASE AS parent_db, REFERENCED_SCHEMA AS parent_schema,
        REFERENCED_OBJECT_NAME AS parent_object,
        CASE
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(BRONZE|RAW|LAND).*'     THEN 1
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(SILVER|STAGE|CLEAN).*'  THEN 2
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(GOLD|MART|DW).*'        THEN 3
            WHEN UPPER(REFERENCING_SCHEMA) REGEXP '.*(SHARE|REPORT|CONSUM).*' THEN 4
            ELSE 0 END AS child_layer,
        CASE
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(BRONZE|RAW|LAND).*'      THEN 1
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(SILVER|STAGE|CLEAN).*'   THEN 2
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(GOLD|MART|DW).*'         THEN 3
            WHEN UPPER(REFERENCED_SCHEMA) REGEXP '.*(SHARE|REPORT|CONSUM).*'  THEN 4
            ELSE 0 END AS parent_layer
    FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
    WHERE REFERENCING_DATABASE LIKE $DB_PATTERN
)
SELECT child_db, child_schema, child_object, child_layer,
       parent_db, parent_schema, parent_object, parent_layer
FROM layered
WHERE child_layer > 0 AND parent_layer > 0
  AND child_layer > parent_layer + 1
ORDER BY child_layer DESC, child_schema, child_object;


/* ---------------------------------------------------------------------------
   BLOCK 3 · View definitions
   The transformation logic held in views — needed to extract business rules
   for the conceptual model, given no model documentation exists.
   --------------------------------------------------------------------------- */
SELECT
    TABLE_CATALOG                        AS database_name,
    TABLE_SCHEMA,
    TABLE_NAME                           AS view_name,
    IS_SECURE,
    IS_MATERIALIZED,
    CREATED,
    LAST_ALTERED,
    VIEW_DEFINITION,
    COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS
WHERE DELETED IS NULL
  AND TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY database_name, TABLE_SCHEMA, view_name;


/* ---------------------------------------------------------------------------
   BLOCK 4 · ACTUAL read/write lineage from ACCESS_HISTORY
   Dynamic lineage: what is REALLY being read and written, not just declared.
   Requires Enterprise Edition.
   --------------------------------------------------------------------------- */
SELECT
    ah.QUERY_START_TIME::DATE             AS access_date,
    ah.USER_NAME,
    obj.value:objectName::STRING          AS object_read,
    obj.value:objectDomain::STRING        AS object_type,
    COUNT(*)                              AS read_events
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) obj
WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY access_date DESC, read_events DESC
LIMIT 5000;

-- Write lineage: which objects are produced, and from what
SELECT
    ah.QUERY_START_TIME::DATE             AS write_date,
    wobj.value:objectName::STRING         AS object_written,
    robj.value:objectName::STRING         AS sourced_from,
    COUNT(*)                              AS write_events
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(input => ah.OBJECTS_MODIFIED) wobj,
     LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) robj
WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY write_date DESC, write_events DESC
LIMIT 5000;


/* ---------------------------------------------------------------------------
   BLOCK 5 · Column-level lineage from ACCESS_HISTORY
   Traces which source columns feed which target columns — the strongest
   available evidence for reverse-engineering business logic.
   --------------------------------------------------------------------------- */
SELECT
    ah.QUERY_START_TIME::DATE                                 AS access_date,
    wcol.value:objectName::STRING                             AS target_object,
    wcol.value:columnName::STRING                             AS target_column,
    src.value:objectName::STRING                              AS source_object,
    src.value:columnName::STRING                              AS source_column,
    COUNT(*)                                                  AS occurrences
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(input => ah.OBJECTS_MODIFIED) wobj,
     LATERAL FLATTEN(input => wobj.value:columns) wcol,
     LATERAL FLATTEN(input => wcol.value:directSources) src
WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY access_date DESC, occurrences DESC
LIMIT 5000;


/* ---------------------------------------------------------------------------
   BLOCK 6 · BI tool access paths   ** confirms the consumption boundary **
   Which client applications read which layers. Tableau and Power BI should
   appear against SHARED only; anything else is a governance gap.
   --------------------------------------------------------------------------- */
SELECT
    COALESCE(qh.CLIENT_APPLICATION_ID, 'UNKNOWN')  AS client_application,
    ah.USER_NAME,
    qh.ROLE_NAME,
    SPLIT_PART(obj.value:objectName::STRING, '.', 1) AS accessed_database,
    SPLIT_PART(obj.value:objectName::STRING, '.', 2) AS accessed_schema,
    CASE
        WHEN UPPER(SPLIT_PART(obj.value:objectName::STRING, '.', 2)) REGEXP '.*(BRONZE|RAW|LAND).*'     THEN 'BRONZE'
        WHEN UPPER(SPLIT_PART(obj.value:objectName::STRING, '.', 2)) REGEXP '.*(SILVER|STAGE|CLEAN).*'  THEN 'SILVER'
        WHEN UPPER(SPLIT_PART(obj.value:objectName::STRING, '.', 2)) REGEXP '.*(GOLD|MART|DW).*'        THEN 'GOLD'
        WHEN UPPER(SPLIT_PART(obj.value:objectName::STRING, '.', 2)) REGEXP '.*(SHARE|REPORT|CONSUM).*' THEN 'SHARED'
        WHEN UPPER(SPLIT_PART(obj.value:objectName::STRING, '.', 2)) REGEXP '.*(WORK|SANDBOX).*'        THEN 'WORKSPACE'
        ELSE 'OTHER'
    END                                             AS layer_accessed,
    COUNT(*)                                        AS access_count
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
  ON qh.QUERY_ID = ah.QUERY_ID,
     LATERAL FLATTEN(input => ah.BASE_OBJECTS_ACCESSED) obj
WHERE ah.QUERY_START_TIME >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY ALL
ORDER BY client_application, access_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 7 · Orphan objects — nothing depends on them and nothing they depend on
   Candidate dead models; also finds tables loaded but never consumed.
   --------------------------------------------------------------------------- */
SELECT
    t.TABLE_CATALOG AS database_name,
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.TABLE_TYPE,
    t.ROW_COUNT,
    t.LAST_ALTERED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d_child
       ON  d_child.REFERENCED_DATABASE    = t.TABLE_CATALOG
       AND d_child.REFERENCED_SCHEMA      = t.TABLE_SCHEMA
       AND d_child.REFERENCED_OBJECT_NAME = t.TABLE_NAME
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d_parent
       ON  d_parent.REFERENCING_DATABASE    = t.TABLE_CATALOG
       AND d_parent.REFERENCING_SCHEMA      = t.TABLE_SCHEMA
       AND d_parent.REFERENCING_OBJECT_NAME = t.TABLE_NAME
WHERE t.DELETED IS NULL
  AND t.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND t.TABLE_CATALOG LIKE $DB_PATTERN
  AND d_child.REFERENCED_OBJECT_NAME    IS NULL
  AND d_parent.REFERENCING_OBJECT_NAME  IS NULL
ORDER BY t.ROW_COUNT DESC NULLS LAST;
