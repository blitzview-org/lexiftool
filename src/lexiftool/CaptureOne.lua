--------------------------------------------------------------------------------
-- File:         lexiftool/CaptureOne.lua
-- Ported from:  lib/Image/ExifTool/CaptureOne.pm
--
-- Description:  Read Capture One EIP and COS files
--
-- Revisions:    2009/11/01 - P. Harvey Created
--
-- Notes:        The EIP format is a ZIP file containing an image (IIQ or TIFF)
--               and some settings files (COS).  COS files are XML based.
--
-- Port notes:   ported: the `Main` table, `HandleCOSAttrs`, `FoundCOS` and
--               `ProcessCOS` -- the whole COS (standalone settings file)
--               path.
--               `ProcessEIP` is ported too, now that ZIP.lua reaches it:
--               its member walk runs on ArchiveZip.lua, this port's stand-in
--               for the optional Archive::Zip module (see ZIP.lua's Port
--               notes).
--               `AttrProc` hooks cannot take scalar references in Lua, so
--               HandleCOSAttrs follows XISF.lua's shape: it mutates
--               attrList/attrs in place and returns (valChanged, prop, val).
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local XMP = require('lexiftool.XMP')
local matches = perl.matches
local ucfirst = perl.ucfirst

local CaptureOne = {}

-- CaptureOne COS XML tags
-- - tags are added dynamically when encountered
-- - this table is not listed in tag name docs
CaptureOne.Main = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Image' },
    PROCESS_PROC = XMP.ProcessXMP,
    VARS = { ID_FMT = 'none' },
    -- upstream: `ValueConv => '\$val'` -- a scalar-ref ValueConv, which this
    -- port spells `ValueConvRef` (see ICC_Profile.lua)
    ColorCorrections = { ValueConvRef = true, Hidden = 1 }, -- (long list of floating point numbers)
}

--------------------------------------------------------------------------------
-- We found an XMP property name/value
-- Inputs: 0) attribute list ref, 1) attr hash ref,
--         2) property name ref, 3) property value ref
-- Returns: true if value was changed
function CaptureOne.HandleCOSAttrs(attrList, attrs, prop, valPt)
    local changed = false
    if #valPt == 0 and attrs.K ~= nil and attrs.V ~= nil then
        prop = attrs.K
        valPt = attrs.V
        -- remove these attributes from the list
        local kept = {}
        for _, a in ipairs(attrList) do
            if a == 'K' or a == 'V' then
                attrs[a] = nil
            else
                kept[#kept + 1] = a
            end
        end
        for i = #attrList, 1, -1 do attrList[i] = nil end
        for i, a in ipairs(kept) do attrList[i] = a end
        changed = true
    end
    return changed, prop, valPt
end

--------------------------------------------------------------------------------
-- We found a COS property name/value
-- Inputs: 0) ExifTool object ref, 1) tag table ref
--         2) reference to array of XMP property names (last is current property)
--         3) property value, 4) attribute hash ref (not used here)
-- Returns: 1 if valid tag was found
function CaptureOne.FoundCOS(et, tagTablePtr, props, val, _attrs)
    local tag = props[#props]
    if not tagTablePtr[tag] then
        et:VPrint(0, '  | [adding ' .. tag .. ']\n')
        local name = ucfirst(tag)
        name = name:gsub('[^%-_a-zA-Z0-9]', '')
        if #tag == 0 then return 0 end
        local tagInfo = { Name = tag }
        -- try formatting any tag with "Date" in the name as a date
        -- (shouldn't affect non-date tags)
        if matches(name, [[Date(?![a-z])]]) then
            tagInfo.Groups = { [2] = 'Time' }
            tagInfo.ValueConv = function(_self, v) return XMP.ConvertXMPDate(v, 1) end
            tagInfo.PrintConv = function(self, v) return self:ConvertDateTime(v) end
        end
        et:AddTagToTable(tagTablePtr, tag, tagInfo)
    end
    -- convert from UTF8 to ExifTool Charset
    val = et:Decode(val, 'UTF8')
    -- un-escape XML character entities
    val = XMP.UnescapeXML(val)
    et:HandleTag(tagTablePtr, tag, val)
    return 0
end

--------------------------------------------------------------------------------
-- Extract information from a COS file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid XML file
function CaptureOne.ProcessCOS(et, dirInfo)
    -- process using XMP module, but override handling of attributes and tags
    dirInfo.XMPParseOpts = {
        AttrProc = CaptureOne.HandleCOSAttrs,
        FoundProc = CaptureOne.FoundCOS,
    }
    local tagTablePtr = et:GetTagTable('lexiftool.CaptureOne.Main')
    local success = et:ProcessDirectory(dirInfo, tagTablePtr)
    dirInfo.XMLParseArgs = nil
    return success
end

--------------------------------------------------------------------------------
-- Extract meta information from an EIP file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function CaptureOne.ProcessEIP(et, dirInfo)
    local ZIP = require('lexiftool.ZIP')
    local zip = dirInfo.ZIP
    local file, buff, status, member
    local parseFile = {}

    et:SetFileType('EIP')

    -- must catch all Archive::Zip warnings
    -- find all manifest files
    local members = zip:membersMatching('^manifest\\d*.xml$')
    -- and choose the one with the highest version number (any better ideas?)
    for _, m in ipairs(members) do
        local f = m:fileName()
        if not (file and perl.lt(f, file)) then
            member = m
            file = f
        end
    end
    -- get file names from our chosen manifest file
    if member then
        buff, status = zip:contents(member)
        if status == 0 then
            local foundImage
            for tag, path in perl.eachMatch(buff, [[(?s)<(RawPath|SettingsPath)>(.*?)</\1>]]) do
                file = path
                if matches(file, '(?i)\\.(cos|iiq|jpe?g|tiff?)$') then
                    parseFile[file] = 1    -- set flag to parse this file
                    if not matches(file, '(?i)\\.cos$') then foundImage = 1 end
                end
                local _ = tag
            end
            -- ignore manifest unless it contained a valid image
            if not foundImage then parseFile = {} end
        end
    end
    -- extract meta information from embedded files
    local docNum = 0
    members = zip:members() -- get all members
    for _, mem in ipairs(members) do
        -- get filename of this ZIP member
        file = mem:fileName()
        if file ~= nil then
            et:VPrint(0, 'File: ' .. file .. '\n')
            -- set the document number and extract ZIP tags
            docNum = docNum + 1
            et.DOC_NUM = docNum
            ZIP.HandleMember(et, mem)
            local want
            if next(parseFile) ~= nil then
                want = parseFile[file]
            else
                -- reading the manifest didn't work, so look for image files in the
                -- root directory and .cos files in the CaptureOne directory
                want = matches(file, [[(?i)^([^/]+\.(iiq|jpe?g|tiff?)|CaptureOne/.*\.cos)$]])
            end
            if want then
                -- extract the contents of the file
                -- Note: this could use a LOT of memory here for RAW images...
                buff, status = zip:contents(mem)
                if status ~= 0 then
                    et:Warn('Error extracting ' .. file)
                elseif matches(file, '(?i)\\.cos$') then
                    -- process Capture One Settings files
                    local subDirInfo = {
                        DataPt = buff,
                        DirLen = #buff,
                        DataLen = #buff,
                    }
                    CaptureOne.ProcessCOS(et, subDirInfo)
                else
                    -- set HtmlDump error if necessary because it doesn't work with embedded files
                    if et.HTML_DUMP then
                        et.HTML_DUMP.Error = "Sorry, can't dump images embedded in ZIP files"
                    end
                    -- process IIQ, JPEG and TIFF images
                    et:ExtractInfo({ ref = 'SCALAR', value = buff }, { ReEntry = 1 })
                end
            end
        end
    end
    et.DOC_NUM = nil
    return 1
end

return CaptureOne
