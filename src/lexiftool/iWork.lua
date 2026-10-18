--------------------------------------------------------------------------------
-- File:         lexiftool/iWork.lua
-- Ported from:  lib/Image/ExifTool/iWork.pm
--
-- Description:  Read Apple iWork '09 XML+ZIP files
--
-- Revisions:    2009/11/11 - P. Harvey Created
--
-- Port notes:   ported: the `Main` table plus `GetTagID` and `FoundTag`.
--               `Process_iWork` is ported too, now that ZIP.lua reaches it:
--               its member walk runs on ArchiveZip.lua, this port's stand-in
--               for the optional Archive::Zip module (see ZIP.lua's Port
--               notes).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local XMP = require('lexiftool.XMP')
local matches = perl.matches
local substr = perl.substr
local uc, ucfirst = perl.uc, perl.ucfirst

local iWork = {}

-- iWork tags
iWork.Main = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Document' },
    PROCESS_PROC = XMP.ProcessXMP,
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        The Apple iWork '09 file format is a ZIP archive containing XML files
        similar to the Office Open XML (OOXML) format.  Metadata tags in iWork
        files are extracted even if they don't appear below.
    ]],
    authors   = { Name = 'Author', Groups = { [2] = 'Author' } },
    comment   = { },
    copyright = { Groups = { [2] = 'Author' } },
    keywords  = { },
    projects  = { List = 1 },
    title     = { },
}

--------------------------------------------------------------------------------
-- Generate a tag ID for this XML tag
-- Inputs: 0) tag property name list ref
-- Returns: tagID
function iWork.GetTagID(props)
    if matches(props[#props], [[^\w+:ID$]]) then return 0 end  -- ignore ID tags
    local m = matches(props[1], [[^.*?:(.*)]])
    if m then return m end
    return props[1]
end

--------------------------------------------------------------------------------
-- We found an XMP property name/value
-- Inputs: 0) ExifTool object ref, 1) tag table ref
--         2) reference to array of XMP property names (last is current property)
--         3) property value, 4) attribute hash ref (not used here)
-- Returns: 1 if valid tag was found
function iWork.FoundTag(et, tagTablePtr, props, val, _attrs)
    if #props == 0 then return 0 end
    local verbose = et:Options('Verbose') or 0

    if verbose > 1 then et:VPrint(0, "  | - Tag '" .. table.concat(props, '/') .. "'\n") end

    -- un-escape XML character entities
    val = XMP.UnescapeXML(val)
    -- convert from UTF8 to ExifTool Charset
    val = et:Decode(val, 'UTF8')
    local tag = iWork.GetTagID(props)
    if not ExifTool.perlTruthy(tag) then return 0 end

    -- add any unknown tags to table
    if not tagTablePtr[tag] then
        if ExifTool.perlTruthy(verbose) then et:VPrint(0, '  [adding ' .. tag .. ']\n') end
        et:AddTagToTable(tagTablePtr, tag, { Name = ucfirst(tag) })
    end
    -- save the tag
    et:HandleTag(tagTablePtr, tag, val)

    return 1
end

local iWorkType = {
    -- file extensions
    NUMBERS = 'NUMBERS',
    PAGES   = 'PAGES',
    KEY     = 'KEY',
    KTH     = 'KTH',
    NMBTEMPLATE = 'NMBTEMPLATE',
    -- we don't support double extensions --
    -- "PAGES.TEMPLATE" => 'Apple Pages Template',
    -- outer XML elements
    ['ls:document'] = 'NUMBERS',
    ['sl:document'] = 'PAGES',
    ['key:presentation'] = 'KEY',
}

-- MIME types for iWork files (Apple has not registered these yet, but these
-- are my best guess after doing some googling.  I'm not 100% sure what "sff"
-- indicates, but I think it refers to the new "flattened" package format)
local mimeType = {
    ['NUMBERS']       = 'application/x-iwork-numbers-sffnumbers',
    ['PAGES']         = 'application/x-iwork-pages-sffpages',
    ['KEY']           = 'application/x-iWork-keynote-sffkey',
    ['NMBTEMPLATE']   = 'application/x-iwork-numbers-sfftemplate',
    ['PAGES.TEMPLATE']= 'application/x-iwork-pages-sfftemplate',
    ['KTH']           = 'application/x-iWork-keynote-sffkth',
}

--------------------------------------------------------------------------------
-- Extract information from an iWork file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function iWork.Process_iWork(et, dirInfo)
    local ZIP = require('lexiftool.ZIP')
    local zip = dirInfo.ZIP
    local type_, index, indexFile, status

    -- try to determine the file type
    -- trust type given by file extension if available
    if et.FILE_EXT then type_ = iWorkType[et.FILE_EXT] end
    if not type_ then
        -- read the index file
        local members = zip:membersMatching('^index\\.(xml|apxl)$')
        if #members > 0 then
            index, status = zip:contents(members[1])
            if status == 0 then
                indexFile = members[1]:fileName()
                local m = { matches(index, [[(?s)^\s*<\?xml version=[^<]+<(\w+:\w+)]]) }
                if #m > 0 and iWorkType[m[1]] then type_ = iWorkType[m[1]] end
            end
        else
            members = zip:membersMatching([[(?i)^.*\.(pages|numbers|key)/Index.*]])
            if #members > 0 then
                local tmp = members[1]:fileName()
                local m = { matches(tmp, '(?i)\\.(pages|numbers|key)') }
                if #m > 0 then type_ = iWorkType[uc(m[1])] end
            end
        end
        if not type_ then type_ = 'ZIP' end     -- assume ZIP by default
    end
    et:SetFileType(type_, mimeType[type_])

    local members = zip:members()
    local docNum = 0
    for _, member in ipairs(members) do
        -- get filename of this ZIP member
        local file = member:fileName()
        if file ~= nil then
            et:VPrint(0, 'File: ' .. file .. '\n')
            -- set the document number and extract ZIP tags
            docNum = docNum + 1
            et.DOC_NUM = docNum
            ZIP.HandleMember(et, member)

            -- process only the index XML and JPEG thumbnail/preview files
            if matches(file, [[(?i)^(index\.(xml|apxl)|QuickLook/Thumbnail\.jpg|[^/]+/preview(-micro|-web)?.jpg)$]]) then
                -- get the file contents if necessary
                local buff
                if indexFile and indexFile == file then
                    -- use the index file we already loaded
                    buff = index
                else
                    buff, status = zip:contents(member)
                    if status ~= 0 then
                        et:Warn('Error extracting ' .. file)
                        buff = nil
                    end
                end
                if buff then
                    -- extract JPEG as PreviewImage (should only be QuickLook/Thumbnail.jpg)
                    if matches(file, '\\.jpg$') then
                        local pm = { matches(file, 'preview-(\\w+)') }
                        local ptype = (#pm > 0) and ((pm[1] == 'web') and 'Other' or 'Thumbnail') or 'Preview'
                        et:FoundTag(ptype .. 'Image', { ref = 'SCALAR', value = buff })
                    else
                        -- process "metadata" section of XML index file
                        local m1 = { matches(buff, [[<(\w+):metadata>]]) }
                        if #m1 > 0 then
                            local ns = m1[1]
                            local p1 = m1[#m1]
                            local m2, p2 = perl.matchesDyn(buff, '</' .. ns .. ':metadata>', p1)
                            if m2 then
                                -- construct XML data from "metadata" section only
                                local xml = '<?xml version="1.0"?>' .. substr(buff, p1, p2 - p1)
                                local subDirInfo = {
                                    DataPt = xml,
                                    DirLen = #xml,
                                    DataLen = #xml,
                                    XMPParseOpts = {
                                        FoundProc = iWork.FoundTag,
                                    },
                                }
                                local tagTablePtr = et:GetTagTable('lexiftool.iWork.Main')
                                et:ProcessDirectory(subDirInfo, tagTablePtr)
                            end
                        end
                    end
                end
            end
        end
    end
    et.DOC_NUM = nil
    return 1
end

return iWork
