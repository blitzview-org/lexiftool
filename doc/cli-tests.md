# CLI golden tests: lexiftool vs. the original exiftool

The CLI harness compares `lexiftool` **byte for byte** against the vendored
Perl `exiftool` (`vendor/exiftool/exiftool`). The goal is broad coverage of the
CLI surface (reading, writing, copying, other) -- every option against one
representative per format family from `vendor/exiftool/t/images/`, not every
option against all 194 images (see "Scope").

Run by hand, the harness is a report: `make test-cli` lists the cases in
which the two tools differ and exits 0, a map of how much of the exiftool
CLI already behaves identically. What always fails (exit 2) is the harness
itself not getting through: a worker that died, or trees in which a case
exists on one side only -- a run that ends normally means the comparison
really ran over every case. With `TEST_CLI_EXPECT_IDENTICAL=1` any
difference beyond the exactly matching known ones (see "Known deviations")
fails the run (exit 1): the self-check (`make test-cli-perl`) always sets it,
and there even a known difference fails, since the same tool ran twice and a
difference there means the harness is not deterministic; CI sets it for
lexiftool as well, so the
port is held to the original on every platform and a regression cannot hide
behind a green job.

## Principle

1. A **matrix** of invocations (`READ`, `WRITE`, `DIR`, `STAY` in
   `src/test-cli/Cases.lua`) is applied to the test images.
2. Every case runs **twice with exactly the same argv**: once with
   `lexiftool`, once with the Perl `exiftool`.
3. Each run leaves **one directory** holding everything it did: stdout,
   stderr, exit code, and the files it worked on.
4. Rather than normalising differences away afterwards (timestamps, time
   zones, locale, permissions), the harness creates **identical preconditions**
   for both sides.
5. The comparison runs **afterwards** over the two resulting trees.

The two phases know nothing about each other:

```
runner:  one tool -> one observation tree   (produces only)
compare: two trees -> results               (compares only)
```

The runner knows only the tool's command line; it never learns whether it
starts Perl or Lua. The comparison knows neither tool nor case list -- the
trees describe themselves. A difference in bytes is therefore a difference
between the tools, never between the harness runs.

| File | Role |
|------|------|
| `Cases.lua`    | the matrix -- pure data |
| `Profiles.lua` | the only place with concrete command lines |
| `Runner.lua`   | one tool over the case list, in parallel, into one tree |
| `Driver.lua`   | one case: prepare `work/`, run, record |
| `Compare.lua`  | two trees against each other |
| `Report.lua`   | `summary.txt`, `failures.txt`, `results.json` |
| `Known.lua`    | the known deviations and how a difference is matched against one |
| `Config.lua`   | paths, image selection, case list, parallelism |
| `main.lua`     | entry point: start phases, print the result |
| `Util.lua`     | portable file/process primitives |

Which tool fills the `test` role is just a profile name in `TEST_CLI_TOOL`
(`lexiftool` or `exiftool-perl`). The self-check "Perl against its own
reference" is therefore not a special mode: it is the same program with a
different profile.

## Source of truth

The invocations are derived 1:1 from the canonical `OPTIONS` reference in the
original:

- `vendor/exiftool/exiftool` (POD from about line 5200: `Option Overview`,
  `Option Details` -- tag operations, input/output formatting, writing,
  copying, other)
- `vendor/exiftool/html/ExifTool.html`

No ad-hoc options are invented.

## Layout of `test-cli-out/`

Both `test-cli-ref/` (reference) and `test-cli-out/` (the tool under test)
have the same layout: one directory per case, named
`<group>/<variant>/<case>`. A variant whose label differs from another's only
in case (`-s` beside `-S`) carries `~lc` in its directory name, so that the
two stay apart on a case-insensitive filesystem (NTFS, APFS); the reports use
the plain label.

```
test-cli-out/read/csv/PDF.pdf/
    meta.txt          group, variant, case, argument template
    stdout.txt
    stderr.txt
    exit.txt
    stat-before.txt   state of work/ after prepare, before the call
    stat.txt          state of work/ after the call
    work/in/PDF.pdf   what the tool worked on

test-cli-out/dir/d-shift/all/
    ...same files...
    work/in/ ...   work/out/   work/src.jpg

test-cli-out/stay/s-growing/all/
    ...same files...
    feed.txt          session steps and whether every {ready} arrived
    work/args.txt     the growing argument file
```

Because both trees look the same, inspecting a case is an ordinary `diff`:

```
diff -u test-cli-ref/read/csv/PDF.pdf/stdout.txt \
        test-cli-out/read/csv/PDF.pdf/stdout.txt
diff -r test-cli-ref/dir/d-shift test-cli-out/dir/d-shift
```

The trees *are* the artefacts; there are no separate failure artefacts. A
`diff -r` over the two roots works as a last resort; the only intentionally
different file is `run.txt`.

At the root of each tree:

- `run.txt` -- the tree's identity card: tool, command line, `TZ`, `LC_ALL`,
  exiftool version, case count, image selection. The comparison refuses to
  run when the environment or the reference exiftool version differ (the
  case/image counts are informational: a narrowed run compares its selection
  against a reference tree that may hold more cases).
- `summary.txt` -- overall score, then `X/Y OK` per variant (worst first),
  then the differing cases with the **file** that differs (at most 10 per
  variant).
- `failures.txt` -- the full list as TSV
  (`group/variant`, case, status, first differing file, case path).
- `results.json` -- machine-readable, for trends across runs.

Both trees are in `.gitignore`; nothing of them is committed.

## Environment

All variables are optional; the default is the full matrix.

- `TEST_CLI_TOOL` -- profile in the test role: `lexiftool` (default) or
  `exiftool-perl`.
- `TEST_CLI_TRACK` -- groups to run: `read`, `write`, `dir`, `stay`, `expr`, or `all`
  (default). Groups are labels, not mechanisms.
- `TEST_CLI_SCOPE=all` -- full cross product of every variant with **all**
  images instead of only the core formats (see "Scope"). Much slower.
  Variants with an explicit image list keep their list.
- `TEST_CLI_IMAGES` -- space-separated patterns; only images whose basename
  matches are processed (e.g. `TEST_CLI_IMAGES='*.jpg *.png'`).
- `TEST_CLI_LIMIT` -- maximum number of images.
- `TEST_CLI_JOBS` -- worker count (default: CPU cores).
- `TEST_CLI_REGEN` -- rebuild the reference tree from scratch and stop (this is
  `make test-cli-gen`).
- `TEST_CLI_LUA` -- Lua interpreter to launch (default `lua5.5`).
- `TEST_CLI_ROCKS_VER` -- Lua version for the rocks paths (default `5.5`).
- `TEST_CLI_LUA_PATH`, `TEST_CLI_LUA_CPATH` -- override the module search
  paths (`LUA_PATH`/`LUA_CPATH` of the child); the defaults come from the
  local rocks tree.
- `TEST_CLI_PERL` -- Perl interpreter for the reference and the self-check
  (default `perl`; CI uses a non-SIP Homebrew Perl on macOS).

On Linux the reference Perl needs the optional `File::StatX` module for full
parity (`cpanm File::StatX`, or `PERL5LIB` pointing at a local install): without
it exiftool does not extract `FileCreateDate`, while lexiftool.sys always has
`statx()`, so `test-cli-lua` reports those lines as differences. The CI
`cli-golden` job installs it for the reference. The unit tests do not require
it (they ignore the optional system tag on Linux).

Likewise on every platform, the reference Perl needs the optional modules
for which lexiftool has a counterpart, or the cases that reach them differ:
`Archive::Zip` (ZIP-based formats), `IO::Compress::Brotli` (Brotli boxes in
JXL), `Compress::Raw::Lzma` (the compressed header of 7z archives, which 7-Zip
writes by default), `Unicode::LineBreak` (display-width alignment of
`-lang` output) and `Term::ReadKey`; `IO::Compress::Bzip2` (Rawzor) and
`Compress::Zlib` ship with Perl. `exiftool -ver -v` lists which of them a
Perl has. The CI `cli-golden` and `corpus` jobs install them.

## The reference tree

Perl exiftool startup is expensive per call, so the reference tree is built
**once** and reused: later runs only start the tool under test. The vendored
exiftool is pinned, making its observations a stable golden reference.

`test-cli-ref/` is gitignored. If the tree is missing, or individual cases are
missing (for example after a variant was added), the run fetches them in its
own visible phase:

```
  [1/3] building reference       100% (12/12)     (N workers, T s)
  [2/3] running lexiftool        100% (2758/2758) (N workers, T s)
  [3/3] comparing                100% (2758/2758) (N workers, T s)
```

A case is complete once its `stat.txt` exists -- the runner writes it last, so
an interrupted run resumes correctly. The tree's `run.txt` is written only at
the end of a phase: an interrupted reference build therefore leaves a tree
without `run.txt`, and the comparison **refuses** it instead of silently
comparing it.

Rebuild with `make test-cli-gen`. This is needed when `vendor/exiftool` is
updated or `TZ`/`LC_ALL` changed -- the comparison notices by itself, because
the environment lines of the two `run.txt` files no longer match.

## Running

Three targets, in the order in which they are used; they differ only in which
tool fills which role:

```
make test-cli-gen     # 1. BUILD the reference: Perl exiftool -> test-cli-ref/
make test-cli-perl    # 2. VALIDATE the harness: Perl vs. reference (must be 100%)
make test-cli-lua     # 3. TEST the port: lexiftool vs. reference
make test-cli         #    alias for test-cli-lua (the everyday case)
```

The order is a dependency, not a suggestion: a reference that `test-cli-perl`
has not confirmed says nothing about the port -- a non-deterministic variant
would otherwise produce wrong DIFFERs forever.

Internally the difference is one environment variable: `test-cli-perl` is
`TEST_CLI_TOOL=exiftool-perl`, `test-cli-lua` is `TEST_CLI_TOOL=lexiftool`,
`test-cli-gen` is `TEST_CLI_REGEN=1`.

Any of them can be narrowed down the same way:

```
TEST_CLI_TRACK=read make test-cli             # only the read group
TEST_CLI_LIMIT=5 make test-cli                # quick smoke test
TEST_CLI_IMAGES=ExifTool.jpg make test-cli    # only one image
make test-cli TEST_CLI_LUA=lua5.4 TEST_CLI_ROCKS_VER=5.4   # other Lua version
```

`make test-cli-gen` **only** builds the Perl reference and performs no
comparison. A failing reference build (e.g. missing perl/exiftool) is a
generator error; there is no OK/DIFFER score. The actual comparison runs only
in `make test-cli` / `make test-cli-perl`.

## Scope: every option, not every format

Crossing every CLI option with all 194 test images is mostly redundancy: an
output formatter such as `-s3` or `-csv` executes the same code on the 195th
file as on the 15th, while tree size and generation time grow with every new
option.

Coverage therefore uses **two axes** that would have to cross, but do not:

1. **Every option** runs against a **core selection** (`CORE_IMAGES` in
   `src/test-cli/Cases.lua`): one representative per format family -- JPEG
   with EXIF/IPTC/XMP, two maker-note variants, GPS, TIFF, raw, PNG, GIF,
   video, audio, PDF, XMP sidecar, PSD.
2. **Every format** is tested three times, twice reading and once writing, via
   three variants with `scope = 'all'`:
   - `read/default` -- the bare `exiftool FILE`. It runs over every test
     file and therefore every format module, exercising more reader code
     than any other single call.
   - `read/a-u-ee-G1` -- `-a -u -ee -G1 FILE`: everything the reader reaches,
     including duplicates, unknown tags and embedded data, each with its
     group. `default` shows only what survives the priority rules; this
     variant catches a missing or misnamed tag underneath them as well.
   - `write/w-Subject` -- `-XMP:Subject=...`. XMP is the broadest writable
     group, so this one call gives every module a write test too. As a side
     effect it yields the writability matrix: fewer than half of the files
     are writable (the rest is a no-op for the original as well and counts
     as ineffective).

One option-specific variant keeps the full set as well: `read/imageDataHash`
(`-ImageDataHash FILE`). The digest is fed by a hash path of each format
module's own (JPEG scan data, TIFF strips and tiles, PNG IDAT, QuickTime and
HEIC media data, RIFF chunks, JPEG 2000/JPEG XL boxes, the raw readers), so a
core selection would leave most of them untested.

So every option has its test and every format has its test, without the
product of both: a few thousand comparisons instead of tens of thousands,
and a correspondingly smaller reference tree.

For the full format matrix (e.g. to check reader module coverage), set
`TEST_CLI_SCOPE=all`. Individual variants can request the full image set
permanently via `scope = 'all'`; that is deliberately the exception.

A third form sits beside the two axes: a variant may name its images
explicitly (`images = { ... }`, see "Extending the matrix"). It is for an
option branch that only certain formats reach -- a verbose dump of one
container, an embedded stream, a tag-name rule visible only in `-s`/`-j` --
so the call runs exactly on the files that exercise the branch, typically a
`lex_` fixture next to its nearest upstream image.

## Images

Two directories are compared:

| Directory | Content | Origin |
|---|---|---|
| `vendor/exiftool/t/images/` | the original's 194 test images | upstream, **never** modified |
| `src/test/images/` | additional fixtures | this port |

The second source exists because some code paths have no representative in the
vendor corpus. `t/images/Photoshop.psd`, for example, has `LayerCount 0`, so
no vendored file reaches `Photoshop.ProcessLayers`. Instead of adding a file
to the vendor tree (and decoupling it from upstream), it lives in its own
directory.

Rules for fixtures:

- **They are fixtures.** Created once, then constant -- no generator, no build
  step.
- **The layout is documented** in `src/test/images/README.md` (byte layout and
  what each file covers).
- **`lex_` name prefix.** The tree layout and `CORE_IMAGES` key on the
  basename; a collision with an upstream name must be impossible.
- Fixtures are **not** in `CORE_IMAGES`; they are tested via `read/default`
  (`scope = 'all'`), the mechanism that gives every format module its CLI
  test. A branch that needs a particular option on a fixture gets its own
  variant with an explicit image list.

A new image needs no `make test-cli-gen`: missing (variant, image) cases are
created lazily. `test-cli-gen` is for invalidating the *whole* tree (different
TZ, locale or exiftool version -- see "The reference tree").

## Help text: generated, not hand-maintained

`lexiftool --help` (and the call without `FILE`) prints the same documentation
as the original -- almost 3,000 lines. It is generated by search-and-replace
from the original output:

- `tools/usage_rules.lua` -- the only place where deviations are defined:
  tool and library names (`exiftool` -> `lexiftool`,
  `Image::ExifTool::X` -> `lexiftool.X`), a preamble naming the port, a
  copyright note, and dropping the `SEE ALSO` section. `exiftool.org` URLs are
  left untouched.
- `tools/gen_usage.lua` (`make usage`) -- generates
  `src/lexiftool/usage.lua`, the text lexiftool actually prints.

`src/test/test_usage.lua` checks two things: `usage_rules(vendored --help)`
equals the generated file, and `lexiftool --help` prints exactly that file.
This belongs to the unit tests (it blocks `make check`), not to the CLI
comparison: the harness must not rewrite the reference to match the port.

## What counts as identical

Everything is compared byte for byte, with two deliberate exceptions:

- **Exit codes** are compared by outcome: both zero, or both non-zero. The
  value of a non-zero code is the implementation's (Perl's `die` exits with
  whatever `errno` was left over, see `differences.md`, "`-k` without a
  console"), but whether a call failed must agree.
- **The source location** Perl appends to a `die`/`croak` message (`at FILE
  line N.`) is neutralised to `at <FILE> line <N>.` on both sides: it names
  Perl's own files, the port's counterpart names its own. The message before
  it must still agree.

A difference that comes from internals of the Perl interpreter is listed as a
known deviation (see "Known deviations" under "Corpus run") and reported as
"known (Perl internals)" -- only while it has exactly the recorded form.

## Deliberate differences

Where lexiftool intentionally differs (see `doc/differences.md`), a
byte comparison against Perl cannot be green; those cases are covered by
`src/test/test_cli_port.lua` (part of `make check`). The golden covers only
the common part:

- `d-config`: a *missing* `-config` file (both: `Config file not found`, run
  without configuration). Perl config files that lexiftool reads as data are
  compared against exiftool in `src/test/test_perlconfig.lua`; one with Perl
  code beyond data warns `Config file not supported by lexiftool (Perl code
  at line N: CONSTRUCT): FILE` and lexiftool continues without it -- covered
  by `test_cli_port.lua`.
- `d-expr-*`: every Perl example from the docs (POD `-if`, "Advanced
  formatting feature" with DateFmt/ShiftTime/NoDups/SetTags, ExifTool.pod
  SetNewValuesFromFile, fmt_files gpx.fmt/kml_track.fmt) plus `my`/`split`,
  `sprintf`, blocks, case modifiers, list slices, variables in patterns,
  `sort`/`reverse`, Image::ExifTool functions and the `-w` warnings that
  fail an `-if` condition (`d-expr-if-warn` with `-v`), `map`/`grep`,
  `s///e`, `keys %info`, seeded `rand`, `substr` outside the string, the
  two-argument `ShiftTime` and the `$1` an expression sees before its own
  first match (`d-expr-outer1`) -- through `perl.eval`, with the same
  result as Perl. The expressions people write in practice are the `expr`
  group (below).
  Perl outside the supported subset reports "Perl syntax unsupported in
  lexiftool: ..." (also with `-if` without `-v`).
- `d-listx-all`: `-listx` over the whole database, because `d-listx`
  (`-listx -EXIF:all`) does not reach the maker-note or XMP tables.
- `-ver -v` is deliberately not in the golden (Lua counterparts instead of
  Perl module versions, plus a port line); `-ver` alone (`d-ver`, `ver`) is.

## Silent variants

A variant where the **reference** tool does nothing proves nothing: both sides
agree trivially and the variant reports 100% OK without executing anything.
Matrix construction errors hide there -- a `$TAG` expanded by the shell, a
missing `=` turning a write into a read, or an option combination the tool
rejects outright.

A case counts as **silent** when the reference left nothing on any compared
channel: empty `stdout.txt`, empty `stderr.txt`, exit code 0, and
`stat-before.txt` equal to `stat.txt`. This is why the snapshot before the
call exists.

A single silent case is inconspicuous and not reported: `-GPS:all` on a file
without GPS prints nothing, and the port being silent too is verified
behaviour -- a wrong tag or an extra warning would make the case differ. Only
a variant that was silent in **every** case is reported. `summary.txt` marks
it `SILENT`, and the terminal prints a warning.

The warning is a suspicion, not a verdict; it can also be a legitimate no-op
for the selected images. Run the call by hand on a suitable image to check.

## Reading results

`summary.txt` shows the score per variant, worst first, and for each differing
case **which file** differs:

```
write/w-o (7 of 14):
  write/w-o/GIF.gif                        stat.txt: work/out/GIF.gif (missing in test)
  write/w-o/PNG.png                        stat.txt: work/out/PNG.png (content)
```

That distinguishes "wrote nothing at all" from "wrote the wrong bytes" without
opening a file. For files under `work/`, the report also distinguishes content,
size, mtime and permissions; `diff -r` would not see the latter three.

The case exists at the same path in both trees:

```
diff -r test-cli-ref/write/w-o/GIF.gif test-cli-out/write/w-o/GIF.gif
```

`failures.txt` is the same list as TSV for filtering with `grep`/`cut`;
`results.json` is for trends across runs.

## Determinism

The harness creates determinism instead of normalising it away:

- Each case runs with `work/` as its working directory. Everything inside is
  named relatively (`in`, `out`, `src.jpg`, `args.txt`), so verbose output
  containing paths is identical in both trees. This matters because upstream
  snips the `Directory` value at 60 characters.
- Inputs are copied, their mode set to 0644 and atime/mtime pinned to a fixed
  future timestamp. Creation time (where the OS exposes it) is pinned too;
  Linux `ctime` is pinned by a preload shim because no syscall can set it:
  - Linux: `tools/ctime_fake.c`, injected via `LD_PRELOAD`
    (`build/ctime_fake.so`), interposes `stat`/`lstat`/`fstat`/`statx` and also
    pins the StatX birth time (the only platform where ctime cannot be set).
  - macOS: `tools/ctime_fake_darwin.c`, injected via
    `DYLD_INSERT_LIBRARIES`, interposes the `stat` family (including the
    `$INODE64` variants); the birth time is set through `setattrlist`
    (`setattrlist` accepts a change time too, but APFS stamps it again on
    the way out, so the interposer is the only way). System Perl is
    SIP-protected and would drop the variable, which is why CI uses a
    Homebrew Perl. A hardened system binary spawned by a tool under test
    (`sh`, `chown`) aborts on start with the library inserted, so the port
    must not shell out where the Perl original uses a builtin -- `chown` is
    native in `lexiftool.sys` for exactly this reason.
  - Windows: creation time is set directly through `lexiftool.sys`
    (`set_times`), which wraps `SetFileTime`.
- The pinned atime is one second after the pinned mtime. `relatime` (the
  Linux default) refreshes atime on a read whenever it is not newer than
  mtime, and the harness reads every copy once for `stat-before.txt`; with
  atime after mtime that read changes nothing. The copies are pinned again
  after that read anyway, for filesystems that refresh atime on every read
  (`strictatime`, Windows with last-access updates enabled), so the tool
  always sees `FileAccessDate` as `2099:01:01 00:00:01`.
- `TZ=UTC`, `LC_ALL=C`, `PERL_HASH_SEED=0`, `PERL_PERTURB_KEYS=0` are set for
  both sides.
- CRLF is deliberately **not** rewritten: the original emits CRLF for some
  formats (`-csv`, RFC 4180) and the port must reproduce it exactly.
- The tool's own `stat.txt` fingerprint classifies mtime as `fixed` (the pinned
  stamp), `runtime` (the wall clock -- a file this run created), or an epoch
  (set deliberately from tag data), so timestamps do not create noise while
  `-CreateDate>FileModifyDate` is still judged.

## Extending the matrix

The tables `READ`, `WRITE`, `DIR` and `STAY` in `src/test-cli/Cases.lua` are
the only place where variants are maintained (the `expr` group's cases come
from the data file `src/test-cli/Expressions.lua`, see below). Each row is
`{ label = '...', args = '...' }`; the file contains nothing else, so reading
it tells you *what* is tested.

Which images a row runs on:

| Field | Images |
|-------|--------|
| (none) | the core selection (`CORE_IMAGES`) |
| `scope = 'all'` | every selected image |
| `images = { 'lex_Vorbis_TagNames.flac', 'Vorbis.ogg' }` | exactly these |

An `images` list holds basenames, looked up in both image directories (the
basename is unique by the `lex_` rule). Use it when an option only matters for
some formats: the core selection would not reach the branch, and the full set
would multiply a large output (`-v3`, `-htmlDump`) over files that add
nothing. The list works in every group: in `READ`/`WRITE` it yields one case
per listed image, in `DIR`/`STAY` it decides which images land in `work/in/`.

- A basename found in neither directory stops the matrix build with an error
  (for every group, whatever `TEST_CLI_TRACK` selects), so a typo cannot turn
  into a variant with no cases.
- `TEST_CLI_IMAGES`/`TEST_CLI_LIMIT` narrow the list like any other selection;
  a listed image they filter out is skipped.
- `TEST_CLI_SCOPE=all` leaves the list alone: the list says where the call
  makes sense, not how much of the format matrix to cover.
- A new row or a longer list needs no `make test-cli-gen`; the missing cases
  are created lazily like those of a new image.

The tables are **not** tracks but declaration groups with two common
defaults (`Cases.GROUPS`):

| Group | `prepare` (what lands in `work/`) | `over` |
|-------|-----------------------------------|--------|
| `READ`  | one image in `work/in/` | one case per image |
| `WRITE` | one image plus `work/src.jpg` | one case per image |
| `DIR`   | all selected images in `work/in/`, plus `work/src.jpg` | one case over everything |
| `STAY`  | like `DIR` | one case over everything (one `-stay_open` session) |
| `EXPR`  | like `DIR`, with the images `Expressions.IMAGES` | one case over everything |

Observation and comparison are identical for all groups; there is no
track-specific logic.

Placeholders in `args`:

| Placeholder | Meaning |
|-------------|---------|
| `@@`        | the case's file, `in/<image>` (only with `over='each'`) |
| `%IN%`      | `in` |
| `%OUT%`     | `out` (created empty) |
| `%SRC%`     | `src.jpg`, the source for `-tagsFromFile` / `-file1` |
| `%ARGFILE%` | `args.txt` (a growing argument file for `-@`) |
| `%AUX%`     | the untouched image directory (read-only, e.g. geotag logs) |
| `%REPO%`    | the repository root (read-only, e.g. config files) |

Substitution is **literal**: exiftool's own `%` formats (`%Y`, `%%f`, `%%e`)
stay unchanged in the same string.

Which table does a new option belong to?

- works on **one** file and writes nothing -> `READ`
- works on **one** file and writes -> `WRITE`
- operates on a **directory** (renames, timestamps, backups, multiple output
  files) or needs no file at all -> `DIR`

### Expression corpus (`EXPR`, group `expr`)

`src/test-cli/Expressions.lua` holds Perl expressions from real exiftool
command lines: `-if` conditions, advanced formatting (`${TAG;EXPR}`, the
right-hand side of `-TAG<...`, `-p` formats) and `-api Filter=...`, taken
verbatim from the exiftool documentation, the ExifTool forum, Stack Exchange
sites, blogs and gists. Each entry keeps its source URL as attribution
(snippets from Stack Exchange are licensed CC BY-SA); none is invented, and
the posts that do not work as their author hoped (shell-quoting slips,
wrong operators) are kept, because what exiftool makes of them is part of
its behaviour. The group checks that `perl.eval` gives exactly upstream's
result for the expressions people actually write, not only for the ones the
documentation shows.

Every entry that has no `skip` becomes one case `x-<id>` (`x-if-001`,
`x-fmt-012`, ...) over one directory with the images `Expressions.IMAGES`
(different makers, with and without GPS, keywords, XMP and dates, and a
video, so that a condition is true for some files and false for others):

| `kind` | command line |
|--------|--------------|
| `if` | `-if EXPR -p '$filename' in` |
| `fmt`, `assign`, `p`, `other` | `-p EXPR in` |
| `api` | `-api OPTION=EXPR -S <Expressions.API_TAGS> in` |

`opts` puts options of the source command line in front (`-userParam
test=Hello`). Nothing is written: an `assign` expression is printed with
`-p` rather than copied into a tag, which runs the same `InsertTagValues`
code. An expression whose result cannot be reproduced runs as a `variant`
with the reason in `why` (the `rand` entry is seeded with `srand(1)`); one
that only makes sense with a writing command (`-api GeoHPosErr`, which
applies while geotagging) carries a `skip` reason instead; the write
cases `w-geotag-hposerr*` cover that one.

To add an expression: append an entry with the next free number of its
kind (ids never change, so the case directories stay stable), the
expression verbatim in a long string (`[[...]]`, `[=[...]=]` when it
contains `]]`), its `src` and a short `note`, then run `make test-cli-perl`
(it builds the new reference case and must stay at 100%) and `make
test-cli-lua`.

### Case type `-stay_open` session (`STAY`, group `stay`)

`-stay_open True -@ ARGFILE` turns exiftool into a long-lived process: the
caller appends command by command to the argument file (or writes to the pipe
on stdin, `-@ -`), terminates each with `-execute[NUM]`, and waits for the line
`{ready[NUM]}` on stdout before sending the next one; `-stay_open False` ends
the session. Upstream has no `.t` file for this, so the harness plays the
caller itself. A `Cases.STAY` entry has `args` (the command line, e.g.
`-stay_open True -@ -`) and a `feed` list:

| Step | Meaning |
|------|---------|
| `'...'` | text sent to the tool as is (lines with `\n`) |
| `{ ready = N }` | wait until stdout contains N `{ready` marks (at most 20 s) |
| `{ sleep = S }` | pause S seconds (e.g. in the middle of a line) |

`via = 'file'` sends the text to a growing file `work/args.txt` (named
`%ARGFILE%` in `args`) instead of stdin; without `via` it goes to stdin. The
session runs in `work/`, and `%IN%` in the feed means the relative `in`, so
the argument file is identical in both trees and is compared like any other
file through `stat.txt`.

`Driver:runFed` starts the tool with stdin as a pipe (`sys.spawn` with
`stdin = 'pipe'`), stdout/stderr into files, and a 60 s timeout. If the tool
exits early, the pipe write side is closed and the error is observed rather
than crashing the harness. Waiting for `{ready}` reads the stdout file -- a
tool that does not flush after `{ready}` (upstream: `$| = 1`) lets the step
time out. That is an observation, not a harness error: `feed.txt` records
every step and whether its wait was answered, and then differs like any other
file. Output is never sorted: its order is the protocol.

The cases (a)-(e): `s-execute` (several `-execute` in sequence on different
files, `{readyN}` per command), `s-write-read` (write in the session, read
back in the next command), `s-error` (missing file and an aborted command in
the middle, `${status}` via `-echo3`, the session continues), `s-false`
(`-stay_open False`: the arguments after `-@ -` on the command line run as the
last command, then end at EOF), `s-quiet` (`-q` without an `-execute` number:
no `{ready}`, only flush) and `s-growing` (the argument file grows while it is
read; lines arrive delayed and split in the middle).

After adding a variant, run `make test-cli-perl`: it first builds the
reference cases the new variant is missing, then compares Perl against them.
This self-check must be **100%**;
otherwise the new variant is not deterministic (e.g. it prints the wall clock)
and would produce wrong differences forever.

## Corpus run (`make test-corpus`)

The golden matrix checks every option on one representative per format
family and every format on the 194 vendored images. What it does not see is
the breadth of real camera files: thousands of models, maker-note variants,
firmware bugs. The corpus run covers that -- the same mechanics (Runner,
observation tree, comparison afterwards, Perl as the oracle), but over an
external corpus and with a small, fixed case list per file.

### The corpus

By default the corpus is Phil Harvey's "ExifTool Meta Information Repository"
(<https://exiftool.org/sample_images.html>): one `<Make>.tar.gz` per
manufacturer (some 100 archives with about 7000 JPEGs, a few hundred MB).
The page says: "To conserve space and avoid copyright
problems, the main image has been replaced, and the large preview image (and
any other information found after the JPEG EOI) has been removed. However,
the JPEG APP1 EXIF segment as well as any other APP segments are preserved in
their original condition." **The page states no licence.** The images are
therefore used only as local test input and are **never committed**: they
are fetched on demand by `tools/fetch_corpus.sh`, and
`vendor/exiftool-samples/` is in `.gitignore`.

    make corpus-fetch                 # fetch/update into vendor/exiftool-samples/
    make corpus-fetch CORPUS=<dir>    # another target directory

`tools/fetch_corpus.sh` reads the archive list from the page's own table (a
new manufacturer is picked up without editing the script) and keeps it as
`manifest.txt` (TSV: archive, make, models, size, "Last Updated"). It
downloads an archive only when it is missing or its date/size in the table
changed since the last download (`archives/manifest.txt`), unpacks it into
`<dir>/<Make>/`, and writes a `README` with the origin and the licence note.
Without network access, put the archives into `<dir>/archives/` by hand and
run `tools/fetch_corpus.sh --offline`. `--manifest-only` fetches just the
page and writes `manifest.txt` -- CI keys its cache of the archives on it.

Any other directory of the form `<dir>/<group>/<file>` works as a corpus too
(`CORPUS=<dir>`); the first level is the grouping (for the samples: the
manufacturer).

The script is portable `sh` (GNU tools on Linux and in Git Bash on Windows,
BSD tools on macOS) and works inside the target directory with relative
paths, so `tar` never sees a Windows drive letter. The sample corpus needs
no special treatment on case-insensitive or Windows file systems: no two
manufacturer directories or file names differ only in case, and no name
contains a character Windows forbids.

### Cases

Per file (groups `read`/`write`; the case name is `<Make>~<file>`, since the
same file name occurs in different manufacturer directories):

| Case type | Call | Compared |
|---|---|---|
| `read/a-u-G1`   | `-a -u -G1 FILE`   | stdout, stderr, exit code |
| `read/j-t`      | `-j -t FILE`       | likewise |
| `read/v3`       | `-v3 FILE`         | likewise |
| `read/X-struct` | `-X -struct FILE`  | likewise |
| `write/w-Artist`| `-Artist=x -o OUT/ FILE`, then `-a -u -G1 OUT/FILE` | likewise for both calls, the written file by hash (`stat.txt`) |
| `write/w-all`   | `-all= -o OUT/ FILE`, then `-a -u -G1 OUT/FILE`     | likewise |

In addition, per manufacturer directory, `stay/s-make/<Make>`: a
`-stay_open True -@ -` session that reads all of the manufacturer's files one
after the other with `-a -u -G1` and `-executeN`, waiting for `{readyN}` each
time (protocol as in case type `STAY`; `feed.txt` records every step).

The readback is done by the same tool that wrote; its output lands in
`readback-stdout.txt`/`readback-stderr.txt`/`readback-exit.txt`. Before it,
the written file's times are pinned like an input copy's (otherwise the wall
clock would show up in `FileModifyDate`); `stat.txt` has been taken by then
and shows what the write call itself did.

**Paths.** Every call runs with the tree root as its working directory and
names its files relative to it: `FILE` is
`read/v3/Canon~CanonEOS_5D.jpg/work/in/CanonEOS_5D.jpg`, `OUT` is
`<case>/work/out`. A session serves all cases of a manufacturer, so the
golden harness' per-case working directory (`work/`) is not possible there;
process mode and the `stay` session follow the same convention. The paths
are identical in both trees, so no tree-specific path reaches the output
(`Directory` in `-a -u -G1`, the file names in `-v3` and in messages).

### Session mode (default) and process mode

`TEST_CORPUS_MODE=session` (default) sends all `read`/`write` cases of a
manufacturer as commands through **one** `-stay_open True -@ -` session per
tool (109 sessions); `TEST_CORPUS_MODE=process` starts one process per call.
The trees have the same layout in both modes (`stdout.txt`, `stderr.txt`,
`exit.txt`, `readback-*`, `stat*.txt`), and `diff -r` works unchanged. The
case `stay/s-make` remains its own scripted session in both modes.

Per command the harness (`CorpusDriver:runMake`, `Session:exec`) sends

    -echo4
    {done<ID>:${status}}
    <the case's arguments, one per line>
    -execute<ID>

| Stream | Split |
|---|---|
| stdout | everything up to the line that ends in `{ready<ID>}` (marker and its line end removed; "ends in", because output without a final newline gets the marker appended to its last line; the line end may be CRLF, as Perl writes it on Windows). |
| stderr | everything up to `{done<ID>:<status>}`. Upstream prints `-echo4` at the top of its command loop after the command and **before** `{ready}` (echo3, echo4, flush STDERR, `{ready}`), so the marker is already in the stderr file when `{ready}` arrives. |
| exit | `<status>`: `-echo4` substitutes the command's `$rtnVal` for `${status}` -- the value the process would exit with (`Exit $rtnValApp`, for one command its `$rtnVal`). |

`-echo4` goes first so that it is registered even when a later argument
aborts the command (`$badCmd` still passes the echo block). No option leaks
between commands: the corpus cases use neither `-common_args` nor
`-charset`/`-config`, and the tool itself resets everything per command at
the top of its loop (the long `undef` list, `$mt` recreated). The arguments
travel one word per line -- the same argv that process mode passes to the
tool (the template split by `Util.shellSplit`, placeholders substituted).

**The session process.** No shell is involved, exactly as in the golden
harness' `STAY` cases: the tool is spawned through `lexiftool.sys` with a
pipe as its stdin and files as its stdout and stderr; the harness writes
each command into the pipe and polls both files. The same code runs on
Linux, macOS and Windows.

**Timeout and crash.** The poll loop also enforces the time limit: a
command that has not answered within `TEST_CORPUS_TIMEOUT` seconds gets the
session killed (its whole process group on POSIX, its job object on
Windows), is recorded with exit 124 (what `timeout(1)` would report) and
counts as a timeout in `summary.md`; the rest of the manufacturer continues
in a new session. If the tool dies by itself (a Lua error, a Perl `die`),
the command gets the output so far, the rest of stderr and the real exit
code. Should the harness itself fail or be interrupted (Ctrl-C), it kills
the session before it exits.

**Chunks.** The cases run per chunk of 25 files (150 cases): a chunk
prepares all of its cases (`Driver:prepare`), takes their fingerprints
(`Driver.fingerprint`), runs all commands (per file `a-u-G1`, `j-t`, `v3`,
`X-struct`, `w-Artist`, `w-all`), takes the fingerprints again, pins the
written copies and reads them back in the same session; `stat.txt` comes
last per case, so an interrupted chunk is redone as a whole. Parallelism
(`TEST_CORPUS_JOBS`) deals whole manufacturers to the workers in session mode
(largest first, to the least loaded one), so the largest manufacturer bounds
the run time from below.

**The reference is per mode.** In a session Perl keeps module state across
commands, and that is visible in the output: the Composite order (which
modules are already loaded), maker-note directory names, and unknown tags
read with `-u` that a later write command in the same session treats as
known. That is upstream behaviour, reproducible by hand without the harness,
and the port has to show it the same way. The mode is therefore part of the
reference tree's key: switching modes discards the reference and rebuilds
it.

**Run time.** A full run (reference, the Perl self-check and the lexiftool
run) takes between a quarter and three quarters of an hour on the GitHub
runners, depending on the platform; the limit is disk work over the
hundreds of thousands of small files per tree, not the tools, so more
workers than four hardly help.

**The comparison runs in the workers too**, each with every n-th case
(`Compare.cases`; the results come back as one file per worker and are
merged in tree order). What is compared does not change: each case
directory is still listed on both sides, so a file present on one side
only, or a case missing from one tree, is still reported. The timeout
verdicts of the report come from the same reads (`refTimeout`/`testTimeout`
in the results).

### Differences from the CLI golden

- **Timeout per call** (`TEST_CORPUS_TIMEOUT`, default 60 s; see "Timeout
  and crash" above). The scripted `stay` session gets 60 s + 2 s per file
  from its start, and its wait for `{ready}` ends as soon as the tool has
  exited.
- **Calls run from the tree root with relative paths** (see "Paths" above)
  instead of from the case's `work/`.
- **Both trees are resumable.** A case is complete once its `stat.txt`
  exists; a call interrupted with Ctrl-C is not recorded (it would otherwise
  count as complete). A tree without `run.txt` is an interrupted run and is
  continued by the next call. A complete test tree (or one of another tool or
  another selection) is started afresh. The reference tree is kept across
  selection changes -- its cases are per file, a narrower selection just uses
  part of them -- and is discarded only when `TZ`, `LC_ALL`, the exiftool
  version, the timeout, the mode or the layout version of the tree change.
- **The input copies are deleted after the fingerprint** (`stat.txt` holds
  their hash); they would otherwise fill the disk. `work/out/` (the written
  files) stays. A full run still takes about 2 GB per tree.
- The fingerprints (`stat-before.txt`, `stat.txt`) are `Driver.fingerprint`'s:
  path, size, mtime class, mode and the first 16 hex digits of the file's MD5,
  exactly as in the golden trees.
- The tree's key (`.started`) includes the layout version of the case
  directories; a reference in another layout is discarded and rebuilt, like
  one of another mode.

### Running

    make test-corpus-gen    # 1. build/complete the reference (Perl), no comparison
    make test-corpus-perl   # 2. Perl against the reference: must be 100%
    make test-corpus-lua    # 3. lexiftool against the reference
    make test-corpus        #    alias for test-corpus-lua

`make test-corpus*` runs `make corpus-fetch` when `CORPUS` is missing. The
Lua, rocks and Perl variables are those of the golden harness
(`TEST_CLI_LUA`, `TEST_CLI_ROCKS_VER`, `TEST_CLI_LUA_PATH`,
`TEST_CLI_LUA_CPATH`, `TEST_CLI_PERL`), and so is the requirement of
`File::StatX` for the reference Perl on Linux (see "Environment"): a
reference built without it lacks `FileCreateDate` in every read case and
makes nearly every case a deviation.

The exit status follows the golden harness. Run by hand, the corpus run is a
report (exit 0). A worker that died, or a case that exists in only one tree,
exits 2; an interrupted phase exits 1 (run again to resume). With
`TEST_CORPUS_EXPECT_IDENTICAL=1` every deviation beyond the exactly matching
known ones (see "Known deviations") exits 1. `make test-corpus-perl` always
sets it, and there even a "known" difference fails: the same tool ran twice,
so any difference means the harness is not deterministic. CI sets it for
lexiftool too: the `corpus` workflow (`.github/workflows/corpus.yml`, started
by hand from the Actions tab, for all three OS or one of them) does all three
steps on Linux, macOS and Windows, with the same per-OS setup as the golden
job in the CI workflow (reference Perl, ctime interposer on Linux and macOS).

A narrowed selection (`TEST_CORPUS_MAKES`, `TEST_CORPUS_SAMPLE`,
`TEST_CORPUS_TRACK`) leaves the manifest `test-corpus-ref/run.txt` of a
complete reference untouched; only a full run rewrites it. Narrowing:

    TEST_CORPUS_MAKES='Canon Nikon' make test-corpus     # these manufacturers only
    TEST_CORPUS_TRACK=read|write|stay make test-corpus   # one group only
    TEST_CORPUS_SAMPLE=500 TEST_CORPUS_SEED=1 make test-corpus
                                    # reproducible sample: every manufacturer
                                    # with at least one file, the rest by
                                    # FNV-1a(seed:path) -- independent of the
                                    # Lua version's random generator
    TEST_CORPUS_TIMEOUT=30 TEST_CORPUS_JOBS=4 make test-corpus
    TEST_CORPUS_MODE=process make test-corpus   # one process per call
                                                # (its own reference, see above)

In session mode a sample changes which files share a session, so its results
are not comparable with a full reference built from all files of a make.

Harness: `src/test-cli/corpus.lua` (case list, configuration, phases, exit
status; uses `Runner`, `Compare` and `Report`), `src/test-cli/CorpusDriver.lua`
(the driver with timeout, readback and cleanup; `runMake`/`Session` for
session mode), `src/test-cli/CorpusReport.lua` (`summary.md`, the known
deviations).

### Reading the results

Like the golden harness, `test-corpus-out/` holds `summary.txt`,
`failures.txt` and `results.json`, plus **`summary.md`**:

- the head line `n/m identical, k known (Perl internals), d differing`;
- per case type: cases, identical, known, differing, timeouts;
- the known deviations (below) with their reason, counted separately;
- per Lua module: the deviations, split by case type. The attribution is a
  heuristic on the reference side: the group of the first differing line
  (`[Canon]` in `-G1`, `<Canon:…>` in `-X`, for `-j` the tag name looked up in
  the same file's `-X` reference, for `-v3` the nearest enclosing
  `(SubDirectory) -->`/`[… directory`), mapped to the module of its table; a
  Lua error (traceback on stderr) is blamed on the module of its top frame;
  without a group the manufacturer stands in (`(make) X`);
- timeouts/hangs and Lua errors, each with its case path;
- the most frequent diff patterns (first differing line without values);
- every deviation with its first 3 diff lines.

Inspect a case as usual:

    diff -r test-corpus-ref/read/v3/Canon~CanonEOS_5D.jpg \
            test-corpus-out/read/v3/Canon~CanonEOS_5D.jpg

### Known deviations

Cases whose difference comes from internals of the Perl interpreter and
cannot be reproduced by the port. They are listed in `src/test-cli/Known.lua`
(the golden cases as `Known.GOLDEN`) and in `src/test-cli/CorpusReport.lua`
(the corpus cases as `KNOWN`), and count as "known (Perl internals)" in
`summary.txt` and `summary.md` instead of as deviations -- but only while the
difference has exactly the recorded form (only the named file, only the named
lines missing or reordered). Any other difference in the same case makes it
an ordinary deviation again; a known case that has become identical is
reported so its entry can be removed. Nothing is suppressed. The Perl
self-checks (`make test-cli-perl`, `make test-corpus-perl`) have no known
cases.

| Case | Case type | Reason |
|---|---|---|
| `Sigma.x3f` (golden) | `read/dump-v`, `read/dump-v2`, `read/dump-v3`, `read/dump-v5` | The same `$lensModel` warning as the Canon corpus cases below (the X3F file has no LensModel). |
| `Garmin~GarminDashCam55.jpg`, `Motorola~MotorolaC261.jpg`, `Reconyx~ReconyxHYPERFIRE_HP4K.jpg`, `Samsung~SamsungHMX-H300.jpg`, `Sony~SonyDPP-FP60.jpg` | `read/v3` | Several Conv warnings appear in the order of `keys %VALUE` in GetInfo, i.e. in Perl's hash order (the interpreter's hash function and bucket layout). |
| `Canon~CanonEOS-1D.jpg`, `Canon~CanonEOS-1DS.jpg`, `Canon~CanonEOS-1DSmkII.jpg`, `Canon~CanonEOS_D30.jpg` | `read/v3` | `Use of uninitialized value $lensModel in pattern match (m//)` (Canon.pm PrintLensID, `$lensModel =~ / \+ ((EXTENDER )?RF)?.../`): Perl reads the variable name from its op tree, the facade sees only the value; by the rule of `perl.num` undef never warns in the port, and a name parameter at the call site would move the Lua line away from the Perl line (conventions §3a). |
| `Leica~LeicaM.jpg`, `Leica~LeicaS2.jpg` | `write/w-Artist` | An uncaught Perl warning (`Use of uninitialized value in subtraction (-) at .../Writer.pl line 6163, <EXIFTOOL_FILE2> chunk 14.`) names Perl's source file, line and input chunk. |
