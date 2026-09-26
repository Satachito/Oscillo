// An ArLyzer on the Mac: the sketch's own protocol and record code
// (instrument.cpp, record.cpp) behind a pseudo-terminal, with the timer and the
// converter replaced by known signals. It prints the port to connect to, so the
// applications can be driven end to end without a Nano R4.
//
//   xcrun c++ -std=c++17 -O2 -I ../arlyzer ../arlyzer/instrument.cpp ../arlyzer/record.cpp simulator.cpp -o arlyzer-sim
//   ./arlyzer-sim                  # prints /dev/ttysNNN
//
// CH1 a 1 kHz sine, CH2 a 500 Hz square, CH3 a 250 Hz triangle, CH4–CH8 sines
// at 100–500 Hz, all about 2.5 V, with a little noise.
#include <fcntl.h>
#include <poll.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>

#include "acquisition.h"
#include "instrument.h"

namespace {

int master = -1;
std::mt19937 noise(1);

uint32_t millisNow() {
  using namespace std::chrono;
  return static_cast<uint32_t>(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

double volts(uint8_t channel, double t) {
  const double pi = 3.14159265358979;
  switch (channel) {
    case 0: return 2.5 + 1.5 * std::sin(2 * pi * 1000 * t);
    case 1: return std::fmod(t * 500, 1.0) < 0.5 ? 4.0 : 1.0;
    case 2: { const double phase = std::fmod(t * 250, 1.0); return 1.0 + 3.0 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase); }
    default: return 2.5 + 0.8 * std::sin(2 * pi * 100 * (channel - 2) * t);
  }
}

uint16_t code(double v) {
  v += std::normal_distribution<double>(0, 0.002)(noise);
  const double c = v / 5.0 * 16383;
  return static_cast<uint16_t>(c < 0 ? 0 : c > 16383 ? 16383 : c);
}

void writePort(const uint8_t *data, size_t length) {
  while (length > 0) {
    const ssize_t n = write(master, data, length);
    if (n > 0) { data += n; length -= n; }
    else { struct pollfd p{master, POLLOUT, 0}; poll(&p, 1, 10); }
  }
}

double meterTime = 0;
void sampleAll(uint16_t averages, uint16_t *readings) {
  if (averages == 0) averages = 1;
  for (uint8_t c = 0; c < acquisition::kChannels; c++) {
    uint32_t total = 0;
    for (uint16_t i = 0; i < averages; i++) total += code(volts(c, meterTime + i * 1e-5));
    readings[c] = static_cast<uint16_t>(static_cast<uint64_t>(total) * 4u / averages);
  }
  meterTime += 0.0137;
}

void setLED(bool) {}

}  // namespace

// The simulated half of acquisition.h: the same record::Recorder, fed by a clock
// instead of a timer interrupt.
namespace acquisition {
namespace {
constexpr uint32_t kClockHz = 48000000;
// The Nano R4's own floor: 10 µs and 1.4 µs an input, at 48 MHz.
constexpr uint32_t kBaseCycles = 480;
constexpr uint32_t kInputCycles = 67;
record::Recorder recorder;
uint8_t slotChannel[kChannels];
uint8_t slotCount = 0;
uint64_t ticksFed = 0;
std::chrono::steady_clock::time_point armedAt;
}  // namespace

bool begin(const uint8_t *) { return true; }
uint32_t clockHz() { return kClockHz; }
uint32_t referenceMicrovolts() { return 5000000; }
uint32_t minPeriodCycles() { return kBaseCycles / kChannels + kInputCycles + 1; }
bool running() { return recorder.running(); }
uint8_t conversionsPerSample() { return recorder.slots(); }

uint8_t configure(const wire::AnalogConfig &config, wire::AcquisitionPlan &plan) {
  const uint8_t status = recorder.configure(config, kClockHz, kBaseCycles, kInputCycles, 0xFFFFFFF0u, plan);
  if (status != wire::ST_OK) return status;
  slotCount = 0;
  for (uint8_t c = 0; c < kChannels; c++)
    if (recorder.mask() & (1u << c)) slotChannel[slotCount++] = c;
  return status;
}

uint8_t arm() {
  if (recorder.running()) return wire::ST_BUSY;
  if (!recorder.configured()) return wire::ST_NOT_CONFIGURED;
  recorder.arm(millisNow());
  ticksFed = 0;
  armedAt = std::chrono::steady_clock::now();
  return wire::ST_OK;
}

uint8_t abort() {
  recorder.abort();
  return wire::ST_OK;
}

// Feeds every tick that is due by the wall clock, each at its exact time.
void poll() {
  if (recorder.running()) {
    const double tick = static_cast<double>(recorder.tickCounts()) / kClockHz;
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - armedAt).count();
    const uint64_t due = static_cast<uint64_t>(elapsed / tick);
    uint16_t codes[kChannels];
    while (ticksFed < due && recorder.running()) {
      const double t = ticksFed * tick;
      for (uint8_t s = 0; s < slotCount; s++) codes[s] = code(volts(slotChannel[s], t));
      recorder.scan(codes);
      ticksFed++;
    }
  }
  recorder.expire(millisNow());
}

void status(wire::AcquisitionStatus &out) { recorder.status(out); }
uint8_t checkRead(uint32_t offset, uint32_t count) { return recorder.checkRead(offset, count); }
uint32_t contiguous(uint32_t offset, uint32_t count, const uint16_t **frames) {
  return recorder.contiguous(offset, count, frames);
}

}  // namespace acquisition

int main() {
  int slave = -1;
  if (openpty(&master, &slave, nullptr, nullptr, nullptr) != 0) { perror("openpty"); return 1; }
  struct termios raw;
  tcgetattr(slave, &raw);
  cfmakeraw(&raw);
  tcsetattr(slave, TCSANOW, &raw);
  std::printf("%s\n", ttyname(slave));
  std::fflush(stdout);

  instrument::begin({4, "ArLyzer Nano R4", sampleAll, setLED});
  instrument::Port port(writePort);
  uint8_t buffer[256];
  uint32_t lastByteMs = 0;
  for (;;) {
    struct pollfd p{master, POLLIN, 0};
    if (poll(&p, 1, 1) > 0) {
      const ssize_t n = read(master, buffer, sizeof buffer);
      for (ssize_t i = 0; i < n; i++) port.receive(buffer[i]);
      if (n > 0) lastByteMs = millisNow();
    }
    if (millisNow() - lastByteMs > 50) port.flush();  // as the sketch does
    acquisition::poll();
  }
}
