import { USB_IDS, OP, MAX_PAYLOAD, request, responseHeader, identity, capabilities, view } from './protocol.mjs';
const errors = ['OK', 'Unknown command', 'Wrong payload size', 'Invalid setting', 'Instrument busy', 'Acquisition not configured', 'No record available', 'Instrument error'];
// One transaction at a time. Bulk packets are a byte stream, not message boundaries.
export class BulkTransport {
  constructor(device, input, output) { this.device = device; this.input = input; this.output = output; this.sequence = 0; this.buffer = new Uint8Array(); this.queue = Promise.resolve(); this.closed = false; }
  async bounded(promise) {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => { this.close().catch(() => {}); reject(new Error('USB timed out. Reconnect the instrument.')); }, 4000);
    })]); } finally { clearTimeout(timer); }
  }
  exchange(opcode, payload) {
    const operation = this.queue.then(() => this.transaction(opcode, payload));
    this.queue = operation.catch(() => {}); return operation;
  }
  async transaction(opcode, payload) {
    if (this.closed) throw new Error('USB connection is closed.');
    const sequence = this.sequence = (this.sequence + 1) & 0xffff;
    const bytes = request(opcode, sequence, payload);
    try {
      const result = await this.bounded(this.device.transferOut(this.output, bytes));
      if (result.status !== 'ok' || result.bytesWritten !== bytes.length) throw new Error('USB write failed');
      await this.fill(12);
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
    try {
      await device.open();
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
      instrument.identity = identity(await instrument.command(OP.identify));
      instrument.caps = capabilities(await instrument.command(OP.capabilities));
      return instrument;
    } catch (error) {
      if (device.opened) await device.close().catch(() => {});
      if (error.name === 'NetworkError' || error.name === 'InvalidStateError') throw new Error('USB is unavailable. Disconnect the macOS app and other browser tabs, then try again.');
      throw error;
    }
  }
  constructor(transport) { this.transport = transport; this.demo = false; }
  command(opcode, payload) { return this.transport.exchange(opcode, payload); }
  async setRange(channel, range) { await this.command(OP.range, new Uint8Array([channel, range])); }
  async setTest(on, frequency) {
    const bytes = new Uint8Array(5); bytes[0] = +on; view(bytes).setUint32(1, frequency, true);
    return view(await this.command(OP.test, bytes)).getUint32(0, true);
  }
  async abort() { await this.command(OP.analogAbort); await this.command(OP.logicAbort); }
  close() { return this.transport.close(); }
}
