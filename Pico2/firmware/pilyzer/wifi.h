// Joining a network and answering to a name, so a phone needs neither an
// address nor a network of its own.
#pragma once

#include <stdbool.h>

/// Brings the radio up and starts joining `ssid`, without waiting for it.
/// False only if the radio itself would not start.
bool wifi_start(const char *ssid, const char *password, const char *hostname);

/// Call from the main loop: lwIP here is polled, not threaded. Finishes
/// joining, starts the server and the name once there is an address, and
/// tries again every so often if the network is not there.
void wifi_poll(void);
