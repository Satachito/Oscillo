#include "arlyzer_net.h"

#include <ESPmDNS.h>
#include <WiFi.h>
#include <fcntl.h>
#include <lwip/sockets.h>

#include "arlyzer_config.h"  // written by build.sh: the network and the name

extern "C" {
#include "http_request.h"  // the Pico 2 W's, with its host tests (Pico2/firmware/pilyzer)
#include "web_files.h"     // baked by build.sh from Pico2/Web/dist
}

namespace {

constexpr uint32_t kHeader = 12;
constexpr uint32_t kMaxRequest = 64;  // instrument::kMaxRequest in the sketch
constexpr uint32_t kMaxReply = 8192;  // kMaxPayload in protocol.h
constexpr uint8_t kRequestMagic = 0xA5;
constexpr uint8_t kResponseMagic = 0x5A;

// A refused password, a network out of range or a 5 GHz-only one all end the
// same way: try again later, and the USB port carries on meanwhile.
constexpr uint32_t kRetryMs = 40000;
constexpr uint32_t kIdleMs = 30000;

HardwareSerial *ra4 = nullptr;  // the UART to the RA4M1
int listener = -1;
bool serving = false;
uint8_t reply[kHeader + kMaxReply];

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
uint32_t relay(const uint8_t *packet, uint32_t length) {
  while (ra4->available()) ra4->read();
  ra4->write(packet, length);
  // The meter with thousands of averages is the slowest reply to start.
  if (!readLink(reply, kHeader, millis() + 3000) || reply[0] != kResponseMagic) return 0;
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
    if (length < kHeader || length > kHeader + kMaxRequest || packet[0] != kRequestMagic) {
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

void run(void *) {
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(ARLYZER_HOSTNAME);
  // Power saving holds each reply until the next beacon, 100 ms apart.
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(ARLYZER_WIFI_SSID, ARLYZER_WIFI_PASSWORD);
  uint32_t attempted = millis();
  bool connected = false;
  for (;;) {
    if (WiFi.status() == WL_CONNECTED) {
      if (!connected) {
        // A link-local IPv6 address, made again on every connection, so mDNS
        // has an answer for the IPv6 half of the question too.
        WiFi.enableIpV6();
        connected = true;
      }
      if (!serving && listen80()) {
        MDNS.begin(ARLYZER_HOSTNAME);
        MDNS.addService("http", "tcp", 80);
        serving = true;
      }
      if (serving) accept();
      for (Connection &c : connections)
        if (c.used) service(c);
    } else {
      connected = false;
      if (millis() - attempted > kRetryMs) {
        WiFi.disconnect();
        WiFi.begin(ARLYZER_WIFI_SSID, ARLYZER_WIFI_PASSWORD);
        attempted = millis();
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
