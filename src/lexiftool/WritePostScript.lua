--------------------------------------------------------------------------------
-- File:         lexiftool/WritePostScript.lua
-- Ported from:  lib/Image/ExifTool/WritePostScript.pl
--
-- Description:  Write PostScript meta information
--
-- Revisions:    03/03/2006 - P. Harvey Created
--
-- References:   (see references in PostScript.pm, plus:)
--               1) http://www.adobe.com/products/postscript/pdfs/PLRM.pdf
--               2) http://www-cdf.fnal.gov/offline/PostScript/PLRM2.pdf
--               3) http://partners.adobe.com/public/developer/en/acrobat/sdk/pdf/pdf_creation_apis_and_specs/pdfmarkReference.pdf
--               4) http://www.npes.org/standards/Tools/DCS20Spec.pdf
--
-- Notes:        (see NOTES in POD doc below)
--
-- Port notes:   All subs of WritePostScript.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::PostScript
--               package and AUTOLOADs it on the first call of one of its
--               subs; this port makes it a module of its own, and
--               PostScript.lua binds every sub at the predeclaration of
--               WritePS to a closure that loads this file on first use
--               (PostScript.WritePS, the table's WRITE_PROC, ... keep
--               working for all callers).  The PostScript.pm subs upstream
--               calls by their bare names (GetNextLine, DecodeComment, ...)
--               are the PostScript module's.
--
--               Perl's `$/`, which WritePS sets with `local`, is the field
--               PostScript.RS that PostScript.lua's GetNextLine reads (saved
--               and restored on return).  Scalar references: a data
--               reference is the string itself (`$$dataPt` is dataPt);
--               DecodeComment hands the extended line back as its second
--               result.  The DOS header `$dos`, which upstream patches with
--               Set16u/Set32u, is a carray here (the port's Set16u/Set32u
--               take the buffer first); the one-argument `Set32u($val)` is
--               ExifTool.Put32u.  An in-memory output file (Perl SCALAR
--               ref) is the port's `{ value = <carray> }` box.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local carray = require('carray')
local length = perl.length
local substr = perl.substr
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local findAllDyn = perl.findAllDyn
local subst = perl.subst
local substDyn = perl.substDyn
local tr = perl.tr
local pack, unpack = perl.pack, perl.unpack
local sprintf = perl.sprintf
local keys, sort = perl.keys, perl.sort
local join = perl.join
local uc, lc = perl.uc, perl.lc
local ord = perl.ord
local num = perl.num
local truthy = perl.truthy
local str = perl.str
local Write = Writer.Write
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get32u = ExifTool.Get32u
local Set16u, Set32u = ExifTool.Set16u, ExifTool.Set32u

local PostScript = require('lexiftool.PostScript')  -- (upstream `package Image::ExifTool::PostScript`)
local WritePostScript = {}

local GetInputRecordSeparator = PostScript.GetInputRecordSeparator
local CheckPSEnd = PostScript.CheckPSEnd
local GetNextLine = PostScript.GetNextLine
local DecodeComment = PostScript.DecodeComment

-- Structure of a DSC PS/EPS document:
--
--   %!PS-Adobe-3.0     [plus " EPSF-3.0" for EPS]
--     <comments>
--   %%EndComments      [optional]
--   %%BeginXxxx
--     <stuff to ignore>
--   %%EndXxxx
--   %%BeginProlog
--     <prolog stuff>
--   %%EndProlog
--   %%BeginSetup
--     <setup stuff>
--   %%EndSetup
--   %ImageData x x x x  [written by Photoshop]
--   %BeginPhotoshop: xxxx
--     <ascii-hex IRB information>
--   %EndPhotosop
--   %%BeginICCProfile: (name) <num> <type>
--     <ICC Profile info>
--   %%EndICCProfile
--   %begin_xml_code
--     <postscript code to define and read the XMP stream object>
--   %begin_xml_packet: xxxx
--     <XMP data>
--   %end_xml_packet
--     <postscript code to add XMP stream to dictionary>
--   %end_xml_code
--   %%Page: x x         [PS only (optional?)]
--     <graphics commands>
--   %%PageTrailer
--   %%Trailer
--     <a bit more code to bracket EPS content for distiller>
--   %%EOF

-- map of where information is stored in PS image
local psMap = {
    XMP          = 'PostScript',
    Photoshop    = 'PostScript',
    IPTC         = 'Photoshop',
    EXIFInfo     = 'Photoshop',
    EXIF         = 'EXIFInfo',
    IFD0         = 'EXIFInfo',
    IFD1         = 'IFD0',
    ICC_Profile  = 'PostScript',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}


--------------------------------------------------------------------------------
-- Write XMP directory to file, with begin/end tokens if necessary
-- Inputs: 0) outfile ref, 1) flags hash ref, 2-N) data to write
-- Returns: true on success
local function WriteXMPDir(outfile, flags, ...)
    local success = 1
    if not truthy(flags.WROTE_BEGIN) then
        if not Write(outfile, '%begin_xml_code' .. PostScript.RS) then success = 0 end
    end
    if not Write(outfile, ...) then success = 0 end
    if not truthy(flags.WROTE_BEGIN) then
        if not Write(outfile, '%end_xml_code' .. PostScript.RS) then success = 0 end
    end
    return success
end

--------------------------------------------------------------------------------
-- Write a directory inside a PS document
-- Inputs: 0) ExifTool object ref, 1) output file reference,
--         2) Directory name, 3) data reference, 4) flags hash ref
-- Returns: 0=error, 1=nothing written, 2=dir written ok
local function WritePSDirectory(et, outfile, dirName, dataPt, flags)
    local success = 2
    local len = dataPt and length(dataPt) or 0
    local create = len ~= 0 and 0 or 1
    local dirInfo = {
        DataPt = dataPt,
        DataLen = len,
        DirStart = 0,
        DirLen = len,
        DirName = dirName,
        Parent = 'PostScript',
    }
    -- Note: $$flags{WROTE_BEGIN} may be 1 for XMP (it is always 0 for
    -- other dirs, but if 1, the begin/end markers were already written)
--
-- prepare necessary postscript code to support embedded XMP
--
    local beforeXMP, afterXMP, reportedLen
    if dirName == 'XMP' and len ~= 0 then
        -- isolate the XMP
        local c1, c2, p1 = matches(dataPt, [[(?s)(.*)(<\?xpacket begin=.{7,13}W5M0MpCehiHzreSzNTczkc9d)]], 0)
        if c2 == nil then
            et:Warn('No XMP packet start')
            return WriteXMPDir(outfile, flags, dataPt)
        end
        beforeXMP = c1
        local xmp = c2
        local w, p2 = matches(dataPt, [[(?s)<\?xpacket end=.(w|r).\?>]], p1)
        if w == nil then
            et:Warn('No XMP packet end')
            return WriteXMPDir(outfile, flags, dataPt)
        end
        xmp = xmp .. substr(dataPt, p1, p2-p1)
        afterXMP = substr(dataPt, p2)
        -- determine if we can adjust the XMP size
        local m = matches(beforeXMP, [[(?s)%begin_xml_packet: (\d+)]])
        if m ~= nil then
            reportedLen = m
            local matches_= findAllDyn(beforeXMP, '(?s)\\b' .. reportedLen .. '\\b')
            if #matches_ ~= 2 then reportedLen = nil end
        end
        -- must edit in place if we can't reliably change the XMP length
        if not truthy(reportedLen) then dirInfo.InPlace = 1 end
        -- process XMP only
        dirInfo.DataLen = length(xmp)
        dirInfo.DirLen = dirInfo.DataLen
        dirInfo.DataPt = xmp
    end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.' .. dirName .. '.Main')
    local val = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
    if val ~= nil then
        dataPt = val    -- use modified directory
        len = length(val)
    elseif dirName == 'XMP' then
        if len == 0 then return 1 end
        -- just write the original XMP
        return WriteXMPDir(outfile, flags, dataPt)
    end
    if len == 0 then
        if create ~= 0 or dirName ~= 'XMP' then return 1 end -- nothing to create
        -- it would be really difficult to delete the XMP,
        -- so instead we write a blank XMP record
        val = "<?xpacket begin='\xef\xbb\xbf' id='W5M0MpCehiHzreSzNTczkc9d'?>\n" ..
              "<x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk='Image::ExifTool " .. ExifTool.VERSION .. "'>\n" ..
              "</x:xmpmeta>\n"
        if not truthy((et.OPTIONS.Compact or { }).NoPadding) then
            val = val .. string.rep(string.rep(' ', 100) .. "\n", 24)
        end
        val = val .. [[<?xpacket end='w'?>]]
        dataPt = val
        len = length(val)
    end
--
-- write XMP directory
--
    if dirName == 'XMP' then
        if create ~= 0 then
            -- create necessary PS/EPS code to support XMP
            beforeXMP =
                "/pdfmark where {pop true} {false} ifelse\n" ..
                "/currentdistillerparams where {pop currentdistillerparams\n" ..
                "/CoreDistVersion get 5000 ge } {false} ifelse\n" ..
                "and not {userdict /pdfmark /cleartomark load put} if\n" ..
                "[/NamespacePush pdfmark\n" ..
                "[/_objdef {exiftool_metadata_stream} /type /stream /OBJ pdfmark\n" ..
                "[{exiftool_metadata_stream} 2 dict begin /Type /Metadata def\n" ..
                "  /Subtype /XML def currentdict end /PUT pdfmark\n" ..
                "/MetadataString " .. len .. " string def % exact length of metadata\n" ..
                "/TempString 100 string def\n" ..
                "/ConsumeMetadata {\n" ..
                "currentfile TempString readline pop pop\n" ..
                "currentfile MetadataString readstring pop pop\n" ..
                "} bind def\n" ..
                "ConsumeMetadata\n" ..
                "%begin_xml_packet: " .. len .. "\n"
            -- note: use q() to get necessary linefeed before %end_xml_packet
            afterXMP = "\n" ..
                "%end_xml_packet\n" ..
                "[{exiftool_metadata_stream} MetadataString /PUT pdfmark\n"
            if truthy(flags.EPS) then
                afterXMP = afterXMP ..
                    "[/Document 1 dict begin\n" ..
                    "  /Metadata {exiftool_metadata_stream} def currentdict end /BDC pdfmark\n" ..
                    "[/NamespacePop pdfmark\n"
                -- write this at end of file
                flags.TRAILER = '[/EMC pdfmark' .. PostScript.RS
            else -- PS
                afterXMP = afterXMP ..
                    "[{Catalog} {exiftool_metadata_stream} /Metadata pdfmark\n" ..
                    "[/NamespacePop pdfmark\n"
            end
            beforeXMP = subst(beforeXMP, [[(?s)\n]], function() return PostScript.RS end, 'g') -- use proper newline characters
            afterXMP = subst(afterXMP, [[(?s)\n]], function() return PostScript.RS end, 'g')
        else
            -- replace xmp size in PS code
            if truthy(reportedLen) then beforeXMP = substDyn(beforeXMP, '(?s)\\b' .. reportedLen .. '\\b', str(len), 'g') end
        end
        if not truthy(WriteXMPDir(outfile, flags, beforeXMP, dataPt, afterXMP)) then success = 0 end
--
-- Write Photoshop or ICC_Profile directory
--
    elseif dirName == 'Photoshop' or dirName == 'ICC_Profile' then
        local startToken, endToken
        if dirName == 'Photoshop' then
            startToken = '%BeginPhotoshop: ' .. len
            endToken = '%EndPhotoshop'
        else
            startToken = '%%BeginICCProfile: (Photoshop Profile) -1 Hex'
            endToken = '%%EndICCProfile'
        end
        if not Write(outfile, startToken, PostScript.RS) then success = 0 end
        -- write as an ASCII-hex comment
        local i
        local wid = 32
        i = 0
        while i < len do
            if wid > len-i then wid = len-i end
            local dat = substr(dataPt, i, wid)
            if not Write(outfile, '% ', uc(unpack('H*',dat)), PostScript.RS) then success = 0 end
            i = i + wid
        end
        if not Write(outfile, endToken, PostScript.RS) then success = 0 end
    else
        et:Warn("Can't write PS directory " .. dirName)
    end
    val = nil -- luacheck: ignore 311
    return success
end

--------------------------------------------------------------------------------
-- Encode postscript tag/value
-- Inputs: 0) tag ID, 1) value
-- Returns: postscript comment
-- - adds brackets, escapes special characters, and limits line length
local function EncodeTag(tag, val)
    if not isMatch(val, [[^\d+$]]) then
        val = subst(val, [[([()\\])]], [[\\$1]], 'g') -- escape brackets and backslashes
        val = subst(val, [[\n]], [[\\n]], 'g')        -- escape newlines
        val = subst(val, [[\r]], [[\\r]], 'g')        -- escape carriage returns
        val = subst(val, [[\t]], [[\\t]], 'g')        -- escape tabs
        -- use octal escape codes for other control characters
        val = subst(val, [[([\x00-\x1f\x7f\xff])]], function(c) return sprintf('\\%.3o',ord(c)) end, 'g')
        val = '(' .. val .. ')'
    end
    local line = carray.new('char'):append('%%' .. tag .. ': ' .. val)
    -- postscript line limit is 255 characters (but it seems that
    -- the limit may be 254 characters if the DOS CR/LF is used)
    -- --> split if necessary using continuation comment "%%+"
    local n
    n = 254
    while length(line)>n do
        substr(line, n, 0, PostScript.RS .. '%%+')
        n = n + 254+length(PostScript.RS)
    end
    return line:tostring() .. PostScript.RS
end

--------------------------------------------------------------------------------
-- Write new tags information in comments section
-- Inputs: 0) ExifTool object ref, 1) output file ref, 2) reference to new tag hash
-- Returns: true on success
local function WriteNewTags(et, outfile, newTags)
    local success = 1

    -- get XMP hint and remove from tags hash
    local xmpHint = newTags.XMP_HINT
    newTags.XMP_HINT = nil

    for _, tag in ipairs(sort(keys(newTags))) do
        local tagInfo = newTags[tag]
        local nvHash = Writer.GetNewValueHash(et, tagInfo)
        if not truthy(nvHash and nvHash.IsCreating) then goto continue end
        do
            local val = et:GetNewValue(nvHash)
            et:VerboseValue('+ PostScript:' .. tagInfo.Name, val)
            if not Write(outfile, EncodeTag(tag, val)) then success = 0 end
            et.CHANGED = (et.CHANGED or 0) + 1
        end
        ::continue::
    end
    -- write XMP hint if necessary
    if truthy(xmpHint) then
        if not Write(outfile, '%ADO_ContainsXMP: MainFirst' .. PostScript.RS) then success = 0 end
    end

    for k in pairs(newTags) do newTags[k] = nil end -- all done with new tags
    return success
end

--------------------------------------------------------------------------------
-- Write PS file
-- Inputs: 0) ExifTool object reference, 1) source dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PS file,
--          or -1 if a write error occurred
function WritePostScript.WritePS(et, dirInfo)
    if not et then return 1 end -- allow dummy access to autoload this package
    local tagTablePtr = GetTagTable(nil, 'lexiftool.PostScript.Main')
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout -- (unset option: upstream's default \*STDOUT)
    local data, buff, err, mode, endToken
    local flags = {}
    local dos, psStart, psNewStart, xmpHint
    local lines = {}
    local n

    n, data = raf:Read(4)
    if n ~= 4 then return 0 end
    if not isMatch(data, [[^(%!PS|%!Ad|\xc5\xd0\xd3\xc6)]]) then return 0 end

    if isMatch(data, [[^%!Ad]]) then
        -- I've seen PS files start with "%!Adobe-PS"...
        n, buff = raf:Read(6)
        if not (n == 6 and buff == 'obe-PS') then return 0 end
        data = data .. buff

    elseif isMatch(data, [[^\xc5\xd0\xd3\xc6]]) then
--
-- process DOS binary PS files
--
        -- save DOS header then seek ahead and check PS header
        n, dos = raf:Read(26)
        if n ~= 26 then return 0 end
        local dosStr = data .. dos
        dos = carray.new('char')
        dos:append(dosStr)
        SetByteOrder('II')
        psStart = Get32u(dos, 4)
        local ok = raf:Seek(psStart, 0)
        if ok then n, data = raf:Read(4); ok = n == 4 and data == '%!PS' end
        if not ok then
            et:Error('Invalid PS header')
            return 1
        end
        raf.PSEnd = psStart + Get32u(dos, 8)
        local base = Get32u(dos, 20)
        Set16u(dos, 28, 0xffff) -- ignore checksum
        if base ~= 0 then
            local dirInfo_ = {
                Parent = 'PS',
                RAF = raf,
                Base = base,
                NoTiffEnd = 1, -- no end-of-TIFF check
            }
            buff = et:WriteTIFF(dirInfo_)
            SetByteOrder('II') -- (WriteTIFF may change this)
            if truthy(buff) then
                buff = substr(buff, base)  -- remove header written by WriteTIFF()
            else
                -- error rewriting TIFF, so just copy over original data
                local len = Get32u(dos, 24)
                ok = raf:Seek(base, 0)
                if ok then n, buff = raf:Read(len); ok = n == len end
                if not ok then
                    et:Error('Error reading embedded TIFF')
                    return 1
                end
                et:Warn('Bad embedded TIFF')
            end
            Set32u(dos, 12, 0)                  -- zero metafile pointer
            Set32u(dos, 16, 0)                  -- zero metafile length
            Set32u(dos, 20, length(dos))        -- set TIFF pointer
            Set32u(dos, 24, length(buff))       -- set TIFF length
        else
            base = Get32u(dos, 12)
            if base ~= 0 then
                -- copy over metafile section
                local len = Get32u(dos, 16)
                ok = raf:Seek(base, 0)
                if ok then n, buff = raf:Read(len); ok = n == len end
                if not ok then
                    et:Error('Error reading metafile section')
                    return 1
                end
                Set32u(dos, 12, length(dos))    -- set metafile pointer
            else
                buff = ''
            end
        end
        psNewStart = length(dos) + length(buff)
        Set32u(dos, 4, psNewStart)  -- set pointer to start of PS
        if not Write(outfile, dos:tostring(), buff) then err = 1 end
        raf:Seek(psStart + 4, 0)    -- seek back to where we were
    end
--
-- rewrite PostScript data
--
    local oldRS = PostScript.RS -- (local $/)
    PostScript.RS = GetInputRecordSeparator(raf)
    if truthy(PostScript.RS) then n, buff = raf:ReadLine(PostScript.RS) end
    if not (truthy(PostScript.RS) and truthy(n)) then
        et:Error('Invalid PostScript data')
        PostScript.RS = oldRS
        return 1
    end
    data = data .. buff
    local rev = matches(data, [[^%!PS-Adobe-3\.(\d+)\b]])
    if not (rev ~= nil and num(rev) < 2) then
        if truthy(et:Error('Document does not conform to DSC spec. Metadata may be unreadable by other apps', 2)) then
            PostScript.RS = oldRS
            return 1
        end
    end
    local psRev = rev -- luacheck: ignore 211 -- save PS revision number (3.x)
    if not Write(outfile, data) then err = 1 end
    if isMatch(data, [[EPSF]]) then flags.EPS = 1 end

    -- get hash of new information keyed by tagID and directories to add/edit
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)

    -- figure out which directories we need to write (PostScript takes priority)
    Writer.InitWriteDirs(et, psMap, 'PostScript')
    local addDirs = et.ADD_DIRS
    local editDirs = et.EDIT_DIRS
    local doneDir = {}

    -- set XMP hint flag (1 for adding, 0 for deleting, undef for no change)
    if addDirs.XMP then xmpHint = 1 end
    if et.DEL_GROUP.XMP then xmpHint = 0 end
    if truthy(xmpHint) then newTags.XMP_HINT = xmpHint end -- add special tag to newTags list

    while true do
        if #lines == 0 and not truthy(GetNextLine(raf, lines)) then break end
        data = table.remove(lines, 1)
        if endToken then
            -- look for end token
            if isMatchDyn(data, '(?is)^' .. endToken .. [[\s*$]]) then
                endToken = nil
                -- found end: process this information
                if mode then
                    if doneDir[mode] then et:Error('Multiple ' .. mode .. ' directories', 1) end
                    doneDir[mode] = 1
                    if not truthy(WritePSDirectory(et, outfile, mode, buff:tostring(), flags)) then err = 1 end
                    -- write end token if we wrote the begin token
                    if truthy(flags.WROTE_BEGIN) then
                        if not Write(outfile, data) then err = 1 end
                    end
                    buff = nil
                else
                    if not Write(outfile, data) then err = 1 end
                end
            else
                -- buffer data in current begin/end block
                if mode == nil then
                    -- pick up XMP in unrecognized blocks for editing in place
                    if isMatch(data, [[^<\?xpacket begin=.{7,13}W5M0MpCehiHzreSzNTczkc9d]]) and
                        editDirs.XMP
                    then
                        buff = carray.new('char'):append(data)
                        mode = 'XMP'
                    else
                        if not Write(outfile, data) then err = 1 end
                    end
                elseif mode == 'XMP' then
                    buff:append(data)
                else
                    -- data is ASCII-hex encoded
                    data = tr(data, '0-9A-Fa-f', '', 'dc') -- remove all but hex characters
                    buff:append(pack('H*', data)) -- translate from hex
                end
            end
            goto continue
        end
        do
            local c1, c2, c3 = matches(data, [=[(?i)^(%{1,2})(Begin)(?!Object:)(.*?)[:\x0d\x0a]]=])
            if c1 ~= nil then
                -- comments section is over... write any new tags now
                if next(newTags) ~= nil then
                    if not truthy(WriteNewTags(et, outfile, newTags)) then err = 1 end
                end
                xmpHint = nil
                -- the beginning of a data block (can only write XMP and Photoshop)
                local modeLookup = {
                    _xml_code = 'XMP',
                    photoshop = 'Photoshop',
                    iccprofile = 'ICC_Profile',
                }
                if num(verbose) > 1 then out:write(c2 .. c3 .. "\n") end
                endToken = c1 .. (c2 == 'begin' and 'end' or 'End') .. c3
                mode = modeLookup[lc(c3)]
                if mode and editDirs[mode] then
                    buff = carray.new('char')   -- initialize buffer for this block
                    flags.WROTE_BEGIN = 0
                else
                    mode = nil  -- not editing this directory
                    if not Write(outfile, data) then err = 1 end
                    flags.WROTE_BEGIN = 1
                end
                goto continue
            end
        end
        do
            local tag, val = matches(data, [[(?s)^%%(?!Page:|PlateFile:|BeginObject:)(\w+): ?(.*)]])
            if tag ~= nil then
                -- rewrite information from PostScript tags in comments
                -- handle Adobe Illustrator files specially
                -- - EVENTUALLY IT WOULD BE BETTER TO FIND ANOTHER IDENTIFICATION METHOD
                --   (because Illustrator doesn't care if the Creator is changed)
                if tag == 'Creator' and isMatch(val, [[^Adobe Illustrator]]) then
                    -- disable writing XMP to PostScript-format Adobe Illustrator files
                    -- because it confuses Illustrator
                    if editDirs.XMP then
                        et:Warn("Can't write XMP to PostScript-format Illustrator files")
                        -- pretend like we wrote it already so we won't try to add it later
                        doneDir.XMP = 1
                    end
                    -- don't allow "Creator" to be changed in Illustrator files
                    -- (we need it to be able to recognize these files)
                    -- --> find a better way to do this!
                    if newTags[tag] then
                        et:Warn("Can't change Postscript:Creator of Illustrator files")
                        newTags[tag] = nil
                    end
                end
                if newTags[tag] then
                    local tagInfo = newTags[tag]
                    newTags[tag] = nil -- write it then forget it
                    if type(tagInfo) ~= 'table' then goto continue end
                    -- decode comment string (reading continuation lines if necessary)
                    val, data = DecodeComment(val, raf, lines, data)
                    if type(val) == 'table' then val = join(et:Options('ListSep'), val) end
                    local nvHash = Writer.GetNewValueHash(et, tagInfo)
                    if truthy(Writer.IsOverwriting(et, nvHash, val)) then
                        et:VerboseValue('- PostScript:' .. tagInfo.Name, val)
                        val = et:GetNewValue(nvHash)
                        et.CHANGED = (et.CHANGED or 0) + 1
                        if val == nil then goto continue end  -- next if tag is being deleted
                        et:VerboseValue('+ PostScript:' .. tagInfo.Name, val)
                        data = EncodeTag(tag, val)
                    end
                end
                goto write
            end
        end
        -- (note: Adobe InDesign doesn't put colon after %ADO_ContainsXMP -- doh!)
        do
            local hint
            if xmpHint ~= nil then hint = matches(data, [[(?s)^%ADO_ContainsXMP:? ?(.+?)[\x0d\x0a]*$]]) end
            if hint ~= nil then
                -- change the XMP hint if necessary
                if truthy(xmpHint) then
                    if hint == 'NoMain' then data = '%ADO_ContainsXMP: MainFirst' .. PostScript.RS end
                else
                    data = '%ADO_ContainsXMP: NoMain' .. PostScript.RS
                end
                -- delete XMP hint flags
                newTags.XMP_HINT = nil
                xmpHint = nil
            else
                -- look for end of comments section
                if next(newTags) ~= nil and (not isMatch(data, [[^%\S]]) or
                    isMatch(data, [[^%(%EndComments|%Page:|%PlateFile:|%BeginObject:|.*BeginLayer)]]))
                then
                    -- write new tags at end of comments section
                    if not truthy(WriteNewTags(et, outfile, newTags)) then err = 1 end
                    xmpHint = nil
                end
                -- look for start of drawing commands (AI uses "%AI5_BeginLayer",
                -- and Helios uses "%%BeginObject:")
                if isMatch(data, [[^%(%Page:|%PlateFile:|%BeginObject:|.*BeginLayer)]]) or
                    not isMatch(data, [[(?s)^(%.*|\s*)$]])
                then
                    -- we have reached the first page or drawing command, so create necessary
                    -- directories and copy the rest of the file, then all done
                    local plateFile = isMatch(data, [[^%%PlateFile:]])
                    -- create Photoshop first, then XMP if necessary
                    for _, dir in ipairs({ 'Photoshop', 'ICC_Profile', 'XMP' }) do
                        if not (editDirs[dir] and not doneDir[dir]) then goto nextDir end
                        if plateFile then
                            -- PlateFile comments may contain offsets so we can't edit these files!
                            et:Warn('Can only edit PostScript information DCS Plate files')
                            break
                        end
                        if not (addDirs[dir] or dir == 'XMP') then goto nextDir end
                        flags.WROTE_BEGIN = 0
                        if not truthy(WritePSDirectory(et, outfile, dir, nil, flags)) then err = 1 end
                        doneDir[dir] = 1
                        ::nextDir::
                    end
                    -- copy rest of file
                    if flags.TRAILER then
                        -- write trailer before %%EOF
                        while true do
                            if not Write(outfile, data) then err = 1 end
                            if #lines > 0 then
                                data = table.remove(lines, 1)
                            else
                                n, data = raf:ReadLine(PostScript.RS)
                                if not truthy(n) then data = nil break end
                                if dos then data = CheckPSEnd(raf, data) end
                                local m, e = matches(data, [=[[\x0d\x0a]%%EOF\b]=])
                                if m ~= nil then
                                    -- split data before "%%EOF"
                                    -- (necessary if data contains other newline sequences)
                                    local pos = e - 5
                                    table.insert(lines, substr(data, pos))
                                    data = substr(data, 0, pos)
                                end
                            end
                            if isMatch(data, [[^%%EOF\b]]) then break end
                        end
                        if not Write(outfile, flags.TRAILER) then err = 1 end
                    end
                    -- simply copy the rest of the file if any data is left
                    if data ~= nil then
                        if not Write(outfile, data) then err = 1 end
                        if #lines > 0 then
                            if not Write(outfile, table.unpack(lines)) then err = 1 end
                        end
                        while true do
                            n, data = raf:Read(65536)
                            if not truthy(n) then break end
                            if dos then data = CheckPSEnd(raf, data) end
                            if not Write(outfile, data) then err = 1 end
                        end
                    end
                    break   -- all done!
                end
            end
        end
        ::write::
        -- write new information or copy existing line
        if not Write(outfile, data) then err = 1 end
        ::continue::
    end
    if dos and not err then
        -- must go back and set length of PS section in DOS header (very dumb design)
        if io.type(outfile) ~= 'file' then  -- (`ref $outfile eq 'SCALAR'`)
            Set32u(outfile.value, 8, length(outfile.value) - psNewStart)
        else
            local pos = outfile:seek('cur')
            if not (outfile:seek('set', 8) and
                    outfile:write(ExifTool.Put32u(pos - psNewStart)) and
                    outfile:seek('set', pos))
            then
                et:Error("Can't write DOS-style PS files in non-seekable stream")
                err = 1
            end
        end
    end
    -- issue warning if we couldn't write any information
    if not err then
        local notDone = {}
        newTags.XMP_HINT = nil
        if next(newTags) ~= nil then notDone[#notDone + 1] = 'PostScript' end
        for _, dir in ipairs({ 'Photoshop', 'ICC_Profile', 'XMP' }) do
            if editDirs[dir] and not doneDir[dir] and
               not et.DEL_GROUP[dir] then notDone[#notDone + 1] = dir end
        end
        if #notDone > 0 then et:Warn("Couldn't write " .. join('/',notDone) .. ' information') end
    end
    if endToken then et:Error('File missing ' .. endToken) end
    PostScript.RS = oldRS   -- (end of `local $/`)
    return err and -1 or 1
end

-- (the subs above, for PostScript.lua's AUTOLOAD closures)
WritePostScript.WriteXMPDir = WriteXMPDir
WritePostScript.WritePSDirectory = WritePSDirectory
WritePostScript.EncodeTag = EncodeTag
WritePostScript.WriteNewTags = WriteNewTags

return WritePostScript -- end
