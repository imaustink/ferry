// podexec: start one process as a pod on a macOS node.
//
//   podexec <uid> <pod-ip> <root> <cmd> [args...]
//
// The whole of what Darwin offers a shared-kernel runtime without SIP changes,
// in order: a Seatbelt profile confining the filesystem to the OS (read-only)
// and the pod's root (read-write); podnet.dylib giving it its own address; and
// a uid of its own, so it cannot signal or read another pod's processes. Must
// start as root, because of the uid.
#include <limits.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: podexec uid ip root cmd...\n"); return 2; }
    uid_t uid = (uid_t)atoi(argv[1]);
    const char *ip = argv[2], *root = argv[3];
    if (chdir(root)) { perror("chdir"); return 1; }

    char profile[4096];
    snprintf(profile, sizeof profile,
        "(version 1)(deny default)"
        "(allow process-fork process-exec signal sysctl-read mach-lookup ipc-posix-shm)"
        "(allow file-read-metadata)"
        "(allow file-read* (subpath \"/System\") (subpath \"/usr\") (subpath \"/private/etc\")"
        "  (subpath \"/dev\") (literal \"/\") (subpath \"%s\"))"
        "(allow file-map-executable (subpath \"%s\"))"
        "(allow file-write* (subpath \"%s\") (literal \"/dev/null\"))"
        "(allow network*)",
        root, root, root);
    char *err = NULL;
    if (sandbox_init(profile, 0, &err)) { fprintf(stderr, "sandbox: %s\n", err); return 1; }

    char shim[PATH_MAX];
    snprintf(shim, sizeof shim, "%s/lib/podnet.dylib", root);
    setenv("DYLD_INSERT_LIBRARIES", shim, 1);
    setenv("FERRY_POD_IP", ip, 1);
    if (setgroups(0, NULL) || setgid(uid) || setuid(uid)) { perror("drop to pod uid"); return 1; }
    execv(argv[4], argv + 4);
    perror("exec");
    return 127;
}
