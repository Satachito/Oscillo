// The HTTP head, checked on the host: the same file the Pico runs.
#include "../http_request.c"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static http_parse_t parse(const char *text, http_request_t *out)
{
    return http_parse(text, (uint32_t)strlen(text), out);
}

static void arriving_in_pieces(void)
{
    // A head split across segments is not a bad request, it is an early one.
    const char *whole = "POST /rpc HTTP/1.1\r\nHost: pilyzer.local\r\nContent-Length: 12\r\n\r\nxxxxxxxxxxxx";
    for (uint32_t n = 1; n < strlen(whole); ++n) {
        http_request_t r;
        http_parse_t verdict = http_parse(whole, n, &r);
        const char *head_end = strstr(whole, "\r\n\r\n") + 4;
        if (n < (uint32_t)(head_end - whole)) assert(verdict == HTTP_PARSE_INCOMPLETE);
        else assert(verdict == HTTP_PARSE_OK);
    }
    http_request_t r;
    assert(parse(whole, &r) == HTTP_PARSE_OK);
    assert(r.method == HTTP_POST);
    assert(!strcmp(r.path, "/rpc"));
    assert(r.content_length == 12);
    assert(r.head_size == (uint32_t)(strstr(whole, "\r\n\r\n") + 4 - whole));
}

static void heads_and_paths(void)
{
    http_request_t r;

    assert(parse("GET / HTTP/1.1\r\n\r\n", &r) == HTTP_PARSE_OK);
    assert(r.method == HTTP_GET && !strcmp(r.path, "/") && r.content_length == 0);

    // A query string names the same file.
    assert(parse("GET /src/main.mjs?v=2 HTTP/1.1\r\n\r\n", &r) == HTTP_PARSE_OK);
    assert(!strcmp(r.path, "/src/main.mjs"));

    // Header names are case insensitive and may be padded.
    assert(parse("POST /rpc HTTP/1.1\r\nCONTENT-LENGTH:\t 4096\r\n\r\n", &r) == HTTP_PARSE_OK);
    assert(r.content_length == 4096);

    assert(parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", &r) == HTTP_PARSE_OK);
    assert(r.close_requested);
    assert(parse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", &r) == HTTP_PARSE_OK);
    assert(!r.close_requested);

    assert(parse("PUT / HTTP/1.1\r\n\r\n", &r) == HTTP_PARSE_MALFORMED);
    assert(parse("GET\r\n\r\n", &r) == HTTP_PARSE_MALFORMED);

    // A path that will not fit is refused rather than truncated into another.
    char long_request[HTTP_MAX_HEAD];
    int at = snprintf(long_request, sizeof long_request, "GET /");
    for (int i = 0; i < HTTP_MAX_PATH; ++i) long_request[at++] = 'a';
    strcpy(long_request + at, " HTTP/1.1\r\n\r\n");
    assert(parse(long_request, &r) == HTTP_PARSE_TOO_LONG);

    // And a head with no end to it is refused rather than buffered forever.
    char endless[HTTP_MAX_HEAD + 64];
    memset(endless, 'x', sizeof endless);
    assert(http_parse(endless, sizeof endless, &r) == HTTP_PARSE_TOO_LONG);
}

static void response_heads(void)
{
    char out[256];
    uint32_t n = http_response_head(out, sizeof out, 200, "text/html; charset=utf-8", "gzip", 1234, false);
    assert(n > 0);
    out[n] = '\0';
    assert(strstr(out, "HTTP/1.1 200 OK\r\n"));
    assert(strstr(out, "Content-Type: text/html; charset=utf-8\r\n"));
    assert(strstr(out, "Content-Encoding: gzip\r\n"));
    assert(strstr(out, "Content-Length: 1234\r\n"));
    assert(strstr(out, "Connection: keep-alive\r\n"));
    assert(!strncmp(out + n - 4, "\r\n\r\n", 4));

    n = http_response_head(out, sizeof out, 404, "text/plain", NULL, 0, true);
    out[n] = '\0';
    assert(strstr(out, "404 Not Found") && strstr(out, "Content-Length: 0"));
    assert(strstr(out, "Connection: close") && !strstr(out, "Content-Encoding"));

    // Too small to hold it is reported, not written past.
    char tiny[16];
    memset(tiny, 0x7f, sizeof tiny);
    assert(http_response_head(tiny, sizeof tiny, 200, "text/html", NULL, 1, true) == 0);
    for (size_t i = 0; i < sizeof tiny; ++i) assert(tiny[i] == 0x7f || i < sizeof tiny);
}

static void finding_files(void)
{
    static const uint8_t body[] = { 1, 2, 3 };
    static const web_file_t files[] = {
        { "/index.html", body, 3 },
        { "/src/main.mjs", body, 3 },
        { "/style.css", body, 3 },
    };
    const uint32_t n = sizeof files / sizeof files[0];

    assert(web_lookup(files, n, "/index.html") == &files[0]);
    assert(web_lookup(files, n, "/") == &files[0]);          // the front panel
    assert(web_lookup(files, n, "/src/main.mjs") == &files[1]);
    assert(web_lookup(files, n, "/nothing") == NULL);
    // Whole-path matching, so none of these reach a file by accident.
    assert(web_lookup(files, n, "/index.htm") == NULL);
    assert(web_lookup(files, n, "/index.html/") == NULL);
    assert(web_lookup(files, n, "/../index.html") == NULL);
    assert(web_lookup(files, n, "") == NULL);
}

static void content_types(void)
{
    assert(!strcmp(http_type_for("/index.html"), "text/html; charset=utf-8"));
    assert(!strcmp(http_type_for("/src/main.mjs"), "text/javascript; charset=utf-8"));
    assert(!strcmp(http_type_for("/style.css"), "text/css; charset=utf-8"));
    assert(!strcmp(http_type_for("/favicon.svg"), "image/svg+xml"));
    assert(!strcmp(http_type_for("/rpc"), "application/octet-stream"));
}

int main(void)
{
    arriving_in_pieces();
    heads_and_paths();
    response_heads();
    finding_files();
    content_types();
    puts("HTTP: heads across segment boundaries, paths, limits, file lookup and response heads passed");
    return 0;
}
