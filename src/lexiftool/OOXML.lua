--------------------------------------------------------------------------------
-- File:         lexiftool/OOXML.lua
-- Ported from:  lib/Image/ExifTool/OOXML.pm
--
-- Description:  Read Office Open XML+ZIP files
--
-- Revisions:    2009/10/31 - P. Harvey Created
--
-- Port notes:   ported: the `Main` table plus `GetTagID` and `FoundTag`.
--               `ProcessDOCX` is ported too, now that ZIP.lua reaches it:
--               its member walk runs on ArchiveZip.lua, this port's stand-in
--               for the optional Archive::Zip module (see ZIP.lua's Port
--               notes).
--               Deviation in FoundTag: upstream's `if ($table and $table)`
--               symbolic-deref test (`no strict 'refs'`) checks that the
--               XMP sub-table's package hash is already populated; this
--               port lets GetTagTable load the module instead.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local XMP = require('lexiftool.XMP')
local matches = perl.matches
local subst = perl.subst
local str = perl.str
local uc, ucfirst = perl.uc, perl.ucfirst
local perlTruthy = ExifTool.perlTruthy

local OOXML = {}

-- XML attributes to queue
local queuedAttrs = {}
local queueAttrs = {
    fmtid = 1,
    pid   = 1,
    name  = 1,
}

-- keep track of items in a vector (to accumulate as a list)
local vectorCount
local vectorVals = {}

-- Office Open XML tags
OOXML.Main = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Document' },
    PROCESS_PROC = XMP.ProcessXMP,
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        The Office Open XML (OOXML) format was introduced with Microsoft Office 2007
        and is used by file types such as DOCX, PPTX, XLSX and VSDX.  These are
        essentially ZIP archives containing XML files.  The table below lists some
        tags which have been observed in OOXML documents, but ExifTool will extract
        any tags found from XML files of the OOXML document properties ("docProps")
        directory.

        B<Tips:>

        1) Structural ZIP tags may be ignored (if desired) with C<--ZIP:all> on the
        command line.

        2) Tags may be grouped by their document number in the ZIP archive with the
        C<-g3> or C<-G3> option.
    ]],
    -- These tags all have 1:1 correspondence with FlashPix tags except for:
    --   OOXML            FlashPix
    --   ---------------  -------------
    --   DocSecurity      Security
    --   Application      Software
    --   dc:Description   Comments
    --   dc:Creator       Author
    Application = { },
    AppVersion  = { },
    category    = { },
    Characters  = { },
    CharactersWithSpaces = { },
    CheckedBy   = { },
    Client      = { },
    Company     = { },
    created     = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    createdType = { Hidden = 1, RawConv = function() return nil end }, -- ignore this XML type name
    DateCompleted = {
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Department  = { },
    Destination = { },
    Disposition = { },
    Division    = { },
    DocSecurity = {
        -- (http://msdn.microsoft.com/en-us/library/documentformat.openxml.extendedproperties.documentsecurity.aspx)
        PrintConv = {
            [0] = 'None',
            [1] = 'Password protected',
            [2] = 'Read-only recommended',
            [4] = 'Read-only enforced',
            [8] = 'Locked for annotations',
        },
    },
    DocumentNumber= { },
    Editor      = { Groups = { [2] = 'Author'} },
    ForwardTo   = { },
    Group       = { },
    HeadingPairs= { },
    HiddenSlides= { },
    HyperlinkBase= { },
    HyperlinksChanged = { PrintConv = { ['false'] = 'No', ['true'] = 'Yes' } },
    keywords    = { },
    Language    = { },
    lastModifiedBy = { Groups = { [2] = 'Author'} },
    lastPrinted = {
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Lines       = { },
    LinksUpToDate= { PrintConv = { ['false'] = 'No', ['true'] = 'Yes' } },
    Mailstop    = { },
    Manager     = { },
    Matter      = { },
    MMClips     = { },
    modified    = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    modifiedType= { Hidden = 1, RawConv = function() return nil end }, -- ignore this XML type name
    Notes       = { },
    Office      = { },
    Owner       = { Groups = { [2] = 'Author'} },
    Pages       = { },
    Paragraphs  = { },
    PresentationFormat = { },
    Project     = { },
    Publisher   = { },
    Purpose     = { },
    ReceivedFrom= { },
    RecordedBy  = { },
    RecordedDate= {
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Reference   = { },
    revision    = { Name = 'RevisionNumber' },
    ScaleCrop   = { PrintConv = { ['false'] = 'No', ['true'] = 'Yes' } },
    SharedDoc   = { PrintConv = { ['false'] = 'No', ['true'] = 'Yes' } },
    Slides      = { },
    Source      = { },
    Status      = { },
    TelephoneNumber = { },
    Template    = { },
    TitlesOfParts= { },
    TotalTime   = {
        Name = 'TotalEditTime',
        PrintConv = function(_self, val) return ExifTool.ConvertTimeSpan(val, 60) end,
    },
    Typist      = { },
    Words       = { },
}

--------------------------------------------------------------------------------
-- Generate a tag ID for this XML tag
-- Inputs: 0) tag property name list ref
-- Returns: tagID and outtermost interesting namespace (or '' if no namespace)
function OOXML.GetTagID(props)
    local tag, namespace
    for _, prop in ipairs(props) do
        -- split name into namespace and property name
        -- (Note: namespace can be '' for property qualifiers)
        local ns, nm = matches(prop, [[(.*?):(.*)]])
        if ns == nil then ns, nm = '', prop end
        if ns ~= 'vt' then         -- ignore 'vt' properties
            if tag ~= nil then
                tag = tag .. ucfirst(nm)  -- add to tag name
            elseif prop ~= 'Properties' and prop ~= 'cp:coreProperties' and
                   prop ~= 'property'
            then
                tag = nm
                -- save namespace of first property to contribute to tag name
                if not perlTruthy(namespace) then namespace = ns end
            end
        end
    end
    return tag, perlTruthy(namespace) and namespace or ''
end

-- upstream's inline `grep /^vt:vector$/, @$props` in boolean context
local function grepVtVector(props)
    for _, p in ipairs(props) do
        if matches(p, [[^vt:vector$]]) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- We found an XMP property name/value
-- Inputs: 0) ExifTool object ref, 1) tag table ref
--         2) reference to array of XMP property names (last is current property)
--         3) property value, 4) attribute hash ref (not used here)
-- Returns: 1 if valid tag was found
function OOXML.FoundTag(et, tagTablePtr, props, val, _attrs)
    if #props == 0 then return 0 end
    local verbose = et:Options('Verbose')

    local tag = props[#props]
    if perl.num(verbose) > 1 then et:VPrint(0, "  | - Tag '", table.concat(props, '/'), "'\n") end

    -- un-escape XML character entities
    val = XMP.UnescapeXML(val)
    -- convert OOXML-escaped characters (eg. "_x0000d_" is a newline)
    val = subst(val, [[(?i)_x([0-9a-f]{4})_]], function(c) return ExifTool.PackUTF8(tonumber(c, 16)) end, 'g')
    -- convert from UTF8 to ExifTool Charset
    val = et:Decode(val, 'UTF8')
    -- queue this attribute for later if necessary
    if queueAttrs[tag] then
        queuedAttrs[tag] = val
        return 0
    end
    local ns
    tag, ns = OOXML.GetTagID(props)
    if not perlTruthy(tag) then
        -- all properties are in ignored namespaces
        -- so 'name' from our queued attributes for the tag
        local name = queuedAttrs.name
        if not perlTruthy(name) then return 0 end
        name = subst(name, [[(^| )([a-z])]], function(a, b) return a .. uc(b) end, 'g') -- start words with uppercase
        tag = (name:gsub('[^%-_a-zA-Z0-9]', ''))   -- (upstream tr/-_a-zA-Z0-9//dc)
        if #tag == 0 then return 0 end
        if not tagTablePtr[tag] then
            local tagInfo = {
                Name = tag,
                Description = name,
            }
            -- format as a date/time value if type is 'vt:filetime'
            if props[#props] == 'vt:filetime' then
                tagInfo.Groups = { [2] = 'Time' }
                tagInfo.Format = 'date'
                tagInfo.PrintConv = function(self, v) return self:ConvertDateTime(v) end
            end
            if perlTruthy(verbose) then et:VPrint(0, '  | [adding ' .. tag .. ']\n') end
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
    elseif tag == 'xmlns' then
        -- ignore namespaces (for now)
        return 0
    elseif type(XMP.Main[ns]) == 'table' and XMP.Main[ns].SubDirectory then
        -- use standard XMP table if it exists
        local tbl = XMP.Main[ns].SubDirectory.TagTable
        if tbl then
            tagTablePtr = et:GetTagTable(tbl)
        end
    elseif #props > 2 and grepVtVector(props) then
        -- handle vector properties (accumulate as lists)
        if props[#props] == 'vt:size' then
            vectorCount = val
            vectorVals = {}
            return 0
        elseif props[#props] == 'vt:baseType' then
            return 0    -- ignore baseType
        elseif perlTruthy(vectorCount) then
            vectorCount = tonumber(vectorCount) - 1
            if perlTruthy(vectorCount) then
                vectorVals[#vectorVals + 1] = val
                return 0
            end
            if #vectorVals > 0 then
                local vals = { table.unpack(vectorVals) }
                vals[#vals + 1] = val
                val = vals
            end
            -- Note: we will lose any improper-sized vector elements here
        end
    end
    -- add any unknown tags to table
    if tagTablePtr[tag] then
        local tagInfo = tagTablePtr[tag]
        if type(tagInfo) == 'table' then
            -- reformat date/time values
            local fmt = tagInfo.Format or tagInfo.Writable or ''
            if fmt == 'date' then val = XMP.ConvertXMPDate(val) end
        end
    else
        if perlTruthy(verbose) then et:VPrint(0, '  [adding ' .. tag .. ']\n') end
        et:AddTagToTable(tagTablePtr, tag, { Name = ucfirst(tag) })
    end
    -- save the tag
    et:HandleTag(tagTablePtr, tag, val)

    -- start fresh for next tag
    vectorCount = nil
    queuedAttrs = {}

    return 1
end

local isOOXML = {
    DOCX = 1,  DOCM = 1,
    DOTX = 1,  DOTM = 1,
    POTX = 1,  POTM = 1,
    PPAX = 1,  PPAM = 1,
    PPSX = 1,  PPSM = 1,
    PPTX = 1,  PPTM = 1,  THMX = 1,
    XLAM = 1,
    XLSX = 1,  XLSM = 1,  XLSB = 1,
    XLTX = 1,  XLTM = 1,
    VSDX = 1,
}

-- generate reverse lookup for file type based on MIME
local fileType = {}
do
    for type_ in pairs(isOOXML) do
        local mime = ExifTool.mimeType[type_]
        if mime then fileType[mime] = type_ end
    end
end

--------------------------------------------------------------------------------
-- Extract information from an Office Open XML file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success
-- Notes: Upon entry to this routine, the file type has already been verified
-- and the dirInfo hash contains 2 elements unique to this process proc:
--   MIME    - mime type of main document from "[Content_Types].xml"
--   ZIP     - reference to Archive::Zip object for this file
--------------------------------------------------------------------------------
function OOXML.ProcessDOCX(et, dirInfo)
    local ZIP = require('lexiftool.ZIP')
    local zip = dirInfo.ZIP
    local tagTablePtr = et:GetTagTable('lexiftool.OOXML.Main')
    local mime = dirInfo.MIME or ExifTool.mimeType.DOCX

    -- set the file type ('DOCX' by default)
    local ftype = fileType[mime]
    if ftype then
        -- THMX is a special case because its contents.main MIME types is PPTX
        if ftype == 'PPTX' and et.FILE_EXT and et.FILE_EXT == 'THMX' then
            ftype = 'THMX'
        end
    else
        et:VPrint(0, 'Unrecognized MIME type: ' .. str(mime) .. '\n')
        -- get MIME type according to file extension
        ftype = et.FILE_EXT
        -- default to 'DOCX' if this isn't a known OOXML extension
        if not (ftype and isOOXML[ftype]) then ftype = 'DOCX' end
    end
    et:SetFileType(ftype)

    -- must catch all Archive::Zip warnings
    -- extract meta information from all files in ZIP "docProps" directory
    local docNum = 0
    local members = zip:members()
    for _, member in ipairs(members) do
        -- get filename of this ZIP member
        local file = member:fileName()
        if file ~= nil then
            et:VPrint(0, 'File: ' .. file .. '\n')
            -- set the document number and extract ZIP tags
            docNum = docNum + 1
            et.DOC_NUM = docNum
            ZIP.HandleMember(et, member)
            -- process only XML and JPEG/WMF thumbnail images in "docProps" directory
            if matches(file, [[(?i)^docProps/(.*\.xml|(thumbnail\.(jpe?g|wmf)))$]]) then
                -- get the file contents
                local buff, status = zip:contents(member)
                if status ~= 0 then
                    et:Warn('Error extracting ' .. file)
                elseif matches(file, '(?i)\\.(jpe?g|wmf)$') then
                    -- extract docProps/thumbnail.(jpg|mwf) as PreviewImage|PreviewMWF
                    local tag = matches(file, '(?i)\\.wmf$') and 'PreviewWMF' or 'PreviewImage'
                    -- (upstream passes a SCALAR reference here, which is what
                    --  makes the value print as the "(Binary data N bytes)"
                    --  placeholder instead of the raw image)
                    et:FoundTag(tag, { ref = 'SCALAR', value = buff })
                else
                    -- process XML files (docProps/app.xml, docProps/core.xml, docProps/custom.xml)
                    -- (skip over XML header if it exists)
                    local hdr = { matches(buff, [[<\?xml\s+.*?\?>]]) }
                    local subDirInfo = {
                        DataPt   = buff,
                        DirLen   = #buff,
                        DirStart = (#hdr > 0) and hdr[#hdr] or 0,
                        DataLen  = #buff,
                        XMPParseOpts = { FoundProc = OOXML.FoundTag },
                    }
                    et:ProcessDirectory(subDirInfo, tagTablePtr)
                end
            end
        end
    end
    et.DOC_NUM = nil
    return 1
end

return OOXML
