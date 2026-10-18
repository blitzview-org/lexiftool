# API contract — the `perl` facade and the public surface

This document is the contract for the intermediate API. Ported modules may
call **only** the functions listed here for operations that map to a Perl
builtin; they never call raw `string.*`/`table.*`/`os.*` for those
operations.

Module: `src/lexiftool/perl.lua`, loaded as `require('lexiftool.perl')`.

## 1. Conventions: Perl semantics everywhere

The facade follows **Perl conventions**, not Lua's:

- **0-based indices and string offsets**, matching Perl arrays and
  `substr`.
- **Negative offsets count from the end** (`-1` = last position), matching
  both Perl and Lua — passed through 1:1 without translation.
- `perl.length` returns the **byte length** (Perl without Unicode magic) —
  important for binary tag values.
- `perl.split` treats the separator as a **regular expression** (Perl
  semantics), not a fixed Lua string.
- `perl.sprintf` follows **Perl formatting semantics** (no Lua `%q`/`%a`
  dialect); `perl.str` produces Perl's SV-style number stringification.

Translation happens exclusively inside the facade and its backends (e.g.
`+1` shift into Lua's 1-based positions). This keeps ported logic
numerically identical to the Perl original. A future `carray` backend is
1-based internally; only the facade adapter knows this.

## 2. Core functions

| Perl original | Facade call | Notes |
|---|---|---|
| `$val = unpack(FMT, $s)` | `perl.unpack(FMT, s)` | whole string from offset 0 (Perl semantics) |
| `unpack` + position tracking | `perl.unpack(FMT, s, off)` | facade extension: off is 0-based bytes, returns (values..., next_off) |
| `pack(FMT, ...)` | `perl.pack(FMT, ...)` | |
| `tell(FH)` | `perl.tell(fh)` | the file position on a plain file; on a pipe or character device (/dev/null) the bytes `perl.print` wrote to the handle, as PerlIO counts them |
| `substr($s, $o, $l)` | `perl.substr(s, o, l)` | 0-based; negative o/l go through |
| `substr($s, $o, $l) = $v` | `perl.substr(s, o, l, repl)` | lvalue form returns modified string |
| `length $s` / `scalar @a` | `perl.length(x)` | bytes for strings, count for lists |
| `$a[$i]` | `perl.at(list, i)` | 0-based |
| `$s =~ /(pat)/; $1, $2, ...` (no `/g`) | `perl.matches(s, pat[, pos])` | returns captures as a list (like `$1,$2,...`; nil for a group that took no part), plus end pos |
| `if ($s =~ /pat/)` (scalar/boolean context) | `perl.isMatch(s, pat[, pos])` | true followed by the captures, or false; required where the first group may be unset (conventions §6) |
| `my @all = $s =~ /pat/g` (list context) | `perl.findAll(s, pat)` | flat array of all matches/captures |
| `while ($s =~ /pat/g) { ... }` (loop context) | `for ... in perl.eachMatch(s, pat) do ... end` | drop-in for Lua's own `string.gmatch`, PCRE2-backed; values only, no position |
| `$s =~ s/pat/repl/g` | `perl.subst(s, pat, repl[, 'g'])` | `repl` in Perl's syntax: `$1`, `${1}`, `$&`, `\$`; see §2b |
| `$s =~ s/pat/CODE/e` | `perl.subst(s, pat, function(c1, c2, ...) ... end)` | the captures arrive as arguments |
| `$s =~ tr/SEARCH/REPL/cds` (also `y///`) | `perl.tr(s, search, repl[, flags])` | byte-wise; returns (new string, count); ranges and backslash escapes as in perlop |
| `eval $code` on `$_`, where `$code` is only `tr///`/`y///`/`s///` statements | `perl.compileEdit(code)` | returns `function(v) -> v'`, or nil for anything beyond that subset (treat as an eval that failed to compile); used for the `Filter` option |
| `eval $code` of user code (the `-if` condition, `${TAG;EXPR}`) | `perl.eval(code, vars[, funcs])` | an interpreter for the subset of Perl such code uses (perl.lua lists it; doc/differences.md for users); variables by name in `vars` (`$_` is `vars._`, written back), helper functions in `funcs`; dies with Perl's `syntax error ...`, or with `Perl syntax unsupported in lexiftool: WHAT (near "...")` for valid Perl outside the subset -- `perl.isUnsupported(e)` tells that one apart |
| `$ENV{NAME}` (read) | `perl.getenv(name)` | only where upstream reads %ENV (the .ExifTool_config lookup); writing is `perl.setenv` |
| `eval { require Module }` | `ok, mod = perl.evalRequire('Module::Name')` | true plus the module (`Module::func` is `mod.func`), or false; `Module::Name` maps to the Lua module `Module.Name`, except: Time::Piece and Term::ReadKey are the facade's own, and IO::Uncompress::Brotli/IO::Compress::Brotli are `unbro`/`bro` over the optional rock `lbrotli` (string or carray in, string out; unbro ignores data after the stream, bro defaults to quality 11, window 22), missing when lbrotli is not installed; Time::HiRes has `gettimeofday()` (a table `{ sec, usec }`, Perl's list) and `tv_interval(t0[, t1])` over the wall clock of `lexiftool.sys` |
| `-r $file` (and `-e -f -d -p -s -l`) | `perl.filetest(op, path)` | `op` is the letter; `-r`: the file can be opened for reading |
| `split /re/, $s` | `perl.split(pat, s[, limit])` | regex separator, returns array |
| `split /re/, $s` (only ever looped over) | `for w in perl.eachSplit(pat, s[, limit]) do ... end` | streaming sibling of `perl.split`; same semantics, no array materialized |
| same, but `pat` built at runtime (`/$var/`) | `perl.matchesDyn`/`isMatchDyn`/`findAllDyn`/`substDyn`/`splitDyn`/`eachMatchDyn`/`eachSplitDyn` (same signatures) | no compiled-pattern cache; see §2a |
| `lc/uc/lcfirst/ucfirst $s` | `perl.lc(s)`, `perl.uc(s)`, ... | |
| `ord $c` / `chr $n` | `perl.ord(c)`, `perl.chr(n)` | |
| `sprintf(FMT, ...)` | `perl.sprintf(FMT, ...)` | Perl semantics |
| `sort LIST` / `sort { ... } LIST` | `perl.sort(list[, cmp])` (new list), `perl.tsort(list[, lt])` (in place; never `table.sort`) | strings ordered as bytes, whatever the host's `LC_COLLATE`; a Perl sort block is stable |
| `$a cmp $b`, `$a lt $b` (`gt`: `perl.lt(b, a)`) | `perl.cmp(a, b)`, `perl.lt(a, b)` | stringified, compared as unsigned bytes (Lua's `<` on strings uses `strcoll`) |
| number → string (SV) | `perl.str(n)` | Perl-compatible rounding/formatting |
| `"$val m"`, `$a . $b` with a number | `perl.str(val) .. ' m'` | Lua's `..` prints an integral float as `2.0`; a value that may be a number is stringified through `perl.str` (as the file-local alias where the module has no `$str` of its own) |
| string → number (`$x / 2`, `$x + 0`, `$x < 3`) | `perl.num(x[, op])` | leading numeric prefix, hex is 0, Inf/NaN; with `op` (the Perl operator: `'/'`, `'+'`, `'*'`, `'<'`, `'**'`, ...) a non-numeric string warns like `use warnings` (`Argument "undef" isn't numeric in division (/)`) through `perl.warn`, i.e. a `$SIG{'__WARN__'}` handler; `perl.int`/`perl.log`/`perl.sprintf` warn the same way ("in int", "in sprintf"); undef numifies silently (Perl's "Use of uninitialized value $name" names the variable) |
| string building `$buf .= $x` | `buf:append(x)` on a carray (`require('carray')`) | mutable byte buffer; see §4 |
| `join($sep, @a)` | `perl.join(sep, list)` | elements stringified like Perl (`708`, not `708.0`) |
| `log($x)` | `perl.log(x)` | dies like Perl for x <= 0 ("Can't take log of 0") |
| `die $msg` inside an eval'd conversion | `perl.die(msg)` | tagged error: GetValue leaves the value undefined and warns `ValueConv Tag: msg`, as upstream's `eval`; any other Lua error propagates (`perl.isDie(e)` tells them apart) |
| `"$x / ${x} / $a[0] / $h{k}"` | `perl.interp(s, env)` | opt-in, see §4a |
| `defined $x` / `exists $h{k}` | `perl.D(x)` / `perl.E(h, k)` | explicit helpers (Lua has no autovivification) |

**lpcre functions behind the regex facade.** The match functions are thin
over lpcre: `perl.matches`/`matchesDyn` are a
tail call of `lpcre.matchpos` (captures or `true`, then the inclusive
1-based end, which is Perl's 0-based `pos()`); `perl.isMatch`/`isMatchDyn`
use `lpcre.test` for a pattern without groups (number of groups per
pattern string memoized from `regex:ncapt()`), `lpcre.find` for one with
groups (`true, captures...`); `perl.eachMatch`/`findAll` (and the `*Dyn`
forms) use `lpcre.findmatch` for a pattern without groups (the match text
comes from C, also for a carray, nothing is packed) and `lpcre.find` for
one with groups; `perl.split`/`eachSplit` use `lpcre.find`; `perl.subst`
uses `lpcre.gsub`. All of them pass Perl's undef for a group that took no part
as nil (lpcre's default, no `UNSET_FALSE`).

## 2a. Regex: cached vs. dynamic patterns

`perl.matches`/`perl.subst`/`perl.split`/`perl.findAll`/`perl.eachMatch`/
`perl.eachSplit` hand `pat` as a string to the regex backend, the `lpcre`
rock (PCRE2; `require('lpcre')` in `perl.lua` only), which compiles it once
and keeps it in its pattern cache (LRU, keyed by the pattern string; the
facade sets its size to 1024, measured: one CLI call on one file uses up to
a few hundred distinct literal patterns) — use these when `pat` is a fixed string in the ported source,
matching the corresponding literal `/pat/` in the Perl original.  The
subject may be a Lua string or a carray (§4): lpcre matches a carray on its
buffer, without a copy.

**Rule: alternation (and anything else beyond Lua-pattern features) goes
through the facade.** When an upstream regex contains `|`, optional groups,
backreferences, lookaround or `{n}` quantifiers, do NOT transliterate it
into Lua-pattern syntax and do NOT hand-split it into sequential matches --
copy the regex verbatim into `perl.matches`/`matchesDyn`. Rationale:

- Lua patterns have no `|`; a transliterated `(A|B|C)` silently becomes a
  literal string and never matches (this trap has hit five separate modules:
  DICOM VR trimming, EXE CodeView signatures, MXF GPS types, Photoshop PSB
  blocks, RIFF compressed-audio types -- all found in one audit).
- Sequential Lua match calls as an "or"-chain re-scan the subject once per
  alternative; the compiled PCRE2 alternation scans once, in C.
- Verbatim copying removes the whole transcription-error class: the pattern
  in the Lua source is diffable against the Perl original.

Simple membership tests that we introduce ourselves (not upstream regexes)
are best served by a plain Lua lookup table; short literal prefixes stay
`string.sub`/`string.match`. Everything regex-shaped comes from upstream ->
facade.

When the Perl original builds the pattern at runtime (`/$var/`, interpolated
`qr/.../`, e.g. `AFCP.pm`'s `/$hdr/`, `GIF.pm`'s
`/$$extInfo{Terminator}/g`, `InDesign.pm`'s `/^\Q$masterPageGUID/`,
`FlashPix.pm`'s `/$pat/`, `ID3.pm`'s `/$pat/sg`), use `perl.matchesDyn`/
`substDyn`/`splitDyn`/`findAllDyn`/`eachMatchDyn`/`eachSplitDyn` instead:
same signatures and semantics, but the pattern is compiled fresh on every
call (`lpcre.new(pat, "n")`, lpcre's NOCACHE flag) and never entered into
the cache. Caching by pattern string at a call site whose pattern differs
on every call would otherwise evict the literal patterns, one throwaway
entry per call. The `*Dyn` functions also take such a precompiled regex
object; the facade's own Perl-code compilers (`perl.compileEdit`, the
regex and `s///` parts of `perl.eval`) compile their pattern once that way,
with Perl's `/imsx` passed as lpcre's flag letters.

## 2b. Regex: the replacement string stays Perl's

`perl.subst`/`perl.substDyn` take the replacement in **Perl's** syntax, and
translate it for the `lpcre.gsub` underneath (string.gsub's syntax):

| in the port (as in Perl) | means |
| --- | --- |
| `$1` … `$9`, `${1}` … `${9}` | the n-th capture |
| `$&` | the whole match |
| `\$` | a literal dollar sign |
| `%` | a literal percent sign |

This is not cosmetic. The backend spells a backreference `%1`, so a
replacement copied over from Perl unchanged used to insert the two literal
characters `$1` — silently, with no error and no failing test. It had done
so in four modules (`GoPro`, `MXF`, `Panasonic`, `Plot`) before anyone
noticed. The backend also treats `%` as its own escape, so `"50%x"` came out
as `"50x"`. Both are now the facade's problem rather than the caller's, and
`make verify` rejects a `%1` written into a replacement.

For Perl's `/e` (code instead of a string), pass a **function**: it receives
the captures as arguments (nil for a group that took no part, Perl's undef)
and returns the replacement.

## 3. `unpack` format subset

Only the templates exiftool actually uses are implemented; the set grows
test-driven as `t/*.t` go green. Tracked here; start with:

`H* a* A Z c C s S i I l L n N v V x X @ ...`

(Supersets and Perl edge semantics are documented per code as they are added.)

Templates of one fixed-size numeric code -- with a count, `*`, a run of the
same code (`NN`) or a leading `x<N>` -- are compiled once per template
string into a reader closure (`UNPACK_FAST`, same results as the general
token loop, vectors from perl 5.42 in `test_perl_facade.lua`); `pack` of
one numeric code without a count likewise (`PACK_FAST`). `A` strips
trailing NULs and all whitespace (`\t\n\v\f\r` too, as pp_pack.c), `pack`
numifies a string by its numeric prefix (`"0x10"` is 0).

## 4. Mutable byte buffers (`carray`)

Perl's mutable string scalar (`$dataPt`, `\$dataPt`) maps to the `carray` C
module (a 1-based, in-place-mutable `char` array) rather than a Lua string
(immutable). Ported code uses `require('carray')` directly; there is no
facade buffer constructor.

The `perl` facade string primitives accept **both** a Lua string (read-only)
and a carray (mutable), dispatching on `type(x) == "string"`:

- `perl.length(x)` → `#x` for a string, `x:len()` for a carray.
- `perl.substr(s, off, len[, repl])` → read form works on string or carray and
  returns a copy; the replacement (4-arg) form mutates its argument and
  therefore only accepts a carray (a Lua string there is an error).

This matches Perl's semantics: read-only string operations work on either
representation, while a mutating operation requires a mutable scalar.

The rule holds for write buffers just the same: every Perl string scalar
that gets changed -- `substr(...) = ...` / 4-argument `substr`, `.=`,
`Set32u($v, \$buf, $pos)`, `$fixup->ApplyFixup(\$buf)` -- is a carray from
where Perl creates it (`my $buff = ''` is `local buff = carray.new('char')`,
`$buff .= $x` is `buff:append(x)`, the replacement may be a string or a
carray) and becomes a string again only where Perl hands it to code that
takes a value (return, a hash key, `DataPt` of another module, a CHECK or
conversion routine). When in doubt, use a carray. There is no
string-returning "lvalue substr" helper (`perl.substrAssign` is gone); a
short-lived edit of a string is spelled `local b = carray.new('char'):append(s)`,
`substr(b, off, len, val)`, `s = b:tostring()`. Lua strings stay for
everything Perl does not change.

On a carray, `perl.matches`/`isMatch`/`findAll`/`eachMatch` read its bytes
in place (no copy), `perl.subst` (lpcre.gsub on the carray) and `perl.tr`
(byte translation on the buffer, cut to the new length) edit it in place
(and return it, so `buf = subst(buf, ...)` reads the same for both
representations), `perl.str` yields its bytes,
`perl.truthy` tests them like Perl tests the scalar (empty or `"0"` is
false) and `Writer.Write` writes them. `buf:append(n)` with a Lua *number*
appends one byte, not its digits -- append strings (`entry .. value`
coerces as Perl's `.` does).

**Scalar references (the box).** Perl's reference to a scalar (`\$buf`,
`$$dataPt = ...`, an `$outfile` that is a SCALAR ref) is the box
`{ value = ... }` (with `ref = 'SCALAR'` where `ref()` must recognise it).
Whenever the referenced scalar is changed anywhere -- an output file written
in memory, a trailer buffer, a parse cursor that is eaten from the front
(PDF `ExtractObject`/`ReadToNested`, `InflateStruct`), a block decrypted or
validated in place -- the box holds a **carray**, created with the box:

| Perl | Lua |
|---|---|
| `my $buff = ''; OutFile => \$buff` | `local buff = carray.new('char')`, `OutFile = { value = buff }` |
| `Write($outfile, ...)` / `$$outfile .= $x` | `Write(outfile, ...)` / `outfile.value:append(x)` |
| `substr($$dataPt, $pos, $len) = $x` | `substr(dataPt.value, pos, len, x)` |
| `$$dataPt = substr($$dataPt, $n)` | `substr(dataPt.value, 0, n, '')` |
| `$$outfile = $hdr . $$outfile` | `outfile.value = carray.new('char'):append(hdr, outfile.value)` |
| `$$outBuff = $value` | `outBuff.value = carray.new('char'):append(value)` (nil stays nil) |
| `Tell($outfile)`, `length $$outfile` | `Writer.Tell(outfile)`, `length(outfile.value)` |

`Writer.Write` appends to the box's carray (an undefined value starts one,
as `.=` on undef does); `Writer.Tell` is its length. A box never answers
`:write`/`:tell` itself, and there are no ad-hoc append-only buffer objects:
every in-memory output is a box. The value becomes a string again at the
Perl line that uses it as one -- `return $buff` (`buff:tostring()`), a hash
key, a value handed to another module (`DataPt`, a CHECK or conversion
routine, `RandomAccess.new` takes a carray too), string concatenation, CRC
or zlib input. Boxes whose scalar is only read (binary tag values,
`{ ref = 'SCALAR', value = 'Binary data 1234 bytes' }`, indirect PDF
references, the iCCP profile name) keep their Lua string; boxes that carry a
non-string value (CheckXMP's `$valPtr` when it holds a structure, the path
and change counter of `DeleteStruct`) hold that value.

## 4a. String interpolation (`perl.interp`, opt-in)

Optional facade helper that rebuilds Perl string interpolation where keeping
the literal string verbatim matters for parity. Signature:

`perl.interp(s, env)` — `s` is a Perl-style double-quoted string; `env` is a
table providing values selected by the interpolation forms used:

- `$var` / `${var}` → `env.var` (scalar)
- `$a[0]` → `env.a` (list, 0-based via `perl.at`)
- `$h{k}` → `env.h` (hash table)
- `$x->{f}` → `env.x.f` (deref)

Not for use in hot paths (regex/parse loops) — `..` concatenation there
stays preferred. Add forms only as exiftool sources require them; the set is
tracked test-driven like the `unpack` subset.

## 5. Backend selection

Backends are interchangeable implementations of the facade with identical
signatures.

- Default: **auto-detect** (pure-Lua for now; may prefer a native backend on
  LuaJIT, where native `string.pack` is absent).
- Explicit override for tests/benchmarks:
  - `_G.LEXIFTOOL_BACKEND = 'lua'` for CLI use (read at facade load; the only
    library-level config. No `os.getenv` — the caller passes the global via
    `lua -e "LEXIFTOOL_BACKEND=..."`.)
- The backend is selected exactly once, when the facade module loads; there
  is no runtime switch. Ported modules may bind facade functions to local
  aliases at file scope without risking stale bindings.
- A backend must be loadable per-name; adding a backend never changes facade
  behavior visible to ported code.

## 6. Public Image::ExifTool API (required by upstream tests)

Function/method names must match the Perl original exactly.

- `ImageInfo`, `ExtractInfo`, `GetInfo`, `GetTagList`, `GetGroups`
  (`Family0..2`), `GetTagID`, `GetDescription`, `Options`, `CombineInfo`,
  `InsertTagValues`, `SetAlternateFile`, `AddUserDefinedTags`
- Helpers: `GetUnixTime`, `IsFloat`, `GetTagName`
- Options keys: `Duplicates`, `Unknown`, `Group0/1/2`, `Exclude`, `FastScan`,
  `Filter`, `ListItem`, `GlobalTimeShift`.
- `NO_SORT` is not an option but an object member, as upstream
  (`$$exifTool{NO_SORT}` ↔ `et.NO_SORT`); TestLib then lists the tags in
  `GetFoundTags()` order.
- Argument lists (`ImageInfo`, `GetInfo`, `ParseArguments`): Perl tells a tag
  list (`\@tags`) from an options hash (`{...}`) by the reference type. In Lua
  both are tables, so a table with a `[1]` entry -- or an empty table -- is the
  tag list, any other table the options hash. Like upstream, a tag list passed
  in is filled with the found tag keys afterwards (`IO_TAG_LIST`), and
  `GetInfo()` with no argument parses nothing and returns all tags, while
  `GetInfo(nil)` uses the tags requested before (upstream `GetInfo(undef)`).

**Writing to memory.** `WriteInfo(src, box)` and `WriteInfo(box)` (edit in
place) take the box `{ ref = 'SCALAR' }` / `{ ref = 'SCALAR', value = data }`
for Perl's `\$buf`; the input value may be a Lua string or a carray, and
`ImageInfo(box)` reads either. After writing, `box.value` is the **carray**
the library appended to (`WriteInfo(src, box)` always; in place only when
something changed -- otherwise the caller's value is left untouched, as Perl
leaves `$buf`). Read it with `box.value:tostring()`, `perl.str(box.value)`
or the facade's `length`/`substr`, or hand the box straight back to
`ImageInfo`/`WriteInfo`. Rationale: in Perl the caller's scalar *is* the
buffer the writers append to and patch in place (`Set32u` into
`$$outfile`, trailer fixups), so the port hands back that mutable scalar
instead of converting it at a point where Perl has no conversion; the
round trip write-then-read needs no copy, and appending several writes to
one box stays linear.

## 7. File access (`lexiftool.RandomAccess`)

Random-access file reads mirror the Perl `$raf` object (`File::RandomAccess`)
method-for-method; the port module is `require('lexiftool.RandomAccess')`.

- `raf:read(n)`, `raf:seek(pos[, whence])`, `raf:tell()`, `raf:length()`
- `raf:readfile()` (whole file)

Default implementation uses plain `io`; a carray/native backend may later
`appendfile` directly into a C buffer.