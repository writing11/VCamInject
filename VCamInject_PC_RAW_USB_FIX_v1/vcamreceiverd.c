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
#define RAW_MAGIC "VCAMRAW1"
#define RAW_MAGIC_LEN 8
#define RAW_FRAME_MAGIC "FRAM"
#define RAW_FRAME_HEADER_LEN 20
#define MAX_FRAME_BYTES (80U * 1024U * 1024U)
#define OUT_DIR "/var/mobile/Library/VCam"
#define STREAM_FILE OUT_DIR "/stream.h264"
#define FRAME_FILE OUT_DIR "/frame.bgra"
#define FRAME_TMP_FILE OUT_DIR "/frame.bgra.tmp"
#define INFO_FILE OUT_DIR "/frame.info"
#define INFO_TMP_FILE OUT_DIR "/frame.info.tmp"
#define DISABLED_FILE OUT_DIR "/disabled"

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

static uint32_t read_u32_be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) |
           ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) |
           (uint32_t)p[3];
}

static bool write_atomic(const char *tmp_path, const char *final_path, const void *data, size_t len) {
    FILE *out = fopen(tmp_path, "wb");
    if (!out) {
        return false;
    }

    bool ok = fwrite(data, 1, len, out) == len;
    if (fflush(out) != 0) {
        ok = false;
    }
    fclose(out);

    if (!ok) {
        unlink(tmp_path);
        return false;
    }

    if (rename(tmp_path, final_path) != 0) {
        unlink(tmp_path);
        return false;
    }
    return true;
}

static bool write_frame_info(uint32_t width, uint32_t height, uint32_t fps) {
    char info[64];
    int n = snprintf(info, sizeof(info), "%u %u %u\n", width, height, fps);
    if (n <= 0 || n >= (int)sizeof(info)) {
        return false;
    }
    return write_atomic(INFO_TMP_FILE, INFO_FILE, info, (size_t)n);
}

static void handle_raw_client(int fd) {
    ensure_dir();
    unlink(DISABLED_FILE);

    uint8_t header[RAW_FRAME_HEADER_LEN];
    uint8_t *frame = NULL;
    size_t frame_capacity = 0;
    unsigned long long frames = 0;

    fprintf(stdout, "raw frame mode active\n");
    fflush(stdout);

    while (running) {
        ssize_t got = read_exact(fd, header, sizeof(header));
        if (got == 0) {
            break;
        }
        if (got != (ssize_t)sizeof(header)) {
            fprintf(stderr, "bad raw frame header length: %zd\n", got);
            break;
        }
        if (memcmp(header, RAW_FRAME_MAGIC, 4) != 0) {
            fprintf(stderr, "bad raw frame magic\n");
            break;
        }

        uint32_t width = read_u32_be(header + 4);
        uint32_t height = read_u32_be(header + 8);
        uint32_t fps = read_u32_be(header + 12);
        uint32_t payload_len = read_u32_be(header + 16);
        uint64_t expected = (uint64_t)width * (uint64_t)height * 4ULL;

        if (width == 0 || height == 0 || fps == 0 ||
            expected == 0 || expected > MAX_FRAME_BYTES ||
            payload_len != (uint32_t)expected) {
            fprintf(stderr,
                    "invalid raw frame: width=%u height=%u fps=%u payload=%u expected=%llu\n",
                    width,
                    height,
                    fps,
                    payload_len,
                    (unsigned long long)expected);
            break;
        }

        if (frame_capacity < payload_len) {
            uint8_t *next = realloc(frame, payload_len);
            if (!next) {
                fprintf(stderr, "frame allocation failed: %u bytes\n", payload_len);
                break;
            }
            frame = next;
            frame_capacity = payload_len;
        }

        got = read_exact(fd, frame, payload_len);
        if (got != (ssize_t)payload_len) {
            fprintf(stderr, "bad raw frame payload length: %zd\n", got);
            break;
        }

        if (!write_atomic(FRAME_TMP_FILE, FRAME_FILE, frame, payload_len)) {
            fprintf(stderr, "write frame failed: %s\n", strerror(errno));
            break;
        }
        if (!write_frame_info(width, height, fps)) {
            fprintf(stderr, "write frame info failed: %s\n", strerror(errno));
            break;
        }

        frames++;
        if (frames % 120ULL == 0) {
            fprintf(stdout, "raw frames=%llu %ux%u@%u\n", frames, width, height, fps);
            fflush(stdout);
        }
    }

    free(frame);
    fprintf(stdout, "raw client done, frames=%llu\n", frames);
    fflush(stdout);
}

static void handle_legacy_h264_client(int fd, const uint8_t *first, size_t first_len) {
    ensure_dir();
    FILE *out = fopen(STREAM_FILE, "wb");
    if (!out) {
        fprintf(stderr, "open stream failed: %s\n", strerror(errno));
        return;
    }

    if (first_len > 0) {
        fwrite(first, 1, first_len, out);
    }

    uint8_t *buf = malloc(BUFFER_SIZE);
    if (!buf) {
        fclose(out);
        return;
    }

    unsigned long long total = (unsigned long long)first_len;
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
            fprintf(stdout, "received legacy stream %llu bytes\n", total);
            fflush(stdout);
        }
    }

    fflush(out);
    free(buf);
    fclose(out);
    fprintf(stdout, "legacy client done, total=%llu\n", total);
    fflush(stdout);
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

    uint8_t prefix[RAW_MAGIC_LEN];
    got = read_exact(fd, prefix, sizeof(prefix));
    if (got == 0) {
        return;
    }
    if (got != (ssize_t)sizeof(prefix)) {
        fprintf(stderr, "bad post-handshake prefix length: %zd\n", got);
        return;
    }

    if (memcmp(prefix, RAW_MAGIC, RAW_MAGIC_LEN) == 0) {
        handle_raw_client(fd);
    } else {
        handle_legacy_h264_client(fd, prefix, sizeof(prefix));
    }
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
