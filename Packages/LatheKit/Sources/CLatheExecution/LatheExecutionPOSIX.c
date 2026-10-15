#include "LatheExecutionPOSIX.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static int safe_fd(int fd) {
    if (fd < 0) return fd;
    if (fd < 3) {
        int replacement = fcntl(fd, F_DUPFD_CLOEXEC, 3);
        int saved = errno;
        close(fd);
        errno = saved;
        return replacement;
    }
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}
static int make_pipe(int pair[2]) {
    int raw[2];
    if (pipe(raw) < 0) return errno;
    pair[0] = safe_fd(raw[0]);
    if (pair[0] < 0) { int saved = errno; close(raw[1]); return saved; }
    pair[1] = safe_fd(raw[1]);
    if (pair[1] < 0) { int saved = errno; close(pair[0]); pair[0] = -1; return saved; }
    return 0;
}
static void close_pair(int pair[2]) {
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return errno;
    return 0;
}

int lathe_spawn(const char *executable, char *const arguments[], char *const environment[],
                const char *working_directory, int terminal, uint16_t columns, uint16_t rows,
                struct lathe_child *child) {
    int input[2] = {-1,-1}, output[2] = {-1,-1}, error[2] = {-1,-1};
    int master = -1, slave = -1, result = 0;
    char terminal_name[PATH_MAX];
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int attributes_ready = 0, actions_ready = 0;
    if (terminal) {
        struct winsize size = {.ws_row=rows, .ws_col=columns};
        if (openpty(&master, &slave, terminal_name, NULL, &size) < 0) { result=errno; goto cleanup; }
        master = safe_fd(master);
        if (master < 0) { result=errno; goto cleanup; }
        /* Open the slave in the newly created child session, so it becomes
           the controlling terminal. Duping an already-open slave is insufficient. */
        close(slave); slave = -1;
    } else {
        if ((result=make_pipe(input)) || (result=make_pipe(output)) || (result=make_pipe(error))) goto cleanup;
    }
    if ((result=posix_spawnattr_init(&attributes))) goto cleanup;
    attributes_ready=1;
    if ((result=posix_spawn_file_actions_init(&actions))) goto cleanup;
    actions_ready=1;
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    int signals[] = {SIGPIPE,SIGINT,SIGTERM,SIGHUP,SIGQUIT,SIGTSTP,SIGTTIN,SIGTTOU};
    for (size_t i=0; i<sizeof(signals)/sizeof(signals[0]); i++) sigaddset(&defaults,signals[i]);
#define CHECK(call) do { result=(call); if(result) goto cleanup; } while(0)
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                 POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    CHECK(posix_spawnattr_setsigmask(&attributes,&empty));
    CHECK(posix_spawnattr_setsigdefault(&attributes,&defaults));
    CHECK(posix_spawn_file_actions_addchdir_np(&actions,working_directory));
    if (terminal) {
        CHECK(posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,terminal_name,O_RDWR,0));
        CHECK(posix_spawn_file_actions_adddup2(&actions,STDIN_FILENO,STDOUT_FILENO));
        CHECK(posix_spawn_file_actions_adddup2(&actions,STDIN_FILENO,STDERR_FILENO));
    } else {
        CHECK(posix_spawn_file_actions_adddup2(&actions,input[0],STDIN_FILENO));
        CHECK(posix_spawn_file_actions_adddup2(&actions,output[1],STDOUT_FILENO));
        CHECK(posix_spawn_file_actions_adddup2(&actions,error[1],STDERR_FILENO));
    }
    CHECK(posix_spawn(&child->pid,executable,&actions,&attributes,arguments,environment));
    if (terminal) {
        child->input_fd=master; child->output_fd=master; child->error_fd=-1;
        master=-1;
    } else {
        child->input_fd=input[1]; input[1]=-1;
        child->output_fd=output[0]; output[0]=-1;
        child->error_fd=error[0]; error[0]=-1;
    }
    /* These operations cannot fail on our valid descriptors; if they do, stop
       the newly owned group before reporting failure. */
    if ((result=nonblocking(child->input_fd)) || (result=nonblocking(child->output_fd)) ||
        (child->error_fd>=0 && (result=nonblocking(child->error_fd)))) {
        kill(-child->pid,SIGKILL);
        lathe_reap(child->pid);
        if (child->input_fd!=child->output_fd) close(child->input_fd);
        close(child->output_fd);
        if (child->error_fd>=0) close(child->error_fd);
    }
cleanup:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    close_pair(input); close_pair(output); close_pair(error);
    if (master>=0) close(master);
    if (slave>=0) close(slave);
    return result;
#undef CHECK
}

int lathe_child_exit(pid_t pid, int32_t *exit_code, int32_t *signal_number) {
    siginfo_t info;
    memset(&info,0,sizeof(info));
    int result;
    do { result=waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT); } while(result<0 && errno==EINTR);
    if (result<0) return -1;
    if (!info.si_pid) return 0;
    *exit_code = info.si_code==CLD_EXITED ? info.si_status : -1;
    *signal_number = info.si_code==CLD_EXITED ? -1 : info.si_status;
    return 1;
}
int lathe_reap(pid_t pid) {
    int status;
    pid_t result;
    do { result=waitpid(pid,&status,0); } while(result<0 && errno==EINTR);
    return result<0 ? errno : 0;
}
int lathe_resize_terminal(int fd, uint16_t columns, uint16_t rows) {
    struct winsize size={.ws_row=rows,.ws_col=columns};
    return ioctl(fd,TIOCSWINSZ,&size)<0 ? errno : 0;
}
void lathe_block_sigpipe_for_thread(void) {
    sigset_t signals;
    sigemptyset(&signals); sigaddset(&signals,SIGPIPE);
    pthread_sigmask(SIG_BLOCK,&signals,NULL);
}
