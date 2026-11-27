-- Internal monthly case handoff for the revised synthetic study.
-- Use psql --csv to keep the column names even when the queue is empty.
-- Module 2 validates a complete, newest-first original PHP for each account.
WITH queue AS (
    SELECT f.*,
        to_jsonb(e)->>'remediation_policy' AS decision_policy,
        (to_jsonb(e)->>'last_severe_month')::date AS latest_severe,
        (to_jsonb(e)->>'severe_reversal_month')::date AS reversal_proxy,
        -- Old retained tables predate the explicit booleans. Extract optional fields
        -- by name so their absence stays visible to the reviewer.
        (to_jsonb(f)->>'clear_account_status_17a')::boolean AS status_clear,
        (to_jsonb(f)->>'clear_payment_rating_17b')::boolean AS rating_clear,
        (to_jsonb(f)->>'clear_date_of_first_delinquency')::boolean AS dofd_clear,
        (12 * (extract(year FROM f.php_left_byte_date) - extract(year FROM f.impact_end_date))
            + extract(month FROM f.php_left_byte_date) - extract(month FROM f.impact_end_date))::int
            AS post_impact_months
    FROM module2.metro2_remediation_final f
    LEFT JOIN module2.metro2_remediation_window_eval e USING (account)
    WHERE f.manual_review_flag = 1
),
progress AS (
    SELECT q.*,
        -- Only the newest uninterrupted original zeros strictly after bank impact count.
        -- Bounding the prefix prevents a zero in the final bank-impact month from counting.
        length(substring(left(q.full_php, q.post_impact_months) FROM '^0*')) AS current_streak_months
    FROM queue q
)
SELECT account,
    manual_review_reason AS review_reason,
    CASE
        WHEN status_clear IS NULL OR rating_clear IS NULL OR dofd_clear IS NULL
            THEN 'Review the legacy decision under the current study policy. A blank proposed field may be unknown where clear flags were unavailable. Verify the source before reassessing next month.'
        WHEN decision_policy IS DISTINCT FROM 'REVERSAL_AWARE_SEVERE_V2'
            THEN 'Review this archived decision against its original run receipt. Reassess the source months with the current severe-event policy.'
        WHEN remediation_treatment = 'FULL_DEROGATORY_PHP_CLEANUP'
            THEN format('Severe month %s. Reversal proxy %s. Verify the reversal in servicing records and reassess cure with the next original month.',
                        to_char(latest_severe, 'YYYY-MM'), to_char(reversal_proxy, 'YYYY-MM'))
        WHEN manual_review_reason = 'INSUFFICIENT_POST_IMPACT_HISTORY' THEN 'Collect the next original reporting month and reassess cure.'
        ELSE 'Review the unresolved impact and reassess cure with the next original reporting month.'
    END AS review_action,
    impact_start_date AS bank_impact_start,
    impact_end_date AS bank_impact_end,
    credit_impact_start_date AS credit_impact_start,
    credit_impact_end_date AS credit_impact_through,
    latest_doai AS reporting_as_of,
    php_left_byte_date AS latest_history_month,
    account_status_17a AS original_status_17a,
    full_php AS original_php_newest_first,
    post_impact_months,
    CASE WHEN current_streak_months > 0
         THEN (php_left_byte_date - (current_streak_months - 1) * interval '1 month')::date
    END AS current_streak_start,
    current_streak_months,
    cure_consecutive_months_required AS cure_months_required,
    (php_left_byte_date + interval '1 month')::date AS next_history_month,
    remediation_treatment AS proposed_treatment,
    remediated_full_php AS proposed_php_newest_first,
    CASE WHEN status_clear IS NULL OR rating_clear IS NULL OR dofd_clear IS NULL THEN 'UNAVAILABLE_IN_SOURCE'
         ELSE NULLIF(concat_ws(', ',
             CASE WHEN status_clear THEN '17A' END,
             CASE WHEN rating_clear THEN '17B' END,
             CASE WHEN dofd_clear THEN 'DOFD' END), '')
    END AS internal_fields_to_clear,
    payment_rating_17b AS original_payment_rating_17b,
    date_of_first_delinquency AS original_dofd,
    -- Keep both sides of each field decision with the offline case. A known clear
    -- takes precedence. A legacy row can support an explicit replacement, but a
    -- missing historical clear flag cannot establish retention of the original.
    CASE WHEN status_clear THEN NULL
         WHEN remediated_account_status_17a IS NOT NULL THEN remediated_account_status_17a
         WHEN status_clear IS FALSE THEN account_status_17a
    END AS proposed_effective_status_17a,
    CASE WHEN rating_clear THEN NULL
         WHEN remediated_payment_rating_17b IS NOT NULL THEN remediated_payment_rating_17b
         WHEN rating_clear IS FALSE THEN payment_rating_17b
    END AS proposed_effective_rating_17b,
    CASE WHEN dofd_clear THEN NULL
         WHEN remediated_date_of_first_delinquency IS NOT NULL THEN remediated_date_of_first_delinquency
         WHEN dofd_clear IS FALSE THEN date_of_first_delinquency
    END AS proposed_effective_dofd
FROM progress
ORDER BY next_history_month, account;
