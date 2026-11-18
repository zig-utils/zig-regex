/*
 * PCRE2 side of benchmarks/pcre2/compare.sh.
 *
 *   pcre2_bench <patterns.txt> <corpus> <jit|interp>
 *   pcre2_bench version
 *
 * Reads the same pattern files as the Zig suite (name<TAB>flags<TAB>pattern
 * <TAB>sample; flags `i` = PCRE2_CASELESS, `s` = PCRE2_DOTALL), compiles each
 * pattern without UTF (so the subject is bytes, like zig-regex byte mode),
 * counts non-overlapping matches over the corpus and prints one TSV row per
 * pattern: name, matches, best pass in ns. The best pass is taken over at
 * least three passes and at least 1 s, as in the Zig suite.
 */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static char *read_file(const char *path, size_t *len) {
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

/* Count non-overlapping matches; -1 on a matching error. */
static long count_matches(pcre2_code *re, pcre2_match_data *md, pcre2_match_context *mc,
                          const unsigned char *subject, size_t len) {
    long n = 0;
    size_t off = 0;
    while (off <= len) {
        int rc = pcre2_match(re, subject, len, off, 0, md, mc);
        if (rc == PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) return -1;
        PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
        n++;
        off = ov[1] > ov[0] ? ov[1] : ov[1] + 1;
    }
    return n;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        char version[64];
        pcre2_config(PCRE2_CONFIG_VERSION, version);
        printf("%s\n", version);
        return 0;
    }
    if (argc != 4 || (strcmp(argv[3], "jit") != 0 && strcmp(argv[3], "interp") != 0)) {
        fprintf(stderr, "usage: pcre2_bench <patterns.txt> <corpus> <jit|interp>\n");
        return 2;
    }
    int jit = strcmp(argv[3], "jit") == 0;
    size_t patterns_len, corpus_len;
    char *patterns = read_file(argv[1], &patterns_len);
    const unsigned char *corpus = (const unsigned char *)read_file(argv[2], &corpus_len);

    pcre2_match_context *mc = pcre2_match_context_create(NULL);
    pcre2_jit_stack *stack = pcre2_jit_stack_create(32 * 1024, 4 * 1024 * 1024, NULL);
    pcre2_jit_stack_assign(mc, NULL, stack);

    for (char *line = strtok(patterns, "\n"); line; line = strtok(NULL, "\n")) {
        if (line[0] == '#' || line[0] == 0) continue;
        char *name = line;
        char *flags = strchr(name, '\t');
        if (!flags) continue;
        *flags++ = 0;
        char *pattern = strchr(flags, '\t');
        if (!pattern) continue;
        *pattern++ = 0;
        char *end = strchr(pattern, '\t');
        if (end) *end = 0;

        uint32_t options = 0;
        if (strchr(flags, 'i')) options |= PCRE2_CASELESS;
        if (strchr(flags, 's')) options |= PCRE2_DOTALL;
        int err;
        PCRE2_SIZE err_off;
        pcre2_code *re = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, options, &err, &err_off, NULL);
        if (!re) {
            printf("%s\terror:compile\t0\n", name);
            continue;
        }
        if (jit && pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) != 0) {
            printf("%s\terror:jit\t0\n", name);
            pcre2_code_free(re);
            continue;
        }
        pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);

        uint64_t best = UINT64_MAX;
        long result = 0;
        uint64_t start = now_ns();
        for (int passes = 0; passes < 3 || now_ns() - start < 1000000000u; passes++) {
            uint64_t t0 = now_ns();
            result = count_matches(re, md, mc, corpus, corpus_len);
            uint64_t dt = now_ns() - t0;
            if (dt < best) best = dt;
            if (result < 0) break;
        }
        if (result < 0)
            printf("%s\terror:match\t0\n", name);
        else
            printf("%s\t%ld\t%llu\n", name, result, (unsigned long long)best);
        fflush(stdout);
        pcre2_match_data_free(md);
        pcre2_code_free(re);
    }
    pcre2_jit_stack_free(stack);
    pcre2_match_context_free(mc);
    return 0;
}
