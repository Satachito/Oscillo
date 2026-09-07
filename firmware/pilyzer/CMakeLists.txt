cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2)
set(PICO_PLATFORM rp2350)
include(pico_sdk_import.cmake)

project(pilyzer C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

# Which board the firmware is going onto: 0 is a bare Pico 2 with the inputs
# straight on the converter pins, 1 is the analogue front end. It is what the
# host reads to know which input ranges exist.
set(PILYZER_BOARD_ID 0 CACHE STRING "0 = bare Pico 2, 1 = PiLyzer analogue front end")

add_executable(pilyzer
    main.c
    analog.c
    chord_output.c
    logic.c
    usb_descriptors.c
)

pico_generate_pio_header(pilyzer ${CMAKE_CURRENT_LIST_DIR}/logic_capture.pio)

target_compile_options(pilyzer PRIVATE -Wall -Wextra)
target_compile_definitions(pilyzer PRIVATE PILYZER_BOARD_ID=${PILYZER_BOARD_ID})
target_include_directories(pilyzer PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(pilyzer PRIVATE
    pico_stdlib
    pico_unique_id
    hardware_adc
    hardware_dma
    hardware_pio
    hardware_pwm
    tinyusb_device
)

# The instrument owns the USB port; stdio must not fight it for the link.
pico_enable_stdio_usb(pilyzer 0)
pico_enable_stdio_uart(pilyzer 0)
pico_add_extra_outputs(pilyzer)
