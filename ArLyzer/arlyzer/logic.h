// The logic side's record and trigger, with no hardware in it: the plan a
// configuration gets, the ring of one-byte samples, the edge trigger and the
// auto timeout. The interrupt feeds it one sample at a time — bit n is logic
// input Dn — and tests feed it the same way on the host.
//
// It records into memory it is handed rather than its own: the analogue
// record's ring, which sits idle while the logic side runs.
#pragma once
#include <stdint.h>
#include "protocol.h"

namespace logic {

constexpr uint8_t kChannels = 8;

class Recorder {
 public:
  void attach(uint8_t *ring, uint32_t capacity) {
    ring_ = ring;
    capacity_ = capacity;
  }
  uint32_t capacity() const { return capacity_; }

  // The shortest tick is `floorCounts` clock cycles; `tickLimit` is the
  // longest the timer counts. A period longer than that is reached by keeping
  // one tick in `decimation`.
  uint8_t configure(const wire::LogicConfig &config, uint32_t clockHz, uint32_t floorCounts,
                    uint32_t tickLimit, wire::AcquisitionPlan &plan);
  bool configured() const { return configured_; }
  uint32_t tickCounts() const { return tickCounts_; }

  void arm(uint32_t nowMs);
  // One tick's inputs. False once the recorder wants no more.
  bool sample(uint8_t bits);
  // The auto trigger giving up: true if that finished the record.
  bool expire(uint32_t nowMs);
  void abort();
  void overrun();
  // The ring was written by the other side: nothing in it is ours any more.
  void discard();

  bool running() const;
  void status(wire::AcquisitionStatus &out) const;
  uint8_t checkRead(uint32_t offset, uint32_t count) const;
  // Where samples `offset`, `offset + 1`… of the record are, and how many of
  // them sit next to each other before the ring wraps.
  uint32_t contiguous(uint32_t offset, uint32_t count, const uint8_t **samples) const;

 private:
  // What happens when the sample count reaches `nextEvent_`: the record
  // finishes, or the trigger search starts. Out of the way of the sample
  // path, which only counts towards it.
  bool event(uint32_t index, uint8_t previous, uint8_t bits);
  bool edge(uint32_t index, uint8_t previous, uint8_t bits);
  void finish() { state_ = wire::ACQ_COMPLETE; }

  uint8_t *ring_ = nullptr;
  uint32_t capacity_ = 0;

  bool configured_ = false;
  uint32_t recordLength_ = 0, pretrigger_ = 0;
  uint8_t mode_ = wire::TRIGGER_FREE_RUN, channel_ = 0;
  bool falling_ = false;
  uint32_t timeoutMs_ = 0, tickCounts_ = 0, decimation_ = 1;

  // Written by the interrupt, read from the main loop.
  volatile uint8_t state_ = wire::ACQ_IDLE;
  volatile uint32_t written_ = 0;      // samples committed since arm
  volatile uint32_t recordStart_ = 0;  // absolute sample the record begins at
  volatile bool triggered_ = false;
  uint32_t writeSlot_ = 0, ticks_ = 0, armedAt_ = 0;
  uint32_t nextEvent_ = 0;  // the sample count at which something happens
  bool waiting_ = false;    // looking for the edge on every sample
  uint8_t last_ = 0;
};

}  // namespace logic
