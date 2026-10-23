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
-- Port notes:   read subset. Ported: ProcessTNEF (the attribute reader),
--               ProcessProps (the message-properties reader incl. named
--               properties and the currency/OLE-date/boolean/SYSTIME value
--               conversions), DecompressRTF (the RTF decompressor), and
--               the Main/MsgProps/AttachInfo tables, with the verbose
--               output. Deferred (unexercised): the .DAT handling note.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local str = perl.str
local subst = perl.subst
local isMatch = perl.isMatch
local split = perl.split
local unpack = perl.unpack
local perlTruthy = perl.truthy
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local ReadValue = ExifTool.ReadValue
local ASF = require('lexiftool.ASF')
local Microsoft = require('lexiftool.Microsoft')

local TNEF = {}

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
    [0x1f] = 'Unicode', -- (with terminating null)
    [0x40] = 'int64u', -- (time in 100 ns since 1601)
    [0x48] = 'GUID',   -- (16 bytes)
    [0x102] = 'undef', -- (blob)
}

-- byte count for non-integer fixed-size formats
local fmtSize = {
    null   = 0,
    float  = 4,
    double = 8,
    GUID   = 16,
}

local function datePrintConv(self, val) return self:ConvertDateTime(val) end

-- TNEF main table (upstream %Image::ExifTool::TNEF::Main)
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
        -- (ignore secondary code page; the charset side-effect of upstream's
        --  RawConv is not needed -- the string values are already UTF-8)
        RawConv = function(_self, val) return (str(val):gsub(' .*', '')) end,
        PrintConv = Microsoft.codePage,
    },
    [0x089006] = {
        Name = 'TNEFVersion',
        Format = 'int8u',
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = w end
            local rev = {}
            for i = #a, 1, -1 do rev[#rev + 1] = a[i] end
            return table.concat(rev, ' ')
        end,
        PrintConv = function(_self, val) return (val:gsub(' ', '.')) end,
    },
    [0x078008] = 'MessageClass',
    [0x008000] = 'From',
    [0x018004] = 'Subject',
    [0x038005] = { Name = 'SentDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x038006] = { Name = 'ReceivedDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
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
    [0x038020] = { Name = 'MessageModifyDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x069003] = {
        Name = 'MessageProps',
        SubDirectory = { TagTable = 'lexiftool.TNEF.MsgProps' },
    },
    [0x069004] = 'RecipientTable',
    [0x070600] = 'OriginalMessageClass',
    [0x060000] = 'Owner',
    [0x060001] = 'SentFor',
    [0x060002] = 'Delegate',
    [0x030006] = { Name = 'StartDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x030007] = { Name = 'EndDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x050008] = 'OwnerAppointmentID',
    [0x040009] = 'ResponseRequested',
    [0x06800F] = { Name = 'AttachData', Binary = 1 },
    [0x018010] = 'AttachTitle',
    [0x068011] = { Name = 'AttachMetaFile', Binary = 1 },
    [0x038012] = { Name = 'AttachCreateDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x038013] = { Name = 'AttachModifyDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x069001] = 'AttachTransportFilename',
    [0x069002] = { Name = 'AttachRenderingData', Binary = 1 },
    [0x069005] = {
        Name = 'AttachInfo',
        SubDirectory = { TagTable = 'lexiftool.TNEF.AttachInfo' },
    },
}

-- message properties (upstream %TNEF::MsgProps)
TNEF.MsgProps = {
    PROCESS_PROC = false, -- set below to TNEF.ProcessProps
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
    TAG_PREFIX = 'MsgProps',
    VARS = { LONG_TAGS = 0, NO_LOOKUP = 1 }, -- (suppress "long tags" warning in BuildTagLookup)
    [0x0002] = 'AlternateRecipientAllowed',
    [0x0039] = { Name = 'ClientSubmitTime', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x0040] = 'ReceivedByName',
    [0x0044] = 'ReceivedRepresentingName',
    [0x004d] = { Name = 'OriginalAuthorName', Groups = { [2] = 'Author' } },
    [0x0055] = { Name = 'OriginalDeliveryTime', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x0070] = 'Subject',
    [0x0075] = 'ReceivedByAddressType',
    [0x0076] = 'ReceivedByEmailAddress',
    [0x0077] = 'ReceivedRepresentingAddressType',
    [0x0078] = 'ReceivedRepresentingEmailAddress',
    [0x007f] = {
        Name = 'CorrelationKey',
        RawConv = function(_self, val)
            if type(val) == 'table' and val.ref == 'SCALAR' then return val.value end
            return val
        end,
    },
    [0x0c1a] = 'SenderName',
    [0x0c1d] = {
        Name = 'SenderSearchKey',
        RawConv = function(_self, val)
            if type(val) == 'table' and val.ref == 'SCALAR' then return val.value end
            return val
        end,
    },
    [0x0e06] = { Name = 'MessageDeliveryTime', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x0e1d] = 'NormalizedSubject',
    [0x0e28] = 'PrimarySendAccount',
    [0x0e29] = 'NextSendAccount',
    [0x0f02] = { Name = 'DeliveryOrRenewTime', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x1000] = { Name = 'MessageBodyText', Binary = 1 },
    [0x1007] = 'SyncBodyCount',
    [0x1008] = 'SyncBodyData',
    [0x1009] = {
        Name = 'MessageBodyRTF',
        Notes = 'RTF message body, decompressed if necessary',
        RawConv = function(_self, val)
            -- (upstream `$$val`: unref the binary value so GetValue's
            --  ValueConv can run -- a SCALAR-ref value would be skipped by
            --  the binary-ref conversion gate)
            if type(val) == 'table' and val.ref == 'SCALAR' then return val.value end
            return val
        end,
        ValueConv = function(self, val)
            local dat = TNEF.DecompressRTF(self, val)
            return { ref = 'SCALAR', value = dat }
        end,
    },
    [0x1013] = { Name = 'MessageBodyHTML', Binary = 1 },
    [0x1035] = 'InternetMessageID',
    [0x10f4] = 'Hidden',
    [0x10f6] = 'ReadOnly',
    [0x3007] = { Name = 'CreateDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
    [0x3008] = { Name = 'ModifyDate', Format = 'date', Groups = { [2] = 'Time' }, PrintConv = datePrintConv },
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

-- attachment info (upstream %TNEF::AttachInfo)
TNEF.AttachInfo = {
    PROCESS_PROC = false, -- set below to TNEF.ProcessProps
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
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
            [1] = 'AttachData',
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
    [0x7ffb] = { Name = 'ExceptionStartTime', Format = 'date', Groups = { [2] = 'Time' }, Unknown = 1, PrintConv = datePrintConv },
    [0x7ffc] = { Name = 'ExceptionEndTime', Format = 'date', Groups = { [2] = 'Time' }, Unknown = 1, PrintConv = datePrintConv },
}

--------------------------------------------------------------------------------
-- Decompress RTF text (upstream DecompressRTF)
-- Inputs: 0) ExifTool ref, 1) compressed RTF
-- Returns: Decompressed RTF or '' on error
--------------------------------------------------------------------------------
function TNEF.DecompressRTF(et, cdat)
    if #cdat <= 16 then return '' end
    local comp = perl.unpack('V', cdat:sub(9, 12))

    if comp == 0x414c454d then
        return substr(cdat, 16)
    elseif comp ~= 0x75465a4c then
        et:Warn(sprintf('Unknown RTF compression 0x%x', comp))
        return ''
    end
    local dict = [[{\rtf1\ansi\mac\deff0\deftab720{\fonttbl;}]]
        .. [[{\f0\fnil \froman \fswiss \fmodern ]]
        .. [[\fscript \fdecor MS Sans SerifSymbolArialTimes]]
        .. [[ New RomanCourier{\colortbl\red0\green0\blue0]]
        .. '\r\n'
        .. [[\par \pard\plain\f0\fs20\b\i\u\tab\tx]]
    -- (upstream `$cpos = 16` is a 0-based offset; Lua strings are 1-based,
    --  so the compressed data starts at byte 17)
    local cpos = 17
    local clen = #cdat
    local dpos = #dict
    local rtnVal = ''
    while cpos < clen do
        local control = cdat:byte(cpos)
        cpos = cpos + 1
        for _ = 1, 8 do
            if cpos >= clen then break end
            if (control & 0x01) ~= 0 then
                if cpos + 2 > clen then return rtnVal end
                local ref = cdat:byte(cpos) * 256 + cdat:byte(cpos + 1)
                cpos = cpos + 2
                local off = ref >> 4
                local len = (ref & 0x0f) + 2
                if off == dpos % 4096 or off % 4096 >= #dict then return rtnVal end
                for _ = 1, len do
                    local ch = dict:sub((off % 4096) + 1, (off % 4096) + 1)
                    dict = dict:sub(1, (dpos % 4096)) .. ch .. dict:sub((dpos % 4096) + 2)
                    dpos = dpos + 1
                    off = off + 1
                    rtnVal = rtnVal .. ch
                end
            else
                local ch = cdat:sub(cpos, cpos)
                cpos = cpos + 1
                dict = dict:sub(1, (dpos % 4096)) .. ch .. dict:sub((dpos % 4096) + 2)
                dpos = dpos + 1
                rtnVal = rtnVal .. ch
            end
            control = control >> 1
        end
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process TNEF message properties (upstream ProcessProps)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function TNEF.ProcessProps(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = #dataPt
    if dirLen <= 4 then return 0 end
    local entries = unpack('V', dataPt)
    et:VerboseDir('TNEF Properties', entries)
    local pos = 4
    local i = 0
    while i < entries do
        if pos + 4 > dirLen then break end
        local type = Get16u(dataPt, pos)
        local tag  = Get16u(dataPt, pos+2)
        pos = pos + 4
        -- handle named properties (bit 0x8000 set)
        if tag & 0x8000 ~= 0 then
            if pos + 24 > dirLen then break end
            local uid = ASF.GetGUID(substr(dataPt, pos, 16))
            uid = subst(uid, [[-0000-0000-C000-000000000046$]], '')  -- remove common suffix
            local idtype = Get32u(dataPt, pos + 16)
            local num = Get32u(dataPt, pos + 20)
            pos = pos + 24
            if idtype == 0 then      -- number
                tag = uid .. sprintf('_%.8x', num)
            elseif idtype == 1 then -- string
                if pos + num > dirLen or num < 2 then break end
                -- decode string (ignoring null terminator)
                local name = et:Decode(substr(dataPt, pos, num-2), 'UTF16')
                tag = uid .. '_' .. name
                if not tagTbl[tag] then
                    et:AddTagToTable(tagTbl, tag, {
                        Name = ExifTool.MakeTagName(name)
                    })
                end
                pos = pos + ((num + 3) & 0xfffffffc)    -- (padded to an even 4 bytes)
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
        fmt = propType[type]
        if not fmt then break end
        while count ~= 0 do
            local size = fmtSize[fmt]
            local val
            if not perlTruthy(size) then
                local ok, n = isMatch(fmt, [[(\d+)]])
                if ok then
                    size = count * perl.num(n) / 8
                    size = math.tointeger(size) or size -- (Lua: keep an integral size an integer)
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
                        for j = 1, #a do a[j] = perl.num(a[j]) / 10000 end
                    elseif type == 0x07 then   -- OLE date
                        -- convert time from days since Dec 30, 1899
                        for j = 1, #a do
                            if perl.num(a[j]) ~= 0 then a[j] = (perl.num(a[j]) - 25569) * 24 * 3600 end
                            a[j] = ExifTool.ConvertUnixTime(a[j])
                        end
                    elseif type == 0x0b then   -- boolean
                        for j = 1, #a do a[j] = perlTruthy(a[j]) and 'True' or 'False' end
                    elseif type == 0x40 then   -- SYSTIME
                        -- convert time from 100-ns intervals since Jan 1, 1601
                        for j = 1, #a do a[j] = ExifTool.ConvertUnixTime(perl.num(a[j])/1e7-11644473600,1) end
                    end
                    if #a > 1 then val = a else val = a[1] end
                end
                count = 1 -- (read them all already)
            elseif fmt == 'GUID' then
                val = ASF.GetGUID(val)
            elseif fmt == 'Unicode' then
                val = subst(et:Decode(val, 'UTF16'), [[\0+$]], '')
            elseif fmt == 'string' then
                val = subst(val, [[\0+$]], '')
                -- convert from specified code page if supported
                if perlTruthy(et.Charset) then val = et:Decode(val, et.Charset) end
            elseif fmt == 'undef' and #val > 0 then
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
-- Extract EXIF information from a TNEF image (upstream ProcessTNEF)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid TNEF file
--------------------------------------------------------------------------------
function TNEF.ProcessTNEF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(0x15)
    if n ~= 0x15 then return 0 end
    if not buff:match('^\120\159\62\34..\1\6\144\8\0') then return 0 end
    raf:Seek(6, 0)
    et:SetFileType('TNEF')
    ExifTool.SetByteOrder('II')
    local tagTablePtr = et:GetTagTable('lexiftool.TNEF.Main')
    -- read through the attributes
    while true do
        local n2, hdr = raf:Read(9)
        if n2 ~= 9 then break end
        -- (ignore the attrLevel byte: 1 for message, 2 for attachment)
        local tag = perl.unpack('V', hdr:sub(2, 5))
        local len = perl.unpack('V', hdr:sub(6, 9))
        -- increment document number for each attachment
        if tag == 0x069002 then
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
        end
        local n3, dbuf = raf:Read(len)
        if n3 ~= len then break end
        local tagInfo = tagTablePtr[tag]
        local val
        local fmt
        if tagInfo and tagInfo.Format then
            fmt = tagInfo.Format
            if fmt == 'date' and #dbuf >= 12 then
                local d = { ExifTool.Get16u(dbuf, 0), ExifTool.Get16u(dbuf, 2), ExifTool.Get16u(dbuf, 4),
                    ExifTool.Get16u(dbuf, 6), ExifTool.Get16u(dbuf, 8), ExifTool.Get16u(dbuf, 10) }
                val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', d[1], d[2], d[3], d[4], d[5], d[6])
            end
        else
            val = dbuf
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dbuf,
            DataPos = raf:Tell() - len,
            Format = fmt,
        })
        if tag == 0x069005 then et.DOC_NUM = nil end -- end of attachment
        raf:Seek(2, 1) -- skip checksum
    end
    et.DOC_NUM = nil
    return 1
end

-- (PROCESS_PROC set here so the tables can reference ProcessProps)
TNEF.MsgProps.PROCESS_PROC = TNEF.ProcessProps
TNEF.AttachInfo.PROCESS_PROC = TNEF.ProcessProps

return TNEF