-- Internal evidence review for retained tradelines in the revised study.
-- The historical 2020 CRRG, Base Segment Field 25, p. 4-16, specifies conditions
-- based on status and rating. Consumer Information Indicators and servicing due
-- dates are absent from this model. This query assesses only the represented
-- status/rating conditions; its output is not a complete furnishing validation.
-- https://autodealerplus.com/dealerzone/metro2.pdf#page=70
-- Status 05 is screened for historical records. CDIA retired it in April 2022:
-- https://www.cdiaonline.org/ondemand-retirement-of-account-status-05-transferred/
-- All dates are internal study dates. The query never supplies a missing date.
WITH retained AS (
    SELECT f.*,
        CASE WHEN NOT clear_account_status_17a
             THEN coalesce(remediated_account_status_17a, account_status_17a) END AS effective_status_17a,
        CASE WHEN NOT clear_payment_rating_17b
             THEN coalesce(remediated_payment_rating_17b, payment_rating_17b) END AS effective_rating_17b,
        CASE WHEN NOT clear_date_of_first_delinquency
             THEN coalesce(remediated_date_of_first_delinquency, date_of_first_delinquency) END AS effective_field25
    FROM module2.metro2_remediation_final f
    WHERE remediation_treatment <> 'TRADELINE_DELETION'
),
missing_dates AS (
    SELECT r.*,
        CASE
            WHEN effective_status_17a IN ('61','62','63','64','65','71','78','80','82',
                                          '83','84','88','89','93','94','95','96','97')
                THEN 'DATE_REQUIRED_BY_STATUS'
            WHEN effective_status_17a = '13' AND effective_rating_17b IN ('1','2','3','4','5','6','G','L')
                THEN 'DATE_REQUIRED_BY_STATUS_AND_RATING'
            WHEN effective_status_17a = '05' AND effective_rating_17b IN ('1','2','3','4','5','6','G','L')
                THEN 'DATE_REQUIRED_BY_HISTORICAL_05_AND_RATING'
        END AS exception_reason
    FROM retained r
    WHERE effective_field25 IS NULL
)
SELECT account,
    latest_doai AS reporting_as_of,
    php_left_byte_date AS latest_history_month,
    account_status_17a AS source_status_17a,
    payment_rating_17b AS source_rating_17b,
    date_of_first_delinquency AS source_field25,
    effective_status_17a,
    effective_rating_17b,
    effective_field25,
    exception_reason,
    CASE WHEN clear_date_of_first_delinquency THEN 'DATE_CLEARED_BY_PROPOSAL'
         ELSE 'DATE_ABSENT_IN_SOURCE' END AS date_evidence_gap,
    'Reconcile servicing due dates and payment records to verify the first 30-day delinquency leading to the reported condition.' AS proposed_action,
    impact_start_date AS bank_impact_start,
    impact_end_date AS bank_impact_end,
    credit_impact_start_date AS credit_impact_start,
    credit_impact_end_date AS credit_impact_through,
    credit_cure_date AS cure_start,
    (credit_cure_date + (cure_consecutive_months_required - 1) * interval '1 month')::date AS cure_confirmed_through,
    remediation_treatment AS proposed_treatment,
    manual_review_flag AS bank_cure_review_flag,
    manual_review_reason AS bank_cure_review_reason
FROM missing_dates
WHERE exception_reason IS NOT NULL
ORDER BY account;
