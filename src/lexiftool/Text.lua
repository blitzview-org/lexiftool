--------------------------------------------------------------------------------
-- File:         lexiftool/Text.lua
-- Ported from:  lib/Image/ExifTool/Text.pm
--
-- Description:  Deduce characteristics of TXT and CSV files
--
-- Revisions:    2019-11-01 - P. Harvey Created
--               2020-02-13 - PH Added CSV file support
--
-- References:   1) https://github.com/file/file
--
-- Port notes:   ProcessTXT reads the test buffer from dirInfo.TestBuff as
--               upstream; Perl's `$/` (set to the detected newline sequence
--               for the line/word count) is the separator argument of
--               RandomAccess:ReadLine.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local length = perl.length
local matches, matchesDyn = perl.matches, perl.matchesDyn
local isMatch = perl.isMatch
local eachMatch, eachMatchDyn = perl.eachMatch, perl.eachMatchDyn
local findAllDyn = perl.findAllDyn
local tr = perl.tr
local truthy = perl.truthy

local Text = {}

-- Text tags
Text.Main = {
    VARS = { ID_FMT = 'none' },
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Document' },
    NOTES = [[
        Although basic text files contain no metadata, the following tags are
        determined from a simple analysis of the data in TXT and CSV files.
        Statistics are generated only for 8-bit encodings, but the FastScan (-fast)
        option may be used to limit processing to the first 64 KiB in which case
        some tags are not produced.  To avoid long processing delays, ExifTool will
        issue a minor warning and process only the first 64 KiB of any file larger
        than 20 MiB unless the IgnoreMinorErrors (-m) option is used.
    ]],
    MIMEEncoding = { Groups = { [2] = 'Other' } },
    Newlines = {
        PrintConv = {
            ['\r\n'] = 'Windows CRLF',
            ['\r'] = 'Macintosh CR',
            ['\n'] = 'Unix LF',
            [''] = '(none)',
        },
    },
    ByteOrderMark = { PrintConv = { [0] = 'No', [1] = 'Yes' } },
    LineCount = {},
    WordCount = {},
    Delimiter = { PrintConv = { [''] = '(none)', [','] = 'Comma', [';'] = 'Semicolon', ['\t'] = 'Tab' } },
    Quoting = { PrintConv = { [''] = '(none)', ['"'] = 'Double quotes', ["'"] = 'Single quotes' } },
    RowCount = {},
    ColumnCount = {},
}

--------------------------------------------------------------------------------
-- Extract some stats from a text file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a text file
function Text.ProcessTXT(et, dirInfo)
    local dataPt = dirInfo.TestBuff
    local raf = dirInfo.RAF
    local fast = et:Options('FastScan') or 0
    local buff, enc, isBOM, isUTF8, n
    local nl = ''

    if length(dataPt) == 0 then return 0 end -- can't call it a text file if it has no text

    -- read more from the file if necessary
    if fast < 3 and length(dataPt) == ExifTool.testLen then
        n, buff = raf:Read(65536)
        if n == 0 then return 0 end
        dataPt = buff
    end
--
-- make our best guess at the character encoding (EBCDIC is not supported)
--
    if isMatch(dataPt, [=[([\0-\x06\x0e-\x1a\x1c-\x1f\x7f])]=]) then
        -- file contains weird control characters, could be multi-byte Unicode
        local m = matches(dataPt, [[^(\xff\xfe\0\0|\0\0\xfe\xff)]])
        local m2 = not m and matches(dataPt, [[^(\xff\xfe|\xfe\xff)]])
        if m then
            if m == "\xff\xfe\0\0" then
                enc = 'utf-32le'
                local c = matches(dataPt, [[(\r\0\0\0\n|\r|\n)\0\0\0]])
                if c then nl = c end
            else
                enc = 'utf-32be'
                local c = matches(dataPt, [[\0\0\0(\r\0\0\0\n|\r|\n)]])
                if c then nl = c end
            end
        elseif m2 then
            if m2 == "\xff\xfe" then
                enc = 'utf-16le'
                local c = matches(dataPt, [[(\r\0\n|\r|\n)\0]])
                if c then nl = c end
            else
                enc = 'utf-16be'
                local c = matches(dataPt, [[\0(\r\0\n|\r|\n)]])
                if c then nl = c end
            end
        else
            return 0        -- probably not a text file
        end
        nl = tr(nl, '\0', '', 'd') -- remove nulls from newline sequence
        isBOM = 1           -- (we don't recognize UTF-16/UTF-32 without one)
    else
        isUTF8 = ExifTool.IsUTF8(dataPt, 1)
        if isUTF8 == 0 then
            enc = 'us-ascii'
        elseif isUTF8 > 0 then
            enc = 'utf-8'
            isBOM = (isMatch(dataPt, [[^\xef\xbb\xbf]]) and 1 or 0)
        elseif not isMatch(dataPt, [=[[\x80-\x9f]]=]) then
            enc = 'iso-8859-1'
        else
            enc = 'unknown-8bit'
        end
        local c = matches(dataPt, [[(\r\n|\r|\n)]])
        if c then nl = c end
    end

    local tagTablePtr = et:GetTagTable('lexiftool.Text.Main')

    et:SetFileType()
    et:HandleTag(tagTablePtr, 'MIMEEncoding', enc)

    if fast == 3 or not raf:Seek(0, 0) then return 1 end

    if isBOM ~= nil then et:HandleTag(tagTablePtr, 'ByteOrderMark', isBOM) end
    et:HandleTag(tagTablePtr, 'Newlines', nl)

    if truthy(fast) or isUTF8 == nil then return 1 end
--
-- generate stats for CSV files
--
    if et.FileType == 'CSV' then
        local delim, quot, ncols
        local nrows = 0
        while true do
            n, buff = raf:ReadLine()
            if n == 0 then break end
            if delim == nil then
                local count = { [','] = 0, [';'] = 0, ["\t"] = 0 }
                for m in eachMatch(buff, [=[[,;\t]]=]) do count[m] = count[m] + 1 end
                if count[','] > count[';'] and count[','] > count["\t"] then
                    delim = ','
                elseif count[';'] > count["\t"] then
                    delim = ';'
                elseif count["\t"] ~= 0 then
                    delim = "\t"
                else
                    delim = ''
                    ncols = 1
                end
                if not ncols then
                    -- account for delimiters in quotes (simplistically)
                    for _, q, field in eachMatchDyn(buff, '(?s)(^|' .. delim .. [=[)(["'])(.*?)\2(?=]=] .. delim .. '|$)') do
                        quot = q
                        count[delim] = count[delim] - #findAllDyn(field, delim)
                    end
                    ncols = count[delim] + 1
                end
            elseif not truthy(quot) then
                local _, q = matchesDyn(buff, '(?s)(^|' .. delim .. [=[)(["'])(.*?)\2(?=]=] .. delim .. '|$)')
                if q then quot = q end
            end
            nrows = nrows + 1
            if nrows == 1000 and truthy(et:Warn('Not counting rows past 1000', 2)) then
                nrows = nil
                break
            end
        end
        et:HandleTag(tagTablePtr, 'Delimiter', (truthy(delim) and delim or ''))
        et:HandleTag(tagTablePtr, 'Quoting', (truthy(quot) and quot or ''))
        et:HandleTag(tagTablePtr, 'ColumnCount', ncols)
        if truthy(nrows) then et:HandleTag(tagTablePtr, 'RowCount', nrows) end
        return 1
    end
    if et.VALUE.FileSize and et.VALUE.FileSize > 20000000 and
        truthy(et:Warn('Not counting lines/words in text file larger than 20 MB', 2))
    then
        return 1
    end
--
-- count lines/words and check encoding of the rest of the file
--
    local lines, words = 0, 0
    local RS = "\n"     -- (my $oldNL = $/)
    if nl ~= '' then RS = nl end
    while true do
        n, buff = raf:ReadLine(RS)
        if n == 0 then break end
        lines = lines + 1
        for _ in eachMatch(buff, [[\S+]]) do words = words + 1 end
        if nl == '' then
            local c = matches(buff, [[(\r\n|\r|\n)$]])
            if c then
                -- (the first line must have been longer than 64 kB)
                nl = c
                et.VALUE.Newlines = nl
            end
        end
        if raf:Tell() < 65536 then goto next_ end
        -- continue to check encoding after the first 64 kB
        if isUTF8 >= 0 then -- (if ascii or utf8)
            isUTF8 = ExifTool.IsUTF8(buff)
            if isUTF8 > 0 then
                enc = 'utf-8'
            elseif isUTF8 < 0 then
                enc = isMatch(buff, [=[[\x80-\x9f]]=]) and 'unknown-8bit' or 'iso-8859-1'
            end
        elseif enc == 'iso-8859-1' and isMatch(buff, [=[[\x80-\x9f]]=]) then
            enc = 'unknown-8bit'
        end
        ::next_::
    end
    -- ($$et{VALUE}{MIMEEncoding} may be undef if it was ignored)
    if et.VALUE.MIMEEncoding ~= nil and et.VALUE.MIMEEncoding ~= enc then
        et.VALUE.MIMEEncoding = enc
        et:VPrint(0, '  MIMEEncoding [override] = ' .. enc .. "\n")
    end
    et:HandleTag(tagTablePtr, 'LineCount', lines)
    et:HandleTag(tagTablePtr, 'WordCount', words)
    return 1
end

Text.Main.PROCESS_PROC = Text.ProcessTXT

return Text
