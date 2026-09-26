import { USB_IDS, SERIAL_IDS, SERIAL_BAUD, OP, MAX_PAYLOAD, request, responseHeader, identity, capabilities, inputRanges, ranges, view } from './protocol.mjs';
export const errors = ['OK', 'Unknown command', 'Wrong payload size', 'Invalid setting', 'Instrument busy', 'Acquisition not configured', 'No record available', 'Instrument error'];
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
      await this.bounded(this.write(bytes));
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
      const next = await this.bounded(this.read(length - this.buffer.length));
      if (!next.length) { if (++empty > 8) throw new Error('Too many empty USB packets'); continue; }
      const buffer = new Uint8Array(this.buffer.length + next.length);
      buffer.set(this.buffer); buffer.set(next, this.buffer.length); this.buffer = buffer;
      if (buffer.length > MAX_PAYLOAD + 12 + 64) throw new Error('USB response exceeds the frame limit');
    }
  }
  async write(bytes) {
    const result = await this.device.transferOut(this.output, bytes);
    if (result.status !== 'ok' || result.bytesWritten !== bytes.length) throw new Error('USB write failed');
  }
  async read(wanted) {
    const result = await this.device.transferIn(this.input, Math.min(8192, Math.max(64, Math.ceil(wanted / 64) * 64)));
    if (result.status !== 'ok' || !result.data) throw new Error('USB read failed');
    return new Uint8Array(result.data.buffer, result.data.byteOffset, result.data.byteLength);
  }
  async close() { this.closed = true; this.buffer = new Uint8Array(); if (this.device.opened) await this.device.close(); }
}
// The same frames over a USB serial port, for boards whose USB stack offers
// CDC and nothing else — the ArLyzer on an Arduino R4. A serial port is a
// byte stream just as the bulk pipe is, so framing and resynchronisation are
// the bulk transport's own; only the reads and writes differ.
export class SerialTransport extends BulkTransport {
  constructor(port) {
    super(null, 0, 0);
    this.port = port; this.reader = port.readable.getReader(); this.writer = port.writable.getWriter();
  }
  async write(bytes) { await this.writer.write(bytes); }
  async read() {
    const { value, done } = await this.reader.read();
    if (done || !value) throw new Error('The serial port closed.');
    return value;
  }
  async close() {
    if (this.closed) return;
    this.closed = true; this.buffer = new Uint8Array();
    // Cancelling is what ends a read left pending by a timeout.
    await this.reader.cancel().catch(() => {}); this.reader.releaseLock();
    await this.writer.close().catch(() => {}); this.writer.releaseLock();
    await this.port.close().catch(() => {});
  }
}
export class Instrument {
  static async connect() {
    if (!navigator.usb) throw new Error('WebUSB requires Chrome or Edge, on a computer or on Android. You can still use Demo.');
    const device = await navigator.usb.requestDevice({ filters: [USB_IDS] });
    // A reset clears a previous session's unread reply, but a host is allowed
    // to invalidate the handle by performing one, and Windows does. Losing the
    // handle shows up at the next call rather than at the reset itself, so the
    // whole sequence is retried once without it. The nonce scan in
    // synchronize() is what actually recovers framing; the reset is a courtesy.
    try { return await Instrument.open(device, true); }
    catch (error) {
      if (error.deviceStatus || error.name === 'NotFoundError' || error.name === 'AbortError') throw error;
      // The plain path is the one that says what is really wrong, so its
      // failure is the one reported.
      return await Instrument.open(device, false);
    }
  }
  static async connectSerial() {
    if (!navigator.serial) throw new Error('Web Serial requires Chrome or Edge on a computer. You can still use Demo.');
    const port = await navigator.serial.requestPort({ filters: SERIAL_IDS });
    // Any rate but 1200, which an Arduino takes as the signal to drop into its
    // bootloader. CDC ignores the number otherwise.
    await port.open({ baudRate: SERIAL_BAUD, bufferSize: 8192 });
    try {
      await port.setSignals({ dataTerminalReady: true, requestToSend: true });
      return await Instrument.handshake(new SerialTransport(port));
    } catch (error) {
      await port.close().catch(() => {});
      throw error;
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
      return await Instrument.handshake(new BulkTransport(device, input.endpointNumber, output.endpointNumber));
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
  /// Everything after a transport is open, which is the same whichever
  /// transport it is: name the device, ask what it can do, clear anything a
  /// previous session left running, and read its front end.
  static async handshake(transport) {
    const instrument = new Instrument(transport);
    instrument.identity = identity(await transport.synchronize());
    instrument.caps = capabilities(await instrument.command(OP.capabilities));
    // A host that went away mid-sweep leaves the instrument armed, and an
    // armed instrument refuses to be configured, so anything still running
    // belongs to a session that is over.
    await instrument.abort().catch(() => {});
    instrument.ranges = await instrument.frontEnd();
    return instrument;
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
  /// The instrument's own generator: a sine on GPIO0 and white, pink and brown
  /// noise on the three pins above it. Answers with the sine frequency it
  /// settled on.
  async setSignals(on, sineHz) {
    const bytes = new Uint8Array(5); bytes[0] = +on; view(bytes).setUint32(1, sineHz, true);
    return view(await this.command(OP.signals, bytes)).getUint32(0, true);
  }
  async abort() { await this.command(OP.analogAbort); await this.command(OP.logicAbort); }
  close() { return this.transport.close(); }
}
