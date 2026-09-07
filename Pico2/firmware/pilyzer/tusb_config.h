#pragma once

#define CFG_TUSB_RHPORT0_MODE     (OPT_MODE_DEVICE | OPT_MODE_FULL_SPEED)
#define CFG_TUD_ENDPOINT0_SIZE    64

#define CFG_TUD_CDC               0
#define CFG_TUD_MSC               0
#define CFG_TUD_HID               0
#define CFG_TUD_MIDI              0
#define CFG_TUD_VENDOR            1

// One record chunk is 8 KB; a transmit buffer a few packets deep is enough to
// keep the endpoint fed between passes of the main loop.
#define CFG_TUD_VENDOR_RX_BUFSIZE 256
#define CFG_TUD_VENDOR_TX_BUFSIZE 2048
#define CFG_TUD_VENDOR_EPSIZE     64
