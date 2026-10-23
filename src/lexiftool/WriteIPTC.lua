--------------------------------------------------------------------------------
-- File:         lexiftool/WriteIPTC.lua
-- Ported from:  lib/Image/ExifTool/WriteIPTC.pl
--
-- Description:  Write IPTC meta information
--
-- Revisions:    12/15/2004 - P. Harvey Created
--
-- Port notes:   All subs of WriteIPTC.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::IPTC package and
--               AUTOLOADs it on the first call of one of its subs; this port
--               makes it a module of its own, and IPTC.lua binds every sub at
--               its predeclaration position to a closure that loads this
--               file on first use (IPTC.WriteIPTC, IPTC.CheckIPTC, ... keep
--               working for all callers, the tables' WRITE_PROC/CHECK_PROC
--               and conversions included).
--
--               Scalar references: CheckIPTC is a CHECK_PROC and follows the
--               port's convention for those (value in; error and the
--               possibly changed value out), its `$$valPtr` is the local
--               valPtr.  FormatIPTC updates the value and the character set
--               through two refs upstream; here both come back as return
--               values (valPtr, xlatPtr), as IPTC.lua's TranslateCodedString
--               does.  Perl `warn` is perl.warn, so the conversion's eval
--               warning reaches ConvInv as upstream's $SIG{__WARN__} does.
--               The MD5 digests use ExifTool.md5 (Digest::MD5).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local substr = perl.substr
local carray = require('carray')
local length = perl.length
local matches, isMatch = perl.matches, perl.isMatch
local subst = perl.subst
local split = perl.split
local tr = perl.tr
local lc, uc = perl.lc, perl.uc
local chr, ord = perl.chr, perl.ord
local pack, unpack = perl.pack, perl.unpack
local sprintf = perl.sprintf
local num = perl.num
local truthy = perl.truthy
local warn = perl.warn

local IPTC = require('lexiftool.IPTC')  -- (upstream `package Image::ExifTool::IPTC`)
local WriteIPTC = {}

-- (IPTC.pm subs upstream calls by their bare names)
local HandleCodedCharset, TranslateCodedString = IPTC.HandleCodedCharset, IPTC.TranslateCodedString
local IsStandardIPTC = IPTC.IsStandardIPTC

-- mandatory IPTC tags for each record
local mandatory = {
    [1] = {
        [0] = 4,        -- EnvelopeRecordVersion
    },
    [2] = {
        [0] = 4,        -- ApplicationRecordVersion
    },
    [3] = {
        [0] = 4,        -- NewsPhotoVersion
    },
}

-- manufacturer strings for IPTCPictureNumber
local manufacturer = {
    [1] = 'Associated Press, USA',
    [2] = 'Eastman Kodak Co, USA',
    [3] = 'Hasselblad Electronic Imaging, Sweden',
    [4] = 'Tecnavia SA, Switzerland',
    [5] = 'Nikon Corporation, Japan',
    [6] = 'Coatsworth Communications Inc, Canada',
    [7] = 'Agence France Presse, France',
    [8] = 'T/One Inc, USA',
    [9] = 'Associated Newspapers, UK',
    [10] = 'Reuters London',
    [11] = 'Sandia Imaging Systems Inc, USA',
    [12] = 'Visualize, Spain',
}

local iptcCharsetInv = { ['UTF8'] = "\x1b%G", ['UTF-8'] = "\x1b%G" }

-- ISO 2022 Character Coding Notes
-- -------------------------------
-- Character set designation: (0x1b I F, or 0x1b I I F)
-- Initial character 0x1b (ESC)
-- Intermediate character I:
--   0x28 ('(') - G0, 94 chars
--   0x29 (')') - G1, 94 chars
--   0x2a ('*') - G2, 94 chars
--   0x2b ('+') - G3, 94 chars
--   0x2c (',') - G1, 96 chars
--   0x2d ('-') - G2, 96 chars
--   0x2e ('.') - G3, 96 chars
--   0x24 I ('$I') - multiple byte graphic sets (I from above)
--   I 0x20 ('I ') - dynamically redefinable character sets
-- Final character:
--   0x30 - 0x3f = private character set
--   0x40 - 0x7f = standardized character set
-- Character set invocation:
--   G0 : SI = 0x15
--   G1 : SO = 0x14,             LS1R = 0x1b 0x7e ('~')
--   G2 : LS2 = 0x1b 0x6e ('n'), LS2R = 0x1b 0x7d ('}')
--   G3 : LS3 = 0x1b 0x6f ('o'), LS3R = 0x1b 0x7c ('|')
--   (the locking shift "R" codes shift into 0x80-0xff space)
-- Single character invocation:
--   G2 : SS2 = 0x1b 0x8e (or 0x4e in 7-bit)
--   G3 : SS3 = 0x1b 0x8f (or 0x4f in 7-bit)
-- Control chars (designated and invoked)
--   C0 : 0x1b 0x21 F (0x21 = '!')
--   C1 : 0x1b 0x22 F (0x22 = '"')
-- Complete codes (control+graphics, designated and invoked)
--   0x1b 0x25 F   (0x25 = '%')
--   0x1b 0x25 I F
--   0x1b 0x25 0x47 ("\x1b%G") - UTF-8
--   0x1b 0x25 0x40 ("\x1b%@") - return to ISO 2022
-- -------------------------------

--------------------------------------------------------------------------------
-- Inverse print conversion for CodedCharacterSet
-- Inputs: 0) value
local function PrintInvCodedCharset(val)
    local code = iptcCharsetInv[uc(val)]
    if not code then
        code = val
        if isMatch(code, [[(?i)ESC *]]) then  -- translate ESC chars
            code = subst(code, [[(?i)ESC *]], "\x1b", 'g')
            code = subst(code, [[, \x1b]], "\x1b", 'g')   -- remove comma separators
            code = tr(code, ' ', '', 'd')           -- remove spaces
        else
            warn("Bad syntax (use 'UTF8' or 'ESC X Y[, ...]')\n")
        end
    end
    return code
end

--------------------------------------------------------------------------------
-- validate raw values for writing
-- Inputs: 0) ExifTool object ref, 1) tagInfo hash ref, 2) raw value ref
-- Returns: error string or undef (and possibly changes value) on success
-- (Lua: the value itself in, the error and the possibly changed value out --
--  the CHECK_PROC convention)
local function CheckIPTC(et, tagInfo, valPtr)
    local format = tagInfo.Format or tagInfo.Table.FORMAT or ''
    local bits = matches(format, [[^int(\d+)]])
    local fmt, minlen, maxlen = matches(format, [[^(string|digits|undef)\[?(\d+),?(\d*)\]?$]])
    if bits then
        local bytes = perl.int((num(bits) or 0) / 8)
        if bytes ~= 1 and bytes ~= 2 and bytes ~= 4 then
            return "Can't write " .. bytes .. '-byte integer'
        end
        local val = valPtr
        if not ExifTool.IsInt(val) then
            if not ExifTool.IsHex(val) then return 'Not an integer' end
            val = perl.hex(val)
            valPtr = val
        end
        val = perl.int(val)
        local n = 0
        while n < bytes do val = val >> 8; n = n + 1 end
        if val ~= 0 then return 'Value too large for ' .. bytes .. '-byte format' end
    elseif fmt then
        local len = length(valPtr)
        if fmt == 'digits' then
            if not isMatch(valPtr, [[^\d*$]]) then return 'Non-numeric characters in value' end
            if len < num(minlen) and len ~= 0 then
                -- left pad with zeros if necessary
                valPtr = string.rep('0', num(minlen) - len) .. valPtr
                len = num(minlen)
            end
        end
        if minlen ~= nil and fmt ~= 'string' then -- (must truncate strings later, after recoding)
            if not truthy(maxlen) then maxlen = minlen end
            if len < num(minlen) then
                if not truthy(et.OPTIONS.IgnoreMinorErrors) then
                    return '[Minor] String too short (minlen is ' .. minlen .. ')'
                end
                et.CHECK_WARN = 'String too short for IPTC:' .. tagInfo.Name .. ' (written anyway)'
            elseif len > num(maxlen) and not truthy(et.OPTIONS.IgnoreMinorErrors) then
                et.CHECK_WARN = '[Minor] IPTC:' .. tagInfo.Name .. ' exceeds length limit (truncated)'
                valPtr = substr(valPtr, 0, num(maxlen))
            end
        end
    else
        return 'Bad IPTC Format (' .. format .. ')'
    end
    return nil, valPtr
end

--------------------------------------------------------------------------------
-- format IPTC data for writing
-- Inputs: 0) ExifTool object ref, 1) tagInfo pointer,
--         2) value reference (changed if necessary),
--         3) reference to character set for translation (changed if necessary)
--         4) record number, 5) flag set to read value (instead of write)
-- (Lua: the value and the character set in, both -- possibly changed -- out)
local function FormatIPTC(et, tagInfo, valPtr, xlatPtr, rec, read)
    local format = tagInfo.Format or tagInfo.Table.FORMAT
    if not truthy(format) then return valPtr, xlatPtr end
    local bits = matches(format, [[^int(\d+)]])
    if bits then
        if truthy(read) then
            local len = length(valPtr)
            if len <= 8 then    -- limit integer conversion to 8 bytes long
                local val = 0
                local i = 0
                while i < len do
                    val = val * 256 + ord(substr(valPtr, i, 1))
                    i = i + 1
                end
                valPtr = val
            end
        else
            local len = perl.int((num(bits) or 0) / 8)
            if len == 1 then        -- 1 byte
                valPtr = chr(perl.int(valPtr) & 0xff)
            elseif len == 2 then    -- 2-byte integer
                valPtr = pack('n', valPtr)
            else                    -- 4-byte integer
                valPtr = pack('N', valPtr)
            end
        end
    elseif isMatch(format, [[^string]]) then
        if rec == 1 then
            if tagInfo.Name == 'CodedCharacterSet' then
                xlatPtr = HandleCodedCharset(et, valPtr)
            end
        elseif truthy(xlatPtr) and rec < 7 and isMatch(valPtr, [=[[\x80-\xff]]=]) then
            valPtr, xlatPtr = TranslateCodedString(et, valPtr, xlatPtr, read)
        end
        -- must check length now (after any string recoding)
        local minlen, maxlen = matches(format, [=[^string\[(\d+),?(\d*)\]$]=])
        if not truthy(read) and minlen then
            local len = length(valPtr)
            if not truthy(maxlen) then maxlen = minlen end
            minlen, maxlen = num(minlen), num(maxlen)
            if len < minlen then
                if truthy(et:Warn('String too short for IPTC:' .. tagInfo.Name .. ' (padded)', 2)) then
                    valPtr = valPtr .. string.rep(' ', minlen - len)
                end
            elseif len > maxlen then
                if truthy(et:Warn('IPTC:' .. tagInfo.Name .. ' exceeds length limit (truncated)', 2)) then
                    valPtr = substr(valPtr, 0, maxlen)
                    -- make sure UTF-8 is still valid
                    if (truthy(xlatPtr) and xlatPtr or et:Options('Charset')) == 'UTF8' then
                        local _
                        _, valPtr = require('lexiftool.XMP').FixUTF8(valPtr, '.')
                    end
                end
            end
        end
    end
    return valPtr, xlatPtr
end

--------------------------------------------------------------------------------
-- generate IPTC-format date
-- Inputs: 0) EXIF-format date string (YYYY:mm:dd) or date/time string
-- Returns: IPTC-format date string (YYYYmmdd), or undef and issue warning on error
local function IptcDate(val)
    if isMatch(val, [[(?s)^.*?(\d{4})[-:/.]?(\d{2})[-:/.]?(\d{2}).*]]) then
        val = subst(val, [[(?s)^.*?(\d{4})[-:/.]?(\d{2})[-:/.]?(\d{2}).*]], '$1$2$3')
    else
        warn("Invalid date format (use YYYY:mm:dd)\n")
        val = nil
    end
    return val
end

--------------------------------------------------------------------------------
-- generate IPTC-format time
-- Inputs: 0) EXIF-format time string (HH:MM:SS[+/-HH:MM]) or date/time string
-- Returns: IPTC-format time string (HHMMSS+HHMM), or undef and issue warning on error
local function IptcTime(val)
    local date, h, c1, m, c2, s, tz = matches(val, [[(?s)(.*?)\b(\d{1,2})(:?)(\d{2})(:?)(\d{2})(\S*)\s*$]])
    if date and (truthy(c1) or not truthy(c2)) then
        val = sprintf('%.2d%.2d%.2d', h, m, s)
        local tzh, tzm = matches(tz, [[([+-]\d{1,2}):?(\d{2})]])
        if tzh then
            tz = sprintf('%+.2d%.2d', tzh, tzm)
        elseif isMatch(tz, [[(?i)Z]]) then
            tz = '+0000'  -- UTC
        else
            -- use local system timezone by default
            local tm, time
            local y, mo, d = matches(date, [[^(\d{4}):(\d{2}):(\d{2})\s*$]])
            if truthy(date) and y then
                -- we were given a date too, so determine the local timezone
                -- offset at the specified date/time
                local dl = { num(d), num(mo) - 1, num(y) }
                local hh, mm, ss = matches(val, [[(\d{2})(\d{2})(\d{2})]])
                tm = { num(ss), num(mm), num(hh), dl[1], dl[2], dl[3] }
                time = ExifTool.TimeLocal(table.unpack(tm))
            else
                -- it is difficult to get the proper local timezone offset for this
                -- time because the date tag is written separately.  (The offset may be
                -- different on a different date due to daylight savings time.)  In this
                -- case the best we can do easily is to use the current timezone offset.
                time = perl.time()
                tm = perl.localtime(time)
            end
            tz = tr(ExifTool.TimeZoneString(tm, time), ':', '', 'd')
        end
        val = val .. tz
    else
        warn("Invalid time format (use HH:MM:SS[+/-HH:MM])\n")
        val = nil     -- time format error
    end
    return val
end

--------------------------------------------------------------------------------
-- Inverse print conversion for IPTC date or time value
-- Inputs: 0) ExifTool ref, 1) IPTC date or 'now'
-- Returns: IPTC date
local function InverseDateOrTime(et, val)
    if lc(val) == 'now' then return et:TimeNow() end
    return val
end

--------------------------------------------------------------------------------
-- Convert picture number
-- Inputs: 0) value
-- Returns: Converted value
local function ConvertPictureNumber(val)
    if val == string.rep("\0", 16) then
        val = 'Unknown'
    elseif length(val) >= 16 then
        local vals = { unpack('nNA8n', val) }
        val = vals[1]
        local manu = manufacturer[val]
        if manu then val = val .. ' (' .. manu .. ')' end
        val = val .. ', equip ' .. vals[2]
        vals[3] = subst(vals[3], [[(\d{4})(\d{2})(\d{2})]], '$1:$2:$3')
        val = val .. ', ' .. vals[3] .. ', no. ' .. vals[4]
    else
        val = '<format error>'
    end
    return val
end

--------------------------------------------------------------------------------
-- Inverse picture number conversion
-- Inputs: 0) value
-- Returns: Converted value (or undef on error)
local function InvConvertPictureNumber(val)
    val = subst(val, [[\(.*\)]], '', 'g')    -- remove manufacturer description
    val = tr(val, ':', '', 'd')             -- remove date separators
    val = tr(val, '0-9', ' ', 'c')          -- turn remaining non-numbers to spaces
    local vals = split(' ', val)
    if #vals >= 4 then
        val = pack('nNA8n', table.unpack(vals))
    elseif isMatch(val, [[(?i)unknown]]) then
        val = string.rep("\0", 16)
    else
        val = nil
    end
    return val
end

--------------------------------------------------------------------------------
-- Write IPTC data record
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: IPTC data block (may be empty if no IPTC data)
-- Notes: Increments ExifTool CHANGED flag for each tag changed
-- luacheck: push ignore 421 431
local function DoWriteIPTC(et, dirInfo, tagTablePtr)
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout  -- (unset option: upstream's default \*STDOUT)

    -- avoid editing IPTC directory unless necessary:
    -- - improves speed
    -- - avoids changing current MD5 digest unnecessarily
    -- - avoids adding mandatory tags unless some other IPTC is changed
    if not (et.EDIT_DIRS[dirInfo.DirName] ~= nil or
        -- standard IPTC tags in other locations should be edited too (eg. AFCP_IPTC)
        (tagTablePtr == IPTC.Main and et.EDIT_DIRS.IPTC ~= nil)) then return nil end
    local dataPt = dirInfo.DataPt
    if not dataPt then
        local emptyData = ''
        dataPt = emptyData
    end
    local start = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen
    local tagInfo, iptcInfo, tag = nil, {}, nil

    -- start by assuming default IPTC encoding
    local xlat = et:Options('CharsetIPTC')
    if xlat == et:Options('Charset') then xlat = nil end

    -- make sure our dataLen is defined (note: allow zero length directory)
    if dirLen == nil then
        local dataLen = dirInfo.DataLen
        if dataLen == nil then dataLen = length(dataPt) end
        dirLen = dataLen - start
    end
    -- quick check for improperly byte-swapped IPTC
    if dirLen >= 4 and substr(dataPt, start, 1) ~= "\x1c" and
                       substr(dataPt, start + 3, 1) == "\x1c"
    then
        et:Warn('IPTC data was improperly byte-swapped')
        local newData = pack('N*', unpack('V*', substr(dataPt, start, dirLen) .. "\0\0\0"))
        dataPt = newData
        start = 0
        -- NOTE: MUST NOT access $dirInfo DataPt, DirStart or DataLen after this!
    end
    -- generate lookup so we can find the record numbers
    local recordNum = {}
    for _, t in ipairs(ExifTool.TagTableKeys(tagTablePtr)) do
        tag = t
        tagInfo = tagTablePtr[tag]
        if tagInfo.SubDirectory then
            local tbl = tagInfo.SubDirectory.TagTable
            if tbl then
                local subTablePtr = ExifTool.GetTagTable(nil, tbl)
                recordNum[subTablePtr] = tag
            end
        end
    end

    -- loop through new values and accumulate all IPTC information
    -- into lists based on their IPTC record type
    for _, ti in ipairs(Writer.GetNewTagInfoList(et)) do
        tagInfo = ti
        local tbl = tagInfo.Table
        local record = recordNum[tbl]
        -- ignore tags we aren't writing to this directory
        if record ~= nil then
            if iptcInfo[record] == nil then iptcInfo[record] = {} end
            table.insert(iptcInfo[record], tagInfo)
        end
    end

    -- get sorted list of records used.  Might as well be organized and
    -- write our records in order of record number first, then tag number
    local recordList = {}
    for r in pairs(iptcInfo) do recordList[#recordList + 1] = r end
    recordList = perl.sort(recordList, function(a, b) return a - b end)
    local set = {}
    for _, record in ipairs(recordList) do
        -- sort tagInfo lists by tagID
        iptcInfo[record] = perl.sort(iptcInfo[record], function(a, b) return a.TagID - b.TagID end)
        -- build hash of all tagIDs to set
        for _, ti in ipairs(iptcInfo[record]) do
            tagInfo = ti
            set[record] = set[record] or {}
            set[record][tagInfo.TagID] = tagInfo
        end
    end
    -- run through the old IPTC data, inserting our records in
    -- sequence and deleting existing records where necessary
    -- (the IPTC specification states that records must occur in
    -- numerical order, but tags within records need not be ordered)
    local pos = start
    local tail = pos        -- old data written up to this point
    local dirEnd = start + dirLen
    local newData = carray.new('char')
    local lastRec = -1
    local lastRecPos = 0
    local allMandatory = 0
    local foundRec = {}     -- found flags: 0x01-existed before, 0x02-deleted, 0x04-created
    local addNow
    -- (Perl autovivifies $foundRec{$rec}->{...}; the port creates the
    --  record's hash on first access)
    local function foundRecOf(rec)
        if foundRec[rec] == nil then foundRec[rec] = {} end
        return foundRec[rec]
    end

    while true do
        -- get next IPTC record from input directory
        local id, rec, len, valuePtr
        if pos + 5 <= dirEnd then
            local buff = substr(dataPt, pos, 5)
            id, rec, tag, len = unpack('CCCn', buff)
            if id == 0x1c then
                if rec < lastRec then
                    if rec == 0 then
                        if truthy(et:Warn('IPTC record 0 encountered, subsequent records ignored', 2)) then return nil end
                        rec = nil
                        pos = dirEnd
                        len = 0
                    else
                        if truthy(et:Warn("IPTC doesn't conform to spec: Records out of sequence", 2)) then return nil end
                    end
                end
                -- handle extended IPTC entry if necessary
                pos = pos + 5      -- step to after field header
                if len & 0x8000 ~= 0 then
                    local n = len & 0x7fff  -- get num bytes in length field
                    if pos + n <= dirEnd and n <= 8 then
                        -- determine length (a big-endian, variable sized int)
                        len = 0
                        while n ~= 0 do
                            len = len * 256 + ord(substr(dataPt, pos, 1))
                            pos = pos + 1
                            n = n - 1
                        end
                    else
                        len = dirEnd     -- invalid length
                    end
                end
                valuePtr = pos
                pos = pos + len   -- step $pos to next entry
                -- make sure we don't go past the end of data
                -- (this can only happen if original data is bad)
                if pos > dirEnd then pos = dirEnd end
            else
                rec = nil
            end
        end
        -- write out all our records that come before this one
        local writeRec = (rec == nil or rec ~= lastRec)
        if writeRec or addNow then
            while true do
                local newRec = recordList[1]
                if addNow then
                    tagInfo = addNow
                elseif newRec == nil or newRec ~= lastRec then
                    -- handle mandatory tags in last record unless it was empty
                    if length(newData) > lastRecPos then
                        if allMandatory > 1 then
                            -- entire lastRec contained mandatory tags, and at least one tag
                            -- was deleted, so delete entire record unless we specifically
                            -- added a mandatory tag
                            local num = 0
                            for _, code in pairs(foundRecOf(lastRec)) do
                                if code & 0x04 ~= 0 then num = 0 break end
                                if (code & 0x03) == 0x01 then num = num + 1 end
                            end
                            if num ~= 0 then
                                newData = carray.new('char'):append(substr(newData, 0, lastRecPos))
                                if perl.num(verbose) > 1 then out:write('    - ' .. num .. " mandatory tags\n") end
                            end
                        elseif mandatory[lastRec] and
                               tagTablePtr == IPTC.Main
                        then
                            -- add required mandatory tags
                            local mandatory = mandatory[lastRec]
                            local subTablePtr
                            local mandTags = {}
                            for k in pairs(mandatory) do mandTags[#mandTags + 1] = k end
                            for _, mandTag in ipairs(perl.sort(mandTags, function(a, b) return a - b end)) do
                                if truthy(foundRecOf(lastRec)[mandTag]) then goto nextMand end
                                if not subTablePtr then
                                    tagInfo = tagTablePtr[lastRec]
                                    if not (tagInfo and tagInfo.SubDirectory) then
                                        warn("WriteIPTC: Internal error 1\n")
                                        goto nextMand
                                    end
                                    if not tagInfo.SubDirectory.TagTable then goto nextMand end
                                    subTablePtr = ExifTool.GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                                end
                                tagInfo = subTablePtr[mandTag]
                                if not tagInfo then
                                    warn("WriteIPTC: Internal error 2\n")
                                    goto nextMand
                                end
                                do
                                    local value = mandatory[mandTag]
                                    et:VerboseValue('+ IPTC:' .. tagInfo.Name, value, ' (mandatory)')
                                    -- apply necessary format conversions
                                    value, xlat = FormatIPTC(et, tagInfo, value, xlat, lastRec)
                                    len = length(value) -- luacheck: ignore 311
                                    -- generate our new entry
                                    local entry = pack('CCCn', 0x1c, lastRec, mandTag, length(value))
                                    newData:append(entry .. value)    -- add entry to new IPTC data
                                    -- (don't mark as changed if just mandatory tags changed)
                                    -- ++$$et{CHANGED};
                                end
                                ::nextMand::
                            end
                        end
                    end
                    if newRec == nil then break end
                    lastRec = newRec
                    lastRecPos = length(newData)
                    allMandatory = 1
                end
                if not addNow then
                    -- compare current entry with entry next in line to write out
                    -- (write out our tags in numerical order even though
                    -- this isn't required by the IPTC spec)
                    if rec ~= nil and rec <= newRec then break end
                    tagInfo = iptcInfo[newRec][1]
                end
                local newTag = tagInfo.TagID
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                -- only add new values if...
                local doSet, values
                local found = foundRecOf(newRec)[newTag] or 0
                if found & 0x02 ~= 0 then
                    -- ...tag existed before and was deleted (unless we already added it)
                    if found & 0x04 == 0 then doSet = 1 end
                elseif truthy(tagInfo.List) then
                    -- ...tag is List and it existed before or we are creating it
                    if found ~= 0 then
                        if not truthy(nvHash.CreateOnly) then doSet = 1 end
                    elseif truthy(nvHash.IsCreating) then
                        doSet = 1
                    end
                else
                    -- ...tag didn't exist before and we are creating it
                    if found == 0 and truthy(nvHash.IsCreating) then doSet = 1 end
                end
                if doSet then
                    values = et:GetNewValue(nvHash, true) or {}
                    if #values > 0 then foundRecOf(newRec)[newTag] = found | 0x04 end
                    -- write tags for each value in list
                    for _, v in ipairs(values) do
                        local value = v
                        et:VerboseValue('+ ' .. perl.str(dirInfo.DirName) .. ':' .. tagInfo.Name, value)
                        -- reset allMandatory flag if a non-mandatory tag is written
                        if allMandatory ~= 0 then
                            local mandatory = mandatory[newRec]
                            if not (mandatory and mandatory[newTag]) then allMandatory = 0 end
                        end
                        -- apply necessary format conversions
                        value, xlat = FormatIPTC(et, tagInfo, value, xlat, newRec)
                        -- (note: IPTC string values are NOT null terminated)
                        len = length(value)
                        -- generate our new entry
                        local entry = pack('CCC', 0x1c, newRec, newTag)
                        if len <= 0x7fff then
                            entry = entry .. pack('n', len)
                        else
                            -- extended dataset tag
                            entry = entry .. pack('nN', 0x8004, len)
                        end
                        newData:append(entry .. value)    -- add entry to new IPTC data
                        et.CHANGED = (et.CHANGED or 0) + 1
                    end
                end
                -- continue on with regular programming if done adding tag now
                if addNow then
                    addNow = nil
                    if writeRec then goto nextWrite end
                    break
                end
                -- remove this tagID from the sorted write list
                table.remove(iptcInfo[newRec], 1)
                if #iptcInfo[newRec] == 0 then table.remove(recordList, 1) end
                ::nextWrite::
            end
            if writeRec then
                -- all done if no more records to write
                if rec == nil then break end
                -- update last record variables
                lastRec = rec
                lastRecPos = length(newData)
                allMandatory = 1
            end
        end
        -- set flag indicating we found this tag
        foundRecOf(rec)[tag] = foundRecOf(rec)[tag] or 0x01
        -- write out this record unless we are setting it with a new value
        tagInfo = set[rec] and set[rec][tag]
        if tagInfo then
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            len = pos - valuePtr
            local val = substr(dataPt, valuePtr, len)
            -- remove null terminator if it exists (written by braindead software like Picasa 2.0)
            if tagInfo.Format and isMatch(tagInfo.Format, [[^string]]) then val = subst(val, [[\0+$]], '') end
            local oldXlat = xlat
            val, xlat = FormatIPTC(et, tagInfo, val, xlat, rec, 1)
            if truthy(Writer.IsOverwriting(et, nvHash, val)) then
                xlat = oldXlat   -- don't change translation (not writing this value)
                et:VerboseValue('- ' .. perl.str(dirInfo.DirName) .. ':' .. tagInfo.Name, val)
                et.CHANGED = (et.CHANGED or 0) + 1
                -- set deleted flag to indicate we found and deleted this tag
                foundRecOf(rec)[tag] = foundRecOf(rec)[tag] | 0x02
                -- increment allMandatory flag to indicate a tag was removed
                if allMandatory ~= 0 then allMandatory = allMandatory + 1 end
                -- write this tag now if overwriting an existing value
                if nvHash.Value and #nvHash.Value > 0 and #recordList > 0 and
                    recordList[1] == rec and foundRecOf(rec)[tag] & 0x04 == 0
                then
                    addNow = tagInfo
                end
                goto continue
            end
        elseif rec == 1 and tag == 90 then
            -- handle CodedCharacterSet tag
            local val = substr(dataPt, valuePtr, pos - valuePtr)
            xlat = HandleCodedCharset(et, val)
        end
        -- reset allMandatory flag if a non-mandatory tag is written
        if allMandatory ~= 0 then
            local mandatory = mandatory[rec]
            if not (mandatory and mandatory[tag]) then
                allMandatory = 0
            end
        end
        -- write out the record
        newData:append(substr(dataPt, tail, pos - tail))
        ::continue::
        tail = pos
    end
    -- make sure the rest of the data is zero
    if tail < dirEnd then
        local pad = substr(dataPt, tail, dirEnd - tail)
        if isMatch(pad, [=[[^\0]]=]) then
            if truthy(et:Warn('Unrecognized data in IPTC padding', 2)) then return nil end
        end
    end
    return newData:tostring()
end
-- luacheck: pop

--------------------------------------------------------------------------------
-- Write IPTC data record and calculate NewIPTCDigest
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: IPTC data block (may be empty if no IPTC data)
-- Notes: Increments ExifTool CHANGED flag for each tag changed
function WriteIPTC.WriteIPTC(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package

    local newData = DoWriteIPTC(et, dirInfo, tagTablePtr)

    -- calculate standard IPTC digests only if we are writing or deleting
    -- Photoshop:IPTCDigest with a value of 'new' or 'old'
    -- ($Image::ExifTool::Photoshop::iptcDigestInfo: defined once Photoshop.pm
    --  is loaded)
    local Photoshop = package.loaded['lexiftool.Photoshop']
    while Photoshop and Photoshop.iptcDigestInfo do -- luacheck: ignore 512
        local nvHash = et.NEW_VALUE and et.NEW_VALUE[Photoshop.iptcDigestInfo]
        if nvHash == nil then break end
        if not truthy(IsStandardIPTC(et:MetadataPath())) then break end
        local values = et:GetNewValue(nvHash, true) or {}
        if nvHash.DelValue then
            for _, v in ipairs(nvHash.DelValue) do values[#values + 1] = v end
        end
        local new, old = 0, 0
        for _, v in ipairs(values) do
            if isMatch(v, [[^new$]]) then new = new + 1 end
            if isMatch(v, [[^old$]]) then old = old + 1 end
        end
        if new == 0 and old == 0 then break end
        if not et:hasMD5() then
            et:Warn('Digest::MD5 must be installed to calculate IPTC digest')
            break
        end
        local dataPt
        if new ~= 0 then
            if newData ~= nil then
                dataPt = newData
            else
                dataPt = dirInfo.DataPt
                if truthy(dirInfo.DirStart) or length(dataPt) ~= dirInfo.DirLen then
                    local buff = substr(dataPt, dirInfo.DirStart, dirInfo.DirLen)
                    dataPt = buff
                end
            end
            -- set NewIPTCDigest data member unless IPTC is being deleted
            if length(dataPt) > 0 then et.NewIPTCDigest = et:md5(dataPt) end
        end
        if old ~= 0 then
            if new ~= 0 and newData == nil then
                et.OldIPTCDigest = et.NewIPTCDigest
            elseif dirInfo.DataPt then --(may be undef if creating new IPTC)
                dataPt = dirInfo.DataPt
                if truthy(dirInfo.DirStart) or length(dataPt) ~= dirInfo.DirLen then
                    local buff = substr(dataPt, dirInfo.DirStart, dirInfo.DirLen)
                    dataPt = buff
                end
                if length(dataPt) > 0 then et.OldIPTCDigest = et:md5(dataPt) end
            end
        end
        break
    end
    -- set changed if ForceWrite tag was set to "IPTC"
    if newData ~= nil and length(newData) > 0 and et.FORCE_WRITE and truthy(et.FORCE_WRITE.IPTC) then
        et.CHANGED = (et.CHANGED or 0) + 1
    end
    return newData
end

-- (the subs above, for IPTC.lua's AUTOLOAD closures)
WriteIPTC.PrintInvCodedCharset = PrintInvCodedCharset
WriteIPTC.CheckIPTC = CheckIPTC
WriteIPTC.FormatIPTC = FormatIPTC
WriteIPTC.IptcDate = IptcDate
WriteIPTC.IptcTime = IptcTime
WriteIPTC.InverseDateOrTime = InverseDateOrTime
WriteIPTC.ConvertPictureNumber = ConvertPictureNumber
WriteIPTC.InvConvertPictureNumber = InvConvertPictureNumber
WriteIPTC.DoWriteIPTC = DoWriteIPTC

return WriteIPTC -- end
