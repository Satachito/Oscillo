// The network an UNO R4 WiFi joins, set from a host the way a Pico 2 W's is.
//
// The host talks to the RA4M1 and the radio belongs to the ESP32-S3, so the
// RA4M1 only passes the network on. ArLyzer's bridge (ArLyzer/bridge) asks
// once a second over the UART between them with bridgeSync, carrying its own
// status; the RA4M1 keeps that status for networkStatus, and answers with a
// network a host has set, if there is one the bridge has not taken yet. The
// bridge keeps it in its own flash (NVS) and joins.
//
// A network goes across until the bridge says it has it: the offer carries a
// generation, and the bridge puts the last one it took into its next sync,
// after which the RA4M1 forgets the network, password and all. A sync that
// lost a byte on the way is simply offered again.
//
// Nothing here touches the board, so it runs in the host tests too.
#pragma once
#include <stdint.h>

#include "protocol.h"

namespace network {

// Whether a bridge has asked since the RA4M1 started: without one — Arduino's
// own firmware on the ESP32-S3, or a board without a radio — there is nothing
// to hand a network to, and capabilities does not offer it.
bool bridged();

// setNetwork. badArgument for what the bridge would refuse.
uint8_t configure(const wire::NetworkConfig &config);

// networkStatus: the bridge's last word, or the network a host has just set
// while the bridge has yet to take it.
void status(wire::NetworkStatus &out);

// bridgeSync. True with `offer` filled when there is a network to hand over.
bool sync(const wire::NetworkStatus &bridge, wire::NetworkOffer &offer);

// Why a network would be refused, as the bridge and the Pico 2 W judge it.
bool validPassword(const char *field, uint32_t width);
bool validName(const char *field, uint32_t width);

}  // namespace network
