import { scaleFor, activeChannels } from './protocol.mjs';
import { fmt, spectrum } from './signal.mjs';
export const COLORS = ['#e9c96b', '#79cdd8', '#c0a1ef', '#9ed190', '#d8ad7f', '#a6bcec', '#d592b9', '#afbf7a'];
export class Plot {
  constructor(canvas) {
    this.canvas = canvas; this.context = canvas.getContext('2d');
    this.observer = new ResizeObserver(() => this.draw()); this.observer.observe(canvas);
  }
  update(frame, settings, caps, board) { this.frame = frame; this.settings = settings; this.caps = caps; this.board = board; this.spectrum = frame?.kind === 'scope' && settings.mode === 'spectrum' ? spectrum(frame.traces[0]?.samples || [], frame.period) : null; this.draw(); }
  draw() {
    const { canvas, context: c } = this, width = canvas.clientWidth, height = canvas.clientHeight;
    if (!width || !height) return;
    const dpr = Math.min(devicePixelRatio || 1, 2);
    canvas.width = width * dpr; canvas.height = height * dpr; c.scale(dpr, dpr);
    c.clearRect(0, 0, width, height);
    const box = { x: 44, y: 18, w: width - 65, h: height - 48 };
    if (this.frame?.kind === 'meter') { box.y = 88; box.h -= 70; }
    c.font = '9px ui-monospace, SFMono-Regular, monospace';
    c.strokeStyle = '#344238'; c.lineWidth = .6;
    for (let col = 0; col <= 10; col++) {
      const x = box.x + col / 10 * box.w; c.beginPath(); c.moveTo(x, box.y); c.lineTo(x, box.y + box.h); c.stroke();
    }
    for (let row = 0; row <= 8; row++) {
      const y = box.y + row / 8 * box.h; c.strokeStyle = row === 4 ? '#607160' : '#344238';
      c.beginPath(); c.moveTo(box.x, y); c.lineTo(box.x + box.w, y); c.stroke();
    }
    if (!this.frame || !this.settings) return;
    c.save(); c.beginPath(); c.rect(box.x, box.y, box.w, box.h); c.clip();
    if (this.frame.kind === 'logic') this.logic(c, box);
    else if (this.frame.kind === 'meter') this.meter(c, box);
    else if (this.settings.mode === 'spectrum') this.fft(c, box);
    else if (this.settings.xy && this.frame.traces.length >= 2) this.xy(c, box);
    else this.scope(c, box);
    c.restore(); this.axes(c, box);
  }
  mapping(index, box) {
    const settings = this.settings.channels[index], scale = scaleFor(this.settings, this.caps, this.board, index);
    const centre = settings.ac ? 0 : scale.centre;
    const perDiv = settings.scale || scale.span / 8;
    return { centre, perDiv, y: v => box.y + box.h / 2 - ((v - centre) / perDiv + settings.offset) * box.h / 8 };
  }
  trace(c, values, box, y, color) {
    c.strokeStyle = color; c.lineWidth = 1.25; c.beginPath();
    if (values.length > box.w * 2) {
      for (let pixel = 0; pixel < Math.floor(box.w); pixel++) {
        const from = Math.floor(pixel / box.w * values.length), to = Math.min(values.length, Math.ceil((pixel + 1) / box.w * values.length));
        let lo = Infinity, hi = -Infinity; for (let i = from; i < to; i++) { lo = Math.min(lo, values[i]); hi = Math.max(hi, values[i]); }
        c.moveTo(box.x + pixel, y(lo)); c.lineTo(box.x + pixel, y(hi));
      }
    } else for (let i = 0; i < values.length; i++) {
      const x = box.x + i / Math.max(values.length - 1, 1) * box.w;
      if (i) c.lineTo(x, y(values[i])); else c.moveTo(x, y(values[i]));
    }
    c.stroke();
  }
  scope(c, box) {
    for (const trace of this.frame.traces) this.trace(c, trace.samples, box, this.mapping(trace.index, box).y, COLORS[trace.index]);
    if (this.settings.trigger !== 0) {
      const x = box.x + this.frame.triggerIndex / Math.max(this.frame.count - 1, 1) * box.w;
      c.strokeStyle = '#a3cd87'; c.lineWidth = .8; c.setLineDash([3, 5]); c.beginPath(); c.moveTo(x, box.y); c.lineTo(x, box.y + box.h); c.stroke();
      const t = this.frame.traces.find(t => t.index === this.settings.source) || this.frame.traces[0];
      const y = this.mapping(t.index, box).y(this.settings.level - t.removedMean);
      c.beginPath(); c.moveTo(box.x, y); c.lineTo(box.x + box.w, y); c.stroke(); c.setLineDash([]);
    }
  }
  xy(c, box) {
    const [first, second] = this.frame.traces, xmap = this.mapping(first.index, box), ymap = this.mapping(second.index, box);
    c.strokeStyle = '#b8e89b'; c.lineWidth = 1; c.beginPath();
    for (let i = 0; i < first.samples.length; i++) {
      const x = box.x + box.w / 2 + ((first.samples[i] - xmap.centre) / xmap.perDiv + this.settings.channels[first.index].offset) / 10 * box.w, y = ymap.y(second.samples[i]);
      if (i) c.lineTo(x, y); else c.moveTo(x, y);
    }
    c.stroke();
  }
  fft(c, box) {
    const s = this.spectrum; if (!s?.bins.length) return;
    const max = Math.ceil(Math.max(0, ...s.bins.map(b => b.db)) / 20) * 20;
    this.fftMax = max;
    this.trace(c, s.bins.map(b => b.db), box, db => box.y + (max - db) / 120 * box.h, COLORS[this.frame.traces[0].index]);
    if (s.peak) {
      const x = box.x + s.peak.frequency * this.frame.period * 2 * box.w, y = box.y + (max - s.peak.db) / 120 * box.h;
      c.fillStyle = '#d5e6bf'; c.beginPath(); c.arc(x, y, 3, 0, 2 * Math.PI); c.fill();
    }
  }
  logic(c, box) {
    const active = Array.from({ length: 8 }, (_, i) => i).filter(i => this.settings.logicEnabled & (1 << i));
    for (const [slot, channel] of active.entries()) {
      const step = box.h / Math.max(active.length, 1), top = box.y + slot * step + step * .25;
      this.trace(c, Float64Array.from(this.frame.samples, v => (v >> channel) & 1), box, v => top + (1 - v) * step * .45, COLORS[channel]);
      c.fillStyle = COLORS[channel]; c.fillText(`D${channel}`, box.x + 5, top - 4);
    }
  }
  meter(c, box) {
    const all = this.frame.history.flatMap(r => r.values); if (!all.length) return;
    let low = Math.min(...all), high = Math.max(...all), span = Math.max(.1, high - low); low -= span * .1; high += span * .1;
    this.meterRange = { low, high };
    for (let i = 0; i < this.frame.values.length; i++) this.trace(c, this.frame.history.map(row => row.values[i]), box, v => box.y + (high - v) / (high - low) * box.h, COLORS[i]);
  }
  axes(c, box) {
    c.fillStyle = '#758c7b'; c.textAlign = 'right';
    const frame = this.frame;
    if (frame.kind === 'scope' && this.settings.mode !== 'spectrum') {
      const map = this.mapping(frame.traces[0].index, box), offset = this.settings.channels[frame.traces[0].index].offset;
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(map.centre + (4 - r - offset) * map.perDiv, 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    } else if (this.spectrum) {
      for (let r = 0; r <= 8; r += 2) c.fillText(`${(this.fftMax || 0) - r / 8 * 120}`, box.x - 7, box.y + r / 8 * box.h + 3);
      c.fillText('dBV', box.x - 7, box.y - 6);
    } else if (this.meterRange && frame.kind === 'meter') {
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(this.meterRange.high - r / 8 * (this.meterRange.high - this.meterRange.low), 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    }
    c.textAlign = 'center';
    for (let col = 0; col <= 10; col += 2) {
      let label;
      if (this.spectrum) label = fmt(col / 10 / frame.period / 2, 'Hz');
      else if (frame.kind === 'meter') label = fmt(col / 10 * ((frame.history.at(-1)?.time || 0) - (frame.history[0]?.time || 0)), 's');
      else if (this.settings.xy && frame.kind === 'scope' && frame.traces.length >= 2) { const m = this.mapping(frame.traces[0].index, box); label = fmt(m.centre + (col - 5) * m.perDiv, 'V'); }
      else label = fmt((col / 10 * (frame.count - 1) - frame.triggerIndex) * frame.period, 's');
      c.fillText(label, box.x + col / 10 * box.w, box.y + box.h + 19);
    }
  }
}
