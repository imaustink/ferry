// A stand-in for an image's own binary: built here, ad-hoc signed by the
// linker, linked against the OS's libSystem like any macOS program.
//
// It reports what a container would want hidden -- the filesystem root, other
// processes, network interfaces -- using only libSystem, because an Apple
// binary copied into a container is killed before it runs.
#include <dirent.h>
#include <ifaddrs.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    printf("hello from pid %d", getpid());
    if (argc < 2) { printf("\n"); return 0; }

    printf("\n  / holds:");
    DIR *d = opendir("/");
    struct dirent *e;
    while (d && (e = readdir(d))) if (e->d_name[0] != '.') printf(" %s", e->d_name);
    if (d) closedir(d);

    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t len = 0;
    sysctl(mib, 3, NULL, &len, NULL, 0);
    printf("\n  processes visible: %zu\n  interfaces:", len / sizeof(struct kinfo_proc));

    struct ifaddrs *ifs, *i;
    if (getifaddrs(&ifs) == 0) {
        for (i = ifs; i; i = i->ifa_next)
            if (i->ifa_addr && i->ifa_addr->sa_family == AF_LINK) printf(" %s", i->ifa_name);
        freeifaddrs(ifs);
    }
    printf("\n");
    return 0;
}
