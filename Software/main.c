#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "platform.h"

enum { WORK_SLOTS = 8, WORK_ROUNDS = 64 };

static volatile int32_t initial_values[WORK_SLOTS] = {
    -37, 19, 103, -211, 7, 83, -9, 41
};
static volatile uint32_t initial_checksum = UINT32_C(0x13579bdf);
static volatile int32_t work_values[WORK_SLOTS];
static volatile unsigned completed_runs;

static void run_workload(void)
{
    uint32_t checksum = initial_checksum;
    for (unsigned slot = 0; slot < WORK_SLOTS; ++slot)
        work_values[slot] = initial_values[slot];

    for (unsigned round = 0; round < WORK_ROUNDS; ++round) {
        unsigned slot = round & (WORK_SLOTS - 1);
        unsigned neighbor = (slot + 3) & (WORK_SLOTS - 1);
        int32_t divisor = 3 + (int32_t)(round & 15);
        int32_t mixed = work_values[slot] * 13 - work_values[neighbor] + (int32_t)round;
        int32_t quotient = mixed / divisor;
        int32_t remainder = mixed % divisor;
        work_values[slot] = quotient - 5 * remainder;

        if (remainder < 0)
            checksum ^= (uint32_t)quotient << slot;
        else
            checksum += ((uint32_t)quotient << 3) ^ (uint32_t)remainder;
        checksum = (checksum << 5) | (checksum >> 27);
    }

    int32_t sum = 0;
    for (unsigned slot = 0; slot < WORK_SLOTS; ++slot)
        sum += work_values[slot];

    unsigned run = ++completed_runs;
    int passed = checksum == UINT32_C(0xbbbd5367) && sum == 4239;
    printf("run %u: checksum=%08lx sum=%ld %s\n", run,
           (unsigned long)checksum, (long)sum, passed ? "PASS" : "FAIL");
    if (!passed)
        puts("Expected checksum=bbbd5367 sum=4239");
}

static int read_line(char *line, size_t capacity)
{
    size_t length = 0;
    int overflow = 0;
    int character;
    while ((character = getchar()) != EOF) {
        if (character == '\r' || character == '\n') {
            putchar('\n');
            line[length] = '\0';
            return overflow ? -1 : 1;
        }
        if (character == '\b' || character == 127) {
            if (!overflow && length != 0) {
                --length;
                fputs("\b \b", stdout);
            }
        } else if (character >= ' ' && character <= '~') {
            if (length + 1 < capacity) {
                line[length++] = (char)character;
                putchar(character);
            } else {
                overflow = 1;
            }
        }
        fflush(stdout);
    }
    return 0;
}

static int parse_number(const char *argument, unsigned limit, unsigned *number)
{
    while (*argument == ' ')
        ++argument;
    if (*argument < '0' || *argument > '9')
        return 0;

    unsigned value = 0;
    while (*argument >= '0' && *argument <= '9') {
        value = value * 10 + (unsigned)(*argument++ - '0');
        if (value > limit)
            return 0;
    }
    while (*argument == ' ')
        ++argument;
    *number = value;
    return *argument == '\0';
}

static void run_command(char *line)
{
    while (*line == ' ')
        ++line;
    if (*line == '\0')
        return;

    char *argument = strchr(line, ' ');
    if (argument != NULL)
        *argument++ = '\0';
    else
        argument = line + strlen(line);

    unsigned n;
    if (strcmp(line, "fib") == 0) {
        if (!parse_number(argument, 47, &n)) {
            puts("Usage: fib <0-47>");
            return;
        }
        unsigned previous = 0;
        unsigned current = 1;
        for (unsigned i = 0; i < n; ++i) {
            unsigned next = previous + current;
            previous = current;
            current = next;
        }
        printf("fib(%u) = %u\n", n, previous);
    } else if (strcmp(line, "fact") == 0) {
        if (!parse_number(argument, 12, &n)) {
            puts("Usage: fact <0-12>");
            return;
        }
        unsigned result = 1;
        for (unsigned i = 2; i <= n; ++i)
            result *= i;
        printf("fact(%u) = %u\n", n, result);
    } else if (strcmp(line, "run") == 0) {
        while (*argument == ' ')
            ++argument;
        if (*argument == '\0')
            run_workload();
        else
            puts("Usage: run");
    } else if (strcmp(line, "help") == 0) {
        puts("Commands: run, fib <0-47>, fact <0-12>, help");
    } else {
        puts("Unknown command. Type help.");
    }
}

int main(void)
{
    char line[64];
    set_interval(UINT64_C(1000000));
    puts("Anvil UART shell. Type help.");
    for (;;) {
        fputs("anvil> ", stdout);
        fflush(stdout);
        int status = read_line(line, sizeof line);
        if (status == 0)
            break;
        if (status < 0)
            puts("Command too long.");
        else if (line[strspn(line, " ")] != '\0') {
            uint32_t elapsed = seconds;
            printf("[%lu s] %s\n", (unsigned long)elapsed, line);
            run_command(line);
        }
    }
    return 0;
}
