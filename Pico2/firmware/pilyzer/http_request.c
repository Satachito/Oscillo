#include "http_request.h"

#include <string.h>

static bool starts_with(const char *s, uint32_t n, const char *prefix)
{
    uint32_t length = (uint32_t)strlen(prefix);
    return n >= length && memcmp(s, prefix, length) == 0;
}

// Header names are case insensitive, and only the names are compared here.
static bool header_is(const char *line, uint32_t n, const char *name)
{
    uint32_t length = (uint32_t)strlen(name);
    if (n < length) return false;
    for (uint32_t i = 0; i < length; ++i) {
        char a = line[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return false;
    }
    return true;
}

static uint32_t decimal(const char *s, uint32_t n)
{
    uint32_t value = 0;
    for (uint32_t i = 0; i < n; ++i) {
        if (s[i] < '0' || s[i] > '9') break;
        value = value * 10 + (uint32_t)(s[i] - '0');
    }
    return value;
}

http_parse_t http_parse(const char *data, uint32_t length, http_request_t *out)
{
    // The head ends at the first blank line. Until it arrives there is nothing
    // to decide, however much body may already be sitting behind it.
    const char *end = NULL;
    for (uint32_t i = 0; i + 3 < length && i < HTTP_MAX_HEAD; ++i) {
        if (memcmp(data + i, "\r\n\r\n", 4) == 0) { end = data + i + 4; break; }
    }
    if (!end) return length >= HTTP_MAX_HEAD ? HTTP_PARSE_TOO_LONG : HTTP_PARSE_INCOMPLETE;

    memset(out, 0, sizeof *out);
    out->head_size = (uint32_t)(end - data);

    if (starts_with(data, length, "GET "))       { out->method = HTTP_GET;  data += 4; }
    else if (starts_with(data, length, "POST ")) { out->method = HTTP_POST; data += 5; }
    else return HTTP_PARSE_MALFORMED;

    const char *space = memchr(data, ' ', (size_t)(end - data));
    if (!space) return HTTP_PARSE_MALFORMED;
    // A query string names the same file; the server has nothing to do with it.
    const char *stop = memchr(data, '?', (size_t)(space - data));
    if (!stop) stop = space;
    uint32_t path_length = (uint32_t)(stop - data);
    if (path_length == 0) return HTTP_PARSE_MALFORMED;
    if (path_length >= HTTP_MAX_PATH) return HTTP_PARSE_TOO_LONG;
    memcpy(out->path, data, path_length);
    out->path[path_length] = '\0';

    for (const char *line = memchr(data, '\n', (size_t)(end - data)); line && line + 1 < end; ) {
        ++line;
        const char *next = memchr(line, '\n', (size_t)(end - line));
        uint32_t n = (uint32_t)((next ? next : end) - line);
        if (header_is(line, n, "content-length:")) {
            const char *value = line + strlen("content-length:");
            while (value < line + n && (*value == ' ' || *value == '\t')) ++value;
            out->content_length = decimal(value, (uint32_t)(line + n - value));
        } else if (header_is(line, n, "connection:") ) {
            for (uint32_t i = 0; i + 5 <= n; ++i)
                if (header_is(line + i, n - i, "close")) { out->close_requested = true; break; }
        }
        line = next;
    }
    return HTTP_PARSE_OK;
}

static uint32_t append(char *out, uint32_t capacity, uint32_t at, const char *text)
{
    uint32_t n = (uint32_t)strlen(text);
    if (at + n > capacity) return capacity + 1;     // overflow, reported by the caller
    memcpy(out + at, text, n);
    return at + n;
}

static uint32_t append_number(char *out, uint32_t capacity, uint32_t at, uint32_t value)
{
    char digits[11];
    int n = 0;
    do { digits[n++] = (char)('0' + value % 10); value /= 10; } while (value);
    if (at + (uint32_t)n > capacity) return capacity + 1;
    while (n) out[at++] = digits[--n];
    return at;
}

uint32_t http_response_head(char *out, uint32_t capacity, int status,
                            const char *type, const char *encoding,
                            uint32_t body_length, bool close)
{
    const char *reason = status == 200 ? "200 OK"
                       : status == 400 ? "400 Bad Request"
                       : status == 404 ? "404 Not Found"
                       : status == 405 ? "405 Method Not Allowed"
                       : status == 503 ? "503 Service Unavailable"
                                       : "500 Internal Server Error";
    uint32_t at = 0;
    at = append(out, capacity, at, "HTTP/1.1 ");
    at = append(out, capacity, at, reason);
    at = append(out, capacity, at, "\r\nContent-Type: ");
    at = append(out, capacity, at, type);
    if (encoding) {
        at = append(out, capacity, at, "\r\nContent-Encoding: ");
        at = append(out, capacity, at, encoding);
    }
    at = append(out, capacity, at, "\r\nContent-Length: ");
    at = append_number(out, capacity, at, body_length);
    // Nothing here is worth a stale copy: the panel is replaced when the
    // firmware is, and a reply is only ever true at the moment it is made.
    at = append(out, capacity, at, "\r\nCache-Control: no-store");
    at = append(out, capacity, at, close ? "\r\nConnection: close" : "\r\nConnection: keep-alive");
    at = append(out, capacity, at, "\r\n\r\n");
    return at > capacity ? 0 : at;
}

const char *http_type_for(const char *path)
{
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (!strcmp(dot, ".html")) return "text/html; charset=utf-8";
    if (!strcmp(dot, ".css"))  return "text/css; charset=utf-8";
    if (!strcmp(dot, ".mjs") || !strcmp(dot, ".js")) return "text/javascript; charset=utf-8";
    if (!strcmp(dot, ".svg"))  return "image/svg+xml";
    if (!strcmp(dot, ".json")) return "application/json";
    if (!strcmp(dot, ".md"))   return "text/markdown; charset=utf-8";
    return "application/octet-stream";
}

const web_file_t *web_lookup(const web_file_t *files, uint32_t count, const char *path)
{
    if (!strcmp(path, "/")) path = "/index.html";
    // A path is matched whole. Nothing here walks a directory, so ".." is not
    // special — there is no tree to climb out of, only this table.
    for (uint32_t i = 0; i < count; ++i)
        if (!strcmp(files[i].path, path)) return &files[i];
    return NULL;
}
