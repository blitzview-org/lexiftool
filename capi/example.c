/*------------------------------------------------------------------------------
 * File:         capi/example.c
 *
 * Description:  Example of the lexiftool C API: opens a session, runs
 *               "-j IMAGE" and "-ver", prints each command's stdout to
 *               stdout and its stderr and status to stderr; then reads
 *               IMAGE's tags with lexiftool_image_info (-G1) and prints
 *               the first ones to stderr; closes.
 *               Usage: example [IMAGE]
 *               (default IMAGE: vendor/exiftool/t/images/Canon.jpg)
 *------------------------------------------------------------------------------
 */

#include <stdio.h>
#include "lexiftool.h"

static int run(lexiftool_session* s, int argc, const char* const argv[])
{
    lexiftool_result r;
    int rc = lexiftool_execute(s, argc, argv, &r);
    fwrite(r.stdout_data, 1, r.stdout_len, stdout);
    fflush(stdout);
    fwrite(r.stderr_data, 1, r.stderr_len, stderr);
    if (rc != LEXIFTOOL_OK)
        fprintf(stderr, "example: error %d: %s\n", rc, lexiftool_last_error(s));
    else
        fprintf(stderr, "example: status %d\n", r.status);
    lexiftool_result_free(&r);
    return rc;
}

int main(int argc, char** argv)
{
    const char* image = argc > 1 ? argv[1] : "vendor/exiftool/t/images/Canon.jpg";
    const char* cmd1[] = { "-j", image };
    const char* cmd2[] = { "-ver" };
    lexiftool_options opt = { .struct_size = sizeof(opt) };  /* all defaults */
    lexiftool_session* s;
    int rc;

    fprintf(stderr, "example: lexiftool %s\n", lexiftool_version());
    s = lexiftool_open(&opt);
    if (s == NULL) return 1;
    if (lexiftool_last_error(s) != NULL) {
        fprintf(stderr, "example: %s\n", lexiftool_last_error(s));
        lexiftool_close(s);
        return 1;
    }
    rc = run(s, 2, cmd1);
    if (rc == LEXIFTOOL_OK) rc = run(s, 1, cmd2);
    if (rc == LEXIFTOOL_OK) {
        const char* opts[] = { "-G1" };
        lexiftool_tags t;
        size_t i;
        rc = lexiftool_image_info(s, image, 1, opts, &t);
        if (rc == LEXIFTOOL_OK) {
            fprintf(stderr, "example: image_info: %zu tags, status %d\n", t.count, t.status);
            for (i = 0; i < t.count && i < 5; i++)
                fprintf(stderr, "  [%s] %s = %s\n", t.tags[i].group, t.tags[i].name, t.tags[i].value);
            for (i = 0; i < t.message_count; i++)
                fprintf(stderr, "  %s: %s\n", t.messages[i].level, t.messages[i].text);
        } else {
            fprintf(stderr, "example: image_info error %d: %s\n", rc, lexiftool_last_error(s));
        }
        lexiftool_tags_free(&t);
    }
    lexiftool_close(s);
    return rc == LEXIFTOOL_OK ? 0 : 1;
}
