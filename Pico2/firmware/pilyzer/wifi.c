#include "wifi.h"

#include <string.h>

#include "http_server.h"
#include "network_config.h"
#include "pico/cyw43_arch.h"
#include "pico/time.h"
#include "lwip/apps/mdns.h"
#include "lwip/netif.h"

// Joining is a state the main loop steps through, never a wait. The first
// version blocked in cyw43_arch_wifi_connect_timeout_ms for up to thirty
// seconds with USB already started and nobody running tud_task, so the Mac
// gave up on the device; and anything that went wrong in there took USB down
// with it for good.

// The network and name in use, as C strings: from flash if a host has set
// them, else built in, else none — and then the radio waits to be told.
static char network[33], passphrase[65], name[33];
static uint8_t source = NET_SOURCE_NONE;
static bool radio, served, lit;
static absolute_time_t next_attempt;

// A new network from a host, applied a moment after the reply to it has gone
// (over Wi-Fi, leaving the old network first would take the reply with it),
// and never in the middle of a join: leaving one that was still going on reset
// the board, as the LED request did (wifi_poll).
static bool pending;
static absolute_time_t apply_at;
static char pending_network[33], pending_passphrase[65], pending_name[33];

// A refused password, a network out of range or a 5 GHz-only one (the radio
// is 2.4 GHz) all end the same way: try again later, keep answering USB.
#define RETRY_MS 40000
#define APPLY_DELAY_MS 300

// A fixed-width wire field as a C string.
static void take(char *out, size_t size, const char *field, size_t width)
{
    size_t length = strnlen(field, width);
    if (length > size - 1) length = size - 1;
    memcpy(out, field, length);
    out[length] = 0;
}

static void attempt(void)
{
    if (!network[0]) return;
    // WPA2 or WPA3, whichever the network offers: many routers now run both
    // on one name, and some only WPA3. No password is an open network.
    uint32_t auth = passphrase[0] ? CYW43_AUTH_WPA3_WPA2_AES_PSK : CYW43_AUTH_OPEN;
    cyw43_arch_wifi_connect_async(network, passphrase[0] ? passphrase : NULL, auth);
    next_attempt = make_timeout_time_ms(RETRY_MS);
}

bool wifi_start(const char *ssid, const char *password, const char *hostname)
{
    if (cyw43_arch_init()) return false;
    radio = true;
    pilyzer_network_config_t stored;
    if (network_config_load(&stored)) {
        take(network, sizeof network, stored.ssid, sizeof stored.ssid);
        take(passphrase, sizeof passphrase, stored.password, sizeof stored.password);
        take(name, sizeof name, stored.hostname, sizeof stored.hostname);
        source = NET_SOURCE_STORED;
    } else if (ssid[0]) {
        take(network, sizeof network, ssid, 32);
        take(passphrase, sizeof passphrase, password, 64);
        take(name, sizeof name, hostname, 32);
        source = NET_SOURCE_BUILT;
    }
    if (!name[0]) strcpy(name, "pilyzer");
    cyw43_arch_enable_sta_mode();
    netif_set_hostname(netif_default, name);
    attempt();
    return true;
}

// A name mDNS can carry and a person can type: letters, digits and hyphens,
// not at either end.
static bool valid_name(const char *s)
{
    size_t n = strlen(s);
    if (n == 0 || n > 31 || s[0] == '-' || s[n - 1] == '-') return false;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    return true;
}

// WPA wants 8 to 63 characters, or 64 hexadecimal digits; none is an open
// network.
static bool valid_passphrase(const char *s)
{
    size_t n = strlen(s);
    if (n == 0) return true;
    if (n == 64) {
        for (size_t i = 0; i < n; i++)
            if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= 'A' && s[i] <= 'F'))) return false;
        return true;
    }
    return n >= 8 && n <= 63;
}

uint8_t wifi_configure(const pilyzer_network_config_t *config)
{
    if (!radio) return ST_INTERNAL;
    char ssid[33], password[65], hostname[33];
    take(ssid, sizeof ssid, config->ssid, sizeof config->ssid);
    take(password, sizeof password, config->password, sizeof config->password);
    take(hostname, sizeof hostname, config->hostname, sizeof config->hostname);
    if (!hostname[0]) strcpy(hostname, "pilyzer");
    if (ssid[0] && (!valid_passphrase(password) || !valid_name(hostname))) return ST_BAD_ARGUMENT;
    if (!network_config_store(config)) return ST_INTERNAL;
    strcpy(pending_network, ssid);
    strcpy(pending_passphrase, password);
    strcpy(pending_name, hostname);
    pending = true;
    apply_at = make_timeout_time_ms(APPLY_DELAY_MS);
    return ST_OK;
}

static void apply(void)
{
    pending = false;
    const bool renamed = strcmp(name, pending_name) != 0;
    strcpy(network, pending_network);
    strcpy(passphrase, pending_passphrase);
    strcpy(name, pending_name);
    source = network[0] ? NET_SOURCE_STORED : NET_SOURCE_NONE;
    netif_set_hostname(netif_default, name);
    if (served && renamed) mdns_resp_rename_netif(netif_default, name);
    // The LED goes out only from a network already joined: a GPIO request in
    // the middle of a join is the one that stopped the main loop (wifi_poll).
    if (lit && cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA) == CYW43_LINK_UP) {
        cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, false);
        lit = false;
    }
    cyw43_wifi_leave(&cyw43_state, CYW43_ITF_STA);
    attempt();
}

void wifi_status(pilyzer_network_status_t *out)
{
    memset(out, 0, sizeof *out);
    out->source = source;
    // Wire fields: zero-padded, and a full one has no terminator.
    memcpy(out->ssid, network, strnlen(network, sizeof out->ssid));
    memcpy(out->hostname, name, strnlen(name, sizeof out->hostname));
    if (!radio || !network[0]) return;
    int status = cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA);
    if (status == CYW43_LINK_UP) {
        out->state = NET_JOINED;
        const ip4_addr_t *ip = netif_ip4_addr(netif_default);
        out->ipv4[0] = ip4_addr1(ip);
        out->ipv4[1] = ip4_addr2(ip);
        out->ipv4[2] = ip4_addr3(ip);
        out->ipv4[3] = ip4_addr4(ip);
    } else if (status == CYW43_LINK_FAIL || status == CYW43_LINK_NONET || status == CYW43_LINK_BADAUTH) {
        out->state = NET_FAILING;
    } else {
        out->state = NET_JOINING;
    }
}

// Link-local only. The router hands out a global address as well, and the
// radio driver turns autoconfiguration on to take it, which could make the
// instrument reachable from beyond the house on a network that lets IPv6 in;
// the page and /rpc have no login. So autoconfiguration goes off again and any
// address it took goes, leaving slot 0, the link-local one mDNS answers with.
// (Allowing only that one slot instead stopped the firmware dead within
// minutes of joining.)
static void keep_link_local_only(struct netif *n)
{
    netif_set_ip6_autoconfig_enabled(n, 0);
    for (s8_t i = 1; i < LWIP_IPV6_NUM_ADDRESSES; i++)
        if (!ip6_addr_isinvalid(netif_ip6_addr_state(n, i))) netif_ip6_addr_set_state(n, i, IP6_ADDR_INVALID);
}

void wifi_poll(void)
{
    if (!radio) return;
    cyw43_arch_poll();
    int status = cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA);
    const bool joining = status == CYW43_LINK_JOIN || status == CYW43_LINK_NOIP;
    if (pending && !joining && time_reached(apply_at)) {
        apply();
        return;
    }

    if (status == CYW43_LINK_UP) {
        keep_link_local_only(netif_default);
        if (!served) {
            served = true;
            mdns_resp_init();
            mdns_resp_add_netif(netif_default, name);
            mdns_resp_add_service(netif_default, name, "_http", DNSSD_PROTO_TCP, 80, NULL, NULL);
            http_server_start();
        }
        // The LED hangs off the radio on a W, so it can say the front panel
        // is up. Only once joined, though: a GPIO request sent while a join
        // is still going on never got its answer on the bench, and the main
        // loop - USB with it - stopped dead. That is why it does not blink
        // while joining.
        if (!lit) {
            cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, true);
            lit = true;
        }
        return;
    }

    bool failed = status == CYW43_LINK_FAIL || status == CYW43_LINK_NONET
               || status == CYW43_LINK_BADAUTH || status == CYW43_LINK_DOWN;
    if (failed && time_reached(next_attempt)) attempt();
}
