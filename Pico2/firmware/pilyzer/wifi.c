#include "wifi.h"

#include "http_server.h"
#include "pico/cyw43_arch.h"
#include "pico/time.h"
#include "lwip/apps/mdns.h"
#include "lwip/netif.h"

// Joining is a state the main loop steps through, never a wait. The first
// version blocked in cyw43_arch_wifi_connect_timeout_ms for up to thirty
// seconds with USB already started and nobody running tud_task, so the Mac
// gave up on the device; and anything that went wrong in there took USB down
// with it for good.

static const char *network, *passphrase, *name;
static bool radio, served;
static absolute_time_t next_attempt;

// A refused password, a network out of range or a 5 GHz-only one (the radio
// is 2.4 GHz) all end the same way: try again later, keep answering USB.
#define RETRY_MS 40000

static void attempt(void)
{
    // WPA2 or WPA3, whichever the network offers: many routers now run both
    // on one name, and some only WPA3.
    cyw43_arch_wifi_connect_async(network, passphrase, CYW43_AUTH_WPA3_WPA2_AES_PSK);
    next_attempt = make_timeout_time_ms(RETRY_MS);
}

bool wifi_start(const char *ssid, const char *password, const char *hostname)
{
    if (cyw43_arch_init()) return false;
    radio = true;
    network = ssid;
    passphrase = password;
    name = hostname;
    cyw43_arch_enable_sta_mode();
    netif_set_hostname(netif_default, hostname);
    attempt();
    return true;
}

void wifi_poll(void)
{
    if (!radio) return;
    cyw43_arch_poll();

    int status = cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA);
    if (status == CYW43_LINK_UP) {
        if (!served) {
            served = true;
            mdns_resp_init();
            mdns_resp_add_netif(netif_default, name);
            mdns_resp_add_service(netif_default, name, "_http", DNSSD_PROTO_TCP, 80, NULL, NULL);
            http_server_start();
            // The LED hangs off the radio on a W, so it can say the front
            // panel is up. Only now, though: a GPIO request sent while a join
            // is still going on never got its answer on the bench, and the
            // main loop - USB with it - stopped dead. That is why it does not
            // blink while joining.
            cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, true);
        }
        return;
    }

    bool failed = status == CYW43_LINK_FAIL || status == CYW43_LINK_NONET
               || status == CYW43_LINK_BADAUTH || status == CYW43_LINK_DOWN;
    if (failed && time_reached(next_attempt)) attempt();
}
