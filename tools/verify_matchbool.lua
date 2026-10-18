--------------------------------------------------------------------------------
-- File:         tools/verify_matchbool.lua
--
-- Description:  verify that a regex match whose first capture may be unset is
--               never tested through perl.matches' first return value
--------------------------------------------------------------------------------

-- doc/conventions.md §6: perl.matches/matchesDyn return the captures, and a
-- group that took no part in the match comes back as nil (Perl's undef). When
-- the FIRST group can stay unset -- `(a)?b`, `^x|(y)`, `(a)*b` -- a successful
-- match therefore starts with nil, and `if matches(s, [[(a)?b]])` is false
-- where Perl's `if ($s =~ /(a)?b/)` is true. Such a test must be written
-- `if isMatch(s, [[(a)?b]])`.
--
-- Reported (exit 1):
--
-- 1. matches/matchesDyn whose first return value is used other than as
--    captures, unless the pattern is a literal whose first group must take
--    part in every match (or that has no group at all). "As captures" means
--    the call is the whole right-hand side of an assignment
--    (`local a, b = matches(...)`). Every other use -- `if`, `not`,
--    `and`/`or`, `== nil`, `return`, a function argument, and also a table
--    constructor `{ matches(...) }`, whose length operator may report 0 for
--    a table starting with nil (Lua 5.5 and LuaJIT do) -- is a boolean (or
--    scalar) use. A pattern that is not a literal (matchesDyn,
--    or matches with a concatenation involving variables) counts as unsafe,
--    since its groups cannot be checked here.
-- 2. findAll/split/eachSplit with a literal pattern that has any group
--    which can stay unset, and eachMatch with one whose first group can:
--    these yield such a group as false (a nil cannot sit in an array, and a
--    nil first value would end the for loop), where Perl has undef.
-- 3. subst with a literal pattern that has such a group and a replacement
--    function (lrexlib passed the unset group to it as false; lpcre passes
--    nil, Perl's undef -- the check is kept as it was).
-- 4. matches/matchesDyn/isMatch/isMatchDyn as the last argument of a call:
--    Lua passes every return value on -- all captures plus the end offset --
--    so `tonumber(matches(s, [[(\d+)]]))` is tonumber(cap, endOffset), a
--    number in base endOffset. Perl's `($s =~ /(\d+)/)[0]` or `$1` is
--    `tonumber((matches(...)))` (or a local first).
--
-- Literals are recognized as a single string literal, a `..` chain of string
-- literals, or a name bound to such a chain by a `local NAME = ...` in the
-- same file. The pattern structure is parsed here (no PCRE2 needed): a group
-- can stay unset if it, or a group around it, is quantified with a minimum
-- of 0 (`?`, `*`, `{0,n}`, `{,n}`), sits in a branch of an alternation, or
-- lies inside a negative lookaround, a conditional or a branch-reset group.
-- Comments are skipped; the check covers src/lexiftool.lua and the modules
-- directly in src/lexiftool/ (not perl.lua, which implements the facade).
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).

local function walkUp(startDir)
    local repoDir = startDir
    while true do
        local marker = repoDir .. '/vendor/exiftool/t/ExifTool.t'
        local f = io.open(marker, 'r')
        if f then f:close(); return repoDir end
        local parent = repoDir:match('^(.*)/[^/]+$')
        if not parent then return repoDir end
        repoDir = parent
    end
end

local function moduleDir()
    local source = debug.getinfo(1, 'S').source
    if source:sub(1, 1) == '@' then source = source:sub(2) end
    source = source:gsub('^%./', '')
    local ok, lfs = pcall(require, 'lfs')
    if ok and source:sub(1, 1) ~= '/' then
        local cwd = lfs.currentdir()
        -- forward slashes: a Windows path (backslashes) would be eaten as
        -- escapes by Perl's glob in the runtime checks below
        if cwd then source = cwd:gsub('\\', '/') .. '/' .. source end
    end
    return source:match('^(.*)/[^/]+$') or '.'
end

local REPO = walkUp(moduleDir())
if not io.open(REPO .. '/vendor/exiftool/t/ExifTool.t', 'r') then
    io.stderr:write('verify_matchbool.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local SRC = REPO .. '/src/lexiftool'

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

--------------------------------------------------------------------------------
-- Pattern structure
--------------------------------------------------------------------------------

-- Quantifier at position i of p: returns its minimum and the position after
-- it (including a lazy/possessive suffix), or nil if there is none.
local function quantAt(p, i)
    local c = p:sub(i, i)
    local min, j
    if c == '?' or c == '*' then
        min, j = 0, i + 1
    elseif c == '+' then
        min, j = 1, i + 1
    elseif c == '{' then
        local a, b, lo = p:find('^{(%d+),?%d*}', i)
        if not a then
            a, b = p:find('^{,%d+}', i)
            if not a then return nil end -- (a literal brace)
            lo = '0'
        end
        min, j = tonumber(lo), b + 1
    else
        return nil
    end
    local d = p:sub(j, j)
    if d == '?' or d == '+' then j = j + 1 end
    return min, j
end

-- Parse PCRE pattern p; returns the number of capturing groups and an array
-- telling for each whether it can be unset after a successful match.
-- Raises an error for a construct it does not understand.
local function captureInfo(p)
    local root = { kind = 'root', alt = false, min = 1 }
    local stack = { root }
    local caps = {}
    local i, n = 1, #p
    local xmode = false
    while i <= n do
        local c = p:sub(i, i)
        local atomEnd           -- position after a plain atom
        if c == '\\' then
            local d = p:sub(i + 1, i + 1)
            local j = i + 2
            if d == 'Q' then
                local e = p:find('\\E', j, true)
                atomEnd = e and e + 2 or n + 1
            else
                local open = p:sub(j, j)
                local close = ({ ['{'] = '}', ['<'] = '>', ["'"] = "'" })[open]
                if d:match('[xopPNgk]') and close then
                    local e = p:find(close, j + 1, true)
                    j = (e or n) + 1
                elseif d == 'c' then
                    j = j + 1
                end
                atomEnd = j
            end
        elseif c == '[' then
            local j = i + 1
            if p:sub(j, j) == '^' then j = j + 1 end
            if p:sub(j, j) == ']' then j = j + 1 end
            while j <= n do
                local e = p:sub(j, j)
                if e == '\\' then
                    j = j + 2
                elseif e == '[' and p:sub(j + 1, j + 1) == ':' then
                    local q = p:find(':]', j + 2, true)
                    j = q and q + 2 or j + 1
                elseif e == ']' then
                    j = j + 1
                    break
                else
                    j = j + 1
                end
            end
            atomEnd = j
        elseif c == '(' then
            local r = p:sub(i + 1)
            local kind, j
            if r:find('^%*') or r:find('^%?#') then          -- (*VERB), comment
                local e = p:find(')', i, true)
                i = (e or n) + 1
                goto continue
            elseif not r:find('^%?') then kind, j = 'cap', i + 1
            elseif r:find('^%?[:>]') then kind, j = 'group', i + 3
            elseif r:find('^%?=') then kind, j = 'look', i + 3
            elseif r:find('^%?!') then kind, j = 'neglook', i + 3
            elseif r:find('^%?<=') then kind, j = 'look', i + 4
            elseif r:find('^%?<!') then kind, j = 'neglook', i + 4
            elseif r:find('^%?|') then kind, j = 'reset', i + 3
            elseif r:find('^%?%(') then kind, j = 'cond', i + 2
            elseif r:find('^%?P?<[%a_]') or r:find("^%?'") then
                kind, j = 'cap', p:find("[>']", i + 3) + 1
            else
                -- inline flags: (?i) applies to the rest, (?i:...) is a group
                local a, b, fl, how = r:find('^%?([%a%-%^]*)([:)])')
                if not a then error('unsupported group construct at ' .. i) end
                if fl:match('^[^-]*x') then xmode = true end
                if how == ')' then
                    i = i + 1 + b
                    goto continue
                end
                kind, j = 'group', i + 1 + b
            end
            local g = { kind = kind, alt = false, min = 1, parent = stack[#stack] }
            if kind == 'cap' then caps[#caps + 1] = g end
            stack[#stack + 1] = g
            i = j
            goto continue
        elseif c == ')' then
            local g = table.remove(stack)
            if #stack == 0 then error('unbalanced )') end
            local min, j = quantAt(p, i + 1)
            if min then g.min = min; i = j else i = i + 1 end
            goto continue
        elseif c == '|' then
            stack[#stack].alt = true
            i = i + 1
            goto continue
        elseif xmode and c == '#' then
            local e = p:find('\n', i, true)
            i = (e or n) + 1
            goto continue
        else
            atomEnd = i + 1
        end
        i = select(2, quantAt(p, atomEnd)) or atomEnd
        ::continue::
    end
    if #stack ~= 1 then error('unbalanced (') end
    local optional = {}
    for k, g in ipairs(caps) do
        local opt = g.min == 0
        local a = g.parent
        while a do      -- (an alternation inside g itself leaves g set)
            if a.alt or a.min == 0 or a.kind == 'neglook' or a.kind == 'cond'
                or a.kind == 'reset' then
                opt = true
            end
            a = a.parent
        end
        optional[k] = opt
    end
    return #caps, optional
end

--------------------------------------------------------------------------------
-- Lua source scanning
--------------------------------------------------------------------------------

-- End of the long bracket opening at i of s (s:sub(i) starts with `[=*[`),
-- and its body.
local function longBracket(s, i)
    local eq = s:match('^%[(=*)%[', i)
    if not eq then return nil end
    local close = ']' .. eq .. ']'
    local e = s:find(close, i, true)
    if not e then return #s, s:sub(i + #eq + 2) end
    return e + #close - 1, s:sub(i + #eq + 2, e - 1)
end

-- Tokens of a Lua source: { t = 'str'|'id'|'num'|'op', v = value, s = start,
-- line = line number }; comments and whitespace are dropped, string literals
-- carry their value.
local function tokens(src)
    local out, i, n, line = {}, 1, #src, 1
    local function add(t, v, s, e)
        out[#out + 1] = { t = t, v = v, s = s, line = line }
        local _, nl = src:sub(s, e):gsub('\n', '')
        line = line + nl
    end
    while i <= n do
        local c = src:sub(i, i)
        if src:sub(i, i + 1) == '--' then
            local e = longBracket(src, i + 2)
            if not e then e = (src:find('\n', i, true) or n + 1) - 1 end
            local _, nl = src:sub(i, e):gsub('\n', '')
            line = line + nl
            i = e + 1
        elseif c == '[' and src:find('^%[=*%[', i) then
            local e, body = longBracket(src, i)
            -- (Lua drops a newline right after the opening bracket)
            add('str', (body:gsub('^\r?\n', '')), i, e)
            i = e + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c then break
                else j = j + 1 end
            end
            local fn = load('return ' .. src:sub(i, j))
            local ok, v = pcall(fn or error)
            add('str', ok and v or nil, i, j)
            i = j + 1
        elseif c:match('[%a_]') then
            local a, b = src:find('^[%w_]+', i)
            add('id', src:sub(a, b), a, b)
            i = b + 1
        elseif c:match('%d') then
            local a, b = src:find('^[%w_.]+', i)
            add('num', src:sub(a, b), a, b)
            i = b + 1
        elseif c == '\n' then
            line = line + 1
            i = i + 1
        elseif c:match('%s') then
            i = i + 1
        else
            local op = src:match('^%.%.%.', i) or src:match('^[=~<>]=', i)
                or src:match('^%.%.', i) or src:match('^::', i) or src:match('^//', i)
                or src:match('^<<', i) or src:match('^>>', i) or c
            add('op', op, i, i + #op - 1)
            i = i + #op
        end
    end
    return out
end

-- Value of the literal expression in tokens toks[a..b] (a string literal or
-- a `..` chain of them, or a name in consts), or nil.
local function literalValue(toks, a, b, consts)
    if a == b and toks[a].t == 'id' then return consts[toks[a].v] end
    local parts = {}
    for k = a, b do
        local t = toks[k]
        if (k - a) % 2 == 0 then
            if t.t ~= 'str' or t.v == nil then return nil end
            parts[#parts + 1] = t.v
        elseif not (t.t == 'op' and t.v == '..') then
            return nil
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

-- Names bound to a literal by `local NAME = <literal>` (statement ends at the
-- next token that cannot continue the chain).
local function localConsts(toks)
    local consts = {}
    for k = 1, #toks - 3 do
        if toks[k].v == 'local' and toks[k + 1].t == 'id' and toks[k + 2].v == '=' then
            local b = k + 3
            while toks[b + 2] and toks[b + 1].v == '..' and toks[b + 2].t == 'str' do b = b + 2 end
            if not (toks[b + 1] and toks[b + 1].v == '..') then
                local v = literalValue(toks, k + 3, b, {})
                if v and consts[toks[k + 1].v] == nil then consts[toks[k + 1].v] = v end
            end
        end
    end
    return consts
end

local FUNCS = {
    matches = 'match', matchesDyn = 'match', isMatch = 'bool', isMatchDyn = 'bool',
    eachMatch = 'iter', findAll = 'list', split = 'list', eachSplit = 'list',
    subst = 'subst',
}
local PAT_ARG = { split = 1, eachSplit = 1 }

-- Binary operators after which a value is used, not stored.
local USE_AFTER = {
    ['and'] = true, ['or'] = true, ['=='] = true, ['~='] = true, ['..'] = true,
    ['<'] = true, ['>'] = true, ['<='] = true, ['>='] = true, ['+'] = true,
    ['-'] = true, ['*'] = true, ['/'] = true, ['//'] = true, ['%'] = true,
    ['^'] = true, ['&'] = true, ['|'] = true, ['~'] = true, ['<<'] = true,
    ['>>'] = true, ['['] = true, ['.'] = true, [':'] = true, ['('] = true,
}

local failures = 0
local function report(path, line, msg)
    print(('%s:%d: %s'):format(path:sub(#REPO + 2), line, msg))
    failures = failures + 1
end

local function check(path)
    local src = readall(path)
    local toks = tokens(src)
    local consts = localConsts(toks)
    for k = 1, #toks do
        local t = toks[k]
        local kind = t.t == 'id' and FUNCS[t.v]
        if not kind or not toks[k + 1] or toks[k + 1].v ~= '(' then goto next end
        local prev = toks[k - 1]
        if prev and (prev.v == 'function' or prev.v == ':') then goto next end
        local first = k
        if prev and prev.v == '.' then
            if toks[k - 2].v ~= 'perl' then goto next end
            first = k - 2
        end
        do
            -- split the argument list at top-level commas
            local depth, args, a0 = 0, {}, k + 2
            local j = k + 1
            while j <= #toks do
                local v = toks[j].t == 'op' and toks[j].v
                if v == '(' or v == '{' or v == '[' then
                    depth = depth + 1
                elseif v == ')' or v == '}' or v == ']' then
                    depth = depth - 1
                    if depth == 0 then
                        args[#args + 1] = { a0, j - 1 }
                        break
                    end
                elseif v == ',' and depth == 1 then
                    args[#args + 1] = { a0, j - 1 }
                    a0 = j + 1
                end
                j = j + 1
            end
            local close = j
            local pa = args[PAT_ARG[t.v] or 2]
            local pat = pa and pa[1] <= pa[2] and literalValue(toks, pa[1], pa[2], consts)
            local ncap, optional
            if pat then
                local ok, nc, opt = pcall(captureInfo, pat)
                if not ok then
                    report(path, t.line, 'cannot parse pattern ' .. pat .. ': ' .. tostring(nc))
                    goto next
                end
                ncap, optional = nc, opt
            end
            local shown = pat and ('[[' .. pat .. ']]') or '(non-literal pattern)'
            if kind == 'match' or kind == 'bool' then
                -- (4) last argument of a call?
                local before, after = toks[first - 1], toks[close + 1]
                if before and (before.v == '(' or before.v == ',') and after and after.v == ')' then
                    -- find the parenthesis that opens the enclosing list
                    local d, o = 0, first - 1
                    while o >= 1 do
                        local v = toks[o].t == 'op' and toks[o].v
                        if v == ')' or v == ']' or v == '}' then
                            d = d + 1
                        elseif v == '(' or v == '[' or v == '{' then
                            if d == 0 then break end
                            d = d - 1
                        end
                        o = o - 1
                    end
                    local caller = toks[o - 1]
                    if toks[o] and toks[o].v == '(' and caller and (caller.t == 'id'
                        and caller.v ~= 'and' and caller.v ~= 'or' and caller.v ~= 'not'
                        and caller.v ~= 'return' and caller.v ~= 'if' and caller.v ~= 'elseif'
                        and caller.v ~= 'while' and caller.v ~= 'until' and caller.v ~= 'in'
                        or caller.v == ')' or caller.v == ']' or caller.t == 'str') then
                        report(path, t.line, t.v .. ' as the last argument of a call passes'
                            .. ' all captures and the end offset on -- wrap it in parentheses')
                    end
                end
            end
            if kind == 'bool' then
                goto next
            elseif kind == 'match' then
                if pat and not optional[1] then goto next end
                local before, after = toks[first - 1], toks[close + 1]
                local usedAfter = after and ((after.t == 'op' and USE_AFTER[after.v])
                    or after.v == 'then' or after.v == 'do')
                -- (a table constructor is no capture context here: `#t` of a
                --  table with a nil first value may well be 0)
                local asCaptures = not usedAfter and before ~= nil and before.v == '='
                if not asCaptures then
                    report(path, t.line, t.v .. ' with ' .. shown .. ' used as a boolean; '
                        .. (pat and 'its first group may be unset' or 'its groups are unknown')
                        .. ' -- use isMatch' .. (t.v == 'matchesDyn' and 'Dyn' or ''))
                end
            elseif pat then
                local anyOpt = false
                for i = 1, kind == 'iter' and 1 or ncap do anyOpt = anyOpt or optional[i] end
                if anyOpt then
                    local repl = args[3]
                    local strRepl = repl and repl[1] == repl[2] and toks[repl[1]].t == 'str'
                    if kind == 'list' or kind == 'iter' then
                        report(path, t.line, t.v .. ' with ' .. shown
                            .. ': a group that may be unset comes back as false, not undef')
                    elseif not strRepl then
                        report(path, t.line, 'subst with ' .. shown .. ' and a replacement'
                            .. ' function: a group that may be unset is passed as false')
                    end
                end
            end
        end
        ::next::
    end
end

local p = io.popen("ls '" .. SRC .. "'/*.lua '" .. REPO .. "'/src/lexiftool.lua 2>/dev/null")
for path in p:lines() do
    if not path:match('/perl%.lua$') then check(path) end
end
p:close()

if failures > 0 then
    print(('verify_matchbool: %d regex facade call(s) would read an unset capture wrongly'
        .. ' (doc/conventions.md §6)'):format(failures))
    os.exit(1)
end
print('verify_matchbool: OK')
