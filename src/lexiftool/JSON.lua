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

local Import = require('lexiftool.Import')
local matches = require('lexiftool.perl').matches
local truthy = require('lexiftool.perl').truthy
local tsort = require('lexiftool.perl').tsort
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
    local on1 = matches(tag, [[^settings\w{8}-\w{4}-\w{4}-\w{4}-\w{12}(Data|Metadata.+)$]])
    if on1 then
        tag = 'ON1_Settings' .. on1
        -- (upstream also: $et->OverrideFileType('ONP','application/on1') if
        --  $$et{FILE_TYPE} eq 'JSON'; deferred)
    end

    -- avoid conflict with special table entries
    if et.specialTags[tag] then tag = tag .. '!' end

    if not tagTablePtr[tag] then
        local name = tag
        name = name:gsub(':', '_') -- use underlines in place of colons in tag name
        name = name:gsub('^c2pa', 'C2PA') -- hack to fix "C2PA" case
        name = et.MakeTagName(name)
        local desc = et.MakeDescription(name)
        desc = desc:gsub('^C2 PA', 'C2PA') -- hack to get "C2PA" correct
        et:VPrint(0, et.INDENT, '[adding ' .. tag .. ']\n')
        local tagInfo = {
            Name = name,
            Description = desc,
            Temporary = 1,
        }
        -- (merge the %flags, e.g. List/Flat/Struct, into the new entry like
        --  upstream's `%flags` in the AddTagToTable call)
        if flags then
            for k, v in pairs(flags) do tagInfo[k] = v end
        end
        et:AddTagToTable(tagTablePtr, tag, tagInfo)
    end
    et:HandleTag(tagTablePtr, tag, val)
end

--------------------------------------------------------------------------------
-- Process a JSON tag
-- Inputs: 0) ExifTool ref, 1) tag table, 2) tag ID, 3) value, 4) tagInfo flags
-- - expands structures into flattened tags as required
--------------------------------------------------------------------------------
-- Upstream's `%flags, List => 1` / `Flat => 1` / `Struct => 1` merges into a
-- fresh flags table (upstream passes a copied hash on each recursive call).
local function mergeFlags(flags, key)
    local f = { [key] = 1 }
    if flags then for k, v in pairs(flags) do f[k] = v end end
    return f
end

function JSON.ProcessTag(et, tagTablePtr, tag, val, flags)
    -- (a `{ref='SCALAR', value=...}` tuple is neither a HASH nor an ARRAY
    --  upstream, so it goes straight to FoundTag as a plain value; CBOR.lua
    --  builds those for byte strings)
    if type(val) == 'table' and val.ref ~= 'SCALAR' then
        if val._ordered_keys_ ~= nil then
            -- hash value (upstream `ref $val eq 'HASH'`); only hashes are
            -- subject to the Struct option, and they flatten into field tags
            if truthy(et:Options('Struct')) then
                FoundTag(et, tagTablePtr, tag, val, mergeFlags(flags, 'Struct'))
                if et:Options('Struct') <= 1 then return end
            end
            -- support hashes with ordered keys
            for i = 1, #val._ordered_keys_ do
                local key = val._ordered_keys_[i]
                local tg = tag .. (key:match('^%d') and tag:match('%d$') and '_' or '') .. (ucfirst(key))
                tg = tg:gsub('([^a-zA-Z])([a-z])', function(a, b) return a .. uc(b) end)
                JSON.ProcessTag(et, tagTablePtr, tg, val[key], mergeFlags(flags, 'Flat'))
            end
        else
            -- array value (upstream `ref $val eq 'ARRAY'`): each element is a
            -- List member of the same tag, so a dynamically-created array tag
            -- becomes a List tag whose repeated FoundTag calls accumulate into
            -- one list value
            for i = 1, #val do
                JSON.ProcessTag(et, tagTablePtr, tag, val[i], mergeFlags(flags, 'List'))
            end
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
    local database = {}
    local dataPt
    local blockName

    if not raf then
        dataPt = dirInfo.DataPt
        if dirInfo.DirStart or (dirInfo.DirLen and dirInfo.DirLen ~= #dataPt) then
            local buff = dataPt:sub(dirInfo.DirStart + 1, dirInfo.DirStart + dirInfo.DirLen)
            dataPt = buff
        end
        local RandomAccess = require('lexiftool.RandomAccess')
        raf = RandomAccess.new(dataPt)
        -- extract as a block if requested
        blockName = dirInfo.BlockInfo and dirInfo.BlockInfo.Name or ''
        local blockExtract = et:Options('BlockExtract')
        if blockName ~= '' and (blockExtract or
            (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(blockName)]) or
            (et.TAGS_FROM_FILE and not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP[lc(blockName)]))) then
            et:FoundTag(dirInfo.BlockInfo, dataPt)
            if blockExtract and blockExtract > 1 then return 1 end
        end
        et:VerboseDir('JSON')
    end

    -- read information from JSON file into database structure
    local err = Import.ReadJSON(raf, database,
        et:Options('MissingTagValue'), et:Options('Charset'))

    if err or not next(database) then return 0 end

    if not dataPt then et:SetFileType() end

    tagTablePtr = tagTablePtr or et:GetTagTable('lexiftool.JSON.Main')

    -- remove any old tag definitions in case they change flags
    for key, tagInfo in pairs(tagTablePtr) do
        if type(tagInfo) == 'table' and tagInfo.Temporary then
            tagTablePtr[key] = nil
        end
    end

    -- extract tags from JSON database
    local keys = {}
    for k in pairs(database) do keys[#keys + 1] = k end
    tsort(keys)
    for i = 1, #keys do
        local info = database[keys[i]]
        local tags = et.OrderedKeys(info)
        for j = 1, #tags do
            local tag = tags[j]
            local val = info[tag]
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
