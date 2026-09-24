// The protocol end of the instrument: frames in, frames out, dispatched to the
// acquisition and the meter. Nothing here touches the board, so the same code
// runs on the Nano R4 and in the host simulator (ArLyzer/host).
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace instrument {

struct Board {
  void (*write)(const uint8_t *data, size_t length);
  // An immediate reading of all eight inputs, left-aligned into 16 bits.
  void (*sample)(uint16_t averages, uint16_t *readings);
  void (*led)(bool on);
};

void begin(const Board &board);
// One byte of the request stream. A stray byte before a frame's magic is
// dropped, so the parser finds the next frame on its own.
void receive(uint8_t byte);

}  // namespace instrument
