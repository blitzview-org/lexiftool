# Performance comparison with the Perl original

Every development snapshot and every release carries a performance
comparison of lexiftool with Perl ExifTool of the same version, measured
on the very Linux executable it offers: the bar chart (`benchmark.svg`,
`benchmark-dark.svg`) and the raw data (`results.json`) are attached to
the [latest-dev pre-release](../../../releases/tag/latest-dev) or the
release; the chart, the tables by file type and the method are the
repository's GitHub Pages site, <https://blitzview-org.github.io/lexiftool/>,
deployed from the same build (a release asset is served as a download,
which GitHub does not render as an image, so the README shows the chart
from there).

## What is measured

Both tools run on one GitHub-hosted Ubuntu runner, in the same job, case
by case: [hyperfine](https://github.com/sharkdp/hyperfine) starts the Perl
exiftool and lexiftool directly after each other (no shell in between),
2 warm-up runs, then 20 timed runs each (sessions and the directory run 5
times). The files come from the test images of the vendored ExifTool
(`vendor/exiftool/t/images`), copied to a temporary directory.

A **single call** -- one process for one file, the everyday use from a
script -- costs start-up, the loading of the format modules the file
needs, and the processing of the file. The chart shows the three as one
stacked bar per tool, as the mean over a mix of seven file types; the table
breaks the mix down by type. The parts come from three measurements:

| Measurement | Command | Gives |
|---|---|---|
| `start` | `-ver` | start-up alone |
| `read-<type>` | `-j -G1 FILE`, one process per call | the single call |
| `session-<type>` | `-stay_open True -@ ARGS`, 30 commands `-j -G1 FILE` | processing: (session minus `session-empty`) / 30 |
| `session-empty` | `-stay_open True -@ ARGS` with `-stay_open False` only | the session's own start and end |

Module loading is the single call minus start-up minus processing. The
mix: `Canon.jpg` and `Nikon.jpg` (JPEG with maker notes), `DNG.dng`,
`QuickTime.mov`, `PDF.pdf`, `XMP.jpg`, `Google.jpg` (JPEG with an HDR+
maker note from a Google Pixel, a 38 kB base64-encoded protobuf in the
XMP, the most compute-intensive of the mix).

The write is split the same way: `write-jpeg` (`-overwrite_original
-Artist=... copy.jpg`, a fresh copy per run) and `session-write` (30 writes
on the copy in one session, alternating two values so that every command
rewrites the file). `dir-read` (`-j -G1 -q -r IMAGES`) is one process over
all test images: throughput in files per second.

`session-jpeg` is the everyday batch job of a photo tool: one `-stay_open`
session reading ordinary camera and phone JPEGs, `-j -G1 FILE` per command.
The files are in `bench/images`, one per maker (Canon, Nikon, Sony,
Olympus, Panasonic, FujiFilm, Pentax, Apple), each taken in turn and four
times in all (32 commands); the report gives the time per command, the
empty session subtracted, as wall clock and as CPU time. The test images
of ExifTool are cut down to a few kilobytes (8x8 pixels, no thumbnail), so
these files are generated from them by `tools/gen_bench_images.sh`: the
complete metadata of one test image per maker, maker notes included,
copied by the Perl exiftool onto a 1000x750 gradient, plus a 160x120
thumbnail and, where the maker notes hold one, a 640x480 preview
([bench/images/README.md](../bench/images/README.md) lists the sources and
what the copy changes). The picture is small on purpose: the size of the
image data does not change the read time of either tool.

Per case and tool: **wall-clock time** (mean, minimum and standard
deviation of the timed runs; the mean is the bar), **CPU time** (user plus
system) and **peak memory** (the maximum resident set size of one extra run
under GNU `time`; the chart shows the mix mean of the single calls and the
directory run).

A GitHub runner is a shared virtual machine: the absolute times differ
from run to run by ten or twenty percent. The ratio between the two tools,
measured in the same run on the same machine, does not; the table shows
the standard deviation so the noise is visible.

## Running it yourself

```sh
sudo apt install hyperfine jq time lua5.4     # Debian/Ubuntu; Arch: pacman -S hyperfine jq time
make linux                                    # the standalone executable (podman), or
make bench BENCH_LEXIFTOOL=bin/lexiftool      # any lexiftool command line, e.g. the launcher of the checkout (after . ./activate.sh)
```

`make bench` runs `tools/bench_cli.sh build/bench PERL LEXIFTOOL RUNS` with
the vendored Perl exiftool and writes `build/bench/README.md` (the tables),
`index.html` (chart and tables as a page), `benchmark.svg`,
`benchmark-dark.svg` and `results.json`;
`tools/bench_report.lua` turns the measurements into those files and can
be run again on its own (`lua tools/bench_report.lua build/bench`).
Variables: `BENCH_LEXIFTOOL`, `BENCH_RUNS` (default 20; sessions and the
directory run a quarter of that, at least 3), `BENCH_PERL`; the script also
reads `BENCH_IMAGES`, `BENCH_JPEGS` (the camera JPEGs, default
`bench/images`), `BENCH_WARMUP`, `BENCH_SESSION` (commands per session,
default 30; `session-jpeg` takes every file the same number of times, at
least that many commands in all) and `BENCH_LUA`.

In CI (`.github/workflows/benchmark.yml`) the comparison runs after the
standalone build of every push to master and of every version tag, on the
Linux executable of that run, before the publishing job attaches
executables and results to the pre-release or release; on master the
Pages job (`.github/workflows/pages.yml`) then publishes chart and tables,
together with the download pages of the executables and the C API zips
(`tools/download_pages.lua`). Started by hand (workflow dispatch), it builds
the executable itself (the build is reproducible: the same commit gives the
same bytes as the published one) and shows the result in the job summary
and as a run artifact; with the `publish` option it also refreshes the
Pages site, the chart the README shows, without touching any release
(the download pages are rebuilt from the latest-dev pre-release as it
stands).
