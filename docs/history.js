(() => {
  const section = document.querySelector('.worked-cases');
  if (!section) return;

  const controls = section.querySelector('.wc-switch');
  const buttons = Array.from(controls.querySelectorAll('button[aria-controls]'));
  const cases = section.querySelectorAll('.wc-record');

  function showCase(button) {
    const selectedId = button.getAttribute('aria-controls');
    cases.forEach(record => { record.hidden = record.id !== selectedId; });
    buttons.forEach(choice => choice.setAttribute('aria-pressed', String(choice === button)));
  }

  controls.hidden = false;
  buttons.forEach(button => button.addEventListener('click', () => showCase(button)));
  showCase(buttons[0]);

  const reader = section.querySelector('.wc-history');
  if (!reader) return;
  const months = Array.from(reader.querySelectorAll('.wc-months button'));
  function readMonth(button) {
    months.forEach(month => month.setAttribute('aria-pressed', String(month === button)));
    const {label, original, proposed, why} = button.dataset;
    reader.querySelector('[data-reading-label]').textContent = label;
    reader.querySelector('[data-reading-original]').textContent = original;
    reader.querySelector('[data-reading-proposed]').textContent = proposed;
    reader.querySelector('[data-reading-why]').textContent = why;
  }
  months.forEach((button, index) => {
    button.addEventListener('click', () => readMonth(button));
    button.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowLeft') next = Math.max(index - 1, 0);
      else if (event.key === 'ArrowRight') next = Math.min(index + 1, months.length - 1);
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = months.length - 1;
      else return;
      event.preventDefault();
      months[next].focus();
      readMonth(months[next]);
    });
  });
})();
