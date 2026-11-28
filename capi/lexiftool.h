/*------------------------------------------------------------------------------
 * File:         capi/lexiftool.h
 *
 * Description:  C API of lexiftool: exiftool as an in-process library.
 *               A session is one lexiftool instance -- an own Lua state
 *               running the command-line script in its -stay_open command
 *               loop, plus one ExifTool object of the library -- into which
 *               the caller hands
 *               - a command as an argument list or as argfile text, and
 *                 gets that command's stdout, stderr and exit status back
 *                 (lexiftool_execute, lexiftool_execute_text), or
 *               - a file plus an optional list of tags, and gets the tags
 *                 back as entries with name, groups, description, ID,
 *                 converted and numerical value, straight from the
 *                 library's ImageInfo (lexiftool_image_info), or
 *               - new values (lexiftool_set_new_value) and then a file to
 *                 write them to (lexiftool_write_info),
 *               with the options of the session's ExifTool object set by
 *               lexiftool_set_option. Everything runs synchronously in the
 *               calling thread.
 *
 *               Rules:
 *               - Any number of sessions per process, each used from one
 *                 thread at a time (the caller serializes); different
 *                 sessions may run in different threads at the same time.
 *                 The library starts no threads and has no asynchronous,
 *                 timeout or cancel mechanism.
 *               - Strings are byte strings, passed on unchanged (file names
 *                 and tag values are bytes, as for exiftool; see -charset).
 *                 Where a length comes with a string, the length counts and
 *                 the bytes may contain NUL.
 *               - Memory: the caller owns what it passes in; the library
 *                 owns the session; a result belongs to the caller until
 *                 lexiftool_result_free()/lexiftool_info_free().
 *
 *               See doc/capi.md.
 *------------------------------------------------------------------------------
 */

#ifndef LEXIFTOOL_H
#define LEXIFTOOL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Exported symbols (the shared library exports nothing else). Windows:
 * a program that links the DLL (lexiftool.dll through its import library)
 * gets __declspec(dllimport); one that links the static library defines
 * LEXIFTOOL_STATIC (pkg-config --static --cflags does); the library itself
 * is compiled with LEXIFTOOL_BUILD_DLL or LEXIFTOOL_STATIC. */
#if defined(_WIN32) || defined(__CYGWIN__)
#  if defined(LEXIFTOOL_BUILD_DLL)
#    define LEXIFTOOL_API __declspec(dllexport)
#  elif defined(LEXIFTOOL_STATIC)
#    define LEXIFTOOL_API
#  else
#    define LEXIFTOOL_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__)
#  define LEXIFTOOL_API __attribute__((visibility("default")))
#else
#  define LEXIFTOOL_API
#endif

/* Version of this C API (incremented on incompatible changes). */
#define LEXIFTOOL_API_VERSION 3

/* Return codes (negative). */
#define LEXIFTOOL_OK         0    /* success                                */
#define LEXIFTOOL_E_ARG     -1    /* invalid argument (NULL session, NULL
                                     file, ...)                             */
#define LEXIFTOOL_E_NOMEM   -2    /* out of memory; the session stays
                                     usable                                 */
#define LEXIFTOOL_E_FAILED  -3    /* a Lua error in the session, or a failed
                                     start; the session is unusable from
                                     now on (lexiftool_last_error())        */
#define LEXIFTOOL_E_ENDED   -4    /* the session's command loop has ended (a
                                     command contained "-stay_open False");
                                     the session is unusable from now on    */

/* Length argument for a NUL-terminated string. */
#define LEXIFTOOL_NUL_TERMINATED ((size_t)-1)

typedef struct lexiftool_session lexiftool_session;

/* Settings of a session. Zero-initialize, set struct_size, then set what
 * is needed; every other field may stay 0/NULL. Copied during
 * lexiftool_open(). */
typedef struct lexiftool_options {
    size_t              struct_size;    /* sizeof(lexiftool_options) (fields
                                           beyond it count as 0), or 0 for
                                           the whole struct               */
    /* exiftool -config FILE (must come first on exiftool's command line):
     * NULL = the default config file lookup (.lexiftool_config, then
     * .ExifTool_config), "" = no config file */
    const char*         config_file;
    /* arguments common to all commands of lexiftool_execute*(), as after
     * exiftool's -common_args (e.g. "-G", "-n", "-charset", "filename=utf8") */
    int                 common_argc;
    const char* const*  common_argv;
    /* build variant "rock" only (modules loaded from the file system):
     * package.path / package.cpath of the session's Lua state, NULL = Lua's
     * defaults (LUA_PATH_5_5 / LUA_PATH, ...; an installed library: its own
     * module directories, then Lua's built-in default, without the
     * environment -- doc/capi.md "Module paths"). Ignored by the embedded
     * variant, which carries all modules inside. */
    const char*         lua_path;
    const char*         lua_cpath;
} lexiftool_options;

/* ---------------------------------------------------------------------------
 * Session
 */

/* Opens a session: creates its Lua state, starts the script's -stay_open
 * command loop (exiftool [-config FILE] -stay_open True -@ -
 * [-common_args ...]) up to the wait for the first command, and creates the
 * session's ExifTool object. options may be NULL (all defaults).
 * Returns NULL only when out of memory. If starting failed, the session is
 * returned anyway: lexiftool_state() is LEXIFTOOL_E_FAILED and
 * lexiftool_last_error() says why; close it with lexiftool_close(). */
LEXIFTOOL_API lexiftool_session* lexiftool_open(const lexiftool_options* options);

/* Ends the command loop as "-stay_open False" does (cleanup of the last
 * command) and frees the session. NULL is ignored. */
LEXIFTOOL_API void lexiftool_close(lexiftool_session* session);

/* LEXIFTOOL_OK while the session is usable, else LEXIFTOOL_E_ENDED or
 * LEXIFTOOL_E_FAILED (LEXIFTOOL_E_ARG for NULL). */
LEXIFTOOL_API int lexiftool_state(const lexiftool_session* session);

/* Message of the session's last failure or of the last call's error (see
 * the functions), or NULL; valid until the next call with this session. */
LEXIFTOOL_API const char* lexiftool_last_error(const lexiftool_session* session);

/* Version of lexiftool (a git describe, e.g. "vX.Y.2-3-gabc1234", or
 * "Unknown" without a build step that set it); static. */
LEXIFTOOL_API const char* lexiftool_version(void);

/* LEXIFTOOL_API_VERSION of the library (to check against the header). */
LEXIFTOOL_API int lexiftool_api_version(void);

/* ---------------------------------------------------------------------------
 * Commands, as for an exiftool -stay_open client
 */

/* Output of one command. stdout_data and stderr_data are never NULL after a
 * lexiftool_execute*() call: they are NUL-terminated (the NUL is not
 * counted in the length) but may contain NUL bytes themselves (-b). */
typedef struct lexiftool_result {
    char*   stdout_data;
    size_t  stdout_len;
    char*   stderr_data;
    size_t  stderr_len;
    int     status;         /* exit status of the command, as ${status}:
                               0 ok, 1 error, 2 all files failed -if      */
} lexiftool_result;

/* Runs one command: argv[0..argc-1] are its arguments (no program name,
 * no "-execute"), passed verbatim (they may contain newlines). A
 * "-execute" among them separates commands, as for a client; out then
 * holds the output of all of them and the status of the last. Fills *out
 * on every return (with what was produced up to a failure, or empty
 * strings); release it with lexiftool_result_free().
 * Returns LEXIFTOOL_OK or a negative code. */
LEXIFTOOL_API int lexiftool_execute(lexiftool_session* session, int argc,
                                    const char* const argv[],
                                    lexiftool_result* out);

/* The same with argfile text (len bytes, or LEXIFTOOL_NUL_TERMINATED): one
 * argument per line, with exiftool's argfile rules (comment lines "#",
 * "#[CSTR]" lines with C escapes, leading white space and white space
 * around "=" removed, empty lines ignored). A "-execute" line separates
 * commands; one on the last line is optional. */
LEXIFTOOL_API int lexiftool_execute_text(lexiftool_session* session,
                                         const char* text, size_t len,
                                         lexiftool_result* out);

/* Frees the buffers of a result and zeroes it (safe on a zeroed result). */
LEXIFTOOL_API void lexiftool_result_free(lexiftool_result* result);

/* ---------------------------------------------------------------------------
 * The session's ExifTool object (Image::ExifTool API)
 */

/* Sets an option of the session's ExifTool object, as Options(name, value):
 * value NULL = undef; a decimal integer ("0", "1", "-3") is passed as a
 * number, anything else as the string. The options apply to
 * lexiftool_image_info/set_new_value/write_info, not to the commands of
 * lexiftool_execute*() (those take their options from the arguments).
 * Returns LEXIFTOOL_OK or a negative code. */
LEXIFTOOL_API int lexiftool_set_option(lexiftool_session* session,
                                       const char* name, const char* value);

/* One tag of lexiftool_image_info(). */
typedef struct lexiftool_tag {
    const char* name;       /* tag name, e.g. "Make" (GetTagName)          */
    const char* group[3];   /* group names of family 0, 1, 2 (GetGroup)    */
    const char* desc;       /* description (GetDescription)                */
    const char* id;         /* tag ID as text (GetTagID), "" if none       */
    const char* value;      /* converted value (PrintConv, unless the
                               PrintConv option is 0)                      */
    size_t      value_len;
    const char* num;        /* numerical value (ValueConv); may point to
                               the same bytes as value                      */
    size_t      num_len;
    int         copy_num;   /* 0, or N for the duplicate "Tag (N)" (the
                               family 4 group "CopyN")                      */
    int         binary;     /* LEXIFTOOL_BINARY_*                          */
    size_t      binary_len; /* length of the binary data (also when value
                               holds the placeholder)                      */
} lexiftool_tag;

#define LEXIFTOOL_BINARY_NONE   0   /* no binary value                     */
#define LEXIFTOOL_BINARY_HIDDEN 1   /* binary value not delivered: value is
                                       "(Binary data N bytes, use -b option
                                       to extract)", as exiftool shows it  */
#define LEXIFTOOL_BINARY_DATA   2   /* value/num hold the binary data      */

/* Result of lexiftool_image_info(): one block of memory. */
typedef struct lexiftool_info {
    size_t          count;      /* number of tags                          */
    lexiftool_tag*  tags;
    const char*     error;      /* value of the first Error tag, or NULL   */
    const char*     warning;    /* value of the first Warning tag, or NULL */
    void*           mem;        /* (internal)                              */
} lexiftool_info;

/* Flags of lexiftool_image_info(). */
#define LEXIFTOOL_INFO_BINARY 1u    /* deliver all binary values (the
                                       Binary option for this call)        */

/* Reads the tags of one file through ImageInfo of the session's ExifTool
 * object: tags[0..ntags-1] are the requested tags, as ImageInfo takes them
 * ("Model", "EXIF:*", "-Composite:all" ...); tags NULL or ntags 0 = all.
 * The entries are in ImageInfo's order: the order of the file, or the
 * requested order when tags were named (the Sort option of the session
 * changes it, e.g. "Group0:1:2:4" for the order of the keys of
 * exiftool -php -l -G:0:1:2:4 -D).
 * All duplicates are included unless the Duplicates option is 0. Binary
 * values are delivered with LEXIFTOOL_INFO_BINARY or when the tag is
 * named in tags, otherwise as a placeholder with their length. Errors and
 * warnings of reading are tags themselves (group ExifTool), the first of
 * each also in out->error/warning ("Error opening file" for a file that
 * cannot be opened, as ImageInfo says).
 * Fills *out (zeroed on errors); release it with lexiftool_info_free().
 * Returns LEXIFTOOL_OK or a negative code. */
LEXIFTOOL_API int lexiftool_image_info(lexiftool_session* session,
                                       const char* file,
                                       const char* const tags[], int ntags,
                                       unsigned flags, lexiftool_info* out);

/* Frees an info and zeroes it (safe on a zeroed one). */
LEXIFTOOL_API void lexiftool_info_free(lexiftool_info* info);

/* Sets a new value as SetNewValue(tag, value) of the session's object (it
 * is only noted; lexiftool_write_info writes it). tag may carry groups
 * ("XMP:Title", "EXIF:all") and a trailing "#" for the numerical value.
 * value NULL deletes the tag; len is the length of value (binary data) or
 * LEXIFTOOL_NUL_TERMINATED. tag NULL clears all new values (SetNewValue()).
 * Returns the number of tags set (0: none, lexiftool_last_error() has
 * SetNewValue's message), or a negative code. */
LEXIFTOOL_API int lexiftool_set_new_value(lexiftool_session* session,
                                          const char* tag,
                                          const char* value, size_t len);

/* Writes the new values: WriteInfo(file, outfile) of the session's object.
 * outfile NULL rewrites file in place; otherwise outfile must not exist.
 * The new values stay set for further writes.
 * Returns WriteInfo's result -- 1 written, 2 written without changes,
 * 0 error (the Error message in lexiftool_last_error()) -- or a negative
 * code. After 1 or 2, lexiftool_last_error() has the warning of the write,
 * if there was one. */
LEXIFTOOL_API int lexiftool_write_info(lexiftool_session* session,
                                       const char* file, const char* outfile);

#ifdef __cplusplus
}
#endif

#endif /* LEXIFTOOL_H */
