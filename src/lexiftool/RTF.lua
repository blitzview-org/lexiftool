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
-- Port notes:   complete (read-only module).
--               - A data reference with its pos() is a table
--                 { data = <string>, pos = <0-based offset or nil> } (pos
--                 nil = Perl's undef pos); `/g` matches that carry on at
--                 pos() are `matches` calls taking and returning the
--                 0-based end offset.
--               - Charset.Recompose keys its tables by number, so the \uN
--                 code point is numified (num) before it is passed on.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local substr, length, tr, chr, hex = perl.substr, perl.length, perl.tr, perl.chr, perl.hex
local matches, matchesDyn, isMatch, subst, eachMatch = perl.matches, perl.matchesDyn, perl.isMatch, perl.subst, perl.eachMatch
local perlTruthy, num, str = perl.truthy, perl.num, perl.str
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable

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

-- RTF tags (ref 1)
RTF.Main = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        This table lists standard tags of the RTF information group, but ExifTool
        will also extract any non-standard tags found in this group.  As well,
        ExifTool will extract any custom properties that are found.  See
        L<http://www.microsoft.com/en-ca/download/details.aspx?id=10725> for the
        specification.
    ]],
    title    = { },
    subject  = { },
    author   = { Groups = { [2] = 'Author' } },
    manager  = { },
    company  = { },
    copyright= { Groups = { [2] = 'Author' } }, -- (written by Apple TextEdit)
    operator = { Name = 'LastModifiedBy' },
    category = { },
    keywords = { },
    comment  = { },
    doccomm  = { Name = 'Comments' },
    hlinkbase= { Name = 'HyperlinkBase' },
    creatim  = {
        Name = 'CreateDate',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    revtim   = {
        Name = 'ModifyDate',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    printim  = {
        Name = 'LastPrinted',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    buptim   = {
        Name = 'BackupTime',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    edmins   = {
        Name = 'TotalEditTime', -- in minutes
        PrintConv = function(_self, val) return ExifTool.ConvertTimeSpan(val, 60) end,
    },
    nofpages = { Name = 'Pages' },
    nofwords = { Name = 'Words' },
    nofchars = { Name = 'Characters' },
    nofcharsws={
        Name = 'CharactersWithSpaces',
        Notes = [[
            according to the 2007 Microsoft RTF specification this is clearly the number
            of characters NOT including spaces, but Microsoft Word writes this as the
            number WITH spaces, so ExifTool names this tag according to the de facto
            standard
        ]],
    },
    id       = { Name = 'InternalIDNumber' },
    version  = { Name = 'RevisionNumber' },
    vern     = { Name = 'InternalVersionNumber' },
}

-- lookup for user-defined properties
-- (none are pre-defined and this table doesn't appear in the docs)
RTF.UserProps = {
    GROUPS = { [2] = 'Document' },
}

--------------------------------------------------------------------------------
-- Read to nested closing curly bracket "}"
-- Inputs: 0) data ref, 1) optional RAF ref to read more data if available
-- Returns: text inside brackets, or undef on error
-- Notes: On entry the current position in the data must be set to immediately
--        after the command that opens the bracket.  On return the current
--        position is immediately following the closing brace if the return
--        value is defined.
local function ReadToNested(dataPt, raf)
    local pos = dataPt.pos
    local level = 1
    while true do
        -- look for the next bracket
        local c1, c2, en = matches(dataPt.data, [[(\\*)([{}])]], dataPt.pos)
        if not c1 then
            dataPt.pos = nil    -- (a failed m//g resets pos)
            -- must read some more data
            local p = length(dataPt.data)
            local n, buff
            if raf then n, buff = raf:Read(65536) end
            if not (raf and perlTruthy(n)) then break end
            dataPt.data = dataPt.data .. buff
            -- rewind position to include any leading backslashes
            while p ~= 0 and substr(dataPt.data, p - 1, 1) == '\\' do p = p - 1 end
            dataPt.pos = p -- set position to continue search
            goto continue
        end
        dataPt.pos = en
        -- bracket is escaped if preceded by an odd number of backslashes
        if perlTruthy(c1) and (length(c1) & 0x01) ~= 0 then goto continue end
        if c2 == '{' then level = level + 1 goto continue end
        level = level - 1
        if level > 0 then goto continue end
        do return substr(dataPt.data, pos, dataPt.pos - pos - 1) end
        ::continue::
    end
    return nil
end

--------------------------------------------------------------------------------
-- Unescape RTF escape sequences
-- Inputs: 0) ExifTool ref, 1) RTF text, 2) RTF character set (for hex characters)
-- Returns: Unescaped text (in current ExifTool Charset)
function RTF.UnescapeRTF(et, val, charset)

    -- return now unless we have a control sequence
    if not isMatch(val, [[\\]]) then
        val = tr(val, '\n\r', '', 'd') -- ignore CR's and LF's
        return val
    end
    -- CR/LF is significant if it terminates a control sequence (so change these to a space)
    -- (was $val =~ s/(^|[^\\])((?:\\\\)*)(\\[a-zA-Z]+(?:-?\d+)?)[\n\r]/$1$2$3 /g;)
    -- (upstream `s/\\(?:([a-zA-Z]+(?:-?\d+)?)[\n\r]|(.))/'\\'.($1 ? "$1 " : $2)/sge`;
    --  one mandatory group here, so no unset capture reaches the function:
    --  more than one character is the control word with its CR/LF)
    val = subst(val, [[(?s)\\((?:[a-zA-Z]+(?:-?\d+)?)[\n\r]|.)]], function(c) return '\\' .. (length(c) > 1 and substr(c, 0, -1) .. ' ' or c) end, 'g')
    -- protect the newline control sequence by converting to a \par command
    -- (was $val =~ s/(^|[^\\])((?:\\\\)*)(\\[\n\r])/$1$2\\par /g;)
    -- (upstream `s/(\\[\n\r])|(\\.)/$2 || '\\par '/sge`, with one group)
    val = subst(val, [[(?s)(\\.)]], function(c) return isMatch(c, [[^\\[\n\r]$]]) and '\\par ' or c end, 'g')
    -- all other CR/LF's are ignored (so delete them)
    val = tr(val, '\n\r', '', 'd')

    local rtnVal = ''
    local len = length(val)
    local skip = 1   -- default Unicode skip count
    local p0 = 0
    local pos        -- (pos($val))

    while true do
        -- find next backslash
        local m, en = matches(val, [[\\]], pos)
        pos = m and en or nil
        local p1 = m and pos or len + 1
        -- add text up to start of this control sequence (or up to end)
        local n = p1 - p0 - 1
        if n > 0 then rtnVal = rtnVal .. substr(val, p0, n) end
        -- all done if at the end or if control sequence is empty
        if p1 >= len then break end
        -- look for an ASCII-letter control word or Unicode control
        local c1, c2, e2 = matches(val, [[\G([a-zA-Z]+)(-?\d+)? ?]], pos)
        pos = c1 and e2 or nil
        if c1 then
            -- interpret command if recognized
            if c1 == 'uc' then       -- \ucN
                skip = c2
            elseif c1 == 'u' then   -- \uN
                if num(c2, '<') < 0 then
                    et:Warn('Invalid Unicode character(s) in text')
                    rtnVal = rtnVal .. '?'
                else
                    local Charset = require('lexiftool.Charset')
                    rtnVal = rtnVal .. Charset.Recompose(et, { num(c2) })
                    if perlTruthy(skip) then
                        -- must skip the specified number of characters
                        -- (not simple because RTF control words count as a single character)
                        local m3, _, _, e3 = matchesDyn(val, [[\G([^\\]|\\([a-zA-Z]+)(-?\d+)? ?|\\'.{2}|\\.){]] .. str(skip) .. '}', pos)
                        if not m3 then break end
                        pos = e3
                    end
                end
            elseif rtfEntity[c1] then
                local Charset = require('lexiftool.Charset')
                rtnVal = rtnVal .. Charset.Recompose(et, { rtfEntity[c1] })
            end -- (else ignore the command)
        else
            local ch = substr(val, p1, 1)
            if ch == "'" then
                -- hex character code
                if p1 + 3 > len then break end
                local hex_ = substr(val, p1 + 1, 2)
                if isMatch(hex_, [[^[0-9a-fA-F]{2}$]]) then
                    require('lexiftool.Charset')
                    rtnVal = rtnVal .. et:Decode(chr(hex(hex_)), charset)
                end
                pos = p1 + 3    -- skip to after the hex code
            else
                -- assume a standard control symbol (\, {, }, etc)
                -- (note, this may not be valid for some uncommon
                --  control symbols like \~ for non-breaking space)
                rtnVal = rtnVal .. ch
                pos = p1 + 1    -- skip to after this character
            end
        end
        p0 = pos
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Read information in a RTF document
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid RTF file
function RTF.ProcessRTF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2, cs
    local n

    n, buff = raf:Read(64)
    if not (perlTruthy(n) and perlTruthy(raf:Seek(0,0))) then return 0 end
    if not isMatch(buff, [=[^[\n\r]*\{[\n\r]*\\rtf[^a-zA-Z]]=]) then return 0 end
    et:SetFileType()
--
-- determine the RTF character set
--
    local cpg = matches(buff, [[\\ansicpg(\d*)]])
    if cpg then
        cs = 'cp' .. cpg
    else
        local cst = matches(buff, [=[\\(ansi|mac|pc|pca)[^a-zA-Z]]=])
        if cst then
            local trans = {
                ansi = 'Latin',
                mac  = 'MacRoman',
                pc   = 'cp437',
                pca  = 'cp850',
            }
            cs = trans[cst]
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
    local tagTablePtr = GetTagTable(nil, 'lexiftool.RTF.Main')
    buff = nil
--
-- scan for \info group
--
    while true do
        n, buf2 = raf:Read(65536)
        if not perlTruthy(n) then break end
        if buff ~= nil then
            -- read more but leave some overlap for the match
            buff = { data = substr(buff.data, -16) .. buf2 }
        else
            buff = { data = buf2 }
        end
        local c1, en = matches(buff.data, [[[^\\]\{[\n\r]*\\info([^a-zA-Z])]])
        if not c1 then goto continue end
        buff.pos = en
        -- anything but a space is included in the contents
        if c1 ~= ' ' then buff.pos = buff.pos - 1 end
        do
            local info = ReadToNested(buff, raf)
            if info == nil then
                et:Warn('Unterminated information group')
                break
            end
            info = { data = info }
            -- process info commands (eg. "\author", "\*\copyright");
            while true do
                local _, c2, c3, e = matches(info.data, [[\{[\n\r]*(\\\*[\n\r]*)?\\([a-zA-Z]+)([^a-zA-Z])]], info.pos)
                if c2 == nil then info.pos = nil break end
                info.pos = e
                if c3 ~= ' ' then info.pos = info.pos - 1 end
                local tag = c2
                local val = ReadToNested(info)
                if val == nil then break end
                local tagInfo = tagTablePtr[tag]
                if tagInfo and tagInfo.Format and tagInfo.Format == 'date' then
                    -- parse RTF date commands
                    local idx = { yr=0,mo=1,dy=2,hr=3,min=4,sec=5 }
                    local t = { 0, 0, 0, 0, 0, 0 }  -- (0) x 6
                    for k, v in eachMatch(val, [[\\([a-z]+)(\d+)]]) do
                        if idx[k] ~= nil then
                            t[idx[k] + 1] = v
                        end
                    end
                    val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', table.unpack(t))
                else
                    -- unescape RTF string value
                    val = RTF.UnescapeRTF(et, val, charset)
                end
                -- create tagInfo for unknown tags
                if not tagInfo then
                    AddTagToTable(nil, tagTablePtr, tag, { Name = ucfirst(tag) })
                end
                et:HandleTag(tagTablePtr, tag, val)
            end
        end
        ::continue::
    end
    if buff == nil then return 1 end
--
-- scan for \userprops (but don't read more from file to find the start of this command)
--
    buff.pos = 0
    while true do -- luacheck: ignore 512
        local c1, en = matches(buff.data, [[[^\\]\{[\n\r]*\\\*[\n\r]*\\userprops([^a-zA-Z])]], buff.pos)
        if not c1 then buff.pos = nil break end
        buff.pos = en
        -- Note: The RTF spec places brackets around each propinfo structure,
        -- but Microsoft Word doesn't write it this way, so tolerate either.
        if c1 ~= ' ' then buff.pos = buff.pos - 1 end
        local props = ReadToNested(buff, raf)
        tagTablePtr = GetTagTable(nil, 'lexiftool.RTF.UserProps')
        if props == nil then
            et:Warn('Unterminated user properties')
            break
        end
        props = { data = props }
        -- process user properties
        local tag
        while true do
            local _, c2, c3, e = matches(props.data, [[\{[\n\r]*(\\\*[\n\r]*)?\\([a-zA-Z]+)([^a-zA-Z])]], props.pos)
            if c2 == nil then props.pos = nil break end
            props.pos = e
            if c3 ~= ' ' then props.pos = props.pos - 1 end
            local t = c2
            local val = ReadToNested(props)
            if val == nil then break end
            val = RTF.UnescapeRTF(et, val, charset)
            if t == 'propname' then
                tag = val
                goto next
            elseif t ~= 'staticval' or tag == nil then
                goto next   -- ignore \linkval and \proptype for now
            end
            tag = subst(tag, [[\s(.)]], function(c) return uc(c) end, 'g')    -- capitalize all words in tag name
            tag = tr(tag, '-_a-zA-Z0-9', '', 'dc') -- remove illegal characters
            if not perlTruthy(tag) then goto next end
            -- create tagInfo for unknown tags
            if not tagTablePtr[tag] then
                AddTagToTable(nil, tagTablePtr, tag, { Name = tag })
            end
            et:HandleTag(tagTablePtr, tag, val)
            ::next::
        end
        break   -- (didn't really want to loop)
    end
    return 1
end

return RTF
