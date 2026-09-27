// Joining a network and answering to a name, so a phone needs neither an
// address nor a network of its own.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "pilyzer_protocol.h"

/// Brings the radio up and starts joining, without waiting for it: the network
/// a host stored, else `ssid` if it is not empty, else none until a host sets
/// one. False only if the radio itself would not start.
bool wifi_start(const char *ssid, const char *password, const char *hostname);

/// OP_SET_NETWORK: stores the network and name, and joins them a moment later,
/// once the reply has gone. An empty SSID forgets the network.
uint8_t wifi_configure(const pilyzer_network_config_t *config);

/// OP_NETWORK_STATUS.
void wifi_status(pilyzer_network_status_t *out);

/// Call from the main loop: lwIP here is polled, not threaded. Finishes
/// joining, starts the server and the name once there is an address, and
/// tries again every so often if the network is not there.
void wifi_poll(void);
