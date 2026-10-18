--------------------------------------------------------------------------------
-- File:         lexiftool/DNG.lua
-- Ported from:  lib/Image/ExifTool/DNG.pm
--
-- Description:  Read DNG-specific information
--
-- Revisions:    01/09/2006 - P. Harvey Created
--
-- References:   1) http://www.adobe.com/products/dng/
--
-- Port notes:   Complete port of DNG.pm: every table and sub, in upstream
--               order, read and write (WriteAdobeStuff is AdobeData's
--               WRITE_PROC as upstream).  Deviations forced by Lua:
--               - The predeclarations `sub ProcessOriginalRaw($$$);` ... are
--                 one block of locals at the top; the subs assign to them
--                 (and are exported on the module table), and the
--                 PROCESS_PROC/WRITE_PROC/ProcessProc/WriteProc entries are
--                 `false` placeholders filled in after the subs.
--               - `use Image::ExifTool::CanonRaw` (for %crwTagFormat and the
--                 maker-note builders) is a require at the call sites, as are
--                 Fixup, MinoltaRaw and WriteExif's RebuildMakerNotes; the
--                 maker notes are copied into AdobeData from
--                 MakerNotes.Main at load time, as upstream does.
--               - An output buffer (`$$outfile`) is a box `{ value = ... }`
--                 holding a carray (doc/api.md §4).
--               - Compress::Zlib is ExifTool hasZlib/inflate.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')              -- (upstream `use Image::ExifTool::Exif`)
local MakerNotes = require('lexiftool.MakerNotes')  -- (upstream `use Image::ExifTool::MakerNotes`)
-- (upstream `use Image::ExifTool::CanonRaw`: required at the call sites)
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local carray = require('carray')
local isMatch = perl.isMatch
local tr = perl.tr
local lc = perl.lc
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local pack = perl.pack
local unpack = perl.unpack
local int = perl.int
local truthy = perl.truthy
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local Set16u = ExifTool.Put16u
local Set32u = ExifTool.Put32u
local SetByteOrder = ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local GetTagTable = ExifTool.GetTagTable

local DNG = {}

-- (upstream's predeclarations `sub ProcessOriginalRaw($$$);` ... are this
--  block of locals; the subs below assign to them)
local ProcessOriginalRaw, ProcessAdobeData, ProcessAdobeMakN, ProcessAdobeCRW
local ProcessAdobeRAF, ProcessAdobeMRW, ProcessAdobeSR2, ProcessAdobeIFD
local WriteAdobeStuff

-- data in OriginalRawFileData
DNG.OriginalRaw = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        This table defines tags extracted from the DNG OriginalRawFileData
        information.
    ]],
    [0] = { Name = 'OriginalRawImage',    Binary = 1 },
    [1] = { Name = 'OriginalRawResource', Binary = 1 },
    [2] = 'OriginalRawFileType',
    [3] = 'OriginalRawCreator',
    [4] = { Name = 'OriginalTHMImage',    Binary = 1 },
    [5] = { Name = 'OriginalTHMResource', Binary = 1 },
    [6] = 'OriginalTHMFileType',
    [7] = 'OriginalTHMCreator',
}

DNG.AdobeData = { --PH
    GROUPS = { [0] = 'MakerNotes', [1] = 'AdobeDNG', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false,   -- predeclaration, see below for implementation
    NOTES = [[
        This information is found in the "Adobe" DNGPrivateData.

        The maker notes ('MakN') are processed by ExifTool, but some information may
        have been lost by the Adobe DNG Converter.  This is because the Adobe DNG
        Converter (as of version 6.3) doesn't properly handle information referenced
        from inside the maker notes that lies outside the original maker notes
        block.  This information is lost when only the maker note block is copied to
        the DNG image.   While this doesn't effect all makes of cameras, it is a
        problem for some major brands such as Olympus and Sony.

        Other entries in this table represent proprietary information that is
        extracted from the original RAW image and restructured to a different (but
        still proprietary) Adobe format.
    ]],
    MakN  = { },   -- (filled in later)
   ['CRW '] = {
        Name = 'AdobeCRW',
        SubDirectory = {
            TagTable = 'lexiftool.CanonRaw.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeCRW)
            WriteProc = false,   -- predeclaration, see below (WriteAdobeStuff)
        },
    },
   ['MRW '] = {
        Name = 'AdobeMRW',
        SubDirectory = {
            TagTable = 'lexiftool.MinoltaRaw.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeMRW)
            WriteProc = false,   -- predeclaration, see below (WriteAdobeStuff)
        },
    },
   ['SR2 '] = {
        Name = 'AdobeSR2',
        SubDirectory = {
            TagTable = 'lexiftool.Sony.SR2Private',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeSR2)
        },
    },
   ['RAF '] = {
        Name = 'AdobeRAF',
        SubDirectory = {
            TagTable = 'lexiftool.FujiFilm.RAF',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeRAF)
        },
    },
    ['Pano'] = {
        Name = 'AdobePano',
        SubDirectory = {
            TagTable = 'lexiftool.PanasonicRaw.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeIFD)
        },
    },
    ['Koda'] = {
        Name = 'AdobeKoda',
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.IFD',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeIFD)
        },
    },
    ['Leaf'] = {
        Name = 'AdobeLeaf',
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.SubIFD',
            ProcessProc = false, -- predeclaration, see below (ProcessAdobeIFD)
        },
    },
}

-- (DNG 1.7)
DNG.ImageSeq = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0] = { Name = 'SeqID',         Format = 'var_string' },
    [1] = { Name = 'SeqType',       Format = 'var_string' },
    [2] = { Name = 'SeqFrameInfo',  Format = 'var_string' },
    [3] = { Name = 'SeqIndex',      Format = 'int32u' },
    [7] = { Name = 'SeqCount',      Format = 'int32u' },
    [11] = { Name = 'SeqFinal',     Format = 'int8u', PrintConv = { [0] = 'No', [1] = 'Yes' } },
}

-- (DNG 1.7)
DNG.ProfileDynamicRange = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0] = { Name = 'PDRVersion',    Format = 'int16u' },
    [2] = { Name = 'DynamicRange',  Format = 'int16u', PrintConv = { [0] = 'Standard', [1] = 'High' } },
    [4] = { Name = 'HintMaxOutputValue', Format = 'float' },
}

-- fill in maker notes
do
    local list = DNG.AdobeData.MakN
    for _, tagInfo in ipairs(MakerNotes.Main) do
        if type(tagInfo) ~= 'table' then
            list[#list + 1] = tagInfo
            goto continue
        end
        local copy = { }
        for k, v in pairs(tagInfo) do copy[k] = v end
        copy.Groups = nil
        copy.GotGroups = nil
        copy.Table = nil
        list[#list + 1] = copy
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Process DNG OriginalRawFileData information
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function ProcessOriginalRaw(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local end_ = start + dirInfo.DirLen
    local pos = start
    local index, err

    SetByteOrder('MM') -- pointers are always big-endian in this structure
    index = 0
    while index < 8 do
        if pos + 4 > end_ then break end
        local val = Get32u(dataPt, pos)
        if not truthy(val) then pos = pos + 4 goto continue end -- ignore zero values
        do
            local tagInfo = et:GetTagInfo(tagTablePtr, index)
            if not tagInfo then err = 'Missing DNG tag ' .. index break end
            if (index & 0x02) ~= 0 then
                -- extract a simple file type (tags 2, 3, 6 and 7)
                val = substr(dataPt, pos, 4)
                pos = pos + 4
            else
                -- extract a compressed data block (tags 0, 1, 4 and 5)
                local n = int((val + 65535) / 65536)
                local hdrLen = 4 * (n + 2)
                if pos + hdrLen > end_ then err = '' break end
                local tag = tagInfo.Name
                -- only extract this information if requested (because it takes time)
                local lcTag = lc(tag)
                if (truthy(et.OPTIONS.Binary) and not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP[lcTag])) or
                    (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lcTag])
                then
                    if not et:hasZlib() then   -- (`eval { require Compress::Zlib }`)
                        err = 'Install Compress::Zlib to extract compressed images'
                        break
                    end
                    local i = 0
                    val = ''
                    local p2 = pos + Get32u(dataPt, pos + 4)
                    while i < n do
                        -- inflate this compressed block
                        local p1 = p2
                        p2 = pos + Get32u(dataPt, pos + (i + 2) * 4)
                        if p1 >= p2 or p2 > end_ then
                            err = 'Bad compressed RAW image'
                            break
                        end
                        local buff = substr(dataPt, p1, p2 - p1)
                        local v2, stat = et:inflate(buff)
                        if stat then   -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                            val = val .. v2
                        else
                            err = 'Error inflating compressed RAW image'
                            break
                        end
                        i = i + 1
                    end
                    pos = p2
                else
                    if pos + hdrLen > end_ then err = '' break end
                    local len = Get32u(dataPt, pos + hdrLen - 4)
                    if pos + len > end_ then err = '' break end
                    val = substr(dataPt, pos + hdrLen, len - hdrLen) -- luacheck: ignore 311 (dead upstream line, carried)
                    val = 'Binary data ' .. len .. ' bytes'
                    pos = pos + len   -- skip over this block
                end
            end
            et:FoundTag(tagInfo, val)
        end
        ::continue::
        index = index + 1
    end
    if err ~= nil then et:Warn(truthy(err) and err or 'Bad OriginalRawFileData') end
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe DNGPrivateData directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessAdobeData(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local pos = dirInfo.DirStart
    local end_ = dirInfo.DirLen + pos
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local htmlDump = et:Options('HtmlDump')

    if not isMatch(dataPt, [[^Adobe\0]]) then return 0 end
    if not outfile then
        et:VerboseDir(dirInfo)
        -- don't parse makernotes if FastScan > 1
        local fast = et:Options('FastScan')
        if truthy(fast) and fast > 1 then return 1 end
    end
    if truthy(htmlDump) then et:HDump(dataPos, 6, 'Adobe DNGPrivateData header') end
    SetByteOrder('MM') -- always big endian
    pos = pos + 6
    while pos + 8 <= end_ do
        local tag, size = unpack('x' .. pos .. 'a4N', dataPt)
        pos = pos + 8
        if pos + size > end_ then break end
        local tagInfo = tagTablePtr[tag]
        if truthy(htmlDump) then
            local name = 'Adobe' .. tag
            name = tr(name, ' ', '', 'd')
            et:HDump(dataPos + pos - 8, 8, name .. ' header', 'Data Size: ' .. size .. ' bytes')
            -- dump non-EXIF format data
            if not isMatch(tag, '^(MakN|SR2 )$') then
                et:HDump(dataPos + pos, size, name .. ' data')
            end
        end
        if truthy(verbose) and not outfile then
            if not tagInfo then et:VPrint(0, et.INDENT .. 'Unsupported DNGAdobeData record: (' .. tag .. ")\n") end
            local hashInfo   -- (`ref $tagInfo eq 'HASH' ? $tagInfo : undef`; MakN is a list)
            if tagInfo and tagInfo[1] == nil then hashInfo = tagInfo end
            et:VerboseInfo(tag, hashInfo, {
                DataPt = dataPt,
                DataPos = dataPos,
                Start = pos,
                Size = size,
            })
        end
        local value
        while tagInfo do -- luacheck: ignore 512
            local subTable, subName, processProc
            if tagInfo[1] == nil then   -- (`ref $tagInfo eq 'HASH'`)
                if not tagInfo.SubDirectory then
                    if outfile then
                        -- copy value across to outfile
                        value = substr(dataPt, pos, size)
                    else
                        et:HandleTag(tagTablePtr, tag, substr(dataPt, pos, size))
                    end
                    break
                end
                subTable = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                subName = tagInfo.Name
                processProc = tagInfo.SubDirectory.ProcessProc
            else
                subTable = tagTablePtr
                subName = 'AdobeMakN'
                processProc = ProcessAdobeMakN
            end
            local dirInfo_ = {   -- (upstream's inner `my %dirInfo`)
                Base     = dirInfo.Base,
                DataPt   = dataPt,
                DataPos  = dataPos,
                DataLen  = dirInfo.DataLen,
                DirStart = pos,
                DirLen   = size,
                DirName  = subName,
            }
            if outfile then
                dirInfo_.Proc = processProc  -- WriteAdobeStuff() calls this to do the actual writing
                value = require('lexiftool.Writer').WriteDirectory(et, dirInfo_, subTable, WriteAdobeStuff)
                -- use old directory if an error occurred
                if value == nil then value = substr(dataPt, pos, size) end
            else
                -- override process proc for MakN
                et:ProcessDirectory(dirInfo_, subTable, processProc)
            end
            break
        end
        if value ~= nil and truthy(length(value)) then
            -- add "Adobe" header if necessary
            if not (outfile.value and truthy(length(outfile.value))) then outfile.value = carray.new('char'):append("Adobe\0") end
            outfile.value:append(tag .. pack('N', length(value)) .. value)
            if (length(value) & 0x01) ~= 0 then outfile.value:append("\0") end -- pad if necessary
        end
        pos = pos + size
        if (size & 0x01) ~= 0 then pos = pos + 1 end -- (darn padding)
    end
    if pos ~= end_ then et:Warn(pos .. ' ' .. end_ .. ' Adobe private data is corrupt') end
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe CRW directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
-- Notes: data has 4 byte header (2 for byte order and 2 for entry count)
-- - this routine would be as simple as ProcessAdobeMRW() below if Adobe hadn't
--   pulled the bonehead move of reformatting the CRW information
function ProcessAdobeCRW(et, dirInfo, tagTablePtr)
    local CanonRaw = require('lexiftool.CanonRaw')
    local Writer = require('lexiftool.Writer')
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local end_ = start + dirInfo.DirLen
    local verbose = et:Options('Verbose') or 0   -- (undef compares as 0 in Perl)
    local buildMakerNotes = et:Options('MakerNotes')
    local outfile = dirInfo.OutFile
    local newTags, oldChanged

    SetByteOrder('MM') -- always big endian
    if dirInfo.DirLen < 4 then return 0 end
    local byteOrder = substr(dataPt, start, 2)
    if not isMatch(byteOrder, '^(II|MM)$') then return 0 end

    -- initialize maker note data if building maker notes
    if truthy(buildMakerNotes) then CanonRaw.InitMakerNotes(et) end

    local entries = Get16u(dataPt, start + 2)
    local pos = start + 4
    if not outfile then et:VerboseDir(dirInfo, entries) end
    if outfile then
        -- get hash of new tags
        newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
        outfile.value = carray.new('char'):append(substr(dataPt, start, 4))
        oldChanged = et.CHANGED
    end
    -- loop through entries in Adobe CRW information
    local index = 0
    while index < entries do
        if pos + 6 > end_ then break end
        local tag = Get16u(dataPt, pos)
        local size = Get32u(dataPt, pos + 2)
        pos = pos + 6
        if pos + size > end_ then break end
        local value = substr(dataPt, pos, size)
        local tagID = tag & 0x3fff
        local tagType = (tag >> 8) & 0x38   -- get tag type
        local format = CanonRaw.crwTagFormat[tagType]
        local count
        local tagInfo = et:GetTagInfo(tagTablePtr, tagID, value)
        if tagInfo then
            if tagInfo.Format then format = tagInfo.Format end
            count = tagInfo.Count
        end
        -- set count to 1 by default for values that were in the directory entry
        if count == nil and (tag & 0x4000) ~= 0 and format and format ~= 'string' then
            count = 1
        end
        -- set count from tagInfo count if necessary
        if format and not truthy(count) then
            -- set count according to format and size
            local fnum = Exif.formatNumber[format]
            local fsiz = Exif.formatSize[fnum]
            count = int(size / fsiz)
        end
        if not format then format = 'undef' end
        SetByteOrder(byteOrder)
        local val = ReadValue(value, 0, format, count, size)
        if outfile then
            if tagInfo then
                local subdir = tagInfo.SubDirectory
                if subdir and subdir.TagTable then
                    local name = tagInfo.Name
                    local newTagTable = GetTagTable(nil, subdir.TagTable)
                    if not newTagTable then return 0 end
                    local subdirStart = 0
                    --#### eval Start ()
                    if subdir.Start then
                        subdirStart = subdir.Start   -- (a number, or a function of the value here)
                        if type(subdirStart) == 'function' then subdirStart = subdirStart(value) end
                    end
                    local dirData = value
                    local subdirInfo = {
                        Name     = name,
                        DataPt   = dirData,
                        DataLen  = size,
                        DirStart = subdirStart,
                        DirLen   = size - subdirStart,
                        Parent   = dirInfo.DirName,
                    }
                    --#### eval Validate ($dirData, $subdirStart, $size)
                    if subdir.Validate ~= nil and not subdir.Validate(et, dirData, subdirStart, size) then
                        et:Warn('Invalid ' .. name .. ' data')
                    else
                        subdir = Writer.WriteDirectory(et, subdirInfo, newTagTable)
                        if subdir ~= nil and truthy(length(subdir)) then
                            if truthy(subdirStart) then
                                -- add header before data directory
                                value = substr(value, 0, subdirStart) .. subdir
                            else
                                value = subdir
                            end
                        end
                    end
                elseif newTags[tagID] then
                    local nvHash = Writer.GetNewValueHash(et, tagInfo)
                    if truthy(Writer.IsOverwriting(et, nvHash, val)) then
                        local newVal = et:GetNewValue(nvHash)
                        local verboseVal
                        if verbose > 1 then verboseVal = newVal end
                        -- convert to specified format if necessary
                        if newVal ~= nil and format then
                            newVal = Writer.WriteValue(newVal, format, count)
                        end
                        if newVal ~= nil then
                            et:VerboseValue('- CanonRaw:' .. tagInfo.Name, value)
                            et:VerboseValue('+ CanonRaw:' .. tagInfo.Name, verboseVal)
                            value = newVal
                            et.CHANGED = (et.CHANGED or 0) + 1
                        end
                    end
                end
            end
            -- write out new value (always big-endian)
            SetByteOrder('MM')
            -- (verified that there is no padding here)
            outfile.value:append(Set16u(tag) .. Set32u(length(value)) .. value)
        else
            et:HandleTag(tagTablePtr, tagID, val, {
                Index   = index,
                DataPt  = dataPt,
                DataPos = dirInfo.DataPos,
                Start   = pos,
                Size    = size,
                TagInfo = tagInfo,
            })
            if truthy(buildMakerNotes) then
                -- build maker notes information if requested
                CanonRaw.BuildMakerNotes(et, tagID, tagInfo,
                                         value, format, count)
            end
        end
        -- (we lost the directory structure, but the second tag 0x0805
        -- should be in the ImageDescription directory)
        if tagID == 0x0805 then et.DIR_NAME = 'ImageDescription' end
        SetByteOrder('MM')
        pos = pos + size
        index = index + 1
    end
    if outfile and (outfile.value == nil or index ~= entries or
        et.CHANGED == oldChanged)
    then
        et.CHANGED = oldChanged -- nothing changed
        outfile.value = nil     -- rewrite old directory
    end
    if index ~= entries then
        et:Warn('Truncated CRW notes')
    elseif pos < end_ then
        et:Warn(end_ - pos .. ' extra bytes at end of CRW notes')
    end
    -- finish building maker notes if necessary
    if truthy(buildMakerNotes) then
        SetByteOrder(byteOrder)
        CanonRaw.SaveMakerNotes(et)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe MRW directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
-- Notes: data has 4 byte header (2 for byte order and 2 for entry count)
function ProcessAdobeMRW(et, dirInfo, _tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local dirStart = dirInfo.DirStart
    local outfile = dirInfo.OutFile

    -- construct fake MRW file
    local buff = "\0MRM" .. pack('N', dirLen - 4)
    -- ignore leading byte order and directory count words
    buff = buff .. substr(dataPt, dirStart + 4, dirLen - 4)
    local raf = RandomAccess.new(buff)
    local dirInfo_ = { RAF = raf, OutFile = outfile }   -- (upstream's inner `my %dirInfo`)
    local rtnVal = require('lexiftool.MinoltaRaw').ProcessMRW(et, dirInfo_)
    if outfile and outfile.value ~= nil and truthy(length(outfile.value)) then
        -- remove MRW header and add Adobe header
        outfile.value = carray.new('char'):append(substr(dataPt, dirStart, 4), substr(outfile.value, 8))
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process Adobe RAF directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function ProcessAdobeRAF(et, dirInfo, tagTablePtr)
    if dirInfo.OutFile then return 0 end -- (can't write this yet)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local dirEnd = dirInfo.DirLen + pos
    local readIt, warn

    -- set byte order according to first 2 bytes of Adobe RAF data
    if pos + 2 <= dirEnd and SetByteOrder(substr(dataPt, pos, 2)) then
        pos = pos + 2
    else
        et:Warn('Invalid DNG RAF data')
        return 0
    end
    et:VerboseDir(dirInfo)
    -- make fake RAF object for processing (same acronym, different meaning)
    local raf = RandomAccess.new(dataPt)
    local num = ''
    -- loop through all records in Adobe RAF data:
    -- 0 - RAF table (not processed)
    -- 1 - first RAF directory
    -- 2 - second RAF directory (if available)
    while true do
        if pos + 4 > dirEnd then break end
        local len = Get32u(dataPt, pos)
        pos = pos + 4 + len -- step to next entry in Adobe RAF record
        if not truthy(len) then break end  -- ends with an empty entry
        if not readIt then readIt = 1 goto continue end -- ignore first entry (RAF table)
        do
            local dirInfo_ = {   -- (upstream's inner `my %dirInfo`)
                RAF      = raf,
                DirStart = pos - len,
            }
            et.SET_GROUP1 = 'RAF' .. num
            if not truthy(et:ProcessDirectory(dirInfo_, tagTablePtr)) then warn = 1 end
            et.SET_GROUP1 = nil
            num = (truthy(num) and num or 1) + 1
        end
        ::continue::
    end
    if warn then et:Warn('Possibly corrupt RAF information') end
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe SR2 directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
-- Notes: data has 6 byte header (2 for byte order and 4 for original offset)
function ProcessAdobeSR2(et, dirInfo, tagTablePtr)
    if dirInfo.OutFile then return 0 end -- (can't write this yet)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local len = dirInfo.DirLen

    if len < 6 then return 0 end
    SetByteOrder('MM')
    local originalPos = Get32u(dataPt, start + 2)
    if not SetByteOrder(substr(dataPt, start, 2)) then return 0 end

    et:VerboseDir(dirInfo)
    local dataPos = dirInfo.DataPos
    local dirStart = start + 6  -- pointer to maker note directory
    local dirLen = len - 6

    -- initialize subdirectory information
    local fix = dataPos + dirStart - originalPos
    local subdirInfo = {
        DirName   = 'AdobeSR2',
        Base      = dirInfo.Base + fix,
        DataPt    = dataPt,
        DataPos   = dataPos - fix,
        DataLen   = dirInfo.DataLen,
        DirStart  = dirStart,
        DirLen    = dirLen,
        Parent    = dirInfo.DirName,
    }
    if truthy(et:Options('HtmlDump')) then
        et:HDump(dataPos + start, 6, 'Adobe SR2 data')
    end
    -- parse the SR2 directory
    et:ProcessDirectory(subdirInfo, tagTablePtr)
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe-mutilated IFD directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
-- Notes: data has 2 byte header (byte order of the data)
function ProcessAdobeIFD(et, dirInfo, tagTablePtr)
    if dirInfo.OutFile then return 0 end -- (can't write this yet)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local dataPos = dirInfo.DataPos

    if dirInfo.DirLen < 4 then return 0 end
    local dataOrder = substr(dataPt, pos, 2)
    if not SetByteOrder(dataOrder) then return 0 end -- validate byte order of data

    -- parse the mutilated IFD.  This is similar to a TIFF IFD, except:
    -- - data follows directly after Count entry in IFD
    -- - byte order of IFD entries is always big-endian, but byte order of data changes
    SetByteOrder('MM')     -- IFD structure is always big-endian
    local entries = Get16u(dataPt, pos + 2)
    et:VerboseDir(dirInfo, entries)
    pos = pos + 4

    local end_ = pos + dirInfo.DirLen
    local index = 0
    while index < entries do
        if pos + 8 > end_ then break end
        SetByteOrder('MM') -- directory entries always big-endian (doh!)
        local tagID = Get16u(dataPt, pos)
        local format = Get16u(dataPt, pos + 2)
        local count = Get32u(dataPt, pos + 4)
        if format < 1 or format > 13 then
            -- warn unless the IFD was just padded with zeros
            if truthy(format) then
                et:Warn(sprintf('Unknown format (' .. format .. ') for ' .. dirInfo.DirName .. ' tag 0x%x', tagID))
            end
            return 0 -- must be corrupted
        end
        local size = Exif.formatSize[format] * count
        if pos + 8 + size > end_ then break end
        local formatStr = Exif.formatName[format]
        SetByteOrder(dataOrder)   -- data stored in native order
        local val = ReadValue(dataPt, pos + 8, formatStr, count, size)
        et:HandleTag(tagTablePtr, tagID, val, {
            Index   = index,
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = pos + 8,
            Size    = size
        })
        pos = pos + 8 + size
        index = index + 1
    end
    if index < entries then
        et:Warn('Truncated ' .. dirInfo.DirName .. ' directory')
        return 0
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Adobe MakerNotes directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
-- Notes: data has 6 byte header (2 for byte order and 4 for original offset)
--        --> or 18 bytes for DNG converted from JPG by Adobe Camera Raw!
function ProcessAdobeMakN(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local len = dirInfo.DirLen
    local outfile = dirInfo.OutFile

    if len < 6 then return 0 end
    SetByteOrder('MM')
    local originalPos = Get32u(dataPt, start + 2)
    if not SetByteOrder(substr(dataPt, start, 2)) then return 0 end

    if not outfile then et:VerboseDir(dirInfo) end
    local dataPos = dirInfo.DataPos
    local hdrLen = 6

    -- 2018-09-27: hack for extra 12 bytes in MakN header of JPEG converted to DNG
    -- by Adobe Camera Raw (4 bytes "00 00 00 01" followed by 8 unknown bytes)
    -- - this is because CameraRaw copies the maker notes from the wrong location
    --   in a JPG image (off by 12 bytes presumably due to the JPEG headers)
    -- - this hack won't work in most cases because the extra bytes are not consistent
    --   since they are just the data that existed in the JPG before the maker notes
    -- - also, the last 12 bytes of the maker notes will be missing
    -- - 2022-04-26: this bug still exists in Camera Raw 14.3
    if len >= 18 and substr(dataPt, start + 6, 4) == "\0\0\0\x01" then hdrLen = hdrLen + 12 end

    local dirStart = start + hdrLen    -- pointer to maker note directory
    local dirLen = len - hdrLen

    local hdr = substr(dataPt, dirStart, dirLen < 48 and dirLen or 48)
    local tagInfo = et:GetTagInfo(tagTablePtr, 'MakN', hdr)
    if not (tagInfo and tagInfo.SubDirectory) then return 0 end
    local subdir = tagInfo.SubDirectory
    local subTable = GetTagTable(nil, subdir.TagTable)
    -- initialize subdirectory information
    local subdirInfo = {
        DirName   = 'MakerNotes',
        Name      = tagInfo.Name,   -- needed for maker notes verbose dump
        Base      = dirInfo.Base,
        DataPt    = dataPt,
        DataPos   = dataPos,
        DataLen   = dirInfo.DataLen,
        DirStart  = dirStart,
        DirLen    = dirLen,
        TagInfo   = tagInfo,
        FixBase   = subdir.FixBase,
        EntryBased= subdir.EntryBased,
        Parent    = dirInfo.DirName,
    }
    -- look for start of maker notes IFD
    local loc = MakerNotes.LocateIFD(et, subdirInfo)
    if loc == nil then
        et:Warn('Maker notes could not be parsed')
        return 0
    end
    if truthy(et:Options('HtmlDump')) then
        et:HDump(dataPos + start, hdrLen, 'Adobe MakN data')
        if truthy(loc) then et:HDump(dataPos + dirStart, loc, tagInfo.Name .. ' header') end
    end

    local fix = 0
    if not subdir.Base then
        -- adjust base offset for current maker note position
        fix = dataPos + dirStart - originalPos
        subdirInfo.Base = subdirInfo.Base + fix
        subdirInfo.DataPos = subdirInfo.DataPos - fix
    end
    if outfile then
        -- rewrite the maker notes directory
        local fixup = require('lexiftool.Fixup').new()
        subdirInfo.Fixup = fixup
        local oldChanged = et.CHANGED
        local buff = require('lexiftool.Writer').WriteDirectory(et, subdirInfo, subTable)
        -- nothing to do if error writing directory or nothing changed
        if not (buff ~= nil and et.CHANGED ~= oldChanged) then
            et.CHANGED = oldChanged
            return 1
        end
        -- deleting maker notes if directory is empty
        if not truthy(length(buff)) then
            outfile.value = carray.new('char')
            return 1
        end
        -- apply a one-time fixup to offsets
        if subdirInfo.Relative then
            -- shift all offsets to be relative to new base
            local baseShift = dataPos + dirStart + dirInfo.Base - subdirInfo.Base
            fixup.Shift = fixup.Shift + baseShift
        else
            -- shift offsets to position of original maker notes
            fixup.Shift = fixup.Shift + originalPos
        end
        -- if we wrote the directory as a block the header is already included
        if subdirInfo.BlockWrite then loc = 0 end
        fixup.Shift = fixup.Shift + loc    -- adjust for makernotes header
        buff = fixup:ApplyFixup(carray.new('char'):append(buff)):tostring() -- fix up pointer offsets
        -- get copy of original Adobe header (6 or 18) and makernotes header ($loc)
        local header = substr(dataPt, start, hdrLen + loc)
        -- add Adobe and makernotes headers to new directory
        outfile.value = carray.new('char'):append(header, buff)
    else
        -- parse the maker notes directory
        et:ProcessDirectory(subdirInfo, subTable, subdir.ProcessProc)
        -- extract maker notes as a block if specified
        if truthy(et:Options('MakerNotes')) or
            (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(tagInfo.Name)])
        then
            local val
            if tagInfo.MakerNotes then
                subdirInfo.Base     = dirInfo.Base + fix
                subdirInfo.DataPos  = dataPos - fix
                subdirInfo.DirStart = dirStart
                subdirInfo.DirLen   = dirLen
                -- rebuild the maker notes to identify all offsets that require fixing up
                val = require('lexiftool.WriteExif').RebuildMakerNotes(et, subdirInfo, subTable)
                if val == nil and dirLen > 4 then
                    et:Warn('Error rebuilding maker notes (may be corrupt)')
                end
            else
                -- extract this directory as a block if specified
                if not tagInfo.Writable then return 1 end
            end
            if val == nil then val = substr(dataPt, 20) end
            local key = et:FoundTag(tagInfo, val)
            if et.MAKER_NOTE_FIXUP then
                et.TAG_EXTRA[key].Fixup = et.MAKER_NOTE_FIXUP
                et.MAKER_NOTE_FIXUP = nil
            end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Write Adobe information (calls appropriate ProcessProc to do the actual work)
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: new data block (may be empty if directory is deleted) or undef on error
function WriteAdobeStuff(et, dirInfo, tagTablePtr)
    if not et then return 1 end  -- allow dummy access
    local proc = dirInfo.Proc or ProcessAdobeData
    local buff = { }   -- (upstream `my $buff`, handed out as \$buff)
    dirInfo.OutFile = buff
    if not truthy(proc(et, dirInfo, tagTablePtr)) then buff.value = nil end
    return buff.value and buff.value:tostring()
end

DNG.ProcessOriginalRaw = ProcessOriginalRaw
DNG.ProcessAdobeData = ProcessAdobeData
DNG.ProcessAdobeCRW = ProcessAdobeCRW
DNG.ProcessAdobeMRW = ProcessAdobeMRW
DNG.ProcessAdobeRAF = ProcessAdobeRAF
DNG.ProcessAdobeSR2 = ProcessAdobeSR2
DNG.ProcessAdobeIFD = ProcessAdobeIFD
DNG.ProcessAdobeMakN = ProcessAdobeMakN
DNG.WriteAdobeStuff = WriteAdobeStuff

-- (PROCESS_PROC/WRITE_PROC and SubDirectory procs of the tables above: the
--  predeclared subs exist only now, see the predeclaration placeholders)
DNG.OriginalRaw.PROCESS_PROC = ProcessOriginalRaw
DNG.AdobeData.PROCESS_PROC = ProcessAdobeData
DNG.AdobeData.WRITE_PROC = WriteAdobeStuff
DNG.AdobeData['CRW '].SubDirectory.ProcessProc = ProcessAdobeCRW
DNG.AdobeData['CRW '].SubDirectory.WriteProc = WriteAdobeStuff
DNG.AdobeData['MRW '].SubDirectory.ProcessProc = ProcessAdobeMRW
DNG.AdobeData['MRW '].SubDirectory.WriteProc = WriteAdobeStuff
DNG.AdobeData['SR2 '].SubDirectory.ProcessProc = ProcessAdobeSR2
DNG.AdobeData['RAF '].SubDirectory.ProcessProc = ProcessAdobeRAF
DNG.AdobeData['Pano'].SubDirectory.ProcessProc = ProcessAdobeIFD
DNG.AdobeData['Koda'].SubDirectory.ProcessProc = ProcessAdobeIFD
DNG.AdobeData['Leaf'].SubDirectory.ProcessProc = ProcessAdobeIFD

return DNG
