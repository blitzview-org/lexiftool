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
 *                 tz_new(value[, flavor]), tz_localtime(zone, t)
 *                                     $ENV{TZ} = VALUE + tzset, localtime
 *                                     (port: a time zone of the ExifTool
 *                                     object that sets the TimeZone option,
 *                                     read as the platform's C library
 *                                     reads TZ; neither the environment nor
 *                                     the process's zone is touched)
 *                 strftime(fmt, sec, min, hour, mday, mon, year[, zone])
 *                                     POSIX::strftime (libc strftime_l in
 *                                     the LC_TIME locale of the
 *                                     environment, a locale object of its
 *                                     own; the process locale is never
 *                                     switched; mktime and %Z in the zone)
 *                 decimal_point()     the radix character of the current
 *                                     locale (nl_langinfo(RADIXCHAR);
 *                                     Windows: localeconv) (port:
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
 *                 futimes(fh, atime, mtime)
 *                                     utime ATIME, MTIME, FILEHANDLE
 *                                     (futimens; SetFileTime on Windows)
 *                 setmode(fh, crlf)   binmode FILEHANDLE[, ':crlf']
 *                 isreg(fh)           -f FILEHANDLE
 *                 fstat(fh)           stat FILEHANDLE
 *                 stat(path)          stat PATH (thread-safe, unlike
 *                                     lfs.attributes' permissions)
 *                 signal(name, func)  $SIG{NAME} = HANDLER
 *                 nosignals([on])     (port: no process-wide signal
 *                                     handlers in this Lua state -- the
 *                                     default for every Lua state this
 *                                     module is loaded into, library use
 *                                     and embedding hosts included; only
 *                                     the command-line launchers turn it
 *                                     off before loading lexiftool.main,
 *                                     so a CLI process keeps installing
 *                                     real handlers as upstream does)
 *                 errno()             errno (for the exit status of an
 *                                     uncaught die)
 *                 fpe_test()          (port: tests and clears the
 *                                     floating-point flags "division by
 *                                     zero" and "invalid"; Perl's `/` dies
 *                                     where C's gives Inf, see perl.pcall)
 *                 fpe_raise(div, inv) (port: sets those flags again)
 *                 gettimeofday()      Time::HiRes::gettimeofday (list
 *                                     context: seconds, microseconds)
 *                 sleep_ms(ms)        select(undef,undef,undef,SECONDS)
 *                 fdopen(fd, mode)    open FH, "<&=FD" (and the other
 *                                     modes; an ordinary Lua file)
 *               POSIX only:
 *                 getpwuid/getpwnam/getgrgid/getgrnam  the builtins of the
 *                                     same names (scalar context)
 *                 realpath(path)      Cwd::abs_path
 *                 get_btime(path|fh)  File::StatX statx()/fstatx() STATX_BTIME
 *                                     (Linux, where the headers have it;
 *                                     the raw syscall below glibc 2.28)
 *                 readkey_noecho()    Term::ReadKey ReadMode('cbreak') +
 *                                     ReadKey(0) + ReadMode(0) (termios)
 *               Windows only (Win32::API / Win32API::File / Win32::FindFile
 *               upstream; names are UTF-8 and widened here):
 *                 create_file(path, access, share, _, create, flags, _)
 *                                     Win32API::File::CreateFileW (the
 *                                     handle as a light userdata)
 *                 os_fhandle_open_fd(wh, mode)   OsFHandleOpenFd
 *                 close_handle(wh)    CloseHandle
 *                 get_full_path_name(path)       GetFullPathNameW
 *                 get_file_attributes(path)      GetFileAttributesW
 *                 get_file_time(fh)   GetOsFHandle + GetFileTime (packed
 *                                     FILETIME structs, as upstream
 *                                     unpacks them)
 *                 set_file_time(fh, ctime, atime, mtime)
 *                                     GetOsFHandle + SetFileTime (packed
 *                                     FILETIME structs, 0 for NULL)
 *                 read_dir(dir)       Win32::FindFile::ReadDir
 *                                     (FindFirstFileW/FindNextFileW)
 *                 readmode(mode)      Term::ReadKey::ReadMode (console
 *                                     mode of STDIN)
 *                 peekchar()          Term::ReadKey::Win32PeekChar(STDIN, 0)
 *               Test-harness primitives (setenv, spawn, cpu_count, getpid,
 *               copy_file, set_times), see the section further down; the
 *               library does not call them.
 *               State: none of its own outside the Lua state that calls it
 *               (doc/conventions.md §12)
 *               -- zone and locale objects are userdata, Term::ReadKey's
 *               saved console mode and pending keys a registry userdata per
 *               Lua state, and no process-wide setting (environment,
 *               locale, TZ) is changed, so separate Lua states may run in
 *               parallel threads. The one exception is the signal handling
 *               (sigState, sigPending, sigAny, savedHook/Mask/Count): a C
 *               signal handler reaches a Lua state only through static
 *               storage, and dispositions are process-wide anyway. It is
 *               used only by a Lua state that has called
 *               nosignals(false), i.e. by the command-line launchers.
 *               Depends on the C runtime (and, on Windows, kernel32) only --
 *               no third-party library, so it builds wherever Lua does.
 *               (Brotli and zlib, which need libbrotlidec/enc and zlib,
 *               come from the separate rocks compress.brotli and
 *               compress.zlib.)
 *               Windows (MSVC or MinGW, _WIN32) uses the CRT spellings
 *               _putenv_s/_chmod/_chsize_s/_setmode/_open_osfhandle,
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
#include <limits.h>     /* ULONG_MAX (time zones) */
#include <fenv.h>       /* fetestexcept (Perl's "Illegal division by zero") */
#include <locale.h>     /* newlocale / _create_locale (strftime), localeconv (Windows) */
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
#  include <langinfo.h> /* nl_langinfo_l(CODESET) (strftime), nl_langinfo(RADIXCHAR) */
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

/* strerror(err), thread-safe: strerror_s on Windows, the GNU strerror_r
 * (which returns the text, maybe not in buf) where glibc gives it under
 * _GNU_SOURCE, else the POSIX (XSI) one (0 on success; on failure, the text
 * it may still have written, as macOS writes "Unknown error: N", else
 * glibc's/musl's wording of strerror for an unknown number) */
static void push_strerror(lua_State* L, int err) {
    char buf[256];
#if defined(_WIN32)
    if (strerror_s(buf, sizeof(buf), err) != 0) buf[0] = '\0';
    lua_pushstring(L, buf);
#elif defined(__GLIBC__) && defined(_GNU_SOURCE)
    lua_pushstring(L, strerror_r(err, buf, sizeof(buf)));
#else
    buf[0] = '\0';
    if (strerror_r(err, buf, sizeof(buf)) != 0 && buf[0] == '\0')
        snprintf(buf, sizeof(buf), "Unknown error %d", err);
    lua_pushstring(L, buf);
#endif
}

static int push_error(lua_State* L, int err) {
    lua_pushnil(L);
    push_strerror(L, err);
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
 * setenv(name, value) -- writes the process environment (for the CLI test
 * harness, which passes values on to its children; the library writes no
 * environment). On POSIX setenv() updates the one copy there is. On Windows
 * there are two: the C runtime's (read by getenv/os.getenv) and the Win32
 * block (passed to CreateProcess). Both are updated, so a child spawned
 * right after the write sees the value too.
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

/*------------------------------------------------------------------------------
 * Time zones of an ExifTool object (port: upstream's Options('TimeZone')
 * writes $ENV{TZ} and calls tzset, which changes the zone of the whole
 * process for good; here the zone belongs to the object that set it, and
 * neither the environment nor the C library's own zone state is touched).
 *
 *   tz_new(value[, flavor])  reads a TZ value the way the C library Perl
 *                            runs on reads $ENV{TZ} at tzset, into a zone
 *                            object (a userdata; it never fails, as tzset
 *                            never does)
 *   tz_localtime(zone, t)    localtime() in that zone: sec, min, hour,
 *                            mday, mon (0-based), year (-1900), wday, yday,
 *                            isdst, gmtoff (seconds east of UTC) and the
 *                            zone abbreviation (%Z); nil where the C
 *                            library's localtime fails
 *   strftime(..., zone)      (the optional 8th argument of strftime below)
 *                            normalizes the fields with mktime() in that
 *                            zone and formats %Z (and %z) from it
 *
 * The flavor is the C library whose reading is reproduced -- by default the
 * one of the platform (the other two are there for the tests):
 *   "gnu"     glibc (Linux and every other Unix): the value (without a
 *             leading ':'; empty: "Universal") names a TZif file under
 *             $TZDIR (default /usr/share/zoneinfo) or, absolute, anywhere;
 *             failing that it is a POSIX TZ string ("EST5EDT", "<+05>-5",
 *             "CET-1CEST,M3.5.0,M10.5.0/3", offsets with the POSIX sign:
 *             positive west of Greenwich). A file's footer rule covers the
 *             times after its last transition; a string with a DST name but
 *             no rule takes the transitions of the "posixrules" file,
 *             shifted to its offsets (and that file's footer afterwards), or
 *             the US rules M3.2.0,M11.1.0 without it. glibc's own readings
 *             are kept: a value it cannot parse is UTC with the name parsed
 *             so far ("+05:00": UTC with an empty name), rules apply from
 *             1970 on (an earlier year gets the 1970 dates), the year a
 *             rule is looked up for is the UTC year, and "posixrules" is
 *             shifted as by every tzset after a process's first one (the
 *             one state Perl's localtime and mktime ever see). mktime starts
 *             from the UTC offset of the zone's previous mktime, so a local
 *             time that exists twice follows that one; glibc keeps it per
 *             process, here per zone object.
 *   "tzcode"  macOS (Libc's localtime.c, tzcode 8.14): the file under
 *             /var/db/timezone/zoneinfo (TZDIR), else the POSIX string --
 *             where an empty name is allowed ("+05:00" is UTC-5) and the
 *             rules give transitions from 1970 on, 1200 of them -- else UTC;
 *             a DST name without a rule takes "posixrules" like glibc, or
 *             ",M4.1.0,M10.5.0" without it. mktime bisects the time_t range
 *             and fails for a local time that does not exist (a DST gap)
 *             and for years before 1900.
 *   "crt"     Windows (the C runtime's _tzset, which Time::Piece::_tzset
 *             runs): "tzn[+|-]hh[:mm[:ss]][dzn]" -- the first three
 *             characters are the standard name, the number after them the
 *             offset (west positive), and anything left over turns daylight
 *             saving time on, its name the next three characters, with the
 *             US rules (from 2007: second Sunday of March to first Sunday of
 *             November, before: first Sunday of April to last Sunday of
 *             October, 02:00) -- so an ID like "America/New_York" is "Ame"
 *             at UTC with US DST "ric", exactly what Perl gets on Windows.
 *             localtime fails before 1970 and after the year 3000, and so
 *             does mktime, which leaves tm_isdst -1 then -- the CRT's
 *             strftime takes that as DST: %Z the DST name (empty without
 *             one), %z the standard offset plus the DST bias.
 * Leap-second files ("right/...") are read as if they had no leap seconds.
 * The zone objects are independent of each other and of every Lua state
 * but their own; nothing here has static mutable state.
 */
#define ZONE_META "lexiftool.sys.zone"

/* struct tm carries tm_gmtoff/tm_zone, which strftime's %z/%Z read */
#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) \
    || defined(__OpenBSD__) || defined(__DragonFly__)
#  define SYS_TM_ZONE 1
#endif

enum { ZF_GNU = 1, ZF_TZCODE = 2, ZF_CRT = 3 };

/* a broken-down local time */
typedef struct {
    int sec, min, hour, mday, mon, year, wday, yday, isdst;
    int64_t gmtoff;             /* seconds east of UTC */
    const char* zone;           /* abbreviation (in the zone object) */
} ZTm;

/* floor division and modulo */
static int64_t z_fdiv(int64_t a, int64_t b) {
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
    return q;
}
static int64_t z_fmod(int64_t a, int64_t b) { return a - z_fdiv(a, b) * b; }

static int z_isleap(int64_t y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

/* days since 1970-01-01 of a civil date (proleptic Gregorian; month 1..12) */
static int64_t z_days_from_civil(int64_t y, int m, int d) {
    int64_t era, yoe, doy, doe;
    y -= (m <= 2);
    era = z_fdiv(y, 400);
    yoe = y - era * 400;
    doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/* the UTC broken-down time of t (fields as struct tm); 0 if the year does
 * not fit an int */
static int z_gmtime(int64_t t, ZTm* tm) {
    static const int cum[2][12] = {
        { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 },
        { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 },
    };
    int64_t days = z_fdiv(t, 86400), rem = z_fmod(t, 86400);
    int64_t z = days + 719468, era = z_fdiv(z, 146097);
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int d = (int)(doy - (153 * mp + 2) / 5 + 1);
    int m = (int)(mp < 10 ? mp + 3 : mp - 9);
    if (m <= 2) ++y;
    if (y - 1900 < INT32_MIN || y - 1900 > INT32_MAX) return 0;
    tm->year = (int)(y - 1900);
    tm->mon = m - 1;
    tm->mday = d;
    tm->hour = (int)(rem / 3600);
    tm->min = (int)(rem / 60 % 60);
    tm->sec = (int)(rem % 60);
    tm->wday = (int)z_fmod(days + 4, 7);
    tm->yday = cum[z_isleap(y)][m - 1] + d - 1;
    tm->isdst = 0;
    tm->gmtoff = 0;
    tm->zone = "";
    return 1;
}

/* ---- reading a whole (small) file ---- */
static unsigned char* z_read_file(const char* path, size_t maxlen, size_t* len) {
    FILE* f = fopen(path, "rb");
    unsigned char* buf;
    size_t n = 0;
    if (f == NULL) return NULL;
    buf = (unsigned char*)malloc(maxlen + 1);
    if (buf == NULL) { fclose(f); return NULL; }
    while (n < maxlen) {
        size_t r = fread(buf + n, 1, maxlen - n, f);
        if (r == 0) break;
        n += r;
    }
    if (ferror(f)) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *len = n;
    return buf;
}

#if !defined(_WIN32)
/* a regular file? (glibc and tzcode both refuse anything else) */
static int z_is_regular(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}
#else
static int z_is_regular(const char* path) {
    DWORD a = GetFileAttributesA(path);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
#endif

static int64_t z_be32(const unsigned char* p) {
    uint32_t v = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    return (int64_t)(int32_t)v;
}
static int64_t z_be64(const unsigned char* p) {
    uint64_t v = 0;
    int i;
    for (i = 0; i < 8; ++i) v = (v << 8) | p[i];
    return (int64_t)v;
}

/*==============================================================================
 * glibc (time/tzfile.c, time/tzset.c)
 */
#define GNU_NAME_MAX 256
#define GNU_MAX_FILE (4 << 20)

typedef struct {
    char name[GNU_NAME_MAX];
    int64_t offset;             /* seconds east of UTC */
    int type;                   /* 0: Jn (J0, zero-based), 1: Jn (J1), 2: M */
    unsigned short m, n, d;
    int64_t secs;               /* time of day of the change */
} GnuRule;

typedef struct { GnuRule r[2]; } GnuPosix;

typedef struct {
    int64_t offset;
    unsigned char isdst, idx, isstd, isut;
} GnuType;

typedef struct {
    int use_tzfile;
    /* the TZif data */
    size_t ntrans;
    int64_t* trans;
    unsigned char* tidx;
    size_t ntypes;
    GnuType* types;
    char* names;
    size_t nnames;
    int has_spec;               /* the footer, parsed */
    GnuPosix spec;
    int64_t rule_stdoff, rule_dstoff;
    /* the POSIX string (no file) */
    GnuPosix posix;
} GnuZone;

static void gnu_free(GnuZone* z) {
    free(z->trans); free(z->tidx); free(z->types); free(z->names);
    z->trans = NULL; z->tidx = NULL; z->types = NULL; z->names = NULL;
    z->ntrans = z->ntypes = z->nnames = 0;
}

static int z_isdigit(int c) { return c >= '0' && c <= '9'; }
static int z_isalpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static int z_isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

/* sscanf's %hu: white space, an optional sign, digits (strtoul, saturating,
 * then truncated to unsigned short); returns 1 and advances *sp, or 0 */
static int z_scan_hu(const char** sp, unsigned short* out) {
    const char* s = *sp;
    int neg = 0;
    unsigned long v = 0;
    int over = 0;
    while (z_isspace((unsigned char)*s)) ++s;
    if (*s == '+' || *s == '-') neg = (*s++ == '-');
    if (!z_isdigit((unsigned char)*s)) return 0;
    while (z_isdigit((unsigned char)*s)) {
        unsigned long d = (unsigned long)(*s - '0');
        if (v > (ULONG_MAX - d) / 10) over = 1;
        else v = v * 10 + d;
        ++s;
    }
    if (over) v = ULONG_MAX;
    if (neg) v = (unsigned long)(-(long long)v);
    *out = (unsigned short)v;
    *sp = s;
    return 1;
}

/* sscanf(s, "%hu%n:%hu%n:%hu%n", ...): returns the number of items, the
 * consumed length in *consumed (the last %n reached) */
static int z_scan_hms(const char* s, unsigned short* hh, unsigned short* mm,
                      unsigned short* ss, int* consumed) {
    const char* p = s;
    if (!z_scan_hu(&p, hh)) return 0;
    *consumed = (int)(p - s);
    if (*p != ':') return 1;
    ++p;
    if (!z_scan_hu(&p, mm)) return 1;
    *consumed = (int)(p - s);
    if (*p != ':') return 2;
    ++p;
    if (!z_scan_hu(&p, ss)) return 2;
    *consumed = (int)(p - s);
    return 3;
}

static int gnu_parse_tzname(const char** tzp, GnuRule* r) {
    const char* start = *tzp;
    const char* p = start;
    size_t len;
    while (z_isalpha((unsigned char)*p)) ++p;
    len = (size_t)(p - start);
    if (len < 3) {
        p = *tzp;
        if (*p++ != '<') return 0;
        start = p;
        while (z_isalpha((unsigned char)*p) || z_isdigit((unsigned char)*p) || *p == '+' || *p == '-')
            ++p;
        len = (size_t)(p - start);
        if (*p++ != '>' || len < 3) return 0;
    }
    if (len >= GNU_NAME_MAX) len = GNU_NAME_MAX - 1;
    memcpy(r->name, start, len);
    r->name[len] = '\0';
    *tzp = p;
    return 1;
}

static int gnu_parse_offset(const char** tzp, GnuPosix* P, int which) {
    const char* tz = *tzp;
    int64_t sign;
    unsigned short hh = 0, mm = 0, ss = 0;
    int consumed = 0;
    if (which == 0 && (*tz == '\0' || (*tz != '+' && *tz != '-' && !z_isdigit((unsigned char)*tz))))
        return 0;
    if (*tz == '+' || *tz == '-') sign = (*tz++ == '-') ? 1 : -1;
    else sign = -1;
    *tzp = tz;
    if (z_scan_hms(tz, &hh, &mm, &ss, &consumed) > 0) {
        P->r[which].offset = sign * ((ss < 59 ? ss : 59) + (mm < 59 ? mm : 59) * 60
                                     + (int64_t)(hh < 24 ? hh : 24) * 3600);
    } else if (which == 0) {
        P->r[0].offset = 0;
        return 0;
    } else {
        P->r[1].offset = P->r[0].offset + 3600;
    }
    *tzp = tz + consumed;
    return 1;
}

static int gnu_parse_rule(const char** tzp, GnuRule* r, int which) {
    const char* tz = *tzp;
    tz += (*tz == ',');
    if (*tz == 'J' || z_isdigit((unsigned char)*tz)) {
        unsigned long d = 0;
        const char* s;
        r->type = (*tz == 'J') ? 1 : 0;
        if (r->type == 1 && !z_isdigit((unsigned char)*++tz)) return 0;
        s = tz;
        while (z_isdigit((unsigned char)*tz)) {
            if (d < 100000) d = d * 10 + (unsigned long)(*tz - '0');
            ++tz;
        }
        if (tz == s || d > 365) return 0;
        if (r->type == 1 && d == 0) return 0;
        r->d = (unsigned short)d;
    } else if (*tz == 'M') {
        const char* p = tz + 1;
        int items = 0;
        r->type = 2;
        if (z_scan_hu(&p, &r->m)) {
            ++items;
            if (*p == '.') {
                ++p;
                if (z_scan_hu(&p, &r->n)) {
                    ++items;
                    if (*p == '.') {
                        ++p;
                        if (z_scan_hu(&p, &r->d)) ++items;
                    }
                }
            }
        }
        if (items != 3 || r->m < 1 || r->m > 12 || r->n < 1 || r->n > 5 || r->d > 6) return 0;
        tz = p;
    } else if (*tz == '\0') {
        /* the US rules, "M3.2.0,M11.1.0" */
        r->type = 2;
        if (which == 0) { r->m = 3; r->n = 2; r->d = 0; }
        else            { r->m = 11; r->n = 1; r->d = 0; }
    } else {
        return 0;
    }
    if (*tz != '\0' && *tz != '/' && *tz != ',') {
        return 0;
    } else if (*tz == '/') {
        int negative, consumed = 0;
        unsigned short hh = 2, mm = 0, ss = 0;
        ++tz;
        if (*tz == '\0') return 0;
        negative = (*tz == '-');
        tz += negative;
        z_scan_hms(tz, &hh, &mm, &ss, &consumed);
        tz += consumed;
        r->secs = (negative ? -1 : 1) * ((int64_t)hh * 3600 + mm * 60 + ss);
    } else {
        r->secs = 2 * 3600;
    }
    *tzp = tz;
    return 1;
}

static int gnu_read_file(const char* file, GnuZone* z);

/* __tzfile_default: the transitions of "posixrules" for the given names
 * and offsets; 1 if the zone now uses them.
 * A transition in wall-clock time after a DST period is moved by the
 * user's DST offset minus glibc's rule_dstoff, a static that
 * __tzfile_read leaves alone (it sets it only for a file without
 * transitions) and that __tzfile_default itself sets to the user's DST
 * offset at its end. So the very first tzset of a process moves these
 * transitions by the whole DST offset (rule_dstoff still 0: EST5EDT
 * without its own file ends DST four hours early), every later one by
 * nothing. Perl is always in the later state: Options' POSIX::tzset is
 * followed by the tzset that Perl's localtime runs before localtime_r
 * (LOCALTIME_R_NEEDS_TZSET) and the one inside glibc's mktime, so
 * rule_dstoff equals the user's DST offset here (the TZ value is the same
 * at each re-read). */
static int gnu_tzfile_default(GnuZone* z, const GnuPosix* P) {
    GnuZone t;
    size_t i, stdlen, dstlen;
    int isdst = 0;
    memset(&t, 0, sizeof(t));
    if (!gnu_read_file("posixrules", &t)) return 0;
    if (t.ntypes < 2) { gnu_free(&t); return 0; }
    for (i = 0; i < t.ntrans; ++i) {
        const GnuType* tt = &t.types[t.tidx[i]];
        t.tidx[i] = tt->isdst;
        if (tt->isut)
            ;
        else if (isdst && !tt->isstd)
            ;   /* (+= dstoff - rule_dstoff: nothing, see above) */
        else
            t.trans[i] += P->r[0].offset - t.rule_stdoff;
        isdst = tt->isdst;
    }
    stdlen = strlen(P->r[0].name) + 1;
    dstlen = strlen(P->r[1].name) + 1;
    free(t.names);
    t.names = (char*)malloc(stdlen + dstlen);
    if (t.names == NULL) { gnu_free(&t); return 0; }
    memcpy(t.names, P->r[0].name, stdlen);
    memcpy(t.names + stdlen, P->r[1].name, dstlen);
    t.nnames = stdlen + dstlen;
    t.ntypes = 2;
    t.types[0].idx = 0;
    t.types[0].offset = P->r[0].offset;
    t.types[0].isdst = 0;
    t.types[1].idx = (unsigned char)(stdlen < 256 ? stdlen : 255);
    t.types[1].offset = P->r[1].offset;
    t.types[1].isdst = 1;
    t.rule_stdoff = P->r[0].offset;
    t.rule_dstoff = P->r[1].offset;
    gnu_free(z);
    *z = t;
    z->use_tzfile = 1;
    return 1;
}

/* __tzset_parse_tz; returns 1 when the "posixrules" file took over (only
 * where withDefault is set: not for a file's footer) */
static int gnu_parse_posix(const char* tz, GnuPosix* P, GnuZone* withDefault) {
    memset(P, 0, sizeof(*P));
    if (gnu_parse_tzname(&tz, &P->r[0]) && gnu_parse_offset(&tz, P, 0)) {
        if (*tz != '\0') {
            if (gnu_parse_tzname(&tz, &P->r[1])) {
                gnu_parse_offset(&tz, P, 1);
                if (*tz == '\0' || (tz[0] == ',' && tz[1] == '\0')) {
                    if (withDefault && gnu_tzfile_default(withDefault, P)) return 1;
                }
            }
            if (gnu_parse_rule(&tz, &P->r[0], 0))
                gnu_parse_rule(&tz, &P->r[1], 1);
        } else {
            memcpy(P->r[1].name, P->r[0].name, sizeof(P->r[0].name));
            P->r[1].offset = P->r[0].offset;
        }
    }
    return 0;
}

/* __tzfile_read: a TZif file (relative names under $TZDIR) */
static int gnu_read_file(const char* file, GnuZone* z) {
    char* path = NULL;
    unsigned char* buf;
    size_t len, pos, i;
    int64_t isut, isstd, leaps, timecnt, typecnt, charcnt;
    int width = 4;
    memset(z, 0, sizeof(*z));
    if (*file == '\0') file = "Universal";
    if (*file != '/') {
        const char* tzdir = getenv("TZDIR");
        if (tzdir == NULL || *tzdir == '\0') tzdir = "/usr/share/zoneinfo";
        path = (char*)malloc(strlen(tzdir) + strlen(file) + 2);
        if (path == NULL) return 0;
        sprintf(path, "%s/%s", tzdir, file);
        file = path;
    }
    if (!z_is_regular(file)) { free(path); return 0; }
    buf = z_read_file(file, GNU_MAX_FILE, &len);
    free(path);
    if (buf == NULL) return 0;
    pos = 0;
    for (;;) {
        size_t need;
        if (len - pos < 44 || memcmp(buf + pos, "TZif", 4) != 0) goto lose;
        isut = z_be32(buf + pos + 20);
        isstd = z_be32(buf + pos + 24);
        leaps = z_be32(buf + pos + 28);
        timecnt = z_be32(buf + pos + 32);
        typecnt = z_be32(buf + pos + 36);
        charcnt = z_be32(buf + pos + 40);
        if (isut < 0 || isstd < 0 || leaps < 0 || timecnt < 0 || typecnt < 0 || charcnt < 0)
            goto lose;
        if (typecnt > 256 || timecnt > (1 << 20) || charcnt > (1 << 16) || leaps > (1 << 16)
            || isut > typecnt || isstd > typecnt)
            goto lose;
        need = (size_t)(timecnt * width + timecnt + typecnt * 6 + charcnt
                        + leaps * (width + 4) + isstd + isut);
        if (width == 4 && buf[pos + 4] != '\0') {
            /* version 2 and later: the 64-bit data follows the 32-bit one */
            if (len - pos - 44 < need) goto lose;
            pos += 44 + need;
            width = 8;
            continue;
        }
        pos += 44;
        if (len - pos < need) goto lose;
        break;
    }
    z->ntrans = (size_t)timecnt;
    z->ntypes = (size_t)typecnt;
    z->nnames = (size_t)charcnt;
    z->trans = (int64_t*)malloc((z->ntrans ? z->ntrans : 1) * sizeof(int64_t));
    z->tidx = (unsigned char*)malloc(z->ntrans ? z->ntrans : 1);
    z->types = (GnuType*)calloc(z->ntypes ? z->ntypes : 1, sizeof(GnuType));
    z->names = (char*)malloc(z->nnames + 1);
    if (!z->trans || !z->tidx || !z->types || !z->names) goto lose;
    for (i = 0; i < z->ntrans; ++i, pos += (size_t)width)
        z->trans[i] = width == 8 ? z_be64(buf + pos) : z_be32(buf + pos);
    for (i = 0; i < z->ntrans; ++i) {
        z->tidx[i] = buf[pos++];
        if (z->tidx[i] >= z->ntypes) goto lose;
    }
    for (i = 0; i < z->ntypes; ++i) {
        z->types[i].offset = z_be32(buf + pos);
        z->types[i].isdst = buf[pos + 4];
        z->types[i].idx = buf[pos + 5];
        if (z->types[i].isdst > 1 || z->types[i].idx > z->nnames) goto lose;
        pos += 6;
    }
    memcpy(z->names, buf + pos, z->nnames);
    z->names[z->nnames] = '\0';
    pos += z->nnames;
    pos += (size_t)(leaps * (width + 4));
    for (i = 0; i < (size_t)isstd; ++i) z->types[i].isstd = buf[pos++] != 0;
    for (i = 0; i < (size_t)isut; ++i) z->types[i].isut = buf[pos++] != 0;
    if (z->ntypes == 0) goto lose;
    /* the POSIX TZ-style footer (64-bit data only) */
    if (width == 8 && len - pos >= 2 && buf[pos] == '\n') {
        size_t speclen = len - pos - 2;
        char* spec = (char*)malloc(speclen + 1);
        if (spec) {
            memcpy(spec, buf + pos + 1, speclen);
            spec[speclen] = '\0';
            if (*spec != '\0') {
                z->has_spec = 1;
                gnu_parse_posix(spec, &z->spec, NULL);
            }
            free(spec);
        }
    }
    /* the offset of the latest standard-time type (rule_stdoff); glibc
     * leaves rule_dstoff as it was (gnu_tzfile_default takes the value it
     * has there) */
    z->rule_stdoff = z->ntrans == 0 ? z->types[0].offset : 0;
    z->rule_dstoff = z->ntrans == 0 ? z->types[0].offset : 0;
    if (z->ntrans > 0) {
        size_t j = z->ntrans;
        while (j-- > 0) {
            if (!z->types[z->tidx[j]].isdst) {
                z->rule_stdoff = z->types[z->tidx[j]].offset;
                break;
            }
        }
    }
    free(buf);
    z->use_tzfile = 1;
    return 1;
lose:
    free(buf);
    gnu_free(z);
    z->use_tzfile = 0;
    return 0;
}

/* compute_change: the time the rule's change takes place in that year */
static int64_t gnu_change(const GnuRule* r, int64_t year) {
    static const int mon_yday[2][13] = {
        { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
        { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
    };
    int64_t t;
    if (year > 1970)
        t = ((year - 1970) * 365
             + ((year - 1) / 4 - 1970 / 4)
             - ((year - 1) / 100 - 1970 / 100)
             + ((year - 1) / 400 - 1970 / 400)) * 86400;
    else
        t = 0;
    switch (r->type) {
    case 1:
        t += (int64_t)(r->d - 1) * 86400;
        if (r->d >= 60 && z_isleap(year)) t += 86400;
        break;
    case 0:
        t += (int64_t)r->d * 86400;
        break;
    default: {
        const int* myday = &mon_yday[z_isleap(year)][r->m];
        unsigned int i;
        int64_t d, m1, yy0, yy1, yy2, dow;
        t += (int64_t)myday[-1] * 86400;
        m1 = (r->m + 9) % 12 + 1;
        yy0 = (r->m <= 2) ? (year - 1) : year;
        yy1 = yy0 / 100;
        yy2 = yy0 % 100;
        dow = ((26 * m1 - 2) / 10 + 1 + yy2 + yy2 / 4 + yy1 / 4 - 2 * yy1) % 7;
        if (dow < 0) dow += 7;
        d = r->d - dow;
        if (d < 0) d += 7;
        for (i = 1; i < r->n; ++i) {
            if (d + 7 >= myday[0] - myday[-1]) break;
            d += 7;
        }
        t += d * 86400;
        break;
    }
    }
    return t - r->offset + r->secs;
}

/* __tz_compute + __offtime for a POSIX rule pair */
static int gnu_posix_localtime(const GnuPosix* P, int64_t t, ZTm* tm) {
    ZTm u;
    int64_t c0, c1, year;
    int isdst;
    if (!z_gmtime(t, &u)) return 0;
    year = (int64_t)u.year + 1900;
    c0 = gnu_change(&P->r[0], year);
    c1 = gnu_change(&P->r[1], year);
    if (c0 > c1) isdst = (t < c1 || t >= c0);
    else isdst = (t >= c0 && t < c1);
    if (!z_gmtime(t + P->r[isdst].offset, tm)) return 0;
    tm->isdst = isdst;
    tm->gmtoff = P->r[isdst].offset;
    tm->zone = P->r[isdst].name;
    return 1;
}

static int gnu_localtime(const GnuZone* z, int64_t t, ZTm* tm) {
    size_t i;
    const GnuType* info;
    if (!z->use_tzfile) return gnu_posix_localtime(&z->posix, t, tm);
    if (z->ntrans == 0 || t < z->trans[0]) {
        i = 0;
        while (i < z->ntypes && z->types[i].isdst) ++i;
        if (i == z->ntypes) i = 0;
    } else if (t >= z->trans[z->ntrans - 1]) {
        if (z->has_spec && gnu_posix_localtime(&z->spec, t, tm)) return 1;
        i = z->tidx[z->ntrans - 1];
    } else {
        size_t lo = 0, hi = z->ntrans - 1;  /* trans[lo] <= t < trans[hi] */
        while (lo + 1 < hi) {
            size_t mid = (lo + hi) / 2;
            if (t < z->trans[mid]) hi = mid;
            else lo = mid;
        }
        i = z->tidx[lo];
    }
    info = &z->types[i];
    if (!z_gmtime(t + info->offset, tm)) return 0;
    tm->isdst = info->isdst;
    tm->gmtoff = info->offset;
    tm->zone = z->names + info->idx;
    return 1;
}

static void gnu_new(GnuZone* z, const char* tz) {
    if (*tz == '\0') tz = "Universal";
    if (*tz == ':') ++tz;
    if (gnu_read_file(tz, z)) return;
    memset(z, 0, sizeof(*z));
    if (*tz == '\0' || strcmp(tz, "/etc/localtime") == 0) {
        strcpy(z->posix.r[0].name, "UTC");
        strcpy(z->posix.r[1].name, "UTC");
        return;
    }
    gnu_parse_posix(tz, &z->posix, z);
}

/*==============================================================================
 * tzcode 8.14 (macOS Libc stdtime/FreeBSD/localtime.c; public domain)
 */
#define TZC_MAX_TIMES 1200
#define TZC_MAX_TYPES 256
#define TZC_MAX_CHARS 50
#define TZC_MAX_LEAPS 50
#define TZC_CHARS_SIZE 512          /* BIGGEST(TZ_MAX_CHARS + 1, 2 * (255 + 1)) */
#define TZC_SECSPERREPEAT ((int64_t)400 * 31556952)
#if defined(__APPLE__)
#  define TZC_TZDIR "/var/db/timezone/zoneinfo"
#else
#  define TZC_TZDIR "/usr/share/zoneinfo"   /* (for the tests elsewhere) */
#endif
#define TZC_DEFRULESTRING ",M4.1.0,M10.5.0"

typedef struct {
    int64_t gmtoff;
    int isdst, abbrind, ttisstd, ttisgmt;
} TzcType;

typedef struct {
    int leapcnt, timecnt, typecnt, charcnt, goback, goahead;
    int64_t ats[TZC_MAX_TIMES];
    unsigned char types[TZC_MAX_TIMES];
    TzcType ttis[TZC_MAX_TYPES];
    char chars[TZC_CHARS_SIZE];
} TzcState;

typedef struct { int type; int day, week, mon; int64_t time; } TzcRule;  /* type: 0 J, 1 n, 2 M */

static int tzc_parse(const char* name, TzcState* sp, int lastditch);

static int tzc_typesequiv(const TzcState* sp, int a, int b) {
    const TzcType *ap, *bp;
    if (a < 0 || a >= sp->typecnt || b < 0 || b >= sp->typecnt) return 0;
    ap = &sp->ttis[a];
    bp = &sp->ttis[b];
    return ap->gmtoff == bp->gmtoff && ap->isdst == bp->isdst && ap->ttisstd == bp->ttisstd
        && ap->ttisgmt == bp->ttisgmt && strcmp(&sp->chars[ap->abbrind], &sp->chars[bp->abbrind]) == 0;
}

/* tzload */
static int tzc_load(const char* name, TzcState* sp, int doextend) {
    char fullname[1024 + 1];
    unsigned char* buf;
    unsigned char* p;
    size_t nread0;
    long nread;
    int i, stored;
    sp->goback = sp->goahead = 0;
    if (name[0] == ':') ++name;
    if (name[0] != '/') {
        if (strlen(TZC_TZDIR) + 1 + strlen(name) >= 1024) return -1;
        strcpy(fullname, TZC_TZDIR);
        strcat(fullname, "/");
        strcat(fullname, name);
        name = fullname;
    }
    if (!z_is_regular(name)) return -1;
    /* (the size of upstream's buffer: two headers, two states, the times) */
    buf = z_read_file(name, 2 * 44 + 2 * 18432 + 4 * TZC_MAX_TIMES, &nread0);
    if (buf == NULL) return -1;
    nread = (long)nread0;
    if (nread <= 0) goto out;
    for (stored = 4; stored <= 8; stored *= 2) {
        int ttisstdcnt, ttisgmtcnt;
        if (nread < 44) goto out;
        ttisstdcnt = (int)z_be32(buf + 24);
        ttisgmtcnt = (int)z_be32(buf + 20);
        sp->leapcnt = (int)z_be32(buf + 28);
        sp->timecnt = (int)z_be32(buf + 32);
        sp->typecnt = (int)z_be32(buf + 36);
        sp->charcnt = (int)z_be32(buf + 40);
        p = buf + 44;
        if (sp->leapcnt < 0 || sp->leapcnt > TZC_MAX_LEAPS ||
            sp->typecnt <= 0 || sp->typecnt > TZC_MAX_TYPES ||
            sp->timecnt < 0 || sp->timecnt > TZC_MAX_TIMES ||
            sp->charcnt < 0 || sp->charcnt > TZC_MAX_CHARS ||
            (ttisstdcnt != sp->typecnt && ttisstdcnt != 0) ||
            (ttisgmtcnt != sp->typecnt && ttisgmtcnt != 0))
            goto out;
        if (nread - (p - buf) < (long)sp->timecnt * stored + sp->timecnt + sp->typecnt * 6
                + sp->charcnt + sp->leapcnt * (stored + 4) + ttisstdcnt + ttisgmtcnt)
            goto out;
        for (i = 0; i < sp->timecnt; ++i) {
            sp->ats[i] = stored == 4 ? z_be32(p) : z_be64(p);
            p += stored;
        }
        for (i = 0; i < sp->timecnt; ++i) {
            sp->types[i] = *p++;
            if (sp->types[i] >= sp->typecnt) goto out;
        }
        for (i = 0; i < sp->typecnt; ++i) {
            TzcType* t = &sp->ttis[i];
            t->gmtoff = z_be32(p);
            p += 4;
            t->isdst = *p++;
            if (t->isdst != 0 && t->isdst != 1) goto out;
            t->abbrind = *p++;
            if (t->abbrind > sp->charcnt) goto out;
        }
        for (i = 0; i < sp->charcnt; ++i) sp->chars[i] = (char)*p++;
        sp->chars[i] = '\0';
        p += (size_t)sp->leapcnt * (size_t)(stored + 4);   /* (leap seconds: not applied) */
        for (i = 0; i < sp->typecnt; ++i) {
            if (ttisstdcnt == 0) sp->ttis[i].ttisstd = 0;
            else {
                sp->ttis[i].ttisstd = *p++;
                if (sp->ttis[i].ttisstd != 1 && sp->ttis[i].ttisstd != 0) goto out;
            }
        }
        for (i = 0; i < sp->typecnt; ++i) {
            if (ttisgmtcnt == 0) sp->ttis[i].ttisgmt = 0;
            else {
                sp->ttis[i].ttisgmt = *p++;
                if (sp->ttis[i].ttisgmt != 1 && sp->ttis[i].ttisgmt != 0) goto out;
            }
        }
        /* out-of-sort ats: ignore the end */
        for (i = 0; i < sp->timecnt - 2; ++i)
            if (sp->ats[i] > sp->ats[i + 1]) {
                sp->timecnt = i + 1;
                break;
            }
        /* an old file: done */
        if (buf[4] == '\0') break;
        nread -= (long)(p - buf);
        memmove(buf, p, (size_t)nread);
    }
    if (doextend && nread > 2 && buf[0] == '\n' && buf[nread - 1] == '\n' &&
        sp->typecnt + 2 <= TZC_MAX_TYPES) {
        TzcState* ts = (TzcState*)calloc(1, sizeof(TzcState));
        int result;
        if (ts == NULL) goto out;
        buf[nread - 1] = '\0';
        result = tzc_parse((const char*)&buf[1], ts, 0);
        if (result == 0 && ts->typecnt == 2 && sp->charcnt + ts->charcnt <= TZC_MAX_CHARS) {
            for (i = 0; i < 2; ++i) ts->ttis[i].abbrind += sp->charcnt;
            for (i = 0; i < ts->charcnt; ++i) sp->chars[sp->charcnt++] = ts->chars[i];
            i = 0;
            while (i < ts->timecnt && sp->timecnt > 0 && ts->ats[i] <= sp->ats[sp->timecnt - 1]) ++i;
            while (i < ts->timecnt && sp->timecnt < TZC_MAX_TIMES) {
                sp->ats[sp->timecnt] = ts->ats[i];
                sp->types[sp->timecnt] = (unsigned char)(sp->typecnt + ts->types[i]);
                ++sp->timecnt;
                ++i;
            }
            sp->ttis[sp->typecnt++] = ts->ttis[0];
            sp->ttis[sp->typecnt++] = ts->ttis[1];
        }
        free(ts);
    }
    if (sp->timecnt > 1) {
        for (i = 1; i < sp->timecnt; ++i)
            if (tzc_typesequiv(sp, sp->types[i], sp->types[0]) &&
                sp->ats[i] - sp->ats[0] == TZC_SECSPERREPEAT) {
                sp->goback = 1;
                break;
            }
        for (i = sp->timecnt - 2; i >= 0; --i)
            if (tzc_typesequiv(sp, sp->types[sp->timecnt - 1], sp->types[i]) &&
                sp->ats[sp->timecnt - 1] - sp->ats[i] == TZC_SECSPERREPEAT) {
                sp->goahead = 1;
                break;
            }
    }
    free(buf);
    return 0;
out:
    free(buf);
    return -1;
}

static const char* tzc_getzname(const char* strp, const char** name, size_t* len) {
    const char* ket;
    char c;
    if (*strp == '<' && (ket = strchr(strp, '>')) != NULL) {
        *name = strp + 1;
        *len = (size_t)(ket - strp - 1);
        return ket + 1;
    }
    *name = strp;
    while ((c = *strp) != '\0' && !z_isdigit((unsigned char)c) && c != ',' && c != '-' && c != '+')
        ++strp;
    *len = (size_t)(strp - *name);
    return strp;
}

static const char* tzc_getqzname(const char* strp, int delim) {
    while (*strp != '\0' && *strp != delim) ++strp;
    return strp;
}

static const char* tzc_getnum(const char* strp, int* nump, int min, int max) {
    int num = 0;
    char c;
    if (strp == NULL || !z_isdigit((unsigned char)(c = *strp))) return NULL;
    do {
        num = num * 10 + (c - '0');
        if (num > max) return NULL;
        c = *++strp;
    } while (z_isdigit((unsigned char)c));
    if (num < min) return NULL;
    *nump = num;
    return strp;
}

static const char* tzc_getsecs(const char* strp, int64_t* secsp) {
    int num;
    strp = tzc_getnum(strp, &num, 0, 24 * 7 - 1);
    if (strp == NULL) return NULL;
    *secsp = (int64_t)num * 3600;
    if (*strp == ':') {
        strp = tzc_getnum(strp + 1, &num, 0, 59);
        if (strp == NULL) return NULL;
        *secsp += num * 60;
        if (*strp == ':') {
            strp = tzc_getnum(strp + 1, &num, 0, 60);
            if (strp == NULL) return NULL;
            *secsp += num;
        }
    }
    return strp;
}

static const char* tzc_getoffset(const char* strp, int64_t* offsetp) {
    int neg = 0;
    if (*strp == '-') { neg = 1; ++strp; }
    else if (*strp == '+') ++strp;
    strp = tzc_getsecs(strp, offsetp);
    if (strp == NULL) return NULL;
    if (neg) *offsetp = -*offsetp;
    return strp;
}

static const char* tzc_getrule(const char* strp, TzcRule* r) {
    if (*strp == 'J') {
        r->type = 0;
        strp = tzc_getnum(strp + 1, &r->day, 1, 365);
    } else if (*strp == 'M') {
        r->type = 2;
        strp = tzc_getnum(strp + 1, &r->mon, 1, 12);
        if (strp == NULL) return NULL;
        if (*strp++ != '.') return NULL;
        strp = tzc_getnum(strp, &r->week, 1, 5);
        if (strp == NULL) return NULL;
        if (*strp++ != '.') return NULL;
        strp = tzc_getnum(strp, &r->day, 0, 6);
    } else if (z_isdigit((unsigned char)*strp)) {
        r->type = 1;
        strp = tzc_getnum(strp, &r->day, 0, 365);
    } else {
        return NULL;
    }
    if (strp == NULL) return NULL;
    if (*strp == '/') strp = tzc_getsecs(strp + 1, &r->time);
    else r->time = 2 * 3600;
    return strp;
}

static int64_t tzc_transtime(int64_t janfirst, int year, const TzcRule* r, int64_t offset) {
    static const int mon_lengths[2][12] = {
        { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
        { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
    };
    int leapyear = z_isleap(year);
    int64_t value = 0;
    int i, d, m1, yy0, yy1, yy2, dow;
    switch (r->type) {
    case 0:
        value = janfirst + (int64_t)(r->day - 1) * 86400;
        if (leapyear && r->day >= 60) value += 86400;
        break;
    case 1:
        value = janfirst + (int64_t)r->day * 86400;
        break;
    default:
        value = janfirst;
        for (i = 0; i < r->mon - 1; ++i) value += (int64_t)mon_lengths[leapyear][i] * 86400;
        m1 = (r->mon + 9) % 12 + 1;
        yy0 = (r->mon <= 2) ? (year - 1) : year;
        yy1 = yy0 / 100;
        yy2 = yy0 % 100;
        dow = ((26 * m1 - 2) / 10 + 1 + yy2 + yy2 / 4 + yy1 / 4 - 2 * yy1) % 7;
        if (dow < 0) dow += 7;
        d = r->day - dow;
        if (d < 0) d += 7;
        for (i = 1; i < r->week; ++i) {
            if (d + 7 >= mon_lengths[leapyear][r->mon - 1]) break;
            d += 7;
        }
        value += (int64_t)d * 86400;
        break;
    }
    return value + r->time + offset;
}

/* tzparse */
static int tzc_parse(const char* name, TzcState* sp, int lastditch) {
    const char* stdname;
    const char* dstname = NULL;
    size_t stdlen, dstlen;
    int64_t stdoffset, dstoffset;
    int load_result;
    char* cp;
    if (lastditch) {
        stdname = name;
        stdlen = strlen(name);
        name += stdlen;
        if (stdlen >= sizeof sp->chars) stdlen = (sizeof sp->chars) - 1;
        stdoffset = 0;
    } else {
        name = tzc_getzname(name, &stdname, &stdlen);
        if (*name == '\0') return -1;
        name = tzc_getoffset(name, &stdoffset);
        if (name == NULL) return -1;
    }
    load_result = tzc_load("posixrules", sp, 0);
    if (load_result != 0) sp->leapcnt = 0;
    if (*name != '\0') {
        if (*name == '<') {
            dstname = ++name;
            name = tzc_getqzname(name, '>');
            if (*name != '>') return -1;
            dstlen = (size_t)(name - dstname);
            name++;
        } else {
            name = tzc_getzname(name, &dstname, &dstlen);
        }
        if (*name != '\0' && *name != ',' && *name != ';') {
            name = tzc_getoffset(name, &dstoffset);
            if (name == NULL) return -1;
        } else {
            dstoffset = stdoffset - 3600;
        }
        if (*name == '\0' && load_result != 0) name = TZC_DEFRULESTRING;
        if (*name == ',' || *name == ';') {
            TzcRule start, end;
            int year;
            int64_t janfirst = 0;
            ++name;
            if ((name = tzc_getrule(name, &start)) == NULL) return -1;
            if (*name++ != ',') return -1;
            if ((name = tzc_getrule(name, &end)) == NULL) return -1;
            if (*name != '\0') return -1;
            sp->typecnt = 2;
            sp->ttis[0].gmtoff = -dstoffset;
            sp->ttis[0].isdst = 1;
            sp->ttis[0].abbrind = (int)stdlen + 1;
            sp->ttis[1].gmtoff = -stdoffset;
            sp->ttis[1].isdst = 0;
            sp->ttis[1].abbrind = 0;
            sp->timecnt = 0;
            for (year = 1970; sp->timecnt + 2 <= TZC_MAX_TIMES; ++year) {
                int64_t starttime = tzc_transtime(janfirst, year, &start, stdoffset);
                int64_t endtime = tzc_transtime(janfirst, year, &end, dstoffset);
                int n = sp->timecnt;
                if (starttime > endtime) {
                    sp->ats[n] = endtime;   sp->types[n] = 1;
                    sp->ats[n + 1] = starttime; sp->types[n + 1] = 0;
                } else {
                    sp->ats[n] = starttime; sp->types[n] = 0;
                    sp->ats[n + 1] = endtime;   sp->types[n + 1] = 1;
                }
                sp->timecnt += 2;
                janfirst += (int64_t)(z_isleap(year) ? 366 : 365) * 86400;
            }
        } else {
            int64_t theirstdoffset = 0, theirdstoffset = 0, theiroffset;
            int isdst = 0, i, j;
            if (*name != '\0') return -1;
            for (i = 0; i < sp->timecnt; ++i) {
                j = sp->types[i];
                if (!sp->ttis[j].isdst) { theirstdoffset = -sp->ttis[j].gmtoff; break; }
            }
            for (i = 0; i < sp->timecnt; ++i) {
                j = sp->types[i];
                if (sp->ttis[j].isdst) { theirdstoffset = -sp->ttis[j].gmtoff; break; }
            }
            for (i = 0; i < sp->timecnt; ++i) {
                j = sp->types[i];
                sp->types[i] = (unsigned char)sp->ttis[j].isdst;
                if (sp->ttis[j].ttisgmt) {
                    /* no adjustment to transition time */
                } else if (isdst && !sp->ttis[j].ttisstd) {
                    sp->ats[i] += dstoffset - theirdstoffset;
                } else {
                    sp->ats[i] += stdoffset - theirstdoffset;
                }
                theiroffset = -sp->ttis[j].gmtoff;
                if (sp->ttis[j].isdst) theirdstoffset = theiroffset;
                else theirstdoffset = theiroffset;
            }
            (void)isdst;    /* (upstream never sets it either) */
            sp->ttis[0].gmtoff = -stdoffset;
            sp->ttis[0].isdst = 0;
            sp->ttis[0].abbrind = 0;
            sp->ttis[1].gmtoff = -dstoffset;
            sp->ttis[1].isdst = 1;
            sp->ttis[1].abbrind = (int)stdlen + 1;
            sp->typecnt = 2;
        }
    } else {
        dstlen = 0;
        sp->typecnt = 1;
        sp->timecnt = 0;
        sp->ttis[0].gmtoff = -stdoffset;
        sp->ttis[0].isdst = 0;
        sp->ttis[0].abbrind = 0;
    }
    sp->charcnt = (int)stdlen + 1;
    if (dstlen != 0) sp->charcnt += (int)dstlen + 1;
    if ((size_t)sp->charcnt > sizeof sp->chars) return -1;
    cp = sp->chars;
    memcpy(cp, stdname, stdlen);
    cp += stdlen;
    *cp++ = '\0';
    if (dstlen != 0) {
        memcpy(cp, dstname, dstlen);
        cp[dstlen] = '\0';
    }
    return 0;
}

/* tzset_basic for a TZ value */
static void tzc_new(TzcState* sp, const char* name) {
    if (*name == '\0') {
        sp->leapcnt = sp->timecnt = sp->typecnt = 0;
        sp->ttis[0].isdst = 0;
        sp->ttis[0].gmtoff = 0;
        sp->ttis[0].abbrind = 0;
        strcpy(sp->chars, "UTC");
        return;
    }
    if (tzc_load(name, sp, 1) != 0)
        if (name[0] == ':' || tzc_parse(name, sp, 0) != 0)
            if (tzc_load("UTC", sp, 1) != 0)    /* gmtload */
                (void)tzc_parse("UTC", sp, 1);
}

/* localsub */
static int tzc_localtime(const TzcState* sp, int64_t t, ZTm* tm) {
    const TzcType* ttisp;
    int i;
    if (sp->timecnt > 0 && ((sp->goback && t < sp->ats[0]) ||
                            (sp->goahead && t > sp->ats[sp->timecnt - 1]))) {
        int64_t newt = t, seconds, icycles;
        if (t < sp->ats[0]) seconds = sp->ats[0] - t;
        else seconds = t - sp->ats[sp->timecnt - 1];
        --seconds;
        icycles = seconds / 400 / 31556952 + 1;
        seconds = icycles * TZC_SECSPERREPEAT;
        if (t < sp->ats[0]) newt += seconds;
        else newt -= seconds;
        if (newt < sp->ats[0] || newt > sp->ats[sp->timecnt - 1]) return 0;
        if (!tzc_localtime(sp, newt, tm)) return 0;
        {
            int64_t newy = tm->year;
            if (t < sp->ats[0]) newy -= icycles * 400;
            else newy += icycles * 400;
            if (newy < INT32_MIN || newy > INT32_MAX) return 0;
            tm->year = (int)newy;
            /* (the weekday repeats with the 400-year cycle, the day of the
               year too) */
        }
        return 1;
    }
    if (sp->timecnt == 0 || t < sp->ats[0]) {
        i = 0;
        while (sp->ttis[i].isdst)
            if (++i >= sp->typecnt) { i = 0; break; }
    } else {
        int lo = 1, hi = sp->timecnt;
        while (lo < hi) {
            int mid = (lo + hi) >> 1;
            if (t < sp->ats[mid]) hi = mid;
            else lo = mid + 1;
        }
        i = sp->types[lo - 1];
    }
    ttisp = &sp->ttis[i];
    if (!z_gmtime(t + ttisp->gmtoff, tm)) return 0;
    tm->isdst = ttisp->isdst;
    tm->gmtoff = ttisp->gmtoff;
    tm->zone = &sp->chars[ttisp->abbrind];
    return 1;
}

/*==============================================================================
 * The Windows C runtime (tzset.cpp, localtime.cpp, mktime.cpp of the UCRT;
 * msvcrt.dll reads TZ the same way)
 */
typedef struct {
    char tzname[2][4];
    int64_t timezone;           /* seconds WEST of UTC */
    int daylight;
} CrtZone;

#define CRT_MAX_TIME64 ((int64_t)32535215999)  /* 3000-12-31 23:59:59 UTC */

/* atol: white space, an optional sign, digits */
static int64_t crt_atol(const char* p) {
    int neg = 0;
    int64_t v = 0;
    while (z_isspace((unsigned char)*p)) ++p;
    if (*p == '+' || *p == '-') neg = (*p++ == '-');
    while (z_isdigit((unsigned char)*p)) {
        if (v < ((int64_t)1 << 40)) v = v * 10 + (*p - '0');
        ++p;
    }
    return neg ? -v : v;
}

static void crt_new(CrtZone* z, const char* tz) {
    const char* p;
    size_t n = 0;
    char sign;
    memset(z, 0, sizeof(*z));
    while (n < 3 && tz[n] != '\0') { z->tzname[0][n] = tz[n]; ++n; }
    p = tz + n;
    sign = *p;
    if (sign == '-') ++p;
    z->timezone = crt_atol(p) * 3600;
    while (*p == '+' || z_isdigit((unsigned char)*p)) ++p;
    if (*p == ':') {
        z->timezone += crt_atol(++p) * 60;
        while (z_isdigit((unsigned char)*p)) ++p;
        if (*p == ':') {
            z->timezone += crt_atol(++p);
            while (z_isdigit((unsigned char)*p)) ++p;
        }
    }
    if (sign == '-') z->timezone = -z->timezone;
    z->daylight = *p ? 1 : 0;
    if (z->daylight) {
        for (n = 0; n < 3 && p[n] != '\0'; ++n) z->tzname[1][n] = p[n];
    }
}

/* the year day (0-based) of the week-th (5: last) Sunday of a month */
static int crt_sunday(int year1900, int month, int week) {
    static const int cum[2][13] = {
        { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
        { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
    };
    int64_t y = (int64_t)year1900 + 1900;
    int leap = z_isleap(y);
    int first = cum[leap][month - 1];
    int dow = (int)z_fmod(z_days_from_civil(y, month, 1) + 4, 7);
    int yday = first + (7 - dow) % 7 + (week - 1) * 7;
    if (week == 5 && yday >= cum[leap][month]) yday -= 7;
    return yday;
}

/* _isindst for the US rules (tm: the standard-time fields) */
static int crt_isindst(const ZTm* tb) {
    int startyd, endyd;
    int64_t startms = 2 * 3600000, endms = 2 * 3600000 - 3600000, ms;
    if (tb->year < 107) {
        startyd = crt_sunday(tb->year, 4, 1);
        endyd = crt_sunday(tb->year, 10, 5);
    } else {
        startyd = crt_sunday(tb->year, 3, 2);
        endyd = crt_sunday(tb->year, 11, 1);
    }
    if (tb->yday < startyd || tb->yday > endyd) return 0;
    if (tb->yday > startyd && tb->yday < endyd) return 1;
    ms = 1000 * ((int64_t)tb->sec + 60 * tb->min + 3600 * tb->hour);
    if (tb->yday == startyd) return ms >= startms;
    return ms < endms;
}

static int crt_localtime(const CrtZone* z, int64_t t, ZTm* tm) {
    int64_t lt;
    if (t < 0 || t > CRT_MAX_TIME64) return 0;
    lt = t - z->timezone;
    if (!z_gmtime(lt, tm)) return 0;
    tm->isdst = 0;
    if (z->daylight && crt_isindst(tm)) {
        lt += 3600;
        if (!z_gmtime(lt, tm)) return 0;
        tm->isdst = 1;
    }
    tm->gmtoff = -z->timezone + (tm->isdst ? 3600 : 0);
    tm->zone = z->tzname[tm->isdst];
    return 1;
}

/*==============================================================================
 * The zone object
 */
typedef struct {
    int flavor;
    char* value;                /* the TZ value as given */
    int64_t mktime_offset;      /* (gnu: glibc's localtime_offset, see gnu_mktime) */
    union {
        GnuZone gnu;
        TzcState* tzc;
        CrtZone crt;
    } u;
} SysZone;

static int zone_localtime(const SysZone* z, int64_t t, ZTm* tm) {
    switch (z->flavor) {
    case ZF_GNU:    return gnu_localtime(&z->u.gnu, t, tm);
    case ZF_TZCODE: return tzc_localtime(z->u.tzc, t, tm);
    default:        return crt_localtime(&z->u.crt, t, tm);
    }
}

/* ---- mktime() with tm_isdst = -1 in the zone, per flavor: the normalized
 * local time of the fields in *out, 0 where the C library's mktime fails
 * (and leaves the fields alone). Where a local time exists twice (the
 * hour a DST period ends) or not at all (the hour it begins), each C
 * library has an answer of its own, so each one's algorithm is followed
 * as written, not a rule of thumb. ---- */

/* glibc (time/mktime.c, __mktime_internal with __localtime64_r): probe
 * with a guessed UTC offset and correct by the difference, starting from
 * the offset of the previous mktime call -- so a time that exists twice
 * comes out at the instant with the previous result's offset (after a
 * winter date the second, standard-time one, after a summer date the
 * first). A time in a gap, where the probes oscillate between two values,
 * is the one with tm_isdst set if only one has it (moved forward by the
 * gap). glibc keeps that offset in a static for the whole process; here
 * it belongs to the zone object (*offset; 0 at first, as glibc's). */
static int64_t gnu_ydhms_diff(int64_t year1, int64_t yday1, int hour1, int min1, int sec1,
                              int year0, int yday0, int hour0, int min0, int sec0) {
    /* (shr is an arithmetic shift, i.e. a floor division by 2^b) */
    int64_t a4 = z_fdiv(year1, 4) + 1900 / 4 - !(year1 & 3);
    int64_t b4 = z_fdiv(year0, 4) + 1900 / 4 - !(year0 & 3);
    int64_t a100 = (a4 + (a4 < 0)) / 25 - (a4 < 0);
    int64_t b100 = (b4 + (b4 < 0)) / 25 - (b4 < 0);
    int64_t a400 = z_fdiv(a100, 4);
    int64_t b400 = z_fdiv(b100, 4);
    int64_t intervening_leap_days = (a4 - b4) - (a100 - b100) + (a400 - b400);
    int64_t years = year1 - year0;
    int64_t days = 365 * years + yday1 - yday0 + intervening_leap_days;
    int64_t hours = 24 * days + hour1 - hour0;
    int64_t minutes = 60 * hours + min1 - min0;
    return 60 * minutes + sec1 - sec0;
}

static int64_t gnu_tm_diff(int64_t year, int64_t yday, int hour, int min, int sec, const ZTm* tp) {
    return gnu_ydhms_diff(year, yday, hour, min, sec, tp->year, tp->yday, tp->hour, tp->min, tp->sec);
}

/* ranged_convert: localtime, or where it fails (a year beyond int) the
 * nearest time it handles, found by bisection towards 0 */
static int gnu_ranged_convert(const GnuZone* z, int64_t* t, ZTm* tp) {
    int64_t bad, ok = 0;
    ZTm oktm;
    int have = 0;
    if (gnu_localtime(z, *t, tp)) return 1;
    bad = *t;
    for (;;) {
        int64_t mid = z_fdiv(ok, 2) + z_fdiv(bad, 2) + ((ok | bad) & 1);
        if (mid == ok || mid == bad) break;
        if (gnu_localtime(z, mid, tp)) { ok = mid; oktm = *tp; have = 1; }
        else bad = mid;
    }
    if (!have) return 0;
    *t = ok;
    *tp = oktm;
    return 1;
}

static int gnu_mktime(const GnuZone* z, int64_t* offset, int sec, int min, int hour, int mday,
                      int mon, int year_requested, ZTm* out) {
    static const unsigned short mon_yday_tab[2][13] = {
        { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
        { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
    };
    ZTm tm;
    int remaining_probes = 6;
    int dst2 = 0;
    int mon_remainder = mon % 12;
    int negative_mon_remainder = mon_remainder < 0;
    int mon_years = mon / 12 - negative_mon_remainder;
    int64_t year = (int64_t)year_requested + mon_years;
    int64_t mon_yday = (int64_t)mon_yday_tab[z_isleap(year + 1900)]
                                            [mon_remainder + 12 * negative_mon_remainder] - 1;
    int64_t yday = mon_yday + mday;
    int64_t off = *offset;
    int64_t negative_offset_guess = -off;
    int sec_requested = sec;
    int64_t t0, t, t1, t2;
    /* (LEAP_SECONDS_POSSIBLE: out-of-range seconds are put back at the end) */
    if (sec < 0) sec = 0;
    if (59 < sec) sec = 59;
    t0 = gnu_ydhms_diff(year, yday, hour, min, sec, 1970 - 1900, 0, 0, 0,
                        (int)negative_offset_guess);
    t = t1 = t2 = t0;
    for (;;) {
        int64_t dt;
        if (!gnu_ranged_convert(z, &t, &tm)) return 0;
        dt = gnu_tm_diff(year, yday, hour, min, sec, &tm);
        if (dt == 0) break;
        /* (isdst is -1: the oscillation test's "dst2 <= tm_isdst" branch) */
        if (t == t1 && t != t2 && (tm.isdst < 0 || dst2 <= (tm.isdst != 0)))
            goto offset_found;
        remaining_probes--;
        if (remaining_probes == 0) return 0;
        t1 = t2, t2 = t, t += dt, dst2 = tm.isdst != 0;
    }
    /* (the hunt for a neighbouring time with the requested tm_isdst is
       left out: with isdst -1 there is none to differ from) */
offset_found:
    *offset = t - t0 - negative_offset_guess;
    if (sec_requested != tm.sec) {
        int64_t sec_adjustment = sec == 0 && tm.sec == 60;
        sec_adjustment -= sec;
        sec_adjustment += sec_requested;
        t += sec_adjustment;
        if (!gnu_localtime(z, t, &tm)) return 0;
    }
    *out = tm;
    return 1;
}

/* tzcode (macOS Libc localtime.c: mktime -> time1 -> time2 -> time2sub
 * with localsub, built with PCTS and __DARWIN_UNIX03 -- Apple's private.h
 * defines PCTS): normalize the fields, then a binary search over the whole
 * 64-bit time_t for a time whose local fields compare equal. A time that
 * exists twice is whichever of the two the bisection reaches. One in a gap
 * has no match; with tm_isdst -1, time1's PCTS branch then takes it as
 * standard time (tm_isdst 0) and tries the other types: shifted by the
 * difference of a DST and a standard offset and taken as DST, which moves
 * 02:30 of a spring gap on to 03:30 DST. Where that fails too (a year
 * before 1900, "POLA"), mktime returns -1 with the fields as given but
 * tm_isdst 0. */
typedef struct { int sec, min, hour, mday, mon, year, isdst; } TzcFields;

static int tzc_increment_overflow(int* number, int delta) {
    int64_t r = (int64_t)*number + delta;
    if (r < INT_MIN || r > INT_MAX) return 1;
    *number = (int)r;
    return 0;
}

static int tzc_normalize_overflow(int* tensptr, int* unitsptr, int base) {
    int tensdelta = (*unitsptr >= 0) ? (*unitsptr / base) : (-1 - (-1 - *unitsptr) / base);
    *unitsptr -= tensdelta * base;
    return tzc_increment_overflow(tensptr, tensdelta);
}

static int tzc_long_normalize_overflow(int64_t* tensptr, int* unitsptr, int base) {
    int tensdelta = (*unitsptr >= 0) ? (*unitsptr / base) : (-1 - (-1 - *unitsptr) / base);
    *unitsptr -= tensdelta * base;
    *tensptr += tensdelta;
    return 0;
}

static int tzc_tmcomp(const ZTm* a, const TzcFields* b) {
    int result;
    if (a->year != b->year) return a->year > b->year ? 1 : -1;
    if ((result = (a->mon - b->mon)) == 0 &&
        (result = (a->mday - b->mday)) == 0 &&
        (result = (a->hour - b->hour)) == 0 &&
        (result = (a->min - b->min)) == 0)
        result = a->sec - b->sec;
    return result;
}

static int tzc_time2sub(const TzcState* sp, const TzcFields* tmp, int do_norm_secs,
                        ZTm* out) {
    static const int mon_lengths[2][12] = {
        { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
        { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
    };
    static const int year_lengths[2] = { 365, 366 };
    TzcFields yourtm = *tmp;
    ZTm mytm;
    int i, saved_seconds;
    int64_t y, li, lo, hi, t, newt;
    if (do_norm_secs && tzc_normalize_overflow(&yourtm.min, &yourtm.sec, 60)) return 0;
    if (tzc_normalize_overflow(&yourtm.hour, &yourtm.min, 60)) return 0;
    if (tzc_normalize_overflow(&yourtm.mday, &yourtm.hour, 24)) return 0;
    y = yourtm.year;
    if (tzc_long_normalize_overflow(&y, &yourtm.mon, 12)) return 0;
    y += 1900;
    while (yourtm.mday <= 0) {
        --y;
        li = y + (1 < yourtm.mon);
        yourtm.mday += year_lengths[z_isleap(li)];
    }
    while (yourtm.mday > 366) {
        li = y + (1 < yourtm.mon);
        yourtm.mday -= year_lengths[z_isleap(li)];
        ++y;
    }
    for (;;) {
        i = mon_lengths[z_isleap(y)][yourtm.mon];
        if (yourtm.mday <= i) break;
        yourtm.mday -= i;
        if (++yourtm.mon >= 12) {
            yourtm.mon = 0;
            ++y;
        }
    }
    y -= 1900;
    if (y < INT_MIN || y > INT_MAX) return 0;
    yourtm.year = (int)y;
    if (yourtm.year < 0) return 0;      /* Don't go below 1900 for POLA */
    if (yourtm.sec >= 0 && yourtm.sec < 60)
        saved_seconds = 0;
    else if (y + 1900 < 1970) {
        if (tzc_increment_overflow(&yourtm.sec, 1 - 60)) return 0;
        saved_seconds = yourtm.sec;
        yourtm.sec = 60 - 1;
    } else {
        saved_seconds = yourtm.sec;
        yourtm.sec = 0;
    }
    lo = INT64_MIN;
    hi = INT64_MAX;
    for (;;) {
        int dir;
        t = lo / 2 + hi / 2;
        if (t < lo) t = lo;
        else if (t > hi) t = hi;
        if (!tzc_localtime(sp, t, &mytm)) dir = (t > 0) ? 1 : -1;
        else dir = tzc_tmcomp(&mytm, &yourtm);
        if (dir != 0) {
            if (t == lo) {
                if (t == INT64_MAX) return 0;
                ++t;
                ++lo;
            } else if (t == hi) {
                if (t == INT64_MIN) return 0;
                --t;
                --hi;
            }
            if (lo > hi) return 0;
            if (dir > 0) hi = t;
            else lo = t;
            continue;
        }
        /* (unix03: a zone with a single type has no alternative time) */
        if (sp->typecnt == 1 && yourtm.isdst > 0) yourtm.isdst = 0;
        if (yourtm.isdst < 0 || mytm.isdst == yourtm.isdst) break;
        /* Right time, wrong type. Hunt for right time, right type. It's
           okay to guess wrong since the guess gets checked. */
        {
            int j, found = 0;
            for (i = sp->typecnt - 1; i >= 0 && !found; --i) {
                if (sp->ttis[i].isdst != yourtm.isdst) continue;
                for (j = sp->typecnt - 1; j >= 0; --j) {
                    if (sp->ttis[j].isdst == yourtm.isdst) continue;
                    newt = t + sp->ttis[j].gmtoff - sp->ttis[i].gmtoff;
                    if (!tzc_localtime(sp, newt, &mytm)) continue;
                    if (tzc_tmcomp(&mytm, &yourtm) != 0) continue;
                    if (mytm.isdst != yourtm.isdst) continue;
                    /* We have a match. */
                    t = newt;
                    found = 1;
                    break;
                }
            }
            if (!found) return 0;
        }
        break;
    }
    newt = t + saved_seconds;
    if ((newt < t) != (saved_seconds < 0)) return 0;
    t = newt;
    if (!tzc_localtime(sp, t, out)) return 0;
    return 1;
}

/* time2: first without normalizing the seconds, then with */
static int tzc_time2(const TzcState* sp, const TzcFields* tmp, ZTm* out) {
    return tzc_time2sub(sp, tmp, 0, out) || tzc_time2sub(sp, tmp, 1, out);
}

/* time1 (PCTS): tm_isdst as given (-1 from POSIX::strftime) in *isdst, set
 * to 0 by the PCTS branch where the first try fails -- the caller's
 * struct tm keeps that value when mktime fails altogether */
static int tzc_time1(const TzcState* sp, TzcFields* tmp, ZTm* out) {
    int seen[TZC_MAX_TYPES];
    int types[TZC_MAX_TYPES];
    int i, nseen, sameind, otherind;
    if (tmp->isdst > 1) tmp->isdst = 1;
    if (tzc_time2(sp, tmp, out)) return 1;
    /* PCTS code courtesy Grant Sullivan. */
    if (tmp->isdst < 0) tmp->isdst = 0;     /* reset to std and try again */
    /* We're supposed to assume that somebody took a time of one type and
       did some math on it that yielded a "struct tm" that's bad. We try to
       divine the type they started from and adjust to the type they
       need. */
    for (i = 0; i < sp->typecnt; ++i) seen[i] = 0;
    nseen = 0;
    for (i = sp->timecnt - 1; i >= 0; --i)
        if (!seen[sp->types[i]]) {
            seen[sp->types[i]] = 1;
            types[nseen++] = sp->types[i];
        }
    for (sameind = 0; sameind < nseen; ++sameind) {
        int samei = types[sameind];
        if (sp->ttis[samei].isdst != tmp->isdst) continue;
        for (otherind = 0; otherind < nseen; ++otherind) {
            int otheri = types[otherind];
            int delta;
            if (sp->ttis[otheri].isdst == tmp->isdst) continue;
            delta = (int)(sp->ttis[otheri].gmtoff - sp->ttis[samei].gmtoff);
            tmp->sec += delta;
            tmp->isdst = !tmp->isdst;
            if (tzc_time2(sp, tmp, out)) return 1;
            tmp->sec -= delta;
            tmp->isdst = !tmp->isdst;
        }
    }
    return 0;
}

/* settzname: tzname[0] (returned) and the offsets east of UTC behind
 * timezone and altzone, from the last transition backwards (PR-3765457):
 * the first standard and the first DST type met, else the type of the
 * first transition; "   " (WILDABBR) and 0 where there is none */
static const char* tzc_settzname(const TzcState* sp, int64_t* stdoff, int64_t* dstoff) {
    static const unsigned char none[1] = { 0 };
    const unsigned char* types;
    const char* name = "   ";
    int i, needStd = 1, needDst = 1;
    *stdoff = *dstoff = 0;
    if (sp->timecnt == 0 && sp->typecnt == 1) {
        i = 0;
        types = none;       /* (we use the null as index) */
    } else {
        i = sp->timecnt - 1;
        types = sp->types;
    }
    for (; i >= 0 && (needStd || needDst); --i) {
        const TzcType* ttisp = &sp->ttis[types[i]];
        if (ttisp->isdst) {
            if (needDst) {
                needDst = 0;
                *dstoff = ttisp->gmtoff;
            }
        } else if (needStd) {
            needStd = 0;
            name = &sp->chars[ttisp->abbrind];
            *stdoff = ttisp->gmtoff;
        }
        if (i == 0) {
            if (needDst) *dstoff = ttisp->gmtoff;
            if (needStd) *stdoff = ttisp->gmtoff;
        }
    }
    return name;
}

static int tzc_mktime(const TzcState* sp, int sec, int min, int hour, int mday, int mon,
                      int year, int* isdst, ZTm* out) {
    TzcFields f;
    int ok;
    f.sec = sec; f.min = min; f.hour = hour; f.mday = mday; f.mon = mon; f.year = year;
    f.isdst = *isdst;
    ok = tzc_time1(sp, &f, out);
    *isdst = f.isdst;
    return ok;
}

/* The UCRT (mktime.cpp common_mktime with use_local_time, __time64_t --
 * the mktime of a 64-bit time_t build such as Strawberry Perl's): the year
 * must be within 1969..3001 (tm_year 69..1101); a month outside 0..11 is
 * brought into it, the years carried -- in the caller's struct tm, as the
 * UCRT does, even where it fails afterwards; the fields are summed up as
 * seconds since 1970 (the leap days counted as in the Gregorian calendar,
 * which is what _days[] and __crt_time_elapsed_leap_years add up to), the
 * zone's offset added, and localtime() taken. Since tm_isdst is -1 (POSIX::
 * strftime), DST follows that localtime: if it says DST, the DST bias is
 * added and localtime() taken again, and its fields (with its tm_isdst)
 * are the result. The bias is -3600: the UCRT's initial _dstbias, which
 * _tzset leaves alone for a TZ value (tzset_from_environment_nolock sets
 * only _timezone, _daylight and _tzname), as crt_localtime assumes too.
 * Fails (EINVAL; the fields stay as given, but for the month) for a year
 * out of range and where localtime fails -- before 1970 UTC, after 3000.
 * (The overflow checks ChkAdd/ChkMul cannot fire for int fields summed in
 * 64 bits and are left out.) */
#define CRT_BASE_YEAR   70          /* _BASE_YEAR */
#define CRT_MAX_YEAR64  1100        /* _MAX_YEAR64 (3000) */
#define CRT_DSTBIAS     (-3600)     /* _dstbias */

static int crt_mktime(const CrtZone* z, struct tm* tb, ZTm* out) {
    /* _days: the days before each month (from Jan 1), minus one */
    static const int days[13] = { -1, 30, 58, 89, 119, 150, 180, 211, 242, 272, 303, 333, 364 };
    int64_t years = tb->tm_year, t;
    if (years < CRT_BASE_YEAR - 1 || years > CRT_MAX_YEAR64 + 1) return 0;
    if (tb->tm_mon < 0 || tb->tm_mon > 11) {
        years += tb->tm_mon / 12;
        if ((tb->tm_mon %= 12) < 0) {
            tb->tm_mon += 12;
            --years;
        }
        if (years < CRT_BASE_YEAR - 1 || years > CRT_MAX_YEAR64 + 1) return 0;
    }
    /* the elapsed days to the month, then to the date */
    t = days[tb->tm_mon];
    if (z_isleap(years + 1900) && tb->tm_mon > 1) ++t;
    t += z_days_from_civil(years + 1900, 1, 1);
    t += tb->tm_mday;
    /* hours, minutes, seconds */
    t = ((t * 24 + tb->tm_hour) * 60 + tb->tm_min) * 60 + tb->tm_sec;
    /* the zone: localtime of the time as standard time, then DST */
    t += z->timezone;
    if (!crt_localtime(z, t, out)) return 0;
    if (out->isdst > 0) {
        t += CRT_DSTBIAS;
        if (!crt_localtime(z, t, out)) return 0;
    }
    return 1;
}

/* mktime in the zone of the fields of *tb (which only the "crt" reading
 * changes, see crt_mktime) */
static int zone_mktime(SysZone* z, struct tm* tb, ZTm* out) {
    switch (z->flavor) {
    case ZF_GNU:    return gnu_mktime(&z->u.gnu, &z->mktime_offset, tb->tm_sec, tb->tm_min,
                                      tb->tm_hour, tb->tm_mday, tb->tm_mon, tb->tm_year, out);
    case ZF_TZCODE: return tzc_mktime(z->u.tzc, tb->tm_sec, tb->tm_min, tb->tm_hour, tb->tm_mday,
                                      tb->tm_mon, tb->tm_year, &tb->tm_isdst, out);
    default:        return crt_mktime(&z->u.crt, tb, out);
    }
}

static int sys_zone_gc(lua_State* L) {
    SysZone* z = (SysZone*)luaL_checkudata(L, 1, ZONE_META);
    if (z->flavor == ZF_GNU) gnu_free(&z->u.gnu);
    else if (z->flavor == ZF_TZCODE) free(z->u.tzc);
    free(z->value);
    z->flavor = 0;
    z->value = NULL;
    return 0;
}

/* tz_new(value[, flavor]) */
static int sys_tz_new(lua_State* L) {
    size_t len;
    const char* value = luaL_checklstring(L, 1, &len);
    const char* fl = luaL_optstring(L, 2, NULL);
    SysZone* z;
    int flavor;
#if defined(_WIN32)
    flavor = ZF_CRT;
#elif defined(__APPLE__)
    flavor = ZF_TZCODE;
#else
    flavor = ZF_GNU;
#endif
    if (fl != NULL) {
        if (strcmp(fl, "gnu") == 0) flavor = ZF_GNU;
        else if (strcmp(fl, "tzcode") == 0) flavor = ZF_TZCODE;
        else if (strcmp(fl, "crt") == 0) flavor = ZF_CRT;
        else return luaL_argerror(L, 2, "flavor must be 'gnu', 'tzcode' or 'crt'");
    }
    z = (SysZone*)lua_newuserdatauv(L, sizeof(SysZone), 0);
    memset(z, 0, sizeof(*z));
    if (luaL_newmetatable(L, ZONE_META)) {
        lua_pushcfunction(L, sys_zone_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);
    /* (the value as a C string, as Perl's %ENV passes it on) */
    z->value = (char*)malloc(strlen(value) + 1);
    if (z->value == NULL) return luaL_error(L, "not enough memory");
    strcpy(z->value, value);
    z->flavor = flavor;
    switch (flavor) {
    case ZF_GNU:
        gnu_new(&z->u.gnu, z->value);
        break;
    case ZF_TZCODE:
        z->u.tzc = (TzcState*)calloc(1, sizeof(TzcState));
        if (z->u.tzc == NULL) return luaL_error(L, "not enough memory");
        tzc_new(z->u.tzc, z->value);
        break;
    default:
        crt_new(&z->u.crt, z->value);
        break;
    }
    (void)len;
    return 1;
}

static void push_ztm(lua_State* L, const ZTm* tm) {
    lua_pushinteger(L, tm->sec);
    lua_pushinteger(L, tm->min);
    lua_pushinteger(L, tm->hour);
    lua_pushinteger(L, tm->mday);
    lua_pushinteger(L, tm->mon);
    lua_pushinteger(L, tm->year);
    lua_pushinteger(L, tm->wday);
    lua_pushinteger(L, tm->yday);
    lua_pushinteger(L, tm->isdst);
    lua_pushinteger(L, (lua_Integer)tm->gmtoff);
    lua_pushstring(L, tm->zone ? tm->zone : "");
}

/* tz_localtime(zone, t) */
static int sys_tz_localtime(lua_State* L) {
    SysZone* z = (SysZone*)luaL_checkudata(L, 1, ZONE_META);
    lua_Integer t = luaL_checkinteger(L, 2);
    ZTm tm;
    if (!zone_localtime(z, (int64_t)t, &tm)) {
        lua_pushnil(L);
        return 1;
    }
    push_ztm(L, &tm);
    return 11;
}

/* The format with every plain %Z (and, where told, %z) replaced by the
 * zone's text ('%' doubled); flags or a width before Z leave the
 * conversion to the C library unless the name is empty (then: the width in
 * spaces). Returns a malloc'ed string or NULL (nothing to replace). */
static char* zone_format(const char* fmt, const ZTm* tm, int doZ, int doz, int anyFlags) {
    size_t cap = strlen(fmt) * 2 + 64, n = 0;
    char* out = (char*)malloc(cap);
    const char* p = fmt;
    int changed = 0;
    char zbuf[16];
    const char* zname = tm->zone ? tm->zone : "";
    if (out == NULL) return NULL;
    {
        /* %z as the UCRT writes it: from the bias west of UTC */
        int64_t bias = -tm->gmtoff, a;
        a = bias < 0 ? -bias : bias;
        sprintf(zbuf, "%c%02d%02d", bias > 0 ? '-' : '+', (int)(a / 3600), (int)(a / 60 % 60));
    }
    while (*p) {
        const char* spec = p;
        const char* q;
        const char* text = NULL;
        size_t width = 0;
        int plain;
        if (*p != '%') {
            if (n + 2 >= cap) { char* o = (char*)realloc(out, cap *= 2); if (!o) { free(out); return NULL; } out = o; }
            out[n++] = *p++;
            continue;
        }
        q = p + 1;
        if (*q == '%') {
            if (n + 3 >= cap) { char* o = (char*)realloc(out, cap *= 2); if (!o) { free(out); return NULL; } out = o; }
            out[n++] = '%'; out[n++] = '%';
            p = q + 1;
            continue;
        }
        while (*q == '_' || *q == '-' || *q == '0' || *q == '^' || *q == '#') ++q;
        while (z_isdigit((unsigned char)*q)) width = width * 10 + (size_t)(*q++ - '0');
        if (*q == 'E' || *q == 'O') ++q;
        plain = (q == p + 1) || anyFlags;
        if (*q == 'Z' && doZ && (plain || *zname == '\0')) text = zname;
        else if (*q == 'z' && doz && plain) text = zbuf;
        if (text == NULL) {
            /* copy the conversion unchanged */
            size_t k = (size_t)(q - spec) + (*q ? 1 : 0);
            if (n + k + 2 >= cap) { char* o = (char*)realloc(out, cap = cap * 2 + k); if (!o) { free(out); return NULL; } out = o; }
            memcpy(out + n, spec, k);
            n += k;
            p = spec + k;
            continue;
        }
        changed = 1;
        {
            size_t tl = strlen(text), k;
            if (!plain && width > tl) {
                size_t pad = width - tl;
                if (n + pad + 2 >= cap) { char* o = (char*)realloc(out, cap = cap * 2 + pad); if (!o) { free(out); return NULL; } out = o; }
                memset(out + n, ' ', pad);
                n += pad;
            }
            for (k = 0; k < tl; ++k) {
                if (n + 3 >= cap) { char* o = (char*)realloc(out, cap *= 2); if (!o) { free(out); return NULL; } out = o; }
                if (text[k] == '%') out[n++] = '%';
                out[n++] = text[k];
            }
        }
        p = q + 1;
    }
    out[n] = '\0';
    if (!changed) { free(out); return NULL; }
    return out;
}

/*------------------------------------------------------------------------------
 * POSIX::strftime(fmt, sec, min, hour, mday, mon, year) -- Perl 5.42's
 * POSIX.xs strftime with its default isdst = -1 (the only form upstream
 * calls; Perl 5.42.0 alone defaults it to 0, a bug of that release, GH
 * #22351, which the port does not reproduce -- doc/differences.md), i.e.
 * locale.c sv_strftime_ints -> ints_to_tm + sv_strftime_common -> strftime8
 * -> strftime_tm, over the platform's own libc strftime (not
 * Lua's os.date, which on Windows rejects conversions outside its own list,
 * %C and %e among them, where Perl hands the format to the CRT unchanged):
 *  - the struct tm is zeroed, the six fields are set, tm_isdst = -1, and
 *    libc mktime() normalizes it in place (its result is ignored, so a time
 *    mktime cannot represent keeps the fields as given, with tm_wday/tm_yday
 *    0 and tm_isdst -1, as in Perl -- on Windows the CRT's strftime then
 *    takes tm_isdst as true for %Z and %z);
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
    SysZone* zone = NULL;
    ZTm ztm;
    char* zfmt = NULL;

    memset(&mytm, 0, sizeof(mytm));
    mytm.tm_sec  = int_arg(L, 2);
    mytm.tm_min  = int_arg(L, 3);
    mytm.tm_hour = int_arg(L, 4);
    mytm.tm_mday = int_arg(L, 5);
    mytm.tm_mon  = int_arg(L, 6);
    mytm.tm_year = int_arg(L, 7);

    /* the locale Perl's LC_TIME has (find_locale_from_environment) */
    sl = get_locale(L);

    /* ints_to_tm: libc mktime() with isdst = -1 normalizes the fields --
     * port: with a zone object (the ExifTool object's TimeZone), mktime in
     * that zone instead of the process's */
    mytm.tm_isdst = -1;
    if (!lua_isnoneornil(L, 8)) {
        zone = (SysZone*)luaL_checkudata(L, 8, ZONE_META);
        if (zone_mktime(zone, &mytm, &ztm)) {
            mytm.tm_sec = ztm.sec;
            mytm.tm_min = ztm.min;
            mytm.tm_hour = ztm.hour;
            mytm.tm_mday = ztm.mday;
            mytm.tm_mon = ztm.mon;
            mytm.tm_year = ztm.year;
            mytm.tm_wday = ztm.wday;
            mytm.tm_yday = ztm.yday;
            mytm.tm_isdst = ztm.isdst;
        } else {
            /* (mktime failed: the fields stay as given, isdst -1; the CRT's
               %Z and %z then take tm_isdst as true -- wcsftime.cpp:
               tzname[tm_isdst ? 1 : 0], _timezone plus _dstbias) */
            memset(&ztm, 0, sizeof(ztm));
            ztm.isdst = -1;
            if (zone->flavor == ZF_CRT) {
                ztm.zone = zone->u.crt.tzname[1];
                ztm.gmtoff = -(zone->u.crt.timezone + CRT_DSTBIAS);
            } else if (zone->flavor == ZF_TZCODE) {
                /* (macOS: time1's PCTS branch has left tm_isdst 0, and
                   strftime takes %Z from tzname[0] without a tm_zone and
                   %z from timezone -- the standard name and offset) */
                int64_t dstoff;
                ztm.isdst = mytm.tm_isdst;
                ztm.zone = tzc_settzname(zone->u.tzc, &ztm.gmtoff, &dstoff);
            } else {
                ztm.zone = "";
            }
        }
#if defined(SYS_TM_ZONE)
        mytm.tm_gmtoff = (long)ztm.gmtoff;
        mytm.tm_zone = (char*)ztm.zone;
#endif
    } else {
        (void)mktime(&mytm);
    }

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

    /* port: %Z (and, without the struct tm fields for it, %z) of the zone
     * object, which the C library cannot know (glibc would also take an
     * empty tm_zone for the process's own zone name) */
    if (zone != NULL) {
        if (zone->flavor == ZF_CRT) {
            /* (both as the UCRT's wcsftime writes them, on every platform:
               another C library would read tm_isdst -1 its own way) */
            zfmt = zone_format(fmt, &ztm, 1, 1, 1);
        } else if (zone->flavor == ZF_TZCODE) {
            /* (both as macOS's strftime writes them, on every platform:
               %Z the tm_zone, %z under __DARWIN_UNIX03 not tm_gmtoff but
               timezone or altzone by tm_isdst -- of the zone object here,
               as they are of the TZ Perl has set there) */
            ZTm zz = ztm;
            int64_t stdoff, dstoff;
            (void)tzc_settzname(zone->u.tzc, &stdoff, &dstoff);
            zz.gmtoff = ztm.isdst > 0 ? dstoff : stdoff;
            zfmt = zone_format(fmt, &zz, 1, 1, 0);
        } else {
#if defined(SYS_TM_ZONE)
            zfmt = *ztm.zone == '\0' ? zone_format(fmt, &ztm, 1, 0, 0) : NULL;
#elif defined(_WIN32)
            zfmt = zone_format(fmt, &ztm, 1, 1, 1);
#else
            zfmt = zone_format(fmt, &ztm, 1, 1, 0);
#endif
        }
        if (zfmt != NULL) {
            fmt = zfmt;
            fmtlen = strlen(fmt);
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
    free(zfmt);
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
 * The decimal point of the calling thread's current LC_NUMERIC locale
 * (port: Perl keeps LC_NUMERIC at "C" outside `use locale`, so its numbers
 * always print with '.'; Lua's number formatting follows the current
 * locale, which an embedding host may have set. The facade replaces this
 * string with '.' -- it only reads the locale, never sets it). May be more
 * than one byte.
 * Thread safety: glibc's localeconv() fills one static struct on every call
 * (MT-Unsafe race:localeconv), so POSIX systems read the radix character
 * with nl_langinfo, which only returns a pointer into the locale's data
 * (the thread's locale after a uselocale, as for snprintf). The Windows
 * C runtime's localeconv() only returns the current locale's own lconv
 * (per thread with _configthreadlocale) and writes nothing.
 */
static int sys_decimal_point(lua_State* L) {
#if defined(_WIN32)
    const struct lconv* lc = localeconv();
    const char* dp = (lc && lc->decimal_point) ? lc->decimal_point : NULL;
#else
    const char* dp = nl_langinfo(RADIXCHAR);
#endif
    lua_pushstring(L, (dp != NULL && dp[0] != '\0') ? dp : ".");
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

/* closef method of the stdio handles sys.fdopen returns (the io library's
 * own close function is static, so a handle made here needs this one) */
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

/*------------------------------------------------------------------------------
 * Perl's open FH, "<&=FD" (also ">&=", ">>&=", "+<&=" -- the C mode "rb",
 * "wb", "ab", "r+b"): a Lua file (the "FILE*" metatable, so io.read/write/
 * seek/close/lines work on it) for an existing file descriptor, through
 * fdopen (_fdopen on Windows, the descriptor switched to binary mode). An
 * append stream starts at the end of the file. Returns the file, or nil
 * plus the error.
 */
static int sys_fdopen(lua_State* L) {
    int fd = (int)luaL_checkinteger(L, 1);
    const char* mode = luaL_checkstring(L, 2);
    /* the userdata first, closed (closef NULL), as liolib's newprefile */
    luaL_Stream* p = (luaL_Stream*)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
    p->f = NULL;
    p->closef = NULL;
    luaL_setmetatable(L, LUA_FILEHANDLE);
#if defined(_WIN32)
    _setmode(fd, _O_BINARY);
    p->f = _fdopen(fd, mode);
#else
    p->f = fdopen(fd, mode);
#endif
    if (!p->f) return push_error(L, errno);
    p->closef = &sys_fclose_file;
    if (mode[0] == 'a') fseek(p->f, 0, SEEK_END);
    return 1;
}

#if defined(_WIN32)
/*------------------------------------------------------------------------------
 * The Win32API::File calls of ExifTool::Open and ExifTool::Exists:
 * CreateFileW($file, $access, $share, [], $create, $flags, []) with the
 * caller's access, share and creation values (arguments 4 and 7, the
 * security attributes and the template, are ignored: NULL as upstream's
 * []); the name is UTF-8 and widened here. Returns the handle (a light
 * userdata), or nil plus the error and the Win32 error code -- Perl's false
 * result.
 */
static int sys_create_file(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    DWORD access = (DWORD)luaL_checkinteger(L, 2);
    DWORD share = (DWORD)luaL_checkinteger(L, 3);
    DWORD create = (DWORD)luaL_checkinteger(L, 5);
    DWORD flags = (DWORD)luaL_optinteger(L, 6, 0);
    wchar_t* wpath = wide_from_utf8(path);
    HANDLE wh;
    DWORD e;
    if (!wpath) return push_error(L, ENOMEM);
    wh = CreateFileW(wpath, access, share, NULL, create, flags, NULL);
    e = GetLastError();
    free(wpath);
    if (wh == INVALID_HANDLE_VALUE) return push_winerror(L, e);
    lua_pushlightuserdata(L, (void*)wh);
    return 1;
}

/* OsFHandleOpenFd($wh, $mode): a C run-time file descriptor for a Win32
 * handle (_open_osfhandle with the caller's flags), or -1 */
static int sys_os_fhandle_open_fd(lua_State* L) {
    HANDLE wh;
    int flags = (int)luaL_optinteger(L, 2, 0);
    luaL_argcheck(L, lua_islightuserdata(L, 1), 1, "handle expected");
    wh = (HANDLE)lua_touserdata(L, 1);
    lua_pushinteger(L, (lua_Integer)_open_osfhandle((intptr_t)wh, flags));
    return 1;
}

/* CloseHandle($wh): true on success */
static int sys_close_handle(lua_State* L) {
    luaL_argcheck(L, lua_islightuserdata(L, 1), 1, "handle expected");
    lua_pushboolean(L, CloseHandle((HANDLE)lua_touserdata(L, 1)) != 0);
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
 * utime ATIME, MTIME, FILEHANDLE -- Perl's futimes form of utime: sets the
 * access and modification times of an open Lua file (after flushing its
 * stdio buffer, so pending writes do not stamp the file again afterwards).
 * The times are Unix seconds; as in Perl's doio.c, only their integer
 * part counts (SvIV, truncated toward zero; the microseconds of Perl's
 * timeval are 0 -- sub-second times are Time::HiRes::utime's).  Both nil:
 * the current time, as Perl's utime(undef, undef, FH).  POSIX: futimens on
 * the descriptor; Windows: SetFileTime on its handle (_get_osfhandle),
 * with the times as FILETIMEs, the creation time left unchanged.  Returns true, or nil plus the error text and code (errno; on
 * Windows the Win32 error code of SetFileTime).
 */
static int sys_futimes(lua_State* L) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    int now = lua_isnoneornil(L, 2) && lua_isnoneornil(L, 3);
    lua_Number na = now ? 0 : luaL_optnumber(L, 2, 0);
    lua_Number nm = now ? 0 : luaL_optnumber(L, 3, 0);
    long long sec[2];
    sec[0] = (long long)na;
    sec[1] = (long long)nm;
    /* (a closed file: Perl's utime finds no IoIFP and counts EBADF) */
    if (p->closef == NULL || p->f == NULL) return push_error(L, EBADF);
    if (fflush(p->f) != 0) return push_error(L, errno);
#if defined(_WIN32)
    {
        HANDLE h = (HANDLE)_get_osfhandle(_fileno(p->f));
        FILETIME ft[2];
        int i;
        if (h == INVALID_HANDLE_VALUE) return push_error(L, EBADF);
        if (now) {
            GetSystemTimeAsFileTime(&ft[0]);
            ft[1] = ft[0];
        } else {
            for (i = 0; i < 2; ++i) {
                /* 100 ns intervals since 0:00 UTC Jan 1, 1601 */
                long long t = (sec[i] + 11644473600LL) * 10000000LL;
                if (t < 0) return push_error(L, EINVAL);
                ft[i].dwLowDateTime = (DWORD)((unsigned long long)t & 0xFFFFFFFFULL);
                ft[i].dwHighDateTime = (DWORD)((unsigned long long)t >> 32);
            }
        }
        if (!SetFileTime(h, NULL, &ft[0], &ft[1])) return push_winerror(L, GetLastError());
    }
#else
    {
        struct timespec ts[2];
        int i;
        for (i = 0; i < 2; ++i) {
            ts[i].tv_sec = (time_t)sec[i];
            ts[i].tv_nsec = now ? UTIME_NOW : 0;
        }
        if (futimens(fileno(p->f), ts) != 0) return push_error(L, errno);
    }
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
 * stat FILEHANDLE: the fields of Perl's stat list for an open file (fstat),
 * as a table: dev, ino, mode (the whole st_mode), nlink, uid, gid, rdev,
 * size, atime, mtime, ctime and, POSIX only, blksize and blocks (Perl's are
 * '' on Windows).  ExtractInfo stats the handle it reads, which for `-` is
 * the redirected file or the pipe behind STDIN.  nil plus the error text
 * if the call fails.
 */
static void set_int_field(lua_State* L, const char* k, lua_Integer v) {
    lua_pushinteger(L, v);
    lua_setfield(L, -2, k);
}

#if defined(_WIN32)
/* Perl's win32_fstat derives the mode from the handle rather than taking
 * the CRT's: a pipe is a FIFO and a character device a char special file,
 * both readable and writable by all (prw-rw-rw-), and a disk file is
 * executable when its name ends in .exe, .bat, .cmd or .com -- what the
 * CRT's _stat does for a path, which _fstat64 cannot know.  The file name
 * comes from GetFinalPathNameByHandleW (kernel32, Windows Vista and later),
 * called directly; headers that target an older Windows (_WIN32_WINNT below
 * 0x0600, as older MinGW-w64 defaults to) do not declare it, so it is
 * declared here with the signature of <fileapi.h>. */
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0600
WINBASEAPI DWORD WINAPI GetFinalPathNameByHandleW(HANDLE hFile, LPWSTR lpszFilePath,
                                                  DWORD cchFilePath, DWORD dwFlags);
#endif
static int win_exe_name(HANDLE h) {
    wchar_t buf[MAX_PATH + 1];
    DWORD n = GetFinalPathNameByHandleW(h, buf, MAX_PATH, 0);
    if (n < 4 || n > MAX_PATH) return 0;
    return _wcsicmp(buf + n - 4, L".exe") == 0 || _wcsicmp(buf + n - 4, L".bat") == 0 ||
           _wcsicmp(buf + n - 4, L".cmd") == 0 || _wcsicmp(buf + n - 4, L".com") == 0;
}
static unsigned win_fstat_mode(int fd, unsigned mode) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    const unsigned rw = _S_IREAD | _S_IWRITE;
    const unsigned all = rw | (rw >> 3) | (rw >> 6);
    if (h == INVALID_HANDLE_VALUE) return mode;
    switch (GetFileType(h)) {
    case FILE_TYPE_PIPE: return _S_IFIFO | all;
    case FILE_TYPE_CHAR: return _S_IFCHR | all;
    case FILE_TYPE_DISK:
        if ((mode & _S_IFMT) == _S_IFREG && win_exe_name(h))
            mode |= _S_IEXEC | (_S_IEXEC >> 3) | (_S_IEXEC >> 6);
        return mode;
    default: return mode;
    }
}
#endif

/* the table of stat/fstat from a struct stat (_stat64 on Windows), its mode
 * given apart (on Windows win_fstat_mode for a handle) */
#if defined(_WIN32)
typedef struct _stat64 SysStat;
#else
typedef struct stat SysStat;
#endif
static void push_stat_table(lua_State* L, const SysStat* st, lua_Integer mode) {
    lua_createtable(L, 0, 13);
    set_int_field(L, "dev", (lua_Integer)st->st_dev);
    set_int_field(L, "ino", (lua_Integer)st->st_ino);
    set_int_field(L, "mode", mode);
    set_int_field(L, "nlink", (lua_Integer)st->st_nlink);
    set_int_field(L, "uid", (lua_Integer)st->st_uid);
    set_int_field(L, "gid", (lua_Integer)st->st_gid);
    set_int_field(L, "rdev", (lua_Integer)st->st_rdev);
    set_int_field(L, "size", (lua_Integer)st->st_size);
    set_int_field(L, "atime", (lua_Integer)st->st_atime);
    set_int_field(L, "mtime", (lua_Integer)st->st_mtime);
    set_int_field(L, "ctime", (lua_Integer)st->st_ctime);
#if !defined(_WIN32)
    set_int_field(L, "blksize", (lua_Integer)st->st_blksize);
    set_int_field(L, "blocks", (lua_Integer)st->st_blocks);
#endif
}

static int sys_fstat(lua_State* L) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
    if (p->closef == NULL) return luaL_error(L, "attempt to use a closed file");
#if defined(_WIN32)
    {
        struct _stat64 st;
        if (_fstat64(_fileno(p->f), &st) != 0) return push_error(L, errno);
        push_stat_table(L, &st, (lua_Integer)win_fstat_mode(_fileno(p->f), st.st_mode));
    }
#else
    {
        struct stat st;
        if (fstat(fileno(p->f), &st) != 0) return push_error(L, errno);
        push_stat_table(L, &st, (lua_Integer)st.st_mode);
    }
#endif
    return 1;
}

/* stat PATH: the same table for a file name (stat(2), following symbolic
 * links; on Windows the CRT's _stat64 of the narrow name, as Perl's stat
 * and luafilesystem's attributes take it). Port: in place of
 * lfs.attributes(path), whose "permissions" string is built in a static
 * buffer of luafilesystem -- not thread-safe, and the numeric mode is what
 * Perl's stat gives anyway. nil plus the error text if the call fails. */
static int sys_stat(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    SysStat st;
#if defined(_WIN32)
    if (_stat64(path, &st) != 0) return push_error(L, errno);
#else
    if (stat(path, &st) != 0) return push_error(L, errno);
#endif
    push_stat_table(L, &st, (lua_Integer)st.st_mode);
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

/* The module's only writable static variables (doc/conventions.md §12):
 * process-wide like the dispositions they serve, and touched only by a Lua
 * state that has called nosignals(false) -- signal() of any other state
 * returns before them. */
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
 * pointed at this Lua state. True by default (set by luaopen_lexiftool_sys
 * below) -- a Lua state this module is loaded into must not take over the
 * host's Ctrl-C, or leave a closed Lua state behind in sigState, unless it
 * is explicitly told it owns the process (the two command-line launchers,
 * `lexiftool` and standalone/launcher.lua, switch it off before loading
 * lexiftool.main so the running CLI process installs real handlers, as
 * upstream does; doc/capi.md's sessions keep the default). The switch is a
 * registry field, so it is per Lua state; it must be set before the first
 * signal() (main.lua sets $SIG{INT}/$SIG{CONT} when it is loaded). Returns
 * the setting before the call; without an argument only reads it. The
 * registry field "lexiftool.sys.nosignals" may also be set from C before
 * this module is loaded (that value is kept, see luaopen below). */
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
 * The saved mode and the pending bytes of peekchar below (the XS's static
 * filehash entry and event buffer) are kept per Lua state, in a userdata
 * of the registry, rather than in static variables of the module.
 */
typedef struct {
    int saved;          /* (the XS's filehash entry for STDIN) */
    DWORD savebuf;
    int eventCount;     /* (the XS's eventCount/events of Win32PeekChar) */
    struct { int repeatCount; int ascii; } events[4];
} ReadKeyState;

static const char* const READKEY_KEY = "lexiftool.sys.readkey";

/* this Lua state's ReadKeyState, created zeroed on first use (the registry
 * keeps the userdata alive, and it does not move) */
static ReadKeyState* readkey_state(lua_State* L) {
    ReadKeyState* ks;
    if (lua_getfield(L, LUA_REGISTRYINDEX, READKEY_KEY) == LUA_TUSERDATA) {
        ks = (ReadKeyState*)lua_touserdata(L, -1);
    } else {
        lua_pop(L, 1);
        ks = (ReadKeyState*)lua_newuserdatauv(L, sizeof(ReadKeyState), 0);
        memset(ks, 0, sizeof(ReadKeyState));
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, READKEY_KEY);
    }
    lua_pop(L, 1);
    return ks;
}

static int sys_readmode(lua_State* L) {
    int mode = (int)luaL_checkinteger(L, 1);
    ReadKeyState* ks = readkey_state(L);
    HANDLE whnd = (HANDLE)_get_osfhandle(_fileno(stdin));
    DWORD work;
    int firsttime = !ks->saved;
    if (!GetConsoleMode(whnd, &work)) {
        lua_pushnil(L);
        lua_pushfstring(L, "GetConsoleMode failed, LastError=|%d|", (int)GetLastError());
        return 2;
    }
    if (firsttime) {
        ks->savebuf = work;
        ks->saved = 1;
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
            work = ks->savebuf;
            firsttime = 1;
            break;
    }
    if (!SetConsoleMode(whnd, work)) {
        lua_pushnil(L);
        lua_pushfstring(L, "SetConsoleMode failed, LastError=|%d|", (int)GetLastError());
        return 2;
    }
    if (firsttime) ks->saved = 0;  /* (mode 0 forgets the saved mode) */
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
#define KEY_PUSH(I, K) { ks->events[I].repeatCount = 1; ks->events[I].ascii = K; }
#define KEY_PUSH3(K1, K2, K3) \
    do { KEY_PUSH(2, K1); KEY_PUSH(1, K2); KEY_PUSH(0, K3); \
         ks->eventCount = 3; goto again; } while (0)
#define KEY_PUSH4(K1, K2, K3, K4) \
    do { KEY_PUSH(3, K1); KEY_PUSH(2, K2); KEY_PUSH(1, K3); KEY_PUSH(0, K4); \
         ks->eventCount = 4; goto again; } while (0)
static int sys_peekchar(lua_State* L) {
    ReadKeyState* ks = readkey_state(L);
    HANDLE whnd = (HANDLE)_get_osfhandle(_fileno(stdin));
    INPUT_RECORD record;
    DWORD readRecords;
    int keyCount;
    char key;
again:
    if (ks->eventCount) {
        key = (char)ks->events[ks->eventCount - 1].ascii;
        ks->events[ks->eventCount - 1].repeatCount--;
        if (ks->events[ks->eventCount - 1].repeatCount <= 0) ks->eventCount--;
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
        ks->events[0].repeatCount = keyCount;
        ks->events[0].ascii = key;
        ks->eventCount = 1;
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
 * own builtins) already consults. The reentrant _r variants, so that no
 * static buffer of the C library is shared with another thread: the
 * buffer starts at sysconf(_SC_GETPW_R_SIZE_MAX/_SC_GETGR_R_SIZE_MAX) (1024
 * where that is indeterminate) and doubles on ERANGE; it is a userdata, so
 * the collector frees it whatever happens. Same results as getpwuid and
 * the others. Windows has no POSIX user/group database and Perl does not
 * implement these there either (the port's callers already expect nil,
 * see perl.lua).
 */
#define R_BUFFER_MAX ((size_t)1 << 24)
static char* r_buffer(lua_State* L, int sizeName, size_t* size) {
    long n = sysconf(sizeName);
    *size = n > 0 ? (size_t)n : 1024;
    return (char*)lua_newuserdatauv(L, *size, 0);
}
static char* r_grow(lua_State* L, size_t* size) {
    lua_pop(L, 1);
    *size *= 2;
    return (char*)lua_newuserdatauv(L, *size, 0);
}
static int sys_getpwuid(lua_State* L) {
    uid_t uid = (uid_t)luaL_checkinteger(L, 1);
    struct passwd pwd, *pw = NULL;
    size_t size;
    char* buf = r_buffer(L, _SC_GETPW_R_SIZE_MAX, &size);
    int rc;
    while ((rc = getpwuid_r(uid, &pwd, buf, size, &pw)) == ERANGE && size < R_BUFFER_MAX)
        buf = r_grow(L, &size);
    if (rc != 0 || pw == NULL) return 0;
    lua_pushstring(L, pw->pw_name);
    return 1;
}
static int sys_getpwnam(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    struct passwd pwd, *pw = NULL;
    size_t size;
    char* buf = r_buffer(L, _SC_GETPW_R_SIZE_MAX, &size);
    int rc;
    while ((rc = getpwnam_r(name, &pwd, buf, size, &pw)) == ERANGE && size < R_BUFFER_MAX)
        buf = r_grow(L, &size);
    if (rc != 0 || pw == NULL) return 0;
    lua_pushinteger(L, (lua_Integer)pw->pw_uid);
    return 1;
}
static int sys_getgrgid(lua_State* L) {
    gid_t gid = (gid_t)luaL_checkinteger(L, 1);
    struct group grp, *gr = NULL;
    size_t size;
    char* buf = r_buffer(L, _SC_GETGR_R_SIZE_MAX, &size);
    int rc;
    while ((rc = getgrgid_r(gid, &grp, buf, size, &gr)) == ERANGE && size < R_BUFFER_MAX)
        buf = r_grow(L, &size);
    if (rc != 0 || gr == NULL) return 0;
    lua_pushstring(L, gr->gr_name);
    return 1;
}
static int sys_getgrnam(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    struct group grp, *gr = NULL;
    size_t size;
    char* buf = r_buffer(L, _SC_GETGR_R_SIZE_MAX, &size);
    int rc;
    while ((rc = getgrnam_r(name, &grp, buf, size, &gr)) == ERANGE && size < R_BUFFER_MAX)
        buf = r_grow(L, &size);
    if (rc != 0 || gr == NULL) return 0;
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
    struct statx stx;
    int rc;
    if (lua_type(L, 1) == LUA_TSTRING) {
        rc = LX_STATX(AT_FDCWD, lua_tostring(L, 1), 0, STATX_BTIME, &stx);
    } else {
        /* File::StatX::fstatx on an open file */
        luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, 1, LUA_FILEHANDLE);
        if (p->closef == NULL) return luaL_error(L, "attempt to use a closed file");
        rc = LX_STATX(fileno(p->f), "", AT_EMPTY_PATH, STATX_BTIME, &stx);
    }
    if (rc != 0) {
        lua_pushnil(L);
        push_strerror(L, errno);
        return 2;
    }
    if (!(stx.stx_mask & STATX_BTIME) || stx.stx_btime.tv_sec == 0) {
        lua_pushnil(L);
        return 1;
    }
    /* seconds with the fraction, as the module's btime: a number like
     * 1700000000.83793, which ConvertUnixTime rounds to the second */
    lua_pushnumber(L, (lua_Number)stx.stx_btime.tv_sec +
                      (lua_Number)stx.stx_btime.tv_nsec / 1e9);
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

/* fpe_test(): test and clear the floating-point exception flags "division
 * by zero" and "invalid" (returns two booleans).  fpe_raise(div, inv) sets
 * them again.  Perl's `/` dies "Illegal division by zero" where C's gives
 * Inf or NaN; Lua's `/` on two numbers reaches no metamethod, so the perl
 * facade reads the flags around a conversion (perl.evalcall) instead. */
static int sys_fpe_test(lua_State* L) {
    int f = fetestexcept(FE_DIVBYZERO | FE_INVALID);
    if (f) feclearexcept(FE_DIVBYZERO | FE_INVALID);
    lua_pushboolean(L, (f & FE_DIVBYZERO) != 0);
    lua_pushboolean(L, (f & FE_INVALID) != 0);
    return 2;
}

static int sys_fpe_raise(lua_State* L) {
    int f = 0;
    if (lua_toboolean(L, 1)) f |= FE_DIVBYZERO;
    if (lua_toboolean(L, 2)) f |= FE_INVALID;
    if (f) feraiseexcept(f);
    return 0;
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

/* Win32API::File::GetOsFHandle: the Win32 handle behind a Lua file (after
 * flushing its stdio buffer, so pending writes do not land after a time set
 * through the handle). INVALID_HANDLE_VALUE for a closed file. */
static HANDLE os_fhandle(lua_State* L, int idx) {
    luaL_Stream* p = (luaL_Stream*)luaL_checkudata(L, idx, LUA_FILEHANDLE);
    if (p->closef == NULL || p->f == NULL) return INVALID_HANDLE_VALUE;
    fflush(p->f);
    return (HANDLE)_get_osfhandle(_fileno(p->f));
}

/* A FILETIME struct as `pack 'LL', low, high` (8 bytes) */
static void push_filetime(lua_State* L, const FILETIME* ft) {
    unsigned char b[8];
    DWORD lo = ft->dwLowDateTime, hi = ft->dwHighDateTime;
    int i;
    for (i = 0; i < 4; ++i) {
        b[i] = (unsigned char)(lo >> (8 * i));
        b[i + 4] = (unsigned char)(hi >> (8 * i));
    }
    lua_pushlstring(L, (const char*)b, 8);
}

/* The Win32::API GetFileTime call of ExifTool::GetFileTime (the daylight
 * savings time workaround): GetFileTime on the handle of an open Lua file.
 * Returns true and the FILETIME structs in the API's order (creation,
 * access, modification), each packed like `pack 'LL', low, high` -- the
 * buffers upstream's Call fills and then unpacks. nil plus the error
 * otherwise; the third value is the Win32 error code
 * (Win32::GetLastError()), 0 for an invalid handle. */
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
    lua_pushboolean(L, 1);
    push_filetime(L, &c);
    push_filetime(L, &a);
    push_filetime(L, &m);
    return 4;
}

/* The Win32::API SetFileTime call of ExifTool::SetFileTime: SetFileTime on
 * the handle of an open Lua file, with the arguments in the API's order
 * (creation, access, modification).  Each time is a FILETIME struct packed
 * by the caller (`pack 'LL', low, high`, 8 bytes), or 0 for NULL (do not
 * change).  Returns true, or nil plus the error and the Win32 error code. */
static int sys_set_file_time(lua_State* L) {
    HANDLE h = os_fhandle(L, 1);
    FILETIME ft[3];
    FILETIME* pt[3] = { NULL, NULL, NULL };
    int i;
    for (i = 0; i < 3; ++i) {
        size_t len;
        const char* s;
        if (lua_type(L, i + 2) != LUA_TSTRING) continue;  /* NULL */
        s = lua_tolstring(L, i + 2, &len);
        if (len != 8) return luaL_argerror(L, i + 2, "FILETIME struct expected");
        ft[i].dwLowDateTime = (DWORD)((unsigned char)s[0] | (unsigned char)s[1] << 8 |
                                      (unsigned char)s[2] << 16 | (DWORD)(unsigned char)s[3] << 24);
        ft[i].dwHighDateTime = (DWORD)((unsigned char)s[4] | (unsigned char)s[5] << 8 |
                                       (unsigned char)s[6] << 16 | (DWORD)(unsigned char)s[7] << 24);
        pt[i] = &ft[i];
    }
    if (h == INVALID_HANDLE_VALUE) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid handle");
        lua_pushinteger(L, 0);
        return 3;
    }
    if (!SetFileTime(h, pt[0], pt[1], pt[2])) return push_winerror(L, GetLastError());
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
    { "tz_new",         sys_tz_new },
    { "tz_localtime",   sys_tz_localtime },
    /* strftime: a closure over its locale object, see luaopen below */
    { "decimal_point",  sys_decimal_point },
    { "strless",        sys_strless },
    { "strcmp",         sys_strcmp },
    { "chmod",          sys_chmod },
    { "chown",          sys_chown },
    { "mkdir",          sys_mkdir },
    { "rename",         sys_rename },
    { "unlink",         sys_unlink },
    { "fdopen",         sys_fdopen },
#if defined(_WIN32)
    { "create_file",        sys_create_file },
    { "os_fhandle_open_fd", sys_os_fhandle_open_fd },
    { "close_handle",       sys_close_handle },
#endif
    { "ftruncate",      sys_ftruncate },
    { "futimes",        sys_futimes },
    { "isreg",          sys_isreg },
    { "fstat",          sys_fstat },
    { "stat",           sys_stat },
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
    { "fpe_test",       sys_fpe_test },
    { "fpe_raise",      sys_fpe_raise },
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
    /* nosignals default: true (record only), unless a C host already set
     * the registry field before loading this module (see sys_nosignals). */
    if (lua_getfield(L, LUA_REGISTRYINDEX, NOSIGNALS_KEY) == LUA_TNIL) {
        lua_pushboolean(L, 1);
        lua_setfield(L, LUA_REGISTRYINDEX, NOSIGNALS_KEY);
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
