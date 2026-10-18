--------------------------------------------------------------------------------
-- File:         lexiftool/RTF.lua
-- Ported from:  lib/Image/ExifTool/RTF.pm
--
-- Description:  Read Rich Text Format meta information
--
-- Revisions:    2010/06/17 - P. Harvey Created
--
-- References:   1) http://download.microsoft.com/download/2/f/5/2f599e18-07ee-4ec5-a1e7-f4e6a9423592/Word2007RTFSpec9.doc
--               2) http://search.cpan.org/dist/RTF-Writer/lib/RTF/Cookbook.pod
--
-- Port notes:   read subset. Ported: the Main/UserProps tables,
--               ReadToNested (the nested-brace reader), UnescapeRTF (the
--               escape-sequence decoder incl. hex chars, \uN unicode and
--               the standard entities), and ProcessRTF (the \info-group
--               and \userprops scanners with the RTF date-command parser).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst

local RTF = {}

-- supported RTF character entities
local rtfEntity = {
    par       = 0x0a,
    tab       = 0x09,
    endash    = 0x2013,
    emdash    = 0x2014,
    lquote    = 0x2018,
    rquote    = 0x2019,
    ldblquote = 0x201c,
    rdblquote = 0x201d,
    bullet    = 0x2022,
}

-- RTF tags (upstream %Image::ExifTool::RTF::Main)
RTF.Main = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        This table lists standard tags of the RTF information group, but ExifTool
        will also extract any non-standard tags found in this group.  As well,
        ExifTool will extract any custom properties that are found.  See
        L<http://www.microsoft.com/en-ca/download/details.aspx?id=10725> for the
        specification.
    ]],
    title = {},
    subject = {},
    author = { Groups = { [2] = 'Author' } },
    manager = {},
    company = {},
    copyright = { Groups = { [2] = 'Author' } }, -- (written by Apple TextEdit)
    operator = { Name = 'LastModifiedBy' },
    category = {},
    keywords = {},
    comment = {},
    doccomm = { Name = 'Comments' },
    hlinkbase = { Name = 'HyperlinkBase' },
    creatim = {
        Name = 'CreateDate',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    revtim = {
        Name = 'ModifyDate',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    printim = {
        Name = 'LastPrinted',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    buptim = {
        Name = 'BackupTime',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    edmins = {
        Name = 'TotalEditTime', -- in minutes
        PrintConv = function(_self, val) return ExifTool.ConvertTimeSpan(val, 60) end,
    },
    nofpages = { Name = 'Pages' },
    nofwords = { Name = 'Words' },
    nofchars = { Name = 'Characters' },
    nofcharsws = {
        Name = 'CharactersWithSpaces',
        Notes = [[
            according to the 2007 Microsoft RTF specification this is clearly the number
            of characters NOT including spaces, but Microsoft Word writes this as the
            number WITH spaces, so ExifTool names this tag according to the de facto
            standard
        ]],
    },
    id = { Name = 'InternalIDNumber' },
    version = { Name = 'RevisionNumber' },
    vern = { Name = 'InternalVersionNumber' },
}

-- lookup for user-defined properties
RTF.UserProps = {
    GROUPS = { [2] = 'Document' },
}

--------------------------------------------------------------------------------
-- Read to nested closing curly bracket "}" (upstream ReadToNested; the
-- vendored test files are small enough to read into memory in one go)
-- Inputs: 0) data string, 1) 1-based position just after the opening '{'
-- Returns: text inside brackets (or nil on error), plus the 1-based
--          position just after the matching '}'
--------------------------------------------------------------------------------
local function ReadToNested(data, pos)
    local level = 1
    local i = pos
    while i <= #data do
        local b = data:find('[{}]', i)
        if not b then return nil end
        -- count preceding backslashes
        local bs = 0
        local j = b - 1
        while j >= 1 and data:sub(j, j) == '\\' do bs = bs + 1 j = j - 1 end
        if bs % 2 == 0 then
            -- (bracket is not escaped)
            local c = data:sub(b, b)
            if c == '{' then
                level = level + 1
            else
                level = level - 1
                if level <= 0 then
                    return data:sub(pos, b - 1), b + 1
                end
            end
        end
        i = b + 1
    end
    return nil
end

--------------------------------------------------------------------------------
-- Unescape RTF escape sequences (upstream UnescapeRTF)
-- Inputs: 0) ExifTool ref, 1) RTF text, 2) RTF character set (for hex characters)
-- Returns: Unescaped text (in current ExifTool Charset)
--------------------------------------------------------------------------------
function RTF.UnescapeRTF(et, val, charset)
    -- return now unless we have a control sequence
    if not val:find('\\', 1, true) then
        val = val:gsub('[\r\n]', '') -- ignore CR's and LF's
        return val
    end
    -- CR/LF is significant if it terminates a control sequence (so change
    -- these to a space) -- upstream's first substitution
    val = val:gsub('\\([a-zA-Z]+%-?%d*)[\r\n]', '\\%1 ')
    -- protect the newline control sequence by converting to a \par command
    -- (upstream's second substitution)
    val = val:gsub('\\[\r\n]', '\\par ')
    -- all other CR/LF's are ignored (so delete them)
    val = val:gsub('[\r\n]', '')

    local rtnVal = {}
    local len = #val
    local skip = 1 -- default Unicode skip count
    local p0 = 1

    while true do
        -- find next backslash
        local p1 = val:find('\\', p0, true)
        if not p1 then p1 = len + 1 end
        -- add text up to start of this control sequence (or up to end)
        local n = p1 - p0
        if n > 0 then rtnVal[#rtnVal + 1] = val:sub(p0, p1 - 1) end
        -- all done if at the end or if control sequence is empty
        if p1 > len then break end
        -- look for an ASCII-letter control word or Unicode control
        -- (upstream `/\G([a-zA-Z]+)(-?\d+)? ?/g` -- the number is optional,
        --  which Lua patterns can't express as a group, so try both forms)
        local word, num = val:match('^([a-zA-Z]+)(%-?%d+) ?', p1 + 1)
        if not word then
            word = val:match('^([a-zA-Z]+) ?', p1 + 1)
        end
        if word then
            -- (position after the control word, accounting for the optional
            --  trailing space consumed by the pattern's ` ?`)
            local wordEnd = p1 + 1 + #word + #(num or '')
            if val:sub(wordEnd, wordEnd) == ' ' then wordEnd = wordEnd + 1 end
            if word == 'uc' then
                skip = tonumber(num)
                p0 = wordEnd
            elseif word == 'u' then
                if tonumber(num) < 0 then
                    et:Warn('Invalid Unicode character(s) in text')
                    rtnVal[#rtnVal + 1] = '?'
                    p0 = wordEnd
                else
                    rtnVal[#rtnVal + 1] = require('lexiftool.Charset').Recompose(et, { tonumber(num) })
                    if skip and skip ~= 0 then
                        -- must skip the specified number of characters
                        -- (not simple because RTF control words count as a single character)
                        -- (upstream: `\G([^\\]|\\([a-zA-Z]+)(-?\d+)? ?|\\'.{2}|\\.){$skip}`)
                        local consumed = 0
                        local sp = wordEnd
                        while consumed < skip and sp <= len do
                            local ch = val:sub(sp, sp)
                            if ch == '\\' then
                                -- a control word counts as a single character
                                local w2, n2 = val:match('^([a-zA-Z]+)(%-?%d+)? ?', sp + 1)
                                if w2 then
                                    sp = sp + 1 + #w2 + (#n2 or 0)
                                    if val:sub(sp, sp) == ' ' then sp = sp + 1 end
                                elseif val:sub(sp + 1, sp + 1) == "'" and sp + 4 <= len then
                                    sp = sp + 4 -- hex character (4 chars: \'xx)
                                else
                                    sp = sp + 2 -- standard control symbol
                                end
                            else
                                sp = sp + 1
                            end
                            consumed = consumed + 1
                        end
                        p0 = sp
                    else
                        p0 = wordEnd
                    end
                end
            elseif rtfEntity[word] then
                rtnVal[#rtnVal + 1] = require('lexiftool.Charset').Recompose(et, { rtfEntity[word] })
                p0 = wordEnd
            else
                p0 = wordEnd
            end
        else
            local ch = val:sub(p1 + 1, p1 + 1)
            if ch == "'" then
                -- hex character code
                if p1 + 3 > len then break end
                local hex = val:sub(p1 + 2, p1 + 3)
                if hex:match('^[0-9a-fA-F][0-9a-fA-F]$') then
                    rtnVal[#rtnVal + 1] = et:Decode(string.char(tonumber(hex, 16)), charset)
                end
                p0 = p1 + 4 -- skip to after the hex code
            else
                -- assume a standard control symbol (\, {, }, etc)
                rtnVal[#rtnVal + 1] = ch
                p0 = p1 + 2 -- skip to after this character
            end
        end
    end
    return table.concat(rtnVal)
end

--------------------------------------------------------------------------------
-- Read information in an RTF document (upstream ProcessRTF)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid RTF file
--------------------------------------------------------------------------------
function RTF.ProcessRTF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(64)
    raf:Seek(0, 0)
    if n ~= 64 or not buff:match('^[\r\n]*{[\r\n]*\\rtf[^a-zA-Z]') then return 0 end
    et:SetFileType()

    -- determine the RTF character set
    local cs
    local cpg = buff:match('\\ansicpg(%d*)')
    if cpg then
        cs = 'cp' .. cpg
    else
        local t = perl.matches(buff, '\\\\(ansi|mac|pc|pca)[^a-zA-Z]')
        local trans = {
            ansi = 'Latin',
            mac = 'MacRoman',
            pc = 'cp437',
            pca = 'cp850',
        }
        if t then
            cs = trans[t]
        else
            et:Warn('Unspecified RTF encoding. Will assume Latin')
            cs = 'Latin'
        end
    end
    local charset = ExifTool.charsetName[lc(cs)]
    if not charset then
        et:Warn('Unsupported RTF encoding ' .. cs .. '. Will assume Latin.')
        charset = 'Latin'
    end
    local tagTablePtr = et:GetTagTable('lexiftool.RTF.Main')

    -- read the whole file into memory (the vendored test file is 990 bytes)
    local data = raf:ReadFile()

    -- scan for \info group
    local gstart = data:find('{[\r\n]*\\info[^a-zA-Z]')
    if gstart then
        local info = ReadToNested(data, gstart + 1)
        if not info then
            et:Warn('Unterminated information group')
        else
            -- process info commands (eg. "\author", "\*\copyright"); the
            -- command is `{\tag` or `{\*\tag` (Lua patterns have no
            -- optional-group quantifier, so the `\*` form is tried first)
            local ipos = 1
            while true do
                local ibEnd
                local tag
                -- try the \*\tag form first, then the plain \tag form
                local s1, e1 = info:find('{[\r\n]*\\%*[\r\n]*\\([a-zA-Z]+)', ipos)
                local s2, e2 = info:find('{[\r\n]*\\([a-zA-Z]+)', ipos)
                if s1 and (not s2 or s1 <= s2) then
                    ibEnd = e1
                    tag = info:match('\\([a-zA-Z]+)', s1)
                elseif s2 then
                    ibEnd = e2
                    tag = info:match('\\([a-zA-Z]+)', s2)
                else
                    break
                end
                -- (the value starts after the separator; if the separator is
                --  a space, skip it, otherwise include it -- upstream
                --  `pos($info) = pos - 1 if $3 ne ' '`)
                local sep = info:sub(ibEnd + 1, ibEnd + 1)
                local valStart = sep == ' ' and (ibEnd + 2) or (ibEnd + 1)
                local val, iafter = ReadToNested(info, valStart)
                if not val then break end
                ipos = iafter
                tag = tag or ''
                local tagInfo = tagTablePtr[tag]
                if tagInfo and tagInfo.Format and tagInfo.Format == 'date' then
                    -- parse RTF date commands
                    local idx = { yr = 0, mo = 1, dy = 2, hr = 3, min = 4, sec = 5 }
                    local t = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
                    for k, v in val:gmatch('\\([a-z]+)(%d+)') do
                        if idx[k] then t[idx[k]] = tonumber(v) end
                    end
                    val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', t[0], t[1], t[2], t[3], t[4], t[5])
                else
                    -- unescape RTF string value
                    val = RTF.UnescapeRTF(et, val, charset)
                end
                -- create tagInfo for unknown tags
                if not tagInfo then
                    et:AddTagToTable(tagTablePtr, tag, { Name = ucfirst(tag) })
                end
                et:HandleTag(tagTablePtr, tag, val)
            end
        end
    end

    -- scan for \userprops
    -- scan for \userprops
    do
        local ub = data:find('{[\r\n]*\\%*[\r\n]*\\userprops[^a-zA-Z]')
        if ub then
            local props = ReadToNested(data, ub + 1)
            if not props then
                et:Warn('Unterminated user properties')
            else
                tagTablePtr = et:GetTagTable('lexiftool.RTF.UserProps')
                -- process user properties
                local tag
                local ppos = 1
                while true do
            -- (the command may be `\propname` or `\*\something`; try the
            --  plain form first since userprops entries are `{{\propname ...}`)
            local pb, pbEnd = props:find('{[\r\n]*\\([a-zA-Z]+)', ppos)
            if not pb then break end
            local t = props:match('\\([a-zA-Z]+)', pb)
            -- (the value starts after the separator; a space separator is
            --  skipped, otherwise included -- same rule as the info loop)
            local sep = props:sub(pbEnd + 1, pbEnd + 1)
            local valStart = sep == ' ' and (pbEnd + 2) or (pbEnd + 1)
            local val, pafter = ReadToNested(props, valStart)
            if not val then break end
            ppos = pafter
            val = RTF.UnescapeRTF(et, val, charset)
            if t == 'propname' then
                tag = val
            elseif t == 'staticval' and tag then
                tag = tag:gsub('[ \t\n\r\f\v](.)', function(c) return uc(c) end) -- capitalize all words in tag name
                tag = tag:gsub('[^%-_a-zA-Z0-9]', '') -- remove illegal characters
                if tag ~= '' then
                    if not tagTablePtr[tag] then
                        et:AddTagToTable(tagTablePtr, tag, { Name = tag })
                    end
                    et:HandleTag(tagTablePtr, tag, val)
                end
            end
                    -- (ignore \linkval and \proptype for now)
                end
            end
        end
    end
    return 1
end

return RTF