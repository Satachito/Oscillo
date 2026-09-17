// PiLyzer protocol v1. Keep this in step with ../../docs/protocol.md.
export const USB_IDS = { vendorId: 0x1209, productId: 0x0001 };
export const OP = Object.freeze({ identify: 1, capabilities: 2, range: 4, test: 5, inputRanges: 7, signals: 8, analogConfigure: 0x10, analogArm: 0x11, analogStatus: 0x12, analogRead: 0x13, analogAbort: 0x14, sample: 0x15, logicConfigure: 0x20, logicArm: 0x21, logicStatus: 0x22, logicRead: 0x23, logicAbort: 0x24 });
export const MAX_PAYLOAD = 8192;
export const view = bytes => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
export function request(opcode, sequence, payload = new Uint8Array()) {
  if (payload.length > MAX_PAYLOAD) throw new Error('Request too large');
  const bytes = new Uint8Array(12 + payload.length), v = view(bytes);
  bytes[0] = 0xa5; bytes[1] = opcode;
  v.setUint16(4, sequence, true); v.setUint32(8, payload.length, true);
  bytes.set(payload, 12); return bytes;
}
export function responseHeader(bytes, opcode, sequence) {
  if (bytes.length < 12) throw new Error('Short response header');
  const v = view(bytes), length = v.getUint32(8, true);
  if (bytes[0] !== 0x5a || bytes[1] !== opcode || v.getUint16(4, true) !== sequence) throw new Error(`USB response is out of sequence (expected ${opcode}/${sequence}, header ${Array.from(bytes.slice(0, 12), b => b.toString(16).padStart(2, '0')).join(' ')}). Reconnect the instrument.`);
  if (length > MAX_PAYLOAD) throw new Error('Invalid USB response length');
  return { length, status: bytes[2] };
}
function size(bytes, length, name) { if (bytes.length < length) throw new Error(`Incomplete ${name} reply`); return view(bytes); }
export function identity(bytes) {
  const v = size(bytes, 32, 'identity');
  if (v.getUint32(0, true) !== 0x5a594c50 || v.getUint16(4, true) !== 1) throw new Error('This device does not speak PiLyzer protocol v1.');
  const firmware = v.getUint16(6, true);
  return { name: new TextDecoder().decode(bytes.subarray(12, 32)).split('\0')[0], board: v.getUint32(8, true), firmware: `${firmware >> 8}.${firmware & 255}` };
}
export function capabilities(bytes) {
  const v = size(bytes, 48, 'capabilities');
  const c = { channels: bytes[0], bits: bytes[1], logicChannels: bytes[2], ranges: bytes[3], clock: v.getUint32(4, true), minCycles: v.getUint32(8, true), maxRecord: v.getUint32(12, true), maxPretrigger: v.getUint32(16, true), logicClock: v.getUint32(20, true), logicMaxRecord: v.getUint32(24, true), logicMaxPretrigger: v.getUint32(28, true), reference: v.getUint32(32, true) / 1e6, flags: v.getUint32(36, true) };
  if (c.channels < 1 || c.channels > 3 || c.bits < 8 || c.bits > 16 || c.logicChannels > 8 || !c.clock || !c.minCycles || c.maxRecord < 50 || c.maxRecord > 65536 || c.logicMaxRecord > 131072 || !(c.reference > 0)) throw new Error('Unsupported instrument capabilities');
  c.fullScale = ((2 ** c.bits) - 1) * 2 ** (16 - c.bits); return c;
}
export function plan(bytes) {
  const v = size(bytes, 24, 'acquisition plan');
  const p = { clock: v.getUint32(0, true), divisor: v.getUint32(4, true), decimation: v.getUint32(8, true), count: v.getUint32(12, true), pretrigger: v.getUint32(16, true), mask: bytes[20], channels: bytes[21] };
  p.period = p.divisor / 256 / p.clock * p.decimation * p.channels;
  if (!(p.period > 0) || !Number.isFinite(p.period) || p.count < 1 || p.count > 131072 || p.channels < 1 || p.channels > 3) throw new Error('Invalid acquisition plan');
  return p;
}
export function status(bytes) {
  const v = size(bytes, 16, 'acquisition status');
  return { state: bytes[0], triggered: bytes[1] === 1, count: v.getUint32(4, true), triggerIndex: v.getUint32(8, true) };
}
export const activeChannels = (settings, caps) => settings.channels.flatMap((c, i) => c.enabled && i < caps.channels ? [i] : []);
// One InputRange as the device reports it — see ../../docs/protocol.md. Gain
// arrives in millionths of a volt per volt and offset in microvolts.
export function inputRanges(bytes) {
  const v = view(bytes), result = [];
  for (let offset = 0; offset + 32 <= bytes.length; offset += 32) {
    const name = new TextDecoder().decode(bytes.subarray(offset + 12, offset + 32)).split('\0')[0];
    const gain = v.getInt32(offset + 4, true) / 1e6;
    if (!gain || !name) throw new Error('The instrument described a range this application cannot use.');
    result.push({ name, gain, offset: v.getInt32(offset + 8, true) / 1e6, switchPosition: bytes[offset] });
  }
  if (!result.length) throw new Error('Incomplete input range reply');
  return result;
}
// Firmware before 1.7 does not describe its front end, so the application falls
// back to a table of its own keyed on the board id. This is the only place it
// still compiles in a constant about a particular board, and it exists only for
// those older devices.
export const ranges = board => board === 0 ? [{ name: '0 – 3.3 V', gain: 1, offset: 0, switchPosition: 0 }] : [{ name: '±25 V', gain: .062645, offset: 1.650515, switchPosition: 0 }, { name: '±5 V', gain: .297269, offset: 1.652442, switchPosition: 1 }];
// Volts per division a channel can be set to, and the finest of them that
// still shows the whole range with zero on the centre line — half the grid has
// to hold whichever end is further from zero. This is what a channel nobody has
// set uses, so the menu offers volts per division and nothing else.
export const SCALE_STEPS = [.01, .02, .05, .1, .2, .5, 1, 2, 5, 10, 20];
export const fitScale = scale => {
  const needed = 2 * Math.max(Math.abs(scale.low), Math.abs(scale.high)) / 8;
  return SCALE_STEPS.find(step => step >= needed * 0.999) ?? SCALE_STEPS.at(-1);
};
// The input that reads mid scale: what a passive front end biased to the middle
// of the converter's range leaves on a grounded input. A board that reports its
// own offset has taken it out already, and this comes back at about zero.
// The first of the four pins the generator drives: the sine, and then white,
// pink and brown noise. The same four on every board, which is the point of
// them being where they are.
export const SIGNAL_BASE_PIN = 16;
// The GPIO the test square wave comes out of. The PL2407AFE brings its own SG
// OUT pad here, and every other board followed it.
export const CALIBRATION_PIN = 22;
export const midRailVolts = (caps, range) => (caps.reference / 2 - range.offset) / range.gain;
// What this channel reads with nothing on the input: measured if anybody has,
// otherwise what the bias was set to. Both calibrations are measured from it.
export const referenceBias = ch => ch.measuredBias ?? ch.bias ?? 0;
// `frontEnd` is the instrument's own range list, from inputRanges() or from the
// fallback table. Nothing below this line knows what board it is talking to.
export function scaleFor(settings, caps, frontEnd, channel) {
  const ch = settings.channels[channel], r = frontEnd[ch.range] || frontEnd[0];
  // The divider's own tolerance: 1% parts put the gain out by up to 2%, which
  // no range descriptor can know. One known voltage measures it away. There is
  // deliberately no offset beside it — what the converter saw is what the
  // screen shows, and a front end's bias is drawn as a line rather than taken
  // out of the numbers.
  const correction = ch.gain?.[ch.range] || 1;
  const volts = code => (code / caps.fullScale * caps.reference - r.offset) / r.gain * correction * ch.probe;
  const code = volts => Math.max(0, Math.min(caps.fullScale, Math.round((volts / ch.probe / correction * r.gain + r.offset) / caps.reference * caps.fullScale)));
  const low = volts(0), high = volts(caps.fullScale), span = high - low;
  // Zero is the centre line on every range. A range that reaches only one side
  // of zero used to centre on its own midpoint so that it filled the grid, and
  // the cost was a centre line reading 1.65 V: a trace at 3.3 V then looks
  // like it is at 1.65 unless every division is counted from the legend.
  return { volts, code, low, high, span, centre: 0, correction, r };
}
// A trigger level sitting on the rail never fires, which looks exactly like a
// broken trigger rather than a level left behind by a range change. Keep it
// somewhere the signal can actually reach.
// Where a trigger level can usefully sit: the range with 2% kept off each rail.
export function triggerWindow(scale) {
  const margin = Math.abs(scale.span) * .02;
  const low = Math.min(scale.low, scale.high) + margin, high = Math.max(scale.low, scale.high) - margin;
  return low < high ? { low, high } : null;
}
// The middle of what a channel reads: the bias a front end holds the input at.
// A trigger that cannot fire where it is starts here, because it is the one
// level a biased signal is certain to cross.
export const biasVolts = scale => scale.volts(65520 / 2);
export function usableTriggerLevel(scale, volts) {
  const window = triggerWindow(scale);
  if (!window) return scale.centre;
  return Math.min(Math.max(volts, window.low), window.high);
}
// The wire structures of docs/protocol.md, kept apart from the planners above
// them so the byte layout can be checked against tests/fixtures/wire-golden.json
// — the same file the Swift core is checked against.
export function encodeAnalogConfig(f) {
  const bytes = new Uint8Array(32), v = view(bytes);
  bytes[0] = f.mask; bytes[1] = f.triggerMode; bytes[2] = f.triggerSlot; bytes[3] = f.triggerSlope;
  v.setUint16(4, f.level, true); v.setUint16(6, f.hysteresis, true);
  v.setBigUint64(8, BigInt(f.periodFs), true);
  v.setUint32(16, f.record, true); v.setUint32(20, f.pretrigger, true);
  v.setUint32(24, f.timeoutUs, true); v.setUint32(28, f.lowPassHz, true);
  return bytes;
}
export function encodeLogicConfig(f) {
  const bytes = new Uint8Array(24), v = view(bytes);
  bytes[0] = f.triggerMode; bytes[1] = f.triggerChannel; bytes[2] = f.triggerSlope;
  v.setBigUint64(4, BigInt(f.periodFs), true);
  v.setUint32(12, f.record, true); v.setUint32(16, f.pretrigger, true); v.setUint32(20, f.timeoutUs, true);
  return bytes;
}
export function analogRequest(settings, caps, frontEnd) {
  const active = activeChannels(settings, caps);
  if (!active.length) throw new Error('Enable at least one channel.');
  const mask = active.reduce((m, c) => m | (1 << c), 0);
  const floor = caps.minCycles / caps.clock * active.length;
  const duration = settings.timebase * 10;
  let count = Math.min(settings.record, caps.maxRecord), period = duration / count;
  if (period < floor) { period = floor; count = Math.min(caps.maxRecord, Math.max(50, Math.round(duration / period))); }
  const source = active.includes(settings.source) ? settings.source : active[0];
  const trigger = scaleFor(settings, caps, frontEnd, source);
  const pretrigger = Math.min(Math.floor(count * settings.position), caps.maxPretrigger, count - 1);
  if (settings.lpf && !(caps.flags & 8)) throw new Error('Trigger LPF requires firmware 1.2 or later.');
  const payload = encodeAnalogConfig({
    mask, triggerMode: settings.trigger, triggerSlot: active.indexOf(source), triggerSlope: settings.slope,
    level: trigger.code(settings.level),
    // The firmware compares hysteresis against a converter code, so the same
    // ceiling as the native application applies here.
    hysteresis: Math.min(Math.round(settings.hysteresis * caps.fullScale), 4095),
    periodFs: Math.round(period * 1e15), record: count, pretrigger, timeoutUs: 100000, lowPassHz: settings.lpf,
  });
  return { payload, active, mask, count, period, pretrigger, source };
}
export function logicRequest(settings, caps) {
  const count = Math.min(settings.logicRecord, caps.logicMaxRecord);
  return encodeLogicConfig({
    triggerMode: settings.trigger, triggerChannel: settings.logicSource, triggerSlope: settings.slope,
    periodFs: Math.round(Math.max(1 / settings.logicRate, 1 / caps.logicClock) * 1e15),
    record: count, pretrigger: Math.min(Math.floor(count * settings.position), caps.logicMaxPretrigger), timeoutUs: 100000,
  });
}
export function readRequest(offset, count) {
  const bytes = new Uint8Array(8), v = view(bytes); v.setUint32(0, offset, true); v.setUint32(4, count, true); return bytes;
}
export function splitAnalog(bytes, channels) {
  if (bytes.length % (channels * 2)) throw new Error('Incomplete interleaved sample frame');
  const v = view(bytes), count = bytes.length / channels / 2;
  return Array.from({ length: channels }, (_, c) => Float64Array.from({ length: count }, (_, i) => v.getUint16((i * channels + c) * 2, true)));
}
export const demoCaps = Object.freeze({ channels: 3, bits: 12, logicChannels: 8, ranges: 2, clock: 48000000, minCycles: 97, maxRecord: 16384, maxPretrigger: 16383, logicClock: 150000000, logicMaxRecord: 65536, logicMaxPretrigger: 65535, reference: 3.3, flags: 11 | 32, fullScale: 65520 });

// The spectrum's own words for the two settings a sweep is made of, as on the
// Mac. The time on screen is the resolution — a bin is one over it — and the
// points spread across it set the sample rate, half of which is the highest
// frequency the record holds. Span and resolution are those settings said the
// other way round, so the scope still shows the record a spectrum came from.
// The record lengths are powers of two, which is also what the transform trims
// a record to, so the resolution chosen is the bin width got.
export const RECORD_LENGTHS = [512, 1024, 2048, 4096, 8192, 16384];
export const resolutionFor = timebase => 1 / (timebase * 10);
const fastestRate = (caps, channels) => caps.clock / caps.minCycles / Math.max(channels, 1);
// Spans in a 1–2–5 sequence, up to half the fastest rate these channels share.
export function spectrumSpans(caps, channels) {
  const top = fastestRate(caps, channels) / 2, spans = [];
  for (let decade = 10; decade <= top; decade *= 10) for (const m of [1, 2, 5]) if (decade * m <= top) spans.push(decade * m);
  return spans;
}
// The shortest record that reaches the span at the resolution, or null when
// none can: the longest stops short, or it would sample faster than the converter.
export function spectrumRecord(span, resolution, caps, channels, lengths = RECORD_LENGTHS) {
  const fastest = fastestRate(caps, channels);
  return [...lengths].sort((a, b) => a - b).find(length => length <= caps.maxRecord
    && length * resolution / 2 >= span * (1 - 1e-9) && length * resolution <= fastest * (1 + 1e-9)) ?? null;
}
// Zero is everything the record holds, and leaves the record alone.
export function setSpectrumSpan(settings, span, caps, channels) {
  settings.spectrumSpan = span;
  const record = span ? spectrumRecord(span, resolutionFor(settings.timebase), caps, channels) : null;
  if (record) settings.record = record;
}
export function setSpectrumResolution(settings, timebase, caps, channels) {
  settings.timebase = timebase;
  const record = settings.spectrumSpan ? spectrumRecord(settings.spectrumSpan, resolutionFor(timebase), caps, channels) : null;
  if (record) settings.record = record;
}
// The axis ends at the span, unless the record in hand does not reach it.
export const displayedTop = (span, nyquist) => span > 0 ? Math.min(span, nyquist) : nyquist;
