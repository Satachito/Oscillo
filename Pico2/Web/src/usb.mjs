import { USB_IDS, OP, MAX_PAYLOAD, request, responseHeader, identity, capabilities, inputRanges, ranges, view } from './protocol.mjs';
const errors = ['OK', 'Unknown command', 'Wrong payload size', 'Invalid setting', 'Instrument busy', 'Acquisition not configured', 'No record available', 'Instrument error'];
// One transaction at a time. Bulk packets are a byte stream, not message boundaries.
export class BulkTransport {
  constructor(device, input, output) { this.device = device; this.input = input; this.output = output; this.sequence = 0; this.buffer = new Uint8Array(); this.queue = Promise.resolve(); this.closed = false; }
  async bounded(promise) {
    let timer;
    // Whichever side loses the race still settles later; without a handler of
    // its own a losing transfer rejects into nothing.
    promise.catch(() => {});
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => { this.close().catch(() => {}); reject(new Error('USB timed out. Reconnect the instrument.')); }, 4000);
    })]); } finally { clearTimeout(timer); }
  }
  exchange(opcode, payload) {
    const operation = this.queue.then(() => this.transaction(opcode, payload));
    this.queue = operation.catch(() => {}); return operation;
  }
  synchronize() {
    // Use a fresh nonce so a previous session's IDENTIFY reply is not accepted.
    this.sequence = crypto.getRandomValues(new Uint16Array(1))[0];
    const operation = this.queue.then(() => this.transaction(OP.identify, undefined, true));
    this.queue = operation.catch(() => {}); return operation;
  }
  async seekIdentity(sequence) {
    // Reset does not reliably empty already queued IN data on every host.
    // Only the initial handshake may scan past old data; normal exchanges
    // remain strict. Never leave a timed-out read pending behind a new request.
    const deadline = performance.now() + 4000;
    for (let discarded = 0; discarded <= 65536; discarded++) {
      if (performance.now() > deadline) throw new Error('USB synchronization timed out. Reconnect the instrument.');
      await this.fill(12);
      const b = this.buffer, v = view(b);
      if (b[0] === 0x5a && b[1] === OP.identify && b[2] === 0 && b[3] === 0 &&
          v.getUint16(4, true) === sequence && v.getUint16(6, true) === 0 && v.getUint32(8, true) === 32) {
        await this.fill(44);
        try { identity(this.buffer.subarray(12, 44)); return; } catch { /* old sample bytes can resemble a header */ }
      }
      this.buffer = this.buffer.subarray(1);
    }
    throw new Error('Too much stale USB data. Reconnect the instrument.');
  }
  async transaction(opcode, payload, synchronizing = false) {
    if (this.closed) throw new Error('USB connection is closed.');
    const sequence = this.sequence = (this.sequence + 1) & 0xffff;
    const bytes = request(opcode, sequence, payload);
    try {
      const result = await this.bounded(this.device.transferOut(this.output, bytes));
      if (result.status !== 'ok' || result.bytesWritten !== bytes.length) throw new Error('USB write failed');
      if (synchronizing) await this.seekIdentity(sequence);
      else await this.fill(12);
      const header = responseHeader(this.buffer, opcode, sequence);
      await this.fill(12 + header.length);
      const data = this.buffer.slice(12, 12 + header.length);
      this.buffer = this.buffer.slice(12 + header.length);
      if (header.status) {
        const error = new Error(errors[header.status] || `Device error ${header.status}`);
        error.deviceStatus = header.status; throw error;
      }
      return data;
    } catch (error) {
      // Protocol/I/O failure loses framing. A rejected device command does not.
      if (!error.deviceStatus) await this.close().catch(() => {});
      throw error;
    }
  }
  async fill(length) {
    let empty = 0;
    while (this.buffer.length < length) {
      const result = await this.bounded(this.device.transferIn(this.input, Math.min(8192, Math.max(64, Math.ceil((length - this.buffer.length) / 64) * 64))));
      if (result.status !== 'ok' || !result.data) throw new Error('USB read failed');
      const next = new Uint8Array(result.data.buffer, result.data.byteOffset, result.data.byteLength);
      if (!next.length) { if (++empty > 8) throw new Error('Too many empty USB packets'); continue; }
      const buffer = new Uint8Array(this.buffer.length + next.length);
      buffer.set(this.buffer); buffer.set(next, this.buffer.length); this.buffer = buffer;
      if (buffer.length > MAX_PAYLOAD + 12 + 64) throw new Error('USB response exceeds the frame limit');
    }
  }
  async close() { this.closed = true; this.buffer = new Uint8Array(); if (this.device.opened) await this.device.close(); }
}
export class USBInstrument {
  static async connect() {
    if (!navigator.usb) throw new Error('WebUSB requires desktop Chrome or Edge. You can still use Demo.');
    const device = await navigator.usb.requestDevice({ filters: [USB_IDS] });
    // A reset clears a previous session's unread reply, but a host is allowed
    // to invalidate the handle by performing one, and Windows does. Losing the
    // handle shows up at the next call rather than at the reset itself, so the
    // whole sequence is retried once without it. The nonce scan in
    // synchronize() is what actually recovers framing; the reset is a courtesy.
    try { return await USBInstrument.open(device, true); }
    catch (error) {
      if (error.deviceStatus || error.name === 'NotFoundError' || error.name === 'AbortError') throw error;
      // The plain path is the one that says what is really wrong, so its
      // failure is the one reported.
      return await USBInstrument.open(device, false);
    }
  }
  static async open(device, reset) {
    try {
      await device.open();
      if (reset) await device.reset();
      if (!device.configuration) await device.selectConfiguration(1);
      const iface = device.configuration.interfaces.find(i => i.alternates.some(a => a.interfaceClass === 255));
      if (!iface) throw new Error('No PiLyzer vendor interface found');
      const alternate = iface.alternates.find(a => a.interfaceClass === 255);
      await device.claimInterface(iface.interfaceNumber);
      if (iface.alternate.alternateSetting !== alternate.alternateSetting) await device.selectAlternateInterface(iface.interfaceNumber, alternate.alternateSetting);
      const input = alternate.endpoints.find(e => e.direction === 'in' && e.type === 'bulk');
      const output = alternate.endpoints.find(e => e.direction === 'out' && e.type === 'bulk');
      if (!input || !output) throw new Error('PiLyzer bulk endpoints are missing');
      const instrument = new USBInstrument(new BulkTransport(device, input.endpointNumber, output.endpointNumber));
      instrument.identity = identity(await instrument.transport.synchronize());
      instrument.caps = capabilities(await instrument.command(OP.capabilities));
      instrument.ranges = await instrument.frontEnd();
      return instrument;
    } catch (error) {
      if (device.opened) await device.close().catch(() => {});
      // Name the failure. Every one of these means something else holds the
      // interface or the handle went stale, and which of the two it is only
      // the browser knows.
      if (error.name === 'NetworkError' || error.name === 'InvalidStateError' || error.name === 'SecurityError' || error.name === 'NotFoundError')
        throw new Error(`USB is unavailable — ${error.name}: ${error.message} Close any other tab or application holding the instrument, then unplug it and plug it back in.`);
      throw error;
    }
  }
  constructor(transport) { this.transport = transport; this.demo = false; }
  command(opcode, payload) { return this.transport.exchange(opcode, payload); }
  async setRange(channel, range) { await this.command(OP.range, new Uint8Array([channel, range])); }
  // The device's own description of its front end whenever it will give one.
  // Firmware before 1.7 does not, so the board-id table stands in for it.
  async frontEnd() {
    if (!(this.caps.flags & 16)) return ranges(this.identity.board);
    try { return inputRanges(await this.command(OP.inputRanges)); }
    catch { return ranges(this.identity.board); }
  }
  async setTest(on, frequency) {
    const bytes = new Uint8Array(5); bytes[0] = +on; view(bytes).setUint32(1, frequency, true);
    return view(await this.command(OP.test, bytes)).getUint32(0, true);
  }
  async abort() { await this.command(OP.analogAbort); await this.command(OP.logicAbort); }
  close() { return this.transport.close(); }
}
