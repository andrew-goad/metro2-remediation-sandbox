(() => {
  'use strict';
  const count = document.getElementById('accounts');
  const cure = document.getElementById('threshold');
  const code = document.getElementById('recipe');
  const original = code.textContent;
  const copy = document.getElementById('copy-recipe');
  const message = document.getElementById('recipe-status');
  function update() {
    const valid = count.checkValidity() && /^\d+$/.test(count.value);
    count.setAttribute('aria-invalid', String(!valid));
    code.textContent = valid ? original.replace('-AccountCount 1000 -CureMonths 3', '-AccountCount ' + Number(count.value) + ' -CureMonths ' + cure.value) : '';
    copy.disabled = !valid;
    message.textContent = valid ? '' : 'Enter a whole number of accounts between 1 and 2,147,483,647.';
  }
  count.addEventListener('input', update);
  cure.addEventListener('change', update);
  copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(code.textContent);
      message.textContent = 'PowerShell commands copied.';
    } catch {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
      message.textContent = 'Commands selected. Press Ctrl+C or Command+C to copy.';
    }
  });
  update();
})();
