#include "acquisition.h"

#include <Arduino.h>
#include <FspTimer.h>

namespace acquisition {
namespace {

// The shortest tick: 10 µs, and 1.4 µs more for each enabled input — one input
// at 88 kSa/s, four at 64, eight at 47 kSa/s each. On a Nano R4 (2026-09-26)
// the shortest ticks that kept a 1 kHz square at 1000 Hz, with or without a
// trigger, were 9.5 µs with one input, 13 with four and 17.3 with eight —
// about 8.3 µs + 1.13 µs an input. This keeps a fifth in hand.
constexpr double kTickBaseSeconds = 10e-6;
constexpr double kTickPerInputSeconds = 1.4e-6;
constexpr uint8_t kTickPriority = 4;

FspTimer timer;
uint8_t timerType = GPT_TIMER;
uint32_t timerHz = 0;  // zero until a timer is running, which is what says it is

uint8_t converterChannel[kChannels];  // the inputs as ANxx numbers
uint8_t slotChannel[kChannels];       // the enabled ones, in slot order
uint8_t slotCount = 0;
bool primed = false;
uint32_t due = 0;           // DWT cycle count this tick should have come at
uint32_t tickCycles = 0;    // one tick, in CPU cycles

record::Recorder recorder;

// Every tick: take the scan the last tick started, then start the next. The
// converter works between ticks, so the interrupt never waits on it.
void onTick(timer_callback_args_t *) {
  const uint32_t now = DWT->CYCCNT;
  if (!recorder.running()) return;
  R_ADC0_Type *adc = R_ADC0;
  // Either the scan has not finished, or the interrupt has fallen behind the
  // timer. Its gaps can each look nearly right while it slips a little every
  // tick, until two ticks run into one and a sample is gone, so it is the
  // running total that is checked: half a tick behind is too far.
  if (primed) due += tickCycles; else due = now;
  if (adc->ADCSR_b.ADST || static_cast<int32_t>(now - due) > static_cast<int32_t>(tickCycles / 2)) {
    recorder.overrun();
    timer.stop();
    return;
  }
  // Take the last scan's results and start the next one before doing anything
  // with them: the converter then works while the record does, and a tick
  // only has to be as long as the slower of the two, not both end to end.
  uint16_t codes[kChannels];
  const bool previous = primed;
  if (previous)
    for (uint8_t s = 0; s < slotCount; s++) codes[s] = adc->ADDR[slotChannel[s]];
  primed = true;
  adc->ADCSR_b.ADST = 1;
  if (previous && !recorder.scan(codes)) timer.stop();
}

}  // namespace

bool begin(const uint8_t *pins) {
  for (uint8_t c = 0; c < kChannels; c++) {
    // analogRead opens the converter at its full resolution and puts the pin
    // in analogue mode; acquisition then drives the same converter directly.
    // By port and pin, so that D4 on an UNO is D4 and not A4.
    (void)analogRead(digitalPinToBspPin(pins[c]));
    converterChannel[c] = GET_CHANNEL(getPinCfgs(pins[c], PIN_CFG_REQ_ADC)[0]);
  }
  int8_t channel = FspTimer::get_available_timer(timerType);
  if (channel < 0) return false;
  if (!timer.begin(TIMER_MODE_PERIODIC, timerType, channel, 48000, 24000, TIMER_SOURCE_DIV_1, onTick))
    return false;
  // Above USB's 12: the core runs its USB interrupt at the same level the
  // timer gets by default, and a tick held up behind a reply arrives late —
  // tens of µs on a Nano R4, enough to find the next scan still running.
  if (!timer.setup_overflow_irq(kTickPriority) || !timer.open()) return false;
  timer.stop();
  timer.set_period_buffer(false);
  timerHz = timer.get_freq_hz();
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;  // the cycle counter the lost-tick check reads
  DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
  return timerHz > 0;
}

uint32_t clockHz() { return timerHz; }

// The rail was 5.22 V on the first Nano R4, 4.5 % above nominal, and 4.89 V on
// the first Minima, and it moves with the port and the cable. The chip's
// internal reference does not, so the rail is measured against it. Its value
// is each board's own, taken against the rail on a meter on 2026-09-26 (5.225 V
// on the Nano, 4.89 V on the Minima); another chip's differs by its own
// tolerance, which Calibrate in the applications then takes out once — and
// no longer has to be redone when the USB supply changes.
//
// Read it on its own, with the longest sampling time. Interleaved with a
// pin it read 8 % low, and at the shortest sampling time 6 % high.
#if defined(ARDUINO_MINIMA)
constexpr double kInternalReferenceVolts = 1.4414;
#else
constexpr double kInternalReferenceVolts = 1.4331;
#endif

uint32_t referenceMicrovolts() {
  static uint32_t measured = 5000000;
  if (recorder.running()) return measured;
  R_ADC0_Type *adc = R_ADC0;
  while (adc->ADCSR_b.ADST) {}
  const uint16_t low = adc->ADANSA[0], high = adc->ADANSA[1];
  adc->ADANSA[0] = 0;
  adc->ADANSA[1] = 0;
  adc->ADSSTRO = 0xFF;  // the reference wants the longest sampling time
  adc->ADEXICR_b.OCSA = 1;
  uint32_t total = 0;
  for (int i = 0; i < 256; i++) {
    adc->ADCSR_b.ADST = 1;
    while (adc->ADCSR_b.ADST) {}
    total += adc->ADOCDR;
  }
  adc->ADEXICR_b.OCSA = 0;
  adc->ADANSA[0] = low;
  adc->ADANSA[1] = high;
  if (total) measured = static_cast<uint32_t>(kInternalReferenceVolts * 16383.0 * 256 / total * 1e6 + 0.5);
  return measured;
}

// The protocol states the floor as so much a channel, but the real one has a
// fixed part as well. What it is told is the eight-input figure, so a host
// asks for everything eight inputs can do; with fewer inputs the plan comes
// back slower than asked, and the host draws from the plan.
uint32_t minPeriodCycles() {
  return static_cast<uint32_t>((kTickBaseSeconds / kChannels + kTickPerInputSeconds) * timerHz + 0.999);
}

bool running() { return recorder.running(); }

uint8_t conversionsPerSample() { return recorder.slots(); }

uint8_t configure(const wire::AnalogConfig &config, wire::AcquisitionPlan &plan) {
  if (timerHz == 0) return wire::ST_INTERNAL_ERROR;
  const uint32_t tickLimit = timerType == AGT_TIMER ? 0xFFFFu : 0xFFFFFFF0u;
  const uint32_t base = static_cast<uint32_t>(kTickBaseSeconds * timerHz + 0.5);
  const uint32_t perInput = static_cast<uint32_t>(kTickPerInputSeconds * timerHz + 0.5);
  const uint8_t status = recorder.configure(config, timerHz, base, perInput, tickLimit, plan);
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
  tickCycles = static_cast<uint32_t>(static_cast<uint64_t>(recorder.tickCounts()) * SystemCoreClock / timerHz);
  recorder.arm(millis());
  // GTPR holds the period less one; the AGT's own call takes the count.
  const uint32_t counts = recorder.tickCounts();
  timer.set_period(timerType == AGT_TIMER ? counts : counts - 1);
  // The first tick a whole period away: the counter from zero, and no cycle
  // end left pending from the last record.
  if (timerType == GPT_TIMER) {
    R_GPT0_Type *gpt = reinterpret_cast<R_GPT0_Type *>(
        R_GPT0_BASE + (R_GPT1_BASE - R_GPT0_BASE) * timer.get_channel());
    gpt->GTCNT = 0;
    gpt->GTST = 0;  // status flags clear by writing zero
  } else {
    timer.reset();
  }
  const IRQn_Type irq = timer.get_cfg()->cycle_end_irq;
  if (irq >= 0) {
    R_BSP_IrqStatusClear(irq);
    NVIC_ClearPendingIRQ(irq);
  }
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
