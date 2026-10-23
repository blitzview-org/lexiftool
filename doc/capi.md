# C API (draft)

Status: design draft with a working prototype in `capi/`. Nothing here is
part of a release yet; the API may still change.

## Idea

Most programs that use exiftool do not start it per file. They start it
once with `-stay_open True -@ -`, write one command at a time as an
argument list followed by `-execute`, read the output up to `{ready}`, and
finally send `-stay_open False`. Libraries such as PyExifTool (Python) and
exiftool-vendored (Node) are wrappers around exactly that protocol.

The lexiftool C API offers the same model in-process, without the
protocol: a *session* is one lexiftool instance -- an own Lua state in
which the command-line script waits in its own `-stay_open` command loop.
The caller hands in one command at a time as a list of C strings and gets
that command's stdout and stderr as two buffers plus its status back,
synchronously. Nothing is read from stdin, nothing is written to stdout
or stderr, there is no `-execute`, no `{ready}`, no line encoding.

For callers that only want tag values, a second call takes the text
formatting out entirely: `lexiftool_image_info` takes a file and a few
options and returns the tags as a list of name/group/value entries,
straight from the library, with warnings and errors as a list too. A
third call writes tags (`lexiftool_set_tags`).

## API

Header: `capi/lexiftool.h`.

```c
typedef struct lexiftool_session lexiftool_session;

typedef struct lexiftool_options {
    int                 struct_size;    /* sizeof(lexiftool_options), or 0 */
    int                 common_argc;    /* as after -common_args, e.g. */
    const char* const*  common_argv;    /*   "-G", "-charset", "filename=utf8" */
    const char*         config_file;    /* -config FILE; NULL default, "" none */
    const char*         lua_path;       /* "rock" build only: package.path */
    const char*         lua_cpath;      /*   and package.cpath, NULL = default */
} lexiftool_options;

typedef struct lexiftool_result {
    char*   stdout_data;  size_t stdout_len;
    char*   stderr_data;  size_t stderr_len;
    int     status;       /* as ${status}: 0 ok, 1 error, 2 all files failed -if */
} lexiftool_result;

typedef struct lexiftool_tag {
    const char* name;     /* "Make" */
    const char* group;    /* with -G[n]: "IFD0", "EXIF:IFD0", ...; else NULL */
    const char* value;    /* as -j prints it; raw bytes with -b */
    size_t      value_len;
    int         binary;   /* value holds raw binary data (-b) */
} lexiftool_tag;

typedef struct lexiftool_message { const char* level, *text; } lexiftool_message;

typedef struct lexiftool_tags {
    size_t count;          lexiftool_tag*      tags;
    size_t message_count;  lexiftool_message*  messages;
    int    status;         /* 0 ok, 1 error */
    void*  mem;            /* internal: the one allocation */
} lexiftool_tags;

lexiftool_session* lexiftool_open(const lexiftool_options* options);
int  lexiftool_execute(lexiftool_session* s, int argc, const char* const argv[],
                       lexiftool_result* out);
void lexiftool_result_free(lexiftool_result* result);
int  lexiftool_image_info(lexiftool_session* s, const char* path,
                          int argc, const char* const argv[], lexiftool_tags* out);
int  lexiftool_set_tags(lexiftool_session* s, const char* path, int n,
                        const char* const names[], const char* const values[],
                        lexiftool_tags* out);
void lexiftool_tags_free(lexiftool_tags* tags);
void lexiftool_close(lexiftool_session* s);
const char* lexiftool_version(void);
const char* lexiftool_last_error(const lexiftool_session* s);
```

Return codes: `LEXIFTOOL_OK` (0) or negative: `LEXIFTOOL_E_ARG` (bad
argument), `LEXIFTOOL_E_NOMEM`, `LEXIFTOOL_E_FAILED` (Lua error in the
command loop or failed start; the session is unusable from then on),
`LEXIFTOOL_E_ENDED` (a command contained `-stay_open False`; the loop has
ended), `LEXIFTOOL_E_ERROR` (`image_info`/`set_tags` only: that call hit a
Lua error; the session stays usable).

### Semantics

- **`lexiftool_open`** creates the session and starts the script as
  `lexiftool [-config FILE] -stay_open True -@ - [-common_args ARGS...]`,
  up to the point where it waits for the first command. `options` may be
  NULL (all defaults). It returns NULL only when out of memory. If the
  start fails (a module cannot be loaded, a Lua error), the session is
  returned anyway: `lexiftool_last_error()` says why and every call
  returns `LEXIFTOOL_E_FAILED`. Output of the start itself (e.g. a config
  file warning) is kept and arrives with the first command's output, as
  with `-stay_open`.
- **`lexiftool_execute`** runs one command. `argv` holds its arguments --
  the lines a `-stay_open` client writes before `-execute`, without the
  program name and without `-execute` -- passed verbatim: unlike argfile
  lines they may contain newlines and leading or trailing blanks. The
  return value says whether the command *ran*; the *command's* own result
  is `out->status`, the value exiftool puts into `${status}` and the exit
  code of a single run: 0, 1 (an error, e.g. file not found) or 2 (all
  files failed the `-if` condition). `out` is filled on every return (on
  errors with empty strings), so it is always freed.
- **`lexiftool_image_info`** reads one file: see below.
- **`lexiftool_set_tags`** writes tags of one file: `SetNewValue(names[i],
  values[i])` for each pair (a NULL value deletes the tag, as `-TAG=`),
  then `WriteInfo(path)`, which replaces the file (as
  `-overwrite_original`, no `_original` backup). `out->messages` gets the
  warnings (an unknown tag name) and errors, `out->status` is 0 when the
  file was written or nothing had to change, 1 on an error. Everything
  else about writing (`-tagsFromFile`, `+=`, `-if`, backups, ...) goes
  through `lexiftool_execute` with the usual arguments.
- **`lexiftool_result_free`** / **`lexiftool_tags_free`** free a result
  (safe on a zeroed one).
- **`lexiftool_close`** ends the loop the way a client's
  `-stay_open False` does (the script's `Exit()` cleanup runs) and frees
  the session. NULL is ignored.
- **`lexiftool_version`** returns the port's own version/identity (a
  `git describe`, e.g. `v13.59.2` on a tagged release or
  `v13.59.2-3-gabc1234` otherwise; `Unknown` if `build-linux.sh` was not
  run on a checkout with `.git`), a static string, baked in at build time
  (`LEXIFTOOL_PORT_VERSION`). `LEXIFTOOL_API_VERSION` in the header numbers
  the C API itself.
- **`lexiftool_last_error`** returns the message of the session's last
  failure (with a Lua traceback for a Lua error), or NULL; valid until the
  next call with that session. A command's own errors ("File not found")
  are not failures: they are on `stderr_data` / in `messages` and in
  `status`.

### lexiftool_image_info

`argv` holds options, from this subset of the command line's (anything
else is `LEXIFTOOL_E_ARG`; a word starting with `-` that is no option is a
tag name, as on the command line):

| option | effect |
|---|---|
| `-G[n[:n...]]` | `tag->group` set, as `-G` shows it (`EXIF`, `IFD0` for `-G1`, `EXIF:IFD0` for `-G0:1`); sorted by group as `-G` does when no tag is named |
| `-a` | all duplicates (otherwise suppressed as `-j` does) |
| `-b` | binary values as raw bytes (`binary` = 1) |
| `-n`, `-e`, `-ee`, `-u`, `-U`, `-fast`, `-fast2` | as on the command line |
| `-api OPT[=VAL]`, `-c FMT`, `-d FMT`, `-lang LANG` | as on the command line |
| `-sep STR` | separator for list values (default `", "`) |
| `-TAG`, `--TAG`, `-x TAG` | tags to extract / to exclude (default: all) |

Inside, it is the library call `-j` makes: a new ExifTool object with the
options set, `ImageInfo(path, tags)` with `Duplicates` on, then for every
found tag key `GetTagName`, `GetGroup(key, n)` and the value, with the
duplicate suppression of the `-j` output (a `TAG (1)` key whose priority
tag exists in the same group, and a second tag of the same group and name,
are left out unless `-a`). The values are what `-j` writes, before JSON
quoting:

- a scalar value as Perl stringifies it (`13.59`, `"Canon"`, `True` --
  `-j` writes the last as JSON `true`; NUL bytes inside a value are kept,
  `-j` drops them);
- a list (ARRAY) **joined into one string** with `", "` (or `-sep`), the
  way exiftool's text output shows lists. Decision: a flat list of
  name/value pairs is what every binding can marshal with one struct;
  per-item lists would need a second level of arrays for the rare list
  tag. A caller that needs the items uses `-sep` with a separator that
  does not occur in the values (e.g. `"\x1f"`), or `lexiftool_execute`
  with `-j`;
- binary data (SCALAR) as `(Binary data N bytes, use -b option to
  extract)`, or with `-b` the raw bytes, `binary` = 1 (`value_len` counts
  them; the value is NUL-terminated as well);
- a structure (only with `-api Struct=1`) serialized as for the text
  output.

Warnings and errors are in `out->messages` (`level` "Warning" or "Error"),
not on stderr: all `Warning`/`Error` tags of the file, as `PrintErrors`
lists them. A missing file gives no tags, the message "File not found"
and status 1, as the command line does.

### Memory

The caller owns everything it passes in; `lexiftool_open` copies what it
needs from the options. The library owns the session. A result's buffers
belong to the caller until `lexiftool_result_free` / `lexiftool_tags_free`;
a `lexiftool_tags` is one allocation (the two arrays and all strings).

`stdout_data`/`stderr_data` and tag values are NUL-terminated for
convenience, but the length is authoritative: with `-b` the data is binary
and may contain NUL bytes. A command's output is collected in memory (Lua
strings, copied once into the result), so it must fit in memory -- a
command that would print gigabytes (`-b` of a large embedded video) should
write to files with `-w` / `-o` / `-W` instead, exactly as one would do
through a pipe.

### Threads

A session is used from one thread at a time; the caller serializes.
Several sessions may exist in one process and may be used from different
threads at the same time: every session is its own Lua state, and the C
modules linked into it keep their state per Lua state (`lpcre`,
`carray`, `lfs`, `digest`, the `compress.*` and the `cipher.*` modules
have no mutable static data; `lpcre`, `compress.brotli` and `compress.zlib` are
tested with several states in parallel threads).
The library itself starts no threads and has no asynchronous, timeout or
cancel mechanism; concurrency is the caller's business.

What remains process-wide, as for any library:

- **Signals.** `main.lua` sets `$SIG{INT}`/`$SIG{CONT}` when it is loaded
  (`perl.SIG` -> `lexiftool.sys.signal`), which would install a C signal
  handler and remember the Lua state in a C static. A session switches
  this off per Lua state before loading anything
  (`lexiftool.sys.nosignals(true)`, a registry field): `signal` then only
  records the handler, the process's dispositions stay as the host set
  them (tested: SIGINT stays `SIG_DFL`) and no closed Lua state is left
  in the static.
- **Environment and locale.** The `TimeZone` API option writes `$ENV{TZ}`
  as upstream does (`setenv` + `tzset`); that is process-wide, and
  sessions that use it concurrently affect each other (and the host).
  The locale is only read: `DateFormat` conversions and `Time::Piece`'s
  `use_locale` format through `lexiftool.sys.strftime`, which loads the
  `LC_TIME`/`LC_CTYPE` locale named by the environment (`LC_ALL`,
  `LC_TIME`, `LANG`) into a locale object of its own at the first call,
  one per session's Lua state, and never switches the process or thread
  locale. On Windows (UCRT/MSVC builds) the C runtime's invalid-parameter
  handler is silenced through the thread-local handler for the duration
  of that call only. The static `liblexiftool.a` of the embedded build
  links musl, whose locale data has English names only: there `-d` with
  name conversions (`%a %A %b %B %p %c %x`) gives English names whatever
  the locale, while `liblexiftool.so` (and the standalone executable)
  use the system's glibc and its locale data, as Perl does.
  The host's `LC_NUMERIC` does not show in the output either: numbers
  print with `.` as in exiftool (Perl's `LC_NUMERIC` is "C"); the
  session reads the decimal point the C library uses before every
  command and replaces it, without setting a locale; likewise the host's
  `LC_COLLATE` does not change any order: strings sort and compare as
  bytes, as in Perl (see differences.md, "Numbers, sorting and the host
  locale").
- **Current directory.** Relative file names are resolved against the
  process's current directory. The current directory is process-wide, so
  a per-session working directory cannot be provided safely; callers pass
  absolute paths (or chdir themselves while no other session runs). For
  that reason the options have no working-directory field.
- **Standard input.** The session does not touch the standard streams: a
  command that names `-` as a file (or `-@ -`) reads the *process's*
  stdin, and `-k` waits for its terminal. Hosts leave those out.

## Mapping onto the inside

```
lexiftool_open                    Lua state of the session
  luaL_openlibs
  [embedded] lx_setup(L)          standalone/main.c: C modules (preload),
                                  embedded-module searcher, launcher chunk
  capi/session.lua                sys.nosignals(true); arg = {...}
                                  main = launcher(VROOT, getFile, true)
                                       | require 'lexiftool.main'
                                  main.session{config, commonArgs}:
                                    coroutine: main({-config F, -stay_open,
                                      True, -@, -, -common_args, ...},
                                      {readArgs = coroutine.yield})
                                    Command loop ... ReadStayOpen  -- yield
lexiftool_execute(argv)           main.execute(session, argv):
                                    perl.redirect(io.stdout/io.stderr, buffers)
                                    resume(argv + "-execute")
                                    command runs; loop top: echo3/echo4,
                                    rtnValPrev, (no "{ready}"),
                                    ReadStayOpen -> yield(rtnValPrev)
                                    perl.redirect(..., nil)
  copy both strings, status    <- table.concat(buffers), rtnValPrev
lexiftool_image_info(path, argv)  imageInfo: ExifTool.new, Options,
                                    ImageInfo, GetGroup/GetTagName/values
lexiftool_close                   main.execute(session, nil):
                                    "-stay_open False", loop ends,
                                    Exit() returns (session) ... main returns
  lua_close
```

**The entry and the line to upstream.** The command loop is `main.lua`'s
own `-stay_open` loop, structurally unchanged: `-common_args`,
`-echo3`/`-echo4` with `${status}`, the per-command reset of the
file-scope variables, `rtnValPrev`, and everything that outlives a
command (config, loaded modules, the Composite order) run exactly as for
a `-stay_open` client -- because it *is* that loop, started with
`-stay_open True -@ -`. The session is that running script; one per Lua
state, as the script's file scope is one per Lua state. A command is the
stretch between two waits of the loop for input, which is `ReadStayOpen`
-- the one place where upstream blocks. The port-only additions are:

1. `ReadStayOpen`: if the launcher gave `launchInfo.readArgs`, take the
   next command's arguments from it (`readArgs(rtnValPrev)`) instead of
   reading lines from the ARGFILE. In a session that is
   `coroutine.yield`: the yield hands the finished command's status to
   `execute`, the resume brings the next argument list (plus `-execute`,
   which ends a command in the loop as it does for a client).
2. The `{ready}` print at the loop top is skipped in a session (the host
   knows where a command ends: at the yield).
3. `Exit()` returns instead of `os.exit` in a session.
4. `session`/`execute` at the end of `main.lua`, and the module's value: a
   table callable as `main(argv, launch)` (the launchers keep calling it
   so) that carries the two functions.

Everything else is upstream's code path. A loop body turned into a
function (`execute` running one iteration) was the alternative; it would
have meant cutting the loop at a point upstream does not have, moving the
loop-local state into the file scope and re-entering in the middle of an
iteration. The coroutine keeps the cut where upstream has it.

**Output.** Everything the script and the library print goes through the
`perl` facade: `perl.print`/`perl.printf` (`print(io.stdout, ...)`,
`print(fp, ...)` with `fp` = `io.stdout`), `perl.warn`, and the library's
verbose output to its `TextOut` handle (default `io.stdout`).
`perl.redirect(fh, buf)` switches a handle to a Lua table: those
functions append the bytes there instead of writing them, and a direct
`fh:write(...)` on the switched handle does the same (the first call
replaces the `write` method of the Lua state's file handles by one that
looks at the switch -- some 150 verbose-output lines in the library
modules still write to `TextOut` that way). `execute` switches stdout and
stderr to the session's tables while the coroutine runs and
`table.concat`s them afterwards; the strings are byte strings, so `-b`
output comes through unchanged. In the command-line tool `perl.redirect`
is never called and nothing of it exists. The places that wrote to the
process's streams without the facade (`io.write`, `io.stderr:write`,
Lua's `print` -- debug and internal-error output of 15 modules) now go
through `perl.print`.

## Build variants

- **embedded** (as the standalone executable): all Lua modules as
  bytecode in one blob (`standalone/genembed.lua`, `blob.c`, brotli-
  compressed per entry), the C modules (`lexiftool.sys`, `lpcre`,
  `carray`, `lfs`, `digest`, `compress.brotli`, `compress.zlib`,
  `compress.lzma`, `compress.bzip2`, `cipher.aes`, `cipher.rc4`) and their
  libraries (Lua 5.5.1, PCRE2, zlib, brotli, liblzma, libbz2) linked in; the setup of the Lua state
  is `lx_setup()` of `standalone/main.c` (compiled with `-DLX_NO_MAIN`
  for the library). Two outputs:
  - `liblexiftool.a`, static, musl, nothing loaded from the file system
    (musl's locale data: date names in English only, see "Environment
    and locale" above);
  - `liblexiftool.so`, shared, `-fPIC`, against glibc 2.17 (a library
    loaded into an ordinary process must not bring its own libc): the
    same objects compiled with `-fvisibility=hidden`, linked against PIC
    archives of the dependencies that the builder image carries in
    `lib/x86_64-gnu-pic` (`standalone/deps.sh`), with a version script so
    that only the `lexiftool_*` functions are exported (`nm -D` is
    checked by the build).
- **rock**: only `capi/lexiftool.c`; the Lua modules and C modules come
  from `package.path`/`package.cpath` (the installed rock), Lua from the
  system's `liblua`. Options `lua_path`/`lua_cpath` set the paths.

## Bindings (sketches)

All of them load the shared library (`liblexiftool.so`, built by
`capi/build-linux.sh embedded`) and call the functions; the result
struct of `lexiftool_execute` is five fields.

Python (ctypes):

```python
import ctypes as C
class Res(C.Structure): _fields_ = [("out", C.c_void_p), ("out_len", C.c_size_t),
    ("err", C.c_void_p), ("err_len", C.c_size_t), ("status", C.c_int)]
lx = C.CDLL("liblexiftool.so"); lx.lexiftool_open.restype = C.c_void_p
s = C.c_void_p(lx.lexiftool_open(None)); r = Res(); argv = (C.c_char_p * 2)(b"-j", b"a.jpg")
lx.lexiftool_execute(s, 2, argv, C.byref(r)); print(C.string_at(r.out, r.out_len).decode(), r.status)
lx.lexiftool_result_free(C.byref(r)); lx.lexiftool_close(s)
```

Node (koffi):

```js
const koffi = require('koffi'), lx = koffi.load('liblexiftool.so');
const Res = koffi.struct({ out: 'void *', outLen: 'size_t', err: 'void *', errLen: 'size_t', status: 'int' });
const open = lx.func('void *lexiftool_open(void *)'), exec = lx.func('int lexiftool_execute(void *, int, const char **, _Out_ Res *)');
const s = open(null), r = {}; exec(s, 2, ['-j', 'a.jpg'], r);
console.log(Buffer.from(koffi.view(r.out, Number(r.outLen))).toString(), r.status); // then result_free, close
```

Rust:

```rust
#[repr(C)] struct LxResult { out: *mut u8, out_len: usize, err: *mut u8, err_len: usize, status: i32 }
extern "C" { fn lexiftool_open(o: *const c_void) -> *mut c_void; fn lexiftool_execute(s: *mut c_void, argc: i32, argv: *const *const c_char, r: *mut LxResult) -> i32; fn lexiftool_result_free(r: *mut LxResult); fn lexiftool_close(s: *mut c_void); }
let args = [c"-j".as_ptr(), c"a.jpg".as_ptr()]; let mut r: LxResult = unsafe { std::mem::zeroed() };
let s = unsafe { lexiftool_open(std::ptr::null()) }; unsafe { lexiftool_execute(s, 2, args.as_ptr(), &mut r) };
let out = unsafe { std::slice::from_raw_parts(r.out, r.out_len) }.to_vec(); unsafe { lexiftool_result_free(&mut r); lexiftool_close(s) };
```

C# (P/Invoke):

```csharp
[StructLayout(LayoutKind.Sequential)] struct LxResult { public IntPtr Out; public UIntPtr OutLen; public IntPtr Err; public UIntPtr ErrLen; public int Status; }
[DllImport("lexiftool")] static extern IntPtr lexiftool_open(IntPtr o);
[DllImport("lexiftool")] static extern int lexiftool_execute(IntPtr s, int argc, string[] argv, out LxResult r);
var s = lexiftool_open(IntPtr.Zero); lexiftool_execute(s, 2, new[] { "-j", "a.jpg" }, out var r);
var bytes = new byte[(int)r.OutLen]; Marshal.Copy(r.Out, bytes, 0, bytes.Length); // then lexiftool_result_free(ref r), lexiftool_close(s)
```

(C#'s default `string[]` marshalling is ANSI/UTF-8 per platform; file
names that are not valid UTF-8 need `byte[][]`.)

`lexiftool_image_info` in Python (the tag and tags structs as in the
header):

```python
class Tag(C.Structure): _fields_ = [("name", C.c_char_p), ("group", C.c_char_p),
    ("value", C.c_void_p), ("value_len", C.c_size_t), ("binary", C.c_int)]
class Msg(C.Structure): _fields_ = [("level", C.c_char_p), ("text", C.c_char_p)]
class Tags(C.Structure): _fields_ = [("count", C.c_size_t), ("tags", C.POINTER(Tag)),
    ("message_count", C.c_size_t), ("messages", C.POINTER(Msg)), ("status", C.c_int), ("mem", C.c_void_p)]
t = Tags(); opts = (C.c_char_p * 1)(b"-G1")
lx.lexiftool_image_info(s, b"a.jpg", 1, opts, C.byref(t))
info = {(t.tags[i].group, t.tags[i].name): C.string_at(t.tags[i].value, t.tags[i].value_len) for i in range(t.count)}
lx.lexiftool_tags_free(C.byref(t))
```

### Relation to exiftool `-stay_open` clients

The argument lists are the same: whatever PyExifTool's
`execute(*params)` or exiftool-vendored's task arguments write to
exiftool's stdin, one per line before `-execute`, is passed here as
`argv` -- `-j`, `-G1`, `-n`, `-b`, `-TAG=VALUE`, `-overwrite_original`,
`-if`, `-p`, `-@ ARGFILE`, `-echo4 ${status}` and so on behave the same.
The session options carry what goes on the exiftool command line before
`-stay_open`: `-config` and `-common_args`. Differences:

- no `-execute`, no `{ready}` markers, no line encoding: arguments may
  contain newlines; output arrives separated per stream, with the status;
- `-execute` inside `argv` splits it into two commands, as for a client;
  an option that is left without its argument takes the `-execute` that
  ends the command, so the command runs on with the next call's arguments
  (a client would hang at that point);
- `-stay_open` inside a command is not meaningful (`False` ends the
  session, `True -@ FILE` would switch away from the host);
- standard input is the process's (see Threads).

A client library could therefore offer lexiftool as a second backend
behind its existing API: its command builders stay, only the transport
(pipe + `{ready}` parser) is replaced by `lexiftool_execute`; a reader of
`-j` output can use `lexiftool_image_info` instead.

## Prototype

Files in `capi/`:

| file             | content                                                     |
|------------------|-------------------------------------------------------------|
| `lexiftool.h`    | the API                                                     |
| `lexiftool.c`    | sessions, results (both variants); marshals between C and `session.lua` |
| `session.lua`    | the Lua side: opens `main.session`, `execute`, `imageInfo`, `setTags`; embedded into `lexiftool.c` as a C array at build time |
| `example.c`      | runs `-j IMAGE` and `-ver`, prints the outputs; then `lexiftool_image_info -G1` (summary on stderr) |
| `test_capi.c`    | API tests                                                   |
| `build-linux.sh` | `embedded` (in the standalone builder container, zig cc: static musl archive and shared glibc library), `rock` (host gcc, system Lua 5.5, plus an ASan build), `test` |

Outside `capi/`: `main.session`/`main.execute` (`src/lexiftool/main.lua`),
`perl.redirect` (`src/lexiftool/perl.lua`), `sys.nosignals`
(`src/lexiftool/sys.c`), `lx_setup` (`standalone/main.c`), the launcher's
embedding mode (`standalone/launcher.lua`), the PIC archives
(`standalone/deps.sh`).

```
make image-linux                  # builder image (once; deps.sh changed)
sh capi/build-linux.sh embedded   # liblexiftool.a + liblexiftool.so
sh capi/build-linux.sh rock       # needs lua5.5 + headers, the rocks, make sys
sh capi/build-linux.sh test
```

`test_capi` checks sessions (hundreds of commands, two sessions used
alternately, open/close cycles, `-stay_open False`), `lexiftool_execute`
against the CLI's output byte for byte (including binary `-b` output),
`lexiftool_image_info` entry for entry against `-j`, `lexiftool_set_tags`
(write, read back, delete) and the absence of a process-wide SIGINT
handler; the rock build runs under AddressSanitizer/LeakSanitizer.

Note: the -j output of a file can depend on the files processed before it
in the same session (the order of the Composite tags), in Perl exiftool
with `-stay_open` as well as here; tests that compare outputs across
commands must take that into account.
