--------------------------------------------------------------------------------
-- File:         lexiftool/Leaf.lua
-- Ported from:  lib/Image/ExifTool/Leaf.pm
--
-- Description:  Read Creo Leaf EXIF meta information
--
-- Revisions:    09/28/2005  - P. Harvey Created
--
-- Port notes:   complete: all fifteen tables (Main, CameraProfile,
--               CaptureProfile, ImageProfile, ShootSetup, CaptureSetup,
--               Neutrals, Selection, ToneCurve, Sharpness, ColorSetup,
--               SaveSetup, CameraSetup, LookHeader, Unknown, SubIFD), the
--               table-preparation block that generates the tag names and the
--               tables' NOTES, and ProcessLeaf.
--               `%Image::ExifTool::previewImageTagInfo`, which upstream
--               spreads into JPEG_preview_data, becomes the shared helper
--               `ExifTool.previewImageTagInfo()` in lexiftool.lua.
--               Wired where upstream wires it: Exif.Main tags 0x8602
--               (WB_GRGBLevels), 0x8606 (LeafData -> Leaf.Main) and 0x888a
--               (LeafSubIFD -> Leaf.SubIFD).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local subst = perl.subst
local substr = perl.substr
local uc, ucfirst = perl.uc, perl.ucfirst
local Get32u = ExifTool.Get32u
local ReadValue = ExifTool.ReadValue

local Leaf = {}

Leaf.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Camera' },
    NOTES = [[
        These tags are found in .MOS images from Leaf digital camera backs as
        written by Creo Leaf Capture.  They exist within the Leaf-specific directory
        structure of EXIF tag 0x8606.  The tables below list observed Leaf tags,
        however ExifTool will extract any tags found in the Leaf directories even if
        they don't appear in these tables.
    ]],
    icc_camera_profile = {
        Name = 'ICC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    icc_rgb_ws_profile = {
        Name = 'RGB_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    camera_profile = {
        Name = 'CameraProfile',
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.CameraProfile',
        },
    },
    JPEG_preview_data = ExifTool.previewImageTagInfo {
        Groups = { [2] = 'Preview' },
    },
    JPEG_preview_info = 'PreviewInfo',
    icc_camera_to_tone_space_flow = {
        Name = 'ToneSpaceFlow',
        Description = 'ICC To Tone Space Flow',
        Format = 'int16u',
    },
    icc_camera_to_tone_matrix = {
        Name = 'ToneMatrix',
        Description = 'ICC To Tone Matrix',
        Format = 'int8u',
        Binary = 1,
    },
    PDA_histogram_data = {
        Name = 'PDAHistogram',
        Binary = 1,
    },
    pattern_ratation_angle = {
        Name = 'PatternAngle',
        Description = 'Pattern Rotation Angle',
        Format = 'int16u',
        Notes = '"ratation" is not a typo',
    },
    back_serial_number = {
        Name = 'BackSerial',
        Description = 'Back Serial Number',
        PrintConv = function(_self, val) return subst(val, [[(?s) .*]], '') end,
    },
    image_offset = { Format = 'int16u' },
}

Leaf.CameraProfile = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Camera' },
    CamProf_version = 'CameraProfileVersion',
    CamProf_name    = 'CameraName',
    CamProf_type    = 'CameraType',
    -- (upstream sets CamProf_back_type twice in a row, the plain string first
    --  and the hash second; in both languages the second one wins)
    CamProf_back_type = {
        Name = 'CameraBackType',
    },
    CamProf_capture_profile = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.CaptureProfile',
        },
    },
    CamProf_image_profile = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.ImageProfile',
        },
    },
}

Leaf.CaptureProfile = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    CaptProf_version        = {},
    CaptProf_name           = {},
    CaptProf_type           = {},
    CaptProf_back_type      = {},
    CaptProf_serial_number  = {
        Name = 'CaptureSerial',
        Description = 'Capture Serial Number',
        PrintConv = function(_self, val) return subst(val, [[(?s) .*]], '') end,
    },
    CaptProf_image_offset       = {},
    CaptProf_luminance_consts   = {},
    CaptProf_xy_offset_info     = 'XYOffsetInfo',
    CaptProf_color_matrix       = {},
    CaptProf_reconstruction_type= {},
    CaptProf_image_fields       = {},
    CaptProf_image_bounds       = {},
    CaptProf_number_of_planes   = {},
    CaptProf_raw_data_rotation  = {},
    CaptProf_color_averages     = {},
    CaptProf_mosaic_pattern     = {},
    CaptProf_dark_correction_type={},
    CaptProf_right_dark_rect    = {},
    CaptProf_left_dark_rect     = {},
    CaptProf_center_dark_rect   = {},
    CaptProf_CCD_rect           = {},
    CaptProf_CCD_valid_rect     = {},
    CaptProf_CCD_video_rect     = {},
}

Leaf.ImageProfile = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    ImgProf_version         = {},
    ImgProf_name            = {},
    ImgProf_type            = {},
    ImgProf_back_type       = {},
    ImgProf_shoot_setup = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.ShootSetup',
        },
    },
    ImgProf_image_status    = {},
    ImgProf_rotation_angle  = {},
}

Leaf.ShootSetup = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    ShootObj_version        = {},
    ShootObj_name           = {},
    ShootObj_type           = {},
    ShootObj_back_type      = {},
    ShootObj_capture_setup = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.CaptureSetup',
        },
    },
    ShootObj_color_setup = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.ColorSetup',
        },
    },
    ShootObj_save_setup = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.SaveSetup',
        },
    },
    ShootObj_camera_setup = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.CameraSetup',
        },
    },
    ShootObj_look_header = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.LookHeader',
        },
    },
}

Leaf.CaptureSetup = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    CaptureObj_version      = {},
    CaptureObj_name         = {},
    CaptureObj_type         = {},
    CaptureObj_back_type    = {},
    CaptureObj_neutals = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.Neutrals',
        },
    },
    CaptureObj_selection = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.Selection',
        },
    },
    CaptureObj_tone_curve = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.ToneCurve',
        },
    },
    CaptureObj_sharpness = {
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.Sharpness',
        },
    },
    CaptureObj_single_quality = {},
    CaptureObj_Multi_quality  = {},
}

Leaf.Neutrals = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    NeutObj_version         = {},
    NeutObj_name            = {},
    NeutObj_type            = {},
    NeutObj_back_type       = {},
    NeutObj_neutrals        = {},
    NeutObj_color_casts     = {},
    NeutObj_shadow_end_points    = {},
    NeutObj_highlight_end_points = {},
}

Leaf.Selection = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    SelObj_version          = {},
    SelObj_name             = {},
    SelObj_type             = {},
    SelObj_back_type        = {},
    SelObj_rect             = {},
    SelObj_resolution       = {},
    SelObj_scale            = {},
    SelObj_locks            = {},
    SelObj_orientation      = {},
}

Leaf.ToneCurve = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    ToneObj_version         = {},
    ToneObj_name            = {},
    ToneObj_type            = {},
    ToneObj_back_type       = {},
    ToneObj_npts            = {},
    ToneObj_tones           = {},
    ToneObj_gamma           = {},
}

Leaf.Sharpness = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    SharpObj_version        = {},
    SharpObj_name           = {},
    SharpObj_type           = {},
    SharpObj_back_type      = {},
    SharpObj_sharp_method   = {},
    SharpObj_data_len       = {},
    SharpObj_sharp_info     = {},
}

Leaf.ColorSetup = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Image' },
    ColorObj_version        = {},
    ColorObj_name           = {},
    ColorObj_type           = {},
    ColorObj_back_type      = {},
    ColorObj_has_ICC        = {},
    ColorObj_input_profile  = {},
    ColorObj_output_profile = {},
    ColorObj_color_mode     = {},
    ColorObj_color_type     = {},
}

Leaf.SaveSetup = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Other' },
    SaveObj_version         = {},
    SaveObj_name            = {},
    SaveObj_type            = {},
    SaveObj_back_type       = {},
    SaveObj_leaf_auto_active= {},
    SaveObj_leaf_hot_folder = {},
    SaveObj_leaf_output_file_type = {},
    SaveObj_leaf_auto_base_name   = {},
    SaveObj_leaf_save_selection   = {},
    SaveObj_leaf_open_proc_HDR    = {},
    SaveObj_std_auto_active       = {},
    SaveObj_std_hot_folder        = {},
    SaveObj_std_output_file_type  = {},
    SaveObj_std_output_color_mode = {},
    SaveObj_std_output_bit_depth  = {},
    SaveObj_std_base_name         = {},
    SaveObj_std_save_selection    = {},
    SaveObj_std_oxygen            = {},
    SaveObj_std_open_in_photoshop = {},
    SaveObj_std_scaled_output     = {},
    SaveObj_std_sharpen_output    = {},
}

Leaf.CameraSetup = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Camera' },
    CameraObj_version       = {},
    CameraObj_name          = {},
    CameraObj_type          = {},
    CameraObj_back_type     = {},
    CameraObj_ISO_speed     = {},
    CameraObj_strobe        = {},
    CameraObj_camera_type   = {},
    CameraObj_lens_type     = {},
    CameraObj_lens_ID       = {},
}

Leaf.LookHeader = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Other' },
    LookHead_version        = {},
    LookHead_name           = {},
    LookHead_type           = {},
    LookHead_back_type      = {},
}

-- tag table for any unknown Leaf directories
Leaf.Unknown = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Leaf', [2] = 'Unknown' },
}

-- table for Leaf SubIFD entries
Leaf.SubIFD = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'LeafSubIFD', [2] = 'Image'},
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    NOTES = [[
        Leaf writes a TIFF-format sub-IFD inside IFD0 of a MOS image.  No tags in
        this sub-IFD are currently known, except for tags 0x8602 and 0x8606 which
        really shouldn't be here anyway (so they don't appear in the table below)
        because they duplicate references to the same data from tags with the same
        ID in IFD0.
    ]],
}

-- prepare Leaf tables by generating tag 'Name' and table 'NOTES'
do
    local tableList = { 'lexiftool.Leaf.Main' }
    local doneTable = {}
    -- keep prefix in tag name of common tags
    local keepPrefix = { Version=1, Name=1, Type=1, BackType=1 }
    while #tableList > 0 do
        local tableName = table.remove(tableList, 1)
        if not doneTable[tableName] then
            -- (upstream: `my $prefix = ($table =~ /::Main$/) ? undef : '';` --
            --  written out, because Lua's `cond and nil or ''` always yields '')
            local prefix
            if not matches(tableName, [[\.Main$]]) then prefix = '' end
            doneTable[tableName] = 1
            local table_ = Leaf[tableName:match('^lexiftool%.Leaf%.(.*)$')]
            for tag, tagInfo in pairs(table_) do
                if type(tagInfo) == 'table' and tag ~= 'GROUPS' then
                    if prefix ~= nil and prefix == '' then
                        prefix = subst(tag, [[(?s)_.*]], '')
                    end
                    if not tagInfo.Name then
                        local name = subst(tag, [[_(.)]], function(c) return uc(c) end, 'g')
                        if prefix ~= nil and prefix ~= '' then
                            name = perl.substDyn(name, '^' .. prefix, '')
                            if keepPrefix[name] then name = prefix .. name end
                        end
                        tagInfo.Name = ucfirst(name)
                    end
                    if tagInfo.SubDirectory then
                        local subTable = tagInfo.SubDirectory.TagTable
                        if matches(subTable, [[\.Leaf\.]]) then
                            tableList[#tableList + 1] = subTable
                        end
                    end
                end
            end
            if prefix ~= nil and prefix ~= '' then
                table_.NOTES = "All B<Tag ID>'s in the following table have a " ..
                               "leading '" .. prefix .. "_' which\nhas been removed.\n"
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Process Leaf information
-- Inputs: 0) ExifTool object reference
--         1) Reference to directory information hash
--         2) Pointer to tag table for this directory
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function Leaf.ProcessLeaf(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (dirInfo.DataLen - dirStart)
    local dirEnd = dirStart + dirLen
    local verbose = et:Options('Verbose')
    local pos = dirStart
    local hdrLen = 52    -- header length for PKTS information
    local success

    if ExifTool.perlTruthy(verbose) then et:VerboseDir('Leaf') end
    while true do
        if pos + hdrLen > dirEnd then break end
        local header = substr(dataPt, pos, hdrLen)
        if substr(header, 0, 4) ~= 'PKTS' then break end
        success = 1
        local size = Get32u(header, 48)
        pos = pos + hdrLen
        if pos + size > dirEnd then
            et:Warn('Truncated Leaf data')
            break
        end
        local tag = substr(header, 8, 40)
        tag = subst(tag, [[(?s)\0.*]], '')
        if tag ~= '' then
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            -- generate tag info for unknown tags
            local val
            if tagInfo and tagInfo.Format then
                val = ReadValue(dataPt, pos, tagInfo.Format, nil, size)
            else
                val = substr(dataPt, pos, size)
            end
            if not tagInfo then
                local name = ucfirst(tag)
                name = subst(name, [[_(.)]], function(c) return uc(c) end, 'g')
                if matches(val, [[^PKTS\0\0\0\x01]]) then
                    -- also unpack unknown directories
                    tagInfo = {
                        Name = name,
                        SubDirectory = { TagTable = 'lexiftool.Leaf.Unknown' },
                    }
                elseif tagTablePtr ~= Leaf.Main or
                       ExifTool.perlTruthy(et:Options('Unknown'))
                then
                    tagInfo = {
                        Name = name,
                        Writable = 0,
                        PrintConv = function(self, v) return ExifTool.LimitLongValues(v, self) end,
                    }
                    -- make tags in main table unknown because they tend to be binary
                    if tagTablePtr == Leaf.Main then tagInfo.Unknown = 1 end
                end
                if tagInfo then ExifTool.AddTagToTable(et, tagTablePtr, tag, tagInfo) end
            end
            if ExifTool.perlTruthy(verbose) then
                et:VerboseInfo(tag, tagInfo, {
                    Table   = tagTablePtr,
                    Value   = val,
                    DataPt  = dataPt,
                    DataPos = dirInfo.DataPos,
                    Size    = size,
                    Start   = pos,
                })
            end
            if tagInfo then
                if tagInfo.SubDirectory then
                    local subdirInfo = {
                        DataPt = dataPt,
                        DirLen = size,
                        DirStart = pos,
                        DataPos = dirInfo.DataPos,
                        DirName = 'Leaf PKTS',
                    }
                    local subTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                    et:ProcessDirectory(subdirInfo, subTable)
                else
                    -- (ReadValue hands back a Lua number for a single-value
                    --  Format; Perl's tr/// stringifies it on the spot)
                    if type(val) == 'number' then val = ExifTool.NumStr(val) end
                    val = val:gsub('\n', ' ')   -- translate newlines to spaces
                    val = subst(val, [[\0+$]], '')   -- remove null terminators
                    et:FoundTag(tagInfo, val)
                end
            end
            pos = pos + size
        end
    end
    if not success then et:Warn('Bad format Leaf data') end
    return success
end

Leaf.Main.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.CameraProfile.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.CaptureProfile.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.ImageProfile.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.ShootSetup.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.CaptureSetup.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.Neutrals.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.Selection.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.ToneCurve.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.Sharpness.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.ColorSetup.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.SaveSetup.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.CameraSetup.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.LookHeader.PROCESS_PROC = Leaf.ProcessLeaf
Leaf.Unknown.PROCESS_PROC = Leaf.ProcessLeaf

return Leaf
