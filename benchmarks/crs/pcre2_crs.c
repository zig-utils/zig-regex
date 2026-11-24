/*
 * PCRE2 side of benchmarks/crs/compare.sh.
 *
 *   pcre2_crs <work-dir> <jit|interp>
 *
 * Reads the patterns.tsv and inputs.bin that `bench_crs prepare` wrote,
 * compiles each pattern the way ModSecurity compiles @rx (PCRE2_DOTALL |
 * PCRE2_MULTILINE, no UTF, so the subject is bytes), runs pcre2_match once
 * per input and prints the same rows as `bench_crs run`: name, ok or
 * error:<reason>, one 0/1 per input, best pass over all inputs in ns, and the
 * first repetition of the first pass in ns. A pass
 * is timed at least 5 times and for at least 10 ms, and matches every input
 * REPS times (reported per repetition), as in bench_crs.
 */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Times every input is matched within one pass, as in bench_crs. */
#define REPS 16

/* CLOCK_MONOTONIC ticks in whole microseconds on macOS, coarser than many
 * patterns' time; the uptime clock there counts nanoseconds. */
static uint64_t now_ns(void) {
#ifdef __APPLE__
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
#endif
}

static char *read_file(const char *dir, const char *name, size_t *len) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "%s: read failed\n", path);
        exit(2);
    }
    buf[n] = 0;
    fclose(f);
    *len = (size_t)n;
    return buf;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        char version[64];
        pcre2_config(PCRE2_CONFIG_VERSION, version);
        printf("%s\n", version);
        return 0;
    }
    if (argc != 3 || (strcmp(argv[2], "jit") != 0 && strcmp(argv[2], "interp") != 0)) {
        fprintf(stderr, "usage: pcre2_crs <work-dir> <jit|interp> | version\n");
        return 2;
    }
    int jit = strcmp(argv[2], "jit") == 0;

    size_t tsv_len, bin_len;
    char *tsv = read_file(argv[1], "patterns.tsv", &tsv_len);
    const unsigned char *bin = (const unsigned char *)read_file(argv[1], "inputs.bin", &bin_len);

    size_t count = 0, cap = 64;
    const unsigned char **inputs = malloc(cap * sizeof *inputs);
    size_t *lens = malloc(cap * sizeof *lens);
    for (size_t i = 0; i < bin_len;) {
        if (bin_len - i < 4) return 2;
        uint32_t n = (uint32_t)bin[i] | (uint32_t)bin[i + 1] << 8 | (uint32_t)bin[i + 2] << 16 | (uint32_t)bin[i + 3] << 24;
        i += 4;
        if (bin_len - i < n) return 2;
        if (count == cap) {
            cap *= 2;
            inputs = realloc(inputs, cap * sizeof *inputs);
            lens = realloc(lens, cap * sizeof *lens);
        }
        inputs[count] = bin + i;
        lens[count] = n;
        count++;
        i += n;
    }
    char *hits = malloc(count + 1);
    hits[count] = 0;

    pcre2_match_context *mc = pcre2_match_context_create(NULL);
    pcre2_jit_stack *stack = pcre2_jit_stack_create(32 * 1024, 4 * 1024 * 1024, NULL);
    pcre2_jit_stack_assign(mc, NULL, stack);

    for (char *line = strtok(tsv, "\n"); line; line = strtok(NULL, "\n")) {
        char *pattern = strchr(line, '\t');
        if (!pattern) continue;
        *pattern++ = 0;
        const char *name = line;

        int err;
        PCRE2_SIZE err_off;
        pcre2_code *re = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, PCRE2_DOTALL | PCRE2_MULTILINE, &err,
                                       &err_off, NULL);
        if (!re) {
            printf("%s\terror:compile\t-\t0\t0\n", name);
            continue;
        }
        if (jit && pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) != 0) {
            printf("%s\terror:jit\t-\t0\t0\n", name);
            pcre2_code_free(re);
            continue;
        }
        pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);

        uint64_t best = UINT64_MAX, first = 0;
        int failed = 0;
        uint64_t start = now_ns();
        for (int passes = 0; passes < 5 || now_ns() - start < 10000000u; passes++) {
            uint64_t t0 = now_ns();
            for (int r = 0; r < REPS && !failed; r++) {
                for (size_t k = 0; k < count; k++) {
                    int rc = pcre2_match(re, inputs[k], lens[k], 0, 0, md, mc);
                    if (rc < 0 && rc != PCRE2_ERROR_NOMATCH) {
                        failed = rc;
                        break;
                    }
                    hits[k] = rc >= 0 ? '1' : '0';
                }
                /* The very first repetition is the cold one. */
                if (passes == 0 && r == 0) first = now_ns() - t0;
            }
            if (failed) break;
            uint64_t dt = (now_ns() - t0) / REPS;
            if (dt < best) best = dt;
        }
        if (failed)
            printf("%s\terror:match:%d\t-\t0\t0\n", name, failed);
        else
            printf("%s\tok\t%s\t%llu\t%llu\n", name, hits, (unsigned long long)best, (unsigned long long)first);
        fflush(stdout);
        pcre2_match_data_free(md);
        pcre2_code_free(re);
    }
    pcre2_jit_stack_free(stack);
    pcre2_match_context_free(mc);
    return 0;
}
