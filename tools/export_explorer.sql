-- One read-only SELECT; every count and record shares a PostgreSQL statement snapshot.
-- The browser population consists of every Module 2 final account. The larger
-- blueprint is counted separately. Its matching IDs do not prove shared run lineage.
WITH monthly AS (
    SELECT d.account,
           json_agg(json_build_array(d.byte_date, d.original_status, d.remediated_status,
                                     d.is_within_credit_impact_window)
                    ORDER BY d.byte_date DESC) AS months,
           min(d.remediation_treatment) AS min_treatment,
           max(d.remediation_treatment) AS max_treatment
    FROM module2.metro2_remediation_php_detail AS d
    GROUP BY d.account
), accounts AS (
    SELECT f.account, f.profile_type, f.latest_doai, f.date_closed, f.full_php,
           f.php_left_byte_date, f.php_right_byte_date, f.account_status_17a,
           f.payment_rating_17b, f.date_of_first_delinquency, f.impact_start_date,
           f.impact_end_date, f.credit_impact_start_date, f.credit_impact_end_date,
           f.credit_cure_date, f.cure_consecutive_months_required, f.manual_review_flag,
           f.manual_review_reason, f.remediation_treatment, f.remediated_full_php,
           f.remediated_account_status_17a, f.remediated_payment_rating_17b,
           f.remediated_date_of_first_delinquency,
           -- Legacy snapshots stored only sparse overrides. Their missing clear
           -- actions remain NULL, while the revised engine emits explicit booleans.
           (to_jsonb(f)->>'clear_account_status_17a')::boolean AS clear_account_status_17a,
           (to_jsonb(f)->>'clear_payment_rating_17b')::boolean AS clear_payment_rating_17b,
           (to_jsonb(f)->>'clear_date_of_first_delinquency')::boolean AS clear_date_of_first_delinquency,
           to_jsonb(f)->>'account_field_policy' AS account_field_policy,
           to_jsonb(f)->>'account_field_review_reason' AS account_field_review_reason,
           f.remediation_applied_flag,
           f.remediation_fields_modified, e.post_impact_month_count, e.has_derog_in_credit_window,
           e.has_delinquency_in_credit_window, e.has_post_derog_recovery_evidence,
           -- Retained spring databases predate the charge-off indicator. A missing
           -- column exports as NULL so these histories remain available to the explorer.
           (to_jsonb(e)->>'has_chargeoff_in_credit_window')::integer AS has_chargeoff_in_credit_window,
           (to_jsonb(e)->>'last_severe_month')::date AS last_severe_month,
           (to_jsonb(e)->>'severe_reversal_month')::date AS severe_reversal_month,
           to_jsonb(e)->>'remediation_policy' AS remediation_policy, m.months,
           CASE WHEN b.account IS NULL THEN 'missing'
                WHEN ROW(b.profile_type, b.end_date, b.date_closed, b.months_reporting)
                   IS NOT DISTINCT FROM ROW(f.profile_type, f.latest_doai, f.date_closed, length(f.full_php))
                THEN 'matching fields' ELSE 'different fields' END AS blueprint_alignment,
           i.account IS NOT NULL AND e.account IS NOT NULL AND m.account IS NOT NULL
           AND ROW(i.impact_start_date, i.impact_end_date, m.min_treatment, m.max_treatment)
               IS NOT DISTINCT FROM ROW(f.impact_start_date, f.impact_end_date,
                                        f.remediation_treatment, f.remediation_treatment)
           AND ROW(e.profile_type, e.latest_doai, e.date_closed, e.full_php, e.php_left_byte_date,
                   e.php_right_byte_date, e.account_status_17a, e.payment_rating_17b,
                   e.date_of_first_delinquency, e.impact_start_date, e.impact_end_date,
                   e.credit_impact_start_date, e.credit_impact_end_date, e.credit_cure_date,
                   e.cure_consecutive_months_required, e.manual_review_flag,
                   e.manual_review_reason, e.remediation_treatment)
               IS NOT DISTINCT FROM
               ROW(f.profile_type, f.latest_doai, f.date_closed, f.full_php, f.php_left_byte_date,
                   f.php_right_byte_date, f.account_status_17a, f.payment_rating_17b,
                   f.date_of_first_delinquency, f.impact_start_date, f.impact_end_date,
                   f.credit_impact_start_date, f.credit_impact_end_date, f.credit_cure_date,
                   f.cure_consecutive_months_required, f.manual_review_flag,
                   f.manual_review_reason, f.remediation_treatment) AS sources_agree
    FROM module2.metro2_remediation_final AS f
    LEFT JOIN module2.metro2_remediation_input AS i USING (account)
    LEFT JOIN module2.metro2_remediation_window_eval AS e USING (account)
    LEFT JOIN monthly AS m USING (account)
    LEFT JOIN module1.metro2_account_blueprint AS b USING (account)
), records AS (
    SELECT 0 AS sort_group, NULL::bigint AS account,
           json_build_object(
               'formatVersion', 1,
               'hasDecisionPolicyColumn', (SELECT to_jsonb(e) ? 'remediation_policy' FROM module2.metro2_remediation_window_eval e ORDER BY e.account LIMIT 1),
               'hasFieldPolicyColumn', (SELECT to_jsonb(f) ? 'account_field_policy' FROM module2.metro2_remediation_final f ORDER BY f.account LIMIT 1),
               'databasePolicy', (SELECT to_jsonb(e)->>'remediation_policy'
                                  FROM module2.metro2_remediation_window_eval e ORDER BY e.account LIMIT 1),
               'accountFieldPolicy', (SELECT to_jsonb(f)->>'account_field_policy'
                                      FROM module2.metro2_remediation_final f ORDER BY f.account LIMIT 1),
               'database', current_database(),
               'postgresVersion', current_setting('server_version'),
               'snapshotUTC', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'blueprintCount', (SELECT count(*) FROM module1.metro2_account_blueprint),
               'inputCount', (SELECT count(*) FROM module2.metro2_remediation_input),
               'evaluationCount', (SELECT count(*) FROM module2.metro2_remediation_window_eval),
               'accountCount', (SELECT count(*) FROM module2.metro2_remediation_final),
               'monthCount', (SELECT count(*) FROM module2.metro2_remediation_php_detail)
           ) AS row_json
    UNION ALL
    SELECT 1, a.account, row_to_json(a) FROM accounts AS a
)
SELECT row_json FROM records ORDER BY sort_group, account;
