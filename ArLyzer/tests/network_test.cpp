// Host tests for network:: — a host's network handed to the bridge on the
// WiFi's ESP32-S3, and forgotten once the bridge says it has it.
//
//   xcrun c++ -std=c++17 -Wall -Wextra -I ../arlyzer ../arlyzer/network.cpp network_test.cpp -o network_test && ./network_test
#include <cstdio>
#include <cstring>
#include <string>

#include "network.h"

using namespace wire;

static int failures = 0;
#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::printf("%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition); \
      failures++;                                                          \
    }                                                                      \
  } while (0)

static NetworkConfig config(const char *ssid, const char *password, const char *hostname = "") {
  NetworkConfig c{};
  std::strncpy(c.ssid, ssid, sizeof c.ssid);
  std::strncpy(c.password, password, sizeof c.password);
  std::strncpy(c.hostname, hostname, sizeof c.hostname);
  return c;
}

static NetworkStatus bridgeSays(uint8_t state, const char *ssid, uint16_t taken) {
  NetworkStatus s{};
  s.state = state;
  s.source = ssid[0] ? NET_SOURCE_STORED : NET_SOURCE_NONE;
  s.reserved = taken;
  s.ipv4[0] = 192, s.ipv4[1] = 168, s.ipv4[2] = 0, s.ipv4[3] = 20;
  std::strncpy(s.ssid, ssid, sizeof s.ssid);
  std::strncpy(s.hostname, "arlyzer", sizeof s.hostname);
  return s;
}

static bool allZero(const void *data, size_t length) {
  const uint8_t *b = static_cast<const uint8_t *>(data);
  for (size_t i = 0; i < length; i++)
    if (b[i]) return false;
  return true;
}

int main() {
  // No bridge yet: nothing to hand a network to.
  CHECK(!network::bridged());
  CHECK(network::configure(config("Bench", "password1")) == ST_NOT_CONFIGURED);

  NetworkOffer offer{};
  CHECK(!network::sync(bridgeSays(NET_NOT_SET, "", 0), offer));
  CHECK(network::bridged());

  NetworkStatus s;
  network::status(s);
  CHECK(s.state == NET_NOT_SET);

  // The bridge's own rules.
  CHECK(network::configure(config("Bench", "short")) == ST_BAD_ARGUMENT);
  CHECK(network::configure(config("Bench", "password1", "Upper")) == ST_BAD_ARGUMENT);
  CHECK(network::configure(config("Bench", "password1", "-edge")) == ST_BAD_ARGUMENT);
  CHECK(network::configure(config("Bench", std::string(64, 'g').c_str())) == ST_BAD_ARGUMENT);
  CHECK(network::configure(config("Bench", std::string(64, 'a').c_str())) == ST_OK);
  CHECK(network::configure(config("Bench", "")) == ST_OK);  // open

  // A host sets one: it is offered until the bridge says it has it.
  CHECK(network::configure(config("Bench", "password1", "scope")) == ST_OK);
  network::status(s);
  CHECK(s.state == NET_JOINING && !std::strcmp(s.ssid, "Bench") && !std::strcmp(s.hostname, "scope"));
  CHECK(s.source == NET_SOURCE_STORED && allZero(s.ipv4, 4));

  CHECK(network::sync(bridgeSays(NET_NOT_SET, "", 0), offer));
  const uint16_t generation = offer.generation;
  CHECK(generation != 0);
  CHECK(!std::strcmp(offer.config.password, "password1"));
  // Lost on the way: offered again.
  CHECK(network::sync(bridgeSays(NET_NOT_SET, "", 0), offer));
  CHECK(offer.generation == generation);

  // Taken: no more offers, and the status is the bridge's own.
  CHECK(!network::sync(bridgeSays(NET_JOINED, "Bench", generation), offer));
  network::status(s);
  CHECK(s.state == NET_JOINED && s.ipv4[3] == 20 && s.reserved == 0);
  CHECK(!network::sync(bridgeSays(NET_JOINED, "Bench", generation), offer));

  // A second network gets a new generation, so an old acknowledgement does
  // not count for it.
  CHECK(network::configure(config("Other", "password2")) == ST_OK);
  CHECK(network::sync(bridgeSays(NET_JOINED, "Bench", generation), offer));
  CHECK(offer.generation != generation);
  CHECK(!network::sync(bridgeSays(NET_JOINING, "Other", offer.generation), offer));

  // Forgetting is a network too, with an empty SSID.
  CHECK(network::configure(config("", "")) == ST_OK);
  network::status(s);
  CHECK(s.state == NET_NOT_SET && s.ssid[0] == 0);
  CHECK(network::sync(bridgeSays(NET_JOINED, "Other", 0), offer));
  CHECK(offer.config.ssid[0] == 0);

  if (failures) {
    std::printf("%d failed\n", failures);
    return 1;
  }
  std::printf("network: all passed\n");
  return 0;
}
