import { Instrument } from './instrument.mjs';
import { connect as connectOverNetwork, available as servedByInstrument } from './net.mjs';
import { Acquisition, DemoInstrument, makeSettings } from './acquisition.mjs';
import { activeChannels, demoCaps, ranges, scaleFor, usableTriggerLevel, triggerWindow, biasVolts, midRailVolts, referenceBias, SIGNAL_BASE_PIN, CALIBRATION_PIN, SCALE_STEPS, fitScale, resolutionFor, spectrumSpans, spectrumRecord, setSpectrumSpan, setSpectrumResolution } from './protocol.mjs';
import { fmt, csv, decodeLogic, logicActivity, spectrumCsv, WINDOWS, SPECTRUM_SCALES } from './signal.mjs';
import { COLORS, CURSOR_COLOR, Plot } from './plot.mjs';
const $ = id => document.getElementById(id);
const NUMERIC_CONTROLS = { 'spi-clock': 'spiClock', 'spi-data': 'spiData', 'spi-select': 'spiSelect', 'i2c-clock': 'i2cClock', 'i2c-data': 'i2cData', 'spectrum-averaging': 'spectrumAveraging', 'spectrum-harmonics': 'spectrumHarmonics', 'logic-trigger': 'logicTrigger', 'logic-source': 'logicSource', 'logic-slope': 'logicSlope', 'logic-position': 'logicPosition', averaging: 'averaging', 'xy-x': 'xyX', 'xy-y': 'xyY', 'signal-sine': 'signalSineHz', timebase: 'timebase', record: 'record', 'log-interval': 'logInterval', trigger: 'trigger', slope: 'slope', level: 'level', position: 'position', hysteresis: 'hysteresis', 'test-frequency': 'testFrequency', 'logic-rate': 'logicRate', 'logic-record': 'logicRecord', 'uart-line': 'uartLine', 'uart-baud': 'uartBaud' };
// Sliders show their value beside the label, as the Mac's LabeledSlider does.
const SLIDER_READOUTS = {
  position: v => `${Math.round(v * 100)} %`, 'logic-position': v => `${Math.round(v * 100)} %`,
  level: v => fmt(v, 'V'), hysteresis: v => `${(v * 100).toFixed(1)} %`,
};
function showSliderReadouts() {
  for (const [id, format] of Object.entries(SLIDER_READOUTS)) $(`${id}-label`).value = format(settings[NUMERIC_CONTROLS[id]]);
}
const STRING_CONTROLS = [['decoder', 'decoder'], ['uart-parity', 'uartParity'], ['spectrum-window', 'spectrumWindow'], ['spectrum-scale', 'spectrumScale']];
const CHECK_CONTROLS = [['spectrum-log', 'spectrumLog'], ['spectrum-peaks', 'spectrumPeaks'], ['test-enabled', 'testEnabled'], ['xy', 'xy'], ['spi-uses-select', 'spiUsesSelect'], ['spi-idle-high', 'spiIdleHigh'], ['spi-second-edge', 'spiSecondEdge'], ['signals-enabled', 'signalsEnabled']];
const STORAGE_KEY = 'pilyzer.settings.v1';
// The front panel comes back the way it was left, the per-channel zero
// included: it describes the wiring — the bias a front end adds — rather than
// a moment, and it is visible in a field of its own, which is what makes it
// safe to restore.
function loadSettings() {
  const defaults = makeSettings();
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null'); } catch { return defaults; }
  if (!saved || typeof saved !== 'object') return defaults;
  // Field by field, and only when the stored value still has the shape the
  // current version expects: an older or hand-edited entry cannot break start-up.
  const accept = (value, against) => typeof value === typeof against && (typeof against !== 'number' || Number.isFinite(value));
  for (const [key, value] of Object.entries(defaults)) {
    if (key === 'channels') for (const [index, channel] of defaults.channels.entries()) {
      const stored = saved.channels?.[index];
      if (stored) for (const [field, current] of Object.entries(channel)) {
        if (field === 'gain') {
          // One correction a range, and a missing one is no correction.
          if (Array.isArray(stored.gain)) channel.gain = stored.gain.map(v => Number.isFinite(v) ? v : 1);
        } else if (field === 'measuredBias') {
          // A number once somebody has measured it, and null until then, so
          // the shape check below would refuse whichever it is not.
          if (Number.isFinite(stored.measuredBias)) channel.measuredBias = stored.measuredBias;
        } else if (accept(stored[field], current)) channel[field] = stored[field];
      }
    }
    else if (accept(saved[key], value)) defaults[key] = saved[key];
  }
  if (!['scope', 'spectrum', 'logic', 'meter'].includes(defaults.mode)) defaults.mode = 'scope';
  // The UART switch came before the decoder menu; a saved one still decodes.
  if (saved.uart === true && saved.decoder === undefined) defaults.decoder = 'UART';
  return defaults;
}
function saveSettings() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(settings)); } catch { /* private windows and disabled storage are fine */ }
}
// Restores the controls from the settings, which may have come back from an
// earlier visit rather than from the defaults the markup was written with.
function applyControls() {
  for (const [id, key] of Object.entries(NUMERIC_CONTROLS)) $(id).value = settings[key];
  for (const [id, key] of CHECK_CONTROLS) $(id).checked = settings[key];
  for (const [id, key] of STRING_CONTROLS) $(id).value = settings[key];
  showSliderReadouts();
  $('logic-lines').querySelectorAll('input').forEach((input, i) => { input.checked = !!(settings.logicEnabled & (1 << i)); });
}
let settings = loadSettings(), instrument = null, frame = null, connecting = false;
// Set once at startup: true when this page came from the instrument's own
// server, in which case it is reached over the network and not over USB.
let overNetwork = false;
const plot = new Plot($('plot'));
const acquisition = new Acquisition(value => { frame = value; renderFrame(); }, (message, error = false) => {
  $('status').textContent = message; if (error) showError(message); updateButtons();
});
function caps() { return instrument?.caps || demoCaps; }
// The instrument's own range list. Offline there is no instrument to ask, so
// the panel previews the front end this application was built alongside.
function frontEnd() { return instrument?.ranges ?? ranges(1); }
function showError(message = '') { $('error').textContent = message; $('error').hidden = !message; }
function updateButtons() {
  $('run').disabled = !instrument || connecting; $('run').textContent = acquisition.running ? '■ Stop' : '▶ Run';
  $('single').disabled = !instrument || acquisition.running || connecting;
  $('connect').hidden = !!instrument; $('demo').hidden = !!instrument; $('disconnect').hidden = !instrument;
  $('connect').disabled = connecting || !(overNetwork || navigator.usb); $('demo').disabled = connecting;
  $('run-dot').classList.toggle('live', acquisition.running);
  $('connection-dot').classList.toggle('connected', !!instrument);
  $('source-badge').textContent = instrument ? instrument.demo ? 'DEMO' : 'USB' : 'OFFLINE';
  $('device-name').textContent = instrument ? `${instrument.identity.name} · firmware ${instrument.identity.firmware}` : 'No instrument connected';
  $('empty-state').hidden = !!frame; $('export').disabled = !frame;
  $('empty-demo').disabled = connecting || acquisition.running;
  $('empty-demo').textContent = instrument ? 'Single capture' : 'Start a demo →';
  $('empty-state').querySelector('h2').textContent = instrument ? 'Ready for your signal.' : 'A closer look at your signal.';
  $('empty-state').querySelector('p').textContent = instrument ? 'Press Run for continuous capture, or Single for one record.' : (overNetwork ? 'This page came from the instrument. Press Connect, or explore three channels with the built-in demo.' : 'Connect your PiLyzer Pico 2, or explore three channels with the built-in demo.');
}
function option(value, label) { const el = document.createElement('option'); el.value = value; el.textContent = label; return el; }
function options(id, values, selected) { $(id).replaceChildren(...values.map(([value, label]) => option(value, label))); $(id).value = selected; }
// A volts field whose number goes into the settings as it is typed. Committing
// on change instead rebuilt every channel card as the field lost focus — which
// happens on the press of the next button — so a click on Mid rail or Set gain
// straight after typing landed on a card that had just been replaced, and did
// nothing. Leaving the field only tidies what it shows.
function voltsField(input, read, write, after) {
  const show = () => { input.value = Number(read().toPrecision(6)); };
  show();
  input.addEventListener('input', () => {
    const value = Number(input.value);
    if (input.value.trim() === '' || !Number.isFinite(value)) return;
    write(value); after(); saveSettings();
  });
  input.addEventListener('change', show);
}
function channelControls() {
  $('channels').replaceChildren();
  for (let i = 0; i < caps().channels; i++) {
    const ch = settings.channels[i], el = document.createElement('div'); el.className = 'channel-card'; el.style.setProperty('--channel-color', COLORS[i]);
    el.innerHTML = `<div class="channel-heading"><label><input type="checkbox" data-field="enabled" aria-label="Enable CH${i + 1}"/><span class="marker"></span>CH${i + 1}</label><span class="channel-note">GPIO ${26 + i}</span></div><div class="channel-body"${ch.enabled ? '' : ' hidden'}><label class="field">Input range<select data-field="range" aria-label="CH${i + 1} input range"></select></label><div class="field-pair"><label>Scale / div<select data-field="scale" aria-label="CH${i + 1} scale"></select></label><label>Probe<select data-field="probe" aria-label="CH${i + 1} probe"><option value="1">1×</option><option value="10">10×</option></select></label></div><label class="slider-label">Position<output>${ch.offset.toFixed(1)} div</output><input data-field="offset" aria-label="CH${i + 1} position" type="range" min="-4" max="4" step="0.1"/></label><label class="check-row" data-ac-row><input type="checkbox" data-field="ac" aria-label="CH${i + 1} remove mean"/>Remove mean</label><label class="field">Bias <span class="unit">V</span><input data-bias type="number" step="0.01" aria-label="CH${i + 1} bias volts"/></label><p class="hint">Where the front end holds this input with nothing on it. Drawn as a dotted line; readings stay as the converter saw them.</p><p class="hint" data-bias-note hidden></p><div class="channel-actions"><button class="zero-button" data-zero title="Ground this input and capture a trace first: what it reads is the bias.">Measure</button><button class="zero-button" data-afe>Mid rail</button></div><label class="field">Applied <span class="unit">V</span><input data-applied type="number" step="0.1" aria-label="CH${i + 1} applied volts"/></label><p class="hint">A known voltage on the input. Set gain measures the swing from the bias and corrects the gain by what it is short of this — so measure the bias first. The divider's 1% parts put it out by up to 2%.</p><p class="hint" data-gain-note hidden></p><div class="channel-actions"><button class="zero-button" data-gain title="Put a known steady voltage on this input and capture a trace first.">Set gain</button><button class="zero-button" data-reset title="Clears this channel's bias and gain correction.">Reset</button></div></div>`;
    const range = el.querySelector('[data-field=range]'); frontEnd().forEach((r, j) => range.add(option(j, r.name))); range.disabled = frontEnd().length < 2;
    const scale = el.querySelector('[data-field=scale]');
    SCALE_STEPS.forEach(v => scale.add(option(v, fmt(v, 'V'))));
    for (const control of el.querySelectorAll('[data-field]')) {
      const key = control.dataset.field;
      if (control.type === 'checkbox') control.checked = ch[key];
      // A channel nobody has set reads through the step that fits its range,
      // rather than storing one before the instrument has said what its ranges
      // are — the menu shows a number either way.
      else if (key === 'scale') control.value = ch.scale || fitScale(scaleFor(settings, caps(), frontEnd(), i));
      else control.value = ch[key];
      if (key === 'enabled') control.disabled = ch.enabled && activeChannels(settings, caps()).length === 1;
      // Only the scope draws what Remove mean changes: the spectrum takes the
      // mean out itself, because a DC offset through the window is a skirt
      // over the low bins rather than a tall one at zero, and the meter's
      // whole job is the reading the converter actually made.
      if (key === 'ac') {
        const applies = settings.mode === 'scope';
        control.disabled = !applies;
        const row = el.querySelector('[data-ac-row]');
        row.classList.toggle('inactive', !applies);
        row.title = applies ? 'Centres the trace on zero, and the CSV with it.'
          : 'Scope only. The spectrum removes the mean itself, and the meter logs what the converter read.';
      }
      if (control.type === 'range') control.addEventListener('input', () => {
        ch[key] = Number(control.value);
        el.querySelector('output').textContent = `${ch[key].toFixed(1)} div`;
        renderFrame();
      });
      control.addEventListener('change', () => {
        ch[key] = control.type === 'checkbox' ? control.checked : Number(control.value);
        if (!activeChannels(settings, caps()).length) ch.enabled = true;
        synchronize(); changed();
      });
    }
    voltsField(el.querySelector('[data-bias]'), () => ch.bias ?? 0, value => { ch.bias = value; },
      () => { showMeasured(); renderFrame(); });
    voltsField(el.querySelector('[data-applied]'), () => ch.applied, value => { ch.applied = value; }, () => {});
    const r = frontEnd()[ch.range] || frontEnd()[0];
    const midRail = midRailVolts(caps(), r);
    const afe = el.querySelector('[data-afe]');
    afe.title = `Writes ${fmt(midRail, 'V')}, the input that reads mid scale: where a passive front end holds it.`;
    afe.onclick = () => { ch.bias = Number(midRail.toPrecision(6)); synchronize(); changed(); };

    // Both buttons read one number off the capture on screen, so both refuse a
    // capture that is moving: a bias or a gain measured off a waveform is a
    // number about the instant the button was pressed.
    const steady = trace => trace.stats.pp <= Math.abs(scaleFor(settings, caps(), frontEnd(), i).span) * 0.01;
    el.querySelector('[data-zero]').onclick = () => {
      const trace = frame?.traces?.find(t => t.index === i); if (!trace) { showError(`Capture CH${i + 1} first.`); return; }
      if (!steady(trace)) { showError(`CH${i + 1} has a signal on the input. Ground it, or switch the signal off, and capture again.`); return; }
      ch.measuredBias = trace.stats.mean; synchronize(); changed();
    };
    const gainButton = el.querySelector('[data-gain]');
    gainButton.onclick = () => {
      const trace = frame?.traces?.find(t => t.index === i); if (!trace) { showError(`Capture CH${i + 1} first.`); return; }
      const applied = Number(ch.applied);
      if (!Number.isFinite(applied) || Math.abs(applied) < 1e-6) { showError('Say what voltage is on the input first.'); return; }
      if (!steady(trace)) { showError(`CH${i + 1} is not sitting still — the gain is measured from one reading, so it needs a steady DC voltage on the input, not a waveform.`); return; }
      const swing = trace.stats.mean - referenceBias(ch);
      if (Math.abs(swing) < 1e-9) { showError(`CH${i + 1} reads its bias, so there is nothing to correct.`); return; }
      const proposed = (ch.gain[ch.range] || 1) * applied / swing;
      // The dividers are 1% parts and the reference is a per cent of its own;
      // a tenth is not a resistor being out, it is the wrong reading.
      if (Math.abs(proposed - 1) > 0.10) {
        showError(`That would correct CH${i + 1}'s gain by ${((proposed - 1) * 100).toFixed(0)} %. A divider of 1% parts is out by two, so check that ${fmt(applied, 'V')} really is on the input and that the bias has been measured.`);
        return;
      }
      ch.gain[ch.range] = proposed;
      synchronize(); changed();
    };
    const measured = el.querySelector('[data-bias-note]');
    function showMeasured() {
      measured.hidden = ch.measuredBias === null || ch.measuredBias === undefined;
      if (measured.hidden) return;
      const error = ch.measuredBias - (ch.bias ?? 0);
      measured.textContent = `Measured ${fmt(ch.measuredBias, 'V')} — ${fmt(Math.abs(error), 'V')} ${error < 0 ? 'below' : 'above'} it, marked on the right.`;
      measured.style.color = COLORS[i];
    }
    showMeasured();
    const correction = ch.gain?.[ch.range] || 1;
    const note = el.querySelector('[data-gain-note]');
    note.hidden = Math.abs(correction - 1) < 1e-9;
    note.textContent = `Gain corrected by ${((correction - 1) * 100).toFixed(2)} % — readings are scaled by it.`;
    note.style.color = COLORS[i];
    el.querySelector('[data-reset]').onclick = () => {
      ch.bias = 0; ch.measuredBias = null; ch.gain = [1, 1]; synchronize(); changed();
    };
    $('channels').append(el);
  }
  calibrationButtons();
}
const timebases = [10e-6, 20e-6, 50e-6, .0001, .0002, .0005, .001, .002, .005, .01, .02, .05, .1, .2, .5, 1, 2, 5];
// A level left behind by another range sits on the rail, where no signal ever
// crosses it. That reads as a broken trigger, so it is moved into reach.
// A level outside what the input reaches is left exactly as it was typed — it
// is the user's number — and simply reported as one nothing will cross.
function settleTriggerLevel() {
  const note = $('level-note');
  if (settings.mode === 'logic' || settings.mode === 'meter') { note.hidden = true; return; }
  const scale = scaleFor(settings, caps(), frontEnd(), settings.source);
  const window = triggerWindow(scale);
  note.hidden = !!window && settings.level >= window.low && settings.level <= window.high;
  if (note.hidden) return;
  note.textContent = window
    ? `CH${settings.source + 1} reaches ${fmt(window.low, 'V')} to ${fmt(window.high, 'V')}, so nothing will cross ${fmt(settings.level, 'V')}. The level is left where it was set.`
    : `CH${settings.source + 1} has no range to trigger in.`;
}

// Once, when an instrument answers: a level that cannot fire on the channel it
// watches starts at that channel's bias instead. One that can fire is never
// touched, whatever it is.
function seedTriggerLevel() {
  const scale = scaleFor(settings, caps(), frontEnd(), settings.source);
  const window = triggerWindow(scale);
  if (!window || (settings.level >= window.low && settings.level <= window.high)) return;
  settings.level = Number(biasVolts(scale).toPrecision(6));
  $('level').value = settings.level;
}
// The spectrum's horizontal controls, in its own terms. Each menu offers what
// is reachable with the other as it stands, plus the current choice so the
// menu still names it when it no longer is.
function frequencyControls(channels, allowed) {
  const c = caps(), reaches = (span, resolution) => spectrumRecord(span, resolution, c, channels) !== null;
  const spans = spectrumSpans(c, channels).filter(span => reaches(span, resolutionFor(settings.timebase)));
  if (settings.spectrumSpan && !spans.includes(settings.spectrumSpan)) spans.push(settings.spectrumSpan);
  const times = allowed.filter(t => !settings.spectrumSpan || reaches(settings.spectrumSpan, resolutionFor(t)));
  if (!times.includes(settings.timebase)) times.push(settings.timebase);
  const floor = c.minCycles / c.clock * Math.max(channels, 1), duration = settings.timebase * 10;
  const period = Math.max(duration / Math.min(settings.record, c.maxRecord), floor), nyquist = 1 / period / 2;
  options('spectrum-span', [[0, `Full · ${fmt(nyquist, 'Hz')}`], ...spans.sort((a, b) => a - b).map(s => [s, fmt(s, 'Hz')])], settings.spectrumSpan);
  options('spectrum-resolution', times.sort((a, b) => b - a).map(t => [t, fmt(resolutionFor(t), 'Hz')]), settings.timebase);
  $('spectrum-plan').textContent = `${fmt(1 / period, 'Sa/s')} · ${Math.round(duration / period).toLocaleString()} points · a sweep every ${fmt(duration, 's')}`;
  const held = settings.spectrumSpan > nyquist * (1 + 1e-9);
  $('spectrum-held').hidden = !held;
  if (held) $('spectrum-held').textContent = `Drawn to ${fmt(nyquist, 'Hz')}: at this resolution, with ${channels} channel${channels === 1 ? '' : 's'} sharing the converter, the record does not reach ${fmt(settings.spectrumSpan, 'Hz')}.`;
  $('spectrum-alias').textContent = `Nothing filters the input before the converter, so a signal above ${fmt(nyquist, 'Hz')} — half the sample rate — folds back into the span as a false peak.`;
}
// A logarithmic slider gives the low end as much travel as the high end, as on
// the Mac. Off has its own switch, so zero is never put through log10, and the
// cutoff last used comes back when the filter is switched on again.
let rememberedCutoff = 1000;
function showLowPass() {
  const on = settings.lpf > 0, unsupported = !!instrument && !(caps().flags & 8);
  if (on) rememberedCutoff = settings.lpf;
  $('lpf-enabled').checked = on; $('lpf-enabled').disabled = unsupported; $('lpf-1k').disabled = unsupported;
  $('lpf').value = Math.log10(Math.max(on ? settings.lpf : rememberedCutoff, 100));
  $('lpf').disabled = !on || unsupported;
  $('lpf-value').value = on ? `${settings.lpf.toLocaleString()} Hz` : 'Off';
}
function synchronize() {
  const active = activeChannels(settings, caps());
  if (!active.includes(settings.source)) settings.source = active[0] ?? 0;
  settleTriggerLevel();
  const minimum = caps().minCycles / caps().clock * Math.max(active.length, 1) * 5;
  const allowed = timebases.filter(v => v >= minimum);
  if (!allowed.includes(settings.timebase)) settings.timebase = allowed.find(v => v >= settings.timebase) || allowed.at(-1);
  options('timebase', allowed.map(v => [v, fmt(v, 's')]), settings.timebase);
  const logic = settings.mode === 'logic', meter = settings.mode === 'meter';
  options('source', active.map(i => [i, `CH${i + 1}`]), settings.source);
  options('logic-source', Array.from({ length: caps().logicChannels }, (_, i) => [i, `D${i}`]), settings.logicSource);
  // The level slider spans what the source channel reads, as on the Mac.
  const levelScale = scaleFor(settings, caps(), frontEnd(), settings.source);
  $('level').min = Math.min(levelScale.low, levelScale.high); $('level').max = Math.max(levelScale.low, levelScale.high);
  $('level').step = 'any'; $('level').value = settings.level;
  showSliderReadouts();
  $('active-count').textContent = `${active.length} channel${active.length === 1 ? '' : 's'} enabled`;
  $('max-rate').replaceChildren(document.createTextNode(fmt(caps().clock / caps().minCycles / Math.max(active.length, 1), 'Sa/s') + ' '), Object.assign(document.createElement('small'), { textContent: '/ channel max' }));
  const spectrumMode = settings.mode === 'spectrum';
  $('horizontal-controls').hidden = logic || meter || spectrumMode; $('frequency-controls').hidden = !spectrumMode;
  $('record').value = settings.record;
  if (spectrumMode) frequencyControls(active.length, allowed);
  $('spectrum-controls').hidden = !spectrumMode;
  if (!WINDOWS[settings.spectrumWindow]) settings.spectrumWindow = 'Hann';
  if (!SPECTRUM_SCALES.includes(settings.spectrumScale)) settings.spectrumScale = 'dBV';
  settings.spectrumAveraging = Math.min(Math.max(Math.round(settings.spectrumAveraging) || 1, 1), 64);
  settings.spectrumHarmonics = Math.min(Math.max(Math.round(settings.spectrumHarmonics) || 2, 2), 12);
  for (const [id, key] of STRING_CONTROLS) $(id).value = settings[key];
  $('spectrum-averaging').value = settings.spectrumAveraging; $('spectrum-harmonics').value = settings.spectrumHarmonics;
  $('spectrum-window-advice').textContent = WINDOWS[settings.spectrumWindow].advice;
  // The Mac shows trigger controls with the scope only; logic has its own.
  $('trigger-controls').hidden = settings.mode !== 'scope';
  $('analog-acquisition').hidden = settings.mode !== 'scope' && !spectrumMode; $('record-row').hidden = settings.mode !== 'scope';
  $('lpf-hint').hidden = !settings.lpf;
  $('lpf-hint').textContent = instrument && !(caps().flags & 8) ? 'Trigger LPF requires firmware 1.2 or later.' : 'LPF affects trigger timing; the trace is unchanged.';
  $('normal-hint').hidden = settings.trigger !== 2;
  $('logger-controls').hidden = !meter;
  $('channel-controls').hidden = logic; $('logic-controls').hidden = !logic;
  // Decode, as on the Mac: a section of its own, showing only what the chosen protocol needs.
  $('decode-controls').hidden = !logic;
  $('uart-controls').hidden = settings.decoder !== 'UART'; $('spi-controls').hidden = settings.decoder !== 'SPI'; $('i2c-controls').hidden = settings.decoder !== 'I²C';
  $('spi-select-row').hidden = !settings.spiUsesSelect;
  for (const [id, key] of [['uart-line', 'uartLine'], ['spi-clock', 'spiClock'], ['spi-data', 'spiData'], ['spi-select', 'spiSelect'], ['i2c-clock', 'i2cClock'], ['i2c-data', 'i2cData']]) $(id).value = settings[key];
  const perBit = settings.logicRate / settings.uartBaud;
  $('uart-advice').textContent = perBit < 4 ? `${perBit.toFixed(1)} samples a bit — sample faster for a reliable decode.` : `${Math.round(perBit)} samples a bit.`;
  $('xy').disabled = settings.mode !== 'scope' || active.length < 2;
  $('test-controls').hidden = instrument && !(caps().flags & 2);
  $('test-frequency').disabled = !settings.testEnabled;
  // Every board has one, but not on the same pins: a PL2407AFE switches its
  // ranges on GPIO2-5, so its generator starts above them.
  $('signal-controls').hidden = !instrument || !(caps().flags & 32);
  $('signal-sine-row').hidden = !settings.signalsEnabled;
  settings.averaging = Math.min(Math.max(Math.round(settings.averaging) || 1, 1), 100); $('averaging').value = settings.averaging;
  $('averaging-row').hidden = settings.mode !== 'scope' && settings.mode !== 'spectrum';
  // X/Y picks its channels from the enabled ones, as on the Mac.
  $('xy-axes').hidden = !settings.xy || settings.mode !== 'scope';
  if (!active.includes(settings.xyX)) settings.xyX = active[0] ?? 0;
  if (!active.includes(settings.xyY) || settings.xyY === settings.xyX) settings.xyY = active.find(i => i !== settings.xyX) ?? settings.xyX;
  options('xy-x', active.map(i => [i, `CH${i + 1}`]), settings.xyX);
  options('xy-y', active.map(i => [i, `CH${i + 1}`]), settings.xyY);
  showLowPass();
  for (const op of $('record').options) op.disabled = Number(op.value) > caps().maxRecord;
  for (const op of $('logic-rate').options) op.disabled = Number(op.value) > caps().logicClock;
  for (const op of $('logic-record').options) op.disabled = Number(op.value) > caps().logicMaxRecord;
  $('test-pin').textContent = instrument?.demo ? 'Demo is generated in this browser. Test output controls apply to a USB instrument.' : `GPIO${CALIBRATION_PIN} · 0–3.3 V square wave. Wire the output to an input to measure it.`;
  $('signal-pins').textContent = `GPIO${SIGNAL_BASE_PIN} sine, GPIO${SIGNAL_BASE_PIN + 1} white, GPIO${SIGNAL_BASE_PIN + 2} pink, GPIO${SIGNAL_BASE_PIN + 3} brown — PWM at 586 kHz, so each pin wants an RC (1 kΩ and 10 nF) to come out as a voltage.`;
  $('mode-title').textContent = { scope: 'Oscilloscope', spectrum: 'Spectrum analyser', logic: 'Logic analyser', meter: 'Voltage meter' }[settings.mode];
  document.body.classList.toggle('meter-mode', meter);
  document.querySelectorAll('[data-mode]').forEach(el => { const selected = el.dataset.mode === settings.mode; el.classList.toggle('selected', selected); el.setAttribute('aria-pressed', selected); });
  channelControls(); renderFrame(); updateButtons(); saveSettings();
}
// How much log there is, in its own terms rather than in wall-clock time.
function logSummary(frame) {
  if (!frame.history.length) return 'no points yet';
  return `${frame.history.length.toLocaleString()} pt · every ${fmt(frame.interval, 's')} · ${fmt(frame.history.at(-1).time, 's')}`;
}
// Both take their number from the capture on screen, so what enables them is
// a capture arriving — not the panel happening to be rebuilt.
function calibrationButtons() {
  const ready = !!frame && frame.kind === 'scope';
  for (const button of document.querySelectorAll('[data-zero], [data-gain]')) button.disabled = !ready;
}
function renderFrame() {
  calibrationButtons();
  plot.update(frame, settings, caps(), frontEnd());
  $('legend').replaceChildren();
  const traces = frame?.traces || activeChannels(settings, caps()).map(index => ({ index }));
  for (const trace of traces) {
    const el = document.createElement('span'); el.className = 'trace-label'; el.style.color = COLORS[trace.index];
    const scale = scaleFor(settings, caps(), frontEnd(), trace.index), ch = settings.channels[trace.index];
    el.textContent = `CH${trace.index + 1}  ${fmt(ch.scale || scale.span / 8, 'V')}/div${ch.ac ? ' · AC' : ''}${trace.clipped ? ' · CLIP' : ''}`;
    $('legend').append(el);
  }
  if (settings.mode === 'logic') $('legend').textContent = 'D0–D7 · 3.3 V logic';
  if (settings.mode === 'meter') $('legend').textContent = frame?.kind === 'meter' ? `logging every ${fmt(frame.interval, 's')} · min/mean/max` : '—';
  if (settings.mode === 'spectrum') {
    for (const el of $('legend').children) el.textContent = el.textContent.split(' ')[0];
    const resolution = plot.spectra?.[0]?.resolution;
    for (const text of [settings.spectrumWindow, `${settings.spectrumAveraging}× avg`, resolution ? `${fmt(resolution, 'Hz')} per bin` : null]) {
      if (!text) continue;
      const el = document.createElement('span'); el.className = 'legend-note'; el.textContent = text; $('legend').append(el);
    }
  }
  $('trigger-summary').textContent = settings.mode === 'meter' ? 'Logging all inputs · min/mean/max a point' : `Trigger: ${['Free', 'Auto', 'Normal'][settings.mode === 'logic' ? settings.logicTrigger : settings.trigger]}${settings.mode === 'logic' ? ` · D${settings.logicSource}` : ` · CH${settings.source + 1}`}${settings.lpf && settings.mode !== 'logic' ? ` · LPF ${fmt(settings.lpf, 'Hz')}` : ''}`;
  $('timing').textContent = frame?.period ? `${fmt(1 / frame.period, 'Sa/s')} · ${frame.count.toLocaleString()} points${frame.decimation > 1 ? ` · ${frame.decimation}× decimation` : ''}` : frame?.kind === 'meter' ? logSummary(frame) : '— Sa/s · — points';
  if (settings.mode === 'meter') $('log-span').textContent = frame?.kind === 'meter' && frame.history.length ? `${frame.history.length} PT · ${fmt(frame.history.at(-1).time, 's').toUpperCase()}` : 'EMPTY';
  $('empty-state').hidden = !!frame; $('export').disabled = !frame;
  $('meter-values').hidden = frame?.kind !== 'meter';
  $('measurements').replaceChildren();
  const cursorCard = frame?.kind === 'scope' && settings.mode === 'scope' && cursors.enabled;
  $('measurements').style.setProperty('--cards', Math.max(3, (frame?.kind === 'scope' ? frame.traces.length : 0) + (cursorCard ? 1 : 0)));
  const addCard = (titleText, colour, rows) => {
    const card = document.createElement('article'); card.className = 'measurement'; if (colour) card.style.setProperty('--channel-color', colour);
    const title = document.createElement('h2'); title.innerHTML = colour ? '<i></i> ' : ''; title.append(titleText.toUpperCase()); card.append(title);
    const table = document.createElement('table');
    for (const [label, value] of rows) { const row = table.insertRow(); row.insertCell().textContent = label; const td = row.insertCell(); td.className = 'value'; td.textContent = value; }
    card.append(table); $('measurements').append(card);
  };
  if (frame?.kind === 'scope' && settings.mode === 'spectrum') {
    // Distortion and noise from the spectrum on screen, as the Mac shows them:
    // a card a channel, and the harmonics beside it when there is only one.
    const measured = (plot.spectra || []).filter(entry => entry.quality);
    const percent = v => `${(v * 100).toFixed(2)} %`, decibels = v => Number.isFinite(v) ? `${v.toFixed(1)} dB` : '—';
    for (const entry of measured) addCard(`Channel ${entry.index + 1}`, COLORS[entry.index], [
      ['Frequency', fmt(entry.quality.fundamental.frequency, 'Hz')], ['Level', fmt(entry.quality.fundamental.amplitude, 'V')],
      ['THD', percent(entry.quality.thd)], ['THD+N', percent(entry.quality.thdPlusNoise)],
      ['SNR', decibels(entry.quality.snr)], ['SINAD', decibels(entry.quality.sinad)], ['ENOB', `${entry.quality.enob.toFixed(1)} bits`]]);
    if (measured.length === 1) addCard('Harmonics', '', measured[0].quality.harmonics.slice(0, 5).map((peak, i) => [`H${i + 2}`, fmt(peak.amplitude, 'V')]));
    $('measurements').style.setProperty('--cards', Math.max(3, measured.length + (measured.length === 1 ? 1 : 0)));
    if (!measured.length) { const el = document.createElement('div'); el.className = 'measurement-placeholder'; el.textContent = 'A tone has to be on screen before its distortion can be measured.'; $('measurements').append(el); }
  }
  else if (frame?.kind === 'scope') {
  for (const trace of frame.traces) {
    addCard(`Channel ${trace.index + 1}`, COLORS[trace.index], [['Peak to peak', fmt(trace.stats.pp, 'V')], ['Mean', fmt(trace.stats.mean, 'V')], ['RMS', fmt(trace.stats.rms, 'V')], ['AC RMS', fmt(trace.stats.acRms, 'V')],
      ['Frequency', fmt(trace.stats.frequency, 'Hz')], ['Duty', trace.stats.duty === null ? '—' : `${(trace.stats.duty * 100).toFixed(1)} %`], ['Rise', fmt(trace.stats.rise, 's')]]);
  }
  if (cursorCard) {
    const card = document.createElement('article'); card.className = 'measurement'; card.style.setProperty('--channel-color', CURSOR_COLOR);
    const title = document.createElement('h2'); title.innerHTML = '<i></i> CURSORS'; card.append(title);
    const table = document.createElement('table'), span = Math.abs(cursors.b - cursors.a) * frame.count * frame.period;
    for (const [label, value] of [['Δt', fmt(span, 's')], ['1/Δt', span > 0 ? fmt(1 / span, 'Hz') : '—']]) { const row = table.insertRow(); row.insertCell().textContent = label; const td = row.insertCell(); td.className = 'value'; td.textContent = value; }
    card.append(table); $('measurements').append(card);
  }
  }
  else if (frame?.kind === 'meter') {
    $('meter-values').replaceChildren(...frame.values.map((value, i) => { const el = document.createElement('div'); el.className = 'meter-value'; el.style.color = COLORS[i]; const label = document.createElement('small'); label.textContent = `CH${i + 1}`; el.append(label, document.createTextNode(fmt(value, 'V', 4))); return el; }));
    const hint = document.createElement('div'); hint.className = 'measurement-placeholder'; hint.textContent = 'Meter readings are DC coupled. Ground the inputs before checking offsets.'; $('measurements').append(hint);
  } else if (frame?.kind === 'logic') {
    // A card an input, as on the Mac: its rate and duty, or which way it sits idle.
    const activity = logicActivity(frame.samples, frame.period, caps().logicChannels);
    $('measurements').style.setProperty('--cards', 4);
    for (const a of activity) addCard(`D${a.channel}`, COLORS[a.channel], a.idle
      ? [['State', a.idleHigh ? 'idle high' : 'idle low']]
      : [['Frequency', fmt(a.frequency, 'Hz')], ['Duty', `${Math.round(a.duty * 100)} %`]]);
  } else {
    const el = document.createElement('div'); el.className = 'measurement-placeholder'; el.textContent = 'Measurements appear with your first capture.'; $('measurements').append(el);
  }
  $('decode-panel').hidden = !(frame?.kind === 'logic' && settings.decoder !== 'None');
  if (!$('decode-panel').hidden) {
    const items = decodeLogic(frame.samples, frame.period, settings);
    $('decode-title').textContent = `${settings.decoder} · ${items.length.toLocaleString()} items`;
    $('decoded').replaceChildren();
    if (!items.length) { const el = document.createElement('span'); el.className = 'decode-empty'; el.textContent = 'Nothing decoded from this record yet.'; $('decoded').append(el); }
    // Each item says when it happened, counted from the trigger.
    for (const item of items.slice(0, 2000)) {
      const el = document.createElement('span'); el.className = `byte${item.kind === 'error' ? ' bad' : item.kind === 'control' ? ' control' : ''}`;
      el.textContent = item.text; el.title = fmt((item.start - frame.triggerIndex) * frame.period, 's'); $('decoded').append(el);
    }
  }
  document.querySelectorAll('[data-zero]').forEach(el => { el.disabled = !frame || frame.kind !== 'scope'; });
}
async function changed() {
  showError();
  if (!instrument) return;
  if (acquisition.running) acquisition.start(settings);
  else try {
    await acquisition.configure(settings);
  } catch (e) { showError(e.message); }
}
async function connect(demo) {
  if (instrument || connecting) return;
  connecting = true; showError(); updateButtons();
  try {
    instrument = demo ? new DemoInstrument() : overNetwork ? await connectOverNetwork() : await Instrument.connect(); acquisition.attach(instrument); frame = null;
    if (demo) settings.channels.forEach(ch => { ch.range = 1; ch.scale = 1; });
    settings.channels.forEach(ch => { if (ch.range >= frontEnd().length) ch.range = 0; });
    // The zero and the gain describe the wiring, so connecting does not clear
    // them, and a trigger level that works is not moved either.
    seedTriggerLevel();
    settings.record = Math.min(settings.record, caps().maxRecord);
    if (!(caps().flags & 8)) settings.lpf = 0;
    synchronize();
    if (demo) acquisition.start(settings);
    else { await instrument.abort(); $('status').textContent = 'Connected · press Run'; }
  } catch (e) { if (e.name !== 'NotFoundError') showError(e.message); instrument = null; acquisition.attach(null); }
  finally { connecting = false; updateButtons(); }
}
$('connect').onclick = () => connect(false); $('demo').onclick = () => connect(true);
$('empty-demo').onclick = () => instrument ? acquisition.start(settings, true) : connect(true);
$('disconnect').onclick = async () => {
  try { await acquisition.stop(); await instrument?.close(); } catch (e) { showError(e.message); }
  finally { instrument = null; acquisition.attach(null); frame = null; synchronize(); $('status').textContent = 'Disconnected'; }
};
$('run').onclick = async () => { showError(); if (acquisition.running) { try { await acquisition.stop(); } catch (e) { showError(e.message); } } else acquisition.start(settings); updateButtons(); };
$('single').onclick = () => { showError(); acquisition.start(settings, true); updateButtons(); };
$('clear').onclick = () => { frame = null; acquisition.resetLog(); plot.resetSpectrum(); renderFrame(); };
$('export').onclick = () => {
  let text = csv(frame), name = `pilyzer-${settings.mode}-${new Date().toISOString().replace(/[:.]/g, '-')}.csv`;
  if (settings.mode === 'spectrum' && plot.spectra) text = spectrumCsv(plot.spectra);
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' })), a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
// Cursors belong to the session rather than the saved settings, as on the Mac.
const cursors = { enabled: false, a: .3, b: .7 };
plot.cursors = cursors;
function showCursors() {
  $('cursors-enabled').checked = cursors.enabled; $('cursor-controls').hidden = !cursors.enabled;
  for (const key of ['a', 'b']) { $(`cursor-${key}`).value = cursors[key]; $(`cursor-${key}-value`).value = `${Math.round(cursors[key] * 100)} %`; }
}
$('cursors-enabled').addEventListener('change', () => { cursors.enabled = $('cursors-enabled').checked; showCursors(); renderFrame(); });
for (const key of ['a', 'b']) $(`cursor-${key}`).addEventListener('input', () => { cursors[key] = Number($(`cursor-${key}`).value); showCursors(); renderFrame(); });
showCursors();
$('lpf-enabled').addEventListener('change', () => { settings.lpf = $('lpf-enabled').checked ? rememberedCutoff : 0; synchronize(); changed(); });
// The reading follows the thumb; the instrument hears about it when it stops.
$('lpf').addEventListener('input', () => { settings.lpf = Math.round(10 ** Number($('lpf').value)); $('lpf-value').value = `${settings.lpf.toLocaleString()} Hz`; });
$('lpf').addEventListener('change', () => { synchronize(); changed(); });
$('lpf-1k').addEventListener('click', () => { settings.lpf = 1000; synchronize(); changed(); });
$('spectrum-span').addEventListener('change', () => {
  setSpectrumSpan(settings, Number($('spectrum-span').value), caps(), activeChannels(settings, caps()).length);
  synchronize(); changed();
});
$('spectrum-resolution').addEventListener('change', () => {
  setSpectrumResolution(settings, Number($('spectrum-resolution').value), caps(), activeChannels(settings, caps()).length);
  synchronize(); changed();
});
for (const [id, key] of Object.entries(NUMERIC_CONTROLS)) {
  $(id).addEventListener('change', () => {
    const value = Number($(id).value); if (!Number.isFinite(value)) return;
    // Points logged at one interval cannot share a time axis with points logged
    // at another, so changing it starts a new log.
    if (key === 'logInterval' && value !== settings[key]) { acquisition.resetLog(); frame = null; }
    settings[key] = value; synchronize(); changed();
  });
}
// A slider only reaches the instrument when it is let go, so the drag has
// nothing to redraw — but the reading beside it follows the thumb.
for (const [id, format] of Object.entries(SLIDER_READOUTS)) $(id).addEventListener('input', () => { $(`${id}-label`).value = format(Number($(id).value)); });
$('source').onchange = () => { settings.source = Number($('source').value); synchronize(); changed(); };
for (const [id, key] of CHECK_CONTROLS) $(id).onchange = () => { settings[key] = $(id).checked; synchronize(); changed(); };
for (const [id, key] of STRING_CONTROLS) $(id).onchange = () => { settings[key] = $(id).value; synchronize(); changed(); };
for (const el of document.querySelectorAll('[data-mode]')) el.onclick = async () => {
  const wasRunning = acquisition.running; try { await acquisition.stop(); } catch (e) { showError(e.message); }
  settings.mode = el.dataset.mode; frame = null; plot.resetSpectrum(); synchronize(); if (wasRunning) acquisition.start(settings);
};
for (let i = 0; i < 8; i++) {
  const label = document.createElement('label'), input = document.createElement('input'); input.type = 'checkbox'; input.checked = true;
  input.onchange = () => { if (input.checked) settings.logicEnabled |= 1 << i; else settings.logicEnabled &= ~(1 << i); saveSettings(); renderFrame(); };
  label.append(input, document.createTextNode(`D${i}`)); $('logic-lines').append(label);
  for (const select of document.querySelectorAll('[data-logic-line]')) select.add(option(i, `D${i}`));
}
if (navigator.usb) navigator.usb.addEventListener('disconnect', event => {
  if (instrument && !instrument.demo && event.device === instrument.transport.device) {
    acquisition.running = false; acquisition.token++; instrument = null; acquisition.attach(null); showError('The instrument was unplugged. Reconnect USB to continue.'); updateButtons();
  }
});
window.addEventListener('pagehide', () => { acquisition.token++; if (instrument && !instrument.demo) instrument.close().catch(() => {}); });
// If this page was served by an instrument, `rpc` answers beside it and there
// is nothing to plug in or choose. Anywhere else the probe fails quickly and
// the USB path stands as before.
servedByInstrument().then(yes => {
  if (!yes) return;
  overNetwork = true;
  $('connect').firstChild.nodeValue = 'Connect ';
  $('browser-note').hidden = true;
  updateButtons(); renderFrame();
});
$('browser-note').hidden = !!navigator.usb;
applyControls(); synchronize();
