export function measure(samples, period) {
  if (!samples.length) return { min: 0, max: 0, mean: 0, rms: 0, acRms: 0, pp: 0, frequency: null };
  let min = Infinity, max = -Infinity, sum = 0, squares = 0;
  for (const x of samples) { min = Math.min(min, x); max = Math.max(max, x); sum += x; squares += x * x; }
  const mean = sum / samples.length, rms = Math.sqrt(squares / samples.length), pp = max - min;
  const crossings = []; let armed = false;
  if (pp > 1e-5) for (let i = 1; i < samples.length; i++) {
    if (samples[i] < mean - pp * .1) armed = true;
    if (armed && samples[i - 1] < mean && samples[i] >= mean) {
      crossings.push(i - 1 + (mean - samples[i - 1]) / (samples[i] - samples[i - 1])); armed = false;
    }
  }
  const frequency = crossings.length > 1 ? (crossings.length - 1) / ((crossings.at(-1) - crossings[0]) * period) : null;
  return { min, max, mean, rms, acRms: Math.sqrt(Math.max(0, rms * rms - mean * mean)), pp, frequency };
}
export function spectrum(samples, period) {
  const n = 2 ** Math.floor(Math.log2(samples.length));
  if (n < 8) return { bins: [], peak: null, resolution: 0 };
  const real = new Float64Array(n), imag = new Float64Array(n); let weight = 0;
  for (let i = 0; i < n; i++) { const w = .5 - .5 * Math.cos(2 * Math.PI * i / (n - 1)); weight += w; real[i] = samples[i] * w; }
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit;
    if (i < j) [real[i], real[j]] = [real[j], real[i]];
  }
  for (let length = 2; length <= n; length *= 2) {
    const angle = -2 * Math.PI / length;
    for (let i = 0; i < n; i += length) for (let k = 0; k < length / 2; k++) {
      const a = i + k, b = a + length / 2, wr = Math.cos(angle * k), wi = Math.sin(angle * k);
      const tr = wr * real[b] - wi * imag[b], ti = wr * imag[b] + wi * real[b];
      real[b] = real[a] - tr; imag[b] = imag[a] - ti; real[a] += tr; imag[a] += ti;
    }
  }
  const resolution = 1 / period / n;
  const bins = Array.from({ length: n / 2 + 1 }, (_, i) => {
    const peak = Math.hypot(real[i], imag[i]) / weight * (i === 0 || i === n / 2 ? 1 : 2);
    const rms = peak / (i === 0 || i === n / 2 ? 1 : Math.SQRT2);
    return { frequency: i * resolution, rms, db: 20 * Math.log10(Math.max(rms, 1e-9)) };
  });
  const peak = bins.slice(1).reduce((best, b) => b.rms > best.rms ? b : best, bins[1]);
  return { bins, peak, resolution };
}
export function decodeUART(samples, period, line = 4, baud = 115200) {
  const bit = 1 / baud / period, result = [];
  if (bit < 4) return { result, advice: 'Increase the logic sample rate: UART needs at least 4 samples per bit.' };
  const high = i => !!(samples[Math.min(Math.round(i), samples.length - 1)] & (1 << line));
  for (let i = 1; i + 10 * bit < samples.length; i++) {
    if (!high(i - 1) || high(i) || high(i + bit * .5)) continue;
    let value = 0; for (let b = 0; b < 8; b++) if (high(i + (1.5 + b) * bit)) value |= 1 << b;
    result.push({ time: i * period, value, error: !high(i + 9.5 * bit) }); i += Math.floor(9.5 * bit);
    if (result.length >= 512) break;
  }
  return { result, advice: 'UART · 8 data bits · no parity · 1 stop bit' };
}
export function csv(frame) {
  if (!frame) return '';
  if (frame.kind === 'logic') {
    const rows = ['time_s,' + Array.from({ length: 8 }, (_, i) => `D${i}`).join(',')];
    for (let i = 0; i < frame.samples.length; i++) rows.push([((i - frame.triggerIndex) * frame.period).toPrecision(10), ...Array.from({ length: 8 }, (_, b) => (frame.samples[i] >> b) & 1)].join(','));
    return rows.join('\n') + '\n';
  }
  if (frame.kind === 'meter') return 'time_s,' + frame.values.map((_, i) => `CH${i + 1}_V`).join(',') + '\n' + frame.history.map(row => [row.time, ...row.values].join(',')).join('\n') + '\n';
  const rows = ['time_s,' + frame.traces.map(t => `CH${t.index + 1}_V`).join(',')];
  for (let i = 0; i < frame.count; i++) rows.push([((i - frame.triggerIndex) * frame.period).toPrecision(10), ...frame.traces.map(t => t.samples[i].toPrecision(9))].join(','));
  return rows.join('\n') + '\n';
}
export function fmt(value, unit = '', digits = 3) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  const prefixes = [[1e9, 'G'], [1e6, 'M'], [1e3, 'k'], [1, ''], [1e-3, 'm'], [1e-6, 'µ'], [1e-9, 'n']];
  const [scale, prefix] = value === 0 ? [1, ''] : prefixes.find(([n]) => Math.abs(value) >= n * .9999) || prefixes.at(-1);
  return `${Number((value / scale).toPrecision(digits))} ${prefix}${unit}`.trim();
}
