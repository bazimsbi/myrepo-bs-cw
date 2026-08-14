/* ============================================================================
   08 · OPTIONAL DATA PROFILING   ***  OPT-IN — REQUIRES APPROVAL  ***
   Corewell Health — Snowflake DD&A  |  Prepared by TEKsystems Team (TGS)

   ----------------------------------------------------------------------------
   !! READ BEFORE RUNNING !!

   Unlike scripts 01-07, these queries READ TABLE DATA. They are written to
   return only AGGREGATES (counts, cardinality, null rates, min/max on dates
   and numerics) and never row-level values — but they still execute against
   tables that may contain PHI.

   DO NOT RUN without explicit approval from Corewell's data governance owner.
   Run against the fewest tables needed, and prefer non-PHI tables where the
   question can be answered either way.

   Every query below is a template: replace <DB>.<SCHEMA>.<TABLE> and the
   column lists before executing. Nothing runs as-is.
   ----------------------------------------------------------------------------

   PURPOSE  Confirm the GRAIN of the three source feeds — Epic (encounter
            level), MHA Claims (discharge level) and Strata (cost case level).
            Grain reconciliation is the central modelling problem for the
            Strategy & Market Intelligence model, and it cannot be resolved
            from metadata alone.
   ============================================================================ */


/* ---------------------------------------------------------------------------
   TEMPLATE 1 · Grain test — is this column set unique?
   The definitive test of a table's grain. Run per candidate key combination.
   --------------------------------------------------------------------------- */
/*
SELECT
    COUNT(*)                                            AS total_rows,
    COUNT(DISTINCT <KEY_COL_1>)                         AS distinct_key1,
    COUNT(DISTINCT <KEY_COL_1> || '|' || <KEY_COL_2>)   AS distinct_key_combo,
    COUNT(*) - COUNT(DISTINCT <KEY_COL_1> || '|' || <KEY_COL_2>) AS duplicate_rows,
    CASE
        WHEN COUNT(*) = COUNT(DISTINCT <KEY_COL_1> || '|' || <KEY_COL_2>)
            THEN 'UNIQUE — grain confirmed'
        ELSE 'NOT UNIQUE — grain is finer than these columns'
    END                                                 AS grain_verdict
FROM <DB>.<SCHEMA>.<TABLE>;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 2 · Column profile — cardinality, null rate, range
   Returns aggregates only. Safe for numeric and date columns; for string
   columns it returns counts, NOT sample values.
   --------------------------------------------------------------------------- */
/*
SELECT
    COUNT(*)                                                       AS row_count,
    COUNT(<COL>)                                                   AS non_null_count,
    COUNT(*) - COUNT(<COL>)                                        AS null_count,
    ROUND(100.0 * (COUNT(*) - COUNT(<COL>)) / NULLIF(COUNT(*),0), 2) AS pct_null,
    COUNT(DISTINCT <COL>)                                          AS distinct_values,
    ROUND(100.0 * COUNT(DISTINCT <COL>) / NULLIF(COUNT(*),0), 2)   AS pct_distinct,
    MIN(<COL>)                                                     AS min_value,  -- omit for PHI columns
    MAX(<COL>)                                                     AS max_value   -- omit for PHI columns
FROM <DB>.<SCHEMA>.<TABLE>;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 2b · Null-rate sweep across many columns at once
   Aggregate-only, no values returned. Safe for PHI-bearing tables.
   --------------------------------------------------------------------------- */
/*
SELECT
    COUNT(*) AS row_count,
    ROUND(100.0 * COUNT_IF(<COL_A> IS NULL) / NULLIF(COUNT(*),0), 2) AS pct_null_col_a,
    ROUND(100.0 * COUNT_IF(<COL_B> IS NULL) / NULLIF(COUNT(*),0), 2) AS pct_null_col_b,
    ROUND(100.0 * COUNT_IF(<COL_C> IS NULL) / NULLIF(COUNT(*),0), 2) AS pct_null_col_c,
    COUNT(DISTINCT <COL_A>) AS card_col_a,
    COUNT(DISTINCT <COL_B>) AS card_col_b,
    COUNT(DISTINCT <COL_C>) AS card_col_c
FROM <DB>.<SCHEMA>.<TABLE>;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 3 · Date coverage and history depth
   Establishes how much history exists per source — needed to determine the
   time dimension range and whether the three sources are comparable.
   --------------------------------------------------------------------------- */
/*
SELECT
    MIN(<DATE_COL>)                                        AS earliest_date,
    MAX(<DATE_COL>)                                        AS latest_date,
    DATEDIFF('day', MIN(<DATE_COL>), MAX(<DATE_COL>))      AS days_of_history,
    COUNT(DISTINCT DATE_TRUNC('month', <DATE_COL>))        AS distinct_months,
    COUNT(*)                                               AS total_rows,
    ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT DATE_TRUNC('month', <DATE_COL>)),0), 0)
                                                           AS avg_rows_per_month
FROM <DB>.<SCHEMA>.<TABLE>;
*/

-- Volume by month — reveals gaps, backfills and load anomalies
/*
SELECT
    DATE_TRUNC('month', <DATE_COL>)  AS month,
    COUNT(*)                         AS row_count
FROM <DB>.<SCHEMA>.<TABLE>
GROUP BY 1
ORDER BY 1;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 4 · Referential integrity check between two tables
   Snowflake does not enforce FKs, so orphan rates must be measured. Important
   before declaring a relationship in the logical model.
   --------------------------------------------------------------------------- */
/*
SELECT
    COUNT(*)                                                   AS child_rows,
    COUNT(p.<PARENT_KEY>)                                      AS matched_rows,
    COUNT(*) - COUNT(p.<PARENT_KEY>)                           AS orphan_rows,
    ROUND(100.0 * (COUNT(*) - COUNT(p.<PARENT_KEY>))
          / NULLIF(COUNT(*),0), 2)                             AS pct_orphaned
FROM <DB>.<SCHEMA>.<CHILD_TABLE> c
LEFT JOIN <DB>.<SCHEMA>.<PARENT_TABLE> p
       ON c.<CHILD_FK> = p.<PARENT_KEY>;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 5 · Cross-source overlap   ** the market-share question **

   For Strategy & Market Intelligence, a core requirement is distinguishing
   "our" activity from total market activity in the MHA data. This measures
   how well Epic encounters reconcile to MHA discharge records.

   NOTE: if the join requires patient-level identifiers, this becomes a PHI
   operation and must be run by Corewell staff under their own controls —
   not by the TEKsystems team. Prefer facility/service-line/period joins.
   --------------------------------------------------------------------------- */
/*
SELECT
    COUNT(DISTINCT e.<FACILITY_KEY>)                AS epic_facilities,
    COUNT(DISTINCT m.<FACILITY_KEY>)                AS mha_facilities,
    COUNT(DISTINCT CASE WHEN m.<FACILITY_KEY> IS NOT NULL
                        THEN e.<FACILITY_KEY> END)  AS matched_facilities
FROM <DB>.<SCHEMA>.<EPIC_TABLE> e
FULL OUTER JOIN <DB>.<SCHEMA>.<MHA_TABLE> m
       ON  e.<FACILITY_KEY> = m.<FACILITY_KEY>
       AND DATE_TRUNC('month', e.<DATE_COL>) = DATE_TRUNC('month', m.<DATE_COL>);
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 6 · Code-set conformance
   Do the three sources use the same reference codes (ICD, DRG, CPT, service
   line, facility)? Divergent code sets are the most common cause of failed
   conformed dimensions.
   --------------------------------------------------------------------------- */
/*
SELECT 'EPIC' AS source, COUNT(DISTINCT <CODE_COL>) AS distinct_codes,
       MIN(LENGTH(<CODE_COL>)) AS min_len, MAX(LENGTH(<CODE_COL>)) AS max_len
FROM <DB>.<SCHEMA>.<EPIC_TABLE>
UNION ALL
SELECT 'MHA',  COUNT(DISTINCT <CODE_COL>), MIN(LENGTH(<CODE_COL>)), MAX(LENGTH(<CODE_COL>))
FROM <DB>.<SCHEMA>.<MHA_TABLE>
UNION ALL
SELECT 'STRATA', COUNT(DISTINCT <CODE_COL>), MIN(LENGTH(<CODE_COL>)), MAX(LENGTH(<CODE_COL>))
FROM <DB>.<SCHEMA>.<STRATA_TABLE>;
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 7 · SCD Type 2 integrity
   Discovery confirmed SCD2 dimensions via dbt snapshots. This validates that
   no entity has overlapping or gapped effective periods.
   --------------------------------------------------------------------------- */
/*
WITH windows AS (
    SELECT
        <BUSINESS_KEY>,
        <VALID_FROM>,
        <VALID_TO>,
        LEAD(<VALID_FROM>) OVER (PARTITION BY <BUSINESS_KEY>
                                 ORDER BY <VALID_FROM>) AS next_valid_from
    FROM <DB>.<SCHEMA>.<DIM_TABLE>
)
SELECT
    COUNT(*)                                                       AS total_versions,
    COUNT(DISTINCT <BUSINESS_KEY>)                                 AS distinct_entities,
    COUNT_IF(<VALID_TO> > next_valid_from)                         AS overlapping_periods,
    COUNT_IF(next_valid_from IS NOT NULL
             AND <VALID_TO> < next_valid_from)                     AS gapped_periods
FROM windows;
*/

-- Current-record check: exactly one open record per business key
/*
SELECT
    COUNT(*)                                        AS entities_with_open_record,
    COUNT_IF(open_records > 1)                      AS entities_with_multiple_open,
    COUNT_IF(open_records = 0)                      AS entities_with_none_open
FROM (
    SELECT <BUSINESS_KEY>, COUNT_IF(<VALID_TO> IS NULL) AS open_records
    FROM <DB>.<SCHEMA>.<DIM_TABLE>
    GROUP BY 1
);
*/


/* ---------------------------------------------------------------------------
   TEMPLATE 8 · Duplicate detection on a declared key
   --------------------------------------------------------------------------- */
/*
SELECT <KEY_COL>, COUNT(*) AS occurrences
FROM <DB>.<SCHEMA>.<TABLE>
GROUP BY 1
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 100;
*/
