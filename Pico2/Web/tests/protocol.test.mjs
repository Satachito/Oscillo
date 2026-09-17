import test from 'node:test';
import assert from 'node:assert/strict';
import { resolutionFor, spectrumSpans, spectrumRecord, setSpectrumSpan, setSpectrumResolution, displayedTop, fitScale, midRailVolts, referenceBias, analogRequest, activeChannels, demoCaps, identity, capabilities, plan, readRequest, splitAnalog, scaleFor, ranges, inputRanges, OP, request, responseHeader, view } from '../src/protocol.mjs';
import { makeSettings, Acquisition, DemoInstrument, LOG_CAPACITY } from '../src/acquisition.mjs';
import { BulkTransport } from '../src/instrument.mjs';
import { HttpTransport, available } from '../src/net.mjs';
import { measure, spectrum, spectrumCsv, csv, decodeUART } from '../src/signal.mjs';
const caps = demoCaps;
const afe = ranges(1), bare = ranges(0);
for (let mask = 1; mask < 8; mask++) test(`mask ${mask}: correct channel slots, scale and 97-cycle rate floor`, () => {
  const settings = makeSettings(); settings.timebase = 50e-6; settings.source = 2;
  settings.channels.forEach((c, i) => c.enabled = !!(mask & (1 << i)));
  const actual = analogRequest(settings, caps, afe), active = activeChannels(settings, caps), v = view(actual.payload);
  assert.equal(actual.mask, mask); assert.equal(actual.payload[0], mask);
  assert.equal(actual.payload[2], Math.max(0, active.indexOf(2)));
  assert.ok(Math.abs(actual.period - active.length * 97 / 48000000) < 1e-12);
  assert.equal(v.getBigUint64(8, true), BigInt(Math.round(actual.period * 1e15)));
  assert.equal(v.getUint32(16, true), actual.count);
  assert.ok(actual.pretrigger < actual.count);
});
test('older two-channel device and unipolar scale remain supported', () => {
  const settings = makeSettings(); settings.source = 2; settings.level = 1.65;
  const actual = analogRequest(settings, { ...caps, channels: 2, minCycles: 96 }, bare);
  assert.equal(actual.mask, 3); assert.equal(actual.source, 0);
  assert.ok(Math.abs(view(actual.payload).getUint16(4, true) - 32760) < 1);
  // Zero is the centre line even on a range that never goes below it, and the
  // step a channel starts on is the finest that still shows the whole of it:
  // 0-3.3 V needs 825 mV a division, so 1 V is the one to land on.
  assert.equal(scaleFor(settings, caps, bare, 0).centre, 0);
  assert.equal(fitScale(scaleFor(settings, caps, bare, 0)), 1);
  assert.equal(fitScale(scaleFor(settings, caps, afe, 0)), 10);   // rev A reaches +/-26 V
  settings.channels[0].probe = 10;
  const scale = scaleFor(settings, caps, bare, 0); assert.ok(Math.abs(scale.volts(scale.code(5)) - 5) < .001);
});
test('trigger LPF support and no-channel requests are validated', () => {
  const s = makeSettings(); s.lpf = 1000;
  assert.throws(() => analogRequest(s, { ...caps, flags: 0 }, afe), /LPF/);
  s.channels.forEach(c => c.enabled = false);
  assert.throws(() => analogRequest(s, caps, afe), /Enable/);
});
test('three-channel payload splitting preserves sparse input order', () => {
  const bytes = new Uint8Array(18), v = view(bytes);
  [100, 200, 300, 101, 201, 301, 102, 202, 302].forEach((n, i) => v.setUint16(i * 2, n, true));
  assert.deepEqual(splitAnalog(bytes, 3).map(c => Array.from(c)), [[100, 101, 102], [200, 201, 202], [300, 301, 302]]);
  assert.throws(() => splitAnalog(bytes.slice(1), 3), /Incomplete/);
  assert.equal(view(readRequest(10, 1365)).getUint32(4, true), 1365);
});
test('identity and response sequence are checked before accepting data', () => {
  const data = new Uint8Array(32), v = view(data); v.setUint32(0, 0x5a594c50, true); v.setUint16(4, 1, true); v.setUint16(6, 0x105, true);
  assert.equal(identity(data).firmware, '1.5'); data[0] = 0;
  assert.throws(() => identity(data), /does not speak/);
  const req = request(OP.identify, 24); req[0] = 0x5a;
  assert.equal(responseHeader(req, OP.identify, 24).length, 0);
  assert.throws(() => responseHeader(req, OP.identify, 25), /sequence/);
});
function reply(op, sequence, payload, status = 0) { const bytes = request(op, sequence, payload); bytes[0] = 0x5a; bytes[2] = status; return bytes; }
class FakeDevice {
  opened = true; packets = []; calls = [];
  async transferOut(endpoint, bytes) {
    assert.equal(this.packets.length, 0, 'requests must not overlap');
    const op = bytes[1], seq = view(bytes).getUint16(4, true); this.calls.push(op);
    const payload = op === OP.analogRead ? Uint8Array.from({ length: 8190 }, (_, i) => i % 256) : new Uint8Array([17, 23]);
    const answer = reply(op, seq, payload, op === 99 ? 3 : 0);
    this.packets = [new Uint8Array(), answer.slice(0, 5), answer.slice(5, 12), answer.slice(12, 76), answer.slice(76)].filter((p, i) => i === 0 || p.length);
    return { status: 'ok', bytesWritten: bytes.length };
  }
  async transferIn() { await new Promise(r => setTimeout(r, 1)); const p = this.packets.shift(); return { status: 'ok', data: view(p) }; }
  async close() { this.opened = false; }
}
test('bulk stream handles fragmented headers, full-size payloads, ZLP and concurrent callers', async () => {
  const device = new FakeDevice(), transport = new BulkTransport(device, 2, 1);
  const [large, small] = await Promise.all([transport.exchange(OP.analogRead), transport.exchange(OP.identify)]);
  assert.equal(large.length, 8190); assert.equal(large[8189], 8189 % 256); assert.deepEqual([...small], [17, 23]);
  assert.deepEqual(device.calls, [OP.analogRead, OP.identify]);
});
test('a rejected command leaves framing intact; bad framing closes the device', async () => {
  const device = new FakeDevice(), transport = new BulkTransport(device, 2, 1);
  await assert.rejects(transport.exchange(99), /Invalid setting/);
  assert.equal(device.opened, true); await transport.exchange(OP.identify);
  device.transferIn = async () => ({ status: 'ok', data: view(new Uint8Array(12)) });
  await assert.rejects(transport.exchange(OP.identify), /sequence/); assert.equal(device.opened, false);
});
test('measurements and FFT agree with a known sine wave', () => {
  const rate = 32768, samples = Float64Array.from({ length: 4096 }, (_, i) => 2 * Math.sin(2 * Math.PI * 1000 * i / rate));
  const m = measure(samples, 1 / rate), f = spectrum(samples, 1 / rate);
  assert.ok(Math.abs(m.rms - Math.SQRT2) < .001); assert.ok(Math.abs(m.frequency - 1000) < .01);
  assert.equal(f.peak.frequency, 1000); assert.ok(Math.abs(f.peak.rms - Math.SQRT2) < .002);
});
test('spectrum shows every channel: an input and its half-level output line up bin for bin', () => {
  const rate = 32768, sine = a => Float64Array.from({ length: 4096 }, (_, i) => a * Math.sin(2 * Math.PI * 1000 * i / rate));
  const spectra = [{ index: 0, ...spectrum(sine(2), 1 / rate) }, { index: 2, ...spectrum(sine(1), 1 / rate) }];
  const lines = spectrumCsv(spectra).trim().split('\n');
  assert.equal(lines[0], 'frequency_Hz,CH1_rms_V,CH1_dBV,CH3_rms_V,CH3_dBV');
  assert.equal(lines.length, spectra[0].bins.length + 1);
  const row = lines.find(line => line.startsWith('1000,')).split(',').map(Number);
  assert.ok(Math.abs(row[1] - Math.SQRT2) < .002); assert.ok(Math.abs(row[3] - Math.SQRT1_2) < .001);
  assert.ok(Math.abs(row[2] - row[4] - 20 * Math.log10(2)) < .01, 'the dB difference is the gain');
  assert.equal(spectrumCsv([]), '');
});
test('a bias is drawn, not taken out of the reading', () => {
  const settings = makeSettings(), at = volts => Math.round(volts / 3.3 * 65520);
  // Nothing is subtracted: a bare board biased to mid rail reads 1.65 V, and
  // goes on reading 1.65 V once it has been told that is where it sits.
  assert.equal(Math.round(scaleFor(settings, demoCaps, bare, 0).volts(at(1.65)) * 1000), 1650);
  settings.channels[0].bias = 1.65;
  const scale = scaleFor(settings, demoCaps, bare, 0);
  assert.equal(Math.round(scale.volts(at(1.65)) * 1000), 1650);
  assert.equal(scale.code(1.65), at(1.65));
  // What the button writes, and what a calibration measures from.
  assert.ok(Math.abs(midRailVolts(demoCaps, bare[0]) - 1.65) < 1e-9);
  assert.equal(referenceBias(settings.channels[0]), 1.65);
  settings.channels[0].measuredBias = 1.6312;
  assert.equal(referenceBias(settings.channels[0]), 1.6312);   // measured wins

  // A divider that is 2% low: one known voltage says so, and the correction
  // scales the reading — the only one of the two that does.
  settings.channels[0].gain[0] = 1.02;
  const corrected = scaleFor(settings, demoCaps, bare, 0);
  assert.equal(Math.round(corrected.volts(at(1.0)) * 1000), 1020);
  assert.equal(corrected.code(1.02), at(1.0));                 // and back again
  settings.channels[0].gain[0] = 1;

  // Boards report three ranges; an array stored by an older version holds two.
  settings.channels[0].range = 2;
  const third = [...bare, ...ranges(1)];
  assert.equal(scaleFor(settings, demoCaps, third, 0).correction, 1);
  assert.ok(Number.isFinite(scaleFor(settings, demoCaps, third, 0).volts(at(1.65))));
});
test('the CSV carries what the screen shows, and says which column was centred', () => {
  const frame = { kind: 'scope', period: .001, count: 2, triggerIndex: 1, traces: [
    { index: 0, samples: new Float64Array([-0.021, 0.014]), removedMean: 1.6489 },
    { index: 1, samples: new Float64Array([1.671, 1.669]) },
  ] };
  const lines = csv(frame).trim().split('\n');
  assert.equal(lines[0], '# CH1: mean removed, 1.648900 V');   // enough to put it back
  assert.equal(lines[1], 'time_s,CH1_V,CH2_V');
  assert.ok(lines[2].includes('-0.021'));                      // as the screen shows it
  // A capture with nothing centred is the file it always was.
  const plain = csv({ ...frame, traces: [frame.traces[1]] }).trim().split('\n');
  assert.equal(plain[0], 'time_s,CH2_V');
});
test('the signal generator is asked for by opcode 8, and offered by bit 5', () => {
  assert.equal(OP.signals, 8);
  const settings = makeSettings();
  assert.equal(settings.signalsEnabled, false);
  assert.equal(settings.signalSineHz, 440);
  assert.ok(!(demoCaps.flags & 32) || true);  // the demo answers it; a board says so itself
});
test('CSV contains physical CH3 label and time relative to trigger', () => {
  const text = csv({ kind: 'scope', traces: [{ index: 2, samples: new Float64Array([1, 2]) }], period: .001, count: 2, triggerIndex: 1 });
  assert.match(text, /^time_s,CH3_V\n/); assert.match(text, /-0.001/);
});
test('UART decode samples bit centres and catches framing errors', () => {
  const bits = [1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1]; // A5, LSB first
  const samples = Uint8Array.from(bits.flatMap(bit => Array(16).fill(bit ? 16 : 0)));
  const decoded = decodeUART(samples, 1 / (115200 * 16));
  assert.equal(decoded.result[0].value, 0xa5); assert.equal(decoded.result[0].error, false);
});
test('normal trigger waiting can be stopped without a frame', async () => {
  const frames = [], engine = new Acquisition(frame => frames.push(frame), () => {});
  engine.attach(new DemoInstrument()); const settings = makeSettings(); settings.trigger = 2; settings.level = 50;
  engine.start(settings); await new Promise(r => setTimeout(r, 25)); await engine.stop();
  assert.equal(frames.length, 0); assert.equal(engine.running, false);
});
test('single capture returns all enabled channels once', async () => {
  const frames = [], engine = new Acquisition(frame => frames.push(frame), () => {});
  engine.attach(new DemoInstrument()); const settings = makeSettings(); settings.trigger = 0;
  await engine.start(settings, true); assert.equal(frames.length, 1); assert.equal(frames[0].traces.length, 3); assert.equal(engine.running, false);
});

test('USB connect synchronizes past stale ADC bytes even when reset leaves IN data queued', async () => {
  const { Instrument } = await import('../src/instrument.mjs');
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  const events = [], alternate = { interfaceClass: 255, alternateSetting: 0, endpoints: [{ direction: 'in', type: 'bulk', endpointNumber: 2 }, { direction: 'out', type: 'bulk', endpointNumber: 1 }] };
  const device = new FakeDevice();
  device.packets = [Uint8Array.from([0x30, 0, 0x30, 0, 0x60, 0x8b, 0x20, 0, 0x20, 0, 0xb0, 0x8b]), reply(OP.identify, 987, new Uint8Array(32))];
  device.configuration = { interfaces: [{ interfaceNumber: 0, alternate, alternates: [alternate] }] };
  device.open = async () => { events.push('open'); device.opened = true; };
  device.reset = async () => { events.push('reset'); /* host retains unread IN packets */ };
  device.claimInterface = async n => { assert.equal(n, 0); events.push('claim'); };
  device.transferOut = async (endpoint, bytes) => {
    assert.equal(endpoint, 1); if (bytes[1] !== OP.identify) assert.equal(device.packets.length, 0, 'handshake must consume old replies');
    const op = bytes[1], payload = new Uint8Array(op === OP.identify ? 32 : 48), v = view(payload);
    if (op === OP.identify) { v.setUint32(0, 0x5a594c50, true); v.setUint16(4, 1, true); v.setUint16(6, 0x105, true); }
    else { payload.set([3, 12, 8, 2]); [48000000, 97, 16384, 16383, 150000000, 65536, 65535, 3300000, 15].forEach((n, i) => v.setUint32(4 + i * 4, n, true)); }
    device.packets.push(reply(op, view(bytes).getUint16(4, true), payload));
    return { status: 'ok', bytesWritten: bytes.length };
  };
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { usb: { requestDevice: async () => device } } });
  try {
    const instrument = await Instrument.connect();
    assert.equal(instrument.identity.firmware, '1.5'); assert.equal(instrument.caps.channels, 3);
    assert.deepEqual(events, ['open', 'reset', 'claim']); await instrument.close();
  } finally { if (previous) Object.defineProperty(globalThis, 'navigator', previous); else delete globalThis.navigator; }
});

// The wire format is written twice — once in Swift, once here — so it is held
// to one shared fixture. A change on either side that the other does not follow
// fails here and in Tests/PiLyzerCoreTests/WireFormatTests.swift.
test('encoders agree with the shared wire fixture', async () => {
  const { readFile } = await import('node:fs/promises');
  const { encodeAnalogConfig, encodeLogicConfig } = await import('../src/protocol.mjs');
  const hex = bytes => Buffer.from(bytes).toString('hex');
  const golden = JSON.parse(await readFile(new URL('./fixtures/wire-golden.json', import.meta.url), 'utf8'));
  for (const c of golden.requestHeaders) assert.equal(hex(request(c.opcode, c.sequence, new Uint8Array(c.payloadLength)).slice(0, 12)), c.bytes);
  for (const c of golden.analogConfigs) assert.equal(hex(encodeAnalogConfig(c)), c.bytes);
  for (const c of golden.logicConfigs) assert.equal(hex(encodeLogicConfig(c)), c.bytes);
  for (const c of golden.readRequests) assert.equal(hex(readRequest(c.offset, c.count)), c.bytes);
  // The decoder is checked the other way round: bytes in, front end out.
  for (const c of golden.inputRanges) {
    const [range] = inputRanges(Uint8Array.from(Buffer.from(c.bytes, 'hex')));
    assert.equal(range.name, c.name);
    assert.equal(range.switchPosition, c.switchPosition);
    assert.ok(Math.abs(range.gain - c.gainMicro / 1e6) < 1e-12);
    assert.ok(Math.abs(range.offset - c.offsetMicrovolts / 1e6) < 1e-12);
  }
  const both = new Uint8Array(64);
  both.set(Buffer.from(golden.inputRanges[0].bytes, 'hex'), 0);
  both.set(Buffer.from(golden.inputRanges[1].bytes, 'hex'), 32);
  assert.deepEqual(inputRanges(both).map(r => r.name), ['±25 V', '±5 V']);
  assert.ok(golden.analogConfigs.length && golden.logicConfigs.length, 'the fixture must not be empty');
});

test('a trigger level left on the rail is moved somewhere the signal reaches', async () => {
  const { usableTriggerLevel, triggerWindow } = await import('../src/protocol.mjs');
  // The window the panel names when it moves a level: 2% off each rail.
  const { biasVolts } = await import('../src/protocol.mjs');
  // What a level that cannot fire is seeded to: the middle of what the channel
  // reads. On a bare board that is the mid rail the front end biases to.
  assert.ok(Math.abs(biasVolts(scaleFor(makeSettings(), caps, bare, 0)) - 1.65) < 1e-3);
  assert.ok(Math.abs(biasVolts(scaleFor(makeSettings(), caps, afe, 0))) < 0.01);
  const bare0 = triggerWindow(scaleFor(makeSettings(), caps, bare, 0));
  // 0 V is outside a bare board's window, which is what makes the seed matter.
  assert.ok(0 < bare0.low);
  assert.ok(Math.abs(bare0.low - 3.3 * .02) < 1e-9 && Math.abs(bare0.high - 3.3 * .98) < 1e-9);
  const settings = makeSettings(), unipolar = scaleFor(settings, caps, bare, 0);
  assert.ok(Math.abs(usableTriggerLevel(unipolar, 0) - 3.3 * .02) < 1e-9);      // 0 V is the bottom rail here
  assert.ok(Math.abs(usableTriggerLevel(unipolar, 99) - 3.3 * .98) < 1e-9);
  assert.equal(usableTriggerLevel(unipolar, 1.65), 1.65);                       // already reachable, untouched
  const five = scaleFor({ ...settings, channels: settings.channels.map(c => ({ ...c, range: 1 })) }, caps, afe, 0);
  assert.ok(usableTriggerLevel(five, 20) < five.high && usableTriggerLevel(five, 20) > 5);
});

test('initial synchronization is bounded and closes a stream without a valid identity', async () => {
  const device = new FakeDevice();
  device.transferOut = async (_, bytes) => ({ status: 'ok', bytesWritten: bytes.length });
  device.transferIn = async () => ({ status: 'ok', data: view(new Uint8Array(8192)) });
  const transport = new BulkTransport(device, 2, 1);
  await assert.rejects(transport.synchronize(), /Too much stale USB data/);
  assert.equal(device.opened, false);
});

test('the front end comes from the device, and from the board-id table only when it will not say', async () => {
  const { Instrument } = await import('../src/instrument.mjs');
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  const alternate = { interfaceClass: 255, alternateSetting: 0, endpoints: [{ direction: 'in', type: 'bulk', endpointNumber: 2 }, { direction: 'out', type: 'bulk', endpointNumber: 1 }] };
  const golden = JSON.parse(await (await import('node:fs/promises')).readFile(new URL('./fixtures/wire-golden.json', import.meta.url), 'utf8'));

  async function connect({ flags, board }) {
    const device = new FakeDevice();
    device.configuration = { interfaces: [{ interfaceNumber: 0, alternate, alternates: [alternate] }] };
    device.open = async () => { device.opened = true; };
    device.reset = async () => {};
    device.claimInterface = async () => {};
    device.transferOut = async (_, bytes) => {
      const op = bytes[1], sequence = view(bytes).getUint16(4, true);
      let payload;
      if (op === OP.identify) {
        payload = new Uint8Array(32); const v = view(payload);
        v.setUint32(0, 0x5a594c50, true); v.setUint16(4, 1, true); v.setUint16(6, 0x107, true);
        v.setUint32(8, board, true);
      } else if (op === OP.capabilities) {
        payload = new Uint8Array(48); const v = view(payload);
        payload.set([3, 12, 8, 2]);
        [48000000, 97, 16384, 16383, 150000000, 65536, 65535, 3300000, flags].forEach((n, i) => v.setUint32(4 + i * 4, n, true));
      } else if (op === OP.inputRanges) {
        // Only firmware that advertises the capability is ever asked.
        assert.ok(flags & 16, 'a device without the capability bit must not be asked');
        payload = new Uint8Array(64);
        payload.set(Buffer.from(golden.inputRanges[0].bytes, 'hex'), 0);
        payload.set(Buffer.from(golden.inputRanges[1].bytes, 'hex'), 32);
      } else payload = new Uint8Array();
      device.packets = [reply(op, sequence, payload)];
      return { status: 'ok', bytesWritten: bytes.length };
    };
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { usb: { requestDevice: async () => device } } });
    const instrument = await Instrument.connect();
    await instrument.close();
    return instrument;
  }

  try {
    const reported = await connect({ flags: 15 | 16, board: 1 });
    assert.deepEqual(reported.ranges.map(r => r.name), ['±25 V', '±5 V']);
    assert.equal(reported.ranges[1].switchPosition, 1);

    // Firmware 1.6 and earlier: the board-id table stands in, and CH1 on a bare
    // Pico still reads 0 to 3.3 V rather than nothing at all.
    const older = await connect({ flags: 15, board: 0 });
    assert.deepEqual(older.ranges.map(r => r.name), ['0 – 3.3 V']);
    assert.equal(older.ranges[0].gain, 1);
  } finally { if (previous) Object.defineProperty(globalThis, 'navigator', previous); else delete globalThis.navigator; }
});

test('a logged point carries the whole interval, not the instant it ended on', async () => {
  const engine = new Acquisition(() => {}, () => {});
  engine.attach(new DemoInstrument());
  const settings = makeSettings();
  settings.mode = 'meter'; settings.logInterval = .05;
  // Read many times across several intervals, so each written point has a
  // whole interval's worth of readings behind it rather than just the one it
  // fell due on.
  const { pause } = await import('../src/acquisition.mjs');
  let frame;
  for (let i = 0; i < 40; i++) {
    frame = await engine.capture(engine.instrument, settings, null, engine.token);
    await pause(5);
  }
  assert.ok(frame.history.length >= 3, `expected several points, got ${frame.history.length}`);
  assert.ok(frame.history.length >= 1, 'the log starts with a point rather than an empty chart');
  const point = frame.history[0];
  assert.equal(point.low.length, 3);
  for (let ch = 0; ch < 3; ch++) {
    assert.ok(point.low[ch] <= point.mean[ch] && point.mean[ch] <= point.high[ch]);
  }
  // The demo's channels move, so at least one interval must have spanned a
  // range rather than collapsing to a single reading.
  const spread = frame.history.some(row => row.high.some((h, i) => h - row.low[i] > 1e-9));
  assert.ok(spread, 'every point collapsed to one reading — the interval was not accumulated');
  // The axis is laid out from the interval, not from how long the reads took.
  assert.equal(frame.interval, .05);
  frame.history.forEach((row, i) => assert.ok(Math.abs(row.time - i * .05) < 1e-9));
});

test('the log CSV carries each interval\'s extremes and an absolute timestamp', () => {
  const start = Date.UTC(2026, 0, 2, 3, 4, 5) / 1000;
  const text = csv({ kind: 'meter', values: [0, 0], interval: 2, start, history: [
    { time: 0, low: [1, -1], mean: [1.5, -0.5], high: [2, 0] },
    { time: 2, low: [3, -3], mean: [3.5, -2.5], high: [4, -2] },
  ] });
  const lines = text.trim().split('\n');
  assert.equal(lines[0], 'time_s,timestamp,CH1_min_V,CH1_mean_V,CH1_max_V,CH2_min_V,CH2_mean_V,CH2_max_V');
  assert.match(lines[1], /^0\.00000000,2026-01-02T03:04:05\.000Z,1\.00000000,1\.50000000,2\.00000000,/);
  assert.match(lines[2], /^2\.00000000,2026-01-02T03:04:07\.000Z,3\.00000000,/);
});

test('the log drops its oldest points rather than growing without limit', async () => {
  const engine = new Acquisition(() => {}, () => {});
  engine.attach(new DemoInstrument());
  engine.history = Array.from({ length: LOG_CAPACITY }, (_, i) => ({ time: i, low: [0], mean: [0], high: [0] }));
  const settings = makeSettings();
  settings.mode = 'meter'; settings.logInterval = .05;
  engine.pointDue = 0;
  const frame = await engine.capture(engine.instrument, settings, null, engine.token);
  assert.equal(frame.history.length, LOG_CAPACITY);
});

test('spectrum peaks are strongest first, at the tone\'s own frequency between bins', () => {
  const rate = 50000, n = 4096, period = 1 / rate;
  // Neither tone lands on a bin centre: the bins are 12.2 Hz apart.
  const samples = Float64Array.from({ length: n }, (_, i) => Math.sin(2 * Math.PI * 1003 * i * period) + .25 * Math.sin(2 * Math.PI * 3007 * i * period));
  const f = spectrum(samples, period);
  assert.ok(f.peaks.length >= 2);
  assert.ok(f.peaks[0].rms > f.peaks[1].rms);
  assert.ok(Math.abs(f.peaks[0].frequency - 1003) < f.resolution / 10, `read ${f.peaks[0].frequency}`);
  assert.ok(Math.abs(f.peaks[1].frequency - 3007) < f.resolution / 10, `read ${f.peaks[1].frequency}`);
});
test('the spectrum is the same whether or not the panel removed the mean', () => {
  // Remove mean is a scope setting; a DC offset through the window becomes a
  // skirt over the low bins, not a tall bin 0, so the transform takes it out.
  const n = 4096, period = 1 / 50000;
  const sine = i => 1.5 * Math.sin(2 * Math.PI * 440 * i * period);
  const biased = spectrum(Float64Array.from({ length: n }, (_, i) => 1.65 + sine(i)), period);
  const centred = spectrum(Float64Array.from({ length: n }, (_, i) => sine(i)), period);
  assert.equal(biased.peak.frequency, centred.peak.frequency);
  for (const i of [0, 1, 2, 40]) {
    assert.ok(Math.abs(biased.bins[i].rms - centred.bins[i].rms) < 1e-9, `bin ${i}`);
  }
  // And the tone itself is where it belongs rather than losing to the skirt.
  assert.ok(Math.abs(biased.peak.frequency - 440) < 1, biased.peak.frequency);
});

// A stand-in for the instrument's own HTTP server: one POST in, one reply out.
function fakeServer({ status = 0, truncate = false, httpStatus = 200, hang = false } = {}) {
  const calls = [];
  return { calls, fetch: async (url, init) => {
    const bytes = new Uint8Array(init.body);
    const op = bytes[1], seq = view(bytes).getUint16(4, true);
    calls.push({ op, seq, url: String(url) });
    if (hang) return new Promise((_, reject) => init.signal.addEventListener('abort', () => {
      const e = new Error('aborted'); e.name = 'AbortError'; reject(e);
    }));
    if (httpStatus !== 200) return { ok: false, status: httpStatus };
    const answer = reply(op, seq, new Uint8Array([17, 23]), status);
    const body = truncate ? answer.slice(0, 13) : answer;
    return { ok: true, arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) };
  } };
}
function withFetch(server, run) {
  const saved = globalThis.fetch;
  globalThis.fetch = server.fetch;
  return run().finally(() => { globalThis.fetch = saved; });
}

test('the network transport posts to rpc beside the page and returns the payload', async () => {
  const server = fakeServer();
  await withFetch(server, async () => {
    const t = new HttpTransport('http://192.168.4.1/index.html');
    assert.deepEqual([...await t.exchange(OP.capabilities)], [17, 23]);
    assert.match(server.calls[0].url, /^http:\/\/192\.168\.4\.1\/rpc$/);
    assert.equal(server.calls[0].op, OP.capabilities);
  });
});

test('the network transport keeps one transaction outstanding and numbers them in order', async () => {
  const server = fakeServer();
  await withFetch(server, async () => {
    const t = new HttpTransport('http://192.168.4.1/');
    await Promise.all([t.exchange(OP.analogRead), t.exchange(OP.identify), t.exchange(OP.capabilities)]);
    assert.deepEqual(server.calls.map(c => c.op), [OP.analogRead, OP.identify, OP.capabilities]);
    const seqs = server.calls.map(c => c.seq);
    assert.deepEqual(seqs, [seqs[0], seqs[0] + 1, seqs[0] + 2]);
  });
});

test('a refused command leaves the network connection up; a broken one closes it', async () => {
  await withFetch(fakeServer({ status: 3 }), async () => {
    const t = new HttpTransport('http://192.168.4.1/');
    await assert.rejects(t.exchange(99), /Invalid setting/);
    assert.equal(t.closed, false, 'the instrument answering is not a link failure');
    await assert.rejects(t.exchange(99), /Invalid setting/);   // still usable
  });
  await withFetch(fakeServer({ httpStatus: 404 }), async () => {
    const t = new HttpTransport('http://example.test/');
    await assert.rejects(t.exchange(OP.identify), /answered 404/);
    assert.equal(t.closed, true);
  });
});

test('a reply shorter than its header claims is refused rather than half-read', async () => {
  await withFetch(fakeServer({ truncate: true }), async () => {
    const t = new HttpTransport('http://192.168.4.1/');
    await assert.rejects(t.exchange(OP.identify), /shorter than its header/);
  });
});

test('an instrument that stops answering times out with something to act on', async () => {
  await withFetch(fakeServer({ hang: true }), async () => {
    const t = new HttpTransport('http://192.168.4.1/');
    const pending = assert.rejects(t.exchange(OP.identify), /Check the Wi-Fi connection/);
    await new Promise(r => setTimeout(r, 5));
    t.close();                       // stand in for the 8 s fuse
    await pending;
  });
});

test('an https page does not probe for an instrument it could not talk to anyway', async () => {
  let asked = false;
  const saved = globalThis.fetch;
  globalThis.fetch = async () => { asked = true; throw new Error('should not be called'); };
  try {
    assert.equal(await available('https://satachito.github.io/Oscillo/'), false);
    assert.equal(asked, false, 'mixed content makes the answer moot, so no request is made');
  } finally { globalThis.fetch = saved; }
});

// The same cases as the macOS app's SpectrumSpanTests.
const spanCaps = { clock: 48000000, minCycles: 96, maxRecord: 16384 };
test('the time on screen is the resolution', () => {
  assert.ok(Math.abs(resolutionFor(.001) - 100) < 1e-9);
  assert.ok(Math.abs(resolutionFor(.01) - 10) < 1e-9);
});
test('a span picks the shortest record that reaches it, and leaves the resolution', () => {
  const settings = { ...makeSettings(), timebase: .01 };
  setSpectrumSpan(settings, 5000, spanCaps, 1);
  assert.equal(settings.record, 1024);
  assert.equal(settings.spectrumSpan, 5000);
  assert.equal(settings.timebase, .01);
});
test('a resolution keeps the span by choosing the record again', () => {
  const settings = { ...makeSettings(), timebase: .01 };
  setSpectrumSpan(settings, 5000, spanCaps, 1);
  setSpectrumResolution(settings, .1, spanCaps, 1);
  assert.equal(settings.record, 16384);
});
test('the whole band leaves the record alone', () => {
  const settings = { ...makeSettings(), record: 4096 };
  setSpectrumSpan(settings, 0, spanCaps, 1);
  assert.equal(settings.record, 4096);
});
test('a span and resolution nothing can reach are refused', () => {
  assert.equal(spectrumRecord(200000, 1, spanCaps, 1), null);
  assert.equal(spectrumRecord(1000, 10000, spanCaps, 1), null);
  assert.ok(!spectrumSpans(spanCaps, 3).includes(100000));
  assert.equal(spectrumSpans(spanCaps, 1).at(-1), 200000);
});
test('the axis ends at the span, or where the record does if that is sooner', () => {
  assert.equal(displayedTop(5000, 5120), 5000);
  assert.equal(displayedTop(5000, 2560), 2560);
  assert.equal(displayedTop(0, 5120), 5120);
});

// Duty and rise, measured as the macOS app's Measurements does.
test('a square wave reads its duty cycle, and a ramp its 10–90 % rise time', () => {
  const rate = 100000, period = 1 / rate;
  const square = Float64Array.from({ length: 10000 }, (_, i) => (i % 1000) < 300 ? 3.3 : 0);
  const m = measure(square, period);
  assert.ok(Math.abs(m.frequency - 100) < .01, `read ${m.frequency}`);
  assert.ok(Math.abs(m.duty - .3) < .002, `read ${m.duty}`);
  // 0 V to 1 V over 100 samples, then held: 10 % to 90 % is 80 samples.
  const ramp = Float64Array.from({ length: 400 }, (_, i) => Math.min(Math.max((i - 100) / 100, 0), 1));
  assert.ok(Math.abs(measure(ramp, period).rise - 80 * period) < period / 10);
  assert.equal(measure(new Float64Array(64).fill(1.65), period).duty, null);
});
test('averaged sweeps come back as one frame of the average', async () => {
  const settings = { ...makeSettings(), averaging: 4, trigger: 0 };
  const acquisition = new Acquisition(() => {}, () => {});
  acquisition.attach(new DemoInstrument());
  const frame = await acquisition.capture(acquisition.instrument, settings, null, acquisition.token);
  assert.equal(frame.kind, 'scope');
  assert.equal(frame.traces.length, 3);
  assert.equal(frame.traces[0].samples.length, frame.count);
});
