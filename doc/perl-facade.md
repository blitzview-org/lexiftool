# The `perl` facade

Ported modules reach every Perl built-in through the facade
`src/lexiftool/perl.lua` (`require('lexiftool.perl')`); they never call raw
`string.*`/`table.*`/`os.*` for an operation that maps to a Perl built-in.
This document is the contract of its functions. When a call site uses the
facade and when plain Lua is right is a rule of
[conventions.md](conventions.md#3a-facade-or-raw-lua-what-decides); the
comments in `perl.lua` describe how each function does what is promised
here.

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

Translation happens exclusively inside the facade (e.g. the `+1` shift into
Lua's 1-based positions), so ported logic stays numerically identical to
the Perl original. The `carray` buffers are 1-based internally; only the
facade knows this.

## 2. Core functions

| Perl original | Facade call | Notes |
|---|---|---|
| `$val = unpack(FMT, $s)` | `perl.unpack(FMT, s)` | whole string from offset 0 (Perl semantics); `x` past the end or `X` before the start dies "'x' outside of string in unpack" as in Perl |
| `unpack` + position tracking | `perl.unpack(FMT, s, off)` | facade extension: off is 0-based bytes, returns (values..., next_off) |
| `pack(FMT, ...)` | `perl.pack(FMT, ...)` | a numeric code warns "Use of uninitialized value in pack" for an undef value (not for values missing at the end of the list) and "isn't numeric in pack" for a non-numeric string |
| `tell(FH)` | `perl.tell(fh)` | the file position on a plain file; on a pipe or character device (/dev/null) the bytes `perl.print` wrote to the handle, as PerlIO counts them |
| `substr($s, $o, $l)` | `perl.substr(s, o, l)` | 0-based; negative o/l go through; offsets as Perl's translate_substr_offsets: a substring wholly outside the string is undef (nil) with Perl's "substr outside of string" warning, one partly outside is cut to the string |
| `substr($s, $o, $l) = $v` | `perl.substr(s, o, l, repl)` | lvalue form; mutates a carray (§4) |
| `length $s` / `scalar @a` | `perl.length(x)` | bytes for strings, count for lists |
| `$a[$i]` | `perl.at(list, i)` | 0-based; a non-integer index is truncated as in Perl |
| `$s =~ /(pat)/; $1, $2, ...` (no `/g`) | `perl.matches(s, pat[, pos])` | returns captures as a list (like `$1,$2,...`; nil for a group that took no part), plus end pos |
| `if ($s =~ /pat/)` (scalar/boolean context) | `perl.isMatch(s, pat[, pos])` | true followed by the captures, or false; required where the first group may be unset ([conventions.md §6](conventions.md#6-regex)) |
| `my @all = $s =~ /pat/g` (list context) | `perl.findAll(s, pat)` | flat array of all matches/captures |
| `while ($s =~ /pat/g) { ... }` (loop context) | `for ... in perl.eachMatch(s, pat) do ... end` | drop-in for Lua's own `string.gmatch`, PCRE2-backed; values only, no position |
| `$s =~ s/pat/repl/g` | `perl.subst(s, pat, repl[, 'g'])` | `repl` in Perl's syntax: `$1`, `${1}`, `$&`, `\$`; see §2b |
| the value of `$s =~ s/pat/repl/` itself | `local s2, n = perl.substN(s, pat, repl[, 'g'])` | n: the number of substitutions, or `false` (Perl's false: `''`/0 without a warning) |
| `$s =~ s/pat/CODE/e` | `perl.subst(s, pat, function(c1, c2, ...) ... end)` | the captures arrive as arguments |
| `$s =~ tr/SEARCH/REPL/cds` (also `y///`) | `perl.tr(s, search, repl[, flags])` | byte-wise; returns (new string, count); ranges and backslash escapes as in perlop |
| `eval $code` on `$_`, where `$code` is only `tr///`/`y///`/`s///` statements | `perl.compileEdit(code)` | returns `function(v) -> v'`, or nil for anything beyond that subset (treat as an eval that failed to compile); used for the `Filter` option |
| `eval $code` of user code (the `-if` condition, `${TAG;EXPR}`) | `perl.eval(code, vars[, funcs])` | an interpreter for the subset of Perl such code uses (perl.lua lists it; [differences.md](differences.md) for users); variables by name in `vars` (`$_` is `vars._`, written back), helper functions in `funcs`; dies with Perl's `syntax error ...`, or with `Perl syntax unsupported in lexiftool: WHAT (near "...")` for valid Perl outside the subset -- `perl.isUnsupported(e)` tells that one apart |
| `$ENV{NAME}` (read) | `perl.getenv(name)` | only where upstream reads %ENV (the .ExifTool_config lookup); the library writes no environment -- upstream's `$ENV{TZ} = ...; tzset` of the `TimeZone` option is `perl.setObjectTimeZone(obj, value)`, a zone of that object |
| `eval { require Module }` | `ok, mod = perl.evalRequire('Module::Name')` | true plus the module (`Module::func` is `mod.func`), or false; `Module::Name` maps to the Lua module `Module.Name`. CPAN modules without a Lua counterpart (Brotli, Lzma, Bunzip2, Unicode::GCString, Time::HiRes, File::Basename, the Win32 modules) are the facade's own, over the required rocks and `lexiftool.sys`, with the subset upstream calls; `MODULE_LOADERS` in perl.lua lists them, each loader documents its functions |
| `open FH, EXPR` (two-argument form) | `FH = perl.open(expr)` | the Lua file, or nil plus the error text; EXPR as in Perl: `<NAME`/bare NAME, `>`, `>>`, `+<`, `CMD|`, `|CMD`, `-` (STDIN/STDOUT), `&=FD` after a mode; surrounding whitespace dropped, the name ends at the first NUL (`" NAME\0"`) |
| `utime ATIME, MTIME, LIST` | `perl.utime(atime, mtime, ...)` | the number of files changed; LIST may hold names and open Lua files (Perl's futimes form); only the integer part of a time counts, both times undef set the current time |
| `-r $file` (and `-e -f -d -p -S -s -l`) | `perl.filetest(op, path)` | `op` is the letter; `-r`: the file can be opened for reading |
| `split /re/, $s` | `perl.split(pat, s[, limit])` | regex separator, returns array |
| `split /re/, $s` (only ever looped over) | `for w in perl.eachSplit(pat, s[, limit]) do ... end` | streaming sibling of `perl.split`; same semantics, no array materialized |
| same, but `pat` built at runtime (`/$var/`) | `perl.matchesDyn`/`isMatchDyn`/`findAllDyn`/`substDyn`/`splitDyn`/`eachMatchDyn`/`eachSplitDyn` (same signatures) | no compiled-pattern cache; see §2a |
| `lc/uc/lcfirst/ucfirst $s` | `perl.lc(s)`, `perl.uc(s)`, ... | ASCII only, whatever the host's `LC_CTYPE` |
| `ord $c` / `chr $n` | `perl.ord(c)`, `perl.chr(n)` | |
| `sprintf(FMT, ...)` | `perl.sprintf(FMT, ...)` | Perl semantics |
| `sort LIST` / `sort { ... } LIST` | `perl.sort(list[, cmp])` (new list), `perl.tsort(list[, lt])` (in place) | strings ordered as bytes, whatever the host's `LC_COLLATE`; stable like Perl's sort (with a block: elements it calls equal; without: elements of one string form, `1` and `'1'`) |
| `keys %h` / `values %h` | `perl.keys(h)` / `perl.values(h)` (a new list; loop `for _, k in ipairs(keys(h))`) | a fixed order instead of Perl's per-process hash order: the keys in Perl's string order (bytewise, a number key in its Perl string form), table keys (Perl references) after them, by a name built from their contents; `values` follows `keys`. Where Perl's result depends on its hash order, lexiftool thus always gives the same one of Perl's possible results ([differences.md](differences.md#results-that-depend-on-perls-hash-order)) |
| `$a cmp $b`, `$a lt $b` (`gt`: `perl.lt(b, a)`) | `perl.cmp(a, b)`, `perl.lt(a, b)` | stringified, compared as unsigned bytes (Lua's `<` on strings uses `strcoll`) |
| number → string (SV) | `perl.str(n)` | Perl-compatible rounding/formatting: `%.15g`, always `.`, no `.0` on an integral float, undef as `''` |
| `"$val m"`, `$a . $b` with a number | `perl.str(val) .. ' m'` | Lua's `..` prints an integral float as `2.0` |
| string → number (`$x / 2`, `$x + 0`, `$x < 3`) | `perl.num(x[, op])` | leading numeric prefix, hex is 0, Inf/NaN; with `op` (the Perl operator: `'/'`, `'+'`, `'<'`, ...) a non-numeric string warns like `use warnings` (`Argument "abc" isn't numeric in division (/)`) through `perl.warn`; `perl.int`/`perl.log`/`perl.sprintf` warn the same way; undef numifies silently |
| `$val / 2`, `$val > 0`, `$val & 0x0f` on a value that may be a string | Lua's own operator | loading the facade gives the string metatable arithmetic, order and bitwise metamethods that numify like `perl.num(x, op)` (`'12abc' / 2` is 6 and warns, `'1' / '0'` dies "Illegal division by zero", bitwise results are Perl's UV). Not covered: `==`/`~=` between a string and a number, two strings in an order comparison, and nil -- use `perl.num(x, op)` there (perl.lua lists the remaining limits) |
| `-$x` (unary minus) | `perl.neg(x)` | a non-numeric string starting with a letter becomes `"-" .. x`, one starting with `+`/`-` flips the sign character (Perl's pp_negate); otherwise numeric negation, warning "isn't numeric in negation (-)" |
| string building `$buf .= $x` | `buf:append(x)` on a carray (`require('carray')`) | mutable byte buffer; see §4 |
| `map { BLOCK } @a` | `perl.map(fn, list)` | fn gets the element (`$_`) and may return several values; undef ones are skipped |
| `join($sep, @a)` | `perl.join(sep, list)` | elements stringified like Perl (`708`, not `708.0`) |
| `log($x)` | `perl.log(x)` | dies like Perl for x <= 0 ("Can't take log of 0") |
| `$x =~ /pat/` with `$x` undef | `perl.isMatch(nil, pat)`, `perl.matches(nil, pat)` | undef matches as `''` and warns "Use of uninitialized value in pattern match (m//)" (without the variable name Perl adds for a plain variable); in a conversion the warning is the conversion error, as upstream |
| `die $msg` inside an eval'd conversion | `perl.die(msg)` | tagged error: GetValue leaves the value undefined and warns `ValueConv Tag: msg`, as upstream's `eval`; any other Lua error propagates (`perl.isDie(e)` tells them apart) |
| `"$x / ${x} / $a[0] / $h{k}"` | `perl.interp(s, env)` | opt-in, see §4a |
| `defined $x` / `exists $h{k}` | `perl.D(x)` / `perl.E(h, k)` | explicit helpers (Lua has no autovivification) |
| `$h{$key}` with a key from split/regex/arithmetic | `perl.hget(h, key)` | the key `"4"` and the number `4` are one element, as Perl stringifies keys; a string finds a number key only when it is exactly how Perl prints that number (`"2.1"`, not `"04"`, `"4.0"` or `"0x4"`) |
| `eval` around a conversion (`$value = eval $conv`) | `perl.pcall(f, ...)` / `perl.xpcall(f, handler, ...)` | pcall/xpcall with Perl's arithmetic: a division or modulus by zero of two numbers fails with Perl's "Illegal division by zero"/"Illegal modulus zero" instead of giving Inf or a Lua error; `0/0` stays NaN. The library's conversion call sites use these |

## 2a. Regex: cached vs. dynamic patterns

`perl.matches`/`isMatch`/`subst`/`split`/`findAll`/`eachMatch`/`eachSplit`
hand `pat` as a string to the regex backend, the `lpcre` rock (PCRE2;
required in `perl.lua` only), which compiles it once and keeps it in its
LRU pattern cache. Use these where `pat` is a fixed string in the ported
source, matching a literal `/pat/` in the Perl original. The subject may be
a Lua string or a carray (§4): lpcre matches a carray on its buffer,
without a copy.

Where the Perl original builds the pattern at runtime (`/$var/`,
interpolated `qr/.../`, e.g. `GIF.pm`'s `/$$extInfo{Terminator}/g`,
`InDesign.pm`'s `/^\Q$masterPageGUID/`), use the `*Dyn` forms instead: same
signatures and semantics, but the pattern is compiled on every call and
never enters the cache, where a pattern that differs on every call would
evict the literal ones. The `*Dyn` functions also take a precompiled
`lpcre` regex object.

How to choose between a native Lua pattern and the facade, and between
`matches`, `isMatch`, `findAll` and `eachMatch`, is
[conventions.md §6](conventions.md#6-regex).

## 2b. Regex: the replacement string stays Perl's

`perl.subst`/`perl.substDyn` take the replacement in **Perl's** syntax, and
translate it for the `lpcre.gsub` underneath (string.gsub's syntax):

| in the port (as in Perl) | means |
| --- | --- |
| `$1` … `$9`, `${1}` … `${9}` | the n-th capture |
| `$&` | the whole match |
| `\$` | a literal dollar sign |
| `%` | a literal percent sign |
| `\n` `\t` `\r` `\f` `\e` `\a`, `\0`/`\0NN`, `\xHH`/`\x{HH}` | the character, as in Perl's double-quotish replacement (other backslashed letters keep their backslash) |

A replacement copied over from Perl therefore works unchanged, where the
backend's own syntax would silently insert a literal `$1` or swallow a `%`;
a `%1` written into a replacement is therefore a mistake.

For Perl's `/e` (code instead of a string), pass a **function**: it receives
the captures as arguments (nil for a group that took no part, Perl's undef)
and returns the replacement.

## 3. `unpack` format subset

Only the templates exiftool actually uses are implemented, among them:

`H* a* A Z c C s S i I l L n N v V U x X @ ...`

Edge semantics follow `pp_pack.c` and are documented per code in the
facade: `A` strips trailing NULs and all whitespace (`\t\n\v\f\r` too),
`pack` numifies a string by its numeric prefix (`"0x10"` is 0), and
`pack('f')` of a value beyond FLT_MAX is +-Inf.

`U` decodes a character: in C0 mode (a template not starting with `U`, or
after `C0`, as Charset.pm's `unpack('C0U*', $val)`) one UTF-8 sequence with
Perl's lax decoder -- surrogates, non-characters and 5- to 13-byte code
points are accepted, a malformed sequence gives 0 and Perl's "Malformed
UTF-8 character: ... in unpack" warning(s) word for word; in U0 mode (a
template starting with `U`, or after `U0`) one byte, as Perl reads a byte
string upgraded to its internal UTF-8. Other codes in U0 mode are not
supported.

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
conversion routine). When in doubt, use a carray. A short-lived edit of a
string is spelled `local b = carray.new('char'):append(s)`,
`substr(b, off, len, val)`, `s = b:tostring()`. Lua strings stay for
everything Perl does not change.

On a carray, `perl.matches`/`isMatch`/`findAll`/`eachMatch` read its bytes
in place (no copy), `perl.subst` and `perl.tr` edit it in place (and return
it, so `buf = subst(buf, ...)` reads the same for both representations),
`perl.str` yields its bytes, `perl.truthy` tests them like Perl tests the
scalar (empty or `"0"` is false) and `Writer.Write` writes them.
`buf:append(n)` with a Lua *number* appends one byte, not its digits --
append strings (`entry .. value` coerces as Perl's `.` does).

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
routine; `RandomAccess:new` takes a carray too), string concatenation or
CRC input (the zlib/Brotli functions take the carray itself). Boxes whose
scalar is only read (binary tag values,
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
stays preferred. Only the forms exiftool sources require are supported,
like the `unpack` subset.

## 5. Backend and globals

The facade has one backend, `lua`. It is selected once, when the facade
module loads, so ported modules may bind facade functions to file-scope
local aliases without risking stale bindings.

The library reads no environment variable for its own settings and no
global but these two, both through `_G.` and both set by the caller before
the library loads:

- `_G.LEXIFTOOL_BACKEND` -- the facade backend (`lua -e
  "LEXIFTOOL_BACKEND='lua'" ...`); any other value is an error.
- `_G.LEXIFTOOL_PORT_VERSION` -- the build's identity string, which the
  launcher, the standalone and the C API builds set; `src/lexiftool.lua`
  reads it once for `ExifTool._VERSION` and `-ver -v` prints it
  (`Unknown` when unset).

Globals for **test code only**, never read by the library:

- `_G.LEXIFTOOL_REPO_DIR` -- the repository root (otherwise
  `src/test/TestLib.lua` finds it by walking up to `vendor/exiftool/t`).
- `_G.LEXIFTOOL_TEST_LOCALE`, `_G.LEXIFTOOL_TEST_LOCALE_REQUIRED` -- the
  locale the test runner sets before each test file (make's `TEST_LOCALE`,
  `TEST_LOCALE_REQUIRED`).
- `_G.LEXIFTOOL_TEST_PERL` -- the Perl whose `localtime`/`gmtime` the
  facade's are compared with (make's `TEST_PERL`).
