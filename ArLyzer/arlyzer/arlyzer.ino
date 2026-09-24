// ArLyzer: the PiLyzer wire protocol (Pico2/docs/protocol.md) on an Arduino
// Nano R4, eight analogue inputs, A0–A7. Minimal: identify, capabilities,
// inputRanges, setLED, setRange, the two aborts and analogSample — enough for
// the applications' meter. No acquisitions yet, so Run on the scope is refused.
//
// The transport is the board's USB CDC serial, not the vendor bulk interface
// the Pico uses. The stock Renesas core builds its own USB descriptors and
// compiles TinyUSB's vendor class out (CFG_TUD_VENDOR 0 in the variant's
// tusb_config.h), so a sketch cannot add one. The frames are byte-for-byte the
// same; only what carries them differs.

#include <Arduino.h>

namespace {

constexpr uint8_t kRequestMagic = 0xA5;
constexpr uint8_t kResponseMagic = 0x5A;
constexpr uint32_t kIdentityMagic = 0x5A594C50;  // "PLYZ"
constexpr uint16_t kProtocolVersion = 1;
constexpr uint16_t kFirmwareVersion = 0x0001;    // 0.1
constexpr uint32_t kBoardId = 4;

constexpr uint8_t kChannels = 8;
constexpr uint8_t kBits = 14;
// The RA4M1 runs on 5 V here and the default reference is its own supply, so
// this is only as good as the USB 5 V it came from.
constexpr uint32_t kReferenceMicrovolts = 5000000;
const uint8_t kPins[kChannels] = {A0, A1, A2, A3, A4, A5, A6, A7};

// What the acquisition will offer once it exists. The applications refuse a
// device that reports no clock or a record under 50 points, so these are
// stated now. The conversion period is a placeholder until it is measured:
// 96 cycles of 48 MHz, 2 µs.
constexpr uint32_t kAnalogClockHz = 48000000;
constexpr uint32_t kMinPeriodCycles = 96;
constexpr uint32_t kMaxRecord = 1024;  // eight channels of 2 bytes: 16 KB of the 32 KB

enum : uint8_t {
  OP_IDENTIFY = 0x01,
  OP_CAPABILITIES = 0x02,
  OP_SET_LED = 0x03,
  OP_SET_RANGE = 0x04,
  OP_INPUT_RANGES = 0x07,
  OP_ANALOG_ABORT = 0x14,
  OP_ANALOG_SAMPLE = 0x15,
  OP_LOGIC_ABORT = 0x24,
};

enum : uint8_t {
  ST_OK = 0,
  ST_UNKNOWN_OPCODE = 1,
  ST_BAD_LENGTH = 2,
  ST_BAD_ARGUMENT = 3,
};

constexpr uint32_t CAP_REPORTS_RANGES = 1u << 4;

struct __attribute__((packed)) Header {
  uint8_t magic, opcode, status, flags;
  uint16_t sequence, reserved;
  uint32_t length;
};

struct __attribute__((packed)) Identity {
  uint32_t magic;
  uint16_t protocolVersion, firmwareVersion;
  uint32_t boardId;
  char name[20];
};

struct __attribute__((packed)) Capabilities {
  uint8_t analogChannels, analogBits, logicChannels, analogRanges;
  uint32_t analogClockHz, analogMinPeriodCycles;
  uint32_t analogMaxRecord, analogMaxPretrigger;
  uint32_t logicClockHz, logicMaxRecord, logicMaxPretrigger;
  uint32_t referenceMicrovolts, flags;
  uint32_t reserved[2];
};

struct __attribute__((packed)) InputRange {
  uint8_t switchPosition, flags;
  uint16_t reserved;
  int32_t gainMicro, offsetMicrovolts;
  char name[20];
};

static_assert(sizeof(Header) == 12, "header is 12 bytes");
static_assert(sizeof(Identity) == 32, "identity is 32 bytes");
static_assert(sizeof(Capabilities) == 48, "capabilities is 48 bytes");
static_assert(sizeof(InputRange) == 32, "an input range is 32 bytes");

constexpr uint32_t kMaxPayload = 64;  // the longest request in protocol v1 is 32

Header request;
uint8_t payload[kMaxPayload];
size_t headerFill = 0;
uint32_t payloadFill = 0;

void respond(const Header &req, uint8_t status, const void *data, uint32_t length) {
  Header h{};
  h.magic = kResponseMagic;
  h.opcode = req.opcode;
  h.status = status;
  h.sequence = req.sequence;
  h.length = length;
  Serial.write(reinterpret_cast<const uint8_t *>(&h), sizeof h);
  if (length) Serial.write(static_cast<const uint8_t *>(data), length);
}

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

void dispatch(const Header &req, const uint8_t *data, uint32_t length) {
  switch (req.opcode) {
    case OP_IDENTIFY: {
      Identity id{};
      id.magic = kIdentityMagic;
      id.protocolVersion = kProtocolVersion;
      id.firmwareVersion = kFirmwareVersion;
      id.boardId = kBoardId;
      memcpy(id.name, "ArLyzer Nano R4", 15);
      respond(req, ST_OK, &id, sizeof id);
      return;
    }
    case OP_CAPABILITIES: {
      Capabilities caps{};
      caps.analogChannels = kChannels;
      caps.analogBits = kBits;
      caps.analogRanges = 1;
      caps.analogClockHz = kAnalogClockHz;
      caps.analogMinPeriodCycles = kMinPeriodCycles;
      caps.analogMaxRecord = kMaxRecord;
      caps.analogMaxPretrigger = kMaxRecord - 1;
      caps.referenceMicrovolts = kReferenceMicrovolts;
      caps.flags = CAP_REPORTS_RANGES;
      respond(req, ST_OK, &caps, sizeof caps);
      return;
    }
    case OP_INPUT_RANGES: {
      InputRange range{};
      range.gainMicro = 1000000;
      memcpy(range.name, "0 – 5 V", strlen("0 – 5 V"));
      respond(req, ST_OK, &range, sizeof range);
      return;
    }
    case OP_SET_LED:
      if (length < 1) { respond(req, ST_BAD_LENGTH, nullptr, 0); return; }
      digitalWrite(LED_BUILTIN, data[0] ? HIGH : LOW);
      respond(req, ST_OK, nullptr, 0);
      return;
    case OP_SET_RANGE:
      if (length < 2) { respond(req, ST_BAD_LENGTH, nullptr, 0); return; }
      respond(req, data[0] < kChannels && data[1] == 0 ? ST_OK : ST_BAD_ARGUMENT, nullptr, 0);
      return;
    case OP_ANALOG_ABORT:
    case OP_LOGIC_ABORT:
      respond(req, ST_OK, nullptr, 0);  // nothing is ever running to stop
      return;
    case OP_ANALOG_SAMPLE: {
      uint16_t averages = 1;
      if (length >= 2) memcpy(&averages, data, sizeof averages);
      uint16_t readings[kChannels];
      sampleAll(averages, readings);
      respond(req, ST_OK, readings, sizeof readings);
      return;
    }
    default:
      respond(req, ST_UNKNOWN_OPCODE, nullptr, 0);
      return;
  }
}

// Collects one frame at a time from the byte stream. A stray byte before the
// magic is dropped, so the parser finds the next frame on its own.
void receive() {
  uint8_t *raw = reinterpret_cast<uint8_t *>(&request);
  while (Serial.available()) {
    int b = Serial.read();
    if (b < 0) return;
    if (headerFill < sizeof request) {
      if (headerFill == 0 && b != kRequestMagic) continue;
      raw[headerFill++] = static_cast<uint8_t>(b);
      if (headerFill < sizeof request) continue;
      payloadFill = 0;
      if (request.length == 0) {
        dispatch(request, payload, 0);
        headerFill = 0;
      }
      continue;
    }
    if (payloadFill < kMaxPayload) payload[payloadFill] = static_cast<uint8_t>(b);
    if (++payloadFill < request.length) continue;
    if (request.length > kMaxPayload) respond(request, ST_BAD_LENGTH, nullptr, 0);
    else dispatch(request, payload, request.length);
    headerFill = 0;
  }
}

}  // namespace

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  analogReadResolution(kBits);
  Serial.begin(115200);  // CDC ignores the rate; 1200 is the one that resets into the bootloader
}

void loop() {
  receive();
}
