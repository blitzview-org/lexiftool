/*
 * ctime_fake_darwin.c -- DYLD interposer for the CLI comparison harness.
 *
 * Same purpose as ctime_fake.c on Linux: exiftool reports the inode change
 * time (st_ctime) as "File Inode Change Date/Time", and that value is stamped
 * to the wall clock at copy time. macOS has no API to set it, so the harness
 * makes every stat() see a fixed value instead.
 *
 * This cannot be an LD_PRELOAD shim: macOS uses DYLD_INSERT_LIBRARIES and dyld
 * interposition (__DATA,__interpose). It also cannot be injected into the
 * system Perl or /usr/bin/stat, because SIP strips DYLD_* for Apple-signed
 * binaries. The harness therefore runs a Homebrew Perl (and Lua) and pins the
 * birth time itself through lexiftool.sys's set_times()/setattrlist(), which
 * /usr/bin/stat then reports unchanged.
 *
 * The replacements call the originals by name: dyld rewrites the references
 * of every OTHER image to point at the replacements, while the interposing
 * image's own calls still reach libsystem. So there is no dlsym(RTLD_NEXT),
 * no constructor and no state -- nothing that could run while dyld is still
 * binding the process (which is what crashed an earlier version of this shim
 * during startup).
 *
 * Build: cc -dynamiclib -o ctime_fake.so ctime_fake_darwin.c
 */

#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

/* 2099-01-01 00:00:00 UTC. The harness runs with TZ=UTC, so this is the same
 * instant the Linux shim gets from mktime() of that civil time. */
#define FIXED_CTIME ((time_t)4070908800)

static void fix_stat(struct stat *s) {
    if (!s) return;
    s->st_ctimespec.tv_sec = FIXED_CTIME;
    s->st_ctimespec.tv_nsec = 0;
}

#define INTERPOSE(replacement, replacee)                                    \
    __attribute__((used)) static struct {                                   \
        const void *replacement;                                            \
        const void *replacee;                                               \
    } _interpose_##replacee                                                 \
    __attribute__((section("__DATA,__interpose"))) = {                      \
        (const void *)(unsigned long)&replacement,                          \
        (const void *)(unsigned long)&replacee                              \
    }

static int my_stat(const char *p, struct stat *b) {
    int r = stat(p, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_lstat(const char *p, struct stat *b) {
    int r = lstat(p, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_fstat(int fd, struct stat *b) {
    int r = fstat(fd, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_fstatat(int dfd, const char *p, struct stat *b, int f) {
    int r = fstatat(dfd, p, b, f);
    if (r == 0) fix_stat(b);
    return r;
}

INTERPOSE(my_stat, stat);
INTERPOSE(my_lstat, lstat);
INTERPOSE(my_fstat, fstat);
INTERPOSE(my_fstatat, fstatat);

/* The non-INODE64 symbols are what <sys/stat.h> maps to on modern macOS; the
 * INODE64 spellings are the actual libsystem entry points used by Perl's
 * pp_stat and by C code compiled with _DARWIN_USE_64_BIT_INODE. Interpose both
 * so it does not matter which one a caller links against. The INODE64 variants
 * exist only on the Intel architectures; arm64 links the plain symbols. */
#if defined(__x86_64__) || defined(__i386__)
extern int stat_inode64(const char *, struct stat *) __asm("_stat$INODE64");
extern int lstat_inode64(const char *, struct stat *) __asm("_lstat$INODE64");
extern int fstat_inode64(int, struct stat *) __asm("_fstat$INODE64");
extern int fstatat_inode64(int, const char *, struct stat *, int)
    __asm("_fstatat$INODE64");

static int my_stat_inode64(const char *p, struct stat *b) {
    int r = stat_inode64(p, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_lstat_inode64(const char *p, struct stat *b) {
    int r = lstat_inode64(p, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_fstat_inode64(int fd, struct stat *b) {
    int r = fstat_inode64(fd, b);
    if (r == 0) fix_stat(b);
    return r;
}
static int my_fstatat_inode64(int dfd, const char *p, struct stat *b, int f) {
    int r = fstatat_inode64(dfd, p, b, f);
    if (r == 0) fix_stat(b);
    return r;
}

INTERPOSE(my_stat_inode64, stat_inode64);
INTERPOSE(my_lstat_inode64, lstat_inode64);
INTERPOSE(my_fstat_inode64, fstat_inode64);
INTERPOSE(my_fstatat_inode64, fstatat_inode64);
#endif
