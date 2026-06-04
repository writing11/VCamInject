#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define VCAM_PORT 9999
#define HANDSHAKE_LEN 44
#define BUFFER_SIZE 262144
#define OUT_DIR "/var/mobile/Library/VCam"
#define STREAM_FILE OUT_DIR "/stream.h264"

static volatile sig_atomic_t running = 1;

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

static void ensure_dir(void) {
    mkdir("/var/mobile/Library", 0755);
    mkdir(OUT_DIR, 0755);
}

static ssize_t read_exact(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;

    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n == 0) {
            return 0;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        got += (size_t)n;
    }

    return (ssize_t)got;
}

static bool ack(int fd) {
    uint8_t ok = 0x01;
    return send(fd, &ok, 1, 0) == 1;
}

static void handle_client(int fd) {
    uint8_t handshake[HANDSHAKE_LEN];
    ssize_t got = read_exact(fd, handshake, sizeof(handshake));
    if (got != HANDSHAKE_LEN) {
        fprintf(stderr, "bad handshake length: %zd\n", got);
        return;
    }

    if (memcmp(handshake, "VCAM", 4) != 0) {
        fprintf(stderr, "warning: unknown handshake magic\n");
    }

    if (!ack(fd)) {
        fprintf(stderr, "ack failed: %s\n", strerror(errno));
        return;
    }

    ensure_dir();
    FILE *out = fopen(STREAM_FILE, "wb");
    if (!out) {
        fprintf(stderr, "open stream failed: %s\n", strerror(errno));
        return;
    }

    uint8_t *buf = malloc(BUFFER_SIZE);
    if (!buf) {
        fclose(out);
        return;
    }

    unsigned long long total = 0;
    while (running) {
        ssize_t n = recv(fd, buf, BUFFER_SIZE, 0);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "recv failed: %s\n", strerror(errno));
            break;
        }

        fwrite(buf, 1, (size_t)n, out);
        total += (unsigned long long)n;
        if ((total % (8ULL * 1024ULL * 1024ULL)) < (unsigned long long)n) {
            fflush(out);
            fprintf(stdout, "received %llu bytes\n", total);
            fflush(stdout);
        }
    }

    fflush(out);
    free(buf);
    fclose(out);
    fprintf(stdout, "client done, total=%llu\n", total);
    fflush(stdout);
}

static int listen_socket(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(VCAM_PORT);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(void) {
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);
    ensure_dir();

    int server = listen_socket();
    if (server < 0) {
        fprintf(stderr, "listen %d failed: %s\n", VCAM_PORT, strerror(errno));
        return 1;
    }

    fprintf(stdout, "vcamreceiverd listening on %d\n", VCAM_PORT);
    fflush(stdout);

    while (running) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "accept failed: %s\n", strerror(errno));
            sleep(1);
            continue;
        }
        handle_client(client);
        close(client);
    }

    close(server);
    return 0;
}
