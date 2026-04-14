/* ====================================================================================================
PROGRAM:  Metro 2 Remediation Simulator — (Version 2)
SUBTITLE: Module 2: Credit Impact Window and PHP Remediation Engine
FILE:     module_02_metro2_remediation_engine.sql
AUTHOR:   Andrew R Goad
DB:       PostgreSQL 15+
PURPOSE:  Build a synthetic credit-reporting remediation engine on top of Module 1 outputs.

AUTHORING INTENT
----------------
This script is written as BOTH:
1) a working remediation simulation module, and
2) a teaching tool for users who want to learn both the SQL mechanics and the credit-risk /
   Metro 2 remediation methodology step by step.

DEPENDENCY
----------
This module expects Module 1 to have already been run successfully and to have produced:
   - module1.metro2_final
   - module1.metro2_status_history

These two tables are the core inputs because:
   - module1.metro2_final gives us the stitched account-level history and latest-state fields
   - module1.metro2_status_history gives us the month-level behavioral backbone we need to
     determine cure, credit impact windows, and remediation application

MODULE 2 OBJECTIVES
-------------------
This module performs four major jobs:

1) Simulate a second input table that represents the bank's financial remediation timeframe
   - account
   - impact_start_date
   - impact_end_date

2) Determine the CREDIT reporting impact timeframe
   - credit_impact_start_date
   - credit_impact_end_date
   - credit_cure_date
   - manual_review_flag
   - manual_review_reason

3) Assign a remediation treatment
   - TRADELINE_DELETION
   - FULL_DEROGATORY_PHP_CLEANUP
   - SIMPLE_DELINQUENCY_PHP_CLEANUP
   - NO_IMPACT_CLEAN_PHP_HISTORY

4) Produce remediated delta fields and audit fields
   - remediated_full_php
   - remediated_account_status_17A
   - remediated_payment_rating_17B
   - remediated_date_of_first_delinquency
   - remediation_applied_flag
   - remediation_fields_modified

WHY MODULE 2 EXISTS
-------------------
Module 1 established a realistic synthetic Metro 2 reporting population.

Module 2 adds a remediation layer so we can answer questions like:
- When did the credit reporting impact start?
- When did the credit reporting impact end?
- Did the customer cure after the issue ended?
- Does the account need manual review because impact may still be ongoing?
- Is the right treatment:
    - tradeline deletion
    - full derogatory PHP cleanup
    - simple delinquency PHP cleanup
    - or no credit reporting impact at all?

VERSION HISTORY
---------------
Version 1:
- Initial release of the remediation engine
- Implemented Layer 1 and Layer 2 logic:
    - credit impact timeframe
    - cure logic
    - manual review
    - deletion override
    - PHP cleanup logic
    - remediated secondary fields
    - audit flags

Version 2:
- Corrected false-positive tradeline deletion logic for reversed-major-derog scenarios
- Deletion override no longer uses "no cure yet" as a proxy for "no recovery from derog"
- New logic distinguishes:
    - lack of cure threshold
      versus
    - lack of post-derog recovery evidence
- Tradeline deletion now requires:
    - a derogatory event in the credit impact window, AND
    - no later recovery evidence after the most recent derog month

CORE DESIGN PRINCIPLE
---------------------
Like Module 1, this module is intentionally designed around month-level history rather than
treating PHP strings as the computational backbone.

This means:
- We use module1.metro2_status_history as the truth source
- We evaluate cure and treatment month-by-month
- We then render remediated PHP as an output artifact

This makes the logic:
- easier to validate
- easier to teach
- easier to audit
- more efficient than repeatedly exploding PHP strings everywhere

======================================================================================================
JOB AID — HOW TO USE THIS SCRIPT
======================================================================================================

1) ENVIRONMENT ASSUMPTION
   This script is intended for local PostgreSQL inside DBeaver.
   It is not optimized for lightweight browser sandboxes.

2) EXECUTION ORDER
   A) Run Module 1 first
   B) Then run this Module 2 script
   C) Review the QA queries at the bottom

3) PARAMETER TO EDIT
   Most users should only edit the INSERT INTO module2_params statement.

   Current input:
      - cure_consecutive_months_required

   Default:
      cure_consecutive_months_required = 3

4) CURE POLICY NOTE
   The 3-month cure rule is a conservative remediation-policy default used for this analytical
   framework. It is not presented here as a formal Metro 2 requirement.

   In this module:
   - Cure means N consecutive months of status = '0'
   - Cure is evaluated AFTER impact_end_date
   - B and D do NOT count as cure
   - Only literal 0 counts as cure

5) IMPORTANT DIFFERENCE BETWEEN FINANCIAL IMPACT AND CREDIT IMPACT
   Financial impact dates:
      - impact_start_date
      - impact_end_date

   Credit impact dates:
      - credit_impact_start_date
      - credit_impact_end_date

   In this module:
   - credit_impact_start_date = impact_start_date
   - credit_impact_end_date may extend beyond impact_end_date because we allow time for the
     customer to stabilize from a credit reporting standpoint

6) MANUAL REVIEW POLICY
   Manual review is intended to identify accounts where impact may still be ongoing.

   In this module:
   - If an account is closed and there is no cure, do NOT manual review
   - If an account is open and has insufficient post-impact months, manual review may be needed
   - If an account is open and no cure is found, manual review may be needed
   - HOWEVER: if there is no delinquency and no derogatory content in the credit impact timeframe,
     there is no impact to remediate and no manual review is needed

7) DELETION OVERRIDE POLICY
   Tradeline deletion is the most conservative remediation treatment in this module.

   In Version 2, deletion is triggered only when:
   - a derogatory byte (G/H/J/K/L) exists in the credit impact timeframe, AND
   - there is NO recovery evidence after the most recent derog month

   Recovery evidence for this project means:
   - a later month with explicit payment-performance status in:
       0,1,2,3,4,5,6

   This change is critical because:
   - a customer can recover from a major derog,
   - become non-derog again,
   - yet still fail the configured 3-month cure threshold

   That scenario should route to normal evaluation / cleanup logic,
   NOT automatic tradeline deletion.

8) HOW REMEDIATED PHP WORKS
   FULL_DEROGATORY_PHP_CLEANUP:
      - inside the credit impact timeframe only
      - suppress 1-6 and G/H/J/K/L to D

   SIMPLE_DELINQUENCY_PHP_CLEANUP:
      - inside the credit impact timeframe only
      - suppress 1-6 to D

   TRADELINE_DELETION:
      - no remediated PHP string is populated

   NO_IMPACT_CLEAN_PHP_HISTORY:
      - remediated PHP remains NULL because no change was made

9) IMPORTANT REMEDIATED DERIVATION RULE
   For remediated derived fields only:
      D behaves like 0

   This applies when deriving:
      - remediated_account_status_17A
      - remediated_payment_rating_17B
      - remediated_date_of_first_delinquency

10) DELTA-BASED OUTPUT DESIGN
   Remediated fields are only populated when a change is actually made.

   That means:
   - if remediated_full_php is unchanged, it stays NULL
   - if remediated_account_status_17A is unchanged, it stays NULL
   - etc.

======================================================================================================
MAIN OUTPUT TABLES
======================================================================================================

1) metro2_remediation_input
   Simulated bank remediation input:
      - account
      - impact_start_date
      - impact_end_date

2) metro2_remediation_window_eval
   Layer 1 evaluation output:
      - credit impact dates
      - cure date
      - manual review logic
      - recovery-after-derog logic
      - remediation treatment

3) metro2_remediation_php_detail
   Month-level remediation detail:
      - original_status
      - remediated_status
      - whether the month falls inside the credit impact window

4) metro2_remediation_final
   Final account-level remediation output:
      - original context
      - impact dates
      - remediation treatment
      - remediated delta fields
      - audit flags

======================================================================================================
METRO 2 COMMENT AID USED IN THIS MODULE
======================================================================================================

A) PAYMENT HISTORY PROFILE (PHP)
   - Stored as full history in module1.metro2_final.full_php
   - Leftmost byte = most recent represented month
   - Rightmost byte = oldest represented month

B) PHP BYTES USED HERE
   B = no reported history
   D = suppressed
   0 = current
   1 = 30 DPD
   2 = 60 DPD
   3 = 90 DPD
   4 = 120 DPD
   5 = 150 DPD
   6 = 180+ DPD
   G = collection
   H = foreclosure
   J = voluntary surrender
   K = repossession
   L = charge-off

C) ACCOUNT STATUS 17A VALUES USED HERE
   11 = current
   13 = paid/closed account / zero balance
   61 = paid in full, surrender
   62 = paid in full, collection
   63 = paid in full, repossession
   64 = paid in full, charge-off
   65 = paid in full, foreclosure
   71 = 30–59 DPD
   78 = 60–89 DPD
   80 = 90–119 DPD
   82 = 120–149 DPD
   83 = 150–179 DPD
   84 = 180+ DPD
   93 = collection
   94 = foreclosure
   95 = voluntary surrender
   96 = repossession
   97 = charge-off
   DA = tradeline deletion (synthetic remediation code used in this project)

D) PAYMENT RATING 17B VALUES USED HERE
   0,1,2,3,4,5,6
   G, L
   NULL for 61–65 in this synthetic remediation module
   0 for 13 in this synthetic remediation module

======================================================================================================
IMPORTANT LIMITATIONS
======================================================================================================
1) This is a synthetic remediation-learning module, not a production furnishing engine.
2) Remediated fields are delta-based:
      - only populate when a change is being written to that remediated field
      - otherwise remain NULL
3) Because the remediated fields are delta-based, some conceptual changes-to-NULL are represented
   through treatment and audit fields rather than by forcing a value into every remediated column.
==================================================================================================== */


-- ====================================================================================================
-- SECTION 0: SCHEMA SETUP
-- ====================================================================================================
-- Purpose:
--   Keep Module 2 objects in a dedicated schema while still allowing reads from Module 1 objects.
--
-- Why this exists:
--   A separate schema helps keep project modules organized and easier to inspect in DBeaver.
--
-- SQL mechanics:
--   - CREATE SCHEMA IF NOT EXISTS creates the schema only if needed
--   - SET search_path makes module2 the default target for new objects in this session
-- ====================================================================================================
CREATE SCHEMA IF NOT EXISTS module2;
SET search_path TO module2, module1, public;


-- ====================================================================================================
-- SECTION 1: RESET
-- ====================================================================================================
-- Purpose:
--   Drop prior Module 2 objects so the script can be rerun cleanly.
--
-- Why this exists:
--   Remediation design is iterative. This allows full refresh behavior during development/testing.
--
-- SQL mechanics:
--   - DROP TABLE IF EXISTS avoids errors when objects do not already exist
-- ====================================================================================================
DROP TABLE IF EXISTS module2_params;
DROP TABLE IF EXISTS metro2_remediation_final;
DROP TABLE IF EXISTS metro2_remediation_php_detail;
DROP TABLE IF EXISTS metro2_remediation_window_eval;
DROP TABLE IF EXISTS metro2_remediation_input;


-- ====================================================================================================
-- SECTION 2: USER PARAMETERS
-- ====================================================================================================
-- Purpose:
--   Store user-editable remediation parameters.
--
-- Why this exists:
--   A parameter table makes assumptions easy to:
--   - inspect
--   - validate
--   - reference from later SQL blocks
--
-- SQL mechanics:
--   - CREATE TEMP TABLE creates a session-level parameter table
--   - The INSERT statement below is the primary user-editable input
-- ====================================================================================================
CREATE TEMP TABLE module2_params (
    cure_consecutive_months_required INTEGER NOT NULL
);

INSERT INTO module2_params (
    cure_consecutive_months_required
)
VALUES (
    3    -- conservative remediation-policy default
);


-- ====================================================================================================
-- SECTION 3: GATEKEEPER VALIDATION
-- ====================================================================================================
-- Purpose:
--   Fail fast if the parameter row is invalid.
--
-- Why this exists:
--   Validation at the top prevents confusing downstream failures.
--
-- SQL mechanics:
--   - DO $$ ... $$ executes a procedural PL/pgSQL block
--   - We read the parameter into a variable and test it with IF logic
-- ====================================================================================================
DO $$
DECLARE
    v_cure_months INTEGER;
BEGIN
    SELECT cure_consecutive_months_required
    INTO v_cure_months
    FROM module2_params;

    IF v_cure_months IS NULL OR v_cure_months < 1 THEN
        RAISE EXCEPTION
            'MODULE 2 PARAMETER VALIDATION FAILED: cure_consecutive_months_required must be an integer >= 1. Current value = %',
            v_cure_months;
    END IF;
END $$;


-- ====================================================================================================
-- SECTION 4: BUILD REMEDIATION INPUT TABLE
-- ====================================================================================================
-- Purpose:
--   Simulate the second input table:
--      - account
--      - impact_start_date
--      - impact_end_date
--
-- Why this exists:
--   Module 2 needs a bank-side remediation timeframe input.
--   We simulate it deterministically so the same account gets the same input every run.
--
-- Important rule:
--   impact_start_date and impact_end_date must fall within the represented PHP history:
--      - between php_right_byte_date and php_left_byte_date
--
-- SQL mechanics:
--   - Pull each account's available history window from module1.metro2_final
--   - Use deterministic hashed seeds to choose a valid start offset and duration
--   - This mirrors the reproducible synthetic style used in Module 1
-- ====================================================================================================
CREATE TABLE metro2_remediation_input AS
WITH
base AS (
    SELECT
        f.account,
        f.php_right_byte_date,
        f.php_left_byte_date,
        (
            EXTRACT(YEAR  FROM age(f.php_left_byte_date, f.php_right_byte_date)) * 12
          + EXTRACT(MONTH FROM age(f.php_left_byte_date, f.php_right_byte_date))
        )::INT + 1 AS history_month_count
    FROM module1.metro2_final f
),
seeds AS (
    SELECT
        b.*,
        (('x' || substr(md5(account::text || '-m2a'), 1, 7))::bit(28)::int) AS s1,
        (('x' || substr(md5(account::text || '-m2b'), 1, 7))::bit(28)::int) AS s2
    FROM base b
),
offsets AS (
    SELECT
        account,
        php_right_byte_date,
        php_left_byte_date,
        history_month_count,
        (s1 % history_month_count) AS start_offset
    FROM seeds
),
durations AS (
    SELECT
        o.*,
        (('x' || substr(md5(o.account::text || '-m2c'), 1, 7))::bit(28)::int) AS s3
    FROM offsets o
),
final_input AS (
    SELECT
        d.account,
        (d.php_right_byte_date + ((d.start_offset) * INTERVAL '1 month'))::DATE AS impact_start_date,
        (
            d.php_right_byte_date
            + ((d.start_offset) * INTERVAL '1 month')
            + (
                (
                    (d.s3 % GREATEST(d.history_month_count - d.start_offset, 1))
                ) * INTERVAL '1 month'
              )
        )::DATE AS impact_end_date
    FROM durations d
)
SELECT
    account,
    impact_start_date,
    impact_end_date
FROM final_input
ORDER BY account;

CREATE INDEX ix_remediation_input_account
    ON metro2_remediation_input (account);


-- ====================================================================================================
-- SECTION 5: INPUT VALIDATION
-- ====================================================================================================
-- Purpose:
--   Validate that every simulated remediation input row is logically bounded by the account's
--   represented PHP history.
--
-- SQL mechanics:
--   - Join the simulated input back to module1.metro2_final
--   - Count any invalid rows
--   - Raise an exception if any exist
-- ====================================================================================================
DO $$
DECLARE
    v_bad_rows INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_bad_rows
    FROM metro2_remediation_input i
    JOIN module1.metro2_final f
      ON i.account = f.account
    WHERE i.impact_start_date < f.php_right_byte_date
       OR i.impact_end_date   > f.php_left_byte_date
       OR i.impact_start_date > i.impact_end_date;

    IF v_bad_rows > 0 THEN
        RAISE EXCEPTION
            'MODULE 2 INPUT VALIDATION FAILED: % remediation input rows fall outside the valid PHP bounds or have impact_start_date > impact_end_date.',
            v_bad_rows;
    END IF;
END $$;


-- ====================================================================================================
-- SECTION 6: BUILD LAYER 1 WINDOW EVALUATION TABLE
-- ====================================================================================================
-- Purpose:
--   Establish the credit-impact timeframe and treatment logic.
--
-- This section determines:
--   - credit_impact_start_date
--   - credit_impact_end_date
--   - credit_cure_date
--   - manual_review_flag
--   - manual_review_reason
--   - remediation_treatment
--
-- Major business rules implemented here:
--   1) credit_impact_start_date = impact_start_date
--   2) cure requires N consecutive months of status = '0' AFTER impact_end_date
--   3) if no cure and closed, do not manual review
--   4) if no cure and open, manual review may depend on post-impact history sufficiency
--   5) if there is no delinquency and no derogatory content in the credit impact timeframe,
--      then there is no impact to remediate and no manual review is needed
--   6) tradeline deletion requires:
--         - derog in the credit impact timeframe, AND
--         - no later payment-performance recovery evidence after the most recent derog month
-- ====================================================================================================
CREATE TABLE metro2_remediation_window_eval AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: base
-- Purpose:
--   Combine Module 1 account-level context with the simulated remediation input and parameter row.
--
-- Why this exists:
--   This creates the account-level foundation for all later Layer 1 logic.
--
-- SQL mechanics:
--   - Join module1.metro2_final to metro2_remediation_input by account
--   - Cross join the one-row parameter table
--   - Derive a closed-account flag from 17A
-- --------------------------------------------------------------------------------------------
base AS (
    SELECT
        f.account,
        f.profile_type,
        f.latest_doai,
        f.date_closed,
        f.full_php,
        f.php_left_byte_date,
        f.php_right_byte_date,
        f.account_status_17A,
        f.payment_rating_17B,
        f.date_of_first_delinquency,
        i.impact_start_date,
        i.impact_end_date,
        p.cure_consecutive_months_required,
        CASE
            WHEN f.account_status_17A IN ('13','61','62','63','64','65') THEN 1
            ELSE 0
        END AS is_closed_account
    FROM module1.metro2_final f
    JOIN metro2_remediation_input i
      ON f.account = i.account
    CROSS JOIN module2_params p
),

-- --------------------------------------------------------------------------------------------
-- CTE: post_impact_months
-- Purpose:
--   Pull all month-level statuses strictly AFTER impact_end_date.
--
-- Why this exists:
--   Cure is defined using post-impact months only.
--
-- SQL mechanics:
--   - Join to module1.metro2_status_history
--   - Keep only byte_date > impact_end_date
--   - Sequence months from oldest to newest using ROW_NUMBER
-- --------------------------------------------------------------------------------------------
post_impact_months AS (
    SELECT
        b.account,
        h.byte_date,
        h.status,
        ROW_NUMBER() OVER (
            PARTITION BY b.account
            ORDER BY h.byte_date
        ) AS seq_asc
    FROM base b
    JOIN module1.metro2_status_history h
      ON b.account = h.account
    WHERE h.byte_date > b.impact_end_date
),

-- --------------------------------------------------------------------------------------------
-- CTE: post_impact_counts
-- Purpose:
--   Count how many represented months exist after impact_end_date.
--
-- Why this exists:
--   We need to know whether the account has enough post-impact months to evaluate cure.
-- --------------------------------------------------------------------------------------------
post_impact_counts AS (
    SELECT
        account,
        COUNT(*) AS post_impact_month_count
    FROM post_impact_months
    GROUP BY account
),

-- --------------------------------------------------------------------------------------------
-- CTE: zero_only
-- Purpose:
--   Keep only post-impact months with status = '0'.
--
-- Why this exists:
--   In this framework, cure is strict:
--      only literal 0 counts
--      B and D do not count
--
-- SQL mechanics:
--   - seq_asc - row_number() is a classic SQL technique for identifying consecutive runs
-- --------------------------------------------------------------------------------------------
zero_only AS (
    SELECT
        account,
        byte_date,
        seq_asc,
        seq_asc - ROW_NUMBER() OVER (
            PARTITION BY account
            ORDER BY byte_date
        ) AS zero_grp
    FROM post_impact_months
    WHERE status = '0'
),

-- --------------------------------------------------------------------------------------------
-- CTE: zero_runs
-- Purpose:
--   Collapse consecutive zero rows into runs and measure each run's length.
-- --------------------------------------------------------------------------------------------
zero_runs AS (
    SELECT
        account,
        zero_grp,
        MIN(byte_date) AS run_start_date,
        MAX(byte_date) AS run_end_date,
        COUNT(*) AS run_length
    FROM zero_only
    GROUP BY account, zero_grp
),

-- --------------------------------------------------------------------------------------------
-- CTE: qualifying_cure
-- Purpose:
--   Find the earliest zero run that satisfies the configured cure threshold.
--
-- Definition:
--   credit_cure_date = first month of the first qualifying cure run
-- --------------------------------------------------------------------------------------------
qualifying_cure AS (
    SELECT DISTINCT ON (z.account)
        z.account,
        z.run_start_date AS credit_cure_date
    FROM zero_runs z
    JOIN module2_params p
      ON 1 = 1
    WHERE z.run_length >= p.cure_consecutive_months_required
    ORDER BY z.account, z.run_start_date
),

-- --------------------------------------------------------------------------------------------
-- CTE: preliminary_eval
-- Purpose:
--   Apply the basic Layer 1 credit-impact end-date logic BEFORE treatment assignment.
--
-- Rules:
--   - If cure found:
--       credit_impact_end_date = month before cure date
--       manual_review_flag_pre = 0
--   - Else if closed:
--       credit_impact_end_date = php_left_byte_date
--       manual_review_flag_pre = 0
--   - Else if insufficient post-impact months:
--       credit_impact_end_date = php_left_byte_date
--       manual_review_flag_pre = 1
--       reason = INSUFFICIENT_POST_IMPACT_HISTORY
--   - Else:
--       credit_impact_end_date = php_left_byte_date
--       manual_review_flag_pre = 1
--       reason = NO_CURE_OPEN_ACCOUNT
-- --------------------------------------------------------------------------------------------
preliminary_eval AS (
    SELECT
        b.account,
        b.profile_type,
        b.latest_doai,
        b.date_closed,
        b.full_php,
        b.php_left_byte_date,
        b.php_right_byte_date,
        b.account_status_17A,
        b.payment_rating_17B,
        b.date_of_first_delinquency,
        b.impact_start_date,
        b.impact_end_date,
        b.cure_consecutive_months_required,
        b.is_closed_account,

        b.impact_start_date AS credit_impact_start_date,
        qc.credit_cure_date,

        COALESCE(pc.post_impact_month_count, 0) AS post_impact_month_count,

        CASE
            WHEN qc.credit_cure_date IS NOT NULL
                THEN (qc.credit_cure_date - INTERVAL '1 month')::DATE
            ELSE b.php_left_byte_date
        END AS credit_impact_end_date_pre,

        CASE
            WHEN qc.credit_cure_date IS NOT NULL THEN 0
            WHEN b.is_closed_account = 1 THEN 0
            WHEN COALESCE(pc.post_impact_month_count, 0) < b.cure_consecutive_months_required THEN 1
            ELSE 1
        END AS manual_review_flag_pre,

        CASE
            WHEN qc.credit_cure_date IS NOT NULL THEN NULL
            WHEN b.is_closed_account = 1 THEN NULL
            WHEN COALESCE(pc.post_impact_month_count, 0) < b.cure_consecutive_months_required
                THEN 'INSUFFICIENT_POST_IMPACT_HISTORY'
            ELSE 'NO_CURE_OPEN_ACCOUNT'
        END AS manual_review_reason_pre
    FROM base b
    LEFT JOIN qualifying_cure qc
      ON b.account = qc.account
    LEFT JOIN post_impact_counts pc
      ON b.account = pc.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: credit_window_flags
-- Purpose:
--   Inspect the provisional credit impact window and detect whether it contains:
--   - any derogatory bytes (G/H/J/K/L)
--   - any delinquency bytes (1-6)
--
-- Why this exists:
--   These flags drive both:
--   - treatment assignment
--   - manual review refinement
--
-- Important enhancement:
--   If the credit impact window contains neither delinquency nor derogatory content,
--   then the account is effectively "no impact" from a credit reporting standpoint,
--   even if post-impact history is short.
-- --------------------------------------------------------------------------------------------
credit_window_flags AS (
    SELECT
        p.account,
        MAX(CASE WHEN h.status IN ('G','H','J','K','L') THEN 1 ELSE 0 END) AS has_derog_in_credit_window,
        MAX(CASE WHEN h.status IN ('1','2','3','4','5','6') THEN 1 ELSE 0 END) AS has_delinquency_in_credit_window
    FROM preliminary_eval p
    JOIN module1.metro2_status_history h
      ON p.account = h.account
     AND h.byte_date BETWEEN p.credit_impact_start_date AND p.credit_impact_end_date_pre
    GROUP BY p.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: most_recent_derog_in_window
-- Purpose:
--   Find the most recent derogatory month inside the provisional credit impact window.
--
-- Why this exists:
--   Version 2 fixes a logic bug by distinguishing:
--      - "no cure yet"
--        from
--      - "no recovery from derog"
--
-- We only want tradeline deletion when the derog is truly unresolved.
--
-- SQL mechanics:
--   - MAX(byte_date) returns the most recent derog month because byte_date increases forward in time
-- --------------------------------------------------------------------------------------------
most_recent_derog_in_window AS (
    SELECT
        p.account,
        MAX(h.byte_date) AS most_recent_derog_date
    FROM preliminary_eval p
    JOIN module1.metro2_status_history h
      ON p.account = h.account
     AND h.byte_date BETWEEN p.credit_impact_start_date AND p.credit_impact_end_date_pre
     AND h.status IN ('G','H','J','K','L')
    GROUP BY p.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: post_derog_recovery_flags
-- Purpose:
--   Check whether any later month AFTER the most recent derog month shows explicit
--   payment-performance recovery evidence.
--
-- Recovery evidence for this project means:
--   a later month with status in:
--      0,1,2,3,4,5,6
--
-- Why this exists:
--   A reversed major derog can still fail the configured cure threshold while clearly showing
--   that the customer exited the derog state. That should NOT force tradeline deletion.
--
-- SQL mechanics:
--   - Join the most recent derog month to later months in the same account history
--   - If any later month is 0-6, we mark recovery evidence = 1
-- --------------------------------------------------------------------------------------------
post_derog_recovery_flags AS (
    SELECT
        d.account,
        MAX(CASE WHEN h.status IN ('0','1','2','3','4','5','6') THEN 1 ELSE 0 END) AS has_post_derog_recovery_evidence
    FROM most_recent_derog_in_window d
    JOIN module1.metro2_status_history h
      ON d.account = h.account
     AND h.byte_date > d.most_recent_derog_date
    GROUP BY d.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: final_eval
-- Purpose:
--   Apply the final Layer 1 decision hierarchy.
--
-- Final hierarchy:
--   1) Unresolved derog in credit impact window:
--         - remediation_treatment = TRADELINE_DELETION
--         - manual_review_flag = 0
--      where unresolved derog means:
--         - derog exists, and
--         - there is no post-derog recovery evidence
--
--   2) No delinquency and no derog in credit impact window:
--         - remediation_treatment = NO_IMPACT_CLEAN_PHP_HISTORY
--         - manual_review_flag = 0
--
--   3) Else use the pre-evaluated manual review result and assign cleanup treatment:
--         - FULL_DEROGATORY_PHP_CLEANUP if derog exists
--         - SIMPLE_DELINQUENCY_PHP_CLEANUP if only delinquency exists
-- --------------------------------------------------------------------------------------------
final_eval AS (
    SELECT
        p.account,
        p.profile_type,
        p.latest_doai,
        p.date_closed,
        p.full_php,
        p.php_left_byte_date,
        p.php_right_byte_date,
        p.account_status_17A,
        p.payment_rating_17B,
        p.date_of_first_delinquency,
        p.impact_start_date,
        p.impact_end_date,
        p.credit_impact_start_date,
        p.credit_impact_end_date_pre AS credit_impact_end_date,
        p.credit_cure_date,
        p.cure_consecutive_months_required,
        p.post_impact_month_count,

        COALESCE(f.has_derog_in_credit_window, 0) AS has_derog_in_credit_window,
        COALESCE(f.has_delinquency_in_credit_window, 0) AS has_delinquency_in_credit_window,
        COALESCE(r.has_post_derog_recovery_evidence, 0) AS has_post_derog_recovery_evidence,

        CASE
            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 1
             AND COALESCE(r.has_post_derog_recovery_evidence, 0) = 0
            THEN 0

            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 0
             AND COALESCE(f.has_delinquency_in_credit_window, 0) = 0
            THEN 0

            ELSE p.manual_review_flag_pre
        END AS manual_review_flag,

        CASE
            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 1
             AND COALESCE(r.has_post_derog_recovery_evidence, 0) = 0
            THEN NULL

            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 0
             AND COALESCE(f.has_delinquency_in_credit_window, 0) = 0
            THEN NULL

            ELSE p.manual_review_reason_pre
        END AS manual_review_reason,

        CASE
            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 1
             AND COALESCE(r.has_post_derog_recovery_evidence, 0) = 0
            THEN 'TRADELINE_DELETION'

            WHEN COALESCE(f.has_derog_in_credit_window, 0) = 1
            THEN 'FULL_DEROGATORY_PHP_CLEANUP'

            WHEN COALESCE(f.has_delinquency_in_credit_window, 0) = 1
            THEN 'SIMPLE_DELINQUENCY_PHP_CLEANUP'

            ELSE 'NO_IMPACT_CLEAN_PHP_HISTORY'
        END AS remediation_treatment
    FROM preliminary_eval p
    LEFT JOIN credit_window_flags f
      ON p.account = f.account
    LEFT JOIN post_derog_recovery_flags r
      ON p.account = r.account
)

SELECT
    account,
    profile_type,
    latest_doai,
    date_closed,
    full_php,
    php_left_byte_date,
    php_right_byte_date,
    account_status_17A,
    payment_rating_17B,
    date_of_first_delinquency,
    impact_start_date,
    impact_end_date,
    credit_impact_start_date,
    credit_impact_end_date,
    credit_cure_date,
    cure_consecutive_months_required,
    post_impact_month_count,
    has_derog_in_credit_window,
    has_delinquency_in_credit_window,
    has_post_derog_recovery_evidence,
    manual_review_flag,
    manual_review_reason,
    remediation_treatment
FROM final_eval
ORDER BY account;

CREATE INDEX ix_remediation_window_eval_account
    ON metro2_remediation_window_eval (account);


-- ====================================================================================================
-- SECTION 7: BUILD MONTH-LEVEL REMEDIATION DETAIL
-- ====================================================================================================
-- Purpose:
--   Create one row per account per represented month showing:
--   - original status
--   - whether the month is inside the credit impact window
--   - remediated status after treatment logic is applied
--
-- Why this exists:
--   This table is the easiest place to:
--   - inspect exactly which months changed
--   - stitch remediated_full_php later
--   - support future audit and QA work
--
-- SQL mechanics:
--   - Join the Layer 1 result to module1.metro2_status_history
--   - Apply cleanup logic only inside the credit impact timeframe
-- ====================================================================================================
CREATE TABLE metro2_remediation_php_detail AS
SELECT
    e.account,
    h.byte_date,
    h.perf_age,
    h.status AS original_status,

    CASE
        WHEN h.byte_date BETWEEN e.credit_impact_start_date AND e.credit_impact_end_date THEN 1
        ELSE 0
    END AS is_within_credit_impact_window,

    e.remediation_treatment,

    CASE
        WHEN e.remediation_treatment = 'FULL_DEROGATORY_PHP_CLEANUP'
         AND h.byte_date BETWEEN e.credit_impact_start_date AND e.credit_impact_end_date
         AND h.status IN ('1','2','3','4','5','6','G','H','J','K','L')
        THEN 'D'

        WHEN e.remediation_treatment = 'SIMPLE_DELINQUENCY_PHP_CLEANUP'
         AND h.byte_date BETWEEN e.credit_impact_start_date AND e.credit_impact_end_date
         AND h.status IN ('1','2','3','4','5','6')
        THEN 'D'

        ELSE h.status
    END AS remediated_status
FROM metro2_remediation_window_eval e
JOIN module1.metro2_status_history h
  ON e.account = h.account
ORDER BY e.account, h.byte_date DESC;

CREATE INDEX ix_remediation_php_detail_account_byte_date
    ON metro2_remediation_php_detail (account, byte_date DESC);


-- ====================================================================================================
-- SECTION 8: BUILD FINAL REMEDIATION OUTPUT
-- ====================================================================================================
-- Purpose:
--   Produce the final Module 2 output table with:
--   - original context
--   - impact dates
--   - remediation treatment
--   - remediated delta fields
--   - audit flags
--
-- This section also derives:
--   - remediated_account_status_17A
--   - remediated_payment_rating_17B
--   - remediated_date_of_first_delinquency
--
-- Important design rule:
--   Remediated fields are delta-based.
--   If no change is made to a remediated field, that remediated field remains NULL.
-- ====================================================================================================
CREATE TABLE metro2_remediation_final AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: remediated_php_all
-- Purpose:
--   Stitch the month-level remediated statuses into one full remediated PHP candidate.
--
-- Why this exists:
--   This gives us the candidate remediated PHP before applying delta-based nulling rules.
-- --------------------------------------------------------------------------------------------
remediated_php_all AS (
    SELECT
        account,
        STRING_AGG(remediated_status, '' ORDER BY byte_date DESC) AS remediated_full_php_candidate
    FROM metro2_remediation_php_detail
    GROUP BY account
),

-- --------------------------------------------------------------------------------------------
-- CTE: normalized_remediated_history
-- Purpose:
--   Normalize remediated history for derivation purposes only.
--
-- Rule:
--   D behaves like 0 for remediated status / payment rating / DOFD derivations.
-- --------------------------------------------------------------------------------------------
normalized_remediated_history AS (
    SELECT
        d.account,
        d.byte_date,
        CASE
            WHEN d.remediated_status = 'D' THEN '0'
            ELSE d.remediated_status
        END AS normalized_status
    FROM metro2_remediation_php_detail d
),

-- --------------------------------------------------------------------------------------------
-- CTE: latest_normalized_status
-- Purpose:
--   Find the most recent normalized remediated byte per account.
--
-- SQL mechanics:
--   - DISTINCT ON keeps the first row per account
--   - ORDER BY byte_date DESC makes that first row the newest byte
-- --------------------------------------------------------------------------------------------
latest_normalized_status AS (
    SELECT DISTINCT ON (account)
        account,
        normalized_status AS latest_normalized_byte
    FROM normalized_remediated_history
    ORDER BY account, byte_date DESC
),

-- --------------------------------------------------------------------------------------------
-- CTE: corresponding_derog_basis
-- Purpose:
--   Map original 61-65 statuses to the derogatory basis they imply.
--
-- Why this exists:
--   If the remediated history removes that derogatory basis, the remediated status should
--   become 13 rather than stay in a closed paid-post-derog bucket.
-- --------------------------------------------------------------------------------------------
corresponding_derog_basis AS (
    SELECT
        e.account,
        e.account_status_17A AS original_account_status_17A,
        CASE e.account_status_17A
            WHEN '61' THEN 'J'
            WHEN '62' THEN 'G'
            WHEN '63' THEN 'K'
            WHEN '64' THEN 'L'
            WHEN '65' THEN 'H'
            ELSE NULL
        END AS required_derog_basis
    FROM metro2_remediation_window_eval e
),

-- --------------------------------------------------------------------------------------------
-- CTE: derog_basis_remaining
-- Purpose:
--   Check whether the corresponding derog basis still exists anywhere in the normalized
--   remediated history.
-- --------------------------------------------------------------------------------------------
derog_basis_remaining AS (
    SELECT
        c.account,
        MAX(
            CASE
                WHEN c.required_derog_basis IS NOT NULL
                 AND n.normalized_status = c.required_derog_basis
                THEN 1 ELSE 0
            END
        ) AS basis_still_exists
    FROM corresponding_derog_basis c
    JOIN normalized_remediated_history n
      ON c.account = n.account
    GROUP BY c.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: remediated_status_candidates
-- Purpose:
--   Derive the candidate remediated 17A value BEFORE delta-based nulling.
--
-- Rules:
--   1) TRADELINE_DELETION -> DA
--   2) If no PHP cleanup treatment was applied -> NULL candidate
--   3) Original 13 remains 13 if PHP changed
--   4) Original 61-65 become 13 if the derog basis is removed
--   5) Otherwise derive from the normalized latest remediated byte
-- --------------------------------------------------------------------------------------------
remediated_status_candidates AS (
    SELECT
        e.account,
        CASE
            WHEN e.remediation_treatment = 'TRADELINE_DELETION'
                THEN 'DA'

            WHEN e.remediation_treatment NOT IN ('FULL_DEROGATORY_PHP_CLEANUP', 'SIMPLE_DELINQUENCY_PHP_CLEANUP')
                THEN NULL

            WHEN e.account_status_17A = '13'
                THEN '13'

            WHEN e.account_status_17A IN ('61','62','63','64','65')
             AND COALESCE(d.basis_still_exists, 0) = 0
                THEN '13'

            WHEN e.account_status_17A IN ('61','62','63','64','65')
             AND COALESCE(d.basis_still_exists, 0) = 1
                THEN e.account_status_17A

            ELSE
                CASE l.latest_normalized_byte
                    WHEN '0' THEN '11'
                    WHEN '1' THEN '71'
                    WHEN '2' THEN '78'
                    WHEN '3' THEN '80'
                    WHEN '4' THEN '82'
                    WHEN '5' THEN '83'
                    WHEN '6' THEN '84'
                    WHEN 'G' THEN '93'
                    WHEN 'H' THEN '94'
                    WHEN 'J' THEN '95'
                    WHEN 'K' THEN '96'
                    WHEN 'L' THEN '97'
                    ELSE NULL
                END
        END AS remediated_account_status_17A_candidate
    FROM metro2_remediation_window_eval e
    LEFT JOIN latest_normalized_status l
      ON e.account = l.account
    LEFT JOIN derog_basis_remaining d
      ON e.account = d.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: remediated_rating_candidates
-- Purpose:
--   Derive the candidate remediated 17B value BEFORE delta-based nulling.
--
-- Rules:
--   1) TRADELINE_DELETION -> NULL
--   2) No PHP cleanup treatment -> NULL
--   3) Remediated 13 -> 0
--   4) Remediated 61-65 -> NULL
--   5) Otherwise derive from normalized latest remediated byte
-- --------------------------------------------------------------------------------------------
remediated_rating_candidates AS (
    SELECT
        e.account,
        CASE
            WHEN e.remediation_treatment = 'TRADELINE_DELETION'
                THEN NULL

            WHEN e.remediation_treatment NOT IN ('FULL_DEROGATORY_PHP_CLEANUP', 'SIMPLE_DELINQUENCY_PHP_CLEANUP')
                THEN NULL

            WHEN s.remediated_account_status_17A_candidate = '13'
                THEN '0'

            WHEN s.remediated_account_status_17A_candidate IN ('61','62','63','64','65')
                THEN NULL

            ELSE
                CASE l.latest_normalized_byte
                    WHEN '0' THEN '0'
                    WHEN '1' THEN '1'
                    WHEN '2' THEN '2'
                    WHEN '3' THEN '3'
                    WHEN '4' THEN '4'
                    WHEN '5' THEN '5'
                    WHEN '6' THEN '6'
                    WHEN 'G' THEN 'G'
                    WHEN 'L' THEN 'L'
                    ELSE NULL
                END
        END AS remediated_payment_rating_17B_candidate
    FROM metro2_remediation_window_eval e
    LEFT JOIN remediated_status_candidates s
      ON e.account = s.account
    LEFT JOIN latest_normalized_status l
      ON e.account = l.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: ordered_normalized_history
-- Purpose:
--   Sequence the normalized remediated history from most recent to oldest while tracking whether
--   a non-adverse break has appeared.
--
-- Why this exists:
--   Remediated DOFD should only exist when there is still a current active adverse run.
--
-- SQL mechanics:
--   - A windowed SUM counts how many non-adverse months have appeared so far
--   - While non_adverse_seen = 0, we are still inside the initial adverse run
-- --------------------------------------------------------------------------------------------
ordered_normalized_history AS (
    SELECT
        n.account,
        n.byte_date,
        n.normalized_status,
        SUM(
            CASE
                WHEN n.normalized_status NOT IN ('1','2','3','4','5','6','G','H','J','K','L')
                THEN 1 ELSE 0
            END
        ) OVER (
            PARTITION BY n.account
            ORDER BY n.byte_date DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS non_adverse_seen
    FROM normalized_remediated_history n
),

-- --------------------------------------------------------------------------------------------
-- CTE: remediated_dofd_candidates
-- Purpose:
--   Derive the candidate remediated DOFD BEFORE delta-based nulling.
--
-- Rules:
--   1) TRADELINE_DELETION -> NULL
--   2) No PHP cleanup treatment -> NULL
--   3) Closed remediated statuses (13,61-65) -> NULL
--   4) Otherwise:
--       - inspect only the current contiguous adverse run
--       - inside that run, find the oldest 1-6 byte
--       - if none exists, DOFD = NULL
-- --------------------------------------------------------------------------------------------
remediated_dofd_candidates AS (
    SELECT
        e.account,
        CASE
            WHEN e.remediation_treatment = 'TRADELINE_DELETION'
                THEN NULL

            WHEN e.remediation_treatment NOT IN ('FULL_DEROGATORY_PHP_CLEANUP', 'SIMPLE_DELINQUENCY_PHP_CLEANUP')
                THEN NULL

            WHEN s.remediated_account_status_17A_candidate IN ('13','61','62','63','64','65')
                THEN NULL

            ELSE MIN(o.byte_date) FILTER (WHERE o.normalized_status IN ('1','2','3','4','5','6'))
        END AS remediated_date_of_first_delinquency_candidate
    FROM metro2_remediation_window_eval e
    LEFT JOIN remediated_status_candidates s
      ON e.account = s.account
    LEFT JOIN ordered_normalized_history o
      ON e.account = o.account
     AND o.non_adverse_seen = 0
    GROUP BY
        e.account,
        e.remediation_treatment,
        s.remediated_account_status_17A_candidate
),

-- --------------------------------------------------------------------------------------------
-- CTE: combined_candidates
-- Purpose:
--   Gather all candidate remediated values into one place before delta-based nulling.
-- --------------------------------------------------------------------------------------------
combined_candidates AS (
    SELECT
        e.account,
        e.profile_type,
        e.latest_doai,
        e.date_closed,
        e.full_php,
        e.php_left_byte_date,
        e.php_right_byte_date,
        e.account_status_17A,
        e.payment_rating_17B,
        e.date_of_first_delinquency,
        e.impact_start_date,
        e.impact_end_date,
        e.credit_impact_start_date,
        e.credit_impact_end_date,
        e.credit_cure_date,
        e.cure_consecutive_months_required,
        e.manual_review_flag,
        e.manual_review_reason,
        e.remediation_treatment,

        p.remediated_full_php_candidate,
        s.remediated_account_status_17A_candidate,
        r.remediated_payment_rating_17B_candidate,
        d.remediated_date_of_first_delinquency_candidate

    FROM metro2_remediation_window_eval e
    LEFT JOIN remediated_php_all p
      ON e.account = p.account
    LEFT JOIN remediated_status_candidates s
      ON e.account = s.account
    LEFT JOIN remediated_rating_candidates r
      ON e.account = r.account
    LEFT JOIN remediated_dofd_candidates d
      ON e.account = d.account
),

-- --------------------------------------------------------------------------------------------
-- CTE: delta_fields
-- Purpose:
--   Apply the agreed delta-based rule:
--   only populate remediated fields when they actually differ from the original fields.
--
-- Why this exists:
--   This makes the output easier to audit because NULL means "no change written".
-- --------------------------------------------------------------------------------------------
delta_fields AS (
    SELECT
        c.*,

        CASE
            WHEN c.remediation_treatment IN ('FULL_DEROGATORY_PHP_CLEANUP', 'SIMPLE_DELINQUENCY_PHP_CLEANUP')
             AND c.remediated_full_php_candidate IS DISTINCT FROM c.full_php
            THEN c.remediated_full_php_candidate
            ELSE NULL
        END AS remediated_full_php,

        CASE
            WHEN c.remediated_account_status_17A_candidate IS DISTINCT FROM c.account_status_17A
            THEN c.remediated_account_status_17A_candidate
            ELSE NULL
        END AS remediated_account_status_17A,

        CASE
            WHEN c.remediated_payment_rating_17B_candidate IS DISTINCT FROM c.payment_rating_17B
            THEN c.remediated_payment_rating_17B_candidate
            ELSE NULL
        END AS remediated_payment_rating_17B,

        CASE
            WHEN c.remediated_date_of_first_delinquency_candidate IS DISTINCT FROM c.date_of_first_delinquency
            THEN c.remediated_date_of_first_delinquency_candidate
            ELSE NULL
        END AS remediated_date_of_first_delinquency

    FROM combined_candidates c
),

-- --------------------------------------------------------------------------------------------
-- CTE: final_flags
-- Purpose:
--   Derive:
--      - remediation_applied_flag
--      - remediation_fields_modified
--
-- Rule set:
--   based on the actual remediated_* columns and whether they are populated
--
-- Grouping:
--   PHP = remediated_full_php
--   STATUS = remediated_account_status_17A
--   DERIVED_FIELDS = remediated_payment_rating_17B OR remediated_date_of_first_delinquency
-- --------------------------------------------------------------------------------------------
final_flags AS (
    SELECT
        d.*,

        CASE
            WHEN d.remediated_full_php IS NOT NULL
              OR d.remediated_account_status_17A IS NOT NULL
              OR d.remediated_payment_rating_17B IS NOT NULL
              OR d.remediated_date_of_first_delinquency IS NOT NULL
            THEN 1
            ELSE 0
        END AS remediation_applied_flag,

        CASE
            WHEN d.remediated_full_php IS NULL
             AND d.remediated_account_status_17A IS NULL
             AND d.remediated_payment_rating_17B IS NULL
             AND d.remediated_date_of_first_delinquency IS NULL
            THEN 'NONE'

            WHEN d.remediated_full_php IS NOT NULL
             AND d.remediated_account_status_17A IS NULL
             AND d.remediated_payment_rating_17B IS NULL
             AND d.remediated_date_of_first_delinquency IS NULL
            THEN 'PHP_ONLY'

            WHEN d.remediated_full_php IS NULL
             AND d.remediated_account_status_17A IS NOT NULL
             AND d.remediated_payment_rating_17B IS NULL
             AND d.remediated_date_of_first_delinquency IS NULL
            THEN 'STATUS_ONLY'

            WHEN d.remediated_full_php IS NOT NULL
             AND d.remediated_account_status_17A IS NOT NULL
             AND d.remediated_payment_rating_17B IS NULL
             AND d.remediated_date_of_first_delinquency IS NULL
            THEN 'PHP_AND_STATUS'

            WHEN d.remediated_full_php IS NOT NULL
             AND d.remediated_account_status_17A IS NULL
             AND (
                    d.remediated_payment_rating_17B IS NOT NULL
                 OR d.remediated_date_of_first_delinquency IS NOT NULL
                 )
            THEN 'PHP_AND_DERIVED_FIELDS'

            WHEN d.remediated_full_php IS NULL
             AND d.remediated_account_status_17A IS NOT NULL
             AND (
                    d.remediated_payment_rating_17B IS NOT NULL
                 OR d.remediated_date_of_first_delinquency IS NOT NULL
                 )
            THEN 'STATUS_AND_DERIVED_FIELDS'

            ELSE 'PHP_STATUS_AND_DERIVED_FIELDS'
        END AS remediation_fields_modified

    FROM delta_fields d
)

SELECT
    account,
    profile_type,
    latest_doai,
    date_closed,
    full_php,
    php_left_byte_date,
    php_right_byte_date,
    account_status_17A,
    payment_rating_17B,
    date_of_first_delinquency,

    impact_start_date,
    impact_end_date,

    credit_impact_start_date,
    credit_impact_end_date,
    credit_cure_date,
    cure_consecutive_months_required,

    manual_review_flag,
    manual_review_reason,
    remediation_treatment,

    remediated_full_php,
    remediated_account_status_17A,
    remediated_payment_rating_17B,
    remediated_date_of_first_delinquency,

    remediation_applied_flag,
    remediation_fields_modified

FROM final_flags
ORDER BY account;

CREATE INDEX ix_remediation_final_account
    ON metro2_remediation_final (account);


-- ====================================================================================================
-- SECTION 9: QA / REVIEW QUERIES
-- ====================================================================================================
-- Purpose:
--   Provide inspection queries for learning, validation, screenshots, and walkthroughs.
--
-- Why this exists:
--   These queries help a reviewer understand:
--   - what inputs were simulated
--   - how Layer 1 behaved
--   - which treatments were assigned
--   - what remediated fields changed
--   - whether post-derog recovery evidence is preventing false deletions
-- ====================================================================================================

-- --------------------------------------------------------------------------------------------
-- QA 1: Echo the Module 2 parameter row
-- --------------------------------------------------------------------------------------------
SELECT * FROM module2_params;

-- --------------------------------------------------------------------------------------------
-- QA 2: Sample remediation input rows
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_input
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 3: Review Layer 1 evaluation outputs
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    impact_start_date,
    impact_end_date,
    credit_impact_start_date,
    credit_impact_end_date,
    credit_cure_date,
    post_impact_month_count,
    has_derog_in_credit_window,
    has_delinquency_in_credit_window,
    has_post_derog_recovery_evidence,
    manual_review_flag,
    manual_review_reason,
    remediation_treatment
FROM metro2_remediation_window_eval
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 4: Count accounts by remediation treatment
-- --------------------------------------------------------------------------------------------
SELECT
    remediation_treatment,
    COUNT(*) AS account_count
FROM metro2_remediation_window_eval
GROUP BY remediation_treatment
ORDER BY remediation_treatment;

-- --------------------------------------------------------------------------------------------
-- QA 5: Count manual review cases by reason
-- --------------------------------------------------------------------------------------------
SELECT
    COALESCE(manual_review_reason, 'NO_MANUAL_REVIEW') AS manual_review_reason,
    COUNT(*) AS account_count
FROM metro2_remediation_final
GROUP BY COALESCE(manual_review_reason, 'NO_MANUAL_REVIEW')
ORDER BY manual_review_reason;

-- --------------------------------------------------------------------------------------------
-- QA 6: Sample month-level remediation detail
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_php_detail
ORDER BY account, byte_date DESC
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 7: Sample final remediation output
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_final
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 8: Tradeline deletion examples
-- Why:
--   Should now exclude reversed-major-derog accounts that show post-derog recovery evidence
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_final
WHERE remediation_treatment = 'TRADELINE_DELETION'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 9: Full derogatory cleanup examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_final
WHERE remediation_treatment = 'FULL_DEROGATORY_PHP_CLEANUP'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 10: Simple delinquency cleanup examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_final
WHERE remediation_treatment = 'SIMPLE_DELINQUENCY_PHP_CLEANUP'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 11: No-impact examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_remediation_final
WHERE remediation_treatment = 'NO_IMPACT_CLEAN_PHP_HISTORY'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 12: Review remediation_fields_modified distribution
-- --------------------------------------------------------------------------------------------
SELECT
    remediation_fields_modified,
    COUNT(*) AS account_count
FROM metro2_remediation_final
GROUP BY remediation_fields_modified
ORDER BY remediation_fields_modified;

-- --------------------------------------------------------------------------------------------
-- QA 13: Accounts where remediated status changed
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    account_status_17A,
    remediated_account_status_17A,
    remediation_treatment,
    remediation_fields_modified
FROM metro2_remediation_final
WHERE remediated_account_status_17A IS NOT NULL
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 14: Accounts where remediated PHP changed
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    full_php,
    remediated_full_php,
    remediation_treatment,
    remediation_fields_modified
FROM metro2_remediation_final
WHERE remediated_full_php IS NOT NULL
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 15: Accounts where remediated DOFD changed
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    date_of_first_delinquency,
    remediated_date_of_first_delinquency,
    remediation_treatment,
    remediation_fields_modified
FROM metro2_remediation_final
WHERE remediated_date_of_first_delinquency IS NOT NULL
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 16: Accounts with derog in the credit window that also show post-derog recovery evidence
-- Why:
--   These are the critical edge cases that Version 2 is designed to protect from false deletions
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    full_php,
    impact_start_date,
    impact_end_date,
    credit_impact_start_date,
    credit_impact_end_date,
    has_derog_in_credit_window,
    has_post_derog_recovery_evidence,
    remediation_treatment
FROM metro2_remediation_window_eval
WHERE has_derog_in_credit_window = 1
  AND has_post_derog_recovery_evidence = 1
ORDER BY account
LIMIT 100;
