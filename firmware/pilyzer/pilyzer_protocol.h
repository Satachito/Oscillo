// Wire format shared by the RP2350 firmware and the macOS application.
// The authoritative description is docs/protocol.md; this header is the
// machine-readable half of it, and the static assertions at the bottom are
// what keep the two from drifting apart.
#pragma once

#include <stdint.h>

#define PILYZER_MAGIC_REQUEST   0xA5
#define PILYZER_MAGIC_RESPONSE  0x5A
#define PILYZER_IDENTITY_MAGIC  0x5A594C50u   // "PLYZ"
#define PILYZER_PROTOCOL_VERSION 1

enum pilyzer_opcode {
    OP_IDENTIFY              = 0x01,
    OP_CAPABILITIES          = 0x02,
    OP_SET_LED               = 0x03,
    OP_SET_RANGE             = 0x04,
    OP_SET_CALIBRATION_OUT   = 0x05,
    OP_REBOOT_BOOTLOADER     = 0x06,

    OP_ANALOG_CONFIGURE      = 0x10,
    OP_ANALOG_ARM            = 0x11,
    OP_ANALOG_STATUS         = 0x12,
    OP_ANALOG_READ           = 0x13,
    OP_ANALOG_ABORT          = 0x14,
    OP_ANALOG_SAMPLE         = 0x15,

    OP_LOGIC_CONFIGURE       = 0x20,
    OP_LOGIC_ARM             = 0x21,
    OP_LOGIC_STATUS          = 0x22,
    OP_LOGIC_READ            = 0x23,
    OP_LOGIC_ABORT           = 0x24,
};

enum pilyzer_status {
    ST_OK             = 0,
    ST_UNKNOWN_OPCODE = 1,
    ST_BAD_LENGTH     = 2,
    ST_BAD_ARGUMENT   = 3,
    ST_BUSY           = 4,
    ST_NOT_CONFIGURED = 5,
    ST_NO_DATA        = 6,
    ST_INTERNAL       = 7,
};

enum pilyzer_trigger_mode { TRIG_FREE_RUN = 0, TRIG_AUTO = 1, TRIG_NORMAL = 2 };
enum pilyzer_slope        { SLOPE_RISING = 0, SLOPE_FALLING = 1 };

enum pilyzer_state {
    STATE_IDLE      = 0,
    STATE_FILLING   = 1,
    STATE_WAITING   = 2,
    STATE_POST      = 3,
    STATE_COMPLETE  = 4,
    STATE_ABORTED   = 5,
    STATE_OVERRUN   = 6,
};

// Capability flags.
#define CAP_SOFTWARE_RANGE     (1u << 0)
#define CAP_CALIBRATION_OUTPUT (1u << 1)
#define CAP_BUFFERED_LOGIC     (1u << 2)
#define CAP_TRIGGER_LOWPASS    (1u << 3)

#define PILYZER_HEADER_SIZE 12

typedef struct __attribute__((packed)) {
    uint8_t  magic;
    uint8_t  opcode;
    uint8_t  status;
    uint8_t  flags;
    uint16_t sequence;
    uint16_t reserved;
    uint32_t length;
} pilyzer_header_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t protocol_version;
    uint16_t firmware_version;
    uint32_t board_id;
    char     name[20];
} pilyzer_identity_t;

typedef struct __attribute__((packed)) {
    uint8_t  analog_channels;
    uint8_t  analog_bits;
    uint8_t  logic_channels;
    uint8_t  analog_ranges;
    uint32_t analog_clock_hz;
    uint32_t analog_min_period_cycles;
    uint32_t analog_max_record;
    uint32_t analog_max_pretrigger;
    uint32_t logic_clock_hz;
    uint32_t logic_max_record;
    uint32_t logic_max_pretrigger;
    uint32_t reference_microvolts;
    uint32_t flags;
    uint32_t reserved[2];
} pilyzer_capabilities_t;

typedef struct __attribute__((packed)) {
    uint8_t  channel_mask;
    uint8_t  trigger_mode;
    uint8_t  trigger_source;
    uint8_t  trigger_slope;
    uint16_t trigger_level;
    uint16_t trigger_hysteresis;
    uint64_t sample_period_fs;
    uint32_t record_samples;
    uint32_t pretrigger_samples;
    uint32_t auto_timeout_us;
    uint32_t trigger_lowpass_hz;  // 0 = off; capability-gated extension
} pilyzer_analog_config_t;

typedef struct __attribute__((packed)) {
    uint8_t  trigger_mode;
    uint8_t  trigger_channel;
    uint8_t  trigger_slope;
    uint8_t  reserved;
    uint64_t sample_period_fs;
    uint32_t record_samples;
    uint32_t pretrigger_samples;
    uint32_t auto_timeout_us;
} pilyzer_logic_config_t;

typedef struct __attribute__((packed)) {
    uint32_t clock_hz;
    uint32_t divisor_q8;
    uint32_t decimation;
    uint32_t record_samples;
    uint32_t pretrigger_samples;
    uint8_t  channel_mask;
    uint8_t  conversions_per_sample;
    uint16_t reserved;
} pilyzer_plan_t;

typedef struct __attribute__((packed)) {
    uint8_t  state;
    uint8_t  triggered;
    uint16_t reserved;
    uint32_t samples_available;
    uint32_t trigger_index;
    uint32_t reserved2;
} pilyzer_acq_status_t;

typedef struct __attribute__((packed)) {
    uint32_t offset;
    uint32_t count;
} pilyzer_read_request_t;

_Static_assert(sizeof(pilyzer_header_t)       == 12, "header layout");
_Static_assert(sizeof(pilyzer_identity_t)     == 32, "identity layout");
_Static_assert(sizeof(pilyzer_capabilities_t) == 48, "capabilities layout");
_Static_assert(sizeof(pilyzer_analog_config_t)== 32, "analog config layout");
_Static_assert(sizeof(pilyzer_logic_config_t) == 24, "logic config layout");
_Static_assert(sizeof(pilyzer_plan_t)         == 24, "plan layout");
_Static_assert(sizeof(pilyzer_acq_status_t)   == 16, "status layout");
