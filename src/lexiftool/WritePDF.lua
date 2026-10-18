--------------------------------------------------------------------------------
-- File:         lexiftool/WritePDF.lua
-- Ported from:  lib/Image/ExifTool/WritePDF.pl
--
-- Description:  Write PDF meta information
--
-- Revisions:    12/08/2007 - P. Harvey Created
--
-- References:   1) http://partners.adobe.com/public/developer/pdf/index_reference.html
--
-- Notes:        The special "PDF-update" group can be deleted to revert exiftool updates
--
-- Port notes:   All subs of WritePDF.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::PDF package and
--               AUTOLOADs it on the first call of one of its subs; this port
--               makes it a module of its own, and PDF.lua binds every sub at
--               its predeclaration position to a closure that loads this
--               file on first use (PDF.WritePDF, PDF.CheckPDF,
--               PDF.WritePDFValue, ... keep working for all callers).
--
--               PDF objects as in PDF.lua (a dictionary has a `_tags` list,
--               an indirect reference is `{ ref = 'SCALAR', value = 'N G R' }`,
--               PDF.ref stands in for Perl's ref()).  Scalar references:
--               CheckPDF is a CHECK_PROC and follows the port's convention
--               for those (value in; error and the possibly changed value
--               out).  EncodeString and CryptObject update their argument
--               through a reference (or Perl's @_ alias) upstream; here they
--               return the new value and the caller stores it.  The package
--               variable $lastFetched is PDF.lastFetched; Perl's `$/`, which
--               WritePDF sets with `local`, is the module local RS (restored
--               on return).  The XMP packet ImageInfo returns is a
--               { ref = 'SCALAR', value = ... } box; DataPt is its string.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `package Image::ExifTool::PDF`, Image::ExifTool's subs)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local length = perl.length
local substr = perl.substr
local carray = require('carray')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local tr = perl.tr
local pack, unpack = perl.pack, perl.unpack
local sprintf = perl.sprintf
local keys, sort = perl.keys, perl.sort
local join = perl.join
local hex = perl.hex
local chr, ord = perl.chr, perl.ord
local int = perl.int
local num = perl.num
local truthy = perl.truthy
local Write = Writer.Write
local Tell = Writer.Tell
local GetTagTable = ExifTool.GetTagTable

local PDF = require('lexiftool.PDF')    -- (upstream `package Image::ExifTool::PDF`)
local WritePDF = {}

local ref = PDF.ref
local Crypt, CryptStream = PDF.Crypt, PDF.CryptStream
local ReadPDFValue, LocateObject = PDF.ReadPDFValue, PDF.LocateObject

-- (upstream's predeclarations `sub WriteObject($$);` ... are this block of
--  locals; the subs below assign to them)
local WriteObject, EncodeString, CryptObject

-- comments to mark beginning and end of ExifTool incremental update
local beginComment = '%BeginExifToolUpdate'
local endComment   = '%EndExifToolUpdate '

local keyExt     -- crypt key extension
local pdfVer     -- version of PDF file we are writing (highest Version in Root dictionaries)

-- (Perl's input record separator `$/`, which WritePDF sets with `local`)
local RS = "\n"

-- internal tags used in dictionary objects
local myDictTags = {
    _tags = 1, _stream = 1, _decrypted = 1, _needCrypt = 1,
    _filtered = 1, _entry_size = 1, _table = 1,
}

-- map for directories that we can add
local pdfMap = {
    XMP = 'PDF',
}

--------------------------------------------------------------------------------
-- Validate raw PDF values for writing (string date integer real boolean name)
-- Inputs: 0) ExifTool object ref, 1) tagInfo hash ref, 2) raw value ref
-- Returns: error string or undef (and possibly changes value) on success
local function CheckPDF(_et, tagInfo, valPtr)
    local format = tagInfo.Writable or tagInfo.Table.WRITABLE
    if not truthy(format) then
        return 'No writable format'
    elseif format == 'string' then -- luacheck: ignore 542
        -- (encode later because list-type string tags need to be encoded as a unit)
    elseif format == 'date' then
        -- be flexible about this for now
        if not isMatch(valPtr, [[^\d{4}]]) then return 'Bad date format' end
    elseif format == 'integer' then
        if not ExifTool.IsInt(valPtr) then return 'Not an integer' end
    elseif format == 'real' then
        if not isMatch(valPtr, [[^[+-]?(?=\d|\.\d)\d*(\.\d*)?$]]) then return 'Not a real number' end
    elseif format == 'boolean' then
        valPtr = (truthy(valPtr) and not isMatch(valPtr, [[(?i)^f]])) and 'true' or 'false'
    elseif format == 'name' then
        if isMatch(valPtr, [[\0]]) then return 'Invalid PDF name' end
    else
        return "Invalid PDF format '" .. format .. "'"
    end
    return nil, valPtr   -- value is OK
end

--------------------------------------------------------------------------------
-- Format value for writing to PDF file
-- Inputs: 0) ExifTool ref, 1) value, 2) format string (string,date,integer,real,boolean,name)
-- Returns: formatted value or undef on error
-- Notes: Called at write time, so $pdfVer may be checked
local function WritePDFValue(et, val, format)
    if not truthy(format) then
        return nil
    elseif format == 'string' then
        -- encode as UCS2 if it contains any special characters
        if isMatch(val, [=[[\x80-\xff]]=]) then val = "\xfe\xff" .. et:Encode(val, 'UCS2', 'MM') end
        val = EncodeString(val)
    elseif format == 'date' then
        -- convert date to "D:YYYYmmddHHMMSS+-HH'MM'" format
        val = subst(val, [[(:\d{2})\.\d*]], '$1')              -- remove sub-seconds
        val = subst(val, [[([-+]\d{2}):(\d{2})]], "${1}'${2}'")  -- change timezone delimiters if necessary
        val = tr(val, ' :', '', 'd')                           -- remove spaces and colons
        val =  'D:' .. val                                     -- add leading "D:"
        val = EncodeString(val)
    elseif isMatch(format, [[^(integer|real|boolean)$]]) then -- luacheck: ignore 542
        -- no reformatting necessary
    elseif format == 'name' then
        if isMatch(val, [[\0]]) then return nil end
        if num(pdfVer) >= 1.2 then
            val = subst(val, [=[([\t\n\f\r ()<>[\]{}\/%#])]=], function(c) return sprintf('#%.2x', ord(c)) end, 'g')
        else
            if isMatch(val, [=[[\t\n\f\r ()<>[\]{}\/%]]=]) then return nil end
        end
        val = '/' .. val -- add leading '/'
    else
        return nil
    end
    return val
end

--------------------------------------------------------------------------------
-- Encode PDF string
-- Inputs: 0) reference to PDF string
-- Returns: (updates string with encoded data)
-- (returns the encoded string, see the port notes)
function EncodeString(strPt)
    if ref(strPt) == 'ARRAY' then
        for i, str in ipairs(strPt) do
            strPt[i] = EncodeString(str)
        end
        return strPt
    end
    strPt = Crypt(strPt, keyExt, 1)  -- encrypt if necessary
    -- encode as hex if we have any control characters (except tab)
    if isMatch(strPt, [=[[\x00-\x08\x0a-\x1f\x7f\xff]]=]) then
        -- encode as hex
        local str = carray.new('char')
        local len = length(strPt)
        local i = 0
        while true do
            local n = len - i
            if n == 0 then break end
            if n > 40 then n = 40 end -- break into reasonable-length lines
            if i ~= 0 then str:append(RS) end
            str:append(unpack('H*', substr(strPt, i, n)))
            i = i + n
        end
        strPt = '<' .. str:tostring() .. '>'
    else
        strPt = subst(strPt, [[([()\\])]], [[\\$1]], 'g')    -- must escape round brackets and backslashes
        strPt = '(' .. strPt .. ')'
    end
    return strPt
end

--------------------------------------------------------------------------------
-- Encrypt an object
-- Inputs: 0) PDF object (encrypts in place)
-- Notes: Encrypts according to "_needCrypt" dictionary entry,
--        then deletes "_needCrypt" when done
-- (a string comes back as the return value instead of through Perl's @_
--  alias; dictionaries and arrays are still encrypted in place)
function CryptObject(obj)
    if ref(obj) == '' then
        -- only literal strings and hex strings are encrypted
        if isMatch(obj, [=[^[(<]]=]) then
            PDF.lastFetched = nil -- (reset this just in case)
            local val = ReadPDFValue(obj)
            val = EncodeString(val)
            obj = val
        end
    elseif ref(obj) == 'HASH' then
        local needCrypt = obj._needCrypt
        for _, tag in ipairs(keys(obj)) do
            if myDictTags[tag] then goto continue end
            -- re-encrypt necessary objects only (others are still encrypted)
            -- (this is really annoying, but is necessary because objects stored
            -- in encrypted streams are decrypted when extracting, but strings stored
            -- as direct objects are decrypted later since they must be decoded
            -- before being decrypted)
            if needCrypt then
                local c
                if needCrypt[tag] ~= nil then c = needCrypt[tag] else c = needCrypt['*'] end
                if not truthy(c) then goto continue end
            end
            obj[tag] = CryptObject(obj[tag])
            ::continue::
        end
        obj._needCrypt = nil   -- avoid re-re-crypting
    elseif ref(obj) == 'ARRAY' then
        for i, val in ipairs(obj) do
            obj[i] = CryptObject(val)
        end
    end
    return obj
end

--------------------------------------------------------------------------------
-- Get free entries from xref stream dictionary that we wrote previously
-- Inputs: 0) xref dictionary reference
-- Returns: free entry hash (keys are object numbers, values are xref entry list refs)
local function GetFreeEntries(dict)
    local xrefFree = {}
    -- we write xref stream entries in 'CNn' or 'CNNn' format (with 8-byte 'NN' offset),
    local w = dict.W
    if ref(w) == 'ARRAY' then
        local bytes = join(' ', w)
        local fmt
        if bytes == '1 4 2' then
            fmt = 'CNn'
        elseif bytes == '1 8 2' then
            fmt = 'CNNn'
        else
            return xrefFree
        end
        local size = dict._entry_size -- this will be 7 for 'CNn' or 11 for 'CNNn'
        local index = dict.Index
        local len = length(dict._stream)
        -- scan the table for free objects
        local num_ = #index / 2
        local pos = 0
        local i, j
        i = 0
        while i < num_ do
            local start = num(index[i*2 + 1])
            local count = num(index[i*2+1 + 1])
            j = 0
            while j < count do
                if pos + size > len then break end
                local t = { unpack('x' .. pos .. ' ' .. fmt, dict._stream) }
                if #t == 4 then
                    t[2] = t[2] * 4294967296 + t[3]
                    t[3] = t[4]
                    t = { 3 }
                end
                -- add entry if object was free
                if t[1] == 0 then xrefFree[start+j] = { t[2], t[3], 'f' } end
                pos = pos + size -- step to next entry
                j = j + 1
            end
            i = i + 1
        end
    end
    return xrefFree
end

--------------------------------------------------------------------------------
-- Write PDF object
-- Inputs: 0) output file or scalar ref, 1) PDF object
-- Returns: true on success
-- Notes: inserts white space before object, but none afterward
function WriteObject(outfile, obj)
    if ref(obj) == 'SCALAR' then
        if not Write(outfile, ' ', obj.value) then return 0 end
    elseif ref(obj) == 'ARRAY' then
        -- write array
        if not Write(outfile, #obj > 10 and RS or ' ', '[') then return 0 end
        for _, item in ipairs(obj) do
            if not truthy(WriteObject(outfile, item)) then return 0 end
        end
        if not Write(outfile, ' ]') then return 0 end
    elseif ref(obj) == 'HASH' then
        -- write dictionary
        if not Write(outfile, RS, '<<') then return 0 end
        -- prepare object as required if it has a stream
        if truthy(obj._stream) then
            -- encrypt stream if necessary (must be done before determining Length)
            if truthy(obj._decrypted) then CryptStream(obj, keyExt) end
            -- write "Length" entry in dictionary
            obj.Length = length(obj._stream)
            table.insert(obj._tags, 'Length')
            -- delete Filter-related entries since we don't yet write filtered streams
            obj.Filter = nil
            obj.DecodeParms = nil
            obj.DL = nil
        end
        -- don't write my internal entries
        local wrote = {}
        for k, v in pairs(myDictTags) do wrote[k] = v end
        -- write tags in original order, adding new ones later alphabetically
        local tags = {}
        for _, tag in ipairs(obj._tags) do tags[#tags + 1] = tag end
        for _, tag in ipairs(sort(keys(obj))) do tags[#tags + 1] = tag end
        for _, tag in ipairs(tags) do
            -- ignore already-written or missing entries
            if wrote[tag] or obj[tag] == nil then goto continue end
            if not Write(outfile, RS, '/' .. tag) then return 0 end
            if not truthy(WriteObject(outfile, obj[tag])) then return 0 end
            wrote[tag] = 1
            ::continue::
        end
        if not Write(outfile, RS, '>>') then return 0 end
        if truthy(obj._stream) then
            -- write object stream
            -- (a single 0x0d may not follow 'stream', so use 0x0d+0x0a here to be sure)
            if not Write(outfile, RS, "stream\x0d\x0a") then return 0 end
            if not Write(outfile, obj._stream, RS, 'endstream') then return 0 end
        end
    else
        -- write string, number, name or object reference
        Write(outfile, ' ', obj)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Write PDF File
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if not valid PDF file, -1 on write error
-- Notes: dictionary structure:  Main --+--> Info
--                                      +--> Root --> Metadata
function WritePDF.WritePDF(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local buff, capture, newXRef, newObj = nil, {}, {}, {} -- luacheck: ignore 311
    local out, id, gen

    -- make sure this is a PDF file
    local pos = raf:Tell()
    local n
    n, buff = raf:Read(1024)
    if n < 8 then return 0 end
    local lead = matches(buff, [[^(\s*)%PDF-(\d+\.\d+)]])
    if lead == nil then return 0 end
    et.PDFBase = length(lead)
    raf:Seek(pos, 0)

    -- create a new ExifTool object and use it to read PDF and XMP information
    local newTool = ExifTool.new()
    newTool:Options('List', 1)
    newTool:Options('Password', et:Options('Password'))
    newTool:Options('NoPDFList', et:Options('NoPDFList'))
    newTool.PDF_CAPTURE = capture
    local info = newTool:ImageInfo(raf, 'XMP', 'PDF:*', 'Error', 'Warning')
    -- not a valid PDF file unless we got a version number
    pdfVer = newTool.PDFVersion
    if not truthy(pdfVer) then et:Error('Missing PDF:PDFVersion') return 0 end
    -- check version number
    if num(pdfVer) > 2.0 then
        if truthy(et:Error('Writing PDF ' .. pdfVer .. ' is untested', 1)) then return 0 end
    end
    -- fail if we had any serious errors while extracting information
    if capture.Error or info.Error then
        et:Error(capture.Error or info.Error)
        return 1
    end
    -- make sure we have everything we need to rewrite this file
    for _, obj in ipairs({ 'Main', 'Root', 'xref' }) do
        if capture[obj] then goto continue end
        -- any warning we received may give a clue about why this object is missing
        if info.Warning then et:Error(info.Warning) end
        et:Error("Can't find " .. obj .. ' object')
        do return 1 end
        ::continue::
    end
    Writer.InitWriteDirs(et, pdfMap, 'XMP')

    -- copy file up to start of previous exiftool update or end of file
    -- (comment, startxref & EOF with 11-digit offsets and 2-byte newlines is 63 bytes)
    if not raf:Seek(-64,2) then return -1 end
    n, buff = raf:Read(64)
    if not truthy(n) or not raf:Seek(0,0) then return -1 end
    local rtn = 1
    local prevUpdate
    -- (now $endComment is before "startxref", but pre-7.41 we wrote it after the EOF)
    local m1 = matches(buff, '(?s)' .. endComment .. [[(\d+)\s+(startxref\s+\d+\s+%%EOF\s+)?$]])
    if m1 ~= nil then
        prevUpdate = num(m1)
        -- rewrite the file up to the original EOF
        if not truthy(Writer.CopyBlock(raf, outfile, prevUpdate + et.PDFBase)) then rtn = -1 end
        -- verify that we are now at the start of an ExifTool update
        n, buff = raf:Read(length(beginComment))
        if not (truthy(n) and buff == beginComment) then
            et:Error('Previous ExifTool update is corrupted')
            return rtn
        end
        if not raf:Seek(prevUpdate+et.PDFBase, 0) then rtn = -1 end
        if et.DEL_GROUP['PDF-update'] then
            et:VPrint(0, "  Reverted previous ExifTool updates\n")
            et.CHANGED = (et.CHANGED or 0) + 1
            return rtn
        end
    elseif et.DEL_GROUP['PDF-update'] then
        et:Error('File contains no previous ExifTool update')
        return rtn
    else
        -- rewrite the whole file
        while true do
            n, buff = raf:Read(65536)
            if not truthy(n) then break end
            if not Write(outfile, buff) then rtn = -1 end
        end
    end
    if truthy(et:Options('Verbose')) then out = et:Options('TextOut') or io.stdout end -- (unset option: upstream's default \*STDOUT)
--
-- create our new PDF objects to write
--
    local xref = capture.xref
    local mainDict = capture.Main
    local metaRef = capture.Root.Metadata
    local nextObject

    -- start by finding reference for info object in case it was deleted
    -- in a previous edit so we can re-use it here if adding PDF Info
    local prevInfoRef
    if prevUpdate then
        if not capture.Prev then
            et:Error("Can't locate trailer dictionary prior to last edit")
            return rtn
        end
        prevInfoRef = capture.Prev.Info
        -- start from previous size so the xref table doesn't continue
        -- to grow if we repeatedly add and delete the Metadata object
        nextObject = num(capture.Prev.Size)
        -- don't re-use Meta reference if object was added in a previous update
        if metaRef then
            local m = matches(metaRef.value, [[^(\d+)]])
            if m ~= nil and num(m) >= nextObject then metaRef = nil end
        end
    else
        prevInfoRef = mainDict.Info
        nextObject = num(mainDict.Size)
    end

    -- delete entire PDF group if specified
    local infoChanged = 0
    if et.DEL_GROUP.PDF and capture.Info then
        capture.Info = nil
        info = { XMP = info.XMP } -- remove extracted PDF tags
        if out then out:write("  Deleting PDF Info dictionary\n") end
        infoChanged = infoChanged + 1
    end

    -- create new Info dictionary if necessary
    if not capture.Info then capture.Info = { _tags = { } } end
    local infoDict = capture.Info

    -- must pre-determine Info reference to be used in encryption
    local infoRef = prevInfoRef or { ref = 'SCALAR', value = nextObject .. ' 0 R' }
    if ref(infoRef) ~= 'SCALAR' then
        et:Error('Info dictionary is not an indirect object')
        return rtn
    end
    keyExt = infoRef.value

    -- must encrypt all values in dictionary if they came from an encrypted stream
    if infoDict._needCrypt then CryptObject(infoDict) end

    -- must set line separator before calling WritePDFValue()
    local oldRS = RS
    RS = capture.newline

    -- rewrite PDF Info tags
    local newTags = Writer.GetNewTagInfoHash(et, PDF.Info)
    for _, tagID in ipairs(sort(keys(newTags))) do
        local tagInfo = newTags[tagID]
        if num(pdfVer) >= 2.0 and not tagInfo.PDF2 then
            if truthy(et:Warn('Writing PDF:' .. tagInfo.Name .. ' is deprecated for PDF 2.0 documents',2)) then goto continue end
        end
        do
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            local vals, deleted = {}, nil
            local tag = tagInfo.Name
            local val = info[tag]
            local tagKey = tag -- luacheck: ignore 311
            if val == nil then
                -- must check for tag key with copy number
                tagKey = nil
                for _, k in ipairs(keys(info)) do
                    if isMatchDyn(k, '^' .. tag) then tagKey = k break end
                end
                if tagKey then val = info[tagKey] end
            end
            if val ~= nil then
                local oldVals = {}
                if ref(val) == 'ARRAY' then
                    for k = 1, #val do oldVals[k] = val[k] end
                    val = table.remove(oldVals, 1)
                end
                while true do
                    if Writer.IsOverwriting(et, nvHash, val) > 0 then
                        deleted = 1
                        et:VerboseValue('- PDF:' .. tag, val)
                        infoChanged = infoChanged + 1
                    else
                        vals[#vals + 1] = val
                    end
                    if #oldVals == 0 then break end
                    val = table.remove(oldVals, 1)
                end
                -- don't write this out if we deleted all values
                if #vals == 0 then infoDict[tagID] = nil end
            elseif nvHash.EditOnly then
                goto continue
            end
            -- decide whether we want to write this tag
            -- (native PDF information is always preferred, so don't check IsCreating)
            if not (deleted or tagInfo.List or infoDict[tagID] == nil) then goto continue end

            -- add new values to existing ones
            local newVals = et:GetNewValue(nvHash, true) or {}
            if #newVals > 0 then
                for _, v in ipairs(newVals) do vals[#vals + 1] = v end
                infoChanged = infoChanged + 1
                if out then
                    for _, v in ipairs(newVals) do
                        et:VerboseValue('+ PDF:' .. tag, v)
                    end
                end
            end
            if #vals == 0 then
                -- remove this entry from the Info dictionary if no values remain
                infoDict[tagID] = nil
                goto continue
            end
            -- format value(s) for writing to PDF file
            local writable = tagInfo.Writable or PDF.Info.WRITABLE
            if not tagInfo.List then
                val = WritePDFValue(et, table.remove(vals, 1), writable)
            elseif tagInfo.List == 'array' then
                for k = 1, #vals do
                    vals[k] = WritePDFValue(et, vals[k], writable)
                    if vals[k] == nil then vals = {} break end
                end
                if #vals > 0 then val = vals else val = nil end
            else
                val = WritePDFValue(et, join(et:Options('ListSep'), vals), writable)
            end
            if val ~= nil then
                infoDict[tagID] = val
                infoChanged = infoChanged + 1
            else
                et:Warn('Error converting ' .. tagInfo.Name .. ' value')
            end
        end
        ::continue::
    end
    if infoChanged ~= 0 then
        et.CHANGED = (et.CHANGED or 0) + infoChanged
    elseif prevUpdate then
        -- must still write Info dictionary if it was previously updated
        local oldPos = LocateObject(xref, infoRef.value)
        if truthy(oldPos) and oldPos > prevUpdate then infoChanged = 1 end
    end

    -- create new Info dictionary if necessary
    if infoChanged ~= 0 then
        -- increment object count if we used a new object here
        if #keys(capture.Info) > 1 then
            newObj[infoRef.value] = capture.Info-- save to write later
            mainDict.Info = infoRef         -- add reference to trailer dictionary
            if not prevInfoRef then nextObject = nextObject + 1 end
        else
            -- remove Info from Main (trailer) dictionary
            mainDict.Info = nil
            -- write free entry in xref table if Info existed prior to all edits
            if prevInfoRef then newObj[infoRef.value] = '' end
        end
    end

    -- rewrite XMP
    local xmpInfo = {
        DataPt = info.XMP and info.XMP.value,
        Parent = 'PDF',
    }
    local xmpTable = GetTagTable(nil, 'lexiftool.XMP.Main')
    local oldChanged = et.CHANGED
    local newXMP = Writer.WriteDirectory(et, xmpInfo, xmpTable)
    if newXMP == nil then newXMP = info.XMP and info.XMP.value or '' end

    -- WriteDirectory() will increment CHANGED erroneously if non-existent
    -- XMP is deleted as a block -- so check for this
    if not (truthy(newXMP) or info.XMP) then
        et.CHANGED = oldChanged
        et:VPrint(0, "  (XMP not changed -- still empty)\n")
    end
    local metaChanged, rootChanged

    if (et.CHANGED or 0) ~= (oldChanged or 0) and newXMP ~= nil then
        metaChanged = 1
    elseif prevUpdate and capture.Root.Metadata then
        -- must still write Metadata dictionary if it was previously updated
        local oldPos = LocateObject(xref, capture.Root.Metadata.value)
        if truthy(oldPos) and oldPos > prevUpdate then metaChanged = 1 end
    end
    if metaChanged then
        if truthy(newXMP) then
            if ref(metaRef) == '' then
                -- allocate new PDF object
                metaRef = { ref = 'SCALAR', value = nextObject .. ' 0 R' }
                nextObject = nextObject + 1
                capture.Root.Metadata = metaRef
                rootChanged = 1 -- set flag to replace Root dictionary
            end
            -- create the new metadata dictionary to write later
            newObj[metaRef.value] = {
                Type       = '/Metadata',
                Subtype    = '/XML',
              -- Length     = length newXMP, (set by WriteObject)
                _tags      = { 'Type', 'Subtype' },
                _stream    = newXMP,
                _decrypted = 1, -- (this will be ignored if EncryptMetadata is false)
            }
        elseif capture.Root.Metadata then
            -- free existing metadata object
            newObj[capture.Root.Metadata.value] = ''
            capture.Root.Metadata = nil
            rootChanged = 1 -- set flag to replace Root dictionary
        end
    end
    -- add new Root dictionary if necessary
    local rootRef = mainDict.Root
    if not rootRef then
        et:Error("Can't find Root dictionary")
        RS = oldRS
        return rtn
    end
    if not rootChanged and prevUpdate then
        -- must still write Root dictionary if it was previously updated
        local oldPos = LocateObject(xref, rootRef.value)
        if truthy(oldPos) and oldPos > prevUpdate then rootChanged = 1 end
    end
    if rootChanged then newObj[rootRef.value] = capture.Root end
--
-- write incremental update if anything was changed
--
    if truthy(et.CHANGED) then
        -- remember position of original EOF
        local oldEOF = Tell(outfile) - et.PDFBase
        if not Write(outfile, beginComment) then rtn = -1 end

        -- write new objects
        for _, objRef in ipairs(sort(keys(newObj))) do
            local c1, c2 = matches(objRef, [[^(\d+) (\d+)]])
            if c1 == nil then rtn = -1 break end
            id, gen = num(c1), c2
            if not truthy(newObj[objRef]) then
                gen = num(gen)
                if gen < 65535 then gen = gen + 1 end
                -- write free entry in xref table
                newXRef[id] = { 0, gen, 'f' }
                goto continue
            end
            -- create new entry for xref table
            newXRef[id] = { Tell(outfile) - et.PDFBase + length(RS), gen, 'n' }
            keyExt = id .. ' ' .. gen .. ' obj' -- (must set for stream encryption)
            if not Write(outfile, RS, keyExt) then rtn = -1 end
            if not truthy(WriteObject(outfile, newObj[objRef])) then rtn = -1 end
            if not Write(outfile, RS, 'endobj') then rtn = -1 end
            ::continue::
        end

        -- Prev points to old xref table
        if not prevUpdate then mainDict.Prev = capture.startxref end

        -- add xref entry for head of free-object list
        newXRef[0] = { 0, 65535, 'f' }

        -- must insert free xref entries from previous exiftool update if applicable
        if prevUpdate then
            local mainFree
            -- extract free entries from our previous Main xref stream
            if truthy(mainDict.Type) and mainDict.Type == '/XRef' then
                mainFree = GetFreeEntries(xref.dicts[1])
            else
                -- free entries from Main xref table already captured for us
                mainFree = capture.mainFree
            end
            for _, id_ in ipairs(sort(keys(mainFree), function(a, b) return a - b end)) do
                if not newXRef[id_] then newXRef[id_] = mainFree[id_] end
            end
        end

        -- connect linked list of free object in our xref table
        local prevFree = 0
        for _, id_ in ipairs(sort(keys(newXRef), function(a, b) return b - a end)) do -- (reverse sort)
            if newXRef[id_][3] ~= 'f' then goto continue end -- skip if not free
            -- no need to add free entry for objects added by us
            -- in previous edits then freed again
            if id_ >= nextObject then
                newXRef[id_] = nil  -- Note: deleting newXRef entry!
                goto continue
            end
            newXRef[id_][1] = prevFree
            prevFree = id_
            ::continue::
        end

        -- prepare our main dictionary for writing
        mainDict.Size = nextObject -- update number of objects
        -- must change the ID if it exists
        if ref(mainDict.ID) == 'ARRAY' and #mainDict.ID > 1 then
            -- increment first byte since this is an easy change to make
            id = carray.new('char'):append(mainDict.ID[2])  -- (edited in place below)
            local c = matches(id, [[(?i)^<([0-9a-f]{2})]])
            if c ~= nil then
                local byte = unpack('H2',chr((hex(c) + 1) & 0xff))
                substr(id, 1, 2, byte)
            else
                c = matches(id, [[(?s)^\((.)]])
                if c ~= nil and c ~= '\\' and c ~= ')' and c ~= '(' then
                    local ch = chr((ord(c) + 1) & 0xff)
                    -- avoid generating characters that could cause problems
                    if isMatch(ch, [=[[()\\\x00-\x08\x0a-\x1f\x7f\xff]]=]) then ch = 'a' end
                    substr(id, 1, 1, ch)
                end
            end
            mainDict.ID[2] = id:tostring()
        end

        -- remember position of xref table in file (we will write this next)
        local startxref = Tell(outfile) - et.PDFBase + length(RS)

        -- must write xref as a stream in xref-stream-only files
        if truthy(mainDict.Type) and mainDict.Type == '/XRef' then

            -- create entry for the xref stream object itself
            newXRef[nextObject] = { Tell(outfile) - et.PDFBase + length(RS), 0, 'n' }
            nextObject = nextObject + 1
            mainDict.Size = nextObject
            -- create xref stream and Index entry
            local bits = 4
            ::Restart:: while true do -- luacheck: ignore 512
                mainDict.W = { 1, bits, 2 }  -- int8u, int32u/int64u, int16u ('CNn' or 'CNNn')
                mainDict.Index = { }
                mainDict._stream = carray.new('char')
                local ids = sort(keys(newXRef), function(a, b) return a - b end)
                while #ids > 0 do
                    local startID = ids[1]
                    while true do
                        id = table.remove(ids, 1)
                        local pos_, gen_, type_ = table.unpack(newXRef[id])
                        if pos_ > 0xffffffff then
                            if bits == 4 then
                                -- switch to 64-bit integer offsets
                                bits = 8
                                goto Restart
                            end
                        end
                        if bits == 4 then
                            mainDict._stream:append(pack('CNn', type_ == 'f' and 0 or 1, pos_, gen_))
                        else
                            local hi = int(pos_ / 4294967296)
                            local lo = pos_ - hi * 4294967296
                            mainDict._stream:append(pack('CNNn', type_ == 'f' and 0 or 1, hi, lo, gen_))
                        end
                        if #ids == 0 or ids[1] ~= id + 1 then break end
                    end
                    -- add Index entries for this section of the xref stream
                    table.insert(mainDict.Index, startID)
                    table.insert(mainDict.Index, id - startID + 1)
                end
                mainDict._stream = mainDict._stream:tostring() -- (WriteObject takes a string)
                break
            end
            -- write the xref stream object
            keyExt = id .. ' 0 obj' -- (set anyway, but xref stream should NOT be encrypted)
            if not Write(outfile, RS, keyExt) then rtn = -1 end
            if not truthy(WriteObject(outfile, mainDict)) then rtn = -1 end
            if not Write(outfile, RS, 'endobj') then rtn = -1 end

        else

            -- write new xref table
            if not Write(outfile, RS, 'xref', RS) then rtn = -1 end
            -- lines must be exactly 20 bytes, so pad newline if necessary
            local endl = (length(RS) == 1 and ' ' or '') .. RS
            local ids = sort(keys(newXRef), function(a, b) return a - b end)
            while #ids > 0 do
                local startID = ids[1]
                buff = carray.new('char')
                while true do
                    id = table.remove(ids, 1)
                    buff:append(sprintf('%.10d %.5d %s%s', newXRef[id][1], newXRef[id][2], newXRef[id][3], endl))
                    if #ids == 0 or ids[1] ~= id + 1 then break end
                end
                -- write this (contiguous-numbered object) section of the xref table
                if not Write(outfile, startID, ' ', id - startID + 1, RS, buff) then rtn = -1 end
            end

            -- write main (trailer) dictionary
            if not Write(outfile, 'trailer') then rtn = -1 end
            if not truthy(WriteObject(outfile, mainDict)) then rtn = -1 end
        end
        -- write trailing comment (marker to allow edits to be reverted)
        if not Write(outfile, RS, endComment, oldEOF, RS) then rtn = -1 end

        -- write pointer to main xref table and EOF marker
        if not Write(outfile, 'startxref', RS, startxref, RS, '%%EOF', RS) then rtn = -1 end

    elseif prevUpdate then

        -- nothing new changed, so copy over previous incremental update
        if not raf:Seek(prevUpdate+et.PDFBase, 0) then rtn = -1 end
        while true do
            n, buff = raf:Read(65536)
            if not truthy(n) then break end
            if not Write(outfile, buff) then rtn = -1 end
        end
    end
    if rtn > 0 and truthy(et.CHANGED) and (et.DEL_GROUP.PDF or et.DEL_GROUP.XMP) then
        et:Warn('ExifTool PDF edits are reversible. Deleted tags may be recovered!', 1)
    end
    newTool = nil -- luacheck: ignore 311
    capture = nil -- luacheck: ignore 311
    RS = oldRS    -- (end of `local $/`)
    return rtn
end

-- (the subs above, for PDF.lua's AUTOLOAD closures)
WritePDF.CheckPDF = CheckPDF
WritePDF.WritePDFValue = WritePDFValue
WritePDF.EncodeString = EncodeString
WritePDF.CryptObject = CryptObject
WritePDF.GetFreeEntries = GetFreeEntries
WritePDF.WriteObject = WriteObject

return WritePDF -- end
