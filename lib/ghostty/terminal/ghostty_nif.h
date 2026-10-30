#include <ghostty/vt.h>

// The current-terminal (TTY) adapter is Unix-only: it needs termios/poll.
// On Windows the terminal NIF only uses the libghostty-vt C API above.
#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif
