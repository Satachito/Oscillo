// Host tests for logic::Recorder — the logic side's plan, ring, edge trigger
// and auto timeout, fed sample by sample the way the timer interrupt feeds it.
//
//   xcrun c++ -std=c++17 -Wall -Wextra -I ../arlyzer ../arlyzer/logic.cpp logic_test.cpp -o logic_test && ./logic_test
#include <cmath>
#include <cstdio>
#include <vector>

#include "logic.h"

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
static constexpr uint32_t kFloor = 96;  // 2 µs at 48 MHz

static LogicConfig config(double periodSeconds, uint32_t record, uint32_t pre, uint8_t mode = TRIGGER_FREE_RUN,
                          uint8_t channel = 0, uint8_t slope = 0) {
  LogicConfig c{};
  c.triggerMode = mode;
  c.triggerChannel = channel;
  c.triggerSlope = slope;
  c.periodFemtoseconds = static_cast<uint64_t>(std::llround(periodSeconds * 1e15));
  c.recordLength = record;
  c.pretriggerLength = pre;
  c.autoTimeoutMicroseconds = 100000;
  return c;
}

static std::vector<uint8_t> readBack(const logic::Recorder &r, uint32_t count) {
  std::vector<uint8_t> out;
  uint32_t offset = 0;
  while (offset < count) {
    const uint8_t *samples;
    const uint32_t run = r.contiguous(offset, count - offset, &samples);
    out.insert(out.end(), samples, samples + run);
    offset += run;
  }
  return out;
}

static double planPeriod(const AcquisitionPlan &p) {
  return p.divisorQ8 / 256.0 / p.clockHz * p.conversionsPerSample * p.decimation;
}

static void planIsExactAndBounded() {
  static uint8_t ring[4096];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  // Faster than the floor: the floor.
  CHECK(r.configure(config(1e-7, 1000, 100), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  CHECK(std::fabs(planPeriod(plan) - 2e-6) < 1e-12);
  CHECK(plan.conversionsPerSample == 1 && plan.channelMask == 0xFF && plan.decimation == 1);
  // Longer than the ring: the ring.
  CHECK(r.configure(config(1e-5, 100000, 99999), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  CHECK(plan.recordLength == 4096 && plan.pretriggerLength == 4095);
  // A 16-bit timer reaches a second by keeping one tick in several.
  CHECK(r.configure(config(1.0, 100, 0), kClock, kFloor, 0xFFFF, plan) == ST_OK);
  CHECK(plan.decimation > 1 && plan.divisorQ8 / 256 <= 0xFFFF);
  CHECK(std::fabs(planPeriod(plan) - 1.0) < 1e-3);
  // A trigger channel or slope it does not have is refused.
  CHECK(r.configure(config(1e-5, 100, 0, TRIGGER_AUTO, 8), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_BAD_ARGUMENT);
  CHECK(r.configure(config(1e-5, 100, 0, TRIGGER_AUTO, 0, 2), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_BAD_ARGUMENT);
}

static void freeRunKeepsTheLastRecord() {
  static uint8_t ring[256];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  CHECK(r.configure(config(2e-6, 100, 0), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  r.arm(0);
  uint32_t fed = 0;
  while (r.sample(static_cast<uint8_t>(fed))) fed++;
  fed++;
  CHECK(fed == 100);
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && s.available == 100 && !s.triggered);
  const auto got = readBack(r, 100);
  for (uint32_t i = 0; i < 100; i++) CHECK(got[i] == static_cast<uint8_t>(i));
}

// Line 3 low for a while, then high: the record puts the first high sample at
// the trigger index, with the pre-trigger history in front of it.
static void edgeTrigger(uint8_t slope) {
  static uint8_t ring[256];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  CHECK(r.configure(config(2e-6, 64, 16, TRIGGER_NORMAL, 3, slope), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  r.arm(0);
  const uint8_t before = slope ? 0x08 : 0x00, after = slope ? 0x00 : 0x08;
  // 700 samples before the edge: the ring (256) goes round more than twice.
  uint32_t n = 0;
  for (; n < 700; n++) CHECK(r.sample(before | static_cast<uint8_t>(n & 1)));
  bool more = true;
  for (uint32_t k = 0; more && k < 1000; k++, n++) more = r.sample(after | static_cast<uint8_t>(n & 1));
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && s.triggered && s.triggerIndex == 16 && s.available == 64);
  const auto got = readBack(r, 64);
  for (uint32_t i = 0; i < 64; i++) CHECK((got[i] & 0x08) == (i < 16 ? before : after));
  // The other bits are the samples as they came: bit 0 alternates.
  for (uint32_t i = 1; i < 64; i++) CHECK((got[i] & 1) != (got[i - 1] & 1));
}

// A line high from the first sample has not risen: there is nothing before it.
static void aLineAlreadyHighIsNotAnEdge() {
  static uint8_t ring[128];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  CHECK(r.configure(config(2e-6, 32, 0, TRIGGER_NORMAL, 0, 0), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  r.arm(0);
  for (int i = 0; i < 500; i++) CHECK(r.sample(0x01));
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_WAITING);
}

static void autoTimesOutWithTheNewestRecord() {
  static uint8_t ring[128];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  CHECK(r.configure(config(2e-6, 50, 10, TRIGGER_AUTO, 0, 0), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  r.arm(1000);
  for (uint32_t i = 0; i < 300; i++) CHECK(r.sample(static_cast<uint8_t>(i << 1)));  // bit 0 never rises
  CHECK(!r.expire(1050));  // 100 ms timeout not yet up
  CHECK(r.expire(1101));
  AcquisitionStatus s;
  r.status(s);
  CHECK(s.state == ACQ_COMPLETE && !s.triggered);
  const auto got = readBack(r, 50);
  for (uint32_t i = 0; i < 50; i++) CHECK(got[i] == static_cast<uint8_t>((250 + i) << 1));
}

static void readsAreChecked() {
  static uint8_t ring[128];
  logic::Recorder r;
  r.attach(ring, sizeof ring);
  AcquisitionPlan plan;
  CHECK(r.configure(config(2e-6, 100, 0), kClock, kFloor, 0xFFFFFFF0u, plan) == ST_OK);
  CHECK(r.checkRead(0, 10) == ST_NO_DATA);
  r.arm(0);
  while (r.sample(0)) {}
  CHECK(r.checkRead(0, 100) == ST_OK);
  CHECK(r.checkRead(50, 51) == ST_BAD_ARGUMENT);
  r.discard();
  CHECK(r.checkRead(0, 10) == ST_NO_DATA);
}

int main() {
  planIsExactAndBounded();
  freeRunKeepsTheLastRecord();
  edgeTrigger(0);
  edgeTrigger(1);
  aLineAlreadyHighIsNotAnEdge();
  autoTimesOutWithTheNewestRecord();
  readsAreChecked();
  if (failures) {
    std::printf("%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("all logic tests passed\n");
  return 0;
}
