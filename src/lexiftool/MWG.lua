--------------------------------------------------------------------------------
-- File:         lexiftool/MWG.lua
-- Ported from:  lib/Image/ExifTool/MWG.pm
--
-- Description:  Metadata Working Group support
--
-- Revisions:    2009/10/21 - P. Harvey Created
--
-- References:   1) http://www.metadataworkinggroup.org/
--
-- Port notes:   Complete port of MWG.pm: every table and sub, in upstream
--               order.  Conversion strings are Lua functions; a WriteAlso
--               conversion gets (self, val, opts) -- `$opts{EditGroup} = 1`
--               sets opts.EditGroup.  OverwriteStringList returns the new
--               value as second result (upstream: through $newValuePt).
--               `strict` is consulted by the Exif/IPTC/Photoshop/XMP readers
--               through ExifTool.MWGstrict (lexiftool.lua), which looks this
--               module up instead of requiring it.  The %Regions/%Keywords/
--               %Collections XMP namespace tables are reached from XMP.lua's
--               Main table independently of the Composite tags.  Load()
--               adds the Composite tags with AddCompositeTags and
--               AddTagsToLookup as upstream; OverwriteStringList is reached
--               through WriteExif's custom IsOverwriting call once Load()
--               has hooked it into EXIF:Artist.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local XMP = require('lexiftool.XMP')
local perl = require('lexiftool.perl')

local MWG = {}

local mwgLoaded  -- flag set if we alreaded Load()ed the MWG tags

-- enable MWG strict mode (causes non-standard EXIF, IPTC and XMP to be
-- ignored; read through ExifTool.MWGstrict, see the Port notes)
MWG.strict = nil

local truthy = perl.truthy

-- MWG Composite tags
MWG.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'MWG', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    WRITE_PROC = ExifTool.DummyWriteProc,
    NOTES = [[
        The table below lists special Composite tags which are used to access other
        tags based on the MWG 2.0 recommendations.  These tags are only accessible
        when explicitly loaded, but this is done automatically by the exiftool
        application if MWG is specified as a group for any tag on the command line,
        or manually with the C<-use MWG> option.  Via the API, the MWG Composite
        tags are loaded by calling "C<Image::ExifTool::MWG::Load()>".

        When reading, the value of each MWG tag is B<Derived From> the specified
        tags based on the MWG guidelines.  When writing, the appropriate associated
        tags are written.  The value of the IPTCDigest tag is updated automatically
        when the IPTC is changed if either the IPTCDigest tag didn't exist
        beforehand or its value agreed with the original IPTC digest (indicating
        that the XMP is synchronized with the IPTC).  IPTC information is written
        only if the original file contained IPTC.

        Loading the MWG module activates "strict MWG conformance mode", which has
        the effect of causing EXIF, IPTC and XMP in non-standard locations to be
        ignored when reading, as per the MWG recommendations.  Instead, a "Warning"
        tag is generated when non-standard metadata is encountered.  This feature
        may be disabled by setting C<$Image::ExifTool::MWG::strict = 0> in the
        L<ExifTool config file|../config.html> (or from your Perl script when using the API).  Note
        that the behaviour when writing is not changed:  ExifTool always creates new
        records only in the standard location, but writes new tags to any
        EXIF/IPTC/XMP records that exist.

        Contrary to the EXIF specification, the MWG recommends that EXIF "ASCII"
        string values be stored as UTF-8.  To honour this, the exiftool application
        sets the default internal EXIF string encoding to "UTF8" when the MWG module
        is loaded, but via the API this must be done manually by setting the
        L<CharsetEXIF|../ExifTool.html#CharsetEXIF> option.

        A complication of the MWG specification is that although the MWG:Creator
        property may consist of multiple values, the associated EXIF tag
        (EXIF:Artist) is only a simple string.  To resolve this discrepancy the MWG
        recommends a technique which allows a list of values to be stored in a
        string by using a semicolon-space separator (with quotes around values if
        necessary).  When the MWG module is loaded, ExifTool automatically
        implements this policy and changes EXIF:Artist to a list-type tag.
    ]],
    Keywords = {
        TagID = 'MWG-Keywords',
        Flags  = { 'Writable', 'List' },
        Desire = {
            [0] = 'IPTC:Keywords', -- (64-character limit)
            [1] = 'XMP-dc:Subject',
            [2] = 'CurrentIPTCDigest',
            [3] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[2] == nil or (val[1] ~= nil and (val[3] == nil or val[2] == val[3])) then
                return val[1]
            end
            return MWG.RecoverTruncatedIPTC(val[0], val[1], 64)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            -- only write Keywords if IPTC exists (eg. set EditGroup option)
            ['IPTC:Keywords']  = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-dc:Subject'] = function(_self, val) return val end,
        },
    },
    Description = {
        TagID = 'MWG-Description',
        Writable = 1,
        Desire = {
            [0] = 'EXIF:ImageDescription',
            [1] = 'IPTC:Caption-Abstract', -- (2000-character limit)
            [2] = 'XMP-dc:Description',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^ *$') then return val[0] end
            if val[3] == nil or (val[2] ~= nil and (val[4] == nil or val[3] == val[4])) then
                return val[2]
            end
            return MWG.RecoverTruncatedIPTC(val[1], val[2], 2000)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['EXIF:ImageDescription'] = function(_self, val) return val end,
            ['IPTC:Caption-Abstract'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-dc:Description']    = function(_self, val) return val end,
        },
    },
    DateTimeOriginal = {
        TagID = 'MWG-DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Notes = '"specifies when a photo was taken" - MWG',
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Desire = {
            [0] = 'Composite:SubSecDateTimeOriginal',
            [1] = 'EXIF:DateTimeOriginal',
            [2] = 'IPTC:DateCreated',
            [3] = 'IPTC:TimeCreated',
            [4] = 'XMP-photoshop:DateCreated',
            [5] = 'CurrentIPTCDigest',
            [6] = 'IPTCDigest',
        },
        -- must check for validity in RawConv to avoid hiding a same-named tag,
        -- but IPTC dates use a ValueConv so we need to derive the value there
        RawConv = function(_self, val)
            if val[0] ~= nil or val[1] ~= nil or truthy(val[2]) or
                (val[4] ~= nil and (val[5] == nil or val[6] == nil or val[5] == val[6])) then
                return val
            end
            return nil
        end,
        ValueConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^[: ]*$') then return val[0] end
            if val[1] ~= nil and not perl.str(val[1]):match('^[: ]*$') then return val[1] end
            if val[5] == nil or (val[4] ~= nil and (val[6] == nil or val[5] == val[6])) then
                return val[4]
            end
            if truthy(val[2]) then
                if truthy(val[3]) then return perl.str(val[2]) .. ' ' .. perl.str(val[3]) end
                return val[2]
            end
            return nil
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val, nil, 1) end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            -- set EXIF date/time values according to PrintConv option instead
            -- of defaulting to Type=ValueConv to allow reformatting to be applied
            ['Composite:SubSecDateTimeOriginal']  = function(_self, val, opts) opts.Type = nil return val end,
            ['IPTC:DateCreated']                  = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['IPTC:TimeCreated']                  = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-photoshop:DateCreated']         = function(_self, val) return val end,
        },
    },
    CreateDate = {
        TagID = 'MWG-CreateDate',
        Groups = { [2] = 'Time' },
        Notes = '"specifies when an image was digitized" - MWG',
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Desire = {
            [0] = 'Composite:SubSecCreateDate',
            [1] = 'EXIF:CreateDate',
            [2] = 'IPTC:DigitalCreationDate',
            [3] = 'IPTC:DigitalCreationTime',
            [4] = 'XMP-xmp:CreateDate',
            [5] = 'CurrentIPTCDigest',
            [6] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[0] ~= nil or val[1] ~= nil or truthy(val[2]) or
                (val[4] ~= nil and (val[5] == nil or val[6] == nil or val[5] == val[6])) then
                return val
            end
            return nil
        end,
        ValueConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^[: ]*$') then return val[0] end
            if val[1] ~= nil and not perl.str(val[1]):match('^[: ]*$') then return val[1] end
            if val[5] == nil or (val[4] ~= nil and (val[6] == nil or val[5] == val[6])) then
                return val[4]
            end
            if truthy(val[2]) then
                if truthy(val[3]) then return perl.str(val[2]) .. ' ' .. perl.str(val[3]) end
                return val[2]
            end
            return nil
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val, nil, 1) end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['Composite:SubSecCreateDate'] = function(_self, val, opts) opts.Type = nil return val end,
            ['IPTC:DigitalCreationDate']   = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['IPTC:DigitalCreationTime']   = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-xmp:CreateDate']         = function(_self, val) return val end,
        },
    },
    ModifyDate = {
        TagID = 'MWG-ModifyDate',
        Groups = { [2] = 'Time' },
        Notes = '"specifies when a file was modified by the user" - MWG',
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Desire = {
            [0] = 'Composite:SubSecModifyDate',
            [1] = 'EXIF:ModifyDate',
            [2] = 'XMP-xmp:ModifyDate',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^[: ]*$') then return val[0] end
            if val[1] ~= nil and not perl.str(val[1]):match('^[: ]*$') then return val[1] end
            if val[3] == nil or val[4] == nil or val[3] == val[4] then return val[2] end
            return nil
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val, nil, 1) end,
        -- return empty string from check routines so this tag will never be set
        -- (only WriteAlso tags are written), the only difference is a -v2 message
        DelCheck   = function() return '' end,
        WriteCheck = function() return '' end,
        WriteAlso  = {
            ['Composite:SubSecModifyDate'] = function(_self, val, opts) opts.Type = nil return val end,
            ['XMP-xmp:ModifyDate']         = function(_self, val) return val end,
        },
    },
    Orientation = {
        TagID = 'MWG-Orientation',
        Writable   = 1,
        Require = { [0] = 'EXIF:Orientation' },
        ValueConv = function(_self, val) return val[0] end,
        PrintConv = require('lexiftool.Exif').orientation,
        DelCheck   = function() return '' end,
        WriteCheck = function() return '' end,
        WriteAlso  = {
            ['EXIF:Orientation'] = function(_self, val) return val end,
        },
    },
    Rating = {
        TagID = 'MWG-Rating',
        Writable   = 1,
        Require = { [0] = 'XMP-xmp:Rating' },
        ValueConv = function(_self, val) return val[0] end,
        DelCheck   = function() return '' end,
        WriteCheck = function() return '' end,
        WriteAlso  = {
            ['XMP-xmp:Rating'] = function(_self, val) return val end,
        },
    },
    Copyright = {
        TagID = 'MWG-Copyright',
        Groups = { [2] = 'Author' },
        Writable = 1,
        Desire = {
            [0] = 'EXIF:Copyright',
            [1] = 'IPTC:CopyrightNotice', -- (128-character limit)
            [2] = 'XMP-dc:Rights',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^ *$') then return val[0] end
            if val[3] == nil or (val[2] ~= nil and (val[4] == nil or val[3] == val[4])) then
                return val[2]
            end
            return MWG.RecoverTruncatedIPTC(val[1], val[2], 128)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['EXIF:Copyright'] = function(self, val)
                -- encode if necessary (not automatic because Format is 'undef')
                local enc = self:Options('CharsetEXIF')
                if truthy(enc) then
                    local v = val
                    v = self:Encode(v, enc)
                    return v
                end
                return val
            end,
            ['IPTC:CopyrightNotice'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-dc:Rights']        = function(_self, val) return val end,
        },
    },
    Creator = {
        TagID = 'MWG-Creator',
        Groups = { [2] = 'Author' },
        Flags  = { 'Writable', 'List' },
        Desire = {
            [0] = 'EXIF:Artist',
            [1] = 'IPTC:By-line', -- (32-character limit)
            [2] = 'XMP-dc:Creator',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            if val[0] ~= nil and not perl.str(val[0]):match('^ *$') then return val[0] end
            if val[3] == nil or (val[2] ~= nil and (val[4] == nil or val[3] == val[4])) then
                return val[2]
            end
            return MWG.RecoverTruncatedIPTC(val[1], val[2], 32)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['EXIF:Artist']    = function(_self, val) return val end,
            ['IPTC:By-line']   = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-dc:Creator'] = function(_self, val) return val end,
        },
    },
    Country = {
        TagID = 'MWG-Country',
        Groups = { [2] = 'Location' },
        Writable = 1,
        Desire = {
            [0] = 'IPTC:Country-PrimaryLocationName', -- (64-character limit)
            [1] = 'XMP-photoshop:Country',
            [2] = 'XMP-iptcExt:LocationShownCountryName',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            local xmpVal = truthy(val[2]) and val[2] or val[1]
            if val[3] == nil or (xmpVal ~= nil and (val[4] == nil or val[3] == val[4])) then
                return xmpVal
            end
            return MWG.RecoverTruncatedIPTC(val[0], xmpVal, 64)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['IPTC:Country-PrimaryLocationName'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-photoshop:Country'] = function(_self, val) return val end, -- (legacy)
            ['XMP-iptcExt:LocationShownCountryName'] = function(_self, val) return val end,
        },
    },
    State = {
        TagID = 'MWG-State',
        Groups = { [2] = 'Location' },
        Writable = 1,
        Desire = {
            [0] = 'IPTC:Province-State', -- (32-character limit)
            [1] = 'XMP-photoshop:State',
            [2] = 'XMP-iptcExt:LocationShownProvinceState',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            local xmpVal = truthy(val[2]) and val[2] or val[1]
            if val[3] == nil or (xmpVal ~= nil and (val[4] == nil or val[3] == val[4])) then
                return xmpVal
            end
            return MWG.RecoverTruncatedIPTC(val[0], xmpVal, 32)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['IPTC:Province-State'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-photoshop:State'] = function(_self, val) return val end, -- (legacy)
            ['XMP-iptcExt:LocationShownProvinceState'] = function(_self, val) return val end,
        },
    },
    City = {
        TagID = 'MWG-City',
        Groups = { [2] = 'Location' },
        Writable = 1,
        Desire = {
            [0] = 'IPTC:City', -- (32-character limit)
            [1] = 'XMP-photoshop:City',
            [2] = 'XMP-iptcExt:LocationShownCity',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            local xmpVal = truthy(val[2]) and val[2] or val[1]
            if val[3] == nil or (xmpVal ~= nil and (val[4] == nil or val[3] == val[4])) then
                return xmpVal
            end
            return MWG.RecoverTruncatedIPTC(val[0], xmpVal, 32)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['IPTC:City'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-photoshop:City'] = function(_self, val) return val end, -- (legacy)
            ['XMP-iptcExt:LocationShownCity'] = function(_self, val) return val end,
        },
    },
    Location = {
        TagID = 'MWG-Location',
        Groups = { [2] = 'Location' },
        Writable = 1,
        Desire = {
            [0] = 'IPTC:Sub-location', -- (32-character limit)
            [1] = 'XMP-iptcCore:Location',
            [2] = 'XMP-iptcExt:LocationShownSublocation',
            [3] = 'CurrentIPTCDigest',
            [4] = 'IPTCDigest',
        },
        RawConv = function(_self, val)
            local xmpVal = truthy(val[2]) and val[2] or val[1]
            if val[3] == nil or (xmpVal ~= nil and (val[4] == nil or val[3] == val[4])) then
                return xmpVal
            end
            return MWG.RecoverTruncatedIPTC(val[0], xmpVal, 32)
        end,
        DelCheck   = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteCheck = function(self) return MWG.ReconcileIPTCDigest(self) end,
        WriteAlso  = {
            ['IPTC:Sub-location'] = function(_self, val, opts) opts.EditGroup = 1 return val end,
            ['XMP-iptcCore:Location'] = function(_self, val) return val end, -- (legacy)
            ['XMP-iptcExt:LocationShownSublocation'] = function(_self, val) return val end,
        },
    },
}

-- MWG XMP structures
local sExtensions = {
    STRUCT_NAME = 'MWG Extensions',
    NAMESPACE   = false, -- variable namespace
    NOTES = [[
        This structure may contain any top-level XMP tags, but none have been
        pre-defined in ExifTool.  Since no flattened tags have been pre-defined,
        RegionExtensions is writable only as a structure (eg.
        C<{xmp-dc:creator=me,rating=5}>).  Fields for this structure are identified
        using the standard ExifTool tag name (with optional leading group name,
        and/or trailing language code, and/or trailing C<#> symbol to disable print
        conversion).
    ]],
}
local sRegionStruct = {
    STRUCT_NAME = 'MWG RegionStruct',
    NAMESPACE   = 'mwg-rs',
    Area = { Struct = XMP.sArea },
    Type = {
        PrintConv = {
            Face = 'Face',
            Pet = 'Pet',
            Focus = 'Focus',
            BarCode = 'BarCode',
        },
    },
    Name        = { },
    Description = { },
    FocusUsage  = {
        PrintConv = {
            EvaluatedUsed = 'Evaluated, Used',
            EvaluatedNotUsed = 'Evaluated, Not Used',
            NotEvaluatedNotUsed = 'Not Evaluated, Not Used',
        },
    },
    BarCodeValue = { },
    Extensions  = { Struct = sExtensions },
    Rotation    = { -- (observed in LR6 XMP)
        Writable = 'real',
        Notes = 'not part of MWG 2.0 spec',
    },
    -- Title - seen in sample XMP of MWG 2.0 specification, but not in spec itself
    seeAlso = { Namespace = 'rdfs', Resource = 1 },
}
local sKeywordStruct = {
    STRUCT_NAME = 'MWG KeywordStruct',
    NAMESPACE   = 'mwg-kw',
    Keyword   = { },
    Applied   = { Writable = 'boolean' },
}
sKeywordStruct.Children = { Struct = sKeywordStruct, List = 'Bag' }

-- MWG 2.0 XMP region namespace tags
MWG.Regions = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-mwg-rs', [2] = 'Image' },
    NAMESPACE = 'mwg-rs',
    NOTES = [[
        Image region metadata defined by the MWG 2.0 specification.  These tags
        may be accessed without the need to load the MWG Composite tags above.  See
        L<https://web.archive.org/web/20180919181934/http://www.metadataworkinggroup.org/pdf/mwg_guidance.pdf>
        for the official specification.
    ]],
    Regions = {
        Name = 'RegionInfo',
        FlatName = 'Region',
        Struct = {
            STRUCT_NAME = 'MWG RegionInfo',
            NAMESPACE   = 'mwg-rs',
            RegionList = {
                FlatName = 'Region',
                Struct = sRegionStruct,
                List = 'Bag',
            },
            AppliedToDimensions = { Struct = XMP.sDimensions },
        },
    },
    RegionsRegionList = { Flat = 1, Name = 'RegionList' },
}

-- MWG 2.0 XMP hierarchical keyword namespace tags
MWG.Keywords = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-mwg-kw', [2] = 'Image' },
    NAMESPACE = 'mwg-kw',
    NOTES = [[
        Hierarchical keywords metadata defined by the MWG 2.0 specification.
        ExifTool unrolls keyword structures to an arbitrary depth of 6 to allow
        individual levels to be accessed with different tag names, and to avoid
        infinite recursion.  See
        L<https://web.archive.org/web/20180919181934/http://www.metadataworkinggroup.org/pdf/mwg_guidance.pdf>
        for the official specification.
    ]],
    -- arbitrarily define only the first 6 levels of the keyword hierarchy
    Keywords = {
        Name = 'KeywordInfo',
        Struct = {
            STRUCT_NAME = 'MWG KeywordInfo',
            NAMESPACE   = 'mwg-kw',
            Hierarchy = { Struct = sKeywordStruct, List = 'Bag' },
        },
    },
    KeywordsHierarchy = { Name = 'HierarchicalKeywords', Flat = 1 },
    KeywordsHierarchyKeyword  = { Name = 'HierarchicalKeywords1', Flat = 1 },
    KeywordsHierarchyApplied  = { Name = 'HierarchicalKeywords1Applied', Flat = 1 },
    KeywordsHierarchyChildren = { Name = 'HierarchicalKeywords1Children', Flat = 1 },
    KeywordsHierarchyChildrenKeyword  = { Name = 'HierarchicalKeywords2', Flat = 1 },
    KeywordsHierarchyChildrenApplied  = { Name = 'HierarchicalKeywords2Applied', Flat = 1 },
    KeywordsHierarchyChildrenChildren = { Name = 'HierarchicalKeywords2Children', Flat = 1 },
    KeywordsHierarchyChildrenChildrenKeyword  = { Name = 'HierarchicalKeywords3', Flat = 1 },
    KeywordsHierarchyChildrenChildrenApplied  = { Name = 'HierarchicalKeywords3Applied', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildren = { Name = 'HierarchicalKeywords3Children', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenKeyword  = { Name = 'HierarchicalKeywords4', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenApplied  = { Name = 'HierarchicalKeywords4Applied', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenChildren = { Name = 'HierarchicalKeywords4Children', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenChildrenKeyword  = { Name = 'HierarchicalKeywords5', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenChildrenApplied  = { Name = 'HierarchicalKeywords5Applied', Flat = 1 },
    -- break infinite recursion
    KeywordsHierarchyChildrenChildrenChildrenChildrenChildren = { Name = 'HierarchicalKeywords5Children', Flat = 1, NoSubStruct = 1 },
    KeywordsHierarchyChildrenChildrenChildrenChildrenChildrenKeyword = { Name = 'HierarchicalKeywords6', Flat = 1 },
    KeywordsHierarchyChildrenChildrenChildrenChildrenChildrenApplied = { Name = 'HierarchicalKeywords6Applied', Flat = 1 },
}

-- MWG 2.0 XMP collections namespace tags
MWG.Collections = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-mwg-coll', [2] = 'Image' },
    NAMESPACE = 'mwg-coll',
    Collections = {
        FlatName = '',
        List = 'Bag',
        Struct = {
            STRUCT_NAME = 'MWG CollectionInfo',
            NAMESPACE   = 'mwg-coll',
            CollectionName = { },
            CollectionURI  = { },
        },
    },
}

--------------------------------------------------------------------------------
-- Load the MWG Composite tags
function MWG.Load()
    if mwgLoaded then return end

    -- add our composite tags
    ExifTool.AddCompositeTags('lexiftool.MWG', nil, MWG)
    -- must also add to lookup so we can write them
    -- (since MWG tags aren't in the tag lookup by default)
    ExifTool.AddTagsToLookup(MWG.Composite,
                             'lexiftool.ExifTool.Composite')

    -- modify EXIF:Artist to behave as a list-type tag
    local artist = require('lexiftool.Exif').Main[0x13b]
    artist.List = 1
    artist.IsOverwriting = function(...) return MWG.OverwriteStringList(...) end
    artist.RawConv = function(et, val) return MWG.StringToList(val, et) end

    -- enable MWG strict mode if not set already
    -- (causes non-standard EXIF, IPTC and XMP to be ignored)
    if MWG.strict == nil then MWG.strict = 1 end

    mwgLoaded = 1
end

--------------------------------------------------------------------------------
-- Change a list of values to a string using MWG rules
-- Inputs: 0)reference to list of values
-- Returns: string of values (and may reformat list entries)
function MWG.ListToString(vals)
    for i, v in ipairs(vals) do
        -- double all quotes in value and quote the value if it begins
        -- with a quote or contains a semicolon-space separator
        if perl.isMatch(v, '^"') or perl.isMatch(v, '; ') then
            v = perl.subst(v, '"', '""', 'g')   -- double all quotes
            vals[i] = '"' .. v .. '"'           -- quote the value
        end
    end
    return perl.join('; ', vals)
end

--------------------------------------------------------------------------------
-- Change a string value to a list of values using MWG rules
-- Inputs: 0) string of values, 1) ExifTool ref
-- Returns: value or list reference if more than one value
-- Notes: Sets Warning tag on error
function MWG.StringToList(str, et)
    local vals, inQuotes = {}, nil
    local t = perl.split('; ', perl.str(str), -1)
    for _, v in ipairs(t) do
        local wasQuotes = inQuotes
        if not inQuotes then
            local stripped = perl.subst(v, '^"', '')
            if stripped ~= v then inQuotes = 1 end
            v = stripped
        end
        if inQuotes then
            -- remove the last quote and reset the inQuotes flag if
            -- the value ended in an odd number of quotes
            local unq = perl.subst(v, '((^|[^"])("")*)"$', '$1')
            if unq ~= v then inQuotes = nil end
            v = unq
            v = perl.subst(v, '""', '"', 'g') -- un-double the contained quotes
        end
        if wasQuotes then
            -- previous separator was quoted, so concatinate with previous value
            vals[#vals] = vals[#vals] .. '; ' .. v
        else
            vals[#vals + 1] = v
        end
    end
    if inQuotes then et:Warn('Incorrectly quoted MWG string-list value') end
    return #vals > 1 and vals or vals[1]
end

--------------------------------------------------------------------------------
-- Handle logic for overwriting EXIF string-type list tag
-- Inputs: 0) ExifTool ref, 1) new value hash ref,
--         2) old string value (or undef if it didn't exist), 3) new value ref
-- Returns: 1 and sets the new value for the tag
-- (Lua: the new value is the second result instead of $$newValuePt)
function MWG.OverwriteStringList(et, nvHash, val)
    local new, delIndex = {}, nil
    local newValue
    local writeMode = et:Options('WriteMode')
    if writeMode ~= 'wcg' then
        if val ~= nil then
            if not perl.isMatch(writeMode, '(?i)w') then return 0 end
        else
            if not perl.isMatch(writeMode, '(?i)c') then return 0 end
        end
    end
    if nvHash.DelValue and val ~= nil then
        -- preserve specified old values
        local old = MWG.StringToList(val, et)
        local olds = type(old) == 'table' and old or { old }
        if #nvHash.DelValue > 0 then
            local del = {}
            for _, d in ipairs(nvHash.DelValue) do del[d] = 1 end
            for _, o in ipairs(olds) do
                if not del[o] then
                    new[#new + 1] = o
                elseif not delIndex then
                    delIndex = #new
                end
            end
        else
            for _, o in ipairs(olds) do new[#new + 1] = o end
        end
    end
    -- add new values (at location of deleted values, if any)
    if nvHash.Value then
        if delIndex ~= nil then
            for i, v in ipairs(nvHash.Value) do table.insert(new, delIndex + i, v) end
        else
            for _, v in ipairs(nvHash.Value) do new[#new + 1] = v end
        end
    end
    if #new > 0 then
        -- convert back to string format
        newValue = MWG.ListToString(new)
    else
        newValue = nil  -- delete the tag
    end
    return 1, newValue
end

--------------------------------------------------------------------------------
-- Reconcile IPTC digest after writing an MWG tag
-- Inputs: 0) ExifTool object ref
-- Returns: empty string
function MWG.ReconcileIPTCDigest(et)
    -- set new value for IPTCDigest if not done already
    local iptcDigestInfo = require('lexiftool.Photoshop').iptcDigestInfo
    if not (iptcDigestInfo and et.NEW_VALUE and et.NEW_VALUE[iptcDigestInfo]) then
        -- write new IPTCDigest only if it doesn't exist or
        -- is the same as the digest of the original IPTC
        local Writer = require('lexiftool.Writer')
        Writer.SetNewValue(et, 'Photoshop:IPTCDigest', 'old', { Protected = 1, DelValue = 1 })
        Writer.SetNewValue(et, 'Photoshop:IPTCDigest', 'new', { Protected = 1 })
    end
    return ''
end

--------------------------------------------------------------------------------
-- Recover strings which were truncated by IPTC dataset length limit
-- Inputs: 0) IPTC value, 1) XMP value, 2) length limit
-- Notes: handles the case where IPTC and/or XMP values are lists
function MWG.RecoverTruncatedIPTC(iptc, xmp, limit)
    if xmp == nil then return iptc end
    if type(iptc) == 'table' then
        if type(xmp) ~= 'table' then xmp = { xmp } end
        local vals = {}
        for i = 1, #iptc do
            vals[i] = MWG.RecoverTruncatedIPTC(iptc[i], xmp[i], limit)
        end
        return vals
    elseif iptc ~= nil and #iptc == limit then
        if type(xmp) == 'table' then xmp = xmp[1] end    -- take first element of list
        if xmp and #xmp > limit and iptc == xmp:sub(1, limit) then return xmp end
    end
    return iptc
end

return MWG
