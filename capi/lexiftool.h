/*------------------------------------------------------------------------------
 * File:         capi/lexiftool.h
 *
 * Description:  C API of lexiftool (draft, prototype): exiftool as an
 *               in-process library. A session is one lexiftool instance --
 *               an own Lua state running the command-line script -- into
 *               which the caller hands
 *               - one command at a time as an argument list (exactly the
 *                 arguments an exiftool -stay_open client writes before
 *                 "-execute") and gets that command's stdout, stderr and
 *                 status back as buffers (lexiftool_execute), or
 *               - one file plus a few options and gets its tags back as a
 *                 list of name/group/value entries, taken from the library
 *                 without any text formatting (lexiftool_image_info), or
 *               - one file plus tag names and values to write
 *                 (lexiftool_set_tags).
 *               Everything runs synchronously in the calling thread.
 *
 *               Rules:
 *               - Any number of sessions per process; each session is used
 *                 from one thread at a time (the caller serializes). The
 *                 library starts no threads and has no asynchronous,
 *                 timeout or cancel mechanism.
 *               - Every string is a NUL-terminated byte string, passed on
 *                 to lexiftool unchanged (file names and tag values are
 *                 bytes, as for exiftool; see -charset).
 *               - Memory: the caller owns what it passes in; the library
 *                 owns the session; a result's buffers belong to the
 *                 caller until lexiftool_result_free()/lexiftool_tags_free().
 *
 *               See doc/capi.md for the design and the mapping onto
 *               src/lexiftool/main.lua.
 *------------------------------------------------------------------------------
 */

#ifndef LEXIFTOOL_H
#define LEXIFTOOL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Exported symbols (the shared library exports nothing else) */
#if defined(_WIN32) && defined(LEXIFTOOL_BUILD_DLL)
#  define LEXIFTOOL_API __declspec(dllexport)
#elif defined(__GNUC__)
#  define LEXIFTOOL_API __attribute__((visibility("default")))
#else
#  define LEXIFTOOL_API
#endif

/* Version of this C API (incremented on incompatible changes). */
#define LEXIFTOOL_API_VERSION 2

/* Return codes. */
#define LEXIFTOOL_OK         0    /* the call ran; see the result's status  */
#define LEXIFTOOL_E_ARG     -1    /* invalid argument (NULL session, an
                                     option lexiftool_image_info does not
                                     know, ...); lexiftool_last_error()    */
#define LEXIFTOOL_E_NOMEM   -2    /* out of memory                          */
#define LEXIFTOOL_E_FAILED  -3    /* the session failed (Lua error in the
                                     command loop, failed start); unusable
                                     from now on                            */
#define LEXIFTOOL_E_ENDED   -4    /* the session's command loop has ended
                                     (a command contained
                                     "-stay_open False"); unusable          */
#define LEXIFTOOL_E_ERROR   -5    /* lexiftool_image_info/_set_tags only:
                                     this call failed with a Lua error
                                     (lexiftool_last_error()); the session
                                     stays usable                           */

typedef struct lexiftool_session lexiftool_session;

/* Options of a session. Zero-initialize, then set what is needed; every
 * field may stay 0/NULL. The arrays are copied during lexiftool_open(). */
typedef struct lexiftool_options {
    int                 struct_size;    /* sizeof(lexiftool_options) (fields
                                           beyond it count as 0), or 0      */
    /* arguments common to all commands, as after exiftool's -common_args
     * (e.g. "-G", "-n", "-charset", "filename=utf8") */
    int                 common_argc;
    const char* const*  common_argv;
    /* exiftool -config FILE (must come first on exiftool's command line):
     * NULL = the default .ExifTool_config lookup, "" = no config file */
    const char*         config_file;
    /* build variant "rock" only (modules loaded from the file system):
     * package.path / package.cpath of the session's Lua state, NULL = Lua's
     * defaults (LUA_PATH_5_5 / LUA_PATH, ...). Ignored by the embedded
     * variant, which carries all modules inside. */
    const char*         lua_path;
    const char*         lua_cpath;
} lexiftool_options;

/* Output of one command. stdout_data and stderr_data are never NULL after
 * lexiftool_execute(): they are NUL-terminated (the NUL is not counted in
 * the length) but may contain NUL bytes themselves (-b binary output). */
typedef struct lexiftool_result {
    char*   stdout_data;
    size_t  stdout_len;
    char*   stderr_data;
    size_t  stderr_len;
    int     status;         /* exit status of the command, as ${status}:
                               0 ok, 1 error, 2 all files failed -if      */
} lexiftool_result;

/* One tag of lexiftool_image_info(). */
typedef struct lexiftool_tag {
    const char* name;       /* tag name, e.g. "Make" (no group, no "(1)")  */
    const char* group;      /* with -G[n]: the group name(s) as -G shows
                               them ("EXIF", "IFD0", "EXIF:IFD0" for
                               -G0:1); NULL without -G                     */
    const char* value;      /* the value as text, as -j prints it; a list
                               joined with ", " (-sep); binary data
                               "(Binary data N bytes, use -b option to
                               extract)", or with -b the raw bytes        */
    size_t      value_len;  /* length of value (binary data may contain
                               NUL bytes; value is NUL-terminated too)    */
    int         binary;     /* 1: value holds raw binary data (-b)         */
} lexiftool_tag;

/* A warning or an error (as exiftool prints them on stderr). */
typedef struct lexiftool_message {
    const char* level;      /* "Warning" or "Error"                        */
    const char* text;       /* e.g. "File not found", "Unknown file type"  */
} lexiftool_message;

/* Result of lexiftool_image_info() / lexiftool_set_tags(): one block of
 * memory, released with lexiftool_tags_free(). */
typedef struct lexiftool_tags {
    size_t              count;           /* number of tags                  */
    lexiftool_tag*      tags;
    size_t              message_count;   /* number of messages              */
    lexiftool_message*  messages;
    int                 status;          /* 0 ok, 1 error (an Error message) */
    void*               mem;             /* (internal)                      */
} lexiftool_tags;

/* Opens a session: creates its Lua state and starts the script's
 * -stay_open command loop (exiftool [-config FILE] -stay_open True -@ -
 * [-common_args ...]), waiting for the first command.
 * Returns NULL only when out of memory. If starting failed, the session
 * is returned anyway: lexiftool_last_error() says why, lexiftool_execute()
 * returns LEXIFTOOL_E_FAILED; close it with lexiftool_close(). */
LEXIFTOOL_API lexiftool_session* lexiftool_open(const lexiftool_options* options);

/* Runs one command: argv[0..argc-1] are its arguments (no program name,
 * no "-execute"). Fills *out (also on errors, with what was produced up to
 * the failure, or empty strings); release it with lexiftool_result_free().
 * Returns LEXIFTOOL_OK or a negative LEXIFTOOL_E_* code. */
LEXIFTOOL_API int lexiftool_execute(lexiftool_session* session, int argc,
                                    const char* const argv[],
                                    lexiftool_result* out);

/* Frees the buffers of a result and zeroes it (safe on a zeroed result). */
LEXIFTOOL_API void lexiftool_result_free(lexiftool_result* result);

/* Reads the tags of one file, straight from the library (ImageInfo):
 * argv[0..argc-1] are options from this subset of the command line's:
 *   -G[n[:n...]]  group names (family n, 0 by default) in tag->group
 *   -a -e -ee -n -u -U -fast -fast2 -b
 *   -api OPT[=VAL]  -c FMT  -d FMT  -lang LANG  -sep STR  -x TAG
 *   -TAG  --TAG     tags to extract / to exclude (default: all)
 * Duplicates are suppressed as for -j (unless -a). Warnings and errors go
 * into out->messages, not to stderr; out->status is 1 when there was an
 * error (file not found, ...). Fills *out (zeroed on errors); release it
 * with lexiftool_tags_free().
 * Returns LEXIFTOOL_OK, LEXIFTOOL_E_ARG (an unknown option; see
 * lexiftool_last_error()), or another negative code. */
LEXIFTOOL_API int lexiftool_image_info(lexiftool_session* session,
                                       const char* path, int argc,
                                       const char* const argv[],
                                       lexiftool_tags* out);

/* Writes tags of one file in place (SetNewValue for each pair, then
 * WriteInfo, the original file replaced as with -overwrite_original):
 * values[i] NULL deletes the tag names[i] (as -TAG=). names may carry a
 * group ("XMP:Title") and the operators of -TAG+=/-TAG-= are not
 * supported. out gets the messages (count stays 0) and the status (0 the
 * file was written or nothing had to change, 1 error).
 * Returns LEXIFTOOL_OK or a negative code. */
LEXIFTOOL_API int lexiftool_set_tags(lexiftool_session* session,
                                     const char* path, int n,
                                     const char* const names[],
                                     const char* const values[],
                                     lexiftool_tags* out);

/* Frees a lexiftool_tags and zeroes it (safe on a zeroed one). */
LEXIFTOOL_API void lexiftool_tags_free(lexiftool_tags* tags);

/* Ends the command loop as "-stay_open False" does (cleanup of the last
 * command) and frees the session. NULL is ignored. */
LEXIFTOOL_API void lexiftool_close(lexiftool_session* session);

/* Version of lexiftool (a git describe, e.g. "v13.59.2-3-gabc1234", or
 * "Unknown" without a build step that set it); static. */
LEXIFTOOL_API const char* lexiftool_version(void);

/* Message of the last failure of this session, or NULL; valid until the
 * next call with this session. */
LEXIFTOOL_API const char* lexiftool_last_error(const lexiftool_session* session);

#ifdef __cplusplus
}
#endif

#endif /* LEXIFTOOL_H */
