cmake_minimum_required(VERSION 3.13)

# A Pico 2 W joins a network and hands out the front panel itself, which is the
# only way onto an iPhone: Safari has no WebUSB anywhere. Everything else is
# identical, and the pin map already avoids the pins the radio takes.
option(PILYZER_WIFI "Serve the browser application over Wi-Fi (needs a Pico 2 W)" OFF)
if(PILYZER_WIFI)
    set(PICO_BOARD pico2_w)
else()
    set(PICO_BOARD pico2)
endif()
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
    logic.c
    signals.c
    signal_source.c
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

if(PILYZER_WIFI)
    set(PILYZER_WIFI_SSID "" CACHE STRING "Network the instrument joins")
    set(PILYZER_WIFI_PASSWORD "" CACHE STRING "Its password")
    set(PILYZER_HOSTNAME "pilyzer" CACHE STRING "The name it answers to, as <name>.local")
    if(PILYZER_WIFI_SSID STREQUAL "")
        message(FATAL_ERROR "PILYZER_WIFI needs -DPILYZER_WIFI_SSID=... and -DPILYZER_WIFI_PASSWORD=...")
    endif()

    # The browser application, gzipped into flash. Regenerated whenever the
    # built application changes, so the firmware cannot serve a stale panel.
    set(WEB_DIST ${CMAKE_CURRENT_LIST_DIR}/../../Web/dist)
    file(GLOB_RECURSE WEB_SOURCES CONFIGURE_DEPENDS ${WEB_DIST}/*)
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/web_files.h
        COMMAND ${CMAKE_COMMAND} -E echo "Baking the browser application into flash"
        COMMAND python3 ${CMAKE_CURRENT_LIST_DIR}/bake-web.py ${WEB_DIST} ${CMAKE_CURRENT_BINARY_DIR}/web_files.h
        DEPENDS ${WEB_SOURCES} ${CMAKE_CURRENT_LIST_DIR}/bake-web.py
        COMMENT "bake-web.py")
    add_custom_target(pilyzer_web DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/web_files.h)
    add_dependencies(pilyzer pilyzer_web)

    target_sources(pilyzer PRIVATE http_request.c http_server.c wifi.c)
    target_include_directories(pilyzer PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
    target_compile_definitions(pilyzer PRIVATE
        PILYZER_WIFI=1
        PILYZER_WIFI_SSID="${PILYZER_WIFI_SSID}"
        PILYZER_WIFI_PASSWORD="${PILYZER_WIFI_PASSWORD}"
        PILYZER_HOSTNAME="${PILYZER_HOSTNAME}")
    target_link_libraries(pilyzer PRIVATE
        pico_cyw43_arch_lwip_poll
        pico_lwip_mdns)
endif()

# The instrument owns the USB port; stdio must not fight it for the link.
pico_enable_stdio_usb(pilyzer 0)
pico_enable_stdio_uart(pilyzer 0)
pico_add_extra_outputs(pilyzer)
