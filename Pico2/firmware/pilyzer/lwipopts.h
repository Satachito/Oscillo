// lwIP for a polled, single-threaded instrument: no sockets, no RTOS, one
// listener and at most a couple of connections.
#pragma once

#define NO_SYS                      1
#define LWIP_SOCKET                 0
#define LWIP_NETCONN                0
#define SYS_LIGHTWEIGHT_PROT        0

#define MEM_LIBC_MALLOC             0
#define MEM_ALIGNMENT               4
// The records are the reason for the size: a reply can be most of 100 kB, and
// it is handed out in segments as they are acknowledged.
#define MEM_SIZE                    16000
#define MEMP_NUM_TCP_SEG            64
// Six connections for the six the browser opens (http_server.c), and room
// beside them for ones still closing. Replies point into flash rather than
// being copied, and each of those pieces is a PBUF.
#define MEMP_NUM_TCP_PCB            12
#define MEMP_NUM_PBUF               64
#define MEMP_NUM_ARP_QUEUE          10
#define PBUF_POOL_SIZE              24

#define LWIP_ARP                    1
#define LWIP_ETHERNET               1
#define LWIP_ICMP                   1
#define LWIP_RAW                    1
#define LWIP_IPV4                   1
#define LWIP_IPV6                   0
#define LWIP_TCP                    1
#define LWIP_UDP                    1
#define LWIP_DHCP                   1
#define LWIP_DNS                    1

#define TCP_MSS                     1460
#define TCP_WND                     (8 * TCP_MSS)
#define TCP_SND_BUF                 (8 * TCP_MSS)
#define TCP_SND_QUEUELEN            ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))

#define LWIP_NETIF_STATUS_CALLBACK  1
#define LWIP_NETIF_LINK_CALLBACK    1
#define LWIP_NETIF_HOSTNAME         1
#define LWIP_NETIF_TX_SINGLE_PBUF   1

// The whole point of the name: a phone finds pilyzer.local without being told
// an address, and Safari resolves it natively.
#define LWIP_MDNS_RESPONDER         1
#define LWIP_NUM_NETIF_CLIENT_DATA  1
#define MDNS_MAX_SERVICES           1
#define LWIP_IGMP                   1

// lwIP sizes its timer pool for its own protocols only; the mDNS responder
// adds probe, announce and rate-limit timers on top, and an empty pool is an
// assertion, which here is a panic that takes USB down with the radio.
#define MEMP_NUM_SYS_TIMEOUT        (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 8)

#define LWIP_STATS                  0
#define LWIP_STATS_DISPLAY          0
#define MEM_STATS                   0
#define SYS_STATS                   0
#define LINK_STATS                  0
