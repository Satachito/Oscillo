// The PiLyzer wire protocol, version 1 — see Pico2/docs/protocol.md. Every
// structure is little-endian and packed exactly as the document lays it out.
#pragma once
#include <stdint.h>

namespace wire {

constexpr uint8_t kRequestMagic = 0xA5;
constexpr uint8_t kResponseMagic = 0x5A;
constexpr uint32_t kIdentityMagic = 0x5A594C50;  // "PLYZ"
constexpr uint16_t kProtocolVersion = 1;
constexpr uint32_t kMaxPayload = 8192;

enum Opcode : uint8_t {
  OP_IDENTIFY = 0x01,
  OP_CAPABILITIES = 0x02,
  OP_SET_LED = 0x03,
  OP_SET_RANGE = 0x04,
  OP_INPUT_RANGES = 0x07,
  OP_SET_NETWORK = 0x09,     // an UNO R4 WiFi running ArLyzer's bridge
  OP_NETWORK_STATUS = 0x0A,
  OP_ANALOG_CONFIGURE = 0x10,
  OP_ANALOG_ARM = 0x11,
  OP_ANALOG_STATUS = 0x12,
  OP_ANALOG_READ = 0x13,
  OP_ANALOG_ABORT = 0x14,
  OP_ANALOG_SAMPLE = 0x15,
  OP_LOGIC_CONFIGURE = 0x20,
  OP_LOGIC_ARM = 0x21,
  OP_LOGIC_STATUS = 0x22,
  OP_LOGIC_READ = 0x23,
  OP_LOGIC_ABORT = 0x24,
  // Between the RA4M1 and ArLyzer's bridge on the WiFi's ESP32-S3 only, over
  // the UART between them: never answered on USB, and the bridge passes none
  // on from the network (network.h).
  OP_BRIDGE_SYNC = 0x7E,
};

enum Status : uint8_t {
  ST_OK = 0,
  ST_UNKNOWN_OPCODE = 1,
  ST_BAD_LENGTH = 2,
  ST_BAD_ARGUMENT = 3,
  ST_BUSY = 4,
  ST_NOT_CONFIGURED = 5,
  ST_NO_DATA = 6,
  ST_INTERNAL_ERROR = 7,
};

enum AcquisitionState : uint8_t {
  ACQ_IDLE = 0,
  ACQ_FILLING = 1,
  ACQ_WAITING = 2,
  ACQ_POST_TRIGGER = 3,
  ACQ_COMPLETE = 4,
  ACQ_ABORTED = 5,
  ACQ_OVERRUN = 6,
};

enum TriggerMode : uint8_t { TRIGGER_FREE_RUN = 0, TRIGGER_AUTO = 1, TRIGGER_NORMAL = 2 };

constexpr uint32_t CAP_TRIGGER_LOWPASS = 1u << 3;
constexpr uint32_t CAP_REPORTS_RANGES = 1u << 4;
constexpr uint32_t CAP_NETWORK = 1u << 6;

enum NetworkState : uint8_t { NET_NOT_SET = 0, NET_JOINING = 1, NET_JOINED = 2, NET_FAILING = 3 };
enum NetworkSource : uint8_t { NET_SOURCE_NONE = 0, NET_SOURCE_STORED = 1, NET_SOURCE_BUILT = 2 };

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

struct __attribute__((packed)) AnalogConfig {
  uint8_t channelMask, triggerMode, triggerSlot, triggerSlope;
  uint16_t triggerLevel, triggerHysteresis;
  uint64_t periodFemtoseconds;
  uint32_t recordLength, pretriggerLength, autoTimeoutMicroseconds, lowPassHz;
};

struct __attribute__((packed)) LogicConfig {
  uint8_t triggerMode, triggerChannel, triggerSlope, reserved;
  uint64_t periodFemtoseconds;
  uint32_t recordLength, pretriggerLength, autoTimeoutMicroseconds;
};

struct __attribute__((packed)) AcquisitionPlan {
  uint32_t clockHz, divisorQ8, decimation, recordLength, pretriggerLength;
  uint8_t channelMask, conversionsPerSample;
  uint16_t reserved;
};

struct __attribute__((packed)) AcquisitionStatus {
  uint8_t state, triggered;
  uint16_t reserved;
  uint32_t available, triggerIndex, reserved2;
};

struct __attribute__((packed)) ReadRequest {
  uint32_t offset, count;
};

// setNetwork: UTF-8, zero-padded; a string that fills its field needs no
// terminator. An empty SSID forgets the network, an empty name is the default.
struct __attribute__((packed)) NetworkConfig {
  char ssid[32];
  char password[64];
  char hostname[32];
};

// networkStatus. Never the password. From the bridge, `reserved` carries the
// generation of the last offer it took (network.h).
struct __attribute__((packed)) NetworkStatus {
  uint8_t state, source;
  uint16_t reserved;
  uint8_t ipv4[4];
  char ssid[32];
  char hostname[32];
};

// The reply to bridgeSync when a host has set a network the bridge has not
// yet taken.
struct __attribute__((packed)) NetworkOffer {
  uint16_t generation, reserved;
  NetworkConfig config;
};

static_assert(sizeof(Header) == 12, "header is 12 bytes");
static_assert(sizeof(Identity) == 32, "identity is 32 bytes");
static_assert(sizeof(Capabilities) == 48, "capabilities is 48 bytes");
static_assert(sizeof(InputRange) == 32, "an input range is 32 bytes");
static_assert(sizeof(AnalogConfig) == 32, "an analogue configuration is 32 bytes");
static_assert(sizeof(LogicConfig) == 24, "a logic configuration is 24 bytes");
static_assert(sizeof(AcquisitionPlan) == 24, "a plan is 24 bytes");
static_assert(sizeof(AcquisitionStatus) == 16, "a status is 16 bytes");
static_assert(sizeof(NetworkConfig) == 128, "a network configuration is 128 bytes");
static_assert(sizeof(NetworkStatus) == 72, "a network status is 72 bytes");
static_assert(sizeof(NetworkOffer) == 132, "a network offer is 132 bytes");

}  // namespace wire
