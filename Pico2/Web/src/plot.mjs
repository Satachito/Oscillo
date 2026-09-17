import { scaleFor, fitScale, displayedTop } from './protocol.mjs';
import { fmt, spectrum } from './signal.mjs';
export const CURSOR_COLOR = '#e58b72';
export const COLORS = ['#e9c96b', '#79cdd8', '#c0a1ef', '#9ed190', '#d8ad7f', '#a6bcec', '#d592b9', '#afbf7a'];
export class Plot {
  constructor(canvas) {
    this.canvas = canvas; this.context = canvas.getContext('2d');
    this.observer = new ResizeObserver(() => this.draw()); this.observer.observe(canvas);
  }
  update(frame, settings, caps, frontEnd) { this.frame = frame; this.settings = settings; this.caps = caps; this.frontEnd = frontEnd; this.spectra = frame?.kind === 'scope' && settings.mode === 'spectrum' ? frame.traces.map(t => ({ index: t.index, ...spectrum(t.samples, frame.period) })) : null; this.draw(); }
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
    const settings = this.settings.channels[index], scale = scaleFor(this.settings, this.caps, this.frontEnd, index);
    const centre = 0;
    const perDiv = settings.scale || fitScale(scale);
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
  // The channels X/Y was asked for, or the first two there are when one of them
  // is not in this frame.
  xyTraces() {
    const traces = this.frame.traces, x = traces.find(t => t.index === this.settings.xyX) || traces[0];
    return [x, traces.find(t => t.index === this.settings.xyY && t !== x) || traces.find(t => t !== x)];
  }
  scope(c, box) {
    this.bias(c, box);
    for (const trace of this.frame.traces) this.trace(c, trace.samples, box, this.mapping(trace.index, box).y, COLORS[trace.index]);
    if (this.cursors?.enabled) {
      c.save(); c.strokeStyle = CURSOR_COLOR; c.globalAlpha = .8; c.lineWidth = 1;
      for (const fraction of [this.cursors.a, this.cursors.b]) {
        const x = box.x + Math.min(Math.max(fraction, 0), 1) * box.w;
        c.beginPath(); c.moveTo(x, box.y); c.lineTo(x, box.y + box.h); c.stroke();
      }
      c.restore();
    }
    if (this.settings.trigger !== 0) {
      const x = box.x + this.frame.triggerIndex / Math.max(this.frame.count - 1, 1) * box.w;
      c.strokeStyle = '#a3cd87'; c.lineWidth = .8; c.setLineDash([3, 5]); c.beginPath(); c.moveTo(x, box.y); c.lineTo(x, box.y + box.h); c.stroke(); c.setLineDash([]);
      // An arrow on the left edge rather than a line across the screen: the
      // bias lines are horizontal too, and two dashed rules at similar heights
      // are hard to tell apart. It marks a height without covering the trace.
      const t = this.frame.traces.find(t => t.index === this.settings.source) || this.frame.traces[0];
      const y = this.mapping(t.index, box).y(this.settings.level - t.removedMean);
      this.arrow(c, box.x, Math.min(Math.max(y, box.y + 5), box.y + box.h - 5), 1,
                 '#a3cd87', y < box.y || y > box.y + box.h);
    }
  }
  /// A triangle pointing `direction` (1 right, -1 left), filled while the thing
  /// it marks is on screen and hollow when it is only pointing the way.
  arrow(c, x, y, direction, colour, hollow) {
    c.beginPath();
    c.moveTo(x, y - 5); c.lineTo(x + 9 * direction, y); c.lineTo(x, y + 5); c.closePath();
    if (hollow) { c.strokeStyle = colour; c.lineWidth = 1; c.stroke(); }
    else { c.fillStyle = colour; c.fill(); }
  }
  // Where each channel's front end holds its input with nothing on it, and —
  // once somebody has measured it — what it actually read. The gap between the
  // two is that channel's offset error. Neither is taken out of a reading.
  bias(c, box) {
    for (const trace of this.frame.traces) {
      const channel = this.settings.channels[trace.index], map = this.mapping(trace.index, box);
      if (channel.bias) {
        const y = map.y(channel.bias);
        if (y >= box.y && y <= box.y + box.h) {
          c.strokeStyle = COLORS[trace.index]; c.globalAlpha = .55; c.lineWidth = 1;
          c.setLineDash([3, 3]); c.beginPath(); c.moveTo(box.x, y); c.lineTo(box.x + box.w, y); c.stroke();
          c.setLineDash([]); c.globalAlpha = .9; c.textAlign = 'right'; c.fillStyle = COLORS[trace.index];
          c.fillText(`CH${trace.index + 1} bias`, box.x + box.w - 8, Math.max(y - 4, box.y + 9));
          c.globalAlpha = 1; c.textAlign = 'left';
        }
      }
      if (channel.measuredBias !== null && channel.measuredBias !== undefined) {
        const y = map.y(channel.measuredBias);
        this.arrow(c, box.x + box.w, Math.min(Math.max(y, box.y + 5), box.y + box.h - 5), -1,
                   COLORS[trace.index], y < box.y || y > box.y + box.h);
      }
    }
  }
  xy(c, box) {
    const [first, second] = this.xyTraces(), xmap = this.mapping(first.index, box), ymap = this.mapping(second.index, box);
    const offset = this.settings.channels[first.index].offset;
    const x = v => box.x + box.w / 2 + ((v - xmap.centre) / xmap.perDiv + offset) * box.w / 8;
    c.strokeStyle = '#b8e89b'; c.lineWidth = 1; c.beginPath();
    for (let i = 0; i < first.samples.length; i++) {
      const px = x(first.samples[i]), py = ymap.y(second.samples[i]);
      if (i) c.lineTo(px, py); else c.moveTo(px, py);
    }
    c.stroke();
    c.fillStyle = '#8c9e90'; c.textAlign = 'left';
    c.fillText(`X: CH${first.index + 1}   Y: CH${second.index + 1}`, box.x + 8, box.y + 14);
  }
  // Every channel on one axis: an input and an output read against each other
  // is what makes two channels worth having here. Peaks are ringed and labelled
  // with their frequency, as on the Mac: the strongest five of one channel, or
  // two apiece in each channel's colour when there are more, or the labels
  // bury the traces they describe.
  fft(c, box) {
    const spectra = (this.spectra || []).filter(s => s.bins.length); if (!spectra.length) return;
    // The axis ends at the span; the bins past it are not drawn, but one more
    // than fits is, so the trace runs to the edge and the clip trims it.
    const top = this.fftTop = displayedTop(this.settings.spectrumSpan, 1 / this.frame.period / 2);
    const resolution = spectra[0].resolution, last = Math.min(spectra[0].bins.length - 1, Math.ceil(top / resolution));
    const shown = spectra.map(s => s.bins.slice(0, last + 1));
    const max = Math.ceil(Math.max(0, ...shown.flatMap(bins => bins.map(b => b.db))) / 20) * 20;
    this.fftMax = max;
    const y = db => box.y + (max - db) / 120 * box.h;
    c.save(); c.beginPath(); c.rect(box.x, box.y, box.w, box.h); c.clip();
    spectra.forEach((s, i) => this.trace(c, shown[i], { ...box, w: box.w * last * resolution / top }, y, COLORS[s.index], b => b.db));
    c.restore();
    const limit = spectra.length > 1 ? 2 : 5;
    c.save(); c.textAlign = 'center'; c.lineWidth = 1;
    // The strongest of what is on screen, not of the whole record.
    for (const s of spectra) for (const peak of (s.peaks || []).filter(p => p.frequency <= top).slice(0, limit)) {
      const px = box.x + peak.frequency / top * box.w, py = y(peak.db);
      if (px <= box.x + 1 || px > box.x + box.w) continue;
      c.strokeStyle = c.fillStyle = spectra.length > 1 ? COLORS[s.index] : '#d5e6bf';
      c.beginPath(); c.arc(px, py, 3, 0, 2 * Math.PI); c.stroke();
      c.fillText(fmt(peak.frequency, 'Hz'), Math.min(Math.max(px, box.x + 24), box.x + box.w - 24), Math.max(py - 8, box.y + 9));
    }
    c.restore();
  }
  logic(c, box) {
    const active = Array.from({ length: 8 }, (_, i) => i).filter(i => this.settings.logicEnabled & (1 << i));
    for (const [slot, channel] of active.entries()) {
      const step = box.h / Math.max(active.length, 1), top = box.y + slot * step + step * .25;
      this.trace(c, this.frame.samples, box, v => top + (1 - v) * step * .45, COLORS[channel], v => (v >> channel) & 1);
      c.fillStyle = COLORS[channel]; c.fillText(`D${channel}`, box.x + 5, top - 4);
    }
  }
  // Without the shading a slow log looks calm however much the signal moved
  // between its points.
  meter(c, box) {
    const history = this.frame.history; if (!history.length) return;
    let low = Infinity, high = -Infinity;
    for (const row of history) for (let i = 0; i < row.low.length; i++) { low = Math.min(low, row.low[i]); high = Math.max(high, row.high[i]); }
    if (!Number.isFinite(low)) return;
    const span = Math.max(.1, high - low); low -= span * .1; high += span * .1;
    this.meterRange = { low, high };
    const x = i => box.x + i / Math.max(history.length - 1, 1) * box.w;
    const y = v => box.y + (high - v) / (high - low) * box.h;
    for (let i = 0; i < this.frame.values.length; i++) {
      c.fillStyle = COLORS[i] + '2e';
      c.beginPath();
      for (let n = 0; n < history.length; n++) c.lineTo(x(n), y(history[n].high[i]));
      for (let n = history.length - 1; n >= 0; n--) c.lineTo(x(n), y(history[n].low[i]));
      c.closePath(); c.fill();
      this.trace(c, history, box, y, COLORS[i], row => row.mean[i]);
    }
  }
  axes(c, box, columns) {
    c.fillStyle = '#758c7b'; c.textAlign = 'right';
    const frame = this.frame;
    if (frame.kind === 'scope' && this.settings.mode !== 'spectrum') {
      // In X/Y the vertical axis belongs to the second trace, not the first.
      const index = (this.xyMode ? this.xyTraces()[1] : frame.traces[0]).index;
      const map = this.mapping(index, box), offset = this.settings.channels[index].offset;
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(map.centre + (4 - r - offset) * map.perDiv, 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    } else if (this.spectra) {
      for (let r = 0; r <= 8; r += 2) c.fillText(`${(this.fftMax || 0) - r / 8 * 120}`, box.x - 7, box.y + r / 8 * box.h + 3);
      c.fillText('dBV', box.x - 7, box.y - 6);
    } else if (this.meterRange && frame.kind === 'meter') {
      for (let r = 0; r <= 8; r += 2) c.fillText(fmt(this.meterRange.high - r / 8 * (this.meterRange.high - this.meterRange.low), 'V'), box.x - 7, box.y + r / 8 * box.h + 3);
    }
    c.textAlign = 'center';
    for (let col = 0; col <= columns; col += 2) {
      let label;
      if (this.spectra) label = fmt(col / columns * (this.fftTop || 1 / frame.period / 2), 'Hz');
      else if (frame.kind === 'meter') label = fmt(col / columns * (frame.history.at(-1)?.time || 0), 's');
      else if (this.xyMode) { const index = this.xyTraces()[0].index, m = this.mapping(index, box); label = fmt(m.centre + (col - columns / 2 - this.settings.channels[index].offset) * m.perDiv, 'V'); }
      else label = fmt((col / columns * (frame.count - 1) - frame.triggerIndex) * frame.period, 's');
      c.fillText(label, box.x + col / columns * box.w, box.y + box.h + 19);
    }
  }
}
