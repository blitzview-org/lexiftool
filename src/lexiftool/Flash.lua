--------------------------------------------------------------------------------
-- File:         lexiftool/Flash.lua
-- Ported from:  lib/Image/ExifTool/Flash.pm
--
-- Description:  Read Shockwave Flash meta information
--
-- Revisions:    05/16/2006 - P. Harvey Created
--               06/07/2007 - PH Added support for FLV (Flash Video) files
--               10/23/2008 - PH Added support for XMP in FLV and SWF
--
-- References:   1) http://www.the-labs.com/MacromediaFlash/SWF-Spec/SWFfileformat.html
--               2) http://sswf.sourceforge.net/SWFalexref.html
--               3) http://osflash.org/flv/
--               4) http://www.irisa.fr/texmex/people/dufouil/ffmpegdoxy/flv_8h.html
--               5) http://www.adobe.com/devnet/xmp/pdfs/XMPSpecificationPart3.pdf (Oct 2008)
--               6) http://www.adobe.com/devnet/swf/pdf/swf_file_format_spec_v9.pdf
--               7) http://help.adobe.com/en_US/FlashMediaServer/3.5_Deving/WS5b3ccc516d4fbf351e63e3d11a0773d56e-7ff6.html
--               8) http://www.adobe.com/devnet/flv/pdf/video_file_format_spec_v10.pdf
--
-- Notes:        I'll add AMF3 support if someone sends me a FLV with AMF3 data
--
-- Port notes:   read-only subset (SWF header + FlashAttributes/XMP tag scan,
--               including zlib-compressed CWS files through the
--               ExifTool.inflateInit stream, and the FLV container + AMF
--               Meta packet reader).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str
local length = require('lexiftool.perl').length
local perlTruthy = require('lexiftool.perl').truthy
local ucfirst = require('lexiftool.perl').ucfirst

local Flash = {}

-- information extracted from SWF header
Flash.Main = {
    GROUPS = { [2] = 'Video' },
    VARS = { ALPHA_FIRST = 1 },
    NOTES = [[
        The information below is extracted from SWF (Shockwave Flash) files.  Tags
        with string ID's represent information extracted from the file header.
    ]],
    FlashVersion = { },
    Compressed   = { PrintConv = { [0] = 'False', [1] = 'True' } },
    ImageWidth   = { },
    ImageHeight  = { },
    FrameRate    = { },
    FrameCount   = { },
    Duration = {
        Notes = 'calculated from FrameRate and FrameCount',
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [69] = {
        Name = 'FlashAttributes',
        PrintConv = { BITMASK = {
            [0] = 'UseNetwork',
            [3] = 'ActionScript3',
            [4] = 'HasMetadata',
        } },
    },
    [77] = {
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

-- packets in Flash Video files
Flash.FLV = {
    NOTES = [[
        Information is extracted from the following packets in FLV (Flash Video)
        files.
    ]],
    [0x08] = {
        Name = 'Audio',
        BitMask = 0x04,
        SubDirectory = { TagTable = 'lexiftool.Flash.Audio' },
    },
    [0x09] = {
        Name = 'Video',
        BitMask = 0x01,
        SubDirectory = { TagTable = 'lexiftool.Flash.Video' },
    },
    [0x12] = {
        Name = 'Meta',
        SubDirectory = { TagTable = 'lexiftool.Flash.Meta' },
    },
}

-- tags in Flash Video packet header
Flash.Audio = {
    PROCESS_PROC = require('lexiftool.FLAC').ProcessBitStream,
    GROUPS = { [2] = 'Audio' },
    NOTES = 'Information extracted from the Flash Audio header.',
    ['Bit0-3'] = {
        Name = 'AudioEncoding',
        PrintConv = {
            [0] = 'PCM-BE (uncompressed)', -- PCM-BE according to ref 8
            [1] = 'ADPCM',
            [2] = 'MP3',
            [3] = 'PCM-LE (uncompressed)', --8
            [4] = 'Nellymoser 16kHz Mono', --8
            [5] = 'Nellymoser 8kHz Mono',
            [6] = 'Nellymoser',
            [7] = 'G.711 A-law logarithmic PCM', --8
            [8] = 'G.711 mu-law logarithmic PCM', --8
            -- (9 is reserved, ref 8)
            [10] = 'AAC', --8
            [11] = 'Speex', --8
            [13] = 'MP3 8-Khz', --8
            [15] = 'Device-specific sound', --8
        },
    },
    ['Bit4-5'] = {
        Name = 'AudioSampleRate',
        ValueConv = {
            [0] = 5512,
            [1] = 11025,
            [2] = 22050,
            [3] = 44100,
        },
    },
    ['Bit6'] = {
        Name = 'AudioBitsPerSample',
        ValueConv = function(_self, val) return 8 * (val + 1) end,
    },
    ['Bit7'] = {
        Name = 'AudioChannels',
        ValueConv = function(_self, val) return val + 1 end,
        PrintConv = {
            [1] = '1 (mono)',
            [2] = '2 (stereo)',
        },
    },
}

-- tags in Flash Video packet header
Flash.Video = {
    PROCESS_PROC = require('lexiftool.FLAC').ProcessBitStream,
    GROUPS = { [2] = 'Video' },
    NOTES = 'Information extracted from the Flash Video header.',
    ['Bit4-7'] = {
        Name = 'VideoEncoding',
        PrintConv = {
            [1] = 'JPEG', --8
            [2] = 'Sorensen H.263',
            [3] = 'Screen Video',
            [4] = 'On2 VP6',
            [5] = 'On2 VP6 Alpha', --3
            [6] = 'Screen Video 2', --3
            [7] = 'H.264', --7 (called "AVC" by ref 8)
        },
    },
}

-- tags in Flash META packet (in ActionScript Message Format)
Flash.Meta = {
    GROUPS = { [2] = 'Video' },
    NOTES = [[
        Below are a few observed FLV Meta tags, but ExifTool will attempt to extract
        information from any tag found.
    ]],
    audiocodecid  = { Name = 'AudioCodecID',    Groups = { [2] = 'Audio' } },
    audiodatarate = {
        Name = 'AudioBitrate',
        Groups = { [2] = 'Audio' },
        ValueConv = function(_self, val) return val * 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    audiodelay    = { Name = 'AudioDelay',      Groups = { [2] = 'Audio' } },
    audiosamplerate = { Name = 'AudioSampleRate', Groups = { [2] = 'Audio' } },
    audiosamplesize = { Name = 'AudioSampleSize', Groups = { [2] = 'Audio' } },
    audiosize     = { Name = 'AudioSize',       Groups = { [2] = 'Audio' } },
    bytelength    = 'ByteLength', -- (youtube)
    canseekontime = 'CanSeekOnTime', -- (youtube)
    canSeekToEnd  = 'CanSeekToEnd',
    creationdate  = {
        -- (not an AMF date type in my sample)
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('[ \t\n\r\f\v]+$', '')) end, -- trim trailing whitespace
    },
    createdby     = 'CreatedBy', --7
    cuePoints     = {
        Name = 'CuePoint',
        SubDirectory = { TagTable = 'lexiftool.Flash.CuePoint' },
    },
    datasize      = 'DataSize',
    duration = {
        Name = 'Duration',
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    filesize      = 'FileSizeBytes',
    framerate     = {
        Name = 'FrameRate',
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    hasAudio      = { Name = 'HasAudio',        Groups = { [2] = 'Audio' } },
    hasCuePoints  = 'HasCuePoints',
    hasKeyframes  = 'HasKeyFrames',
    hasMetadata   = 'HasMetadata',
    hasVideo      = 'HasVideo',
    height        = 'ImageHeight',
    httphostheader = 'HTTPHostHeader', -- (youtube)
    keyframesTimes = 'KeyFramesTimes',
    keyframesFilepositions = 'KeyFramePositions',
    lasttimestamp = 'LastTimeStamp',
    lastkeyframetimestamp = 'LastKeyFrameTime',
    metadatacreator = 'MetadataCreator',
    metadatadate  = {
        Name = 'MetadataDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    purl          = 'URL', -- (youtube) (what does P mean?)
    pmsg          = 'Message', -- (youtube) (what does P mean?)
    sourcedata    = 'SourceData', -- (youtube)
    starttime     = { -- (youtube)
        Name = 'StartTime',
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    stereo        = { Name = 'Stereo',          Groups = { [2] = 'Audio' } },
    -- luacheck: push ignore 314
    totalduration = { -- (youtube)
        Name = 'TotalDuration',
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    totaldatarate = { -- (youtube)
        Name = 'TotalDataRate',
        ValueConv = function(_self, val) return val * 1000 end,
        PrintConv = function(_self, val) return math.floor(val + 0.5) end,
    },
    -- (upstream lists 'totalduration' twice; the later plain entry wins)
    totalduration = 'TotalDuration',
    -- luacheck: pop
    videocodecid  = 'VideoCodecID',
    videodatarate = {
        Name = 'VideoBitrate',
        ValueConv = function(_self, val) return val * 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    videosize     = 'VideoSize',
    width         = 'ImageWidth',
    -- tags in 'onXMPData' packets
    liveXML       = { --5
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

-- tags in Flash META CuePoint structure
Flash.CuePoint = {
    GROUPS = { [2] = 'Video' },
    NOTES = [[
        These tag names are added to the CuePoint name to generate complete tag
        names like "CuePoint0Name".
    ]],
    name = 'Name',
    type = 'Type',
    time = 'Time',
    parameters = {
        Name = 'Parameter',
        SubDirectory = { TagTable = 'lexiftool.Flash.Parameter' },
    },
}

-- tags in Flash META CuePoint Parameter structure
Flash.Parameter = {
    GROUPS = { [2] = 'Video' },
    NOTES = [[
        There are no pre-defined parameter tags, but ExifTool will extract any
        existing parameters, with tag names like "CuePoint0ParameterXxx".
    ]],
}

-- name lookup for known AMF data types
local amfType = { 'double', 'boolean', 'string', 'object', 'movieClip', 'null',
    'undefined', 'reference', 'mixedArray', 'objectEnd', 'array', 'date',
    'longString', 'unsupported', 'recordSet', 'XML', 'typedObject', 'AMF3data' }

-- test for AMF structure types (object, mixed array or typed object)
local isStruct = { [0x03] = 1, [0x08] = 1, [0x10] = 1 }

-- Meta packets that we process
local processMetaPacket = { onMetaData = 1, onXMPData = 1 }

-- Handle a found flash tag (upstream FoundFlashTag)
-- Inputs: 0) ExifTool ref, 1) tag ID, 2) value
local function FoundFlashTag(et, tag, val)
    et:HandleTag(Flash.Main, tag, val)
end

-- Convert an ASCII bit string ("0101...") to an integer (upstream
-- `unpack('N', pack('B32', '0' x (32 - length $_) . $_))`)
local function bitStrToInt(bits)
    local v = 0
    for i = 1, #bits do
        v = v * 2 + (bits:byte(i) == 0x31 and 1 or 0)
    end
    return v
end

-- Read data from possibly compressed file
-- Inputs: 0) RAF reference, 1) data buffer, 2) bytes to read, 2) compressed flag
-- Returns: number of bytes read (may be greater than requested bytes if compressed)
-- - concatenates data to current buffer
-- - updates compressed flag with reference to inflate object for future calls
--   (or sets to error message and returns zero on error)
-- (upstream modifies its arguments 1 and 3 in place; here both are boxes,
--  { value })
local function ReadCompressed(raf, buffRef, len, inflateRef)
    local inflate = inflateRef[1]
    local n, buff = raf:Read(len)
    if n == 0 then
        inflateRef[1] = 'Error reading file'
        return 0
    end
    -- uncompress if necessary
    if perlTruthy(inflate) then
        if type(inflate) ~= 'table' then
            if not ExifTool.hasZlib() then   -- (`eval { require Compress::Zlib }`)
                inflateRef[1] = 'Install Compress::Zlib to extract compressed information'
                return 0
            end
            inflate = ExifTool.inflateInit()
            if not inflate then
                inflateRef[1] = 'Error initializing inflate for Flash data'
                return 0
            end
            inflateRef[1] = inflate -- pass inflate object back to caller
        end
        local tmp = buff
        buff = ''
        -- read 64 more bytes at a time and inflate until we get enough uncompressed data
        while true do
            local dat, stat = inflate:inflate(tmp)
            if stat == ExifTool.Z_STREAM_END or
               stat == ExifTool.Z_OK
            then
                buff = buff .. dat -- add inflated data to buffer
                if length(buff) >= len or stat == ExifTool.Z_STREAM_END then break end
                local n2
                n2, tmp = raf:Read(64)
                if n2 == 0 then break end -- must read a bit more data
            else
                buff = ''
                break
            end
        end
        if length(buff) == 0 then inflateRef[1] = 'Error inflating compressed Flash data' end
    end
    if buffRef[1] ~= nil then buffRef[1] = buffRef[1] .. buff else buffRef[1] = buff end
    return length(buff)
end

-- Process Flash Video AMF Meta packet (ref 5)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
--         3) Set to extract single type/value only
-- Returns: 1 on success, (or type/value if extracting single value)
-- Notes: Updates DataPos in dirInfo if extracting single value
function Flash.ProcessMeta(et, dirInfo, tagTablePtr, single)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = dirInfo.DirLen or #dataPt
    local pos = dirInfo.Pos or 0
    local type_
    local val

    if not single then
        et:VerboseDir('Meta')
    end

    local rec = 0
    while true do
        if pos >= dirLen then break end
        type_ = dataPt:byte(pos + 1)
        pos = pos + 1
        if type_ == 0x00 or type_ == 0x0b then -- double or date
            if pos + 8 > dirLen then break end
            val = ExifTool.GetDouble(dataPt, pos)
            pos = pos + 8
            if type_ == 0x0b then -- date
                val = val / 1000 -- convert to seconds
                -- get time zone
                if pos + 2 > dirLen then break end
                local tz = ExifTool.Get16s(dataPt, pos)
                pos = pos + 2
                -- construct date/time string
                val = ExifTool.ConvertUnixTime(val, 0, 6)
                -- add timezone
                if tz < 0 then
                    val = val .. '-'
                    tz = -tz
                else
                    val = val .. '+'
                end
                val = val .. sprintf('%.2d:%.2d', math.floor(tz / 60), tz % 60)
            end
        elseif type_ == 0x01 then -- boolean
            if pos + 1 > dirLen then break end
            val = dataPt:byte(pos + 1)
            if val < 2 then val = ({ [0] = 'No', [1] = 'Yes' })[val] end
            pos = pos + 1
        elseif type_ == 0x02 then -- string
            if pos + 2 > dirLen then break end
            local len = ExifTool.Get16u(dataPt, pos)
            if pos + 2 + len > dirLen then break end
            val = substr(dataPt, pos + 2, len)
            pos = pos + 2 + len
        elseif isStruct[type_] then -- object, mixed array or typed object
            local getName
            val = '' -- dummy value
            if type_ == 0x08 then -- mixed array
                -- skip last array index for mixed array
                if pos + 4 > dirLen then break end
                pos = pos + 4
            elseif type_ == 0x10 then -- typed object
                getName = true
            end
            while true do
                -- get tag ID (or typed object name)
                if pos + 2 > dirLen then break end
                local len = ExifTool.Get16u(dataPt, pos)
                if pos + 2 + len > dirLen then
                    et:Warn('Truncated ' .. (amfType[type_ + 1] or type_) .. ' record')
                    break
                end
                local tag = substr(dataPt, pos + 2, len)
                pos = pos + 2 + len
                -- first string of a typed object is the object name
                if getName then
                    getName = nil
                    goto continue
                end
                local subTablePtr = tagTablePtr
                local tagInfo = subTablePtr[tag]
                -- switch to subdirectory table if necessary
                if tagInfo and tagInfo.SubDirectory then
                    local subTable = tagInfo.SubDirectory.TagTable
                    -- descend into Flash SubDirectory
                    if subTable:match('^lexiftool%.Flash%.') then
                        tag = tagInfo.Name -- use our name for the tag
                        subTablePtr = et:GetTagTable(subTable)
                    end
                end
                -- get object value
                local valPos = pos + 1
                dirInfo.Pos = pos
                local structName = dirInfo.StructName
                -- add structure name to start of tag name
                if structName then tag = structName .. ucfirst(tag) end
                dirInfo.StructName = tag -- set new structure name
                local t, v = Flash.ProcessMeta(et, dirInfo, subTablePtr, true)
                dirInfo.StructName = structName -- restore original structure name
                pos = dirInfo.Pos -- update to new position in packet
                -- all done if this value contained tags
                if not (t ~= nil and v ~= nil) then break end
                if isStruct[t] then goto continue end -- already handled tags in sub-structures
                if type(v) == 'table' and v[1] == nil and #v == 0 then goto continue end -- ignore empty arrays
                if t == 0x09 then break end -- (end of object)
                if not subTablePtr[tag] and tag:match('^[A-Za-z0-9]+$') then
                    et:AddTagToTable(subTablePtr, tag, { Name = ucfirst(tag) })
                end
                et:HandleTag(subTablePtr, tag, v, {
                    DataPt = dataPt,
                    DataPos = dataPos,
                    Start = valPos,
                    Size = pos - valPos,
                    Format = amfType[t + 1] or sprintf('0x%x', t),
                })
                ::continue::
            end
        elseif type_ == 0x05 or type_ == 0x06 or type_ == 0x09 or type_ == 0x0d then
            -- null, undefined, dirLen of object, or unsupported
            val = ''
        elseif type_ == 0x07 then -- reference
            if pos + 2 > dirLen then break end
            val = ExifTool.Get16u(dataPt, pos)
            pos = pos + 2
        elseif type_ == 0x0a then -- array
            if pos + 4 > dirLen then break end
            local num = ExifTool.Get32u(dataPt, pos)
            dirInfo.Pos = pos + 4
            local vals = {}
            -- add array index to compound tag name
            local structName = dirInfo.StructName
            for i = 0, num - 1 do
                if structName then dirInfo.StructName = structName .. i end
                local t, v = Flash.ProcessMeta(et, dirInfo, tagTablePtr, true)
                if v == nil then break end
                -- save value unless contained in a sub-structure
                if not isStruct[t] then vals[#vals + 1] = v end
            end
            dirInfo.StructName = structName
            pos = dirInfo.Pos
            val = vals
        elseif type_ == 0x0c or type_ == 0x0f then -- long string or XML
            if pos + 4 > dirLen then break end
            local len = ExifTool.Get32u(dataPt, pos)
            if pos + 4 + len > dirLen then break end
            val = substr(dataPt, pos + 4, len)
            pos = pos + 4 + len
        else
            local t = amfType[type_ + 1] or sprintf('type 0x%x', type_)
            et:Warn('AMF ' .. t .. ' record not yet supported')
            type_ = nil -- (so we don't print another warning)
            break -- can't continue
        end
        if single then break end -- all done if extracting single value
        if not isStruct[type_] then
            -- only process certain Meta packets
            if type_ == 0x02 and rec == 0 then
                local verb = processMetaPacket[val] and 'processing' or 'ignoring'
                et:VPrint(0, '  | (' .. verb .. ' ' .. val .. ' information)\n')
                if not processMetaPacket[val] then break end
            else
                -- give verbose indication if we ignore a lone value
                local t = amfType[type_ + 1] or sprintf('type 0x%x', type_)
                et:VPrint(1, "  | (ignored lone " .. t .. " value '" .. str(val) .. "')\n")
            end
        end
        rec = rec + 1
    end
    if val == nil and type_ ~= nil then
        et:Warn(sprintf('Truncated AMF record 0x%x', type_))
    end
    if single then
        dirInfo.Pos = pos -- update position
        return type_, val -- return single type/value pair
    end
    return 1
end

-- Read information from a Flash Video file (upstream ProcessFLV)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid Flash Video file
function Flash.ProcessFLV(et, dirInfo)
    local verbose = et:Options('Verbose')
    local raf = dirInfo.RAF

    local n, buff = raf:Read(9)
    if n ~= 9 then return 0 end
    if buff:sub(1, 4) ~= 'FLV\1' then return 0 end
    ExifTool.SetByteOrder('MM')
    et:SetFileType()
    -- (upstream: `unpack('x4CN', $buff)` -- byte 4 (0-based) is the flags,
    --  bytes 5-8 are the data offset, big-endian)
    local flags = buff:byte(5)
    local offset = ExifTool.Get32u(buff, 5)
    if offset > 9 then
        if not raf:Seek(offset - 9, 1) then return 1 end
    end
    flags = flags & 0x05 -- only look for audio/video
    local found = 0
    local tagTablePtr = et:GetTagTable('lexiftool.Flash.FLV')
    while true do
        local n2, buff2 = raf:Read(15)
        if n2 ~= 15 then break end
        -- (upstream: `unpack('x4N', $buff)` -- bytes 4-7 are the
        --  little-endian? no, big-endian type/len field)
        local len = ExifTool.Get32u(buff2, 4)
        local type_ = len >> 24
        len = len & 0x00ffffff
        local tagInfo = et:GetTagInfo(tagTablePtr, type_)
        if verbose and verbose > 1 then
            local name = tagInfo and tagInfo.Name or ('type ' .. type_)
            et:VPrint(1, 'FLV ' .. name .. ' packet, len ' .. len .. '\n')
        end
        buff = nil
        if tagInfo and tagInfo.SubDirectory then
            local mask = tagInfo.BitMask
            if mask then
                -- handle audio or video packet
                if (found & mask) == 0 then
                    found = found | mask
                    flags = flags & ~mask
                    if len >= 1 then
                        local n3, b3 = raf:Read(1)
                        if n3 == 1 then
                            buff = b3
                            len = len - 1
                        else
                            et:Warn('Bad ' .. tagInfo.Name .. ' packet')
                            break
                        end
                    end
                end
            else
                local n3, b3 = raf:Read(len)
                if n3 == len then
                    buff = b3
                    len = 0
                else
                    et:Warn('Truncated Meta packet')
                    break
                end
            end
        else
            -- (a plain non-subdirectory tag: discard the payload)
            if len ~= 0 and not raf:Seek(len, 1) then break end
            len = 0
        end
        if buff ~= nil then
            et:HandleTag(tagTablePtr, type_, nil, {
                DataPt = buff,
                DataPos = raf:Tell() - #buff,
                Size = #buff,
            })
        end
        if flags == 0 then break end
        if len ~= 0 and not raf:Seek(len, 1) then break end
    end
    return 1
end

-- Extract information from a Flash file (upstream ProcessSWF)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid Flash file
function Flash.ProcessSWF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    local sig = buff:sub(1, 3)
    if (sig ~= 'FWS' and sig ~= 'CWS') or buff:byte(4) == 0 then return 0 end -- (`/^(F|C)WS([^\0])/`)
    local compressed = sig:sub(1, 1) == 'C' and 1 or 0
    local vers = buff:byte(4)

    ExifTool.SetByteOrder('II')
    et:SetFileType()
    et:GetTagTable('lexiftool.Flash.Main') -- make sure table is initialized

    FoundFlashTag(et, 'FlashVersion', vers)
    FoundFlashTag(et, 'Compressed', compressed)

    -- read the next 64 bytes of the file (and inflate if necessary)
    local buffRef = { '' }
    local inflateRef = { compressed }
    if ReadCompressed(raf, buffRef, 64, inflateRef) == 0 then
        if perlTruthy(inflateRef[1]) then et:Warn(inflateRef[1]) end
        return 1
    end
    buff = buffRef[1]

    -- unpack elements of bit-packed Flash Rect structure
    local nBits = buff:byte(1) >> 3 -- bits in x1,x2,y1,y2 elements
    local totBits = 5 + nBits * 4 -- total bits in Rect structure
    local nBytes = math.floor((totBits + 7) / 8) -- byte length of Rect structure
    if #buff < nBytes + 4 then
        et:Warn('Truncated Flash file')
        return 1
    end
    -- build an ASCII bit string of the first totBits bits (upstream
    -- `unpack("B$totBits", $buff)`, big-endian bit order)
    local bits = {}
    for i = 1, totBits do
        local byte = buff:byte(math.floor((i - 1) / 8) + 1) or 0
        local shift = 7 - ((i - 1) % 8)
        bits[#bits + 1] = ((byte >> shift) & 1) == 1 and '1' or '0'
    end
    bits = table.concat(bits)
    -- isolate Rect elements (skip the 5-bit nBits field, then 4 x nBits)
    local vals = {}
    for i = 0, 3 do
        local start = 5 + i * nBits + 1
        vals[i + 1] = bitStrToInt(bits:sub(start, start + nBits - 1))
    end

    -- calculate and store ImageWidth/Height
    FoundFlashTag(et, 'ImageWidth', (vals[2] - vals[1]) / 20)
    FoundFlashTag(et, 'ImageHeight', (vals[4] - vals[3]) / 20)

    -- get frame rate and count (2 little-endian uint16 after the Rect)
    local fr0 = buff:byte(nBytes + 1) or 0
    local fr1 = buff:byte(nBytes + 2) or 0
    local fc0 = buff:byte(nBytes + 3) or 0
    local fc1 = buff:byte(nBytes + 4) or 0
    local frameRate = fr0 + fr1 * 256
    local frameCount = fc0 + fc1 * 256
    FoundFlashTag(et, 'FrameRate', frameRate / 256)
    FoundFlashTag(et, 'FrameCount', frameCount)
    if frameRate ~= 0 then
        FoundFlashTag(et, 'Duration', frameCount * 256 / frameRate)
    end

    -- scan through the tags to find FlashAttributes and XMP
    buff = substr(buff, nBytes + 4)
    local hasMeta
    while true do
        local buffLen = length(buff)
        if buffLen < 2 then break end
        local code = ExifTool.Get16u(buff, 0)
        local pos = 2
        local tag = code >> 6
        local size = code & 0x3f
        et:VPrint(1, 'SWF tag ' .. tag .. ' (' .. size .. ' bytes):\n')
        if not (tag == 69 or tag == 77 or hasMeta) then break end
        -- read enough to get a complete short record
        if pos + size > buffLen then
            -- (read 2 extra bytes if available to get next tag word)
            buffRef[1] = buff
            if ReadCompressed(raf, buffRef, size + 2, inflateRef) == 0 then
                if perlTruthy(inflateRef[1]) then et:Warn(inflateRef[1]) end
                return 1
            end
            buff = buffRef[1]
            buffLen = length(buff)
            if pos + size > buffLen then break end
        end
        -- read extended record if necessary
        if size == 0x3f then
            if pos + 4 > buffLen then break end
            size = ExifTool.Get32u(buff, pos)
            pos = pos + 4
            if size > 1000000 then break end -- don't read anything huge
            if pos + size > buffLen then
                buffRef[1] = buff
                if ReadCompressed(raf, buffRef, size + 2, inflateRef) == 0 then
                    if perlTruthy(inflateRef[1]) then et:Warn(inflateRef[1]) end
                    return 1
                end
                buff = buffRef[1]
                buffLen = length(buff)
                if pos + size > buffLen then break end
            end
            et:VPrint(1, '  [extended size ' .. size .. ' bytes]\n')
        end
        if tag == 69 then -- FlashAttributes
            if size == 0 then break end
            local flags = ExifTool.Get8u(buff, pos)
            FoundFlashTag(et, tag, flags)
            if (flags & 0x10) == 0 then break end -- only continue if we have metadata (XMP)
            hasMeta = 1
        elseif tag == 77 then -- Metadata
            local val = substr(buff, pos, size)
            FoundFlashTag(et, tag, val)
            break
        end
        if pos + 2 > buffLen then break end
        buff = substr(buff, pos) -- remove everything before the next tag
    end
    return 1
end

-- (PROCESS_PROC forward references: the Meta/CuePoint/Parameter tables are
--  defined above, before ProcessMeta -- set the process procs after the
--  function exists, mirroring upstream's table-headers)
Flash.Meta.PROCESS_PROC = Flash.ProcessMeta
Flash.CuePoint.PROCESS_PROC = Flash.ProcessMeta
Flash.Parameter.PROCESS_PROC = Flash.ProcessMeta

return Flash
