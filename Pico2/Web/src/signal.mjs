// As the macOS app measures. Every timing figure comes from crossings of the
// half-way level with a 5 % guard band, so noise at a crossing does not invent
// edges; the period comes from whichever edge was seen at least twice, since a
// short record may hold only one of the other; rise and fall are 10 % to 90 %.
export function measure(samples, period) {
  const result = { min: 0, max: 0, mean: 0, rms: 0, acRms: 0, pp: 0, frequency: null, period: null, duty: null, rise: null, fall: null };
  const n = samples.length; if (!n) return result;
  let min = Infinity, max = -Infinity, sum = 0, squares = 0;
  for (const x of samples) { min = Math.min(min, x); max = Math.max(max, x); sum += x; squares += x * x; }
  const mean = sum / n, pp = max - min;
  Object.assign(result, { min, max, mean, pp, rms: Math.sqrt(squares / n), acRms: Math.sqrt(Math.max(0, squares / n - mean * mean)) });
  if (pp <= 1e-9 || !(period > 0)) return result;
  const cross = (i, level) => { const step = samples[i] - samples[i - 1]; return Math.abs(step) < 1e-15 ? i : i - 1 + (level - samples[i - 1]) / step; };
  const middle = (max + min) / 2, guard = pp * .05, rising = [], falling = [];
  let above = samples[0] > middle;
  for (let i = 1; i < n; i++) {
    if (!above && samples[i] > middle + guard) { above = true; rising.push(cross(i, middle)); }
    else if (above && samples[i] < middle - guard) { above = false; falling.push(cross(i, middle)); }
  }
  const edges = rising.length >= 2 ? rising : falling;
  if (edges.length >= 2) {
    const cycle = (edges.at(-1) - edges[0]) / (edges.length - 1) * period;
    if (cycle > 0) { result.period = cycle; result.frequency = 1 / cycle; }
  }
  if (rising.length && result.period) {
    const fall = falling.find(f => f > rising[0]);
    if (fall !== undefined) result.duty = Math.min(Math.max((fall - rising[0]) * period / result.period, 0), 1);
  }
  const low = min + pp * .1, high = min + pp * .9;
  const transition = up => {
    let start = null;
    for (let i = 1; i < n; i++) {
      const a = samples[i - 1], b = samples[i];
      if (up) { if (a < low && b >= low) start = cross(i, low); if (start !== null && a < high && b >= high) return (cross(i, high) - start) * period; }
      else { if (a > high && b <= high) start = cross(i, high); if (start !== null && a > low && b <= low) return (cross(i, low) - start) * period; }
    }
    return null;
  };
  result.rise = transition(true); result.fall = transition(false);
  return result;
}
// One column pair per channel. Every trace comes from the same record, so the
// bins line up and one frequency column serves them all.
export function spectrumCsv(spectra) {
  if (!spectra?.length || !spectra[0].bins.length) return '';
  const header = ['frequency_Hz', ...spectra.flatMap(s => [`CH${s.index + 1}_rms_V`, `CH${s.index + 1}_dBV`])];
  const rows = spectra[0].bins.map((bin, i) => [bin.frequency, ...spectra.flatMap(s => s.bins[i] ? [s.bins[i].rms, s.bins[i].db] : ['', ''])].join(','));
  return [header.join(','), ...rows].join('\n') + '\n';
}
// The windows the macOS app offers: what each is for, the coefficients, and
// how many bins one tone is smeared over, which the distortion figures need.
export const WINDOWS = {
  Rectangular: { advice: 'No window. Only for signals that fit the record exactly.', enbw: 1, at: () => 1 },
  Hann: { advice: 'General purpose.', enbw: 1.5, at: x => .5 - .5 * Math.cos(x) },
  Hamming: { advice: 'Slightly narrower than Hann, with higher distant sidelobes.', enbw: 1.36, at: x => .54 - .46 * Math.cos(x) },
  'Blackman-Harris': { advice: 'Lowest sidelobes; use next to a strong tone.', enbw: 2, at: x => .35875 - .48829 * Math.cos(x) + .14128 * Math.cos(2 * x) - .01168 * Math.cos(3 * x) },
  'Flat top': { advice: 'Most accurate amplitude; poorest resolution.', enbw: 3.77, at: x => .21557895 - .41663158 * Math.cos(x) + .277263158 * Math.cos(2 * x) - .083578947 * Math.cos(3 * x) + .006947368 * Math.cos(4 * x) },
};
export const SPECTRUM_SCALES = ['dBV', 'dBu', 'dBFS', 'V'];
// Amplitudes are volts peak. dBV and dBu are of the RMS, dBFS of the peak
// against the channel's own full scale, V is the peak itself — as on the Mac.
export function levelOf(amplitude, scale, fullScale) {
  if (scale === 'V') return amplitude;
  if (scale === 'dBFS') return 20 * Math.log10(Math.max(amplitude, 1e-12) / Math.max(fullScale, 1e-12));
  const rms = amplitude / Math.SQRT2;
  return scale === 'dBu' ? 20 * Math.log10(Math.max(rms, 1e-12) / .7745966692) : 20 * Math.log10(Math.max(rms, 1e-12));
}
export function spectrum(samples, period, window = 'Hann') {
  const n = 2 ** Math.floor(Math.log2(samples.length));
  if (n < 8) return fromAmplitudes(new Float64Array(0), 0, window);
  const shape = (WINDOWS[window] || WINDOWS.Hann).at;
  const real = new Float64Array(n), imag = new Float64Array(n); let weight = 0;
  // The mean comes out here rather than being left to the panel's Remove mean,
  // which is a scope setting. A DC offset put through the window is not a tall
  // bin 0 but a skirt across the first few bins, and on a mid-rail input that
  // skirt outweighs the signal — a 440 Hz tone on 1.65 V reported its peak at
  // 12 Hz. So the spectrum is the same whether the panel removes the mean.
  let mean = 0;
  for (let i = 0; i < n; i++) mean += samples[i];
  mean /= n;
  for (let i = 0; i < n; i++) { const w = shape(2 * Math.PI * i / (n - 1)); weight += w; real[i] = (samples[i] - mean) * w; }
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
  // Dividing by the window's sum takes its coherent gain back out, so a 1 V
  // sine reads 1 V whichever window is chosen.
  const amplitudes = Float64Array.from({ length: n / 2 + 1 }, (_, i) => Math.hypot(real[i], imag[i]) / weight * (i === 0 || i === n / 2 ? 1 : 2));
  return fromAmplitudes(amplitudes, 1 / period / n, window);
}
// Everything the page shows is read off the amplitudes, so an averaged
// spectrum is rebuilt from its averaged amplitudes the same way.
function fromAmplitudes(amplitudes, resolution, window) {
  const last = amplitudes.length - 1;
  const bins = Array.from(amplitudes, (amplitude, i) => {
    const rms = amplitude / (i === 0 || i === last ? 1 : Math.SQRT2);
    return { frequency: i * resolution, rms, db: 20 * Math.log10(Math.max(rms, 1e-9)) };
  });
  const peak = bins.length > 1 ? bins.slice(1).reduce((best, b) => b.rms > best.rms ? b : best, bins[1]) : null;
  return { bins, amplitudes, peak, peaks: peaks(amplitudes, resolution, amplitudes.length), resolution, window };
}
function interpolatedPeak(amplitudes, i, resolution) {
  if (i < 1 || i + 1 >= amplitudes.length) return { frequency: i * resolution, amplitude: amplitudes[i] ?? 0, bin: i };
  const left = Math.log(Math.max(amplitudes[i - 1], 1e-18)), centre = Math.log(Math.max(amplitudes[i], 1e-18)), right = Math.log(Math.max(amplitudes[i + 1], 1e-18));
  const denominator = left - 2 * centre + right;
  const shift = Math.abs(denominator) < 1e-15 ? 0 : .5 * (left - right) / denominator;
  return { frequency: (i + shift) * resolution, amplitude: Math.exp(centre - .25 * (left - right) * shift), bin: i };
}
// Local maxima, strongest first, as the macOS app finds them. A tone between
// two bins is read at its real frequency: a parabola through the log of the
// three bins around it is the standard correction.
export function peaks(amplitudes, resolution, limit = 8, floor = 1e-7) {
  const found = [];
  for (let i = 1; i < amplitudes.length - 1; i++) {
    const value = amplitudes[i];
    if (value <= floor || value < amplitudes[i - 1] || value <= amplitudes[i + 1]) continue;
    const peak = interpolatedPeak(amplitudes, i, resolution), rms = peak.amplitude / Math.SQRT2;
    found.push({ ...peak, rms, db: 20 * Math.log10(Math.max(rms, 1e-9)) });
  }
  return found.sort((a, b) => b.amplitude - a.amplitude).slice(0, limit);
}
// Averages, in power, the latest run of spectra that agree on bins and window.
export function averageSpectra(spectra) {
  const latest = spectra.at(-1); if (!latest?.amplitudes.length) return latest ?? fromAmplitudes(new Float64Array(0), 0, 'Hann');
  const power = new Float64Array(latest.amplitudes.length); let used = 0;
  for (let k = spectra.length - 1; k >= 0; k--) {
    const s = spectra[k];
    if (s.amplitudes.length !== power.length || s.resolution !== latest.resolution || s.window !== latest.window) break;
    for (let i = 0; i < power.length; i++) power[i] += s.amplitudes[i] * s.amplitudes[i];
    used++;
  }
  return fromAmplitudes(power.map(p => Math.sqrt(p / used)), latest.resolution, latest.window);
}
// Distortion and noise around the strongest tone, as the Mac measures them.
// Each bin belongs to exactly one thing — the DC skirt, the fundamental, a
// harmonic, or the noise — or the band around a low harmonic re-counts the
// fundamental's own skirt and a clean tone reports distortion it does not have.
export function spectrumQuality(s, harmonicCount) {
  const a = s.amplitudes; if (!a || a.length <= 8) return null;
  const skirt = Math.ceil((WINDOWS[s.window] || WINDOWS.Hann).enbw) + 1;
  let strongest = skirt;
  for (let i = skirt; i < a.length; i++) if (a[i] > a[strongest]) strongest = i;
  if (!(a[strongest] > 0)) return null;
  const claimed = new Set(), power = (bin, claim) => {
    let total = 0;
    for (let i = Math.max(bin - skirt, 0); i <= Math.min(bin + skirt, a.length - 1); i++) if (!claimed.has(i)) { total += a[i] * a[i]; if (claim) claimed.add(i); }
    return total;
  };
  for (let i = 0; i <= skirt; i++) claimed.add(i);
  const fundamentalPower = power(strongest, true), harmonics = [];
  let harmonicPower = 0;
  for (let order = 2; order <= Math.max(harmonicCount, 2); order++) {
    const bin = strongest * order;
    if (bin + skirt >= a.length) break;
    // A harmonic closer than two skirts to the fundamental is not resolved from it.
    if (bin - strongest <= 2 * skirt) continue;
    harmonicPower += power(bin, true); harmonics.push(interpolatedPeak(a, bin, s.resolution));
  }
  let noisePower = 0;
  for (let i = skirt + 1; i < a.length; i++) if (!claimed.has(i)) noisePower += a[i] * a[i];
  const rest = harmonicPower + noisePower;
  const sinad = 10 * Math.log10(Math.max(fundamentalPower, 1e-30) / Math.max(rest, 1e-30));
  return {
    fundamental: interpolatedPeak(a, strongest, s.resolution), harmonics,
    thd: fundamentalPower > 0 ? Math.sqrt(harmonicPower / fundamentalPower) : 0,
    thdPlusNoise: fundamentalPower > 0 ? Math.sqrt(rest / fundamentalPower) : 0,
    snr: 10 * Math.log10(Math.max(fundamentalPower, 1e-30) / Math.max(noisePower, 1e-30)),
    sinad, enob: (sinad - 1.76) / 6.02,
  };
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
  // One row a logged interval, so the extremes within it are part of the record
  // rather than something only the screen knew.
  if (frame.kind === 'meter') {
    const header = ['time_s', 'timestamp'];
    frame.values.forEach((_, i) => header.push(`CH${i + 1}_min_V`, `CH${i + 1}_mean_V`, `CH${i + 1}_max_V`));
    const rows = frame.history.map(row => {
      const cells = [row.time.toPrecision(9), new Date((frame.start + row.time) * 1000).toISOString()];
      row.mean.forEach((_, i) => cells.push(row.low[i].toPrecision(9), row.mean[i].toPrecision(9), row.high[i].toPrecision(9)));
      return cells.join(',');
    });
    return [header.join(','), ...rows].join('\n') + '\n';
  }
  // The file is what the screen shows: centred where Remove mean is on, as it
  // came off the converter where it is not. A centred column looks like any
  // other column once the file is opened somewhere else, so the ones that had
  // their mean taken out say so, and say how much — enough to put it back.
  const notes = frame.traces.filter(t => t.removedMean).map(t => `# CH${t.index + 1}: mean removed, ${t.removedMean.toPrecision(7)} V`);
  const rows = ['time_s,' + frame.traces.map(t => `CH${t.index + 1}_V`).join(',')];
  for (let i = 0; i < frame.count; i++) rows.push([((i - frame.triggerIndex) * frame.period).toPrecision(10), ...frame.traces.map(t => t.samples[i].toPrecision(9))].join(','));
  return [...notes, ...rows].join('\n') + '\n';
}
export function fmt(value, unit = '', digits = 3) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  const prefixes = [[1e9, 'G'], [1e6, 'M'], [1e3, 'k'], [1, ''], [1e-3, 'm'], [1e-6, 'µ'], [1e-9, 'n']];
  const [scale, prefix] = value === 0 ? [1, ''] : prefixes.find(([n]) => Math.abs(value) >= n * .9999) || prefixes.at(-1);
  return `${Number((value / scale).toPrecision(digits))} ${prefix}${unit}`.trim();
}
