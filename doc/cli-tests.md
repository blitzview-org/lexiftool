# CLI golden tests: lexiftool vs. the original exiftool

The CLI harness (`src/test-cli/`) compares `lexiftool` **byte for byte**
against the vendored Perl `exiftool` (`vendor/exiftool/exiftool`): every
option against one representative per format family, and every format
against a few broad calls (see "Scope").

Run by hand, the harness is a report: `make test-cli` lists the cases in
which the two tools differ and exits 0. It exits 2 when the harness itself
did not get through (a worker died, or a case exists in one tree only). With
`TEST_CLI_EXPECT_IDENTICAL=1` any difference beyond the exactly matching
known ones (see "Known deviations") exits 1; the self-check
`make test-cli-perl` always sets it, and CI sets it for lexiftool too.

## Principle

1. A **matrix** of invocations (`src/test-cli/Cases.lua`) is applied to the
   test images.
2. Every case runs **twice with exactly the same argv**: once with
   `lexiftool`, once with the Perl `exiftool`.
3. Each run leaves **one directory** holding everything it did: stdout,
   stderr, exit code, and the files it worked on.
4. Rather than normalising differences away afterwards, the harness creates
   **identical preconditions** for both sides (see "Determinism").
5. The comparison runs **afterwards** over the two resulting trees.

```
runner:  one tool -> one observation tree   (produces only)
compare: two trees -> results               (compares only)
```

The runner knows only the tool's command line; the comparison knows neither
tool nor case list -- the trees describe themselves. Which tool fills the
test role is a profile name (`TEST_CLI_TOOL`), so "Perl against its own
reference" is the same program with a different profile. The role of each
harness file is described in its banner.

## Source of truth

The invocations are derived 1:1 from the canonical option reference of the
original (`vendor/exiftool/exiftool`, POD sections `Option Overview` and
`Option Details`; `vendor/exiftool/html/ExifTool.html`). No ad-hoc options
are invented.

## Environment

All variables are optional; the default is the full matrix.

| Variable | Meaning |
|---|---|
| `TEST_CLI_TOOL` | profile in the test role: `lexiftool` (default) or `exiftool-perl` |
| `TEST_CLI_TRACK` | groups to run: `read`, `write`, `dir`, `stay`, `expr` or `all` (default) |
| `TEST_CLI_SCOPE=all` | every variant against **all** images instead of the core selection (much slower; explicit image lists stay) |
| `TEST_CLI_IMAGES` | space-separated basename patterns, e.g. `'*.jpg *.png'` |
| `TEST_CLI_LIMIT` | maximum number of images |
| `TEST_CLI_JOBS` | worker count (default: CPU cores) |
| `TEST_CLI_REGEN` | rebuild the reference tree from scratch and stop (`make test-cli-gen`) |
| `TEST_CLI_EXPECT_IDENTICAL=1` | any difference beyond the known ones fails (exit 1) |
| `TEST_CLI_LUA` | Lua interpreter to launch (default `lua5.5`) |
| `TEST_CLI_ROCKS_VER` | Lua version for the rocks paths (default `5.5`) |
| `TEST_CLI_LUA_PATH`, `TEST_CLI_LUA_CPATH` | module search paths of the child (default: the local rocks tree) |
| `TEST_CLI_PERL` | Perl interpreter for the reference and the self-check (default `perl`) |

The reference Perl needs the optional modules for which lexiftool has a
counterpart, or the cases that reach them differ: `Archive::Zip`,
`IO::String`, `IO::Compress::Brotli`, `Compress::Raw::Lzma`,
`Unicode::LineBreak` and `Term::ReadKey`, and on Linux `File::StatX` (without
it exiftool extracts no `FileCreateDate`). `exiftool -ver -v` lists which of
them a Perl has.

## Running

Three targets, in the order in which they are used; they differ only in
which tool fills which role:

```
make test-cli-gen     # 1. BUILD the reference: Perl exiftool -> test-cli-ref/
make test-cli-perl    # 2. VALIDATE the harness: Perl vs. reference (must be 100%)
make test-cli-lua     # 3. TEST the port: lexiftool vs. reference
make test-cli         #    alias for test-cli-lua
```

The order is a dependency: a reference that `test-cli-perl` has not
confirmed says nothing about the port. `test-cli-gen` only builds the
reference and compares nothing.

The reference tree `test-cli-ref/` is built once and reused. Missing cases
(a new variant or image) are filled in by the next run in its own phase, so
`test-cli-gen` is needed only to invalidate the whole tree: after updating
`vendor/exiftool`, changing `TZ`/`LC_ALL` or switching the reference Perl.
The comparison notices such a mismatch itself (each tree records its
environment in `run.txt`) and refuses to compare. An interrupted run resumes
where it stopped.

Narrowing works the same for all targets, e.g.
`TEST_CLI_TRACK=read TEST_CLI_IMAGES=ExifTool.jpg make test-cli`.

## Reading results

Both trees (`test-cli-ref/`, `test-cli-out/`, gitignored) have the same
layout: one directory per case, `<group>/<variant>/<case>`, holding
`stdout.txt`, `stderr.txt`, `exit.txt`, the fingerprints of `work/` before
and after the call (`stat-before.txt`, `stat.txt`) and `work/` itself. A
case is therefore inspected with an ordinary `diff`:

```
diff -r test-cli-ref/write/w-o/GIF.gif test-cli-out/write/w-o/GIF.gif
```

At the root of `test-cli-out/`, `summary.txt` gives the score per variant,
worst first, and for each differing case the **file** that differs (for
files under `work/`: content, size, mtime or permissions); `failures.txt` is
the same list as TSV, `results.json` the machine-readable form.

A variant whose reference left nothing on any channel in **every** case
(empty stdout and stderr, exit 0, `work/` unchanged) is marked `SILENT`: it
proves nothing and usually hides a construction error in the matrix (a
missing `=`, a shell-expanded `$TAG`). Check it by hand on a suitable image.

## Scope: every option, not every format

Every option runs against a **core selection** (`CORE_IMAGES` in
`Cases.lua`, one representative per format family); every format is covered
by a few variants with `scope = 'all'` (`read/default`, `read/a-u-ee-G1`,
`write/w-Subject`, `read/imageDataHash`). A variant that only matters for
certain formats names its images explicitly (see "Extending the matrix").

Images come from `vendor/exiftool/t/images/` (never modified) and
`src/test/images/` (the port's `lex_` fixtures, see
[its README](../src/test/images/README.md)).

## Determinism

Each case runs in its own `work/` with relative file names. Inputs are
copied with mode 0644 and their times pinned to a fixed future timestamp;
ctime, which no syscall can set, is faked via a preload shim
(`tools/ctime_fake*.c`; on macOS this needs a non-SIP Perl). Both sides run
with `TZ=UTC`, `LC_ALL=C`, `PERL_HASH_SEED=0`, `PERL_PERTURB_KEYS=0`; a case
whose Perl result depends on the order of a hash keyed by references does
not belong in the matrix. Output is never rewritten (CRLF included).

## What counts as identical

Everything is compared byte for byte, with two exceptions:

- **Exit codes** are compared by outcome (both zero or both non-zero); the
  value of a non-zero code is the implementation's (see `differences.md`,
  "`-k` without a console").
- **The source location** Perl appends to a `die`/`croak` message (`at FILE
  line N.`) is neutralised on both sides; the message before it must agree.

A difference from Perl interpreter internals, or from an obvious exiftool
bug the port does not reproduce, is a known deviation (see "Known
deviations").

## Deliberate differences

Where lexiftool differs on purpose (`doc/differences.md`), a byte comparison
cannot be green; those cases are covered by `src/test/test_cli_port.lua`
(and Perl config files by `src/test/test_perlconfig.lua`), and the golden
covers only the common part. `-ver -v` is not in the golden (Lua
counterparts instead of Perl module versions); `-ver` alone is.

The help text (`--help`) is generated from the original's, see
`CONTRIBUTING.md`, "Help text"; it is checked by `src/test/test_usage.lua`,
not by the golden.

## Extending the matrix

The tables `READ`, `WRITE`, `DIR` and `STAY` in `src/test-cli/Cases.lua` are
the only place where variants are maintained; each row is
`{ label = '...', args = '...' }`.

Which table a new option belongs to:

- works on **one** file and writes nothing -> `READ`
- works on **one** file and writes -> `WRITE`
- operates on a **directory** (renames, timestamps, backups, multiple
  output files) or needs no file at all -> `DIR`
- a `-stay_open` session -> `STAY`

Which images a row runs on:

| Field | Images |
|-------|--------|
| (none) | the core selection (`CORE_IMAGES`) |
| `scope = 'all'` | every selected image |
| `images = { 'lex_Vorbis_TagNames.flac', 'Vorbis.ogg' }` | exactly these (basenames from both image directories; an unknown name stops the build) |

Placeholders in `args` (substituted literally; exiftool's own `%Y`, `%%f`
stay):

| Placeholder | Meaning |
|-------------|---------|
| `@@`        | the case's file, `in/<image>` (one case per image) |
| `%IN%`      | `in` |
| `%OUT%`     | `out` (created empty) |
| `%SRC%`     | `src.jpg`, the source for `-tagsFromFile` / `-file1` |
| `%ARGFILE%` | `args.txt` (a growing argument file for `-@`) |
| `%AUX%`     | the untouched image directory (read-only) |
| `%REPO%`    | the repository root (read-only) |

A `STAY` row adds a `feed` list: text sent to the tool as is,
`{ ready = N }` (wait for N `{ready` marks), `{ sleep = S }` and
`{ file = NAME }` (send the bytes of `work/NAME`); `via = 'file'` writes the
feed to `%ARGFILE%` instead of stdin. `feed.txt` records every step and
whether its wait was answered.

After adding a variant, run `make test-cli-perl`: it builds the missing
reference cases and must stay at **100%**, otherwise the variant is not
deterministic. Then run `make test-cli-lua`.

### Expression corpus

`src/test-cli/Expressions.lua` (group `expr`) holds Perl expressions from
real exiftool command lines (`-if`, advanced formatting, `-p`, `-api
Filter=`), taken verbatim from the documentation, forums and blogs, each with
its source URL. To add one: append an entry with the next free id of its
kind (ids never change), the expression verbatim in a long string, its
`src` and a short `note`, then run `make test-cli-perl` and
`make test-cli-lua`. The fields are described in the file's banner.

## Corpus run

The corpus run (`make test-corpus`) applies the same mechanics to an
external corpus of real camera files: by default Phil Harvey's sample images
(<https://exiftool.org/sample_images.html>, one directory per manufacturer).
The page states no licence, so the images are only fetched on demand
(`make corpus-fetch [CORPUS=<dir>]`, offline: `tools/fetch_corpus.sh
--offline` over archives put into `<dir>/archives/`) and never committed.
Any directory of the form `<dir>/<group>/<file>` works as a corpus
(`CORPUS=<dir>`).

Per file the cases `read/a-u-G1`, `read/j-t`, `read/v3`, `read/X-struct`,
`write/w-Artist` and `write/w-all` (the written file is read back with
`-a -u -G1`), and per manufacturer a scripted `-stay_open` session
`stay/s-make`. The targets mirror the golden ones:

    make test-corpus-gen    # 1. build/complete the reference (Perl)
    make test-corpus-perl   # 2. Perl against the reference: must be 100%
    make test-corpus-lua    # 3. lexiftool against the reference
    make test-corpus        #    alias for test-corpus-lua

`make test-corpus*` runs `make corpus-fetch` when `CORPUS` is missing; the
`TEST_CLI_LUA`/`_ROCKS_VER`/`_LUA_PATH`/`_LUA_CPATH`/`_PERL` variables and
the reference Perl's modules are those of the golden harness. Further
variables:

| Variable | Meaning |
|---|---|
| `TEST_CORPUS_MODE` | `session` (default): all calls of a manufacturer as commands of one `-stay_open` session per tool; `process`: one process per call. Each mode has its own reference, since a session's Perl keeps module state across commands |
| `TEST_CORPUS_MAKES` | only these manufacturers, e.g. `'Canon Nikon'` |
| `TEST_CORPUS_TRACK` | `read`, `write` or `stay` |
| `TEST_CORPUS_SAMPLE`, `TEST_CORPUS_SEED` | a reproducible sample of N files (in session mode not comparable with a full reference) |
| `TEST_CORPUS_TIMEOUT` | time limit per call in seconds (default 60); a timeout is recorded as exit 124 |
| `TEST_CORPUS_JOBS` | worker count |
| `TEST_CORPUS_EXPECT_IDENTICAL=1` | any deviation beyond the known ones exits 1 |

The trees `test-corpus-ref/` and `test-corpus-out/` (about 2 GB per tree)
have the golden layout and are both resumable. Every call runs from the tree
root with relative paths. `test-corpus-out/summary.md` adds the deviations
per case type and per Lua module, timeouts and Lua errors, and the first
diff lines of every deviation. The exit status follows the golden harness.
The workflow `.github/workflows/corpus.yml` runs all three steps on demand.

### Known deviations

Cases whose difference comes from internals of the Perl interpreter, or
from an obvious bug in exiftool or in Perl that the port does not reproduce
(`doc/differences.md`, "Upstream bugs the port does not reproduce"), are
listed in `src/test-cli/Known.lua` (`Known.GOLDEN`, `Known.PERL_BUGS`) and in
`src/test-cli/CorpusReport.lua` (`KNOWN`), each entry with its reason. They
count as "known" instead of as deviations -- but only while the difference
has exactly the recorded form:

- only the named file differs, and in it only the recorded lines (missing,
  reordered, or without Perl's variable name);
- `hash-order`: exactly the other of two variants recorded verbatim, where
  exiftool's result depends on its hash order (`doc/differences.md`,
  "Results that depend on Perl's hash order");
- `upstream-bug`: the reference shows exactly exiftool's abort (non-zero
  exit, the recorded `die` message, a prefix of the output) and the test
  side exactly the expected result, taken from a named twin image;
- `upstream-fix`: exiftool prints a wrong result where the port prints the
  right one; the recorded edits per file (lines replaced, inserted or
  removed, found in order, or for binary output such as `-b` the exact
  bytes of a fixture) turn the reference into exactly the test side, and no
  other file differs;
- `perl-bug`: only for a reference built by a Perl of the recorded platform
  and releases, and every differing line shows exactly the bug's wrong value
  in the reference and the right one on the test side.

Any other difference in the same case makes it an ordinary deviation again;
a known case that has become identical is reported so its entry can be
removed. Nothing is suppressed. The Perl self-checks have no known cases.
