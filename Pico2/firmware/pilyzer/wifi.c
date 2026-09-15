#include "wifi.h"

#include "pico/cyw43_arch.h"
#include "lwip/apps/mdns.h"
#include "lwip/netif.h"

#include <stdio.h>

static bool joined;

bool wifi_start(const char *ssid, const char *password, const char *hostname)
{
    if (cyw43_arch_init()) return false;
    cyw43_arch_enable_sta_mode();
    netif_set_hostname(netif_default, hostname);

    // Thirty seconds, once. A bench instrument that cannot find the network is
    // still an instrument: USB does not depend on any of this.
    if (cyw43_arch_wifi_connect_timeout_ms(ssid, password, CYW43_AUTH_WPA2_AES_PSK, 30000)) {
        return false;
    }
    joined = true;

    mdns_resp_init();
    mdns_resp_add_netif(netif_default, hostname);
    mdns_resp_add_service(netif_default, hostname, "_http", DNSSD_PROTO_TCP, 80, NULL, NULL);
    return true;
}

void wifi_poll(void)
{
    if (joined) cyw43_arch_poll();
}
