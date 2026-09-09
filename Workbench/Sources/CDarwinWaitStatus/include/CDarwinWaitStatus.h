#ifndef C_DARWIN_WAIT_STATUS_H
#define C_DARWIN_WAIT_STATUS_H

#include <stdbool.h>
#include <sys/wait.h>

static inline bool afleet_wait_status_exited(int status) {
    return WIFEXITED(status);
}

static inline int afleet_wait_exit_status(int status) {
    return WEXITSTATUS(status);
}

static inline bool afleet_wait_status_stopped(int status) {
    return WIFSTOPPED(status);
}

static inline int afleet_wait_stop_signal(int status) {
    return WSTOPSIG(status);
}

static inline bool afleet_wait_status_signalled(int status) {
    return WIFSIGNALED(status);
}

static inline int afleet_wait_term_signal(int status) {
    return WTERMSIG(status);
}

#endif
