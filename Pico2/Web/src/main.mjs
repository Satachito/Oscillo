import { USBInstrument } from './usb.mjs';
import { Acquisition, DemoInstrument, makeSettings } from './acquisition.mjs';
import { activeChannels, demoCaps, ranges, scaleFor, usableTriggerLevel } from './protocol.mjs';
import { fmt, csv, decodeUART } from './signal.mjs';
import { COLORS, Plot } from './plot.mjs';
const $ = id => document.getElementById(id);
const NUMERIC_CONTROLS = { timebase: 'timebase', record: 'record', 'log-interval': 'logInterval', trigger: 'trigger', slope: 'slope', level: 'level', position: 'position', hysteresis: 'hysteresis', lpf: 'lpf', 'test-frequency': 'testFrequency', 'logic-rate': 'logicRate', 'logic-record': 'logicRecord', 'uart-line': 'uartLine', 'uart-baud': 'uartBaud' };
const CHECK_CONTROLS = [['test-enabled', 'testEnabled'], ['xy', 'xy'], ['uart', 'uart']];
const STORAGE_KEY = 'pilyzer.settings.v1';
// The front panel comes back the way it was left. Per-channel zeroing does not:
// that belongs to a calibration session, and connecting starts a new one.
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
      if (stored) for (const [field, current] of Object.entries(channel)) if (field !== 'zero' && accept(stored[field], current)) channel[field] = stored[field];
    }
    else if (accept(saved[key], value)) defaults[key] = saved[key];
  }
  if (!['scope', 'spectrum', 'logic', 'meter'].includes(defaults.mode)) defaults.mode = 'scope';
  return defaults;
}
function saveSettings() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...settings, channels: settings.channels.map(({ zero, ...rest }) => rest) })); } catch { /* private windows and disabled storage are fine */ }
}
// Restores the controls from the settings, which may have come back from an
// earlier visit rather than from the defaults the markup was written with.
function applyControls() {
  for (const [id, key] of Object.entries(NUMERIC_CONTROLS)) $(id).value = settings[key];
  for (const [id, key] of CHECK_CONTROLS) $(id).checked = settings[key];
  $('position-label').value = `${Math.round(settings.position * 100)}%`;
  $('logic-lines').querySelectorAll('input').forEach((input, i) => { input.checked = !!(settings.logicEnabled & (1 << i)); });
}
let settings = loadSettings(), instrument = null, frame = null, connecting = false;
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
  $('connect').disabled = connecting || !navigator.usb; $('demo').disabled = connecting;
  $('run-dot').classList.toggle('live', acquisition.running);
  $('connection-dot').classList.toggle('connected', !!instrument);
  $('source-badge').textContent = instrument ? instrument.demo ? 'DEMO' : 'USB' : 'OFFLINE';
  $('device-name').textContent = instrument ? `${instrument.identity.name} · firmware ${instrument.identity.firmware}` : 'No instrument connected';
  $('empty-state').hidden = !!frame; $('export').disabled = !frame;
  $('empty-demo').disabled = connecting || acquisition.running;
  $('empty-demo').textContent = instrument ? 'Single capture' : 'Start a demo →';
  $('empty-state').querySelector('h2').textContent = instrument ? 'Ready for your signal.' : 'A closer look at your signal.';
  $('empty-state').querySelector('p').textContent = instrument ? 'Press Run for continuous capture, or Single for one record.' : 'Connect your PiLyzer Pico 2, or explore three channels with the built-in demo.';
}
function option(value, label) { const el = document.createElement('option'); el.value = value; el.textContent = label; return el; }
function options(id, values, selected) { $(id).replaceChildren(...values.map(([value, label]) => option(value, label))); $(id).value = selected; }
function channelControls() {
  $('channels').replaceChildren();
  for (let i = 0; i < caps().channels; i++) {
    const ch = settings.channels[i], el = document.createElement('div'); el.className = 'channel-card'; el.style.setProperty('--channel-color', COLORS[i]);
    el.innerHTML = `<div class="channel-heading"><label><input type="checkbox" data-field="enabled" aria-label="Enable CH${i + 1}"/><span class="marker"></span>CH${i + 1}</label><span class="channel-note">GPIO ${26 + i}</span></div><label class="field">Input range<select data-field="range" aria-label="CH${i + 1} input range"></select></label><div class="field-pair"><label>Scale / div<select data-field="scale" aria-label="CH${i + 1} scale"></select></label><label>Probe<select data-field="probe" aria-label="CH${i + 1} probe"><option value="1">1×</option><option value="10">10×</option></select></label></div><label class="slider-label">Position<output>${ch.offset} div</output><input data-field="offset" aria-label="CH${i + 1} position" type="range" min="-4" max="4" step="0.1"/></label><div class="channel-actions"><label class="check-row"><input type="checkbox" data-field="ac" aria-label="CH${i + 1} remove mean"/>Remove mean</label><button class="zero-button" data-zero title="Ground this input and capture a trace before setting zero.">Set zero</button><button class="zero-button" data-reset>Reset</button></div>`;
    const range = el.querySelector('[data-field=range]'); frontEnd().forEach((r, j) => range.add(option(j, r.name))); range.disabled = frontEnd().length < 2;
    const scale = el.querySelector('[data-field=scale]'); [[0, 'Full range'], ...[.01, .02, .05, .1, .2, .5, 1, 2, 5, 10, 20].map(v => [v, fmt(v, 'V')])].forEach(([v, t]) => scale.add(option(v, t)));
    for (const control of el.querySelectorAll('[data-field]')) {
      const key = control.dataset.field;
      if (control.type === 'checkbox') control.checked = ch[key]; else control.value = ch[key];
      if (key === 'enabled') control.disabled = ch.enabled && activeChannels(settings, caps()).length === 1;
      control.addEventListener('change', () => {
        ch[key] = control.type === 'checkbox' ? control.checked : Number(control.value);
        if (!activeChannels(settings, caps()).length) ch.enabled = true;
        synchronize(); changed();
      });
    }
    el.querySelector('[data-zero]').disabled = !frame || frame.kind !== 'scope';
    el.querySelector('[data-zero]').onclick = () => {
      const trace = frame?.traces?.find(t => t.index === i); if (!trace) { showError(`Capture CH${i + 1} first.`); return; }
      ch.zero[ch.range] += trace.stats.mean / ch.probe; synchronize(); changed();
    };
    el.querySelector('[data-reset]').onclick = () => { ch.zero = [0, 0]; synchronize(); changed(); };
    $('channels').append(el);
  }
}
const timebases = [10e-6, 20e-6, 50e-6, .0001, .0002, .0005, .001, .002, .005, .01, .02, .05, .1, .2, .5, 1, 2, 5];
// A level left behind by another range sits on the rail, where no signal ever
// crosses it. That reads as a broken trigger, so it is moved into reach.
function settleTriggerLevel() {
  if (settings.mode === 'logic' || settings.mode === 'meter') return;
  const usable = usableTriggerLevel(scaleFor(settings, caps(), frontEnd(), settings.source), settings.level);
  if (Math.abs(usable - settings.level) > 1e-9) { settings.level = usable; $('level').value = Number(usable.toPrecision(6)); }
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
  options('source', (logic ? Array.from({ length: caps().logicChannels }, (_, i) => i) : active).map(i => [i, `${logic ? 'D' : 'CH'}${logic ? i : i + 1}`]), logic ? settings.logicSource : settings.source);
  $('active-count').textContent = `${active.length} channel${active.length === 1 ? '' : 's'} enabled`;
  $('max-rate').replaceChildren(document.createTextNode(fmt(caps().clock / caps().minCycles / Math.max(active.length, 1), 'Sa/s') + ' '), Object.assign(document.createElement('small'), { textContent: '/ channel max' }));
  $('horizontal-controls').hidden = logic || meter; $('trigger-controls').hidden = meter; $('analog-trigger-extra').hidden = logic;
  $('logger-controls').hidden = !meter;
  $('channel-controls').hidden = logic; $('logic-controls').hidden = !logic;
  $('level').disabled = logic; $('xy').disabled = settings.mode !== 'scope' || active.length < 2;
  $('test-controls').hidden = instrument && !(caps().flags & 2);
  $('test-frequency').disabled = !settings.testEnabled;
  $('lpf').disabled = instrument && !(caps().flags & 8);
  for (const op of $('record').options) op.disabled = Number(op.value) > caps().maxRecord;
  for (const op of $('logic-rate').options) op.disabled = Number(op.value) > caps().logicClock;
  for (const op of $('logic-record').options) op.disabled = Number(op.value) > caps().logicMaxRecord;
  if (instrument) {
    const [major, minor] = instrument.identity.firmware.split('.').map(Number);
    const pin = instrument.identity.board === 3 ? 22 : major > 1 || minor >= 5 ? 20 : minor >= 3 ? 28 : 2;
    $('test-pin').textContent = instrument.demo ? 'Demo is generated in this browser. Test output controls apply to a USB instrument.' : `GPIO${pin} · 0–3.3 V square wave. Wire the output to an input to measure it.`;
  }
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
function renderFrame() {
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
  $('trigger-summary').textContent = settings.mode === 'meter' ? 'Logging all inputs · min/mean/max a point' : `Trigger: ${['Free run', 'Auto', 'Normal'][settings.trigger]}${settings.mode === 'logic' ? ` · D${settings.logicSource}` : ` · CH${settings.source + 1}`}${settings.lpf && settings.mode !== 'logic' ? ` · LPF ${fmt(settings.lpf, 'Hz')}` : ''}`;
  $('timing').textContent = frame?.period ? `${fmt(1 / frame.period, 'Sa/s')} · ${frame.count.toLocaleString()} points${frame.decimation > 1 ? ` · ${frame.decimation}× decimation` : ''}` : frame?.kind === 'meter' ? logSummary(frame) : '— Sa/s · — points';
  if (settings.mode === 'meter') $('log-span').textContent = frame?.kind === 'meter' && frame.history.length ? `${frame.history.length} PT · ${fmt(frame.history.at(-1).time, 's').toUpperCase()}` : 'EMPTY';
  $('empty-state').hidden = !!frame; $('export').disabled = !frame;
  $('meter-values').hidden = frame?.kind !== 'meter';
  $('measurements').replaceChildren();
  if (frame?.kind === 'scope') for (const trace of frame.traces) {
    const card = document.createElement('article'); card.className = 'measurement'; card.style.setProperty('--channel-color', COLORS[trace.index]);
    const title = document.createElement('h2'); title.innerHTML = `<i></i> CHANNEL ${trace.index + 1}`; card.append(title);
    const table = document.createElement('table');
    const rows = settings.mode === 'spectrum' && trace === frame.traces[0] && plot.spectrum?.peak
      ? [['Peak', fmt(plot.spectrum.peak.frequency, 'Hz')], ['Level', `${plot.spectrum.peak.db.toFixed(1)} dBV`], ['Resolution', fmt(plot.spectrum.resolution, 'Hz')]]
      : [['Peak to peak', fmt(trace.stats.pp, 'V')], ['Frequency', fmt(trace.stats.frequency, 'Hz')], ['RMS', fmt(trace.stats.rms, 'V')], ['Mean', fmt(trace.stats.mean, 'V')]];
    for (const [label, value] of rows) { const row = table.insertRow(); row.insertCell().textContent = label; const td = row.insertCell(); td.className = 'value'; td.textContent = value; }
    card.append(table); $('measurements').append(card);
  }
  else if (frame?.kind === 'meter') {
    $('meter-values').replaceChildren(...frame.values.map((value, i) => { const el = document.createElement('div'); el.className = 'meter-value'; el.style.color = COLORS[i]; const label = document.createElement('small'); label.textContent = `CH${i + 1}`; el.append(label, document.createTextNode(fmt(value, 'V', 4))); return el; }));
    const hint = document.createElement('div'); hint.className = 'measurement-placeholder'; hint.textContent = 'Meter readings are DC coupled. Ground the inputs before checking offsets.'; $('measurements').append(hint);
  } else {
    const el = document.createElement('div'); el.className = 'measurement-placeholder'; el.textContent = frame?.kind === 'logic' ? 'Digital inputs D0–D7 · enable UART decode to inspect a serial signal.' : 'Measurements appear with your first capture.'; $('measurements').append(el);
  }
  $('decode-panel').hidden = !(frame?.kind === 'logic' && settings.uart);
  if (!$('decode-panel').hidden) {
    const decoded = decodeUART(frame.samples, frame.period, settings.uartLine, settings.uartBaud);
    $('decode-advice').textContent = decoded.advice; $('decoded').replaceChildren();
    for (const item of decoded.result) { const el = document.createElement('span'); el.className = 'byte' + (item.error ? ' bad' : ''); el.textContent = item.value.toString(16).padStart(2, '0').toUpperCase(); el.title = `${fmt(item.time, 's')} · ${item.error ? 'framing error' : item.value >= 32 && item.value < 127 ? String.fromCharCode(item.value) : item.value}`; $('decoded').append(el); }
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
    instrument = demo ? new DemoInstrument() : await USBInstrument.connect(); acquisition.attach(instrument); frame = null;
    settings.channels.forEach(ch => { ch.zero = [0, 0]; });
    if (demo) settings.channels.forEach(ch => { ch.range = 1; ch.scale = 1; });
    // Start the trigger where the front end's own range is centred: mid rail on
    // a bare Pico 2, zero on a bipolar front end. No board id needed.
    settings.channels.forEach(ch => { if (ch.range >= frontEnd().length) ch.range = 0; });
    settings.level = scaleFor(settings, caps(), frontEnd(), 0).centre;
    $('level').value = settings.level;
    settings.record = Math.min(settings.record, caps().maxRecord);
    if (!(caps().flags & 8)) { settings.lpf = 0; $('lpf').value = 0; }
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
$('clear').onclick = () => { frame = null; acquisition.resetLog(); renderFrame(); };
$('export').onclick = () => {
  let text = csv(frame), name = `pilyzer-${settings.mode}-${new Date().toISOString().replace(/[:.]/g, '-')}.csv`;
  if (settings.mode === 'spectrum' && plot.spectrum) text = 'frequency_Hz,rms_V,level_dBV\n' + plot.spectrum.bins.map(b => `${b.frequency},${b.rms},${b.db}`).join('\n') + '\n';
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' })), a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
for (const [id, key] of Object.entries(NUMERIC_CONTROLS)) {
  $(id).addEventListener('change', () => {
    const value = Number($(id).value); if (!Number.isFinite(value)) return;
    // Points logged at one interval cannot share a time axis with points logged
    // at another, so changing it starts a new log.
    if (key === 'logInterval' && value !== settings[key]) { acquisition.resetLog(); frame = null; }
    settings[key] = value; $('position-label').value = `${Math.round(settings.position * 100)}%`; synchronize(); changed();
  });
}
$('source').onchange = () => { settings[settings.mode === 'logic' ? 'logicSource' : 'source'] = Number($('source').value); saveSettings(); changed(); renderFrame(); };
for (const [id, key] of CHECK_CONTROLS) $(id).onchange = () => { settings[key] = $(id).checked; synchronize(); changed(); };
for (const el of document.querySelectorAll('[data-mode]')) el.onclick = async () => {
  const wasRunning = acquisition.running; try { await acquisition.stop(); } catch (e) { showError(e.message); }
  settings.mode = el.dataset.mode; frame = null; synchronize(); if (wasRunning) acquisition.start(settings);
};
for (let i = 0; i < 8; i++) {
  const label = document.createElement('label'), input = document.createElement('input'); input.type = 'checkbox'; input.checked = true;
  input.onchange = () => { if (input.checked) settings.logicEnabled |= 1 << i; else settings.logicEnabled &= ~(1 << i); saveSettings(); renderFrame(); };
  label.append(input, document.createTextNode(`D${i}`)); $('logic-lines').append(label); $('uart-line').add(option(i, `D${i}`));
}
if (navigator.usb) navigator.usb.addEventListener('disconnect', event => {
  if (instrument && !instrument.demo && event.device === instrument.transport.device) {
    acquisition.running = false; acquisition.token++; instrument = null; acquisition.attach(null); showError('The instrument was unplugged. Reconnect USB to continue.'); updateButtons();
  }
});
window.addEventListener('pagehide', () => { acquisition.token++; if (instrument && !instrument.demo) instrument.close().catch(() => {}); });
$('browser-note').hidden = !!navigator.usb;
applyControls(); synchronize();
