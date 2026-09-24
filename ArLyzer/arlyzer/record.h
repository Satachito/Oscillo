// The acquisition's arithmetic and state, with no hardware in it: the plan a
// configuration gets, box-car decimation, the ring, the trigger and the auto
// timeout. The interrupt feeds it one scan at a time; tests feed it the same
// way on the host.
#pragma once
#include <stdint.h>
#include "protocol.h"

namespace record {

constexpr uint8_t kChannels = 8;
// Conversions the ring holds. With all eight inputs on that is 1024 samples
// each, and a record may use the whole ring: nothing is kept but the history in
// front of the trigger and the record itself.
constexpr uint32_t kBufferConversions = 8192;
constexpr uint32_t kMaxRecord = kBufferConversions / kChannels;

class Recorder {
 public:
  // `slotCycles` is the shortest time each enabled input may take within one
  // tick, in clock cycles; `tickLimit` the longest tick the timer can count.
  uint8_t configure(const wire::AnalogConfig &config, uint32_t clockHz, uint32_t slotCycles,
                    uint32_t tickLimit, wire::AcquisitionPlan &plan);
  bool configured() const { return configured_; }
  uint8_t slots() const { return slots_; }
  uint8_t mask() const { return mask_; }
  uint32_t tickCounts() const { return tickCounts_; }

  void arm(uint32_t nowMs);
  // One scan of the enabled inputs, in slot order, as the converter's 14-bit
  // codes. False once the recorder wants no more.
  bool scan(const uint16_t *codes);
  // The auto trigger giving up: true if that finished the record.
  bool expire(uint32_t nowMs);
  void abort();
  void overrun();

  bool running() const;
  void status(wire::AcquisitionStatus &out) const;
  uint8_t checkRead(uint32_t offset, uint32_t count) const;
  // Where frames `offset`, `offset + 1`… of the record are, and how many of
  // them sit next to each other before the ring wraps.
  uint32_t contiguous(uint32_t offset, uint32_t count, const uint16_t **frames) const;

 private:
  void commit();
  void finish() { state_ = wire::ACQ_COMPLETE; }

  uint16_t ring_[kBufferConversions];

  bool configured_ = false;
  uint8_t mask_ = 0, slots_ = 0;
  uint32_t framesInRing_ = 0, recordLength_ = 0, pretrigger_ = 0;
  uint8_t mode_ = wire::TRIGGER_FREE_RUN, triggerSlot_ = 0;
  bool falling_ = false;
  uint16_t level_ = 0, hysteresis_ = 0;
  uint32_t timeoutMs_ = 0, tickCounts_ = 0, decimation_ = 1;

  // Written by the interrupt, read from the main loop.
  volatile uint8_t state_ = wire::ACQ_IDLE;
  volatile uint32_t written_ = 0;      // frames committed since arm
  volatile uint32_t recordStart_ = 0;  // absolute frame the record begins at
  volatile bool triggered_ = false;
  uint32_t writeSlot_ = 0, ticks_ = 0, armedAt_ = 0;
  bool edgeArmed_ = false;
  uint32_t sums_[kChannels] = {};
};

}  // namespace record
