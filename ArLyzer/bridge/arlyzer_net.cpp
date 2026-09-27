#include "arlyzer_net.h"

#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_netif.h>
#include <fcntl.h>
#include <lwip/sockets.h>

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

// A refused password, a network out of range or a 5 GHz-only one all end the
// same way: try again later, and the USB port carries on meanwhile.
constexpr uint32_t kRetryMs = 40000;
constexpr uint32_t kIdleMs = 30000;
// Longer than this without joining is said to be failing, whatever the radio
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
uint32_t attempted = 0;
bool joined = false;

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
  if (network[0]) WiFi.begin(network, passphrase[0] ? passphrase : nullptr);
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
  attempt();
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
  } else if (s == WL_NO_SSID_AVAIL || s == WL_CONNECT_FAILED || millis() - attempted > kJoinMs) {
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
  WiFi.setAutoReconnect(true);
  attempt();
  for (;;) {
    if (millis() - syncedAt > (synced ? kSyncMs : kFirstSyncMs)) {
      syncedAt = millis();
      sync();
    }
    if (pending && static_cast<int32_t>(millis() - applyAt) >= 0) apply();
    if (WiFi.status() == WL_CONNECTED) {
      if (!joined) {
        // A link-local IPv6 address, made again on every connection, so mDNS
        // has an answer for the IPv6 half of the question too.
        WiFi.enableIpV6();
        joined = true;
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
      joined = false;
      if (network[0] && millis() - attempted > kRetryMs) {
        WiFi.disconnect();
        attempt();
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
