-- Independently reconstruct cure, qualifying credit-window events and treatment from original DATED performance.
-- REVERSAL_AWARE_SEVERE_V2: the first later original numeric after the latest in-window severe
-- event supports cleanup. Earlier schemas can be inspected; the pass receipt requires this policy
-- and its dated evidence fields. The original post-bank zero run separately defines cure.
-- Field decisions also require EVIDENCE_SCOPED_FIELDS_V2. Verify monthly symbols, clock, independent
-- source copies, preservation of current fields, positive elections, dated basis and servicing referrals.
-- Supply psql variables expected_accounts and required_months. The launcher defines
-- metro2_existing_snapshot only inside its existing repeatable-read handoff transaction.
\if :{?metro2_existing_snapshot}
\else
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
\endif
SET LOCAL statement_timeout = '12min';
SET LOCAL jit = off;
WITH settings AS (
    SELECT :expected_accounts::int AS expected_accounts, :required_months::int AS threshold
), original AS (
    SELECT h.account, min(h.byte_date) AS first_month, max(h.byte_date) AS last_month,
           count(*) AS nmonths, count(DISTINCT h.byte_date) AS ndates,
           bool_and(h.byte_date = date_trunc('month', h.byte_date)::date AND
                    h.byte_date IS NOT NULL) AS valid_keys,
           bool_and(coalesce(h.status ~ '^[0-6BDGHJKL]$',false)) AS valid_symbols,
           string_agg(h.status, '' ORDER BY h.byte_date DESC) AS original_php,
           string_agg(h.status, '' ORDER BY h.byte_date) FILTER (WHERE h.byte_date>i.impact_end_date) AS later_php,
           count(*) FILTER (WHERE h.byte_date>i.impact_end_date) AS later_count
    FROM module1.metro2_status_history h
    JOIN module2.metro2_remediation_input i USING (account)
    GROUP BY h.account
), first_streak AS (
    SELECT o.*, i.impact_start_date AS bank_start, i.impact_end_date AS bank_end,
           f.account_status_17a AS original_17a, f.payment_rating_17b AS original_17b,
           f.date_of_first_delinquency AS original_dofd,
           f.latest_doai AS source_doai, f.php_left_byte_date AS source_left, f.php_right_byte_date AS source_right,
           f.full_php AS summary_php, f.profile_type AS source_profile, f.date_closed AS source_closed_date,
           s.threshold, nullif(strpos(coalesce(o.later_php,''), repeat('0',s.threshold)),0) AS streak_offset,
           coalesce(f.account_status_17a IN ('13','61','62','63','64','65'), false) AS closed
    FROM original o JOIN module2.metro2_remediation_input i USING (account)
    JOIN module1.metro2_final f USING (account)
    CROSS JOIN settings s
), dated AS (
    SELECT *, (bank_end+make_interval(months=>streak_offset))::date AS cure_start,
           (bank_end+make_interval(months=>streak_offset+threshold-1))::date AS confirm_month,
           coalesce((bank_end+make_interval(months=>streak_offset-1))::date,last_month) AS credit_end
    FROM first_streak
), adverse AS (
    -- Cure confirmation can supply reversal evidence, but an incident never acquires
    -- another severe event or adverse month after its credit window closes.
    SELECT d.account,
           max(h.byte_date) FILTER (WHERE h.byte_date <= d.credit_end
               AND h.status IN ('G','H','J','K','L')) AS last_major,
           bool_or(h.byte_date <= d.credit_end AND h.status='L') AS window_chargeoff,
           bool_or(h.byte_date <= d.credit_end AND h.status IN ('1','2','3','4','5','6')) AS has_late,
           array_agg(h.byte_date ORDER BY h.byte_date)
               FILTER (WHERE h.status IN ('0','1','2','3','4','5','6')) AS numeric_months
    FROM dated d
    JOIN module1.metro2_status_history h
      ON h.account=d.account AND h.byte_date BETWEEN d.bank_start AND coalesce(d.confirm_month,d.last_month)
    GROUP BY d.account
), evidence AS (
    SELECT a.*, (SELECT min(m) FROM unnest(a.numeric_months) m WHERE m>a.last_major) AS first_reversal
    FROM adverse a
), treatments AS (
    SELECT d.*, a.last_major, a.first_reversal, a.has_late, a.window_chargeoff,
           (a.first_reversal IS NOT NULL) AS recovered,
           CASE WHEN a.first_reversal IS NOT NULL THEN 'FULL_DEROGATORY_PHP_CLEANUP'
                WHEN a.last_major IS NOT NULL THEN 'TRADELINE_DELETION'
                WHEN a.has_late THEN 'SIMPLE_DELINQUENCY_PHP_CLEANUP'
                ELSE 'NO_IMPACT_CLEAN_PHP_HISTORY' END AS expected_treatment
    FROM dated d JOIN evidence a USING (account)
), expected AS MATERIALIZED (
    SELECT *, CASE WHEN expected_treatment IN ('SIMPLE_DELINQUENCY_PHP_CLEANUP','FULL_DEROGATORY_PHP_CLEANUP')
                          AND NOT closed AND cure_start IS NULL
                   THEN CASE WHEN later_count<threshold THEN 'INSUFFICIENT_POST_IMPACT_HISTORY'
                             ELSE 'NO_CURE_OPEN_ACCOUNT' END END AS reason
    FROM treatments
), original_vs_detail AS (
    SELECT coalesce(h.account,d.account) AS account,h.byte_date,d.byte_date AS stored_date,
           h.status,d.original_status AS detail_original,d.remediated_status,d.is_within_credit_impact_window,
           h.perf_age,d.perf_age AS stored_perf_age,d.remediation_treatment AS detail_treatment
    FROM module1.metro2_status_history h
    FULL JOIN module2.metro2_remediation_php_detail d USING (account,byte_date)
), monthly_expected AS (
    SELECT m.*, e.expected_treatment, e.last_month, e.original_17b, e.source_closed_date,
           CASE e.original_17a WHEN '61' THEN 'J' WHEN '62' THEN 'G'
                               WHEN '63' THEN 'K' WHEN '64' THEN 'L' WHEN '65' THEN 'H' END AS paid_basis,
           m.byte_date BETWEEN e.bank_start AND e.credit_end AS within_window,
           CASE WHEN m.byte_date BETWEEN e.bank_start AND e.credit_end AND
                    ((e.expected_treatment='SIMPLE_DELINQUENCY_PHP_CLEANUP' AND m.status IN ('1','2','3','4','5','6'))
                      OR (e.expected_treatment='FULL_DEROGATORY_PHP_CLEANUP' AND m.status IN ('1','2','3','4','5','6','G','H','J','K','L')))
                THEN 'D' ELSE m.status END AS proposed
    FROM original_vs_detail m LEFT JOIN expected e USING (account)
), monthly AS (
    SELECT account, count(*) AS rows_checked,
           count(*) FILTER (WHERE byte_date IS NULL OR stored_date IS NULL
                  OR ROW(status, proposed, within_window::int, perf_age, expected_treatment) IS DISTINCT FROM
                     ROW(detail_original, remediated_status, is_within_credit_impact_window, stored_perf_age, detail_treatment)) AS mismatches,
           count(*) FILTER (WHERE status IS DISTINCT FROM proposed) AS proposed_changes,
           string_agg(proposed,'' ORDER BY byte_date DESC) AS proposed_php,
           bool_or(byte_date=last_month AND proposed IS DISTINCT FROM status) AS edited_latest,
           max(byte_date) FILTER (WHERE status=paid_basis AND proposed IS DISTINCT FROM status) AS removed_paid_month,
           bool_or(proposed=paid_basis) AS retained_paid_basis,
           max(byte_date) FILTER (WHERE status='D') AS newest_unknown_month,
           max(byte_date) FILTER (WHERE status IN ('1','2','3','4','5','6','G','H','J','K','L')) AS last_original_adverse,
           max(status) FILTER (WHERE byte_date=(date_trunc('month',source_closed_date)-interval '1 month')::date) AS closure_mark,
           bool_or(byte_date=(date_trunc('month',source_closed_date)-interval '1 month')::date AND proposed IS DISTINCT FROM status) AS closure_mark_changed,
           max(byte_date) FILTER (WHERE status=original_17b AND proposed IS DISTINCT FROM status AND
                            status IN ('1','2','3','4','5','6','G','L') AND
                            byte_date=(date_trunc('month',source_closed_date)-interval '1 month')::date) AS removed_closure_rating_month,
           max(byte_date) FILTER (WHERE proposed IN ('1','2','3','4','5','6','G','H','J','K','L')) AS last_retained_adverse
    FROM monthly_expected GROUP BY account
), basis AS (
    SELECT e.*, m.rows_checked, m.proposed_changes, m.mismatches, m.proposed_php,
           m.edited_latest, m.removed_paid_month, m.retained_paid_basis, m.removed_closure_rating_month, m.last_retained_adverse,
           m.newest_unknown_month, m.last_original_adverse, m.closure_mark, m.closure_mark_changed,
           left(e.original_php,1) AS latest_original,
           (ARRAY['11','71','78','80','82','83','84','93','94','95','96','97'])
              [nullif(strpos('0123456GHJKL',left(e.original_php,1)),0)] AS latest_status_code,
           CASE e.original_17a WHEN '61' THEN 'J' WHEN '62' THEN 'G'
                               WHEN '63' THEN 'K' WHEN '64' THEN 'L' WHEN '65' THEN 'H' END AS paid_basis,
           e.expected_treatment IN ('SIMPLE_DELINQUENCY_PHP_CLEANUP','FULL_DEROGATORY_PHP_CLEANUP') AS cleanup
    FROM expected e FULL JOIN monthly m USING (account)
), episode_evidence AS (
    -- Examine an inclusive slice of ORIGINAL history for each potentially affected field basis.
    -- Offsets are taken from the supplied onset and the cutoff, independent of the engine's
    -- monthly aggregates. The source month and every intervening observation must be present.
    SELECT b.*, ep.latest_supported, ep.closure_supported, ep.major_supported
    FROM basis b
    CROSS JOIN LATERAL (
        SELECT coalesce(bool_or(supported) FILTER (WHERE kind='latest'),false) AS latest_supported,
               coalesce(bool_or(supported) FILTER (WHERE kind='closure'),false) AS closure_supported,
               coalesce(bool_or(supported) FILTER (WHERE kind='major'),false) AS major_supported
        FROM (
            SELECT v.kind, b.original_dofd IS NULL OR
                   (date_trunc('month',b.original_dofd)::date BETWEEN b.first_month AND v.basis_month
                    AND substring(b.original_php FROM n.onset_pos FOR 1) ~ '^[1-6]$'
                    AND substring(b.original_php FROM n.basis_pos FOR greatest(0,n.onset_pos-n.basis_pos+1)) ~ '^[1-6GHJKL]+$') AS supported
            FROM (VALUES ('latest',b.last_month), ('closure',b.removed_closure_rating_month), ('major',b.removed_paid_month)) v(kind,basis_month)
            CROSS JOIN LATERAL (
                SELECT extract(year FROM b.last_month)::int*12+extract(month FROM b.last_month)::int AS last_index,
                       extract(year FROM b.original_dofd)::int*12+extract(month FROM b.original_dofd)::int AS onset_index,
                       extract(year FROM v.basis_month)::int*12+extract(month FROM v.basis_month)::int AS basis_index
            ) z
            CROSS JOIN LATERAL (SELECT 1+z.last_index-z.onset_index AS onset_pos, 1+z.last_index-z.basis_index AS basis_pos) n
        ) tested
    ) ep
), raw_authority AS (
    SELECT b.*,
           coalesce(cleanup AND NOT closed AND edited_latest AND original_17a=latest_status_code
                    AND (original_17b IS NULL OR original_17b IN ('0',latest_original))
                    AND (original_dofd IS NULL OR date_trunc('month',original_dofd)::date <= last_month),false) AS open_basis,
           coalesce(removed_closure_rating_month IS NOT NULL
                    AND (last_retained_adverse IS NULL OR last_retained_adverse <= removed_closure_rating_month)
                    AND (original_dofd IS NULL OR date_trunc('month',original_dofd)::date <= removed_closure_rating_month),false) AS closure_rating_basis,
           coalesce(source_closed_date > source_doai
                 OR last_original_adverse >= date_trunc('month',source_closed_date)::date,false) AS closure_conflict
    FROM episode_evidence b
), supported AS (
    SELECT b.*,
           coalesce(cleanup AND paid_basis IS NOT NULL AND removed_paid_month IS NOT NULL
                    AND removed_paid_month <= source_closed_date
                    AND (newest_unknown_month IS NULL OR newest_unknown_month <= removed_paid_month)
                    AND NOT retained_paid_basis
                    AND (last_retained_adverse IS NULL OR last_retained_adverse <= removed_paid_month)
                    AND (original_dofd IS NULL OR date_trunc('month',original_dofd)::date <= removed_paid_month)
                    AND (original_17b IS NULL OR original_17b IN ('0',paid_basis) OR closure_rating_basis),false) AS paid_status_basis,
           original_17b IS NULL OR original_17b IN ('0',paid_basis) OR closure_supported AS paid_rating_supported
    FROM raw_authority b
), eligible AS (
    SELECT s.*,
           open_basis AND latest_supported AND source_closed_date IS NULL AS elect_open,
           paid_status_basis AND major_supported AND paid_rating_supported AND NOT closure_conflict AS elect_paid,
           coalesce(cleanup AND original_17a='13' AND closure_rating_basis AND closure_supported AND NOT closure_conflict,false) AS elect_closed_13
    FROM supported s
), derived_proposals AS (
    SELECT e.*,
           CASE WHEN expected_treatment='TRADELINE_DELETION' THEN 'DA'
                WHEN elect_open THEN '11' WHEN elect_paid THEN '13'
                ELSE original_17a END AS proposed_17a,
           CASE WHEN elect_open OR elect_paid OR elect_closed_13 THEN '0'
                ELSE original_17b END AS proposed_17b,
           CASE WHEN elect_open OR elect_paid OR elect_closed_13 THEN NULL::date
                ELSE original_dofd END AS proposed_dofd
    FROM eligible e
), referrals AS (
    -- These are source-evidence referrals, independent of cure-queue membership.
    SELECT d.*, CASE
        WHEN expected_treatment='TRADELINE_DELETION' OR elect_open OR elect_paid OR elect_closed_13 THEN NULL
        WHEN original_17a IN ('05','13','65','88','89','94','95') AND nullif(btrim(original_17b),'') IS NULL
             THEN 'MISSING_REQUIRED_PAYMENT_RATING'
        WHEN NOT cleanup THEN NULL
        WHEN (open_basis AND source_closed_date IS NOT NULL)
              OR ((paid_status_basis OR (original_17a='13' AND closure_rating_basis)) AND closure_conflict)
             THEN 'CLOSURE_TIMING_UNCONFIRMED'
        WHEN (open_basis AND NOT latest_supported)
              OR (paid_status_basis AND NOT coalesce(major_supported AND paid_rating_supported,false))
              OR (original_17a='13' AND closure_rating_basis AND NOT closure_supported)
             THEN 'ONSET_CONTINUITY_UNCONFIRMED'
        WHEN paid_basis IS NOT NULL AND retained_paid_basis IS FALSE THEN 'PAID_MAJOR_BASIS_UNCONFIRMED'
        WHEN original_17a='13' AND original_17b IN ('1','2','3','4','5','6','G','L')
              AND (closure_mark IS DISTINCT FROM original_17b OR closure_mark_changed OR source_closed_date>source_doai)
             THEN 'CLOSURE_RATING_BASIS_UNCONFIRMED'
        WHEN NOT closed AND latest_original IN ('0','1','2','3','4','5','6','G','H','J','K','L')
              AND (original_17a IS DISTINCT FROM latest_status_code OR edited_latest)
             THEN 'AS_OF_FIELD_BASIS_UNCONFIRMED'
        WHEN NOT closed AND latest_original IN ('1','2','3','4','5','6','G','H','J','K','L')
              AND newest_unknown_month >= date_trunc('month',original_dofd)::date THEN 'ONSET_CONTINUITY_UNCONFIRMED'
        END AS field_referral
    FROM derived_proposals d
), written AS (
    SELECT d.*, nullif(proposed_php,original_php) AS new_php,
           nullif(proposed_17a,original_17a) AS new_17a,
           nullif(proposed_17b,original_17b) AS new_17b,
           nullif(proposed_dofd,original_dofd) AS new_dofd,
           cleanup AND original_17a IS NOT NULL AND proposed_17a IS NULL AS clear_17a,
           cleanup AND original_17b IS NOT NULL AND proposed_17b IS NULL AS clear_17b,
           cleanup AND original_dofd IS NOT NULL AND proposed_dofd IS NULL AS clear_dofd,
           proposed_17a IS DISTINCT FROM original_17a AS status_changed,
           proposed_17b IS DISTINCT FROM original_17b OR proposed_dofd IS DISTINCT FROM original_dofd AS other_fields_changed
    FROM referrals d
), summary_actions AS (
    SELECT w.*, CASE
             WHEN new_php IS NOT NULL AND status_changed AND other_fields_changed THEN 'PHP_STATUS_AND_DERIVED_FIELDS'
             WHEN new_php IS NOT NULL AND status_changed THEN 'PHP_AND_STATUS'
             WHEN new_php IS NOT NULL AND other_fields_changed THEN 'PHP_AND_DERIVED_FIELDS'
             WHEN new_php IS NOT NULL THEN 'PHP_ONLY'
             WHEN status_changed AND other_fields_changed THEN 'STATUS_AND_DERIVED_FIELDS'
             WHEN status_changed THEN 'STATUS_ONLY'
             WHEN other_fields_changed THEN 'DERIVED_FIELDS_ONLY'
             ELSE 'NONE' END AS field_summary
    FROM written w
), comparison AS (
    SELECT e.*,
           f.account AS final_id, w.account AS window_id,
           -- Clock and input provenance come from the original dated observation table.
           -- Mutating the same date or string in every downstream table must still fail.
           (e.source_doai IS DISTINCT FROM (e.last_month + INTERVAL '1 month')::date
             OR e.source_doai IS NULL OR e.last_month IS NULL) AS bad_clock,
           (NOT coalesce(e.valid_symbols,false)
             OR NOT coalesce(e.original_php ~ '^[0-6DGHJKL]*B*$',false)) AS bad_symbols,
           (ROW(e.source_left,e.source_right,e.summary_php) IS DISTINCT FROM
            ROW(e.last_month,e.first_month,e.original_php)
            OR ROW(w.latest_doai,w.php_left_byte_date,w.php_right_byte_date,w.full_php,w.account_status_17a,
                   w.payment_rating_17b,w.date_of_first_delinquency,w.date_closed,w.profile_type)
               IS DISTINCT FROM ROW(e.source_doai,e.last_month,e.first_month,e.original_php,e.original_17a,
                                    e.original_17b,e.original_dofd,e.source_closed_date,e.source_profile)
            OR ROW(f.latest_doai,f.php_left_byte_date,f.php_right_byte_date,f.full_php,f.account_status_17a,
                   f.payment_rating_17b,f.date_of_first_delinquency,f.date_closed,f.profile_type)
               IS DISTINCT FROM ROW(e.source_doai,e.last_month,e.first_month,e.original_php,e.original_17a,
                                    e.original_17b,e.original_dofd,e.source_closed_date,e.source_profile)) AS bad_source_snapshot,
           (w.credit_cure_date IS DISTINCT FROM e.cure_start OR f.credit_cure_date IS DISTINCT FROM e.cure_start
             OR w.cure_consecutive_months_required IS DISTINCT FROM e.threshold
             OR f.cure_consecutive_months_required IS DISTINCT FROM e.threshold
             OR (e.confirm_month IS NOT NULL AND e.confirm_month>e.last_month)) AS bad_cure,
           (ROW(w.impact_start_date,w.impact_end_date,w.credit_impact_start_date,w.credit_impact_end_date,
                f.impact_start_date,f.impact_end_date,f.credit_impact_start_date,f.credit_impact_end_date) IS DISTINCT FROM
            ROW(e.bank_start,e.bank_end,e.bank_start,e.credit_end,e.bank_start,e.bank_end,e.bank_start,e.credit_end)) AS bad_window,
           (ROW(w.has_derog_in_credit_window,w.has_delinquency_in_credit_window,w.has_post_derog_recovery_evidence,w.post_impact_month_count,(to_jsonb(w)->>'has_chargeoff_in_credit_window')::int) IS DISTINCT FROM
            ROW((e.last_major IS NOT NULL)::int,e.has_late::int,e.recovered::int,e.later_count,e.window_chargeoff::int)) AS bad_indicators,
           (ROW((to_jsonb(w)->>'last_severe_month')::date,(to_jsonb(w)->>'severe_reversal_month')::date)
               IS DISTINCT FROM ROW(e.last_major,e.first_reversal)) AS bad_event_dates,
           ((to_jsonb(w)->>'remediation_policy') IS DISTINCT FROM 'REVERSAL_AWARE_SEVERE_V2') AS bad_policy_id,
           (ROW(w.remediation_treatment, f.remediation_treatment) IS DISTINCT FROM ROW(e.expected_treatment,e.expected_treatment)) AS bad_treatment,
           (ROW(w.manual_review_flag,w.manual_review_reason,f.manual_review_flag,f.manual_review_reason) IS DISTINCT FROM
            ROW((e.reason IS NOT NULL)::int,e.reason,(e.reason IS NOT NULL)::int,e.reason)) AS bad_review,
           (f.full_php IS DISTINCT FROM e.original_php
             OR f.remediated_full_php IS DISTINCT FROM e.new_php
             OR ((f.remediated_account_status_17a IS NOT DISTINCT FROM 'DA') IS DISTINCT FROM (e.expected_treatment='TRADELINE_DELETION'))) AS bad_outputs,
           -- Enforce forbidden actions directly on the recorded outputs; this check
           -- does not depend on the expected sparse-delta or summary calculations.
           (f.remediated_date_of_first_delinquency IS NOT NULL
             OR coalesce((to_jsonb(f)->>'clear_account_status_17a')::boolean,false)
             OR coalesce((to_jsonb(f)->>'clear_payment_rating_17b')::boolean,false)
             OR (act.has_field_change AND e.expected_treatment <> 'TRADELINE_DELETION' AND
                 (NOT e.cleanup
                  -- A dated later episode and a source gap are independent of earlier monthly edits.
                  OR (NOT e.closed AND (e.last_month>e.credit_end OR e.last_month<e.bank_start
                                        OR e.latest_original NOT IN ('1','2','3','4','5','6','G','H','J','K','L')
                                        OR e.original_17a IS DISTINCT FROM e.latest_status_code))
                  -- An existing closed basis left in the proposed history forbids field-level actions.
                  OR (e.paid_basis IS NOT NULL AND (e.retained_paid_basis OR e.removed_paid_month IS NULL))
                  OR (e.original_17a='13' AND e.removed_closure_rating_month IS NULL)))
             OR (f.remediated_account_status_17a IS NOT NULL AND
                 NOT coalesce((f.remediated_account_status_17a='DA' AND e.expected_treatment='TRADELINE_DELETION')
                      OR (f.remediated_account_status_17a='11' AND e.elect_open)
                      OR (f.remediated_account_status_17a='13' AND e.elect_paid),false))
             OR ((f.remediated_payment_rating_17b IS NOT NULL OR coalesce((to_jsonb(f)->>'clear_date_of_first_delinquency')::boolean,false))
                 AND NOT coalesce(e.elect_open OR e.elect_paid OR e.elect_closed_13,false))) AS bad_unsupported_actions,
           ((to_jsonb(f)->>'account_field_policy') IS DISTINCT FROM 'EVIDENCE_SCOPED_FIELDS_V2'
            OR NOT (to_jsonb(f) ? 'account_field_review_reason')) AS bad_field_policy,
           ((to_jsonb(f)->>'account_field_review_reason') IS DISTINCT FROM e.field_referral) AS bad_field_referral,
           (e.original_dofd IS NOT NULL AND act.has_field_change AND e.expected_treatment <> 'TRADELINE_DELETION' AND
              ((NOT e.closed AND NOT e.latest_supported) OR (e.paid_basis IS NOT NULL AND NOT coalesce(e.major_supported AND e.paid_rating_supported,false))
                OR (e.original_17a='13' AND NOT e.closure_supported))) AS bad_episode_action,
           (e.proposed_17a IN ('05','13','65','88','89','94','95') AND nullif(btrim(e.proposed_17b),'') IS NULL
            AND (to_jsonb(f)->>'account_field_review_reason') IS DISTINCT FROM 'MISSING_REQUIRED_PAYMENT_RATING') AS bad_missing_rating_referral,
           ROW(f.account_status_17a,f.payment_rating_17b,f.date_of_first_delinquency)
             IS DISTINCT FROM ROW(e.original_17a,e.original_17b,e.original_dofd) AS bad_original_fields,
           ROW(f.remediated_account_status_17a,f.remediated_payment_rating_17b,f.remediated_date_of_first_delinquency)
             IS DISTINCT FROM ROW(e.new_17a,e.new_17b,e.new_dofd) AS bad_field_deltas,
           ROW((to_jsonb(f)->>'clear_account_status_17a')::boolean,(to_jsonb(f)->>'clear_payment_rating_17b')::boolean,
               (to_jsonb(f)->>'clear_date_of_first_delinquency')::boolean)
             IS DISTINCT FROM ROW(e.clear_17a,e.clear_17b,e.clear_dofd) AS bad_clear_flags,
           ROW(f.remediation_fields_modified,f.remediation_applied_flag)
             IS DISTINCT FROM ROW(e.field_summary,(e.field_summary<>'NONE')::int) AS bad_field_summary,
           (e.bank_start IS NULL OR e.bank_end IS NULL OR
            e.bank_start IS DISTINCT FROM date_trunc('month',e.bank_start)::date OR
            e.bank_end IS DISTINCT FROM date_trunc('month',e.bank_end)::date) AS bad_incident_month_key,
           (e.nmonths<>e.ndates OR NOT e.valid_keys OR e.bank_start>e.bank_end
              OR e.bank_start<e.first_month OR e.bank_end>e.last_month
              OR e.nmonths<>1+(extract(year from e.last_month)-extract(year from e.first_month))*12
                            +extract(month from e.last_month)-extract(month from e.first_month)) AS bad_dates
    FROM summary_actions e
    FULL JOIN module2.metro2_remediation_final f ON e.account=f.account
    FULL JOIN module2.metro2_remediation_window_eval w ON coalesce(e.account,f.account)=w.account
    CROSS JOIN LATERAL (SELECT f.remediated_account_status_17a IS NOT NULL OR f.remediated_payment_rating_17b IS NOT NULL
                  OR f.remediated_date_of_first_delinquency IS NOT NULL OR coalesce((to_jsonb(f)->>'clear_date_of_first_delinquency')::boolean,false)
                  AS has_field_change) act
), stats AS (
    SELECT count(*) AS accounts_checked, count(DISTINCT account) AS unique_source_accounts,
           sum(rows_checked)::bigint AS monthly_records_compared, sum(proposed_changes)::bigint AS monthly_corrections,
           count(*) FILTER (WHERE cure_start IS NOT NULL) AS confirmed_cures,
           count(*) FILTER (WHERE reason IS NOT NULL) AS manual_reviews,
           count(*) FILTER (WHERE window_chargeoff AND cure_start IS NULL AND recovered) AS uncured_chargeoffs_with_later_numeric_cleaned,
           count(*) FILTER (WHERE last_major IS NOT NULL AND NOT recovered) AS unresolved_severe_events_deleted,
           count(*) FILTER (WHERE recovered) AS reversed_severe_events_cleaned,
           count(*) FILTER (WHERE bad_event_dates) AS severe_event_date_mismatches,
           count(*) FILTER (WHERE bad_policy_id) AS policy_identifier_mismatches,
           count(*) FILTER (WHERE account IS NULL OR window_id IS NULL OR final_id IS NULL OR rows_checked IS NULL) AS missing_joins,
           count(*) FILTER (WHERE bad_cure) AS cure_start_or_threshold_mismatches,
           count(*) FILTER (WHERE bad_window) AS impact_boundary_mismatches,
           count(*) FILTER (WHERE bad_indicators) AS recovery_or_window_indicator_mismatches,
           count(*) FILTER (WHERE bad_treatment) AS treatment_mismatches,
           count(*) FILTER (WHERE bad_review) AS review_disposition_mismatches,
           count(*) FILTER (WHERE bad_outputs) AS output_php_or_deletion_instruction_mismatches,
           count(*) FILTER (WHERE bad_dates) AS original_calendar_mismatches,
           count(*) FILTER (WHERE bad_incident_month_key) AS invalid_incident_month_keys,
           count(*) FILTER (WHERE bad_clock) AS reporting_clock_mismatches,
           count(*) FILTER (WHERE bad_symbols) AS unsupported_or_misplaced_source_symbols,
           count(*) FILTER (WHERE bad_source_snapshot) AS source_snapshot_copy_mismatches,
           count(*) FILTER (WHERE bad_unsupported_actions) AS unjustified_current_field_actions,
           count(*) FILTER (WHERE bad_field_policy) AS field_policy_identifier_mismatches,
           count(*) FILTER (WHERE bad_episode_action) AS unsupported_onset_episode_actions,
           count(*) FILTER (WHERE bad_missing_rating_referral) AS unreferred_required_rating_gaps,
           count(*) FILTER (WHERE bad_field_referral) AS field_evidence_referral_mismatches,
           count(*) FILTER (WHERE field_referral IS NOT NULL) AS field_evidence_referrals,
           count(*) FILTER (WHERE bad_original_fields) AS original_account_field_mismatches,
           count(*) FILTER (WHERE bad_field_deltas) AS account_field_delta_mismatches,
           count(*) FILTER (WHERE bad_clear_flags) AS explicit_clear_flag_mismatches,
           count(*) FILTER (WHERE bad_field_summary) AS applied_or_field_summary_mismatches,
           count(*) FILTER (WHERE clear_17a) AS explicit_status_clears,
           count(*) FILTER (WHERE clear_17b) AS explicit_rating_clears,
           count(*) FILTER (WHERE clear_dofd) AS explicit_dofd_clears,
           coalesce(sum(mismatches),0)::bigint AS monthly_edit_or_source_mismatches
    FROM comparison
), sizes AS (
    SELECT (SELECT count(*) FROM module1.metro2_account_blueprint) AS blueprint,
           (SELECT count(*) FROM module1.metro2_final) AS generator_final,
           (SELECT count(*) FROM module2.metro2_remediation_input) AS bank_inputs,
           (SELECT count(*) FROM module2.metro2_remediation_window_eval) AS window_evaluations,
           (SELECT count(*) FROM module2.metro2_remediation_final) AS remediation_final,
           (SELECT count(*) FROM module1.metro2_status_history) AS source_months,
           (SELECT count(*) FROM module2.metro2_remediation_php_detail) AS detail_months
)
SELECT jsonb_build_object('verification_policy','REVERSAL_AWARE_SEVERE_V2','database', current_database(), 'postgresql', current_setting('server_version'),
    'threshold', s.threshold, 'requested_accounts',s.expected_accounts, 'sizes',to_jsonb(n), 'audit',to_jsonb(a),
    'pass',s.expected_accounts=ALL(ARRAY[n.blueprint,n.generator_final,n.bank_inputs,n.window_evaluations,n.remediation_final,a.accounts_checked,a.unique_source_accounts])
       AND a.monthly_records_compared=n.source_months AND n.source_months=n.detail_months AND a.monthly_records_compared>0
       AND s.expected_accounts>0 AND s.threshold>0
       AND a.unsupported_onset_episode_actions+a.unreferred_required_rating_gaps+a.invalid_incident_month_keys+a.unjustified_current_field_actions+a.field_policy_identifier_mismatches+a.field_evidence_referral_mismatches+a.missing_joins+a.cure_start_or_threshold_mismatches+a.impact_boundary_mismatches
         +a.severe_event_date_mismatches+a.policy_identifier_mismatches+a.recovery_or_window_indicator_mismatches+a.treatment_mismatches+a.review_disposition_mismatches
         +a.output_php_or_deletion_instruction_mismatches+a.original_calendar_mismatches+a.monthly_edit_or_source_mismatches
         +a.reporting_clock_mismatches+a.unsupported_or_misplaced_source_symbols+a.source_snapshot_copy_mismatches
         +a.original_account_field_mismatches+a.account_field_delta_mismatches+a.explicit_clear_flag_mismatches+a.applied_or_field_summary_mismatches=0)
FROM stats a CROSS JOIN sizes n CROSS JOIN settings s;
\if :{?metro2_existing_snapshot}
\else
COMMIT;
\endif
