// Parsing a request head and writing a response head, with nothing underneath.
//
// Kept apart from the socket so it can be compiled and tested on a host: every
// mistake in an HTTP server that is worth catching is in this half.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HTTP_MAX_HEAD 1024      // a request head longer than this is refused
#define HTTP_MAX_PATH 64

typedef enum { HTTP_GET, HTTP_POST, HTTP_OTHER } http_method_t;

typedef struct {
    http_method_t method;
    char          path[HTTP_MAX_PATH];
    uint32_t      content_length;
    uint32_t      head_size;        // bytes up to and including the blank line
    bool          close_requested;
} http_request_t;

typedef enum {
    HTTP_PARSE_INCOMPLETE,   // the head has not all arrived; ask again later
    HTTP_PARSE_OK,
    HTTP_PARSE_TOO_LONG,     // head over HTTP_MAX_HEAD, or a path that will not fit
    HTTP_PARSE_MALFORMED,
} http_parse_t;

http_parse_t http_parse(const char *data, uint32_t length, http_request_t *out);

/// Writes a response head into `out`, returning its length, or 0 if it will
/// not fit. `encoding` may be NULL; `type` may not.
uint32_t http_response_head(char *out, uint32_t capacity, int status,
                            const char *type, const char *encoding,
                            uint32_t body_length, bool close);

/// The content type to serve a baked file under, from its name.
const char *http_type_for(const char *path);

/// One file of the browser application, stored gzipped in flash.
typedef struct {
    const char    *path;
    const uint8_t *data;
    uint32_t       length;
} web_file_t;

/// Finds the file a request path names, or NULL. "/" is the front panel.
const web_file_t *web_lookup(const web_file_t *files, uint32_t count, const char *path);
