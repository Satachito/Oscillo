#include "instrument.h"

#include <string.h>

#include "acquisition.h"
#include "protocol.h"

using namespace wire;

namespace instrument {
namespace {

constexpr uint16_t kFirmwareVersion = 0x0002;  // 0.2
constexpr uint32_t kBoardId = 4;
constexpr uint8_t kChannels = acquisition::kChannels;
constexpr uint8_t kBits = 14;
// The RA4M1 runs on 5 V here and the default reference is its own supply, so
// this is only as good as the USB 5 V it came from.
constexpr uint32_t kReferenceMicrovolts = 5000000;
constexpr uint32_t kMaxRequest = 64;  // the longest request in protocol v1 is 32

Board io;
Header request;
uint8_t payload[kMaxRequest];
size_t headerFill = 0;
uint32_t payloadFill = 0;

void sendHeader(const Header &req, uint8_t status, uint32_t length) {
  Header h{};
  h.magic = kResponseMagic;
  h.opcode = req.opcode;
  h.status = status;
  h.sequence = req.sequence;
  h.length = length;
  io.write(reinterpret_cast<const uint8_t *>(&h), sizeof h);
}

void respond(const Header &req, uint8_t status, const void *data, uint32_t length) {
  sendHeader(req, status, length);
  if (length) io.write(static_cast<const uint8_t *>(data), length);
}

// A finished record, straight out of the ring: at most two runs, one either
// side of where it wraps.
void sendRecord(const Header &req, uint32_t offset, uint32_t count) {
  const uint32_t frameBytes = acquisition::conversionsPerSample() * 2u;
  sendHeader(req, ST_OK, count * frameBytes);
  while (count > 0) {
    const uint16_t *frames;
    const uint32_t run = acquisition::contiguous(offset, count, &frames);
    io.write(reinterpret_cast<const uint8_t *>(frames), run * frameBytes);
    offset += run;
    count -= run;
  }
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
      caps.analogClockHz = acquisition::clockHz();
      caps.analogMinPeriodCycles = acquisition::minPeriodCycles();
      caps.analogMaxRecord = acquisition::kMaxRecord;
      caps.analogMaxPretrigger = acquisition::kMaxRecord - 1;
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
      io.led(data[0] != 0);
      respond(req, ST_OK, nullptr, 0);
      return;
    case OP_SET_RANGE:
      if (length < 2) { respond(req, ST_BAD_LENGTH, nullptr, 0); return; }
      respond(req, data[0] < kChannels && data[1] == 0 ? ST_OK : ST_BAD_ARGUMENT, nullptr, 0);
      return;
    case OP_ANALOG_CONFIGURE: {
      if (length < sizeof(AnalogConfig)) { respond(req, ST_BAD_LENGTH, nullptr, 0); return; }
      AnalogConfig config;
      memcpy(&config, data, sizeof config);
      AcquisitionPlan plan;
      const uint8_t status = acquisition::configure(config, plan);
      respond(req, status, &plan, status == ST_OK ? sizeof plan : 0);
      return;
    }
    case OP_ANALOG_ARM:
      respond(req, acquisition::arm(), nullptr, 0);
      return;
    case OP_ANALOG_STATUS: {
      AcquisitionStatus status;
      acquisition::status(status);
      respond(req, ST_OK, &status, sizeof status);
      return;
    }
    case OP_ANALOG_READ: {
      if (length < sizeof(ReadRequest)) { respond(req, ST_BAD_LENGTH, nullptr, 0); return; }
      ReadRequest read;
      memcpy(&read, data, sizeof read);
      const uint8_t status = acquisition::checkRead(read.offset, read.count);
      if (status != ST_OK) { respond(req, status, nullptr, 0); return; }
      sendRecord(req, read.offset, read.count);
      return;
    }
    case OP_ANALOG_ABORT:
      respond(req, acquisition::abort(), nullptr, 0);
      return;
    case OP_LOGIC_ABORT:
      respond(req, ST_OK, nullptr, 0);  // there is no logic analyser to stop
      return;
    case OP_ANALOG_SAMPLE: {
      // The immediate reading shares the converter with the record.
      if (acquisition::running()) { respond(req, ST_BUSY, nullptr, 0); return; }
      uint16_t averages = 1;
      if (length >= 2) memcpy(&averages, data, sizeof averages);
      uint16_t readings[kChannels];
      io.sample(averages, readings);
      respond(req, ST_OK, readings, sizeof readings);
      return;
    }
    default:
      respond(req, ST_UNKNOWN_OPCODE, nullptr, 0);
      return;
  }
}

}  // namespace

void begin(const Board &board) { io = board; }

void receive(uint8_t byte) {
  uint8_t *raw = reinterpret_cast<uint8_t *>(&request);
  if (headerFill < sizeof request) {
    if (headerFill == 0 && byte != kRequestMagic) return;
    raw[headerFill++] = byte;
    if (headerFill < sizeof request) return;
    payloadFill = 0;
    if (request.length == 0) {
      dispatch(request, payload, 0);
      headerFill = 0;
    }
    return;
  }
  if (payloadFill < kMaxRequest) payload[payloadFill] = byte;
  if (++payloadFill < request.length) return;
  if (request.length > kMaxRequest) respond(request, ST_BAD_LENGTH, nullptr, 0);
  else dispatch(request, payload, request.length);
  headerFill = 0;
}

}  // namespace instrument
