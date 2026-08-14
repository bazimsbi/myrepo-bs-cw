/* ============================================================================
   02 · COLUMN PROFILING & GRAIN DISCOVERY
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   PURPOSE  Column-level inventory to seed the conceptual data model, locate
            candidate keys and grain, and surface PHI/PII candidates ahead of
            the governance session.
   READS    SNOWFLAKE.ACCOUNT_USAGE (metadata only)
   RETURNS  Column NAMES and data types. No column VALUES. No PHI/PII content.
   NEEDS    IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE
   ============================================================================ */

-- ---------------------------------------------------------------- CONFIGURE
SET DB_PATTERN = '%';


/* ---------------------------------------------------------------------------
   BLOCK 1 · Full column inventory
   The raw material for conceptual modelling. Large result — export to CSV.
   --------------------------------------------------------------------------- */
SELECT
    c.TABLE_CATALOG                      AS database_name,
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.ORDINAL_POSITION,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    COALESCE(c.CHARACTER_MAXIMUM_LENGTH,
             c.NUMERIC_PRECISION)        AS size_or_precision,
    c.NUMERIC_SCALE,
    c.IS_NULLABLE,
    c.COLUMN_DEFAULT,
    c.IS_IDENTITY,
    c.COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
WHERE c.DELETED IS NULL
  AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND c.TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY c.TABLE_CATALOG, c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION;


/* ---------------------------------------------------------------------------
   BLOCK 2 · Data type distribution
   Highlights modelling smells: everything VARCHAR, VARIANT-heavy landing,
   inconsistent numeric precision across what should be the same measure.
   --------------------------------------------------------------------------- */
SELECT
    c.TABLE_CATALOG                      AS database_name,
    c.TABLE_SCHEMA,
    c.DATA_TYPE,
    COUNT(*)                             AS column_count,
    COUNT(DISTINCT c.TABLE_NAME)         AS tables_using
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
WHERE c.DELETED IS NULL
  AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND c.TABLE_CATALOG LIKE $DB_PATTERN
GROUP BY ALL
ORDER BY database_name, TABLE_SCHEMA, column_count DESC;


/* ---------------------------------------------------------------------------
   BLOCK 3 · Declared constraints (PK / FK / UNIQUE)
   Snowflake constraints are informational, not enforced — but where dbt or the
   engineers declared them, they document intended grain and relationships.
   Empty results are themselves a finding.
   --------------------------------------------------------------------------- */
SELECT
    tc.TABLE_CATALOG                     AS database_name,
    tc.TABLE_SCHEMA,
    tc.TABLE_NAME,
    tc.CONSTRAINT_NAME,
    tc.CONSTRAINT_TYPE,                  -- PRIMARY KEY / UNIQUE / FOREIGN KEY
    tc.COMMENT
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_CONSTRAINTS tc
WHERE tc.DELETED IS NULL
  AND tc.TABLE_CATALOG LIKE $DB_PATTERN
ORDER BY tc.CONSTRAINT_TYPE, tc.TABLE_CATALOG, tc.TABLE_SCHEMA, tc.TABLE_NAME;

-- Foreign key relationships in detail (the implied ERD)
SELECT
    rc.CONSTRAINT_NAME,
    rc.CONSTRAINT_SCHEMA,
    rc.UNIQUE_CONSTRAINT_NAME,
    rc.UNIQUE_CONSTRAINT_SCHEMA,
    rc.MATCH_OPTION,
    rc.UPDATE_RULE,
    rc.DELETE_RULE
FROM SNOWFLAKE.ACCOUNT_USAGE.REFERENTIAL_CONSTRAINTS rc
WHERE rc.DELETED IS NULL
ORDER BY rc.CONSTRAINT_SCHEMA, rc.CONSTRAINT_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 4 · PHI / PII CANDIDATE COLUMNS   ** priority for governance session **

   Name-pattern screen for protected health information and personal data,
   tuned for a healthcare payvider (Epic clinical + claims + cost accounting).

   IMPORTANT — this is a NAME-based heuristic, not a classification.
     · It will produce false positives (e.g. "PROVIDER_NAME" is not PHI).
     · It will MISS anything non-obviously named.
   Treat the output as the candidate list to walk through with Corewell's
   governance SME, not as a finished PHI inventory.
   --------------------------------------------------------------------------- */
WITH scored AS (
    SELECT
        c.TABLE_CATALOG                  AS database_name,
        c.TABLE_SCHEMA,
        c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE,
        UPPER(c.COLUMN_NAME)             AS col_u,
        CASE
            -- Direct identifiers — HIPAA Safe Harbor
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(SSN|SOCIAL_SEC|TAX_ID|TIN).*'
                THEN 'DIRECT ID — national identifier'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(MRN|MEDICAL_REC|PAT_ID|PATIENT_ID|PATIENT_NUM|PAT_MRN).*'
                THEN 'DIRECT ID — medical record number'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(MEMBER_ID|SUBSCRIBER|POLICY_NUM|GROUP_NUM|HICN|MBI).*'
                THEN 'DIRECT ID — health plan member'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(FIRST_NAME|LAST_NAME|MIDDLE_NAME|FULL_NAME|PAT_NAME|PATIENT_NAME|SURNAME).*'
                THEN 'DIRECT ID — name'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(EMAIL|PHONE|MOBILE|FAX|CONTACT_NUM).*'
                THEN 'DIRECT ID — contact'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(ADDR|STREET|CITY|ZIP|POSTAL|COUNTY|GEOCODE|LATITUDE|LONGITUDE).*'
                THEN 'QUASI ID — geography'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(DOB|BIRTH_DATE|DATE_OF_BIRTH|BIRTHDATE|DEATH_DATE|DECEASED|AGE).*'
                THEN 'QUASI ID — dates/age'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(ACCOUNT_NUM|ACCT_NUM|GUARANTOR|CLAIM_NUM|CLAIM_ID|INVOICE).*'
                THEN 'DIRECT ID — account/claim'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(CSN|ENCOUNTER_ID|VISIT_ID|ADMIT_ID|CONTACT_SERIAL).*'
                THEN 'INDIRECT ID — encounter key'
            -- Sensitive clinical categories
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(HIV|AIDS|SUBSTANCE|SUD|ALCOHOL|DRUG_ABUSE|BEHAVIORAL|PSYCH|MENTAL_HEALTH).*'
                THEN 'SENSITIVE — potential 42 CFR Part 2 / behavioral health'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(GENOM|GENETIC|DNA|VARIANT_CALL|SEQUENCE).*'
                THEN 'SENSITIVE — genomic (GINA)'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(DIAGNOS|ICD|DRG|PROCEDURE|CPT|HCPCS|MEDICATION|RX_|PRESCRIP).*'
                THEN 'CLINICAL — diagnosis/procedure/medication'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(RACE|ETHNIC|GENDER|SEX|LANGUAGE|RELIGION|MARITAL|VETERAN).*'
                THEN 'DEMOGRAPHIC — protected class'
            ELSE NULL
        END                              AS phi_pii_category
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    WHERE c.DELETED IS NULL
      AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
      AND c.TABLE_CATALOG LIKE $DB_PATTERN
)
SELECT
    phi_pii_category,
    database_name,
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE
FROM scored
WHERE phi_pii_category IS NOT NULL
ORDER BY
    CASE
        WHEN phi_pii_category LIKE 'SENSITIVE%' THEN 1
        WHEN phi_pii_category LIKE 'DIRECT ID%' THEN 2
        WHEN phi_pii_category LIKE 'QUASI ID%'  THEN 3
        ELSE 4
    END,
    database_name, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 4b · PHI/PII candidate rollup — the number for the readout
   Cross-referenced against masking coverage in script 03.
   --------------------------------------------------------------------------- */
WITH scored AS (
    SELECT
        c.TABLE_CATALOG AS database_name,
        c.TABLE_SCHEMA,
        CASE
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(SSN|SOCIAL_SEC|MRN|MEDICAL_REC|PAT_ID|PATIENT_ID|MEMBER_ID|SUBSCRIBER|FIRST_NAME|LAST_NAME|FULL_NAME|EMAIL|PHONE|DOB|BIRTH_DATE|DATE_OF_BIRTH|ADDR|STREET|ZIP|POSTAL).*'
                THEN 'IDENTIFIER'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(HIV|SUBSTANCE|SUD|ALCOHOL|BEHAVIORAL|PSYCH|MENTAL_HEALTH|GENOM|GENETIC).*'
                THEN 'SENSITIVE CATEGORY'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*(DIAGNOS|ICD|DRG|PROCEDURE|CPT|HCPCS|MEDICATION).*'
                THEN 'CLINICAL'
            ELSE NULL
        END AS category
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    WHERE c.DELETED IS NULL
      AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
      AND c.TABLE_CATALOG LIKE $DB_PATTERN
)
SELECT database_name, TABLE_SCHEMA, category, COUNT(*) AS candidate_columns
FROM scored
WHERE category IS NOT NULL
GROUP BY ALL
ORDER BY database_name, TABLE_SCHEMA, candidate_columns DESC;


/* ---------------------------------------------------------------------------
   BLOCK 5 · CANDIDATE KEYS AND GRAIN   ** priority for data modelling **

   Surfaces likely business keys, surrogate keys and dimension/fact grain by
   naming convention. This is how we begin reconciling grain across the three
   sources (Epic = encounter level, MHA = discharge level, Strata = cost case).
   --------------------------------------------------------------------------- */
WITH classified AS (
    SELECT
        c.TABLE_CATALOG                      AS database_name,
        c.TABLE_SCHEMA,
        c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE,
        c.ORDINAL_POSITION,
        CASE
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_SK$|^SK_.*|.*SURROGATE.*'  THEN 'SURROGATE KEY'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_BK$|.*BUSINESS_KEY.*'      THEN 'BUSINESS KEY'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_HK$|.*HASH.*'              THEN 'HASH KEY'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_ID$|^ID$'                  THEN 'ID COLUMN'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_KEY$'                      THEN 'KEY COLUMN'
            WHEN UPPER(c.COLUMN_NAME) REGEXP '.*_CODE$'                     THEN 'CODE COLUMN'
            ELSE NULL
        END                                  AS key_candidate_type,
        CASE
            WHEN UPPER(c.TABLE_NAME) REGEXP '^DIM_.*|.*_DIM$'               THEN 'DIMENSION'
            WHEN UPPER(c.TABLE_NAME) REGEXP '^FACT_.*|^FCT_.*|.*_FACT$'     THEN 'FACT'
            WHEN UPPER(c.TABLE_NAME) REGEXP '^BRG_.*|.*BRIDGE.*'            THEN 'BRIDGE'
            WHEN UPPER(c.TABLE_NAME) REGEXP '^STG_.*'                       THEN 'STAGING'
            WHEN UPPER(c.TABLE_NAME) REGEXP '.*SNAPSHOT.*'                  THEN 'DBT SNAPSHOT'
            ELSE NULL
        END                                  AS modelled_object_type
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    WHERE c.DELETED IS NULL
      AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
      AND c.TABLE_CATALOG LIKE $DB_PATTERN
)
SELECT database_name, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       key_candidate_type, modelled_object_type
FROM classified
WHERE key_candidate_type IS NOT NULL
   OR modelled_object_type IS NOT NULL
ORDER BY database_name, TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;


/* ---------------------------------------------------------------------------
   BLOCK 6 · SCD Type 2 / history-tracking footprint
   Discovery confirmed dbt snapshots plus SCD1 and SCD2. This locates them.
   --------------------------------------------------------------------------- */
SELECT
    c.TABLE_CATALOG                      AS database_name,
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    LISTAGG(c.COLUMN_NAME, ', ')
        WITHIN GROUP (ORDER BY c.ORDINAL_POSITION) AS scd_columns_present,
    COUNT(*)                             AS scd_column_count
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
WHERE c.DELETED IS NULL
  AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND c.TABLE_CATALOG LIKE $DB_PATTERN
  AND UPPER(c.COLUMN_NAME) IN (
        'DBT_VALID_FROM','DBT_VALID_TO','DBT_SCD_ID','DBT_UPDATED_AT',
        'VALID_FROM','VALID_TO','EFFECTIVE_FROM','EFFECTIVE_TO',
        'EFF_START_DATE','EFF_END_DATE','START_DATE','END_DATE',
        'IS_CURRENT','CURRENT_FLAG','IS_ACTIVE','ROW_IS_CURRENT','VERSION'
      )
GROUP BY ALL
ORDER BY scd_column_count DESC, database_name, TABLE_SCHEMA, TABLE_NAME;


/* ---------------------------------------------------------------------------
   BLOCK 7 · Audit / lineage columns present on tables
   Indicates whether load metadata is retained — needed for lineage and for
   incremental logic review.
   --------------------------------------------------------------------------- */
SELECT
    c.TABLE_CATALOG                      AS database_name,
    c.TABLE_SCHEMA,
    COUNT(DISTINCT c.TABLE_NAME)         AS tables_with_audit_cols,
    LISTAGG(DISTINCT UPPER(c.COLUMN_NAME), ', ') AS audit_columns_seen
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
WHERE c.DELETED IS NULL
  AND c.TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
  AND c.TABLE_CATALOG LIKE $DB_PATTERN
  AND UPPER(c.COLUMN_NAME) REGEXP '.*(LOAD_DATE|LOADED_AT|INSERT_DATE|INSERTED_AT|UPDATE_DATE|UPDATED_AT|CREATED_AT|ETL_|BATCH_ID|SOURCE_SYSTEM|SOURCE_FILE|_FILE_NAME|INGEST).*'
GROUP BY ALL
ORDER BY tables_with_audit_cols DESC;


/* ---------------------------------------------------------------------------
   FALLBACK · Without SNOWFLAKE database access, run per database
   --------------------------------------------------------------------------- */
-- USE DATABASE <DB>;
-- SELECT TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME,
--        DATA_TYPE, IS_NULLABLE, COMMENT
-- FROM   INFORMATION_SCHEMA.COLUMNS
-- WHERE  TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
-- ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;
