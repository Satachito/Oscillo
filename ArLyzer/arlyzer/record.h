// The acquisition's arithmetic and state, with no hardware in it: the plan a
// configuration gets, box-car decimation, the ring, the trigger and the auto
// timeout. The interrupt feeds it one scan at a time; tests feed it the same
// way on the host.
#pragma once
#include <stdint.h>
#include "protocol.h"

namespace record {

// Eight inputs, but seven on an UNO R4 WiFi: its core links in every UART it
// has, which leaves no room for an eight-input ring, and its eighth converter
// input would have been D13 with the LED on it.
#if defined(ARDUINO_UNOWIFIR4)
constexpr uint8_t kChannels = 7;
#else
constexpr uint8_t kChannels = 8;
#endif
// Conversions the ring holds: 1024 samples of each input with all of them on,
// and a record may use the whole ring: nothing is kept but the history in
// front of the trigger and the record itself.
constexpr uint32_t kMaxRecord = 1024;
constexpr uint32_t kBufferConversions = kMaxRecord * kChannels;
// The trigger's low-pass, as on the Pico (trigger_filter.h): one pole on the
// trigger input alone, the record untouched.
constexpr uint32_t kLowPassMinHz = 100;
constexpr uint32_t kLowPassMaxHz = 100000;

class Recorder {
 public:
  // The shortest tick is `baseCycles` plus `inputCycles` for each enabled
  // input, in clock cycles; `tickLimit` is the longest tick the timer counts.
  uint8_t configure(const wire::AnalogConfig &config, uint32_t clockHz, uint32_t baseCycles,
                    uint32_t inputCycles, uint32_t tickLimit, wire::AcquisitionPlan &plan);
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
  // The ring's memory, which the logic side records into while this one is
  // idle; `discard` then says nothing in it is this record's any more.
  uint8_t *storage() { return reinterpret_cast<uint8_t *>(ring_); }
  static constexpr uint32_t kStorageBytes = kBufferConversions * sizeof(uint16_t);
  void discard();

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

  // The trigger's low-pass: its weight for a new sample in 1/65536ths (zero
  // when off), how many samples it takes to settle from the first, and its
  // state, the filtered sample with 8 bits below the code. Integer, as it
  // runs in the timer interrupt.
  uint32_t lowPassWeight_ = 0, lowPassSettling_ = 0, lowPassRemaining_ = 0;
  int32_t lowPassState_ = 0;
  bool lowPassStarted_ = false;
};

}  // namespace record
