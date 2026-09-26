// Host tests for record::Recorder — the acquisition's arithmetic, trigger and
// ring, fed scan by scan the way the timer interrupt feeds it on the board.
//
//   xcrun c++ -std=c++17 -Wall -Wextra -I ../arlyzer ../arlyzer/record.cpp record_test.cpp -o record_test && ./record_test
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "record.h"

using namespace wire;

static int failures = 0;
#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::printf("%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition); \
      failures++;                                                          \
    }                                                                      \
  } while (0)

static constexpr uint32_t kClock = 48000000;
static constexpr uint32_t kSlot = 480;  // 10 µs at 48 MHz

static AnalogConfig config(uint8_t mask, double periodSeconds, uint32_t record, uint32_t pre,
                           uint8_t mode = TRIGGER_FREE_RUN) {
  AnalogConfig c{};
  c.channelMask = mask;
  c.triggerMode = mode;
  c.periodFemtoseconds = static_cast<uint64_t>(std::llround(periodSeconds * 1e15));
  c.recordLength = record;
  c.pretriggerLength = pre;
  c.autoTimeoutMicroseconds = 100000;
  return c;
}

static double planPeriod(const AcquisitionPlan &p) {
  return p.divisorQ8 / 256.0 / p.clockHz * p.conversionsPerSample * p.decimation;
}

// Reads the whole record back through contiguous(), as sendRecord does.
static std::vector<uint16_t> readBack(const record::Recorder &r, uint32_t count) {
  std::vector<uint16_t> out;
  uint32_t offset = 0;
  while (offset < count) {
    const uint16_t *frames;
    const uint32_t run = r.contiguous(offset, count - offset, &frames);
    out.insert(out.end(), frames, frames + run * r.slots());
    offset += run;
  }
  return out;
}

static void planTakesTheSlowestTickAndAveragesTheRest() {
  static record::Recorder r;
  AcquisitionPlan p;
  CHECK(r.configure(config(0xFF, 1e-3, 1000, 0), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(p.conversionsPerSample == 8);
  CHECK(p.decimation == 12);  // 48000 counts wanted, 3840 the fastest: 12 fit
  CHECK(r.tickCounts() % 8 == 0);
  CHECK(std::fabs(planPeriod(p) - 1e-3) < 1e-9);
  CHECK(p.recordLength == 1000);
}

static void aPeriodTooShortGetsTheFloor() {
  static record::Recorder r;
  AcquisitionPlan p;
  CHECK(r.configure(config(0x01, 1e-6, 500, 0), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(p.decimation == 1);
  CHECK(r.tickCounts() == kSlot);
  CHECK(std::fabs(planPeriod(p) - 10e-6) < 1e-12);
}

// A fixed part and so much an input, as the board has it.
static void theFloorHasAFixedPartAndOneAnInput() {
  static record::Recorder r;
  AcquisitionPlan p;
  CHECK(r.configure(config(0x01, 1e-6, 500, 0), kClock, 312, 48, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(r.tickCounts() == 360);  // 312 + 48: 7.5 µs with one input
  CHECK(r.configure(config(0xFF, 1e-6, 500, 0), kClock, 312, 48, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(r.tickCounts() == 696);  // 312 + 8 x 48: 14.5 µs with eight
  CHECK(std::fabs(planPeriod(p) - 14.5e-6) < 1e-12);
}

static void recordsAreClampedToTheRing() {
  static record::Recorder r;
  AcquisitionPlan p;
  CHECK(r.configure(config(0xFF, 1e-3, 5000, 4000), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(p.recordLength == record::kMaxRecord);
  CHECK(p.pretriggerLength == record::kMaxRecord - 1);
  CHECK(r.configure(config(0x01, 1e-3, 5000, 10), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_OK);
  CHECK(p.recordLength == 5000);
}

static void badConfigurationsAreRefused() {
  static record::Recorder r;
  AcquisitionPlan p;
  CHECK(r.configure(config(0x00, 1e-3, 100, 0), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_BAD_ARGUMENT);
  AnalogConfig filtered = config(0x01, 1e-3, 100, 0);
  filtered.lowPassHz = 1000;
  CHECK(r.configure(filtered, kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_BAD_ARGUMENT);
  CHECK(r.configure(config(0x01, 1e-3, 100, 0, 3), kClock, 0, kSlot, 0xFFFFFFF0u, p) == ST_BAD_ARGUMENT);
}

static void freeRunFillsARecordAndLeftAligns() {
  static record::Recorder r;
  AcquisitionPlan p;
  r.configure(config(0x05, 50e-6, 100, 0), kClock, 0, kSlot, 0xFFFFFFF0u, p);
  r.arm(0);
  uint32_t scans = 0;
  for (uint16_t i = 0; r.running(); i++, scans++) {
    const uint16_t codes[2] = {i, static_cast<uint16_t>(16383 - i)};
    r.scan(codes);
  }
  CHECK(scans == 100u * p.decimation);
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && !s.triggered && s.available == 100);
  const auto samples = readBack(r, 100);
  CHECK(samples.size() == 200);
  // Frame k averages scans k*D … k*D + D-1 of a ramp.
  const double first = (p.decimation - 1) / 2.0 * 4;
  CHECK(std::fabs(samples[0] - first) <= 4);
  CHECK(std::fabs(samples[1] - (16383 * 4 - first)) <= 4);
}

// A step on the source channel, after a long quiet stretch that wraps the ring.
static void aRisingEdgeLandsAtThePretriggerIndex() {
  static record::Recorder r;
  AcquisitionPlan p;
  AnalogConfig c = config(0xFF, 10e-6 * 8, 300, 60, TRIGGER_NORMAL);
  c.triggerSlot = 3;
  c.triggerLevel = 8000 * 4;
  c.triggerHysteresis = 100;
  r.configure(c, kClock, 0, kSlot, 0xFFFFFFF0u, p);
  CHECK(p.decimation == 1);
  r.arm(0);
  uint32_t frame = 0;
  while (r.running()) {
    uint16_t codes[8];
    for (int s = 0; s < 8; s++) codes[s] = static_cast<uint16_t>(s * 100);
    codes[3] = frame < 3000 ? 1000 : 12000;
    r.scan(codes);
    frame++;
  }
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && s.triggered && s.triggerIndex == 60);
  const auto samples = readBack(r, 300);
  CHECK(samples[59 * 8 + 3] == 1000 * 4);
  CHECK(samples[60 * 8 + 3] == 12000 * 4);
  CHECK(samples[60 * 8 + 5] == 500 * 4);  // the other inputs ride along in slot order
  // The record straddles the ring's end, so it comes back in two runs.
  const uint16_t *frames;
  CHECK(r.contiguous(0, 300, &frames) < 300);
}

static void hysteresisIgnoresNoiseAtTheLevel() {
  static record::Recorder r;
  AcquisitionPlan p;
  AnalogConfig c = config(0x01, 10e-6, 50, 10, TRIGGER_NORMAL);
  c.triggerLevel = 8000 * 4;
  c.triggerHysteresis = 400;
  r.configure(c, kClock, 0, kSlot, 0xFFFFFFF0u, p);
  r.arm(0);
  for (int i = 0; i < 2000; i++) {
    const uint16_t code = i % 2 ? 8010 : 7990;  // 80 counts either side, inside the hysteresis
    r.scan(&code);
  }
  CHECK(r.running());
  for (int i = 0; i < 5 && r.running(); i++) {
    const uint16_t low = 7800;
    r.scan(&low);
  }
  const uint16_t high = 8100;
  r.scan(&high);
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_POST_TRIGGER && s.triggered);
}

static void aFallingEdgeFires() {
  static record::Recorder r;
  AcquisitionPlan p;
  AnalogConfig c = config(0x01, 10e-6, 20, 5, TRIGGER_NORMAL);
  c.triggerSlope = 1;
  c.triggerLevel = 8000 * 4;
  r.configure(c, kClock, 0, kSlot, 0xFFFFFFF0u, p);
  r.arm(0);
  int frame = 0;
  while (r.running()) {
    const uint16_t code = frame++ < 40 ? 12000 : 2000;
    r.scan(&code);
  }
  const auto samples = readBack(r, 20);
  CHECK(samples[4] == 12000 * 4 && samples[5] == 2000 * 4);
}

static void autoHandsBackTheNewestRecordWhenNothingCrosses() {
  static record::Recorder r;
  AcquisitionPlan p;
  AnalogConfig c = config(0x01, 10e-6, 100, 10, TRIGGER_AUTO);
  c.triggerLevel = 60000;
  r.configure(c, kClock, 0, kSlot, 0xFFFFFFF0u, p);
  r.arm(1000);
  for (uint16_t i = 0; i < 250; i++) r.scan(&i);
  CHECK(!r.expire(1050));  // not yet
  CHECK(r.expire(1100));
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && !s.triggered);
  const auto samples = readBack(r, 100);
  CHECK(samples[0] == 150 * 4 && samples[99] == 249 * 4);
}

static void normalModeWaitsForever() {
  static record::Recorder r;
  AcquisitionPlan p;
  AnalogConfig c = config(0x01, 10e-6, 100, 10, TRIGGER_NORMAL);
  c.triggerLevel = 60000;
  r.configure(c, kClock, 0, kSlot, 0xFFFFFFF0u, p);
  r.arm(0);
  for (uint16_t i = 0; i < 500; i++) r.scan(&i);
  CHECK(!r.expire(1000000));
  CHECK(r.running());
  r.abort();
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_ABORTED);
}

static void readsAreChecked() {
  static record::Recorder r;
  AcquisitionPlan p;
  r.configure(config(0xFF, 10e-6 * 8, 1024, 0), kClock, 0, kSlot, 0xFFFFFFF0u, p);
  CHECK(r.checkRead(0, 10) == ST_NO_DATA);
  r.arm(0);
  AcquisitionPlan busy;
  CHECK(r.configure(config(0x01, 1e-3, 10, 0), kClock, 0, kSlot, 0xFFFFFFF0u, busy) == ST_BUSY);
  uint16_t codes[8] = {};
  while (r.running()) r.scan(codes);
  CHECK(r.checkRead(0, 512) == ST_OK);       // 8192 bytes, the most one reply holds
  CHECK(r.checkRead(0, 513) == ST_BAD_ARGUMENT);
  CHECK(r.checkRead(1000, 25) == ST_BAD_ARGUMENT);
}

int main() {
  planTakesTheSlowestTickAndAveragesTheRest();
  aPeriodTooShortGetsTheFloor();
  theFloorHasAFixedPartAndOneAnInput();
  recordsAreClampedToTheRing();
  badConfigurationsAreRefused();
  freeRunFillsARecordAndLeftAligns();
  aRisingEdgeLandsAtThePretriggerIndex();
  hysteresisIgnoresNoiseAtTheLevel();
  aFallingEdgeFires();
  autoHandsBackTheNewestRecordWhenNothingCrosses();
  normalModeWaitsForever();
  readsAreChecked();
  if (failures) {
    std::printf("%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("all record tests passed\n");
  return 0;
}
