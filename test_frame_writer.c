#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

#define OUT_DIR "/var/mobile/Library/VCam"
#define FRAME_FILE OUT_DIR "/frame.bgra"
#define INFO_FILE OUT_DIR "/frame.info"

int main(int argc, char **argv) {
    int width = argc > 1 ? atoi(argv[1]) : 720;
    int height = argc > 2 ? atoi(argv[2]) : 1280;
    if (width <= 0 || height <= 0) {
        return 1;
    }

    mkdir("/var/mobile/Library", 0755);
    mkdir(OUT_DIR, 0755);

    FILE *frame = fopen(FRAME_FILE, "wb");
    if (!frame) {
        return 2;
    }

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            uint8_t b = (uint8_t)(x * 255 / width);
            uint8_t g = (uint8_t)(y * 255 / height);
            uint8_t r = 80;
            uint8_t a = 255;
            fwrite(&b, 1, 1, frame);
            fwrite(&g, 1, 1, frame);
            fwrite(&r, 1, 1, frame);
            fwrite(&a, 1, 1, frame);
        }
    }
    fclose(frame);

    FILE *info = fopen(INFO_FILE, "w");
    if (!info) {
        return 3;
    }
    fprintf(info, "%d %d 30\n", width, height);
    fclose(info);
    return 0;
}
