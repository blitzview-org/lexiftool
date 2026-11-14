--------------------------------------------------------------------------------
-- File:         lexiftool/JSON.lua
-- Ported from:  lib/Image/ExifTool/JSON.pm
--
-- Description:  Read JSON files
--
-- Notes:        Set ExifTool MissingTagValue to "null" to ignore JSON nulls
--
-- Revisions:    2017/03/13 - P. Harvey Created
--
-- Port notes:   read subset: JSON tag table plus ProcessJSON / ProcessTag /
--               FoundTag; ReadJSON lives in Import.lua (upstream
--               Image::ExifTool::Import); ON1_SettingsData decodes its
--               base64 value into the PLIST::Main subdirectory, as upstream.
--------------------------------------------------------------------------------

local JSON = {}

local ExifTool = require('lexiftool')
local Import = require('lexiftool.Import')
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local ref = perl.ref
local substr = perl.substr
local length = perl.length
local GetTagTable = ExifTool.GetTagTable
local isMatch = require('lexiftool.perl').isMatch
local subst = require('lexiftool.perl').subst
local tr = require('lexiftool.perl').tr
local truthy = require('lexiftool.perl').truthy
local perlNum = require('lexiftool.perl').num
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

JSON.Main = {
    GROUPS = { [0] = 'JSON', [1] = 'JSON', [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        Other than a few tags in the table below, JSON tags have not been
        pre-defined.  However, ExifTool will read any existing tags from basic
        JSON-formatted files.
    ]],
    -- ON1 settings tags
    ON1_SettingsData = {
        RawConv = function(_self, val)
            local XMP = require('lexiftool.XMP')
            val = XMP.DecodeBase64(val)
            return val
        end,
        SubDirectory = { TagTable = 'lexiftool.PLIST.Main' },
    },
    ON1_SettingsMetadataCreated     = { Groups = { [2] = 'Time' } },
    ON1_SettingsMetadataModified    = { Groups = { [2] = 'Time' } },
    ON1_SettingsMetadataName        = { },
    ON1_SettingsMetadataPluginID    = { },
    ON1_SettingsMetadataTimestamp   = { Groups = { [2] = 'Time' } },
    ON1_SettingsMetadataUsage       = { },
    ON1_SettingsMetadataVisibleToUser= { },
    adjustmentsSettingsStatisticsLightMap = { -- (in JSON of AAE files)
        Name = 'AdjustmentsSettingsStatisticsLightMap',
        -- (upstream's DecodeBase64 returns a scalar reference; XMP.lua is
        --  required lazily, an eager top-level require reorders Composite builds)
        ValueConv = function(_self, val)
            return { ref = 'SCALAR', value = require('lexiftool.XMP').DecodeBase64(val) }
        end,
    },
}

--------------------------------------------------------------------------------
-- Store a tag value
-- Inputs: 0) ExifTool ref, 1) tag table, 2) tag ID, 3) value, 4) tagInfo flags
--------------------------------------------------------------------------------
local function FoundTag(et, tagTablePtr, tag, val, flags)
    -- special case to reformat ON1 tag names
    if isMatch(tag, [[^settings\w{8}-\w{4}-\w{4}-\w{4}-\w{12}(Data|Metadata.+)$]]) then
        tag = subst(tag, [[^settings\w{8}-\w{4}-\w{4}-\w{4}-\w{12}(Data|Metadata.+)$]], 'ON1_Settings$1')
        if et.FILE_TYPE == 'JSON' then et:OverrideFileType('ONP','application/on1') end
    end

    -- avoid conflict with special table entries
    if et.specialTags[tag] then tag = tag .. '!' end

    if not tagTablePtr[tag] then
        local name = tag
        name = tr(name, ':', '_') -- use underlines in place of colons in tag name
        name = subst(name, '(?i)^c2pa', 'C2PA')   -- hack to fix "C2PA" case
        name = et.MakeTagName(name)
        local desc = et.MakeDescription(name)
        desc = subst(desc, '^C2 PA', 'C2PA')    -- hack to get "C2PA" correct
        et:VPrint(0, et.INDENT, '[adding ' .. tag .. ']\n')
        local tagInfo = {
            Name = name,
            Description = desc,
        }
        -- (upstream's `%flags` in the AddTagToTable call, e.g. List/Flat/Struct)
        if flags then
            for k, v in pairs(flags) do tagInfo[k] = v end
        end
        tagInfo.Temporary = 1
        et:AddTagToTable(tagTablePtr, tag, tagInfo)
    end
    et:HandleTag(tagTablePtr, tag, val)
end

--------------------------------------------------------------------------------
-- Process a JSON tag
-- Inputs: 0) ExifTool ref, 1) tag table, 2) tag ID, 3) value, 4) tagInfo flags
-- - expands structures into flattened tags as required
-- (Lua: `%flags, Struct => 1` is a copy of the flags table with the added key)
--------------------------------------------------------------------------------
local function addFlag(flags, key)
    local f = { }
    if flags then for k, v in pairs(flags) do f[k] = v end end
    f[key] = 1
    return f
end

function JSON.ProcessTag(et, tagTablePtr, tag, val, flags)

    if ref(val) == 'HASH' then
        if truthy(et:Options('Struct')) then
            FoundTag(et, tagTablePtr, tag, val, addFlag(flags, 'Struct'))
            if perlNum(et:Options('Struct')) <= 1 then return end
        end
        -- support hashes with ordered keys
        for _, key in ipairs(ExifTool.OrderedKeys(val)) do
            local tg = tag .. ((isMatch(key, [[^\d]]) and isMatch(tag, [[\d$]])) and '_' or '') .. ucfirst(key)
            tg = subst(tg, [[([^a-zA-Z])([a-z])]], function(c1, c2) return c1 .. uc(c2) end, 'g')
            JSON.ProcessTag(et, tagTablePtr, tg, val[key], addFlag(flags, 'Flat'))
        end
    elseif ref(val) == 'ARRAY' then
        for _, item in ipairs(val) do
            JSON.ProcessTag(et, tagTablePtr, tag, item, addFlag(flags, 'List'))
        end
    elseif val ~= nil then
        FoundTag(et, tagTablePtr, tag, val, flags)
    end
end

--------------------------------------------------------------------------------
-- Extract meta information from a JSON file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success, 0 if this wasn't a recognized JSON file
--------------------------------------------------------------------------------
function JSON.ProcessJSON(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local structOpt = et:Options('Struct') -- luacheck: ignore 211
    local database, dataPt = { }, nil

    if not raf then
        dataPt = dirInfo.DataPt
        if truthy(dirInfo.DirStart) or (truthy(dirInfo.DirLen) and dirInfo.DirLen ~= length(dataPt)) then
            local buff = substr(dirInfo.DataPt, dirInfo.DirStart, dirInfo.DirLen)
            dataPt = buff
        end
        raf = RandomAccess.new(dataPt)
        -- extract as a block if requested
        local blockName = dirInfo.BlockInfo and dirInfo.BlockInfo.Name or ''
        local blockExtract = et:Options('BlockExtract')
        -- (REQ_TAG_LOOKUP/EXCL_TAG_LOOKUP may not exist yet: Perl autovivifies)
        if truthy(blockName) and (truthy(blockExtract) or (et.REQ_TAG_LOOKUP or { })[lc(blockName)] or
            (et.TAGS_FROM_FILE and not (et.EXCL_TAG_LOOKUP or { })[lc(blockName)]))
        then
            et:FoundTag(dirInfo.BlockInfo, dataPt)
            if truthy(blockExtract) and perlNum(blockExtract) > 1 then return 1 end
        end
        et:VerboseDir('JSON')
    end

    -- read information from JSON file into database structure
    local err = Import.ReadJSON(raf, database,
        et:Options('MissingTagValue'), et:Options('Charset'))

    if err or not next(database) then return 0 end

    if not dataPt then et:SetFileType() end

    if not tagTablePtr then tagTablePtr = GetTagTable(nil, 'lexiftool.JSON.Main') end

    -- remove any old tag definitions in case they change flags
    for _, key in ipairs(ExifTool.TagTableKeys(tagTablePtr)) do
        if tagTablePtr[key].Temporary then tagTablePtr[key] = nil end
    end

    -- extract tags from JSON database
    for _, key in ipairs(perl.sort(perl.keys(database))) do
        for _, tag in ipairs(ExifTool.OrderedKeys(database[key])) do
            local val = database[key][tag]
            -- (ignore SourceFile if generated automatically by ReadJSON)
            if not (tag == 'SourceFile' and val ~= nil and val == '*') then
                JSON.ProcessTag(et, tagTablePtr, tag, val)
            end
        end
    end
    return 1
end

JSON.Main.PROCESS_PROC = JSON.ProcessJSON

return JSON
