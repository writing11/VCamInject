#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <dlfcn.h>
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
#include <time.h>
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
#define DEVICE_FILE OUT_DIR "/device.id"
#define DEVICE_TMP_FILE OUT_DIR "/device.id.tmp"
#define LICENSE_FILE OUT_DIR "/license.key"
#define LICENSE_TMP_FILE OUT_DIR "/license.key.tmp"
#define TRIAL_FILE OUT_DIR "/trial.start"
#define TRIAL_TMP_FILE OUT_DIR "/trial.start.tmp"
#define CONTROL_MAGIC "VCAMCTL1"
#define CONTROL_MAGIC_LEN 8
#define MAX_STATE_BYTES 4096
#define DEVICE_ID_HEX_BYTES 16

static volatile sig_atomic_t running = 1;

static bool read_state_file(const char *path, char **out, size_t *out_len);
static bool write_atomic(const char *tmp_path, const char *final_path, const void *data, size_t len);

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

static void ensure_dir(void) {
    mkdir("/var/mobile/Library", 0755);
    mkdir(OUT_DIR, 0755);
    chmod(OUT_DIR, 0777);
}

static bool is_valid_device_id(const char *data, size_t len) {
    size_t count = 0;
    for (size_t i = 0; i < len; i++) {
        char c = data[i];
        bool ok = (c >= '0' && c <= '9') ||
                  (c >= 'A' && c <= 'Z') ||
                  (c >= 'a' && c <= 'z');
        if (!ok) {
            continue;
        }
        count++;
    }
    return count >= 16;
}

static size_t normalized_alnum_upper(const char *in, char *out, size_t out_cap) {
    if (!in || !out || out_cap == 0) {
        return 0;
    }

    size_t len = 0;
    for (size_t i = 0; in[i] && len + 1 < out_cap; i++) {
        unsigned char c = (unsigned char)in[i];
        if (isalnum(c)) {
            out[len++] = (char)toupper(c);
        }
    }
    out[len] = '\0';
    return len;
}

static bool append_material_value(CFTypeRef value, char *material, size_t material_cap, size_t *count) {
    if (!value || !material || !count || material_cap == 0) {
        return false;
    }

    char raw[512] = {0};
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, raw, sizeof(raw), kCFStringEncodingUTF8);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        long long number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &number);
        snprintf(raw, sizeof(raw), "%lld", number);
    } else {
        CFStringRef desc = CFCopyDescription(value);
        if (desc) {
            CFStringGetCString(desc, raw, sizeof(raw), kCFStringEncodingUTF8);
            CFRelease(desc);
        }
    }

    char normalized[512] = {0};
    size_t normalized_len = normalized_alnum_upper(raw, normalized, sizeof(normalized));
    if (normalized_len < 6 ||
        strcmp(normalized, "0") == 0 ||
        strcmp(normalized, "1") == 0 ||
        strcmp(normalized, "UNKNOWN") == 0) {
        return false;
    }

    if (strstr(material, normalized)) {
        return false;
    }

    size_t current = strlen(material);
    int written = snprintf(material + current, material_cap - current, "%s|", normalized);
    if (written <= 0 || (size_t)written >= material_cap - current) {
        return false;
    }

    (*count)++;
    return true;
}

static bool stable_hardware_device_id(char out[DEVICE_ID_HEX_BYTES * 2 + 1]) {
    typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    MGCopyAnswerFunc copyAnswer = handle ? (MGCopyAnswerFunc)dlsym(handle, "MGCopyAnswer") : NULL;
    if (!copyAnswer) {
        return false;
    }

    const char *keys[] = {
        "UniqueDeviceID",
        "re6Zb+zwFKJNlkQTUeT+/w",
        "SerialNumber",
        "VasUgeSzVyHdB27g2XpN0g",
        "UniqueChipID",
        "aK5A62T7R++lRD3kS+oCfg",
        "DieID",
        "InternationalMobileEquipmentIdentity"
    };

    char material[2048] = {0};
    size_t count = 0;
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keys[i], kCFStringEncodingUTF8);
        if (!key) {
            continue;
        }
        CFTypeRef answer = copyAnswer(key);
        CFRelease(key);
        if (!answer) {
            continue;
        }
        append_material_value(answer, material, sizeof(material), &count);
        CFRelease(answer);
    }

    char normalized_material[2048] = {0};
    size_t material_len = normalized_alnum_upper(material, normalized_material, sizeof(normalized_material));
    if (count == 0 || material_len < 12) {
        return false;
    }

    char message[2300] = {0};
    snprintf(message, sizeof(message), "VCAMDEVICE|V3|%s", material);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(message, (CC_LONG)strlen(message), digest);

    static const char hex[] = "0123456789ABCDEF";
    for (size_t i = 0; i < DEVICE_ID_HEX_BYTES; i++) {
        out[i * 2] = hex[(digest[i] >> 4) & 0x0f];
        out[i * 2 + 1] = hex[digest[i] & 0x0f];
    }
    out[DEVICE_ID_HEX_BYTES * 2] = '\0';
    return true;
}

static bool ensure_device_id(void) {
    char *existing = NULL;
    size_t existing_len = 0;
    if (read_state_file(DEVICE_FILE, &existing, &existing_len)) {
        bool valid = is_valid_device_id(existing, existing_len);
        free(existing);
        if (valid) {
            chmod(DEVICE_FILE, 0666);
            return true;
        }
    }

    char stable_id[DEVICE_ID_HEX_BYTES * 2 + 1] = {0};
    if (stable_hardware_device_id(stable_id)) {
        return write_atomic(DEVICE_TMP_FILE, DEVICE_FILE, stable_id, strlen(stable_id));
    }

    uint8_t random_bytes[DEVICE_ID_HEX_BYTES];
    FILE *urandom = fopen("/dev/urandom", "rb");
    if (urandom) {
        size_t got = fread(random_bytes, 1, sizeof(random_bytes), urandom);
        fclose(urandom);
        if (got != sizeof(random_bytes)) {
            urandom = NULL;
        }
    }

    if (!urandom) {
        unsigned long seed = (unsigned long)time(NULL) ^ (unsigned long)getpid();
        for (size_t i = 0; i < sizeof(random_bytes); i++) {
            seed = seed * 1103515245UL + 12345UL;
            random_bytes[i] = (uint8_t)((seed >> 16) & 0xff);
        }
    }

    char device_id[DEVICE_ID_HEX_BYTES * 2 + 1];
    static const char hex[] = "0123456789ABCDEF";
    for (size_t i = 0; i < sizeof(random_bytes); i++) {
        device_id[i * 2] = hex[(random_bytes[i] >> 4) & 0x0f];
        device_id[i * 2 + 1] = hex[random_bytes[i] & 0x0f];
    }
    device_id[sizeof(device_id) - 1] = '\0';
    return write_atomic(DEVICE_TMP_FILE, DEVICE_FILE, device_id, strlen(device_id));
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

static bool send_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

static ssize_t read_line(int fd, char *buf, size_t cap) {
    if (cap == 0) {
        return -1;
    }

    size_t len = 0;
    while (len + 1 < cap) {
        char c = 0;
        ssize_t n = recv(fd, &c, 1, 0);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (c == '\n') {
            break;
        }
        buf[len++] = c;
    }
    buf[len] = '\0';
    return (ssize_t)len;
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
    chmod(final_path, 0666);
    return true;
}

static const char *state_path_for_key(const char *key) {
    if (strcmp(key, "device.id") == 0) {
        return DEVICE_FILE;
    }
    if (strcmp(key, "license.key") == 0) {
        return LICENSE_FILE;
    }
    if (strcmp(key, "trial.start") == 0) {
        return TRIAL_FILE;
    }
    return NULL;
}

static const char *state_tmp_path_for_key(const char *key) {
    if (strcmp(key, "device.id") == 0) {
        return DEVICE_TMP_FILE;
    }
    if (strcmp(key, "license.key") == 0) {
        return LICENSE_TMP_FILE;
    }
    if (strcmp(key, "trial.start") == 0) {
        return TRIAL_TMP_FILE;
    }
    return NULL;
}

static bool read_state_file(const char *path, char **out, size_t *out_len) {
    FILE *in = fopen(path, "rb");
    if (!in) {
        return false;
    }

    if (fseek(in, 0, SEEK_END) != 0) {
        fclose(in);
        return false;
    }
    long size = ftell(in);
    if (size < 0 || size > (long)MAX_STATE_BYTES) {
        fclose(in);
        return false;
    }
    rewind(in);

    char *data = calloc((size_t)size + 1, 1);
    if (!data) {
        fclose(in);
        return false;
    }

    size_t got = fread(data, 1, (size_t)size, in);
    fclose(in);
    if (got != (size_t)size) {
        free(data);
        return false;
    }

    while (got > 0 && (data[got - 1] == '\n' || data[got - 1] == '\r' || data[got - 1] == ' ' || data[got - 1] == '\t')) {
        data[--got] = '\0';
    }

    *out = data;
    *out_len = got;
    return true;
}

static void handle_control_client(int fd) {
    ensure_dir();
    ensure_device_id();
    if (!ack(fd)) {
        return;
    }

    char line[256];
    if (read_line(fd, line, sizeof(line)) <= 0) {
        return;
    }

    char command[16] = {0};
    char key[64] = {0};
    unsigned int len = 0;
    int parsed = sscanf(line, "%15s %63s %u", command, key, &len);
    const char *path = state_path_for_key(key);
    const char *tmp_path = state_tmp_path_for_key(key);

    if (parsed >= 2 && strcmp(command, "GET") == 0 && path) {
        char *data = NULL;
        size_t data_len = 0;
        if (!read_state_file(path, &data, &data_len)) {
            send_all(fd, "NO 0\n", 5);
            return;
        }

        char header[64];
        int n = snprintf(header, sizeof(header), "OK %zu\n", data_len);
        if (n > 0 && n < (int)sizeof(header)) {
            send_all(fd, header, (size_t)n);
            if (data_len > 0) {
                send_all(fd, data, data_len);
            }
        }
        free(data);
        return;
    }

    if (parsed == 3 && strcmp(command, "SET") == 0 && path && tmp_path && len <= MAX_STATE_BYTES) {
        char *data = calloc((size_t)len + 1, 1);
        if (!data) {
            send_all(fd, "ERR 0\n", 6);
            return;
        }
        ssize_t got = read_exact(fd, data, (size_t)len);
        bool ok = got == (ssize_t)len && write_atomic(tmp_path, path, data, (size_t)len);
        free(data);
        send_all(fd, ok ? "OK 0\n" : "ERR 0\n", ok ? 5 : 6);
        return;
    }

    if (parsed >= 2 && strcmp(command, "DEL") == 0 && path) {
        unlink(path);
        send_all(fd, "OK 0\n", 5);
        return;
    }

    send_all(fd, "ERR 0\n", 6);
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

    if (memcmp(handshake, CONTROL_MAGIC, CONTROL_MAGIC_LEN) == 0) {
        handle_control_client(fd);
        return;
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
    ensure_device_id();

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
