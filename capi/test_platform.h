/*------------------------------------------------------------------------------
 * File:         capi/test_platform.h
 *
 * Description:  The few operating-system services the C API's test
 *               programs need, for Linux, macOS and Windows (MSVC and
 *               MinGW): threads (POSIX threads, or _beginthreadex), the
 *               sorted regular files of a directory, mkdir, copying a
 *               file, binary stdout, the disposition of SIGINT. Included
 *               first, before any system header: it also sets the feature
 *               macros (_GNU_SOURCE on Linux, _DARWIN_C_SOURCE on macOS;
 *               C99 printf formats such as %zu with MinGW, no deprecation
 *               warnings for the POSIX names with MSVC).
 *               Test code only; the library does not use it.
 *------------------------------------------------------------------------------
 */

#ifndef LEXIFTOOL_TEST_PLATFORM_H
#define LEXIFTOOL_TEST_PLATFORM_H

#if defined(_WIN32)
#  ifndef __USE_MINGW_ANSI_STDIO
#    define __USE_MINGW_ANSI_STDIO 1
#  endif
#  ifndef _CRT_SECURE_NO_WARNINGS
#    define _CRT_SECURE_NO_WARNINGS
#  endif
#  ifndef _CRT_NONSTDC_NO_DEPRECATE
#    define _CRT_NONSTDC_NO_DEPRECATE
#  endif
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#elif defined(__APPLE__)
#  ifndef _DARWIN_C_SOURCE
#    define _DARWIN_C_SOURCE
#  endif
#else
#  ifndef _GNU_SOURCE
#    define _GNU_SOURCE
#  endif
#endif

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <windows.h>
#  include <direct.h>
#  include <fcntl.h>
#  include <io.h>
#  include <process.h>
#else
#  include <dirent.h>
#  include <pthread.h>
#  include <sys/stat.h>
#  include <sys/types.h>
#endif

#if defined(__GNUC__)
#  define TP_UNUSED __attribute__((unused))
#else
#  define TP_UNUSED
#endif

/* ---------------------------------------------------------------------------
 * Threads: tp_thread_start(&t, fn, arg) runs fn(arg) in a new thread (0 on
 * success), tp_thread_join(t) waits for it
 */

#if defined(_WIN32)
typedef HANDLE tp_thread;
typedef struct { void* (*fn)(void*); void* arg; } tp_start_arg;

static unsigned __stdcall tp_trampoline(void* p)
{
    tp_start_arg a = *(tp_start_arg*)p;
    free(p);
    a.fn(a.arg);
    return 0;
}

static TP_UNUSED int tp_thread_start(tp_thread* t, void* (*fn)(void*), void* arg)
{
    tp_start_arg* a = malloc(sizeof(*a));
    if (a == NULL) return -1;
    a->fn = fn;
    a->arg = arg;
    *t = (HANDLE)_beginthreadex(NULL, 0, tp_trampoline, a, 0, NULL);
    if (*t == NULL) { free(a); return -1; }
    return 0;
}

static TP_UNUSED void tp_thread_join(tp_thread t)
{
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
}
#else
typedef pthread_t tp_thread;

static TP_UNUSED int tp_thread_start(tp_thread* t, void* (*fn)(void*), void* arg)
{
    return pthread_create(t, NULL, fn, arg);
}

static TP_UNUSED void tp_thread_join(tp_thread t)
{
    pthread_join(t, NULL);
}
#endif

/* ---------------------------------------------------------------------------
 * Files
 */

static int tp_cmpstr(const void* a, const void* b)
{
    return strcmp(*(char* const*)a, *(char* const*)b);
}

/* adds a copy of name to the list v (n entries, room for *cap) */
static char** tp_push(char** v, int* n, int* cap, const char* name)
{
    if (*n == *cap) {
        char** p = realloc(v, (size_t)(*cap = *cap ? *cap * 2 : 256) * sizeof(*v));
        if (p == NULL) return v;
        v = p;
    }
    v[(*n)++] = strdup(name);
    return v;
}

/* the sorted names of the regular files in dir (malloc'd, as the list);
 * NULL if dir cannot be read */
static TP_UNUSED char** tp_list_files(const char* dir, int* count)
{
    char** v = NULL;
    int n = 0, cap = 0;
#if defined(_WIN32)
    WIN32_FIND_DATAA e;
    char pattern[2048];
    HANDLE h;
    snprintf(pattern, sizeof(pattern), "%s\\*", dir);
    if ((h = FindFirstFileA(pattern, &e)) == INVALID_HANDLE_VALUE) return NULL;
    do {
        if (!(e.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)))
            v = tp_push(v, &n, &cap, e.cFileName);
    } while (FindNextFileA(h, &e));
    FindClose(h);
#else
    DIR* d = opendir(dir);
    struct dirent* e;
    if (d == NULL) return NULL;
    while ((e = readdir(d)) != NULL) {
        char path[2048];
        struct stat st;
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        v = tp_push(v, &n, &cap, e->d_name);
    }
    closedir(d);
#endif
    if (n > 0) qsort(v, (size_t)n, sizeof(*v), tp_cmpstr);
    *count = n;
    return v;
}

/* creates a directory (an existing one is fine) */
static TP_UNUSED int tp_mkdir(const char* dir)
{
#if defined(_WIN32)
    return _mkdir(dir);
#else
    return mkdir(dir, 0777);
#endif
}

static TP_UNUSED int tp_copy_file(const char* from, const char* to)
{
    FILE* in = fopen(from, "rb"), *out = fopen(to, "wb");
    char tmp[65536];
    size_t n;
    int good = in != NULL && out != NULL;
    while (good && (n = fread(tmp, 1, sizeof(tmp), in)) > 0)
        good = fwrite(tmp, 1, n, out) == n;
    if (in) fclose(in);
    if (out) fclose(out);
    return good;
}

/* opens a file by its UTF-8 name (Windows: through the wide API, so that a
 * name outside the ANSI code page works) */
static TP_UNUSED FILE* tp_fopen_utf8(const char* name, const char* mode)
{
#if defined(_WIN32)
    wchar_t wname[1024], wmode[16];
    if (MultiByteToWideChar(CP_UTF8, 0, name, -1, wname, 1024) == 0 ||
        MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode, 16) == 0) return NULL;
    return _wfopen(wname, wmode);
#else
    return fopen(name, mode);
#endif
}

/* stdout without newline translation (Windows; a no-op elsewhere) */
static TP_UNUSED void tp_binary_stdout(void)
{
#if defined(_WIN32)
    fflush(stdout);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
}

/* 1 if SIGINT has its default disposition (Windows: read by setting it
 * and putting it back, the C runtime has no query) */
static TP_UNUSED int tp_sigint_default(void)
{
#if defined(_WIN32)
    void (*h)(int) = signal(SIGINT, SIG_DFL);
    if (h != SIG_ERR) signal(SIGINT, h);
    return h == SIG_DFL;
#else
    struct sigaction sa;
    return sigaction(SIGINT, NULL, &sa) == 0 && !(sa.sa_flags & SA_SIGINFO) &&
           sa.sa_handler == SIG_DFL;
#endif
}

#endif /* LEXIFTOOL_TEST_PLATFORM_H */
