/*------------------------------------------------------------------------------
 * File:         lexiftool/sys.c
 *
 * Description:  The few operating-system primitives Perl has built in and
 *               standard Lua lacks (module `lexiftool.sys`)
 *
 * Port notes:   Mandatory C helper of the port (module
 *               "lexiftool.sys"). Each library function stands in for one
 *               Perl builtin or core-module call; the perl facade
 *               (src/lexiftool/perl.lua) wraps the builtins, while the
 *               Win32 stand-ins are called directly at the upstream call
 *               sites they replace (lexiftool.lua, Writer.lua, main.lua):
 *                 platform()          $^O
 *                 setenv(name, value) $ENV{NAME} = VALUE (write only)
 *                 tzset()             POSIX::tzset / Time::Piece::_tzset
 *                 strftime(fmt, sec, min, hour, mday, mon, year)
 *                                     POSIX::strftime (libc strftime_l in
 *                                     the LC_TIME locale of the
 *                                     environment, a locale object of its
 *                                     own; the process locale is never
 *                                     switched)
 *                 decimal_point()     localeconv()->decimal_point (port:
 *                                     numbers print with '.' as Perl's
 *                                     LC_NUMERIC=C does)
 *                 strless(a, b)       $a lt $b on bytes (port: Perl
 *                                     compares strings as unsigned bytes
 *                                     outside `use locale`; Lua's `<` goes
 *                                     through strcoll)
 *                 strcmp(a, b)        $a cmp $b on bytes (-1, 0 or 1)
 *                 chmod(mode, path)   chmod MODE, FILE
 *                 chown(path, uid, gid) chown UID, GID, FILE (-1 keeps an id)
 *                 mkdir(path, mode)   mkdir PATH, MODE (CreateDirectoryW
 *                                     on Windows)
 *                 rename(old, new)    rename OLD, NEW (MoveFileExW)
 *                 unlink(path)        unlink FILE (DeleteFileW)
 *                 ftruncate(fh, len)  truncate FILEHANDLE, LENGTH
 *                 setmode(fh, crlf)   binmode FILEHANDLE[, ':crlf']
 *                 isreg(fh)           -f FILEHANDLE
 *                 signal(name, func)  $SIG{NAME} = HANDLER
 *                 nosignals([on])     (port: no process-wide signal
 *                                     handlers in this Lua state, for an
 *                                     embedding host)
 *                 errno()             errno (for the exit status of an
 *                                     uncaught die)
 *                 gettimeofday()      Time::HiRes::gettimeofday (list
 *                                     context: seconds, microseconds)
 *                 sleep_ms(ms)        select(undef,undef,undef,SECONDS)
 *               POSIX only:
 *                 getpwuid/getpwnam/getgrgid/getgrnam  the builtins of the
 *                                     same names (scalar context)
 *                 realpath(path)      Cwd::abs_path
 *                 get_btime(path)     File::StatX statx() STATX_BTIME
 *                                     (Linux, where the headers have it;
 *                                     the raw syscall below glibc 2.28)
 *                 readkey_noecho()    Term::ReadKey ReadMode('cbreak') +
 *                                     ReadKey(0) + ReadMode(0) (termios)
 *               Windows only (Win32::API / Win32API::File / Win32::FindFile
 *               upstream; names are UTF-8 and widened here):
 *                 open(path, mode)    Win32API::File::CreateFileW +
 *                                     OsFHandleOpenFd, with ExifTool::Open's
 *                                     access/share/create flags; returns an
 *                                     ordinary Lua file
 *                 create_file_read(path)         CreateFileW (GENERIC_READ,
 *                                     FILE_SHARE_READ, OPEN_EXISTING) +
 *                                     CloseHandle (ExifTool::Exists)
 *                 get_full_path_name(path)       GetFullPathNameW
 *                 get_file_attributes(path)      GetFileAttributesW
 *                 get_file_time(fh)   GetOsFHandle + GetFileTime
 *                 set_file_time(fh, atime, mtime, ctime)
 *                                     GetOsFHandle + SetFileTime
 *                 read_dir(dir)       Win32::FindFile::ReadDir
 *                                     (FindFirstFileW/FindNextFileW)
 *                 readmode(mode)      Term::ReadKey::ReadMode (console
 *                                     mode of STDIN)
 *                 peekchar()          Term::ReadKey::Win32PeekChar(STDIN, 0)
 *               Test-harness primitives (spawn, cpu_count, getpid,
 *               copy_file, set_times), see the section further down; the
 *               library does not call them.
 *               Depends on the C runtime (and, on Windows, kernel32) only --
 *               no third-party library, so it builds wherever Lua does.
 *               (Brotli, which needs libbrotlidec/enc, comes from the
 *               separate optional rock lbrotli, like upstream's optional
 *               IO::Uncompress::Brotli.)
 *               Windows (MSVC or MinGW, _WIN32) uses the CRT spellings
 *               _putenv_s/_tzset/_chmod/_chsize_s/_setmode/_open_osfhandle,
 *               CRT signal() and the Win32 API of <windows.h>, all present
 *               with the classic msvcrt.dll as well as with the UCRT;
 *               no POSIX header is included in that branch.
 *               Build: `make sys` (gcc/clang -shared; see the Makefile for
 *               macOS and the Windows command lines).
 *------------------------------------------------------------------------------
 */

#if defined(_WIN32)
#  if defined(__MINGW32__) && !defined(MINGW_HAS_SECURE_API)
#    define MINGW_HAS_SECURE_API 1  /* _putenv_s, _chsize_s in MinGW-w64 */
#  endif
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN     /* kernel32 API only from <windows.h> */
#  endif
#else
#  ifndef _FILE_OFFSET_BITS
#    define _FILE_OFFSET_BITS 64    /* 64-bit off_t for ftruncate */
#  endif
#  ifndef _POSIX_C_SOURCE
#    define _POSIX_C_SOURCE 200809L /* setenv, sigaction, fileno */
#  endif
#  ifndef _DEFAULT_SOURCE
#    define _DEFAULT_SOURCE         /* realpath(path, NULL) (glibc; a
                                        _POSIX_C_SOURCE definition above
                                        would otherwise suppress it) */
#  endif
#  if defined(__linux__) && !defined(_GNU_SOURCE)
#    define _GNU_SOURCE            /* statx() (file creation time) */
#  endif
#  if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#    define _DARWIN_C_SOURCE        /* keep the BSD names visible on macOS */
#  endif
#endif

#include <errno.h>
#include <locale.h>     /* newlocale / _create_locale (strftime), localeconv */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#if defined(_WIN32)
#  include <fcntl.h>    /* _O_BINARY, _O_TEXT */
#  include <io.h>       /* _chmod, _chsize_s, _fileno, _setmode, _get_osfhandle */
#  include <stdlib.h>   /* _putenv_s */
#  include <sys/stat.h> /* _S_IREAD, _S_IWRITE */
#  include <time.h>     /* _tzset, mktime, _wcsftime_l */
#  include <wchar.h>    /* wide command lines for spawn() */
#  include <windows.h>  /* GetSystemTimeAsFileTime, CreateProcessW, ... */
#else
#  include <fcntl.h>    /* open, O_* (spawn stdio) */
#  include <stdlib.h>   /* setenv */
#  include <sys/stat.h> /* chmod */
#  include <sys/types.h>
#  include <sys/utsname.h>
#  include <sys/wait.h> /* waitpid */
#  include <langinfo.h> /* nl_langinfo_l(CODESET) (strftime) */
#  include <termios.h>
#  include <time.h>     /* tzset, clock_gettime, mktime, strftime_l */
#  include <unistd.h>   /* ftruncate, isatty, read, fork, execvp */
#  include <pwd.h>      /* getpwuid, getpwnam */
#  include <grp.h>      /* getgrgid, getgrnam */
#  if defined(__APPLE__)
#    include <sys/attr.h> /* setattrlist, ATTR_CMN_CRTIME */
#    include <xlocale.h>  /* locale_t, strftime_l, nl_langinfo_l */
#  endif
#endif

/* Guard against building with the headers of another Lua version: the
 * Makefile passes the version it builds for. */
#if defined(LEXIFTOOL_LUA_VERSION_NUM) && LEXIFTOOL_LUA_VERSION_NUM != LUA_VERSION_NUM
#  error "lua.h does not match the Lua version this module is built for (check LUA_INCDIR)"
#endif

/* Perl's convention for a failed system call: false plus the error text. */
#if defined(_WIN32)
static wchar_t* wide_from_utf8(const char* s);
#endif

static int push_error(lua_State* L, int err) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    lua_pushinteger(L, err);
    return 3;
}

#if defined(_WIN32)
/* The same for a Win32 error code (GetLastError()): its system message text
 * (strerror() knows only the CRT's errno values), and the code itself, which
 * is what Perl's Win32::GetLastError() reports. */
static int push_winerror(lua_State* L, DWORD err) {
    char buf[512];
    DWORD n = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, err, 0, buf, (DWORD)sizeof(buf), NULL);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == '.'))
        --n;    /* drop the trailing ".\r\n" */
    lua_pushnil(L);
    if (n > 0) lua_pushlstring(L, buf, (size_t)n);
    else lua_pushfstring(L, "error %d", (int)err);
    lua_pushinteger(L, (lua_Integer)err);
    return 3;
}
#endif

/*------------------------------------------------------------------------------
 * $^O -- the operating system name Perl was built for. Decided at compile
 * time, like Perl's own value. MSYS is tested before cygwin because the
 * MSYS2 runtime is a cygwin fork that defines __CYGWIN__ too, while its Perl
 * reports 'msys'; MirBSD before OpenBSD for the same reason.
 */
static int sys_platform(lua_State* L) {
#if defined(_WIN32)
    lua_pushliteral(L, "MSWin32");
#elif defined(__MSYS__)
    lua_pushliteral(L, "msys");
#elif defined(__CYGWIN__)
    lua_pushliteral(L, "cygwin");
#elif defined(__APPLE__) && defined(__MACH__)
    lua_pushliteral(L, "darwin");
#elif defined(__ANDROID__)
    lua_pushliteral(L, "android");
#elif defined(__linux__)
    lua_pushliteral(L, "linux");
#elif defined(__FreeBSD__)
    lua_pushliteral(L, "freebsd");
#elif defined(__MirBSD__)
    lua_pushliteral(L, "mirbsd");
#elif defined(__OpenBSD__)
    lua_pushliteral(L, "openbsd");
#elif defined(__NetBSD__)
    lua_pushliteral(L, "netbsd");
#elif defined(__DragonFly__)
    lua_pushliteral(L, "dragonfly");
#elif defined(__sun)
    lua_pushliteral(L, "solaris");
#elif defined(_AIX)
    lua_pushliteral(L, "aix");
#elif defined(__hpux)
    lua_pushliteral(L, "hpux");
#elif defined(__HAIKU__)
    lua_pushliteral(L, "haiku");
#elif defined(__GNU__)
    lua_pushliteral(L, "gnu");
#else
    /* any other Unix: Perl's Configure takes the lower-cased uname -s */
    struct utsname u;
    if (uname(&u) == 0) {
        char buf[sizeof(u.sysname)];
        size_t i;
        for (i = 0; u.sysname[i] && i < sizeof(buf) - 1; ++i) {
            char c = u.sysname[i];
            buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
        }
        buf[i] = '\0';
        lua_pushstring(L, buf);
    } else {
        lua_pushliteral(L, "unix");
    }
#endif
    return 1;
}

/*------------------------------------------------------------------------------
 * $ENV{NAME} = VALUE -- writes the process environment. On POSIX setenv()
 * updates the one copy there is. On Windows there are two: the C runtime's
 * (read by getenv/os.getenv and consulted by _tzset) and the Win32 block
 * (passed to CreateProcess). Both are updated, so a child spawned right after
 * the write sees the value too. There is deliberately no unsetenv (upstream
 * never deletes from %ENV).
 */
static int sys_setenv(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    const char* value = luaL_checkstring(L, 2);
#if defined(_WIN32)
    /* Both are needed: _putenv_s updates the CRT's environment (what getenv
     * and Perl's %ENV read), SetEnvironmentVariableW the Win32 block that
     * CreateProcessW passes on to children. */
    {
        wchar_t* wname = wide_from_utf8(name);
        wchar_t* wvalue = wide_from_utf8(value);
        DWORD e = ERROR_NOT_ENOUGH_MEMORY;
        BOOL ok = FALSE;
        if (wname && wvalue) {
            ok = SetEnvironmentVariableW(wname, wvalue);
            if (!ok) e = GetLastError();
        }
        free(wname);
        free(wvalue);
        if (!ok) return push_winerror(L, e);
    }
    {
        errno_t err = _putenv_s(name, value);
        if (err != 0) return push_error(L, err);
    }
#else
    if (setenv(name, value, 1) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/* POSIX::tzset() / Time::Piece::_tzset() -- re-read TZ from the environment */
static int sys_tzset(lua_State* L) {
#if defined(_WIN32)
    _tzset();
#else
    tzset();
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * POSIX::strftime(fmt, sec, min, hour, mday, mon, year) -- Perl 5.42's
 * POSIX.xs strftime with its default isdst = -1 (the only form upstream
 * calls), i.e. locale.c sv_strftime_ints -> ints_to_tm + sv_strftime_common
 * -> strftime8 -> strftime_tm, over the platform's own libc strftime (not
 * Lua's os.date, which on Windows rejects conversions outside its own list,
 * %C and %e among them, where Perl hands the format to the CRT unchanged):
 *  - the struct tm is zeroed, the six fields are set, tm_isdst = -1, and
 *    libc mktime() normalizes it in place (its result is ignored, so a time
 *    mktime cannot represent -- before 1970 on Windows -- keeps the fields
 *    as given, with tm_wday/tm_yday 0, as in Perl);
 *  - it formats in the locale Perl gives LC_TIME (and LC_CTYPE) from the
 *    environment at startup (LC_ALL, else LC_TIME, else LANG; with none of
 *    them the system default: "C" on POSIX, ".ACP" on Windows -- locale.c
 *    find_locale_from_environment; "C" for a name the system does not
 *    know). Where Perl sets that locale for the whole process, the name is
 *    read here at the first call and loaded into a locale object of this
 *    module instance (a userdata upvalue of the function, freed with it),
 *    which strftime_l / nl_langinfo_l use; the process and thread locales
 *    are never switched, so an embedding host and other Lua states are not
 *    affected. Windows has no _strftime_l in msvcrt.dll, so the format is
 *    widened, run through _wcsftime_l and narrowed again, in the code page
 *    the locale name gives (".UTF-8"/".65001": UTF-8, ".ACP"/".OCP": the
 *    system's ANSI/OEM code page, a numeric suffix: that code page, "C":
 *    Latin-1, which maps every byte to itself as the CRT's "C" locale
 *    does, anything else: the ANSI code page);
 *  - in a UTF-8 locale a format with bytes above 0x7f is upgraded from
 *    Latin-1 to UTF-8 first (strftime8, called_externally), so its result
 *    holds those characters UTF-8 encoded -- the bytes Perl's string
 *    carries once ExifTool's Sanitize has encoded it;
 *  - the buffer starts at max(2 * length, 64) and doubles while strftime
 *    returns 0, up to 2049 times the format length; an empty format gives
 *    "", a 0 return for exactly "%p" gives "", any other 0 return is a
 *    failure. On Windows a strftime that sets errno to EINVAL (an invalid
 *    conversion, reported through the CRT's invalid-parameter handler) fails
 *    at once. With the UCRT (or MSVC 2012 and later) the handler is
 *    silenced for the duration of the call through the thread-local
 *    handler, invisible to the rest of the process (the default handler of
 *    an MSVC build would end the process; Strawberry Perl's MinGW runtime
 *    silences it); msvcrt.dll calls none.
 * Returns the formatted string, or nil with errno = EINVAL on failure (the
 * facade turns that into POSIX::strftime's empty string).
 */
#if defined(_WIN32) && (defined(_UCRT) || (defined(_MSC_VER) && _MSC_VER >= 1700))
#  define SYS_THREAD_IPH 1
#  if defined(__MINGW32__)
/* (in the UCRT import libraries of MinGW-w64, not in its headers) */
_CRTIMP _invalid_parameter_handler __cdecl
_set_thread_local_invalid_parameter_handler(_invalid_parameter_handler handler);
#  endif
static void silent_invalid_parameter(const wchar_t* expression, const wchar_t* function,
                                     const wchar_t* file, unsigned int line,
                                     uintptr_t reserved) {
    (void)expression; (void)function; (void)file; (void)line; (void)reserved;
}
#endif

/* An int argument the way Perl's int typemap takes it: (int)SvIV(arg) */
static int int_arg(lua_State* L, int i) {
    lua_Integer v;
    if (lua_isinteger(L, i)) {
        v = lua_tointeger(L, i);
    } else {
        lua_Number n = luaL_checknumber(L, i);
        if (n != n) v = 0;
        else if (n >= (lua_Number)LUA_MAXINTEGER) v = LUA_MAXINTEGER;
        else if (n <= (lua_Number)LUA_MININTEGER) v = LUA_MININTEGER;
        else v = (lua_Integer)n;
    }
    return (int)v;
}

/* locale.c is_codeset_name_UTF8: "UTF-8" or "UTF8", any case */
static int is_utf8_codeset(const char* name) {
    static const char u[] = "utf";
    int i;
    if (name == NULL) return 0;
    for (i = 0; i < 3; ++i) {
        char c = name[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (c != u[i]) return 0;
    }
    name += 3;
    if (*name == '-') ++name;
    return name[0] == '8' && name[1] == '\0';
}

/* The locale object strftime formats in (upvalue 1 of sys_strftime) */
#define LOCALE_META "lexiftool.sys.locale"

typedef struct {
    int ready;              /* loaded (at the first call) */
    int isUtf8;             /* its character set is UTF-8 */
#if defined(_WIN32)
    _locale_t loc;
    UINT cp;                /* code page of the narrow strings */
#else
    locale_t loc;
#endif
} SysLocale;

static int sys_locale_gc(lua_State* L) {
    SysLocale* sl = (SysLocale*)luaL_checkudata(L, 1, LOCALE_META);
    if (sl->loc) {
#if defined(_WIN32)
        _free_locale(sl->loc);
#else
        freelocale(sl->loc);
#endif
        sl->loc = 0;
    }
    sl->ready = 0;
    return 0;
}

#if defined(_WIN32)
/* The code page of a Windows locale name ("German_Germany.1252",
 * "de-DE.UTF-8", ".ACP", "C") */
static UINT codepage_of(const char* name) {
    const char* dot = strrchr(name, '.');
    if (strcmp(name, "C") == 0 || strcmp(name, "POSIX") == 0) return 28591;
    if (dot != NULL) {
        const char* s = dot + 1;
        if (is_utf8_codeset(s)) return CP_UTF8;
        if (_stricmp(s, "ACP") == 0) return GetACP();
        if (_stricmp(s, "OCP") == 0) return GetOEMCP();
        if (*s >= '0' && *s <= '9') {
            char* end;
            unsigned long n = strtoul(s, &end, 10);
            if (*end == '\0' && n <= 0xffffUL && IsValidCodePage((UINT)n)) return (UINT)n;
        }
    }
    return GetACP();
}
#endif

/* Load the locale of the environment once (find_locale_from_environment) */
static SysLocale* get_locale(lua_State* L) {
    SysLocale* sl = (SysLocale*)lua_touserdata(L, lua_upvalueindex(1));
    const char* name;
    if (sl->ready) return sl;
    name = getenv("LC_ALL");
    if (name == NULL || *name == '\0') name = getenv("LC_TIME");
    if (name == NULL || *name == '\0') name = getenv("LANG");
    if (name == NULL || *name == '\0') {
#if defined(_WIN32)
        name = ".ACP";
#else
        name = "C";
#endif
    }
#if defined(_WIN32)
    sl->loc = _create_locale(LC_ALL, name);
    if (sl->loc == NULL) {
        name = "C";             /* (Perl falls back to "C" for a bad name) */
        sl->loc = _create_locale(LC_ALL, name);
    }
    sl->cp = codepage_of(name);
    sl->isUtf8 = (sl->cp == CP_UTF8);
#else
    sl->loc = newlocale(LC_TIME_MASK | LC_CTYPE_MASK, name, (locale_t)0);
    if (sl->loc == (locale_t)0) {
        name = "C";             /* (Perl falls back to "C" for a bad name) */
        sl->loc = newlocale(LC_TIME_MASK | LC_CTYPE_MASK, name, (locale_t)0);
    }
    sl->isUtf8 = sl->loc ? is_utf8_codeset(nl_langinfo_l(CODESET, sl->loc)) : 0;
#endif
    sl->ready = 1;
    return sl;
}

static int sys_strftime(lua_State* L) {
    const char* fmt = luaL_checkstring(L, 1);
    size_t fmtlen = strlen(fmt);    /* (Perl passes the format as a C string) */
    struct tm mytm;
    SysLocale* sl;
    char* upgraded = NULL;
    char* out = NULL;
    size_t bufsize, len = 0, outlen = 0;
    int succeeded = 0;
#if defined(_WIN32)
    wchar_t* wfmt = NULL;
    wchar_t* wbuf = NULL;
#endif
#if defined(SYS_THREAD_IPH)
    _invalid_parameter_handler origHandler;
#endif

    size_t origlen = fmtlen;    /* (sv_strftime_common sizes the buffer
                                   from the format as passed) */

    memset(&mytm, 0, sizeof(mytm));
    mytm.tm_sec  = int_arg(L, 2);
    mytm.tm_min  = int_arg(L, 3);
    mytm.tm_hour = int_arg(L, 4);
    mytm.tm_mday = int_arg(L, 5);
    mytm.tm_mon  = int_arg(L, 6);
    mytm.tm_year = int_arg(L, 7);

    /* the locale Perl's LC_TIME has (find_locale_from_environment) */
    sl = get_locale(L);

    /* ints_to_tm: libc mktime() with isdst = -1 normalizes the fields */
    mytm.tm_isdst = -1;
    (void)mktime(&mytm);

    /* strftime8: a byte format becomes UTF-8 in a UTF-8 locale */
    if (sl->isUtf8) {
        size_t i, n = 0;
        for (i = 0; i < fmtlen; ++i) n += ((unsigned char)fmt[i] >= 0x80) ? 2 : 1;
        if (n != fmtlen) {
            upgraded = (char*)malloc(n + 1);
            if (upgraded) {
                char* o = upgraded;
                for (i = 0; i < fmtlen; ++i) {
                    unsigned char c = (unsigned char)fmt[i];
                    if (c >= 0x80) {
                        *o++ = (char)(0xc0 | (c >> 6));
                        *o++ = (char)(0x80 | (c & 0x3f));
                    } else {
                        *o++ = (char)c;
                    }
                }
                *o = '\0';
                fmt = upgraded;
                fmtlen = n;
            }
        }
    }

    /* strftime_tm (an empty format yields an empty result) */
    if (fmtlen == 0) {
        succeeded = 1;
    } else {
#if defined(_WIN32)
        /* (no _strftime_l in msvcrt.dll: the wide variant, in the code
           page of the locale) */
        int wlen = (sl->loc && fmtlen < (size_t)0x7fffffff)
                 ? MultiByteToWideChar(sl->cp, 0, fmt, (int)fmtlen, NULL, 0) : 0;
        if (wlen > 0) {
            wfmt = (wchar_t*)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
            if (wfmt) {
                MultiByteToWideChar(sl->cp, 0, fmt, (int)fmtlen, wfmt, wlen);
                wfmt[wlen] = L'\0';
            }
        }
        if (wfmt) {
#  if defined(SYS_THREAD_IPH)
            origHandler = _set_thread_local_invalid_parameter_handler(silent_invalid_parameter);
#  endif
            bufsize = origlen * 2 > 64 ? origlen * 2 : 64;
            do {
                wchar_t* nbuf = (wchar_t*)realloc(wbuf, bufsize * sizeof(wchar_t));
                int saved = errno, failed;
                if (nbuf == NULL) break;
                wbuf = nbuf;
                /* Windows will tell you if the input is invalid */
                errno = 0;
                len = _wcsftime_l(wbuf, bufsize, wfmt, &mytm, sl->loc);
                failed = (errno == EINVAL);
                errno = saved;
                if (failed) break;
                if (len >= 1 && len <= bufsize - 1) {
                    succeeded = 1;
                    break;
                }
                bufsize *= 2;
            } while (bufsize < ((size_t)(1 << 11) + 1) * fmtlen);
#  if defined(SYS_THREAD_IPH)
            _set_thread_local_invalid_parameter_handler(origHandler);
#  endif
            if (succeeded) {
                int n = WideCharToMultiByte(sl->cp, 0, wbuf, (int)len, NULL, 0, NULL, NULL);
                out = n > 0 ? (char*)malloc((size_t)n) : NULL;
                if (out) {
                    WideCharToMultiByte(sl->cp, 0, wbuf, (int)len, out, n, NULL, NULL);
                    outlen = (size_t)n;
                } else {
                    succeeded = 0;
                }
            }
        }
#else
        if (sl->loc) {
            bufsize = origlen * 2 > 64 ? origlen * 2 : 64;
            do {
                char* nbuf = (char*)realloc(out, bufsize);
                if (nbuf == NULL) break;
                out = nbuf;
                len = strftime_l(out, bufsize, fmt, &mytm, sl->loc);
                if (len >= 1 && len <= bufsize - 1) {
                    succeeded = 1;
                    outlen = len;
                    break;
                }
                bufsize *= 2;
            } while (bufsize < ((size_t)(1 << 11) + 1) * fmtlen);
        }
#endif
        if (!succeeded && strcmp(fmt, "%p") == 0) {
            outlen = 0;
            succeeded = 1;
        }
    }

#if defined(_WIN32)
    free(wfmt);
    free(wbuf);
#endif
    free(upgraded);
    if (succeeded) {
        lua_pushlstring(L, outlen ? out : "", outlen);
        free(out);
    } else {
        free(out);
        lua_pushnil(L);
        errno = EINVAL;         /* (SET_EINVAL) */
    }
    return 1;
}

/*------------------------------------------------------------------------------
 * The decimal point of the process's current LC_NUMERIC locale (port: Perl
 * keeps LC_NUMERIC at "C" outside `use locale`, so its numbers always print
 * with '.'; Lua's number formatting follows the global locale, which an
 * embedding host may have set. The facade replaces this string with '.' --
 * it only reads the locale, never sets it). May be more than one byte.
 */
static int sys_decimal_point(lua_State* L) {
    const struct lconv* lc = localeconv();
    const char* dp = (lc && lc->decimal_point && lc->decimal_point[0])
                   ? lc->decimal_point : ".";
    lua_pushstring(L, dp);
    return 1;
}

/*------------------------------------------------------------------------------
 * String order as Perl's lt/cmp outside `use locale`: unsigned bytes, a
 * prefix before the longer string. Lua's own `<` compares two strings with
 * strcoll, i.e. in the LC_COLLATE order of the process's locale, which an
 * embedding host may have set (de_DE: "a A b B"; Perl: "A B a b"). The
 * locale is only bypassed here, never read or set.
 */
static int byte_cmp(const char* a, size_t la, const char* b, size_t lb) {
    int c = memcmp(a, b, la < lb ? la : lb);
    if (c != 0) return c < 0 ? -1 : 1;
    return la < lb ? -1 : (la > lb ? 1 : 0);
}

/* strless(a, b): true when a sorts before b. Two strings compare bytewise;
 * any other pair goes to Lua's `<` (numbers numerically, a metamethod, or
 * Lua's error for a mixed pair), so this is a drop-in comparator for
 * table.sort wherever `<` was one. */
static int sys_strless(lua_State* L) {
    if (lua_type(L, 1) == LUA_TSTRING && lua_type(L, 2) == LUA_TSTRING) {
        size_t la, lb;
        const char* a = lua_tolstring(L, 1, &la);
        const char* b = lua_tolstring(L, 2, &lb);
        lua_pushboolean(L, byte_cmp(a, la, b, lb) < 0);
    } else {
        lua_pushboolean(L, lua_compare(L, 1, 2, LUA_OPLT));
    }
    return 1;
}

/* strcmp(a, b): -1, 0 or 1 as `a cmp b`; numbers are converted with Lua's
 * tostring rules (the facade passes Perl-stringified values). */
static int sys_strcmp(lua_State* L) {
    size_t la, lb;
    const char* a = luaL_checklstring(L, 1, &la);
    const char* b = luaL_checklstring(L, 2, &lb);
    lua_pushinteger(L, byte_cmp(a, la, b, lb));
    return 1;
}

/*------------------------------------------------------------------------------
 * chmod MODE, FILE (one file; the facade loops over Perl's LIST). Windows
 * keeps only a read-only flag: like Perl's win32_chmod, the owner read/write
 * bits are passed on (_S_IREAD/_S_IWRITE are 0400/0200 there too), the rest
 * has no meaning for the CRT.
 */
static int sys_chmod(lua_State* L) {
    lua_Integer mode = luaL_checkinteger(L, 1);
    const char* path = luaL_checkstring(L, 2);
#if defined(_WIN32)
    if (_chmod(path, (int)(mode & (_S_IREAD | _S_IWRITE))) != 0) return push_error(L, errno);
#else
    if (chmod(path, (mode_t)(mode & 07777)) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/* chown(2) for Perl's chown: -1 leaves an id alone. On Windows Perl's chown
 * is a no-op that still counts the file, so succeed without touching it. */
static int sys_chown(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer uid = luaL_optinteger(L, 2, -1);
    lua_Integer gid = luaL_optinteger(L, 3, -1);
#if defined(_WIN32)
    (void)uid; (void)gid;
    if (_access(path, 0) != 0) return push_error(L, errno);
#else
    if (chown(path, (uid_t)uid, (gid_t)gid) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

#if defined(_WIN32)
/* closef method of the stdio handles sys.open returns (the io library's own
 * close function is static, so a wide handle needs this one) */
static int sys_fclose_file(lua_State* L) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    int ok = 1;
    if (p->f) {
        if (fclose(p->f) != 0) ok = 0;
        p->f = NULL;
    }
    p->closef = NULL;
    if (!ok) return push_error(L, errno);
    lua_pushboolean(L, 1);
    return 1;
}
#endif

/*------------------------------------------------------------------------------
 * The Windows Unicode branch of ExifTool::Open: Win32API::File::CreateFileW
 * with the access, share and creation flags upstream derives from the Perl
 * MODE ('<' read, '>' write, '>>' append, '+<' update), then OsFHandleOpenFd
 * (_open_osfhandle) and Perl's open "&=FD" (_fdopen). As upstream, a handle
 * opened for writing shares nothing (share 0), one opened for reading shares
 * read and write. The result is an ordinary Lua file (the "FILE*" metatable),
 * so io.read/write/seek/close/lines work on it. Returns the file, or nil plus
 * the error.
 */
#if defined(_WIN32)
static int sys_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    const char* mode = luaL_optstring(L, 2, "<");
    DWORD access, share = 0, create;
    int flags;
    const char* cmode;
    wchar_t* wpath;
    HANDLE wh;
    int fd;
    luaL_Stream* p;
    if (!strcmp(mode, ">")) {
        access = GENERIC_WRITE;
        create = CREATE_ALWAYS;
        flags = _O_WRONLY | _O_BINARY;
        cmode = "wb";
    } else if (!strcmp(mode, ">>")) {
        access = GENERIC_WRITE | FILE_APPEND_DATA;
        create = OPEN_ALWAYS;
        flags = _O_WRONLY | _O_APPEND | _O_BINARY;
        cmode = "ab";
    } else if (!strcmp(mode, "<")) {
        access = GENERIC_READ;
        create = OPEN_EXISTING;
        flags = _O_RDONLY | _O_BINARY;
        cmode = "rb";
    } else if (!strcmp(mode, "+<")) {
        access = GENERIC_READ | GENERIC_WRITE;   /* update */
        create = OPEN_EXISTING;
        flags = _O_RDWR | _O_BINARY;
        cmode = "r+b";
    } else {
        return push_error(L, EINVAL);
    }
    if (!(access & GENERIC_WRITE)) share = FILE_SHARE_READ | FILE_SHARE_WRITE;
    /* the userdata first, closed (closef NULL), as liolib's newprefile: an
     * allocation error here then cannot leak an open handle */
    p = (luaL_Stream*)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
    p->f = NULL;
    p->closef = NULL;
    luaL_setmetatable(L, LUA_FILEHANDLE);
    wpath = wide_from_utf8(path);
    if (!wpath) return push_error(L, ENOMEM);
    wh = CreateFileW(wpath, access, share, NULL, create, 0, NULL);
    free(wpath);
    if (wh == INVALID_HANDLE_VALUE) return push_winerror(L, GetLastError());
    fd = _open_osfhandle((intptr_t)wh, flags);
    if (fd < 0) {
        CloseHandle(wh);
        return push_error(L, EBADF);
    }
    p->f = _fdopen(fd, cmode);
    if (!p->f) {
        int e = errno;
        _close(fd);     /* (closes wh too) */
        return push_error(L, e);
    }
    p->closef = &sys_fclose_file;
    return 1;
}
#endif

#if defined(_WIN32)
/*------------------------------------------------------------------------------
 * ExifTool::Exists's Windows test: Win32API::File::CreateFileW($file,
 * GENERIC_READ, FILE_SHARE_READ, [], OPEN_EXISTING, 0, []) and, when that
 * gives a handle, CloseHandle. True if the handle could be opened, else nil
 * plus the Win32 error -- so, as upstream, a directory (no
 * FILE_FLAG_BACKUP_SEMANTICS) or a file another process holds open for
 * writing does not "exist".
 */
static int sys_create_file_read(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    wchar_t* wpath = wide_from_utf8(path);
    HANDLE wh;
    if (!wpath) return push_error(L, ENOMEM);
    wh = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    free(wpath);
    if (wh == INVALID_HANDLE_VALUE) return push_winerror(L, GetLastError());
    CloseHandle(wh);
    lua_pushboolean(L, 1);
    return 1;
}
#endif

/*------------------------------------------------------------------------------
 * mkdir PATH, MODE -- Perl's mkdir (and the wide CreateDirectoryW on
 * Windows, so directory names outside the ANSI code page work). Returns true,
 * or nil plus the error.
 */
static int sys_mkdir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer mode = luaL_optinteger(L, 2, 0777);
#if defined(_WIN32)
    wchar_t* wpath = wide_from_utf8(path);
    DWORD e = 0;
    (void)mode;     /* (no permission bits on Windows, as Perl's win32_mkdir) */
    if (!wpath) return push_error(L, ENOMEM);
    if (!CreateDirectoryW(wpath, NULL)) e = GetLastError();
    free(wpath);
    if (e) return push_winerror(L, e);
#else
    if (mkdir(path, (mode_t)(mode & 07777)) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * rename OLD, NEW / unlink FILE -- Perl's builtins. Windows goes through the
 * wide API so file names outside the ANSI code page work; MoveFileExW also
 * replaces an existing target and redirects across volumes, as Perl's rename
 * does there. Return true, or nil plus the error.
 */
static int sys_rename(lua_State* L) {
    const char* old = luaL_checkstring(L, 1);
    const char* new = luaL_checkstring(L, 2);
#if defined(_WIN32)
    wchar_t* wold = wide_from_utf8(old);
    wchar_t* wnew = wide_from_utf8(new);
    DWORD e;
    BOOL ok;
    if (!wold || !wnew) {
        free(wold);
        free(wnew);
        return push_error(L, ENOMEM);
    }
    ok = MoveFileExW(wold, wnew, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED);
    e = ok ? 0 : GetLastError();
    free(wold);
    free(wnew);
    if (!ok) return push_winerror(L, e);
#else
    if (rename(old, new) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_unlink(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
#if defined(_WIN32)
    wchar_t* wpath = wide_from_utf8(path);
    DWORD e = 0;
    if (!wpath) return push_error(L, ENOMEM);
    if (!DeleteFileW(wpath)) e = GetLastError();
    free(wpath);
    if (e) return push_winerror(L, e);
#else
    if (unlink(path) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * truncate FILEHANDLE, LENGTH -- takes a Lua file handle (io.open), flushes
 * its stdio buffer, then cuts the underlying file to LENGTH bytes.
 */
static int sys_ftruncate(lua_State* L) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    lua_Integer len = luaL_checkinteger(L, 2);
    if (p->closef == NULL) return luaL_error(L, "attempt to use a closed file");
    if (len < 0) return push_error(L, EINVAL);
    if (fflush(p->f) != 0) return push_error(L, errno);
#if defined(_WIN32)
    {
        errno_t err = _chsize_s(_fileno(p->f), (__int64)len);
        if (err != 0) return push_error(L, err);
    }
#else
    if (ftruncate(fileno(p->f), (off_t)len) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * binmode FILEHANDLE[, ':crlf'] -- the Windows half of Perl's binmode: a
 * stream's CRT translation mode, '\n' <-> '\r\n' on write/read, is a
 * property of the underlying OS file descriptor, set with _setmode (there
 * is no portable, POSIX way to change it after an fdopen/fopen, which is
 * why perl.lua cannot just reopen the handle in a different mode itself).
 * No argument (or any other string) means binary, matching plain
 * binmode(FILEHANDLE); 'text' (crlf true) is exactly ':crlf'. A no-op
 * everywhere else: POSIX has no such distinction, matching Perl's own
 * binmode there.
 */
static int sys_setmode(lua_State* L) {
#if defined(_WIN32)
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    int crlf = lua_toboolean(L, 2);
    if (p->closef == NULL) return luaL_error(L, "attempt to use a closed file");
    if (fflush(p->f) != 0) return push_error(L, errno);
    if (_setmode(_fileno(p->f), crlf ? _O_TEXT : _O_BINARY) == -1)
        return push_error(L, errno);
#else
    luaL_checkudata(L, 1, LUA_FILEHANDLE);  /* same argument error as above */
#endif
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * -f FILEHANDLE: true if the open file is a plain file (fstat S_ISREG) --
 * perl.tell needs it: only there is the OS file position what Perl's tell
 * answers (a pipe or character device such as /dev/null has none)
 */
static int sys_isreg(lua_State* L) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    if (p->closef == NULL) return luaL_error(L, "attempt to use a closed file");
#if defined(_WIN32)
    {
        struct _stat64 st;
        if (_fstat64(_fileno(p->f), &st) != 0) return push_error(L, errno);
        lua_pushboolean(L, (st.st_mode & _S_IFMT) == _S_IFREG);
    }
#else
    {
        struct stat st;
        if (fstat(fileno(p->f), &st) != 0) return push_error(L, errno);
        lua_pushboolean(L, S_ISREG(st.st_mode));
    }
#endif
    return 1;
}

/*------------------------------------------------------------------------------
 * $SIG{NAME} = HANDLER
 *
 * Perl delivers signals "safely": the C-level handler only records the
 * signal, and the Perl handler runs at the next safe point between two ops.
 * The same here, the way lua.c handles Ctrl-C: the C handler sets a flag and
 * arms a one-shot debug hook (lua_sethook is async-signal-safe); the hook
 * runs between two Lua instructions, removes itself, restores a hook that
 * was installed before, and calls the Lua handler with the signal name as
 * its argument, as Perl does. Like Perl's safe signals, the handlers are
 * installed without SA_RESTART, so a blocking read on a pipe or terminal
 * returns early and the handler runs right after it.
 * Limits: the hook is armed on the main Lua thread, so a handler waits while
 * a coroutine runs; on Windows the CRT runs a SIGINT handler on its own
 * thread (as for lua.c's Ctrl-C handling) and resets it to SIG_DFL before
 * the call, so the handler re-installs itself.
 */
typedef struct { const char* name; int sig; } SigName;

static const SigName sigNames[] = {
#if defined(_WIN32)
    { "INT", SIGINT }, { "TERM", SIGTERM }, { "ABRT", SIGABRT },
#  ifdef SIGBREAK
    { "BREAK", SIGBREAK },
#  endif
#else
    { "HUP", SIGHUP }, { "INT", SIGINT }, { "QUIT", SIGQUIT },
    { "TERM", SIGTERM }, { "ABRT", SIGABRT }, { "ALRM", SIGALRM },
    { "USR1", SIGUSR1 }, { "USR2", SIGUSR2 }, { "PIPE", SIGPIPE },
    { "CHLD", SIGCHLD }, { "CONT", SIGCONT }, { "TSTP", SIGTSTP },
    { "TTIN", SIGTTIN }, { "TTOU", SIGTTOU },
#  ifdef SIGWINCH
    { "WINCH", SIGWINCH },
#  endif
#endif
    { NULL, 0 }
};
#define NSIGNAMES (sizeof(sigNames) / sizeof(sigNames[0]) - 1)

static const char* const HANDLERS_KEY = "lexiftool.sys.signal";
/* registry field: true = signal() only records the handler (nosignals) */
static const char* const NOSIGNALS_KEY = "lexiftool.sys.nosignals";

static lua_State* volatile sigState = NULL;     /* main thread */
static volatile sig_atomic_t sigPending[NSIGNAMES];
static volatile sig_atomic_t sigAny = 0;
static lua_Hook savedHook = NULL;
static int savedMask = 0, savedCount = 0;

static void sig_hook(lua_State* L, lua_Debug* ar);

static void sig_handler(int sig) {
    size_t i;
    lua_State* L = sigState;
#if defined(_WIN32)
    signal(sig, sig_handler);   /* the CRT has reset it to SIG_DFL */
#endif
    for (i = 0; i < NSIGNAMES; ++i) {
        if (sigNames[i].sig == sig) sigPending[i] = 1;
    }
    if (L != NULL && !sigAny) {
        lua_Hook old = lua_gethook(L);
        if (old != sig_hook) {
            savedHook = old;
            savedMask = lua_gethookmask(L);
            savedCount = lua_gethookcount(L);
        }
        sigAny = 1;
        lua_sethook(L, sig_hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
    }
}

static void sig_hook(lua_State* L, lua_Debug* ar) {
    size_t i;
    (void)ar;
    lua_sethook(L, savedHook, savedMask, savedCount);
    sigAny = 0;
    for (i = 0; i < NSIGNAMES; ++i) {
        if (!sigPending[i]) continue;
        sigPending[i] = 0;
        lua_getfield(L, LUA_REGISTRYINDEX, HANDLERS_KEY);
        if (lua_getfield(L, -1, sigNames[i].name) == LUA_TFUNCTION) {
            lua_remove(L, -2);
            lua_pushstring(L, sigNames[i].name);
            lua_call(L, 1, 0);
        } else {
            lua_pop(L, 2);
        }
    }
}

static int install(int sig, void (*func)(int)) {
#if defined(_WIN32)
    return signal(sig, func) == SIG_ERR ? -1 : 0;
#else
    struct sigaction act;
    memset(&act, 0, sizeof(act));
    act.sa_handler = func;
    sigemptyset(&act.sa_mask);
    act.sa_flags = 0;           /* no SA_RESTART, like Perl's safe signals */
    return sigaction(sig, &act, NULL);
#endif
}

/* signal(name, handler): handler is a function, 'IGNORE', or 'DEFAULT'/nil.
 * Returns true, or nil plus a message for a name this platform lacks (Perl
 * ignores %SIG keys that are no signal here, so callers may too). */
static int sys_signal(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    int type = lua_type(L, 2);
    size_t i;
    int rc;
    for (i = 0; i < NSIGNAMES; ++i) {
        if (strcmp(sigNames[i].name, name) == 0) break;
    }
    if (i == NSIGNAMES) {
        lua_pushnil(L);
        lua_pushfstring(L, "No such signal: SIG%s", name);
        return 2;
    }
    /* remember the Lua handler (or forget it) */
    lua_getfield(L, LUA_REGISTRYINDEX, HANDLERS_KEY);
    lua_pushvalue(L, 2);
    if (type != LUA_TFUNCTION) {
        lua_pop(L, 1);
        lua_pushnil(L);
    }
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
    /* a Lua state that must not touch the process's signal dispositions
     * (nosignals) keeps the handler and installs nothing */
    lua_getfield(L, LUA_REGISTRYINDEX, NOSIGNALS_KEY);
    rc = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (rc) {
        if (type != LUA_TFUNCTION && type != LUA_TNIL && type != LUA_TNONE &&
            !(type == LUA_TSTRING && (strcmp(lua_tostring(L, 2), "IGNORE") == 0 ||
                                      strcmp(lua_tostring(L, 2), "DEFAULT") == 0)))
            return luaL_argerror(L, 2, "function, 'IGNORE' or 'DEFAULT' expected");
        lua_pushboolean(L, 1);
        return 1;
    }
    if (type == LUA_TFUNCTION) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
        sigState = lua_tothread(L, -1);
        lua_pop(L, 1);
        rc = install(sigNames[i].sig, sig_handler);
    } else if (type == LUA_TSTRING && strcmp(lua_tostring(L, 2), "IGNORE") == 0) {
        rc = install(sigNames[i].sig, SIG_IGN);
    } else if (type == LUA_TNIL || type == LUA_TNONE ||
               (type == LUA_TSTRING && strcmp(lua_tostring(L, 2), "DEFAULT") == 0)) {
        rc = install(sigNames[i].sig, SIG_DFL);
    } else {
        return luaL_argerror(L, 2, "function, 'IGNORE' or 'DEFAULT' expected");
    }
    if (rc != 0) return push_error(L, errno);
    lua_pushboolean(L, 1);
    return 1;
}

/* nosignals([on]) -- (port, no Perl counterpart) switches this Lua state's
 * signal() to recording only: the handlers are kept (and never run), no
 * process-wide disposition is changed and the C-level state above is never
 * pointed at this Lua state. For an embedding host (the C API's sessions,
 * doc/capi.md), which must neither take over the host's Ctrl-C nor leave a
 * closed Lua state behind in sigState. The switch is a registry field, so
 * it is per Lua state; it must be set before the first signal() (main.lua
 * sets $SIG{INT}/$SIG{CONT} when it is loaded). Returns the setting before
 * the call; without an argument only reads it. The registry field
 * "lexiftool.sys.nosignals" may also be set from C before this module is
 * loaded. */
static int sys_nosignals(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, NOSIGNALS_KEY);
    lua_pushboolean(L, lua_toboolean(L, -1));
    if (!lua_isnoneornil(L, 1)) {
        lua_pushboolean(L, lua_toboolean(L, 1));
        lua_setfield(L, LUA_REGISTRYINDEX, NOSIGNALS_KEY);
    }
    return 1;
}

#if !defined(_WIN32)
/*------------------------------------------------------------------------------
 * Term::ReadKey::ReadMode('cbreak'); ReadKey(0); ReadMode(0) on POSIX -- read
 * one key from STDIN without echo and without waiting for RETURN, then
 * restore the terminal. Returns the key as a one-byte string, or nil at end
 * of input or when a signal interrupted the read. STDIN that is no terminal
 * is read as it is (Term::ReadKey's termios ReadMode has nothing to change
 * there and ignores the failed tcgetattr/tcsetattr, as here).
 */
static int sys_readkey_noecho(lua_State* L) {
    char c;
    struct termios oldt, newt;
    int fd = fileno(stdin);
    int tty = isatty(fd) && tcgetattr(fd, &oldt) == 0;
    ssize_t n;
    if (tty) {
        newt = oldt;
        newt.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
        newt.c_cc[VMIN] = 1;
        newt.c_cc[VTIME] = 0;
        tcsetattr(fd, TCSANOW, &newt);
    }
    n = read(fd, &c, 1);
    if (tty) tcsetattr(fd, TCSANOW, &oldt);
    if (n != 1) return 0;
    lua_pushlstring(L, &c, 1);
    return 1;
}
#else
/*------------------------------------------------------------------------------
 * Term::ReadKey's ReadMode(MODE) on Windows (ReadKey.xs, ReadMode under
 * WIN32), for STDIN: the console mode of STDIN's handle, saved on the first
 * call and restored by mode 0. MODE is the number Term::ReadKey maps its
 * names to (0 restore, 1 normal, 2 noecho, 3 cbreak, 4 raw, 5 ultra-raw).
 * As there, GetConsoleMode comes first, for every mode: STDIN that is no
 * console (a file, a pipe, the NUL device) fails it. Returns true, or nil
 * plus the text Term::ReadKey croaks with
 * ("GetConsoleMode failed, LastError=|N|", likewise for SetConsoleMode).
 */
static int readmode_saved = 0;      /* (the XS's filehash entry for STDIN) */
static DWORD readmode_savebuf;
static int sys_readmode(lua_State* L) {
    int mode = (int)luaL_checkinteger(L, 1);
    HANDLE whnd = (HANDLE)_get_osfhandle(_fileno(stdin));
    DWORD work;
    int firsttime = !readmode_saved;
    if (!GetConsoleMode(whnd, &work)) {
        lua_pushnil(L);
        lua_pushfstring(L, "GetConsoleMode failed, LastError=|%d|", (int)GetLastError());
        return 2;
    }
    if (firsttime) {
        readmode_savebuf = work;
        readmode_saved = 1;
    }
    switch (mode) {
        case 5:
            /* Should 5 disable ENABLE_WRAP_AT_EOL_OUTPUT? */
        case 4:
            work &= ~(ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT|ENABLE_LINE_INPUT|ENABLE_PROCESSED_OUTPUT);
            break;
        case 3:
            work &= ~(ENABLE_LINE_INPUT|ENABLE_ECHO_INPUT);
            work |= ENABLE_PROCESSED_INPUT|ENABLE_PROCESSED_OUTPUT;
            break;
        case 2:
            work &= ~(ENABLE_ECHO_INPUT);
            work |= ENABLE_LINE_INPUT|ENABLE_PROCESSED_INPUT|ENABLE_PROCESSED_OUTPUT;
            break;
        case 1:
            work |= ENABLE_ECHO_INPUT|ENABLE_LINE_INPUT|ENABLE_PROCESSED_INPUT|ENABLE_PROCESSED_OUTPUT;
            break;
        case 0:
            work = readmode_savebuf;
            firsttime = 1;
            break;
    }
    if (!SetConsoleMode(whnd, work)) {
        lua_pushnil(L);
        lua_pushfstring(L, "SetConsoleMode failed, LastError=|%d|", (int)GetLastError());
        return 2;
    }
    if (firsttime) readmode_saved = 0;  /* (mode 0 forgets the saved mode) */
    lua_pushboolean(L, 1);
    return 1;
}

/*------------------------------------------------------------------------------
 * Term::ReadKey's Win32PeekChar(STDIN, 0) -- its ReadKey(0) in cbreak (or a
 * rawer) mode on Windows: the next key-down event of the console input,
 * modifier-only keys skipped, the cursor and editing keys as their xterm
 * escape sequences (handed out one byte per call), a key's repeat count as
 * that many calls. Returns the byte as a one-byte string. Upstream does not
 * check ReadConsoleInput; here a failed read returns nil instead of reading
 * an undefined record (only possible once the console has gone away, since
 * ReadMode has succeeded before).
 */
#define KEY_PUSH(I, K) { peek_events[I].repeatCount = 1; peek_events[I].ascii = K; }
#define KEY_PUSH3(K1, K2, K3) \
    do { KEY_PUSH(2, K1); KEY_PUSH(1, K2); KEY_PUSH(0, K3); \
         peek_eventCount = 3; goto again; } while (0)
#define KEY_PUSH4(K1, K2, K3, K4) \
    do { KEY_PUSH(3, K1); KEY_PUSH(2, K2); KEY_PUSH(1, K3); KEY_PUSH(0, K4); \
         peek_eventCount = 4; goto again; } while (0)
static int peek_eventCount = 0;
static struct { int repeatCount; int ascii; } peek_events[4];
static int sys_peekchar(lua_State* L) {
    HANDLE whnd = (HANDLE)_get_osfhandle(_fileno(stdin));
    INPUT_RECORD record;
    DWORD readRecords;
    int keyCount;
    char key;
again:
    if (peek_eventCount) {
        key = (char)peek_events[peek_eventCount - 1].ascii;
        peek_events[peek_eventCount - 1].repeatCount--;
        if (peek_events[peek_eventCount - 1].repeatCount <= 0) peek_eventCount--;
        lua_pushlstring(L, &key, 1);
        return 1;
    }
    if (!ReadConsoleInputA(whnd, &record, 1, &readRecords) || readRecords == 0)
        return 0;
    if (record.EventType != KEY_EVENT) goto again;
    if (record.Event.KeyEvent.bKeyDown == FALSE) goto again;   /* throw away KeyUp events */
    switch (record.Event.KeyEvent.wVirtualKeyCode) {
        case 38: KEY_PUSH3(27, 91, 65);         /* up */
        case 40: KEY_PUSH3(27, 91, 66);         /* down */
        case 39: KEY_PUSH3(27, 91, 67);         /* right */
        case 37: KEY_PUSH3(27, 91, 68);         /* left */
        case 33: KEY_PUSH3(27, 79, 121);        /* page up */
        case 34: KEY_PUSH3(27, 79, 115);        /* page down */
        case 36: KEY_PUSH4(27, 91, 49, 126);    /* home */
        case 35: KEY_PUSH4(27, 91, 52, 126);    /* end */
        case 45: KEY_PUSH4(27, 91, 50, 126);    /* insert */
        case 46: KEY_PUSH4(27, 91, 51, 126);    /* delete */
        case 16: case 17: case 18: case 20: case 144: case 145:
            goto again;     /* throw away shift/alt/ctrl key only key events */
    }
    keyCount = record.Event.KeyEvent.wRepeatCount;
    key = record.Event.KeyEvent.uChar.AsciiChar;
    keyCount--;
    if (keyCount) {
        peek_events[0].repeatCount = keyCount;
        peek_events[0].ascii = key;
        peek_eventCount = 1;
    }
    lua_pushlstring(L, &key, 1);
    return 1;
}
#endif

/*------------------------------------------------------------------------------
 * errno -- the C library's last error number, for the exit status of an
 * uncaught Perl die (perl.c my_failure_exit: errno if it is set, else the
 * high byte of $?, else 255).
 */
static int sys_errno(lua_State* L) {
    lua_pushinteger(L, errno);
    return 1;
}

/*------------------------------------------------------------------------------
 * Time::HiRes::gettimeofday() in list context -- the wall-clock time as
 * whole seconds and microseconds since the epoch. Returns nothing when the
 * clock cannot be read.
 */
static int sys_gettimeofday(lua_State* L) {
#if defined(_WIN32)
    /* Not C11 timespec_get(): MinGW-w64 declares it only when building
     * against the UCRT, and the stand-alone build links the classic
     * msvcrt.dll. GetSystemTimeAsFileTime() exists on every Windows; a
     * FILETIME counts 100 ns units since 1601-01-01, which is
     * 11644473600 s before the Unix epoch. */
    FILETIME ft;
    unsigned long long t;
    GetSystemTimeAsFileTime(&ft);
    t = ((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    t -= 116444736000000000ULL;
    lua_pushinteger(L, (lua_Integer)(t / 10000000ULL));
    lua_pushinteger(L, (lua_Integer)((t / 10ULL) % 1000000ULL));
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 0;
    lua_pushinteger(L, (lua_Integer)ts.tv_sec);
    lua_pushinteger(L, (lua_Integer)(ts.tv_nsec / 1000));
#endif
    return 2;
}

#if !defined(_WIN32)
/*------------------------------------------------------------------------------
 * getpwuid/getpwnam/getgrgid/getgrnam in scalar context -- the user or group
 * name for a numeric id, or the id for a name; nothing when there is none.
 * Real libc calls (not /etc/passwd parsing), so a directory service such as
 * macOS's goes through the same path the C library (and therefore Perl's
 * own builtins) already consults. Not reentrant (plain getpwuid/getpwnam,
 * not the _r variants) -- fine for a single Lua state's own calls, exactly
 * what Perl's builtins are.  Windows has no POSIX user/group database and
 * Perl does not implement these there either (the port's callers already
 * expect nil, see perl.lua).
 */
static int sys_getpwuid(lua_State* L) {
    struct passwd* pw = getpwuid((uid_t)luaL_checkinteger(L, 1));
    if (pw == NULL) return 0;
    lua_pushstring(L, pw->pw_name);
    return 1;
}
static int sys_getpwnam(lua_State* L) {
    struct passwd* pw = getpwnam(luaL_checkstring(L, 1));
    if (pw == NULL) return 0;
    lua_pushinteger(L, (lua_Integer)pw->pw_uid);
    return 1;
}
static int sys_getgrgid(lua_State* L) {
    struct group* gr = getgrgid((gid_t)luaL_checkinteger(L, 1));
    if (gr == NULL) return 0;
    lua_pushstring(L, gr->gr_name);
    return 1;
}
static int sys_getgrnam(lua_State* L) {
    struct group* gr = getgrnam(luaL_checkstring(L, 1));
    if (gr == NULL) return 0;
    lua_pushinteger(L, (lua_Integer)gr->gr_gid);
    return 1;
}

/* Cwd::abs_path's realpath(3): resolves ".", ".." *and* symlinks (unlike
 * Windows, where NTFS reparse points mostly aren't; Cwd.pm does not
 * resolve them there either, so perl.lua's Windows fallback -- plain "."/
 * ".." normalization, no symlink resolution -- already matches). The
 * realpath(path, NULL) form mallocs the result buffer itself (POSIX.1-2008,
 * glibc and the BSD/Darwin libc both have it), so there is no PATH_MAX
 * buffer to size. NULL (nonexistent path, or any component unreadable) is
 * the caller's cue to fall back the way it already does for Windows. */
static int sys_realpath(lua_State* L) {
    char* p = realpath(luaL_checkstring(L, 1), NULL);
    if (p == NULL) return 0;
    lua_pushstring(L, p);
    free(p);
    return 1;
}

#if defined(__linux__) && defined(STATX_BTIME)
/* glibc declares the statx() wrapper only since 2.28, while the kernel
 * headers (struct statx, STATX_BTIME) can be newer than the libc: the
 * standalone executable and liblexiftool.so link against glibc 2.17. There
 * the raw syscall stands in; a kernel without statx (< 4.11) fails it with
 * ENOSYS, which ends up as nil like a missing birth time. */
#  if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 28))
#    include <sys/syscall.h>
#    include <unistd.h>
#    define LX_STATX(dirfd, path, flags, mask, buf) \
         syscall(SYS_statx, (dirfd), (path), (flags), (mask), (buf))
#  else
#    define LX_STATX(dirfd, path, flags, mask, buf) \
         statx((dirfd), (path), (flags), (mask), (buf))
#  endif
/* statx() birthtime: File::StatX's STATX_BTIME (upstream's Linux-only
 * FileCreateDate). Calls the libc wrapper rather than the raw syscall where
 * the libc has one, so the test harness's statx shim (tools/ctime_fake.c)
 * can pin it. nil when the filesystem doesn't record a birth time, like the
 * module's undefined btime. */
static int sys_get_btime(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    struct statx stx;
    if (LX_STATX(AT_FDCWD, path, 0, STATX_BTIME, &stx) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }
    if (!(stx.stx_mask & STATX_BTIME) || stx.stx_btime.tv_sec == 0) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushinteger(L, (lua_Integer)stx.stx_btime.tv_sec);
    return 1;
}
#endif
#endif

/*------------------------------------------------------------------------------
 * Test-harness primitives.
 *
 * The CLI harness (src/test-cli/) must run on POSIX and Windows without a
 * shell: `os.execute` goes through cmd.exe on Windows and cannot express
 * pipes, redirections, a working directory and a timeout portably. These
 * helpers live here because this is already the port's only C module; the
 * library itself calls none of them except sleep_ms (perl.select's timeout).
 *
 *   spawn(argv [, opts]) -> proc
 *       argv: array of strings; opts.cwd, opts.stdin ("pipe"|"null"),
 *       opts.stdout, opts.stderr (file paths), opts.timeout (seconds,
 *       enforced by proc:wait).
 *   proc:write(s) / proc:close_stdin() / proc:kill() / proc:pid()
 *   proc:wait([timeout_ms]) -> exit_code, signal, timed_out
 *   sleep_ms(ms), cpu_count(), getpid()
 *   copy_file(src, dst)
 *   set_times(path, atime, mtime, creation) -- nil leaves a time unchanged;
 *       creation is the file's birth time where the OS has one (macOS,
 *       Windows), ignored on Linux.
 *------------------------------------------------------------------------------
 */
#define PROC_META "lexiftool.sys.proc"

typedef struct {
#if defined(_WIN32)
    HANDLE in, process, thread, job;
#else
    int in;
    pid_t pid;
    int status;
#endif
    int waited, timed_out;
    int code, sig;
} SysProc;

static SysProc* check_proc(lua_State* L) {
    return (SysProc*)luaL_checkudata(L, 1, PROC_META);
}

static int sys_sleep_ms(lua_State* L) {
    lua_Integer ms = luaL_checkinteger(L, 1);
    if (ms < 0) ms = 0;
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    {
        struct timespec ts;
        ts.tv_sec = (time_t)(ms / 1000);
        ts.tv_nsec = (long)((ms % 1000) * 1000000);
        while (nanosleep(&ts, &ts) != 0 && errno == EINTR) { }
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_cpu_count(lua_State* L) {
#if defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    lua_pushinteger(L, (lua_Integer)si.dwNumberOfProcessors);
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    lua_pushinteger(L, (lua_Integer)(n > 0 ? n : 1));
#endif
    return 1;
}

static int sys_getpid(lua_State* L) {
#if defined(_WIN32)
    lua_pushinteger(L, (lua_Integer)GetCurrentProcessId());
#else
    lua_pushinteger(L, (lua_Integer)getpid());
#endif
    return 1;
}

static int sys_copy_file(lua_State* L) {
    const char* src = luaL_checkstring(L, 1);
    const char* dst = luaL_checkstring(L, 2);
#if defined(_WIN32)
    wchar_t* wsrc = wide_from_utf8(src);
    wchar_t* wdst = wide_from_utf8(dst);
    DWORD e = 0;
    if (!wsrc || !wdst) {
        free(wsrc); free(wdst);
        return push_error(L, ENOMEM);
    }
    if (!CopyFileW(wsrc, wdst, FALSE)) e = GetLastError();
    free(wsrc); free(wdst);
    if (e) return push_winerror(L, e);
#else
    int in = open(src, O_RDONLY);
    int out;
    char buf[65536];
    ssize_t n;
    if (in < 0) return push_error(L, errno);
    out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (out < 0) { int e = errno; close(in); return push_error(L, e); }
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0) {
                int e = errno;
                close(in); close(out);
                return push_error(L, e);
            }
            off += w;
        }
    }
    if (n < 0) { int e = errno; close(in); close(out); return push_error(L, e); }
    close(in);
    if (close(out) != 0) return push_error(L, errno);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_set_times(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    int has_a = !lua_isnoneornil(L, 2);
    int has_m = !lua_isnoneornil(L, 3);
    int has_c = !lua_isnoneornil(L, 4);
    lua_Integer a = has_a ? luaL_checkinteger(L, 2) : 0;
    lua_Integer m = has_m ? luaL_checkinteger(L, 3) : 0;
    lua_Integer c = has_c ? luaL_checkinteger(L, 4) : 0;
#if defined(_WIN32)
    {
        wchar_t* wpath = wide_from_utf8(path);
        HANDLE h;
        FILETIME ft[3];
        FILETIME *pa = NULL, *pm = NULL, *pc = NULL;
        DWORD e = 0;
        if (!wpath) return push_error(L, ENOMEM);
        if (has_a) { unsigned long long t = (unsigned long long)(a + 11644473600LL) * 10000000ULL;
            ft[0].dwLowDateTime = (DWORD)t; ft[0].dwHighDateTime = (DWORD)(t >> 32); pa = &ft[0]; }
        if (has_m) { unsigned long long t = (unsigned long long)(m + 11644473600LL) * 10000000ULL;
            ft[1].dwLowDateTime = (DWORD)t; ft[1].dwHighDateTime = (DWORD)(t >> 32); pm = &ft[1]; }
        if (has_c) { unsigned long long t = (unsigned long long)(c + 11644473600LL) * 10000000ULL;
            ft[2].dwLowDateTime = (DWORD)t; ft[2].dwHighDateTime = (DWORD)(t >> 32); pc = &ft[2]; }
        h = CreateFileW(wpath, FILE_WRITE_ATTRIBUTES,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
        if (h == INVALID_HANDLE_VALUE) e = GetLastError();
        free(wpath);
        if (e) return push_winerror(L, e);
        if (!SetFileTime(h, pc, pa, pm)) e = GetLastError();
        CloseHandle(h);
        if (e) return push_winerror(L, e);
    }
#else
    {
        struct timespec ts[2];
        ts[0].tv_sec = has_a ? (time_t)a : 0;
        ts[0].tv_nsec = has_a ? 0 : UTIME_OMIT;
        ts[1].tv_sec = has_m ? (time_t)m : 0;
        ts[1].tv_nsec = has_m ? 0 : UTIME_OMIT;
        if (utimensat(AT_FDCWD, path, ts, 0) != 0) return push_error(L, errno);
#  if defined(__APPLE__)
        /* (the change time is not settable this way: setattrlist accepts
         *  ATTR_CMN_CHGTIME, but APFS stamps the change time again as the
         *  call itself changes attributes -- the harness pins it with an
         *  interposer instead, as on Linux) */
        if (has_c) {
            struct attrlist al;
            struct timespec ct;
            memset(&al, 0, sizeof(al));
            al.bitmapcount = ATTR_BIT_MAP_COUNT;
            al.commonattr = ATTR_CMN_CRTIME;
            ct.tv_sec = (time_t)c;
            ct.tv_nsec = 0;
            if (setattrlist(path, &al, &ct, sizeof(ct), 0) != 0)
                return push_error(L, errno);
        }
#  else
        (void)has_c;
        (void)c;
#  endif
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

#if defined(_WIN32)
/* UTF-8 -> UTF-16; invalid UTF-8 falls back to the ANSI code page, which is
 * what an untagged Perl string means to Win32API::File as well. */
static wchar_t* wide_from_utf8(const char* s) {
    UINT cp = CP_UTF8;
    int n = MultiByteToWideChar(cp, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    wchar_t* w;
    if (n <= 0) { cp = CP_ACP; n = MultiByteToWideChar(cp, 0, s, -1, NULL, 0); }
    if (n <= 0) return NULL;
    w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(cp, 0, s, -1, w, n);
    return w;
}

/* UTF-16 -> UTF-8 (malloc'd, NULL on failure) */
static char* utf8_from_wide(const wchar_t* w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char* s;
    if (n <= 0) return NULL;
    s = (char*)malloc((size_t)n);
    if (!s) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

/* GetFullPathNameW: normalize a path to its absolute long form. Perl reaches
 * the same API through Win32::API, Win32API::File the file attributes. */
static int sys_get_full_path_name(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    wchar_t* wpath = wide_from_utf8(path);
    wchar_t* buf;
    DWORD len, got;
    char* utf8;
    if (!wpath) return push_error(L, EINVAL);
    len = GetFullPathNameW(wpath, 0, NULL, NULL);
    if (len == 0) { DWORD e = GetLastError(); free(wpath); return push_winerror(L, e); }
    buf = (wchar_t*)malloc((size_t)(len + 1) * sizeof(wchar_t));
    if (!buf) { free(wpath); return push_error(L, ENOMEM); }
    got = GetFullPathNameW(wpath, len + 1, buf, NULL);
    free(wpath);
    if (got == 0 || got > len) {
        DWORD e = GetLastError();
        free(buf);
        return push_winerror(L, e);
    }
    utf8 = utf8_from_wide(buf);
    free(buf);
    if (!utf8) return push_error(L, ENOMEM);
    lua_pushstring(L, utf8);
    free(utf8);
    return 1;
}

/* GetFileAttributesW (Win32API::File::GetFileAttributes): attribute bits, or
 * nil plus the error, like Perl's failed call. */
static int sys_get_file_attributes(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    wchar_t* wpath = wide_from_utf8(path);
    DWORD attr;
    if (!wpath) return push_error(L, EINVAL);
    attr = GetFileAttributesW(wpath);
    free(wpath);
    if (attr == INVALID_FILE_ATTRIBUTES) return push_winerror(L, GetLastError());
    lua_pushinteger(L, (lua_Integer)attr);
    return 1;
}

/* FILETIME (100 ns since 1601) -> Unix seconds, the arithmetic of
 * ExifTool::GetFileTime (89 leap years between 1601 and 1970). */
static double filetime_to_unix(const FILETIME* ft) {
    double t = ((double)ft->dwHighDateTime * 4294967296.0 +
                (double)ft->dwLowDateTime) * 1e-7;
    return t - (((1970.0 - 1601.0) * 365.0 + 89.0) * 24.0 * 3600.0);
}

/* Win32API::File::GetOsFHandle: the Win32 handle behind a Lua file (after
 * flushing its stdio buffer, so pending writes do not land after a time set
 * through the handle). INVALID_HANDLE_VALUE for a closed file. */
static HANDLE os_fhandle(lua_State* L, int idx) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, idx, LUA_FILEHANDLE);
    if (p->closef == NULL || p->f == NULL) return INVALID_HANDLE_VALUE;
    fflush(p->f);
    return (HANDLE)_get_osfhandle(_fileno(p->f));
}

/* The MSWin32 branch of ExifTool::GetFileTime (the daylight savings time
 * workaround): GetFileTime on the handle of an open Lua file, returned as
 * access, modification and creation time in Unix seconds (fractional, as
 * upstream's arithmetic). nil plus the error otherwise; the third value is
 * the Win32 error code (Win32::GetLastError()), 0 for an invalid handle. */
static int sys_get_file_time(lua_State* L) {
    HANDLE h = os_fhandle(L, 1);
    FILETIME c, a, m;
    if (h == INVALID_HANDLE_VALUE) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid handle");
        lua_pushinteger(L, 0);
        return 3;
    }
    if (!GetFileTime(h, &c, &a, &m)) return push_winerror(L, GetLastError());
    lua_pushnumber(L, filetime_to_unix(&a));
    lua_pushnumber(L, filetime_to_unix(&m));
    lua_pushnumber(L, filetime_to_unix(&c));
    return 3;
}

/* Unix seconds -> FILETIME, the arithmetic of Writer.pl's SetFileTime */
static void unix_to_filetime(double t, FILETIME* ft) {
    double wt = (t + ((1970.0 - 1601.0) * 365.0 + 89.0) * 24.0 * 3600.0) * 1e7;
    double hi = (double)(unsigned long long)(wt / 4294967296.0);
    ft->dwHighDateTime = (DWORD)hi;
    ft->dwLowDateTime = (DWORD)(unsigned long long)(wt - hi * 4294967296.0);
}

/* The MSWin32 branch of ExifTool::SetFileTime: SetFileTime on the handle of
 * an open Lua file; a nil time is left unchanged (upstream's NULL FILETIME).
 * Returns true, or nil plus the error and the Win32 error code. */
static int sys_set_file_time(lua_State* L) {
    HANDLE h = os_fhandle(L, 1);
    FILETIME ft[3];
    FILETIME* pt[3] = { NULL, NULL, NULL };
    int i;
    for (i = 0; i < 3; ++i) {
        if (lua_isnoneornil(L, i + 2)) continue;
        unix_to_filetime((double)luaL_checknumber(L, i + 2), &ft[i]);
        pt[i] = &ft[i];
    }
    if (h == INVALID_HANDLE_VALUE) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid handle");
        lua_pushinteger(L, 0);
        return 3;
    }
    /* (argument order of the API: creation, access, modification) */
    if (!SetFileTime(h, pt[2], pt[0], pt[1])) return push_winerror(L, GetLastError());
    lua_pushboolean(L, 1);
    return 1;
}

/* The first unpaired UTF-16 surrogate in a name, or 0 */
static unsigned unpaired_surrogate(const wchar_t* w) {
    for (; *w; ++w) {
        if (*w >= 0xD800 && *w <= 0xDBFF) {
            if (w[1] >= 0xDC00 && w[1] <= 0xDFFF) { ++w; continue; }
            return (unsigned)*w;
        }
        if (*w >= 0xDC00 && *w <= 0xDFFF) return (unsigned)*w;
    }
    return 0;
}

/* FindFirstFileW/FindNextFileW on a directory, the names only (like Perl's
 * readdir and Win32::FindFile::ReadDir; the caller skips '.' and '..').
 * Names come back as UTF-8, which is what Win32::FindFile::ReadDir returns
 * and why ScanDir can then set CharsetFileName to UTF8.  A directory with no
 * entries gives an empty table; a real error gives nil plus its text. */
static int sys_read_dir(lua_State* L) {
    const char* dir = luaL_checkstring(L, 1);
    wchar_t* wdir = wide_from_utf8(dir);
    wchar_t* pat;
    WIN32_FIND_DATAW fd;
    HANDLE h;
    size_t wlen;
    int idx = 0;
    if (!wdir) return push_error(L, EINVAL);
    wlen = wcslen(wdir);
    pat = (wchar_t*)malloc((wlen + 3) * sizeof(wchar_t));
    if (!pat) { free(wdir); return push_error(L, ENOMEM); }
    wcscpy(pat, wdir);
    /* append the stem "*" (with a separator unless the path already has one) */
    if (wlen > 0 && (wdir[wlen - 1] == L'/' || wdir[wlen - 1] == L'\\')) wcscat(pat, L"*");
    else wcscat(pat, L"/*");
    free(wdir);
    h = FindFirstFileW(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        if (e == ERROR_FILE_NOT_FOUND) { lua_newtable(L); return 1; }
        return push_winerror(L, e);
    }
    lua_newtable(L);
    do {
        char* name;
        unsigned sur = unpaired_surrogate(fd.cFileName);
        if (sur) {
            /* no UTF-8 form: fail with the text Perl's warning gives, which
             * ScanDir tests for "surrogate" (its 8.3-name patch) */
            char hex[8];
            snprintf(hex, sizeof(hex), "%04X", sur);
            FindClose(h);
            lua_pushnil(L);
            lua_pushfstring(L, "Unicode surrogate U+%s is illegal in UTF-8", hex);
            lua_pushinteger(L, (lua_Integer)ERROR_NO_UNICODE_TRANSLATION);
            return 3;
        }
        name = utf8_from_wide(fd.cFileName);
        if (name) {
            lua_pushstring(L, name);
            lua_rawseti(L, -2, ++idx);
            free(name);
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return 1;
}

/* Append one argv element to a CreateProcessW command line, using the
 * CommandLineToArgvW quoting rules (backslashes only special before a quote,
 * doubled at the end of a quoted argument). `p` is advanced. */
static void append_quoted_w(wchar_t** p, const wchar_t* arg) {
    int quote = (*arg == L'\0' || wcspbrk(arg, L" \t") != NULL);
    wchar_t* out = *p;
    if (quote) *out++ = L'"';
    while (*arg) {
        size_t nbs = 0;
        while (*arg == L'\\') { ++nbs; ++arg; }
        if (*arg == L'\0') {
            while (nbs-- > 0) { *out++ = L'\\'; *out++ = L'\\'; }
            break;
        }
        if (*arg == L'"') {
            size_t i;
            for (i = 0; i < nbs * 2 + 1; ++i) *out++ = L'\\';
            *out++ = L'"';
            ++arg;
        } else {
            while (nbs-- > 0) *out++ = L'\\';
            *out++ = *arg++;
        }
    }
    if (quote) *out++ = L'"';
    *p = out;
}
#endif

static int sys_spawn(lua_State* L) {
    size_t nargs, i;
    const char* cwd = NULL;
    const char* out_path = NULL;
    const char* err_path = NULL;
    int stdin_pipe = 0;

    luaL_checktype(L, 1, LUA_TTABLE);
    if (!lua_isnoneornil(L, 2)) {
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_getfield(L, 2, "cwd");
        if (lua_isstring(L, -1)) cwd = lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "stdout");
        if (lua_isstring(L, -1)) out_path = lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "stderr");
        if (lua_isstring(L, -1)) err_path = lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "stdin");
        if (lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "pipe") == 0)
            stdin_pipe = 1;
        lua_pop(L, 1);
    }
    nargs = lua_rawlen(L, 1);
    if (nargs == 0) return luaL_error(L, "spawn: empty argv");
    /* check the types before anything is allocated (a Lua error later on
     * would leak it); strings only, so the pointers stay anchored in argv */
    for (i = 1; i <= nargs; ++i) {
        int t = lua_rawgeti(L, 1, (lua_Integer)i);
        lua_pop(L, 1);
        if (t != LUA_TSTRING) return luaL_error(L, "spawn: argv[%d] is not a string", (int)i);
    }

#if defined(_WIN32)
    {
        wchar_t** wargv = (wchar_t**)calloc(nargs + 1, sizeof(wchar_t*));
        wchar_t* cmdline = NULL;
        size_t cap = 1;
        wchar_t* q;
        wchar_t* wcwd = NULL;
        wchar_t* wout = NULL;
        wchar_t* werr = NULL;
        HANDLE nuls[2] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE };
        HANDLE rd = INVALID_HANDLE_VALUE, wr = INVALID_HANDLE_VALUE;
        HANDLE oh = INVALID_HANDLE_VALUE, eh = INVALID_HANDLE_VALUE;
        SECURITY_ATTRIBUTES sa;
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        SysProc* p;
        int ok;

        if (!wargv) return push_error(L, ENOMEM);
        for (i = 1; i <= nargs; ++i) {
            const char* a;
            lua_rawgeti(L, 1, (lua_Integer)i);
            a = lua_tostring(L, -1);
            wargv[i - 1] = wide_from_utf8(a);
            lua_pop(L, 1);
            if (!wargv[i - 1]) {
                for (i = 0; i < nargs; ++i) free(wargv[i]);
                free(wargv);
                return push_error(L, ENOMEM);
            }
            cap += 2 * wcslen(wargv[i - 1]) + 4;
        }
        cmdline = (wchar_t*)malloc(cap * sizeof(wchar_t));
        if (!cmdline) {
            for (i = 0; i < nargs; ++i) free(wargv[i]);
            free(wargv);
            return push_error(L, ENOMEM);
        }
        q = cmdline;
        for (i = 0; i < nargs; ++i) {
            if (i) *q++ = L' ';
            append_quoted_w(&q, wargv[i]);
        }
        *q = L'\0';
        for (i = 0; i < nargs; ++i) free(wargv[i]);
        free(wargv);

        if (cwd) wcwd = wide_from_utf8(cwd);
        if (out_path) wout = wide_from_utf8(out_path);
        if (err_path) werr = wide_from_utf8(err_path);

        memset(&sa, 0, sizeof(sa));
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;

        if (stdin_pipe) {
            if (!CreatePipe(&rd, &wr, &sa, 0)) {
                free(cmdline); free(wcwd); free(wout); free(werr);
                return push_winerror(L, GetLastError());
            }
            SetHandleInformation(wr, HANDLE_FLAG_INHERIT, 0);
        } else {
            nuls[0] = CreateFileW(L"NUL", GENERIC_READ,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
            rd = nuls[0];
        }
        if (wout) {
            oh = CreateFileW(wout, GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        } else {
            nuls[1] = CreateFileW(L"NUL", GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
            oh = nuls[1];
        }
        if (werr) {
            eh = CreateFileW(werr, GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        } else {
            eh = CreateFileW(L"NUL", GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        }
        if (rd == INVALID_HANDLE_VALUE || oh == INVALID_HANDLE_VALUE ||
            eh == INVALID_HANDLE_VALUE) {
            DWORD e = GetLastError();
            if (rd != INVALID_HANDLE_VALUE) CloseHandle(rd);
            if (stdin_pipe && wr != INVALID_HANDLE_VALUE) CloseHandle(wr);
            if (oh != INVALID_HANDLE_VALUE) CloseHandle(oh);
            if (eh != INVALID_HANDLE_VALUE) CloseHandle(eh);
            free(cmdline); free(wcwd); free(wout); free(werr);
            return push_winerror(L, e);
        }

        memset(&si, 0, sizeof(si));
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = rd;
        si.hStdOutput = oh;
        si.hStdError = eh;
        memset(&pi, 0, sizeof(pi));
        ok = CreateProcessW(NULL, cmdline, NULL, NULL, TRUE,
                            CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                            NULL, wcwd, &si, &pi);
        if (!ok) {
            DWORD e = GetLastError();
            if (rd != INVALID_HANDLE_VALUE) CloseHandle(rd);  /* pipe or NUL */
            if (wr != INVALID_HANDLE_VALUE) CloseHandle(wr);
            if (oh != INVALID_HANDLE_VALUE) CloseHandle(oh);
            if (eh != INVALID_HANDLE_VALUE) CloseHandle(eh);
            free(cmdline); free(wcwd); free(wout); free(werr);
            return push_winerror(L, e);
        }
        free(cmdline); free(wcwd); free(wout); free(werr);
        CloseHandle(rd);
        CloseHandle(oh);
        CloseHandle(eh);

        p = (SysProc*)lua_newuserdatauv(L, sizeof(*p), 0);
        memset(p, 0, sizeof(*p));
        p->in = stdin_pipe ? wr : INVALID_HANDLE_VALUE;
        p->process = pi.hProcess;
        p->thread = pi.hThread;
        p->job = CreateJobObjectW(NULL, NULL);
        if (p->job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
            memset(&li, 0, sizeof(li));
            li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(p->job, JobObjectExtendedLimitInformation,
                                    &li, sizeof(li));
            if (!AssignProcessToJobObject(p->job, p->process)) {
                CloseHandle(p->job);
                p->job = NULL;
            }
        }
        ResumeThread(p->thread);
        luaL_setmetatable(L, PROC_META);
        return 1;
    }
#else
    {
        char** argv = (char**)calloc(nargs + 1, sizeof(char*));
        int infds[2] = { -1, -1 };
        pid_t pid;
        SysProc* p;
        if (!argv) return push_error(L, ENOMEM);
        for (i = 1; i <= nargs; ++i) {
            lua_rawgeti(L, 1, (lua_Integer)i);
            argv[i - 1] = (char*)lua_tostring(L, -1);
            lua_pop(L, 1);
        }
        if (stdin_pipe && pipe(infds) != 0) {
            free(argv);
            return push_error(L, errno);
        }
        pid = fork();
        if (pid < 0) {
            int e = errno;
            if (stdin_pipe) { close(infds[0]); close(infds[1]); }
            free(argv);
            return push_error(L, e);
        }
        if (pid == 0) {
            int fd;
            setpgid(0, 0);
            if (cwd && chdir(cwd) != 0) _exit(127);
            if (stdin_pipe) {
                dup2(infds[0], 0);
                close(infds[0]);
                close(infds[1]);
            } else {
                fd = open("/dev/null", O_RDONLY);
                if (fd >= 0) { dup2(fd, 0); close(fd); }
            }
            if (out_path) {
                fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if (fd < 0) _exit(127);
                dup2(fd, 1);
                close(fd);
            }
            if (err_path) {
                fd = open(err_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if (fd < 0) _exit(127);
                dup2(fd, 2);
                close(fd);
            }
            execvp(argv[0], argv);
            _exit(127);
        }
        if (stdin_pipe) {
            close(infds[0]);
            fcntl(infds[1], F_SETFD, FD_CLOEXEC);
        } else {
            infds[1] = -1;
        }
        free(argv);
        p = (SysProc*)lua_newuserdatauv(L, sizeof(*p), 0);
        memset(p, 0, sizeof(*p));
        p->in = infds[1];
        p->pid = pid;
        luaL_setmetatable(L, PROC_META);
        return 1;
    }
#endif
}

static int sys_proc_write(lua_State* L) {
    SysProc* p = check_proc(L);
    size_t len;
    const char* s = luaL_checklstring(L, 2, &len);
#if defined(_WIN32)
    size_t off = 0;
    if (p->in == INVALID_HANDLE_VALUE) {
        lua_pushnil(L);
        lua_pushliteral(L, "stdin is closed");
        return 2;
    }
    while (off < len) {
        DWORD wrote = 0;
        if (!WriteFile(p->in, s + off, (DWORD)(len - off), &wrote, NULL)) {
            return push_winerror(L, GetLastError());
        }
        off += wrote;
    }
#else
    size_t off = 0;
    if (p->in < 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "stdin is closed");
        return 2;
    }
    while (off < len) {
        ssize_t w = write(p->in, s + off, len - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE) {
                lua_pushnil(L);
                lua_pushliteral(L, "broken pipe");
                return 2;
            }
            return push_error(L, errno);
        }
        off += (size_t)w;
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_proc_close_stdin(lua_State* L) {
    SysProc* p = check_proc(L);
#if defined(_WIN32)
    if (p->in != INVALID_HANDLE_VALUE) {
        CloseHandle(p->in);
        p->in = INVALID_HANDLE_VALUE;
    }
#else
    if (p->in >= 0) {
        close(p->in);
        p->in = -1;
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_proc_kill(lua_State* L) {
    SysProc* p = check_proc(L);
#if defined(_WIN32)
    if (p->job) TerminateJobObject(p->job, 1);
    else if (p->process) TerminateProcess(p->process, 1);
#else
    if (!p->waited) {
        kill(-p->pid, SIGKILL);
        kill(p->pid, SIGKILL);
    }
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int sys_proc_pid(lua_State* L) {
    SysProc* p = check_proc(L);
#if defined(_WIN32)
    lua_pushinteger(L, (lua_Integer)GetProcessId(p->process));
#else
    lua_pushinteger(L, (lua_Integer)p->pid);
#endif
    return 1;
}

static int sys_proc_wait(lua_State* L) {
    SysProc* p = check_proc(L);
    lua_Integer timeout = luaL_optinteger(L, 2, -1);

    if (p->waited) {
        lua_pushinteger(L, p->timed_out ? -1 : (lua_Integer)p->code);
        lua_pushinteger(L, (lua_Integer)p->sig);
        lua_pushboolean(L, p->timed_out);
        return 3;
    }
#if defined(_WIN32)
    {
        DWORD ms = timeout < 0 ? INFINITE : (DWORD)timeout;
        DWORD r = WaitForSingleObject(p->process, ms);
        if (r == WAIT_TIMEOUT) {
            if (p->job) TerminateJobObject(p->job, 1);
            else TerminateProcess(p->process, 1);
            WaitForSingleObject(p->process, INFINITE);
            p->timed_out = 1;
        }
        {
            DWORD wcode = 0;
            GetExitCodeProcess(p->process, &wcode);
            p->code = (int)wcode;
            p->sig = 0;
        }
        p->waited = 1;
        if (p->thread) { CloseHandle(p->thread); p->thread = NULL; }
        if (p->process) { CloseHandle(p->process); p->process = NULL; }
    }
#else
    {
        int status = 0;
        if (timeout < 0) {
            while (waitpid(p->pid, &status, 0) < 0 && errno == EINTR) { }
        } else {
            struct timespec start, now;
            clock_gettime(CLOCK_MONOTONIC, &start);
            for (;;) {
                pid_t r = waitpid(p->pid, &status, WNOHANG);
                long elapsed;
                if (r == p->pid) break;
                if (r < 0 && errno != EINTR) break;
                clock_gettime(CLOCK_MONOTONIC, &now);
                elapsed = (long)((now.tv_sec - start.tv_sec) * 1000 +
                                 (now.tv_nsec - start.tv_nsec) / 1000000);
                if (elapsed >= (long)timeout) {
                    kill(-p->pid, SIGKILL);
                    kill(p->pid, SIGKILL);
                    while (waitpid(p->pid, &status, 0) < 0 && errno == EINTR) { }
                    p->timed_out = 1;
                    break;
                }
                {
                    struct timespec ts;
                    ts.tv_sec = 0;
                    ts.tv_nsec = 10 * 1000 * 1000;
                    nanosleep(&ts, NULL);
                }
            }
        }
        p->status = status;
        p->waited = 1;
        if (WIFEXITED(status)) { p->code = WEXITSTATUS(status); p->sig = 0; }
        else if (WIFSIGNALED(status)) { p->sig = WTERMSIG(status); p->code = 128 + p->sig; }
        else { p->code = -1; p->sig = 0; }
    }
#endif
    lua_pushinteger(L, p->timed_out ? -1 : (lua_Integer)p->code);
    lua_pushinteger(L, (lua_Integer)p->sig);
    lua_pushboolean(L, p->timed_out);
    return 3;
}

/* Non-blocking "has it exited?" probe. Unlike wait(), this never kills on a
 * timeout and never blocks: the runner polls its workers with it. A process
 * observed to have exited here is reaped/closed, so a later wait() just
 * returns the recorded code. */
static int sys_proc_alive(lua_State* L) {
    SysProc* p = check_proc(L);
    if (p->waited) { lua_pushboolean(L, 0); return 1; }
#if defined(_WIN32)
    {
        DWORD r = WaitForSingleObject(p->process, 0);
        if (r == WAIT_TIMEOUT) { lua_pushboolean(L, 1); return 1; }
        if (r == WAIT_OBJECT_0) {
            DWORD wcode = 0;
            GetExitCodeProcess(p->process, &wcode);
            p->code = (int)wcode;
            p->sig = 0;
        } else {
            p->code = -1;
            p->sig = 0;
        }
        p->waited = 1;
        if (p->thread) { CloseHandle(p->thread); p->thread = NULL; }
        if (p->process) { CloseHandle(p->process); p->process = NULL; }
        lua_pushboolean(L, 0);
        return 1;
    }
#else
    {
        int status = 0;
        pid_t r = waitpid(p->pid, &status, WNOHANG);
        if (r == 0) { lua_pushboolean(L, 1); return 1; }
        if (r == p->pid) {
            p->status = status;
            p->waited = 1;
            if (WIFEXITED(status)) { p->code = WEXITSTATUS(status); p->sig = 0; }
            else if (WIFSIGNALED(status)) { p->sig = WTERMSIG(status); p->code = 128 + p->sig; }
            else { p->code = -1; p->sig = 0; }
        } else if (errno == EINTR) {
            lua_pushboolean(L, 1);
            return 1;
        } else {
            p->waited = 1;
            p->code = -1;
            p->sig = 0;
        }
        lua_pushboolean(L, 0);
        return 1;
    }
#endif
}

static int sys_proc_gc(lua_State* L) {
    SysProc* p = check_proc(L);
#if defined(_WIN32)
    if (p->in != INVALID_HANDLE_VALUE) CloseHandle(p->in);
    if (p->thread) CloseHandle(p->thread);
    if (p->process) CloseHandle(p->process);
    if (p->job) CloseHandle(p->job);
    p->in = INVALID_HANDLE_VALUE;
    p->thread = p->process = p->job = NULL;
#else
    if (p->in >= 0) close(p->in);
    if (!p->waited) waitpid(p->pid, &p->status, WNOHANG);
    p->in = -1;
#endif
    return 0;
}

static const luaL_Reg proc_funcs[] = {
    { "write",       sys_proc_write },
    { "close_stdin", sys_proc_close_stdin },
    { "kill",        sys_proc_kill },
    { "pid",         sys_proc_pid },
    { "wait",        sys_proc_wait },
    { "alive",       sys_proc_alive },
    { NULL, NULL }
};

static const luaL_Reg sys_funcs[] = {
    { "platform",       sys_platform },
    { "setenv",         sys_setenv },
    { "tzset",          sys_tzset },
    /* strftime: a closure over its locale object, see luaopen below */
    { "decimal_point",  sys_decimal_point },
    { "strless",        sys_strless },
    { "strcmp",         sys_strcmp },
    { "chmod",          sys_chmod },
    { "chown",          sys_chown },
    { "mkdir",          sys_mkdir },
    { "rename",         sys_rename },
    { "unlink",         sys_unlink },
#if defined(_WIN32)
    { "open",           sys_open },
    { "create_file_read", sys_create_file_read },
#endif
    { "ftruncate",      sys_ftruncate },
    { "isreg",          sys_isreg },
    { "setmode",        sys_setmode },
    { "signal",         sys_signal },
    { "nosignals",      sys_nosignals },
#if defined(_WIN32)
    { "readmode",       sys_readmode },
    { "peekchar",       sys_peekchar },
#else
    { "readkey_noecho", sys_readkey_noecho },
#endif
    { "errno",          sys_errno },
    { "gettimeofday",   sys_gettimeofday },
    { "spawn",          sys_spawn },
    { "sleep_ms",       sys_sleep_ms },
    { "cpu_count",      sys_cpu_count },
    { "getpid",         sys_getpid },
    { "copy_file",      sys_copy_file },
    { "set_times",      sys_set_times },
#if defined(_WIN32)
    { "get_full_path_name",   sys_get_full_path_name },
    { "get_file_attributes",  sys_get_file_attributes },
    { "get_file_time",        sys_get_file_time },
    { "set_file_time",        sys_set_file_time },
    { "read_dir",             sys_read_dir },
#else
    { "getpwuid",       sys_getpwuid },
    { "getpwnam",       sys_getpwnam },
    { "getgrgid",       sys_getgrgid },
    { "getgrnam",       sys_getgrnam },
    { "realpath",       sys_realpath },
#if defined(__linux__) && defined(STATX_BTIME)
    { "get_btime",      sys_get_btime },
#endif
#endif
    { NULL, NULL }
};

#if defined(_WIN32)
__declspec(dllexport)
#endif
int luaopen_lexiftool_sys(lua_State* L) {
    luaL_newmetatable(L, PROC_META);
    lua_newtable(L);
    luaL_setfuncs(L, proc_funcs, 0);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, sys_proc_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    if (lua_getfield(L, LUA_REGISTRYINDEX, HANDLERS_KEY) != LUA_TTABLE) {
        lua_newtable(L);
        lua_setfield(L, LUA_REGISTRYINDEX, HANDLERS_KEY);
    }
    lua_pop(L, 1);
    luaL_newlib(L, sys_funcs);
    /* strftime with the locale object of this module instance as its
     * upvalue (loaded at the first call, freed with the function) */
    {
        SysLocale* sl = (SysLocale*)lua_newuserdatauv(L, sizeof(SysLocale), 0);
        memset(sl, 0, sizeof(*sl));
        if (luaL_newmetatable(L, LOCALE_META)) {
            lua_pushcfunction(L, sys_locale_gc);
            lua_setfield(L, -2, "__gc");
        }
        lua_setmetatable(L, -2);
        lua_pushcclosure(L, sys_strftime, 1);
        lua_setfield(L, -2, "strftime");
    }
    /* the interpreter's full release ("Lua 5.5.0"; Lua code sees only
     * _VERSION, "Lua 5.5"), for the port line of -ver -v */
    lua_pushliteral(L, LUA_RELEASE);
    lua_setfield(L, -2, "lua_release");
    return 1;
}
