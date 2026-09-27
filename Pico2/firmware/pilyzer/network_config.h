// The network a Pico 2 W joins, kept near the end of flash so a host can set
// it once and a firmware update leaves it alone — a UF2 only writes the blocks
// it carries, and the program is nowhere near there (network_config.c says
// why it is not the very last sector).
#pragma once

#include <stdbool.h>

#include "pilyzer_protocol.h"

/// The stored network, if one was set and has survived intact.
bool network_config_load(pilyzer_network_config_t *out);

/// Stores `config`, or erases what is stored when its SSID is empty. False if
/// the flash could not be written.
bool network_config_store(const pilyzer_network_config_t *config);
