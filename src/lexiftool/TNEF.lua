--------------------------------------------------------------------------------
-- File:         lexiftool/TNEF.lua
-- Ported from:  lib/Image/ExifTool/TNEF.pm
--
-- Description:  Read TNEF meta information
--
-- Revisions:    2025-07-08 - P. Harvey Created
--
-- References:   1) https://officeprotocoldoc.z19.web.core.windows.net/files/MS-OXTNEF/%5bMS-OXTNEF%5d.pdf
--               2) https://officeprotocoldoc.z19.web.core.windows.net/files/MS-OXCMSG/%5bMS-OXCMSG%5d.pdf
--               3) https://msopenspecs.azureedge.net/files/MS-OXPROPS/%5bMS-OXPROPS%5d.pdf
--               4) https://officeprotocoldoc.z19.web.core.windows.net/files/MS-OXCDATA/%5bMS-OXCDATA%5d.pdf
--               5) https://github.com/echo-devim/pyjacktrick/blob/main/mapi_constants.py
--
-- Port notes:   TNEF.pm in full: the %propType/%fmtSize lookups, the Main,
--               MsgProps and AttachInfo tables, DecompressRTF, ProcessProps
--               and ProcessTNEF.  Lua forms: the hash spread %dateInfo is a
--               helper call in front of the entry (`dateInfo { ... }`);
--               the predeclared ProcessProps is a `false` PROCESS_PROC
--               assigned at the end; the dictionary and the result of
--               DecompressRTF, which upstream edits in place, are carrays.
--               A binary value (`\$copy`) is { ref = 'SCALAR', value = ... }.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local ASF = require('lexiftool.ASF')
local Microsoft = require('lexiftool.Microsoft')
local perl = require('lexiftool.perl')
local carray = require('carray')
local perlTruthy = perl.truthy
local length, substr = perl.length, perl.substr
local sprintf, str, num = perl.sprintf, perl.str, perl.num
local isMatch, subst, tr = perl.isMatch, perl.subst, perl.tr
local split, join, reverse = perl.split, perl.join, perl.reverse
local unpack = perl.unpack
local Get16u, Get32u = ExifTool.Get16u, ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ReadValue = ExifTool.ReadValue
local charsetName = ExifTool.charsetName

local TNEF = {}

-- (upstream predeclaration `sub ProcessProps($$$);`: the PROCESS_PROC
--  entries below are `false` until ProcessProps is defined)

-- TNEF property types
local propType = {
    [0x01] = 'null',
    [0x02] = 'int16s',
    [0x03] = 'int32s',
    [0x04] = 'float',
    [0x05] = 'double',
    [0x06] = 'int64s', -- (currency / 10000)
    [0x07] = 'double', -- (days since Dec 30, 1899)
    [0x0a] = 'int32s', -- (error code)
    [0x0b] = 'int16s', -- (boolean)
    [0x0d] = 'undef',  -- (object)
    [0x14] = 'int64s',
    [0x1e] = 'string', -- (with terminating null)
    [0x1f] = 'Unicode',-- (with terminating null)
    [0x40] = 'int64u', -- (time in 100 ns since 1601)
    [0x48] = 'GUID',   -- (16 bytes)
    [0x102] = 'undef', -- (blob)
}

-- byte count for non-integer fixed-size formats
local fmtSize = {
    null    = 0,
    float   = 4,
    double  = 8,
    GUID    = 16,
}

-- (port helper: Perl's `{ ..., %dateInfo }` -- the entries of %dateInfo are
--  added to the tagInfo)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

-- (port helper: Perl's `$$val` under "strict refs" -- the value of a scalar
--  reference, and a die for a plain string, which the RawConv eval turns into
--  a warning)
local function deref(val)
    if perl.ref(val) == 'SCALAR' then return val.value end
    perl.die("Can't use string (\"" .. str(val) .. "\") as a SCALAR ref while \"strict refs\" in use")
end

local dateInfo = spread {
    Format = 'date',
    Groups = { [2] = 'Time' },
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

TNEF.Main = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
    VARS = { NO_LOOKUP = 1 },
    NOTES = [[
        Information extracted from Transport Neutral Encapsulation Format (TNEF)
        files (eg. winmail.dat).  But note that the exiftool application doesn't
        process files with a .DAT extension by default when a directory name is
        given, so in this case either specify the .DAT file(s) by name or add
        C<-ext+ dat> to the command.
    ]],
    [0x069007] = {
        Name = 'CodePage',
        Format = 'int32u',
        SeparateTable = 'Microsoft CodePage',
        -- (ignore secondary code page)
        RawConv = function(self, val)
            val = subst(val, ' .*', ''); self.Charset = charsetName['cp' .. str(val)]; return val
        end,
        PrintConv = Microsoft.codePage,
    },
    [0x089006] = {
        Name = 'TNEFVersion',
        Format = 'int8u',
        ValueConv = function(_self, val) local a = { reverse(table.unpack(split(' ', val))) }; return join(' ', a) end,
        PrintConv = function(_self, val) val = tr(val, ' ', '.'); return val end,
    },
    [0x078008] = 'MessageClass',
    [0x008000] = 'From',
    [0x018004] = 'Subject',
    [0x038005] = dateInfo { Name = 'SentDate' },
    [0x038006] = dateInfo { Name = 'ReceivedDate' },
    [0x068007] = 'MessageStatus',
    [0x018009] = 'MessageID',
    [0x02800C] = 'MessageBody',
    [0x04800D] = {
        Name = 'Priority',
        Format = 'int16u', -- (contrary to documentation which says int32u)
        PrintConv = {
            [0] = 'Low',
            [1] = 'Normal',
            [2] = 'High',
        },
    },
    [0x038020] = dateInfo { Name = 'MessageModifyDate' }, -- (unclear what this really means)
    [0x069003] = {
        Name = 'MessageProps',
        SubDirectory = { TagTable = 'lexiftool.TNEF.MsgProps' },
    },
    [0x069004] = 'RecipientTable',
    [0x070600] = 'OriginalMessageClass',
    [0x060000] = 'Owner',
    [0x060001] = 'SentFor',
    [0x060002] = 'Delegate',
    [0x030006] = dateInfo { Name = 'StartDate' },
    [0x030007] = dateInfo { Name = 'EndDate' },
    [0x050008] = 'OwnerAppointmentID',
    [0x040009] = 'ResponseRequested',
    [0x06800F] = { Name = 'AttachData', Binary = 1 },
    [0x018010] = 'AttachTitle',
    [0x068011] = { Name = 'AttachMetaFile', Binary = 1 },
    [0x038012] = dateInfo { Name = 'AttachCreateDate' },
    [0x038013] = dateInfo { Name = 'AttachModifyDate' },
    [0x069001] = 'AttachTransportFilename',
    [0x069002] = { Name = 'AttachRenderingData', Binary = 1 }, -- (start of attachment)
    [0x069005] = { -- (end of attachment)
        Name = 'AttachInfo',
        SubDirectory = { TagTable = 'lexiftool.TNEF.AttachInfo' },
    },
}

TNEF.MsgProps = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = 'MsgProps',
    VARS = { LONG_TAGS = 0, NO_LOOKUP = 1 }, -- (suppress "long tags" warning in BuildTagLookup)
    [0x0002] = 'AlternateRecipientAllowed',
    [0x0039] = dateInfo { Name = 'ClientSubmitTime' },
    [0x0040] = 'ReceivedByName',
    [0x0044] = 'ReceivedRepresentingName',
    [0x004d] = { Name = 'OriginalAuthorName', Groups = { [2] = 'Author' } },
    [0x0055] = dateInfo { Name = 'OriginalDeliveryTime' },
    [0x0070] = 'Subject',
    [0x0075] = 'ReceivedByAddressType',
    [0x0076] = 'ReceivedByEmailAddress',
    [0x0077] = 'ReceivedRepresentingAddressType',
    [0x0078] = 'ReceivedRepresentingEmailAddress',
    [0x007f] = { Name = 'CorrelationKey', RawConv = function(_self, val) return deref(val) end },
    [0x0c1a] = 'SenderName',
    [0x0c1d] = { Name = 'SenderSearchKey', RawConv = function(_self, val) if perlTruthy(perl.ref(val)) then return deref(val) end; return val end },
    [0x0e06] = dateInfo { Name = 'MessageDeliveryTime' },
    [0x0e1d] = 'NormalizedSubject',
    [0x0e28] = 'PrimarySendAccount',
    [0x0e29] = 'NextSendAccount',
    [0x0f02] = dateInfo { Name = 'DeliveryOrRenewTime' }, -- #5
    [0x1000] = { Name = 'MessageBodyText', Binary = 1 },
    [0x1007] = 'SyncBodyCount',
    [0x1008] = 'SyncBodyData',
    [0x1009] = {
        Name = 'MessageBodyRTF',
        Notes = 'RTF message body, decompressed if necessary',
        RawConv = function(_self, val) return deref(val) end, -- (ValueConv won't convert a scalar ref, so convert to scalar here)
        ValueConv = function(self, val) local dat = TNEF.DecompressRTF(self,val); return { ref = 'SCALAR', value = dat } end,
    },
    [0x1013] = { Name = 'MessageBodyHTML', Binary = 1 },
    [0x1035] = 'InternetMessageID',
    [0x10f4] = 'Hidden',
    [0x10f6] = 'ReadOnly',
    [0x3007] = dateInfo { Name = 'CreateDate' },
    [0x3008] = dateInfo { Name = 'ModifyDate' },
    [0x3fde] = 'InternetCodePage',
    [0x3ff1] = 'LocalUserID',
    [0x3ff8] = { Name = 'CreatorName', Groups = { [2] = 'Author' } },
    [0x3ffa] = 'LastModifierName',
    [0x3ffd] = 'MessageCodePage',
    [0x4076] = { Name = 'SpamConfidenceLevel' },
    -- named properties that look interesting
    ['00020329_Author'] = {
        Name = 'Author',
        Groups = { [2] = 'Author' },
        Notes = [[
            tag ID's for named properties are constructed from the property namespace
            GUID with the ending "-0000-0000-C000-000000000046" removed, followed by the
            string or numerical ID in hex, separated by an underscore
        ]],
    }, -- (NC)
    ['00020329_LastAuthor'] = { Name = 'LastAuthor', Groups = { [2] = 'Author' } }, -- (NC)
    ['00062004_0000801A'] = 'HomeAddress', -- (NC)
    ['00062004_000080DA'] = 'HomeAddressCountryCode', -- (NC)
    ['00062008_00008554'] = 'AppVersion',
}

-- ref https://pkg.go.dev/github.com/axigenmessaging/tnef#section-readme
TNEF.AttachInfo = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = 'Attach',
    [0x0e20] = 'AttachSize',
    [0x0e21] = 'AttachNum',
    [0x0ff8] = { Name = 'MappingSignature', Unknown = 1 },
    [0x3001] = 'AttachFileName',
    [0x3703] = 'AttachFileExtension',
    [0x3701] = 'AttachBinary',
    [0x3705] = {
        Name = 'AttachMethod',
        PrintConv = {
            [0] = 'Attachment Created',
            [1] = 'AttachData', -- (contrary to documentation which says the AttachBinary tag)
            [2] = 'AttachLongPathName (recipients with access)',
            [4] = 'AttachLongPathName',
            [5] = 'Embedded Message',
            [6] = 'AttachBinary (object)',
            [7] = 'AttachLongPathName (using AttachmentProviderType)',
        },
    },
    [0x3707] = 'AttachLongFileName',
    [0x3708] = 'AttachPathName',
    [0x370d] = 'AttachLongPathName',
    [0x370e] = 'AttachMIMEType',
    [0x7ffb] = dateInfo {
        Name = 'ExceptionStartTime',
        Unknown = 1, -- (because these values don't make sense in my samples)
    },
    [0x7ffc] = dateInfo { Name = 'ExceptionEndTime',   Unknown = 1 },
}

--------------------------------------------------------------------------------
-- Decompress RTF text (ref https://metacpan.org/pod/Mail::Exchange::Message)
-- Inputs: 0) ExifTool ref, 1) compressed RTF
-- Returns: Decompressed RTF or '' on error
function TNEF.DecompressRTF(et, cdat)
    if length(cdat) <= 16 then return '' end
    local comp = unpack('x8V', cdat)

    if comp == 0x414c454D then
        return substr(cdat, 16)
    elseif comp ~= 0x75465a4c then
        et:Warn(sprintf('Unknown RTF compression 0x%x', comp))
        return ''
    end
    local dict = carray.new('char'):append([[{\rtf1\ansi\mac\deff0\deftab720{\fonttbl;}]]..
               [[{\f0\fnil \froman \fswiss \fmodern ]]..
               [[\fscript \fdecor MS Sans SerifSymbolArialTimes]]..
               [[ New RomanCourier{\colortbl\red0\green0\blue0]]..
               "\r\n"..[[\par \pard\plain\f0\fs20\b\i\u\tab\tx]])
    local cpos = 16
    local clen = length(cdat)
    local dpos = length(dict)
    local rtnVal = carray.new('char')
    while cpos < clen do
        local control = unpack('C', substr(cdat, cpos, 1)); cpos = cpos + 1
        local i = 0
        while i<8 and cpos<clen do
            if control & (1<<i) ~= 0 then
                if cpos + 2 > clen then return rtnVal:tostring() end
                local ref = unpack('n', substr(cdat, cpos, 2))
                cpos = cpos + 2
                local off = ref >> 4
                local len = (ref & 0x0f) + 2
                if off == dpos % 4096 or off % 4096 >= length(dict) then return rtnVal:tostring() end
                for _ = 0, len - 1 do
                    local ch = substr(dict, (off % 4096), 1); off = off + 1
                    substr(dict, (dpos % 4096), 1, ch); dpos = dpos + 1
                    rtnVal:append(ch)
                end
            else
                local ch = substr(cdat, cpos, 1); cpos = cpos + 1
                substr(dict, (dpos % 4096), 1, ch); dpos = dpos + 1
                rtnVal:append(ch)
            end
            i = i + 1
        end
    end
    return rtnVal:tostring()
end

--------------------------------------------------------------------------------
-- Process TNEF message properties
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function TNEF.ProcessProps(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = length(dataPt)
    if dirLen <= 4 then return 0 end
    local entries = unpack('V', dataPt)
    et:VerboseDir('TNEF Properties', entries)
    local pos = 4
    local i = 0
    while i<entries do
        if pos + 4 > dirLen then break end
        local type = Get16u(dataPt, pos)
        local tag  = Get16u(dataPt, pos+2)
        pos = pos + 4
        -- handle named properties (bit 0x8000 set)
        if tag & 0x8000 ~= 0 then
            if pos + 24 > dirLen then break end
            local uid = ASF.GetGUID(substr(dataPt, pos, 16))
            uid = subst(uid, '-0000-0000-C000-000000000046$', '')  -- remove common suffix
            local idtype = Get32u(dataPt, pos + 16)
            local num_ = Get32u(dataPt, pos + 20)
            pos = pos + 24
            if idtype == 0 then      -- number
                tag = uid .. sprintf('_%.8x', num_)
            elseif idtype == 1 then -- string
                if pos + num_ > dirLen or num_ < 2 then break end
                -- decode string (ignoring null terminator)
                local name = et:Decode(substr(dataPt, pos, num_-2), 'UTF16')
                tag = uid .. '_' .. name
                if not tagTbl[tag] then
                    AddTagToTable(nil, tagTbl, tag, {
                        Name = ExifTool.MakeTagName(name)
                    })
                end
                pos = pos + ((num_ + 3) & 0xfffffffc)    -- (padded to an even 4 bytes)
            else
                break -- error
            end
        end
        local count = 1
        local multi, fmt
        if type & 0x1000 ~= 0 then
            multi = 1
            type = type & 0x0fff
            if pos + 4 > dirLen then break end
            count = Get32u(dataPt, pos)
            pos = pos + 4
        end
        fmt = propType[type]; if not fmt then break end
        while count ~= 0 do
            local size = fmtSize[fmt]
            local val
            if not perlTruthy(size) then
                local ok, c1 = isMatch(fmt, [[(\d+)]])
                if ok then
                    size = count * num(c1) / 8
                    size = math.tointeger(size) or size -- (Perl keeps an exact quotient an integer)
                elseif fmt == 'null' then
                    val = '' -- ($size is already 0)
                else
                    -- skip 1 count for "special case" stupidity
                    if not multi then pos = pos + 4 end
                    if pos + 4 > dirLen then break end
                    size = Get32u(dataPt, pos)
                    pos = pos + 4
                    if pos + size > dirLen then break end
                    val = substr(dataPt, pos, size)
                end
            end
            if val == nil then
                val = ReadValue(dataPt, pos, fmt, count, size)
                if type == 0x06 or type == 0x07 or type == 0x0b or type == 0x40 then
                    local a = split(' ', val)
                    if type == 0x06 then        -- currency
                        for j = 1, #a do a[j] = num(a[j]) / 10000 end
                    elseif type == 0x07 then   -- OLE date
                        -- convert time from days since Dec 30, 1899
                        for j = 1, #a do
                            if num(a[j]) ~= 0 then a[j] = (num(a[j]) - 25569) * 24 * 3600 end
                            a[j] = ExifTool.ConvertUnixTime(a[j])
                        end
                    elseif type == 0x0b then   -- boolean
                        for j = 1, #a do a[j] = perlTruthy(a[j]) and 'True' or 'False' end
                    elseif type == 0x40 then   -- SYSTIME
                        -- convert time from 100-ns intervals since Jan 1, 1601
                        for j = 1, #a do a[j] = ExifTool.ConvertUnixTime(num(a[j])/1e7-11644473600,1) end
                    end
                    if #a > 1 then val = a else val = a[1] end
                end
                count = 1 -- (read them all already)
            elseif fmt == 'GUID' then
                val = ASF.GetGUID(val)
            elseif fmt == 'Unicode' then
                val = et:Decode(val, 'UTF16'); val = subst(val, [[\0+$]], '')
            elseif fmt == 'string' then
                val = subst(val, [[\0+$]], '')
                -- convert from specified code page if supported
                if perlTruthy(et.Charset) then val = et:Decode(val, et.Charset) end
            elseif fmt == 'undef' and perlTruthy(length(val)) then
                local copy = val
                val = { ref = 'SCALAR', value = copy }  -- change to a binary data reference
            end
            et:HandleTag(tagTbl, tag, val, {
                DataPt  = dataPt,
                DataPos = dataPos,
                Start   = pos,
                Size    = size,
                Format  = sprintf('%s, type 0x%.2x', fmt, type),
                Index   = i,
            })
            pos = pos + ((size + 3) & 0xfffffffc)
            count = count - 1
        end
        i = i + 1
    end
    if i ~= entries then et:Warn('Error parsing message properties') end
    return 1
end

--------------------------------------------------------------------------------
-- Extract EXIF information from a TNEF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid TNEF file
function TNEF.ProcessTNEF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff

    -- verify this is a valid TNEF file (read TNEFHeader and TNEFVersion)
    n, buff = raf:Read(0x15)
    if not (n == 0x15 and raf:Seek(6, 0)) then return 0 end
    if not isMatch(buff, [[(?s)^\x78\x9f\x3e\x22..\x01\x06\x90\x08\0]]) then return 0 end
    et:SetFileType('TNEF')
    SetByteOrder('II')
    local tagTbl = GetTagTable(nil, 'lexiftool.TNEF.Main')
    -- read through the attributes
    while true do
        n, buff = raf:Read(9)
        if n ~= 9 then break end
        -- (ignore the attrLevel byte: 1 for message, 2 for attachment)
        local tag, len = unpack('x1VV', buff)
        -- increment document number for each attachment
        if tag == 0x069002 then et.DOC_COUNT = num(et.DOC_COUNT) + 1; et.DOC_NUM = et.DOC_COUNT end
        n, buff = raf:Read(len); if n ~= len then break end
        local tagInfo = tagTbl[tag]
        local val, fmt
        if tagInfo and tagInfo.Format then
            fmt = tagInfo.Format
            if fmt == 'date' and length(buff) >= 12 then
                val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', unpack('v6', buff))
            end
        else
            val = buff
        end
        et:HandleTag(tagTbl, tag, val, {
            DataPt  = buff,
            DataPos = raf:Tell() - len,
            Format  = fmt,
        })
        if tag == 0x069005 then et.DOC_NUM = nil end -- end of attachment
        raf:Seek(2, 1)  -- skip checksum
    end
    et.DOC_NUM = nil
    return 1
end

TNEF.MsgProps.PROCESS_PROC = TNEF.ProcessProps
TNEF.AttachInfo.PROCESS_PROC = TNEF.ProcessProps

return TNEF -- end
