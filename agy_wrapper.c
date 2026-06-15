#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int is_process_running(const char *pattern) {
    char cmd[256];
    // Use absolute path for pgrep to avoid path resolution issues in Android sh
    snprintf(cmd, sizeof(cmd), "/data/data/com.termux/files/usr/bin/pgrep -f \"%s\" > /dev/null", pattern);
    return system(cmd) == 0;
}

int main(int argc, char *argv[]) {
    // 1. Force Termux PATH and environment variables
    setenv("PATH", "/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets", 1);
    setenv("GEMINI_DIR", "/data/data/com.termux/files/home/.gemini", 1);
    setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/data/data/com.termux/files/usr/tmp/dbus-session.socket", 1);

    int started_daemon = 0;

    // 2. Ensure dbus-daemon session bus is running
    if (!is_process_running("dbus-daemon.*session")) {
        system("rm -f /data/data/com.termux/files/usr/tmp/dbus-session.socket");
        system("/data/data/com.termux/files/usr/bin/dbus-daemon --session --address=unix:path=/data/data/com.termux/files/usr/tmp/dbus-session.socket --fork");
        started_daemon = 1;
    }

    // 3. Ensure dummy-keyring-daemon is running
    if (!is_process_running("dummy-keyring-daemon.py")) {
        system("/data/data/com.termux/files/usr/bin/nohup /data/data/com.termux/files/usr/bin/python3 /data/data/com.termux/files/usr/libexec/dummy-keyring-daemon.py > /dev/null 2>&1 &");
        started_daemon = 1;
    }

    // 4. Wait 400ms if any daemon was newly started to avoid timing issues with socket binding
    if (started_daemon) {
        usleep(400000);
    }

    // 5. Construct arguments for glibc dynamic linker
    char *ld_path = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    char *lib_path = "/data/data/com.termux/files/home/.local/bin/../lib:/data/data/com.termux/files/usr/glibc/lib";
    char *real_binary = "/data/data/com.termux/files/home/.local/bin/agy.va39.real";

    char **new_argv = malloc((argc + 4) * sizeof(char *));
    if (new_argv == NULL) {
        perror("malloc failed");
        return 1;
    }

    new_argv[0] = ld_path;
    new_argv[1] = "--library-path";
    new_argv[2] = lib_path;
    new_argv[3] = real_binary;

    for (int i = 1; i < argc; i++) {
        new_argv[i + 3] = argv[i];
    }
    new_argv[argc + 3] = NULL;

    execv(ld_path, new_argv);

    perror("execv failed");
    free(new_argv);
    return 1;
}
