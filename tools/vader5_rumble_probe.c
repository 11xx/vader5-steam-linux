#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void msleep(int milliseconds)
{
    struct timespec ts = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (long)(milliseconds % 1000) * 1000000L,
    };

    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
    }
}

static void dump(const char *prefix, const unsigned char *buf, int len)
{
    printf("%s len=%d", prefix, len);
    for (int i = 0; i < len; ++i) {
        printf(" %02x", buf[i]);
    }
    putchar('\n');
}

static int write_cmd(int fd, const unsigned char *cmd, int len, bool verbose)
{
    unsigned char out[32] = { 0 };

    if (len > (int)sizeof(out)) {
        len = sizeof(out);
    }
    memcpy(out, cmd, len);

    int written = write(fd, out, sizeof(out));
    if (written < 0) {
        printf("write failed: %s\n", strerror(errno));
        return -1;
    }
    if (written != (int)sizeof(out)) {
        printf("short write: %d of %zu\n", written, sizeof(out));
        return -1;
    }
    if (verbose) {
        dump("write", out, written);
    }
    return 0;
}

static int send_init_sequence(int fd, bool verbose)
{
    const unsigned char init1[] = { 0x5a, 0xa5, 0x01, 0x02, 0x03 };
    const unsigned char init2[] = { 0x5a, 0xa5, 0xa1, 0x02, 0xa3 };
    const unsigned char init3[] = { 0x5a, 0xa5, 0x02, 0x02, 0x04 };
    const unsigned char init4[] = { 0x5a, 0xa5, 0x04, 0x02, 0x06 };
    const unsigned char enable[] = { 0x5a, 0xa5, 0x11, 0x07, 0xff, 0x01, 0xff, 0xff, 0xff, 0x15, 0x00 };
    const unsigned char *cmds[] = { init1, init2, init3, init4, enable };
    const int lens[] = { sizeof(init1), sizeof(init2), sizeof(init3), sizeof(init4), sizeof(enable) };

    for (int i = 0; i < 5; ++i) {
        if (write_cmd(fd, cmds[i], lens[i], verbose) < 0) {
            return -1;
        }
        msleep(120);
    }
    return 0;
}

static void fill_rumble(unsigned char out[32], int slot, unsigned char value, bool checksum)
{
    memset(out, 0, 32);
    out[0] = 0x5a;
    out[1] = 0xa5;
    out[2] = 0x12;
    out[3] = 0x06;

    if (slot >= 0 && slot < 6) {
        out[4 + slot] = value;
    }

    if (checksum) {
        unsigned int sum = 0;

        for (int i = 2; i < 8; ++i) {
            sum += out[i];
        }
        out[8] = (unsigned char)(sum & 0xff);
    }
}

static int send_rumble_slot(int fd, int slot, unsigned char value, bool checksum, bool verbose)
{
    unsigned char packet[32];

    fill_rumble(packet, slot, value, checksum);
    return write_cmd(fd, packet, sizeof(packet), verbose);
}

static int send_rumble_pair(int fd, int slot_a, int slot_b, unsigned char value, bool checksum, bool verbose)
{
    unsigned char packet[32];

    fill_rumble(packet, -1, 0, checksum);
    if (slot_a >= 0 && slot_a < 6) {
        packet[4 + slot_a] = value;
    }
    if (slot_b >= 0 && slot_b < 6) {
        packet[4 + slot_b] = value;
    }
    if (checksum) {
        unsigned int sum = 0;

        for (int i = 2; i < 8; ++i) {
            sum += packet[i];
        }
        packet[8] = (unsigned char)(sum & 0xff);
    }
    return write_cmd(fd, packet, sizeof(packet), verbose);
}

static void usage(const char *argv0)
{
    printf("usage: %s /dev/hidrawN [--checksum] [--no-init] [--verbose]\n", argv0);
    printf("\n");
    printf("Sweeps the six payload bytes in the Vader 5 rumble command:\n");
    printf("  5a a5 12 06 b0 b1 b2 b3 b4 b5 ...\n");
    printf("\n");
    printf("Close Steam before running this so SDL is not also writing to the device.\n");
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    bool checksum = false;
    bool init = true;
    bool verbose = false;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--checksum") == 0) {
            checksum = true;
        } else if (strcmp(argv[i], "--no-init") == 0) {
            init = false;
        } else if (strcmp(argv[i], "--verbose") == 0) {
            verbose = true;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (!path) {
            path = argv[i];
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    if (!path) {
        usage(argv[0]);
        return 1;
    }

    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        printf("open %s failed: %s\n", path, strerror(errno));
        return 1;
    }

    printf("opened %s\n", path);
    printf("checksum mode: %s\n", checksum ? "on" : "off");

    if (init) {
        printf("sending Vader 5 init/test-mode sequence\n");
        if (send_init_sequence(fd, verbose) < 0) {
            close(fd);
            return 1;
        }
    }

    printf("\n");
    printf("Report which physical motor moves for each slot.\n");
    printf("Known current SDL rumble uses slot 0 and slot 1.\n");
    printf("\n");

    const char *labels[] = {
        "slot 0: raw byte 4, left grip rumble",
        "slot 1: raw byte 5, right grip rumble",
        "slot 2: raw byte 6, left trigger rumble",
        "slot 3: raw byte 7, right trigger rumble",
        "slot 4: raw byte 8, unused/checksum byte",
        "slot 5: raw byte 9, unused in current testing",
    };

    for (int slot = 0; slot < 6; ++slot) {
        printf("%s\n", labels[slot]);
        fflush(stdout);
        if (send_rumble_slot(fd, slot, 0xff, checksum, verbose) < 0) {
            close(fd);
            return 1;
        }
        msleep(900);
        if (send_rumble_slot(fd, -1, 0x00, checksum, verbose) < 0) {
            close(fd);
            return 1;
        }
        msleep(700);
    }

    const int pairs[][2] = {
        { 0, 1 },
        { 2, 3 },
        { 4, 5 },
    };

    printf("\npair checks\n");
    for (int i = 0; i < 3; ++i) {
        printf("slots %d + %d\n", pairs[i][0], pairs[i][1]);
        fflush(stdout);
        if (send_rumble_pair(fd, pairs[i][0], pairs[i][1], 0xff, checksum, verbose) < 0) {
            close(fd);
            return 1;
        }
        msleep(900);
        if (send_rumble_slot(fd, -1, 0x00, checksum, verbose) < 0) {
            close(fd);
            return 1;
        }
        msleep(700);
    }

    printf("\ndone; sending final rumble stop\n");
    send_rumble_slot(fd, -1, 0x00, checksum, verbose);

    close(fd);
    return 0;
}
