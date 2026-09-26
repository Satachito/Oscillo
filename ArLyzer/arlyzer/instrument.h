// The protocol end of the instrument: frames in, frames out, dispatched to the
// acquisition and the meter. Nothing here touches the board, so the same code
// runs on every board and in the host simulator (ArLyzer/host).
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

namespace instrument {

using Write = void (*)(const uint8_t *data, size_t length);

struct Board {
  uint32_t id;       // the board id identify reports (protocol.md)
  const char *name;  // at most 20 bytes
  // An immediate reading of every input, left-aligned into 16 bits.
  void (*sample)(uint16_t averages, uint16_t *readings);
  void (*led)(bool on);
};

void begin(const Board &board);

// The longest request in protocol v1 is 32 bytes.
constexpr uint32_t kMaxRequest = 64;

// One stream that requests arrive on and replies go back out of. A board may
// answer on more than one — the UNO R4 WiFi on its USB port and over its
// radio — and each keeps its own half-received frame.
class Port {
 public:
  explicit Port(Write write) : write_(write) {}
  // One byte of the request stream. A stray byte before a frame's magic is
  // dropped, so the parser finds the next frame on its own.
  void receive(uint8_t byte);
  // Drops a frame that stopped arriving part way, so a lost byte costs one
  // request rather than every one after it.
  void flush() { headerFill_ = 0; }

 private:
  Write write_;
  wire::Header request_{};
  uint8_t payload_[kMaxRequest];
  size_t headerFill_ = 0;
  uint32_t payloadFill_ = 0;
};

}  // namespace instrument
