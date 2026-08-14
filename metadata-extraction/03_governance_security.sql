/* ============================================================================
   03 · GOVERNANCE & SECURITY
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Baseline the security model ahead of the session with Corewell's
            Snowflake administration SME (Tim Burer): masking policies, row
            access policies, tags, roles, grants and privileged access.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   RETURNS  Policy names, bodies and grant structures. No PHI/PII values.
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
            (some SHOW commands require ACCOUNTADMIN or MANAGE GRANTS)

   Discovery context: Corewell described "masked and unmasked roles" with the
   Shared layer as the primary enforcement point. These queries test whether
   protection is ROLE-based (applied per object) or TAG-based (inherited), and
   how much of the PHI surface from script 02 is actually covered.
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
SET DB_PATTERN = '%';


/* ---------------------------------------------------------------------------
   BLOCK 1 · Masking policies defined
   --------------------------------------------------------------------------- */
SELECT
    POLICY_CATALOG                       AS database_name,
    POLICY_SCHEMA,
    POLICY_NAME,
    POLICY_OWNER,
    POLICY_SIGNATURE,
    POLICY_RETURN_TYPE,
    POLICY_BODY,                         -- review: does it branch on ROLE or TAG?
    CREATED,
    LAST_ALTERED,
    COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES
WHERE DELETED IS NULL
  AND POLICY_CATALOG LIKE $DB_PATTERN
ORDER BY POLICY_CATALOG, POLICY_SCHEMA, POLICY_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Row access policies defined
   --------------------------------------------------------------------------- */
SELECT
    POLICY_CATALOG                       AS database_name,
    POLICY_SCHEMA,
    POLICY_NAME,
    POLICY_OWNER,
    POLICY_SIGNATURE,
    POLICY_BODY,
    CREATED,
    LAST_ALTERED,
    COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
WHERE DELETED IS NULL
  AND POLICY_CATALOG LIKE $DB_PATTERN
ORDER BY POLICY_CATALOG, POLICY_SCHEMA, POLICY_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 3 · WHERE policies are actually attached   ** key finding **
   A policy that exists but is attached to few columns is not protection.
   Compare this count against the PHI candidate count from script 02 block 4b.
   --------------------------------------------------------------------------- */
SELECT
    POLICY_KIND,                         -- MASKING_POLICY / ROW_ACCESS_POLICY
    POLICY_DB                            AS policy_database,
    POLICY_SCHEMA,
    POLICY_NAME,
    REF_DATABASE_NAME                    AS applied_to_database,
    REF_SCHEMA_NAME                      AS applied_to_schema,
    REF_ENTITY_NAME                      AS applied_to_object,
    REF_ENTITY_DOMAIN                    AS object_type,
    REF_COLUMN_NAME                      AS applied_to_column,
    REF_ARG_COLUMN_NAMES                 AS policy_arg_columns,
    TAG_NAME                             AS attached_via_tag   -- non-null = tag-based
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE REF_DATABASE_NAME LIKE $DB_PATTERN
ORDER BY POLICY_KIND, policy_database, POLICY_SCHEMA, POLICY_NAME,
         applied_to_schema, applied_to_object, applied_to_column;

-- Coverage rollup: how many columns each policy protects, and by what mechanism
SELECT
    POLICY_KIND,
    POLICY_NAME,
    IFF(TAG_NAME IS NULL, 'DIRECT (per-object)', 'TAG-BASED (inherited)')
                                         AS attachment_mechanism,
    COUNT(*)                             AS attachment_count,
    COUNT(DISTINCT REF_DATABASE_NAME || '.' || REF_SCHEMA_NAME) AS schemas_covered,
    COUNT(DISTINCT REF_ENTITY_NAME)      AS objects_covered
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE REF_DATABASE_NAME LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY POLICY_KIND, attachment_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 4 · Tags defined and where assigned
   Empty results here + populated results in Block 3 = protection is applied
   per object rather than inherited from classification. That is the central
   governance finding for the redesign.
   --------------------------------------------------------------------------- */
SELECT
    TAG_DATABASE, TAG_SCHEMA, TAG_NAME, TAG_OWNER,
    TAG_ALLOWED_VALUES, CREATED, LAST_ALTERED, COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.TAGS
WHERE DELETED IS NULL
ORDER BY TAG_DATABASE, TAG_SCHEMA, TAG_NAME;

-- Tag assignments
SELECT
    TAG_DATABASE, TAG_SCHEMA, TAG_NAME, TAG_VALUE,
    OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME,
    COLUMN_NAME, DOMAIN AS object_type
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DELETED IS NULL
  AND (OBJECT_DATABASE LIKE $DB_PATTERN OR OBJECT_DATABASE IS NULL)
ORDER BY TAG_NAME, OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 5 · UNPROTECTED PHI CANDIDATES   ** the headline governance number **
   PHI-candidate columns (name heuristic from script 02) that carry NO masking
   policy. Expect false positives — validate with the governance SME.
   --------------------------------------------------------------------------- */
WITH phi_candidates AS (
    SELECT
        c.TABLE_CATALOG AS database_name,
        c.TABLE_SCHEMA,
        c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    WHERE c.DELETED IS NULL
      AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
      AND c.TABLE_CATALOG LIKE $DB_PATTERN
      AND UPPER(c.COLUMN_NAME) REGEXP
          '.*(SSN|SOCIAL_SEC|MRN|MEDICAL_REC|PAT_ID|PATIENT_ID|MEMBER_ID|SUBSCRIBER|HICN|MBI|FIRST_NAME|LAST_NAME|FULL_NAME|PAT_NAME|EMAIL|PHONE|DOB|BIRTH_DATE|DATE_OF_BIRTH|ADDR|STREET|ZIP|POSTAL|GUARANTOR|CLAIM_NUM).*'
),
masked AS (
    SELECT DISTINCT
        REF_DATABASE_NAME AS database_name,
        REF_SCHEMA_NAME   AS TABLE_SCHEMA,
        REF_ENTITY_NAME   AS TABLE_NAME,
        REF_COLUMN_NAME   AS COLUMN_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
    WHERE POLICY_KIND = 'MASKING_POLICY'
      AND REF_COLUMN_NAME IS NOT NULL
)
SELECT
    p.database_name,
    p.TABLE_SCHEMA,
    p.TABLE_NAME,
    p.COLUMN_NAME,
    p.DATA_TYPE,
    'NO MASKING POLICY ATTACHED' AS finding
FROM phi_candidates p
LEFT JOIN masked m
       ON  m.database_name = p.database_name
       AND m.TABLE_SCHEMA  = p.TABLE_SCHEMA
       AND m.TABLE_NAME    = p.TABLE_NAME
       AND m.COLUMN_NAME   = p.COLUMN_NAME
WHERE m.COLUMN_NAME IS NULL
ORDER BY p.database_name, p.TABLE_SCHEMA, p.TABLE_NAME, p.COLUMN_NAME;

-- Summary line for the readout
WITH phi_candidates AS (
    SELECT c.TABLE_CATALOG AS db, c.TABLE_SCHEMA AS sch, c.TABLE_NAME AS tbl, c.COLUMN_NAME AS col
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    WHERE c.DELETED IS NULL
      AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
      AND c.TABLE_CATALOG LIKE $DB_PATTERN
      AND UPPER(c.COLUMN_NAME) REGEXP
          '.*(SSN|MRN|MEDICAL_REC|PAT_ID|PATIENT_ID|MEMBER_ID|SUBSCRIBER|FIRST_NAME|LAST_NAME|EMAIL|PHONE|DOB|BIRTH_DATE|ADDR|ZIP).*'
),
masked AS (
    SELECT DISTINCT REF_DATABASE_NAME db, REF_SCHEMA_NAME sch, REF_ENTITY_NAME tbl, REF_COLUMN_NAME col
    FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
    WHERE POLICY_KIND = 'MASKING_POLICY' AND REF_COLUMN_NAME IS NOT NULL
)
SELECT
    COUNT(*)                                          AS phi_candidate_columns,
    COUNT(m.col)                                      AS masked_columns,
    COUNT(*) - COUNT(m.col)                           AS unmasked_columns,
    ROUND(100.0 * COUNT(m.col) / NULLIF(COUNT(*),0), 1) AS pct_masked
FROM phi_candidates p
LEFT JOIN masked m
       ON m.db = p.db AND m.sch = p.sch AND m.tbl = p.tbl AND m.col = p.col;


/* ---------------------------------------------------------------------------
   BLOCK 6 · Roles and role hierarchy
   Confirms the "masked / unmasked role" pattern described in discovery.
   --------------------------------------------------------------------------- */
SELECT NAME AS role_name, COMMENT, OWNER, CREATED_ON, DELETED_ON
FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
WHERE DELETED_ON IS NULL
ORDER BY NAME;

-- Role-to-role grants (the hierarchy)
SELECT
    GRANTEE_NAME                         AS child_role,
    NAME                                 AS granted_role,
    PRIVILEGE,
    GRANTED_BY,
    CREATED_ON
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE DELETED_ON IS NULL
  AND GRANTED_ON = 'ROLE'
  AND PRIVILEGE  = 'USAGE'
ORDER BY child_role, granted_role;


/* ---------------------------------------------------------------------------
   BLOCK 7 · Object privileges granted to roles
   Shows who can read what — the practical access map.
   --------------------------------------------------------------------------- */
SELECT
    GRANTEE_NAME                         AS role_name,
    PRIVILEGE,
    GRANTED_ON                           AS object_type,
    TABLE_CATALOG                        AS database_name,
    TABLE_SCHEMA,
    NAME                                 AS object_name,
    GRANT_OPTION,
    GRANTED_BY,
    CREATED_ON
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE DELETED_ON IS NULL
  AND GRANTED_ON IN ('TABLE','VIEW','MATERIALIZED VIEW','SCHEMA','DATABASE')
  AND (TABLE_CATALOG LIKE $DB_PATTERN OR TABLE_CATALOG IS NULL)
ORDER BY role_name, object_type, database_name, TABLE_SCHEMA, object_name;

-- Rollup: privilege surface per role
SELECT
    GRANTEE_NAME                         AS role_name,
    GRANTED_ON                           AS object_type,
    PRIVILEGE,
    COUNT(*)                             AS grant_count
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE DELETED_ON IS NULL
  AND GRANTED_ON IN ('TABLE','VIEW','MATERIALIZED VIEW','SCHEMA','DATABASE')
GROUP BY ALL
ORDER BY role_name, grant_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 8 · Users and their roles — privileged access review
   Flags how many humans hold ACCOUNTADMIN / SECURITYADMIN / SYSADMIN.
   --------------------------------------------------------------------------- */
SELECT
    GRANTEE_NAME                         AS user_name,
    ROLE                                 AS role_name,
    GRANTED_BY,
    CREATED_ON
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE DELETED_ON IS NULL
ORDER BY role_name, user_name;

-- Privileged role holders
SELECT
    ROLE AS privileged_role,
    COUNT(DISTINCT GRANTEE_NAME) AS user_count,
    LISTAGG(DISTINCT GRANTEE_NAME, ', ') WITHIN GROUP (ORDER BY GRANTEE_NAME) AS users
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE DELETED_ON IS NULL
  AND ROLE IN ('ACCOUNTADMIN','SECURITYADMIN','SYSADMIN','ORGADMIN')
GROUP BY ALL
ORDER BY privileged_role;


/* ---------------------------------------------------------------------------
   BLOCK 9 · User security posture — SSO / MFA / key-pair / service accounts
   --------------------------------------------------------------------------- */
SELECT
    NAME                                 AS user_name,
    LOGIN_NAME,
    DISABLED,
    HAS_PASSWORD,
    HAS_RSA_PUBLIC_KEY,                  -- key-pair auth (service accounts)
    EXT_AUTHN_DUO                        AS mfa_duo_enabled,
    DEFAULT_ROLE,
    DEFAULT_WAREHOUSE,
    LAST_SUCCESS_LOGIN,
    DATEDIFF('day', LAST_SUCCESS_LOGIN, CURRENT_TIMESTAMP()) AS days_since_login,
    CREATED_ON,
    OWNER,
    COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE DELETED_ON IS NULL
ORDER BY DISABLED, days_since_login DESC NULLS FIRST;


/* ---------------------------------------------------------------------------
   BLOCK 10 · Future grants
   Determines whether new objects inherit access automatically — a maturity
   signal, and relevant to how the new Gold/Shared model will be governed.
   --------------------------------------------------------------------------- */
-- SHOW does not accept a wildcard. Run once per database / schema,
-- substituting the real names from script 01 block 1.
--
--   SHOW FUTURE GRANTS IN DATABASE <DB>;
--   SHOW FUTURE GRANTS IN SCHEMA   <DB>.<SCHEMA>;
--
-- Capture each result set with:
--   SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* ---------------------------------------------------------------------------
   BLOCK 11 · Network policies and account-level security parameters
   Requires ACCOUNTADMIN.
   --------------------------------------------------------------------------- */
SHOW NETWORK POLICIES;
SHOW PARAMETERS LIKE '%TIMEOUT%'   IN ACCOUNT;
SHOW PARAMETERS LIKE '%RETENTION%' IN ACCOUNT;
