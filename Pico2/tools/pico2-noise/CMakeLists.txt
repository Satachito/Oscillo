cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2)
set(PICO_PLATFORM rp2350)

include(pico_sdk_import.cmake)

project(noise C CXX ASM)
set(CMAKE_C_STANDARD 11)

pico_sdk_init()

# The generator itself lives with the instrument firmware, which emits the
# same four signals: one copy, one set of tests, no drift.
add_executable(noise noise.c ../../firmware/pilyzer/signal_source.c)
target_include_directories(noise PRIVATE ../../firmware/pilyzer)

target_link_libraries(noise
    pico_stdlib
    hardware_pwm
    hardware_clocks
)

pico_enable_stdio_usb(noise 1)
pico_enable_stdio_uart(noise 0)
pico_add_extra_outputs(noise)
