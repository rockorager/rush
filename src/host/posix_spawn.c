/* Keep libc's platform-specific spawn attribute layout out of the Zig ABI. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdint.h>

int rush_posix_spawn(pid_t *pid, const char *path, const char *const argv[],
                     const char *const envp[], const uint8_t *default_signals,
                     size_t signal_count)
{
    posix_spawnattr_t attributes;
    sigset_t defaults;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0)
        return error;

    sigemptyset(&defaults);
    for (size_t i = 0; i < signal_count; i++) {
        if (sigaddset(&defaults, default_signals[i]) != 0) {
            error = errno;
            goto done;
        }
    }
    error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (error != 0)
        goto done;
    error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF);
    if (error != 0)
        goto done;

    /* Without SETSIGMASK the child inherits the caller's original mask. */
    error = posix_spawn(pid, path, NULL, &attributes,
                        (char *const *)argv, (char *const *)envp);
done:
    posix_spawnattr_destroy(&attributes);
    return error;
}
