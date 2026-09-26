// ArLyzer over Wi-Fi, from the UNO R4 WiFi's ESP32-S3.
//
// The ESP32 joins the network, answers to <name>.local, hands out the browser
// application from its own flash and passes each POST /rpc to the RA4M1 over
// the UART the stock firmware used for its AT commands — the same frames the
// USB port carries, on a line of their own. See README.md.
#pragma once

#include <HardwareSerial.h>

// Starts the radio and a task of its own that serves it. `link` is the UART
// to the RA4M1's Serial2, already begun at the rate the sketch listens at.
void arlyzerNetBegin(HardwareSerial &link);
