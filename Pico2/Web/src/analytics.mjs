// Counts which way an instrument was connected, on the GitHub Pages copy only:
// index.html defines gtag there and nowhere else. The event is a name and
// nothing more — no samples, readings or device details.
export const CONNECTIONS = { usb: 'connect_usb', serial: 'connect_serial', wifi: 'connect_wifi', demo: 'connect_demo' };
export function track(event) {
  try { globalThis.gtag?.('event', event); } catch { /* measuring never gets in the way of connecting */ }
}
