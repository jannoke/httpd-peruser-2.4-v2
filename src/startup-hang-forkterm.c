/* LD_PRELOAD for startup-hang-test.sh: wraps fork() in httpd. Each child logs
 * "<pid> <fork time, µs since the epoch> <delay µs or -1>" to FT_LOG, and with
 * probability FT_RATIO arms a POSIX timer that sends the child a SIGTERM
 * FT_MAX_US µs or less after the fork. The signal is process-directed, like
 * peruser's kill(-pid, SIGTERM): any thread that doesn't block it may take it.
 * httpd's own code is untouched.
 *
 *   gcc -shared -fPIC -O2 -o /tmp/forkterm.so startup-hang-forkterm.c -ldl -lrt
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

pid_t fork(void)
{
    static pid_t (*real_fork)(void);
    if (!real_fork)
        real_fork = (pid_t (*)(void))dlsym(RTLD_NEXT, "fork");

    pid_t pid = real_fork();
    if (pid != 0)
        return pid;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    const char *ratio_s = getenv("FT_RATIO"), *max_s = getenv("FT_MAX_US"), *log = getenv("FT_LOG");
    double ratio = ratio_s ? atof(ratio_s) : 0;
    long max_us = max_s ? atol(max_s) : 0;
    unsigned seed = (unsigned)(getpid() * 2654435761u) ^ (unsigned)tv.tv_usec;
    long delay = -1;

    if (ratio > 0 && max_us > 0 && (double)rand_r(&seed) / RAND_MAX < ratio) {
        timer_t t;
        struct sigevent sev;
        struct itimerspec its;
        memset(&sev, 0, sizeof(sev));
        sev.sigev_notify = SIGEV_SIGNAL;
        sev.sigev_signo = SIGTERM;
        delay = 1 + (long)((double)rand_r(&seed) / RAND_MAX * max_us);
        memset(&its, 0, sizeof(its));
        its.it_value.tv_sec = delay / 1000000;
        its.it_value.tv_nsec = (delay % 1000000) * 1000;
        if (timer_create(CLOCK_MONOTONIC, &sev, &t) != 0 || timer_settime(t, 0, &its, NULL) != 0)
            delay = -2;
    }
    if (log) {
        char line[96];
        int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0666);
        if (fd >= 0) {
            int n = snprintf(line, sizeof(line), "%d %lld %ld\n", (int)getpid(),
                             (long long)tv.tv_sec * 1000000 + tv.tv_usec, delay);
            if (write(fd, line, n) < 0) { /* nothing to do */ }
            close(fd);
        }
    }
    return 0;
}
