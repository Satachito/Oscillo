// ArLyzer: the PiLyzer wire protocol (Pico2/docs/protocol.md) on an Arduino
// Nano R4, UNO R4 Minima or UNO R4 WiFi, eight analogue inputs (seven on the
// WiFi): immediate readings for the meter, and timed, triggered records for
// the oscilloscope and the spectrum.
//
// The transport is the board's USB CDC serial, not the vendor bulk interface
// the Pico uses. The stock Renesas core builds its own USB descriptors and
// compiles TinyUSB's vendor class out (CFG_TUD_VENDOR 0 in the variant's
// tusb_config.h), so a sketch cannot add one. The frames are byte-for-byte the
// same; only what carries them differs.
//
// On the WiFi the USB port is the ESP32-S3's, which passes the bytes on over a
// UART at whatever rate the host opened the port at; on the others the rate
// means nothing.
//
// This file is the board: the pins, the serial port and the meter's readings.
// The protocol is instrument.cpp, the record's logic record.cpp, and the timer
// and converter that feed it acquisition.cpp.

#include <Arduino.h>
#include "acquisition.h"
#include "instrument.h"

namespace {

constexpr uint8_t kChannels = acquisition::kChannels;
#if defined(ARDUINO_MINIMA)
// The UNO has only A0–A5 on its analogue header, but D4 and D5 are converter
// inputs as well (P103 = AN019, P102 = AN020).
constexpr uint32_t kBoardId = 5;
constexpr char kName[] = "ArLyzer R4 Minima";
const uint8_t kPins[kChannels] = {A0, A1, A2, A3, A4, A5, 4, 5};
#elif defined(ARDUINO_UNOWIFIR4)
// On the WiFi the one converter input off the analogue header that is free is
// D10 (P103 = AN019). D13 (P102 = AN020) would be the next, but it carries the
// board's LED, and there is no RAM for an eighth input anyway (record.h).
constexpr uint32_t kBoardId = 6;
constexpr char kName[] = "ArLyzer R4 WiFi";
const uint8_t kPins[kChannels] = {A0, A1, A2, A3, A4, A5, 10};
#else
constexpr uint32_t kBoardId = 4;
constexpr char kName[] = "ArLyzer Nano R4";
const uint8_t kPins[kChannels] = {A0, A1, A2, A3, A4, A5, A6, A7};
#endif

// analogRead(4) is A4, not D4: a number below A0 is taken as an analogue
// index. The port-and-pin form reads the pin itself, whichever header it is on.
int readPin(uint8_t pin) { return analogRead(digitalPinToBspPin(pin)); }

void writeSerial(const uint8_t *data, size_t length) { Serial.write(data, length); }

// A serial stream and the requests arriving on it.
struct Link {
  arduino::HardwareSerial &serial;
  instrument::Port port;
  uint32_t lastByteMs;
};

void serve(Link &link) {
  while (link.serial.available()) {
    const int b = link.serial.read();
    if (b < 0) break;
    link.port.receive(static_cast<uint8_t>(b));
    link.lastByteMs = millis();
  }
  // A host sends a request all at once, so one quiet this long is not coming.
  if (millis() - link.lastByteMs > 50) link.port.flush();
}

Link usb{Serial, instrument::Port(writeSerial), 0};

#if defined(ARDUINO_UNOWIFIR4)
// The WiFi's second UART, to the ESP32-S3, carries what its radio receives
// when the ESP32 runs ArLyzer's bridge (ArLyzer/bridge) rather than the stock
// one; with the stock one nothing arrives on it.
void writeRadio(const uint8_t *data, size_t length) { Serial2.write(data, length); }
Link radio{Serial2, instrument::Port(writeRadio), 0};
#endif

void sampleAll(uint16_t averages, uint16_t *readings) {
  if (averages == 0) averages = 1;
  if (averages > 4096) averages = 4096;
  uint32_t totals[kChannels] = {};
  for (uint16_t i = 0; i < averages; i++) {
    for (uint8_t c = 0; c < kChannels; c++) {
      (void)readPin(kPins[c]);  // the first conversion after the mux moves is not trustworthy
      totals[c] += readPin(kPins[c]);
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
  instrument::begin({kBoardId, kName, sampleAll, setLED});
  // The WiFi's UART takes an interrupt a byte, and with the tick at its
  // shortest there is little time for one: at 460800 and above, requests lost
  // bytes while a record was being taken (2026-09-26). Raising the UART above
  // the tick kept the bytes but made the ticks late instead. 230400 lost none.
  // A native CDC port ignores the rate; 1200 is the one that resets into the
  // bootloader on every board.
  Serial.begin(230400);
#if defined(ARDUINO_UNOWIFIR4)
  Serial2.begin(230400);
#endif
}

void loop() {
  serve(usb);
#if defined(ARDUINO_UNOWIFIR4)
  serve(radio);
#endif
  acquisition::poll();
}
