/* ====================================================================================================
PROGRAM:  Metro 2 Synthetic Portfolio Generator — (Version 2)
SUBTITLE: Module 1: Longtitudinal Tradeline Sample Builder
FILE:     module_01_metro2_synthetic_portfolio_generator.sql
AUTHOR:   Andrew R Goad
DB:       PostgreSQL 15+
PURPOSE:  Build a synthetic Metro 2-style portfolio for analytics, SQL learning, QA practice,
          GitHub portfolio use, and later remediation simulation modules.

AUTHORING INTENT
----------------
This script is written as BOTH:
1) a working synthetic data generator, and
2) a teaching tool for users who want to learn the SQL and methodology step by step.

VERSION HISTORY
---------------
Version 1:
- Built metro2_sample first
- Then repeatedly exploded PHP to derive stitched outputs
- Included QA ideas, but the computational design was heavier than necessary

Version 2:
- Materializes month-level account performance once in metro2_status_history
- Uses that table as the central truth source
- Derives metro2_sample and metro2_final from the same reusable month-level history
- Improves performance, readability, and auditability
- Keeps QA in the same script now that the target environment is local PostgreSQL + DBeaver

CORE DESIGN PRINCIPLE
---------------------
PHP is an output artifact, not the computational backbone.

This means:
- We do NOT repeatedly explode and reassemble PHP to compute business logic
- Instead, we compute a clean month-level status history first
- Then PHP becomes a rendered view over that history

This is both:
- more efficient
- easier to debug
- easier to explain to future readers

======================================================================================================
JOB AID — HOW TO USE THIS SCRIPT
======================================================================================================

1) INSTALL / ENVIRONMENT ASSUMPTION
   This script is intended for local PostgreSQL inside DBeaver.
   It is not optimized for browser sandboxes like DB Fiddle.

2) RECOMMENDED DATABASE / SCHEMA SETUP
   Example:
      CREATE DATABASE metro2_lab;
      CREATE SCHEMA IF NOT EXISTS module1;
      SET search_path TO module1, public;

   This script creates the schema if needed and sets the search_path for the current session.

3) INPUTS TO EDIT
   Most users should only edit the INSERT INTO module1_params statement near the top.
   Inputs:
      - sample_size
      - pct_current
      - pct_mild
      - pct_mod
      - pct_severe
      - pct_derog

   Defaults:
      sample_size = 5000000
      current     = 70%
      mild        = 15%
      mod         =  8%
      severe      =  4%
      derog       =  3%

4) VALIDATION
   The script validates the user inputs and raises an error immediately if:
      - sample_size <= 0
      - any percentage is outside [0, 1]
      - percentages do not sum to 1.000000

5) MAIN OUTPUT TABLES
   A) metro2_account_blueprint
      Account-level generation metadata

   B) metro2_status_history
      One row per account per represented month
      This is the core month-level truth table

   C) metro2_sample
      Longitudinal snapshot table with:
         - account
         - date_of_account_information
         - php

   D) metro2_final
      Final account-level output table with:
         - latest_doai
         - date_closed
         - full_php
         - account_status_17A
         - payment_rating_17B
         - date_of_first_delinquency

6) QA / REVIEW
   The final section contains review queries to help inspect the output.
   These queries are intended for:
      - learning
      - screenshots
      - portfolio walkthroughs
      - sanity checks

======================================================================================================
METRO 2 COMMENT AID USED IN THIS MODULE
======================================================================================================

A) PAYMENT HISTORY PROFILE (PHP)
   - 24-byte string
   - leftmost byte = most recent month represented
   - rightmost byte = oldest month represented
   - in this project, leftmost byte is assumed to be one month prior to DOAI

   Example:
      DOAI = 2025-10-01
      PHP byte 1 = 2025-09-01
      PHP byte 24 = 2023-10-01

B) PHP BYTES MODELED HERE
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

C) ACCOUNT STATUS 17A VALUES MODELED HERE
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

D) PAYMENT RATING 17B VALUES MODELED HERE
   0,1,2,3,4,5,6
   G, L
   NULL for 61–65 in this synthetic module
   0 for 13 in this synthetic module

IMPORTANT LIMITATION
--------------------
This is a synthetic portfolio-learning module, not a production furnishing engine.
The goal is:
- realistic behavior
- explainable SQL
- internally consistent outputs
- good portfolio presentation

It is not intended to reproduce every edge case of a production Metro 2 furnishing engine.
==================================================================================================== */


-- ====================================================================================================
-- SECTION 0: SCHEMA SETUP
-- ====================================================================================================
-- Purpose:
--   Keep project tables out of the default public schema and place them in a dedicated module schema.
--
-- Why this exists:
--   A dedicated schema is cleaner, more professional, and easier to manage in DBeaver.
--
-- SQL mechanics:
--   - CREATE SCHEMA IF NOT EXISTS creates the schema only if it does not already exist
--   - SET search_path tells PostgreSQL where to create/find unqualified objects for this session
-- ====================================================================================================
CREATE SCHEMA IF NOT EXISTS module1;
SET search_path TO module1, public;


-- ====================================================================================================
-- SECTION 1: RESET
-- ====================================================================================================
-- Purpose:
--   Drop prior objects so the script can be rerun cleanly.
--
-- Why this exists:
--   Synthetic portfolio development is iterative. This lets the script behave like a full refresh.
--
-- SQL mechanics:
--   - DROP TABLE IF EXISTS avoids errors if the table is not already present
--   - We drop downstream tables first, then upstream tables
-- ====================================================================================================
DROP TABLE IF EXISTS module1_params;
DROP TABLE IF EXISTS metro2_final;
DROP TABLE IF EXISTS metro2_sample;
DROP TABLE IF EXISTS metro2_status_history;
DROP TABLE IF EXISTS metro2_account_blueprint;


-- ====================================================================================================
-- SECTION 2: USER PARAMETERS
-- ====================================================================================================
-- Purpose:
--   Store user-editable controls for sample size and portfolio mix.
--
-- Why this exists:
--   Putting parameters into a table makes them easy to:
--   - inspect
--   - validate
--   - reference in later SQL blocks
--
-- SQL mechanics:
--   - CREATE TEMP TABLE creates a temporary table that exists only in the current session
--   - The INSERT statement below is the main user-editable configuration row
-- ====================================================================================================
CREATE TEMP TABLE module1_params (
    sample_size   INTEGER NOT NULL,
    pct_current   NUMERIC(12,6) NOT NULL,
    pct_mild      NUMERIC(12,6) NOT NULL,
    pct_mod       NUMERIC(12,6) NOT NULL,
    pct_severe    NUMERIC(12,6) NOT NULL,
    pct_derog     NUMERIC(12,6) NOT NULL
);

INSERT INTO module1_params (
    sample_size,
    pct_current,
    pct_mild,
    pct_mod,
    pct_severe,
    pct_derog
)
VALUES (
    5000000,   -- total number of synthetic accounts to generate
    0.700000,  -- share of CURRENT accounts
    0.150000,  -- share of MILD delinquency accounts
    0.080000,  -- share of MOD delinquency accounts
    0.040000,  -- share of SEVERE delinquency accounts
    0.030000   -- share of DEROG accounts
);


-- ====================================================================================================
-- SECTION 3: GATEKEEPER VALIDATION
-- ====================================================================================================
-- Purpose:
--   Fail fast if the parameter configuration is invalid.
--
-- Why this exists:
--   Validation at the top prevents confusing downstream failures.
--
-- SQL mechanics:
--   - DO $$ ... $$ runs a procedural PL/pgSQL block
--   - We read the parameter row into variables
--   - We test the values using IF statements
--   - RAISE EXCEPTION stops the script immediately with a descriptive message
-- ====================================================================================================
DO $$
DECLARE
    v_sample_size INTEGER;
    v_pct_current NUMERIC(12,6);
    v_pct_mild    NUMERIC(12,6);
    v_pct_mod     NUMERIC(12,6);
    v_pct_severe  NUMERIC(12,6);
    v_pct_derog   NUMERIC(12,6);
    v_sum         NUMERIC(18,10);
BEGIN
    SELECT
        sample_size,
        pct_current,
        pct_mild,
        pct_mod,
        pct_severe,
        pct_derog
    INTO
        v_sample_size,
        v_pct_current,
        v_pct_mild,
        v_pct_mod,
        v_pct_severe,
        v_pct_derog
    FROM module1_params;

    v_sum := v_pct_current + v_pct_mild + v_pct_mod + v_pct_severe + v_pct_derog;

    IF v_sample_size IS NULL OR v_sample_size <= 0 THEN
        RAISE EXCEPTION
            'MODULE 1 PARAMETER VALIDATION FAILED: sample_size must be a positive integer. Current value = %',
            v_sample_size;
    END IF;

    IF v_pct_current < 0 OR v_pct_current > 1
       OR v_pct_mild  < 0 OR v_pct_mild  > 1
       OR v_pct_mod   < 0 OR v_pct_mod   > 1
       OR v_pct_severe < 0 OR v_pct_severe > 1
       OR v_pct_derog < 0 OR v_pct_derog > 1
    THEN
        RAISE EXCEPTION
            'MODULE 1 PARAMETER VALIDATION FAILED: all percentage inputs must be between 0 and 1 inclusive. Current values = current:% mild:% mod:% severe:% derog:%',
            v_pct_current, v_pct_mild, v_pct_mod, v_pct_severe, v_pct_derog;
    END IF;

    IF ABS(v_sum - 1.000000) > 0.000001 THEN
        RAISE EXCEPTION
            'MODULE 1 PARAMETER VALIDATION FAILED: profile percentages must sum to 1.000000. Current sum = % (current:% mild:% mod:% severe:% derog:%)',
            v_sum, v_pct_current, v_pct_mild, v_pct_mod, v_pct_severe, v_pct_derog;
    END IF;
END $$;


-- ====================================================================================================
-- SECTION 4: BUILD ACCOUNT BLUEPRINT
-- ====================================================================================================
-- Purpose:
--   Create one account-level row per synthetic account, including:
--   - profile assignment
--   - activity flag
--   - closure behavior
--   - derog code
--   - date range
--   - synthetic behavior pattern string
--
-- Why this exists:
--   This table is the "account design layer" for the module.
--   It lets us separate:
--      (a) account-level assumptions
--   from (b) month-level status generation
--
-- SQL mechanics:
--   This section uses a chain of CTEs (WITH clauses).
--   A CTE is like a temporary named result set used only within one query.
--   We use CTEs here because each step builds logically on the prior step.
-- ====================================================================================================
CREATE TABLE metro2_account_blueprint AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: params
-- Purpose:
--   Read the one-row parameter table into the query.
--
-- SQL mechanics:
--   SELECT * FROM module1_params simply exposes the parameters for later CTEs.
-- --------------------------------------------------------------------------------------------
params AS (
    SELECT * FROM module1_params
),

-- --------------------------------------------------------------------------------------------
-- CTE: profile_cutoffs
-- Purpose:
--   Convert percentage targets into cumulative integer cutoffs.
--
-- Why this exists:
--   We want to assign account ids 1..N into profile buckets according to the user-configured mix.
--
-- SQL mechanics:
--   - FLOOR(sample_size * pct_x) converts percentages into counts
--   - cumulative cutoffs allow a CASE statement later to classify each account id into a bucket
-- --------------------------------------------------------------------------------------------
profile_cutoffs AS (
    SELECT
        sample_size,
        FLOOR(sample_size * pct_current)::INT AS curr_cut,
        FLOOR(sample_size * (pct_current + pct_mild))::INT AS mild_cut,
        FLOOR(sample_size * (pct_current + pct_mild + pct_mod))::INT AS mod_cut,
        FLOOR(sample_size * (pct_current + pct_mild + pct_mod + pct_severe))::INT AS severe_cut
    FROM params
),

-- --------------------------------------------------------------------------------------------
-- CTE: base_accounts
-- Purpose:
--   Create one row per synthetic account and assign a base profile type.
--
-- Why this exists:
--   This is the first true account-level population step.
--
-- SQL mechanics:
--   - generate_series(1, sample_size) creates integers 1..sample_size
--   - each integer becomes an account id
--   - CASE compares each account id to the cumulative cutoffs to assign its profile bucket
-- --------------------------------------------------------------------------------------------
base_accounts AS (
    SELECT
        gs AS account,
        CASE
            WHEN gs <= pc.curr_cut   THEN 'CURRENT'
            WHEN gs <= pc.mild_cut   THEN 'MILD'
            WHEN gs <= pc.mod_cut    THEN 'MOD'
            WHEN gs <= pc.severe_cut THEN 'SEVERE'
            ELSE 'DEROG'
        END AS base_profile_type
    FROM profile_cutoffs pc
    CROSS JOIN generate_series(1, (SELECT sample_size FROM params)) AS gs
),

-- --------------------------------------------------------------------------------------------
-- CTE: seeds
-- Purpose:
--   Create deterministic pseudo-random seed values per account.
--
-- Why this exists:
--   We want reproducible synthetic variation. If you rerun the script with the same inputs,
--   each account should get the same synthetic behavior.
--
-- SQL mechanics:
--   - md5(text) produces a deterministic hash string
--   - substr(..., 1, 7) takes part of the hash
--   - the hex is converted into an integer using bit casting
--   - multiple seeds allow different types of behavior to vary independently
-- --------------------------------------------------------------------------------------------
seeds AS (
    SELECT
        b.*,
        (('x' || substr(md5(account::text || '-a'), 1, 7))::bit(28)::int) AS s1,
        (('x' || substr(md5(account::text || '-b'), 1, 7))::bit(28)::int) AS s2,
        (('x' || substr(md5(account::text || '-c'), 1, 7))::bit(28)::int) AS s3,
        (('x' || substr(md5(account::text || '-d'), 1, 7))::bit(28)::int) AS s4,
        (('x' || substr(md5(account::text || '-e'), 1, 7))::bit(28)::int) AS s5,
        (('x' || substr(md5(account::text || '-f'), 1, 7))::bit(28)::int) AS s6,
        (('x' || substr(md5(account::text || '-g'), 1, 7))::bit(28)::int) AS s7,
        (('x' || substr(md5(account::text || '-h'), 1, 7))::bit(28)::int) AS s8
    FROM base_accounts b
),

-- --------------------------------------------------------------------------------------------
-- CTE: seeded
-- Purpose:
--   Convert the raw seed values into account-level features:
--   - active vs inactive
--   - behavior variant
--   - suppression flag
--   - derog code family
--
-- Why this exists:
--   This is where account-level diversity begins.
--
-- SQL mechanics:
--   - CASE + modulo (%) creates controlled deterministic branching
--   - s1%100 gives a stable pseudo-random number from 0 to 99 for each account
-- --------------------------------------------------------------------------------------------
seeded AS (
    SELECT
        account,
        base_profile_type,

        CASE
            WHEN base_profile_type = 'CURRENT' THEN CASE WHEN s1 % 100 < 80 THEN 1 ELSE 0 END
            WHEN base_profile_type = 'MILD'    THEN CASE WHEN s1 % 100 < 70 THEN 1 ELSE 0 END
            WHEN base_profile_type = 'MOD'     THEN CASE WHEN s1 % 100 < 55 THEN 1 ELSE 0 END
            WHEN base_profile_type = 'SEVERE'  THEN CASE WHEN s1 % 100 < 38 THEN 1 ELSE 0 END
            ELSE                                    CASE WHEN s1 % 100 < 22 THEN 1 ELSE 0 END
        END AS active_flag,

        s2,
        s3,
        s4 % 100 AS behavior_variant,

        CASE WHEN s5 % 100 < 2 THEN 1 ELSE 0 END AS has_suppression,
        1 + (s6 % 8) AS suppression_start_age,

        CASE
            WHEN s7 % 100 < 50 THEN 'L'
            WHEN s7 % 100 < 75 THEN 'G'
            WHEN s7 % 100 < 87 THEN 'K'
            WHEN s7 % 100 < 95 THEN 'J'
            ELSE 'H'
        END AS derog_code,

        s8 AS raw_seed
    FROM seeds
),

-- --------------------------------------------------------------------------------------------
-- CTE: patterned
-- Purpose:
--   Propose an initial reporting window length per account.
--
-- Why this exists:
--   Real portfolios have varied ages:
--   - some accounts are new
--   - some are seasoned
--   - some are very old but still within bureau-detail retention assumptions
--
-- SQL mechanics:
--   - nested CASE statements create different vintage distributions by profile type
-- --------------------------------------------------------------------------------------------
patterned AS (
    SELECT
        account,
        base_profile_type,
        active_flag,
        behavior_variant,
        has_suppression,
        suppression_start_age,
        derog_code,
        raw_seed,
        CASE
            WHEN base_profile_type = 'CURRENT' THEN
                CASE
                    WHEN s2 % 100 < 20 THEN  3 + (s3 % 10)
                    WHEN s2 % 100 < 60 THEN 13 + (s3 % 24)
                    WHEN s2 % 100 < 85 THEN 37 + (s3 % 24)
                    ELSE                   61 + (s3 % 24)
                END
            WHEN base_profile_type = 'MILD' THEN
                CASE
                    WHEN s2 % 100 < 15 THEN  6 + (s3 % 7)
                    WHEN s2 % 100 < 60 THEN 13 + (s3 % 24)
                    WHEN s2 % 100 < 85 THEN 37 + (s3 % 24)
                    ELSE                   61 + (s3 % 24)
                END
            WHEN base_profile_type = 'MOD' THEN
                CASE
                    WHEN s2 % 100 < 20 THEN  8 + (s3 % 9)
                    WHEN s2 % 100 < 65 THEN 17 + (s3 % 20)
                    WHEN s2 % 100 < 88 THEN 37 + (s3 % 24)
                    ELSE                   61 + (s3 % 24)
                END
            WHEN base_profile_type = 'SEVERE' THEN
                CASE
                    WHEN s2 % 100 < 30 THEN 12 + (s3 % 13)
                    WHEN s2 % 100 < 75 THEN 25 + (s3 % 24)
                    ELSE                   49 + (s3 % 36)
                END
            WHEN base_profile_type = 'DEROG' THEN
                CASE
                    WHEN s2 % 100 < 25 THEN 18 + (s3 % 13)
                    WHEN s2 % 100 < 75 THEN 31 + (s3 % 24)
                    ELSE                   55 + (s3 % 30)
                END
        END AS months_reporting_raw
    FROM seeded
),

-- --------------------------------------------------------------------------------------------
-- CTE: profile_logic
-- Purpose:
--   Convert a very small number of accounts into reversed-major-derog cases.
--
-- Why this exists:
--   In real-world remediation and servicing scenarios, banks sometimes reverse major derogatory
--   outcomes. We include a tiny number of those cases for realism and future remediation work.
-- --------------------------------------------------------------------------------------------
profile_logic AS (
    SELECT
        p.*,
        CASE
            WHEN base_profile_type IN ('CURRENT','MILD','MOD')
             AND active_flag = 1
             AND has_suppression = 0
             AND months_reporting_raw >= 20
             AND raw_seed % 100 < 2
            THEN 'REVERSED_MAJOR_DEROG'
            ELSE base_profile_type
        END AS profile_type
    FROM patterned p
),

-- --------------------------------------------------------------------------------------------
-- CTE: closure_logic
-- Purpose:
--   Assign some inactive accounts to paid/closed statuses.
--
-- Why this exists:
--   A realistic portfolio should not contain only active and open derog accounts.
--   It should also contain:
--   - paid/closed current or near-current accounts
--   - paid post-derog accounts (61–65)
-- --------------------------------------------------------------------------------------------
closure_logic AS (
    SELECT
        pl.*,
        CASE
            WHEN active_flag = 0
             AND profile_type IN ('CURRENT','MILD','MOD')
             AND raw_seed % 100 < 45
            THEN '13'

            WHEN active_flag = 0
             AND profile_type = 'DEROG'
             AND raw_seed % 100 < 55
            THEN CASE derog_code
                     WHEN 'J' THEN '61'
                     WHEN 'G' THEN '62'
                     WHEN 'K' THEN '63'
                     WHEN 'L' THEN '64'
                     WHEN 'H' THEN '65'
                     ELSE NULL
                 END

            ELSE NULL
        END AS close_status_code
    FROM profile_logic pl
),

-- --------------------------------------------------------------------------------------------
-- CTE: pattern_strings
-- Purpose:
--   Assign a behavior pattern string per account.
--
-- Why this exists:
--   This is the core behavioral logic of the generator.
--   Instead of generating month-to-month states independently, we use valid pattern strings
--   so transitions remain logical.
--
-- SQL mechanics:
--   - Each pattern string is ordered from most recent month to older months
--   - Later we "place" that pattern into the account timeline
-- --------------------------------------------------------------------------------------------
pattern_strings AS (
    SELECT
        account,
        profile_type,
        active_flag,
        behavior_variant,
        has_suppression,
        suppression_start_age,
        derog_code,
        raw_seed,
        months_reporting_raw,
        close_status_code,
        CASE
            WHEN profile_type = 'REVERSED_MAJOR_DEROG'
                THEN '012345' || derog_code || '543210'

            WHEN close_status_code = '13' THEN
                CASE
                    WHEN behavior_variant < 70 THEN '0'
                    WHEN behavior_variant < 90 THEN '010'
                    ELSE '01210'
                END

            WHEN close_status_code IN ('61','62','63','64','65') THEN
                REPEAT(
                    CASE close_status_code
                        WHEN '61' THEN 'J'
                        WHEN '62' THEN 'G'
                        WHEN '63' THEN 'K'
                        WHEN '64' THEN 'L'
                        WHEN '65' THEN 'H'
                    END,
                    1 + LEAST(raw_seed % 4, 3)
                ) || '6543210'

            WHEN profile_type = 'CURRENT' THEN
                CASE
                    WHEN behavior_variant < 92 THEN '0'
                    WHEN behavior_variant < 98 THEN '010'
                    ELSE '01210'
                END

            WHEN profile_type = 'MILD' THEN
                CASE
                    WHEN behavior_variant < 30 THEN '10'
                    WHEN behavior_variant < 55 THEN '110'
                    WHEN behavior_variant < 75 THEN '210'
                    WHEN behavior_variant < 90 THEN '010'
                    ELSE '01210'
                END

            WHEN profile_type = 'MOD' THEN
                CASE
                    WHEN behavior_variant < 45 THEN '3210'
                    WHEN behavior_variant < 80 THEN '43210'
                    ELSE '0123210'
                END

            WHEN profile_type = 'SEVERE' THEN
                CASE
                    WHEN behavior_variant < 55 THEN '543210'
                    ELSE '6543210'
                END

            WHEN profile_type = 'DEROG' THEN
                REPEAT(
                    derog_code,
                    1 + LEAST(raw_seed % 5, 4)
                ) || '6543210'
        END AS pattern_string
    FROM closure_logic
),

-- --------------------------------------------------------------------------------------------
-- CTE: pattern_meta
-- Purpose:
--   Derive metadata about each pattern:
--   - pattern length
--   - mode (NONE / ACTIVE / CURED / CLOSED)
--   - clean runway requirement
--
-- Why this exists:
--   Some patterns must be pushed farther back in time so the latest month is current.
--   We also require clean history behind adverse ramps to avoid unrealistic thin-file behavior.
-- --------------------------------------------------------------------------------------------
pattern_meta AS (
    SELECT
        account,
        profile_type,
        active_flag,
        behavior_variant,
        has_suppression,
        suppression_start_age,
        derog_code,
        raw_seed,
        months_reporting_raw,
        close_status_code,
        pattern_string,
        LENGTH(pattern_string) AS pattern_length,
        CASE
            WHEN profile_type = 'REVERSED_MAJOR_DEROG' THEN 'CURED'
            WHEN close_status_code IS NOT NULL THEN 'CLOSED'
            WHEN profile_type IN ('SEVERE', 'DEROG') THEN 'ACTIVE'
            WHEN profile_type IN ('CURRENT','MILD','MOD')
                 AND pattern_string IN ('010','01210','0123210')
            THEN 'CURED'
            WHEN pattern_string = '0' THEN 'NONE'
            ELSE 'ACTIVE'
        END AS pattern_mode,
        CASE
            WHEN pattern_string = '0' THEN 0
            WHEN pattern_string IN ('10','110','010') THEN 2
            WHEN pattern_string IN ('210','01210') THEN 3
            WHEN pattern_string IN ('3210') THEN 3
            WHEN pattern_string IN ('43210','0123210') THEN 4
            WHEN pattern_string IN ('543210') THEN 5
            WHEN pattern_string IN ('6543210') THEN 6
            WHEN profile_type = 'REVERSED_MAJOR_DEROG' THEN 6
            ELSE 6
        END AS clean_runway
    FROM pattern_strings
),

-- --------------------------------------------------------------------------------------------
-- CTE: fitted
-- Purpose:
--   Force enough reporting history to fit the pattern and required clean runway.
--
-- Why this exists:
--   Without this, you get unrealistic cases where the oldest reported month is already deeply delinquent.
--
-- SQL mechanics:
--   - GREATEST ensures the account is old enough to fit:
--         pattern_length + clean_runway
--   - LEAST caps history at 84 months
-- --------------------------------------------------------------------------------------------
fitted AS (
    SELECT
        account,
        profile_type,
        active_flag,
        behavior_variant,
        has_suppression,
        suppression_start_age,
        derog_code,
        raw_seed,
        months_reporting_raw,
        close_status_code,
        pattern_string,
        pattern_length,
        pattern_mode,
        clean_runway,
        LEAST(
            GREATEST(months_reporting_raw, pattern_length + clean_runway),
            84
        ) AS months_reporting
    FROM pattern_meta
),

-- --------------------------------------------------------------------------------------------
-- CTE: dated
-- Purpose:
--   Assign account-level start and end dates.
--
-- Why this exists:
--   Real portfolios are panel data. Accounts do not all start and stop on the same timeline.
--
-- SQL mechanics:
--   - active accounts end at the anchor date
--   - inactive accounts stop at a deterministic earlier date
-- --------------------------------------------------------------------------------------------
dated AS (
    SELECT
        account,
        profile_type,
        active_flag,
        behavior_variant,
        has_suppression,
        suppression_start_age,
        derog_code,
        raw_seed,
        months_reporting_raw,
        close_status_code,
        pattern_string,
        pattern_length,
        pattern_mode,
        clean_runway,
        months_reporting,
        CASE
            WHEN active_flag = 1 THEN DATE '2025-10-01'
            ELSE (DATE '2025-10-01' - ((1 + (account * 13 % 42)) * INTERVAL '1 month'))::date
        END AS end_date
    FROM fitted
),

-- --------------------------------------------------------------------------------------------
-- CTE: blueprint
-- Purpose:
--   Finalize the account-level blueprint table.
--
-- Why this exists:
--   This is the one-row-per-account design table used by downstream steps.
--
-- SQL mechanics:
--   - start_date is derived from end_date and months_reporting
--   - date_closed is populated only for closed-status accounts
--   - episode_start_age controls where the pattern is placed in the time series
-- --------------------------------------------------------------------------------------------
blueprint AS (
    SELECT
        account,
        profile_type,
        active_flag,
        months_reporting,
        (end_date - ((months_reporting - 1) * INTERVAL '1 month'))::date AS start_date,
        end_date,
        CASE WHEN close_status_code IS NOT NULL THEN end_date ELSE NULL END AS date_closed,
        close_status_code,
        has_suppression,
        suppression_start_age,
        derog_code,
        pattern_string,
        pattern_length,
        pattern_mode,
        clean_runway,
        CASE
            WHEN pattern_mode = 'NONE' THEN 0
            WHEN pattern_mode = 'ACTIVE' THEN 0
            WHEN profile_type = 'REVERSED_MAJOR_DEROG' THEN 0
            WHEN close_status_code IS NOT NULL THEN 0
            ELSE raw_seed % GREATEST(months_reporting - pattern_length - clean_runway + 1, 1)
        END AS episode_start_age
    FROM dated
)
SELECT
    account,
    profile_type,
    active_flag,
    months_reporting,
    start_date,
    end_date,
    date_closed,
    close_status_code,
    has_suppression,
    suppression_start_age,
    derog_code,
    pattern_string,
    pattern_length,
    pattern_mode,
    clean_runway,
    episode_start_age
FROM blueprint
ORDER BY account;

CREATE INDEX ix_blueprint_account ON metro2_account_blueprint (account);


-- ====================================================================================================
-- SECTION 5: BUILD MONTH-LEVEL STATUS HISTORY
-- ====================================================================================================
-- Purpose:
--   Create the central month-level truth table:
--      metro2_status_history(account, byte_date, perf_age, status)
--
-- Why this exists:
--   This is the biggest Version 2 optimization.
--   Instead of deriving everything from PHP repeatedly, we calculate month-level history once.
--
-- SQL mechanics:
--   - generate_series(start_date - 1 month, end_date - 1 month, 1 month)
--     creates each represented performance month
--   - ROW_NUMBER ordered descending by byte_date creates perf_age:
--       0 = most recent represented month
--       1 = one month older
--   - pattern placement uses perf_age and episode_start_age
-- ====================================================================================================
CREATE TABLE metro2_status_history AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: performance_months
-- Purpose:
--   Create one row per account per represented month.
-- --------------------------------------------------------------------------------------------
performance_months AS (
    SELECT
        a.account,
        a.profile_type,
        a.start_date,
        a.end_date,
        a.pattern_string,
        a.pattern_length,
        a.pattern_mode,
        a.episode_start_age,
        a.has_suppression,
        a.suppression_start_age,
        gs::date AS byte_date,
        ROW_NUMBER() OVER (
            PARTITION BY a.account
            ORDER BY gs DESC
        ) - 1 AS perf_age
    FROM metro2_account_blueprint a
    CROSS JOIN LATERAL generate_series(
        a.start_date - INTERVAL '1 month',
        a.end_date   - INTERVAL '1 month',
        INTERVAL '1 month'
    ) AS gs
),

-- --------------------------------------------------------------------------------------------
-- CTE: status_history_raw
-- Purpose:
--   Translate each account’s pattern string into raw month-level statuses.
--
-- SQL mechanics:
--   - If the account has no meaningful pattern, assign 0
--   - If perf_age falls inside the pattern window, pull the corresponding character
--     from pattern_string using SUBSTRING
--   - Otherwise assign 0
-- --------------------------------------------------------------------------------------------
status_history_raw AS (
    SELECT
        p.account,
        p.byte_date,
        p.perf_age,
        CASE
            WHEN p.pattern_mode = 'NONE' THEN '0'
            WHEN p.perf_age BETWEEN p.episode_start_age
                               AND     p.episode_start_age + p.pattern_length - 1
            THEN SUBSTRING(
                    p.pattern_string
                    FROM ((p.perf_age - p.episode_start_age + 1)::int)
                    FOR 1
                 )
            ELSE '0'
        END AS status,
        p.has_suppression,
        p.suppression_start_age
    FROM performance_months p
)

-- --------------------------------------------------------------------------------------------
-- Final SELECT for metro2_status_history
-- Purpose:
--   Overlay suppression after raw pattern logic is created.
--
-- Why this exists:
--   Suppression is a visibility treatment layered on top of behavioral state.
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    byte_date,
    perf_age,
    CASE
        WHEN has_suppression = 1
         AND perf_age BETWEEN suppression_start_age AND suppression_start_age + 1
        THEN 'D'
        ELSE status
    END AS status
FROM status_history_raw
ORDER BY account, byte_date DESC;

CREATE INDEX ix_status_history_account_byte_date
    ON metro2_status_history (account, byte_date DESC);


-- ====================================================================================================
-- SECTION 6: BUILD LONGITUDINAL SNAPSHOT TABLE
-- ====================================================================================================
-- Purpose:
--   Create the synthetic ingestion dataset:
--      account, date_of_account_information, php
--
-- Why this exists:
--   This mimics the kind of monthly tradeline snapshot input your later remediation module will use.
--
-- SQL mechanics:
--   - snapshot_rows creates each account’s DOAI timeline
--   - snapshot_bytes expands each DOAI into 24 represented byte months
--   - LEFT JOIN to metro2_status_history pulls the month-level status if it exists
--   - COALESCE(..., 'B') fills missing older months with B
--   - STRING_AGG assembles the 24 bytes into one PHP string
-- ====================================================================================================
CREATE TABLE metro2_sample AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: snapshot_rows
-- Purpose:
--   Create one row per account per DOAI.
-- --------------------------------------------------------------------------------------------
snapshot_rows AS (
    SELECT
        a.account,
        gs::date AS date_of_account_information
    FROM metro2_account_blueprint a
    CROSS JOIN LATERAL generate_series(
        a.start_date,
        a.end_date,
        INTERVAL '1 month'
    ) AS gs
),

-- --------------------------------------------------------------------------------------------
-- CTE: snapshot_bytes
-- Purpose:
--   Expand each DOAI into 24 PHP byte positions.
--
-- SQL mechanics:
--   - generate_series(1,24) creates the 24 byte positions
--   - byte_date = DOAI - pos months
--   - because byte 1 is one month prior to DOAI in this project
-- --------------------------------------------------------------------------------------------
snapshot_bytes AS (
    SELECT
        s.account,
        s.date_of_account_information,
        pos,
        (s.date_of_account_information - (pos * INTERVAL '1 month'))::date AS byte_date
    FROM snapshot_rows s
    CROSS JOIN generate_series(1, 24) AS pos
)

-- --------------------------------------------------------------------------------------------
-- Final SELECT for metro2_sample
-- Purpose:
--   Assemble a 24-byte PHP for every account / DOAI row.
--
-- SQL mechanics:
--   - LEFT JOIN finds the underlying month-level status
--   - COALESCE fills missing history with B
--   - STRING_AGG(... ORDER BY pos) assembles bytes from left to right
-- --------------------------------------------------------------------------------------------
SELECT
    b.account,
    b.date_of_account_information,
    STRING_AGG(COALESCE(h.status, 'B'), '' ORDER BY b.pos) AS php
FROM snapshot_bytes b
LEFT JOIN metro2_status_history h
    ON h.account = b.account
   AND h.byte_date = b.byte_date
GROUP BY b.account, b.date_of_account_information
ORDER BY b.account, b.date_of_account_information DESC;

CREATE INDEX ix_sample_account_doai
    ON metro2_sample (account, date_of_account_information DESC);


-- ====================================================================================================
-- SECTION 7: BUILD FINAL ACCOUNT-LEVEL OUTPUT
-- ====================================================================================================
-- Purpose:
--   Produce one row per account with stitched history and latest-state Metro 2 fields.
--
-- Why this exists:
--   This is the main output table for downstream review and future remediation modules.
--
-- Major improvement vs Version 1:
--   We derive this table directly from metro2_status_history rather than re-exploding metro2_sample.
-- ====================================================================================================
CREATE TABLE metro2_final AS
WITH
-- --------------------------------------------------------------------------------------------
-- CTE: latest_status
-- Purpose:
--   Find the most recent represented status byte for each account.
--
-- SQL mechanics:
--   - DISTINCT ON (account) keeps only the first row per account
--   - ORDER BY account, byte_date DESC ensures the first row is the newest byte_date
-- --------------------------------------------------------------------------------------------
latest_status AS (
    SELECT DISTINCT ON (account)
        account,
        byte_date AS php_left_byte_date,
        status AS latest_byte
    FROM metro2_status_history
    ORDER BY account, byte_date DESC
),

-- --------------------------------------------------------------------------------------------
-- CTE: full_timeline
-- Purpose:
--   Stitch each account’s full month-level history into one long PHP-like string.
--
-- Why this exists:
--   This gives a deduplicated, most-recently-reported timeline for each account.
-- --------------------------------------------------------------------------------------------
full_timeline AS (
    SELECT
        account,
        STRING_AGG(status, '' ORDER BY byte_date DESC) AS full_php,
        MAX(byte_date) AS php_left_byte_date,
        MIN(byte_date) AS php_right_byte_date
    FROM metro2_status_history
    GROUP BY account
),

-- --------------------------------------------------------------------------------------------
-- CTE: latest_doai
-- Purpose:
--   Define the latest reporting date per account.
--
-- Why this exists:
--   In this module, latest_doai aligns to the blueprint end_date.
-- --------------------------------------------------------------------------------------------
latest_doai AS (
    SELECT
        account,
        end_date AS latest_doai
    FROM metro2_account_blueprint
),

-- --------------------------------------------------------------------------------------------
-- CTE: ordered_status
-- Purpose:
--   Create a sequence over each account’s month-level history for DOFD analysis.
--
-- Why this exists:
--   To derive a simple current adverse run, we need to identify the contiguous adverse segment
--   from the most recent month backward until a non-adverse month appears.
--
-- SQL mechanics:
--   - ROW_NUMBER creates a descending sequence
--   - SUM(CASE...) as a window function counts non-adverse months seen so far
--   - while non_adverse_seen = 0, we are still inside the initial adverse run
-- --------------------------------------------------------------------------------------------
ordered_status AS (
    SELECT
        h.account,
        h.byte_date,
        h.status,
        ROW_NUMBER() OVER (PARTITION BY h.account ORDER BY h.byte_date DESC) AS seq,
        SUM(
            CASE
                WHEN h.status NOT IN ('1','2','3','4','5','6','G','H','J','K','L')
                THEN 1 ELSE 0
            END
        ) OVER (
            PARTITION BY h.account
            ORDER BY h.byte_date DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS non_adverse_seen
    FROM metro2_status_history h
),

-- --------------------------------------------------------------------------------------------
-- CTE: current_adverse_run
-- Purpose:
--   Find the first delinquency date inside the current contiguous adverse run.
--
-- Important methodology note:
--   This is a simplified synthetic DOFD logic for a learning module.
--   It is not a full production furnishing engine.
--
-- SQL mechanics:
--   - Restrict to rows where non_adverse_seen = 0
--     meaning we have not yet encountered a current/non-adverse break
--   - Among those rows, take the oldest delinquency byte_date (MIN byte_date)
-- --------------------------------------------------------------------------------------------
current_adverse_run AS (
    SELECT
        account,
        MIN(byte_date) FILTER (WHERE status IN ('1','2','3','4','5','6')) AS date_of_first_delinquency
    FROM ordered_status
    WHERE non_adverse_seen = 0
    GROUP BY account
),

-- --------------------------------------------------------------------------------------------
-- CTE: joined
-- Purpose:
--   Bring together all intermediate pieces needed for the final select.
-- --------------------------------------------------------------------------------------------
joined AS (
    SELECT
        b.account,
        b.profile_type,
        d.latest_doai,
        b.date_closed,
        f.full_php,
        f.php_left_byte_date,
        f.php_right_byte_date,
        l.latest_byte,
        c.date_of_first_delinquency,
        b.close_status_code
    FROM metro2_account_blueprint b
    JOIN latest_doai d USING (account)
    JOIN full_timeline f USING (account)
    JOIN latest_status l USING (account)
    LEFT JOIN current_adverse_run c USING (account)
)

-- --------------------------------------------------------------------------------------------
-- Final SELECT for metro2_final
-- Purpose:
--   Map the latest state into Metro 2-like final fields.
--
-- Business logic:
--   - close_status_code takes precedence over latest_byte when the account is closed
--   - payment rating uses synthetic conventions from this module
--   - DOFD only appears for currently adverse non-closed accounts
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    profile_type,
    latest_doai,
    date_closed,
    full_php,
    php_left_byte_date,
    php_right_byte_date,

    CASE
        WHEN close_status_code IS NOT NULL THEN close_status_code
        ELSE
            CASE latest_byte
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
    END AS account_status_17A,

    CASE
        WHEN close_status_code = '13' THEN '0'
        WHEN close_status_code IN ('61','62','63','64','65') THEN NULL
        ELSE
            CASE latest_byte
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
    END AS payment_rating_17B,

    CASE
        WHEN close_status_code IS NOT NULL THEN NULL
        WHEN latest_byte IN ('1','2','3','4','5','6','G','H','J','K','L')
        THEN date_of_first_delinquency
        ELSE NULL
    END AS date_of_first_delinquency

FROM joined
ORDER BY account;

CREATE INDEX ix_final_account
    ON metro2_final (account);


-- ====================================================================================================
-- SECTION 8: QA / REVIEW QUERIES
-- ====================================================================================================
-- Purpose:
--   Provide inspection queries for learning, validation, screenshots, and walkthroughs.
--
-- Why this exists:
--   Now that this script is running locally, it is practical to keep the QA in the same file.
--
-- Teaching note:
--   These queries do not build new artifacts. They help the user inspect what was built.
-- ====================================================================================================

-- --------------------------------------------------------------------------------------------
-- QA 1: Echo the user parameters
-- Why:
--   Confirms the configured sample size and portfolio mix used for the run
-- --------------------------------------------------------------------------------------------
SELECT * FROM module1_params;

-- --------------------------------------------------------------------------------------------
-- QA 2: Review the resulting profile mix
-- Why:
--   Helps confirm the generated population roughly aligns with the requested portfolio mix
-- SQL mechanics:
--   GROUP BY profile_type counts accounts by profile bucket
-- --------------------------------------------------------------------------------------------
SELECT
    profile_type,
    COUNT(*) AS account_count
FROM metro2_account_blueprint
GROUP BY profile_type
ORDER BY profile_type;

-- --------------------------------------------------------------------------------------------
-- QA 3: Review closed-status mix
-- Why:
--   Confirms that both open and closed-status scenarios were generated
-- SQL mechanics:
--   COALESCE replaces NULL with 'OPEN' for reporting convenience
-- --------------------------------------------------------------------------------------------
SELECT
    COALESCE(close_status_code, 'OPEN') AS close_status_code,
    COUNT(*) AS account_count
FROM metro2_account_blueprint
GROUP BY COALESCE(close_status_code, 'OPEN')
ORDER BY close_status_code;

-- --------------------------------------------------------------------------------------------
-- QA 4: Sample month-level status history
-- Why:
--   Lets users inspect the computational backbone directly
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_status_history
ORDER BY account, byte_date DESC
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 5: Sample longitudinal snapshot rows
-- Why:
--   Lets users inspect the synthetic input table account / DOAI / PHP
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_sample
ORDER BY account, date_of_account_information DESC
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 6: Sample final output rows
-- Why:
--   Lets users inspect the main deliverable of Module 1
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_final
ORDER BY account
LIMIT 100;

-- --------------------------------------------------------------------------------------------
-- QA 7: Review paid / closed examples
-- Why:
--   Specifically surfaces statuses 13 and 61–65
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_final
WHERE account_status_17A IN ('13','61','62','63','64','65')
ORDER BY account
LIMIT 50;

-- --------------------------------------------------------------------------------------------
-- QA 8: Review reversed-major-derog examples
-- Why:
--   Surfaces the rare remediation-style scenario included in the synthetic population
-- --------------------------------------------------------------------------------------------
SELECT *
FROM metro2_final
WHERE profile_type = 'REVERSED_MAJOR_DEROG'
ORDER BY account;

-- --------------------------------------------------------------------------------------------
-- QA 9: Count final accounts by latest 17A status
-- Why:
--   Gives a quick top-line view of the latest-state status distribution
-- --------------------------------------------------------------------------------------------
SELECT
    account_status_17A,
    COUNT(*) AS account_count
FROM metro2_final
GROUP BY account_status_17A
ORDER BY account_status_17A;

-- --------------------------------------------------------------------------------------------
-- QA 10: Inspect currently adverse latest-state accounts
-- Why:
--   Useful for reviewing consistency among:
--      - account_status_17A
--      - payment_rating_17B
--      - DOFD
--      - full_php
-- --------------------------------------------------------------------------------------------
SELECT
    account,
    profile_type,
    account_status_17A,
    payment_rating_17B,
    date_of_first_delinquency,
    full_php
FROM metro2_final
WHERE account_status_17A IN ('71','78','80','82','83','84','93','94','95','96','97')
ORDER BY account
LIMIT 100;
