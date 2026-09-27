#include "network.h"

#include <string.h>

namespace network {
namespace {

bool seen = false;
wire::NetworkStatus last{};    // the bridge's, as its last sync had it
wire::NetworkOffer pending{};  // generation 0: nothing waiting
uint16_t generations = 0;

uint32_t length(const char *field, uint32_t width) {
  uint32_t n = 0;
  while (n < width && field[n]) n++;
  return n;
}

}  // namespace

bool validPassword(const char *s, uint32_t width) {
  const uint32_t n = length(s, width);
  if (n == 0) return true;  // an open network
  if (n == 64) {
    for (uint32_t i = 0; i < n; i++) {
      const char c = s[i];
      if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    }
    return true;
  }
  return n >= 8 && n <= 63;
}

// Empty is the default name.
bool validName(const char *s, uint32_t width) {
  const uint32_t n = length(s, width);
  if (n == 0) return true;
  if (n > 31 || s[0] == '-' || s[n - 1] == '-') return false;
  for (uint32_t i = 0; i < n; i++) {
    const char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  }
  return true;
}

bool bridged() { return seen; }

uint8_t configure(const wire::NetworkConfig &config) {
  if (!seen) return wire::ST_NOT_CONFIGURED;
  if (config.ssid[0] && (!validPassword(config.password, sizeof config.password) ||
                         !validName(config.hostname, sizeof config.hostname)))
    return wire::ST_BAD_ARGUMENT;
  if (++generations == 0) generations = 1;
  pending.generation = generations;
  pending.config = config;
  return wire::ST_OK;
}

void status(wire::NetworkStatus &out) {
  out = last;
  out.reserved = 0;
  if (!pending.generation) return;
  // Said the way the bridge will say it a moment from now.
  out = {};
  if (!pending.config.ssid[0]) return;
  out.state = wire::NET_JOINING;
  out.source = wire::NET_SOURCE_STORED;
  memcpy(out.ssid, pending.config.ssid, sizeof out.ssid);
  memcpy(out.hostname, pending.config.hostname, sizeof out.hostname);
}

bool sync(const wire::NetworkStatus &bridge, wire::NetworkOffer &offer) {
  seen = true;
  last = bridge;
  if (pending.generation && bridge.reserved == pending.generation) {
    memset(&pending, 0, sizeof pending);  // it has it: the password goes
  }
  if (!pending.generation) return false;
  offer = pending;
  return true;
}

}  // namespace network
