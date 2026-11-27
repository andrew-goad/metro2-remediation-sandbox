(() => {
  'use strict';
  const monthFormat = new Intl.DateTimeFormat('en-US', {year: 'numeric', month: 'long', timeZone: 'UTC'});
  const month = value => monthFormat.format(new Date(value + 'T00:00:00Z'));
  const escape = value => String(value).replace(/[&<>"']/g, char =>
    ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[char]));
  function offsetMonth(value, offset) {
    const d = new Date(value + 'T00:00:00Z');
    d.setUTCMonth(d.getUTCMonth() + offset);
    return d.toISOString().slice(0, 10);
  }
  const isLate = code => /^[1-6]$/.test(code);
  const ratingStatuses2020 = new Set(['05', '13', '65', '88', '89', '94', '95']);
  const researchReasons = {
    PAID_MAJOR_BASIS_UNCONFIRMED: 'Verify the servicing event that supports the paid major-derogatory status.',
    CLOSURE_RATING_BASIS_UNCONFIRMED: 'Verify the closing date and the payment performance that supports the closure rating.',
    AS_OF_FIELD_BASIS_UNCONFIRMED: 'Verify the evidence supporting the status and rating as of the reporting date.',
    ONSET_CONTINUITY_UNCONFIRMED: 'Servicing must establish whether the supplied onset belongs to the delinquency being corrected. Compare the original monthly performance with the account ledger.',
    CLOSURE_TIMING_UNCONFIRMED: 'Reconcile the recorded closure date with the status and original adverse payment history before changing an account field.',
    MISSING_REQUIRED_PAYMENT_RATING: 'The effective status requires a payment rating under the historical standard, and the modeled rating is missing. Obtain its servicing basis, then reassess any rating-dependent Field 25 requirement.'
  };

  function accountFieldNote(a) {
    if (!a.account_field_review_reason) return '';
    let why = researchReasons[a.account_field_review_reason] || 'Verify the supporting servicing evidence.';
    if (a.account_field_review_reason === 'MISSING_REQUIRED_PAYMENT_RATING') {
      if (['05', '13'].includes(a.account_status_17a)) {
        why += ' For this status, the missing rating leaves the historical status-and-rating date test unresolved.';
      } else if (['65', '88', '89', '94', '95'].includes(a.account_status_17a)) {
        why += a.date_of_first_delinquency ? ' This status separately requires Field 25. The source already carries a date.' : ' This status separately requires Field 25, and its source date is also missing.';
      }
    }
    return '<p><strong>Account-field research.</strong> ' + why + ' This research flag is separate from the monthly cure decision.</p>';
  }

  function effectiveField(a, key) {
    if (a['clear_' + key] === true) return null;
    if (a['remediated_' + key] != null) return a['remediated_' + key];
    if (a['clear_' + key] === false || a.remediation_treatment === 'NO_IMPACT_CLEAN_PHP_HISTORY') return a[key];
    return undefined;
  }

  function standardRating(a) {
    const original = a.account_status_17a;
    const proposed = effectiveField(a, 'account_status_17a');
    const deleted = a.remediation_treatment === 'TRADELINE_DELETION';
    const known = status => /^\d{2}$/.test(status);
    const needs = status => ratingStatuses2020.has(status);
    const proposedRating = effectiveField(a, 'payment_rating_17b');
    if (!deleted && known(original) && original === proposed) {
      if (!needs(original)) return 'Under the 2020 character layout, original and proposed status ' + original + ' both use a blank standard Field 17B.';
      if (proposedRating === a.payment_rating_17b) {
        const missing = proposedRating == null || proposedRating === '' ? ' The internal modeled rating is missing and needs servicing evidence.' : '';
        return 'Under the 2020 character layout, original and proposed status ' + original + ' both require standard Field 17B.' + missing;
      }
    }
    if (!deleted && known(original) && known(proposed) && !needs(original) && !needs(proposed)) {
      return 'Under the 2020 character layout, standard Field 17B is blank for original status ' + original + ' and proposed status ' + proposed + '.';
    }
    function forStatus(label, status, modeled) {
      if (!known(status)) return label + ' status is unavailable, so Field 17B applicability is undetermined.';
      if (!needs(status)) return 'Standard Field 17B is blank for ' + label.toLowerCase() + ' status ' + status + '.';
      const evidence = modeled === undefined ? ' The export does not establish the effective modeled rating.' :
        modeled == null || modeled === '' ? ' The modeled rating is missing and needs servicing evidence.' : '';
      return label + ' status ' + status + ' requires a payment rating.' + evidence;
    }
    return '2020 character layout. ' + forStatus('Original', original, a.payment_rating_17b) + ' ' +
      (deleted ? 'The proposed DA instruction deletes the tradeline.' :
        forStatus('Proposed', proposed, proposedRating));
  }

  function hasCurrentProposal(a) {
    return a.manual_review_flag === 1 && a.credit_cure_date == null &&
      a.remediation_treatment === 'SIMPLE_DELINQUENCY_PHP_CLEANUP' && a.clear_date_of_first_delinquency === true &&
      /^\d{4}-\d{2}-\d{2}$/.test(a.date_of_first_delinquency) && a.remediated_date_of_first_delinquency == null &&
      a.remediated_account_status_17a === '11' && a.remediated_payment_rating_17b === '0' &&
      isLate(a.full_php?.[0]) && a.remediated_full_php?.[0] === 'D';
  }

  function workedCases(findAccount) {
    const examples = [
      {account: 24064, label: '24064 · Five corrections and no cure', start: '2023-12-01', end: '2024-01-01',
        latest: '2024-04-01', before: '6543210000000', after: 'DDDDD10000000', status: '84', rating: '6',
        dofd: '2023-11-01', post: 3, reason: 'NO_CURE_OPEN_ACCOUNT'},
      {account: 17899, label: '17899 · One correction before follow-up', start: '2025-01-01', end: '2025-01-01',
        latest: '2025-01-01', before: '110000000', after: 'D10000000', status: '71', rating: '1',
        dofd: '2024-12-01', post: 0, reason: 'INSUFFICIENT_POST_IMPACT_HISTORY'}
    ];
    return examples.flatMap(e => {
      const a = findAccount(e.account);
      return a && hasCurrentProposal(a) && a.impact_start_date === e.start && a.impact_end_date === e.end &&
        a.credit_impact_start_date === e.start && a.credit_impact_end_date === e.latest && a.php_left_byte_date === e.latest &&
        a.latest_doai === offsetMonth(e.latest, 1) && a.full_php === e.before && a.remediated_full_php === e.after &&
        a.account_status_17a === e.status && a.payment_rating_17b === e.rating && a.date_of_first_delinquency === e.dofd &&
        a.post_impact_month_count === e.post && a.manual_review_reason === e.reason && a.cure_consecutive_months_required === 3
        ? [{label: e.label, pick: a}] : [];
    });
  }

  function render(a, guideHref) {
    if (!hasCurrentProposal(a)) return '';
    const latest = a.php_left_byte_date;
    const next = month(offsetMonth(latest, 1));
    const months = a.months;
    const prior = months.find(row => row[0] < a.impact_start_date);
    let earlier = '';
    if (prior && isLate(prior[1]) && prior[1] === prior[2]) {
      earlier = month(prior[0]) + ' was already delinquent (code ' + prior[1] + ') before the bank issue. That entry stays in the history. ';
    } else if (prior && prior[1] === '0') {
      earlier = 'The last original month before the bank issue, ' + month(prior[0]) + ', was current. ';
    }
    const possibility = prior && prior[1] === '0' ? 'remained or become current' : 'caught up';
    const atEnd = months.find(row => row[0] === a.impact_end_date);
    const assumption = latest > a.impact_end_date && prior && isLate(prior[1]) && atEnd && isLate(atEnd[1])
      ? 'Without the bank issue, the consumer could have ' + possibility + ' before the issue ended. The study gives the consumer the benefit of that uncertainty through ' + month(latest) + ', while the original history still shows unresolved delinquency.'
      : 'Without the bank issue, the consumer could have ' + possibility + ' by the end of ' + month(latest) + '. The study gives the consumer the benefit of that uncertainty.';
    let history = month(latest) + ' changes from original ' + a.full_php[0] + ' to proposed D. D suppresses that monthly entry.';
    const afterIssue = months.filter(row => row[0] > a.impact_end_date).reverse();
    if (atEnd && isLate(atEnd[1]) && afterIssue.length > 0 && afterIssue.length <= 3 &&
        afterIssue.every(row => isLate(row[1]) && row[2] === 'D')) {
      const originals = afterIssue.map(row => month(row[0]) + ' (' + row[1] + ')').join(', ');
      const changed = months.filter(row => row[1] !== row[2]).length;
      const atStart = months.find(row => row[0] === a.impact_start_date);
      const startReading = atStart && atStart !== atEnd ? 'The bank issue starts in ' + month(atStart[0]) +
        ' at original code ' + escape(atStart[1]) + ' and ends' : 'The bank issue ends';
      history = startReading + ' in ' + month(atEnd[0]) + ' with original code ' + atEnd[1] +
        '. Delinquency continues in ' + originals + '. ' +
        'The proposal substitutes D in ' + changed + ' affected ' + (changed === 1 ? 'month' : 'months') +
        ', including the ' + afterIssue.length + ' after the bank issue.';
    }
    const currentMonths = a.cure_consecutive_months_required;
    const nextCurrent = currentMonths === 1 ? 'An original 0 in ' + next + ' would satisfy this account’s one-month cure threshold.' :
      'An original 0 in ' + next + ' would start the ' + currentMonths + '-month cure test. Zeros through ' +
        month(offsetMonth(latest, currentMonths)) + ' would confirm that start in the ' + offsetMonth(latest, currentMonths + 1) + ' snapshot.';
    return '<section class="case-field25 ex-timing"><h4>What could the consumer have done without the bank issue?</h4>' +
      '<p>' + earlier + history + ' The original record still shows the delinquency.</p>' +
      '<p>' + assumption + '</p>' +
      '<p>For the reporting cycle dated <strong>' + escape(a.latest_doai) + '</strong>, the proposal changes account status (17A) from ' + escape(a.account_status_17a) + ' to 11 (current), changes the internal modeled payment rating from ' + escape(a.payment_rating_17b) + ' to 0, and clears the stored Date of First Delinquency (' +
      a.date_of_first_delinquency + '). ' + standardRating(a) + ' Verify that assumption against the servicing records. Cure depends on later original performance.</p>' +
      '<h4>Read forward from ' + next + '</h4><p>The sample’s original payment history ends in ' + month(latest) + ', one cycle behind account status. Request ' + next +
      ' original history from the ' + offsetMonth(latest, 2) + ' snapshot, then each following original month while review remains open. ' +
      nextCurrent + ' If ' + next + ' is late, use servicing evidence to assess whether the bank issue still affected it and what correction it needs. ' +
      '<a href="' + escape(guideHref) + '">Field 25 guidance and exceptions</a></p></section>';
  }

  window.metro2Field25 = {hasCurrentProposal, workedCases, standardRating, accountFieldNote, render};
})();
