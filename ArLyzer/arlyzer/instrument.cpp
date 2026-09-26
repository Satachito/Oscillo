#include "instrument.h"

#include <string.h>

#include "acquisition.h"
#include "protocol.h"

using namespace wire;

namespace instrument {
namespace {

constexpr uint16_t kFirmwareVersion = 0x0005;  // 0.5: the Minima and the WiFi, several ports, lost bytes survived
constexpr uint8_t kChannels = acquisition::kChannels;
constexpr uint8_t kBits = 14;

Board io;

void sendHeader(Write write, const Header &req, uint8_t status, uint32_t length) {
  Header h{};
  h.magic = kResponseMagic;
  h.opcode = req.opcode;
  h.status = status;
  h.sequence = req.sequence;
  h.length = length;
  write(reinterpret_cast<const uint8_t *>(&h), sizeof h);
}

void respond(Write write, const Header &req, uint8_t status, const void *data, uint32_t length) {
  sendHeader(write, req, status, length);
  if (length) write(static_cast<const uint8_t *>(data), length);
}

// A finished record, straight out of the ring: at most two runs, one either
// side of where it wraps.
void sendRecord(Write write, const Header &req, uint32_t offset, uint32_t count) {
  const uint32_t frameBytes = acquisition::conversionsPerSample() * 2u;
  sendHeader(write, req, ST_OK, count * frameBytes);
  while (count > 0) {
    const uint16_t *frames;
    const uint32_t run = acquisition::contiguous(offset, count, &frames);
    write(reinterpret_cast<const uint8_t *>(frames), run * frameBytes);
    offset += run;
    count -= run;
  }
}

void dispatch(Write write, const Header &req, const uint8_t *data, uint32_t length) {
  switch (req.opcode) {
    case OP_IDENTIFY: {
      Identity id{};
      id.magic = kIdentityMagic;
      id.protocolVersion = kProtocolVersion;
      id.firmwareVersion = kFirmwareVersion;
      id.boardId = io.id;
      const size_t n = strlen(io.name);
      memcpy(id.name, io.name, n < sizeof id.name ? n : sizeof id.name);
      respond(write, req, ST_OK, &id, sizeof id);
      return;
    }
    case OP_CAPABILITIES: {
      Capabilities caps{};
      caps.analogChannels = kChannels;
      caps.analogBits = kBits;
      caps.analogRanges = 1;
      caps.analogClockHz = acquisition::clockHz();
      caps.analogMinPeriodCycles = acquisition::minPeriodCycles();
      caps.analogMaxRecord = acquisition::kMaxRecord;
      caps.analogMaxPretrigger = acquisition::kMaxRecord - 1;
      caps.referenceMicrovolts = acquisition::referenceMicrovolts();
      caps.flags = CAP_REPORTS_RANGES;
      respond(write, req, ST_OK, &caps, sizeof caps);
      return;
    }
    case OP_INPUT_RANGES: {
      InputRange range{};
      range.gainMicro = 1000000;
      memcpy(range.name, "0 – 5 V", strlen("0 – 5 V"));
      respond(write, req, ST_OK, &range, sizeof range);
      return;
    }
    case OP_SET_LED:
      if (length < 1) { respond(write, req, ST_BAD_LENGTH, nullptr, 0); return; }
      io.led(data[0] != 0);
      respond(write, req, ST_OK, nullptr, 0);
      return;
    case OP_SET_RANGE:
      if (length < 2) { respond(write, req, ST_BAD_LENGTH, nullptr, 0); return; }
      respond(write, req, data[0] < kChannels && data[1] == 0 ? ST_OK : ST_BAD_ARGUMENT, nullptr, 0);
      return;
    case OP_ANALOG_CONFIGURE: {
      if (length < sizeof(AnalogConfig)) { respond(write, req, ST_BAD_LENGTH, nullptr, 0); return; }
      AnalogConfig config;
      memcpy(&config, data, sizeof config);
      AcquisitionPlan plan;
      const uint8_t status = acquisition::configure(config, plan);
      respond(write, req, status, &plan, status == ST_OK ? sizeof plan : 0);
      return;
    }
    case OP_ANALOG_ARM:
      respond(write, req, acquisition::arm(), nullptr, 0);
      return;
    case OP_ANALOG_STATUS: {
      AcquisitionStatus status;
      acquisition::status(status);
      respond(write, req, ST_OK, &status, sizeof status);
      return;
    }
    case OP_ANALOG_READ: {
      if (length < sizeof(ReadRequest)) { respond(write, req, ST_BAD_LENGTH, nullptr, 0); return; }
      ReadRequest read;
      memcpy(&read, data, sizeof read);
      const uint8_t status = acquisition::checkRead(read.offset, read.count);
      if (status != ST_OK) { respond(write, req, status, nullptr, 0); return; }
      sendRecord(write, req, read.offset, read.count);
      return;
    }
    case OP_ANALOG_ABORT:
      respond(write, req, acquisition::abort(), nullptr, 0);
      return;
    case OP_LOGIC_ABORT:
      respond(write, req, ST_OK, nullptr, 0);  // there is no logic analyser to stop
      return;
    case OP_ANALOG_SAMPLE: {
      // The immediate reading shares the converter with the record.
      if (acquisition::running()) { respond(write, req, ST_BUSY, nullptr, 0); return; }
      uint16_t averages = 1;
      if (length >= 2) memcpy(&averages, data, sizeof averages);
      uint16_t readings[kChannels];
      io.sample(averages, readings);
      respond(write, req, ST_OK, readings, sizeof readings);
      return;
    }
    default:
      respond(write, req, ST_UNKNOWN_OPCODE, nullptr, 0);
      return;
  }
}

}  // namespace

void begin(const Board &board) { io = board; }

void Port::receive(uint8_t byte) {
  uint8_t *raw = reinterpret_cast<uint8_t *>(&request_);
  if (headerFill_ < sizeof request_) {
    if (headerFill_ == 0 && byte != kRequestMagic) return;
    raw[headerFill_++] = byte;
    if (headerFill_ < sizeof request_) return;
    payloadFill_ = 0;
    // A length no request has is most likely a header that lost a byte on the
    // way — a UART can drop one — and waiting for that many bytes would take
    // every request after it as payload. Answer it now and look for the next.
    if (request_.length == 0 || request_.length > kMaxRequest) {
      if (request_.length == 0) dispatch(write_, request_, payload_, 0);
      else respond(write_, request_, ST_BAD_LENGTH, nullptr, 0);
      headerFill_ = 0;
    }
    return;
  }
  payload_[payloadFill_] = byte;
  if (++payloadFill_ < request_.length) return;
  dispatch(write_, request_, payload_, request_.length);
  headerFill_ = 0;
}

}  // namespace instrument
