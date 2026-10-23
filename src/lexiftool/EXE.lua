--------------------------------------------------------------------------------
-- File:         lexiftool/EXE.lua
-- Ported from:  lib/Image/ExifTool/EXE.pm
--
-- Description:  Read meta information of various executable file formats
--
-- Revisions:    2008/08/28 - P. Harvey Created
--               2011/07/12 - P. Harvey Added CHM (ok, not EXE, but it fits here)
--
-- References:   1) http://www.openwatcom.org/ftp/devel/docs/pecoff.pdf
--               2) http://support.microsoft.com/kb/65122
--               3) http://www.opensource.apple.com
--               4) http://www.skyfree.org/linux/references/ELF_Format.pdf
--               5) http://msdn.microsoft.com/en-us/library/ms809762.aspx
--               6) http://code.google.com/p/pefile/
--               7) http://www.codeproject.com/KB/DLL/showver.aspx
--               8) https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
--
-- Port notes:   read subset covering the vendored test files: Windows PE
--               (EXE.exe, incl. the version resource via ProcessPEDict/
--               ProcessPEResources/ProcessPEVersion and the CodeView debug
--               tables), Mach-O (EXE.macho/dylib + the .a static-library
--               archive walk), ELF (EXE.elf/so) and the plain `!<arch>`
--               static library, PEF (classic MacOS) and CHM files.  All
--               tables, lookups and subs are present; MachOverride carries
--               upstream's name for the Mach-O file-type override.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local perlStr = perl.str
local uc = perl.uc

local EXE = {}

-- PE file resource types (ref 6)
local resourceType = {
    [1] = 'Cursor',
    [2] = 'Bitmap',
    [3] = 'Icon',
    [4] = 'Menu',
    [5] = 'Dialog',
    [6] = 'String',
    [7] = 'Font Dir',
    [8] = 'Font',
    [9] = 'Accelerator',
    [10] = 'RC Data',
    [11] = 'Message Table',
    [12] = 'Group Cursor',
    [14] = 'Group Icon',
    [16] = 'Version',
    [17] = 'Dialog Include',
    [19] = 'Plug-n-Play',
    [20] = 'VxD',
    [21] = 'Animated Cursor',
    [22] = 'Animated Icon',
    [23] = 'HTML',
    [24] = 'Manifest',
}

local languageCode = {
    Notes = [[
        See L<https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-lcid>
        for the full list of Microsoft language codes.
    ]],
    ['0000'] = 'Neutral',
    ['007F'] = 'Invariant',
    ['0400'] = 'Process default',
    ['0401'] = 'Arabic',
    ['0402'] = 'Bulgarian',
    ['0403'] = 'Catalan',
    ['0404'] = 'Chinese (Traditional)',
    ['0405'] = 'Czech',
    ['0406'] = 'Danish',
    ['0407'] = 'German',
    ['0408'] = 'Greek',
    ['0409'] = 'English (U.S.)',
    ['040A'] = 'Spanish (Castilian)',
    ['040B'] = 'Finnish',
    ['040C'] = 'French',
    ['040D'] = 'Hebrew',
    ['040E'] = 'Hungarian',
    ['040F'] = 'Icelandic',
    ['0410'] = 'Italian',
    ['0411'] = 'Japanese',
    ['0412'] = 'Korean',
    ['0413'] = 'Dutch',
    ['0414'] = 'Norwegian (Bokml)',
    ['0415'] = 'Polish',
    ['0416'] = 'Portuguese (Brazilian)',
    ['0417'] = 'Rhaeto-Romanic',
    ['0418'] = 'Romanian',
    ['0419'] = 'Russian',
    ['041A'] = 'Croato-Serbian (Latin)',
    ['041B'] = 'Slovak',
    ['041C'] = 'Albanian',
    ['041D'] = 'Swedish',
    ['041E'] = 'Thai',
    ['041F'] = 'Turkish',
    ['0420'] = 'Urdu',
    ['0421'] = 'Indonesian',
    ['0422'] = 'Ukrainian',
    ['0423'] = 'Belarusian',
    ['0424'] = 'Slovenian',
    ['0425'] = 'Estonian',
    ['0426'] = 'Latvian',
    ['0427'] = 'Lithuanian',
    ['0428'] = 'Maori',
    ['0429'] = 'Farsi',
    ['042a'] = 'Vietnamese',
    ['042b'] = 'Armenian',
    ['042c'] = 'Azeri',
    ['042d'] = 'Basque',
    ['042e'] = 'Sorbian',
    ['042f'] = 'Macedonian',
    ['0430'] = 'Sutu',
    ['0431'] = 'Tsonga',
    ['0432'] = 'Tswana',
    ['0433'] = 'Venda',
    ['0434'] = 'Xhosa',
    ['0435'] = 'Zulu',
    ['0436'] = 'Afrikaans',
    ['0437'] = 'Georgian',
    ['0438'] = 'Faeroese',
    ['0439'] = 'Hindi',
    ['043a'] = 'Maltese',
    ['043b'] = 'Saami',
    ['043c'] = 'Gaelic',
    ['043e'] = 'Malay',
    ['043f'] = 'Kazak',
    ['0440'] = 'Kyrgyz',
    ['0441'] = 'Swahili',
    ['0443'] = 'Uzbek',
    ['0444'] = 'Tatar',
    ['0445'] = 'Bengali',
    ['0446'] = 'Punjabi',
    ['0447'] = 'Gujarati',
    ['0448'] = 'Oriya',
    ['0449'] = 'Tamil',
    ['044a'] = 'Telugu',
    ['044b'] = 'Kannada',
    ['044c'] = 'Malayalam',
    ['044d'] = 'Assamese',
    ['044e'] = 'Marathi',
    ['044f'] = 'Sanskrit',
    ['0450'] = 'Mongolian',
    ['0456'] = 'Galician',
    ['0457'] = 'Konkani',
    ['0458'] = 'Manipuri',
    ['0459'] = 'Sindhi',
    ['045a'] = 'Syriac',
    ['0460'] = 'Kashmiri',
    ['0461'] = 'Nepali',
    ['0465'] = 'Divehi',
    ['047f'] = 'Invariant',
    ['048f'] = 'Esperanto',
    ['0490'] = 'Walon',
    ['0491'] = 'Cornish',
    ['0492'] = 'Welsh',
    ['0493'] = 'Breton',
    ['0800'] = 'Neutral 2',
    ['0804'] = 'Chinese (Simplified)',
    ['0807'] = 'German (Swiss)',
    ['0809'] = 'English (British)',
    ['080A'] = 'Spanish (Mexican)',
    ['080C'] = 'French (Belgian)',
    ['0810'] = 'Italian (Swiss)',
    ['0813'] = 'Dutch (Belgian)',
    ['0814'] = 'Norwegian (Nynorsk)',
    ['0816'] = 'Portuguese',
    ['081A'] = 'Serbo-Croatian (Cyrillic)',
    ['0C07'] = 'German (Austrian)',
    ['0C09'] = 'English (Australian)',
    ['0C0A'] = 'Spanish (Modern)',
    ['0C0C'] = 'French (Canadian)',
    ['1009'] = 'English (Canadian)',
    ['100C'] = 'French (Swiss)',
}

-- (port helper: copy the shared hash into the entry, as Perl's `%hash`
--  spread does -- explicit fields of the entry win)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

-- shared int32u timestamp fields (upstream %int32uTime)
local int32uTime = spread {
    Format = 'int32u',
    Groups = { [0] = 'EXE', [1] = 'EXE', [2] = 'Time' },
    ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- upstream `$val =~ tr/ /./; $val` (int16u[2]/int8u[2] version strings)
local function dotsToVersion(_self, val)
    return (perlStr(val):gsub(' ', '.'))
end

--------------------------------------------------------------------------------
-- EXE metadata
--------------------------------------------------------------------------------
-- Windows PE (Portable Executable) COFF file header (+ optional header)
EXE.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int16u',
    NOTES = [[
        This module extracts information from various types of Windows, MacOS and
        Unix executable and library files.  The first table below lists information
        extracted from the header of Windows PE (Portable Executable) EXE files and
        DLL libraries.
    ]],
    [0] = {
        Name = 'MachineType',
        PrintHex = 1,
        PrintConv = {
            [0x0000] = 'Unknown',
            [0x01] = 'Target host',
            [0x014c] = 'Intel 386 or later, and compatibles',
            [0x014d] = 'Intel i860', --5
            [0x0162] = 'MIPS R3000',
            [0x0166] = 'MIPS little endian (R4000)',
            [0x0168] = 'MIPS R10000',
            [0x0169] = 'MIPS little endian WCI v2',
            [0x0183] = 'Alpha AXP (old)', --5
            [0x0184] = 'Alpha AXP',
            [0x01a2] = 'Hitachi SH3',
            [0x01a3] = 'Hitachi SH3 DSP',
            [0x01a4] = 'Hitachi SH3E',
            [0x01a6] = 'Hitachi SH4',
            [0x01a8] = 'Hitachi SH5',
            [0x01c0] = 'ARM little endian',
            [0x01c2] = 'Thumb',
            [0x01c4] = 'Thumb 2 little endian',
            [0x01d3] = 'Matsushita AM33',
            [0x01f0] = 'PowerPC little endian',
            [0x01f1] = 'PowerPC with floating point support',
            [0x0200] = 'Intel IA64',
            [0x0266] = 'MIPS16',
            [0x0268] = 'Motorola 68000 series',
            [0x0284] = 'Alpha AXP 64-bit',
            [0x0366] = 'MIPS with FPU',
            [0x0466] = 'MIPS16 with FPU',
            [0x0520] = 'Infineon Tricore',
            [0x0ebc] = 'EFI Byte Code',
            [0x3a64] = 'Compiled Hybrid PE',
            [0x5032] = 'RISC-V 32-bit',
            [0x5064] = 'RISC-V 64-bit',
            [0x5128] = 'RISC-V 128-bit',
            [0x6232] = 'LoongArch 32-bit',
            [0x6264] = 'LoongArch 64-bit',
            [0x8664] = 'AMD AMD64',
            [0x9041] = 'Mitsubishi M32R little endian',
            [0xaa64] = 'ARM64 little endian',
            [0xc0ee] = 'clr pure MSIL',
            [0x0cef] = 'CEF',
            [0xec20] = 'Dotnet 0xEC20',
        },
    },
    [2] = int32uTime { Name = 'TimeStamp' },
    [9] = {
        Name = 'ImageFileCharacteristics',
        -- ref https://docs.microsoft.com/en-us/windows/desktop/api/winnt/ns-winnt-image_file_header
        PrintConv = { BITMASK = {
            [0] = 'No relocs',
            [1] = 'Executable',
            [2] = 'No line numbers',
            [3] = 'No symbols',
            [4] = 'Aggressive working-set trim',
            [5] = 'Large address aware',
            [7] = 'Bytes reversed lo',
            [8] = '32-bit',
            [9] = 'No debug',
            [10] = 'Removable run from swap',
            [11] = 'Net run from swap',
            [12] = 'System file',
            [13] = 'DLL',
            [14] = 'Uniprocessor only',
            [15] = 'Bytes reversed hi',
        }},
    },
--
-- optional header starts at index 10
-- (note: all extracted tags are the same for 32 and 64-bit versions of the optional header)
--
    [10] = {
        Name = 'PEType',
        PrintHex = 1,
        PrintConv = {
            [0x107] = 'ROM Image',
            [0x10b] = 'PE32',
            [0x20b] = 'PE32+',
        },
    },
    [11] = {
        Name = 'LinkerVersion',
        Format = 'int8u[2]',
        ValueConv = dotsToVersion,
    },
    [12] = {
        Name = 'CodeSize',
        Format = 'int32u',
    },
    [14] = {
        Name = 'InitializedDataSize',
        Format = 'int32u',
    },
    [16] = {
        Name = 'UninitializedDataSize',
        Format = 'int32u',
    },
    [18] = {
        Name = 'EntryPoint',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%.4x', val) end,
    },
    [30] = {
        Name = 'OSVersion',
        Format = 'int16u[2]',
        ValueConv = dotsToVersion,
    },
    [32] = {
        Name = 'ImageVersion',
        Format = 'int16u[2]',
        ValueConv = dotsToVersion,
    },
    [34] = {
        Name = 'SubsystemVersion',
        Format = 'int16u[2]',
        ValueConv = dotsToVersion,
    },
    [44] = {
        Name = 'Subsystem',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Native',
            [2] = 'Windows GUI',
            [3] = 'Windows command line',
            [5] = 'OS/2 command line', --5
            [7] = 'POSIX command line',
            [9] = 'Windows CE GUI',
            [10] = 'EFI application',
            [11] = 'EFI boot service',
            [12] = 'EFI runtime driver',
            [13] = 'EFI ROM', --6
            [14] = 'XBOX', --6
        },
    },
}

-- information extracted from newer CodeView PDB70 ("RSDS") debug entry
EXE.DebugRSDS = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'CodeView RSDS debug information found in some Windows EXE files.',
    [0]  = int32uTime {
        Name = 'PDBModifyDate',
        Notes = 'Taken from debug directory entry pointing to RSDS record.',
    },
    [20] = { Name = 'PDBAge',       Format = 'int32u' },
    [24] = { Name = 'PDBFileName',  Format = 'string' },
}

-- information extracted from older CodeView PDB20 ("NB10") debug entry
EXE.DebugNB10 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'CodeView NB10 debug information found in some Windows EXE files.',
    [0]  = int32uTime {
        Name = 'PDBModifyDate',
        Notes = 'Taken from debug directory entry pointing to NB10 record.',
    },
    [8]  = int32uTime { Name = 'PDBCreateDate' },
    [12] = { Name = 'PDBAge',       Format = 'int32u' },
    [16] = { Name = 'PDBFileName',  Format = 'string' },
}

EXE.Misc = {
    GROUPS = { [2] = 'Other' },
    VARS = { ID_LABEL = 'Index1' },
    NOTES = 'Miscellaneous CodeView debug information in Windows EXE files.',
    [12] = 'EXEFileName',
}

-- PE file version information (ref 6)
EXE.PEVersion = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int32u',
    NOTES = [[
        Information extracted from the VS_VERSION_INFO structure of Windows PE
        files.
    ]],
    -- (boring -- always 0xfeef04bd)  0 => Signature
    -- (boring -- always 1.0)         1 => StructVersion
    [2] = {
        Name = 'FileVersionNumber',
        Format = 'int16u[4]',
        ValueConv = function(_self, val)
            local a = {}
            for w in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = w end
            return a[2] .. '.' .. a[1] .. '.' .. a[4] .. '.' .. a[3]
        end,
    },
    [4] = {
        Name = 'ProductVersionNumber',
        Format = 'int16u[4]',
        ValueConv = function(_self, val)
            local a = {}
            for w in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = w end
            return a[2] .. '.' .. a[1] .. '.' .. a[4] .. '.' .. a[3]
        end,
    },
    [6] = {
        Name = 'FileFlagsMask',
        PrintConv = function(_self, val) return sprintf('0x%.4x', val) end,
    },
    [7] = { -- ref Cygwin /usr/include/w32api/winver.h
        Name = 'FileFlags',
        PrintConv = { BITMASK = {
            [0] = 'Debug',
            [1] = 'Pre-release',
            [2] = 'Patched',
            [3] = 'Private build',
            [4] = 'Info inferred',
            [5] = 'Special build',
        }},
    },
    [8] = {
        Name = 'FileOS',
        PrintHex = 1,
        PrintConv = { -- ref Cygwin /usr/include/w32api/winver.h
            [0x00001] = 'Win16',
            [0x00002] = 'PM-16',
            [0x00003] = 'PM-32',
            [0x00004] = 'Win32',
            [0x10000] = 'DOS',
            [0x20000] = 'OS/2 16-bit',
            [0x30000] = 'OS/2 32-bit',
            [0x40000] = 'Windows NT',
            [0x10001] = 'Windows 16-bit',
            [0x10004] = 'Windows 32-bit',
            [0x20002] = 'OS/2 16-bit PM-16',
            [0x30003] = 'OS/2 32-bit PM-32',
            [0x40004] = 'Windows NT 32-bit',
        },
    },
    [9] = { -- ref Cygwin /usr/include/w32api/winver.h
        Name = 'ObjectFileType',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Executable application',
            [2] = 'Dynamic link library',
            [3] = 'Driver',
            [4] = 'Font',
            [5] = 'VxD',
            [7] = 'Static library',
        },
    },
    [10] = 'FileSubtype',
    -- (these are usually zero, so ignore them)
    -- 11 => 'FileDateMS',
    -- 12 => 'FileDateLS',
}

-- Windows PE StringFileInfo resource strings
-- (see http://msdn.microsoft.com/en-us/library/aa381049.aspx)
EXE.PEString = {
    GROUPS = { [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Resource strings found in Windows PE files.  The B<TagID>'s are not shown
        because they are the same as the B<Tag Name>.  ExifTool will extract any
        existing StringFileInfo tags even if not listed in this table.
    ]],
    LanguageCode = {
        Notes = 'Windows code page; extracted from the StringFileInfo value',
        -- ref http://techsupt.winbatch.com/TS/T000001050F49.html
        -- (also see http://support.bigfix.com/fixlet/documents/WinInspectors-2006-08-10.pdf)
        -- (also see ftp://ftp.dyu.edu.tw/pub/cpatch/faq/tech/tech_nlsnt.txt)
        -- (not a complete set)
        PrintString = 1,
        SeparateTable = 1,
        PrintConv = languageCode,
    },
    CharacterSet = {
        Notes = 'extracted from the StringFileInfo value',
        -- ref http://techsupt.winbatch.com/TS/T000001050F49.html
        -- (also see http://blog.chinaunix.net/u1/41189/showart_345768.html)
        PrintString = 1,
        PrintConv = {
            ['0000'] = 'ASCII',
            ['03A4'] = 'Windows, Japan (Shift - JIS X-0208)', -- cp932
            ['03A8'] = 'Windows, Chinese (Simplified)', -- cp936
            ['03B5'] = 'Windows, Korea (Shift - KSC 5601)', -- cp949
            ['03B6'] = 'Windows, Taiwan (Big5)', -- cp950
            ['04B0'] = 'Unicode', -- UCS-2
            ['04E2'] = 'Windows, Latin2 (Eastern European)',
            ['04E3'] = 'Windows, Cyrillic',
            ['04E4'] = 'Windows, Latin1',
            ['04E5'] = 'Windows, Greek',
            ['04E6'] = 'Windows, Turkish',
            ['04E7'] = 'Windows, Hebrew',
            ['04E8'] = 'Windows, Arabic',
        },
    },
    BuildDate       = { Groups = { [2] = 'Time' } }, -- (non-standard)
    BuildVersion    = {}, -- (non-standard)
    Comments        = {},
    CompanyName     = {},
    Copyright       = {}, -- (non-standard)
    FileDescription = {},
    FileVersion     = {},
    InternalName    = {},
    LegalCopyright  = {},
    LegalTrademarks = {},
    OriginalFilename= { Name = 'OriginalFileName' },
    PrivateBuild    = {},
    ProductName     = {},
    ProductVersion  = {},
    SpecialBuild    = {},
}

-- Information extracted from Mach-O (Mac OS X) file header
EXE.MachO = {
    GROUPS = { [2] = 'Other' },
    VARS = { ID_LABEL = 'Index' },
    NOTES = [[
        Information extracted from Mach-O (Mac OS X) executable files and DYLIB
        libraries.
    ]],
    -- ref http://www.opensource.apple.com/darwinsource/DevToolsOct2007/cctools-622.9/include/mach/machine.h
    [0] = 'CPUArchitecture',
    [1] = 'CPUByteOrder',
    [2] = 'CPUCount',
    -- ref /System/Library/Frameworks/Kernel.framework/Versions/A/Headers/mach/machine.h
    [3] = {
        Name = 'CPUType',
        List = 1,
        PrintConv = {
            -- handle 64-bit flag (0x1000000)
            OTHER = function(val, _inv, conv)
                local v = val & 0xfeffffff
                if conv[v] then return perlStr(conv[v]) .. ' 64-bit' end
                return 'Unknown (' .. perlStr(val) .. ')'
            end,
            [-1] = 'Any',
            [1] = 'VAX',
            [2] = 'ROMP',
            [4] = 'NS32032',
            [5] = 'NS32332',
            [6] = 'MC680x0',
            [7] = 'x86',
            [8] = 'MIPS',
            [9] = 'NS32532',
            [10] = 'MC98000',
            [11] = 'HPPA',
            [12] = 'ARM',
            [13] = 'MC88000',
            [14] = 'SPARC',
            [15] = 'i860 big endian',
            [16] = 'i860 little endian',
            [17] = 'RS6000',
            [18] = 'PowerPC',
            [255] = 'VEO',
        },
    },
    -- ref /System/Library/Frameworks/Kernel.framework/Versions/A/Headers/mach/machine.h
    [4] = {
        Name = 'CPUSubtype',
        List = 1,
        PrintConv = {
            -- handle 64-bit flags on CPUType (0x1000000) and CPUSubtype (0x80000000)
            OTHER = function(val, _inv, conv)
                local parts = {}
                for w in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do parts[#parts + 1] = tonumber(w) end
                local v = (parts[1] & 0xfeffffff) .. ' ' .. (parts[2] & 0x7fffffff)
                if conv[v] then return perlStr(conv[v]) .. ' 64-bit' end
                return 'Unknown (' .. perlStr(val) .. ')'
            end,
            -- in theory, subtype can be -1 for multiple CPU types,
            -- but in practice I'm not sure anyone uses this - PH
            ['1 0'] = 'VAX (all)',
            ['1 1'] = 'VAX780',
            ['1 2'] = 'VAX785',
            ['1 3'] = 'VAX750',
            ['1 4'] = 'VAX730',
            ['1 5'] = 'UVAXI',
            ['1 6'] = 'UVAXII',
            ['1 7'] = 'VAX8200',
            ['1 8'] = 'VAX8500',
            ['1 9'] = 'VAX8600',
            ['1 10'] = 'VAX8650',
            ['1 11'] = 'VAX8800',
            ['1 12'] = 'UVAXIII',
            ['2 0'] = 'RT (all)',
            ['2 1'] = 'RT PC',
            ['2 2'] = 'RT APC',
            ['2 3'] = 'RT 135',
            -- 32032/32332/32532 subtypes.
            ['4 0'] = 'NS32032 (all)',
            ['4 1'] = 'NS32032 DPC (032 CPU)',
            ['4 2'] = 'NS32032 SQT',
            ['4 3'] = 'NS32032 APC FPU (32081)',
            ['4 4'] = 'NS32032 APC FPA (Weitek)',
            ['4 5'] = 'NS32032 XPC (532)',
            ['5 0'] = 'NS32332 (all)',
            ['5 1'] = 'NS32332 DPC (032 CPU)',
            ['5 2'] = 'NS32332 SQT',
            ['5 3'] = 'NS32332 APC FPU (32081)',
            ['5 4'] = 'NS32332 APC FPA (Weitek)',
            ['5 5'] = 'NS32332 XPC (532)',
            ['6 1'] = 'MC680x0 (all)',
            ['6 2'] = 'MC68040',
            ['6 3'] = 'MC68030',
            ['7 3'] = 'i386 (all)',
            ['7 4'] = 'i486',
            ['7 132'] = 'i486SX',
            ['7 5'] = 'i586',
            ['7 22'] = 'Pentium Pro',
            ['7 54'] = 'Pentium II M3',
            ['7 86'] = 'Pentium II M5',
            ['7 103'] = 'Celeron',
            ['7 119'] = 'Celeron Mobile',
            ['7 8'] = 'Pentium III',
            ['7 24'] = 'Pentium III M',
            ['7 40'] = 'Pentium III Xeon',
            ['7 9'] = 'Pentium M',
            ['7 10'] = 'Pentium 4',
            ['7 26'] = 'Pentium 4 M',
            ['7 11'] = 'Itanium',
            ['7 27'] = 'Itanium 2',
            ['7 12'] = 'Xeon',
            ['7 28'] = 'Xeon MP',
            ['8 0'] = 'MIPS (all)',
            ['8 1'] = 'MIPS R2300',
            ['8 2'] = 'MIPS R2600',
            ['8 3'] = 'MIPS R2800',
            ['8 4'] = 'MIPS R2000a',
            ['8 5'] = 'MIPS R2000',
            ['8 6'] = 'MIPS R3000a',
            ['8 7'] = 'MIPS R3000',
            ['10 0'] = 'MC98000 (all)',
            ['10 1'] = 'MC98601',
            ['11 0'] = 'HPPA (all)',
            ['11 1'] = 'HPPA 7100LC',
            ['12 0'] = 'ARM (all)',
            ['12 1'] = 'ARM A500 ARCH',
            ['12 2'] = 'ARM A500',
            ['12 3'] = 'ARM A440',
            ['12 4'] = 'ARM M4',
            ['12 5'] = 'ARM A680/V4T',
            ['12 6'] = 'ARM V6',
            ['12 7'] = 'ARM V5TEJ',
            ['12 8'] = 'ARM XSCALE',
            ['12 9'] = 'ARM V7',
            ['13 0'] = 'MC88000 (all)',
            ['13 1'] = 'MC88100',
            ['13 2'] = 'MC88110',
            ['14 0'] = 'SPARC (all)',
            ['14 1'] = 'SUN 4/260',
            ['14 2'] = 'SUN 4/110',
            ['15 0'] = 'i860 (all)',
            ['15 1'] = 'i860 860',
            ['16 0'] = 'i860 little (all)',
            ['16 1'] = 'i860 little',
            ['17 0'] = 'RS6000 (all)',
            ['17 1'] = 'RS6000',
            ['18 0'] = 'PowerPC (all)',
            ['18 1'] = 'PowerPC 601',
            ['18 2'] = 'PowerPC 602',
            ['18 3'] = 'PowerPC 603',
            ['18 4'] = 'PowerPC 603e',
            ['18 5'] = 'PowerPC 603ev',
            ['18 6'] = 'PowerPC 604',
            ['18 7'] = 'PowerPC 604e',
            ['18 8'] = 'PowerPC 620',
            ['18 9'] = 'PowerPC 750',
            ['18 10'] = 'PowerPC 7400',
            ['18 11'] = 'PowerPC 7450',
            ['18 100'] = 'PowerPC 970',
            ['255 1'] = 'VEO 1',
            ['255 2'] = 'VEO 2',
        },
    },
    [5] = {
        Name = 'ObjectFileType',
        PrintHex = 1,
        -- ref https://svn.red-bean.com/pyobjc/branches/pyobjc-20x-branch/macholib/macholib/mach_o.py
        PrintConv = {
            [-1] = 'Static library', --PH (internal use only)
            [1] = 'Relocatable object',
            [2] = 'Demand paged executable',
            [3] = 'Fixed VM shared library',
            [4] = 'Core',
            [5] = 'Preloaded executable',
            [6] = 'Dynamically bound shared library',
            [7] = 'Dynamic link editor',
            [8] = 'Dynamically bound bundle',
            [9] = 'Shared library stub for static linking',
            -- (the following from Apple loader.h header file)
            [10] = 'Debug information',
            [11] = 'x86_64 kexts',
        },
    },
    [6] = {
        Name = 'ObjectFlags',
        PrintHex = 1,
        -- ref Apple loader.h header file
        PrintConv = { BITMASK = {
             [0] = 'No undefs',
             [1] = 'Incrementa link',
             [2] = 'Dyld link',
             [3] = 'Bind at load',
             [4] = 'Prebound',
             [5] = 'Split segs',
             [6] = 'Lazy init',
             [7] = 'Two level',
             [8] = 'Force flat',
             [9] = 'No multi defs',
             [10] = 'No fix prebinding',
             [11] = 'Prebindable',
             [12] = 'All mods bound',
             [13] = 'Subsections via symbols',
             [14] = 'Canonical',
             [15] = 'Weak defines',
             [16] = 'Binds to weak',
             [17] = 'Allow stack execution',
             [18] = 'Dead strippable dylib',
             [19] = 'Root safe',
             [20] = 'No reexported dylibs',
             [21] = 'Random address',
        }},
    },
}

-- Information extracted from PEF (Classic MacOS executable) file header
EXE.PEF = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = [[
        Information extracted from PEF (Classic MacOS) executable files and
        libraries.
    ]],
    FORMAT = 'int32u',
    [2] = {
        Name = 'CPUArchitecture',
        Format = 'undef[4]',
        PrintConv = {
            pwpc = 'PowerPC',
            m68k = '68000',
        },
    },
    [3] = 'PEFVersion',
    [4] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        -- timestamp is relative to Jan 1, 1904
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val - ((66 * 365 + 17) * 24 * 3600)) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    --5 => 'OldDefVersion',
    --6 => 'OldImpVersion',
    --7 => 'CurrentVersion',
}

-- Information extracted from ELF (Unix executable) file header
EXE.ELF = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = [[
        Information extracted from ELF (Unix) executable files and SO libraries.
    ]],
    [4] = {
        Name = 'CPUArchitecture',
        PrintConv = {
            [1] = '32 bit',
            [2] = '64 bit',
        },
    },
    [5] = {
        Name = 'CPUByteOrder',
        PrintConv = {
            [1] = 'Little endian',
            [2] = 'Big endian',
        },
    },
    [16] = {
        Name = 'ObjectFileType',
        Format = 'int16u',
        PrintConv = {
            [0] = 'None',
            [1] = 'Relocatable file',
            [2] = 'Executable file',
            [3] = 'Shared object file',
            [4] = 'Core file',
        },
    },
    [18] = {
        Name = 'CPUType',
        Format = 'int16u',
        -- ref /usr/include/linux/elf-em.h
        -- ref https://en.wikipedia.org/wiki/Executable_and_Linkable_Format
        PrintConv = {
            [0] = 'None',
            [1] = 'AT&T WE 32100',
            [2] = 'SPARC',
            [3] = 'i386',
            [4] = 'Motorola 68000',
            [5] = 'Motorola 88000',
            [6] = 'i486',
            [7] = 'i860',
            [8] = 'MIPS R3000',
            [9] = 'IBM System/370',
            [10] = 'MIPS R4000',
            [15] = 'HP PA-RISC',
            [18] = 'Sun v8plus',
            [19] = 'Intel 80960',
            [20] = 'PowerPC',
            [21] = 'PowerPC 64-bit',
            [22] = 'IBM S/390',
            [23] = 'Cell BE SPU',
            [36] = 'NEC V800',
            [37]= 'Fujitsu FR20',
            [38] = 'TRW RH-32',
            [39] = 'Motorola RCE',
            [40] = 'Arm (up to Armv7/AArch32)',
            [41] = 'Digital Alpha',
            [42] = 'SuperH',
            [43] = 'SPARC v9 64-bit',
            [44] = 'Siemens TriCore',
            [45] = 'Argonaut RISC Core',
            [46] = 'Renesas H8/300,300H,H8S',
            [47] = 'Hitachi H8/300H',
            [48] = 'Hitachi H8S',
            [49] = 'Hitachi H8/500',
            [50] = 'HP/Intel IA-64',
            [0x33] = 'Stanford MIPS-X',
            [0x34] = 'Motorola ColdFire',
            [0x35] = 'Motorola M68HC12',
            [0x36] = 'Fujitsu MMA Multimedia Accelerator',
            [0x37] = 'Siemens PCP',
            [0x38] = 'Sony nCPU embedded RISC processor',
            [0x39] = 'Denso NDR1 microprocessor',
            [0x3a] = 'Motorola Star*Core processor',
            [0x3b] = 'Toyota ME16 processor',
            [0x3c] = 'STMicroelectronics ST100 processor',
            [0x3d] = 'Advanced Logic Corp. TinyJ embedded processor family',
            [0x3e] = 'AMD x86-64',
            [0x3f] = 'Sony DSP Processor',
            [0x40] = 'Digital Equipment Corp. PDP-10',
            [0x41] = 'Digital Equipment Corp. PDP-11',
            [0x42] = 'Siemens FX66 microcontroller',
            [0x43] = 'STMicroelectronics ST9+ 8/16 bit microcontroller',
            [0x44] = 'STMicroelectronics ST7 8-bit microcontroller',
            [0x45] = 'Motorola MC68HC16 Microcontroller',
            [0x46] = 'Motorola MC68HC11 Microcontroller',
            [0x47] = 'Motorola MC68HC08 Microcontroller',
            [0x48] = 'Motorola MC68HC05 Microcontroller',
            [0x49] = 'Silicon Graphics SVx',
            [0x4a] = 'STMicroelectronics ST19 8-bit microcontroller',
            [0x4b] = 'Digital VAX',
            [0x4c] = 'Axis Communications 32-bit embedded processor',
            [0x4d] = 'Infineon Technologies 32-bit embedded processor',
            [0x4e] = 'Element 14 64-bit DSP Processor',
            [0x4f] = 'LSI Logic 16-bit DSP Processor',
            [0x57] = 'NEC v850',
            [0x58] = 'Renesas M32R',
            [0x8c] = 'TMS320C6000 Family',
            [0xaf] = 'MCST Elbrus e2k',
            [0xb7] = 'Arm 64-bits (Armv8/AArch64)',
            [0xdc] = 'Zilog Z80',
            [0xf3] = 'RISC-V',
            [0xf7] = 'Berkeley Packet Filter',
            [0x101] = 'WDC 65C816',
            [0x5441] = 'Fujitsu FR-V',
            [0x9026] = 'Alpha', -- (interim value)
            [0x9041] = 'm32r (old)',
            [0x9080] = 'v850 (old)',
            [0xa390] = 'S/390 (old)',
        },
    },
}

-- Information extracted from static library archives
-- (ref http://opensource.apple.com//source/xnu/xnu-1456.1.26/EXTERNAL_HEADERS/ar.h)
EXE.AR = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = [[
        Information extracted from static libraries.
    ]],
    --  0  string[16] ar_name
    [16] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        Format = 'string[12]',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- 28  string[6]  ar_uid
    -- 34  string[6]  ar_gid
    -- 40  string[8]  ar_mode
    -- 48  string[10] ar_size
    -- 58  string[2]  terminator "`\n"
}

-- Microsoft compiled help format (ref http://www.russotto.net/chm/chmformat.html)
EXE.CHM = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = 'Tags extracted from Microsoft Compiled HTML files.',
    FORMAT = 'int32u',
    [1] = { Name = 'CHMVersion' },
    -- 2 - total header length
    -- 3 - 1
    -- 4 - low bits of date/time value plus 42 (ref http://www.nongnu.org/chmspec/latest/ITSF.html)
    [5] = {
        Name = 'LanguageCode',
        SeparateTable = 1,
        ValueConv = function(_self, val) return sprintf("%.4X", val) end,
        PrintConv = languageCode,
    },
}

--------------------------------------------------------------------------------
-- Extract information from a CHM file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid CHM file
function EXE.ProcessCHM(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(56)

    if not (n == 56 and
        perl.isMatch(buff, [[(?s)^ITSF.{20}\x10\xfd\x01\x7c\xaa\x7b\xd0\x11\x9e\x0c\0\xa0\xc9\x22\xe6\xec]])) then return 0 end
    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.EXE.CHM')
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    et:ProcessDirectory({ DataPt = buff }, tagTablePtr)
    return 1
end

--------------------------------------------------------------------------------
-- Read Unicode string (null terminated) from resource
-- Inputs: 0) data string, 1) start offset, 2) data end, 3) optional ExifTool object ref
-- Returns: 0) Unicode string translated to UTF8, or current CharSet with ExifTool ref
--          1) end pos (rounded up to nearest 4 bytes)
--------------------------------------------------------------------------------
local function ReadUnicodeStr(dataPt, pos, endPos, et)
    if endPos > #dataPt then endPos = #dataPt end -- (be safe)
    local str = {}
    while pos + 2 <= endPos do
        local ch = substr(dataPt, pos, 2)
        pos = pos + 2
        if ch == '\0\0' then break end
        str[#str + 1] = ch
    end
    if (pos & 0x03) ~= 0 then pos = pos + 2 end
    local to = et and et:Options('Charset') or 'UTF8'
    return ExifTool.Decode(nil, table.concat(str), 'UTF16', 'II', to), pos
end

--------------------------------------------------------------------------------
-- Process Windows PE Version Resource
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref
-- Returns: true on success
--------------------------------------------------------------------------------
local function ProcessPEVersion(et, dirInfo)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local endPos = pos + dirInfo.DirLen
    local index, len, valLen, str, strEnd -- (upstream's $type is read but unused)

    -- get VS_VERSION_INFO
    index = 0
    while true do
        pos = (pos + 3) & ~0x03 -- align on a 4-byte boundary
        if pos + 6 > endPos then break end
        len = ExifTool.Get16u(dataPt, pos)
        if pos + len > endPos then return false end
        valLen = ExifTool.Get16u(dataPt, pos + 2)
        ExifTool.Get16u(dataPt, pos + 4) -- ($type; read but unused, like upstream)
        if len == 0 and valLen == 0 then return false end -- prevent possible infinite loop
        str, strEnd = ReadUnicodeStr(dataPt, pos + 6, pos + len)
        if strEnd + valLen > endPos then return false end
        if index == 0 and str ~= 'VS_VERSION_INFO' then
            et:Warn('Invalid Version Info block')
            return false
        end
        if str == 'VS_VERSION_INFO' then
            -- parse the fixed version info
            dirInfo.DirStart = strEnd
            dirInfo.DirLen = valLen
            local subTablePtr = et:GetTagTable('lexiftool.EXE.PEVersion')
            et:ProcessDirectory(dirInfo, subTablePtr)
            pos = strEnd + valLen
        elseif str == 'StringFileInfo' and valLen == 0 then
            pos = pos + len
            local pt = strEnd
            -- parse string table
            local tagTablePtr = et:GetTagTable('lexiftool.EXE.PEString')
            index = 0
            while pt + 6 < pos do
                len = ExifTool.Get16u(dataPt, pt)
                if len == 0 then et:Warn('Invalid PEString entry') break end
                valLen = ExifTool.Get16u(dataPt, pt + 2)
                -- $type = Get16u($dataPt, $pt + 4);
                local entryEnd = pt + len
                if entryEnd > endPos then return false end
                -- get tag ID (converted to UTF8)
                str, pt = ReadUnicodeStr(dataPt, pt + 6, entryEnd)
                if index == 0 then
                    -- separate the language code and character set
                    -- (not sure what the CharacterSet tag is for, but the string
                    -- values stored here are UCS-2 in all my files even if the
                    -- CharacterSet is otherwise)
                    local char_
                    if #str > 4 then
                        char_ = substr(str, 4)
                        str = substr(str, 0, 4)
                    end
                    et:HandleTag(tagTablePtr, 'LanguageCode', uc(str))
                    if char_ then et:HandleTag(tagTablePtr, 'CharacterSet', uc(char_)) end
                else
                    local tag = str
                    local value
                    -- get tag value (converted to current Charset)
                    if valLen ~= 0 then
                        -- (only the string is kept here; upstream also takes
                        --  the returned position, which the entry-end reset
                        --  below overwrites)
                        value = (ReadUnicodeStr(dataPt, pt, entryEnd, et))
                    else
                        value = ''
                    end
                    et:HandleTag(tagTablePtr, tag, value, { MakeTagInfo = 1 })
                    -- step to next entry (padded to an even word)
                    pt = (entryEnd + 3) & ~0x03
                end
                -- (the pt reset above belongs inside the else branch: for the
                --  index-0 language/charset entry upstream `next`es past it,
                --  keeping the ReadUnicodeStr position so the loop descends
                --  into the string table's own children)
                index = index + 1
            end
        else
            pos = pos + len + valLen
            -- ignore other information (for now)
        end
        index = index + 1
    end
    return true
end

--------------------------------------------------------------------------------
-- Get actual file offset given a virtual address in a PE file
-- Inputs: 0) virtual address, 1) section list ref
-- Returns: absolute file offset or nil on error
--------------------------------------------------------------------------------
local function GetFileOffset(addr, sections)
    for _, section in ipairs(sections) do
        if addr >= section.VirtualAddress and
           addr <  section.VirtualAddress + section.Size then
            return addr + section.Base - section.VirtualAddress
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Process Windows PE Resources
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref
-- Returns: true on success
--------------------------------------------------------------------------------
local function ProcessPEResources(et, dirInfo)
    local raf = dirInfo.RAF
    local base = dirInfo.Base
    local dirStart = dirInfo.DirStart + base
    local level = dirInfo.Level or 0
    local verbose = et:Options('Verbose')

    if level > 10 then return false end -- protect against deep recursion
    -- read the resource header
    if not raf:Seek(dirStart, 0) then return false end
    local n1, hdr = raf:Read(16)
    if n1 ~= 16 then return false end
    local nameEntries = ExifTool.Get16u(hdr, 12)
    local idEntries = ExifTool.Get16u(hdr, 14)
    local count = nameEntries + idEntries
    if count > 10000 then return false end
    local n2, entries = raf:Read(count * 8)
    if n2 ~= count * 8 then return false end
    -- loop through all resource entries
    for item = 0, count - 1 do
        local pos = item * 8
        local name = ExifTool.Get32u(entries, pos)
        local entryPos = ExifTool.Get32u(entries, pos + 4)
        if level == 0 then
            -- set resource type if this is the 0th level directory
            local resType = resourceType[name] or sprintf('Unknown (0x%x)', name)
            -- ignore everything but the Version resource unless verbose
            if perl.truthy(verbose) then
                et:VPrint(0, resType .. ' resource:\n')
            else
                if resType ~= 'Version' then goto continue end
            end
            dirInfo.ResType = resType
        end
        if (entryPos & 0x80000000) ~= 0 then -- is this a directory?
            -- descend into next directory level
            dirInfo.DirStart = entryPos & 0x7fffffff
            dirInfo.Level = level + 1
            local okRes = ProcessPEResources(et, dirInfo)
            dirInfo.Level = level
            if not okRes then return false end
        elseif dirInfo.ResType == 'Version' and level == 2 and
            not dirInfo.GotVersion then -- (only process first Version resource)
            -- get position of this resource in the file
            local n3, buf2
            if raf:Seek(entryPos + base, 0) then n3, buf2 = raf:Read(16) end
            if not n3 or n3 ~= 16 then return false end
            local addr = ExifTool.Get32u(buf2, 0)
            local len = ExifTool.Get32u(buf2, 4)
            -- determine which section this is in so we can convert the virtual address
            local fileOff = GetFileOffset(addr, dirInfo.Sections)
            if not fileOff then return false end
            local n4, data
            if raf:Seek(fileOff, 0) then n4, data = raf:Read(len) end
            if not n4 or n4 ~= len then return false end
            local okVer = ProcessPEVersion(et, {
                DataPt   = data,
                DataLen  = len,
                DirStart = 0,
                DirLen   = len,
            })
            if not okVer then et:Warn('Possibly corrupt Version resource') end
            dirInfo.GotVersion = true -- set flag so we don't do this again
        end
        ::continue::
    end
    return true
end

--------------------------------------------------------------------------------
-- Process Windows PE file data dictionary
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref
-- Returns: true on success or if the PE resources didn't exist, or false on error
--          processing the PE resources
--------------------------------------------------------------------------------
local function ProcessPEDict(et, dirInfo)
    local raf = dirInfo.RAF
    local dataPt = dirInfo.DataPt
    local dirLen = #dataPt
    local sections = {}
    local dictInfo = {}
    local rsrcFound

    -- loop through all sections
    local pos = 0
    while pos + 40 <= dirLen do
        local name = substr(dataPt, pos, 8)
        local va = ExifTool.Get32u(dataPt, pos + 12)
        local size = ExifTool.Get32u(dataPt, pos + 16)
        local offset = ExifTool.Get32u(dataPt, pos + 20)
        -- remember the section offsets for the VirtualAddress lookup later
        sections[#sections + 1] = { Base = offset, Size = size, VirtualAddress = va }
        -- save details of the first resource section (or .text if .rsrc not found, ref forum11465)
        if (name == '.rsrc\0\0\0' and not rsrcFound and (function() rsrcFound = true return true end)()) or
           (name == '.text\0\0\0' and next(dictInfo) == nil) then
            dictInfo = {
                RAF      = raf,
                Base     = offset,
                DirStart = 0, -- (relative to Base)
                DirLen   = size,
                Sections = sections,
            }
        end
        pos = pos + 40
    end
    dirInfo.Sections = sections -- return section information
    -- process the first resource section
    if next(dictInfo) then
        if not ProcessPEResources(et, dictInfo) then return false end
    end
    return true
end

--------------------------------------------------------------------------------
-- Override file type if necessary for Mach object files and libraries
-- Inputs: 0) ExifTool ref, 1) ObjectFileType number, 2) flag for fat binary
--------------------------------------------------------------------------------
local machOverride = {
    [1] = { 'object file', 'O' },
    [6] = { 'dynamic link library', 'DYLIB' },
    [8] = { 'dynamic bound bundle', 'DYLIB' },
    [9] = { 'dynamic link library stub', 'DYLIB' },
}
local function MachOverride(et, objType, fat)
    local override = machOverride[objType]
    if override then
        local desc = 'Mach-O ' .. (fat and 'fat ' or '') .. override[1]
        et:OverrideFileType(desc, nil, override[2])
    end
end

--------------------------------------------------------------------------------
-- Extract tags from Mach header
-- Inputs: 0) ExifTool ref, 1) data string, 2) flag to extract object type
-- Returns: true if Mach header was found
-- Mach type based on magic number
-- [bit depth, byte order starting with "Little" or "Big"]
--------------------------------------------------------------------------------
local machType = {
    ['\xfe\xed\xfa\xce'] = { '32 bit', 'Big endian' },
    ['\xce\xfa\xed\xfe'] = { '32 bit', 'Little endian' },
    ['\xfe\xed\xfa\xcf'] = { '64 bit', 'Big endian' },
    ['\xcf\xfa\xed\xfe'] = { '64 bit', 'Little endian' },
}
local function ExtractMachTags(et, dataPt, doObj)
    -- get information about mach header based on the magic number (first 4 bytes)
    local info = machType[substr(dataPt, 0, 4)]
    if info then
        -- Mach header structure:
        --  0 int32u magic
        --  4 int32u cputype
        --  8 int32u cpusubtype
        -- 12 int32u filetype
        -- 16 int32u ncmds
        -- 20 int32u sizeofcmds
        -- 24 int32u flags
        local tagTablePtr = et:GetTagTable('lexiftool.EXE.MachO')
        ExifTool.SetByteOrder(info[2])
        -- (upstream Get32s: signed values so the CPUType 64-bit flag bit 31
        --  doesn't wrap negative; Get32s is the port's signed counterpart)
        local cpuType = ExifTool.Get32s(dataPt, 4)
        local subType = ExifTool.Get32s(dataPt, 8)
        et:HandleTag(tagTablePtr, 0, info[1])
        et:HandleTag(tagTablePtr, 1, info[2])
        et:HandleTag(tagTablePtr, 3, cpuType)
        et:HandleTag(tagTablePtr, 4, cpuType .. ' ' .. subType)
        if doObj then
            local objType = ExifTool.Get32u(dataPt, 12)
            local flags = ExifTool.Get32u(dataPt, 24)
            et:HandleTag(tagTablePtr, 5, objType)
            et:HandleTag(tagTablePtr, 6, flags)
            -- override file type if this is an object file or library
            MachOverride(et, objType)
        else -- otherwise this was a static library
            et:OverrideFileType('Mach-O static library', nil, 'A')
        end
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Extract information from an EXE file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid EXE file
--------------------------------------------------------------------------------
function EXE.ProcessEXE(et, dirInfo)
    local raf = dirInfo.RAF

    local size, buff = raf:Read(0x40)
    if not size or size == 0 then return 0 end
    local fast3 = perl.truthy(et.OPTIONS.FastScan) and perl.num(et.OPTIONS.FastScan) == 3
--
-- DOS and Windows EXE
--
    if buff:sub(1, 2) == 'MZ' and size == 0x40 then
        -- DOS/Windows executable
        -- validate DOS header
        -- (ref http://www.delphidabbler.com/articles?article=8&part=2)
        --   0 int16u     magic    - Magic number ("MZ")
        --   ...
        --  60 int32u;    lfanew   - File address of new exe header
        ExifTool.SetByteOrder('II')
        local cblp, cp, _, lfanew = perl.unpack('x2v2x18vx34V', buff) -- ($lfarlc unused)
        local fileSize = (cp - (cblp ~= 0 and 1 or 0)) * 512 + cblp
        -- (changed to warning in upstream 12.08 to accommodate observed 64-bit files)
        if fileSize < 0x40 then et:Warn('Invalid file size in DOS header') end
        -- read the Windows NE, PE or LE (virtual device driver) header
        local sig
        if raf:Seek(lfanew, 0) then
            local n2, buf2 = raf:Read(0x40)
            if n2 and n2 >= 4 then
                buff = buf2
                size = n2
                sig = buff:sub(1, 2)
            end
        end
        if sig == 'PE' then
            -- PE header comes at byte 4 in buff:
            --   4 int16u Machine
            --   6 int16u NumberOfSections
            --   8 int32u TimeDateStamp
            --  12 int32u PointerToSymbolTable
            --  16 int32u NumberOfSymbols
            --  20 int16u SizeOfOptionalHeader
            --  22 int16u Characteristics
            if size >= 24 then -- PE header is 24 bytes (plus optional header)
                local mach = ExifTool.Get16u(buff, 4) -- MachineType
                local flags = ExifTool.Get16u(buff, 22) -- ImageFileCharacteristics
                local machine = ''
                local mainTable = et:GetTagTable('lexiftool.EXE.Main')
                local mc = mainTable[0] and mainTable[0].PrintConv
                if mc then machine = mc[mach] or '' end
                local winType = machine:find('64', 1, true) and 'Win64' or 'Win32'
                local ext = (flags & 0x2000) ~= 0 and 'DLL' or 'EXE'
                et:SetFileType(winType .. ' ' .. ext, nil, ext)
                if fast3 then return 1 end
                -- read the rest of the optional header if necessary
                local optSize = ExifTool.Get16u(buff, 20)
                local more = optSize + 24 - size
                local magic = 0
                if more > 0 then
                    local n3, tail = raf:Read(more)
                    if n3 == more then
                        buff = buff .. tail
                        size = size + more
                        magic = ExifTool.Get16u(buff, 24)
                        -- verify PE magic number
                        if not (magic == 0x107 or magic == 0x10b or magic == 0x20b) then
                            et:Warn('Unknown PE magic number')
                            return 1
                        end
                        -- --> 64-bit if $magic is 0x20b ????
                    else
                        et:Warn('Error reading optional header')
                    end
                end
                -- process PE COFF file header
                local peDirInfo = {
                    DataPt   = buff,
                    DataPos  = raf:Tell() - size,
                    DataLen  = size,
                    DirStart = 4,
                    DirLen   = size - 4,
                }
                et:ProcessDirectory(peDirInfo, mainTable)
                local num = ExifTool.Get16u(buff, 6) -- NumberOfSections
                -- image data directory entry for debug info is index 6,
                -- so offset is 4 bytes + 20 byte header + 96 bytes into PE32 optional
                -- header (or 112 bytes for PE32+) + 6 * 8 bytes into data directory
                local dirEntry = (magic == 0x20b) and 184 or 168
                local addr, len -- virtual address/size of debug section
                if #buff >= dirEntry + 8 then
                    addr = ExifTool.Get32u(buff, dirEntry)
                    len = ExifTool.Get32u(buff, dirEntry + 4)
                end
                -- process data dictionary
                -- (ref https://www.debuginfo.com/articles/debuginfomatch.html)
                local n4, sections = raf:Read(40 * num)
                if n4 ~= 40 * num then return 1 end
                local dictDirInfo = { RAF = raf, DataPt = sections }
                local dictOk = ProcessPEDict(et, dictDirInfo)
                if not dictOk then et:Warn('Error processing PE resources') end
                -- dive into debug section to extract pdb info if available
                if not (addr and len < 2800 and dictDirInfo.Sections and
                    (magic == 0x10b or magic == 0x20b)) then return 1 end
                -- get file offset for debug section
                local off = GetFileOffset(addr, dictDirInfo.Sections)
                if not (off and raf:Seek(off, 0)) then return 1 end
                local n5, debug = raf:Read(len)
                if not n5 or n5 ~= len then return 1 end
                local pos = 0
                while pos + 28 <= n5 do
                    local dbtype = ExifTool.Get32u(debug, pos + 12)
                    if dbtype == 2 or dbtype == 4 then -- (CodeView debug data)
                        local n6, of = ExifTool.Get32u(debug, pos + 16), ExifTool.Get32u(debug, pos + 24)
                        if n6 < 10000 and raf:Seek(of, 0) then
                            local n7, buf2 = raf:Read(n6)
                            if n7 == n6 then
                                if dbtype == 2 then -- CodeView debug info
                                    -- (upstream regex verbatim via the
                                    --  facade; Lua has no alternation)
                                    local kind = perl.matches(buf2, '^(RSDS|NB10)')
                                    if kind then
                                        local tagTablePtr = et:GetTagTable('lexiftool.EXE.Debug' .. kind)
                                        -- use timestamp from debug dir
                                        buf2 = substr(buff, pos + 4, 4) .. substr(buf2, 4)
                                        et:ProcessDirectory({ DataPt = buf2, DataPos = of }, tagTablePtr)
                                    end
                                else -- misc debug info
                                    if n6 > 12 then
                                        local exeFile = substr(buf2, 12)
                                        if ExifTool.Get32u(buf2, 8) ~= 0 then
                                            exeFile = et:Decode(exeFile, 'UTF16')
                                        end
                                        exeFile = exeFile:gsub('\0.*', '', 1) -- truncate at null
                                        local tagTablePtr = et:GetTagTable('lexiftool.EXE.Misc')
                                        et:HandleTag(tagTablePtr, 12, exeFile, { DataPt = buf2, DataPos = of })
                                    end
                                end
                            end
                        end
                    end
                    pos = pos + 28
                end
                return 1
            end
        elseif sig == 'NE' then
            if size >= 0x40 then -- NE header is 64 bytes (ref 2)
                -- check for DLL
                local appFlags = ExifTool.Get16u(buff, 0x0c)
                local ext = (appFlags & 0x80) ~= 0 and 'DLL' or 'EXE'
                et:SetFileType('Win16 ' .. ext, nil, ext)
                -- offset 0x02 is 2 bytes with linker version and revision numbers
                -- offset 0x36 is executable type (2 = Windows)
            end
        elseif sig == 'LE' then
            et:SetFileType('Virtual Device Driver', nil, '386')
        else
            et:SetFileType('DOS EXE', nil, 'exe')
        end
        return 1
--
-- Mach-O (Mac OS X)
--
    elseif perl.matches(buff,
        '^((\\xca\\xfe\\xba\\xbe|\\xfe\\xed\\xfa(\\xce|\\xcf)|(\\xce|\\xcf)\\xfa\\xed\\xfe))') and size > 12 then
        -- Mach-O executable
        -- (ref http://developer.apple.com/documentation/DeveloperTools/Conceptual/MachORuntime/Reference/reference.html)
        local tagTablePtr = et:GetTagTable('lexiftool.EXE.MachO')
        if buff:sub(1, 4) == '\202\254\186\190' then
            ExifTool.SetByteOrder('MM')
            local ver = ExifTool.Get32u(buff, 4)
            -- Java bytecode .class files have the same magic number, so we need to look deeper
            -- (ref https://github.com/file/file/blob/master/magic/Magdir/cafebabe#L6-L15)
            if ver > 30 then
                -- this is Java bytecode
                et:SetFileType('Java bytecode', 'application/java-byte-code', 'class')
                return 1
            end
            et:SetFileType('Mach-O fat binary executable', nil, '')
            if fast3 then return 1 end
            local count = ExifTool.Get32u(buff, 4) -- get architecture count
            local more = count * 20 - (size - 8)
            if more > 0 then
                local n2, tail = raf:Read(more)
                if n2 ~= more then
                    et:Warn('Error reading fat-arch headers')
                    return 1
                end
                buff = buff .. tail
                -- (upstream tracks $size here, but it isn't read again)
            end
            et:HandleTag(tagTablePtr, 2, count)
            for i = 0, count - 1 do
                local cpuType = ExifTool.Get32s(buff, 8 + i * 20)
                local subType = ExifTool.Get32s(buff, 12 + i * 20)
                et:HandleTag(tagTablePtr, 3, cpuType)
                et:HandleTag(tagTablePtr, 4, cpuType .. ' ' .. subType)
            end
            -- load first Mach-O header to get the object file type
            local offset = ExifTool.Get32u(buff, 16)
            if raf:Seek(offset, 0) then
                local n2, buf2 = raf:Read(16)
                if n2 == 16 then
                    if perl.matches(buf2, '^((\\xfe\\xed\\xfa(\\xce|\\xcf)|(\\xce|\\xcf)\\xfa\\xed\\xfe))') then
                        ExifTool.SetByteOrder(buf2:match('^\254\237') and 'MM' or 'II')
                        local objType = ExifTool.Get32u(buf2, 12)
                        et:HandleTag(tagTablePtr, 5, objType)
                        -- override file type if this is a library or object file
                        MachOverride(et, objType, 'fat')
                    elseif buf2:match('^!<arch>\n') then
                        -- .a libraries use this magic number
                        et:HandleTag(tagTablePtr, 5, -1)
                        -- override file type since this is a library
                        et:OverrideFileType('Mach-O fat static library', nil, 'A')
                    else
                        et:Warn('Unrecognized object file type')
                    end
                else
                    et:Warn('Error reading file')
                end
            else
                et:Warn('Error reading file')
            end
        elseif size >= 16 then
            et:SetFileType('Mach-O executable', nil, '')
            if fast3 then return 1 end
            ExtractMachTags(et, buff, 1)
        end
        return 1
--
-- PEF (classic MacOS)
--
    elseif perl.isMatch(buff, '^Joy!peff') and size > 12 then
        -- ref http://developer.apple.com/documentation/mac/pdf/MacOS_RT_Architectures.pdf
        et:SetFileType('Classic MacOS executable', nil, '')
        if fast3 then return 1 end
        ExifTool.SetByteOrder('MM')
        local tagTablePtr = et:GetTagTable('lexiftool.EXE.PEF')
        et:ProcessDirectory({
            DataPt = buff,
            DataPos = 0,
            DataLen = size,
            DirStart = 0,
            DirLen = size,
        }, tagTablePtr)
        return 1
--
-- ELF (Unix)
--
    elseif buff:match('^\127ELF') and size >= 16 then
        et:SetFileType('ELF executable', nil, '')
        if fast3 then return 1 end
        ExifTool.SetByteOrder(buff:byte(6) == 1 and 'II' or 'MM')
        local tagTablePtr = et:GetTagTable('lexiftool.EXE.ELF')
        et:ProcessDirectory({
            DataPt  = buff,
            DataPos = 0,
            DataLen = size,
            DirLen  = size,
        }, tagTablePtr)
        -- override file type if this is a library or object file
        local objType = et.VALUE.ObjectFileType or 0
        local override = ({
            [1] = { 'ELF object file', 'O' },
            [3] = { 'ELF shared library', 'SO' },
        })[objType]
        if override then et:OverrideFileType(override[1], nil, override[2]) end
        return 1
--
-- .a libraries
--
    elseif buff:match('^!<arch>\n') then
        et:SetFileType('Static library', nil, 'A')
        if fast3 then return 1 end
        local pos = 8 -- current file position
        local max = 10 -- maximum number of archive files to check
        local arProcessed = false
        -- read into list of ar structures (each 60 bytes long):
        while max > 0 do
            max = max - 1
            -- seek to start of the ar structure and read it
            local n2, ar = nil, nil
            if raf:Seek(pos, 0) then n2, ar = raf:Read(60) end
            if not n2 or n2 ~= 60 then break end
            if substr(ar, 58, 2) ~= '`\n' then et:Warn('Invalid archive header') break end
            if not arProcessed then
                -- extract some information from first file in archive
                local tagTablePtr = et:GetTagTable('lexiftool.EXE.AR')
                et:ProcessDirectory({ DataPt = ar, DataPos = pos }, tagTablePtr)
                arProcessed = true
            end
            local name = substr(ar, 0, 16)
            local extLen = name:match('^#1/(%d+) *$') -- check for extended archive (BSD variant)
            if extLen then
                local len = tonumber(extLen)
                if len > 256 then et:Warn('Invalid extended archive name length') break end
                -- (we read the name here just to move the file pointer)
                local nn = select(1, raf:Read(len))
                if nn ~= len then et:Warn('Error reading archive name') break end
            end
            local arSize = substr(ar, 48, 10)
            local sz = arSize:match('^(%d+)') -- make sure archive size is a number
            if not sz then break end
            local n3, mh = raf:Read(28)
            if n3 ~= 28 then break end -- read (possible) Mach header
            if ExtractMachTags(et, mh) then break end -- try to extract tags
            pos = pos + 60 + tonumber(sz) -- step to next entry
            if (pos & 0x01) ~= 0 then pos = pos + 1 end -- padded to an even byte
        end
        return 1
--
-- various scripts (perl, sh, etc...)
--
    elseif buff:match('^#![ \t\n\r\f\v]*/[^ \t\n\r\f\v]*bin/([A-Za-z0-9]+)') then
        local prog = buff:match('^#![ \t\n\r\f\v]*/[^ \t\n\r\f\v]*bin/([A-Za-z0-9]+)')
        if prog == 'env' then
            -- upstream: `$buff =~ /\b(perl|python|ruby|php)\b/` (PCRE2 via
            -- the facade -- Lua patterns have no alternation)
            prog = perl.matches(buff, '\\b(perl|python|ruby|php)\\b') or prog
        end
        local mime = 'text/x-' .. prog
        local ext = ({ perl = 'pl', python = 'py', ruby = 'rb', php = 'php' })[prog]
        -- use '.sh' for extension of all shell scripts
        if not ext then ext = prog:match('sh$') and 'sh' or '' end
        et:SetFileType(prog .. ' script', mime, ext)
        return 1
    end
    return 0
end

return EXE
