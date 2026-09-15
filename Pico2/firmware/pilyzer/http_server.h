// The instrument's own web server: it hands out the front panel and answers
// the same packets USB does, one to a POST.
#pragma once

#include <stdbool.h>

/// Starts listening on port 80. False if the port could not be taken.
bool http_server_start(void);
