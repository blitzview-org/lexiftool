--------------------------------------------------------------------------------
-- File:         lexiftool/GIF.lua
-- Ported from:  lib/Image/ExifTool/GIF.pm
--
-- Description:  Read and write GIF meta information
--
-- Revisions:    10/18/2005 - P. Harvey Separated from ExifTool.pm
--               05/23/2008 - P. Harvey Added ability to read/write XMP
--               10/28/2011 - P. Harvey Added ability to read/write ICC_Profile
--
-- References:   1) http://www.w3.org/Graphics/GIF/spec-gif89a.txt
--               2) http://www.adobe.com/devnet/xmp/
--               3) http://graphcomp.com/info/specs/ani_gif.html
--               4) http://www.color.org/icc_specs2.html
--               5) http://www.midiox.com/mmgif.htm
--
-- Port notes:   read subset: ProcessGIF and the Main/Extensions/Screen/
--               Animation/MIDIControl tables.  Write subset: the outfile
--               branch of ProcessGIF writes the File:Comment block and the
--               XMP/ICC_Profile application extensions, promoting the header
--               to GIF89a when something is added, and %gifMap reaches
--               InitWriteDirs with 'XMP' as the preferred group as upstream.
--               Deferred: upstream's scan for user-defined writable
--               application extensions (which extends @appExtensions at
--               runtime) -- this port uses the fixed upstream pair.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = ExifTool.perlTruthy
local Writer = require('lexiftool.Writer')
local Write = Writer.Write
local substr = require('lexiftool.perl').substr
local matches = require('lexiftool.perl').matches
local matchesDyn = require('lexiftool.perl').matchesDyn
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str
local tsort = require('lexiftool.perl').tsort

local GIF = {}

-- map for directories in GIF images
local gifMap = {
    XMP         = 'GIF',
    ICC_Profile = 'GIF',
}

GIF.Main = {
    GROUPS = { [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        This table lists information extracted from GIF images. See
        L<http://www.w3.org/Graphics/GIF/spec-gif89a.txt> for the official GIF89a
        specification.
    ]],
    GIFVersion = {},
    FrameCount = { Notes = 'number of animated images' },
    Text = { Notes = 'text displayed in image' },
    Comment = {
        -- for documentation only -- flag as writable for the docs, but
        -- it won't appear in the TagLookup because there is no WRITE_PROC
        Writable = 2,
    },
    Duration = {
        Notes = 'duration of a single animation iteration',
        PrintConv = function(_self, val) return sprintf('%.2f s', val) end,
    },
    ScreenDescriptor = {
        SubDirectory = { TagTable = 'lexiftool.GIF.Screen' },
    },
    Extensions = { -- (for documentation only)
        SubDirectory = { TagTable = 'lexiftool.GIF.Extensions' },
    },
    TransparentColor = {},
}

-- GIF89a application extensions:
GIF.Extensions = {
    GROUPS = { [2] = 'Image' },
    NOTES = 'Tags extracted from GIF89a application extensions.',
    WRITE_PROC = function() return 1 end, -- (dummy proc to facilitate writable directories)
    ['NETSCAPE/2.0'] = { --#3
        Name = 'Animation',
        SubDirectory = { TagTable = 'lexiftool.GIF.Animation' },
    },
    ['XMP Data/XMP'] = { --#2
        Name = 'XMP',
        -- IncludeLengthBytes indicates the length bytes are part of the data value...
        --  undef = data may contain nulls and is split into 255-byte blocks
        --  1 = data may not contain nulls and is not split; NULL padding is added as necessary
        --  2 = data is not split and may be edited in place; 257-byte landing zone is added
        --  (Terminator may be specified for a value of 1 above, but must be specified for 2)
        IncludeLengthBytes = 2,
        Terminator = [[<\?xpacket end=['"][wr]['"]\?>]], -- (regex to match end of valid data)
        Writable = 2, -- (writable directory!)
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    ['ICCRGBG1/012'] = { --#4
        Name = 'ICC_Profile',
        Writable = 2, -- (writable directory!)
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    ['MIDICTRL/Jon'] = { --#5
        Name = 'MIDIControl',
        SubDirectory = { TagTable = 'lexiftool.GIF.MIDIControl' },
    },
    ['MIDISONG/Dm7'] = { --#5
        Name = 'MIDISong',
        Groups = { [2] = 'Audio' },
        Binary = 1,
    },
    ['C2PA_GIF/'] = { -- https://c2pa.org/specifications/ (NC)
        Name = 'JUMBF',
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
    },
}

-- GIF logical screen descriptor
GIF.Screen = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Information extracted from the GIF logical screen descriptor.',
    [0] = { Name = 'ImageWidth', Format = 'int16u' },
    [2] = { Name = 'ImageHeight', Format = 'int16u' },
    [4.1] = {
        Name = 'HasColorMap',
        Mask = 0x80,
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [4.2] = {
        Name = 'ColorResolutionDepth',
        Mask = 0x70,
        ValueConv = function(_self, val) return val + 1 end,
    },
    [4.3] = {
        Name = 'BitsPerPixel',
        Mask = 0x07,
        ValueConv = function(_self, val) return val + 1 end,
    },
    [5] = 'BackgroundColor',
    [6] = {
        Name = 'PixelAspectRatio',
        RawConv = function(_self, val) return val ~= 0 and val or nil end,
        ValueConv = function(_self, val) return (val + 15) / 64 end,
    },
}

-- GIF Netscape 2.0 animation extension (ref 3)
GIF.Animation = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Information extracted from the "NETSCAPE2.0" animation extension.',
    [1] = {
        Name = 'AnimationIterations',
        Format = 'int16u',
        PrintConv = function(_self, val) return val ~= 0 and val or 'Infinite' end,
    },
}

-- GIF MIDICTRL extension (ref 5)
GIF.MIDIControl = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    NOTES = 'Information extracted from the MIDI control block extension.',
    [0] = 'MIDIControlVersion',
    [1] = 'SequenceNumber',
    [2] = 'MelodicPolyphony',
    [3] = 'PercussivePolyphony',
    [4] = {
        Name = 'ChannelUsage',
        Format = 'int16u',
        PrintConv = function(_self, val) return sprintf('0x%.4x', val) end,
    },
    [6] = {
        Name = 'DelayTime',
        Format = 'int16u',
        ValueConv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) return str(val) .. ' s' end,
    },
}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Read or rewrite GIF meta information (write path)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid GIF file, -1 on write error
--------------------------------------------------------------------------------
-- write a GIF comment extension block
local function writeCommentBlock(outfile, comment)
    Write(outfile, '\33\254')
    local len = #comment
    for n = 0, len - 1, 255 do
        local size = len - n
        if size > 255 then size = 255 end
        Write(outfile, string.char(size), substr(comment, n, size))
    end
    Write(outfile, '\0')
end

-- write a GIF application-extension block (XMP/ICC)
local function writeAppExtension(outfile, ext, buff, inclLen)
    Write(outfile, '\33\255\11', substr(ext, 0, 8), substr(ext, 9, 3))
    if inclLen then
        if inclLen > 1 then
            -- add landing zone (without the terminator, added below)
            local landing = '\1'
            for i = 255, 0, -1 do landing = landing .. string.char(i) end
            buff = buff .. landing
        end
        Write(outfile, buff)
    else
        local pos = 0
        while pos < #buff do
            local n = #buff - pos
            if n > 255 then n = 255 end
            Write(outfile, string.char(n), substr(buff, pos, n))
            pos = pos + n
        end
    end
    Write(outfile, '\0')
end

function GIF.ProcessGIF(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local n1, buff = raf:Read(6)
    if n1 ~= 6 or not buff:match('^GIF8[79]a$') then return 0 end
    local ver = buff:sub(4, 6)
    local n2, s = raf:Read(7)
    if n2 ~= 7 then return 0 end

    local rtnVal = 0
    local tagTablePtr = et:GetTagTable('lexiftool.GIF.Main')
    local extTable = et:GetTagTable('lexiftool.GIF.Extensions')
    ExifTool.SetByteOrder('II')

    local err = false
    local newComment, setComment, nvComment, newExt
    local addDirs
    local doneDir = { }

    if outfile then
        Writer.InitWriteDirs(et, gifMap, 'XMP') -- make XMP the preferred group for GIF
        addDirs = et.ADD_DIRS or { }
        -- determine if we are editing the File:Comment tag
        newComment, nvComment = et:GetNewValue('Comment')
        -- `-all=` records only the wildcard in this port, so ask the helper
        setComment = (nvComment ~= nil) or Writer.IsGroupDeleted(et, 'File')
        -- change to GIF 89a if adding comment, XMP or ICC_Profile
        if (next(addDirs) ~= nil) or newComment ~= nil then buff = 'GIF89a' end
        Write(outfile, buff, s)
        newExt = Writer.GetNewTagInfoHash(et, extTable)
    else
        et:SetFileType()
        et:HandleTag(tagTablePtr, 'GIFVersion', ver)
        et:HandleTag(tagTablePtr, 'ScreenDescriptor', s)
    end

    local flags = s:byte(5)
    if flags & 0x80 ~= 0 then
        local clen = 3 * (2 << (flags & 0x07))
        local n3, cbuf = raf:Read(clen)
        if n3 ~= clen then return 0 end
        if outfile then Write(outfile, cbuf) end
    end

    local frameCount = 0
    local delayTime = 0

    while true do
        local nch, ch = raf:Read(1)
        if nch ~= 1 then break end
        local chByte = ch:byte(1)

        -- write out new metadata now if this isn't an extension block
        if outfile and chByte ~= 0x21 then
            -- write the comment first if necessary
            if newComment ~= nil and nvComment and nvComment.IsCreating and nvComment.IsCreating ~= 0 then
                if perlTruthy(verbose) then et:VPrint(0, '  + Comment = ' .. newComment .. '\n') end
                writeCommentBlock(outfile, newComment)
                newComment = nil
                nvComment = nil
                et.CHANGED = (et.CHANGED or 0) + 1
            end
            -- add application extensions if necessary
            local appExtensions = { 'XMP Data/XMP', 'ICCRGBG1/012' }
            local new = { }
            for tag in pairs(newExt) do new[#new + 1] = tag end
            tsort(new)
            for _, ext in ipairs(appExtensions) do new[#new + 1] = ext end
            -- dedupe while preserving order
            local seen = { }
            local ordered = { }
            for _, ext in ipairs(new) do
                if not seen[ext] then seen[ext] = true; ordered[#ordered + 1] = ext end
            end
            for _, ext in ipairs(ordered) do
                local extInfo = extTable[ext]
                if not extInfo then goto next_ext end
                local name = extInfo.Name
                local subBuff
                if newExt[ext] then
                    newExt[ext] = nil
                    doneDir[name] = 1
                    subBuff = Writer.GetNewValue(et, extInfo)
                elseif addDirs[name] and not doneDir[name] then
                    doneDir[name] = 1
                    local subTable = et:GetTagTable(extInfo.SubDirectory.TagTable)
                    if name == 'XMP' then
                        local XMP = require('lexiftool.XMP')
                        subBuff = XMP.WriteXMP(et, { }, XMP.Main)
                    else
                        subBuff = Writer.WriteDirectory(et, { Parent = 'GIF', DirName = name }, subTable)
                    end
                else
                    goto next_ext
                end
                if subBuff and #subBuff > 0 then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    writeAppExtension(outfile, ext, subBuff, extInfo.IncludeLengthBytes)
                end
                ::next_ext::
            end
        end

        if chByte == 0x2c then
            -- image descriptor
            frameCount = frameCount + 1
            if outfile then Write(outfile, ch) end
            local n4, ibuf = raf:Read(8)
            local n5, ich = raf:Read(1)
            if n4 ~= 8 or n5 ~= 1 then break end
            if outfile then Write(outfile, ibuf, ich) end
            if perlTruthy(verbose) and not outfile then
                et:VPrint(0, string.format('Image: left=%d top=%d width=%d height=%d\n',
                    ExifTool.Get16u(ibuf, 0), ExifTool.Get16u(ibuf, 2),
                    ExifTool.Get16u(ibuf, 4), ExifTool.Get16u(ibuf, 6)))
            end
            if ich:byte(1) & 0x80 ~= 0 then
                local clen = 3 * (2 << (ich:byte(1) & 0x07))
                local n6, cbuf = raf:Read(clen)
                if n6 ~= clen then break end
                if outfile then Write(outfile, cbuf) end
            end
            local n7, mcs = raf:Read(1) -- "LZW Minimum Code Size" byte
            if n7 ~= 1 then break end
            if outfile then Write(outfile, mcs) end
            -- image blocks
            while true do
                local n8, bch = raf:Read(1)
                if n8 ~= 1 then goto doneOuter end
                if outfile then Write(outfile, bch) end
                local blen = bch:byte(1)
                if blen == 0 then break end
                local n9, dbuf = raf:Read(blen)
                if n9 ~= blen then goto doneOuter end
                if outfile then Write(outfile, dbuf) end
            end
            goto continueBlock
        end

        if chByte ~= 0x21 then
            -- normal end of GIF (trailer marker)
            if outfile then
                Write(outfile, ch)
                -- copy the rest of the file (trailer data)
                while true do
                    local _, rest = raf:Read(65536)
                    if not rest or #rest == 0 then break end
                    Write(outfile, rest)
                end
            end
            rtnVal = 1
            break
        end

        -- get extension block type/size
        local n10, s2 = raf:Read(2)
        if n10 ~= 2 then break end
        local a, length = s2:byte(1), s2:byte(2)

        if a == 0xfe then -- comment extension
            local comment = ''
            while length > 0 do
                local n11, cbuf = raf:Read(length)
                if n11 ~= length then goto doneOuter end
                comment = comment .. cbuf
                local n12, nb = raf:Read(1)
                if n12 ~= 1 then goto doneOuter end
                length = nb:byte(1)
            end
            if length ~= 0 then break end -- read error
            rtnVal = 1
            if outfile then
                local isOverwriting
                if setComment then
                    if nvComment then
                        isOverwriting = perlTruthy(Writer.IsOverwriting(et, nvComment, comment))
                        if newComment == nil then newComment = Writer.GetNewValue(et, nvComment) end
                    else
                        isOverwriting = true
                    end
                end
                if isOverwriting then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    comment = newComment
                    nvComment = nil
                else
                    setComment = nil
                end
                if comment ~= nil then
                    writeCommentBlock(outfile, comment)
                end
                newComment = nil
            else
                if #comment > 0 then et:FoundTag('Comment', comment) end
                if et:Options('FastScan') then break end
            end
            goto continueBlock
        elseif a == 0xff and length == 0x0b then -- application extension
            local n13, abuf = raf:Read(length)
            if n13 ~= length then break end
            local hdr = ch .. s2 .. abuf
            local tag = (substr(abuf, 0, 8) .. '/' .. substr(abuf, 8)):gsub('[\0-\31]', '')
            if perlTruthy(verbose) then et:VPrint(0, 'Application Extension: ' .. tag .. '\n') end
            local extInfo = extTable[tag]
            local subdir, inclLen, justCopy, name
            if extInfo then
                if outfile and newExt[extInfo.TagID or tag] then
                    newExt[extInfo.TagID or tag] = nil
                else
                    subdir = extInfo.SubDirectory
                end
                inclLen = extInfo.IncludeLengthBytes
                name = extInfo.Name
                if outfile and not extInfo.Writable then justCopy = true end
            else
                if outfile then justCopy = true end
            end
            if justCopy then Write(outfile, hdr) end

            -- read the extension data
            local dat = ''
            while true do
                local n14, dch = raf:Read(1)
                if n14 ~= 1 then goto doneOuter end
                local dlen = dch:byte(1)
                if dlen == 0 then break end
                local n15, dbuf = raf:Read(dlen)
                if n15 ~= dlen then goto doneOuter end
                if justCopy then Write(outfile, dch, dbuf) end
                dat = dat .. (inclLen and (dch .. dbuf) or dbuf)
            end
            if justCopy then
                Write(outfile, '\0')
                goto continueBlock
            elseif inclLen then
                -- remove landing zone or padding
                local ok, pos
                if extInfo.Terminator then ok, pos = matchesDyn(dat, extInfo.Terminator) end
                if ok then
                    dat = substr(dat, 0, pos)
                else
                    ok, pos = matches(dat, [[\0]])
                    if ok then dat = substr(dat, 0, pos - 1) end
                end
            end
            if subdir then
                local subTable = et:GetTagTable(subdir.TagTable)
                if not outfile then
                    et:ProcessDirectory({
                        DataPt = dat,
                        DataLen = #dat,
                        DirLen = #dat,
                        DirName = name,
                        Parent = 'GIF',
                    }, subTable)
                    goto continueBlock
                end
                if doneDir[name] and doneDir[name] > 1 then
                    et:Warn('Duplicate ' .. name .. ' block created')
                end
                if name == 'XMP' then
                    if Writer.IsGroupDeleted(et, 'XMP') then
                        -- upstream reaches this through WriteDirectory, which
                        -- returns '' for a deleted group; the direct WriteXMP
                        -- call here has to make the check itself
                        et.CHANGED = (et.CHANGED or 0) + 1
                        goto continueBlock
                    end
                    local XMP = require('lexiftool.XMP')
                    local newDat = XMP.WriteXMP(et, { DataPt = dat }, XMP.Main)
                    if newDat ~= nil then
                        dat = newDat
                        doneDir[name] = 1
                    end
                else
                    local newDat = Writer.WriteDirectory(et, {
                        DataPt = dat,
                        DataLen = #dat,
                        DirLen = #dat,
                        DirName = name,
                        Parent = 'GIF',
                    }, subTable)
                    if newDat ~= nil then
                        if #newDat == 0 then goto continueBlock end -- deleted
                        dat = newDat
                        doneDir[name] = 1
                    end
                end
            elseif outfile and not justCopy then
                local nvHash = Writer.GetNewValueHash(et, extInfo)
                if nvHash and perlTruthy(Writer.IsOverwriting(et, nvHash, dat)) then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    local val = Writer.GetNewValue(et, extInfo)
                    if val == nil or #val == 0 then goto continueBlock end
                    dat = val
                    doneDir[name] = 1
                end
            elseif not outfile then
                et:HandleTag(extTable, tag, dat)
                goto continueBlock
            end
            Write(outfile, hdr)
            if inclLen then
                if inclLen > 1 then
                    local landing = '\1'
                    for i = 255, 0, -1 do landing = landing .. string.char(i) end
                    dat = dat .. landing
                end
                Write(outfile, dat)
            else
                local pos = 0
                while pos < #dat do
                    local n = #dat - pos
                    if n > 255 then n = 255 end
                    Write(outfile, string.char(n), substr(dat, pos, n))
                    pos = pos + n
                end
            end
            Write(outfile, '\0')
            goto continueBlock
        elseif a == 0xf9 and length == 4 then -- graphic control extension
            local n16, gbuf = raf:Read(length)
            if n16 ~= length then break end
            if outfile then Write(outfile, ch, s2, gbuf) end
            delayTime = delayTime + ExifTool.Get16u(gbuf, 1)
            if gbuf:byte(1) & 0x01 ~= 0 then
                et:HandleTag(tagTablePtr, 'TransparentColor', gbuf:byte(4))
            end
            goto continueBlock
        elseif a == 0x01 and length == 12 then -- plain text extension
            local n17, tbuf = raf:Read(length)
            if n17 ~= length then break end
            if outfile then Write(outfile, ch, s2, tbuf) end
            local text = ''
            while true do
                local n18, tch = raf:Read(1)
                if n18 ~= 1 then break end
                local tlen = tch:byte(1)
                if tlen == 0 then break end
                local n19, tdat = raf:Read(tlen)
                if n19 ~= tlen then break end
                if outfile then Write(outfile, tch, tdat) end
                text = text .. tdat
            end
            if outfile then Write(outfile, '\0') end
            et:HandleTag(tagTablePtr, 'Text', text)
            goto continueBlock
        else
            -- unrecognized extension block: copy through
            if outfile then Write(outfile, ch, s2) end
            while length > 0 do
                local n20, ubuf = raf:Read(length)
                if n20 ~= length then goto doneOuter end
                if outfile then Write(outfile, ubuf) end
                local n21, sch = raf:Read(1)
                if n21 ~= 1 then goto doneOuter end
                if outfile then Write(outfile, sch) end
                length = sch:byte(1)
            end
        end
        ::continueBlock::
    end
    ::doneOuter::

    if frameCount > 1 then et:HandleTag(tagTablePtr, 'FrameCount', frameCount) end
    if delayTime > 0 then et:HandleTag(tagTablePtr, 'Duration', delayTime / 100) end

    if outfile and err then return -1 end
    return rtnVal
end

return GIF