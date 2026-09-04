// A chord, over two octaves, on eight pins of a Pico 2 (RP2350).
//
// Eight voices, one per pin, so they can be mixed externally or probed one at
// a time. Change kChord below to play something else.
//
// Two waveforms, chosen by kWaveform below:
//
//   Square  A plain 50% PWM at the note frequency. Nothing else is needed:
//           the pin carries the note itself, so a scope or a piezo works
//           straight off the wire.
//
//   Sine    The RP2350 has no DAC, so each voice becomes a PWM carrier whose
//           duty cycle follows a sine table. A DMA channel feeds the table
//           into the PWM compare register, paced by that slice's own wrap
//           signal, and a second channel restarts the first, so a voice runs
//           forever without the CPU. Each pin then needs an RC low-pass
//           (1 kOhm + 100 nF) to turn the carrier back into a sine.

#include <cmath>
#include <cstdio>

#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/pwm.h"
#include "pico/stdlib.h"

namespace {

enum class Waveform { Square, Sine };

constexpr Waveform kWaveform = Waveform::Square;

// Sine only: samples per cycle. A power of two, so the DMA can ring on the
// table.
constexpr uint32_t kTableLength = 256;
constexpr uint32_t kTableBytes = kTableLength * sizeof(uint32_t);
constexpr uint32_t kRingBits = 10;  // 2^10 == kTableBytes

// How much of the PWM range the sine uses.
constexpr float kAmplitude = 0.98f;

// The root, and the pin the lowest voice comes out of.
constexpr float kRoot = 220.0f;   // A3

// The chord, as semitones above the root, then the same again an octave up.
// A7 is a dominant seventh: root, major third, fifth, minor seventh.
constexpr const char *kChord = "A7";
constexpr int kSemitones[] = {0, 4, 7, 10, 12, 16, 19, 22};
constexpr const char *kNames[] = {"A", "C#", "E", "G", "A+", "C#+", "E+", "G+"};

// Odd pins only: each is the B channel of its own PWM slice.
constexpr uint kPins[] = {1, 3, 5, 7, 9, 11, 13, 15};

// The board's green LED is on GPIO25 and is driven by firmware only — the
// Pico 2 has no separate power indicator — so blink it as a sign of life.
constexpr uint kLedPin = PICO_DEFAULT_LED_PIN;
constexpr size_t kVoiceCount = count_of(kPins);
static_assert(count_of(kSemitones) == kVoiceCount, "one interval per pin");
static_assert(count_of(kNames) == kVoiceCount, "one name per pin");

// Every pin is the B channel of its own slice, so no two voices share one. In
// sine mode each voice also claims a pair of DMA channels.
static_assert(kVoiceCount * 2 <= NUM_DMA_CHANNELS, "sine mode needs two DMA channels per voice");

struct Voice {
    uint pin;
    const char *name;
    uint slice;
    uint channel;
    float frequency;   // what the hardware actually produces
    float carrier;     // sine only: the PWM rate the table is clocked at
    uint16_t wrap;
    int data_channel = -1;
    int reload_channel = -1;
};

// Sine only. One table per voice, each aligned to its own size so the DMA's
// read-address ring wraps exactly at the end of the table.
alignas(kTableBytes) uint32_t g_tables[kVoiceCount][kTableLength];
const uint32_t *g_table_pointers[kVoiceCount];

Voice g_voices[kVoiceCount];

/// Programs a slice to run at `frequency`, using the fractional clock divider
/// when the period would not otherwise fit in the 16-bit counter. Returns the
/// frequency the hardware actually lands on.
float configure_slice(uint slice, float frequency, uint16_t *wrap_out) {
    const uint32_t system_clock = clock_get_hz(clk_sys);
    const float total = system_clock / frequency;

    // The divider is 8.4 fixed point: 1/16 steps, up to just under 256.
    uint32_t sixteenths = static_cast<uint32_t>(ceilf(total * 16.0f / 65536.0f));
    if (sixteenths < 16) sixteenths = 16;
    if (sixteenths > 4095) sixteenths = 4095;
    const float divider = sixteenths / 16.0f;

    uint32_t period = static_cast<uint32_t>(lroundf(total / divider));
    if (period < 2) period = 2;
    if (period > 65536) period = 65536;
    const uint16_t wrap = static_cast<uint16_t>(period - 1);
    *wrap_out = wrap;

    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, divider);
    pwm_config_set_wrap(&config, wrap);
    pwm_init(slice, &config, true);

    return system_clock / (period * divider);
}

void fill_table(uint32_t *table, uint16_t wrap, uint channel) {
    const float span = wrap * kAmplitude / 2.0f;
    const float middle = (wrap + 1) / 2.0f;
    const uint shift = (channel == PWM_CHAN_B) ? 16 : 0;
    for (uint32_t index = 0; index < kTableLength; ++index) {
        const float phase = 2.0f * static_cast<float>(M_PI) * index / kTableLength;
        float level = middle + span * sinf(phase);
        if (level < 0) level = 0;
        if (level > wrap) level = wrap;
        table[index] = static_cast<uint32_t>(lroundf(level)) << shift;
    }
}

void start_sine(Voice &voice, uint32_t *table, const uint32_t **pointer) {
    // One table entry per PWM period, so the carrier is the sample rate.
    voice.carrier = configure_slice(voice.slice, voice.frequency * kTableLength, &voice.wrap);
    voice.frequency = voice.carrier / kTableLength;

    fill_table(table, voice.wrap, voice.channel);
    *pointer = table;

    voice.data_channel = dma_claim_unused_channel(true);
    voice.reload_channel = dma_claim_unused_channel(true);

    // The reload channel writes the table address back into the data channel's
    // trigger register, which restarts it. Chaining it to itself means "no
    // chain", so the pair loops forever. Arm it first: the data channel chains
    // straight into it.
    dma_channel_config reload = dma_channel_get_default_config(voice.reload_channel);
    channel_config_set_transfer_data_size(&reload, DMA_SIZE_32);
    channel_config_set_read_increment(&reload, false);
    channel_config_set_write_increment(&reload, false);
    channel_config_set_chain_to(&reload, voice.reload_channel);
    dma_channel_configure(voice.reload_channel, &reload,
                          &dma_hw->ch[voice.data_channel].al3_read_addr_trig,
                          pointer, 1, false);

    // The data channel walks the table into the compare register, one entry per
    // PWM period, then hands over to the reload channel.
    dma_channel_config data = dma_channel_get_default_config(voice.data_channel);
    channel_config_set_transfer_data_size(&data, DMA_SIZE_32);
    channel_config_set_read_increment(&data, true);
    channel_config_set_write_increment(&data, false);
    channel_config_set_ring(&data, false, kRingBits);   // ring the read address
    channel_config_set_dreq(&data, pwm_get_dreq(voice.slice));
    channel_config_set_chain_to(&data, voice.reload_channel);
    dma_channel_configure(voice.data_channel, &data,
                          &pwm_hw->slice[voice.slice].cc,
                          table, kTableLength, true);
}

void start_square(Voice &voice) {
    voice.frequency = configure_slice(voice.slice, voice.frequency, &voice.wrap);
    voice.carrier = voice.frequency;
    pwm_set_chan_level(voice.slice, voice.channel, (voice.wrap + 1) / 2);
}

void start_voice(Voice &voice, uint32_t *table, const uint32_t **pointer) {
    voice.slice = pwm_gpio_to_slice_num(voice.pin);
    voice.channel = pwm_gpio_to_channel(voice.pin);
    gpio_set_function(voice.pin, GPIO_FUNC_PWM);

    if (kWaveform == Waveform::Sine) {
        start_sine(voice, table, pointer);
    } else {
        start_square(voice);
    }
}

/// Checks that a voice is really producing something. A square voice is proved
/// by its counter advancing; a sine voice by its compare register sweeping the
/// table, which only happens while the DMA is running.
bool is_running(const Voice &voice) {
    if (kWaveform == Waveform::Square) {
        const uint16_t first = pwm_get_counter(voice.slice);
        busy_wait_us(50);
        return pwm_get_counter(voice.slice) != first;
    }

    const uint shift = (voice.channel == PWM_CHAN_B) ? 16 : 0;
    uint16_t low = 0xFFFF;
    uint16_t high = 0;
    for (int sample = 0; sample < 400; ++sample) {
        const uint16_t level = static_cast<uint16_t>(pwm_hw->slice[voice.slice].cc >> shift);
        if (level < low) low = level;
        if (level > high) high = level;
        busy_wait_us(37);
    }
    return (high - low) > voice.wrap / 2;
}

}  // namespace

int main() {
    stdio_init_all();
    gpio_init(kLedPin);
    gpio_set_dir(kLedPin, GPIO_OUT);

    for (size_t index = 0; index < kVoiceCount; ++index) {
        g_voices[index].pin = kPins[index];
        g_voices[index].name = kNames[index];
        g_voices[index].frequency = kRoot * powf(2.0f, kSemitones[index] / 12.0f);
        start_voice(g_voices[index], g_tables[index], &g_table_pointers[index]);
    }

    while (true) {
        printf("%s over two octaves (%s), %u voices, system clock %lu Hz\n",
               kChord, kWaveform == Waveform::Square ? "square" : "sine",
               static_cast<unsigned>(kVoiceCount),
               static_cast<unsigned long>(clock_get_hz(clk_sys)));
        for (size_t index = 0; index < kVoiceCount; ++index) {
            const Voice &voice = g_voices[index];
            printf("  GPIO%-2u %-3s slice %u ch %c  %9.4f Hz  wrap %5u  %s\n",
                   voice.pin, voice.name, voice.slice,
                   voice.channel == PWM_CHAN_B ? 'B' : 'A',
                   static_cast<double>(voice.frequency), voice.wrap + 1,
                   is_running(voice) ? "running" : "STALLED");
        }
        // Five seconds of heartbeat before the next report.
        for (int blink = 0; blink < 10; ++blink) {
            gpio_put(kLedPin, blink % 2 == 0);
            sleep_ms(500);
        }
    }
}
