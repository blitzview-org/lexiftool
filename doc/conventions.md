# Conventions — Perl → Lua mapping

These rules keep the ported code structurally parallel to the Perl original
so it can be maintained by hand next to upstream `Image::ExifTool`.

## 1. Files

- Namespace mapping is 1:1: `Image::ExifTool::X` ↔ `lexiftool.X`, file base
  names preserved, `.pm` → `.lua`. The main module is `src/lexiftool.lua`
  (upstream `lib/Image/ExifTool.pm`); plugins live in `src/lexiftool/`
  (`lib/Image/ExifTool/JPEG.pm` ↔ `src/lexiftool/JPEG.lua`).
- On-disk paths are lowercase for Lua `require('lexiftool.JPEG')`; the
  visible file base name stays the same (case-preserved).
- New helper modules have no Perl counterpart and are named without a Perl
  path for which a mapping exists (`perl.lua`, `Helpers.lua`).
- **Module table construction uses the module name, never a generic `M`.**
  Open with `local DPX = {}` and close with `return DPX` (see
  `src/lexiftool/DPX.lua` for the canonical shape). `local M = {} … return M`
  is forbidden.
  - The rule holds for **every** Lua module in the repository, not just the
    ported ones — test and tooling code (`src/test/`, `tools/`) included. "It has no Perl counterpart" is not an exemption.
  - File base name and table name are the **same word**, so the module is
    greppable under one identifier: `Driver.lua` ↔ `local Driver`,
    `WriteExif.lua` ↔ `local WriteExif`. Module files are therefore
    capitalised; entry-point scripts that are run rather than `require`d
    (`src/runtests.lua`) are not modules and stay
    lowercase.
  - **Upstream names that are not valid Lua identifiers** keep their file base
    name and get a single leading underscore for the table name:
    `Image::ExifTool::7Z` ↔ `src/lexiftool/7Z.lua` with `local _7Z = {}` …
    `return _7Z` (a bare `7Z` cannot start an identifier). The underscore is
    the only change permitted — no invented word ("SevenZip"), no generic `M`
    — so the module stays greppable under one identifier, and the `require`
    path is unaffected (`require('lexiftool.7Z')` takes a string).
  - The **importing** side uses the same name too: `local TestLib =
    require('test.TestLib')`, never `local testlib` or an invented alias. Where
    a local would collide with the module name, the local is what gets
    renamed (`local toolProfiles = Profiles.build(…)`), never the module.

## 2. Names and ordering

- Function names, variable names, and local names: **identical** to Perl.
- Code ordering inside a module file follows the Perl original (sub for sub,
  data table for data table). Only diverge where Lua forces it (no `my`,
  no `@_`).
- Dispatch tables become Lua tables of functions (closures), in original
  order.
- Forward references to process subs (`sub ProcessX($$);` predeclarations in
  Perl, or `%tableDefaults` spreading `PROCESS_PROC` before the sub exists):
  the Lua tag table carries a placeholder entry at the same position,
  `PROCESS_PROC = false, -- predeclaration, see below for implementation`,
  and the real function is assigned after its definition, at the bottom of
  the module (`Table.PROCESS_PROC = Module.ProcessX`). This keeps the point
  where PROCESS_PROC is set visible at the same place as in the Perl code.
- A shared defaults hash spread into several tables (`%tableDefaults`)
  becomes a local `tableDefaults(t)` helper next to the tables it serves,
  applied as `MIE.Main = tableDefaults { ... }`; the helper lists every
  default entry in upstream order, with deferred subs as `false`
  predeclarations. Tables that do not spread the hash in Perl keep only
  their explicit entries.

## 3. Mapping table

| Perl | Lua (port) |
|---|---|
| `sub foo { my ($self, $x) = @_; }` | `function ExifTool:foo(x)` (method) or `local function foo(x)` |
| `$self->{Field}` | `self.Field` |
| `my %t = (a => 1, b => [ ... ]);` | `local t = { a = 1, b = { ... } }` |
| `foreach my $k (keys %h)` | `for k, v in pairs(h) do` |
| `$val = unpack(FMT, $s)` | `local val = perl.unpack(FMT, s)` |
| `$s =~ /(x|y)/; my $g = $1;` (no `/g`) | `local g = (perl.matches(s, [[(x|y)]]))` |
| `my @all = $s =~ /(\w+)/g;` (list context) | `local all = perl.findAll(s, [[\w+]])` |
| `while ($s =~ /(\w+)/g) { ... $1 ... }` (loop context) | `for w in eachMatch(s, [[\w+]]) do ... end` |
| `$s2 =~ s/a/b/g` | `local s2 = perl.subst(s2, 'a', 'b', 'g')` |
| `$s2 =~ s/(a)(b)/$2$1/` | `local s2 = perl.subst(s2, '(a)(b)', '$2$1')` — the replacement keeps Perl's `$1`, see api.md §2b |
| `substr($s, $i, $l)` | `substr(s, i, l)` (facade alias, see §3a) |
| `sprintf("%.1f", $val)` | `sprintf('%.1f', val)` (facade alias, see §3a) |
| `"$x yes"` / `$x . $y` | `x .. ' yes'` for plain concat; **or** `perl.interp("$x yes", env)` where Perl interpolation is needed (opt-in, see §9) |
| `defined $x` / `exists $h{k}` | `perl.D(x)` / `perl.E(h, k)` |
| `0-based loops: for (my $i=0; $i<@a; ++$i)` | `for i=0, perl.length(a)-1 do` + `perl.at(a, i)` |

## 3a. Facade or raw Lua: what decides

The facade rule (CONTRIBUTING.md: "never call raw `string.*`/`table.*` for operations
that map to a Perl builtin") is decided **per call site by the Perl original**,
not by preference and not by counting:

> **Does the corresponding Perl line contain the builtin?** Then the Lua line
> uses the facade. Otherwise it uses plain Lua.

For `substr` that means:

```lua
-- ID3.pm:  my $val = substr($$dataPt, $offset, $len);
local val = substr(dataPt, offset, len)                -- yes
local val = dataPt:sub(offset + 1, offset + len)       -- no

-- PNG.pm:  my ($tag,$val) = split /\0/, ${$$dirInfo{DataPt}}, 2;
local data = dirInfo.DataPt:sub(start, start + dirLen - 1)   -- yes: this
        -- slice is a port artifact (Lua has no scalar refs), not a substr
```

The same test applies to `Get8u`/`Get16u`/… — where Perl reads
`Get8u(\$s, $n)`, the Lua reads `ExifTool.Get8u(s, n)` (0-based, argument for
argument identical), never `s:byte(n + 1)`.

**Always bind the facade function to a file-scope local alias**, the same
`local matches = require('lexiftool.perl').matches` pattern §6 prescribes for
the regex facade. That is the whole point of the rule — with the alias the
Lua line is *literally* the Perl line:

```
ID3.pm:1205   my $val    = substr($$dataPt, $offset, $len);
ID3.lua:738   local val  = substr(dataPt, offset, len)
```

without it, `perl.substr(dataPt, offset, len)` still beats `:sub`, but reads
one step further from the original.

**sprintf/printf** follow the same rule: where the Perl line has `sprintf`
(or `printf`, also inside a conversion string like `'sprintf("%.1f",$val)'`),
the Lua line calls `sprintf(...)` through the file-scope alias
(`local sprintf = perl.sprintf`, or `require('lexiftool.perl').sprintf` in a
module without a `perl` local) -- never `string.format` and never the method
form `('%d'):format(n)`. `perl.sprintf` formats like Perl: numeric
conversions numify and truncate (`%d` of 3.7 is 3, of "12abc" is 12), `%s`
stringifies like Perl (`1`, not `1.0`), Inf/NaN print as `Inf`/`-Inf`/`NaN`,
and `%u`, `%b`, `%vd`, `%2$s`, `%*d`/`%.*f`, `%hd` and missing arguments work;
when format and arguments are plain it is a single `string.format` call. So
a call site need not truncate, `tonumber` or `NumStr` an argument to please
Lua (older call sites still carry such wrappers; drop them when touching the
line).
`string.format` stays where no sprintf stands behind the Lua line -- a hex
loop replacing `unpack('H*')`, a message Perl builds by interpolation
(`"Bad format ($format) for $dir entry $index"`). `make verify`
(`tools/verify_sprintf.lua`) reports a raw `string.format` whose format also
occurs on a sprintf/printf line of the module's Perl original.

**sort, cmp, lt/gt** order strings as unsigned bytes in Perl, whatever the
locale; Lua's `<` on two strings uses `strcoll` and follows the host's
`LC_COLLATE`. So ported code never calls `table.sort` directly: Perl's
`sort LIST`/`sort { ... } LIST` returning a new list is `perl.sort`, an
in-place sort of a Lua list is `perl.tsort(list[, lt])` (file-scope alias
`local tsort = perl.tsort`; without `lt` a list of strings sorts bytewise
and a list of numbers numerically). Inside a comparator, and anywhere else,
a string comparison that Perl writes `cmp`/`lt`/`gt`/`le`/`ge` is
`perl.cmp(a, b)` / `perl.lt(a, b)` (`$a gt $b` is `perl.lt(b, a)`, `ge` is
`not perl.lt(a, b)`); a Perl `<=>` stays Lua's numeric `<`. `make verify`
(`tools/verify_sort.lua`) rejects a raw `table.sort` outside perl.lua.

**Stringification** -- Perl's `"$val"`, `$a . $b`, a number used as a
string -- is `perl.str(v)` (file-scope alias `local str = perl.str`, or
`perlStr` in a module whose upstream has `$str` variables): `%.15g` with
`.` as the decimal point whatever the locale, an integral float without
`.0`, `Inf`/`NaN` as Perl spells them, undef (nil) as `''`, `true`/`false`
as `1`/`''`. Lua's `tostring` gives `%.14g`, `2.0`, the locale's decimal
point and `"nil"`, so ported code never calls it on a value; it is left
for error objects (the message of a failed `pcall`, printed or passed on).
Concatenating a number that may be a float with `..` has the same problem
(it is `tostring`); build such a string with `str(v) .. ...` or
`sprintf`. The regex functions of the facade stringify a number subject
(and a number an /e replacement function returns) the Perl way.
`make verify` (`tools/verify_tostring.lua`) rejects a `tostring()` whose
argument is not visibly a string, an integer or an error object
(allowlist: `tools/verify_tostring_allowlist.lua`).

**Character classes and case** follow the same logic. Perl's `\s`, `\w`,
`[[:alpha:]]` and `lc`/`uc` on a byte string mean ASCII (outside
`use locale`): `\s` is exactly space, `\t`, `\n`, `\r`, `\f`, `\v`, `\w`
is `[A-Za-z0-9_]`. Lua's pattern classes `%a %l %u %w %s %p %c %g` (and
their negations) go through `isalpha()`/`isspace()`/... and
`string.lower`/`string.upper` through `tolower()`/`toupper()`, i.e. the
`LC_CTYPE` of the process's global C locale: under a single-byte locale
(Windows cp1252, glibc's `de_DE` ISO-8859-1) `0xE4` is a letter and
`string.lower('\xC4')` is `'\xE4'`. So a Lua pattern in ported code spells
its classes as ASCII sets -- `%s` is `[ \t\n\r\f\v]`, `%S`
`[^ \t\n\r\f\v]`, `%a` `[A-Za-z]`, `%l` `[a-z]`, `%u` `[A-Z]`, `%w`
`[A-Za-z0-9]`, `%p` `` [!-/:-@[-`{-~] ``, merged into one set where they meet
(`[%w_%s]` is `[A-Za-z0-9_ \t\n\r\f\v]`) and kept as literals in the call,
so the gate sees them; `%d` and `%x` are locale-independent by the C
standard and stay. A case change is `perl.lc`/`perl.uc` (file-scope alias
`local lc, uc = perl.lc, perl.uc`), never `:lower()`/`:upper()`: where the
Perl line has `lc`/`uc` that is the exact counterpart, and where Lua builds
a case-insensitive comparison of its own it must be ASCII as well. The
facade's own case helpers use `string.lower`/`upper` only after checking
that the locale maps exactly A-Z/a-z. The PCRE2 patterns of the regex
facade (§6) are not affected: lpcre compiles with PCRE2's built-in
character tables and never calls `pcre2_maketables`, so `\s`, `\w` and
`(?i)` are ASCII whatever the locale. `make verify`
(`tools/verify_ctype.lua`) reports a class in the pattern argument of a
`find`/`match`/`gmatch`/`gsub` call and a `lower`/`upper` call outside the
facade's helpers (allowlist: `tools/verify_ctype_allowlist.lua`).

Cost is not an argument here: the facade call costs tens of nanoseconds
more than the builtin, invisible outside per-byte loops (which §7 forbids
anyway).

## 3b. Perl UVs (unsigned integers from 2^63 to 2^64-1)

Perl keeps an integer as a signed IV or, when it does not fit, as an
unsigned UV, and integer arithmetic stays exact while the result fits
either: `$hi * 4294967296 + $lo` (Writer.pl `Get64u`) is exact up to
2^64-1, and `"$val"` prints 13830554455654793216. A Lua integer has the
same 64 bits but no "unsigned" flag, so the same expression prints
-4616189618054758400 -- and a negative integer alone cannot tell an IV
from a UV, so no facade function can repair it after the fact.

**Decision:** the place where upstream's arithmetic produces a UV marks it
with `perl.uv(...)` (file-scope alias `uv`), and the Lua line otherwise
stays the Perl line:

```
Writer.pl:4487   return $hi * 4294967296 + $lo;
lexiftool.lua    return uv(hi * 4294967296 + lo)
```

`uv(n)` returns a Lua integer below 2^63 unchanged (the common case costs one
call and a comparison) and turns the wrapped bit pattern of a larger value
into a small, interned UV object with Perl's semantics: exact
stringification (`perl.str`, `tostring`, `..`, `sprintf` `%s`/`%u`; `%d`
and `%x` see the bit pattern, as in Perl), exact comparisons with any number
the way Perl compares (integer against integer, otherwise as doubles),
`+ - * % //` and unary minus exact while the result fits an IV/UV and a
double once it does not, `/` exact for an exact quotient (Perl's
`PERL_TRY_UV_DIVIDE`), bit operations on the 64 bits returning a UV again.
`perl.num`/`perl.int` keep it, `perl.truthy` is true. Expectations of
`src/test/test_perl_uv.lua` come from the real perl.

Use `uv()` only where the true result is known to lie in 0..2^64-1 -- two
unsigned 32-bit words, `~0`, a hex literal Perl reads as a UV
(`uv(0xffffffff00000000)`), or a product of non-negative integers that
cannot exceed 2^64 (`mult = uv(mult * 128)` in Protobuf's VarInt, where the
next multiplication then runs on the UV object and overflows into a double
as in Perl). Plain Lua integer arithmetic elsewhere still wraps where Perl
would switch to a UV or NV; values that large do not occur in it.

Alternatives considered and rejected:

- *Keep the Lua integer and interpret it in the facade*: ambiguous, a
  negative integer is also a genuine IV (`Get64s`, `Get32s`).
- *A float for values >= 2^63*: loses the low bits (2^64-8 rounds to 2^64)
  and prints `1.84467440737096e+19` where Perl prints all 20 digits.
- *A decimal string*: prints right, but comparisons with numbers raise in
  Lua, arithmetic turns it into a float and bit operations fail -- e.g.
  MXF's `RawConv => '$val > 1e18 ? undef : $val'` breaks.

Limits of the UV object, by Lua's rules: `type()` is `'table'` (its `.ref`
is `''`, Perl's `ref` of a number, so tests written as `v.ref == nil` for an
ARRAY ref or `v.ref == 'SCALAR'` do not take it for a reference; a bare
`type(v) == 'table'` test does and must be written the Perl way), `==`
against a plain number is always false, and `tonumber`, `math.*` and a raw
`string.format('%d')` do not accept it. LuaJIT (no integers) would need its
own implementation behind the same function.

## 4. Objects

- Perl `bless`-based objects → Lua tables with a metatable; methods named
  exactly as in Perl (`ExifTool:ExtractInfo`, etc.).
- `class->new(...)` → `ExifTool.new(...)` returning a metatable-protected
  table.
- Attribute access `$self->{Foo}` → `self.Foo` (keep the same key names).

## 5. Value conversion and PrintConv

- PrintConv/ValueConv tables that in Perl contain strings of Perl code are
  converted to Lua **functions** with the same story order (closures capture
  what they need).
- `$$tagInfo{...}` lookup helpers are kept centered in `TagTable.lua`.

## 6. Regex

- **The directive is: use a native Lua pattern (`:match`/`:gmatch`/`:gsub`/
  `:find`) wherever it can safely express the Perl original's semantics;
  fall back to PCRE2 via the facade (`perl.matches/subst/split/findAll/
  eachMatch/eachSplit`) only for constructs Lua patterns cannot express or
  cannot express safely.** There is no "default engine" — the two are not
  interchangeable stylistic options, the construct itself decides. Lua
  patterns are measurably faster and are
  Lua-native, so they are always the first choice when they apply.
- **A native Lua pattern may be used only for the specific constructs
  verified equivalent in `src/test/test_lua_pattern_pcre2_equivalents.lua`**
  — plain literals, `^`/`$` anchors, `\d`/`\D` ↔ `%d`/`%D`, `\s`/`\S` ↔
  `%s`/`%S`, negated character classes `[^...]`, byte-range classes
  `[x-y]`, capture groups, greedy `+`/`*`/`?`, lazy `*?` ↔ Lua's `-`, and
  same-pattern backreferences (PCRE2 `\1`..`\9` ↔ Lua `%1`..`%9`, both
  usable inside the pattern itself, not just the replacement). Never by
  manual judgment call; if it's not a passing case in that test file, it
  isn't safe, full stop. Never hand-translate a pattern outside that set (that
  file also documents the concrete traps: `\w` vs `%w` — missing the
  underscore; `\b` vs the
  `%f[%a]` frontier approximation; `.` matching newlines unconditionally in
  Lua vs. only under Perl's `/s`; and constructs Lua has no equivalent for
  at all — alternation `|`, `{n,m}`, `(?i)`, non-capturing groups). A single
  Perl pattern containing alternation always goes to PCRE2 as one literal
  `perl.matches`/etc. call, even where it could technically be reassembled
  from several `or`-joined Lua `:match()` calls — splitting one upstream
  pattern across several
  Lua calls trades a small, real speed gain for logic that no longer reads
  as 1:1 against the Perl original and is easy to get subtly wrong when the
  upstream pattern changes.
- **When a new call site's pattern isn't yet covered by
  `test_lua_pattern_pcre2_equivalents.lua`, don't guess.** Check whether it
  is actually a new instance of an already-verified-safe construct (then
  use a Lua pattern); if it's a genuinely new construct that turns out to
  be safe, add a verifying pair of assertions to that test file first, so
  the equivalence is proven and stays regression-tested, then use the Lua
  pattern. Otherwise (anything already known-unsafe, or genuinely unclear)
  fall back to PCRE2.
- Named captures in Perl map to positional return values in the same order.
- Patterns that are literal in the Perl original use `perl.matches`/`subst`/
  `split`/`findAll`/`eachMatch`/`eachSplit` (cached compiled pattern);
  patterns the Perl original builds at runtime (`/$var/`, interpolated
  `qr/.../`) use `perl.matchesDyn`/`substDyn`/`splitDyn`/`findAllDyn`/
  `eachMatchDyn`/`eachSplitDyn` (no cache) — see `api.md` §2a.
- **Which of `matches`/`findAll`/`eachMatch` to use is decided by whether
  the Perl original has `/g` and, if so, how the result is consumed** — not
  by preference:
  - No `/g`: `perl.matches(s, pat[, pos])` — a single match, optionally
    starting at a byte offset (mirrors Perl's `pos($val) = N` idiom).
  - `/g`, list context (`my @all = $s =~ /pat/g`): `perl.findAll(s, pat)` —
    all matches/captures flattened into an array immediately.
  - `/g`, loop/boolean context (`while ($s =~ /pat/g) { ... }`, or a
    Lua-native `s:gmatch(...)` loop): `perl.eachMatch(s, pat)` — a PCRE2-
    backed drop-in for `string.gmatch`; yields captures (or the whole match
    when `pat` has no capturing groups) one at a time, never a position.
- **A capture group that takes no part in the match is nil (Perl's undef),
  and a match is tested in boolean context with `perl.isMatch`** wherever
  its first group can stay unset:

  ```
  XMP.pm:4352  } elsif ($buf2 =~ /^(\xef\xbb\xbf)?(<\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta|<svg\b)/g) {
  XMP.lua      hit, c1, c2 = isMatch(buf2, '^(\\xef\\xbb\\xbf)?(<\\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta|<svg\\b)')
  Sony.pm      Condition => '$$self{Model} !~ /^NEX-(3|5|5C)|DSLR-(A450|A500|A550)/',
  Sony.lua     Condition = function(self) return not isMatch(self.Model, [[^NEX-(3|5|5C)|DSLR-(A450|A500|A550)]]) end,
  ```

  `perl.matches` returns the captures, so its first value is nil for a
  successful `(a)?b` against `"b"` -- `if matches(...)` would read that as
  "no match", where Perl's `if ($s =~ /(a)?b/)` is true. The same holds for
  `^x|(y)`, `(a)*b`, `(a){0,2}b`. `perl.isMatch(s, pat[, pos])` (and
  `isMatchDyn`) is Perl's match in scalar context: `true` followed by the
  captures (nil where unset, no end offset), or `false`; so a Perl test that
  goes on to read `$1` ports as `local ok, c1 = isMatch(...)`.
  Why this split and not one function: Lua has no value that is both truthy
  and undef. Returning `false` for an unset group (rex's own convention, and
  the facade's in early versions) keeps `if matches(...)` working only for a
  later group and breaks `defined $2` (`c2 ~= nil` is true for false), and it
  made call sites invent workarounds (`matches(...) ~= nil`, `#{ matches(...)
  } > 0`, `x ~= false`, local `matched()` helpers). Returning the end offset
  first would have rewritten ~1800 call sites. So captures are nil like
  undef, and the boolean question gets its own function -- needed only
  where the first group can be unset; `if matches(s, [[^(II|MM)]])` stays as
  it is. `tools/verify_matchbool.lua` (part of `make verify`) parses every
  literal pattern and reports:
  - `matches`/`matchesDyn` used other than as the right-hand side of an
    assignment when the pattern's first group can be unset, or when the
    pattern is not a literal (`matchesDyn`, or `matches` with `'^' .. pat`)
    -- every non-literal boolean test is `isMatchDyn`;
  - a table constructor `{ matches(...) }` with such a pattern: `#t` is any
    border, and Lua 5.5 and LuaJIT report 0 for `{ nil, 7 }`. With a
    mandatory first group `#t > 0` is a sound "did it match", but `#t` is
    not the capture count and `t[#t]` not the end offset once any later
    group is optional -- take those positionally (`local _, _, en =
    matches(...)`);
  - `findAll`/`split`/`eachSplit` with any group that can be unset, and
    `eachMatch` with an optional first group, and `subst` with such a group
    and a replacement function: these hand an unset group over as `false`
    (an array cannot hold nil, a nil first value ends a for loop), so they
    are kept away from such patterns;
  - `matches`/`isMatch` as the last argument of a call, which passes every
    capture plus the end offset on: `tonumber(matches(s, [[(\d+)]]))` is
    `tonumber(cap, endOffset)`, a number in base endOffset. Write
    `tonumber((matches(...)))`.
  What the check cannot see: a scalar-context assignment (`my $ok = $s =~
  /(a)?b/` must be `local ok = isMatch(...)`, not `matches`), and the use of
  `#t` on a capture table.
- The same shape applies to `split`: `perl.split(pat, s[, limit])` returns
  the full array; `perl.eachSplit(pat, s[, limit])` is its streaming
  sibling — same semantics (capture interspersion, trailing-empty-field
  stripping) for a result that's only ever looped over once. **Prefer the
  array forms (`findAll`/`split`) by default — measured, they're faster
  than the streaming forms for typical short tag values** (each streaming
  step is its own Lua function call, which costs more than the one-shot
  array build it was meant to avoid). Reach for
  `eachMatch`/`eachSplit` only when the loop can exit early on a very long
  input (skipping the unscanned rest is the real win) or the input could be
  large enough that materializing the full array is itself the cost driver
  — not as a default micro-optimization. Neither yields a running index —
  Perl has no built-in counter for `/pat/g` or `split` iteration either; a
  loop that needs a position keeps its own counter (`i = i + 1`), same as
  the Perl original.
- Regex pattern strings use Lua long-bracket literals (`[[\d+]]`) instead of
  quoted strings (`'\\d+'`) wherever the pattern contains a backslash, so the
  pattern reads with the same single backslashes as the Perl original
  instead of doubled-up Lua escapes.
- Modules that call the regex facade bind the functions they use to local
  aliases at file scope (`local matches = require('lexiftool.perl').matches`;
  when a module needs several, `local perl = require('lexiftool.perl')` then
  `local matches, subst = perl.matches, perl.subst`), the same pattern
  `perl.lua` itself uses for hot stdlib calls. exiftool runs as a long-lived
  process reading commands from stdin, so these call sites can run often;
  the alias avoids a repeated `perl.matches` table lookup per call and costs
  nothing when it doesn't matter.

## 7. Binary data

- Read paths use `perl.unpack` on whole-string or `off`-position forms; avoid
  `string.byte`/`string.sub` per-byte loops (measurably slower).
- Byte order follows the Perl templates (`v` LE u16, `n` BE u16, `V` LE u32,
  `N` BE u32, `H*` hex string, ...).

## 8. What stays 1:1

- Tag names, group names, IFD structure, option keys, output formats
  (`.failed`/`.out` line format from the tests).

## 9. What necessarily differs (documented)

- Perl string interpolation (`"$x"`): default to `..` concatenation. An
  opt-in helper `perl.interp(s, env)` may rebuild Perl interpolation
  semantics (`$var`, `${var}`, `$var[0]`, `$h{k}`) where keeping the literal
  string verbatim matters for parity; it is never required in hot paths.
- No autovivification: nested tables must be built explicitly.
- No `wantarray`: list/scalar context must be chosen explicitly at the call
  site.
- More than 200 file-scope `my` variables (the `exiftool` script: ~155
  variables next to 55 subs) do not fit Lua's limit of 200 locals per
  function, the chunk included. `src/lexiftool/main.lua` therefore runs in a
  private environment (`local _ENV = setmetatable({}, { __index = _G })`):
  its file-scope variables and subs keep their Perl names and are fields of
  that table, visible to the whole file and to nothing outside it -- not
  globals in the sense of CONTRIBUTING.md (nothing is written to `_G`). luacheck
  checks it with `allow_defined_top`, so every such name must be assigned at
  the top level once (the Perl `my` list). Perl names that differ only by
  sigil get a suffix on the non-scalar one (`%csvTags` -> `csvTags_h` next
  to `@csvTags`), a Lua keyword a trailing underscore (`$end` -> `end_`).

## 10. Comments and formatting fidelity

The goal is line-for-line comparability with the Perl original. The Lua
syntax must differ (`=` vs `=>`, `[N]` vs bare keys, `--` vs `#`), but line
structure, comment placement and column alignment must not.

- **Indentation is 4 spaces everywhere** (library, test code, harness) —
  mirror of the Perl original. No tabs.
- **Header banner verbatim.** Every ported module carries the upstream banner
  (`#` → `--`) unchanged: `File:` renamed to the Lua base name, `Description:`
  kept as the single original line, and `Revisions:`, `References:`,
  `Notes:`, `Legal:` copied as-is. The `Revisions` are the *upstream file's*
  history and are intentionally **not** updated — upstream itself maintains
  them inconsistently (several banners stop at 2004). Never invent or append
  to them.
- **Port note.** The port note is integrated into the banner: `File:` names
  the src-relative Lua path (`lexiftool/X.lua`), a `Ported from:` line
  directly after it names the upstream path below `vendor/exiftool/`
  (`lib/Image/ExifTool/X.pm`), and a `Port notes:` section before the
  closing separator records subset scope, deferred parts and deviations —
  never information the original banner already carries. All three labels
  align on the banner's value column. Files without an upstream counterpart
  (e.g. the Lua-only `src/test/test_*.lua` harnesses that aren't a port of a
  specific `t/*.t` file) use the same framed style without the
  `Ported from:` line **and without a `Revisions:` line** — there is no
  upstream history to carry over, and a `Revisions:` line just invites
  changelog entries. `verify_port` checks the merged banner (upstream
  lines verbatim plus these additions).
- **Port notes stay current.** The `Port notes:` section is living
  documentation of a module's scope: whenever a porting step extends or
  shrinks what a module covers (new tables, new processors, newly deferred
  parts), its `Port notes:` section is updated **in the same change** — no
  separate cleanup commit. Reviewers and `verify_port` can only check the
  form, not the freshness, so keeping it current is part of every porting
  task's definition of done.
- **Table header comments verbatim.** The comment line directly above a
  table is copied verbatim (`# TIFF Compression values` …). If the upstream
  has no comment above a table, ours has none either — do not substitute a
  paraphrase like `-- ... PrintConv lookup.`.
- **Inline reference cites.** `#3`, `#4`, `#PH`, `#NC`, `#16/Milos`, `# (DNG
  1.5)`, … become `-- #3` etc. on the same table line. These cite the
  `References:` list and must be preserved.
- **One entry per line** for map/hash tables, in the upstream order. Mid-table
  comments (e.g. `  # 32910,32911 - Pixar reserved`) keep the upstream indent
  (2 spaces in the Perl, i.e. one level less than the entries).
- **Column alignment mirrors the Perl.** Where the original right-aligns the
  `=>` and comment columns (`%formatNumber`, `%intFormat`, `%manuSig`,
  `%profileClass`), ours right-aligns `=` and `--` to the same columns.
  Where the original is left-aligned (`%compression`, `%photometric…`), ours
  is left-aligned.
- **Spacing:** `[N] = 'value'` with a space around `=` everywhere; no packed
  multi-entry lines.
- **Subsets stay consistent.** Lua tables may be a subset of the upstream
  table, but every Lua entry (key, value, cite comment) must match its
  upstream counterpart exactly.
- A Lua verification tool (`tools/verify_port.lua`, run via `make verify`)
  compares headers, lookup maps and tag-table fields against the vendored
  original; re-run it after touching a table. It must stay green.


## 11. Definition of done for a module

A module `X.lua` counts as complete only when all four hold:

- (a) `make verify` reports no missing table (verify_port), no missing sub
  (verify_structure) and no PROCESS_PROC/WRITE_PROC/CHECK_PROC mismatch
  (verify_procs) for X, and the full field comparison (verify_port §3f:
  every key of every tag info and table head of X, nested SubDirectory/
  Groups/Flags/Struct/... included, against the Perl original -- missing,
  extra, differing value or shape) has no finding for X, i.e. X has no
  entry left in `tools/verify_fields_allowlist.lua` (which is empty; an
  entry may only be removed, never added for new code);
- (b) the banner's `Port notes:` describe the actual state (deferred parts
  named, nothing stale);
- (c) the upstream test family `vendor/exiftool/t/X.t` is green in
  `src/test/`, or its remaining deferrals are named with a reason in the
  test file's banner;
- (d) the command-line output for the images that exercise X is identical
  to the Perl original's (`./lexiftool` vs. `vendor/exiftool/exiftool`).

Documentation changes belong to the same commit as the code they describe;
no separate "Doku:" commits.
