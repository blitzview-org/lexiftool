/*------------------------------------------------------------------------------
 * File:         capi/test_sideeffects.c
 *
 * Description:  Side-effect test of the lexiftool C API (Linux, macOS,
 *               Windows; run by build-linux.sh sideeffects and by the test
 *               variants of build-macos.sh and build-windows.sh): sets up
 *               a host process state that differs from every default --
 *               environment with TZ, the time zone set with tzset, a locale
 *               of its own (de_DE where installed: decimal comma), signal
 *               handlers and ignored signals, a blocked signal, umask, a
 *               working directory, extra file descriptors with their
 *               flags, stdin from a file, stdout and stderr redirected to
 *               files, with bytes pending in a buffer of its own -- and
 *               records it. Then sessions run many commands and calls
 *               (time zones through -api TimeZone and the TimeZone option,
 *               -lang, -d, Verbose output, binary output, writing, error
 *               cases, the end of a session by -stay_open False,
 *               open/close) and afterwards every part of the state must be
 *               as before, and nothing may have reached fd 1 or 2.
 *               Recorded and compared:
 *               - POSIX (Linux, macOS): the environment string by string,
 *                 TZ/tzname/timezone/daylight, setlocale(LC_ALL, NULL) and
 *                 the thread's locale, every signal's disposition, the
 *                 thread's signal mask, cwd, umask, the open descriptors
 *                 and their flags (fcntl), the stdio streams' buffers,
 *                 pending bytes, modes, positions and flags (glibc's
 *                 __fpending & co., the FILE fields on macOS), the file
 *                 offset of stdin. The number of threads is not checked:
 *                 libraries (ours or third-party) and the OS itself may
 *                 start and keep their own worker threads.
 *               - Windows: the environment (the C runtime's and the
 *                 process's block), TZ/_tzname/_timezone/_daylight,
 *                 setlocale(LC_ALL, NULL) and the per-thread locale mode,
 *                 the signals the C runtime knows, cwd, umask, the C
 *                 runtime's descriptors with their handles and translation
 *                 modes, the standard handles, the console's code pages
 *                 and modes, the error mode, the stdio streams' positions
 *                 and flags, the file offset of stdin; the process's
 *                 handles may not have grown (threads are not checked, see
 *                 above). Recorded after one session has run, so that what
 *                 the system loads once
 *                 per process (DLLs, the C runtime's caches) is not
 *                 counted.
 *               In between: a value of 4 MB written and read back through
 *               image_info and a command's stdout, a large stdout, many
 *               commands in one session and SESSIONS sessions in a row,
 *               after which the memory in use must have levelled off
 *               (resident size; Windows: private bytes; not under
 *               AddressSanitizer).
 *               Prints "ok"/"not ok" lines (on the saved stdout).
 *               Usage: test_sideeffects T_IMAGES_DIR SCRATCH_DIR
 *                      [SESSIONS [COMMANDS]]  (default 100, 1000)
 *               Compiled with -DLEXIFTOOL_TEST_EMBEDDED for the embedded
 *               libraries, whose modules do not come from lua_path/
 *               lua_cpath: there a start with such paths succeeds.
 *------------------------------------------------------------------------------
 */

#if defined(_WIN32) && !defined(_WIN32_WINNT)
#  define _WIN32_WINNT 0x0601   /* GetErrorMode, K32GetProcessMemoryInfo */
#endif
#include "test_platform.h"
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <sys/stat.h>
#include <time.h>
#include <wchar.h>
#if defined(_WIN32)
#  include <psapi.h>
#else
#  include <unistd.h>
#endif
#if defined(__GLIBC__)
#  include <stdio_ext.h>
#endif
#if defined(__APPLE__)
#  include <xlocale.h>
#  include <libproc.h>
#endif
#include "lexiftool.h"

#if !defined(_WIN32)
extern char** environ;
#endif

static FILE* report;            /* the saved stdout */
static int failed = 0, total = 0;

static void ok(int cond, const char* name)
{
    total++;
    if (!cond) failed++;
    fprintf(report, "%s %d - %s\n", cond ? "ok" : "not ok", total, name);
    fflush(report);
}

static char* dup0(const char* s) { return s ? strdup(s) : NULL; }

static int same_str(const char* a, const char* b)
{
    return (a == NULL && b == NULL) || (a != NULL && b != NULL && strcmp(a, b) == 0);
}

/* ---------------------------------------------------------------------------
 * A stdio stream's state: buffer size, pending bytes, mode, orientation,
 * position, flags -- as far as the C library lets a program see them
 */

typedef struct {
    size_t  bufsize, pending;
    long    linebuf, reading, writing, orient;
    long    pos;
    int     eof, err;
} stream_state;

static void stream_record(FILE* f, stream_state* s)
{
    memset(s, 0, sizeof(*s));
    /* (the position first: BSD stdio's ftell marks the offset as known in
     * the stream's flags, which a later record would see as a change) */
    s->pos = ftell(f);
#if defined(__GLIBC__)
    s->bufsize = __fbufsize(f);
    s->pending = __fpending(f);
    s->linebuf = __flbf(f);
    s->reading = __freading(f);
    s->writing = __fwriting(f);
#elif defined(__APPLE__)
    /* (the FILE fields of BSD stdio: buffer, bytes in it, flags) */
    s->bufsize = (size_t)f->_bf._size;
    s->pending = f->_bf._base ? (size_t)(f->_p - f->_bf._base) : 0;
    s->linebuf = f->_lbfsize;
    s->reading = f->_r;
    s->writing = f->_w;
    s->orient = f->_flags;
#endif
#if !defined(_WIN32)
    s->orient = s->orient * 4 + fwide(f, 0) + 1;
#endif
    s->eof = feof(f);
    s->err = ferror(f);
}

/* ---------------------------------------------------------------------------
 * The recorded state
 */

enum { MAXFD = 256, MAXENV = 4096 };

#if defined(_WIN32)
/* the signals of the C runtime */
static const int sigs[] = { SIGINT, SIGILL, SIGFPE, SIGSEGV, SIGTERM, SIGBREAK, SIGABRT };
enum { NSIGS = sizeof(sigs) / sizeof(sigs[0]) };

static void (*sig_get(int sig))(int)
{
    void (*h)(int) = signal(sig, SIG_DFL);
    if (h != SIG_ERR) signal(sig, h);
    return h;
}

/* a C runtime descriptor's OS handle, -1 when not open (without the
 * invalid-parameter handler a debug runtime would call) */
static intptr_t fd_handle(int fd)
{
    return _get_osfhandle(fd);
}

/* the translation mode of a descriptor (set and put back), -1 if none */
static int fd_mode(int fd)
{
    int m;
    if (fd_handle(fd) == -1) return -1;
    m = _setmode(fd, _O_BINARY);
    if (m != -1) _setmode(fd, m);
    return m;
}

#  if defined(_MSC_VER) || defined(_UCRT)
static void no_invalid_parameter(const wchar_t* e, const wchar_t* f, const wchar_t* file,
                                 unsigned line, uintptr_t r)
{
    (void)e; (void)f; (void)file; (void)line; (void)r;
}
#  endif
#endif

typedef struct {
    char*            env[MAXENV];       /* copies of the environment strings */
    int              nenv;
    char**           environ_ptr;
    char*            tz;                /* getenv("TZ") (copy) */
    char             tzname0[64], tzname1[64];
    long             timezone_;
    int              daylight_;
    char*            locale_all;        /* setlocale(LC_ALL, NULL) (copy) */
    char             cwd[4096];
    int              umask_;
    stream_state     std[3];
    long long        stdin_off;
#if defined(_WIN32)
    wchar_t*         envblock;          /* GetEnvironmentStringsW (copy) */
    size_t           envblock_len;
    int              thread_locale;     /* _configthreadlocale(0), or -2 */
    void           (*sig[NSIGS])(int);
    intptr_t         fd_handle[MAXFD];
    int              fd_mode[MAXFD];
    HANDLE           stdh[3];
    DWORD            stdh_type[3];
    long             console_mode[3];   /* GetConsoleMode, -1 if no console */
    UINT             console_cp, console_out_cp;
    UINT             error_mode;
    DWORD            handles;           /* GetProcessHandleCount */
#else
    locale_t         thread_locale;     /* uselocale(0) */
    struct sigaction sa[NSIG];
    int              sa_ok[NSIG];
    sigset_t         mask;
    int              fd_flags[MAXFD];   /* F_GETFD, -1 if not open */
    int              fl_flags[MAXFD];   /* F_GETFL */
#endif
} state;

static void record(state* st)
{
    FILE* f[3] = { stdin, stdout, stderr };
    int i;
    memset(st, 0, sizeof(*st));
#if defined(_WIN32)
    for (i = 0; _environ[i] != NULL && i < MAXENV; i++) st->env[i] = strdup(_environ[i]);
    st->nenv = i;
    st->environ_ptr = _environ;
    {
        wchar_t* b = GetEnvironmentStringsW(), *p = b;
        if (b != NULL) {
            while (*p) p += wcslen(p) + 1;
            st->envblock_len = (size_t)(p - b) + 1;
            st->envblock = malloc(st->envblock_len * sizeof(wchar_t));
            if (st->envblock) memcpy(st->envblock, b, st->envblock_len * sizeof(wchar_t));
            FreeEnvironmentStringsW(b);
        }
    }
    snprintf(st->tzname0, sizeof(st->tzname0), "%s", _tzname[0]);
    snprintf(st->tzname1, sizeof(st->tzname1), "%s", _tzname[1]);
    st->timezone_ = _timezone;
    st->daylight_ = _daylight;
#  if defined(_MSC_VER) || defined(_UCRT)
    st->thread_locale = _configthreadlocale(0);
#  else
    st->thread_locale = -2;
#  endif
    for (i = 0; i < NSIGS; i++) st->sig[i] = sig_get(sigs[i]);
    if (GetCurrentDirectoryA(sizeof(st->cwd), st->cwd) == 0) st->cwd[0] = '\0';
    st->umask_ = _umask(0);
    _umask(st->umask_);
    for (i = 0; i < MAXFD; i++) {
        st->fd_handle[i] = fd_handle(i);
        st->fd_mode[i] = fd_mode(i);
    }
    for (i = 0; i < 3; i++) {
        DWORD mode;
        st->stdh[i] = GetStdHandle(i == 0 ? STD_INPUT_HANDLE : i == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
        st->stdh_type[i] = GetFileType(st->stdh[i]);
        st->console_mode[i] = GetConsoleMode(st->stdh[i], &mode) ? (long)mode : -1;
    }
    st->console_cp = GetConsoleCP();
    st->console_out_cp = GetConsoleOutputCP();
    st->error_mode = GetErrorMode();
    if (!GetProcessHandleCount(GetCurrentProcess(), &st->handles)) st->handles = 0;
    st->stdin_off = _lseeki64(0, 0, SEEK_CUR);
#else
    for (i = 0; environ[i] != NULL && i < MAXENV; i++) st->env[i] = strdup(environ[i]);
    st->nenv = i;
    st->environ_ptr = environ;
    snprintf(st->tzname0, sizeof(st->tzname0), "%s", tzname[0]);
    snprintf(st->tzname1, sizeof(st->tzname1), "%s", tzname[1]);
    st->timezone_ = timezone;
    st->daylight_ = daylight;
    st->thread_locale = uselocale((locale_t)0);
    for (i = 1; i < NSIG; i++) st->sa_ok[i] = sigaction(i, NULL, &st->sa[i]) == 0;
    pthread_sigmask(SIG_SETMASK, NULL, &st->mask);
    if (getcwd(st->cwd, sizeof(st->cwd)) == NULL) st->cwd[0] = '\0';
    st->umask_ = (int)umask(0);
    umask((mode_t)st->umask_);
    for (i = 0; i < MAXFD; i++) {
        st->fd_flags[i] = fcntl(i, F_GETFD);
        st->fl_flags[i] = st->fd_flags[i] < 0 ? -1 : fcntl(i, F_GETFL);
#if defined(__APPLE__) && defined(FWASWRITTEN)
        /* (the kernel's own record that the descriptor was written to --
         * the report's duplicate of stdout is, by this test) */
        if (st->fl_flags[i] > 0) st->fl_flags[i] &= ~FWASWRITTEN;
#elif defined(__APPLE__)
        if (st->fl_flags[i] > 0) st->fl_flags[i] &= ~0x10000;   /* FWASWRITTEN */
#endif
    }
    st->stdin_off = (long long)lseek(0, 0, SEEK_CUR);
#endif
    st->tz = dup0(getenv("TZ"));
    st->locale_all = dup0(setlocale(LC_ALL, NULL));
    for (i = 0; i < 3; i++) stream_record(f[i], &st->std[i]);
}

static void compare(const state* a, const state* b, const char* when)
{
    char name[256];
    int i, same;

#define CHECK(cond, what) \
    do { snprintf(name, sizeof(name), "%s: %s", when, what); ok(cond, name); } while (0)

    same = a->nenv == b->nenv && a->environ_ptr == b->environ_ptr;
    for (i = 0; same && i < a->nenv; i++) same = strcmp(a->env[i], b->env[i]) == 0;
    CHECK(same, "environment unchanged (environ and every string)");
#if defined(_WIN32)
    CHECK(a->envblock != NULL && b->envblock != NULL && a->envblock_len == b->envblock_len &&
          memcmp(a->envblock, b->envblock, a->envblock_len * sizeof(wchar_t)) == 0,
          "the process's environment block unchanged");
#endif
    CHECK(same_str(a->tz, b->tz), "TZ unchanged");
    CHECK(strcmp(a->tzname0, b->tzname0) == 0 && strcmp(a->tzname1, b->tzname1) == 0 &&
          a->timezone_ == b->timezone_ && a->daylight_ == b->daylight_,
          "tzname, timezone, daylight unchanged");
    CHECK(same_str(a->locale_all, b->locale_all), "setlocale(LC_ALL, NULL) unchanged");
#if defined(_WIN32)
    CHECK(a->thread_locale == b->thread_locale, "the per-thread locale mode (_configthreadlocale) unchanged");
    same = 1;
    for (i = 0; i < NSIGS; i++)
        if (a->sig[i] != b->sig[i]) {
            fprintf(report, "# signal %d changed\n", sigs[i]);
            same = 0;
        }
    CHECK(same, "every signal's handler unchanged");
#else
    CHECK(a->thread_locale == b->thread_locale, "the thread's locale (uselocale) unchanged");
    same = 1;
    for (i = 1; i < NSIG; i++) {
        const struct sigaction* x = &a->sa[i], *y = &b->sa[i];
        int s1;
        if (a->sa_ok[i] != b->sa_ok[i]) { same = 0; break; }
        if (!a->sa_ok[i]) continue;
        s1 = x->sa_flags == y->sa_flags &&
             ((x->sa_flags & SA_SIGINFO) ? x->sa_sigaction == y->sa_sigaction
                                         : x->sa_handler == y->sa_handler);
        if (s1) {
            int k;
            for (k = 1; k < NSIG; k++)
                if (sigismember(&x->sa_mask, k) != sigismember(&y->sa_mask, k)) s1 = 0;
        }
        if (!s1) {
            fprintf(report, "# signal %d (%s) changed\n", i, strsignal(i));
            same = 0;
        }
    }
    CHECK(same, "every signal's disposition (handler, flags, mask) unchanged");
    same = 1;
    for (i = 1; i < NSIG; i++)
        if (sigismember(&a->mask, i) != sigismember(&b->mask, i)) same = 0;
    CHECK(same, "the thread's signal mask unchanged");
#endif
    CHECK(strcmp(a->cwd, b->cwd) == 0, "current directory unchanged");
    CHECK(a->umask_ == b->umask_, "umask unchanged");
    same = 1;
#if defined(_WIN32)
    for (i = 0; i < MAXFD; i++)
        if (a->fd_handle[i] != b->fd_handle[i] || a->fd_mode[i] != b->fd_mode[i]) {
            fprintf(report, "# fd %d: handle %lld/%lld mode %#x/%#x\n", i, (long long)a->fd_handle[i],
                    (long long)b->fd_handle[i], a->fd_mode[i], b->fd_mode[i]);
            same = 0;
        }
    CHECK(same, "the C runtime's descriptors, their handles and translation modes unchanged");
    same = 1;
    for (i = 0; i < 3; i++)
        if (a->stdh[i] != b->stdh[i] || a->stdh_type[i] != b->stdh_type[i] ||
            a->console_mode[i] != b->console_mode[i]) {
            fprintf(report, "# standard handle %d changed\n", i);
            same = 0;
        }
    CHECK(same, "standard handles, their types and console modes unchanged");
    CHECK(a->console_cp == b->console_cp && a->console_out_cp == b->console_out_cp,
          "the console's input and output code pages unchanged");
    CHECK(a->error_mode == b->error_mode, "the error mode unchanged");
    fprintf(report, "# handles %lu/%lu\n", (unsigned long)a->handles, (unsigned long)b->handles);
    CHECK(b->handles <= a->handles, "no more handles open than before");
#else
    for (i = 0; i < MAXFD; i++)
        if (a->fd_flags[i] != b->fd_flags[i] || a->fl_flags[i] != b->fl_flags[i]) {
            fprintf(report, "# fd %d: FD %d/%d FL %d/%d\n", i, a->fd_flags[i], b->fd_flags[i],
                    a->fl_flags[i], b->fl_flags[i]);
            same = 0;
        }
    CHECK(same, "open file descriptors and their flags unchanged");
#endif
    CHECK(a->stdin_off == b->stdin_off, "file offset of stdin unchanged (nothing read)");
    same = 1;
    for (i = 0; i < 3; i++)
        if (memcmp(&a->std[i], &b->std[i], sizeof(a->std[i])) != 0) {
            const stream_state* x = &a->std[i];
            const stream_state* y = &b->std[i];
            fprintf(report, "# std stream %d changed: buf %zu/%zu pending %zu/%zu lbf %ld/%ld"
                    " r %ld/%ld w %ld/%ld orient %ld/%ld pos %ld/%ld eof %d/%d err %d/%d\n", i,
                    x->bufsize, y->bufsize, x->pending, y->pending, x->linebuf, y->linebuf,
                    x->reading, y->reading, x->writing, y->writing, x->orient, y->orient,
                    x->pos, y->pos, x->eof, y->eof, x->err, y->err);
            same = 0;
        }
    CHECK(same, "stdin/stdout/stderr: buffer, pending bytes, mode, orientation, position, flags unchanged");
#undef CHECK
}

static void free_state(state* st)
{
    int i;
    for (i = 0; i < st->nenv; i++) free(st->env[i]);
    free(st->tz);
    free(st->locale_all);
#if defined(_WIN32)
    free(st->envblock);
#endif
}

/* ---------------------------------------------------------------------------
 * The host's own state
 */

static volatile sig_atomic_t got_usr1 = 0;
static void on_usr1(int sig) { (void)sig; got_usr1 = 1; }
#if !defined(_WIN32)
static void on_hup(int sig, siginfo_t* si, void* uc) { (void)sig; (void)si; (void)uc; }
#endif

static long file_size(const char* path)
{
    struct stat st;
    return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

/* ---------------------------------------------------------------------------
 * What the sessions do
 */

static int nexec = 0, nbad = 0;

static void ex(lexiftool_session* s, int argc, const char** argv, int expect_rc)
{
    lexiftool_result r;
    stream_state before, after;
    int rc;
    stream_record(stdout, &before);
    rc = lexiftool_execute(s, argc, argv, &r);
    stream_record(stdout, &after);
    nexec++;
    if (memcmp(&before, &after, sizeof(before)) != 0) {
        /* (names the culprit; the state comparison fails as well) */
        fprintf(report, "# the host's stdout stream changed by the command %s %s\n", argv[0],
                argc > 1 ? argv[1] : "");
    }
    if (rc != expect_rc) {
        fprintf(report, "# rc %d (expected %d) for %s ...: %s\n", rc, expect_rc, argv[0],
                lexiftool_last_error(s) ? lexiftool_last_error(s) : "");
        nbad++;
    }
    lexiftool_result_free(&r);
}

#define EX(s, rc, ...) do { const char* v_[] = { __VA_ARGS__ }; \
    ex(s, (int)(sizeof(v_) / sizeof(v_[0])), v_, rc); } while (0)

static void session_work(const char* images, const char* scratch)
{
    char canon[2048], gps[2048], copy[2048], out[2048], argfile[2048];
    const char* common[] = { "-api", "TimeZone=Asia/Kolkata" };
    lexiftool_options opt = { .struct_size = sizeof(opt), .common_argc = 2, .common_argv = common };
    lexiftool_session* s, *t;
    lexiftool_info info;
    lexiftool_result r;
    int i;

    snprintf(canon, sizeof(canon), "%s/Canon.jpg", images);
    snprintf(gps, sizeof(gps), "%s/GPS.jpg", images);
    snprintf(copy, sizeof(copy), "%s/se.jpg", scratch);
    snprintf(out, sizeof(out), "%s/se.txt", scratch);
    snprintf(argfile, sizeof(argfile), "%s/se.args", scratch);
    tp_copy_file(canon, copy);
    remove(out);

    s = lexiftool_open(&opt);
    t = lexiftool_open(NULL);
    ok(lexiftool_state(s) == LEXIFTOOL_OK && lexiftool_state(t) == LEXIFTOOL_OK, "two sessions open");

    /* commands: time zones, languages, date formats, output options */
    EX(s, 0, "-ver");
    EX(s, 0, "-a", "-u", "-G1", "-s", canon);
    EX(s, 0, "-api", "TimeZone=America/Los_Angeles", "-d", "%c %Z %z", "-time:all", canon);
    EX(s, 0, "-api", "TimeZone=", "-d", "%Y %Z", "-time:all", canon);
    EX(s, 0, "-lang", "de", "-d", "%A, %d. %B %Y %H:%M:%S %Z", "-G", "-a", canon);
    EX(s, 0, "-lang", "fr", "-j", canon);
    EX(s, 0, "-lang", "ja", "-X", canon);
    EX(s, 0, "-php", "-l", "-G:0:1:2:4", "-D", canon);
    EX(s, 0, "-v3", canon);
    EX(s, 0, "-htmlDump", canon);
    EX(s, 0, "-b", "-ThumbnailImage", canon);  /* binary stdout (binmode on Windows) */
    EX(s, 0, "-b", "-j", canon);
    EX(s, 0, "-api", "Geolocation", "-Geolocation*", gps);
    EX(s, 0, "-echo", "to stdout", "-echo2", "to stderr", "-ver");
    EX(s, 0, "-progress", "-q", "-q", canon);
    EX(s, 0, "-w", out, "-s", canon);
    EX(s, 0, "-overwrite_original", "-Artist=side effects", "-DateTimeOriginal=2020:10:25 02:30:00", copy);
    EX(s, 0, "-api", "TimeZone=Europe/Berlin", "-d", "%c %Z", "-DateTimeOriginal", "-FileModifyDate", copy);
    EX(s, 0, "-tagsFromFile", canon, "-all:all", "-overwrite_original", copy);
    EX(s, 0, "-listx", "-EXIF:All");
    EX(s, 0, "-list");
    /* error cases */
    EX(s, 0, "/nonexistent/file.jpg");
    EX(s, 0, "-badoption", canon);
    EX(s, 0, "-api", "TimeZone=Bad/Zone", "-d", "%Z", "-FileModifyDate", canon);
    EX(s, 0, "-Artist=x", "/nonexistent/dir/x.jpg");
    EX(s, 0, "-if", "$Make eq", canon);
    EX(s, 0, "-@", "/nonexistent/argfile");
    {
        FILE* a = fopen(argfile, "w");
        if (a) { fprintf(a, "-s\n-Make\n%s\n", canon); fclose(a); }
        EX(s, 0, "-@", argfile);
    }
    ok(lexiftool_execute_text(t, "# comment\n-lang\nde\n-s\n-Make\n-execute\n-ver\n", LEXIFTOOL_NUL_TERMINATED, &r)
       == LEXIFTOOL_OK, "execute_text");
    lexiftool_result_free(&r);

    /* the session's object */
    lexiftool_set_option(t, "TimeZone", "Pacific/Chatham");
    lexiftool_set_option(t, "DateFormat", "%c %Z");
    lexiftool_set_option(t, "Lang", "de");
    lexiftool_set_option(t, "Verbose", "3");       /* output to TextOut, dropped */
    lexiftool_set_option(t, "NoSuchOption", "1");  /* a warning, dropped */
    for (i = 0; i < 3; i++) {
        lexiftool_image_info(t, canon, NULL, 0, 0, &info);
        lexiftool_info_free(&info);
    }
    lexiftool_image_info(t, "/nonexistent/file.jpg", NULL, 0, 0, &info);
    lexiftool_info_free(&info);
    lexiftool_set_option(t, "Verbose", "0");
    lexiftool_set_new_value(t, "Comment", "via set_new_value", LEXIFTOOL_NUL_TERMINATED);
    lexiftool_set_new_value(t, "NoSuchTag", "x", LEXIFTOOL_NUL_TERMINATED);
    lexiftool_write_info(t, copy, NULL);
    lexiftool_write_info(t, "/nonexistent/dir/x.jpg", NULL);
    lexiftool_set_new_value(t, NULL, NULL, 0);

    /* the end: one session by -stay_open False, the other by close */
    EX(s, LEXIFTOOL_E_ENDED, "-stay_open", "False");
    lexiftool_close(s);
    lexiftool_close(t);
    ok(nbad == 0, "all commands with the expected return code");

    /* open/close in a row, and a failed start */
    for (i = 0; i < 3; i++) {
        s = lexiftool_open(NULL);
        EX(s, 0, "-ver");
        lexiftool_close(s);
    }
    {
        lexiftool_options bad = { .struct_size = sizeof(bad), .lua_path = "/nonexistent/?.lua",
                                  .lua_cpath = "/nonexistent/?.so" };
        s = lexiftool_open(&bad);
#ifdef LEXIFTOOL_TEST_EMBEDDED
        /* (embedded build: the modules do not come from the paths) */
        ok(lexiftool_state(s) == LEXIFTOOL_OK, "a start with paths that lead nowhere");
#else
        ok(lexiftool_state(s) == LEXIFTOOL_E_FAILED, "a failed start");
#endif
        lexiftool_close(s);
    }
}


/* ---------------------------------------------------------------------------
 * Large results, and memory over many sessions and commands
 */

/* the memory in use, in kB: the resident size (Windows: the private
 * bytes, which trimming the working set cannot lower); -1 if unknown */
static long rss_kb(void)
{
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc;
    if (!K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) return -1;
    return (long)(pmc.PagefileUsage / 1024);
#elif defined(__APPLE__)
    struct proc_taskinfo ti;
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != (int)sizeof(ti)) return -1;
    return (long)(ti.pti_resident_size / 1024);
#else
    long pages = 0, rss = 0;
    FILE* f = fopen("/proc/self/statm", "r");
    if (f == NULL) return -1;
    if (fscanf(f, "%ld %ld", &pages, &rss) != 2) rss = -1;
    fclose(f);
    return rss < 0 ? -1 : rss * (sysconf(_SC_PAGESIZE) / 1024);
#endif
}


#if defined(__SANITIZE_ADDRESS__)
#  define LX_ASAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define LX_ASAN 1
#  endif
#endif

static void resources(const char* images, const char* scratch, int cycles, int commands)
{
    enum { BIG = 4000000 };
    char canon[2048], writer[2048], copy[2048];
    const char* desc = "XMP-dc:Description";
    char* big = malloc(BIG);
    lexiftool_session* s;
    lexiftool_info info;
    lexiftool_result r;
    long rss_warm = 0, rss_end;
    int i, good;

    snprintf(canon, sizeof(canon), "%s/Canon.jpg", images);
    snprintf(writer, sizeof(writer), "%s/Writer.jpg", images);
    snprintf(copy, sizeof(copy), "%s/big.jpg", scratch);
    if (big == NULL) { ok(0, "large value: memory"); return; }
    for (i = 0; i < BIG; i++) big[i] = (char)('A' + (i * 7 + i / 13) % 26);
    tp_copy_file(writer, copy);

    /* a value of 4 MB: written, read back by image_info and by a command */
    s = lexiftool_open(NULL);
    good = lexiftool_set_new_value(s, desc, big, BIG) == 1 && lexiftool_write_info(s, copy, NULL) == 1;
    ok(good, "large value: set_new_value + write_info (4 MB)");
    good = lexiftool_image_info(s, copy, &desc, 1, 0, &info) == LEXIFTOOL_OK && info.count == 1 &&
           info.tags[0].value_len == BIG && memcmp(info.tags[0].value, big, BIG) == 0;
    ok(good, "large value: image_info reads it back byte for byte");
    lexiftool_info_free(&info);
    {
        const char* v[] = { "-b", "-XMP-dc:Description", copy };
        good = lexiftool_execute(s, 3, v, &r) == LEXIFTOOL_OK && r.stdout_len == BIG &&
               memcmp(r.stdout_data, big, BIG) == 0;
        lexiftool_result_free(&r);
    }
    ok(good, "large value: a command's stdout (-b) byte for byte");
    {
        const char* v[] = { "-listx" };
        good = lexiftool_execute(s, 1, v, &r) == LEXIFTOOL_OK && r.stdout_len > 1000000;
        lexiftool_result_free(&r);
    }
    ok(good, "large stdout: -listx");
    /* many commands in one session */
    good = 1;
    for (i = 0; i < commands; i++) {
        const char* v[] = { "-s", "-Make", "-Model", canon };
        if (lexiftool_execute(s, 4, v, &r) != LEXIFTOOL_OK || r.stdout_len < 20) good = 0;
        lexiftool_result_free(&r);
        if (i % 10 == 0) {
            if (lexiftool_image_info(s, canon, NULL, 0, 0, &info) != LEXIFTOOL_OK) good = 0;
            lexiftool_info_free(&info);
        }
    }
    ok(good, "many commands in one session");
    lexiftool_close(s);
    free(big);

    /* many sessions in a row: the memory in use levels off */
    good = 1;
    for (i = 0; i < cycles; i++) {
        const char* v[] = { "-ver" };
        s = lexiftool_open(NULL);
        if (lexiftool_execute(s, 1, v, &r) != LEXIFTOOL_OK) good = 0;
        lexiftool_result_free(&r);
        if (lexiftool_image_info(s, canon, NULL, 0, 0, &info) != LEXIFTOOL_OK) good = 0;
        lexiftool_info_free(&info);
        lexiftool_close(s);
        if (i == cycles / 5) rss_warm = rss_kb();
    }
    rss_end = rss_kb();
    ok(good, "open/execute/image_info/close in a row");
#if defined(LX_ASAN)
    (void)rss_warm; (void)rss_end;
    fprintf(report, "# (resident size not compared under AddressSanitizer)\n");
#else
    fprintf(report, "# resident size after %d sessions: %ld kB, after %d: %ld kB\n",
            cycles / 5 + 1, rss_warm, cycles, rss_end);
    ok(rss_warm > 0 && rss_end - rss_warm < 16384, "resident size levels off (less than 16 MB growth)");
#endif
}


#if defined(_WIN32)
/* a session before the state is recorded (see the description) */
static void warm_up(const char* images)
{
    char canon[2048];
    lexiftool_session* s = lexiftool_open(NULL);
    lexiftool_info info;
    snprintf(canon, sizeof(canon), "%s/Canon.jpg", images);
    EX(s, 0, "-ver");
    EX(s, 0, "-api", "TimeZone=Asia/Kolkata", "-d", "%c %Z", "-b", "-a", "-G1", canon);
    lexiftool_image_info(s, canon, NULL, 0, 0, &info);
    lexiftool_info_free(&info);
    lexiftool_close(s);
}
#endif

int main(int argc, char** argv)
{
    char out1[2048], out2[2048], in0[2048], extra[2048], workdir[2048];
    const char pending[] = "bytes pending in the host's stdout buffer\n";
    static char outbuf[8192];
    state before, after;
    int cycles = argc > 3 ? atoi(argv[3]) : 100, commands = argc > 4 ? atoi(argv[4]) : 1000;
    int fd1, fdx, fdp[2];
    FILE* f;
#if !defined(_WIN32)
    struct sigaction sa;
    sigset_t block;
#endif

    if (argc < 3) {
        fprintf(stderr, "usage: test_sideeffects T_IMAGES_DIR SCRATCH_DIR [SESSIONS [COMMANDS]]\n");
        return 2;
    }
#if defined(_WIN32) && (defined(_MSC_VER) || defined(_UCRT))
    /* (the descriptor scan asks the C runtime about descriptors that are
     * not open: no assertion dialog for that) */
    _set_invalid_parameter_handler(no_invalid_parameter);
#endif
    /* the report goes to a duplicate of the original stdout */
    if ((fd1 = dup(1)) < 0 || (report = fdopen(fd1, "w")) == NULL) return 2;
#if !defined(_WIN32)
    fcntl(fd1, F_SETFD, FD_CLOEXEC);
#endif

    /* ---- the host's state ---- */
    snprintf(out1, sizeof(out1), "%s/fd1.out", argv[2]);
    snprintf(out2, sizeof(out2), "%s/fd2.out", argv[2]);
    snprintf(in0, sizeof(in0), "%s/fd0.in", argv[2]);
    snprintf(extra, sizeof(extra), "%s/extra.txt", argv[2]);
    snprintf(workdir, sizeof(workdir), "%s/cwd", argv[2]);
    if ((f = fopen(in0, "w")) != NULL) { fputs("-ver\n-execute\n", f); fclose(f); }
    /* stdin from a file, stdout/stderr to files */
    if (freopen(in0, "r", stdin) == NULL || freopen(out1, "w", stdout) == NULL ||
        freopen(out2, "w", stderr) == NULL) return 2;
    setvbuf(stdout, outbuf, _IOFBF, sizeof(outbuf));
#if defined(_WIN32)
    setvbuf(stderr, NULL, _IOFBF, 4096);     /* (no line buffering in the C runtime) */
#else
    setvbuf(stderr, NULL, _IOLBF, 0);
    fwide(stderr, -1);
#endif
    fputs(pending, stdout);                     /* pending, not flushed */
    /* environment, time zone, locale */
#if defined(_WIN32)
    _putenv_s("TZ", "CST6CDT");
    _putenv_s("LEXIFTOOL_SIDE_EFFECT_TEST", "1");
    _tzset();
    if (setlocale(LC_ALL, "German_Germany.1252") == NULL && setlocale(LC_ALL, "de-DE") == NULL)
        setlocale(LC_ALL, "C");
#else
    setenv("TZ", "America/Chicago", 1);
    setenv("LEXIFTOOL_SIDE_EFFECT_TEST", "1", 1);
    tzset();
    if (setlocale(LC_ALL, "de_DE.UTF-8") == NULL && setlocale(LC_ALL, "de_DE.utf8") == NULL &&
        setlocale(LC_ALL, "C.UTF-8") == NULL)
        setlocale(LC_ALL, "C");
#endif
    fprintf(report, "# host locale %s, TZ %s\n", setlocale(LC_ALL, NULL), getenv("TZ"));
    /* signals: handlers, ignored ones, a blocked one */
#if defined(_WIN32)
    signal(SIGTERM, on_usr1);
    signal(SIGBREAK, SIG_IGN);
    signal(SIGINT, SIG_IGN);
#else
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_usr1;
    sigemptyset(&sa.sa_mask);
    sigaddset(&sa.sa_mask, SIGUSR2);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGUSR1, &sa, NULL);
    sa.sa_sigaction = on_hup;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCONT, SIG_IGN);
    sigemptyset(&block);
    sigaddset(&block, SIGUSR2);
    pthread_sigmask(SIG_BLOCK, &block, NULL);
#endif
    /* umask, cwd, extra descriptors (one close-on-exec / not inherited,
     * a pipe, one end non-blocking) */
    tp_mkdir(workdir);
#if defined(_WIN32)
    if (_chdir(workdir) != 0) return 2;
    fdx = _open(extra, _O_WRONLY | _O_CREAT | _O_APPEND | _O_NOINHERIT, _S_IREAD | _S_IWRITE);
    if (_pipe(fdp, 4096, _O_BINARY) != 0) return 2;
    /* the C runtime's caches, the DLLs it loads: before recording */
    warm_up(argv[1]);
#else
    umask(027);
    if (chdir(workdir) != 0) return 2;
    fdx = open(extra, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (pipe(fdp) != 0) return 2;
    fcntl(fdp[0], F_SETFL, O_NONBLOCK);
#endif

    record(&before);
    session_work(argv[1], argv[2]);
    resources(argv[1], argv[2], cycles, commands);
    record(&after);
    compare(&before, &after, "after the sessions");

    /* nothing on fd 1/2: stdout's file holds only the host's pending bytes
     * once they are flushed, stderr's file is empty */
    ok(file_size(out1) == 0 && file_size(out2) == 0, "nothing written to fd 1 or fd 2 (stdout buffer still pending)");
    fflush(stdout);
    /* (Windows: stdout in text mode writes the newline as CR LF) */
#if defined(_WIN32)
    ok(file_size(out1) == (long)strlen(pending) + 1, "stdout's file holds exactly the host's pending bytes after its flush");
#else
    ok(file_size(out1) == (long)strlen(pending), "stdout's file holds exactly the host's pending bytes after its flush");
#endif
    ok(got_usr1 == 0, "no signal delivered to the host's handler");
    close(fdx);
    close(fdp[0]);
    close(fdp[1]);
    free_state(&before);
    free_state(&after);
    fprintf(report, "# %d tests, %d failed (%d commands)\n", total, failed, nexec);
    fclose(report);
    return failed ? 1 : 0;
}
