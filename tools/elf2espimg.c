/* Pack a RAM-only Xtensa ELF into an ESP32-S2 ROM boot image (magic 0xE9).
 * Host tool; no Python. See:
 * https://docs.espressif.com/projects/esptool/en/latest/esp32s2/advanced-topics/firmware-image-format.html
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EI_NIDENT 16
#define PT_LOAD 1
#define EM_XTENSA 94
#define MAX_SEG 16
#define ESP32S2_CHIP_ID 2

typedef struct __attribute__((packed)) {
    uint8_t e_ident[EI_NIDENT];
    uint16_t e_type, e_machine;
    uint32_t e_version, e_entry, e_phoff, e_shoff, e_flags;
    uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Elf32_Ehdr;

typedef struct __attribute__((packed)) {
    uint32_t p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align;
} Elf32_Phdr;

typedef struct {
    uint32_t vaddr, filesz, offset;
    uint8_t *data;
} Seg;

static void die(const char *msg) {
    fprintf(stderr, "elf2espimg: %s\n", msg);
    exit(1);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s in.elf out.bin\n", argv[0]);
        return 2;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) die("cannot open elf");

    Elf32_Ehdr eh;
    if (fread(&eh, sizeof eh, 1, in) != 1) die("bad elf header");
    if (memcmp(eh.e_ident, "\x7f""ELF", 4) != 0) die("not ELF");
    if (eh.e_ident[4] != 1) die("need ELF32");
    if (eh.e_machine != EM_XTENSA) die("not Xtensa");

    Seg segs[MAX_SEG];
    int nseg = 0;

    for (int i = 0; i < eh.e_phnum; i++) {
        if (fseek(in, (long)(eh.e_phoff + (uint32_t)i * eh.e_phentsize), SEEK_SET) != 0)
            die("phoff seek");
        Elf32_Phdr ph;
        if (fread(&ph, sizeof ph, 1, in) != 1) die("phdr");
        if (ph.p_type != PT_LOAD || ph.p_filesz == 0) continue;
        if (nseg >= MAX_SEG) die("too many segments");
        segs[nseg].vaddr = ph.p_vaddr;
        segs[nseg].filesz = ph.p_filesz;
        segs[nseg].offset = ph.p_offset;
        segs[nseg].data = malloc(ph.p_filesz);
        if (!segs[nseg].data) die("oom");
        if (fseek(in, (long)ph.p_offset, SEEK_SET) != 0) die("seg seek");
        if (fread(segs[nseg].data, 1, ph.p_filesz, in) != ph.p_filesz) die("seg read");
        nseg++;
    }
    fclose(in);
    if (nseg == 0) die("no loadable segments");

    FILE *out = fopen(argv[2], "wb");
    if (!out) die("cannot write bin");

    uint8_t hdr[8];
    hdr[0] = 0xE9;
    hdr[1] = (uint8_t)nseg;
    hdr[2] = 2;      /* DIO */
    hdr[3] = 0x20;   /* 4 MiB, 40 MHz */
    memcpy(hdr + 4, &eh.e_entry, 4);
    fwrite(hdr, 1, 8, out);

    uint8_t ext[16] = {0};
    ext[0] = 0xEE; /* WP pin disabled */
    ext[4] = (uint8_t)ESP32S2_CHIP_ID;
    ext[5] = 0;
    ext[9] = 0xFF;
    ext[10] = 0xFF;
    ext[15] = 0; /* no SHA-256 footer */
    fwrite(ext, 1, 16, out);

    uint8_t csum = 0xEF;
    for (int i = 0; i < nseg; i++) {
        fwrite(&segs[i].vaddr, 4, 1, out);
        fwrite(&segs[i].filesz, 4, 1, out);
        fwrite(segs[i].data, 1, segs[i].filesz, out);
        for (uint32_t b = 0; b < segs[i].filesz; b++)
            csum ^= segs[i].data[b];
        free(segs[i].data);
    }

    long pos = ftell(out);
    /* pad so size is 16n + 15, then checksum makes a multiple of 16 */
    int pad = (int)((16 - ((pos + 1) % 16)) % 16);
    for (int i = 0; i < pad; i++)
        fputc(0, out);
    fputc(csum, out);
    fclose(out);

    printf("wrote %s (%d segments, entry 0x%08x)\n", argv[2], nseg, eh.e_entry);
    return 0;
}
