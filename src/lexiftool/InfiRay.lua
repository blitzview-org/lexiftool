--------------------------------------------------------------------------------
-- File:         lexiftool/InfiRay.lua
-- Ported from:  lib/Image/ExifTool/InfiRay.pm
--
-- Description:  InfiRay IJPEG thermal image metadata
--
-- Revisions:    2023-02-08 - M. Del Sol Created
--
-- References:   1) https://github.com/exiftool/exiftool/pull/184
--
-- Notes:        Information in this document has been mostly gathered by
--               disassembling the P2 Pro Android app, version 1.0.8.230111.
--
-- Port notes:   read subset. Pure tag-table module (no processing procs):
--               the Version/Factory/Picture/MixMode/OpMode/Isothermal/Sensor
--               tables, all processed via ProcessBinaryData from the JPEG
--               APP2-APP9 segment dispatch in lexiftool.lua. Deferred
--               (unexercised): the extra measurements list in the Picture
--               block and the ndist/nuc_t tables in the Factory block.
--------------------------------------------------------------------------------

local InfiRay = {}

local sprintf = require('lexiftool.perl').sprintf

local convFloat2 = { PrintConv = function(_self, val) return sprintf('%.2f', val) end }
local convPercent = { PrintConv = function(_self, val) return sprintf('%.1f %%', val * 100) end }
local convMeters = { PrintConv = function(_self, val) return sprintf('%.2f m', val) end }
local convCelsius = { PrintConv = function(_self, val) return sprintf('%.2f C', val) end }

-- InfiRay IJPEG version header, found in JPEGs APP2 (upstream %InfiRay::Version)
InfiRay.Version = {
    GROUPS = { [0] = 'APP2', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP2 IJPEG version header, found
        in JPEGs taken with the P2 Pro camera app.
    ]],
    [0x00] = { Name = 'IJPEGVersion', Format = 'int8u[4]' },
    -- 0x04 IJPEGSignature ("IJPEG\0") is commented out upstream
    [0x0c] = { Name = 'IJPEGOrgType', Format = 'int8u' },
    [0x0d] = { Name = 'IJPEGDispType', Format = 'int8u' },
    [0x0e] = { Name = 'IJPEGRotate', Format = 'int8u' },
    [0x0f] = { Name = 'IJPEGMirrorFlip', Format = 'int8u' },
    [0x10] = { Name = 'ImageColorSwitchable', Format = 'int8u' },
    [0x11] = { Name = 'ThermalColorPalette', Format = 'int16u' },
    [0x20] = { Name = 'IRDataSize', Format = 'int64u' },
    [0x28] = { Name = 'IRDataFormat', Format = 'int16u' },
    [0x2a] = { Name = 'IRImageWidth', Format = 'int16u' },
    [0x2c] = { Name = 'IRImageHeight', Format = 'int16u' },
    [0x2e] = { Name = 'IRImageBpp', Format = 'int8u' },
    [0x30] = { Name = 'TempDataSize', Format = 'int64u' },
    [0x38] = { Name = 'TempDataFormat', Format = 'int16u' },
    [0x3a] = { Name = 'TempImageWidth', Format = 'int16u' },
    [0x3c] = { Name = 'TempImageHeight', Format = 'int16u' },
    [0x3e] = { Name = 'TempImageBpp', Format = 'int8u' },
    [0x40] = { Name = 'VisibleDataSize', Format = 'int64u' },
    [0x48] = { Name = 'VisibleDataFormat', Format = 'int16u' },
    [0x4a] = { Name = 'VisibleImageWidth', Format = 'int16u' },
    [0x4c] = { Name = 'VisibleImageHeight', Format = 'int16u' },
    [0x4e] = { Name = 'VisibleImageBpp', Format = 'int8u' },
}

-- InfiRay IJPEG factory temperature, found in IJPEG's APP4 section
-- (upstream %InfiRay::Factory)
InfiRay.Factory = {
    GROUPS = { [0] = 'APP4', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP4 IJPEG camera factory
        defaults and calibration data.
    ]],
    [0x00] = { Name = 'IJPEGTempVersion', Format = 'int8u[4]' },
    [0x04] = { Name = 'FactDefEmissivity', Format = 'int8s' },
    [0x05] = { Name = 'FactDefTau', Format = 'int8s' },
    [0x06] = { Name = 'FactDefTa', Format = 'int16s' },
    [0x08] = { Name = 'FactDefTu', Format = 'int16s' },
    [0x0a] = { Name = 'FactDefDist', Format = 'int16s' },
    [0x0c] = { Name = 'FactDefA0', Format = 'int32s' },
    [0x10] = { Name = 'FactDefB0', Format = 'int32s' },
    [0x14] = { Name = 'FactDefA1', Format = 'int32s' },
    [0x18] = { Name = 'FactDefB1', Format = 'int32s' },
    [0x1c] = { Name = 'FactDefP0', Format = 'int32s' },
    [0x20] = { Name = 'FactDefP1', Format = 'int32s' },
    [0x24] = { Name = 'FactDefP2', Format = 'int32s' },
    [0x44] = { Name = 'FactRelSensorTemp', Format = 'int16s' },
    [0x46] = { Name = 'FactRelShutterTemp', Format = 'int16s' },
    [0x48] = { Name = 'FactRelLensTemp', Format = 'int16s' },
    [0x64] = { Name = 'FactStatusGain', Format = 'int8s' },
    [0x65] = { Name = 'FactStatusEnvOK', Format = 'int8s' },
    [0x66] = { Name = 'FactStatusDistOK', Format = 'int8s' },
    [0x67] = { Name = 'FactStatusTempMap', Format = 'int8s' },
    -- Missing: ndist_table_len, ndist_table, nuc_t_table_len, nuc_t_table
}

-- InfiRay IJPEG picture temperature information, found in IJPEG's APP5 section
-- (upstream %InfiRay::Picture)
InfiRay.Picture = {
    GROUPS = { [0] = 'APP5', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP5 IJPEG picture temperature
        information.
    ]],
    [0x00] = { Name = 'EnvironmentTemp', Format = 'float', PrintConv = convCelsius.PrintConv },
    [0x04] = { Name = 'Distance', Format = 'float', PrintConv = convMeters.PrintConv },
    [0x08] = { Name = 'Emissivity', Format = 'float', PrintConv = convFloat2.PrintConv },
    [0x0c] = { Name = 'Humidity', Format = 'float', PrintConv = convPercent.PrintConv },
    [0x10] = { Name = 'ReferenceTemp', Format = 'float', PrintConv = convCelsius.PrintConv },
    [0x20] = { Name = 'TempUnit', Format = 'int8u' },
    [0x21] = { Name = 'ShowCenterTemp', Format = 'int8u' },
    [0x22] = { Name = 'ShowMaxTemp', Format = 'int8u' },
    [0x23] = { Name = 'ShowMinTemp', Format = 'int8u' },
    [0x24] = { Name = 'TempMeasureCount', Format = 'int16u' },
    -- TODO: process extra measurements list
}

-- InfiRay IJPEG visual-infrared mixing mode, found in IJPEG's APP6 section
-- (upstream %InfiRay::MixMode)
InfiRay.MixMode = {
    GROUPS = { [0] = 'APP6', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP6 IJPEG visual-infrared mixing
        mode section.
    ]],
    [0x00] = { Name = 'MixMode', Format = 'int8u' },
    [0x01] = { Name = 'FusionIntensity', Format = 'float', PrintConv = convPercent.PrintConv },
    [0x05] = { Name = 'OffsetAdjustment', Format = 'float' },
    [0x09] = { Name = 'CorrectionAsix', Format = 'float[30]' },
}

-- InfiRay IJPEG camera operation mode, found in IJPEG's APP7 section
-- (upstream %InfiRay::OpMode)
--
-- I do not know in what units these times are, or what do they represent.
InfiRay.OpMode = {
    GROUPS = { [0] = 'APP7', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP7 IJPEG camera operation mode
        section.
    ]],
    [0x00] = { Name = 'WorkingMode', Format = 'int8u' },
    [0x01] = { Name = 'IntegralTime', Format = 'int32u' },
    [0x05] = { Name = 'IntegratTimeHdr', Format = 'int32u' },
    [0x09] = { Name = 'GainStable', Format = 'int8u' },
    [0x0a] = { Name = 'TempControlEnable', Format = 'int8u' },
    [0x0b] = { Name = 'DeviceTemp', Format = 'float', PrintConv = convCelsius.PrintConv },
}

-- InfiRay IJPEG isothermal information, found in IJPEG's APP8 section
-- (upstream %InfiRay::Isothermal)
--
-- I have genuinely no clue what is the meaning of any of this information, or
-- what is it used for.
InfiRay.Isothermal = {
    GROUPS = { [0] = 'APP8', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP8 IJPEG picture isothermal
        information.
    ]],
    [0x00] = { Name = 'IsothermalMax', Format = 'float' },
    [0x04] = { Name = 'IsothermalMin', Format = 'float' },
    [0x08] = { Name = 'ChromaBarMax', Format = 'float' },
    [0x0c] = { Name = 'ChromaBarMin', Format = 'float' },
}

-- InfiRay IJPEG sensor information, found in IJPEG's APP9 section
-- (upstream %InfiRay::Sensor)
InfiRay.Sensor = {
    GROUPS = { [0] = 'APP9', [2] = 'Image' },
    PROCESS_PROC = require('lexiftool').ProcessBinaryData,
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists tags found in the InfiRay APP9 IJPEG sensor information
        chunk.
    ]],
    [0x000] = { Name = 'IRSensorManufacturer', Format = 'string[12]' },
    [0x040] = { Name = 'IRSensorName', Format = 'string[12]' },
    [0x080] = { Name = 'IRSensorPartNumber', Format = 'string[32]' },
    [0x0c0] = { Name = 'IRSensorSerialNumber', Format = 'string[32]' },
    [0x100] = { Name = 'IRSensorFirmware', Format = 'string[12]' },
    [0x140] = { Name = 'IRSensorAperture', Format = 'float', PrintConv = convFloat2.PrintConv },
    [0x144] = { Name = 'IRFocalLength', Format = 'float', PrintConv = convFloat2.PrintConv },
    [0x180] = { Name = 'VisibleSensorManufacturer', Format = 'string[12]' },
    [0x1c0] = { Name = 'VisibleSensorName', Format = 'string[12]' },
    [0x200] = { Name = 'VisibleSensorPartNumber', Format = 'string[32]' },
    [0x240] = { Name = 'VisibleSensorSerialNumber', Format = 'string[32]' },
    [0x280] = { Name = 'VisibleSensorFirmware', Format = 'string[12]' },
    [0x2c0] = { Name = 'VisibleSensorAperture', Format = 'float' },
    [0x2c4] = { Name = 'VisibleFocalLength', Format = 'float' },
}

return InfiRay