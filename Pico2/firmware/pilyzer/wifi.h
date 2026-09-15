// Joining a network and answering to a name, so a phone needs neither an
// address nor a network of its own.
#pragma once

#include <stdbool.h>

/// Brings the radio up and joins `ssid`. Blocks until it succeeds or the
/// timeout runs out; the instrument works over USB either way.
bool wifi_start(const char *ssid, const char *password, const char *hostname);

/// Call from the main loop: lwIP here is polled, not threaded.
void wifi_poll(void);
