#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void dump(const char *prefix, const unsigned char *buf, int len)
{
    printf("%s len=%d", prefix, len);
    for (int i = 0; i < len; ++i) {
        printf(" %02x", buf[i]);
    }
    putchar('\n');
}

static int write_cmd(int fd, const unsigned char *cmd, int len)
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
    dump("write", out, written);
    return 0;
}

static void drain_for(int fd, int milliseconds)
{
    unsigned char buf[64];
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int elapsed = 0;

    while (elapsed < milliseconds) {
        int rc = poll(&pfd, 1, 20);
        elapsed += 20;
        if (rc < 0) {
            printf("poll failed: %s\n", strerror(errno));
            return;
        }
        if (rc == 0) {
            continue;
        }
        if (pfd.revents & POLLIN) {
            int n = read(fd, buf, sizeof(buf));
            if (n > 0) {
                dump("read ", buf, n);
            } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                printf("read failed: %s\n", strerror(errno));
                return;
            }
        }
    }
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/dev/hidraw7";
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        printf("open %s failed: %s\n", path, strerror(errno));
        return 1;
    }

    printf("opened %s\n", path);

    const unsigned char init1[] = { 0x5a, 0xa5, 0x01, 0x02, 0x03 };
    const unsigned char init2[] = { 0x5a, 0xa5, 0xa1, 0x02, 0xa3 };
    const unsigned char init3[] = { 0x5a, 0xa5, 0x02, 0x02, 0x04 };
    const unsigned char init4[] = { 0x5a, 0xa5, 0x04, 0x02, 0x06 };
    const unsigned char enable[] = { 0x5a, 0xa5, 0x11, 0x07, 0xff, 0x01, 0xff, 0xff, 0xff, 0x15, 0x00 };
    const unsigned char *cmds[] = { init1, init2, init3, init4, enable };
    const int lens[] = { sizeof(init1), sizeof(init2), sizeof(init3), sizeof(init4), sizeof(enable) };

    drain_for(fd, 100);
    for (int i = 0; i < 5; ++i) {
        if (write_cmd(fd, cmds[i], lens[i]) < 0) {
            close(fd);
            return 1;
        }
        drain_for(fd, 200);
    }

    printf("listening 20 seconds; press buttons now\n");
    drain_for(fd, 20000);

    close(fd);
    return 0;
}
