// podnet.dylib: a pod's own address, on a kernel with no network namespaces.
//
// Injected with DYLD_INSERT_LIBRARIES. A pod that binds the wildcard address
// is bound to FERRY_POD_IP instead, so two pods on one macOS node can both
// listen on :8080; and a socket that connects out without binding first is
// bound to FERRY_POD_IP, so its traffic leaves from the pod's address rather
// than the node's. Loopback is left alone -- it is the node's, as it would be
// in a pod that shares nothing else.
//
// Interposition is a convenience, not a boundary: a process that makes the
// syscall itself goes around it. pf's `user` rules are what enforce it.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#define DYLD_INTERPOSE(replacement, replacee)                                      \
    __attribute__((used)) static struct {                                          \
        const void *r;                                                             \
        const void *e;                                                             \
    } interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {      \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee};

static int pod_address(struct in_addr *a) {
    const char *s = getenv("FERRY_POD_IP");
    return s && inet_pton(AF_INET, s, a) == 1;
}

static int podnet_bind(int fd, const struct sockaddr *sa, socklen_t len) {
    struct in_addr pod;
    if (sa && pod_address(&pod)) {
        if (sa->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) {
            struct sockaddr_in in;
            memcpy(&in, sa, sizeof in);
            if (in.sin_addr.s_addr == htonl(INADDR_ANY)) {
                in.sin_addr = pod;
                return bind(fd, (struct sockaddr *)&in, sizeof in);
            }
        }
        // [::] on a dual-stack socket is the other common "every address".
        // It becomes the pod's address in v4-mapped form.
        if (sa->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6)) {
            struct sockaddr_in6 in6;
            memcpy(&in6, sa, sizeof in6);
            if (IN6_IS_ADDR_UNSPECIFIED(&in6.sin6_addr)) {
                memset(&in6.sin6_addr, 0, sizeof in6.sin6_addr);
                in6.sin6_addr.s6_addr[10] = 0xff;
                in6.sin6_addr.s6_addr[11] = 0xff;
                memcpy(&in6.sin6_addr.s6_addr[12], &pod, 4);
                int off = 0;
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
                return bind(fd, (struct sockaddr *)&in6, sizeof in6);
            }
        }
    }
    return bind(fd, sa, len);
}
DYLD_INTERPOSE(podnet_bind, bind)

// Services. ferry-darwin keeps /lib/ferry-services current, one service port a
// line -- "tcp 10.96.14.2:80 10.190.4.2:8080,10.190.4.3:8080" -- and a connect
// to a ClusterIP is sent to one of its endpoints instead: kube-proxy's job, done
// per socket, since a macOS node has no kernel rules to do it with. The file is
// read on every IPv4 connect: a prototype's price, a few microseconds a socket.
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#define SERVICES "/lib/ferry-services"

static int service_endpoint(int fd, const struct sockaddr_in *dst, struct sockaddr_in *out) {
    int type = 0;
    socklen_t tl = sizeof type;
    getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl);
    const char *proto = type == SOCK_DGRAM ? "udp" : "tcp";

    char want[64], ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &dst->sin_addr, ip, sizeof ip);
    snprintf(want, sizeof want, "%s %s:%d ", proto, ip, ntohs(dst->sin_port));

    // FERRY_SERVICES moves the table, for testing the shim outside a pod.
    const char *table = getenv("FERRY_SERVICES");
    FILE *f = fopen(table ? table : SERVICES, "r");
    if (!f) return 0;
    char line[4096];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, want, strlen(want)) != 0) continue;
        // Endpoints, comma separated; one at random, as kube-proxy's
        // probability rules pick.
        char *eps = line + strlen(want), *choice[64];
        int n = 0;
        for (char *tok = strtok(eps, ",\n"); tok && n < 64; tok = strtok(NULL, ",\n")) choice[n++] = tok;
        if (n == 0) break;
        static int seeded;
        if (!seeded) { srandom((unsigned)time(NULL) ^ (unsigned)getpid()); seeded = 1; }
        char *ep = choice[random() % n], *colon = strrchr(ep, ':');
        if (!colon) break;
        *colon = 0;
        memset(out, 0, sizeof *out);
        out->sin_len = sizeof *out;
        out->sin_family = AF_INET;
        out->sin_port = htons((unsigned short)atoi(colon + 1));
        found = inet_pton(AF_INET, ep, &out->sin_addr) == 1;
        break;
    }
    fclose(f);
    return found;
}

// Whether dst is inside the cluster CIDR (FERRY_CLUSTER_CIDR). A pod's own
// address means something only on the pod network: bound to it, a connection
// to the internet or to the API server's LAN address leaves by the machine
// network with a source nothing out there routes back to, and fails. Outside
// the cluster the node's address is used instead -- what a Linux node's
// masquerade does. With no CIDR given, every connection is bound, as before.
static int in_cluster(const struct in_addr *dst) {
    const char *cidr = getenv("FERRY_CLUSTER_CIDR");
    if (!cidr || !*cidr) return 1;
    char net[32];
    const char *slash = strchr(cidr, '/');
    if (!slash || (size_t)(slash - cidr) >= sizeof net) return 1;
    memcpy(net, cidr, slash - cidr);
    net[slash - cidr] = 0;
    struct in_addr base;
    if (inet_pton(AF_INET, net, &base) != 1) return 1;
    int bits = atoi(slash + 1);
    uint32_t mask = bits <= 0 ? 0 : bits >= 32 ? 0xffffffffu : ~((1u << (32 - bits)) - 1);
    return (ntohl(dst->s_addr) & mask) == (ntohl(base.s_addr) & mask);
}

static int podnet_connect(int fd, const struct sockaddr *sa, socklen_t len) {
    struct in_addr pod;
    struct sockaddr_in service;
    if (sa && sa->sa_family == AF_INET && len >= sizeof(struct sockaddr_in) &&
        service_endpoint(fd, (const struct sockaddr_in *)sa, &service)) {
        sa = (const struct sockaddr *)&service;
        len = sizeof service;
    }
    if (sa && sa->sa_family == AF_INET && pod_address(&pod) &&
        in_cluster(&((const struct sockaddr_in *)sa)->sin_addr)) {
        const struct sockaddr_in *dst = (const struct sockaddr_in *)sa;
        struct sockaddr_in cur;
        socklen_t cl = sizeof cur;
        if ((ntohl(dst->sin_addr.s_addr) >> 24) != 127 &&
            getsockname(fd, (struct sockaddr *)&cur, &cl) == 0 &&
            cur.sin_family == AF_INET && cur.sin_port == 0 && cur.sin_addr.s_addr == 0) {
            struct sockaddr_in src = {.sin_len = sizeof src, .sin_family = AF_INET, .sin_addr = pod};
            bind(fd, (struct sockaddr *)&src, sizeof src);
        }
    }
    return connect(fd, sa, len);
}
DYLD_INTERPOSE(podnet_connect, connect)

// UDP that never connects: each datagram names its destination, so the
// ClusterIP rewrite and the source address have to happen per sendto. A
// socket already bound (by an earlier datagram, or by the program) keeps its
// source; one that is not gets the pod's address for a destination in the
// cluster, as a connect would.
static ssize_t podnet_sendto(int fd, const void *buf, size_t n, int flags,
                             const struct sockaddr *sa, socklen_t len) {
    struct sockaddr_in service;
    if (sa && sa->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) {
        if (service_endpoint(fd, (const struct sockaddr_in *)sa, &service)) {
            sa = (const struct sockaddr *)&service;
            len = sizeof service;
        }
        struct in_addr pod;
        struct sockaddr_in cur;
        socklen_t cl = sizeof cur;
        if (pod_address(&pod) && in_cluster(&((const struct sockaddr_in *)sa)->sin_addr) &&
            getsockname(fd, (struct sockaddr *)&cur, &cl) == 0 &&
            cur.sin_family == AF_INET && cur.sin_port == 0 && cur.sin_addr.s_addr == 0) {
            struct sockaddr_in src = {.sin_len = sizeof src, .sin_family = AF_INET, .sin_addr = pod};
            bind(fd, (struct sockaddr *)&src, sizeof src);
        }
    }
    return sendto(fd, buf, n, flags, sa, len);
}
DYLD_INTERPOSE(podnet_sendto, sendto)
