(() => {
  'use strict';
  const field25Guide = document.currentScript?.src
    ? new URL('index.html#field-25', document.currentScript.src).href : 'index.html#field-25';

  const titles = {
    FULL_DEROGATORY_PHP_CLEANUP: 'Derogatory history cleanup',
    SIMPLE_DELINQUENCY_PHP_CLEANUP: 'Delinquency cleanup',
    TRADELINE_DELETION: 'Tradeline deletion',
    NO_IMPACT_CLEAN_PHP_HISTORY: 'No correction'
  };
  const reasons = {
    NO_CURE_OPEN_ACCOUNT: 'The account is open and the original history has enough follow-up months to test for cure. It has yet to meet the threshold.',
    INSUFFICIENT_POST_IMPACT_HISTORY: 'Too few months have been observed since the issue ended to establish cure.'
  };
  const guideDefinitions = [
    ['reversal', 'Reversed charge-off awaiting cure', 327, a => {
      if (a.remediation_treatment !== 'FULL_DEROGATORY_PHP_CLEANUP' || !hasReview(a)) return false;
      const months = a.months;
      return months.some(([date, original]) => date === a.last_severe_month && original === 'L') &&
        months.some(([date, original]) => date === a.severe_reversal_month && /^[1-6]$/.test(original));
    }],
    ['chargeOffAfterIssue', 'Charge-off after the bank issue', 327, a => a.remediation_treatment === 'TRADELINE_DELETION' &&
      a.months.some(row => inWindow(row) && row[0] > a.impact_end_date && row[1] === 'L')],
    ['chargeOff', 'Charge-off during the bank issue', 987, a => a.remediation_treatment === 'TRADELINE_DELETION' &&
      a.months.some(([date, status]) => status === 'L' && date >= a.impact_start_date && date <= a.impact_end_date)],
    ['extended', 'Correction beyond the bank issue', 175, a => a.credit_cure_date && a.remediation_treatment === 'SIMPLE_DELINQUENCY_PHP_CLEANUP' &&
      a.months.some(row => row[0] > a.impact_end_date && isChanged(row))],
    ['ongoing', 'Ongoing delinquency review', 958, a => a.remediation_treatment === 'SIMPLE_DELINQUENCY_PHP_CLEANUP' &&
      hasReview(a) && a.manual_review_reason === 'NO_CURE_OPEN_ACCOUNT' && /^[1-6]$/.test(a.full_php[0])],
    ['openRecovery', 'Recovery after another major event', 450, a => a.remediation_treatment === 'FULL_DEROGATORY_PHP_CLEANUP' &&
      hasReview(a) && !a.months.some(row => inWindow(row) && row[1] === 'L')],
    ['fieldChange', 'A status and rating change', 730, a => a.remediated_payment_rating_17b != null && a.remediated_account_status_17a != null],
    ['clean', 'A clean window', 1, a => a.remediation_treatment === 'NO_IMPACT_CLEAN_PHP_HISTORY']
  ];
  const fields = [
    ['Account status (17A)', 'account_status_17a'],
    ['Internal modeled payment rating', 'payment_rating_17b'],
    ['Date of First Delinquency (Field 25)', 'date_of_first_delinquency'],
    ['Full simulated payment history', 'full_php']
  ];
  const monthFormat = new Intl.DateTimeFormat('en-US', {month: 'short', year: 'numeric', timeZone: 'UTC'});
  const month = s => s ? monthFormat.format(new Date(s.slice(0, 10) + 'T00:00:00Z')) : 'None recorded';
  const num = n => Number(n).toLocaleString('en-US');
  const plural = (n, noun) => num(n) + ' ' + noun + (n === 1 ? '' : 's');
  const escapeText = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  const safeCode = value => '<code>' + escapeText(value) + '</code>';
  const isChanged = row => row[1] !== row[2];
  const inWindow = row => Number(row[3]) === 1;
  const isMajor = status => /^[GHJKL]$/.test(status);
  const previousPolicy = 'CHARGEOFF_REQUIRES_CURE_V1';
  const currentPolicy = 'REVERSAL_AWARE_SEVERE_V2';
  const hasReview = a => Number(a.manual_review_flag) === 1;
  const titleFor = a => titles[a.remediation_treatment] ?? a.remediation_treatment;
  const humanize = s => String(s || '').toLowerCase().replaceAll('_', ' ');
  const classification = s => s === '0' ? 'current' : /^[1-6]$/.test(s) ? 'late' : isMajor(s) ? 'derog' : s === 'D' ? 'unavailable' : 'other';
  const codeMeaning = {
    '0': 'Current', '1': '30–59 days past due', '2': '60–89 days past due', '3': '90–119 days past due',
    '4': '120–149 days past due', '5': '150–179 days past due', '6': '180+ days past due',
    G: 'Collection', H: 'Foreclosure', J: 'Voluntary surrender', K: 'Repossession',
    L: 'Charge-off', D: 'No history available', B: 'No prior history'
  };
  const pageSize = 8;

  function nextMonth(date) {
    const d = new Date(date + 'T00:00:00Z');
    d.setUTCMonth(d.getUTCMonth() + 1);
    return d.toISOString().slice(0, 10);
  }

  function cureEvidence(a, months) {
    const required = Number(a.cure_consecutive_months_required);
    const first = months.findIndex(row => row[0] === a.credit_cure_date);
    if (first < 0 || months[first][0] <= a.impact_end_date || !Number.isInteger(required) || required < 1) return null;
    const proof = months.slice(first, first + required);
    if (proof.length !== required || !proof.every((row, i) =>
      row[1] === '0' && (i === 0 || row[0] === nextMonth(proof[i - 1][0])))) return null;
    let last = first + required - 1;
    while (last + 1 < months.length && months[last + 1][1] === '0' &&
           months[last + 1][0] === nextMonth(months[last][0])) last++;
    return {start: proof[0][0], confirmed: proof.at(-1)[0], lastCurrent: months[last][0]};
  }

  function cureReading(a, months, cure) {
    const required = Number(a.cure_consecutive_months_required);
    if (cure) {
      const continued = cure.lastCurrent > cure.confirmed ? ' The original history stays current through ' + month(cure.lastCurrent) + ' in this run.' : '';
      return 'The first qualifying run began in ' + month(cure.start) + ' and reached ' + plural(required, 'current month') + ' in ' + month(cure.confirmed) + '.' + continued;
    }
    if (a.credit_cure_date) return 'The recorded cure start lacks a complete qualifying run in the available monthly detail.';
    const post = months.filter(row => row[0] > a.impact_end_date);
    if (!post.length) return 'The original history ends with the bank issue. There are no later months to test for cure.';
    let trailing = 0;
    for (let i = post.length - 1; i >= 0 && post[i][1] === '0'; i--) trailing++;
    if (trailing) return 'The latest run of current months began in ' + month(post[post.length - trailing][0]) + '. It covers ' + num(trailing) + ' of the ' + plural(required, 'month') + ' needed to establish cure.';
    return 'The original history contains ' + plural(post.length, 'post-issue month') + '. It has yet to show the required run of ' + plural(required, 'current month') + '.';
  }

  function start() {
    const root = document.getElementById('explorer');
    if (!root) return;
    const data = window.METRO2_DATA;
    if (!data || !Array.isArray(data.accounts) || !data.accounts.length) {
      root.innerHTML = '<h2>Account explorer</h2><p>No account records are available in this edition.</p>';
      return;
    }
    const all = data.accounts.slice().sort((a, b) => Number(a.account) - Number(b.account));
    const retainedRoute = document.getElementById('retained-route');
    if (retainedRoute && (data.meta.sourceKind !== 'replay' || root.dataset.studySnapshot !== data.meta.snapshotUTC)) {
      document.getElementById('ex-cohort').textContent = data.meta.label + ' · ' + plural(all.length, 'loaded account');
      retainedRoute.hidden = false;
    }
    const current = data.meta.policyId === currentPolicy;
    const previous = data.meta.policyId === previousPolicy;
    const scopedFields = data.meta.accountFieldPolicy === 'EVIDENCE_SCOPED_FIELDS_V2';
    const priorFields = data.meta.accountFieldPolicy === 'EVIDENCE_SCOPED_FIELDS_V1';
    const policyLabel = current ? 'Reversal-aware severe-event policy' : previous ?
      'Earlier charge-off policy, which required cure' : 'Recorded treatments from an unverified policy version';
    const queueHref = current && scopedFields && data.meta.sourceKind === 'replay' && all.length === 25000 && root.dataset.reviewSnapshot &&
      root.dataset.reviewSnapshot === data.meta.snapshotUTC ? root.dataset.reviewHref : null;
    const byId = new Map(all.map(a => [String(a.account), a]));
    const guides = guideDefinitions.flatMap(([key, label, id, test]) => {
      if ((key === 'reversal' && !current) || (key === 'chargeOffAfterIssue' && current)) return [];
      if (data.guideIds) {
        const pick = byId.get(String(data.guideIds[key]));
        return pick && test(pick) ? [{label, pick}] : [];
      }
      const preferred = data.meta.sourceKind === 'replay' && all.length === 1000 && byId.get(String(id));
      const pick = preferred && test(preferred) ? preferred : all.find(test);
      return pick ? [{label, pick}] : [];
    });
    if (!guides.some(g => g.pick.remediation_treatment === 'TRADELINE_DELETION')) {
      const deletion = all.find(a => a.remediation_treatment === 'TRADELINE_DELETION');
      if (deletion) guides.unshift({label: 'A deletion instruction', pick: deletion});
    }
    const formatId = a => String(a.account);
    if (queueHref && window.metro2Field25?.workedCases) {
      const featured = window.metro2Field25.workedCases(id => byId.get(String(id)));
      guides.unshift(...featured);
      const headLinks = document.getElementById('scale-worked-cases');
      if (headLinks && featured.length) {
        headLinks.innerHTML = featured.map(({label, pick}) => '<a href="#account=' + pick.account + '">' + escapeText(label) + '</a>').join(' · ');
        headLinks.hidden = false;
        headLinks.addEventListener('click', event => {
          const link = event.target.closest('a');
          if (link && location.hash === link.hash) openLinked();
        });
      }
    }
    let selected = guides[0]?.pick || all[0];
    let matches = all;
    let chronological = [];
    let cure = null;
    let lastSevere = null;
    let reversal = null;
    let monthPage = 0;
    let monthView = 'all';
    let listedGroup = -1;
    const options = Object.entries(titles).filter(([key]) => all.some(a => a.remediation_treatment === key));
    root.setAttribute('aria-labelledby', 'ex-heading');
    root.innerHTML = `
      <h2 id="ex-heading">Account explorer</h2>
      <p class="ex-intro">Follow an account from the simulated bank issue to its proposed correction. Search all ${num(all.length)} evaluated accounts or open a guided case.</p>
      <p class="ex-provenance">${escapeText(data.meta.label)} · ${num(data.meta.monthCount)} account-months · ${policyLabel}${scopedFields ? ' · Episode-verified account fields' : priorFields ? ' · Earlier account-field policy (V1)' : ' · Account-field rules unverified in this export'}${data.meta.cureMonths ? ' · Cure threshold ' + escapeText(data.meta.cureMonths) + ' month' + (data.meta.cureMonths === 1 ? '' : 's') : ''}${queueHref ? ' · <a href="' + escapeText(queueHref) + '">Browse this study’s manual-review queue</a>' : ''}</p>
      <div class="ex-guides" role="group" aria-label="Guided cases">${guides.map(({label, pick}) =>
        '<button type="button" class="ex-guide" data-guide="' + escapeText(pick.account) + '" aria-pressed="false">' + escapeText(label) + '</button>').join('')}</div>
      <div class="ex-finder" role="search" aria-label="Account lookup">
        <div class="ex-filters">
          <label for="ex-find">Account ID<input type="search" inputmode="numeric" id="ex-find" placeholder="Enter all or part of an ID" autocomplete="off"></label>
          <label for="ex-treat">Treatment<select id="ex-treat"><option value="">All treatments</option>${options.map(([v, label]) => '<option value="' + v + '">' + label + '</option>').join('')}</select></label>
          <label for="ex-review">Follow-up<select id="ex-review"><option value="">All review outcomes</option><option value="1">Manual review</option><option value="0">No manual review</option>${(scopedFields || priorFields) ? '<option value="field">Account-field research</option>' : ''}</select></label>
        </div>
        <div class="ex-results">
          <label for="ex-ids"><span id="ex-count">Matching accounts</span><select id="ex-ids"></select></label>
          <button class="ex-step" type="button" id="ex-prev" aria-label="Previous matching account">Previous</button>
          <button class="ex-step" type="button" id="ex-next" aria-label="Next matching account">Next</button>
          <button class="ex-reset" type="button" id="ex-reset">Reset filters</button>
        </div>
      </div>
      <p id="ex-empty" hidden>No accounts match these filters. Reset the filters or try another ID.</p>
      <article id="ex-record" aria-labelledby="ex-account-heading"></article>
      <p id="ex-live" class="ex-sr" role="status" aria-live="polite"></p>`;
    const el = id => document.getElementById('ex-' + id);
    const filterControls = ['find', 'treat', 'review'].map(el);

    function resetFilters() {
      for (const control of filterControls) control.value = '';
    }

    function syncMatches(preferred = null, exactOnly = false) {
      const [input, treatment, review] = filterControls;
      const query = (exactOnly ? input.value : input.value.trim()).replace(/^0+(?=\d)/, '');
      matches = all.filter(a => (exactOnly ? formatId(a) === query : formatId(a).includes(query)) &&
        (!treatment.value || a.remediation_treatment === treatment.value) &&
        (!review.value || (review.value === 'field' ? Boolean(a.account_field_review_reason) : Number(hasReview(a)) === Number(review.value))));
      const exactId = query && matches.find(a => formatId(a) === query);
      selected = matches.includes(preferred) ? preferred : exactId || (matches.includes(selected) ? selected : matches[0]);
      listedGroup = -1;
      el('ids').disabled = !matches.length;
      el('count').textContent = plural(matches.length, 'matching account');
      el('reset').disabled = !exactOnly && !filterControls.some(c => c.value);
      el('empty').hidden = Boolean(selected);
      el('empty').textContent = exactOnly ? (/^\d+$/.test(input.value) ? 'Account ' + input.value + ' is absent from this cohort.' : 'This link contains an invalid account ID.') + ' Reset the filters to browse the available accounts.' : 'No accounts match these filters. Reset the filters or try another ID.';
      renderRecord();
    }

    function populateOptions(selectedIndex) {
      // A small teaching cohort fits in one native picker. Large retained snapshots
      // use groups with jump options, keeping every matching ID reachable.
      const groupSize = matches.length <= 2000 ? 2000 : 250;
      const group = Math.floor(Math.max(selectedIndex, 0) / groupSize);
      if (group === listedGroup) return;
      listedGroup = group;
      const begin = group * groupSize;
      const end = Math.min(begin + groupSize, matches.length);
      const options = document.createDocumentFragment();
      if (begin > 0) options.append(new Option('Earlier matching IDs', 'jump:' + (begin - 1)));
      for (let i = begin; i < end; i++) {
        const a = matches[i];
        options.append(new Option('Account ' + formatId(a) + ' · ' + titleFor(a), formatId(a)));
      }
      if (end < matches.length) options.append(new Option('Later matching IDs', 'jump:' + end));
      el('ids').replaceChildren(options);
    }

    function periodContext(a, row, proof) {
      const [date] = row;
      if (proof && date >= proof.start && date <= proof.confirmed) {
        if (date === proof.start && date === proof.confirmed) return 'Cure starts and is confirmed';
        if (date === proof.start) return 'Qualifying cure run starts';
        if (date === proof.confirmed) return 'Cure confirmed';
        return 'Cure run continues';
      }
      if (date === a.impact_start_date && date === a.impact_end_date) return 'Bank issue starts and ends';
      if (date === a.impact_start_date) return 'Bank issue starts';
      if (date === a.impact_end_date) return 'Bank issue ends';
      if (date > a.impact_start_date && date < a.impact_end_date) return 'During bank issue';
      if (inWindow(row)) return 'Credit impact continues';
      return date < a.credit_impact_start_date ? 'Before impact' : 'After credit window';
    }

    function treatmentReading(a, months, proof) {
      const changes = months.filter(isChanged).length;
      const derog = months.filter(r => inWindow(r) && isMajor(r[1]));
      const lastDerog = derog.at(-1);
      const chargeOff = derog.find(row => row[1] === 'L');
      function eventTiming(row) {
        const date = row[0];
        return (codeMeaning[row[1]] || 'Major derogatory status') + ' (' + escapeText(row[1]) + ') appears in ' + month(date) +
          (date <= a.impact_end_date ? ', during the bank issue. ' : ', after the bank issue ended and inside the credit-impact window. ');
      }
      switch (a.remediation_treatment) {
        case 'FULL_DEROGATORY_PHP_CLEANUP': {
          let evidence = '';
          if (current && lastSevere && reversal) {
            evidence = eventTiming(lastSevere) + 'This is the latest severe event inside the credit-impact window. In ' +
              month(reversal[0]) + ' the original history returns to payment reporting at ' + safeCode(reversal[1]) + ' (' +
              escapeText(codeMeaning[reversal[1]].toLowerCase()) + '). The sandbox treats that return as evidence of reversal. ' +
              (proof ? 'The separate cure test is satisfied in ' + month(proof.confirmed) + '. ' : 'The separate cure threshold remains unmet. ');
          } else if (chargeOff && proof && previous) {
            evidence = eventTiming(chargeOff) + 'A qualifying cure is confirmed in ' + month(proof.confirmed) + ', effective ' + month(proof.start) + '. ';
          } else if (lastSevere && reversal) {
            evidence = eventTiming(lastSevere) + 'In ' + month(reversal[0]) + ' the original record returns to payment performance (' + escapeText(reversal[1]) + '). ';
          }
          return evidence + 'The engine keeps the tradeline and replaces adverse codes with D in ' + plural(changes, 'affected month') + '.';
        }
        case 'SIMPLE_DELINQUENCY_PHP_CLEANUP':
          return 'The credit-impact window contains delinquency and no major derogatory code. The engine replaces ' + (num(changes) + (changes === 1 ? ' affected monthly entry' : ' affected monthly entries')) + ' with D.';
        case 'TRADELINE_DELETION': {
          if (current && lastSevere) {
            return eventTiming(lastSevere) + 'This is the latest severe event inside the credit-impact window. Through ' +
              month(proof ? proof.confirmed : a.php_left_byte_date) + ', no later original payment code from 0 through 6 follows that event. ' +
              'The severe status remains unresolved in the study, so the engine selects deletion of the entire tradeline (DA).';
          }
          if (chargeOff && !a.credit_cure_date && previous) {
            return eventTiming(chargeOff) + 'Through ' + month(a.php_left_byte_date) + ', the original history has no qualifying cure. This earlier policy used those two facts to select deletion of the entire tradeline (DA).';
          }
          const firstDerog = derog[0];
          const observed = firstDerog ? eventTiming(firstDerog) : '';
          if (!previous) {
            return observed + 'The saved output instructs deletion of the entire tradeline (DA).';
          }
          const last = lastDerog ? 'The last major derogatory mark in the window is in ' + month(lastDerog[0]) + '. ' : '';
          return observed + (derog.length > 1 ? last : '') + 'No later original payment code from 0 through 6 shows recovery after that mark. The engine proposes deletion of the entire tradeline (DA) and preserves the monthly records as evidence.';
        }
        case 'NO_IMPACT_CLEAN_PHP_HISTORY':
          return 'The credit-impact window contains no delinquency or major derogatory code. The engine selects no correction and closes the review path.';
        default:
          return 'The result below comes from the account’s recorded treatment and field outputs.';
      }
    }

    function followupReading(a) {
      if (a.remediation_treatment === 'TRADELINE_DELETION') return 'The deletion instruction closes the ongoing-review route. The original months remain available to explain the decision.';
      if (hasReview(a)) return (reasons[a.manual_review_reason] || 'The engine flags this account for manual review.') + ' A monthly reviewer would keep the same bank issue dates and request ' + month(nextMonth(a.php_left_byte_date)) + ' original payment history from the ' + nextMonth(nextMonth(a.php_left_byte_date)) + ' reporting snapshot.';
      if (a.credit_cure_date) return 'The original history meets the cure threshold. The engine leaves the account out of the review queue.';
      if (a.remediation_treatment === 'NO_IMPACT_CLEAN_PHP_HISTORY') return 'A clean credit-impact window closes the review path even without an observed cure.';
      return 'The account has a closed status. Under the sandbox rules this case has no further monthly review.';
    }

    function renderRecord() {
      const a = selected;
      const idx = matches.indexOf(a);
      populateOptions(idx);
      el('prev').disabled = idx <= 0;
      el('next').disabled = idx < 0 || idx >= matches.length - 1;
      for (const button of root.querySelectorAll('[data-guide]')) button.setAttribute('aria-pressed', String(a != null && button.dataset.guide === formatId(a)));
      el('record').hidden = !a;
      if (!a) {
        el('record').replaceChildren();
        el('live').textContent = el('empty').textContent;
        return;
      }
      el('ids').value = formatId(a);
      chronological = a.months.slice().sort((x, y) => x[0].localeCompare(y[0]));
      const deleted = a.remediation_treatment === 'TRADELINE_DELETION';
      const changed = chronological.filter(isChanged).length;
      cure = cureEvidence(a, chronological);
      lastSevere = chronological.filter(row => inWindow(row) && isMajor(row[1])).at(-1) || null;
      const evidenceThrough = current && cure ? cure.confirmed : a.php_left_byte_date;
      reversal = lastSevere && chronological.find(row => row[0] > lastSevere[0] && row[0] <= evidenceThrough && /^[0-6]$/.test(row[1]));
      const endMark = chronological.find(row => row[0] === a.impact_end_date);
      const endReading = endMark ? 'At the end of the bank issue the original history shows ' +
        safeCode(endMark[1]) + ' (' + escapeText((codeMeaning[endMark[1]] || 'other history').toLowerCase()) + '). ' : '';
      const changesAfterIssue = chronological.filter(row => row[0] > a.impact_end_date && isChanged(row)).length;
      const extension = changesAfterIssue ? 'The proposed cleanup also changes ' + plural(changesAfterIssue, 'month') + ' after the bank issue ends.' : '';
      monthView = 'all';
      const firstChange = chronological.findIndex(isChanged);
      const decisionMonth = current && lastSevere ? chronological.indexOf(lastSevere) :
        deleted ? chronological.findIndex(row => inWindow(row) && row[1] === 'L') : -1;
      const start = decisionMonth >= 0 ? decisionMonth : firstChange >= 0 ? firstChange : chronological.findIndex(inWindow);
      monthPage = Math.max(0, Math.floor(start / pageSize));
      function originalCell(key) {
        if (a[key] != null) return safeCode(a[key]);
        return key === 'date_of_first_delinquency' ? 'No date stored' : 'Blank';
      }
      function replacementCell(key) {
        if (a['clear_' + key] === true) return key === 'date_of_first_delinquency' ? 'Clear stored date' : 'Clear to blank';
        const value = a['remediated_' + key];
        return value == null ? 'No replacement emitted' : safeCode(value);
      }
      const clearFlags = fields.slice(0, 3).every(([, key]) => typeof a['clear_' + key] === 'boolean');
      const derivedChanges = a.remediation_treatment.endsWith('_CLEANUP') ? fields.slice(0, 3).flatMap(([name, key]) => {
        const replacement = a['remediated_' + key];
        if (a['clear_' + key] === true) return [key === 'date_of_first_delinquency' ? 'The correction calls for clearing the stored Date of First Delinquency.' : name + ' is cleared to blank.'];
        if (replacement == null) return [];
        const original = a[key] == null ? 'blank' : escapeText(a[key]);
        return [name + ' changes from ' + original + ' to ' + escapeText(replacement) + '.'];
      }).join(' ') : '';
      const heldAtUnknown = scopedFields && a.full_php[0] === 'D' && changed && !deleted && clearFlags &&
        fields.slice(0, 3).every(([, key]) => a['clear_' + key] === false && a['remediated_' + key] == null);
      const kept = heldAtUnknown ? ' The latest original month, ' + month(a.php_left_byte_date) + ', already records D (no payment history). It supplies no evidence of payment or cure. The correction keeps the sourced status ' + (a.account_status_17a == null ? '(blank)' : escapeText(a.account_status_17a)) + ', internal rating ' + (a.payment_rating_17b == null ? '(blank)' : escapeText(a.payment_rating_17b)) + ' and ' + (a.date_of_first_delinquency ? 'stored delinquency date ' + escapeText(a.date_of_first_delinquency) : 'empty delinquency date') + '.' : '';
      const assumption = current && scopedFields ? window.metro2Field25?.render(a, field25Guide) : '';
      const ratingChanged = a.remediated_payment_rating_17b != null || a.clear_payment_rating_17b === true;
      const ratingNote = ratingChanged && window.metro2Field25?.standardRating ? ' ' + escapeText(window.metro2Field25.standardRating(a)) : '';
      el('record').innerHTML = `
        <header class="ex-casehead" id="account=${encodeURIComponent(a.account)}"><div><h3 id="ex-account-heading">Account ${escapeText(a.account)}</h3><p class="ex-profile">Synthetic profile · ${escapeText(humanize(a.profile_type))}</p></div><a href="#account=${encodeURIComponent(a.account)}" class="ex-case-link">Link to account</a></header>
        <section class="ex-timing" aria-labelledby="ex-timing-title"><h4 id="ex-timing-title">When did the issue and its credit impact end?</h4>
          <p class="ex-asof">Account status (17A) as of <strong>${escapeText(a.latest_doai)}</strong> · Original payment history through <strong>${month(a.php_left_byte_date)}</strong></p>
          <table class="ex-dates"><caption class="ex-sr">Bank issue, credit impact and qualifying cure months for account ${escapeText(a.account)}</caption>
          <thead><tr><th scope="col">Period</th><th scope="col">Start month</th><th scope="col">End month</th></tr></thead>
          <tbody><tr><th scope="row">Bank issue</th><td>${month(a.impact_start_date)}</td><td>${month(a.impact_end_date)}</td></tr>
          <tr><th scope="row">Credit-impact window</th><td>${month(a.credit_impact_start_date)}</td><td>${month(a.credit_impact_end_date)}<small>${cure ? 'Month before cure starts' : 'Provisional through latest evidence'}</small></td></tr>
          <tr><th scope="row">Qualifying cure period<small>${plural(a.cure_consecutive_months_required, 'consecutive current month')} required</small></th><td>${a.credit_cure_date ? month(a.credit_cure_date) : 'None established'}</td><td>${cure ? month(cure.confirmed) + '<small>Threshold confirmed</small>' : 'No confirmation'}</td></tr></tbody></table>
          <p class="ex-cure">${endReading}${extension}</p>
          <p class="ex-cure">${cureReading(a, chronological, cure)}</p>
        </section>
        <div class="ex-decision"><div><h4>${escapeText(titleFor(a))}</h4><p>${treatmentReading(a, chronological, cure)} ${derivedChanges}${ratingNote}${kept}</p></div>
          <div><h4>${hasReview(a) ? 'Manual review' : 'No manual review'}</h4><p>${followupReading(a)}${hasReview(a) && queueHref ? ' <a href="' + escapeText(queueHref) + '#account=' + encodeURIComponent(a.account) + '">Open this case in the review queue</a>' : ''}</p></div></div>
        ${assumption || ''}
        ${window.metro2Field25?.accountFieldNote?.(a) || ''}
        <div class="ex-historyhead"><div><h4>${deleted ? 'Monthly evidence for deletion' : 'Monthly payment history'}</h4>
          <p>${deleted ? 'Applying DA removes the entire tradeline. No monthly payment history would be furnished for it afterward. The audit record retains ' + plural(chronological.length, 'original month') + ' as evidence.' : plural(changed, 'changed month') + ' across ' + plural(chronological.length, 'represented month') + '. Read from oldest to newest.'}</p></div>
          <label for="ex-month-filter">Show months<select id="ex-month-filter"><option value="all">All months</option><option value="window">Credit-impact window</option>${current && lastSevere ? '<option value="decision">Severe-event evidence</option>' : ''}${deleted ? '<option value="derog">Major events in the window</option>' : '<option value="changed">Changed months</option>'}</select></label></div>
        <div id="ex-months"></div>
        <details class="ex-fields"><summary>Account fields and replacement values</summary>
          <table><caption class="ex-sr">Account ${escapeText(a.account)} field values</caption>
            <thead><tr><th scope="col">Field</th><th scope="col">Original value</th><th scope="col">Engine instruction</th></tr></thead>
            <tbody>${fields.map(([label, key]) => '<tr><th scope="row">' + label + '</th><td>' + originalCell(key) + '</td><td>' + replacementCell(key) + '</td></tr>').join('')}</tbody>
          </table>
          <p class="ex-standard-rating">${window.metro2Field25?.standardRating ? escapeText(window.metro2Field25.standardRating(a)) : ''} <a href="${escapeText(field25Guide.replace('#field-25', '#field-17b'))}">Field 17B guidance</a></p>
          <p>${clearFlags ? '“Clear stored date” is a SQL instruction. For a retained tradeline, a false clear flag and an empty replacement carry the existing date forward.' : 'This export lacks complete field-clear flags. An empty replacement with no clear flag can mean either an unchanged value or a request to clear the stored value.'} Full simulated history is stored newest first.</p>
          <p>The 2020 guide uses <code>00000000</code> in the 426-character record when Field 25 calls for zero fill. Consumer indicators can change the applicable rule. Confirm the current instructions in CDIA’s access-controlled guide. <a href="${escapeText(field25Guide)}">Field 25 guidance and exceptions</a></p>
        </details>`;
      renderMonths();
      el('live').textContent = plural(matches.length, 'matching account') + '. Showing account ' + formatId(a) + ', ' + titleFor(a) + '.';
    }

    function renderMonths() {
      const deleted = selected.remediation_treatment === 'TRADELINE_DELETION';
      const rows = chronological.filter(row => {
        if (monthView === 'all') return true;
        if (monthView === 'decision') return row === lastSevere || row === reversal;
        if (monthView === 'changed') return isChanged(row);
        return inWindow(row) && (monthView !== 'derog' || isMajor(row[1]));
      });
      if (!rows.length) {
        el('months').innerHTML = '<p class="ex-month-empty">No months meet this selection.</p>';
        return;
      }
      const start = monthPage * pageSize;
      const end = Math.min(start + pageSize, rows.length);
      const markedCode = s => '<span class="ex-code ex-' + classification(s) + '"><b>' + escapeText(s) + '</b><span>' + (codeMeaning[s] || 'Other history') + '</span></span>';
      el('months').innerHTML = `<div class="ex-month-nav"><span>Months ${num(start + 1)}–${num(end)} of ${num(rows.length)}</span><div>
        <button type="button" class="ex-step" data-period="-1" ${start ? '' : 'disabled'}>Earlier</button>
        <button type="button" class="ex-step" data-period="1" ${end < rows.length ? '' : 'disabled'}>Later</button></div></div>
        <table class="ex-month-table"><caption class="ex-sr">Monthly detail for account ${escapeText(selected.account)}</caption>
        <thead><tr><th scope="col">Month</th><th scope="col">${deleted ? 'Original evidence' : 'Original'}</th>${deleted ? '' : '<th scope="col">After treatment</th>'}<th scope="col">Timing</th></tr></thead>
        <tbody>${rows.slice(start, end).map(row => {
          const after = deleted ? '' : '<td>' + markedCode(row[2]) + (isChanged(row) ? '<small class="ex-change-label">Changed</small>' : '') + '</td>';
          const event = current && row === lastSevere ? '<br><small>Latest severe event in the window</small>' :
            current && row === reversal ? '<br><small>First original payment code after the severe event</small>' : '';
          return '<tr' + (isChanged(row) ? ' class="ex-changed"' : '') + '><th scope="row">' + month(row[0]) + '</th><td>' + markedCode(row[1]) + '</td>' + after + '<td>' + periodContext(selected, row, cure) + event + '</td></tr>';
        }).join('')}</tbody></table>`;
    }

    function useGuide(a) {
      resetFilters();
      syncMatches(a);
    }

    function hashId() {
      return location.hash.startsWith('#account=') ? location.hash.slice('#account='.length) : null;
    }

    function openLinked() {
      const id = hashId() ?? (location.hash === '#explorer' || !location.hash ? new URLSearchParams(location.search).get('account') : null);
      if (id === null) return false;
      const a = /^\d+$/.test(id) ? byId.get(id.replace(/^0+(?=\d)/, '')) : null;
      if (a) {
        useGuide(a);
        root.scrollIntoView();
      } else {
        resetFilters();
        el('find').value = id;
        syncMatches(null, true);
        root.scrollIntoView();
      }
      return true;
    }

    function syncLink() {
      // Avoid adding a history entry for every keystroke or filter change.
      if (hashId() === null && !new URLSearchParams(location.search).has('account')) return;
      const url = new URL(location.href);
      url.searchParams.delete('account');
      url.hash = selected ? 'account=' + encodeURIComponent(selected.account) : 'explorer';
      try { history.replaceState(history.state, '', url); } catch { /* Downloaded files can have a restricted origin. */ }
    }

    root.addEventListener('input', event => {
      if (event.target === el('find')) { syncMatches(); syncLink(); }
    });
    root.addEventListener('change', event => {
      const target = event.target;
      if (target === el('treat') || target === el('review')) { syncMatches(); syncLink(); }
      if (target === el('ids')) {
        selected = target.value.startsWith('jump:') ? matches[Number(target.value.slice(5))] : byId.get(target.value);
        renderRecord();
        syncLink();
      }
      if (target === el('month-filter')) { monthView = target.value; monthPage = 0; renderMonths(); }
    });
    root.addEventListener('click', event => {
      const btn = event.target.closest('button');
      if (!btn || btn.disabled) return;
      if (btn.dataset.guide) { useGuide(byId.get(btn.dataset.guide)); syncLink(); }
      if (btn === el('reset')) { resetFilters(); syncMatches(selected); syncLink(); }
      if (btn === el('prev') || btn === el('next')) {
        selected = matches[matches.indexOf(selected) + (btn === el('prev') ? -1 : 1)];
        renderRecord();
        syncLink();
      }
      if (btn.dataset.period) {
        monthPage += Number(btn.dataset.period);
        renderMonths();
        const same = root.querySelector('[data-period="' + btn.dataset.period + '"]');
        (same.disabled ? root.querySelector('[data-period]:not(:disabled)') : same)?.focus();
        el('live').textContent = root.querySelector('.ex-month-nav > span').textContent;
      }
    });
    window.addEventListener('hashchange', openLinked);
    if (!openLinked()) syncMatches(selected);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true});
  else start();
})();
