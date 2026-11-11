import test from 'node:test';
import assert from 'node:assert/strict';
import { analogRequest, minimumPeriod, scaleFor, demoCaps } from '../src/protocol.mjs';
import { makeSettings } from '../src/acquisition.mjs';
import { SoundBuffer, SoundInstrument, SOUND_RANGES, soundCaps, soundCode, soundPlan, scanTrigger, soundColumns, soundLevels } from '../src/sound.mjs';

const rate = 48000;
const caps = soundCaps(2, rate);
// A buffer holding `seconds` of a sine on channel 0 and a quieter one on 1.
function filled(seconds, frequency = 1000, amplitude = .5, capacity = 1 << 16) {
  const buffer = new SoundBuffer(2, capacity), n = Math.round(seconds * rate);
  for (let at = 0; at < n; at += 1000) {
    const length = Math.min(1000, n - at);
    buffer.push([0, 1].map(c => Float32Array.from({ length }, (_, i) => (c ? .1 : amplitude) * Math.sin(2 * Math.PI * frequency * (at + i) / rate))));
  }
  return buffer;
}
function sound(settings = makeSettings()) {
  settings.channels.forEach(ch => { ch.range = 0; ch.scale = 0; });
  settings.level = 0;
  return settings;
}

test('a sound card is sampled all at once, however many inputs are on', () => {
  assert.equal(minimumPeriod(caps, 1), 1 / rate);
  assert.equal(minimumPeriod(caps, 2), 1 / rate);
  assert.ok(Math.abs(minimumPeriod(demoCaps, 3) - 3 * 97 / 48e6) < 1e-15);
  const settings = sound(); settings.timebase = 1e-5;
  assert.ok(Math.abs(analogRequest(settings, caps, SOUND_RANGES).period - 1 / rate) < 1e-12);
});

test('±1 full scale reads as ±1 through the ordinary scaling', () => {
  const scale = scaleFor(sound(), caps, SOUND_RANGES, 0);
  assert.ok(Math.abs(scale.volts(soundCode(1)) - 1) < 1e-4);
  assert.ok(Math.abs(scale.volts(soundCode(-1)) + 1) < 1e-4);
  assert.ok(Math.abs(scale.volts(soundCode(0))) < 1e-4);
  assert.equal(soundCode(2), 65520); assert.equal(soundCode(-2), 0);
});

test('the ring keeps frame numbers across the wrap', () => {
  const buffer = new SoundBuffer(1, 8);
  buffer.push([Float32Array.from([0, 1, 2, 3, 4, 5])]);
  buffer.push([Float32Array.from([6, 7, 8, 9, 10])]);
  assert.equal(buffer.written, 11); assert.equal(buffer.oldest, 3);
  assert.equal(buffer.at(0, 3), 3); assert.equal(buffer.at(0, 10), 10);
  assert.equal(buffer.mean(0, 4, 4), 5.5);
});

test('a slow sweep takes whole frames and averages them', () => {
  const buffer = filled(.1), settings = sound();
  settings.timebase = .01; settings.record = 2048;     // 100 ms over 2048 points
  const plan = soundPlan(buffer, settings, caps, SOUND_RANGES);
  assert.equal(plan.decimation, 2);
  assert.equal(plan.period, 2 / rate);
});

test('the trigger lands on a rising crossing, and a sweep starts on it', () => {
  const buffer = filled(.05), settings = sound();
  settings.timebase = 2e-4; settings.record = 512; settings.position = .25; settings.trigger = 1; settings.slope = 0;
  const plan = soundPlan(buffer, settings, caps, SOUND_RANGES);
  const state = { next: 0, armed: false, edge: -1 };
  const edge = scanTrigger(buffer, state, settings, caps, SOUND_RANGES, plan);
  assert.ok(edge >= 0);
  // A 1 kHz sine at 48 kHz crosses zero rising every 48 frames.
  assert.ok(edge % 48 <= 1 || edge % 48 >= 47, `edge at ${edge}`);
  const sweep = soundColumns(buffer, settings, caps, plan, edge - plan.pretrigger * plan.decimation, true);
  assert.equal(sweep.columns.length, 2); assert.equal(sweep.columns[0].length, plan.count);
  assert.ok(sweep.triggered); assert.equal(sweep.triggerIndex, plan.pretrigger);
  const at = sweep.columns[0][plan.pretrigger];
  assert.ok(Math.abs(at - 32760) < 65520 * .02, `the trigger point reads ${at}`);
  // The state carries on: nothing new has come, so a second look finds the same edge.
  assert.equal(scanTrigger(buffer, state, settings, caps, SOUND_RANGES, plan), edge);
});

test('a level the signal never reaches finds no edge', () => {
  const buffer = filled(.05), settings = sound();
  settings.trigger = 2; settings.level = .8; settings.timebase = 2e-4; settings.record = 512;
  const plan = soundPlan(buffer, settings, caps, SOUND_RANGES);
  assert.equal(scanTrigger(buffer, { next: 0, armed: false, edge: -1 }, settings, caps, SOUND_RANGES, plan), -1);
});

test('the meter shows the RMS of each input', () => {
  const levels = soundLevels(filled(.2), sound(), caps, SOUND_RANGES);
  assert.ok(Math.abs(levels[0] - .5 / Math.SQRT2) < .002, `CH1 ${levels[0]}`);
  assert.ok(Math.abs(levels[1] - .1 / Math.SQRT2) < .002, `CH2 ${levels[1]}`);
});

test('the meter reads zero before any audio has arrived', () => {
  assert.deepEqual(soundLevels(new SoundBuffer(2), sound(), caps, SOUND_RANGES), [0, 0]);
});

test('a sound input is only offered where the browser will give one', () => {
  assert.equal(SoundInstrument.available(), false);   // Node has no microphone
});
