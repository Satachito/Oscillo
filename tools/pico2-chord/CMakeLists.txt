cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2)
set(PICO_PLATFORM rp2350)

include(pico_sdk_import.cmake)

project(chord C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(chord chord.cpp ../../firmware/pilyzer/chord_output.c)

target_link_libraries(chord
    pico_stdlib
    hardware_pwm
    hardware_clocks
)

pico_enable_stdio_usb(chord 1)
pico_enable_stdio_uart(chord 0)
pico_add_extra_outputs(chord)
