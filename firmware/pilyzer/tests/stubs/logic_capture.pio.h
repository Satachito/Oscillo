#include "mock_hardware.h"
static const int logic_capture_program = 0;
static const int logic_trigger_program = 0;
#define logic_trigger_offset_rise 0
#define logic_trigger_offset_fall 3
static inline pio_sm_config logic_capture_program_get_default_config(uint offset) { return (pio_sm_config){0}; }
static inline pio_sm_config logic_trigger_program_get_default_config(uint offset) { return (pio_sm_config){0}; }
