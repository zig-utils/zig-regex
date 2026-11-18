/*
 * PCRE2 side of benchmarks/pcre2/diff.sh: the reference spans for the
 * leftmost-first differential test of zig-regex programs.
 *
 *   pcre2_spans < cases.tsv > spans.tsv
 *
 * Each input line is flags<TAB>pattern-hex<TAB>subject-hex (flags: any of
 * `i` caseless, `m` multiline, `s` dotall, or `-`). Each output line is the
 * `g`-style list of matches: start and end of every non-overlapping match,
 * space separated, found with the same loop as pcre2_bench.c (after an empty
 * match the next search starts one byte later), or `error` when PCRE2 refuses
 * the pattern or a match fails. Subjects are bytes (no UTF).
 *
 * PCRE2_DOLLAR_ENDONLY and PCRE2_ALT_CIRCUMFLEX give `$` and multiline `^`
 * the conventions zig-regex uses (`$` only at the very end; `^` after every
 * newline, a final one included), so the comparison measures match-kind
 * semantics, not those two anchor conventions.
 */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decode hex in place; returns the byte length, or -1. */
static long unhex(char *s) {
    size_t n = strlen(s);
    if (n % 2) return -1;
    for (size_t i = 0; i < n; i += 2) {
        int hi = hexval((unsigned char)s[i]), lo = hexval((unsigned char)s[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        s[i / 2] = (char)(hi * 16 + lo);
    }
    return (long)(n / 2);
}

int main(void) {
    static char line[1 << 20];
    while (fgets(line, sizeof line, stdin)) {
        size_t len = strlen(line);
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
        char *flags = line;
        char *pattern = strchr(flags, '\t');
        if (!pattern) { puts("error"); continue; }
        *pattern++ = 0;
        char *subject = strchr(pattern, '\t');
        if (!subject) { puts("error"); continue; }
        *subject++ = 0;
        long plen = unhex(pattern), slen = unhex(subject);
        if (plen < 0 || slen < 0) { puts("error"); continue; }

        uint32_t options = PCRE2_DOLLAR_ENDONLY | PCRE2_ALT_CIRCUMFLEX;
        if (strchr(flags, 'i')) options |= PCRE2_CASELESS;
        if (strchr(flags, 'm')) options |= PCRE2_MULTILINE;
        if (strchr(flags, 's')) options |= PCRE2_DOTALL;
        int err;
        PCRE2_SIZE err_off;
        pcre2_code *re = pcre2_compile((PCRE2_SPTR)pattern, (PCRE2_SIZE)plen, options, &err, &err_off, NULL);
        if (!re) { puts("error"); continue; }
        pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
        const unsigned char *s = (const unsigned char *)subject;
        size_t off = 0;
        int failed = 0, first = 1;
        static char out[1 << 16];
        size_t used = 0;
        out[0] = 0;
        while (off <= (size_t)slen) {
            int rc = pcre2_match(re, s, (PCRE2_SIZE)slen, off, 0, md, NULL);
            if (rc == PCRE2_ERROR_NOMATCH) break;
            if (rc < 0) { failed = 1; break; }
            PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
            if (used + 48 < sizeof out)
                used += (size_t)snprintf(out + used, sizeof out - used, "%s%zu %zu", first ? "" : " ", (size_t)ov[0], (size_t)ov[1]);
            first = 0;
            off = ov[1] > ov[0] ? ov[1] : ov[1] + 1;
        }
        puts(failed ? "error" : out);
        pcre2_match_data_free(md);
        pcre2_code_free(re);
    }
    return 0;
}
