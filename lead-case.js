(() => {
  const caseTrace = document.querySelector('.lead-trace');
  if (!caseTrace) return;
  const detail = caseTrace.querySelector('.trace-detail');
  const months = caseTrace.querySelectorAll('.trace-buttons button');
  for (const button of months) {
    button.addEventListener('click', () => {
      for (const month of months) {
        month.setAttribute('aria-pressed', String(month === button));
      }
      detail.querySelector('h3').textContent = button.dataset.date;
      detail.querySelector('p').textContent = button.dataset.why;
    });
  }
})();
