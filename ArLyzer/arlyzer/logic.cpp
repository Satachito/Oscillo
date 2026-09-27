#include "logic.h"

namespace logic {

namespace {
bool active(uint8_t s) {
  return s == wire::ACQ_FILLING || s == wire::ACQ_WAITING || s == wire::ACQ_POST_TRIGGER;
}
}  // namespace

uint8_t Recorder::configure(const wire::LogicConfig &config, uint32_t clockHz, uint32_t floorCounts,
                            uint32_t tickLimit, wire::AcquisitionPlan &plan) {
  if (running()) return wire::ST_BUSY;
  if (!ring_ || capacity_ < 2) return wire::ST_INTERNAL_ERROR;
  if (config.triggerMode > wire::TRIGGER_NORMAL || config.triggerChannel >= kChannels ||
      config.triggerSlope > 1)
    return wire::ST_BAD_ARGUMENT;

  recordLength_ = config.recordLength == 0 ? 1 : config.recordLength;
  if (recordLength_ > capacity_) recordLength_ = capacity_;
  pretrigger_ = config.pretriggerLength < recordLength_ ? config.pretriggerLength : recordLength_ - 1;
  mode_ = config.triggerMode;
  channel_ = config.triggerChannel;
  falling_ = config.triggerSlope == 1;
  timeoutMs_ = (config.autoTimeoutMicroseconds + 999) / 1000;

  // As fast as asked, down to the floor; a period longer than the timer can
  // count keeps one tick in several. Nothing is averaged: a logic level is a
  // level, and the sample kept is the one taken at its time.
  const double wanted = static_cast<double>(config.periodFemtoseconds) * 1e-15 * clockHz;
  double tick = wanted < floorCounts ? floorCounts : wanted;
  decimation_ = 1;
  while (tick / decimation_ > tickLimit && decimation_ < 65535) decimation_++;
  uint32_t counts = static_cast<uint32_t>(tick / decimation_ + 0.5);
  if (counts < floorCounts) counts = floorCounts;
  if (counts > tickLimit) counts = tickLimit;
  tickCounts_ = counts;

  plan.clockHz = clockHz;
  plan.divisorQ8 = counts * 256u;
  plan.decimation = decimation_;
  plan.recordLength = recordLength_;
  plan.pretriggerLength = pretrigger_;
  plan.channelMask = (1u << kChannels) - 1;
  plan.conversionsPerSample = 1;
  plan.reserved = 0;
  configured_ = true;
  state_ = wire::ACQ_IDLE;
  return wire::ST_OK;
}

void Recorder::arm(uint32_t nowMs) {
  written_ = 0;
  recordStart_ = 0;
  writeSlot_ = 0;
  ticks_ = 0;
  triggered_ = false;
  last_ = 0;
  waiting_ = false;
  // Free running, the record is done once it is full. Otherwise the search
  // starts once `pretrigger` samples exist to put in front of an edge — and
  // not on the first sample, which has nothing before it to be an edge from.
  nextEvent_ = mode_ == wire::TRIGGER_FREE_RUN ? recordLength_ : (pretrigger_ > 1 ? pretrigger_ : 1) + 1;
  armedAt_ = nowMs;
  state_ = wire::ACQ_FILLING;
}

// The interrupt's own path, run 250,000 times a second: into the ring, count,
// and look at the trigger line only while waiting for it. The rest waits for
// `nextEvent_`. Written as the several states it once switched between on
// every sample, this took 100 of the 200 cycles a tick has.
bool Recorder::sample(uint8_t bits) {
  if (decimation_ > 1) {
    if (++ticks_ != decimation_) return true;
    ticks_ = 0;
  }
  ring_[writeSlot_] = bits;
  if (++writeSlot_ == capacity_) writeSlot_ = 0;
  const uint32_t index = written_;
  written_ = index + 1;
  const uint8_t previous = last_;
  last_ = bits;
  if (waiting_) return edge(index, previous, bits);
  if (index + 1 < nextEvent_) return true;
  return event(index, previous, bits);
}

bool Recorder::event(uint32_t index, uint8_t previous, uint8_t bits) {
  if (state_ == wire::ACQ_FILLING && mode_ != wire::TRIGGER_FREE_RUN) {
    state_ = wire::ACQ_WAITING;
    waiting_ = true;
    return edge(index, previous, bits);  // this sample may be the edge already
  }
  if (state_ == wire::ACQ_FILLING) {
    recordStart_ = written_ - recordLength_;
    triggered_ = false;
  }
  finish();
  return false;
}

bool Recorder::edge(uint32_t index, uint8_t previous, uint8_t bits) {
  const uint8_t mask = 1u << channel_;
  if (!((previous ^ bits) & mask)) return true;
  if (((bits & mask) != 0) == falling_) return true;  // the other way
  // The sample the new level first appears in is the trigger.
  waiting_ = false;
  recordStart_ = index - pretrigger_;
  triggered_ = true;
  state_ = wire::ACQ_POST_TRIGGER;
  nextEvent_ = index - pretrigger_ + recordLength_;
  if (index + 1 < nextEvent_) return true;
  finish();
  return false;
}

bool Recorder::expire(uint32_t nowMs) {
  if (mode_ != wire::TRIGGER_AUTO) return false;
  if (state_ != wire::ACQ_FILLING && state_ != wire::ACQ_WAITING) return false;
  if (nowMs - armedAt_ < timeoutMs_ || written_ < recordLength_) return false;
  // Nothing changed in time: hand back the newest whole record, untriggered,
  // so the trace sweeps rather than freezing.
  recordStart_ = written_ - recordLength_;
  triggered_ = false;
  waiting_ = false;
  finish();
  return true;
}

void Recorder::abort() {
  waiting_ = false;
  if (active(state_)) state_ = wire::ACQ_ABORTED;
}

void Recorder::overrun() {
  waiting_ = false;
  if (active(state_)) state_ = wire::ACQ_OVERRUN;
}

void Recorder::discard() {
  if (!active(state_)) state_ = wire::ACQ_IDLE;
}

bool Recorder::running() const { return active(state_); }

void Recorder::status(wire::AcquisitionStatus &out) const {
  out = {};
  out.state = state_;
  out.triggered = triggered_ ? 1 : 0;
  const uint32_t samples = written_;
  out.available = state_ == wire::ACQ_COMPLETE ? recordLength_
                                                : (samples < recordLength_ ? samples : recordLength_);
  out.triggerIndex = triggered_ ? pretrigger_ : 0;
}

uint8_t Recorder::checkRead(uint32_t offset, uint32_t count) const {
  if (state_ != wire::ACQ_COMPLETE) return wire::ST_NO_DATA;
  if (offset > recordLength_ || count > recordLength_ - offset) return wire::ST_BAD_ARGUMENT;
  if (count > wire::kMaxPayload) return wire::ST_BAD_ARGUMENT;
  return wire::ST_OK;
}

uint32_t Recorder::contiguous(uint32_t offset, uint32_t count, const uint8_t **samples) const {
  const uint32_t slot = (recordStart_ + offset) % capacity_;
  *samples = ring_ + slot;
  const uint32_t run = capacity_ - slot;
  return count < run ? count : run;
}

}  // namespace logic
