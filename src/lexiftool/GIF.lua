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
-- Port notes:   Complete port of GIF.pm: every table and ProcessGIF (read
--               and write), line for line.  Perl's `for (;;)` loops are
--               `while true` loops; `next` is a goto to the label at the end
--               of the loop body, `last Block` a goto to the label behind
--               the outer loop.  %gifMap and @appExtensions are file-scope
--               like upstream's `my` variables, so the user-defined writable
--               application extensions ProcessGIF adds when writing stay
--               added for the following files, as in Perl.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Write = Writer.Write
local perl = require('lexiftool.perl')
local perlTruthy = ExifTool.perlTruthy
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local matches, matchesDyn, isMatch = perl.matches, perl.matchesDyn, perl.isMatch
local substr = perl.substr
local length = perl.length
local sprintf = perl.sprintf
local perlStr = perl.str
local unpack, pack = perl.unpack, perl.pack
local ord, chr = perl.ord, perl.chr
local tr = perl.tr
local keys, sort = perl.keys, perl.sort
local print, printf = perl.print, perl.printf

local GIF = {}

-- (Perl's lists `1,reverse(0..255)` and `1,reverse(0..255),0`: the XMP
--  landing zone, without and with the null terminator)
local landingZone = { 1 }
for i = 255, 0, -1 do landingZone[#landingZone + 1] = i end
local landingZoneNull = { table.unpack(landingZone) }
landingZoneNull[#landingZoneNull + 1] = 0

-- road map of directory locations in GIF images
local gifMap = {
    XMP         = 'GIF',
    ICC_Profile = 'GIF',
}

-- application extensions that we can write, and the order they are written
local appExtensions = { 'XMP Data/XMP', 'ICCRGBG1/012' }

GIF.Main = {
    GROUPS = { [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        This table lists information extracted from GIF images. See
        L<http://www.w3.org/Graphics/GIF/spec-gif89a.txt> for the official GIF89a
        specification.
    ]],
    GIFVersion = { },
    FrameCount = { Notes = 'number of animated images' },
    Text       = { Notes = 'text displayed in image' },
    Comment    = {
        -- for documentation only -- flag as writable for the docs, but
        -- it won't appear in the TagLookup because there is no WRITE_PROC
        Writable = 2,
    },
    Duration   = {
        Notes = 'duration of a single animation iteration',
        PrintConv = function(_self, val) return sprintf('%.2f s', val) end,
    },
    ScreenDescriptor = {
        SubDirectory = { TagTable = 'lexiftool.GIF.Screen' },
    },
    Extensions = { -- (for documentation only)
        SubDirectory = { TagTable = 'lexiftool.GIF.Extensions' },
    },
    TransparentColor = { },
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
        Writable = 2,  -- (writable directory!)
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    ['ICCRGBG1/012'] = { --#4
        Name = 'ICC_Profile',
        Writable = 2,  -- (writable directory!)
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
    ['C2PA_GIF/'] = { --#https://c2pa.org/specifications/ (NC) (authentication code is 0x010000 binary, so removed from tag ID)
        Name = 'JUMBF',
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
    },
}

-- GIF locical screen descriptor
GIF.Screen = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Information extracted from the GIF logical screen descriptor.',
    [0] = {
        Name = 'ImageWidth',
        Format = 'int16u',
    },
    [2] = {
        Name = 'ImageHeight',
        Format = 'int16u',
    },
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
        RawConv = function(_self, val) if perlTruthy(val) then return val else return nil end end,
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
        PrintConv = function(_self, val) if perlTruthy(val) then return val else return 'Infinite' end end,
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
        PrintConv = function(_self, val) return perlStr(val) .. ' s' end,
    },
}

--------------------------------------------------------------------------------
-- Read/write meta information in GIF image
-- Inputs: 0) ExifTool object reference, 1) Directory information ref
-- Returns: 1 on success, 0 if this wasn't a valid GIF file, or -1 if
--          an output file was specified and a write error occurred
function GIF.ProcessGIF(et, dirInfo)
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local a, s, ch, length_, buff
    local err, newComment, setComment, nvComment, newExt
    local addDirs, doneDir = nil, { }
    local frameCount, delayTime = 0, 0
    local n, ver

    -- verify this is a valid GIF file
    n, buff = raf:Read(6)
    if n == 6 then ver = matches(buff, [[^GIF(8[79]a)$]]) end
    if not (n == 6 and ver) then return 0 end
    n, s = raf:Read(7)
    if n ~= 7 then return 0 end

    local rtnVal = 0
    local tagTablePtr = GetTagTable(nil, 'lexiftool.GIF.Main')
    local extTable = GetTagTable(nil, 'lexiftool.GIF.Extensions')
    SetByteOrder('II')

    if outfile then
        -- add any user-defined writable app extensions to the list
        for _, ext in ipairs(sort(keys(extTable))) do
            if type(extTable[ext]) ~= 'table' then goto nextExt end
            local extInfo = extTable[ext]
            if not (extInfo.SubDirectory and perlTruthy(extInfo.Writable) and not gifMap[extInfo.Name]) then goto nextExt end
            gifMap[extInfo.Name] = 'GIF'
            appExtensions[#appExtensions + 1] = ext
            ::nextExt::
        end
        Writer.InitWriteDirs(et, gifMap, 'XMP') -- make XMP the preferred group for GIF
        addDirs = et.ADD_DIRS
        -- determine if we are editing the File:Comment tag
        local delGroup = et.DEL_GROUP
        newComment, nvComment = et:GetNewValue('Comment')
        if nvComment or delGroup.File then setComment = 1 end
        -- change to GIF 89a if adding comment, XMP or ICC_Profile
        if next(addDirs) ~= nil or newComment ~= nil then buff = 'GIF89a' end
        if not Write(outfile, buff, s) then err = 1 end
        newExt = Writer.GetNewTagInfoHash(et, extTable)
    else
        et:SetFileType()   -- set file type
        et:HandleTag(tagTablePtr, 'GIFVersion', ver)
        et:HandleTag(tagTablePtr, 'ScreenDescriptor', s)
    end
    local flags = Get8u(s, 4)
    if flags & 0x80 ~= 0 then -- does this image contain a color table?
        -- calculate color table size
        length_ = 3 * (2 << (flags & 0x07))
        n, buff = raf:Read(length_)
        if n ~= length_ then return 0 end -- skip color table
        if outfile then if not Write(outfile, buff) then err = 1 end end
    end
--
-- loop through GIF blocks
--
    while true do -- Block:
        n, ch = raf:Read(1)
        if n == 0 then break end
        -- write out any new metadata now if this isn't an extension block
        if outfile and ord(ch) ~= 0x21 then
            -- write the comment first if necessary
            if newComment ~= nil and perlTruthy(nvComment.IsCreating) then
                -- write comment marker
                if not Write(outfile, '\x21\xfe') then err = 1 end
                if perlTruthy(verbose) then print(out, '  + Comment = ' .. perlStr(newComment) .. "\n") end
                local len = length(newComment)
                -- write out the comment in 255-byte chunks, each
                -- chunk beginning with a length byte
                local n_ = 0
                while n_ < len do
                    local size = len - n_
                    if size > 255 then size = 255 end
                    local str = substr(newComment, n_, size)
                    if not Write(outfile, pack('C', size), str) then err = 1 end
                    n_ = n_ + 255
                end
                if not Write(outfile, '\0') then err = 1 end  -- empty chunk as terminator
                newComment = nil
                nvComment = nil     -- delete any other extraneous comments
                et.CHANGED = (et.CHANGED or 0) + 1     -- increment file changed flag
            end
            -- add application extensions if necessary
            local new = sort(keys(newExt))
            local exts = { }
            for _, ext in ipairs(appExtensions) do exts[#exts + 1] = ext end
            for _, ext in ipairs(new) do exts[#exts + 1] = ext end
            for _, ext in ipairs(exts) do
                local extInfo = extTable[ext]
                local name = extInfo.Name
                if newExt[ext] then
                    newExt[ext] = nil
                    doneDir[name] = 1       -- (we wrote this as a block instead)
                    buff = et:GetNewValue(extInfo)
                    et:VerboseValue('+ GIF:' .. name, buff)
                elseif addDirs[name] ~= nil and doneDir[name] == nil then
                    doneDir[name] = 1
                    local tbl = GetTagTable(nil, extInfo.SubDirectory.TagTable)
                    local dirInfo_ = { Parent = 'GIF' }
                    if perlTruthy(verbose) then print(out, 'Creating ' .. name .. " application extension block:\n") end
                    buff = Writer.WriteDirectory(et, dirInfo_, tbl)
                else
                    goto nextExt
                end
                if buff ~= nil and length(buff) > 0 then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    if not Write(outfile, '\x21\xff\x0b', substr(ext, 0, 8), substr(ext, 9, 3)) then err = 1 end
                    local pos = 0
                    if not perlTruthy(extTable[ext].IncludeLengthBytes) then
                        local len = length(buff) -- luacheck: ignore 211 (unused, as upstream's $len)
                        while pos < length(buff) do
                            local n_ = length(buff) - pos
                            if n_ > 255 then n_ = 255 end
                            if not Write(outfile, chr(n_), substr(buff, pos, n_)) then err = 1 end
                            pos = pos + n_
                        end
                        if not Write(outfile, '\0') then err = 1 end  -- write null terminator
                    elseif extTable[ext].IncludeLengthBytes < 2 then
                        while pos < length(buff) do pos = pos + ord(substr(buff, pos, 1)) + 1 end
                        -- write data, null padding and terminator
                        if not Write(outfile, buff, string.rep('\0', pos - length(buff) + 1)) then err = 1 end
                    else
                        -- write data, landing zone and null terminator
                        if not Write(outfile, buff, pack('C*', table.unpack(landingZoneNull))) then err = 1 end
                    end
                    doneDir[name] = doneDir[name] + 1   -- set to 2 to indicate we added it
                else
                    if perlTruthy(verbose) then print(out, '  -> no ' .. name .. " to add\n") end
                end
                ::nextExt::
            end
        end
        if ord(ch) == 0x2c then
            frameCount = frameCount + 1
            if outfile then if not Write(outfile, ch) then err = 1 end end
            -- image descriptor
            n, buff = raf:Read(8)
            if n ~= 8 then break end
            n, ch = raf:Read(1)
            if n == 0 then break end
            if outfile then if not Write(outfile, buff, ch) then err = 1 end end
            if perlTruthy(verbose) and not outfile then
                local left, top, w, h = unpack('v*', buff)
                print(out, 'Image: left=' .. left .. ' top=' .. top .. ' width=' .. w .. ' height=' .. h .. "\n")
            end
            if ord(ch) & 0x80 ~= 0 then -- does color table exist?
                length_ = 3 * (2 << (ord(ch) & 0x07))
                -- skip the color table
                n, buff = raf:Read(length_)
                if n ~= length_ then break end
                if outfile then if not Write(outfile, buff) then err = 1 end end
            end
            -- skip "LZW Minimum Code Size" byte
            n, buff = raf:Read(1)
            if n == 0 then break end
            if outfile then if not Write(outfile, buff) then err = 1 end end
            -- skip image blocks
            while true do
                n, ch = raf:Read(1)
                if n == 0 then break end
                if outfile then if not Write(outfile, ch) then err = 1 end end
                if ord(ch) == 0 then break end
                n, buff = raf:Read(ord(ch))
                if n == 0 then break end
                if outfile then if not Write(outfile, buff) then err = 1 end end
            end
            goto nextBlock  -- continue with next field
        end
--               last if ord($ch) == 0x3b;  # normal end of GIF marker
        if ord(ch) ~= 0x21 then
            if outfile then
                if not Write(outfile, ch) then err = 1 end
                -- copy the rest of the file
                while true do
                    n, buff = raf:Read(65536)
                    if n == 0 then break end
                    if not Write(outfile, buff) then err = 1 end
                end
            end
            rtnVal = 1
            break
        end
        -- get extension block type/size
        n, s = raf:Read(2)
        if n ~= 2 then break end
        -- get marker and block size
        a, length_ = unpack(string.rep('C', 2), s)

        if a == 0xfe then                           -- comment extension

            local comment = ''
            while length_ ~= 0 do
                n, buff = raf:Read(length_)
                if n ~= length_ then break end
                if not outfile then et:VerboseDump(buff) end
                -- add buffer to comment string
                comment = comment .. buff
                n, ch = raf:Read(1)
                if n == 0 then break end  -- read next block header
                length_ = ord(ch)  -- get next block size
            end
            if length_ ~= 0 then break end    -- was a read error if length isn't zero
            if outfile then
                local isOverwriting
                if setComment then
                    if nvComment then
                        isOverwriting = Writer.IsOverwriting(et, nvComment, comment)
                        -- get new comment again (may have been shifted)
                        if newComment ~= nil then newComment = et:GetNewValue(nvComment) end
                    else
                        -- group delete, or deleting additional comments after writing one
                        isOverwriting = 1
                    end
                end
                if perlTruthy(isOverwriting) then
                    et.CHANGED = (et.CHANGED or 0) + 1     -- increment file changed flag
                    et:VerboseValue('- GIF:Comment', comment)
                    comment = newComment
                    if comment ~= nil then et:VerboseValue('+ GIF:Comment', comment) end
                    nvComment = nil     -- just delete remaining comments
                else
                    setComment = nil    -- leave remaining comments alone
                end
                if comment ~= nil then
                    -- write comment marker
                    if not Write(outfile, '\x21\xfe') then err = 1 end
                    local len = length(comment)
                    -- write out the comment in 255-byte chunks, each
                    -- chunk beginning with a length byte
                    local n_ = 0
                    while n_ < len do
                        local size = len - n_
                        if size > 255 then size = 255 end
                        local str = substr(comment, n_, size)
                        if not Write(outfile, pack('C', size), str) then err = 1 end
                        n_ = n_ + 255
                    end
                    if not Write(outfile, '\0') then err = 1 end  -- empty chunk as terminator
                end
                newComment = nil    -- don't write the new comment again
            else
                rtnVal = 1
                if perlTruthy(comment) then et:FoundTag('Comment', comment) end
                comment = nil -- luacheck: ignore 311
                -- assume no more than one comment in FastScan mode
                if perlTruthy(et:Options('FastScan')) then break end
            end
            goto nextBlock

        elseif a == 0xff and length_ == 0x0b then  -- application extension

            n, buff = raf:Read(length_)
            if n ~= length_ then break end
            local hdr = ch .. s .. buff
            -- add "/" for readability
            local tag = substr(buff, 0, 8) .. '/' .. substr(buff, 8)
            tag = tr(tag, '\0-\x1f', '', 'd')   -- remove nulls and control characters
            if perlTruthy(verbose) then print(out, 'Application Extension: ' .. tag .. "\n") end

            local extInfo = extTable[tag]
            local subdir, inclLen, justCopy, name
            if extInfo then
                if outfile and newExt[extInfo.TagID] then
                    newExt[extInfo.TagID] = nil  -- don't create again
                    -- (write as a block -- don't define $subdir)
                else
                    subdir = extInfo.SubDirectory
                end
                inclLen = extInfo.IncludeLengthBytes
                name = extInfo.Name
                -- rewrite as-is unless this is a writable
                if outfile and not perlTruthy(extInfo.Writable) then justCopy = 1 end
            else
                if outfile then justCopy = 1 end
            end
            if justCopy then if not Write(outfile, hdr) then err = 1 end end

            -- read the extension data
            local dat = ''
            while true do
                n, ch = raf:Read(1)
                if n == 0 then goto lastBlock end   -- read next block header
                length_ = ord(ch)                    -- get next block size
                if length_ == 0 then break end
                n, buff = raf:Read(length_)
                if n ~= length_ then goto lastBlock end
                if justCopy then if not Write(outfile, ch, buff) then err = 1 end end
                if perlTruthy(inclLen) then dat = dat .. ch .. buff else dat = dat .. buff end
            end
            if justCopy then
                if not Write(outfile, '\0') then err = 1 end
                goto nextBlock
            elseif perlTruthy(inclLen) then
                -- remove landing zone or padding
                local _, pos
                if extInfo.Terminator then _, pos = matchesDyn(dat, extInfo.Terminator) end
                if pos then
                    dat = substr(dat, 0, pos)
                else
                    _, pos = matches(dat, [[\0]])
                    if pos then dat = substr(dat, 0, pos - 1) end
                end
            end
            if subdir then
                local dirInfo_ = {
                    DataPt  = dat,
                    DataLen = length(dat),
                    DirLen  = length(dat),
                    DirName = name,
                    Parent  = 'GIF',
                }
                local subTable = GetTagTable(nil, subdir.TagTable)
                if not outfile then
                    et:ProcessDirectory(dirInfo_, subTable)
                    goto nextBlock
                end
                if justCopy then goto nextBlock end
                if doneDir[name] and doneDir[name] > 1 then
                    et:Warn('Duplicate ' .. name .. ' block created')
                end
                buff = Writer.WriteDirectory(et, dirInfo_, subTable)
                if buff ~= nil then
                    if length(buff) == 0 then goto nextBlock end   -- delete this extension if length is zero
                    dat = buff
                end
                doneDir[name] = 1
            elseif outfile and not justCopy then
                local nvHash = Writer.GetNewValueHash(et, extInfo)
                if nvHash and perlTruthy(Writer.IsOverwriting(et, nvHash, dat)) then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    local val = et:GetNewValue(extInfo)
                    et:VerboseValue('- GIF:' .. name, dat)
                    if not (val ~= nil and length(val) > 0) then goto nextBlock end
                    dat = val
                    et:VerboseValue('+ GIF:' .. name, dat)
                    doneDir[name] = 1       -- (possibly wrote dir as a block)
                end
            elseif not outfile then
                et:HandleTag(extTable, tag, dat)
                goto nextBlock
            end
            if not Write(outfile, hdr) then err = 1 end  -- write extension header
            if perlTruthy(inclLen) then
                -- check for null just to be safe
                if perlTruthy(inclLen) and isMatch(dat, [[\0]]) then et:Error(name .. ' contained NULL character') end
                if inclLen > 1 then
                    -- add landing zone (without terminator, which will be added later)
                    if perlTruthy(inclLen) then dat = dat .. pack('C*', table.unpack(landingZone)) end
                else
                    -- pad with nulls as required
                    local pos = 0
                    while pos < length(dat) do pos = pos + ord(substr(dat, pos, 1)) + 1 end
                    dat = dat .. string.rep('\0', pos - length(dat))
                end
                -- write data and landing zone
                if not Write(outfile, dat) then err = 1 end
            else
                -- write as sub-blocks
                local pos = 0
                local len = length(dat)
                while pos < len do
                    local n_ = len - pos
                    if n_ > 255 then n_ = 255 end
                    if not Write(outfile, chr(n_), substr(dat, pos, n_)) then err = 1 end
                    pos = pos + n_
                end
            end
            if not Write(outfile, '\0') then err = 1 end  -- write null terminator
            goto nextBlock

        elseif a == 0xf9 and length_ == 4 then     -- graphic control extension

            n, buff = raf:Read(length_)
            if n ~= length_ then break end
            -- sum the individual delay times
            local delay = Get16u(buff, 1)
            delayTime = delayTime + delay
            if perlTruthy(verbose) then printf(out, "Graphic Control: delay=%.2f\n", delay / 100) end
            -- get transparent colour
            local bits = Get8u(buff, 0)
            if bits & 0x01 ~= 0 then et:HandleTag(tagTablePtr, 'TransparentColor', Get8u(buff, 3)) end
            if not raf:Seek(-length_, 1) then break end

        elseif a == 0x01 and length_ == 12 then    -- plain text extension

            n, buff = raf:Read(length_)
            if n ~= length_ then break end
            if outfile then if not Write(outfile, ch, s, buff) then err = 1 end end
            if perlTruthy(verbose) and not outfile then
                local left, top, w, h = unpack('v4', buff)
                print(out, 'Text: left=' .. left .. ' top=' .. top .. ' width=' .. w .. ' height=' .. h .. "\n")
            end
            local text = ''
            while true do
                n, ch = raf:Read(1)
                if n == 0 then break end
                length_ = ord(ch)
                if length_ == 0 then break end
                n, buff = raf:Read(length_)
                if n ~= length_ then break end
                if outfile then if not Write(outfile, ch, buff) then err = 1 end end -- write block
                text = text .. buff
            end
            if outfile then if not Write(outfile, '\0') then err = 1 end end  -- write terminator block
            et:HandleTag(tagTablePtr, 'Text', text)
            goto nextBlock
        end
        if outfile then if not Write(outfile, ch, s) then err = 1 end end
        -- skip the block
        while length_ ~= 0 do
            n, buff = raf:Read(length_)
            if n ~= length_ then break end
            if outfile then if not Write(outfile, buff) then err = 1 end end
            n, ch = raf:Read(1)
            if n == 0 then break end  -- read next block header
            if outfile then if not Write(outfile, ch) then err = 1 end end
            length_ = ord(ch)  -- get next block size
        end
        ::nextBlock::
    end
    ::lastBlock::
    if not outfile then
        if frameCount > 1 then et:HandleTag(tagTablePtr, 'FrameCount', frameCount) end
        if delayTime ~= 0 then et:HandleTag(tagTablePtr, 'Duration', delayTime / 100) end
    end

    -- set return value to -1 if we only had a write error
    if rtnVal ~= 0 and err then rtnVal = -1 end
    return rtnVal
end

return GIF
