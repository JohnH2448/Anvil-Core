// newlib-nano system call stubs for Anvil-Core (bare metal, machine mode,
// one program: exit parks the core in a loop).
//
// newlib's libc calls these underscore functions to reach the "OS". Process
// hooks for running other programs (fork, execve, wait) are left out: with one
// program they are unreachable. If the linker ever reports one missing, add a
// stub that sets errno = ENOSYS and returns -1.
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/times.h>

#include "platform.h"

extern unsigned char __heap_start[];
volatile uint32_t seconds;

void set_interval(uint64_t cycles)
{
    clear_csr(mie, MIP_MTIP);
    if (cycles == 0)
        return;

    // Keep the compare high while replacing its low half.
    CLINT_MTIMECMPH = UINT32_MAX;
    CLINT_MTIMECMP = (uint32_t)cycles;
    CLINT_MTIMECMPH = (uint32_t)(cycles >> 32);
    CLINT_MTIMEH = 0;
    CLINT_MTIME = 0;
    set_csr(mie, MIP_MTIP);
    set_csr(mstatus, MSTATUS_MIE);
}

// Memory management (malloc)
void *_sbrk(ptrdiff_t increment);

// File operations (stdio: printf, puts, getchar; fopen for _open)
int     _open(const char *path, int flags, ...);
int     _close(int fd);
ssize_t _read(int fd, void *buffer, size_t length);
ssize_t _write(int fd, const void *buffer, size_t length);
off_t   _lseek(int fd, off_t offset, int whence);
int     _fcntl(int fd, int command, ...);

// File metadata
int _stat(const char *path, struct stat *status);
int _fstat(int fd, struct stat *status);
int _isatty(int fd);

// Filesystem management (link, unlink/remove, rename, mkdir)
int _link(const char *oldpath, const char *newpath);
int _unlink(const char *path);
int _rename(const char *oldpath, const char *newpath);
int _mkdir(const char *path, mode_t mode);

// Process control: exit loops forever; abort/assert reach _kill(_getpid(), SIGABRT)
void _exit(int status) __attribute__((noreturn));
int  _getpid(void);
int  _kill(int pid, int signal);

// Time management (gettimeofday, time, clock)
int     _gettimeofday(struct timeval *tv, void *tz);
clock_t _times(struct tms *buffer);

// Trap handler called from crt0.S trap_entry.
void trap_handler(unsigned long mcause, unsigned long mepc);

ssize_t _write(int fd, const void *buffer, size_t length)
{
    if (fd != 1 && fd != 2) {
        errno = EBADF;
        return -1;
    }

    const unsigned char *bytes = buffer;
    for (size_t i = 0; i < length; ++i) {
        while (UART_TX_BUSY & 1u) {
        }
        UART_TX_DATA = bytes[i];
    }
    return (ssize_t)length;
}

ssize_t _read(int fd, void *buffer, size_t length)
{
    if (fd != 0) {
        errno = EBADF;
        return -1;
    }
    if (length == 0)
        return 0;

    unsigned char *bytes = buffer;
    size_t count = 0;
    // Wait for the first byte, then drain whatever else is already available.
    while (!(UART_RX_READY & 1u)) {
    }
    do {
        bytes[count++] = (unsigned char)UART_RX_DATA;
    } while (count < length && (UART_RX_READY & 1u));
    return (ssize_t)count;
}

int _isatty(int fd)
{
    if (fd >= 0 && fd <= 2)
        return 1;

    errno = EBADF;
    return 0;
}

int _fstat(int fd, struct stat *status)
{
    if (!_isatty(fd))
        return -1;

    *status = (struct stat){0};
    status->st_mode = S_IFCHR;
    return 0;
}

off_t _lseek(int fd, off_t offset, int whence)
{
    (void)offset;
    (void)whence;
    if (_isatty(fd))
        errno = ESPIPE;
    return -1;
}

int _close(int fd)
{
    if (!_isatty(fd))
        return -1;
    return 0;
}

void *_sbrk(ptrdiff_t increment)
{
    static unsigned char *heap_end = __heap_start;
    uintptr_t start = (uintptr_t)__heap_start;
    uintptr_t current = (uintptr_t)heap_end;
    uintptr_t next;

    if (increment >= 0) {
        uintptr_t growth = (uintptr_t)increment;
        if (growth > (uintptr_t)RAM_END - current) {
            errno = ENOMEM;
            return (void *)-1;
        }
        next = current + growth;
    } else {
        // Avoid negating PTRDIFF_MIN.
        uintptr_t shrink = (uintptr_t)0 - (uintptr_t)increment;
        if (shrink > current - start) {
            errno = EINVAL;
            return (void *)-1;
        }
        next = current - shrink;
    }

    void *previous = heap_end;
    heap_end = (unsigned char *)next;
    return previous;
}

int _fcntl(int fd, int command, ...)
{
    if (!_isatty(fd))
        return -1;

    if (command == F_GETFL)
        return fd == 0 ? O_RDONLY : O_WRONLY;

    errno = ENOSYS;
    return -1;
}

// RAM holds the program and heap. Pathname operations have no filesystem.
int _open(const char *path, int flags, ...)
{
    (void)path;
    (void)flags;
    errno = ENOSYS;
    return -1;
}

int _stat(const char *path, struct stat *status)
{
    (void)path;
    (void)status;
    errno = ENOSYS;
    return -1;
}

int _link(const char *oldpath, const char *newpath)
{
    (void)oldpath;
    (void)newpath;
    errno = ENOSYS;
    return -1;
}

int _unlink(const char *path)
{
    (void)path;
    errno = ENOSYS;
    return -1;
}

int _rename(const char *oldpath, const char *newpath)
{
    (void)oldpath;
    (void)newpath;
    errno = ENOSYS;
    return -1;
}

int _mkdir(const char *path, mode_t mode)
{
    (void)path;
    (void)mode;
    errno = ENOSYS;
    return -1;
}

void _exit(int status)
{
    (void)status;
    for (;;) {
    }
}

int _getpid(void)
{
    return 1;
}

int _kill(int pid, int signal)
{
    if (pid != _getpid()) {
        errno = ESRCH;
        return -1;
    }
    if (signal == 0)
        return 0;

    errno = ENOSYS;
    return -1;
}

int _gettimeofday(struct timeval *tv, void *tz)
{
    (void)tv;
    (void)tz;
    errno = ENOSYS;
    return -1;
}

clock_t _times(struct tms *buffer)
{
    (void)buffer;
    errno = ENOSYS;
    return (clock_t)-1;
}

void trap_handler(unsigned long mcause, unsigned long mepc)
{
    (void)mepc;
    switch (mcause) {
    case MCAUSE_SOFTWARE_IRQ:
        CLINT_MSIP = 0;
        break;
    case MCAUSE_TIMER_IRQ:
        CLINT_MTIMEH = 0;
        CLINT_MTIME = 0;
        ++seconds;
        while (UART_TX_BUSY & 1u) {
        }
        UART_TX_DATA = (uint8_t)seconds;
        break;
    case MCAUSE_EXTERNAL_IRQ:
        // The core clears the latched external interrupt on trap entry.
        break;
    }

    if (mcause & MCAUSE_INTERRUPT)
        return;

    _exit(1);
}
