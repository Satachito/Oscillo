import { scaleFor } from './protocol.mjs';
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
    const dpr = Math.min(devicePixelRatio || 1, 2), pixels = [Math.round(width * dpr), Math.round(height * dpr)];
    // Assigning width or height reallocates and clears the backing store, so
    // only do it when the element really changed size.
    if (canvas.width !== pixels[0] || canvas.height !== pixels[1]) [canvas.width, canvas.height] = pixels;
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, width, height);
    let box = { x: 44, y: 18, w: width - 65, h: height - 48 };
    if (this.frame?.kind === 'meter') { box.y = 88; box.h -= 70; }
    // X/Y plots one voltage against another, so a division has to be the same
    // number of pixels each way. On the 10 × 8 sweep grid a circle would come
    // out as a two-to-one ellipse, so the plot gets a square grid of its own.
    this.xyMode = this.frame?.kind === 'scope' && this.settings?.mode === 'scope' && this.settings.xy && this.frame.traces.length >= 2;
    if (this.xyMode) {
      const side = Math.min(box.w, box.h);
      box = { x: box.x + (box.w - side) / 2, y: box.y + (box.h - side) / 2, w: side, h: side };
    }
    const columns = this.xyMode ? 8 : 10;
    c.font = '9px ui-monospace, SFMono-Regular, monospace';
    c.lineWidth = .6;
    for (let col = 0; col <= columns; col++) {
      const x = box.x + col / columns * box.w;
      c.strokeStyle = this.xyMode && col === columns / 2 ? '#607160' : '#344238';
      c.beginPath(); c.moveTo(x, box.y); c.lineTo(x, box.y + box.h); c.stroke();
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
    else if (this.xyMode) this.xy(c, box);
    else this.scope(c, box);
    c.restore(); this.axes(c, box, columns);
  }
  mapping(index, box) {
    const settings = this.settings.channels[index], scale = scaleFor(this.settings, this.caps, this.board, index);
    const centre = settings.ac ? 0 : scale.centre;
    const perDiv = settings.scale || scale.span / 8;
    return { centre, perDiv, y: v => box.y + box.h / 2 - ((v - centre) / perDiv + settings.offset) * box.h / 8 };
  }
  // `map` reads one value out of whatever the caller holds, so a logic record
  // or a bin list is drawn straight from its own storage instead of being
  // copied into a fresh array on every frame.
  trace(c, values, box, y, color, map = v => v) {
    c.strokeStyle = color; c.lineWidth = 1.25; c.beginPath();
    if (values.length > box.w * 2) {
      for (let pixel = 0; pixel < Math.floor(box.w); pixel++) {
        const from = Math.floor(pixel / box.w * values.length), to = Math.min(values.length, Math.ceil((pixel + 1) / box.w * values.length));
        let lo = Infinity, hi = -Infinity;
        for (let i = from; i < to; i++) { const v = map(values[i]); lo = Math.min(lo, v); hi = Math.max(hi, v); }
        c.moveTo(box.x + pixel, y(lo)); c.lineTo(box.x + pixel, y(hi));
      }
    } else for (let i = 0; i < values.length; i++) {
      const x = box.x + i / Math.max(values.length - 1, 1) * box.w, v = map(values[i]);
      if (i) c.lineTo(x, y(v)); else c.moveTo(x, y(v));
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
    const offset = this.settings.channels[first.index].offset;
    const x = v => box.x + box.w / 2 + ((v - xmap.centre) / xmap.perDiv + offset) * box.w / 8;
    c.strokeStyle = '#b8e89b'; c.lineWidth = 1; c.beginPath();
    for (let i = 0; i < first.samples.length; i++) {
      const px = x(first.samples[i]), py = ymap.y(second.samples[i]);
      if (i) c.lineTo(px, py); else c.moveTo(px, py);
    }
    c.stroke();
  }
  fft(c, box) {
    const s = this.spectrum; if (!s?.bins.length) return;
    const max = Math.ceil(Math.max(0, ...s.bins.map(b => b.db)) / 20) * 20;
    this.fftMax = max;
    this.trace(c, s.bins, box, db => box.y + (max - db) / 120 * box.h, COLORS[this.frame.traces[0].index], b => b.db);
    if (s.peak) {
      const x = box.x + s.peak.frequency * this.frame.period * 2 * box.w, y = box.y + (max - s.peak.db) / 120 * box.h;
      c.fillStyle = '#d5e6bf'; c.beginPath(); c.arc(x, y, 3, 0, 2 * Math.PI); c.fill();
    }
  }
  logic(c, box) {
    const active = Array.from({ length: 8 }, (_, i) => i).filter(i => this.settings.logicEnabled & (1 << i));
    for (const [slot, channel] of active.entries()) {
      const step = box.h / Math.max(active.length, 1), top = box.y + slot * step + step * .25;
      this.trace(c, this.frame.samples, box, v => top + (1 - v) * step * .45, COLORS[channel], v => (v >> channel) & 1);
      c.fillStyle = COLORS[channel]; c.fillText(`D${channel}`, box.x + 5, top - 4);
    }
  }
  meter(c, box) {
    const all = this.frame.history.flatMap(r => r.values); if (!all.length) return;
    let low = Math.min(...all), high = Math.max(...all), span = Math.max(.1, high - low); low -= span * .1; high += span * .1;
    this.meterRange = { low, high };
    for (let i = 0; i < this.frame.values.length; i++) this.trace(c, this.frame.history, box, v => box.y + (high - v) / (high - low) * box.h, COLORS[i], row => row.values[i]);
  }
  axes(c, box, columns) {
    c.fillStyle = '#758c7b'; c.textAlign = 'right';
    const frame = this.frame;
    if (frame.kind === 'scope' && this.settings.mode !== 'spectrum') {
      // In X/Y the vertical axis belongs to the second trace, not the first.
      const index = (this.xyMode ? frame.traces[1] : frame.traces[0]).index;
      const map = this.mapping(index, box), offset = this.settings.channels[index].offset;
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(map.centre + (4 - r - offset) * map.perDiv, 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    } else if (this.spectrum) {
      for (let r = 0; r <= 8; r += 2) c.fillText(`${(this.fftMax || 0) - r / 8 * 120}`, box.x - 7, box.y + r / 8 * box.h + 3);
      c.fillText('dBV', box.x - 7, box.y - 6);
    } else if (this.meterRange && frame.kind === 'meter') {
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(this.meterRange.high - r / 8 * (this.meterRange.high - this.meterRange.low), 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    }
    c.textAlign = 'center';
    for (let col = 0; col <= columns; col += 2) {
      let label;
      if (this.spectrum) label = fmt(col / columns / frame.period / 2, 'Hz');
      else if (frame.kind === 'meter') label = fmt(col / columns * ((frame.history.at(-1)?.time || 0) - (frame.history[0]?.time || 0)), 's');
      else if (this.xyMode) { const index = frame.traces[0].index, m = this.mapping(index, box); label = fmt(m.centre + (col - columns / 2 - this.settings.channels[index].offset) * m.perDiv, 'V'); }
      else label = fmt((col / columns * (frame.count - 1) - frame.triggerIndex) * frame.period, 's');
      c.fillText(label, box.x + col / columns * box.w, box.y + box.h + 19);
    }
  }
}
