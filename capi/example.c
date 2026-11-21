/*------------------------------------------------------------------------------
 * File:         capi/example.c
 *
 * Description:  Example of the lexiftool C API: reads the tags of files
 *               with lexiftool_image_info and prints every field of every
 *               tag, one tag per line. The output format is the one of
 *               capi/info_dump.pl, which does the same through Perl's
 *               Image::ExifTool, so that the two can be compared with diff.
 *
 *               Usage: example [-b] [-o OPTION=VALUE]... [-t TAG]... FILE...
 *                 -b            LEXIFTOOL_INFO_BINARY (all binary values)
 *                 -o OPT=VALUE  lexiftool_set_option before the first file
 *                 -t TAG        a requested tag (for every file)
 *
 *               Output per file:
 *                 == FILE
 *                 # N tags[, error ...][, warning ...]
 *               then per tag, separated by tabs:
 *                 name g0 g1 g2 desc id copy_num binary binary_len value num
 *               with "\\", tab, CR, LF and the other control characters
 *               escaped (\\ \t \r \n \xNN); binary data (binary 2) as
 *               "data:LEN:FNV1A32" instead of the bytes.
 *------------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#  include <fcntl.h>
#  include <io.h>
#endif
#include "lexiftool.h"

static void put_escaped(const char* p, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c == '\\') fputs("\\\\", stdout);
        else if (c == '\t') fputs("\\t", stdout);
        else if (c == '\n') fputs("\\n", stdout);
        else if (c == '\r') fputs("\\r", stdout);
        else if (c < 0x20 || c == 0x7f) printf("\\x%02x", c);
        else putchar(c);
    }
}

static void put_value(const char* p, size_t n, int binary)
{
    if (binary == LEXIFTOOL_BINARY_DATA) {
        unsigned long h = 2166136261UL;
        size_t i;
        for (i = 0; i < n; i++) h = ((h ^ (unsigned char)p[i]) * 16777619UL) & 0xffffffffUL;
        printf("data:%lu:%08lx", (unsigned long)n, h);
    } else {
        put_escaped(p, n);
    }
}

int main(int argc, char** argv)
{
    lexiftool_options opt = { .struct_size = sizeof(opt) };
    lexiftool_session* s;
    const char** tags = calloc((size_t)argc, sizeof(*tags));
    unsigned flags = 0;
    int ntags = 0, i, rc = 0, failed = 0;

#if defined(_WIN32)
    _setmode(_fileno(stdout), _O_BINARY);   /* LF line ends, as the Perl dump */
#endif
    s = lexiftool_open(&opt);
    if (s == NULL || tags == NULL) return 1;
    if (lexiftool_state(s) != LEXIFTOOL_OK) {
        fprintf(stderr, "example: %s\n", lexiftool_last_error(s));
        lexiftool_close(s);
        return 1;
    }
    /* options first, as they apply to all files */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-b") == 0) {
            flags |= LEXIFTOOL_INFO_BINARY;
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            tags[ntags++] = argv[++i];
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            char* name = argv[++i], *eq = strchr(name, '=');
            if (eq != NULL) *eq = '\0';
            if (lexiftool_set_option(s, name, eq != NULL ? eq + 1 : NULL) != LEXIFTOOL_OK) failed = 1;
        }
    }
    for (i = 1; i < argc && !failed; i++) {
        lexiftool_info info;
        size_t k;
        if (strcmp(argv[i], "-b") == 0) continue;
        if (strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "-o") == 0) { i++; continue; }
        rc = lexiftool_image_info(s, argv[i], tags, ntags, flags, &info);
        if (rc != LEXIFTOOL_OK) {
            fprintf(stderr, "example: error %d: %s\n", rc, lexiftool_last_error(s));
            failed = 1;
            break;
        }
        printf("== %s\n# %lu tags", argv[i], (unsigned long)info.count);
        if (info.error) { fputs(", error ", stdout); put_escaped(info.error, strlen(info.error)); }
        if (info.warning) { fputs(", warning ", stdout); put_escaped(info.warning, strlen(info.warning)); }
        putchar('\n');
        for (k = 0; k < info.count; k++) {
            const lexiftool_tag* t = &info.tags[k];
            printf("%s\t%s\t%s\t%s\t", t->name, t->group[0], t->group[1], t->group[2]);
            put_escaped(t->desc, strlen(t->desc));
            putchar('\t');
            put_escaped(t->id, strlen(t->id));
            printf("\t%d\t%d\t%lu\t", t->copy_num, t->binary, (unsigned long)t->binary_len);
            put_value(t->value, t->value_len, t->binary);
            putchar('\t');
            put_value(t->num, t->num_len, t->binary);
            putchar('\n');
        }
        lexiftool_info_free(&info);
    }
    lexiftool_close(s);
    free(tags);
    return failed ? 1 : 0;
}
