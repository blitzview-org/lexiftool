# Conventions — Perl → Lua mapping

These rules keep the ported code structurally parallel to the Perl original
so it can be maintained by hand next to upstream `Image::ExifTool`. The
contract of the `perl` facade functions they refer to is in
[perl-facade.md](perl-facade.md).

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
  - The rule holds for **every** Lua module in the repository, test and
    tooling code (`src/test/`, `tools/`) included.
  - File base name and table name are the **same word**, so the module is
    greppable under one identifier: `Driver.lua` ↔ `local Driver`,
    `WriteExif.lua` ↔ `local WriteExif`. Module files are therefore
    capitalised; entry-point scripts that are run rather than `require`d
    (`src/runtests.lua`) are not modules and stay lowercase.
  - **Upstream names that are not valid Lua identifiers** keep their file
    base name and get a single leading underscore for the table name:
    `Image::ExifTool::7Z` ↔ `src/lexiftool/7Z.lua` with `local _7Z = {}` …
    `return _7Z`. The underscore is the only change permitted (no invented
    word such as "SevenZip"); the `require` path is unaffected.
  - The **importing** side uses the same name too: `local TestLib =
    require('test.TestLib')`, never `local testlib` or an invented alias.
    Where a local would collide with the module name, the local is what
    gets renamed (`local toolProfiles = Profiles.build(…)`), never the
    module.
- A module is `require`d at another module's top level only where upstream
  has the corresponding `use`; otherwise it is loaded lazily, as upstream
  does, since a loaded module's Composite table takes part in every file.

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
  the module (`Table.PROCESS_PROC = Module.ProcessX`).
- A shared defaults hash spread into several tables (`%tableDefaults`)
  becomes a local `tableDefaults(t)` helper next to the tables it serves,
  applied as `MIE.Main = tableDefaults { ... }`; the helper lists every
  default entry in upstream order, with deferred subs as `false`
  predeclarations. Tables that do not spread the hash in Perl keep only
  their explicit entries.
- Both rules are checked per module: top-level elements (functions and
  tag/data tables) out of Perl order, and functions whose parameter count or
  order differs from Perl, are deviations that must each be recorded with
  their reason (default: none). Reordering a module or fixing a signature
  shrinks that record, never grows it.

## 3. Mapping table

| Perl | Lua (port) |
|---|---|
| `sub foo { my ($self, $x) = @_; }` | `function ExifTool:foo(x)` (method) or `local function foo(x)` |
| `$self->{Field}` | `self.Field` |
| `my %t = (a => 1, b => [ ... ]);` | `local t = { a = 1, b = { ... } }` |
| `foreach my $k (keys %h)` | `for _, k in ipairs(keys(h)) do` (`keys = perl.keys`; fixed order, [perl-facade.md §2](perl-facade.md#2-core-functions)) -- `pairs` only where the Perl line has no `keys`/`values` or the order cannot matter |
| `$val = unpack(FMT, $s)` | `local val = perl.unpack(FMT, s)` |
| `$s =~ /(x|y)/; my $g = $1;` (no `/g`) | `local g = (perl.matches(s, [[(x|y)]]))` |
| `my @all = $s =~ /(\w+)/g;` (list context) | `local all = perl.findAll(s, [[\w+]])` |
| `while ($s =~ /(\w+)/g) { ... $1 ... }` (loop context) | `for w in eachMatch(s, [[\w+]]) do ... end` |
| `$s2 =~ s/a/b/g` | `local s2 = perl.subst(s2, 'a', 'b', 'g')` |
| `$s2 =~ s/(a)(b)/$2$1/` | `local s2 = perl.subst(s2, '(a)(b)', '$2$1')` — the replacement keeps Perl's `$1`, see [perl-facade.md §2b](perl-facade.md#2b-regex-the-replacement-string-stays-perls) |
| `substr($s, $i, $l)` | `substr(s, i, l)` (facade alias, see §3a) |
| `sprintf("%.1f", $val)` | `sprintf('%.1f', val)` (facade alias, see §3a) |
| `"$x yes"` / `$x . $y` | `x .. ' yes'` for plain concat; **or** `perl.interp("$x yes", env)` where Perl interpolation is needed (opt-in, see §9) |
| `defined $x` / `exists $h{k}` | `perl.D(x)` / `perl.E(h, k)` |
| `0-based loops: for (my $i=0; $i<@a; ++$i)` | `for i=0, perl.length(a)-1 do` + `perl.at(a, i)` |

## 3a. Facade or raw Lua: what decides

Whether a call site uses the facade is decided **per call site by the Perl
original**, not by preference and not by counting:

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

**Always bind the facade function to a file-scope local alias**
(`local substr = perl.substr`), so that the Lua line reads like the Perl
line, as in the first example above.

The same rule, applied to the built-ins whose Lua counterparts behave
differently from Perl's:

- **sprintf/printf.** Where the Perl line has `sprintf` or `printf` (also
  inside a conversion string like `'sprintf("%.1f",$val)'`), the Lua line
  calls `sprintf(...)` through the file-scope alias -- never
  `string.format` or `('%d'):format(n)`, and without `tonumber`/truncation
  wrappers around the arguments, since `perl.sprintf` numifies and
  formats like Perl. `string.format` stays where no sprintf stands behind
  the Lua line (a hex loop replacing `unpack('H*')`, a message Perl builds
  by interpolation).
- **sort, cmp, lt/gt.** Ported code never calls `table.sort`: Perl's
  `sort` returning a new list is `perl.sort`, an in-place sort is
  `perl.tsort(list[, lt])` (alias `tsort`). A string comparison that Perl
  writes `cmp`/`lt`/`gt`/`le`/`ge` is `perl.cmp(a, b)` / `perl.lt(a, b)`
  (`$a gt $b` is `perl.lt(b, a)`, `ge` is `not perl.lt(a, b)`); Perl's
  `<=>` stays Lua's numeric `<`. Lua's `<` on strings follows the host's
  `LC_COLLATE`, Perl's does not.
- **Stringification.** Perl's `"$val"`, `$a . $b` and a number used as a
  string are `perl.str(v)` (alias `str`, or `perlStr` where upstream has
  `$str` variables), or `sprintf`. Lua's `tostring` and `..` on a number
  print `2.0`, `%.14g`, the locale's decimal point and `"nil"`, so
  `tostring` is left for error objects.
- **Numification.** Where Perl writes `$val / 2`, `$val > 0` or
  `$val & 0x0f` on a value that may be a string, the Lua line writes
  `val / 2`, `val > 0`, `val & 0x0f`: the facade gives Lua's string
  operators Perl's numification, so neither `tonumber` nor a `num()`
  wrapper stands in between. What Lua cannot reach that way uses
  `perl.num(x, op)` (the operator argument keeps Perl's "isn't numeric"
  warning):
  - `==`/`~=` between a string and a number: `perl.num(val, '==') == n`;
  - an order comparison of two values that may both be strings:
    `perl.num(a, '<=') <= perl.num(b, '<=')`;
  - an operand that may be undef: `perl.num(x, '/')`;
  - a data member compared in a Condition (it holds a string while a new
    value is written): `perl.num(self.X) >= n`.

  `tonumber` is right only where the Lua line has no Perl counterpart (a
  table key or array index the port computes itself). A division by zero
  of two numbers is caught where the conversion is called (`perl.pcall`),
  not at the operator.
- **Character classes and case.** Perl's `\s`, `\w`, `[[:alpha:]]` and
  `lc`/`uc` on a byte string mean ASCII; Lua's pattern classes
  `%a %l %u %w %s %p %c %g` (and their negations) and
  `string.lower`/`upper` follow the host's `LC_CTYPE`. A Lua pattern in
  ported code therefore spells its classes as ASCII sets, kept as literals
  in the call:

  | Lua class | ASCII set |
  |---|---|
  | `%s` / `%S` | `[ \t\n\r\f\v]` / `[^ \t\n\r\f\v]` |
  | `%a`, `%l`, `%u` | `[A-Za-z]`, `[a-z]`, `[A-Z]` |
  | `%w` | `[A-Za-z0-9]` |
  | `%p` | `` [!-/:-@[-`{-~] `` |

  Sets that meet are merged (`[%w_%s]` is `[A-Za-z0-9_ \t\n\r\f\v]`);
  `%d` and `%x` are locale-independent and stay. A case change is
  `perl.lc`/`perl.uc` (alias `local lc, uc = perl.lc, perl.uc`), never
  `:lower()`/`:upper()`. PCRE2 patterns of the regex facade are ASCII
  whatever the locale. The facade's own case helpers are the only
  exception.

## 3b. Perl UVs (unsigned integers from 2^63 to 2^64-1)

Perl keeps an integer that does not fit a signed IV as an unsigned UV, so
`$hi * 4294967296 + $lo` (Writer.pl `Get64u`) prints 13830554455654793216
where the same Lua expression prints -4616189618054758400. A negative Lua
integer alone cannot tell an IV from a UV, so no facade function can repair
it after the fact.

Mark a UV with `perl.uv(...)` (file-scope alias `uv`) at the place where
upstream's arithmetic produces it; the Lua line otherwise stays the Perl
line:

```
Writer.pl:4487   return $hi * 4294967296 + $lo;
lexiftool.lua    return uv(hi * 4294967296 + lo)
```

`uv(n)` returns a Lua integer below 2^63 unchanged and turns the wrapped
bit pattern of a larger value into a UV object with Perl's semantics:
exact stringification (`perl.str`, `tostring`, `..`, `sprintf` `%s`/`%u`;
`%d` and `%x` see the bit pattern, as in Perl), comparisons the way Perl
compares, `+ - * % //` and unary minus exact while the result fits an
IV/UV and a double once it does not, `/` exact for an exact quotient, bit
operations returning a UV again. `perl.num`/`perl.int` keep it,
`perl.truthy` is true.

Use `uv()` only where the true result is known to lie in 0..2^64-1 -- two
unsigned 32-bit words, `~0`, a hex literal Perl reads as a UV
(`uv(0xffffffff00000000)`), or a product of non-negative integers that
cannot exceed 2^64 (`mult = uv(mult * 128)` in Protobuf's VarInt). Plain
Lua integer arithmetic elsewhere wraps where Perl would switch to a
UV or NV.

Limits of the UV object: `type()` is `'table'` (its `.ref` is `''`, so
`v.ref == nil` or `v.ref == 'SCALAR'` tests do not take it for a
reference, while a bare `type(v) == 'table'` test does and must be written
the Perl way), `==` against a plain number is always false, and
`tonumber`, `math.*` and a raw `string.format('%d')` do not accept it.

## 4. Objects

- Perl `bless`-based objects → Lua tables with a metatable; methods named
  exactly as in Perl (`ExifTool:ExtractInfo`, etc.).
- `class->new(...)` → `ExifTool:new(...)`; as in Perl
  (`ref($that) || $that`), an object in place of the class creates another
  object of its class.
- Attribute access `$self->{Foo}` → `self.Foo` (keep the same key names).
- Perl's `wantarray` becomes an explicit last argument (`true` for list
  context), Perl's `@_` list `...`; the few other signature differences
  are recorded with their reasons.

## 5. Value conversion and PrintConv

- PrintConv/ValueConv tables that in Perl contain strings of Perl code are
  converted to Lua **functions** with the same story order (closures capture
  what they need).
- `$$tagInfo{...}` lookup helpers are kept centered in `TagTable.lua`.

## 6. Regex

- **Use a native Lua pattern (`:match`/`:gmatch`/`:gsub`/`:find`) wherever
  it can safely express the Perl original's semantics; otherwise use PCRE2
  through the facade** (`perl.matches/isMatch/subst/split/findAll/
  eachMatch/eachSplit`). The construct decides, not preference.
- **Safe means: verified in
  `src/test/test_lua_pattern_pcre2_equivalents.lua`** -- plain literals,
  `^`/`$` anchors, `\d`/`\D` ↔ `%d`/`%D`, negated classes `[^...]`,
  byte-range classes `[x-y]`, capture groups, greedy `+`/`*`/`?`, lazy `*?`
  ↔ Lua's `-`, and backreferences `\1`..`\9` ↔ `%1`..`%9`; `\s`/`\w` as the
  ASCII sets of §3a. Anything else goes to PCRE2, in particular
  alternation `|`, `{n,m}`, `(?i)`, non-capturing groups and `\b`; the test
  file also documents the traps (`.` matches a newline in Lua, in Perl only
  under `/s`). A Perl pattern with
  alternation is one literal `perl.matches` call, never several
  `or`-joined Lua matches. Two examples:

  ```lua
  -- Perl: $val =~ /^(\d+)x(\d+)$/            -- verified constructs only
  local w, h = val:match('^(%d+)x(%d+)$')
  -- Perl: $val =~ /^(II|MM)\x2a\0/            -- alternation: PCRE2
  local bo = (matches(val, [[^(II|MM)\x2a\0]]))
  ```
- **A pattern construct that test file does not cover is not guessed.**
  Either it is an instance of a verified construct, or a verifying pair of
  assertions is added to the test file first; otherwise it goes to PCRE2.
- Named captures in Perl map to positional return values in the same order.
- Patterns that are literal in the Perl original use the cached functions;
  patterns the Perl original builds at runtime (`/$var/`, interpolated
  `qr/.../`) use the `*Dyn` forms
  ([perl-facade.md §2a](perl-facade.md#2a-regex-cached-vs-dynamic-patterns)).
- **Which of `matches`/`findAll`/`eachMatch` to use is decided by whether
  the Perl original has `/g` and, if so, how the result is consumed:**
  - No `/g`: `perl.matches(s, pat[, pos])` — a single match, optionally
    starting at a byte offset (Perl's `pos($val) = N` idiom).
  - `/g`, list context (`my @all = $s =~ /pat/g`): `perl.findAll(s, pat)`.
  - `/g`, loop context (`while ($s =~ /pat/g) { ... }`):
    `perl.eachMatch(s, pat)`, yielding the captures (or the whole match)
    one at a time, never a position.
- **A match in boolean context is `perl.isMatch` wherever its first group
  can stay unset.** `perl.matches` returns the captures, and an unset group
  is nil (Perl's undef), so `if matches(s, '(a)?b')` is false for `"b"`,
  where Perl's `if ($s =~ /(a)?b/)` is true (likewise `^x|(y)`, `(a)*b`,
  `(a){0,2}b`). `perl.isMatch` returns `true` followed by the captures, or
  `false`; a Perl test that goes on to read `$1` ports as
  `local ok, c1 = isMatch(...)`. `if matches(s, [[^(II|MM)]])` with a
  mandatory first group stays as it is.

  ```
  XMP.pm:4352  } elsif ($buf2 =~ /^(\xef\xbb\xbf)?(<\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta|<svg\b)/g) {
  XMP.lua      hit, c1, c2 = isMatch(buf2, '^(\\xef\\xbb\\xbf)?(<\\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta|<svg\\b)')
  ```

  Not allowed, therefore:
  - `matches` in a boolean test when the first group can be unset, and
    `matchesDyn` in any boolean test (use `isMatch`/`isMatchDyn`);
  - `{ matches(...) }` with such a pattern (`#t` is any border; take
    captures and the end offset positionally);
  - `findAll`/`split`/`eachSplit` with a group that can be unset,
    `eachMatch` with an optional first group, `subst` with such a group and
    a replacement function (these pass an unset group as `false`);
  - `matches`/`isMatch` as the last argument of a call, which passes every
    capture plus the end offset on: write `tonumber((matches(...)))`.

  The same holds for a scalar-context assignment (`my $ok = $s =~ /(a)?b/`
  is `local ok = isMatch(...)`) and for `#t` on a capture table.
- `perl.split(pat, s[, limit])` returns the full array;
  `perl.eachSplit(pat, s[, limit])` is its streaming sibling with the same
  semantics. **Prefer the array forms (`findAll`/`split`)**, which are
  faster for typical short tag values; use `eachMatch`/`eachSplit` only when
  the loop can exit early on a very long input or the array itself would
  be the cost. Neither yields a running index; a loop that needs a
  position keeps its own counter, as the Perl original does.
- Regex pattern strings use Lua long-bracket literals (`[[\d+]]`) instead of
  quoted strings (`'\\d+'`) wherever the pattern contains a backslash, so
  the pattern reads with the same single backslashes as the Perl original.
- Modules that call the regex facade bind the functions they use to local
  aliases at file scope (`local matches = require('lexiftool.perl').matches`;
  when a module needs several, `local perl = require('lexiftool.perl')` then
  `local matches, subst = perl.matches, perl.subst`), as for every facade
  function (§3a).

## 7. Binary data

- Read paths use `perl.unpack` on whole-string or `off`-position forms; avoid
  `string.byte`/`string.sub` per-byte loops, which are slower.
- Byte order follows the Perl templates (`v` LE u16, `n` BE u16, `V` LE u32,
  `N` BE u32, `H*` hex string, ...).
- A Perl string scalar that is changed is a carray, a reference to one the
  box `{ value = ... }` ([perl-facade.md §4](perl-facade.md#4-mutable-byte-buffers-carray)).

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
- More than 200 file-scope `my` variables and subs (the `exiftool` script)
  do not fit Lua's limit of 200 locals per function, the chunk included.
  `src/lexiftool/main.lua` therefore runs in a private environment
  (`local _ENV = setmetatable({}, { __index = _G })`): its file-scope
  variables and subs keep their Perl names and are fields of that table,
  visible to the whole file and to nothing outside it (nothing is written
  to `_G`). luacheck checks it with `allow_defined_top`, so every such name
  must be assigned at the top level once (the Perl `my` list). Perl names
  that differ only by sigil get a suffix on the non-scalar one
  (`%csvTags` -> `csvTags_h` next to `@csvTags`), a Lua keyword a trailing
  underscore (`$end` -> `end_`).

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
  history and are **not** updated; never invent or append to them.
- **Port note.** The port note is integrated into the banner: `File:` names
  the src-relative Lua path (`lexiftool/X.lua`), a `Ported from:` line
  directly after it names the upstream path below `vendor/exiftool/`
  (`lib/Image/ExifTool/X.pm`), and a `Port notes:` section before the
  closing separator records subset scope, deferred parts and deviations —
  never information the original banner already carries. All three labels
  align on the banner's value column. Files without an upstream counterpart
  (e.g. the Lua-only `src/test/test_*.lua` harnesses that aren't a port of a
  specific `t/*.t` file) use the same framed style without the
  `Ported from:` line **and without a `Revisions:` line**. The merged banner
  (upstream lines verbatim plus these additions) is checked against the
  original.
- **Port notes stay current.** The `Port notes:` section is living
  documentation of a module's scope: whenever a porting step extends or
  shrinks what a module covers (new tables, new processors, newly deferred
  parts), its `Port notes:` section is updated **in the same change**.
  A mechanical check covers the form, not the freshness.
- **Table header comments verbatim.** The comment line directly above a
  table is copied verbatim (`# TIFF Compression values` …). If the upstream
  has no comment above a table, ours has none either — do not substitute a
  paraphrase like `-- ... PrintConv lookup.`.
- **Inline reference cites.** `#3`, `#4`, `#PH`, `#NC`, `#16/Milos`, `# (DNG
  1.5)`, … become `-- #3` etc. on the same table line. These cite the
  `References:` list and must be preserved.
- **Predeclaration note.** The §2 forward-reference placeholder's trailing
  text, `-- predeclaration, see below for implementation`, is the port's own
  note (no upstream counterpart) and is written verbatim everywhere the §2
  rule applies.
- **Port-own comment markers.** A comment that is the port's own note, not a
  translation of anything upstream, opens with one of these fixed,
  grep-able prefixes: `(port: ...)`, `(port helper: ...)`/`(port helpers:
  ...)`, `(port artifact: ...)`, `(upstream: ...)`, `(Lua: ...)`. Use one of
  these forms, not an ad-hoc wording, whenever the note's own category is
  one of them; an unprefixed parenthesised aside (e.g. `(see note above)`)
  is fine too but then reads as part of the carried-over text, since
  upstream itself writes plenty of those. A Perl comment carried over with
  the port's explanation appended as one trailing `(...)` group after the
  original text (e.g. "... in the Xiaomi mess (an undefined $marker is == 0
  in Perl)") is the same idea inline and does not need one of the prefixes
  above either.
- **Section dividers.** A bare separator line of one repeated punctuation
  character (`-` or `=`, upstream's own two spellings for a sub-header
  rule) may introduce a section with no upstream counterpart at all,
  purely as a visual break; it carries no content of its own and is never
  compared against anything upstream.
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
- Headers, lookup maps and tag-table fields are compared mechanically
  against the vendored original; a changed table must still match it.

## 11. Definition of done for a module

A module `X.lua` counts as complete only when all four hold:

- (a) X has no missing table, no missing sub and no
  PROCESS_PROC/WRITE_PROC/CHECK_PROC mismatch against the Perl original,
  and the full field comparison (every key of every tag info and table
  head of X, nested SubDirectory/Groups/Flags/Struct/... included --
  missing, extra, differing value or shape) has no finding for X;
- (b) the banner's `Port notes:` describe the actual state (deferred parts
  named, nothing stale);
- (c) the upstream test family `vendor/exiftool/t/X.t` is green in
  `src/test/`, or its remaining deferrals are named with a reason in the
  test file's banner;
- (d) the command-line output for the images that exercise X is identical
  to the Perl original's (`./lexiftool` vs. `vendor/exiftool/exiftool`).

Documentation changes belong to the same commit as the code they describe;
no separate docs-only commits.

## 12. C modules: no writable static state

The C code of the library (`src/lexiftool/*.c`: `lexiftool.sys`) keeps
no state of its own: no writable variable at file scope (with or without
`static`) and no `static` variable inside a function. Such a variable is
shared by every Lua state and every thread of the process, so two sessions
in one host would race on it. What a Perl module keeps in a C-level static
(Term::ReadKey's saved console mode, a cached function pointer, ...) lives
per Lua state instead -- in a registry field, or in a userdata the registry
or the calling object holds (the time-zone objects of `tz_new`,
`ReadKeyState` of `readmode`/`peekchar`).

Constant data (`static const` tables, `static const char* const` keys) and
pure functions are fine; so are the C library's own calls, as long as they
need no global setting of the process (no `setlocale`, `setenv`, `tzset`;
see `strftime`'s locale object and the zone objects) and are safe in
several threads at once: the `_r` variants (`strerror_r`, `getpwuid_r`,
...), `nl_langinfo(RADIXCHAR)` rather than `localeconv()`. The same goes for
the C modules the library calls: `lfs.attributes` is asked for a single
attribute only, since its full table builds the `permissions` string in a
static buffer (a path's stat is `lexiftool.sys.stat`).

The one exception is signal handling (`signal`, `nosignals`): a C signal
handler reaches a Lua state only through static storage. These variables
are used only in a Lua state that has called `sys.nosignals(false)`, which
only the command-line launchers do; every other Lua state records its
handlers in its registry and installs nothing (doc/capi.md, "Signals").

Every writable variable of static storage duration in `src/lexiftool/*.c`
is checked mechanically; only the signal variables are exempt, each named
with its reason.
