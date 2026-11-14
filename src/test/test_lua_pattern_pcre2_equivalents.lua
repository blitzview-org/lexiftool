--------------------------------------------------------------------------------
-- File:         test/test_lua_pattern_pcre2_equivalents.lua
--
-- Description:  executable reference for which Perl regex constructs a Lua
--               string pattern can safely stand in for, and which cannot.
--               Each assertion is either a confirmed SAFE equivalence (Lua
--               pattern and perl.* PCRE2 facade agree on the same input) or
--               a confirmed UNSAFE divergence (they disagree - documented so
--               nobody "fixes" the difference away by mistake). This file is
--               the source of truth for doc/conventions.md's guidance on
--               when a ported call site may keep a native Lua pattern
--               instead of going through the perl.* PCRE2 facade; if a
--               future Lua/PCRE2 version changes any of this behavior, this
--               file fails and flags it immediately.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

--------------------------------------------------------------------------------
-- SAFE: Lua pattern and Perl/PCRE2 regex agree - either may be used, Lua
-- pattern preferred only when it's actually cheaper (measured).
--------------------------------------------------------------------------------

-- literal substrings and ^/$ anchors on plain text
is('Bit016', ('Bit016'):match('^Bit%d+'), 'lua: literal + digit-run anchored at start')
ok(perl.matches('Bit016', [[^Bit\d+]]) == true, 'pcre2: same pattern matches (no capture group, so a bare true)')

-- \d <-> %d (digit class)
ok(('42'):match('^%d+$') ~= nil, 'lua %d matches digit run')
ok(perl.matches('42', [[^\d+$]]) == true, 'pcre2 \\d matches digit run')
ok(('4a'):match('^%d+$') == nil, 'lua %d rejects non-digit')
ok(perl.matches('4a', [[^\d+$]]) == nil, 'pcre2 \\d rejects non-digit')

-- \s <-> %s, \S <-> %S (whitespace class)
is('a b', (' a b '):match('^%s*(.-)%s*$'), 'lua %s trims whitespace via lazy capture')
is('a b', (perl.matches(' a b ', [[^\s*(.*?)\s*$]])), 'pcre2 \\s trims whitespace the same way (note: PCRE2 lazy is *?, not Lua\'s -)')

-- capture groups: identical syntax in both
is('42', ('id=42'):match('id=(%d+)'), 'lua capture group')
is('42', (perl.matches('id=42', [[id=(\d+)]])), 'pcre2 capture group, same pattern text')

-- greedy quantifiers * + ? on literals/classes: identical syntax and result
is('aaa', ('aaab'):match('^a+'), 'lua greedy +')
ok(perl.matches('aaab', [[^a+]]) == true, 'pcre2 greedy + matches (no capture group, so a bare true)')

-- negated character classes [^...]: identical syntax and semantics in both
-- (basic regex, no engine-specific magic on either side)
do
    local a, b, c = ('foo:bar:baz'):match('^([^:]*):([^:]*):([^:]*)')
    is('foo|bar|baz', a .. '|' .. b .. '|' .. c, 'lua [^:]* splits on a literal delimiter')
    local a2, b2, c2 = perl.matches('foo:bar:baz', [[^([^:]*):([^:]*):([^:]*)]])
    is('foo|bar|baz', a2 .. '|' .. b2 .. '|' .. c2, 'pcre2 [^:]* agrees with lua on the same pattern text')
end

-- byte-range character classes [x-y]: identical between a Lua pattern using
-- decimal \DDD string escapes (e.g. [\32-\126]) and PCRE2 using \xHH hex
-- escapes (e.g. [\x20-\x7e]) - both just express a literal byte range.
ok(('Hello World 123'):match('^[\32-\126]+$') ~= nil, 'lua byte-range class accepts printable ASCII')
ok(perl.matches('Hello World 123', [[^[\x20-\x7e]+$]]) == true, 'pcre2 byte-range class agrees')
ok(('Hello\1World'):match('^[\32-\126]+$') == nil, 'lua byte-range class rejects a control byte')
ok(perl.matches('Hello\1World', [[^[\x20-\x7e]+$]]) == nil, 'pcre2 byte-range class agrees')

-- lazy `*?` (PCRE2) <-> Lua's `-` (its only lazy quantifier, 0-or-more):
-- they agree for the simple "shortest match up to a delimiter" case.
is('a', ('<a><b>'):match('<(.-)>'), 'lua lazy - stops at first >')
is('a', (perl.matches('<a><b>', [[<(.*?)>]])), 'pcre2 lazy *? stops at first >, same result')

--------------------------------------------------------------------------------
-- UNSAFE: Lua pattern and Perl/PCRE2 regex genuinely disagree, or Lua has no
-- construct at all. Never hand-translate these - use the perl.* PCRE2 facade
-- with the literal Perl pattern instead. Each assertion below proves the
-- divergence so it can't silently regress into looking "equivalent".
--------------------------------------------------------------------------------

-- \w includes the underscore in Perl/PCRE2; Lua's %w does NOT (alnum only).
-- The correct Lua stand-in for \w is the character set [%w_], not %w alone -
-- this exact gap was a live bug in Samsung.lua (%w+ rejected block types
-- containing '_') until migrated to perl.matches with the literal \w+.
ok(('under_score'):match('^%w+$') == nil, 'lua %w rejects underscore (WRONG vs Perl \\w)')
ok(('under_score'):match('^[%w_]+$') ~= nil, 'lua [%w_] is the correct \\w stand-in')
ok(perl.matches('under_score', [[^\w+$]]) == true, 'pcre2 \\w accepts underscore directly')

-- \b (word boundary) has no exact Lua equivalent. Lua's frontier pattern
-- %f[set] can approximate it only when the "word" alphabet is letters-only;
-- once the real word-char class includes '_' or digits (as Perl's \w does),
-- %f[%a] and \b disagree on where a boundary falls.
is('Foo_Bar', (('foo_bar'):gsub('%f[%a]%a', string.upper)), 'lua %f[%a] treats _ as a boundary (WRONG vs Perl \\b)')
is('Foo_bar', (perl.subst('foo_bar', [[\b\w]], function(c) return c:upper() end, 'g')), 'pcre2 \\b correctly treats _ as a word char, no boundary before "bar"')

-- `.` matches a literal newline byte in Lua unconditionally (no flags exist).
-- Perl/PCRE2 `.` does NOT match \n unless the /s flag (inline (?s)) is given
-- - which is the Perl original's default unless the source says /s.
ok(('a\nb'):match('a.b') ~= nil, 'lua . matches embedded newline (WRONG vs Perl . without /s)')
is(nil, perl.matches('a\nb', 'a.b'), 'pcre2 . does not match newline without (?s), matching Perl default')
ok(perl.matches('a\nb', '(?s)a.b') == true, 'pcre2 (?s)a.b matches newline when the Perl original actually has /s')

-- Alternation `|` does not exist in Lua patterns at all.
ok(('DCSR'):match('^PHUT$') == nil and ('DCSR'):match('^DCSR$') ~= nil, 'lua alternation requires N separate match() calls, error-prone for N>2')
is('DCSR', (perl.matches('DCSR', [[^(PHUT|DCSR|AgHg|MeSa)$]])), 'pcre2 alternation is one literal pattern, matching the Perl original verbatim')

-- Bounded repetition {n,m} does not exist in Lua patterns at all.
ok(perl.matches('aaa', [[^a{2,3}$]]) == true, 'pcre2 {2,3} bounded repetition has no Lua pattern equivalent whatsoever')

-- Case-insensitive matching: Lua patterns have no inline flag; PCRE2 has (?i).
ok(perl.matches('ABC', '(?i)abc') == true, 'pcre2 (?i) case-insensitive match has no Lua pattern equivalent')

-- Non-capturing groups (?:...): every parenthesis in a Lua pattern captures;
-- there is no way to group without capturing, unlike Perl's (?:...).
-- (a Lua pattern would need an extra capture around "ab", shifting every
--  downstream capture index)
ok(perl.matches('abc', [[(?:ab)c]]) == true, 'pcre2 non-capturing group')

-- Optional capture group `(x)?`: the `?` quantifier can only apply to a
-- single character or class in a Lua pattern, never to a group, so `(b)?`
-- silently matches NOTHING -- not even when "b" is present.  (This exact
-- gap was a live bug in XMP.lua's SaveBlankInfo nodeID-path split: upstream's
-- `((/.*)?)$` optional suffix never matched, so no blank-node info was ever
-- stored -- fixed by capturing the rest unconditionally and treating an
-- empty capture as the absent optional group.)
ok(('a'):match('^(a(b)?)$') == nil, 'lua optional group (b)? never matches (WRONG vs Perl)')
ok(('ab'):match('^(a(b)?)$') == nil, 'lua optional group (b)? fails even when b is present (WRONG vs Perl)')
ok(perl.matches('a', [[^(a(b)?)$]]) ~= nil, 'pcre2 optional group matches when absent')
ok(perl.matches('ab', [[^(a(b)?)$]]) ~= nil, 'pcre2 optional group matches when present')

TestLib.done()
