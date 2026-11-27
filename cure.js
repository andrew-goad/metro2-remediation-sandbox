(() => {
  const steps = [
    ['March ends the bank issue with the account still delinquent.', 'The bank issue began in April 2024. February carries an original 1 and March a 2. March closes the financial period. A post-issue cure streak can first begin in April.'],
    ['April extends the credit impact by one month.', 'April carries an original 1. The account improved from March’s 2, but it remains delinquent. April joins February and March as a month eligible for correction. No current streak has begun.'],
    ['May is the first possible cure month.', 'May carries an original 0. The evidence now includes one consecutive current month after the April delinquency. Two more current months would confirm May as the effective cure month.'],
    ['June supplies the second current month.', 'May and June carry original zeros. With April’s 1, three post-issue observations are available, but only two are consecutive current months. The case still needs review.'],
    ['July confirms the cure that began in May.', 'May, June and July each carry an original 0. The credit window closes at April. The proposed history replaces February’s 1, March’s 2 and April’s 1 with D. The account leaves the review queue.']
  ];
  const group = document.querySelector('#cure .month-row');
  group.addEventListener('click', event => {
    const button = event.target.closest('button[data-month]');
    if (!button) return;
    for (const option of group.querySelectorAll('button')) {
      option.setAttribute('aria-pressed', String(option === button));
    }
    const [heading, description] = steps[Number(button.dataset.month)];
    document.getElementById('cure-label').textContent = heading;
    document.getElementById('cure-description').textContent = description;
  });
  const cohort = window.METRO2_DATA;
  const publishedSnapshot = document.getElementById('explorer')?.dataset.studySnapshot;
  if (publishedSnapshot && publishedSnapshot === cohort?.meta?.snapshotUTC && cohort.meta.sourceKind === 'replay' && cohort.meta.policyId === 'REVERSAL_AWARE_SEVERE_V2' && cohort.accounts.length === 1000) {
    // Worked-case links describe the dated teaching examples. Link only when
    // the selected cohort includes the same history, window, cure and outcome.
    const expected = {
      175: ['0000012100000000000000000000000000000000000000000','2024-04-01','2025-03-01','2025-04-01','2025-05-01','SIMPLE_DELINQUENCY_PHP_CLEANUP',0],
      327: ['012345L543210000000000','2024-12-01','2025-01-01','2025-09-01',null,'FULL_DEROGATORY_PHP_CLEANUP',1],
      958: ['6543210000000','2025-04-01','2025-05-01','2025-09-01',null,'SIMPLE_DELINQUENCY_PHP_CLEANUP',1],
      987: ['LLLL654321000000000000000','2023-02-01','2023-11-01','2023-11-01',null,'TRADELINE_DELETION',0]
    };
    const fields = ['full_php','impact_start_date','impact_end_date','credit_impact_end_date','credit_cure_date','remediation_treatment','manual_review_flag'];
    for (const link of document.querySelectorAll('[data-replay-link]')) {
      const id = Number(link.hash.slice('#account='.length));
      const row = cohort.accounts.find(a => a.account === id);
      link.hidden = !(row && expected[id] && fields.every((field, i) => row[field] === expected[id][i]));
    }
  }
})();
