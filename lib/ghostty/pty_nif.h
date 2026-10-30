#ifndef _WIN32
#ifdef __APPLE__
#include <util.h>
#include <crt_externs.h>
#else
#include <pty.h>
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// Read the inherited environment before fork, while allocation is safe.
static inline char **ghostty_environ(void) {
#ifdef __APPLE__
    return *_NSGetEnviron();
#else
    extern char **environ;
    return environ;
#endif
}
#endif
// The Windows anonymous-pipe backend uses std.os.windows declarations
// directly and needs no libc headers.
