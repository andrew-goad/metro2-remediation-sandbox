-- Show the case name and actual/expected result on any regression.
DO $$
DECLARE
    mismatch record;
BEGIN
    FOR mismatch IN
        WITH actual AS (
            SELECT f.account, f.impact_start_date, f.impact_end_date, f.remediation_treatment,
                   f.credit_cure_date, f.manual_review_reason, f.manual_review_flag, f.remediated_full_php,
                   f.remediated_account_status_17a, f.remediated_payment_rating_17b,
                   f.remediated_date_of_first_delinquency, f.remediation_fields_modified,
                   (SELECT string_agg(m.remediated_status, '' ORDER BY m.byte_date)
                    FROM module2.metro2_remediation_php_detail AS m WHERE m.account=f.account) AS history
            FROM module2.metro2_remediation_final AS f
        )
        SELECT e.case_name, to_jsonb(e) AS expected, to_jsonb(a) AS observed
        FROM regression.policy_cases AS e
        FULL JOIN actual AS a USING (account)
        WHERE ROW(e.bank_start, e.bank_end, e.treatment, e.cure, e.review_reason,
                  (e.review_reason IS NOT NULL)::int, e.revised)
              IS DISTINCT FROM ROW(a.impact_start_date, a.impact_end_date, a.remediation_treatment,
                                   a.credit_cure_date, a.manual_review_reason, a.manual_review_flag, a.history)
           OR (e.treatment='TRADELINE_DELETION' AND
                  ROW(a.remediated_account_status_17a, a.remediation_fields_modified,
                      a.remediated_full_php, a.remediated_payment_rating_17b, a.remediated_date_of_first_delinquency)
                  IS DISTINCT FROM ROW('DA'::text, 'STATUS_ONLY'::text, NULL::text, NULL::text, NULL::date))
    LOOP
        RAISE EXCEPTION 'Regression in %: expected %, observed %', mismatch.case_name, mismatch.expected, mismatch.observed;
    END LOOP;
END $$;


-- Two fixed outcomes exercise an explicit set-to-NULL operation versus an omitted field.
DO $$
BEGIN
    IF EXISTS (
       SELECT 1 FROM regression.policy_cases e JOIN module2.metro2_remediation_final f USING (account)
       WHERE (e.original='1D' AND ROW(f.clear_account_status_17a, f.clear_payment_rating_17b,
                   f.clear_date_of_first_delinquency, f.remediation_fields_modified)
               IS DISTINCT FROM ROW(false, false, false, 'PHP_ONLY'::text))
          OR (e.original='112' AND ROW(f.clear_account_status_17a, f.clear_payment_rating_17b,
                   f.clear_date_of_first_delinquency, f.remediated_account_status_17a, f.remediated_date_of_first_delinquency)
               IS DISTINCT FROM ROW(false, false, true, '11'::text, NULL::date))
    ) THEN
        RAISE EXCEPTION 'Field-clear fixture mismatch';
    END IF;
END $$;
