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
// The logic side's shortest tick: 6 µs, 167 kSa/s. Its interrupt reads two
// port registers, looks the eight lines up in two tables and records the
// byte, about 240 cycles with the way in and out (2026-09-27, UNO R4 WiFi).
// At 5 µs that left the UART too little time and requests lost bytes while a
// record was being taken; 5.5 µs held. This keeps a tenth in hand.
constexpr double kLogicTickSeconds = 6e-6;
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
logic::Recorder logicRecorder;

// Which side the timer is feeding. The two never run at once: they share the
// timer, and the logic side records into the analogue ring.
enum class Side : uint8_t { analog, logic };
volatile Side side = Side::analog;

// The logic inputs, D2–D9 on every board, as the port registers they are
// read from — ports 1 and 3 on all three R4s. Each port's bits are turned
// into logic bits by a table: testing the eight lines one at a time took 158
// cycles a sample, most of the 2 µs budget, where two lookups take a tenth.
constexpr uint8_t kMaxPorts = 2;
constexpr uint32_t kTableBytes = 512 + 64;  // the WiFi's nine-bit span on port 1, and room for another
R_PORT0_Type *logicPort[kMaxPorts];
uint8_t logicPortCount = 0;
uint8_t portShift[kMaxPorts];
uint16_t portMask[kMaxPorts];
uint8_t *portTable[kMaxPorts];
uint8_t tables[kTableBytes];
uint8_t logicPin[logic::kChannels];
// Analogue inputs that are logic inputs too — D4 and D5 on the Minima — and
// so have to be put back into analogue mode before the converter scans them.
bsp_io_port_pin_t sharedPin[kChannels];
uint8_t sharedCount = 0;

void onLogicTick(uint32_t now) {
  if (!logicRecorder.running()) return;
  if (primed) due += tickCycles; else due = now;
  primed = true;
  // A tick is only lost once the interrupt runs a whole tick late: the timer
  // holds one event pending, and a second merges with it. So seven eighths of
  // one is late but whole. Half, as the analogue side allows, turned ticks of
  // 4 to 6 µs into overruns while every sample was there: the main loop's
  // short stretches with interrupts off delay a tick by up to 3.7 µs.
  if (static_cast<int32_t>(now - due) > static_cast<int32_t>(tickCycles - tickCycles / 8)) {
    logicRecorder.overrun();
    timer.stop();
    return;
  }
  // Both ports first, then the tables, so the lines are read as nearly
  // together as the registers allow.
  const uint16_t first = logicPort[0]->PIDR;
  const uint16_t second = logicPortCount > 1 ? logicPort[1]->PIDR : 0;
  uint8_t bits = portTable[0][(first >> portShift[0]) & portMask[0]];
  if (logicPortCount > 1) bits |= portTable[1][(second >> portShift[1]) & portMask[1]];
  if (!logicRecorder.sample(bits)) timer.stop();
}

// Every tick: take the scan the last tick started, then start the next. The
// converter works between ticks, so the interrupt never waits on it.
IRQn_Type tickIrq = static_cast<IRQn_Type>(-1);

void onTick(timer_callback_args_t *) {
  const uint32_t now = DWT->CYCCNT;
  if (side == Side::logic) {
    onLogicTick(now);
    return;
  }
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

// The timer's interrupt, straight from the vector table. Through FSP's own
// handler and FspTimer's callback it cost about 5 µs a tick before any of it
// was ours, which capped the logic side below 100 kSa/s. All the event needs
// is its flag cleared in the interrupt controller.
void tickVector() {
  R_ICU->IELSR_b[tickIrq].IR = 0;
  onTick(nullptr);
}

// Starts the timer with its first tick a whole period away: the counter from
// zero, and no cycle end left pending from the last record.
void startTimer(uint32_t counts) {
  primed = false;
  tickCycles = static_cast<uint32_t>(static_cast<uint64_t>(counts) * SystemCoreClock / timerHz);
  // GTPR holds the period less one; the AGT's own call takes the count.
  timer.set_period(timerType == AGT_TIMER ? counts : counts - 1);
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
}

uint32_t tickLimit() { return timerType == AGT_TIMER ? 0xFFFFu : 0xFFFFFFF0u; }
uint32_t logicFloorCounts() { return static_cast<uint32_t>(kLogicTickSeconds * timerHz + 0.5); }

}  // namespace

bool begin(const uint8_t *pins, const uint8_t *logicPins) {
  logicRecorder.attach(recorder.storage(), record::Recorder::kStorageBytes);
  uint8_t lineSlot[logic::kChannels], lineBit[logic::kChannels];
  uint8_t low[kMaxPorts] = {15, 15}, high[kMaxPorts] = {0, 0};
  for (uint8_t i = 0; i < logic::kChannels; i++) {
    logicPin[i] = logicPins[i];
    const bsp_io_port_pin_t bsp = digitalPinToBspPin(logicPins[i]);
    R_PORT0_Type *port = reinterpret_cast<R_PORT0_Type *>(IOPORT_PRV_PORT_ADDRESS(bsp >> 8));
    uint8_t slot = 0;
    while (slot < logicPortCount && logicPort[slot] != port) slot++;
    if (slot == logicPortCount) {
      if (logicPortCount == kMaxPorts) return false;
      logicPort[logicPortCount++] = port;
    }
    lineSlot[i] = slot;
    lineBit[i] = bsp & 0xFF;
    if (lineBit[i] < low[slot]) low[slot] = lineBit[i];
    if (lineBit[i] > high[slot]) high[slot] = lineBit[i];
    for (uint8_t c = 0; c < kChannels; c++)
      if (digitalPinToBspPin(pins[c]) == bsp) sharedPin[sharedCount++] = bsp;
  }
  // One table a port, indexed by the span of its bits that carry lines.
  uint32_t used = 0;
  for (uint8_t p = 0; p < logicPortCount; p++) {
    const uint32_t entries = 1u << (high[p] - low[p] + 1);
    if (used + entries > kTableBytes) return false;
    portShift[p] = low[p];
    portMask[p] = static_cast<uint16_t>(entries - 1);
    portTable[p] = tables + used;
    for (uint32_t value = 0; value < entries; value++) {
      uint8_t bits = 0;
      for (uint8_t i = 0; i < logic::kChannels; i++)
        if (lineSlot[i] == p && (value >> (lineBit[i] - low[p])) & 1) bits |= 1u << i;
      portTable[p][value] = bits;
    }
    used += entries;
  }
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
  // The core keeps the vector table in RAM (IRQManager writes it), so the
  // timer's entry can point at tickVector instead of FSP's handler.
  tickIrq = timer.get_cfg()->cycle_end_irq;
  if (tickIrq < 0) return false;
  reinterpret_cast<volatile uint32_t *>(SCB->VTOR)[16 + tickIrq] = reinterpret_cast<uint32_t>(&tickVector);
  __DSB();
  timer.set_period_buffer(false);
  timerHz = timer.get_freq_hz();
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;  // the cycle counter the lost-tick check reads
  DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
  return timerHz > 0;
}

// The nominal rate. The timer runs from the chip's on-chip oscillator (HOCO),
// which is untrimmed and good to ±1 %, and none of these boards carries a
// crystal to hold it to — the WiFi's RTC falls back to the low-speed on-chip
// oscillator for the same reason. The Nano R4 and the Minima read a 1 kHz
// square as 1000.1 Hz; the first WiFi read it as 1001.9 Hz, its HOCO 0.19 %
// slow (2026-09-26). That was left as it is rather than corrected for one
// board: the time axis and every frequency on it carry the oscillator's own
// error.
uint32_t clockHz() { return timerHz; }

// The rail was 5.22 V on the first Nano R4, 4.5 % above nominal, 4.89 V on the
// first Minima and 4.81 V on the first WiFi, and it moves with the port and the
// cable. The chip's internal reference does not, so the rail is measured
// against it. Its value is each board's own, taken against the rail on a meter
// on 2026-09-26; another chip's differs by its own tolerance, which Calibrate
// in the applications then takes out once — and no longer has to be redone
// when the USB supply changes.
//
// Read it on its own, with the longest sampling time. Interleaved with a
// pin it read 8 % low, and at the shortest sampling time 6 % high.
#if defined(ARDUINO_MINIMA)
constexpr double kInternalReferenceVolts = 1.4414;
#elif defined(ARDUINO_UNOWIFIR4)
constexpr double kInternalReferenceVolts = 1.4352;
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
  if (logicRecorder.running()) return wire::ST_BUSY;
  const uint32_t base = static_cast<uint32_t>(kTickBaseSeconds * timerHz + 0.5);
  const uint32_t perInput = static_cast<uint32_t>(kTickPerInputSeconds * timerHz + 0.5);
  const uint8_t status = recorder.configure(config, timerHz, base, perInput, tickLimit(), plan);
  if (status != wire::ST_OK) return status;
  slotCount = 0;
  for (uint8_t c = 0; c < kChannels; c++)
    if (recorder.mask() & (1u << c)) slotChannel[slotCount++] = converterChannel[c];
  return wire::ST_OK;
}

uint8_t arm() {
  if (recorder.running() || logicRecorder.running()) return wire::ST_BUSY;
  if (!recorder.configured()) return wire::ST_NOT_CONFIGURED;
  timer.stop();
  side = Side::analog;
  logicRecorder.discard();  // its samples were in this ring
  for (uint8_t i = 0; i < sharedCount; i++) R_IOPORT_PinCfg(&g_ioport_ctrl, sharedPin[i], IOPORT_CFG_ANALOG_ENABLE);
  while (R_ADC0->ADCSR_b.ADST) {}
  // Scan only the enabled inputs. analogRead puts its own selection back the
  // next time the meter asks.
  uint32_t bits = 0;
  for (uint8_t s = 0; s < slotCount; s++) bits |= 1u << slotChannel[s];
  R_ADC0->ADANSA[0] = static_cast<uint16_t>(bits);
  R_ADC0->ADANSA[1] = static_cast<uint16_t>(bits >> 16);
  recorder.arm(millis());
  startTimer(recorder.tickCounts());
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

// Interrupts go off only around the check itself, and only while there is a
// record to check: the loop runs this all the time, and a tick that lands in
// the gap waits for it.
void poll() {
  const uint32_t now = millis();
  if (recorder.running()) {
    noInterrupts();
    if (recorder.expire(now)) timer.stop();
    interrupts();
  }
  if (logicRecorder.running()) {
    noInterrupts();
    if (logicRecorder.expire(now)) timer.stop();
    interrupts();
  }
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

namespace acquisition {

// The fastest the logic side samples, which is what the capabilities call its
// clock: a host offers no rate above it.
uint32_t logicClockHz() { return timerHz ? timerHz / logicFloorCounts() : 0; }
uint32_t logicMaxRecord() { return logicRecorder.capacity(); }
bool logicRunning() { return logicRecorder.running(); }

uint8_t logicConfigure(const wire::LogicConfig &config, wire::AcquisitionPlan &plan) {
  if (timerHz == 0) return wire::ST_INTERNAL_ERROR;
  if (recorder.running()) return wire::ST_BUSY;
  return logicRecorder.configure(config, timerHz, logicFloorCounts(), tickLimit(), plan);
}

uint8_t logicArm() {
  if (recorder.running() || logicRecorder.running()) return wire::ST_BUSY;
  if (!logicRecorder.configured()) return wire::ST_NOT_CONFIGURED;
  timer.stop();
  // The meter leaves shared pins in analogue mode, where they read as zero.
  for (uint8_t i = 0; i < logic::kChannels; i++) pinMode(logicPin[i], INPUT);
  recorder.discard();  // the logic samples go into its ring
  side = Side::logic;
  logicRecorder.arm(millis());
  startTimer(logicRecorder.tickCounts());
  return wire::ST_OK;
}

uint8_t logicAbort() {
  noInterrupts();
  if (logicRecorder.running()) {
    timer.stop();
    logicRecorder.abort();
  }
  interrupts();
  return wire::ST_OK;
}

void logicStatus(wire::AcquisitionStatus &out) {
  noInterrupts();
  logicRecorder.status(out);
  interrupts();
}

uint8_t logicCheckRead(uint32_t offset, uint32_t count) { return logicRecorder.checkRead(offset, count); }

uint32_t logicContiguous(uint32_t offset, uint32_t count, const uint8_t **samples) {
  return logicRecorder.contiguous(offset, count, samples);
}

}  // namespace acquisition
