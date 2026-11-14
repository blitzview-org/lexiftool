--------------------------------------------------------------------------------
-- File:         lexiftool/PerlConfig.lua
--
-- Description:  Read an exiftool config file written in Perl as data
--
-- Notes:        An exiftool config file (.ExifTool_config, -config FILE) is
--               Perl code that exiftool loads with `require`.  Most real
--               config files only assign package variables of
--               Image::ExifTool::UserDefined (and a few others) with nested
--               hash and list literals.  lexiftool never runs Perl: this
--               module parses that subset of Perl and carries the
--               assignments out on Lua tables, with Perl's semantics for
--               the constructs it accepts:
--
--               - statements: `%NAME = LIST;`, `@NAME = LIST;`,
--                 `$NAME = EXPR;`, element assignments
--                 (`$NAME{KEY}{KEY} = EXPR;`, `$NAME[N] = EXPR;`, with or
--                 without `->`, autovivifying), `use`/`require` of an
--                 Image::ExifTool module (loads the Lua module; `use` at
--                 compile time, before the statements run, as Perl does),
--                 the pragmas strict, warnings, utf8 (ASCII files only) and
--                 a Perl version, the calls in CALLS below, constant
--                 statements (`1;`), POD, comments and __END__/__DATA__;
--               - values: numbers (decimal, float, hex, octal, binary),
--                 strings ('...', "..." without interpolation, q{} and qq{}
--                 with any delimiter), qw(), undef, barewords where Perl
--                 takes them for strings (before `=>`, in a subscript, as a
--                 value outside `use strict`), lists, hash and array
--                 literals, references \%NAME, \@NAME and \&NAME, a package
--                 hash or array spliced into a list (%NAME, @NAME, %{EXPR},
--                 @{EXPR}), unary minus and the operators . + - * | & << >>
--                 between constants.
--
--               Package variables are those of Image::ExifTool::UserDefined
--               (kept here across config files, as Perl keeps its package
--               variables, and handed to the caller's apply function as the
--               table a Lua config file returns), a few variables that
--               upstream reads when their module loads (PRELOAD below),
--               tag tables of a module the config file loaded, and new
--               tables in another Image::ExifTool package.
--
--               Anything else (sub, my, our, local, package, BEGIN, if,
--               loops, other calls, variables in values, interpolation, a
--               heredoc, regular expressions, ...) is not run: the whole
--               file is rejected with the line and the construct, and
--               nothing of it is used.  A call of a subroutine that is not
--               defined dies at run time as in Perl: the statements before
--               it stay in effect.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')

local PerlConfig = {}

-- the package variables of the config files read so far, by sigil and name
-- ('%Image::ExifTool::UserDefined', '@Image::ExifTool::UserDefined::Lenses')
PerlConfig.symbols = {}

-- the Lua modules of the Perl modules that config files loaded (with the
-- modules they load in turn): Perl's packages that exist at that time
PerlConfig.loaded = {}

-- the functions a config file may call, by package-qualified name: the
-- module that must be loaded for the sub to be defined, and the function
local CALLS = {
    ['Image::ExifTool::XMP::RegisterNamespace'] = { 'lexiftool.XMP', 'RegisterNamespace' },
}

-- package variables that upstream modules read when they are loaded (not
-- assign): a config file may set them before the module loads
-- (sigil .. name -> module, field)
local PRELOAD = {
    ['$Image::ExifTool::Geolocation::geoDir'] = { 'lexiftool.Geolocation', 'geoDir' },
    ['$Image::ExifTool::Geolocation::altDir'] = { 'lexiftool.Geolocation', 'altDir' },
    ['%Image::ExifTool::Geolocation::geoLang'] = { 'lexiftool.Geolocation', 'geoLang' },
    ['%Image::ExifTool::Shortcuts::UserDefined'] = { 'lexiftool.Shortcuts', 'UserDefined' },
}

-- Perl's named operators and builtin functions: a bareword with one of
-- these names is not a string
local BUILTIN = { }
for name in ([[
    abs accept alarm and atan2 bind binmode bless caller chdir chmod chomp
    chop chown chr chroot close closedir cmp connect cos crypt dbmclose
    dbmopen defined delete die do dump each else elsif eof eq eval exec exists
    exit exp fcntl fileno flock for foreach fork format formline ge getc
    getlogin getpeername getpgrp getppid getpriority glob gmtime goto grep gt
    hex if index int ioctl join keys kill last lc lcfirst le length link listen
    local localtime log lstat lt map mkdir msgctl msgget msgrcv msgsnd my ne
    next no not oct open opendir or ord our pack package pipe pop pos print
    printf prototype push quotemeta rand read readdir readline readlink
    readpipe recv redo ref rename require reset return reverse rewinddir
    rindex rmdir say scalar seek seekdir select semctl semget semop send
    setpgrp setpriority shift shmctl shmget shmread shmwrite shutdown sin
    sleep socket socketpair sort splice split sprintf sqrt srand stat state
    study sub substr symlink syscall sysopen sysread sysseek system syswrite
    tell telldir tie tied time times truncate uc ucfirst umask undef unless
    unlink unpack unshift untie until use utime values vec wait waitpid
    wantarray warn while write x xor BEGIN END INIT CHECK UNITCHECK
    AUTOLOAD DESTROY __FILE__ __LINE__ __PACKAGE__ __SUB__
]]):gmatch('[A-Za-z_]+') do
    BUILTIN[name] = true
end

-- the kind of a reference ('HASH', 'ARRAY'), for the tables made here
local kinds = setmetatable({ }, { __mode = 'k' })

local function newHash() local t = { } kinds[t] = 'HASH' return t end
local function newArray() local t = { } kinds[t] = 'ARRAY' return t end

-- (a rejection: the line and the construct, raised as an error object)
local Reject = { }
Reject.__index = Reject
local function reject(line, what)
    error(setmetatable({ line = line, what = what }, Reject), 0)
end
-- (a Perl run-time error: the message, raised as an error object)
local Die = { }
Die.__index = Die

--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------

local BRACKETS = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' }

-- the multi-character operators, longest first
local OPS = { '<=>', '**=', '||=', '&&=', '//=', '...', '<<=', '>>=',
              '=>', '->', '<<', '>>', '==', '!=', '<=', '>=', '=~', '!~', '**', '||', '&&', '//',
              '..', '::', '+=', '-=', '*=', '/=', '.=', '%=', 'x=', '|=', '&=', '^=', '++', '--' }

-- process the body of a double-quoted string (after its delimiters are
-- removed); escapes as Perl, interpolation of a variable is rejected
local function unescapeDQ(body, line)
    local buf, i, len = { }, 1, #body
    local SIMPLE = { n = '\n', t = '\t', r = '\r', f = '\f', b = '\b', a = '\a', e = '\27' }
    while i <= len do
        local c = body:sub(i, i)
        if c == '\\' then
            local n = body:sub(i + 1, i + 1)
            if SIMPLE[n] then
                buf[#buf + 1] = SIMPLE[n]
                i = i + 2
            elseif n:match('^[0-7]$') then
                local oct = body:match('^[0-7][0-7]?[0-7]?', i + 1)
                local code = tonumber(oct, 8)
                if code > 255 then reject(line, 'wide character in a string') end
                buf[#buf + 1] = string.char(code)
                i = i + 1 + #oct
            elseif n == 'x' then
                local hex = body:match('^{([0-9A-Fa-f_ ]*)}', i + 2)
                if hex then
                    i = i + 4 + #hex
                    hex = hex:gsub('[_ ]', '')
                else
                    hex = body:match('^[0-9A-Fa-f]?[0-9A-Fa-f]?', i + 2)
                    i = i + 2 + #hex
                end
                local code = hex == '' and 0 or tonumber(hex, 16)
                if code > 255 then reject(line, 'wide character in a string') end
                buf[#buf + 1] = string.char(code)
            elseif n:match('^[lLuUQEFNco]$') then
                reject(line, 'escape \\' .. n .. ' in a string')
            elseif n == '' then
                buf[#buf + 1] = '\\'
                i = i + 1
            else
                buf[#buf + 1] = n
                i = i + 2
            end
        elseif c == '$' then
            if i < len then reject(line, 'interpolation in "..."') end
            buf[#buf + 1] = c
            i = i + 1
        elseif c == '@' and body:sub(i + 1, i + 1):match('^[A-Za-z_:{$]$') then
            reject(line, 'interpolation in "..."')
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return table.concat(buf)
end

-- process the body of a single-quoted string: only \\ and a backslashed
-- delimiter are escapes
local function unescapeSQ(body, open, close)
    local buf, i, len = { }, 1, #body
    while i <= len do
        local c = body:sub(i, i)
        if c == '\\' and i < len then
            local n = body:sub(i + 1, i + 1)
            if n == '\\' or n == open or n == close then
                buf[#buf + 1] = n
            else
                buf[#buf + 1] = c .. n
            end
            i = i + 2
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return table.concat(buf)
end

-- Tokenize the text.  Returns the list of tokens; each has `t` (type:
-- 'num', 'str', 'qw', 'var', 'ident', 'op', 'eof') and `line`, and `v` (the
-- value, the name, the operator), `sigil` for a 'var', `dq` for a
-- double-quoted string body.  A construct the lexer already knows to be
-- outside the subset (heredoc, regex, backticks) is rejected here.
local tokenizeText
local function tokenize(text)
    -- (a construct the lexer rejects ends the tokens with a 'bad' token: the
    --  parser reports it when it gets there, so that an earlier construct
    --  outside the subset is the one reported)
    local tokens = { }
    local ok, err = pcall(tokenizeText, text, tokens)
    if not ok then
        if getmetatable(err) ~= Reject then error(err, 0) end
        tokens[#tokens + 1] = { t = 'bad', line = err.line, v = err.what }
    end
    return tokens
end
tokenizeText = function(text, tokens)
    -- (a leading newline, so that POD on the first line is seen as such)
    text = '\n' .. text
    local pos, line, len = 1, 0, #text
    local function emit(tok)
        tok.line = tok.line or line
        tokens[#tokens + 1] = tok
        return tok
    end
    -- does the previous token end a term (so that an operator comes next)?
    local function afterTerm()
        local prev = tokens[#tokens]
        if not prev then return false end
        if prev.t == 'op' then return prev.v == ')' or prev.v == ']' or prev.v == '}' end
        return true
    end
    local function countLines(s)
        local _, n = s:gsub('\n', '')
        line = line + n
    end
    -- the delimited body starting at the opening delimiter at position p;
    -- returns the raw body and the position after the closing delimiter
    local function delimited(p, startLine)
        local open = text:sub(p, p)
        local close = BRACKETS[open] or open
        local depth, i = 1, p + 1
        while i <= len do
            local c = text:sub(i, i)
            if c == '\\' then
                i = i + 2
            else
                if c == close then
                    depth = depth - 1
                    if depth == 0 then
                        countLines(text:sub(p, i))
                        return text:sub(p + 1, i - 1), i + 1, open, close
                    end
                elseif c == open then
                    depth = depth + 1
                end
                i = i + 1
            end
        end
        reject(startLine, "string without its closing delimiter " .. close)
    end
    while true do
        -- skip white space, comments and POD
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == '\n' then
                line = line + 1
                pos = pos + 1
                -- POD: a line starting with =WORD, up to a line =cut (where
                -- a new statement may begin, as Perl takes it)
                local prev = tokens[#tokens]
                if text:sub(pos, pos) == '=' and text:sub(pos + 1, pos + 1):match('^[A-Za-z]$') and
                   (not prev or (prev.t == 'op' and (prev.v == ';' or prev.v == '}')))
                then
                    local stop = text:find('\n=cut[^\n]*', pos)
                    local podEnd
                    if text:sub(pos, pos + 3) == '=cut' then
                        podEnd = text:find('\n', pos) or len + 1
                    elseif stop then
                        podEnd = text:find('\n', stop + 1) or len + 1
                    else
                        podEnd = len + 1
                    end
                    countLines(text:sub(pos, podEnd - 1))
                    pos = podEnd
                end
            elseif c == ' ' or c == '\t' or c == '\r' or c == '\f' or c == '\v' then
                pos = pos + 1
            elseif c == '#' then
                pos = text:find('\n', pos) or len + 1
            else
                break
            end
        end
        if pos > len then break end
        local c = text:sub(pos, pos)
        local term = not afterTerm()
        if term and (c == '%' or c == '@' or c == '$' or c == '&') then
            local name = text:match('^::?[A-Za-z_][A-Za-z0-9_]*', pos + 1) or
                         text:match('^[A-Za-z_][A-Za-z0-9_]*', pos + 1)
            if name then
                local p = pos + 1 + #name
                while true do
                    local more = text:match('^::[A-Za-z0-9_]+', p)
                    if not more then break end
                    name = name .. more
                    p = p + #more
                end
                name = name:gsub('^::', 'main::')
                emit({ t = 'var', sigil = c, v = name })
                pos = p
            elseif text:sub(pos + 1, pos + 1) == '{' then
                emit({ t = 'op', v = c .. '{' })
                pos = pos + 2
            elseif c == '$' and text:sub(pos + 1, pos + 1) == '#' then
                reject(line, '$#')
            elseif c == '$' and pos < len then
                reject(line, 'variable $' .. text:sub(pos + 1, pos + 1))
            else
                emit({ t = 'op', v = c })
                pos = pos + 1
            end
        elseif c == "'" then
            local startLine = line
            local body, p = delimited(pos, startLine)
            emit({ t = 'str', v = unescapeSQ(body, "'", "'"), line = startLine })
            pos = p
        elseif c == '"' then
            local startLine = line
            local body, p = delimited(pos, startLine)
            emit({ t = 'str', v = unescapeDQ(body, startLine), line = startLine })
            pos = p
        elseif c == '`' then
            reject(line, 'backticks')
        elseif c:match('^[0-9]$') or (c == '.' and term and text:sub(pos + 1, pos + 1):match('^[0-9]$')) then
            local num, v
            num = text:match('^0[xX][0-9A-Fa-f_]+', pos)
            if num then
                local digits = num:sub(3):gsub('_', '')
                if #digits > 15 and (#digits > 16 or digits:sub(1, 1):match('^[89A-Fa-f]$')) then
                    reject(line, 'number ' .. num .. ' too large')
                end
                v = tonumber(digits, 16)
            else
                num = text:match('^0[bB][01_]+', pos)
                if num then
                    local digits = num:sub(3):gsub('_', '')
                    if #digits > 63 then reject(line, 'number ' .. num .. ' too large') end
                    v = tonumber(digits, 2)
                else
                    num = text:match('^0[0-7_]+', pos)
                    if num and not text:sub(pos + #num, pos + #num):match('^[0-9.eE]$') then
                        local digits = num:sub(2):gsub('_', '')
                        if #digits > 21 then reject(line, 'number ' .. num .. ' too large') end
                        v = tonumber(digits, 8)
                    else
                        num = text:match('^[0-9_]*', pos)
                        local p = pos + #num
                        local float = false
                        -- (a fraction, but not the range operator `1..2`)
                        if text:sub(p, p) == '.' and text:sub(p + 1, p + 1) ~= '.' then
                            local frac = text:match('^%.[0-9_]*', p)
                            num = num .. frac
                            p = p + #frac
                            float = true
                        end
                        local exp = text:match('^[eE][+-]?[0-9_]+', p)
                        if exp then
                            num = num .. exp
                            float = true
                        end
                        local digits = num:gsub('_', '')
                        if digits:sub(1, 1) == '.' then digits = '0' .. digits end
                        if digits:sub(-1) == '.' then digits = digits .. '0' end
                        if float then
                            v = tonumber(digits) + 0.0
                        else
                            v = math.tointeger(tonumber(digits))
                            -- (beyond an IV Perl has a UV or an NV)
                            if not v or #digits > 18 then reject(line, 'number ' .. num .. ' too large') end
                        end
                    end
                end
            end
            emit({ t = 'num', v = v })
            pos = pos + #num
        elseif c:match('^[A-Za-z_]$') then
            local name = text:match('^[A-Za-z_][A-Za-z0-9_]*', pos)
            local p = pos + #name
            while true do
                local more = text:match("^::[A-Za-z0-9_]*", p)
                if not more then break end
                name = name .. more
                p = p + #more
            end
            -- (a word before `=>` is a string, whatever it is)
            local fat = text:match('^[ \t\r\n]*=>', p)
            if fat then
                emit({ t = 'ident', v = name, fat = true })
                pos = p
            elseif term and (name == '__END__' or name == '__DATA__') then
                break
            elseif name == 'q' or name == 'qq' or name == 'qw' then
                local d = text:match('^[ \t\r\n]*()', p)
                local delim = text:sub(d, d)
                if delim == '' or delim:match('^[A-Za-z0-9_,;)}%]=]$') or (delim == '#' and d > p) then
                    emit({ t = 'ident', v = name })
                    pos = p
                else
                    countLines(text:sub(p, d - 1))
                    local startLine = line
                    local body, after, open, close = delimited(d, startLine)
                    if name == 'q' then
                        emit({ t = 'str', v = unescapeSQ(body, open, close), line = startLine })
                    elseif name == 'qq' then
                        -- (a backslashed delimiter is the delimiter itself)
                        local unesc = body:gsub('\\([%' .. open .. '%' .. close .. '])', '%1')
                        emit({ t = 'str', v = unescapeDQ(unesc, startLine), line = startLine })
                    else
                        local list = { }
                        for w in unescapeSQ(body, open, close):gmatch('[^ \t\r\n\f]+') do
                            list[#list + 1] = w
                        end
                        emit({ t = 'qw', v = list, line = startLine })
                    end
                    pos = after
                end
            elseif term and (name == 'm' or name == 's' or name == 'y' or name == 'tr' or
                             name == 'qr' or name == 'qx') and
                   text:match('^[ \t]*[^A-Za-z0-9_ \t\r\n,;)]', p) then
                reject(line, name .. '//')
            else
                emit({ t = 'ident', v = name })
                pos = p
            end
        elseif term and c == '<' and text:match('^<<~?["\'A-Za-z_]', pos) then
            reject(line, 'heredoc')
        elseif term and c == '/' then
            reject(line, 'regular expression')
        else
            local op
            for _, o in ipairs(OPS) do
                if text:sub(pos, pos + #o - 1) == o then op = o break end
            end
            op = op or c
            emit({ t = 'op', v = op })
            pos = pos + #op
        end
    end
    emit({ t = 'eof', v = 'end of file' })
end

--------------------------------------------------------------------------------
-- Parser
--------------------------------------------------------------------------------

-- the binary operators between constants, by precedence (higher binds
-- tighter), as Perl's
local BINOP = { ['*'] = 5, ['+'] = 4, ['-'] = 4, ['.'] = 4, ['<<'] = 3, ['>>'] = 3,
                ['&'] = 2, ['|'] = 1 }

-- a description of a token, for messages
local function describe(tok)
    if tok.t == 'var' then return 'variable ' .. tok.sigil .. tok.v end
    if tok.t == 'ident' then return tok.v end
    if tok.t == 'str' then return 'string' end
    if tok.t == 'num' then return 'number' end
    if tok.t == 'qw' then return 'qw()' end
    if tok.t == 'eof' then return 'end of file' end
    return "'" .. tok.v .. "'"
end

-- Parse the tokens into a program: { uses = {...}, statements = {...} }.
-- `strict`: barewords are not strings (piped config files, which upstream
-- evals in ExifTool.pm's scope, under its `use strict`)
local function parse(tokens, strict, text)
    local i = 1
    local function peek(k)
        local tok = tokens[i + (k or 0)] or tokens[#tokens]
        if tok.t == 'bad' then reject(tok.line, tok.v) end
        return tok
    end
    local function next_() local tok = peek() i = i + 1 return tok end
    local function isOp(tok, v) return tok.t == 'op' and tok.v == v end
    local function expect(v)
        local tok = next_()
        if not isOp(tok, v) then reject(tok.line, "expected '" .. v .. "' before " .. describe(tok)) end
        return tok
    end
    local parseList

    -- a subscript key: a bareword, -bareword or an expression
    local function parseKey()
        local tok, tok2 = peek(), peek(1)
        if tok.t == 'ident' and isOp(tok2, '}') then
            next_()
            return { t = 'str', v = tok.v, line = tok.line }
        elseif isOp(tok, '-') and tok2.t == 'ident' and isOp(peek(2), '}') then
            next_() next_()
            return { t = 'str', v = '-' .. tok2.v, line = tok.line }
        end
        return parseList()
    end

    local function parseExpr(minPrec)
        local tok = next_()
        local node
        if tok.t == 'num' or tok.t == 'str' then
            node = { t = tok.t, v = tok.v, line = tok.line }
        elseif tok.t == 'qw' then
            node = { t = 'qw', v = tok.v, line = tok.line }
        elseif isOp(tok, '(') then
            local items = isOp(peek(), ')') and { t = 'list', items = { }, line = tok.line } or parseList()
            expect(')')
            node = { t = 'paren', v = items, line = tok.line }
        elseif isOp(tok, '[') then
            local items = isOp(peek(), ']') and { t = 'list', items = { }, line = tok.line } or parseList()
            expect(']')
            node = { t = 'array', v = items, line = tok.line }
        elseif isOp(tok, '{') then
            local items = isOp(peek(), '}') and { t = 'list', items = { }, line = tok.line } or parseList()
            expect('}')
            node = { t = 'hash', v = items, line = tok.line }
        elseif isOp(tok, '\\') then
            local var = next_()
            if var.t ~= 'var' or var.sigil == '$' then reject(tok.line, 'reference \\' .. describe(var)) end
            if isOp(peek(), '(') then reject(tok.line, 'call of &' .. var.v) end
            node = { t = 'ref', sigil = var.sigil, name = var.v, line = tok.line }
        elseif tok.t == 'var' then
            if tok.sigil == '$' or tok.sigil == '&' then reject(tok.line, describe(tok) .. ' in a value') end
            if isOp(peek(), '{') or isOp(peek(), '[') then reject(tok.line, 'slice of ' .. describe(tok)) end
            node = { t = 'var', sigil = tok.sigil, name = tok.v, line = tok.line }
        elseif isOp(tok, '%{') or isOp(tok, '@{') then
            local inner = parseList()
            expect('}')
            node = { t = 'deref', sigil = tok.v:sub(1, 1), v = inner, line = tok.line }
        elseif isOp(tok, '-') then
            local nxt = peek()
            if nxt.t == 'ident' and not BUILTIN[nxt.v] then
                next_()
                node = { t = 'str', v = '-' .. nxt.v, line = tok.line }
            else
                node = { t = 'neg', v = parseExpr(6), line = tok.line }
            end
        elseif isOp(tok, '+') then
            node = parseExpr(6)
        elseif tok.t == 'ident' then
            if tok.fat then
                node = { t = 'str', v = tok.v, line = tok.line }
            elseif tok.v == 'undef' then
                if isOp(peek(), '(') and isOp(peek(1), ')') then next_() next_() end
                node = { t = 'undef', line = tok.line }
            elseif isOp(peek(), '(') or isOp(peek(), '->') then
                reject(tok.line, 'call of ' .. tok.v)
            elseif BUILTIN[tok.v] then
                reject(tok.line, tok.v)
            elseif strict and not tok.v:find('::', 1, true) then
                reject(tok.line, 'bareword ' .. tok.v .. ' under use strict')
            else
                -- (a bareword: under no strict a string; Foo:: is 'Foo')
                node = { t = 'str', v = tok.v:gsub('::$', ''), line = tok.line }
            end
        else
            reject(tok.line, 'unexpected ' .. describe(tok))
        end
        -- binary operators between constants
        while true do
            local op = peek()
            local prec = op.t == 'op' and BINOP[op.v]
            if not prec and op.t == 'ident' and op.v == 'x' then reject(op.line, "operator 'x'") end
            if not prec or prec <= (minPrec or 0) then break end
            next_()
            node = { t = 'binop', op = op.v, a = node, b = parseExpr(prec), line = op.line }
        end
        return node
    end

    -- a comma-separated list (`=>` is a comma)
    parseList = function()
        local first = peek()
        local items = { }
        while true do
            local tok = peek()
            if isOp(tok, ')') or isOp(tok, ']') or isOp(tok, '}') or isOp(tok, ';') or tok.t == 'eof' then
                break
            end
            items[#items + 1] = parseExpr()
            tok = peek()
            if isOp(tok, ',') or isOp(tok, '=>') then
                next_()
            else
                break
            end
        end
        local tok = peek()
        if not (isOp(tok, ')') or isOp(tok, ']') or isOp(tok, '}') or isOp(tok, ';') or tok.t == 'eof') then
            if tok.t == 'ident' and (tok.v == 'if' or tok.v == 'unless' or tok.v == 'for' or
                                     tok.v == 'foreach' or tok.v == 'while' or tok.v == 'until') then
                reject(tok.line, 'statement modifier ' .. tok.v)
            elseif tok.t == 'op' or (tok.t == 'ident' and BUILTIN[tok.v]) then
                reject(tok.line, 'operator ' .. tok.v)
            end
            reject(tok.line, 'unexpected ' .. describe(tok))
        end
        return { t = 'list', items = items, line = first.line }
    end

    local function endStatement()
        local tok = peek()
        if isOp(tok, ';') then
            next_()
        elseif tok.t ~= 'eof' then
            if tok.t == 'ident' and (tok.v == 'if' or tok.v == 'unless' or tok.v == 'for' or
                                     tok.v == 'foreach' or tok.v == 'while' or tok.v == 'until') then
                reject(tok.line, 'statement modifier ' .. tok.v)
            end
            reject(tok.line, 'unexpected ' .. describe(tok))
        end
    end

    local program = { uses = { }, statements = { } }
    local hasUtf8
    while peek().t ~= 'eof' do
        local tok = peek()
        local stmt
        if isOp(tok, ';') then
            next_()
        elseif tok.t == 'ident' and (tok.v == 'use' or tok.v == 'no') then
            next_()
            local mod = next_()
            local use = { t = tok.v, line = tok.line }
            if mod.t == 'num' or (mod.t == 'ident' and mod.v:match('^v[0-9]')) then
                use.version = true
            elseif mod.t ~= 'ident' then
                reject(tok.line, tok.v .. ' ' .. describe(mod))
            else
                use.module = mod.v
                if mod.v == 'strict' then
                    -- (no strict / no strict 'refs' etc.: only the subs part
                    --  matters here, for the barewords)
                    if tok.v == 'use' then
                        strict = true
                    elseif isOp(peek(), ';') or peek().t == 'eof' then
                        strict = false
                    end
                elseif mod.v == 'utf8' then
                    hasUtf8 = tok.v == 'use' and tok.line
                elseif mod.v == 'warnings' then
                    -- (warnings: the run-time warnings of a hash assignment)
                    use.warnings = tok.v == 'use'
                elseif tok.v == 'no' or not (mod.v == 'Image::ExifTool' or
                                             mod.v:sub(1, 17) == 'Image::ExifTool::') then
                    reject(tok.line, tok.v .. ' ' .. mod.v)
                end
                -- (the import list does not matter for data)
                if not isOp(peek(), ';') and peek().t ~= 'eof' then parseList() end
            end
            endStatement()
            program.uses[#program.uses + 1] = use
            if use.warnings ~= nil then
                stmt = { t = 'warnings', on = use.warnings, line = tok.line }
            end
        elseif tok.t == 'ident' and tok.v == 'require' then
            next_()
            local mod = next_()
            if mod.t == 'num' or (mod.t == 'ident' and mod.v:match('^v[0-9]')) then
                stmt = { t = 'expr', v = { t = 'num', v = 1 }, line = tok.line }
            elseif mod.t == 'ident' and (mod.v == 'Image::ExifTool' or mod.v:sub(1, 17) == 'Image::ExifTool::') then
                stmt = { t = 'require', module = mod.v, line = tok.line }
            else
                reject(tok.line, 'require ' .. (mod.t == 'ident' and mod.v or describe(mod)))
            end
            endStatement()
        elseif tok.t == 'ident' and CALLS[tok.v] and isOp(peek(1), '(') then
            next_() next_()
            local args = isOp(peek(), ')') and { t = 'list', items = { } } or parseList()
            expect(')')
            stmt = { t = 'call', name = tok.v, args = args, line = tok.line }
            endStatement()
        elseif tok.t == 'var' and (tok.sigil == '%' or tok.sigil == '@' or tok.sigil == '$') then
            next_()
            local lhs = { t = 'var', sigil = tok.sigil, name = tok.v }
            if tok.sigil == '$' then
                -- element assignment: $NAME{KEY}..., $NAME[N]...
                local keys = { }
                while true do
                    local s = peek()
                    if isOp(s, '->') and (isOp(peek(1), '{') or isOp(peek(1), '[')) and #keys > 0 then
                        next_()
                        s = peek()
                    end
                    if isOp(s, '{') then
                        next_()
                        keys[#keys + 1] = { hash = true, v = parseKey() }
                        expect('}')
                    elseif isOp(s, '[') then
                        next_()
                        keys[#keys + 1] = { hash = false, v = parseList() }
                        expect(']')
                    else
                        break
                    end
                end
                if #keys > 0 then
                    lhs = { t = 'elem', sigil = keys[1].hash and '%' or '@', name = tok.v, keys = keys }
                end
            end
            local op = next_()
            if not isOp(op, '=') then
                if op.t == 'op' and op.v:sub(-1) == '=' and op.v ~= '==' and op.v ~= '=>' then
                    reject(op.line, 'operator ' .. op.v)
                end
                reject(op.line, 'unexpected ' .. describe(op) .. ' after ' .. describe(tok))
            end
            local rhs
            if peek().t == 'eof' or isOp(peek(), ';') then reject(op.line, 'unexpected ' .. describe(peek())) end
            rhs = parseList()
            stmt = { t = 'assign', lhs = lhs, rhs = rhs, line = tok.line }
            endStatement()
        elseif tok.t == 'num' or tok.t == 'str' then
            stmt = { t = 'expr', v = parseList(), line = tok.line }
            endStatement()
        elseif tok.t == 'ident' then
            if isOp(peek(1), '(') or isOp(peek(1), '->') or peek(1).t == 'var' or peek(1).t == 'str' then
                if BUILTIN[tok.v] and not isOp(peek(1), '->') then reject(tok.line, tok.v) end
                reject(tok.line, 'call of ' .. tok.v)
            end
            reject(tok.line, tok.v)
        elseif tok.t == 'var' then
            reject(tok.line, 'call of &' .. tok.v)
        elseif isOp(tok, '{') then
            reject(tok.line, 'block')
        else
            reject(tok.line, 'unexpected ' .. describe(tok))
        end
        if stmt then program.statements[#program.statements + 1] = stmt end
    end
    -- (under `use utf8` the string literals would be characters, not bytes)
    if hasUtf8 and text:find('[\128-\255]') then
        reject(hasUtf8, 'use utf8 with non-ASCII text')
    end
    return program
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

-- the address of a table or function, for the Perl string of a reference
local function address(v)
    return (('%p'):format(v):gsub('^0x0*', '0x'))
end

-- a value as a hash key: Perl keys are strings; a key that is the string
-- of an integer is the integer here, as the Lua tag tables have it
local function toKey(v)
    local s
    if type(v) == 'table' then
        s = (kinds[v] or 'HASH') .. '(' .. address(v) .. ')'
    elseif type(v) == 'function' then
        s = 'CODE(' .. address(v) .. ')'
    else
        s = perl.str(v)
    end
    if s == '0' or (s:match('^%-?[1-9][0-9]*$') and #s < 19) then
        return math.tointeger(tonumber(s))
    end
    return s
end

-- Run the program.  `host` provides the package variables and the module
-- loading (see PerlConfig.Load).  Raises a Reject for a construct outside
-- the subset, a Die for a Perl run-time error.
local function run(program, host)
    local warnings = false
    local line      -- (the line of the statement, where Perl's warnings are)
    local evalList, evalScalar

    -- flatten a node into the list `out`
    local function flatten(node, out)
        local t = node.t
        if t == 'list' then
            for _, item in ipairs(node.items) do flatten(item, out) end
        elseif t == 'paren' then
            flatten(node.v, out)
        elseif t == 'qw' then
            for _, w in ipairs(node.v) do out.n = out.n + 1 out[out.n] = w end
        elseif t == 'var' or t == 'deref' then
            local c
            if t == 'var' then
                c = host.var(node.sigil, node.name, node.line, false)
            else
                c = evalScalar(node.v)
                local kind = node.sigil == '%' and 'HASH' or 'ARRAY'
                if type(c) ~= 'table' or (kinds[c] or 'HASH') ~= kind then
                    reject(node.line, node.sigil .. '{...} of a value that is not a ' .. kind .. ' reference')
                end
            end
            if c then
                if node.sigil == '%' then
                    local keys = { }
                    for k in pairs(c) do keys[#keys + 1] = k end
                    perl.tsort(keys, function(a, b) return perl.lt(perl.str(a), perl.str(b)) end)
                    for _, k in ipairs(keys) do
                        out[out.n + 1], out[out.n + 2] = k, c[k]
                        out.n = out.n + 2
                    end
                else
                    for k = 1, #c do out.n = out.n + 1 out[out.n] = c[k] end
                end
            end
        else
            out.n = out.n + 1
            out[out.n] = evalScalar(node)
        end
    end
    evalList = function(node)
        local out = { n = 0 }
        flatten(node, out)
        return out
    end

    -- fill a hash from a list (later keys replace earlier ones)
    local function fillHash(h, list, what)
        if list.n % 2 == 1 and warnings then
            if list.n == 1 and type(list[1]) == 'table' then
                host.warn('Reference found where even-sized list expected', line)
            else
                host.warn('Odd number of elements in ' .. what, line)
            end
        end
        for k = 1, list.n, 2 do
            host.set(h, toKey(list[k]), list[k + 1])
        end
    end

    evalScalar = function(node)
        local t = node.t
        if t == 'num' or t == 'str' then return node.v end
        if t == 'undef' then return nil end
        if t == 'hash' then
            local h = newHash()
            fillHash(h, evalList(node.v), 'anonymous hash')
            return h
        elseif t == 'array' then
            local a = newArray()
            local list = evalList(node.v)
            for k = 1, list.n do
                if list[k] == nil then reject(node.line, 'undef in a list') end
                a[k] = list[k]
            end
            return a
        elseif t == 'ref' then
            if node.sigil == '&' then return host.code(node.name, node.line) end
            return host.var(node.sigil, node.name, node.line, true)
        elseif t == 'list' or t == 'paren' or t == 'qw' or t == 'var' or t == 'deref' then
            -- (a list in scalar context: Perl's comma operator, the last value)
            if t == 'var' or t == 'deref' then reject(node.line, node.sigil .. ' variable in scalar context') end
            local list = evalList(node)
            return list[list.n]
        elseif t == 'neg' then
            local v = evalScalar(node.v)
            if type(v) == 'string' and v:match('^[A-Za-z_]') then return '-' .. v end
            if type(v) ~= 'number' then reject(node.line, 'unary minus of a value that is not a number') end
            if v == math.mininteger then return -(v + 0.0) end
            return -v
        elseif t == 'binop' then
            local a, b = evalScalar(node.a), evalScalar(node.b)
            local op = node.op
            if op == '.' then
                if type(a) == 'table' or type(b) == 'table' then reject(node.line, "'.' of a reference") end
                return perl.str(a) .. perl.str(b)
            end
            if type(a) ~= 'number' or type(b) ~= 'number' then
                reject(node.line, "operator '" .. op .. "' between values that are not numbers")
            end
            if op == '+' or op == '-' or op == '*' then
                local f
                if op == '+' then f = (a + 0.0) + b elseif op == '-' then f = (a + 0.0) - b else f = (a + 0.0) * b end
                if math.type(a) == 'integer' and math.type(b) == 'integer' and f == math.floor(f) and
                   math.abs(f) < 2^53 then
                    return math.tointeger(f)
                end
                return f
            end
            -- (bit operators: on unsigned integers)
            if math.type(a) ~= 'integer' or math.type(b) ~= 'integer' or a < 0 or b < 0 then
                reject(node.line, "operator '" .. op .. "' on a value that is not an unsigned integer")
            end
            if op == '|' then return a | b end
            if op == '&' then return a & b end
            if b >= 64 then return 0 end
            if op == '<<' then
                local r = a << b
                if r < 0 or (r >> b) ~= a then reject(node.line, "operator '<<' beyond 63 bits") end
                return r
            end
            return a >> b
        end
        reject(node.line, 'unsupported value')
    end

    local last = nil
    for _, stmt in ipairs(program.statements) do
        local t = stmt.t
        line = stmt.line
        if t == 'warnings' then
            warnings = stmt.on
        elseif t == 'require' then
            host.load(stmt.module, stmt.line)
            last = 1
        elseif t == 'call' then
            local list = evalList(stmt.args)
            last = host.call(stmt.name, list, stmt.line)
        elseif t == 'expr' then
            local list = evalList(stmt.v)
            last = list[list.n]
        elseif t == 'assign' then
            local lhs = stmt.lhs
            if lhs.t == 'var' then
                local c = host.var(lhs.sigil, lhs.name, stmt.line, true)
                if lhs.sigil == '$' then
                    local v = evalScalar(stmt.rhs)
                    host.set(c, 'value', v)
                    last = v
                else
                    local list = evalList(stmt.rhs)
                    for k in pairs(c) do host.set(c, k, nil) end
                    if lhs.sigil == '%' then
                        fillHash(c, list, 'hash assignment')
                    else
                        for k = 1, list.n do
                            if list[k] == nil then reject(stmt.line, 'undef in a list') end
                            host.set(c, k, list[k])
                        end
                    end
                    -- (a list assignment in scalar context: the number of
                    --  elements on its right)
                    last = list.n
                end
            else
                local v = evalScalar(stmt.rhs)
                local c = host.var(lhs.sigil, lhs.name, stmt.line, true, true)
                for n, key in ipairs(lhs.keys) do
                    local k = evalScalar(key.v)
                    if key.hash then
                        k = toKey(k)
                    else
                        if math.type(k) ~= 'integer' then reject(stmt.line, 'array index that is not an integer') end
                        if k < 0 then k = #c + k end
                        if k < 0 then reject(stmt.line, 'array index before the start') end
                        k = k + 1
                        if k > #c + 1 then reject(stmt.line, 'array element beyond the end') end
                    end
                    if n == #lhs.keys then
                        if v == nil and not key.hash then reject(stmt.line, 'undef in a list') end
                        host.set(c, k, v)
                    else
                        local nextKey = lhs.keys[n + 1]
                        local sub = c[k]
                        if sub == nil then
                            sub = nextKey.hash and newHash() or newArray()
                            host.set(c, k, sub)
                        elseif type(sub) ~= 'table' or (kinds[sub] or 'HASH') ~= (nextKey.hash and 'HASH' or 'ARRAY') then
                            reject(stmt.line, 'element of a value that is not a reference')
                        end
                        c = sub
                    end
                end
                last = v
            end
        end
    end
    return last
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- the names below Image::ExifTool::UserDefined that upstream reads, with
-- their sigil (the variables of another sigil are never read)
local USER_VARS = { Shortcuts = '%', Options = '%', FileTypes = '%', Lenses = '@',
                    Arguments = '@', Geolocation = '@' }

-- does a module exist (without loading it)?
local function moduleExists(name)
    if package.loaded[name] or package.preload[name] then return true end
    for _, searcher in ipairs(package.searchers or { }) do
        local loader = searcher(name)
        if type(loader) == 'function' then return true end
    end
    return false
end

-- the Lua module of a Perl module name ('Image::ExifTool::XMP' -> 'lexiftool.XMP')
local function luaModule(perlName)
    if perlName == 'Image::ExifTool' then return 'lexiftool' end
    return 'lexiftool.' .. perlName:sub(18):gsub('::', '.')
end

-- Read a Perl config file.
-- Inputs: 0) the text, 1) the file name (for messages; '-' for a piped
--         config), 2) apply: function(config, file, isPerl) that takes over
--         the UserDefined variables, given as the table a Lua config file
--         returns (isPerl true)
-- Returns: true if the file was read (fully, or up to a Perl run-time error)
function PerlConfig.Load(text, file, apply)
    local ExifTool = require('lexiftool')
    local symbols = PerlConfig.symbols
    local undo, touched, touchedList, pending = { }, { }, { }, { }
    -- (writes are logged, so that a rejection at run time leaves no trace)
    local function set(t, k, v)
        undo[#undo + 1] = { t, k, rawget(t, k) }
        t[k] = v
    end
    local host = { set = set }
    function host.warn(msg, line)
        pending[#pending + 1] = msg .. ' at ' .. file .. ' line ' .. line .. '.\n'
    end
    -- load an Image::ExifTool module
    function host.load(perlName, line)
        local name = luaModule(perlName)
        if not moduleExists(name) then reject(line, 'module ' .. perlName .. ' not available in lexiftool') end
        local before = { }
        for k in pairs(package.loaded) do before[k] = true end
        require(name)
        PerlConfig.loaded[name] = true
        for k in pairs(package.loaded) do
            if not before[k] then PerlConfig.loaded[k] = true end
        end
    end
    -- the container of a package variable (a table; a scalar is a table
    -- with the field `value`); nil for a variable that is not there and
    -- not created (`create` false)
    function host.var(sigil, name, line, create, elem)
        local key = sigil .. name
        local c = symbols[key]
        if c then
            if not touched[key] and create then
                touched[key] = true
                touchedList[#touchedList + 1] = key
            end
            return c
        end
        local isUser = name == 'Image::ExifTool::UserDefined' or name:sub(1, 30) == 'Image::ExifTool::UserDefined::'
        local mod, field
        if not isUser and not PRELOAD[key] then
            local pkg, var = name:match('^Image::ExifTool::(.+)::([A-Za-z0-9_]+)$')
            if not pkg then
                if name:sub(1, 17) == 'Image::ExifTool::' then
                    reject(line, 'variable ' .. key .. ' of package Image::ExifTool')
                end
                reject(line, 'variable ' .. key)
            end
            if sigil ~= '%' then reject(line, 'variable ' .. key) end
            mod, field = luaModule('Image::ExifTool::' .. pkg), var
            local m = PerlConfig.loaded[mod] and package.loaded[mod]
            if type(m) == 'table' and m[field] ~= nil then
                -- (a tag table of a loaded module, or one of its package hashes)
                local tbl = m[field]
                local isTable = type(tbl) == 'table' and getmetatable(tbl) == nil
                if isTable then
                    isTable = false
                    for k in pairs(tbl) do
                        if ExifTool.specialTags[k] then isTable = true break end
                    end
                end
                if not isTable then reject(line, 'variable ' .. key .. ' of the module') end
                if create and not elem then reject(line, 'assignment to ' .. key .. ' of the module') end
                return tbl
            end
        end
        if not create then return nil end
        -- a new package variable
        c = sigil == '@' and newArray() or newHash()
        set(symbols, key, c)
        touched[key] = true
        touchedList[#touchedList + 1] = key
        return c
    end
    -- a reference to a subroutine \&NAME: the Lua function, or one that
    -- looks it up when called if its module is not loaded yet
    function host.code(name, line)
        if name:sub(1, 17) ~= 'Image::ExifTool::' then reject(line, 'reference \\&' .. name) end
        local func = ExifTool.evalFuncs()[name]
        if func then return func end
        local pkg, sub = name:match('^(Image::ExifTool::.+)::([A-Za-z_][A-Za-z0-9_]*)$')
        if not pkg then reject(line, 'reference \\&' .. name) end
        local modName = luaModule(pkg)
        if not moduleExists(modName) then reject(line, 'reference \\&' .. name) end
        return function(...)
            local f = require(modName)[sub]
            if type(f) ~= 'function' then perl.die('Undefined subroutine &' .. name .. ' called') end
            return f(...)
        end
    end
    -- a call of one of the CALLS
    function host.call(name, args, line)
        local mod, func = CALLS[name][1], CALLS[name][2]
        local m = PerlConfig.loaded[mod] and package.loaded[mod]
        if type(m) ~= 'table' or type(m[func]) ~= 'function' then
            error(setmetatable({ msg = 'Undefined subroutine &' .. name .. ' called at ' .. file ..
                                       ' line ' .. line .. '.\n' }, Die), 0)
        end
        return m[func](table.unpack(args, 1, args.n))
    end

    local ok, result = pcall(function()
        if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
        -- (upstream evals a piped config file in ExifTool.pm, under its
        --  `use strict`)
        local program = parse(tokenize(text), file == '-', text)
        for _, use in ipairs(program.uses) do
            if use.module and (use.module == 'Image::ExifTool' or use.module:sub(1, 17) == 'Image::ExifTool::') then
                host.load(use.module, use.line)
            end
        end
        return run(program, host)
    end)
    local died
    if not ok then
        if getmetatable(result) == Reject then
            for k = #undo, 1, -1 do
                local u = undo[k]
                u[1][u[2]] = u[3]
            end
            perl.warn('Config file not supported by lexiftool (Perl code at line ' .. result.line .. ': ' ..
                      result.what .. '): ' .. file .. '\n')
            return false
        elseif getmetatable(result) == Die then
            died = result.msg
        else
            error(result, 0)
        end
    end
    for _, msg in ipairs(pending) do perl.warn(msg) end
    -- hand the variables this file set to the caller, as a Lua config table
    local config, preload = { }, { }
    for _, key in ipairs(touchedList) do
        local sigil, name = key:sub(1, 1), key:sub(2)
        local rest = name:match('^Image::ExifTool::UserDefined::(.+)$')
        if name == 'Image::ExifTool::UserDefined' then
            if sigil == '%' then config[name] = symbols[key] end
        elseif PRELOAD[key] then
            preload[#preload + 1] = key
        elseif rest then
            local want = USER_VARS[rest] or '%'
            if sigil == want then
                local val = symbols[key]
                -- (the keys of these hashes are names: Perl's strings, also
                --  where they look like integers)
                if USER_VARS[rest] == '%' then
                    local named = { }
                    for k, v in pairs(val) do named[perl.str(k)] = v end
                    val = named
                end
                config[name] = val
            end
        elseif sigil == '%' then
            -- (a new table in another package)
            config[name] = symbols[key]
        end
    end
    apply(config, file, true)
    for _, key in ipairs(preload) do
        local mod, field = PRELOAD[key][1], PRELOAD[key][2]
        local val = symbols[key]
        if key:sub(1, 1) == '$' then val = val.value end
        local m = require(mod)
        m[field] = val
        -- (Shortcuts.pm loads the user-defined shortcuts when it is loaded:
        --  these first, then those of UserDefined::Shortcuts)
        if mod == 'lexiftool.Shortcuts' then
            m.LoadShortcuts(val)
            if ExifTool.UserDefinedTables.Shortcuts then m.LoadShortcuts(ExifTool.UserDefinedTables.Shortcuts) end
        end
    end
    if died then
        perl.warn(died)
    elseif file ~= '-' and not perl.truthy(result) then
        perl.warn(file .. ' did not return a true value\n')
    end
    return true
end

-- Parse a Perl config file without running it (for tools and tests).
-- Returns the program, or nil, the line and the construct of a rejection
function PerlConfig.Parse(text, strict)
    local ok, result = pcall(function()
        if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
        return parse(tokenize(text), strict, text)
    end)
    if ok then return result end
    if getmetatable(result) == Reject then return nil, result.line, result.what end
    error(result, 0)
end

return PerlConfig
