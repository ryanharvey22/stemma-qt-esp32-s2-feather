/* Convert a raw .bin into a UF2 for TinyUF2 (ESP32-S2 family 0xbfdd4eee). */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FAMILY 0xbfdd4eeeU
#define PAYLOAD 256
#define FLAGS 0x2000 /* family ID present */

int main(int argc, char **argv) {
    uint32_t base = 0x10000;
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s in.bin out.uf2 [flash_addr]\n", argv[0]);
        return 2;
    }
    if (argc == 4)
        base = (uint32_t)strtoul(argv[3], NULL, 0);

    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        perror(argv[1]);
        return 1;
    }
    fseek(in, 0, SEEK_END);
    long sz = ftell(in);
    fseek(in, 0, SEEK_SET);
    if (sz <= 0) {
        fprintf(stderr, "empty input\n");
        return 1;
    }

    uint8_t *bin = malloc((size_t)sz);
    if (!bin || fread(bin, 1, (size_t)sz, in) != (size_t)sz) {
        fprintf(stderr, "read failed\n");
        return 1;
    }
    fclose(in);

    uint32_t nblocks = (uint32_t)((sz + PAYLOAD - 1) / PAYLOAD);
    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        perror(argv[2]);
        return 1;
    }

    for (uint32_t i = 0; i < nblocks; i++) {
        uint8_t blk[512];
        memset(blk, 0, sizeof blk);
        uint32_t *w = (uint32_t *)blk;
        w[0] = 0x0A324655;
        w[1] = 0x9E5D5157;
        w[2] = FLAGS;
        w[3] = base + i * PAYLOAD;
        uint32_t remain = (uint32_t)sz - i * PAYLOAD;
        w[4] = remain > PAYLOAD ? PAYLOAD : remain;
        w[5] = i;
        w[6] = nblocks;
        w[7] = FAMILY;
        memcpy(blk + 32, bin + i * PAYLOAD, w[4]);
        w = (uint32_t *)(blk + 512 - 4);
        *w = 0x0AB16F30;
        fwrite(blk, 1, 512, out);
    }
    fclose(out);
    free(bin);
    printf("wrote %s (%u blocks, base 0x%x)\n", argv[2], nblocks, base);
    return 0;
}
