#include "record.h"

namespace record {

namespace {
bool active(uint8_t s) {
  return s == wire::ACQ_FILLING || s == wire::ACQ_WAITING || s == wire::ACQ_POST_TRIGGER;
}
}  // namespace

uint8_t Recorder::configure(const wire::AnalogConfig &config, uint32_t clockHz, uint32_t baseCycles,
                            uint32_t inputCycles, uint32_t tickLimit, wire::AcquisitionPlan &plan) {
  if (running()) return wire::ST_BUSY;
  if (config.channelMask == 0 || config.triggerMode > wire::TRIGGER_NORMAL || config.triggerSlope > 1)
    return wire::ST_BAD_ARGUMENT;
  // No trigger filter is claimed in the capabilities, so none can be asked for.
  if (config.lowPassHz != 0) return wire::ST_BAD_ARGUMENT;

  mask_ = config.channelMask & ((1u << kChannels) - 1);
  if (mask_ == 0) return wire::ST_BAD_ARGUMENT;
  slots_ = 0;
  for (uint8_t c = 0; c < kChannels; c++)
    if (mask_ & (1u << c)) slots_++;

  framesInRing_ = kBufferConversions / slots_;
  recordLength_ = config.recordLength == 0 ? 1 : config.recordLength;
  if (recordLength_ > framesInRing_) recordLength_ = framesInRing_;
  pretrigger_ = config.pretriggerLength < recordLength_ ? config.pretriggerLength : recordLength_ - 1;
  mode_ = config.triggerMode;
  triggerSlot_ = config.triggerSlot < slots_ ? config.triggerSlot : 0;
  falling_ = config.triggerSlope == 1;
  level_ = config.triggerLevel;
  hysteresis_ = config.triggerHysteresis;
  timeoutMs_ = (config.autoTimeoutMicroseconds + 999) / 1000;

  // The fastest tick these inputs allow, and as much box-car averaging as
  // fits in the period asked for: that is both the anti-alias filter and the
  // extra resolution on a slow sweep.
  const uint32_t floorCounts = baseCycles + slots_ * inputCycles;
  const double wanted = static_cast<double>(config.periodFemtoseconds) * 1e-15 * clockHz;
  const double factor = wanted / floorCounts;
  decimation_ = factor < 1 ? 1 : factor > 65535 ? 65535 : static_cast<uint32_t>(factor);
  double tick = wanted / decimation_;
  if (tick < floorCounts) tick = floorCounts;
  if (tick > tickLimit) tick = tickLimit;
  // A whole number of counts for each input, so the plan's divisor is exact.
  uint32_t counts = (static_cast<uint32_t>(tick + 0.5) + slots_ - 1) / slots_;
  if (counts * slots_ > tickLimit) counts = tickLimit / slots_;
  tickCounts_ = counts * slots_;

  plan.clockHz = clockHz;
  plan.divisorQ8 = counts * 256u;
  plan.decimation = decimation_;
  plan.recordLength = recordLength_;
  plan.pretriggerLength = pretrigger_;
  plan.channelMask = mask_;
  plan.conversionsPerSample = slots_;
  plan.reserved = 0;
  configured_ = true;
  state_ = wire::ACQ_IDLE;
  return wire::ST_OK;
}

void Recorder::arm(uint32_t nowMs) {
  for (uint8_t s = 0; s < slots_; s++) sums_[s] = 0;
  written_ = 0;
  recordStart_ = 0;
  writeSlot_ = 0;
  ticks_ = 0;
  triggered_ = false;
  edgeArmed_ = false;
  armedAt_ = nowMs;
  state_ = wire::ACQ_FILLING;
}

bool Recorder::scan(const uint16_t *codes) {
  if (!active(state_)) return false;
  for (uint8_t s = 0; s < slots_; s++) sums_[s] += codes[s];
  if (++ticks_ == decimation_) {
    ticks_ = 0;
    commit();
  }
  return active(state_);
}

// One decimated sample of every enabled input: into the ring, then the trigger.
void Recorder::commit() {
  uint16_t *frame = ring_ + writeSlot_ * slots_;
  for (uint8_t s = 0; s < slots_; s++) {
    // 14 bits left-aligned into 16, with the average's extra bits below them.
    const uint32_t value = sums_[s] * 4u / decimation_;
    frame[s] = value > 0xFFFF ? 0xFFFF : static_cast<uint16_t>(value);
    sums_[s] = 0;
  }
  const int32_t sample = frame[triggerSlot_];
  const uint32_t index = written_;
  written_ = index + 1;
  if (++writeSlot_ == framesInRing_) writeSlot_ = 0;

  switch (state_) {
    case wire::ACQ_FILLING:
      if (mode_ == wire::TRIGGER_FREE_RUN) {
        if (written_ >= recordLength_) {
          recordStart_ = written_ - recordLength_;
          triggered_ = false;
          finish();
        }
        return;
      }
      // Until `pretrigger` samples exist there is nothing to put in front of
      // an edge, so none is looked for.
      if (index < pretrigger_) return;
      state_ = wire::ACQ_WAITING;
      [[fallthrough]];
    case wire::ACQ_WAITING: {
      // Hysteresis: the signal has to be on the far side of the level by the
      // hysteresis before a crossing counts, so noise fires it once.
      const int32_t level = level_, margin = hysteresis_;
      bool fire = false;
      if (!falling_) {
        if (sample < level - margin) edgeArmed_ = true;
        else if (edgeArmed_ && sample >= level) fire = true;
      } else {
        if (sample > level + margin) edgeArmed_ = true;
        else if (edgeArmed_ && sample <= level) fire = true;
      }
      if (!fire) return;
      recordStart_ = index - pretrigger_;
      triggered_ = true;
      state_ = wire::ACQ_POST_TRIGGER;
      [[fallthrough]];
    }
    case wire::ACQ_POST_TRIGGER:
      if (written_ >= recordStart_ + recordLength_) finish();
      return;
    default:
      return;
  }
}

bool Recorder::expire(uint32_t nowMs) {
  if (mode_ != wire::TRIGGER_AUTO) return false;
  if (state_ != wire::ACQ_FILLING && state_ != wire::ACQ_WAITING) return false;
  if (nowMs - armedAt_ < timeoutMs_ || written_ < recordLength_) return false;
  // Nothing crossed in time: hand back the newest whole record, untriggered,
  // so the trace sweeps rather than freezing.
  recordStart_ = written_ - recordLength_;
  triggered_ = false;
  finish();
  return true;
}

void Recorder::abort() {
  if (active(state_)) state_ = wire::ACQ_ABORTED;
}

void Recorder::overrun() {
  if (active(state_)) state_ = wire::ACQ_OVERRUN;
}

bool Recorder::running() const { return active(state_); }

void Recorder::status(wire::AcquisitionStatus &out) const {
  out = {};
  out.state = state_;
  out.triggered = triggered_ ? 1 : 0;
  const uint32_t frames = written_;
  out.available = state_ == wire::ACQ_COMPLETE ? recordLength_
                                                : (frames < recordLength_ ? frames : recordLength_);
  out.triggerIndex = triggered_ ? pretrigger_ : 0;
}

uint8_t Recorder::checkRead(uint32_t offset, uint32_t count) const {
  if (state_ != wire::ACQ_COMPLETE) return wire::ST_NO_DATA;
  if (offset > recordLength_ || count > recordLength_ - offset) return wire::ST_BAD_ARGUMENT;
  if (count * slots_ * 2u > wire::kMaxPayload) return wire::ST_BAD_ARGUMENT;
  return wire::ST_OK;
}

uint32_t Recorder::contiguous(uint32_t offset, uint32_t count, const uint16_t **frames) const {
  const uint32_t slot = (recordStart_ + offset) % framesInRing_;
  *frames = ring_ + slot * slots_;
  const uint32_t run = framesInRing_ - slot;
  return count < run ? count : run;
}

}  // namespace record
