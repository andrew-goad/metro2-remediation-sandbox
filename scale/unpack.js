(() => {
  'use strict';
  const packed = window.METRO2_PACKED;
  if (!packed) return;
  // Dates in the validated export are consecutive month starts. Histories are
  // stored newest first, and a null revised history means the bytes agree.
  const record = {
    get months() {
      const date = new Date(this.php_left_byte_date + 'T00:00:00Z');
      const revised = this.remediated_full_php ?? this.full_php;
      return Array.from(this.full_php, (before, i) => {
        const period = date.toISOString().slice(0, 10);
        const inside = Number(period >= this.credit_impact_start_date && period <= this.credit_impact_end_date);
        date.setUTCMonth(date.getUTCMonth() - 1);
        return [period, before, revised[i], inside];
      });
    }
  };
  const accounts = packed.rows.map(values => {
    const a = Object.create(record);
    packed.fields.forEach((key, i) => {
      const value = values[i];
      const book = packed.dictionaries[key];
      a[key] = value != null && book ? book[value] : value;
    });
    return a;
  });
  window.METRO2_DATA = {accounts, meta: packed.meta, guideIds: packed.guideIds};
  delete window.METRO2_PACKED;
})();
