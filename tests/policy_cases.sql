-- Each original and expected history is ordered oldest first; its first month is January 2020.
-- IDs pick the given bank-issue dates through the engine's ordinary deterministic incident generator.
-- Fixed expectations use REVERSAL_AWARE_SEVERE_V2. A later original 0–6 reverses the latest
-- in-window severe event. The separate post-bank current-month threshold establishes cure.
CREATE SCHEMA regression;
CREATE TABLE regression.policy_cases (
    account int PRIMARY KEY,
    case_name text NOT NULL,
    original text NOT NULL,
    bank_start date NOT NULL,
    bank_end date NOT NULL,
    treatment text NOT NULL,
    cure date,
    review_reason text,
    revised text NOT NULL
);
INSERT INTO regression.policy_cases VALUES
    (10029, 'chargeoff during bank issue with later late codes', '01L54321', '2020-02-01', '2020-03-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', '0DDDDDDD'),
    (20010, 'chargeoff after bank end with one current month', '120L210', '2020-01-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DD0DDD0'),
    (30004, 'earlier window chargeoff followed by another major and numeric', 'LJ110', '2020-01-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDDD0'),
    (40003, 'chargeoff without a later numerical status', '12LL', '2020-01-01', '2020-04-01', 'TRADELINE_DELETION', NULL, NULL, '12LL'),
    (50030, 'two current months short of cure after a chargeoff', '2L00', '2020-01-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'INSUFFICIENT_POST_IMPACT_HISTORY', 'DD00'),
    (60003, 'confirmed cure after chargeoff during bank issue', '03L1000', '2020-02-01', '2020-03-01', 'FULL_DEROGATORY_PHP_CLEANUP', '2020-05-01', NULL, '0DDD000'),
    (70044, 'confirmed cure following chargeoff after bank end', '12L000', '2020-01-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', '2020-04-01', NULL, 'DDD000'),
    (80010, 'chargeoff before impact only', 'L120', '2020-02-01', '2020-03-01', 'SIMPLE_DELINQUENCY_PHP_CLEANUP', NULL, 'INSUFFICIENT_POST_IMPACT_HISTORY', 'LDD0'),
    (90044, 'chargeoff after terminal window only', '11000L0', '2020-01-01', '2020-02-01', 'SIMPLE_DELINQUENCY_PHP_CLEANUP', '2020-03-01', NULL, 'DD000L0'),
    (100003, 'chargeoff before impact with new uncured J and later numeric', 'LJ120', '2020-02-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'LDDD0'),
    (110040, 'interrupted qualifying streak after chargeoff', 'L00100', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'D00D00'),
    (120082, 'interrupted streak followed by confirmed cure', 'L001000', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', '2020-05-01', NULL, 'D00D000'),
    (130090, 'first qualifying streak followed by a later deterioration', '1L00022L', '2020-01-01', '2020-02-01', 'FULL_DEROGATORY_PHP_CLEANUP', '2020-03-01', NULL, 'DD00022L'),
    (140007, 'clean evaluated window with outside chargeoff', 'L000', '2020-02-01', '2020-03-01', 'NO_IMPACT_CLEAN_PHP_HISTORY', NULL, NULL, 'L000'),
    (150010, 'no history (D) is not an original current month', 'L0D00', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'D0D00'),
    (160042, 'oldest leading no-prior-history B before delinquency and severe event', 'B1L00', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'BDD00'),
    (170086, 'open delinquency without observed cure', '21210', '2020-01-01', '2020-02-01', 'SIMPLE_DELINQUENCY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDDD0'),
    (180005, 'historical cleanup with latest original unavailable D', '1D', '2020-01-01', '2020-01-01', 'SIMPLE_DELINQUENCY_PHP_CLEANUP', NULL, 'INSUFFICIENT_POST_IMPACT_HISTORY', 'DD'),
    (190003, 'ordinary cleanup clears old DOFD when latest mark becomes current', '112', '2020-02-01', '2020-03-01', 'SIMPLE_DELINQUENCY_PHP_CLEANUP', NULL, 'INSUFFICIENT_POST_IMPACT_HISTORY', '1DD'),
    (200006, 'G with later numeric and no cure', 'G210', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDD0'),
    (210001, 'G with no later numeric', '12G', '2020-01-01', '2020-03-01', 'TRADELINE_DELETION', NULL, NULL, '12G'),
    (220017, 'H with later numeric and no cure', 'H210', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDD0'),
    (230000, 'H with no later numeric', '12H', '2020-01-01', '2020-03-01', 'TRADELINE_DELETION', NULL, NULL, '12H'),
    (240025, 'J with later numeric and no cure', 'J210', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDD0'),
    (250009, 'J with no later numeric', '12J', '2020-01-01', '2020-03-01', 'TRADELINE_DELETION', NULL, NULL, '12J'),
    (260028, 'K with later numeric and no cure', 'K210', '2020-01-01', '2020-01-01', 'FULL_DEROGATORY_PHP_CLEANUP', NULL, 'NO_CURE_OPEN_ACCOUNT', 'DDD0'),
    (270001, 'K with no later numeric', '12K', '2020-01-01', '2020-03-01', 'TRADELINE_DELETION', NULL, NULL, '12K');

-- Minimal generator contract for deliberately constructed histories (all accounts open).
CREATE SCHEMA module1;
CREATE TABLE module1.metro2_account_blueprint AS
SELECT account, original AS history FROM regression.policy_cases;

CREATE TABLE module1.metro2_status_history AS
SELECT f.account, (DATE '2020-01-01' + make_interval(months => pos - 1))::date AS byte_date,
       pos AS perf_age, substring(f.history, pos, 1) AS status
FROM module1.metro2_account_blueprint AS f
CROSS JOIN LATERAL generate_series(1, length(f.history)) AS pos;

CREATE TABLE module1.metro2_final AS
SELECT f.account, 'FIXTURE'::text AS profile_type,
       (DATE '2020-01-01' + make_interval(months => length(f.history)))::date AS latest_doai,
       NULL::date AS date_closed, reverse(f.history) AS full_php,
       (DATE '2020-01-01' + make_interval(months => length(f.history)-1))::date AS php_left_byte_date,
       DATE '2020-01-01' AS php_right_byte_date,
       CASE right(f.history, 1)
         WHEN '0' THEN '11' WHEN 'L' THEN '97' WHEN '2' THEN '78' ELSE '71'
       END AS account_status_17a,
       '0'::text AS payment_rating_17b,
       CASE WHEN f.history IN ('1D', '112') THEN DATE '2020-01-01' END AS date_of_first_delinquency
FROM module1.metro2_account_blueprint AS f;
