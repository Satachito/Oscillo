#include "http_server.h"

#include "http_request.h"
#include "pilyzer_protocol.h"
#include "web_files.h"

#include "lwip/tcp.h"

#include <string.h>

// Declared by main.c: runs one request and hands back the reply to send.
bool pilyzer_execute(const uint8_t *packet, uint32_t length,
                     const uint8_t **head, uint32_t *head_size,
                     const uint8_t **body, uint32_t *body_size);

#define HTTP_PORT        80
// A request is a header and at most a short payload — the volume all goes the
// other way — so what has to be buffered per connection is the head and little
// else.
#define REQUEST_BUFFER   (HTTP_MAX_HEAD + 128)
#define RESPONSE_HEAD    192
#define SPANS            3          // response head, then up to two body parts

typedef struct {
    struct tcp_pcb *pcb;
    uint8_t  in[REQUEST_BUFFER];
    uint32_t have;
    char     head[RESPONSE_HEAD];
    const uint8_t *span[SPANS];
    uint32_t span_length[SPANS];
    uint32_t sent;                  // bytes handed to lwIP, across all spans
    uint32_t total;
    bool     in_use;
    bool     close_when_sent;
    bool     holds_reply;           // this connection owns the shared reply buffers
} connection_t;

// A browser loading the page opens up to six connections at once, one per
// module it has found, and a refused one is a module that never arrives - the
// page then shows but nothing on it runs. Each costs about 1.6 kB.
#define CONNECTIONS 6
static connection_t connections[CONNECTIONS];
// The reply lives in buffers the command layer owns, so only one connection
// may be carrying one at a time.
static bool reply_in_flight;

static void release(connection_t *c)
{
    if (c->holds_reply) { reply_in_flight = false; c->holds_reply = false; }
    c->in_use = false;
    c->pcb = NULL;
}

static void reset_response(connection_t *c)
{
    for (int i = 0; i < SPANS; ++i) { c->span[i] = NULL; c->span_length[i] = 0; }
    c->sent = c->total = 0;
}

static void add_span(connection_t *c, const void *data, uint32_t length)
{
    for (int i = 0; i < SPANS; ++i) {
        if (c->span[i]) continue;
        c->span[i] = data; c->span_length[i] = length; c->total += length;
        return;
    }
}

/// Hands lwIP as much of the response as it will take. What is left waits for
/// the acknowledgement that frees room.
static void pump(connection_t *c)
{
    while (c->sent < c->total) {
        uint32_t at = c->sent, index = 0;
        while (index < SPANS && at >= c->span_length[index]) { at -= c->span_length[index]; ++index; }
        if (index >= SPANS) break;

        uint32_t remaining = c->span_length[index] - at;
        uint16_t room = tcp_sndbuf(c->pcb);
        if (room == 0) return;
        uint16_t take = remaining < room ? (uint16_t)remaining : room;
        // The bytes are in flash or in a buffer held until this is acknowledged,
        // so lwIP may point at them rather than copy them.
        err_t error = tcp_write(c->pcb, c->span[index] + at, take, 0);
        if (error == ERR_MEM) break;
        if (error != ERR_OK) { tcp_abort(c->pcb); release(c); return; }
        c->sent += take;
    }
    tcp_output(c->pcb);

    if (c->sent == c->total) {
        if (c->holds_reply) { reply_in_flight = false; c->holds_reply = false; }
        if (c->close_when_sent) { tcp_close(c->pcb); release(c); }
        else { reset_response(c); c->have = 0; }
    }
}

static void plain(connection_t *c, int status, const char *message)
{
    reset_response(c);
    uint32_t length = (uint32_t)strlen(message);
    uint32_t n = http_response_head(c->head, sizeof c->head, status, "text/plain; charset=utf-8",
                                    NULL, length, true);
    c->close_when_sent = true;
    if (!n) { tcp_abort(c->pcb); release(c); return; }
    add_span(c, c->head, n);
    add_span(c, message, length);
    pump(c);
}

static void answer(connection_t *c, const http_request_t *request)
{
    reset_response(c);
    c->close_when_sent = request->close_requested;

    if (request->method == HTTP_POST && !strcmp(request->path, "/rpc")) {
        const uint8_t *packet = c->in + request->head_size;
        const uint8_t *head; uint32_t head_size;
        const uint8_t *body; uint32_t body_size;
        // One reply at a time: they live in buffers the command layer owns.
        if (reply_in_flight) { plain(c, 503, "The instrument is answering another request."); return; }
        if (!pilyzer_execute(packet, request->content_length, &head, &head_size, &body, &body_size)) {
            plain(c, 400, "Not a PiLyzer request, or the instrument is busy.");
            return;
        }
        reply_in_flight = c->holds_reply = true;
        uint32_t n = http_response_head(c->head, sizeof c->head, 200, "application/octet-stream",
                                        NULL, head_size + body_size, c->close_when_sent);
        if (!n) { tcp_abort(c->pcb); release(c); return; }
        add_span(c, c->head, n);
        add_span(c, head, head_size);
        if (body_size) add_span(c, body, body_size);
        pump(c);
        return;
    }
    if (request->method != HTTP_GET) { plain(c, 405, "Only GET and POST."); return; }

    const web_file_t *file = web_lookup(web_files, WEB_FILE_COUNT, request->path);
    if (!file) { plain(c, 404, "No such file on this instrument."); return; }
    uint32_t n = http_response_head(c->head, sizeof c->head, 200, http_type_for(file->path),
                                    "gzip", file->length, c->close_when_sent);
    if (!n) { tcp_abort(c->pcb); release(c); return; }
    add_span(c, c->head, n);
    add_span(c, file->data, file->length);
    pump(c);
}

static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t length)
{
    (void)pcb; (void)length;
    connection_t *c = arg;
    if (c && c->in_use) pump(c);
    return ERR_OK;
}

// Every second or so while a connection is open. A write that found lwIP's
// segment pool empty waits for an acknowledgement to go round again, and a
// connection with nothing in flight has none coming; this is its second go.
static err_t on_poll(void *arg, struct tcp_pcb *pcb)
{
    (void)pcb;
    connection_t *c = arg;
    if (c && c->in_use && c->sent < c->total) pump(c);
    return ERR_OK;
}

static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t error)
{
    connection_t *c = arg;
    if (!c || !c->in_use) { if (p) pbuf_free(p); return ERR_OK; }
    if (!p) { tcp_close(pcb); release(c); return ERR_OK; }          // the other end went away
    if (error != ERR_OK) { pbuf_free(p); tcp_abort(pcb); release(c); return ERR_ABRT; }

    uint32_t room = REQUEST_BUFFER - c->have;
    uint32_t take = p->tot_len < room ? p->tot_len : room;
    pbuf_copy_partial(p, c->in + c->have, (u16_t)take, 0);
    c->have += take;
    tcp_recved(pcb, p->tot_len);
    bool overflowed = p->tot_len > room;
    pbuf_free(p);
    if (overflowed) { plain(c, 400, "That request is too big for this instrument."); return ERR_OK; }

    http_request_t request;
    switch (http_parse((const char *)c->in, c->have, &request)) {
    case HTTP_PARSE_INCOMPLETE: return ERR_OK;                      // more is coming
    case HTTP_PARSE_TOO_LONG:   plain(c, 400, "That request head is too long."); return ERR_OK;
    case HTTP_PARSE_MALFORMED:  plain(c, 400, "That is not a request this instrument understands."); return ERR_OK;
    case HTTP_PARSE_OK: break;
    }
    // The body may still be arriving behind the head.
    if (c->have < request.head_size + request.content_length) return ERR_OK;
    answer(c, &request);
    return ERR_OK;
}

static void on_error(void *arg, err_t error)
{
    (void)error;
    connection_t *c = arg;
    if (c) { c->pcb = NULL; release(c); }                           // lwIP has freed the pcb
}

static err_t on_accept(void *arg, struct tcp_pcb *pcb, err_t error)
{
    (void)arg;
    if (error != ERR_OK || !pcb) return ERR_VAL;
    for (unsigned i = 0; i < sizeof connections / sizeof connections[0]; ++i) {
        connection_t *c = &connections[i];
        if (c->in_use) continue;
        memset(c, 0, sizeof *c);
        c->in_use = true; c->pcb = pcb;
        tcp_arg(pcb, c);
        tcp_recv(pcb, on_recv);
        tcp_sent(pcb, on_sent);
        tcp_err(pcb, on_error);
        tcp_poll(pcb, on_poll, 2);
        return ERR_OK;
    }
    // Every buffer is busy. Refusing is better than queueing a connection
    // there is nowhere to put.
    tcp_abort(pcb);
    return ERR_ABRT;
}

bool http_server_start(void)
{
    struct tcp_pcb *listener = tcp_new_ip_type(IPADDR_TYPE_ANY);
    if (!listener) return false;
    if (tcp_bind(listener, IP_ANY_TYPE, HTTP_PORT) != ERR_OK) { tcp_close(listener); return false; }
    struct tcp_pcb *listening = tcp_listen_with_backlog(listener, 2);
    // On failure the original is still ours to close; on success lwIP has
    // replaced it with a smaller one and freed it already.
    if (!listening) { tcp_close(listener); return false; }
    listener = listening;
    tcp_accept(listener, on_accept);
    return true;
}
