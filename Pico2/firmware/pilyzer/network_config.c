#include "network_config.h"

#include <string.h>

#include "hardware/flash.h"
#include "pico/flash.h"

// The last sector but one, read through XIP and written a page at a time. Not
// the last: every RP2350 UF2 carries one block at 0x10FFFF00 (the SDK's
// workaround for the bootrom's erratum E10), which on a 4 MB chip lands in the
// last sector, so the network stored there was gone after every update.
#define CONFIG_OFFSET (PICO_FLASH_SIZE_BYTES - 2 * FLASH_SECTOR_SIZE)
#define CONFIG_MAGIC  0x4E54454Eu   // "NETN"

typedef struct {
    uint32_t magic;
    uint32_t size;
    pilyzer_network_config_t config;
    uint32_t check;
} stored_t;

_Static_assert(sizeof(stored_t) <= FLASH_PAGE_SIZE, "the stored network fits one page");

// FNV-1a: enough to tell a page that was written from one that was not, or
// was cut off half way.
static uint32_t checksum(const void *data, size_t length)
{
    const uint8_t *bytes = data;
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < length; i++) hash = (hash ^ bytes[i]) * 16777619u;
    return hash;
}

bool network_config_load(pilyzer_network_config_t *out)
{
    const stored_t *stored = (const stored_t *)(XIP_BASE + CONFIG_OFFSET);
    if (stored->magic != CONFIG_MAGIC || stored->size != sizeof stored->config) return false;
    if (stored->check != checksum(&stored->config, sizeof stored->config)) return false;
    memcpy(out, &stored->config, sizeof *out);
    return out->ssid[0] != 0;
}

typedef struct {
    const uint8_t *page;   // NULL to erase only
} write_t;

// Runs with the other core and interrupts held off (flash_safe_execute): the
// flash cannot be read while it is being written, and the program runs from it.
static void write_sector(void *param)
{
    const write_t *w = param;
    flash_range_erase(CONFIG_OFFSET, FLASH_SECTOR_SIZE);
    if (w->page) flash_range_program(CONFIG_OFFSET, w->page, FLASH_PAGE_SIZE);
}

bool network_config_store(const pilyzer_network_config_t *config)
{
    static uint8_t page[FLASH_PAGE_SIZE];
    write_t w = {NULL};
    if (config->ssid[0]) {
        memset(page, 0xFF, sizeof page);
        stored_t stored = {CONFIG_MAGIC, sizeof stored.config, *config, 0};
        stored.check = checksum(&stored.config, sizeof stored.config);
        memcpy(page, &stored, sizeof stored);
        w.page = page;
    }
    return flash_safe_execute(write_sector, &w, 100) == PICO_OK;
}
