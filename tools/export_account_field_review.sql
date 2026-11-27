-- Read the successor's account-field referrals independently of its cure and
-- missing-Field-25 worklists. This query requires the evidence-scoped schema.
WITH referrals AS (
SELECT account,
       account_field_policy,
       account_field_review_reason,
       latest_doai AS reporting_as_of,
       php_left_byte_date AS latest_history_month,
       impact_start_date AS bank_impact_start,
       impact_end_date AS bank_impact_end,
       credit_impact_start_date AS credit_impact_start,
       credit_impact_end_date AS credit_impact_through,
       credit_cure_date AS cure_start,
       remediation_treatment AS proposed_treatment,
       account_status_17a AS original_status_17a,
       payment_rating_17b AS original_internal_rating,
       date_of_first_delinquency AS original_dofd,
       CASE WHEN NOT clear_account_status_17a THEN coalesce(remediated_account_status_17a,account_status_17a) END AS proposed_status_17a,
       CASE WHEN NOT clear_payment_rating_17b THEN coalesce(remediated_payment_rating_17b,payment_rating_17b) END AS proposed_internal_rating,
       CASE WHEN NOT clear_date_of_first_delinquency THEN coalesce(remediated_date_of_first_delinquency,date_of_first_delinquency) END AS proposed_dofd,
       manual_review_flag AS bank_cure_review_flag
FROM module2.metro2_remediation_final
WHERE account_field_review_reason IS NOT NULL
)
SELECT r.*,
       CASE
           WHEN proposed_status_17a IN ('05','13','65','88','89','94','95')
                AND nullif(btrim(proposed_internal_rating),'') IS NULL
               THEN 'Obtain the payment rating and its supporting servicing records. Reassess Field 25 with the verified rating and status.'
           ELSE 'Reconcile the dated onset, performance history, closure and as-of fields with servicing records before changing an account field.'
       END AS servicing_next_step,
       CASE
           WHEN proposed_status_17a IN ('05','13') AND nullif(btrim(proposed_internal_rating),'') IS NULL
               THEN 'CONDITIONAL_ON_MISSING_RATING'
           WHEN proposed_status_17a IN ('61','62','63','64','65','71','78','80','82','83','84','88','89','93','94','95','96','97')
               THEN CASE WHEN proposed_dofd IS NULL THEN 'REQUIRED_BY_STATUS_DATE_ABSENT' ELSE 'REQUIRED_BY_STATUS_DATE_PRESENT' END
           ELSE 'RECONCILE_RETAINED_FIELD_BASIS'
       END AS field25_review_scope
FROM referrals AS r
ORDER BY account;
