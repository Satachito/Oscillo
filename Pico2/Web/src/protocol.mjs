// PiLyzer protocol v1. Keep this in step with ../../docs/protocol.md.
export const USB_IDS = { vendorId: 0x1209, productId: 0x0001 };
export const OP = Object.freeze({ identify: 1, capabilities: 2, range: 4, test: 5, analogConfigure: 0x10, analogArm: 0x11, analogStatus: 0x12, analogRead: 0x13, analogAbort: 0x14, sample: 0x15, logicConfigure: 0x20, logicArm: 0x21, logicStatus: 0x22, logicRead: 0x23, logicAbort: 0x24 });
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
  if (bytes[0] !== 0x5a || bytes[1] !== opcode || v.getUint16(4, true) !== sequence) throw new Error('USB response is out of sequence. Reconnect the instrument.');
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
export const ranges = board => board === 0 ? [{ name: '0–3.3 V', gain: 1, offset: 0 }] : [{ name: '±25 V', gain: .062645, offset: 1.650515 }, { name: '±5 V', gain: .297269, offset: 1.652442 }];
export function scaleFor(settings, caps, board, channel) {
  const ch = settings.channels[channel], r = ranges(board)[ch.range] || ranges(board)[0];
  const zero = ch.zero?.[ch.range] || 0;
  const volts = code => ((code / caps.fullScale * caps.reference - r.offset) / r.gain - zero) * ch.probe;
  const code = volts => Math.max(0, Math.min(caps.fullScale, Math.round(((volts / ch.probe + zero) * r.gain + r.offset) / caps.reference * caps.fullScale)));
  const low = volts(0), high = volts(caps.fullScale), span = high - low;
  let centre = (low + high) / 2;
  if (Math.abs(centre) < Math.abs(span) / 1000) centre = 0;
  return { volts, code, low, high, span, centre, zero, r };
}
export function analogRequest(settings, caps, board) {
  const active = activeChannels(settings, caps);
  if (!active.length) throw new Error('Enable at least one channel.');
  const mask = active.reduce((m, c) => m | (1 << c), 0);
  const floor = caps.minCycles / caps.clock * active.length;
  const duration = settings.timebase * 10;
  let count = Math.min(settings.record, caps.maxRecord), period = duration / count;
  if (period < floor) { period = floor; count = Math.min(caps.maxRecord, Math.max(50, Math.round(duration / period))); }
  const source = active.includes(settings.source) ? settings.source : active[0];
  const trigger = scaleFor(settings, caps, board, source);
  const pretrigger = Math.min(Math.floor(count * settings.position), caps.maxPretrigger, count - 1);
  const payload = new Uint8Array(32), v = view(payload);
  payload[0] = mask; payload[1] = settings.trigger; payload[2] = active.indexOf(source); payload[3] = settings.slope;
  v.setUint16(4, trigger.code(settings.level), true);
  v.setUint16(6, Math.round(settings.hysteresis * caps.fullScale), true);
  v.setBigUint64(8, BigInt(Math.round(period * 1e15)), true);
  v.setUint32(16, count, true); v.setUint32(20, pretrigger, true); v.setUint32(24, 100000, true);
  if (settings.lpf && !(caps.flags & 8)) throw new Error('Trigger LPF requires firmware 1.2 or later.');
  v.setUint32(28, settings.lpf, true);
  return { payload, active, mask, count, period, pretrigger, source };
}
export function logicRequest(settings, caps) {
  const bytes = new Uint8Array(24), v = view(bytes);
  bytes[0] = settings.trigger; bytes[1] = settings.logicSource; bytes[2] = settings.slope;
  v.setBigUint64(4, BigInt(Math.round(Math.max(1 / settings.logicRate, 1 / caps.logicClock) * 1e15)), true);
  const count = Math.min(settings.logicRecord, caps.logicMaxRecord);
  v.setUint32(12, count, true); v.setUint32(16, Math.min(Math.floor(count * settings.position), caps.logicMaxPretrigger), true);
  v.setUint32(20, 100000, true); return bytes;
}
export function readRequest(offset, count) {
  const bytes = new Uint8Array(8), v = view(bytes); v.setUint32(0, offset, true); v.setUint32(4, count, true); return bytes;
}
export function splitAnalog(bytes, channels) {
  if (bytes.length % (channels * 2)) throw new Error('Incomplete interleaved sample frame');
  const v = view(bytes), count = bytes.length / channels / 2;
  return Array.from({ length: channels }, (_, c) => Float64Array.from({ length: count }, (_, i) => v.getUint16((i * channels + c) * 2, true)));
}
export const demoCaps = Object.freeze({ channels: 3, bits: 12, logicChannels: 8, ranges: 2, clock: 48000000, minCycles: 97, maxRecord: 16384, maxPretrigger: 16383, logicClock: 150000000, logicMaxRecord: 65536, logicMaxPretrigger: 65535, reference: 3.3, flags: 11, fullScale: 65520 });
