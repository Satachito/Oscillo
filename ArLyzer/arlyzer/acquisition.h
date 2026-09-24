// Timed acquisition of up to eight inputs — the analogConfigure / analogArm /
// analogStatus / analogRead / analogAbort half of the protocol. This is the
// hardware: a timer and the converter. What they feed is record::Recorder.
#pragma once
#include <stdint.h>
#include "protocol.h"
#include "record.h"

namespace acquisition {

constexpr uint8_t kChannels = record::kChannels;
constexpr uint32_t kMaxRecord = record::kMaxRecord;

// Finds each pin's converter channel and claims a timer. False if no timer was free.
bool begin(const uint8_t *pins);

// The timer's clock, which is the base clock every plan is stated in.
uint32_t clockHz();
// The shortest time allowed for each enabled input within one sample, in
// clock cycles. Not the converter's conversion time: the interrupt that reads
// one scan and starts the next has to fit as well.
uint32_t minPeriodCycles();

bool running();
uint8_t configure(const wire::AnalogConfig &config, wire::AcquisitionPlan &plan);
uint8_t arm();
uint8_t abort();
void status(wire::AcquisitionStatus &out);
// The auto trigger's timeout is watched from the main loop, not the interrupt.
void poll();

uint8_t checkRead(uint32_t offset, uint32_t count);
uint8_t conversionsPerSample();
uint32_t contiguous(uint32_t offset, uint32_t count, const uint16_t **frames);

}  // namespace acquisition
