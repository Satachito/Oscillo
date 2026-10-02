#include "arlyzer_net.h"

#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_netif.h>
#include <esp_netif_net_stack.h>
#include <fcntl.h>
#include <lwip/dhcp.h>
#include <lwip/netif.h>
#include <lwip/prot/dhcp.h>
#include <lwip/sockets.h>
#include <lwip/tcpip.h>

#include "arlyzer_config.h"  // written by build.sh: a built-in network, if any, and the name

extern "C" {
#include "http_request.h"  // the Pico 2 W's, with its host tests (Pico2/firmware/pilyzer)
#include "web_files.h"     // baked by build.sh from Pico2/Web/dist
}

namespace {

constexpr uint32_t kHeader = 12;
constexpr uint32_t kMaxRequest = 128;  // instrument::kMaxRequest in the sketch
constexpr uint32_t kMaxReply = 8192;  // kMaxPayload in protocol.h
constexpr uint8_t kRequestMagic = 0xA5;
constexpr uint8_t kResponseMagic = 0x5A;
// The sketch's network.h: this bridge's status out, a network from a host back.
constexpr uint8_t kBridgeSync = 0x7E;
constexpr uint32_t kStatusBytes = 72;
constexpr uint32_t kOfferBytes = 132;
enum : uint8_t { kNotSet = 0, kJoining = 1, kJoined = 2, kFailing = 3 };
enum : uint8_t { kSourceNone = 0, kSourceStored = 1, kSourceBuilt = 2 };

// Joining, as a Pico 2 W does it: once the radio is on the network, it waits
// for an address for as long as that takes, and only a failure to get onto the
// network is tried again. This bridge used to start over every 40 s whatever
// was going on, and Arduino's own reconnect on top of that, and every new start
// was a new DHCP exchange that threw away replies to the old one. On a Buffalo
// router that now and then holds back everything broadcast on 2.4 GHz for tens
// of seconds - DHCP replies included, as the bench's /wifi-log showed - a board
// went through several such restarts and took 80 s to seven minutes to join.
// A refused password, a network out of range or a 5 GHz-only one end in a
// failure, tried again after a pause that grows to kMaxRetryMs; an attempt
// that has got nowhere by kAttemptMs, or onto the network but no address by
// kAddressMs, is given up. The USB port carries on meanwhile.
constexpr uint32_t kFirstRetryMs = 1000;
constexpr uint32_t kMaxRetryMs = 16000;
constexpr uint32_t kAttemptMs = 15000;
constexpr uint32_t kAddressMs = 120000;
constexpr uint32_t kIdleMs = 30000;
// Longer than this off the network is said to be failing, whatever the radio
// says: the driver reports a refused password only after the first try.
constexpr uint32_t kJoinMs = 20000;
// The RA4M1 is asked once a second, and more often until it first answers, so
// a host that connects early already finds the network setting offered.
constexpr uint32_t kSyncMs = 1000;
constexpr uint32_t kFirstSyncMs = 250;
// A new network is joined this long after it arrives: over Wi-Fi, the reply
// to the request that set it has to get out before the old network goes.
constexpr uint32_t kApplyDelayMs = 300;

HardwareSerial *ra4 = nullptr;  // the UART to the RA4M1
int listener = -1;
bool serving = false;
uint8_t reply[kHeader + kMaxReply];

// The network in use, as C strings: kept in NVS once a host has set one (it
// survives flash.sh, which leaves NVS alone), else built in, else none.
char network[33], passphrase[65], name[33];
uint8_t source = kSourceNone;
bool joined = false;
uint32_t trying = 0;     // since when: start, a new network, or a lost link
uint32_t attempted = 0;  // the attempt in progress began
uint32_t backoff = kFirstRetryMs;
bool retrying = false;   // an attempt failed, and the next is due at retryAt
uint32_t retryAt = 0;
uint32_t seenFailures = 0;
// Set by Arduino's event task: on the network (associated, keys agreed) and
// how many attempts the driver has ended.
volatile bool associated = false;
volatile uint32_t failures = 0;

// What the radio did, kept for GET /wifi-log, so a join that takes long says
// why once it is through. Written by Arduino's event task and the run task,
// so behind a lock; the newest kLog are kept.
enum : uint8_t { kLogAttempt, kLogAssociated, kLogFailed, kLogLost, kLogGaveUp, kLogDhcp, kLogJoined };
struct LogEntry {
  uint32_t ms;
  uint8_t kind;
  uint8_t detail;  // a reason, a channel, or the DHCP client's state
  uint8_t extra;   // the DHCP client's tries
  int8_t rssi;
  // What the interface carried since the attempt began: frames in, broadcast
  // ones among them, DHCP replies in and DHCP requests out.
  uint16_t in, broadcast;
  uint8_t dhcpIn, dhcpOut;
};
constexpr uint32_t kLog = 128;
LogEntry wifiLog[kLog];
uint32_t logged = 0;  // ever, so the oldest kept is logged - kLog
portMUX_TYPE logLock = portMUX_INITIALIZER_UNLOCKED;

// Frames through the station interface, counted on their way between the
// radio driver and lwIP.
volatile uint32_t framesIn = 0, broadcastsIn = 0, dhcpIn = 0, dhcpOut = 0;
netif_input_fn passIn = nullptr;
netif_linkoutput_fn passOut = nullptr;

// The UDP ports of an Ethernet frame carrying IPv4, or false.
bool udpPorts(const pbuf *p, uint16_t &source, uint16_t &destination) {
  const uint8_t *f = static_cast<const uint8_t *>(p->payload);
  if (p->len < 14 + 20 + 8 || f[12] != 0x08 || f[13] != 0x00 || f[23] != 17) return false;
  const uint32_t udp = 14 + (f[14] & 0x0F) * 4;
  if (p->len < udp + 4) return false;
  source = f[udp] << 8 | f[udp + 1];
  destination = f[udp + 2] << 8 | f[udp + 3];
  return true;
}

err_t countIn(pbuf *p, netif *n) {
  framesIn = framesIn + 1;
  if (static_cast<const uint8_t *>(p->payload)[0] & 1) broadcastsIn = broadcastsIn + 1;
  uint16_t from, to;
  if (udpPorts(p, from, to) && from == 67) dhcpIn = dhcpIn + 1;
  return passIn(p, n);
}

err_t countOut(netif *n, pbuf *p) {
  uint16_t from, to;
  if (udpPorts(p, from, to) && to == 67) dhcpOut = dhcpOut + 1;
  return passOut(n, p);
}

netif *station() {
  esp_netif_t *handle = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
  return handle ? static_cast<netif *>(esp_netif_get_netif_impl(handle)) : nullptr;
}

// Once the driver has added the interface to lwIP, which it does once.
void countTraffic() {
  netif *n = station();
  if (!n || !n->input || !n->linkoutput || n->input == countIn) return;
  passIn = n->input;
  passOut = n->linkoutput;
  n->linkoutput = countOut;
  n->input = countIn;
}

void note(uint8_t kind, uint8_t detail = 0, uint8_t extra = 0, int8_t rssi = 0) {
  const LogEntry e = {millis(), kind, detail, extra, rssi,
                      static_cast<uint16_t>(framesIn), static_cast<uint16_t>(broadcastsIn),
                      static_cast<uint8_t>(dhcpIn), static_cast<uint8_t>(dhcpOut)};
  portENTER_CRITICAL(&logLock);
  wifiLog[logged % kLog] = e;
  logged++;
  portEXIT_CRITICAL(&logLock);
}

// lwIP gives up on a REQUEST nobody has answered after about six seconds and
// starts over under a new transaction number, which the ACK the router is
// still holding back then no longer matches; on the bench the ACK came with
// the router's next burst, about 30 s later. So until a request is
// kRequestMs old its tries are wound back, and it keeps asking under the same
// number. Runs in lwIP's own thread, which owns the client.
constexpr uint32_t kRequestMs = 60000;
uint32_t requestXid = 0, requestSince = 0;
uint32_t heldAt = 0;  // the run task's last look

void holdRequest(void *) {
  netif *n = station();
  dhcp *d = n ? netif_dhcp_data(n) : nullptr;
  if (!d || d->state != DHCP_STATE_REQUESTING) {
    requestXid = 0;
    return;
  }
  if (d->xid != requestXid) {
    requestXid = d->xid;
    requestSince = millis();
  }
  if (millis() - requestSince < kRequestMs && d->tries >= 4) d->tries = 2;
}

// The DHCP client's state and tries, noted whenever they change.
uint16_t dhcpSeen = 0xFFFF;
void watchDhcp() {
  netif *n = station();
  const dhcp *d = n ? netif_dhcp_data(n) : nullptr;
  const uint16_t now = d ? (d->state << 8 | d->tries) : 0xFFFE;
  if (now == dhcpSeen) return;
  dhcpSeen = now;
  if (d) note(kLogDhcp, d->state, d->tries);
}

// The sync with the RA4M1 (the sketch's network.h).
uint16_t taken = 0;  // the generation of the last network offered, until the RA4M1 lets it go
bool synced = false;
uint32_t syncedAt = 0;
bool pending = false;
uint32_t applyAt = 0;
char pendingNetwork[33], pendingPassphrase[65], pendingName[33];

struct Connection {
  WiFiClient client;
  char in[HTTP_MAX_HEAD + kHeader + kMaxRequest];
  uint32_t have = 0;
  uint32_t lastMs = 0;
  bool used = false;
};

// A browser loading the page opens several connections at once, one per
// module, and Safari keeps finished ones open a while (the Pico's
// http_server.c has the story). When all are taken, the one idle longest
// makes room.
constexpr int kConnections = 8;
Connection connections[kConnections];

void release(Connection &c) {
  c.client.stop();
  c.used = false;
  c.have = 0;
}

// Exactly `length` bytes from the RA4M1, or false at `deadline`.
bool readLink(uint8_t *out, uint32_t length, uint32_t deadline) {
  uint32_t got = 0;
  while (got < length) {
    const int ready = ra4->available();
    if (ready > 0) {
      const uint32_t want = length - got;
      got += ra4->read(out + got, static_cast<uint32_t>(ready) < want ? ready : want);
      continue;
    }
    if (static_cast<int32_t>(millis() - deadline) > 0) return false;
    vTaskDelay(1);
  }
  return true;
}

// One request to the RA4M1 and its reply, as they are: the sketch answers
// each request with exactly one reply, so anything in the line beforehand is
// left over from one that timed out, and goes.
uint32_t relay(const uint8_t *packet, uint32_t length, uint32_t startMs = 3000) {
  while (ra4->available()) ra4->read();
  ra4->write(packet, length);
  // The meter with thousands of averages is the slowest reply to start.
  if (!readLink(reply, kHeader, millis() + startMs) || reply[0] != kResponseMagic) return 0;
  uint32_t payload;
  memcpy(&payload, reply + 8, sizeof payload);
  if (payload > kMaxReply) return 0;
  // 230400 baud is 23 bytes a millisecond.
  if (!readLink(reply + kHeader, payload, millis() + 200 + payload / 16)) return 0;
  return kHeader + payload;
}

void send(Connection &c, int status, const char *type, const char *encoding, const void *body,
          uint32_t length, bool close) {
  char head[192];
  const uint32_t n = http_response_head(head, sizeof head, status, type, encoding, length, close);
  if (!n) return;
  c.client.write(reinterpret_cast<const uint8_t *>(head), n);
  if (length) c.client.write(static_cast<const uint8_t *>(body), length);
}

void plain(Connection &c, int status, const char *message) {
  send(c, status, "text/plain; charset=utf-8", nullptr, message, strlen(message), true);
}

// The log as text, one line an event: seconds since start, what, and the
// traffic since the attempt began.
char logText[kLog * 96 + 96];

uint32_t writeLog() {
  static LogEntry kept[kLog];
  portENTER_CRITICAL(&logLock);
  const uint32_t total = logged, first = total > kLog ? total - kLog : 0;
  for (uint32_t i = first; i < total; i++) kept[i - first] = wifiLog[i % kLog];
  portEXIT_CRITICAL(&logLock);
  uint32_t n = snprintf(logText, sizeof logText, "%s, %lu s up%s\n", network,
                        static_cast<unsigned long>(millis() / 1000), first ? ", the newest events" : "");
  for (uint32_t i = 0; i < total - first && n < sizeof logText; i++) {
    const LogEntry &e = kept[i];
    char what[48];
    switch (e.kind) {
      case kLogAttempt: snprintf(what, sizeof what, "attempt"); break;
      case kLogAssociated: snprintf(what, sizeof what, "on the network, channel %u", e.detail); break;
      case kLogGaveUp: snprintf(what, sizeof what, "given up"); break;
      case kLogDhcp: snprintf(what, sizeof what, "dhcp state %u, tries %u", e.detail, e.extra); break;
      case kLogJoined: snprintf(what, sizeof what, "joined, %d dBm", e.rssi); break;
      case kLogFailed:
      case kLogLost:
        snprintf(what, sizeof what, "%s %u %s", e.kind == kLogLost ? "lost" : "failed", e.detail,
                 WiFi.disconnectReasonName(static_cast<wifi_err_reason_t>(e.detail)));
        break;
      default: what[0] = 0;
    }
    const unsigned long ms = e.ms;
    n += snprintf(logText + n, sizeof logText - n, "%6lu.%03lu %-36s in %u broadcast %u dhcp %u/%u\n",
                  ms / 1000, ms % 1000, what, e.in, e.broadcast, e.dhcpIn, e.dhcpOut);
  }
  return n < sizeof logText ? n : sizeof logText - 1;
}

// False when the connection is to be closed.
bool answer(Connection &c, const http_request_t &request) {
  if (request.method == HTTP_POST && !strcmp(request.path, "/rpc")) {
    const uint8_t *packet = reinterpret_cast<const uint8_t *>(c.in) + request.head_size;
    const uint32_t length = request.content_length;
    // bridgeSync is between this bridge and the RA4M1 alone: its reply can
    // carry a password.
    if (length < kHeader || length > kHeader + kMaxRequest || packet[0] != kRequestMagic ||
        packet[1] == kBridgeSync) {
      plain(c, 400, "Not an ArLyzer request.");
      return false;
    }
    const uint32_t n = relay(packet, length);
    if (!n) {
      plain(c, 504, "The instrument did not answer.");
      return false;
    }
    send(c, 200, "application/octet-stream", nullptr, reply, n, request.close_requested);
    return !request.close_requested;
  }
  if (request.method != HTTP_GET) {
    plain(c, 405, "Only GET and POST.");
    return false;
  }
  if (!strcmp(request.path, "/wifi-log")) {
    const uint32_t n = writeLog();
    send(c, 200, "text/plain; charset=utf-8", nullptr, logText, n, request.close_requested);
    return !request.close_requested;
  }
  const web_file_t *file = web_lookup(web_files, WEB_FILE_COUNT, request.path);
  if (!file) {
    plain(c, 404, "No such file on this instrument.");
    return false;
  }
  send(c, 200, http_type_for(file->path), "gzip", file->data, file->length, request.close_requested);
  return !request.close_requested;
}

void service(Connection &c) {
  if (!c.client.connected() && !c.client.available()) {
    release(c);
    return;
  }
  const int ready = c.client.available();
  if (ready > 0) {
    const uint32_t room = sizeof c.in - c.have;
    if (room == 0) {
      plain(c, 413, "Request too large.");
      release(c);
      return;
    }
    const int n = c.client.read(reinterpret_cast<uint8_t *>(c.in) + c.have,
                                static_cast<uint32_t>(ready) < room ? ready : room);
    if (n > 0) c.have += n;
    c.lastMs = millis();
  }
  while (c.have) {
    http_request_t request;
    const http_parse_t parsed = http_parse(c.in, c.have, &request);
    if (parsed == HTTP_PARSE_INCOMPLETE) break;
    if (parsed != HTTP_PARSE_OK) {
      plain(c, parsed == HTTP_PARSE_TOO_LONG ? 431 : 400, "Not a request this instrument reads.");
      release(c);
      return;
    }
    const uint32_t total = request.head_size + request.content_length;
    if (total > sizeof c.in) {
      plain(c, 413, "Request too large.");
      release(c);
      return;
    }
    if (c.have < total) break;
    const bool keep = answer(c, request);
    c.lastMs = millis();
    if (!keep) {
      release(c);
      return;
    }
    memmove(c.in, c.in + total, c.have - total);
    c.have -= total;
  }
  if (millis() - c.lastMs > kIdleMs) release(c);
}

// The listening socket, on IPv6 and IPv4 at once. A Mac asks mDNS for both
// addresses and waited five seconds for an IPv6 one that never came, so the
// radio has one (see run); the server then has to answer on it as well, which
// WiFiServer, IPv4 only, does not. lwIP takes an IPv6 socket bound to the
// any-address as both.
bool listen80() {
  listener = socket(AF_INET6, SOCK_STREAM, 0);
  if (listener < 0) return false;
  sockaddr_in6 any{};
  any.sin6_family = AF_INET6;
  any.sin6_port = htons(80);
  any.sin6_addr = in6addr_any;
  if (bind(listener, reinterpret_cast<sockaddr *>(&any), sizeof any) != 0 ||
      listen(listener, kConnections) != 0) {
    close(listener);
    listener = -1;
    return false;
  }
  fcntl(listener, F_SETFL, fcntl(listener, F_GETFL, 0) | O_NONBLOCK);
  return true;
}

void accept() {
  const int fd = ::accept(listener, nullptr, nullptr);
  if (fd < 0) return;
  WiFiClient incoming(fd);
  Connection *slot = nullptr, *idlest = nullptr;
  const uint32_t now = millis();
  for (Connection &c : connections) {
    if (!c.used) {
      slot = &c;
      break;
    }
    if (!idlest || now - c.lastMs > now - idlest->lastMs) idlest = &c;
  }
  if (!slot) {
    release(*idlest);
    slot = idlest;
  }
  slot->client = incoming;
  slot->client.setNoDelay(true);
  slot->have = 0;
  slot->lastMs = now;
  slot->used = true;
}

// A C string, cut to fit.
void copy(char *out, size_t size, const char *in, size_t width) {
  size_t n = strnlen(in, width);
  if (n > size - 1) n = size - 1;
  memcpy(out, in, n);
  out[n] = 0;
}

void attempt() {
  attempted = millis();
  retrying = false;
  seenFailures = failures;
  framesIn = broadcastsIn = dhcpIn = dhcpOut = 0;
  if (!network[0]) return;
  note(kLogAttempt);
  WiFi.begin(network, passphrase[0] ? passphrase : nullptr);
}

// Starts trying afresh: at start, for a new network, or after a lost link.
void startTrying() {
  trying = millis();
  backoff = kFirstRetryMs;
  attempt();
}

// Arduino's event task. Leaving on purpose (ASSOC_LEAVE) is this bridge's own
// doing, and starts nothing.
void onWifi(arduino_event_t *event) {
  switch (event->event_id) {
    case ARDUINO_EVENT_WIFI_STA_CONNECTED:
      associated = true;
      note(kLogAssociated, event->event_info.wifi_sta_connected.channel);
      break;
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED: {
      const uint8_t reason = event->event_info.wifi_sta_disconnected.reason;
      associated = false;
      if (reason == WIFI_REASON_ASSOC_LEAVE) break;
      note(joined ? kLogLost : kLogFailed, reason);
      failures = failures + 1;
      break;
    }
    default:
      break;
  }
}

void load() {
  Preferences stored;
  if (stored.begin("arlyzer-net", true)) {
    const String s = stored.getString("ssid", ""), p = stored.getString("pass", ""), n = stored.getString("name", "");
    stored.end();
    if (s.length()) {
      copy(network, sizeof network, s.c_str(), 32);
      copy(passphrase, sizeof passphrase, p.c_str(), 64);
      copy(name, sizeof name, n.c_str(), 32);
      source = kSourceStored;
    }
  }
  if (source == kSourceNone && ARLYZER_WIFI_SSID[0]) {
    copy(network, sizeof network, ARLYZER_WIFI_SSID, 32);
    copy(passphrase, sizeof passphrase, ARLYZER_WIFI_PASSWORD, 64);
    source = kSourceBuilt;
  }
  if (!name[0]) copy(name, sizeof name, ARLYZER_HOSTNAME, 32);
}

// The network a host set, into NVS, and joined.
void apply() {
  pending = false;
  const bool renamed = strcmp(name, pendingName) != 0;
  Preferences stored;
  if (stored.begin("arlyzer-net", false)) {
    stored.clear();
    if (pendingNetwork[0]) {
      stored.putString("ssid", pendingNetwork);
      stored.putString("pass", pendingPassphrase);
      stored.putString("name", pendingName);
    }
    stored.end();
  }
  strcpy(network, pendingNetwork);
  strcpy(passphrase, pendingPassphrase);
  strcpy(name, pendingName[0] ? pendingName : ARLYZER_HOSTNAME);
  memset(pendingPassphrase, 0, sizeof pendingPassphrase);
  source = network[0] ? kSourceStored : kSourceNone;
  // The radio driver keeps the last network it joined in NVS of its own
  // (WiFi.persistent): forgetting has to reach that copy as well.
  WiFi.disconnect(false, !network[0]);
  joined = false;
  esp_netif_set_hostname(esp_netif_get_handle_from_ifkey("WIFI_STA_DEF"), name);
  if (serving && renamed) {
    MDNS.end();
    MDNS.begin(name);
    MDNS.addService("http", "tcp", 80);
  }
  startTrying();
}

void status(uint8_t *out) {
  memset(out, 0, kStatusBytes);
  out[1] = source;
  memcpy(out + 2, &taken, 2);
  memcpy(out + 8, network, strnlen(network, 32));
  memcpy(out + 40, name, strnlen(name, 32));
  if (!network[0]) return;
  const wl_status_t s = WiFi.status();
  if (s == WL_CONNECTED) {
    out[0] = kJoined;
    const IPAddress ip = WiFi.localIP();
    for (int i = 0; i < 4; i++) out[4 + i] = ip[i];
  } else if (!associated &&
             (s == WL_NO_SSID_AVAIL || s == WL_CONNECT_FAILED || millis() - trying > kJoinMs)) {
    // On the network and waiting for an address is still joining.
    out[0] = kFailing;
  } else {
    out[0] = kJoining;
  }
}

// One bridgeSync: this bridge's status to the RA4M1, and a network back if a
// host has set one.
void sync() {
  uint8_t packet[kHeader + kStatusBytes] = {kRequestMagic, kBridgeSync};
  const uint32_t length = kStatusBytes;
  memcpy(packet + 8, &length, 4);
  status(packet + kHeader);
  // The RA4M1 answers at once unless it is busy with a long meter reading,
  // and then the next sync will do.
  const uint32_t n = relay(packet, sizeof packet, 150);
  if (!n || reply[1] != kBridgeSync || reply[2] != 0) return;
  synced = true;
  if (n != kHeader + kOfferBytes) {
    taken = 0;  // nothing waiting, so no generation is still owed an answer
    return;
  }
  const uint8_t *offer = reply + kHeader;
  uint16_t generation;
  memcpy(&generation, offer, 2);
  if (generation != taken) {
    const uint8_t *config = offer + 4;
    copy(pendingNetwork, sizeof pendingNetwork, reinterpret_cast<const char *>(config), 32);
    copy(pendingPassphrase, sizeof pendingPassphrase, reinterpret_cast<const char *>(config + 32), 64);
    copy(pendingName, sizeof pendingName, reinterpret_cast<const char *>(config + 96), 32);
    pending = true;
    applyAt = millis() + kApplyDelayMs;
    taken = generation;
  }
  memset(reply + kHeader, 0, kOfferBytes);
}

void run(void *) {
  load();
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(name);
  // Power saving holds each reply until the next beacon, 100 ms apart.
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(false);
  WiFi.onEvent(onWifi);
  startTrying();
  for (;;) {
    if (millis() - syncedAt > (synced ? kSyncMs : kFirstSyncMs)) {
      syncedAt = millis();
      sync();
    }
    if (pending && static_cast<int32_t>(millis() - applyAt) >= 0) apply();
    countTraffic();
    if (WiFi.status() == WL_CONNECTED) {
      if (!joined) {
        // A link-local IPv6 address, made again on every connection, so mDNS
        // has an answer for the IPv6 half of the question too.
        WiFi.enableIpV6();
        joined = true;
        note(kLogJoined, 0, 0, WiFi.RSSI());
      }
      if (!serving && listen80()) {
        MDNS.begin(name);
        MDNS.addService("http", "tcp", 80);
        serving = true;
      }
      if (serving) accept();
      for (Connection &c : connections)
        if (c.used) service(c);
    } else {
      watchDhcp();
      if (millis() - heldAt >= 100) {
        heldAt = millis();
        tcpip_callback(holdRequest, nullptr);
      }
      if (joined) {
        joined = false;
        trying = millis();
        backoff = kFirstRetryMs;
      }
      if (network[0]) {
        const uint32_t now = millis();
        if (!retrying && failures != seenFailures) {
          // The attempt is over: the next one after a pause.
          retrying = true;
          retryAt = now + backoff;
          backoff = backoff * 2 < kMaxRetryMs ? backoff * 2 : kMaxRetryMs;
        } else if (!retrying && now - attempted > (associated ? kAddressMs : kAttemptMs)) {
          note(kLogGaveUp);
          retrying = true;
          retryAt = now;
        }
        if (retrying && static_cast<int32_t>(now - retryAt) >= 0) {
          WiFi.disconnect();
          attempt();
        }
      }
    }
    vTaskDelay(1);
  }
}

}  // namespace

void arlyzerNetBegin(HardwareSerial &uart) {
  ra4 = &uart;
  xTaskCreatePinnedToCore(run, "arlyzer", 8192, nullptr, 1, nullptr, 0);
}
