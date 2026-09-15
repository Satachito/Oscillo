import { OP, MAX_PAYLOAD, request, responseHeader } from './protocol.mjs';
import { Instrument, errors } from './instrument.mjs';

// The same packets as the USB path, one to a POST. HTTP gives message
// boundaries, so none of the bulk transport's framing recovery is needed here:
// a reply either arrives whole or the request failed.
export class HttpTransport {
  constructor(base = location.href) {
    this.url = new URL('rpc', base);
    this.sequence = 0; this.queue = Promise.resolve(); this.closed = false; this.pending = null;
  }
  // One transaction at a time, as on USB: the instrument answers a single
  // outstanding command, whatever is carrying it.
  exchange(opcode, payload) {
    const operation = this.queue.then(() => this.transaction(opcode, payload));
    this.queue = operation.catch(() => {}); return operation;
  }
  synchronize() {
    // A fresh nonce, so a reply cached anywhere between here and the
    // instrument cannot pass for this session's.
    this.sequence = crypto.getRandomValues(new Uint16Array(1))[0];
    return this.exchange(OP.identify);
  }
  async transaction(opcode, payload) {
    if (this.closed) throw new Error('The instrument connection is closed.');
    const sequence = this.sequence = (this.sequence + 1) & 0xffff;
    const bytes = request(opcode, sequence, payload);
    const abort = this.pending = new AbortController();
    const timer = setTimeout(() => abort.abort(), 8000);
    let reply;
    try {
      const response = await fetch(this.url, {
        method: 'POST', body: bytes, signal: abort.signal, cache: 'no-store',
        headers: { 'Content-Type': 'application/octet-stream' },
      });
      if (!response.ok) throw new Error(`The instrument answered ${response.status}.`);
      reply = new Uint8Array(await response.arrayBuffer());
    } catch (error) {
      await this.close();
      throw error.name === 'AbortError'
        ? new Error('The instrument stopped answering. Check the Wi-Fi connection.')
        : new Error(`Cannot reach the instrument — ${error.message}`);
    } finally {
      clearTimeout(timer);
      this.pending = null;
    }
    if (reply.length > MAX_PAYLOAD + 12) throw new Error('The reply exceeds the frame limit.');
    const header = responseHeader(reply, opcode, sequence);
    if (reply.length < 12 + header.length) throw new Error('The reply is shorter than its header says.');
    if (header.status) {
      // A refused command is the instrument talking, not the link failing, so
      // the connection stays up — the same distinction the USB path makes.
      const error = new Error(errors[header.status] || `Device error ${header.status}`);
      error.deviceStatus = header.status; throw error;
    }
    return reply.slice(12, 12 + header.length);
  }
  /// Closing abandons whatever is in flight. A request left hanging on a
  /// radio that has gone away would otherwise hold the queue for its full fuse.
  async close() { this.closed = true; this.pending?.abort(); this.pending = null; }
}

/// Connects to the instrument that served this page. There is no address to
/// type: the firmware hands out the front panel and answers `rpc` beside it,
/// so the page's own origin is the instrument.
export async function connect(base = location.href) {
  return Instrument.handshake(new HttpTransport(base));
}

/// Whether this page came from an instrument at all. A single identify, with a
/// short fuse, so a page served from anywhere else gives up quickly and offers
/// USB as before.
///
/// Only an `http:` page can be one: the instrument serves plain HTTP, and a
/// page delivered over HTTPS is not allowed to talk to it whatever it answers.
/// Asking anyway would put a failed request in the console of every visit to
/// the hosted copy.
export async function available(base = location.href) {
  if (new URL(base).protocol !== 'http:') return false;
  const transport = new HttpTransport(base);
  const timer = setTimeout(() => transport.close(), 1500);
  try { await transport.synchronize(); return true; }
  catch { return false; }
  finally { clearTimeout(timer); }
}
