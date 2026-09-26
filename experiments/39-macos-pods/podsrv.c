// podsrv: an image's workload, written the way ordinary servers are -- it
// binds the wildcard address and knows nothing about pods.
//
//   podsrv serve  NAME          listen on 0.0.0.0:8080, answer with who we are
//   podsrv serve6 NAME          the same on [::]:8080, dual-stack
//   podsrv rogue  IP PORT       explicitly bind someone else's address
//   podsrv get    IP|NAME [PORT [COUNT]]  connect COUNT times, print each reply
//   podsrv kill   PID           try to signal another pod's process
//   podsrv echo   -             copy stdin to stdout, for kubectl exec -i
//   podsrv udp    IP|NAME PORT [MSG]  one datagram with sendto, print the reply
//   podsrv dns    NAME...       what name resolution has inside a pod
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static void serve(int fd, const char *name) {
    listen(fd, 16);
    for (;;) {
        struct sockaddr_storage peer;
        socklen_t pl = sizeof peer;
        int c = accept(fd, (struct sockaddr *)&peer, &pl);
        if (c < 0) continue;
        char host[INET6_ADDRSTRLEN] = "?";
        if (peer.ss_family == AF_INET)
            inet_ntop(AF_INET, &((struct sockaddr_in *)&peer)->sin_addr, host, sizeof host);
        else
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&peer)->sin6_addr, host, sizeof host);
        dprintf(c, "%s (uid %d) sees peer %s\n", name, getuid(), host);
        close(c);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) return 2;
    int one = 1;
    if (!strcmp(argv[1], "serve") || !strcmp(argv[1], "rogue")) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(8080)};
        if (!strcmp(argv[1], "rogue")) {
            inet_pton(AF_INET, argv[2], &a.sin_addr);
            a.sin_port = htons(atoi(argv[3]));
        }
        if (bind(fd, (struct sockaddr *)&a, sizeof a)) { printf("bind: %s\n", strerror(errno)); return 1; }
        struct sockaddr_in got; socklen_t gl = sizeof got;
        getsockname(fd, (struct sockaddr *)&got, &gl);
        char h[INET_ADDRSTRLEN];
        printf("%s asked for %s, is bound to %s:%d\n", argv[2],
               !strcmp(argv[1], "rogue") ? argv[2] : "0.0.0.0",
               inet_ntop(AF_INET, &got.sin_addr, h, sizeof h), ntohs(got.sin_port));
        serve(fd, argv[1][0] == 'r' ? "rogue" : argv[2]);
    }
    if (!strcmp(argv[1], "serve6")) {
        int fd = socket(AF_INET6, SOCK_STREAM, 0);
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in6 a = {.sin6_len = sizeof a, .sin6_family = AF_INET6, .sin6_port = htons(8080)};
        if (bind(fd, (struct sockaddr *)&a, sizeof a)) { printf("bind: %s\n", strerror(errno)); return 1; }
        struct sockaddr_in6 got; socklen_t gl = sizeof got;
        getsockname(fd, (struct sockaddr *)&got, &gl);
        char h[INET6_ADDRSTRLEN];
        printf("%s asked for [::], is bound to [%s]:%d\n", argv[2],
               inet_ntop(AF_INET6, &got.sin6_addr, h, sizeof h), ntohs(got.sin6_port));
        serve(fd, argv[2]);
    }
    if (!strcmp(argv[1], "get")) {
        // COUNT connections, each a fresh socket, so a Service's endpoints
        // show up in turn. An image cannot carry /bin/sh to loop for it.
        int count = argc > 4 ? atoi(argv[4]) : 1, status = 0;
        for (int i = 0; i < count; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET,
                                .sin_port = htons(argc > 3 ? atoi(argv[3]) : 8080)};
        if (inet_pton(AF_INET, argv[2], &a.sin_addr) != 1) {
            // A name: resolved the way any macOS program resolves one, through
            // the node's resolver -- which is how cluster DNS reaches a pod.
            struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *res;
            int rc = getaddrinfo(argv[2], NULL, &hints, &res);
            if (rc) { printf("resolve %s: %s\n", argv[2], gai_strerror(rc)); return 1; }
            a.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
            char h[INET_ADDRSTRLEN];
            printf("%s is %s\n", argv[2], inet_ntop(AF_INET, &a.sin_addr, h, sizeof h));
            freeaddrinfo(res);
        }
        int t = 3;
        setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &t, sizeof t);
        if (connect(fd, (struct sockaddr *)&a, sizeof a)) { printf("connect: %s\n", strerror(errno)); status = 1; close(fd); continue; }
        char buf[256];
        ssize_t n = read(fd, buf, sizeof buf - 1);
        if (n > 0) { buf[n] = 0; printf("%s", buf); }
        close(fd);
        }
        return status;
    }
    if (!strcmp(argv[1], "dns")) {
        // What name resolution has to work with inside a pod's root.
        struct stat st;
        const char *sock = "/var/run/mDNSResponder";
        printf("stat %s: %s\n", sock, stat(sock, &st) ? strerror(errno) :
               S_ISSOCK(st.st_mode) ? "a socket" : "not a socket");
        int u = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un sun = {.sun_family = AF_UNIX};
        strncpy(sun.sun_path, sock, sizeof sun.sun_path - 1);
        printf("connect %s: %s\n", sock, connect(u, (struct sockaddr *)&sun, sizeof sun) ? strerror(errno) : "ok");
        close(u);
        for (int i = 2; i < argc; i++) {
            struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *res;
            int rc = getaddrinfo(argv[i], NULL, &hints, &res);
            char h[INET_ADDRSTRLEN] = "";
            if (!rc) {
                inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, h, sizeof h);
                freeaddrinfo(res);
            }
            printf("getaddrinfo %s: %s %s\n", argv[i], rc ? gai_strerror(rc) : "ok", h);
        }
        return 0;
    }
    if (!strcmp(argv[1], "udp")) {
        // One datagram to IP|NAME:PORT with sendto -- never connected -- and
        // the reply, if one comes within three seconds.
        struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(atoi(argv[3]))};
        if (inet_pton(AF_INET, argv[2], &a.sin_addr) != 1) {
            struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_DGRAM}, *res;
            if (getaddrinfo(argv[2], NULL, &hints, &res)) { printf("resolve %s failed\n", argv[2]); return 1; }
            a.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
            freeaddrinfo(res);
        }
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct timeval tv = {.tv_sec = 3};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        const char *msg = argc > 4 ? argv[4] : "ping";
        if (sendto(fd, msg, strlen(msg), 0, (struct sockaddr *)&a, sizeof a) < 0) { printf("sendto: %s\n", strerror(errno)); return 1; }
        char buf[512];
        ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
        if (n < 0) { printf("no reply: %s\n", strerror(errno)); return 1; }
        buf[n] = 0;
        printf("udp reply: %s%s", buf, buf[n - 1] == '\n' ? "" : "\n");
        return 0;
    }
    if (!strcmp(argv[1], "echo")) {
        // stdin back to stdout, prefixed with who we are: kubectl exec -i.
        char line[1024];
        while (fgets(line, sizeof line, stdin)) printf("pid %d, uid %d read: %s", getpid(), getuid(), line);
        return 0;
    }
    if (!strcmp(argv[1], "kill")) {
        int r = kill(atoi(argv[2]), 0);
        printf("signal pid %s as uid %d: %s\n", argv[2], getuid(), r ? strerror(errno) : "allowed");
        return 0;
    }
    return 2;
}
