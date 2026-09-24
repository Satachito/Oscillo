#include "acquisition.h"

#include <Arduino.h>
#include <FspTimer.h>

namespace acquisition {
namespace {

// 10 µs for each enabled input: a placeholder until the board is measured.
// One input then samples at 100 kSa/s and eight at 12.5 kSa/s each.
constexpr double kMinSlotSeconds = 10e-6;

FspTimer timer;
uint8_t timerType = GPT_TIMER;
uint32_t timerHz = 0;  // zero until a timer is running, which is what says it is

uint8_t converterChannel[kChannels];  // A0–A7 as ANxx numbers
uint8_t slotChannel[kChannels];       // the enabled ones, in slot order
uint8_t slotCount = 0;
bool primed = false;

record::Recorder recorder;

// Every tick: take the scan the last tick started, then start the next. The
// converter works between ticks, so the interrupt never waits on it.
void onTick(timer_callback_args_t *) {
  if (!recorder.running()) return;
  R_ADC0_Type *adc = R_ADC0;
  if (adc->ADCSR_b.ADST) {
    // The scan has not finished: the ticks are too close for it.
    recorder.overrun();
    timer.stop();
    return;
  }
  if (primed) {
    uint16_t codes[kChannels];
    for (uint8_t s = 0; s < slotCount; s++) codes[s] = adc->ADDR[slotChannel[s]];
    if (!recorder.scan(codes)) {
      timer.stop();
      return;
    }
  }
  primed = true;
  adc->ADCSR_b.ADST = 1;
}

}  // namespace

bool begin(const uint8_t *pins) {
  for (uint8_t c = 0; c < kChannels; c++) {
    // analogRead opens the converter at its full resolution and puts the pin
    // in analogue mode; acquisition then drives the same converter directly.
    (void)analogRead(pins[c]);
    converterChannel[c] = GET_CHANNEL(getPinCfgs(pins[c], PIN_CFG_REQ_ADC)[0]);
  }
  int8_t channel = FspTimer::get_available_timer(timerType);
  if (channel < 0) return false;
  if (!timer.begin(TIMER_MODE_PERIODIC, timerType, channel, 48000, 24000, TIMER_SOURCE_DIV_1, onTick))
    return false;
  if (!timer.setup_overflow_irq() || !timer.open()) return false;
  timer.stop();
  timer.set_period_buffer(false);
  timerHz = timer.get_freq_hz();
  return timerHz > 0;
}

uint32_t clockHz() { return timerHz; }

uint32_t minPeriodCycles() {
  return static_cast<uint32_t>(kMinSlotSeconds * timerHz + 0.5);
}

bool running() { return recorder.running(); }

uint8_t conversionsPerSample() { return recorder.slots(); }

uint8_t configure(const wire::AnalogConfig &config, wire::AcquisitionPlan &plan) {
  if (timerHz == 0) return wire::ST_INTERNAL_ERROR;
  const uint32_t tickLimit = timerType == AGT_TIMER ? 0xFFFFu : 0xFFFFFFF0u;
  const uint8_t status = recorder.configure(config, timerHz, minPeriodCycles(), tickLimit, plan);
  if (status != wire::ST_OK) return status;
  slotCount = 0;
  for (uint8_t c = 0; c < kChannels; c++)
    if (recorder.mask() & (1u << c)) slotChannel[slotCount++] = converterChannel[c];
  return wire::ST_OK;
}

uint8_t arm() {
  if (recorder.running()) return wire::ST_BUSY;
  if (!recorder.configured()) return wire::ST_NOT_CONFIGURED;
  timer.stop();
  while (R_ADC0->ADCSR_b.ADST) {}
  // Scan only the enabled inputs. analogRead puts its own selection back the
  // next time the meter asks.
  uint32_t bits = 0;
  for (uint8_t s = 0; s < slotCount; s++) bits |= 1u << slotChannel[s];
  R_ADC0->ADANSA[0] = static_cast<uint16_t>(bits);
  R_ADC0->ADANSA[1] = static_cast<uint16_t>(bits >> 16);
  primed = false;
  recorder.arm(millis());
  // GTPR holds the period less one; the AGT's own call takes the count.
  const uint32_t counts = recorder.tickCounts();
  timer.set_period(timerType == AGT_TIMER ? counts : counts - 1);
  timer.reset();
  timer.start();
  return wire::ST_OK;
}

uint8_t abort() {
  noInterrupts();
  if (recorder.running()) {
    timer.stop();
    recorder.abort();
  }
  interrupts();
  return wire::ST_OK;
}

void poll() {
  noInterrupts();
  if (recorder.expire(millis())) timer.stop();
  interrupts();
}

void status(wire::AcquisitionStatus &out) {
  noInterrupts();
  recorder.status(out);
  interrupts();
}

uint8_t checkRead(uint32_t offset, uint32_t count) { return recorder.checkRead(offset, count); }

uint32_t contiguous(uint32_t offset, uint32_t count, const uint16_t **frames) {
  return recorder.contiguous(offset, count, frames);
}

}  // namespace acquisition
