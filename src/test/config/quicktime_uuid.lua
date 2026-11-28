--------------------------------------------------------------------------------
-- File:         test/config/quicktime_uuid.lua
--
-- Description:  Test config file: XMP in a QuickTime 'uuid' atom with an own
--               UUID, the tag of src/test/config/perl/quicktime_uuid.config
--               in the Lua format.  The Condition is made with
--               QuickTime.uuidCondition, so that a new atom gets the UUID.
--------------------------------------------------------------------------------

local QuickTime = require('lexiftool.QuickTime')

local config = { }

config['Image::ExifTool::UserDefined'] = {
    ['Image::ExifTool::QuickTime::Main'] = {
        uuid = {
            Name = 'LexTestUUID',
            Condition = QuickTime.uuidCondition('LEXTEST\x2duuid\x00\x01\x02\xfe'),
            WriteGroup = 'XMP',
            SubDirectory = {
                TagTable = 'Image::ExifTool::XMP::Main',
                DirName = 'XMP',
                Start = 16,
            },
        },
    },
}

return config
