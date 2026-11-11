import { MAX_ANALOG_CHANNELS, analogRequest, scaleFor } from './protocol.mjs';
import { pause } from './acquisition.mjs';
// The computer's own sound input as an instrument: the built-in microphone, or
// better the line input of an audio interface. It is read in the browser and
// never leaves it.
//
// It is not a PiLyzer and does not pretend to be one on the wire. It answers
// the same questions the acquisition asks of a board — what it has, and one
// sweep at a time — out of a buffer the audio thread keeps filling, and finds
// the trigger in software as the demo does.
//
// What it reads is the sound card's own scale: ±1 is full scale, and there is
// no direct current. A channel's gain calibration turns that into volts against
// a known signal, the same as any other front end.
export const SOUND_RANGES = Object.freeze([Object.freeze({ name: '±1 full scale', gain: 1, offset: 1, switchPosition: 0 })]);
export function soundCaps(channels, rate) {
  // Reference 2 V and offset 1 V put −1…+1 across the converter codes, so the
  // rest of the application scales it like any front end. `simultaneous`:
  // every input is its own converter, so switching more on does not slow one.
  return Object.freeze({ channels, bits: 16, logicChannels: 0, ranges: 1, clock: rate, minCycles: 1, simultaneous: true, maxRecord: 65536, maxPretrigger: 65535, logicClock: 0, logicMaxRecord: 0, logicMaxPretrigger: 0, reference: 2, flags: 0, fullScale: 65520 });
}
export const soundCode = x => Math.max(0, Math.min(65520, Math.round((x + 1) / 2 * 65520)));
// The last stretch of every channel, as the audio thread delivered it. Frames
// are counted from the start, so a position stays the same frame however far
// the ring has wrapped since.
export class SoundBuffer {
  constructor(channels, capacity = 1 << 20) {
    this.channels = channels; this.capacity = capacity; this.written = 0;
    this.data = Array.from({ length: channels }, () => new Float32Array(capacity));
  }
  push(blocks) {
    const length = blocks[0]?.length || 0;
    for (let c = 0; c < this.channels; c++) {
      const block = blocks[c] || blocks[0], into = this.data[c];
      for (let i = 0; i < length; i++) into[(this.written + i) % this.capacity] = block[i];
    }
    this.written += length;
  }
  get oldest() { return Math.max(0, this.written - this.capacity); }
  at(channel, frame) { return this.data[channel][frame % this.capacity]; }
  // `decimation` frames from `frame` on, averaged: the anti-alias filter for a
  // slow sweep, as the board averages the conversions underneath each point.
  mean(channel, frame, decimation) {
    let sum = 0;
    for (let j = 0; j < decimation; j++) sum += this.at(channel, frame + j);
    return sum / decimation;
  }
}
// What a sweep asks of the buffer: the interval, a whole number of frames, and
// how many points either side of the trigger.
export function soundPlan(buffer, settings, caps, frontEnd) {
  const req = analogRequest(settings, caps, frontEnd);
  const decimation = Math.max(1, Math.round(req.period * caps.clock));
  // A sweep longer than half the ring would be overwritten while it is read.
  const count = Math.max(2, Math.min(req.count, Math.floor(buffer.capacity / 2 / decimation)));
  const pretrigger = Math.min(req.pretrigger, count - 1);
  return { req, decimation, count, pretrigger, period: decimation / caps.clock };
}
// Looks for the trigger through whatever has arrived since the last look. The
// state carries over, so a long wait in Normal does not read the same audio
// again and again. `from` is the first frame an edge may be on: nothing older
// than the moment the sweep was asked for counts.
export function scanTrigger(buffer, state, settings, caps, frontEnd, plan) {
  const { req, decimation: d, count, pretrigger } = plan;
  const scale = scaleFor(settings, caps, frontEnd, req.source);
  const margin = settings.hysteresis * Math.abs(scale.span), level = settings.level;
  const after = (count - pretrigger) * d;
  const first = Math.max(state.next, buffer.oldest + pretrigger * d);
  let k = first;
  for (; k + after <= buffer.written; k += d) {
    const v = scale.volts(soundCode(buffer.mean(req.source, k, d)));
    if (!state.armed) state.armed = settings.slope ? v > level + margin : v < level - margin;
    else if (settings.slope ? v <= level : v >= level) { state.edge = k; state.armed = false; }
  }
  state.next = k;
  return state.edge;
}
// One sweep's raw columns in converter codes, starting at `start`, in the
// shape the acquisition averages and turns into a frame.
export function soundColumns(buffer, settings, caps, plan, start, triggered) {
  const { req, decimation: d, count, pretrigger, period } = plan;
  const columns = req.active.map(c => Float64Array.from({ length: count }, (_, i) => soundCode(buffer.mean(c, start + i * d, d))));
  return { columns, request: { ...req, count, pretrigger, period }, actual: { period, count, decimation: d, channels: req.active.length, mask: req.mask }, triggered, triggerIndex: triggered ? pretrigger : 0 };
}
// Each input's level for the meter: the RMS of the last tenth of a second.
// A sound card passes no direct current, so the mean the meter shows for a
// board would read zero here, whatever was playing.
export function soundLevels(buffer, settings, caps, frontEnd, seconds = .1) {
  const frames = Math.max(1, Math.min(buffer.written - buffer.oldest, Math.round(seconds * caps.clock)));
  return Array.from({ length: caps.channels }, (_, c) => {
    const scale = scaleFor(settings, caps, frontEnd, c);
    let sum = 0;
    for (let i = buffer.written - frames; i < buffer.written; i++) { const v = scale.volts(soundCode(buffer.at(c, i))); sum += v * v; }
    return Math.sqrt(sum / frames);
  });
}
// The audio thread's side: gather the 128-frame blocks into bigger ones, so
// the page hears from it a few dozen times a second rather than hundreds.
const TAP = `class Tap extends AudioWorkletProcessor {
  constructor() { super(); this.blocks = null; this.filled = 0; }
  process(inputs) {
    const input = inputs[0];
    if (!input || !input.length) return true;
    const length = input[0].length;
    if (!this.blocks || this.blocks.length !== input.length) { this.blocks = input.map(() => new Float32Array(2048)); this.filled = 0; }
    if (this.filled + length > 2048) { this.port.postMessage(this.blocks.map(b => b.slice(0, this.filled))); this.filled = 0; }
    input.forEach((channel, c) => this.blocks[c].set(channel, this.filled));
    this.filled += length;
    return true;
  }
}
registerProcessor('pilyzer-tap', Tap);`;
export class SoundInstrument {
  // The browser gives a page the microphone only over https or on this
  // computer, so the copy a board serves at http://pilyzer.local cannot offer it.
  static available() {
    return !!(globalThis.isSecureContext && globalThis.navigator?.mediaDevices?.getUserMedia && globalThis.AudioWorkletNode);
  }
  static async connect() {
    // The browser's voice processing would clean up exactly what is being
    // measured, so all of it is asked off.
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: { ideal: 2 } } });
    const track = stream.getAudioTracks()[0];
    const settings = track.getSettings();
    let context;
    try {
      context = new AudioContext(settings.sampleRate ? { sampleRate: settings.sampleRate } : {});
      const channels = Math.min(Math.max(settings.channelCount || 1, 1), MAX_ANALOG_CHANNELS);
      const url = URL.createObjectURL(new Blob([TAP], { type: 'text/javascript' }));
      let loaded = false;
      try { await Promise.race([context.audioWorklet.addModule(url).then(() => { loaded = true; }), pause(3000)]); } finally { URL.revokeObjectURL(url); }
      if (!loaded) throw new Error('The browser could not start its audio. Check the sound settings, then try again.');
      const source = context.createMediaStreamSource(stream);
      const tap = new AudioWorkletNode(context, 'pilyzer-tap', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: channels, channelCountMode: 'explicit', channelInterpretation: 'discrete' });
      // Through a silent gain to the output, so the audio graph pulls it.
      const silence = context.createGain(); silence.gain.value = 0;
      source.connect(tap); tap.connect(silence); silence.connect(context.destination);
      const instrument = new SoundInstrument(stream, context, track.label, channels, context.sampleRate);
      tap.port.onmessage = event => instrument.buffer.push(event.data);
      // A computer with no working audio device leaves the context suspended
      // and resume() waiting for good, which would leave Connect waiting too.
      await Promise.race([context.resume(), pause(3000)]);
      if (context.state !== 'running') throw new Error('The browser could not start its audio. Check the sound settings, then try again.');
      return instrument;
    } catch (error) {
      stream.getTracks().forEach(t => t.stop()); context?.close();
      throw error;
    }
  }
  constructor(stream, context, label, channels, rate) {
    this.sound = true; this.stream = stream; this.context = context;
    this.identity = { name: label || 'Sound input', board: -1, firmware: '' };
    this.rate = rate; this.caps = soundCaps(channels, rate); this.ranges = SOUND_RANGES;
    this.buffer = new SoundBuffer(channels);
  }
  async abort() {} async setRange() {} async setTest(on, hz) { return hz; } async setSignals() { return 0; }
  async close() { this.stream.getTracks().forEach(t => t.stop()); await this.context.close().catch(() => {}); }
  levels(settings) { return soundLevels(this.buffer, settings, this.caps, this.ranges); }
  // One sweep of audio that arrived after it was asked for. Free running takes
  // the newest whole record; Auto waits a tenth of a second past the record
  // for an edge and then takes the newest; Normal waits for as long as it takes.
  async sweep(settings, current) {
    const plan = soundPlan(this.buffer, settings, this.caps, this.ranges);
    const span = plan.count * plan.decimation, since = this.buffer.written;
    const state = { next: since, armed: false, edge: -1 }, patience = performance.now() + span / this.rate * 1000 + 100;
    while (current()) {
      if (settings.trigger !== 0) {
        const edge = scanTrigger(this.buffer, state, settings, this.caps, this.ranges, plan);
        if (edge >= 0) return soundColumns(this.buffer, settings, this.caps, plan, edge - plan.pretrigger * plan.decimation, true);
      }
      const fresh = this.buffer.written - span >= since;
      if (fresh && (settings.trigger === 0 || (settings.trigger === 1 && performance.now() > patience))) {
        return soundColumns(this.buffer, settings, this.caps, plan, this.buffer.written - span, false);
      }
      await pause(10);
    }
    return null;
  }
}