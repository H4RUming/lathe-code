#ifndef LATHE_EXECUTION_POSIX_H
#define LATHE_EXECUTION_POSIX_H
#include <sys/types.h>
#include <stdint.h>

struct lathe_child {
    pid_t pid;
    int input_fd;
    int output_fd;
    int error_fd;
};
int lathe_spawn(const char *executable, char *const arguments[], char *const environment[],
                const char *working_directory, int terminal, uint16_t columns, uint16_t rows,
                struct lathe_child *child);
/* Observe without reaping: the PID remains reserved until group cleanup ends. */
int lathe_child_exit(pid_t pid, int32_t *exit_code, int32_t *signal_number);
int lathe_reap(pid_t pid);
int lathe_resize_terminal(int fd, uint16_t columns, uint16_t rows);
void lathe_block_sigpipe_for_thread(void);
#endif
