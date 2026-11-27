/* ====================================================================================================
PROGRAM:  Metro 2 Remediation Simulator — Version 4 (reversal-aware severe-event policy)
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
- Version 2 required both:
    - a derogatory event in the credit impact window, AND
    - no later recovery evidence after the most recent derog month

Version 3 — CHARGEOFF_REQUIRES_CURE_V1 (superseded private study):
- Any original charge-off (L) in the inclusive credit impact window requires
  tradeline deletion if the account has no established credit_cure_date.
- This takes precedence over a later numeric payment mark and over other
  major derogatory codes in the same window.
- Other treatments retain the published Version 2 rules at Git revision 1201adc.
- Verify monthly evidence before replacing the previous run. The complete rebuild
  is one transaction and all output tables are addressed in the module2 schema.
- Explicit clear flags distinguish a computed change to NULL from an unchanged field.

Version 4 — REVERSAL_AWARE_SEVERE_V2 (current sandbox policy):
- Use the most recent original in-window G/H/J/K/L and the first later original
  numeric mark (0–6) to decide between deletion and targeted cleanup.
- Persist both evidence months. Cure remains a separate test of original consecutive
  current months after bank impact ends. Events after confirmed cure do not reopen it.
- Opt into a same-incident rerun to retain validated bank dates across reporting cycles.

Field decision revision — EVIDENCE_SCOPED_FIELDS_V2:
- Keep independent as-of status, internal rating and onset across older cleanup. Require
  an actually removed basis for the favorable election. Refer uncertain fields to servicing.
- Enforce the reporting clock, supported monthly alphabet and oldest-only B padding.
- Check a populated onset against original performance through the proposed field basis.
  Retain disputed fields and refer contradictory closure evidence or missing required ratings.
- On incident reuse, compare all saved bank dates and the prior reporting cutoffs before replacing outputs.

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
   For the next cycle of an existing incident, update the original history and summary
   for the same accounts. On this connection, SET metro2.reuse_incident_dates = 'on';
   then execute this module and RESET metro2.reuse_incident_dates after the rerun.
   Reuse the configured SQL from this study: both saved decision tables must match its cure
   threshold, and all three incident copies must agree. Same-cutoff corrections and later snapshots
   are accepted. To compare another threshold, create a separate fresh study.

3) PARAMETER TO EDIT
   Most users should only edit the INSERT INTO pg_temp.module2_params statement.

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

   Find the latest original G/H/J/K/L inside the inclusive credit-impact window.
   Look for the first original 0–6 strictly after it. This synthetic observation
   supports reversal even if the account is still delinquent and cure is unconfirmed.
   Without reversal, propose whole-tradeline deletion (DA). With reversal, retain
   the tradeline and target its eligible in-window months. A new severe event in
   that same window requires fresh reversal evidence; B and D supply none.

   The cure test uses only consecutive original zeros strictly after bank impact.
   Once confirmed, the window closes just before the first qualifying zero. Isolated
   later events belong to separate assessment. An operational reversal should be
   substantiated by the relevant account and event records.

   Deletion is an account-level instruction. The original monthly evidence remains
   visible and the final manual-review flag is zero.

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
   PHP byte 1 covers the month before DOAI. Field 17A is current as of DOAI. For the
   synthetic election, an adverse-to-D correction to the newest month must be corroborated
   by its as-of status and field evidence. Otherwise preserve the current fields. For a
   closed account, check the specific paid-derogatory or pre-closure rating basis. Source
   D supplies no new onset. Cure still requires consecutive original post-issue zeros.
   Consumer Information Indicators (CII) and the associated Field 25 exceptions are
   outside these inputs. Internal SQL dates and clear flags describe study actions.

10) DELTA-BASED OUTPUT DESIGN
   Remediated fields are only populated when a change is actually made.

   That means:
   - if remediated_full_php is unchanged, it stays NULL
   - if remediated_account_status_17A is unchanged, it stays NULL
   - a populated remediated field supplies its replacement value
   - clear_account_status_17a, clear_payment_rating_17b and clear_date_of_first_delinquency
     separately identify a cleanup instruction to set an existing field to NULL
   - otherwise keep the original value. A deletion supplies DA only.

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
   - Leftmost byte = the month before DOAI. 17A is the separate account status as of DOAI.
   - Rightmost byte = oldest represented month

B) PHP BYTES USED HERE
   B = no reported history
   D = no payment history information available; this sandbox can also propose D during targeted cleanup.
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

D) INTERNAL MODELED PAYMENT RATING
   Source ratings are retained unless an evidenced favorable election applies.
   The standard 17B field has its own status-dependent applicability. In the
   historical character layout 71 and 11 both leave standard 17B blank.
   An internal 1 to 0 election is a study value, not an instruction to populate 17B.

======================================================================================================
IMPORTANT LIMITATIONS
======================================================================================================
1) This is a synthetic remediation-learning module, not a production furnishing engine.
2) Remediated fields are delta-based:
      - only populate when a change is being written to that remediated field
      - otherwise remain NULL
3) Apply the clear flag before falling back to the original 17A, 17B or DOFD.
   A field with a NULL delta and a false clear flag keeps its original value.
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
BEGIN ISOLATION LEVEL REPEATABLE READ;
CREATE SCHEMA IF NOT EXISTS module2;
SET search_path TO module2, module1, public;


-- ====================================================================================================
-- SECTION 1: RESET THE SESSION PARAMETER TABLE
-- ====================================================================================================
-- Qualify the temporary schema so a same-named permanent table is never dropped.
DROP TABLE IF EXISTS pg_temp.module2_params;


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
CREATE TEMP TABLE pg_temp.module2_params (
    cure_consecutive_months_required INTEGER NOT NULL
);

INSERT INTO pg_temp.module2_params (
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
    SELECT cure_consecutive_months_required INTO STRICT v_cure_months
    FROM pg_temp.module2_params;

    IF v_cure_months IS NULL OR v_cure_months < 1 THEN
        RAISE EXCEPTION
            'MODULE 2 PARAMETER VALIDATION FAILED: cure_consecutive_months_required must be an integer >= 1. Current value = %',
            v_cure_months;
    END IF;
END $$;


-- ====================================================================================================
-- Check the source grain before resetting outputs. Cure is measured in calendar months.
-- An omitted or duplicated month would break the relationship between byte position and date.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM module1.metro2_final)
       OR EXISTS (
           SELECT 1 FROM module1.metro2_final
           GROUP BY account HAVING account IS NULL OR count(*) <> 1
       ) THEN
        RAISE EXCEPTION 'MODULE 2 INPUT VALIDATION FAILED: expected one original summary per account and a nonempty population.';
    END IF;

    IF EXISTS (
        WITH monthly AS (
            SELECT account, min(byte_date) AS first_month, max(byte_date) AS last_month,
                   count(*) AS months, count(DISTINCT byte_date) AS unique_dates,
                   bool_or(byte_date IS NULL OR extract(day FROM byte_date) <> 1
                       OR status IS NULL OR status NOT IN ('0','1','2','3','4','5','6','B','D','G','H','J','K','L')) AS invalid_month,
                   string_agg(status, '' ORDER BY byte_date DESC) AS full_php
            FROM module1.metro2_status_history
            GROUP BY account
        )
        SELECT 1
        FROM module1.metro2_final f
        FULL JOIN monthly m USING (account)
        WHERE f.account IS NULL OR m.account IS NULL OR m.invalid_month
           OR f.php_right_byte_date IS DISTINCT FROM m.first_month
           OR f.php_left_byte_date IS DISTINCT FROM m.last_month
           -- This simulator reports on the first of the following month. Future PHP
           -- cannot close the present review. B can only pad the oldest end of history.
           OR f.latest_doai IS DISTINCT FROM (m.last_month + interval '1 month')::date
           OR m.full_php !~ '^[0-6DGHJKL]*B*$'
           OR f.full_php IS DISTINCT FROM m.full_php
           OR m.months <> m.unique_dates
           OR m.months <> (12 * (extract(year FROM m.last_month) - extract(year FROM m.first_month))
                            + extract(month FROM m.last_month) - extract(month FROM m.first_month) + 1)
    ) THEN
        RAISE EXCEPTION 'MODULE 2 INPUT VALIDATION FAILED: monthly source and summary must agree on account, monthly grain, inclusive endpoints and newest-first PHP. DOAI must be the next month-start; supported marks are 0-6/D/G/H/J/K/L and B only before all reported history.';
    END IF;
END $$;

-- A continuing investigation keeps its bank dates even when the represented history grows.
-- Hold them in this transaction before replacing outputs. A bad or incomplete prior cohort
-- fails the whole refresh; a new study keeps the default deterministic generator.
CREATE TEMP TABLE pg_temp.module2_saved_incident_dates ON COMMIT DROP AS
SELECT account, NULL::date AS impact_start_date, NULL::date AS impact_end_date
FROM module1.metro2_final WITH NO DATA;

DO $$
BEGIN
    IF coalesce(nullif(current_setting('metro2.reuse_incident_dates', true), ''), 'off')::boolean THEN
        IF to_regclass('module2.metro2_remediation_input') IS NULL
           OR to_regclass('module2.metro2_remediation_window_eval') IS NULL
           OR to_regclass('module2.metro2_remediation_final') IS NULL THEN
            RAISE EXCEPTION 'MODULE 2 INCIDENT REUSE FAILED: prior input, window and final tables are required.';
        END IF;
        LOCK TABLE module2.metro2_remediation_input, module2.metro2_remediation_window_eval,
                   module2.metro2_remediation_final IN SHARE ROW EXCLUSIVE MODE;
        INSERT INTO pg_temp.module2_saved_incident_dates
        SELECT account, impact_start_date, impact_end_date FROM module2.metro2_remediation_input;

        IF EXISTS (
            SELECT 1 FROM pg_temp.module2_saved_incident_dates
            GROUP BY account HAVING account IS NULL OR count(*) <> 1
        ) OR EXISTS (
            SELECT 1 FROM module1.metro2_final f
            FULL JOIN pg_temp.module2_saved_incident_dates i USING (account)
            WHERE i.account IS NULL OR f.account IS NULL
               OR i.impact_start_date IS NULL OR i.impact_end_date IS NULL
               OR extract(day FROM i.impact_start_date) <> 1 OR extract(day FROM i.impact_end_date) <> 1
               OR i.impact_start_date > i.impact_end_date
               OR i.impact_start_date < f.php_right_byte_date OR i.impact_end_date > f.php_left_byte_date
        ) THEN
            RAISE EXCEPTION 'MODULE 2 INCIDENT REUSE FAILED: expected the same accounts and one valid, represented month-start bank date pair per account.';
        END IF;

        -- The cure threshold is part of a continued incident's decision basis. Changing
        -- the rule alone could close the review without a new observation. Compare every
        -- saved account, including NULLs, against the validated incoming parameter.
        IF (SELECT count(*) FROM pg_attribute
            WHERE attrelid IN ('module2.metro2_remediation_window_eval'::regclass,
                               'module2.metro2_remediation_final'::regclass)
              AND attname = 'cure_consecutive_months_required' AND NOT attisdropped) <> 2 THEN
            RAISE EXCEPTION 'MODULE 2 INCIDENT REUSE FAILED: the prior window and final tables must record the cure threshold.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM module2.metro2_remediation_window_eval w
            CROSS JOIN pg_temp.module2_params p
            WHERE w.cure_consecutive_months_required IS DISTINCT FROM p.cure_consecutive_months_required
        ) OR EXISTS (
            SELECT 1 FROM module2.metro2_remediation_final f
            CROSS JOIN pg_temp.module2_params p
            WHERE f.cure_consecutive_months_required IS DISTINCT FROM p.cure_consecutive_months_required
        ) THEN
            RAISE EXCEPTION 'MODULE 2 INCIDENT REUSE FAILED: the configured cure threshold must match both saved thresholds for every account. Use the original configured Module 2 for follow-up or create a separate study.';
        END IF;

        -- A date can be in range yet differ from the incident already assessed. Require
        -- the two previous decisions to corroborate the saved pair and reporting cutoff.
        -- Source fields/history can be corrected at the same DOAI; compare chronology only.
        IF EXISTS (SELECT 1 FROM module2.metro2_remediation_window_eval
                   GROUP BY account HAVING account IS NULL OR count(*) <> 1)
           OR EXISTS (SELECT 1 FROM module2.metro2_remediation_final
                      GROUP BY account HAVING account IS NULL OR count(*) <> 1)
           OR EXISTS (
               SELECT 1 FROM pg_temp.module2_saved_incident_dates i
               FULL JOIN module2.metro2_remediation_window_eval w USING (account)
               FULL JOIN module2.metro2_remediation_final f USING (account)
               LEFT JOIN module1.metro2_final n USING (account)
               WHERE i.account IS NULL OR w.account IS NULL OR f.account IS NULL
                  OR (w.impact_start_date,w.impact_end_date) IS DISTINCT FROM (i.impact_start_date,i.impact_end_date)
                  OR (f.impact_start_date,f.impact_end_date) IS DISTINCT FROM (i.impact_start_date,i.impact_end_date)
                  OR w.latest_doai IS NULL OR w.php_left_byte_date IS NULL
                  OR extract(day FROM w.php_left_byte_date) <> 1
                  OR w.latest_doai IS DISTINCT FROM (w.php_left_byte_date + interval '1 month')::date
                  OR (f.latest_doai,f.php_left_byte_date) IS DISTINCT FROM (w.latest_doai,w.php_left_byte_date)
                  OR n.latest_doai < f.latest_doai
           ) THEN
            RAISE EXCEPTION 'MODULE 2 INCIDENT REUSE FAILED: prior incident copies and reporting cutoffs must agree for every account; the supplied reporting cutoff cannot move backward.';
        END IF;
    END IF;
END $$;

-- The transaction restores the previous results on any later error. Scope every reset
-- to its module so a matching name elsewhere on search_path cannot be selected.
DROP TABLE IF EXISTS module2.metro2_remediation_final;
DROP TABLE IF EXISTS module2.metro2_remediation_php_detail;
DROP TABLE IF EXISTS module2.metro2_remediation_window_eval;
DROP TABLE IF EXISTS module2.metro2_remediation_input;


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
CREATE TABLE module2.metro2_remediation_input AS
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
    WHERE NOT EXISTS (SELECT 1 FROM pg_temp.module2_saved_incident_dates)
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
UNION ALL
SELECT account, impact_start_date, impact_end_date
FROM pg_temp.module2_saved_incident_dates
ORDER BY account;

CREATE INDEX ix_remediation_input_account
    ON module2.metro2_remediation_input (account);


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
    FROM module2.metro2_remediation_input i
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
--   6) the latest in-window G/H/J/K/L requires deletion until original later 0–6 supports reversal
--   7) reversal supports targeted cleanup; the separate cure test determines ongoing exposure
-- ====================================================================================================
CREATE TABLE module2.metro2_remediation_window_eval AS
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
    JOIN module2.metro2_remediation_input i
      ON f.account = i.account
    CROSS JOIN pg_temp.module2_params p
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
    JOIN pg_temp.module2_params p
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
--   - any original charge-off (L), including when another major event occurs later
--
-- Why this exists:
--   The latest original severe event controls treatment. The any-charge-off flag
--   provides descriptive continuity with earlier study outputs.
--
--   If the credit impact window contains neither delinquency nor derogatory content,
--   then the account is effectively "no impact" from a credit reporting standpoint,
--   even if post-impact history is short.
-- --------------------------------------------------------------------------------------------
credit_window_flags AS (
    SELECT
        p.account,
        MAX(h.byte_date) FILTER (WHERE h.status IN ('G','H','J','K','L')) AS last_severe_month,
        MAX(CASE WHEN h.status = 'L' THEN 1 ELSE 0 END) AS has_chargeoff_in_credit_window,
        MAX(CASE WHEN h.status IN ('1','2','3','4','5','6') THEN 1 ELSE 0 END) AS has_delinquency_in_credit_window
    FROM preliminary_eval p
    JOIN module1.metro2_status_history h
      ON p.account = h.account
     AND h.byte_date BETWEEN p.credit_impact_start_date AND p.credit_impact_end_date_pre
    GROUP BY p.account
),

-- --------------------------------------------------------------------------------------------
-- A numeric mark before the latest severe event cannot reverse that later event.
-- The first qualifying numeric mark may be the first zero of the cure run. Measure
-- only through its confirmation, or through the latest original month if still open.
-- --------------------------------------------------------------------------------------------
reversal AS (
    SELECT f.account, MIN(h.byte_date) AS severe_reversal_month
    FROM credit_window_flags f
    JOIN preliminary_eval p USING (account)
    JOIN module1.metro2_status_history h
      ON h.account = f.account
     AND h.byte_date > f.last_severe_month
     AND h.byte_date <= coalesce(
         (p.credit_cure_date + (p.cure_consecutive_months_required - 1) * interval '1 month')::date,
         p.php_left_byte_date)
     AND h.status IN ('0','1','2','3','4','5','6')
    GROUP BY f.account
),

-- A reversed severe event gets targeted cleanup. Cure and open/closed status govern
-- the separate review flag, so the same account may receive cleanup and continued review.
treatment_eval AS (
    SELECT
        p.*,
        f.last_severe_month,
        r.severe_reversal_month,
        (f.last_severe_month IS NOT NULL)::int AS has_derog_in_credit_window,
        COALESCE(f.has_chargeoff_in_credit_window, 0) AS has_chargeoff_in_credit_window,
        COALESCE(f.has_delinquency_in_credit_window, 0) AS has_delinquency_in_credit_window,
        (r.severe_reversal_month IS NOT NULL)::int AS has_post_derog_recovery_evidence,
        CASE
            WHEN f.last_severe_month IS NOT NULL AND r.severe_reversal_month IS NULL
                THEN 'TRADELINE_DELETION'
            WHEN f.last_severe_month IS NOT NULL
                THEN 'FULL_DEROGATORY_PHP_CLEANUP'
            WHEN f.has_delinquency_in_credit_window = 1
                THEN 'SIMPLE_DELINQUENCY_PHP_CLEANUP'
            ELSE 'NO_IMPACT_CLEAN_PHP_HISTORY'
        END AS remediation_treatment
    FROM preliminary_eval p
    LEFT JOIN credit_window_flags f ON p.account = f.account
    LEFT JOIN reversal r ON p.account = r.account
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
    credit_impact_end_date_pre AS credit_impact_end_date,
    credit_cure_date,
    cure_consecutive_months_required,
    post_impact_month_count,
    has_derog_in_credit_window,
    has_delinquency_in_credit_window,
    has_post_derog_recovery_evidence,
    CASE WHEN remediation_treatment IN ('TRADELINE_DELETION', 'NO_IMPACT_CLEAN_PHP_HISTORY')
         THEN 0 ELSE manual_review_flag_pre END AS manual_review_flag,
    CASE WHEN remediation_treatment IN ('TRADELINE_DELETION', 'NO_IMPACT_CLEAN_PHP_HISTORY')
         THEN NULL ELSE manual_review_reason_pre END AS manual_review_reason,
    remediation_treatment,
    has_chargeoff_in_credit_window,
    last_severe_month,
    severe_reversal_month,
    'REVERSAL_AWARE_SEVERE_V2'::text AS remediation_policy
FROM treatment_eval
ORDER BY account;

CREATE INDEX ix_remediation_window_eval_account
    ON module2.metro2_remediation_window_eval (account);


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
CREATE TABLE module2.metro2_remediation_php_detail AS
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
FROM module2.metro2_remediation_window_eval e
JOIN module1.metro2_status_history h
  ON e.account = h.account
ORDER BY e.account, h.byte_date DESC;

CREATE INDEX ix_remediation_php_detail_account_byte_date
    ON module2.metro2_remediation_php_detail (account, byte_date DESC);


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
CREATE TABLE module2.metro2_remediation_final AS
WITH
-- --------------------------------------------------------------------------------------------
-- The date of account information describes a current-cycle account record. Historical
-- PHP provides evidence for changing its fields only where treatment removed their basis.
source_context AS (
    SELECT w.*,
           CASE w.account_status_17a WHEN '61' THEN 'J' WHEN '62' THEN 'G'
               WHEN '63' THEN 'K' WHEN '64' THEN 'L' WHEN '65' THEN 'H' END AS paid_major,
           (date_trunc('month',w.date_closed) - interval '1 month')::date AS preclosure_month,
           date_trunc('month',w.date_of_first_delinquency)::date AS source_onset_month,
           w.remediation_treatment IN ('SIMPLE_DELINQUENCY_PHP_CLEANUP','FULL_DEROGATORY_PHP_CLEANUP') AS cleanup
    FROM module2.metro2_remediation_window_eval w
),
monthly_evidence AS (
    SELECT d.account,
           string_agg(d.remediated_status,'' ORDER BY d.byte_date DESC) AS proposed_php,
           max(d.original_status) FILTER (WHERE d.byte_date = s.php_left_byte_date) AS newest_mark,
           bool_or(d.byte_date = s.php_left_byte_date AND d.original_status <> d.remediated_status) AS newest_edited,
           max(d.byte_date) FILTER (WHERE d.original_status = s.paid_major
               AND d.original_status <> d.remediated_status) AS removed_paid_major_month,
           bool_or(d.remediated_status = s.paid_major) AS paid_major_survives,
           max(d.byte_date) FILTER (WHERE d.remediated_status IN ('1','2','3','4','5','6','G','H','J','K','L')) AS last_retained_adverse,
           max(d.original_status) FILTER (WHERE d.byte_date = s.preclosure_month) AS preclosure_mark,
           bool_or(d.byte_date = s.preclosure_month AND d.original_status <> d.remediated_status) AS preclosure_edited,
           max(d.byte_date) FILTER (WHERE d.original_status = 'D') AS last_original_unknown,
           max(d.byte_date) FILTER (WHERE d.original_status IN ('1','2','3','4','5','6','G','H','J','K','L')) AS last_original_adverse,
           -- Prove the documented onset in the original data. A cured or unknown
           -- intervening month cannot connect a prior episode to a newer correction.
           min(d.byte_date) FILTER (WHERE d.byte_date = s.source_onset_month
               AND d.original_status IN ('1','2','3','4','5','6')) AS observed_onset,
           min(d.byte_date) FILTER (WHERE d.byte_date >= s.source_onset_month
               AND d.original_status IN ('0','B','D')) AS first_episode_break
    FROM module2.metro2_remediation_php_detail d
    JOIN source_context s USING (account)
    GROUP BY d.account
),
field_basis AS (
    SELECT s.*, m.proposed_php, m.newest_mark, m.newest_edited, m.removed_paid_major_month,
           m.paid_major_survives, m.last_retained_adverse, m.preclosure_mark, m.preclosure_edited,
           m.last_original_unknown, m.last_original_adverse,
           CASE WHEN m.observed_onset IS NOT NULL
                THEN daterange(m.observed_onset, m.first_episode_break, '[)') END AS observed_episode,
           CASE m.newest_mark WHEN '0' THEN '11' WHEN '1' THEN '71' WHEN '2' THEN '78'
               WHEN '3' THEN '80' WHEN '4' THEN '82' WHEN '5' THEN '83' WHEN '6' THEN '84'
               WHEN 'G' THEN '93' WHEN 'H' THEN '94' WHEN 'J' THEN '95' WHEN 'K' THEN '96' WHEN 'L' THEN '97'
           END AS status_supported_by_latest,
           (s.payment_rating_17b IN ('1','2','3','4','5','6','G','L')
             AND m.preclosure_mark = s.payment_rating_17b AND m.preclosure_edited
             AND (m.last_retained_adverse IS NULL OR m.last_retained_adverse <= s.preclosure_month)
             AND (s.source_onset_month IS NULL OR s.source_onset_month <= s.preclosure_month)) AS closure_rating_removed
    FROM source_context s JOIN monthly_evidence m USING (account)
),
candidate_basis AS (
    SELECT b.*,
           CASE
               WHEN NOT cleanup THEN NULL
               -- A paid-derogatory classification can change only after its corresponding
               -- original event was actually removed. Preserve a surviving or later basis.
               WHEN paid_major IS NOT NULL AND removed_paid_major_month IS NOT NULL
                   AND NOT paid_major_survives
                   AND removed_paid_major_month <= date_closed
                   AND (last_original_unknown IS NULL OR last_original_unknown <= removed_paid_major_month)
                   AND (last_retained_adverse IS NULL OR last_retained_adverse <= removed_paid_major_month)
                   AND (source_onset_month IS NULL OR source_onset_month <= removed_paid_major_month)
                   AND (payment_rating_17b IS NULL OR payment_rating_17b IN ('0',paid_major) OR closure_rating_removed)
                   THEN removed_paid_major_month
               WHEN account_status_17a = '13' AND closure_rating_removed THEN preclosure_month
               -- 17899: January's 1 is changed to D. Its sourced February 1 status 71
               -- corroborates that basis. Elect 11/internal 0 and clear the internal DOFD.
               -- December's 1 and source date remain visible; only actual post-issue 0s can establish cure.
               WHEN newest_edited AND account_status_17a = status_supported_by_latest
                   AND (payment_rating_17b IS NULL OR payment_rating_17b IN ('0',newest_mark))
                   AND (source_onset_month IS NULL OR source_onset_month <= php_left_byte_date)
                   THEN php_left_byte_date
           END AS affected_basis_month
    FROM field_basis b
),
basis_checks AS (
    SELECT b.*,
           CASE
               WHEN affected_basis_month IS NULL THEN NULL
               -- A dated closure cannot corroborate an open/current election. On a
               -- closed classification, even a suppressed adverse mark in or after
               -- the closure month needs servicing evidence. This is a study guard.
               WHEN date_closed IS NOT NULL AND (
                   (paid_major IS NULL AND account_status_17a <> '13') OR date_closed > latest_doai OR
                   last_original_adverse >= date_trunc('month',date_closed)::date)
                   THEN 'CLOSURE_TIMING_UNCONFIRMED'
               -- With a supplied date, each basis supporting the bundle must belong
               -- to that original uninterrupted episode. No date is invented when absent.
               WHEN source_onset_month IS NOT NULL AND (
                   NOT coalesce(affected_basis_month <@ observed_episode,false) OR
                   (paid_major IS NOT NULL AND payment_rating_17b NOT IN ('0',paid_major) AND
                    NOT coalesce(preclosure_month <@ observed_episode,false)))
                   THEN 'ONSET_CONTINUITY_UNCONFIRMED'
           END AS blocked_election_reason
    FROM candidate_basis b
),
field_decision AS (
    SELECT b.*,
           CASE WHEN affected_basis_month IS NOT NULL AND blocked_election_reason IS NULL THEN
               CASE WHEN paid_major IS NOT NULL OR account_status_17a = '13' THEN '13' ELSE '11' END
           END AS elected_status
    FROM basis_checks b
),
delta_fields AS (
    SELECT e.*,
           nullif(proposed_php,full_php) AS remediated_full_php,
           CASE WHEN remediation_treatment = 'TRADELINE_DELETION' THEN 'DA'
                ELSE nullif(elected_status,account_status_17a) END AS remediated_account_status_17a,
           CASE WHEN elected_status IS NOT NULL THEN nullif('0',payment_rating_17b) END AS remediated_payment_rating_17b,
           -- No new onset is established by correcting history. Preserve source dates across
           -- original D gaps and unrelated later deterioration. A justified favorable election can clear one.
           NULL::date AS remediated_date_of_first_delinquency,
           false AS clear_account_status_17a,
           false AS clear_payment_rating_17b,
           (elected_status IS NOT NULL AND date_of_first_delinquency IS NOT NULL) AS clear_date_of_first_delinquency,
           -- Separate servicing research from cure monitoring. Missing required effective dates
           -- also remain visible in the distinct Field 25 source-exception report.
           CASE
               WHEN remediation_treatment = 'TRADELINE_DELETION' OR elected_status IS NOT NULL THEN NULL
               -- The historical status/rating screen applies to retained records even
               -- when no PHP is treated. Without the rating some Field 25 tests are indeterminate.
               WHEN account_status_17a IN ('05','13','65','88','89','94','95')
                    AND nullif(btrim(payment_rating_17b),'') IS NULL THEN 'MISSING_REQUIRED_PAYMENT_RATING'
               WHEN NOT cleanup THEN NULL
               WHEN blocked_election_reason IS NOT NULL THEN blocked_election_reason
               WHEN paid_major IS NOT NULL AND NOT paid_major_survives THEN 'PAID_MAJOR_BASIS_UNCONFIRMED'
               WHEN account_status_17a = '13' AND payment_rating_17b IN ('1','2','3','4','5','6','G','L')
                    AND (preclosure_mark IS DISTINCT FROM payment_rating_17b OR preclosure_edited
                         OR date_closed > latest_doai) THEN 'CLOSURE_RATING_BASIS_UNCONFIRMED'
               WHEN paid_major IS NULL AND account_status_17a IS DISTINCT FROM '13'
                    AND newest_mark NOT IN ('B','D') AND
                      (account_status_17a IS DISTINCT FROM status_supported_by_latest OR newest_edited)
                    THEN 'AS_OF_FIELD_BASIS_UNCONFIRMED'
               WHEN paid_major IS NULL AND account_status_17a IS DISTINCT FROM '13'
                    AND newest_mark IN ('1','2','3','4','5','6','G','H','J','K','L')
                    AND last_original_unknown BETWEEN source_onset_month AND php_left_byte_date
                    THEN 'ONSET_CONTINUITY_UNCONFIRMED'
           END AS account_field_review_reason
    FROM field_decision e
),

-- Summarize every replacement or explicit clear in the final field groups.
-- The source columns remain available beside their sparse deltas.
-- --------------------------------------------------------------------------------------------
field_changes AS (
    SELECT d.*,
        d.remediated_full_php IS NOT NULL AS php_changed,
        (d.remediated_account_status_17A IS NOT NULL OR d.clear_account_status_17a) AS status_changed,
        (d.remediated_payment_rating_17B IS NOT NULL OR d.clear_payment_rating_17b
         OR d.remediated_date_of_first_delinquency IS NOT NULL OR d.clear_date_of_first_delinquency) AS derived_changed
    FROM delta_fields d
),
final_flags AS (
    SELECT c.*,
        (php_changed OR status_changed OR derived_changed)::int AS remediation_applied_flag,
        CASE
            WHEN php_changed AND status_changed AND derived_changed THEN 'PHP_STATUS_AND_DERIVED_FIELDS'
            WHEN php_changed AND status_changed THEN 'PHP_AND_STATUS'
            WHEN php_changed AND derived_changed THEN 'PHP_AND_DERIVED_FIELDS'
            WHEN status_changed AND derived_changed THEN 'STATUS_AND_DERIVED_FIELDS'
            WHEN php_changed THEN 'PHP_ONLY'
            WHEN status_changed THEN 'STATUS_ONLY'
            WHEN derived_changed THEN 'DERIVED_FIELDS_ONLY'
            ELSE 'NONE'
        END AS remediation_fields_modified
    FROM field_changes c
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
    remediation_fields_modified,
    clear_account_status_17a,
    clear_payment_rating_17b,
    clear_date_of_first_delinquency,
    'EVIDENCE_SCOPED_FIELDS_V2'::text AS account_field_policy,
    account_field_review_reason

FROM final_flags
ORDER BY account;

CREATE INDEX ix_remediation_final_account
    ON module2.metro2_remediation_final (account);


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
--   - how charge-off, confirmed cure and post-derog performance affect deletion
-- ====================================================================================================

-- --------------------------------------------------------------------------------------------
-- QA 1: Echo the Module 2 parameter row
-- --------------------------------------------------------------------------------------------
SELECT * FROM pg_temp.module2_params;

-- --------------------------------------------------------------------------------------------
-- QA 2: Sample remediation input rows
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_input
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
FROM module2.metro2_remediation_window_eval
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 4: Count accounts by remediation treatment
-- --------------------------------------------------------------------------------------------
SELECT
    remediation_treatment,
    COUNT(*) AS account_count
FROM module2.metro2_remediation_window_eval
GROUP BY remediation_treatment
ORDER BY remediation_treatment;

-- --------------------------------------------------------------------------------------------
-- QA 5: Count manual review cases by reason
-- --------------------------------------------------------------------------------------------
SELECT
    COALESCE(manual_review_reason, 'NO_MANUAL_REVIEW') AS manual_review_reason,
    COUNT(*) AS account_count
FROM module2.metro2_remediation_final
GROUP BY COALESCE(manual_review_reason, 'NO_MANUAL_REVIEW')
ORDER BY manual_review_reason;

-- --------------------------------------------------------------------------------------------
-- QA 6: Sample month-level remediation detail
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_php_detail
ORDER BY account, byte_date DESC
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 7: Sample final remediation output
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_final
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 8: Tradeline deletion examples
-- Why:
--   Inspect cases whose last in-window severe event still lacks a subsequent original numeric mark.
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_final
WHERE remediation_treatment = 'TRADELINE_DELETION'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 9: Full derogatory cleanup examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_final
WHERE remediation_treatment = 'FULL_DEROGATORY_PHP_CLEANUP'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 10: Simple delinquency cleanup examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_final
WHERE remediation_treatment = 'SIMPLE_DELINQUENCY_PHP_CLEANUP'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 11: No-impact examples
-- --------------------------------------------------------------------------------------------
SELECT *
FROM module2.metro2_remediation_final
WHERE remediation_treatment = 'NO_IMPACT_CLEAN_PHP_HISTORY'
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 12: Review remediation_fields_modified distribution
-- --------------------------------------------------------------------------------------------
SELECT
    remediation_fields_modified,
    COUNT(*) AS account_count
FROM module2.metro2_remediation_final
GROUP BY remediation_fields_modified
ORDER BY remediation_fields_modified;

-- --------------------------------------------------------------------------------------------
-- QA 13: Sample accounts with a proposed 17A replacement or explicit internal clear
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    account_status_17A,
    remediated_account_status_17A,
    clear_account_status_17a,
    remediation_treatment,
    remediation_fields_modified
FROM module2.metro2_remediation_final
WHERE remediated_account_status_17A IS NOT NULL OR clear_account_status_17a
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
FROM module2.metro2_remediation_final
WHERE remediated_full_php IS NOT NULL
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 15: Sample accounts with a proposed DOFD replacement or explicit internal clear
-- A NULL proposed date with a true clear flag removes the internal date. Bureau encoding is a separate step.
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    date_of_first_delinquency,
    remediated_date_of_first_delinquency,
    clear_date_of_first_delinquency,
    remediation_treatment,
    remediation_fields_modified
FROM module2.metro2_remediation_final
WHERE remediated_date_of_first_delinquency IS NOT NULL OR clear_date_of_first_delinquency
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 16: Accounts with derog in the credit window that also show post-derog recovery evidence
-- Why:
--   Compare the event month with the first original numeric mark that supported reversal and cleanup.
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    full_php,
    impact_start_date,
    impact_end_date,
    credit_impact_start_date,
    credit_impact_end_date,
    credit_cure_date,
    has_chargeoff_in_credit_window,
    last_severe_month,
    severe_reversal_month,
    has_post_derog_recovery_evidence,
    remediation_treatment
FROM module2.metro2_remediation_window_eval
WHERE has_derog_in_credit_window = 1
  AND has_post_derog_recovery_evidence = 1
ORDER BY account
LIMIT 100;


-- QA 17: Reconcile severe-event routing, final deletion instructions and monthly evidence.
-- A later in-window G/H/J/K/L supersedes any numeric return after an earlier severe event.
-- Each count should be zero.
WITH monthly_check AS (
    SELECT w.account,
           bool_or(h.status = 'L' AND h.byte_date BETWEEN w.credit_impact_start_date
                                                        AND w.credit_impact_end_date) AS original_chargeoff_in_window,
           bool_or(d.original_status IS DISTINCT FROM d.remediated_status) AS changed_month
    FROM module2.metro2_remediation_window_eval w
    JOIN module1.metro2_status_history h ON h.account = w.account
    JOIN module2.metro2_remediation_php_detail d ON d.account = h.account AND d.byte_date = h.byte_date
    GROUP BY w.account
)
SELECT
    count(*) FILTER (
        WHERE w.has_chargeoff_in_credit_window IS DISTINCT FROM c.original_chargeoff_in_window::int
    ) AS chargeoff_indicator_mismatches,
    count(*) FILTER (
        WHERE w.last_severe_month IS NOT NULL AND
            f.remediation_treatment IS DISTINCT FROM CASE WHEN w.severe_reversal_month IS NULL
                THEN 'TRADELINE_DELETION' ELSE 'FULL_DEROGATORY_PHP_CLEANUP' END
    ) AS severe_treatment_mismatches,
    count(*) FILTER (
        WHERE f.remediation_treatment = 'TRADELINE_DELETION'
          AND (f.remediated_account_status_17A IS DISTINCT FROM 'DA' OR c.changed_month
            OR f.remediated_full_php IS NOT NULL OR f.remediated_payment_rating_17B IS NOT NULL
            OR f.remediated_date_of_first_delinquency IS NOT NULL
            OR f.clear_account_status_17a OR f.clear_payment_rating_17b OR f.clear_date_of_first_delinquency
            OR f.remediation_fields_modified IS DISTINCT FROM 'STATUS_ONLY'
            OR f.manual_review_flag IS DISTINCT FROM 0 OR f.manual_review_reason IS NOT NULL)
    ) AS deletion_output_mismatches
FROM module2.metro2_remediation_final f
JOIN module2.metro2_remediation_window_eval w USING (account)
JOIN monthly_check c USING (account);

COMMIT;
