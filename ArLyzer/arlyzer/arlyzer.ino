// ArLyzer: the PiLyzer wire protocol (Pico2/docs/protocol.md) on an Arduino
// Nano R4, eight analogue inputs, A0–A7: immediate readings for the meter, and
// timed, triggered records for the oscilloscope and the spectrum.
//
// The transport is the board's USB CDC serial, not the vendor bulk interface
// the Pico uses. The stock Renesas core builds its own USB descriptors and
// compiles TinyUSB's vendor class out (CFG_TUD_VENDOR 0 in the variant's
// tusb_config.h), so a sketch cannot add one. The frames are byte-for-byte the
// same; only what carries them differs.
//
// This file is the board: the pins, the serial port and the meter's readings.
// The protocol is instrument.cpp, the record's logic record.cpp, and the timer
// and converter that feed it acquisition.cpp.

#include <Arduino.h>
#include "acquisition.h"
#include "instrument.h"

namespace {

constexpr uint8_t kChannels = acquisition::kChannels;
const uint8_t kPins[kChannels] = {A0, A1, A2, A3, A4, A5, A6, A7};

void writeSerial(const uint8_t *data, size_t length) { Serial.write(data, length); }

void sampleAll(uint16_t averages, uint16_t *readings) {
  if (averages == 0) averages = 1;
  if (averages > 4096) averages = 4096;
  uint32_t totals[kChannels] = {};
  for (uint16_t i = 0; i < averages; i++) {
    for (uint8_t c = 0; c < kChannels; c++) {
      (void)analogRead(kPins[c]);  // the first conversion after the mux moves is not trustworthy
      totals[c] += analogRead(kPins[c]);
    }
  }
  // Left-align from 14 bits into 16, as the protocol asks.
  for (uint8_t c = 0; c < kChannels; c++)
    readings[c] = static_cast<uint16_t>(static_cast<uint64_t>(totals[c]) * 4u / averages);
}

void setLED(bool on) { digitalWrite(LED_BUILTIN, on ? HIGH : LOW); }

}  // namespace

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  analogReadResolution(14);
  acquisition::begin(kPins);
  instrument::begin({writeSerial, sampleAll, setLED});
  Serial.begin(115200);  // CDC ignores the rate; 1200 is the one that resets into the bootloader
}

void loop() {
  while (Serial.available()) {
    const int b = Serial.read();
    if (b < 0) break;
    instrument::receive(static_cast<uint8_t>(b));
  }
  acquisition::poll();
}
