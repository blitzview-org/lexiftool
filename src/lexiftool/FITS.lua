--------------------------------------------------------------------------------
-- File:         lexiftool/FITS.lua
-- Ported from:  lib/Image/ExifTool/FITS.pm
--
-- Description:  Read Flexible Image Transport System metadata
--
-- Revisions:    2018/03/07 - P. Harvey Created
--
-- References:   1) https://fits.gsfc.nasa.gov/fits_standard.html
--
-- Port notes:   read port: the Main table plus ProcessFITS. Upstream FITS.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local subst = require('lexiftool.perl').subst
local isMatch = require('lexiftool.perl').isMatch
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

local FITS = {}

-- FITS tags (ref 1)
FITS.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        This table lists some standard Flexible Image Transport System (FITS) tags,
        but ExifTool will extract any other tags found.  See
        L<https://fits.gsfc.nasa.gov/fits_standard.html> for the specification.
    ]],
    TELESCOP = 'Telescope',
    BACKGRND = 'Background',
    INSTRUME = 'Instrument',
    OBJECT   = 'Object',
    OBSERVER = 'Observer',
    DATE     = { Name = 'CreateDate', Groups = { [2] = 'Time' } },
    AUTHOR   = { Name = 'Author',     Groups = { [2] = 'Author' } },
    REFERENC = 'Reference',
   ['DATE-OBS'] = { Name = 'ObservationDate',    Groups = { [2] = 'Time' } },
   ['TIME-OBS'] = { Name = 'ObservationTime',    Groups = { [2] = 'Time' } },
   ['DATE-END'] = { Name = 'ObservationDateEnd', Groups = { [2] = 'Time' } },
   ['TIME-END'] = { Name = 'ObservationTimeEnd', Groups = { [2] = 'Time' } },
    COMMENT  = { Name = 'Comment', PrintConv = function(_self, val) val = subst(val, [[^ +]], ''); return val end,
                 Notes = 'leading spaces are removed if L<PrintConv|../ExifTool.html#PrintConv> is enabled' },
    HISTORY  = { Name = 'History', PrintConv = function(_self, val) val = subst(val, [[^ +]], ''); return val end,
                 Notes = 'leading spaces are removed if L<PrintConv|../ExifTool.html#PrintConv> is enabled' },
}

--------------------------------------------------------------------------------
-- Read information in a FITS document
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid FITS file
--------------------------------------------------------------------------------
function FITS.ProcessFITS(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(80)
    if not (n == 80 and buff:match("^SIMPLE  = " .. (' '):rep(19) .. 'T')) then return 0 end
    et:SetFileType()
    local tagTablePtr = et:GetTagTable('lexiftool.FITS.Main')

    local tag
    local continue_
    while true do
        n, buff = raf:Read(80)
        if n ~= 80 then
            et:Warn('Truncated FITS header')
            break
        end
        local key = substr(buff, 0, 8):gsub(' +$', '') -- remove trailing space from key
        if key == 'CONTINUE' then
            if continue_ == nil then
                et:Warn('Unexpected FITS CONTINUE keyword')
                goto continueLoop
            end
        else
            if continue_ ~= nil then
                -- the previous value wasn't continued, so store with the trailing '&'
                et:HandleTag(tagTablePtr, tag, continue_ .. '&')
                continue_ = nil
            end
            if key == 'END' then break end
            -- make sure the key is valid
            if not key:match('^[-_A-Z0-9]*$') then
                et:Warn('Format error in FITS header')
                break
            end
            if key == 'COMMENT' or key == 'HISTORY' then
                local val = substr(buff, 8) -- comments start in column 9
                val = val:gsub(' +$', '') -- remove trailing spaces
                et:HandleTag(tagTablePtr, key, val)
                goto continueLoop
            end
            -- ignore other lines that aren't tags
            if substr(buff, 8, 2) ~= '= ' then goto continueLoop end
            -- save tag name (avoiding potential conflict with ExifTool variables)
            tag = ExifTool.specialTags[key] and ('_' .. key) or key
            -- add to tag table if necessary
            if not tagTablePtr[tag] then
                -- make tag name lower case with leading capital, then remove
                -- all '_' and capitalize the subsequent letter
                local name = ucfirst(lc(tag))
                name = subst(name, [[_(.)]], function(c) return uc(c) end, 'g')
                et:AddTagToTable(tagTablePtr, tag, { Name = name })
            end
        end
        do
            local val = substr(buff, 10)
            -- parse quoted values
            local quoted, rest = val:match("^'(.-)'(.*)")
            if quoted then
                val, buff = quoted, rest
                while true do -- handle escaped quotes
                    local more, rest2 = buff:match("^('.-)'(.*)")
                    if not more then break end
                    val = val .. more
                    buff = rest2
                end
                val = val:gsub(' +$', '') -- remove trailing spaces
                if continue_ ~= nil then
                    val = continue_ .. val
                    continue_ = nil
                end
                -- check for possible continuation, removing trailing '&'
                local stripped, count = val:gsub('&$', '')
                if count > 0 then
                    continue_ = stripped
                    goto continueLoop
                end
                val = stripped
            elseif continue_ ~= nil then
                et:Warn('Invalid FITS CONTINUE value')
                goto continueLoop
            else
                val = val:gsub(' */.*$', ''):gsub(' +$', '') -- remove trailing spaces and comment
                if #val == 0 then goto continueLoop end -- ignore undefined values
                val = val:gsub('^ +', '') -- remove leading spaces
                -- re-format floating-point values to use 'e'
                -- upstream: `$val =~ tr/DE/e/ if $val =~
                --  /^[+-]?(?=\d|\.\d)\d*(\.\d*)?([ED]([+-]?\d+))?$/` (PCRE2 via
                -- the facade -- the lookahead isn't a Lua pattern)
                if isMatch(val, '^[+-]?(?=\\d|\\.\\d)\\d*(\\.\\d*)?([ED]([+-]?\\d+))?$') then
                    val = val:gsub('[DE]', 'e')
                end
            end
            et:HandleTag(tagTablePtr, tag, val)
        end
        ::continueLoop::
    end
    return 1
end

return FITS
