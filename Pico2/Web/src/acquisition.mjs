import { OP, activeChannels, analogRequest, logicRequest, plan, status, readRequest, splitAnalog, scaleFor, view, demoCaps } from './protocol.mjs';
import { measure } from './signal.mjs';
export const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
export const makeSettings = () => ({ mode: 'scope', timebase: .001, record: 2048, source: 0, trigger: 1, slope: 0, level: 0, position: .15, hysteresis: .004, lpf: 0, channels: Array.from({ length: 3 }, () => ({ enabled: true, range: 0, probe: 1, scale: 0, offset: 0, ac: false, zero: [0, 0] })), testEnabled: true, testFrequency: 1000, logicRate: 1000000, logicRecord: 4096, logicSource: 0, logicEnabled: 255, uart: false, uartLine: 4, uartBaud: 115200, xy: false });
const tone = (channel, t) => channel === 0 ? 2 * Math.sin(2 * Math.PI * 1000 * t) + .02 * Math.sin(2 * Math.PI * 3000 * t) : channel === 1 ? (Math.sin(2 * Math.PI * 500 * t) >= 0 ? 1 : -1) + .25 : 1.5 * Math.sin(2 * Math.PI * 194 * t);
export class DemoInstrument {
  constructor() { this.demo = true; this.identity = { name: 'Demo signal', board: 1, firmware: '1.5' }; this.caps = demoCaps; }
  async abort() {} async close() {} async setRange() {} async setTest(on, hz) { return hz; }
}
function columnsToFrame(columns, request, settings, instrument, actual, triggered, triggerIndex) {
  const traces = request.active.map((index, slot) => {
    const scale = scaleFor(settings, instrument.caps, instrument.identity.board, index);
    const raw = columns[slot], volts = Float64Array.from(raw, scale.volts);
    const stats = measure(volts, actual.period), mean = settings.channels[index].ac ? stats.mean : 0;
    return { index, samples: Float64Array.from(volts, v => v - mean), removedMean: mean, stats, clipped: raw.some(v => v === 0 || v >= instrument.caps.fullScale) };
  });
  return { kind: 'scope', traces, period: actual.period, count: actual.count, triggerIndex, triggered, decimation: actual.decimation, timestamp: Date.now() };
}
function demoAnalog(instrument, settings) {
  const req = analogRequest(settings, instrument.caps, instrument.identity.board), { period, count, pretrigger } = req;
  let start = performance.now() / 1000, triggered = settings.trigger !== 0;
  const alpha = settings.lpf ? 1 - Math.exp(-2 * Math.PI * settings.lpf * period) : 1;
  const settle = settings.lpf ? Math.ceil(5 / (2 * Math.PI * settings.lpf * period)) : 0;
  let filtered = tone(req.source, start), armed = false, edge = -1;
  if (triggered) {
    const margin = settings.hysteresis * scaleFor(settings, instrument.caps, 1, req.source).span;
    for (let i = 0; i < settle + Math.max(count * 3, Math.ceil(.025 / period)); i++) {
      const x = tone(req.source, start + i * period); filtered += alpha * (x - filtered);
      if (i < settle || i < pretrigger) continue;
      if (!armed) armed = settings.slope ? filtered > settings.level + margin : filtered < settings.level - margin;
      else if (settings.slope ? filtered <= settings.level : filtered >= settings.level) { edge = i; break; }
    }
    triggered = edge >= 0;
    if (!triggered && settings.trigger === 2) return null;
    if (triggered) start += (edge - pretrigger) * period;
  }
  const columns = req.active.map(c => {
    const r = scaleFor(settings, instrument.caps, 1, c).r;
    return Float64Array.from({ length: count }, (_, i) => Math.max(0, Math.min(4095, Math.round((tone(c, start + i * period) * r.gain + r.offset) / instrument.caps.reference * 4095))) * 16);
  });
  return columnsToFrame(columns, req, settings, instrument, { period, count, decimation: Math.max(1, Math.floor(period / (instrument.caps.minCycles / instrument.caps.clock * req.active.length))) }, triggered, pretrigger);
}
function demoLogic(settings, caps) {
  const period = Math.max(1 / settings.logicRate, 1 / caps.logicClock), count = Math.min(settings.logicRecord, caps.logicMaxRecord), pretrigger = Math.floor(count * settings.position);
  const samples = Uint8Array.from({ length: count }, (_, i) => {
    const t = i * period; let value = 0;
    for (let b = 0; b < 4; b++) if ((t * 100000 / 2 ** b) % 1 < .5) value |= 1 << b;
    const bits = Math.floor(t * 115200), frame = bits % 10, char = 'PiLyzer '.charCodeAt(Math.floor(bits / 10) % 8);
    if (frame === 9 || (frame > 0 && char & (1 << (frame - 1)))) value |= 16;
    const spi = t % .0001, bit = Math.floor(spi * 1e6);
    if (bit >= 8) value |= 128;
    else { if (spi * 1e6 % 1 >= .5) value |= 32; if (0xa5 & (1 << (7 - bit))) value |= 64; }
    return value;
  });
  return { kind: 'logic', samples, period, count, triggerIndex: pretrigger, triggered: settings.trigger !== 0, timestamp: Date.now() };
}
// Generation tokens cancel polling; transactions remain serialized by the transport.
export class Acquisition {
  constructor(onFrame, onState) { this.onFrame = onFrame; this.onState = onState; this.token = 0; this.running = false; this.pending = Promise.resolve(); this.history = []; }
  attach(instrument) { this.instrument = instrument; this.history = []; }
  async stop() {
    this.running = false; this.token++;
    await this.pending.catch(() => {});
    if (this.instrument) await this.instrument.abort();
    this.onState('Stopped');
  }
  start(settings, single = false) {
    this.running = true;
    const token = ++this.token;
    this.pending = this.pending.catch(() => {}).then(() => this.loop(structuredClone(settings), single, token));
    return this.pending;
  }
  configure(settings) {
    const instrument = this.instrument, snapshot = structuredClone(settings);
    this.pending = this.pending.catch(() => {}).then(async () => {
      if (!instrument || instrument !== this.instrument) return;
      await instrument.abort();
      for (let c = 0; c < instrument.caps.channels; c++) await instrument.setRange(c, instrument.identity.board === 0 ? 0 : snapshot.channels[c].range);
      if (instrument.caps.flags & 2) await instrument.setTest(snapshot.testEnabled, snapshot.testFrequency);
    });
    return this.pending;
  }
  async loop(settings, single, token) {
    const instrument = this.instrument;
    if (!instrument || token !== this.token) return;
    try {
      await instrument.abort();
      for (let c = 0; c < instrument.caps.channels; c++) await instrument.setRange(c, instrument.identity.board === 0 ? 0 : settings.channels[c].range);
      if (instrument.caps.flags & 2) await instrument.setTest(settings.testEnabled, settings.testFrequency);
      let prepared;
      if (!instrument.demo && settings.mode !== 'meter') {
        prepared = settings.mode === 'logic'
          ? plan(await instrument.command(OP.logicConfigure, logicRequest(settings, instrument.caps)))
          : plan(await instrument.command(OP.analogConfigure, analogRequest(settings, instrument.caps, instrument.identity.board).payload));
      }
      while (token === this.token) {
        const before = performance.now();
        this.onState(settings.trigger === 2 && settings.mode !== 'meter' ? 'Waiting for trigger' : 'Acquiring');
        const frame = await this.capture(instrument, settings, prepared, token);
        if (token !== this.token) return;
        if (frame) { this.onFrame(frame); this.onState(frame.kind === 'meter' ? 'Meter' : frame.triggered ? 'Triggered' : 'Free running'); if (single) { this.running = false; this.onState('Single capture'); return; } }
        await pause(Math.max(10, (settings.mode === 'meter' ? 100 : 80) - (performance.now() - before)));
      }
    } catch (error) {
      if (token === this.token) { this.running = false; this.onState(error.message, true); }
    }
  }
  async capture(instrument, settings, actual, token) {
    if (settings.mode === 'meter') {
      let values;
      if (instrument.demo) values = Array.from({ length: instrument.caps.channels }, (_, c) => (tone(c, performance.now() / 1000) - settings.channels[c].zero[settings.channels[c].range]) * settings.channels[c].probe);
      else {
        const bytes = await instrument.command(OP.sample, new Uint8Array([64, 0]));
        if (bytes.length !== instrument.caps.channels * 2) throw new Error('Incomplete meter reading');
        values = Array.from({ length: instrument.caps.channels }, (_, c) => scaleFor(settings, instrument.caps, instrument.identity.board, c).volts(view(bytes).getUint16(c * 2, true)));
      }
      this.history.push({ time: Date.now() / 1000, values }); if (this.history.length > 1000) this.history.shift();
      return { kind: 'meter', values, history: this.history.slice(), timestamp: Date.now() };
    }
    if (instrument.demo) return settings.mode === 'logic' ? demoLogic(settings, instrument.caps) : demoAnalog(instrument, settings);
    const logic = settings.mode === 'logic', arm = logic ? OP.logicArm : OP.analogArm, poll = logic ? OP.logicStatus : OP.analogStatus;
    await instrument.command(arm);
    let result, deadline = performance.now() + actual.period * actual.count * 1000 + 3000;
    while (token === this.token) {
      result = status(await instrument.command(poll));
      if (result.state === 4) break;
      if (result.state === 6) throw new Error('Capture overrun. Use fewer channels or a slower timebase.');
      if (result.state === 5) return null;
      if (settings.trigger !== 2 && performance.now() > deadline) throw new Error('The acquisition did not complete. Stop and reconnect.');
      await pause(10);
    }
    if (token !== this.token) return null;
    const bytesPerSample = logic ? 1 : actual.channels * 2, bytes = new Uint8Array(actual.count * bytesPerSample);
    let offset = 0;
    while (offset < actual.count && token === this.token) {
      const count = Math.min(Math.floor(8192 / bytesPerSample), actual.count - offset);
      const block = await instrument.command(logic ? OP.logicRead : OP.analogRead, readRequest(offset, count));
      if (!block.length || block.length % bytesPerSample || block.length > count * bytesPerSample) throw new Error('Invalid sample block');
      bytes.set(block, offset * bytesPerSample); offset += block.length / bytesPerSample;
    }
    if (token !== this.token) return null;
    if (logic) return { kind: 'logic', samples: bytes, period: actual.period, count: actual.count, triggerIndex: result.triggerIndex, triggered: result.triggered, timestamp: Date.now() };
    const request = analogRequest(settings, instrument.caps, instrument.identity.board);
    if (actual.mask !== request.mask || actual.channels !== request.active.length) throw new Error('The instrument returned an unexpected channel mask');
    return columnsToFrame(splitAnalog(bytes, actual.channels), request, settings, instrument, actual, result.triggered, result.triggerIndex);
  }
}
