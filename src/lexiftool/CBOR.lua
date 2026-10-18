--------------------------------------------------------------------------------
-- File:         lexiftool/CBOR.lua
-- Ported from:  lib/Image/ExifTool/CBOR.pm
--
-- Description:  Read CBOR format metadata
--
-- Revisions:    2021-09-30 - P. Harvey Created
--
-- References:   1) https://c2pa.org/public-draft/
--               2) https://datatracker.ietf.org/doc/html/rfc7049
--               3) https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml
--
-- Port notes:   complete: the Main table, ReadCBORValue and ProcessCBOR.
--               Perl references map onto the shapes this port already uses:
--               a byte string becomes a `{ref='SCALAR', value=...}` tuple, a
--               CBOR map becomes a hash table carrying `_ordered_keys_` (the
--               same shape JSON.lua builds and JSON.ProcessTag consumes), and
--               a CBOR array becomes a plain Lua array.
--               One upstream oddity is carried over rather than corrected: in
--               the half-precision float branch the condition `exp != 31`
--               names the *builtin* `exp` (i.e. `exp($_)`), not the local
--               `$exp`, so it is always true and the `<inf>`/`<nan>` branch is
--               unreachable.  The port keeps that behaviour.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local JSON = require('lexiftool.JSON')
local perl = require('lexiftool.perl')
local substr = perl.substr
local Get8u = ExifTool.Get8u
local GetFloat = ExifTool.GetFloat
local GetDouble = ExifTool.GetDouble
local ReadValue = ExifTool.ReadValue
local SetByteOrder = ExifTool.SetByteOrder

local CBOR = {}

local ReadCBORValue

-- optional CBOR type code
local cborType6 = {
    [0] = 'date/time string',
    [1] = 'epoch-based date/time',
    [2] = 'positive bignum',
    [3] = 'negative bignum',
    [4] = 'decimal fraction',
    [5] = 'bigfloat',
    [16] = 'COSE Encrypt0',          -- #3 (COSE Single Recipient Encrypted Data Object)
    [17] = 'COSE Mac0',              -- #3 (COSE Mac w/o Recipients Object)
    [18] = 'COSE Sign1',             -- #3 (COSE Single Signer Data Object)
    [19] = 'COSE Countersignature',  -- #3 (COSE standalone V2 countersignature)
    [21] = 'expected base64url encoding',
    [22] = 'expected base64 encoding',
    [23] = 'expected base16 encoding',
    [24] = 'encoded CBOR data',
    [25] = 'string number',          -- #3 (reference the nth previously seen string)
    [26] = 'serialized Perl',        -- #3 (Serialised Perl object with classname and constructor arguments)
    [27] = 'serialized code',        -- #3 (Serialised language-independent object with type name and constructor arguments)
    [28] = 'shared value',           -- #3 (mark value as (potentially) shared)
    [29] = 'shared value number',    -- #3 (reference nth marked value)
    [30] = 'rational',               -- #3 (Rational number)
    [31] = 'missing array value',    -- #3 (Absent value in a CBOR Array)
    [32] = 'URI',
    [33] = 'base64url',
    [34] = 'base64',
    [35] = 'regular expression',
    [36] = 'MIME message',
    -- (lots more after this in ref 3, but don't include them unless we see them)
    [55799] = 'CBOR magic number',
}

local cborType7 = {
    [20] = 'False',
    [21] = 'True',
    [22] = 'null',
    [23] = 'undef',
}

CBOR.Main = {
    GROUPS = { [0] = 'JUMBF', [1] = 'CBOR', [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        The tags below are extracted from CBOR (Concise Binary Object
        Representation) metadata.  The C2PA specification uses this format for some
        metadata.  As well as these tags, ExifTool will read any existing tags.
    ]],
    ['dc:title']    = 'Title',
    ['dc:format']   = 'Format',
    -- my sample file has the following 2 tags in CBOR, but they should be JSON
    authorName      = { Name = 'AuthorName', Groups = { [2] = 'Author' } },
    authorIdentifier= { Name = 'AuthorIdentifier', Groups = { [2] = 'Author' } },
    documentID      = { },
    instanceID      = { },
    thumbnailHash   = { List = 1 },
    thumbnailUrl    = { Name = 'ThumbnailURL' },
    relationship    = { }
}

--------------------------------------------------------------------------------
-- Read CBOR value
-- Inputs: 0) ExifTool ref, 1) data ref, 2) position in data, 3) data end
-- Returns: 0) value, 1) error string, 2) new data position
--------------------------------------------------------------------------------
ReadCBORValue = function(et, dataPt, pos, endPos)
    if pos >= endPos then return nil, 'Truncated CBOR data', pos end
    local verbose = et.OPTIONS.Verbose or 0
    local indent = et.INDENT
    local dumpStart = pos
    local fmt = Get8u(dataPt, pos); pos = pos + 1
    local dat = fmt & 0x1f
    local num, val, err, size
    fmt = fmt >> 5
    if dat < 24 then
        num = dat
    elseif dat == 31 then   -- indefinite count (not used in C2PA)
        num = -1  -- (flag for indefinite count)
        et:VPrint(1, et.INDENT .. ' (indefinite count):\n')
    else
        local format = ({ [24] = 'int8u', [25] = 'int16u', [26] = 'int32u', [27] = 'int64u' })[dat]
        if not format then return nil, 'Invalid CBOR integer type ' .. ExifTool.NumStr(dat), pos end
        size = ExifTool.FormatSize(format)
        if pos + size > endPos then return nil, 'Truncated CBOR integer value', pos end
        num = ReadValue(dataPt, pos, format, 1, size)
        pos = pos + size
    end
    local pre = ''
    if et.cbor_pre ~= nil and fmt ~= 6 then
        pre = et.cbor_pre
        et.cbor_pre = nil
    end
    if fmt == 0 then            -- positive integer
        val = num
        et:VPrint(1, et.INDENT .. ' ' .. pre .. 'int+: ' .. ExifTool.NumStr(val) .. '\n')
    elseif fmt == 1 then        -- negative integer
        val = -1 * num
        et:VPrint(1, et.INDENT .. ' ' .. pre .. 'int-: ' .. ExifTool.NumStr(val) .. '\n')
    elseif fmt == 2 or fmt == 3 then    -- byte/UTF8 string
        if pos + num > endPos then return nil, 'Truncated CBOR string value', pos end
        if num < 0 then -- (should not happen in C2PA)
            local string = ''
            et.INDENT = et.INDENT .. '  '
            while true do
                val, err, pos = ReadCBORValue(et, dataPt, pos, endPos)
                if err then return nil, err, pos end
                if val == nil then break end    -- hit the break?
                -- (note: strictly we should be checking that this was a string we read)
                string = string .. val
            end
            et.INDENT = indent
            return string, nil, pos     -- return concatenated byte/text string
        else
            val = substr(dataPt, pos, num)
        end
        pos = pos + num
        if fmt == 2 then    -- (byte string)
            et:VPrint(1, et.INDENT .. ' ' .. pre .. 'byte: <binary data ' .. #val .. ' bytes>\n')
            local dat2 = val
            val = { ref = 'SCALAR', value = dat2 }  -- use scalar reference for binary data
        else                -- (text string)
            val = et:Decode(val, 'UTF8')
            et:VPrint(1, et.INDENT .. ' ' .. pre .. "text: '" .. val .. "'\n")
        end
    elseif fmt == 4 or fmt == 5 then    -- list/hash
        if fmt == 4 then
            et:VPrint(1, et.INDENT .. ' ' .. pre .. 'list: <' .. ExifTool.NumStr(num) .. ' elements>\n')
        else
            et:VPrint(1, et.INDENT .. ' ' .. pre .. 'hash: <' .. ExifTool.NumStr(num) .. ' pairs>\n')
            num = num * 2
        end
        et.INDENT = et.INDENT .. '  '
        local i = 0
        local list = {}
        if verbose > 2 then
            ExifTool.HexDump(dataPt, pos - dumpStart, {
                Start   = dumpStart,
                DataPos = et.cbor_datapos,
                Prefix  = et.INDENT,
                Out     = et:Options('TextOut'),
            })
        end
        while num ~= 0 do
            et.cbor_pre = ExifTool.NumStr(i) .. ') '
            if fmt == 4 then
                i = i + 1
            elseif num & 0x01 ~= 0 then
                et.cbor_pre = string.rep(' ', #et.cbor_pre)
                i = i + 1
            end
            val, err, pos = ReadCBORValue(et, dataPt, pos, endPos)
            if err then return nil, err, pos end
            if val == nil then
                if num >= 0 then return nil, 'Unexpected list terminator', pos end -- (upstream `unless $num < 0`)
                break
            end
            list[#list + 1] = val
            num = num - 1
        end
        dumpStart = pos
        et.INDENT = indent
        if fmt == 5 then
            local keys = {}
            local hash = { _ordered_keys_ = keys }
            for j = 1, #list - 1, 2 do
                hash[list[j]] = list[j + 1]
                keys[#keys + 1] = list[j]   -- save ordered list of keys
            end
            val = hash
        else
            val = list
        end
    elseif fmt == 6 then        -- optional tag
        if verbose > 0 then
            local str = ExifTool.NumStr(num) .. ' (' .. (cborType6[num] or 'unknown') .. ')'
            local spc = et.cbor_pre and string.rep(' ', #et.cbor_pre) or ''
            et:VPrint(1, et.INDENT .. ' ' .. spc .. '<CBOR optional type ' .. str .. '>\n')
            if verbose > 2 then
                ExifTool.HexDump(dataPt, pos - dumpStart, {
                    Start   = dumpStart,
                    DataPos = et.cbor_datapos,
                    Prefix  = et.INDENT .. '  ',
                    Out     = et:Options('TextOut'),
                })
            end
        end
        -- read next value (note: in the case of multiple tags,
        -- this nesting will apply the tags in the correct order)
        val, err, pos = ReadCBORValue(et, dataPt, pos, endPos)
        if err then return nil, err, pos end
        dumpStart = pos
        -- convert some values according to the optional tag number (untested)
        if num == 0 and type(val) ~= 'table' then       -- date/time string
            local XMP = require('lexiftool.XMP')
            val = XMP.ConvertXMPDate(val)
        elseif num == 1 and type(val) ~= 'table' then   -- epoch-based date/time
            if ExifTool.IsFloat(val) then
                -- (`and nil or 6` would always yield 6 in Lua, so this needs
                --  an if; Perl's int() truncates towards zero)
                local dec
                if val ~= (val >= 0 and math.floor(val) or math.ceil(val)) then dec = 6 end
                val = ExifTool.ConvertUnixTime(val, 1, dec)
            end
        elseif (num == 2 or num == 3) and type(val) == 'table' and val.ref == 'SCALAR' then -- pos/neg bignum
            local big = 0
            for k = 0, #val.value - 1 do big = 256 * big + Get8u(val.value, k) end
            val = num == 2 and big or -big
        elseif (num == 4 or num == 5) and -- decimal fraction or bigfloat
            type(val) == 'table' and val.ref == nil and val._ordered_keys_ == nil and #val == 2 and
            ExifTool.IsInt(val[1]) and ExifTool.IsInt(val[2])
        then
            val = val[2] * (num == 4 and 10 or 2) ^ val[1]
        end
    elseif fmt == 7 then
        if dat == 31 then
            val = nil   -- "break" = end of indefinite array/hash (not used in C2PA)
        elseif dat < 24 then
            val = cborType7[num]
            -- (upstream interpolates the undefined $val, not $num, so this
            --  always reads "Unknown ()" -- kept as-is)
            if val == nil then val = 'Unknown ()' end
        elseif dat == 25 then   -- half-precision float
            local exp = (num >> 10) & 0x1f
            local mant = num & 0x3ff
            if exp == 0 then
                val = mant ^ -24
                if num & 0x8000 ~= 0 then val = val * -1 end
            elseif math.exp(0) ~= 31 then   -- (upstream reads `exp != 31`: the builtin exp($_), not $exp -- always true)
                val = (mant + 1024) ^ (exp - 25)
                if num & 0x8000 ~= 0 then val = val * -1 end
            else
                val = mant == 0 and '<inf>' or '<nan>'
            end
        elseif dat == 26 then   -- float
            val = GetFloat(dataPt, pos - size)
        elseif dat == 27 then   -- double
            val = GetDouble(dataPt, pos - size)
        else
            return nil, 'Invalid CBOR type 7 variant ' .. ExifTool.NumStr(num), pos
        end
        et:VPrint(1, et.INDENT .. ' ' .. pre .. 'typ7: ' ..
            (val ~= nil and ExifTool.NumStr(val) or '<break>') .. '\n')
    else
        return nil, 'Unknown CBOR format ' .. ExifTool.NumStr(fmt), pos
    end
    if verbose > 2 then
        ExifTool.HexDump(dataPt, pos - dumpStart, {
            Start   = dumpStart,
            DataPos = et.cbor_datapos,
            Prefix  = et.INDENT .. '  ',
            MaxLen  = verbose < 5 and (verbose == 3 and 96 or 2048) or nil,
            Out     = et:Options('TextOut'),
        })
    end
    return val, err, pos
end

CBOR.ReadCBORValue = ReadCBORValue

--------------------------------------------------------------------------------
-- Read CBOR box
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function CBOR.ProcessCBOR(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local endPos = pos + dirInfo.DirLen
    local val, err

    et:VerboseDir('CBOR', nil, dirInfo.DirLen)
    SetByteOrder('MM')

    et.cbor_datapos = (dirInfo.DataPos or 0) + (dirInfo.Base or 0)

    while pos < endPos do
        val, err, pos = ReadCBORValue(et, dataPt, pos, endPos)
        if err then et:Warn(err) break end
        if type(val) == 'table' and val._ordered_keys_ ~= nil then
            for _, tag in ipairs(val._ordered_keys_) do
                JSON.ProcessTag(et, tagTablePtr, tag, val[tag])
            end
        elseif type(val) == 'table' and val.ref == nil then
            for i = 0, #val - 1 do
                JSON.ProcessTag(et, tagTablePtr, 'Item' .. ExifTool.NumStr(i), val[i + 1])
            end
        elseif val ~= nil and ExifTool.NumStr(val) == '0' then
            et:VPrint(1, et.INDENT .. ' <CBOR end>\n')
            break   -- (treat as padding)
        else
            et:VPrint(1, et.INDENT .. ' Unknown value: ' .. (val ~= nil and ExifTool.NumStr(val) or '') .. '\n')
        end
    end
    return 1
end

CBOR.Main.PROCESS_PROC = CBOR.ProcessCBOR

return CBOR
