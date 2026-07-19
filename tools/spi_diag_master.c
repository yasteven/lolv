#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static void die(const char *what) {
    fprintf(stderr, "ERROR: %s: %s\n", what, strerror(errno));
    exit(1);
}

static unsigned long parse_ul(const char *s, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(s, &end, 0);
    if (errno || !end || *end != '\0') {
        fprintf(stderr, "ERROR: invalid %s: %s\n", name, s);
        exit(2);
    }
    return value;
}

static uint8_t parse_byte(const char *s) {
    unsigned long value = parse_ul(s, "byte");
    if (value > 0xff) {
        fprintf(stderr, "ERROR: byte out of range: %s\n", s);
        exit(2);
    }
    return (uint8_t)value;
}

static void print_bytes(const char *label, const uint8_t *buf, size_t len) {
    printf("%s", label);
    for (size_t i = 0; i < len; ++i)
        printf("%s%02x", i ? " " : "", buf[i]);
    putchar('\n');
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s [--device /dev/spidev0.0] [--speed HZ] "
            "[--mode 0] [--delay-usecs N] BYTE [BYTE ...]\n",
            argv[0]);
        return 2;
    }

    const char *device = "/dev/spidev0.0";
    uint32_t speed_hz = 100000;
    uint8_t mode = SPI_MODE_0;
    uint16_t delay_usecs = 0;

    uint8_t tx[4096];
    uint8_t rx[4096];
    size_t len = 0;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--device")) {
            if (++i >= argc) return 2;
            device = argv[i];
        } else if (!strcmp(argv[i], "--speed")) {
            if (++i >= argc) return 2;
            speed_hz = (uint32_t)parse_ul(argv[i], "speed");
        } else if (!strcmp(argv[i], "--mode")) {
            if (++i >= argc) return 2;
            unsigned long m = parse_ul(argv[i], "mode");
            if (m > 3) {
                fprintf(stderr, "ERROR: mode must be 0..3\n");
                return 2;
            }
            mode = (uint8_t)m;
        } else if (!strcmp(argv[i], "--delay-usecs")) {
            if (++i >= argc) return 2;
            delay_usecs = (uint16_t)parse_ul(argv[i], "delay-usecs");
        } else {
            if (len >= sizeof(tx)) {
                fprintf(stderr, "ERROR: too many bytes\n");
                return 2;
            }
            tx[len++] = parse_byte(argv[i]);
        }
    }

    if (len == 0) {
        fprintf(stderr, "ERROR: provide at least one byte\n");
        return 2;
    }

    memset(rx, 0, sizeof(rx));

    int fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) die("open spidev");

    if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0) die("SPI_IOC_WR_MODE");
    if (ioctl(fd, SPI_IOC_RD_MODE, &mode) < 0) die("SPI_IOC_RD_MODE");

    uint8_t bits = 8;
    if (ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0)
        die("SPI_IOC_WR_BITS_PER_WORD");
    if (ioctl(fd, SPI_IOC_RD_BITS_PER_WORD, &bits) < 0)
        die("SPI_IOC_RD_BITS_PER_WORD");

    if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed_hz) < 0)
        die("SPI_IOC_WR_MAX_SPEED_HZ");
    if (ioctl(fd, SPI_IOC_RD_MAX_SPEED_HZ, &speed_hz) < 0)
        die("SPI_IOC_RD_MAX_SPEED_HZ");

    struct spi_ioc_transfer transfer = {
        .tx_buf = (uintptr_t)tx,
        .rx_buf = (uintptr_t)rx,
        .len = (uint32_t)len,
        .speed_hz = speed_hz,
        .delay_usecs = delay_usecs,
        .bits_per_word = bits,
        .cs_change = 0,
    };

    struct timespec before, after;
    clock_gettime(CLOCK_MONOTONIC_RAW, &before);

    int rc = ioctl(fd, SPI_IOC_MESSAGE(1), &transfer);
    if (rc < 0) die("SPI_IOC_MESSAGE(1)");

    clock_gettime(CLOCK_MONOTONIC_RAW, &after);
    close(fd);

    long long elapsed_ns =
        (after.tv_sec - before.tv_sec) * 1000000000LL +
        (after.tv_nsec - before.tv_nsec);

    printf("device=%s mode=%u bits=%u requested_speed_hz=%u "
           "bytes=%zu ioctl_return=%d elapsed_ns=%lld\n",
           device, mode, bits, speed_hz, len, rc, elapsed_ns);
    print_bytes("tx=", tx, len);
    print_bytes("rx=", rx, len);

    if (rc != (int)len) {
        fprintf(stderr,
            "WARNING: ioctl returned %d, expected %zu transferred bytes\n",
            rc, len);
    }

    return 0;
}
