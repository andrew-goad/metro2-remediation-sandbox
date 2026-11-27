(() => {
  'use strict';
  const byId = id => document.getElementById(id);
  const data = window.METRO2_DATA;
  if (!data || !Array.isArray(data.accounts)) {
    byId('queue-error').textContent = 'The account data could not be loaded. The reviewer files are available above.';
    byId('queue-error').hidden = false;
    return;
  }
  const app = byId('queue-app');
  if (data.meta?.policyId !== 'REVERSAL_AWARE_SEVERE_V2' || data.meta.accountFieldPolicy !== 'EVIDENCE_SCOPED_FIELDS_V2' || data.meta.sourceKind !== 'replay' ||
      data.accounts.length !== 25000 || data.meta.snapshotUTC !== app.dataset.studySnapshot) {
    byId('queue-error').textContent = 'The loaded account data comes from another study. Use the reviewer files above for this published 25,000-account queue.';
    byId('queue-error').hidden = false;
    return;
  }
  const reasons = {
    INSUFFICIENT_POST_IMPACT_HISTORY: {
      short: 'Too little history',
      explanation: 'Too few original reporting months follow the end of the bank issue to test the full cure period.',
      action: 'Collect the next original reporting month and reassess cure.'
    },
    NO_CURE_OPEN_ACCOUNT: {
      short: 'Cure unestablished',
      explanation: 'Enough original reporting months follow the bank issue to test for cure. The account remains open and has yet to meet the threshold.',
      action: 'Review the unresolved impact and reassess cure with the next original reporting month.'
    }
  };
  const treatments = {
    SIMPLE_DELINQUENCY_PHP_CLEANUP: 'Delinquency history cleanup',
    FULL_DEROGATORY_PHP_CLEANUP: 'Derogatory history cleanup'
  };
  const severeNames = {G: 'collection', H: 'foreclosure', J: 'voluntary surrender', K: 'repossession', L: 'charge-off'};
  const paymentNames = ['current', '30–59 days past due', '60–89 days past due', '90–119 days past due',
    '120–149 days past due', '150–179 days past due', '180+ days past due'];
  const queue = data.accounts.filter(a => a.manual_review_flag === 1).sort((a, b) =>
    a.php_left_byte_date.localeCompare(b.php_left_byte_date) || a.account - b.account);
  const formatNumber = new Intl.NumberFormat('en-US');
  const formatMonth = new Intl.DateTimeFormat('en-US', {month: 'short', year: 'numeric', timeZone: 'UTC'});
  const count = value => formatNumber.format(value);
  const shiftMonth = (s, offset) => {
    const d = new Date(s + 'T00:00:00Z');
    d.setUTCMonth(d.getUTCMonth() + offset);
    return d.toISOString().slice(0, 10);
  };
  const displayMonth = date => formatMonth.format(new Date(date + 'T00:00:00Z'));
  const flags = byId('reason-controls').querySelectorAll('[data-reason]');
  const perPage = 8;
  let reason = '', search = '', page = 0, rows = [], selected = null;
  let pickedRow = false;

  byId('count-all').textContent = count(queue.length);
  byId('count-short').textContent = count(queue.filter(a => a.manual_review_reason === 'INSUFFICIENT_POST_IMPACT_HISTORY').length);
  byId('count-open').textContent = count(queue.filter(a => a.manual_review_reason === 'NO_CURE_OPEN_ACCOUNT').length);
  byId('queue-app').hidden = false;
  if (data.meta.accountFieldPolicy === 'EVIDENCE_SCOPED_FIELDS_V2') {
    const research = data.accounts.filter(a => a.account_field_review_reason);
    const missing = research.filter(a => a.account_field_review_reason === 'MISSING_REQUIRED_PAYMENT_RATING');
    const missingDates = missing.filter(a => ['65', '88', '89', '94', '95'].includes(a.account_status_17a) && !a.date_of_first_delinquency).length;
    byId('field-research-count').textContent = research.length
      ? count(research.length) + ' retained accounts need account-field research. ' + (missing.length ? count(missing.length) + ' have a missing payment rating required under the historical status rules. ' : '') + (missingDates ? count(missingDates) + ' of those also lack a delinquency date required directly by their status. ' : '') + 'Servicing verifies the source evidence. The CSV identifies each account, the reason and the applicable date test.'
      : 'This study flagged zero accounts for separate account-field research. The CSV contains its column headings.';
    byId('account-field-research').hidden = false;
  }

  function detail(a) {
    const panel = byId('queue-detail');
    panel.replaceChildren();
    panel.hidden = !a;
    if (!a) return;
    const why = reasons[a.manual_review_reason];
    // Newest-first original PHP. A current month at bank-issue end is outside the cure test.
    const afterIssue = a.full_php.slice(0, a.post_impact_month_count);
    const streak = afterIssue.match(/^0*/)[0].length;
    const latest = a.php_left_byte_date;
    const required = a.cure_consecutive_months_required;
    const next = displayMonth(shiftMonth(latest, 1));
    const streakText = streak ? 'The current run began in ' + displayMonth(shiftMonth(latest, 1 - streak)) + '.' :
      'There is no active post-issue run of current months.';
    const dates = [
      ['Bank issue starts', displayMonth(a.impact_start_date)],
      ['Bank issue ends', displayMonth(a.impact_end_date)],
      ['Credit-impact window', displayMonth(a.credit_impact_start_date) + ' – ' + displayMonth(a.credit_impact_end_date) + ' (provisional end)'],
      ['Latest original history', displayMonth(latest)],
      ['Next history to request', next],
      ['Cure start / confirmation', 'Neither established'],
      ['Account status (17A) as of', a.latest_doai],
      ['Snapshot for next history month', shiftMonth(latest, 2)]
    ];
    const field25 = window.metro2Field25.render(a, '../index.html#field-25');
    let severe = '';
    let action = why.action;
    if (a.last_severe_month && a.severe_reversal_month) {
      const months = a.months;
      const event = months.find(row => row[0] === a.last_severe_month);
      const returned = months.find(row => row[0] === a.severe_reversal_month);
      if (event && returned) {
        severe = '<p class="case-severe">The latest severe event in the window was ' + severeNames[event[1]] + ' (' + event[1] + ') in ' +
          displayMonth(event[0]) + '. In ' + displayMonth(returned[0]) + ' the original history returned to payment reporting at ' +
          returned[1] + ' (' + paymentNames[Number(returned[1])] + '). The sandbox treats that return as evidence of reversal. This account still needs the full run of current months to establish cure.</p>';
        action = 'Severe month ' + event[0].slice(0, 7) + '. Reversal proxy ' + returned[0].slice(0, 7) +
          '. Verify the reversal in servicing records and reassess cure with the next original month.';
      }
    }
    panel.innerHTML = '<h3 tabindex="-1" id="selected-heading">Account ' + a.account + '</h3><p>' + why.explanation + '</p>' +
      '<dl>' + dates.map(([label, value]) => '<dt>' + label + '</dt><dd>' + value + '</dd>').join('') + '</dl>' +
      '<h4>Progress toward cure</h4><p><strong>' + streak + ' of ' + required + ' consecutive current months</strong> as of ' +
      displayMonth(latest) + '. ' + streakText + ' Original performance covers ' + a.post_impact_month_count +
      ' post-issue month' + (a.post_impact_month_count === 1 ? '' : 's') + '.</p>' +
      '<div class="decision"><h4>Proposed correction</h4><p>' + treatments[a.remediation_treatment] +
      '. The study keeps this tradeline and proposes changes to affected monthly entries.</p>' + severe + field25 + '<h4>Next review action</h4><p>' + action + '</p></div>' +
      window.metro2Field25.accountFieldNote(a) + '<a class="full-record" href="../scale/index.html#account=' + encodeURIComponent(a.account) + '">Open original history and proposed field changes</a>';
  }

  function render() {
    for (const button of flags) button.setAttribute('aria-pressed', String(button.dataset.reason === reason));
    const n = rows.length, totalPages = Math.ceil(n / perPage);
    const start = page * perPage;
    const visible = rows.slice(start, start + perPage);
    byId('queue-table').hidden = !n;
    byId('queue-pages').hidden = !n;
    byId('queue-prev').disabled = page === 0;
    byId('queue-next').disabled = page + 1 >= totalPages;
    byId('queue-page').textContent = n ? 'Page ' + count(page + 1) + ' of ' + count(totalPages) : '';
    byId('queue-matches').textContent = n ? 'Showing ' + count(start + 1) + '–' + count(start + visible.length) + ' of ' + count(n) +
      ' matching account' + (n === 1 ? '.' : 's.') : 'No flagged account matches this selection. Reset to see the full queue.';
    byId('queue-rows').innerHTML = visible.map(a =>
      '<tr><td><button type="button" data-account="' + a.account + '" aria-label="Show account ' + a.account +
      '" aria-current="' + (a === selected) + '">' + a.account + '</button></td><td>' + reasons[a.manual_review_reason].short +
      '</td><td>' + displayMonth(shiftMonth(a.php_left_byte_date, 1)) + '</td></tr>').join('');
    detail(selected);
  }

  function filter(pageIndex = 0, account = null) {
    const canonical = /^\d+$/.test(search) ? search.replace(/^0+(?=\d)/, '') : search;
    rows = queue.filter(a => (!reason || a.manual_review_reason === reason) && (!search || String(a.account) === canonical));
    const index = account ? rows.findIndex(a => String(a.account) === account) : -1;
    pickedRow = index >= 0;
    const maxPage = Math.max(0, Math.ceil(rows.length / perPage) - 1);
    page = pickedRow ? Math.floor(index / perPage) : Math.min(pageIndex, maxPage);
    selected = (pickedRow ? rows[index] : rows[page * perPage]) || null;
    render();
  }

  // Exact searches use #account=ID. A table selection also records its listing
  // page and reason, so the shared case and the surrounding queue both reopen.
  function writeAddress(replace = false) {
    const params = new URLSearchParams();
    if (selected && (search || pickedRow)) params.set('account', String(selected.account));
    else if (search) params.set('q', search);
    if (reason) params.set('reason', reason);
    if (!search && (page > 0 || pickedRow)) params.set('page', String(page + 1));
    const url = new URL(location.href);
    url.hash = params.toString();
    if (url.href !== location.href) {
      try {
        if (replace) history.replaceState(null, '', url);
        else history.pushState(null, '', url);
      } catch (error) {
        if (error.name !== 'SecurityError') throw error;
        if (replace) location.replace(url.href);
        else location.hash = url.hash;
      }
    }
  }

  function setPage(nextPage) {
    page = nextPage;
    pickedRow = false;
    selected = rows[page * perPage];
    render();
    writeAddress();
  }
  function openLocation() {
    const params = new URLSearchParams(location.hash.slice(1));
    const selectedReason = params.get('reason');
    reason = Object.hasOwn(reasons, selectedReason) ? selectedReason : '';
    const id = (params.get('account') || '').trim().replace(/^0+(?=\d)/, '');
    const pageParam = params.get('page');
    const pageNumber = /^\d+$/.test(pageParam) && Number.isSafeInteger(Number(pageParam)) ? Number(pageParam) : 0;
    const inList = id && pageNumber > 0 && queue.some(a => String(a.account) === id && (!reason || a.manual_review_reason === reason));
    search = inList ? '' : (id || params.get('q') || '').trim();
    byId('queue-id').value = search;
    filter(Math.max(0, pageNumber - 1), inList ? id : null);
    if (['account','reason','page','q'].some(key => params.has(key))) writeAddress(true);
  }
  for (const button of flags) button.addEventListener('click', () => {
    reason = button.dataset.reason;
    filter();
    writeAddress();
  });
  const featured = window.metro2Field25.workedCases(id => queue.find(a => a.account === id));
  if (featured.length) {
    const examples = byId('queue-examples');
    examples.innerHTML = featured.map(({label, pick}) => '<a href="#account=' + pick.account + '">' + label + '</a>').join(' · ');
    examples.hidden = false;
    examples.addEventListener('click', event => {
      const link = event.target.closest('a');
      if (link && location.hash === link.hash) openLocation();
    });
  }
  byId('queue-lookup').addEventListener('submit', event => {
    event.preventDefault();
    search = byId('queue-id').value.trim();
    filter();
    writeAddress();
  });
  byId('queue-reset').addEventListener('click', () => {
    reason = search = byId('queue-id').value = '';
    filter();
    writeAddress();
  });
  byId('queue-prev').addEventListener('click', () => { if (page > 0) setPage(page - 1); });
  byId('queue-next').addEventListener('click', () => { if ((page + 1) * perPage < rows.length) setPage(page + 1); });
  byId('queue-rows').addEventListener('click', event => {
    const button = event.target.closest('button[data-account]');
    if (!button) return;
    selected = rows.find(a => String(a.account) === button.dataset.account);
    pickedRow = !search;
    render();
    writeAddress();
    byId('selected-heading').focus();
  });
  window.addEventListener('hashchange', openLocation);
  openLocation();
})();
