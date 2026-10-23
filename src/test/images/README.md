# Additional test images

Additions to the vendored test images (`vendor/exiftool/t/images/`) for code
paths that have no representative there. The vendored tree is never
modified; this directory is a second source of test images.

**These files are fixtures.** They were created once and stay constant --
there is no generator and no build step. Changing one changes the test
scenario, and the expected values in the corresponding test must follow.

Name prefix `lex_`: tools that key on the base name must never see a
collision with an upstream image name.

---

## `lex_PhotoshopLayers.psd` (466 bytes)

Covers `Photoshop.ProcessLayersAndMask` / `ProcessLayers` including the
"additional layer info" blocks. `vendor/exiftool/t/images/Photoshop.psd` has
`LayerCount 0` and so never reaches this path.

Two layers; the first has no `lsct` block, the second has one -- so
upstream's padding of the tag lists, which keeps every layer at its index,
runs as well.

Expected (vendored Perl exiftool, `-a -u -G1 -Photoshop:all`):

    [Photoshop] Layer Count         : 2
    [Photoshop] Layer Rectangles    : 0 0 8 8, 0 0 8 8
    [Photoshop] Layer Blend Modes   : Normal, Normal
    [Photoshop] Layer Opacities     : 100%, 100%
    [Photoshop] Layer Visible       : Yes, Yes
    [Photoshop] Layer Names         : Ebene 1, Hintergrund
    [Photoshop] Layer Unicode Names : Ebene 1, Hintergrund
    [Photoshop] Layer IDs           : 42, 43
    [Photoshop] Layer Sections      : Layer, Folder (open)

Checked by `src/test/test_photoshop_layers.lua` (unit test; it also asks the
vendored original directly when perl is available).

### Layout

All numbers big-endian, as in the PSD format.

    8BPS 0001 000000000000  signature, version 1, 6 reserved bytes
    0003                    channels
    00000008 00000008       height, width
    0008 0003               bit depth 8, colour mode RGB
    00000000                Colour Mode Data: length 0
    00000000                Image Resources: length 0
    <len> ...               Layer and Mask Info
    0000 <8*8*3 zero bytes> Image Data: compression 0 (raw)

Layer and Mask Info:

    <len>                   length of the rest
      <len>                 length of the Layer Info
        0002                layer count
        <layer record 1>
        <layer record 2>
      00000000              Global Layer Mask Info: length 0

Layer record:

    00000000 00000000 00000008 00000008   rectangle: top left bottom right
    0000                                  channel count 0 (so no channel info)
    8BIM norm                             blend mode signature + key
    FF 00 00 00                           opacity 255, clipping, flags, filler
    <len> <Extra Data>                    length of the Extra Data

Extra Data:

    00000000                Layer Mask Data: length 0
    00000000                Blending Ranges: length 0
    <Pascal string>         layer name, padded to a multiple of 4
    <Additional Layer Info> any number of blocks

Additional Layer Info block:

    8BIM <4-byte tag> <len> <data, padded to a multiple of 4>

Contents:

| Layer | Name          | Blocks                                             |
|-------|---------------|----------------------------------------------------|
| 1     | `Ebene 1`     | `luni` = "Ebene 1", `lyid` = 42                    |
| 2     | `Hintergrund` | `luni` = "Hintergrund", `lyid` = 43, `lsct` = 1    |

`luni` payload: character count (4 bytes) followed by the text in UTF-16BE.

---

## `lex_Flash_CWS.swf` (292 bytes)

Covers the zlib branch of `Flash.ReadCompressed` (compressed `CWS` files).
`vendor/exiftool/t/images/Flash.swf` is an uncompressed `FWS` file and so
never inflates.

Made from `vendor/exiftool/t/images/Flash.swf`: the same SWF, stored as a
compressed `CWS` file. Its content -- header Rect, frame rate/count and
the XMP Metadata tag -- is that of `Flash.swf`.

Expected (vendored Perl exiftool, `-a -u -G1 -Flash:all -XMP:all`):

    [Flash]         Flash Version                   : 6
    [Flash]         Compressed                      : True
    [Flash]         Image Width                     : 50
    [Flash]         Image Height                    : 50
    [Flash]         Frame Rate                      : 12
    [Flash]         Frame Count                     : 1
    [Flash]         Duration                        : 0.08 s
    [XMP-x]         XMP Toolkit                     : Image::ExifTool 7.50
    [XMP-pdf]       Author                          : Phil

### Layout

    CWS 06                  signature (compressed), version 6
    80010000                file length 384 (little-endian), the length of
                            the uncompressed file
    <zlib stream>           bytes 8..383 of Flash.swf, zlib-compressed
                            (RFC 1950, with header, level 9)

`ReadCompressed` first inflates the 64 bytes it reads, then 64 more bytes
of compressed data until the uncompressed buffer is long enough; the XMP
record (359 bytes) needs a second, larger read on the same inflate stream.

---

## `lex_DICOM_Deflated.dcm` (1115 bytes)

Covers the deflated transfer syntax (`1.2.840.10008.1.2.1.99`, Deflated
Explicit VR Little Endian) in `DICOM.ProcessDICOM`: the data set after the
group 2 meta information is raw-inflated and read from memory.
`vendor/exiftool/t/images/DICOM.dcm` uses Explicit VR Little Endian
(`1.2.840.10008.1.2.1`).

Made from `vendor/exiftool/t/images/DICOM.dcm`; the data set is the same,
so all elements after group 2 are those of `DICOM.dcm`.

Expected (vendored Perl exiftool, `-a -u -G1`, excerpt):

    [DICOM]         Transfer Syntax UID             : Deflated Explicit VR Little Endian
    [DICOM]         Modality                        : MR
    [DICOM]         Manufacturer                    : GE Medical Systems
    [DICOM]         Patient ID                      : 123456
    [DICOM]         Pixel Data                      : (Binary data 53 bytes, use -b option to extract)

### Layout

    <128 bytes>             preamble (as in DICOM.dcm)
    DICM                    signature
    <group 2>               file meta information, explicit VR little
                            endian, as in DICOM.dcm except:
                              (0002,0000) UL FileMetaInfoGroupLength = 182
                                          (was 180)
                              (0002,0010) UI TransferSyntaxUID, 22 bytes =
                                          "1.2.840.10008.1.2.1.99" (was the
                                          20 bytes "1.2.840.10008.1.2.1\0")
    <raw deflate stream>    from offset 0x146: the data set of DICOM.dcm
                            (its bytes from 0x144 to the end), deflated
                            without zlib header (RFC 1951, level 9)

---

## `lex_PLIST_Compressed.aae` (781 bytes)

Covers the `CompressedPLIST` branch of `PLIST.FoundTag`: an `adjustmentData`
value that is not a plain `bplist00` stream is raw-inflated before its
binary PLIST is read. `vendor/exiftool/t/images/PLIST.aae` carries the
binary PLIST uncompressed.

Made from `vendor/exiftool/t/images/PLIST.aae`; only the `<data>` of
`adjustmentData` differs.

Expected (vendored Perl exiftool, `-a -u -G1 -PLIST:all`):

    [PLIST]         Slow Motion Regions Start Time Flags: Valid
    [PLIST]         Slow Motion Regions Start Time Value: 6296250000
    [PLIST]         Slow Motion Regions Start Time Scale: 1000000000
    [PLIST]         Slow Motion Regions Start Time Epoch: 0
    [PLIST]         Slow Motion Regions Duration Flags: Valid
    [PLIST]         Slow Motion Regions Duration Value: 29382500000
    [PLIST]         Slow Motion Regions Duration Time Scale: 1000000000
    [PLIST]         Slow Motion Regions Duration Epoch: 0
    [PLIST]         Slow Motion Regions             : 
    [PLIST]         Slow Motion Rate                : 0.125

### Layout

An XML property list, as `PLIST.aae`. The `adjustmentData` value:

    <data>                  Base64 (68 characters per line, each line
                            indented by a tab) of:
      <raw deflate stream>  the 208-byte binary PLIST of PLIST.aae
                            ("bplist00..."), deflated without zlib header
                            (RFC 1951, level 9)

---

## `lex_XMP_InvalidPrefix.xmp` (349 bytes)

Covers the namespace prefix validation in `XMP.FoundXMP`: a prefix that is
no valid XML name start (`1x`, declared with an unknown URI) is warned
about and renamed for use as a group name (`ns_1x`); the second property in
the same namespace finds the renamed prefix in `%stdXlatNS` and warns no
more.

Written by hand: an XMP packet with one `rdf:Description` declaring
`xmlns:1x='http://example.com/ns/1x/'` and holding `<1x:Label>first` and
`<1x:Note>second`.

Expected (vendored Perl exiftool, `-a -u -G1 -XMP:all -Warning`):

    [XMP-ns_1x]     Label                           : first
    [XMP-ns_1x]     Note                            : second
    [ExifTool]      Warning                         : Invalid XMP namespace prefix '1x'

---

## `lex_XMP_Base64.xmp` (402 bytes)

Covers the base64 branch of `XMP.FoundXMP`: a property with
`rdf:datatype='http://www.w3.org/2001/XMLSchema#base64Binary'` is decoded
(the decoded text is short and free of control characters, so it is kept
as a plain value).

Written by hand: an XMP packet with `<dc:source rdf:datatype=...>` holding
`SGVsbG8gV29ybGQ=`. The decoded text must stay free of `x`, `0` and `c` as
well: upstream's character class `[\0-\x08\x0b\0x0c\x0e-\x1f]` also matches
those three, and a value that matches stays a reference, which prints as
`SCALAR(0x...)` -- an address, different on every run.

Expected (vendored Perl exiftool, `-a -u -G1 -XMP:all -Warning`):

    [XMP-dc]        Source                          : Hello World

---

## `lex_XMP_DoubleUTF8.xmp` (350 bytes)

Covers the double-encoded UTF-8 branch of `XMP.ProcessXMP` for an XMP file:
a UTF-8 byte order mark directly before `<?xpacket begin=`, and text whose
UTF-8 bytes were encoded as UTF-8 once more. `Charset.Decompose` and
`pack('C*')` undo the second layer without a wrap warning, so the decoded
packet is used.

Written by hand: the UTF-8 XMP packet with `<dc:creator>René Müller`,
each byte re-encoded as one UTF-8 character (`é` = `c3 a9` becomes
`c3 83 c2 a9`), preceded by `ef bb bf`.

Expected (vendored Perl exiftool, `-a -u -G1 -XMP:all -Warning`):

    [XMP-dc]        Creator                         : René Müller
    [ExifTool]      Warning                         : XMP is double UTF-encoded

---

## `lex_XMP_DoubleUTF16.xmp` (682 bytes)

The same for the UTF-16 branch (`unpack('n*')`): byte order mark `fe ff`,
then each byte of the UTF-8 packet of `lex_XMP_DoubleUTF8.xmp` as one
big-endian 16-bit unit.

Expected (vendored Perl exiftool, `-a -u -G1 -XMP:all -Warning`):

    [XMP-dc]        Creator                         : René Müller
    [ExifTool]      Warning                         : XMP is double UTF-encoded

---

## `lex_XMP_SuperfluousBOM.jpg` (623 bytes)

Covers the leading-BOM check of `XMP.ProcessXMP` for embedded XMP (the
`DataPt` branch) and the other outcome of the double-encoding test: the
packet holds a character above U+00FF (`€`), so `pack('C*')` warns
("Character in 'C' format wrapped") and the BOM is taken as superfluous --
the packet is read with the BOM removed.

Made from `vendor/exiftool/t/images/Writer.jpg`: an APP1 XMP segment
(`http://ns.adobe.com/xap/1.0/\0`, then `ef bb bf` and a UTF-8 packet with
`<dc:rights>© 2026 €`) inserted after SOI.

Expected (vendored Perl exiftool, `-a -u -G1 -XMP:all -Warning`):

    [XMP-dc]        Rights                          : © 2026 €
    [ExifTool]      Warning                         : Superfluous BOM at start of XMP

---

## `lex_Text_QuotedDelim.csv` (61 bytes)

Covers the quoted-field correction of the column count in
`Text.ProcessTXT`: delimiters inside quotes on the first line are not
counted. `vendor/exiftool/t/images/Text.csv` has no quoted field.

Written by hand, two lines:

    "Smith, John","Main St, 5",city
    "Doe, Jane","Elm St, 7",town

Expected (vendored Perl exiftool, `-a -u -G1 -File:all`, excerpt):

    [File]          MIME Encoding                   : us-ascii
    [File]          Newlines                        : Unix LF
    [File]          Delimiter                       : Comma
    [File]          Quoting                         : Double quotes
    [File]          Column Count                    : 3
    [File]          Row Count                       : 2

---

## `lex_Text_UTF8Trunc.txt` (65732 bytes)

Covers the `trunc` argument of `ExifTool.IsUTF8`: `Text.ProcessTXT`
analyses the first 64 KiB, and here they end inside a 2-byte UTF-8
character, which `IsUTF8($dataPt, 1)` accepts. The lines after the first
64 KiB are checked again (`IsUTF8(\$buff)`) and stay UTF-8.

Written by hand: 1456 lines `The quick brown fox jumps over the lazy
dog.` (45 bytes each), 15 `x` -- so byte 65535 (0-based) is the lead byte
`c3` of `é` and byte 65536 its `a9` --, `é and more text`, then four more
of the fox lines; all lines end in LF.

Expected (vendored Perl exiftool, `-a -u -G1 -File:all`, excerpt):

    [File]          MIME Encoding                   : utf-8
    [File]          Byte Order Mark                 : No
    [File]          Newlines                        : Unix LF
    [File]          Line Count                      : 1461
    [File]          Word Count                      : 13144

---

## `lex_ExifTool_DNGVersion.tif` (4876 bytes)

Covers the DNG override at the end of `DoProcessTIFF`: a TIFF with a
`.tif` extension whose IFD0 holds a `DNGVersion` tag is reported as DNG
(`OverrideFileType('DNG')`) once the directory has been read.

Made from `vendor/exiftool/t/images/ExifTool.tif` with the vendored Perl
exiftool, `-IFD0:DNGVersion=1.4.0.0`; nothing else differs.

Expected (vendored Perl exiftool, `-a -u -G1 -File:all -DNGVersion`,
excerpt):

    [File]          File Type                       : DNG
    [File]          File Type Extension             : dng
    [File]          MIME Type                       : image/x-adobe-dng
    [IFD0]          DNG Version                     : 1.4.0.0

With `-validate -warning -a -G1` (`FinishValidate`, file extension check):

    [ExifTool]      Validate                        : 1 Warning
    [ExifTool]      Warning                         : File has wrong extension (should be DNG, not TIF)

---

## `lex_ExifTool_MultiPage.tif` (4864 bytes)

Covers the `PageCount` tag at the end of `DoProcessTIFF`: a plain TIFF
whose `SubfileType` is 2 ("Single page of multi-page image") sets
`MultiPage`, and the page count is stored once the file has been read.

Made from `vendor/exiftool/t/images/ExifTool.tif` with the vendored Perl
exiftool, `-IFD0:SubfileType#=2`; nothing else differs.

Expected (vendored Perl exiftool, `-a -u -G1 -PageCount -SubfileType`):

    [File]          Page Count                      : 1
    [IFD0]          Subfile Type                    : Single page of multi-page image

---

## `lex_ExifTool_NRW.nrw` (6188 bytes)

Covers the NRW-to-NEF correction at the end of `DoProcessTIFF`: a file
taken for NRW (here by its extension) whose Nikon maker notes hold a
`NEFLinearizationTable` is reported as NEF. In
`vendor/exiftool/t/images/Nikon.nef` the raw image's `Compression`
(34713, Nikon NEF Compressed) already identifies the file as NEF
(`Exif.IdentifyRawFile`), so the correction never runs there.

Made from `vendor/exiftool/t/images/Nikon.nef`: the `Compression` entry of
the full-resolution SubIFD changed from 34713 to 1 (the 2-byte value at
offset 1208, `99 87` to `01 00`); nothing else differs.

Expected (vendored Perl exiftool, `-a -u -G1 -File:all
-NEFLinearizationTable`, excerpt):

    [File]          File Type                       : NEF
    [File]          File Type Extension             : nef
    [File]          MIME Type                       : image/x-nikon-nef
    [Nikon]         NEF Linearization Table         : (Binary data 17 bytes, use -b option to extract)

With `-validate -warning -a -G1` the last of five warnings is
`File has wrong extension (should be NEF, not NRW)`.

---

## `lex_FlashPix_Vignette.vnt` (5640 bytes)

Covers the Scene7 Vignette branch of `FlashPix.ProcessContents`: the
`Contents` stream of an FPX (compound document) file is recognized as a
VNT, the file type is overridden, the description override for `VNT` is
set (read by `GetFileType('VNT', 1)`, see `src/test/test_filedescription.lua`)
and the image size is taken from the stream.

Written by hand: a compound document with 512-byte sectors and one stream.

### Layout

    <512 bytes>             header: signature d0 cf 11 e0 a1 b1 1a e1,
                            version 3, byte order fffe, sector shift 9,
                            mini sector shift 6, 1 FAT sector, directory
                            in sector 1, no mini FAT, no DIFAT sectors
    sector 0                FAT: FATSECT, ENDOFCHAIN (directory), then the
                            chain of sectors 2..9 (Contents)
    sector 1                directory: "Root Entry" (no mini stream) with
                            the child "Contents" (stream, sector 2, 4096
                            bytes), two empty entries
    sectors 2..9            Contents (4096 bytes, so it is stored in the
                            FAT and not in the mini stream)

Contents:

    00000000                4 zero bytes
    01                      1 byte
    lex_Vignette.vnt        original file name
    60 a1 3f 22 0000000000  marker
    80020000 e0010000       width 640, height 480 (little-endian)
    <zero bytes>            padding to 4096 bytes

Expected (vendored Perl exiftool, `-a -u -G1 -File:all`, excerpt):

    [File]          File Type                       : VNT
    [File]          File Type Extension             : vnt
    [File]          MIME Type                       : image/x-vignette
    [File]          Image Width                     : 640
    [File]          Image Height                    : 480

---

## `lex_JSON_ON1.json` (192 bytes)

Covers the ON1 branch of `JSON.FoundTag`: a `settings<GUID>Metadata...`
key is renamed to an `ON1_Settings...` tag, and a file read as JSON is
reported as ON1 Presets (`OverrideFileType('ONP')`). The two `c2pa` keys
cover the case-insensitive "C2PA" name fix.

Written by hand:

    {
      "settings1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6fMetadataName": "Preset One",
      "settings1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6fMetadataUsage": "Develop",
      "c2paTest": "x",
      "C2paOther": "y"
    }

Expected (vendored Perl exiftool, `-a -u -G1 -File:all -JSON:all`):

    [File]          File Type                       : ONP
    [File]          File Type Extension             : onp
    [File]          MIME Type                       : application/on1
    [JSON]          ON1 Settings Metadata Name      : Preset One
    [JSON]          ON1 Settings Metadata Usage     : Develop
    [JSON]          C2PA Test                       : x
    [JSON]          C2PA Other                      : y

---

## `lex_Sony_SR2Private.arw` (460 bytes)

Covers the SR2 private directory of Sony ARW images, which no vendored
image has: `Sony.ProcessSR2` with the encrypted `SR2SubIFD`, both SonyIDC
directories (`IDC_IFD` and `IDC2_IFD`, the latter with offsets relative to
its own start) with the `IDCPreviewImage` Composite tag
(`SonyIDC.ExtractPreviews`), and the in-memory MRW block `MRWInfo`
(`MinoltaRaw.ProcessMRW` from `DataPt`) of a DSLR-A700, whose RIF segment
has the A200/A700-only `ColorTemperature`/`ColorFilter` entries. PRD is
present but, in an ARW file, does not set `MinoltaPRD`, so the RIF
`WB_RBLevels` entries stay out.

Written by hand (little-endian TIFF; all offsets absolute unless noted):

    0    II*\0, IFD0 offset 8
    8    IFD0: Make (50), Model (56), 0xc634 SR2Private (LONG, 72)
    50   "SONY\0", "DSLR-A700\0", padding to 72
    72   SR2Private IFD: 0x7200 SR2SubIFDOffset 152, 0x7201 SR2SubIFDLength
         52, 0x7221 SR2SubIFDKey 0x12345678, 0x7240 IDC_IFD 204,
         0x7241 IDC2_IFD 260, 0x7250 MRWInfo (UNDEFINED, 148 bytes at 312)
    152  SR2SubIFD, encrypted with the key (Sony's cipher is an XOR stream):
         0x7313 WB_RGGBLevels (SSHORT[4] at 194), 0x74a2 MaxFocalLength 70,
         0x74a3 MinFocalLength 18, the four levels, padding to 52 bytes
    204  SonyIDC IFD: 0x201 IDCPreviewStart 304, 0x202 IDCPreviewLength 4,
         0x8000 IDCCreativeStyle 4, 0x8013 ColorTemperatureAdj 5500
    260  SonyIDC2 IFD: 0x201 IDCPreviewStart 48 (relative), 0x202 4,
         0x8001 CreativeStyleWasChanged 1
    304  two 4-byte JPEG stubs FF D8 FF D9
    312  \0MRI + length, segments \0PRD (24), \0WBG (12), \0RIF (80)

The SR2Private IFD sits at 72, not 68, because the RIF segment's address
inside the MRW block is 68: Perl's directory loop check would otherwise
refuse to write the file.

Expected (vendored Perl exiftool, `-a -u -G1 -SonyIDC:all -SR2:all
-SR2SubIFD:all`, excerpt):

    [SonyIDC]       IDC Preview Start               : 304
    [SonyIDC]       IDC Preview Length              : 4
    [SonyIDC]       IDC Creative Style              : Vivid
    [SonyIDC]       Color Temperature Adj           : 5500
    [SonyIDC]       IDC Preview Start               : 308
    [SonyIDC]       IDC Preview Length              : 4
    [SonyIDC]       Creative Style Was Changed      : Yes
    [SonyIDC]       IDC Preview Image               : (Binary data 4 bytes, use -b option to extract)
    [SR2]           SR2 Sub IFD Offset              : 152
    [SR2]           SR2 Sub IFD Length              : 52
    [SR2]           SR2 Sub IFD Key                 : 0x12345678
    [SR2SubIFD]     WB RGGB Levels                  : 528 256 256 416
    [SR2SubIFD]     Max Focal Length                : 70 mm
    [SR2SubIFD]     Min Focal Length                : 18 mm

---

## `lex_Sony_A100.arw` (272 bytes)

Covers the original DSLR-A100 ARW layout: IFD0 tag 0x14a is not a SubIFD
but `A100DataOffset` (`Sony.SetARW`: SubfileType 1, Compression 6, and the
value does not point to a valid IFD), and `SR2Private` points to an MRW
block (`\0MRM`) that `Sony.ProcessSR2` hands to `MinoltaRaw.ProcessMRW`;
the A100-only RIF entries (`ColorMode` with the Sony values, all ten
`WB_RBLevels`, `ColorTemperature`/`ColorFilter` at 76/77,
`RawDataLength`). Writing goes through `Sony.FinishARW`, which moves the
MRW block behind the IFDs and fixes up both offsets.

Written by hand (little-endian TIFF, big-endian MRW block):

    0    II*\0, IFD0 offset 8
    8    IFD0: SubfileType 1, Compression 6, Make (86), Model (92),
         0x14a A100DataOffset 256, 0xc634 SR2Private 104
    86   "SONY\0", "DSLR-A100\0", padding to 104
    104  \0MRM + length, segments \0PRD (24), \0WBG (12), \0RIF (84)
    256  16 bytes 0xFF ("raw data")

Expected (vendored Perl exiftool, `-a -u -G1 -A100DataOffset
-MinoltaRaw:ColorMode -MinoltaRaw:WB_RBLevels* -MinoltaRaw:RawDataLength`):

    [IFD0]          A100 Data Offset                : 256
    [MinoltaRaw]    Color Mode                      : Vivid
    [MinoltaRaw]    WB RB Levels Tungsten           : 256 512
    [MinoltaRaw]    WB RB Levels Daylight           : 257 513
    [MinoltaRaw]    WB RB Levels Cloudy             : 258 514
    [MinoltaRaw]    WB RB Levels Cool White F       : 259 515
    [MinoltaRaw]    WB RB Levels Flash              : 260 516
    [MinoltaRaw]    WB RB Levels Custom             : 261 517
    [MinoltaRaw]    WB RB Levels Shade              : 262 518
    [MinoltaRaw]    WB RB Levels Daylight F         : 263 519
    [MinoltaRaw]    WB RB Levels Day White F        : 264 520
    [MinoltaRaw]    WB RB Levels White F            : 265 521
    [MinoltaRaw]    Raw Data Length                 : 16

---

## `lex_DPX_AspectRatio.dpx` (2080 bytes)

Covers the `AspectRatio` PrintConv of DPX, which reduces the pixel aspect
ratio through `Rationalize`. In `vendor/exiftool/t/images/DPX.dpx` the field
holds the "undefined" sentinel 0xFFFFFFFF, so the tag is dropped there.

Made from `vendor/exiftool/t/images/DPX.dpx`: the 8 bytes at offset 1628
(AspectRatio, two big-endian int32u) changed from `FF`x8 to 1920 and 1080;
nothing else differs.

Expected (vendored Perl exiftool, `-AspectRatio`):

    Aspect Ratio                    : 16:9

---

## `lex_FLAC_ID3.flac` (465 bytes)

Covers the leading/trailing ID3 check of `FLAC.ProcessFLAC` on a FLAC file
that starts with an ID3v2 header and ends with an ID3v1 trailer.

Made from `vendor/exiftool/t/images/FLAC.flac`: an ID3v2.3 header with two
text frames (`TIT2` "ID3v2 Title", `TPE1` "ID3v2 Artist", encoding 0)
prepended, and a 128-byte ID3v1 trailer appended (Title "ID3v1 Title",
Artist "ID3v1 Artist", Album "ID3v1 Album", Year "2006", Comment
"ID3v1 Comment", ID3v1.1 track 5, genre 13).

Expected (vendored Perl exiftool, `-G1 -a -ID3:all -FLAC:SampleRate -ID3Size`):

    [ID3v2_3] Title       : ID3v2 Title
    [ID3v2_3] Artist      : ID3v2 Artist
    [ID3v1]   Title       : ID3v1 Title
    [ID3v1]   Track       : 5
    [ID3v1]   Genre       : Pop
    [FLAC]    Sample Rate : 8000
    [File]    ID3 Size    : 183

---

## `lex_FLAC_ID3v1.flac` (410 bytes)

`vendor/exiftool/t/images/FLAC.flac` with the same 128-byte ID3v1 trailer as
`lex_FLAC_ID3.flac` appended and no ID3v2 header. The file starts with
`fLaC`, so it is `FLAC.ProcessFLAC` itself that finds the trailer through
`ID3.ProcessID3` (an ID3v2-prefixed file is read through the ID3 module
first).

Expected (vendored Perl exiftool): the FLAC and Vorbis tags of `FLAC.flac`,
plus the seven ID3v1 tags and `ID3Size` 128.

---

## `lex_FLAC_ManyBlocks.flac` (802 bytes)

Covers the unbounded metadata-block loop of `FLAC.ProcessFLAC`.

Made from `vendor/exiftool/t/images/FLAC.flac`: between its STREAMINFO block
and its VORBIS_COMMENT block (still the last block) 130 empty PADDING blocks
(header `01 00 00 00` each) are inserted, so the comment block is the 132nd
metadata block.

Expected (vendored Perl exiftool, `-a -u -G1`): 130 `[FLAC] Padding` entries
(binary data, 0 bytes) and all Vorbis comments of `FLAC.flac`
(e.g. `[Vorbis] Title : ExifTool test`).

---

## `lex_APE_ID3v1.ape` (2294 bytes)

Covers the ID3 check at the start of `APE.ProcessAPE` and the APE footer
search in front of an ID3v1 trailer (`$footPos -= $$et{DoneID3}`).

`vendor/exiftool/t/images/APE.ape` (MAC header, APE tag footer at the end)
with the same 128-byte ID3v1 trailer as `lex_FLAC_ID3.flac` appended.

Expected (vendored Perl exiftool, `-a -u -G1`): all APE tags of `APE.ape`
(e.g. `[APE] Title : Men Machine Live`), the seven ID3v1 tags and
`ID3Size` 128.

---

## `lex_MPC_NoID3.mpc` (2122 bytes)

Covers `MPC.ProcessMPC` on a Musepack file without any ID3 data: the file
starts with the `MP+` signature itself.

`vendor/exiftool/t/images/APE.mpc` with its leading ID3v2 header (10-byte
header plus the size given in it) and its 128-byte ID3v1 trailer removed;
the SV7 header and the APE tag at the end are unchanged.

Expected (vendored Perl exiftool, `-G1 -FileType -MPC:TotalFrames -APE:Title`):

    [File] File Type    : MPC
    [MPC]  Total Frames : 102
    [APE]  Title        : Men Machine Live

---

## `lex_Vorbis_TagNames.flac` (347 bytes)

Covers the tag-name construction of `Vorbis.ProcessComments` for comment
fields that are not in the table (`s/[^\w-]+(.?)/\U$1/sg`, then
`s/([a-z0-9])_([a-z])/$1\U$2/g`).

`vendor/exiftool/t/images/FLAC.flac` with five comments added to its
VORBIS_COMMENT block (`metaflac --set-tag`): `FOO_1=one`, `BAR =two` (trailing
space), `A.B=three`, `BAZ_QUX=four`, `X-=five`.

Expected tag names (vendored Perl exiftool, `-s -Vorbis:all`):

    Foo_1  : one
    Bar    : two
    AB     : three
    BazQux : four
    X-     : five

---

## `lex_Ogg_Theora.ogv` (3409 bytes)

Covers `Ogg.ProcessPacket` for a Theora stream (OGV file type override,
`SET_GROUP1` for the Theora comments). No vendored image holds Theora video.

One 16x16 grey frame encoded with libtheora through ffmpeg (bit-exact flags,
no metadata but a `title` comment "Theora Title").

Expected (vendored Perl exiftool, `-G1 -FileType -Theora:ImageWidth -Theora:Title`):

    [File]   File Type   : OGV
    [Theora] Image Width : 16
    [Theora] Title       : Theora Title

---

## `lex_RIFF_RF64.wav` (264 bytes)

Covers the MBWF/RF64 header of `RIFF.ProcessRIFF` and the 64-bit `data`
size taken from the `ds64` chunk.

Made from `vendor/exiftool/t/images/RIFF.wav`: signature `RF64`, RIFF size
0xFFFFFFFF, then a 28-byte `ds64` chunk (RIFF size 256, data size 4, sample
count 4, table length 0) in front of the original `fmt `/`LIST` chunks, and
a `data` chunk with size 0xFFFFFFFF holding 4 bytes 0x80.

Expected (vendored Perl exiftool, `-G1 -FileType -RIFF:DataSize64 -RIFF:RIFFSize64`):

    [File] File Type     : WAV (RF64)
    [RIFF] Data Size 64  : 4 bytes
    [RIFF] RIFF Size 64  : 256 bytes

---

## `lex_RIFF_AVIX.avi` (1318 bytes)

Covers the `LIST_movi` descent of `RIFF.ProcessRIFF` under ExtractEmbedded
and a second, concatenated `RIFF` chunk (`AVIX`, as in OpenDML files).
`vendor/exiftool/t/images/RIFF.avi` has an empty `LIST_movi`.

Made from `vendor/exiftool/t/images/RIFF.avi`: the empty `LIST_movi`
replaced by one holding a `00dc` chunk (4 bytes) and a `01wb` chunk
(2 bytes), the outer RIFF size set to the real length, and a `RIFF`/`AVIX`
chunk appended that holds a `LIST_movi` with one `00dc` chunk (2 bytes).

Expected (vendored Perl exiftool, `-ee -v1`), among the chunk lines:

    RIFF 'LIST_movi' chunk (22 bytes of data):
    RIFF '00dc' chunk (4 bytes of data):
    RIFF '01wb' chunk (2 bytes of data):
    RIFF 'RIFF' chunk (26 bytes of data):
    RIFF 'LIST_movi' chunk (10 bytes of data):
    RIFF '00dc' chunk (2 bytes of data):

---

## File type detection fixtures

The following files cover the file type detection in `ExifTool.ExtractInfo`
(`DetectAndProcess`): the types derived from the extension are tried first,
then every other entry of `@fileTypes`, each after its `%magicNumber` test;
a type whose processor declines the file hands it on to the next one.

### `lex_ExifTool_WrongExt.tif` (2321 bytes)

A byte copy of `vendor/exiftool/t/images/GIF.gif` with a `.tif` extension.
TIFF is the first candidate, its magic number does not match, the scan goes
on and ends at GIF.

Expected (vendored Perl exiftool, `-G1 -FileType`, and `-fast4`, which takes
the type from the extension without reading the file):

    [File] File Type : GIF
    [File] File Type : TIFF      (-fast4)

With `-validate -warning -a -G1`:

    [ExifTool]      Validate                        : 1 Warning
    [ExifTool]      Warning                         : File has wrong extension (should be GIF, not TIF)

### `lex_ExifTool_RecognizedExt.dir` (24 bytes)

The bytes 01 02 03 04 05 06, four times. No magic number matches; DIR is
known by its extension only (no `%magicNumber` entry, `%moduleName` value 0),
so at the end of the list the type is taken from the extension, and it is an
unsupported one.

Expected (vendored Perl exiftool, `-G1 -FileType -MIMEType -Warning`):

    [File]     File Type : DIR
    [File]     MIME Type : application/unknown
    [ExifTool] Warning   : Unsupported file type

### `lex_ExifTool_Zeros.jpg` (1034 bytes)

1024 zero bytes followed by `lexiftool\n`. No type matches; the error
message describes the start of the file.

Expected (vendored Perl exiftool, `-G1 -Error`; `-fast` and `-fast3` stop
at the header):

    [ExifTool] Error : First 1024 bytes of file is binary zeros
    [ExifTool] Error : File header is all binary zeros      (-fast)

### `lex_ExifTool_FormatError.png`, `lex_ExifTool_Unknown`, `lex_ExifTool_BadRaw.raw` (32 bytes each)

The bytes 01 to 20 (hex), in order; the second file has no extension. No
type matches, and the error depends on what the name says the file should
be.

Expected (vendored Perl exiftool, `-G1 -Error`):

    [ExifTool] Error : File format error            (.png)
    [ExifTool] Error : Unknown file type            (no extension)
    [ExifTool] Error : Unsupported RAW file type    (.raw)

### `lex_ExifTool_UnknownHeader.jpg` (218 bytes)

The 16 bytes `LEXIFTOOL-JUNK\r\n` followed by an 8x8 baseline JPEG (ffmpeg
mjpeg, bit-exact flags, 202 bytes). No magic number matches, so the last
step of the scan looks for a JPEG/TIFF header further into the file and
processes the data from there; FileType, FileTypeExtension and MIMEType are
deleted again afterwards.

Expected (vendored Perl exiftool, `-G1 -FileType -Warning`; `-v` adds
"Reset file type due to unknown header"):

    [ExifTool] Warning : Processing JPEG-like data after unknown 16-byte header

### `lex_ExifTool_Unsupported.bz2` (48 bytes)

`printf 'lexiftool\n' | bzip2 -9`. BZ2 is a recognized but unsupported type
(`%moduleName` value 0).

Expected (vendored Perl exiftool, `-G1 -FileType -Warning`):

    [File]     File Type : BZ2
    [ExifTool] Warning   : Unsupported file type

### `lex_QuickTime_NoExt` (840 bytes, no extension)

One 16x16 grey frame, ffmpeg mpeg4 in an MP4 container (bit-exact flags, no
metadata). Without an extension the type comes from the content alone (the
`MOV` magic number, `ftyp` at offset 4).

Expected (vendored Perl exiftool, `-G1 -FileType`, and `-fast4`):

    [File]     File Type : MP4
    [ExifTool] Error     : Unknown file type      (-fast4)

### `lex_MPEG_Video.mpg` (37 bytes)

An MPEG-1 video elementary stream: one 16x16 grey frame from ffmpeg
(mpeg1video, 25 fps, bit-exact flags). Covers `MPEG.ProcessMPEG` as a file
type of its own; no vendored image is an MPEG file.

Expected (vendored Perl exiftool, `-G1 -FileType -MPEG:all`):

    [File] File Type    : MPEG
    [MPEG] Image Width  : 16
    [MPEG] Image Height : 16
    [MPEG] Aspect Ratio : 1:1
    [MPEG] Frame Rate   : 25 fps

### `lex_Red_Truncated.r3d` (16 bytes)

An R3D header announcing a 256-byte first block (`00000100 "RED2"`) followed
by only 8 zero bytes. `Red.ProcessR3D` recognizes the file and returns with
a warning.

Expected (vendored Perl exiftool, `-G1 -FileType -Warning`):

    [File]     File Type : R3D
    [ExifTool] Warning   : Truncated R3D file

### `lex_FLIR_FFF.fff` (64 bytes)

A bare FLIR FFF file header: `FFF\0`, creator `CAMCTRL`, format version 100
(little-endian), record directory at offset 0x40 with 0 entries, next free
index 1. Covers the file-level path of `FLIR.ProcessFLIR` (SetFileType,
byte order from the version number).

Expected (vendored Perl exiftool, `-G1 -FileType -FLIR:all`):

    [File] File Type        : FLIR
    [FLIR] Creator Software : CAMCTRL

### `lex_DICOM_ACR.acr` (142 bytes)

An ACR-NEMA file (DICOM data set without the 128-byte preamble and `DICM`
signature), implicit VR little-endian:

    (0008,0000) len 4   group length 10
    (0008,0060) len 2   "CT"            Modality
    (0010,0010) len 8   "DOE^JOHN"      PatientName
    (0010,0020) len 4   "1234"          PatientID
    (0028,0010) len 2   8               Rows
    (0028,0011) len 2   8               Columns
    (7FE0,0010) len 64  zero bytes      PixelData

Covers the headerless identification branch of `DICOM.ProcessDICOM` and the
VR lookup from the tag table for implicit VR elements.

Expected (vendored Perl exiftool, `-G1 -FileType -DICOM:all`):

    [File]  File Type                : ACR
    [DICOM] Identifying Group Length : 10
    [DICOM] Modality                 : CT
    [DICOM] Patient Name             : DOE^JOHN
    [DICOM] Patient ID               : 1234
    [DICOM] Rows                     : 8
    [DICOM] Columns                  : 8

---

## `lex_PPM_LongComment.ppm` (1192 bytes)

A 3x2 binary PPM (`P6`, MaxVal 255, 18 bytes of pixel data) whose header
does not fit into the first 1024-byte read: a comment line of 1113
characters ("Long comment 0000 0001 ... 0219 "), a second comment line, the
size, a third comment between the size and MaxVal:

    P6\n
    # Long comment 0000 0001 ... 0219 \n
    # second comment line\n
    3 2\n
    # comment after the size\n
    255\n
    <18 bytes 00..11>

Covers the read-more loop of `PPM.ProcessPPM` (the comment block ends past
the first buffer, so the parse restarts on the grown buffer) and the comment
after the image size.

Expected (vendored Perl exiftool, `-j -Comment -ImageWidth -ImageHeight
-MaxVal`; the first comment line shortened here):

    "Comment": "Long comment 0000 0001 ... 0219 \nsecond comment line\ncomment after the size",
    "ImageWidth": 3,
    "ImageHeight": 2,
    "MaxVal": 255

## `lex_PPM_SEAL.pgm` (94 bytes)

A 3x2 binary PGM (`P5`, 6 bytes of pixel data) without a comment before the
size, and a SEAL record as the comment between the size and MaxVal:

    P5\n
    3 2\n
    # <seal seal="1" ka="rsa" da="sha256" b="F~S,s~f" d="example.com" s="abcd"/>\n
    255\n
    <6 bytes 00..05>

Covers the SEAL branch of `PPM.ProcessPPM` (the comment is handed to the
XMP SEAL table instead of being extracted) and, when writing, the deletion
of the SEAL comment with `-SEAL:all=`.

Expected (vendored Perl exiftool, `-G1 -PPM:all -File:all -SEAL:all`, the
System tags left out):

    [File] File Type           : PGM
    [File] File Type Extension : pgm
    [File] MIME Type           : image/x-portable-graymap
    [File] Image Width         : 3
    [File] Image Height        : 2
    [File] Max Val             : 255
    [SEAL] SEAL Version        : 1
    [SEAL] Key Algorithm       : rsa
    [SEAL] Digest Algorithm    : sha256
    [SEAL] Byte Range          : F~S,s~f
    [SEAL] Domain              : example.com
    [SEAL] Signature           : abcd

---

## `lex_OpenEXR_ExifXMP.exr` (819 bytes)

`vendor/exiftool/t/images/OpenEXR.exr` with seven attributes inserted after
its last one (`screenWindowWidth`), before the null byte that ends the
header; the offset table and pixel data follow unchanged. Each attribute is
`name\0 type\0 size(uint32 LE) value`:

    exif          blob          uint32 LE length of the TIFF, then a little-endian
                                TIFF with IFD0 Make "Lex", Model "Exr"
    xmp           string        <x:xmpmeta>... xmp:CreatorTool='EXR fixture' ...
    tiles         tiledesc      64, 32 (uint32 LE), mode 0x11
    multiView     stringvector  "left", "right" (each with a uint32 LE length)
    my-attr.name  opaque        01 02 03
    x             int           7
    %%            int           8

Covers the EXIF/XMP subdirectories of `OpenEXR.ProcessEXR`, the tiledesc
and stringvector values, an unknown value type (binary data) and the tag
names generated for unknown attributes (`My-AttrName`, a one-letter name,
a name without a valid character).

Expected (vendored Perl exiftool, `-G1 -Tiles -MultiView -My-AttrName -TagX
-Invalid -IFD0:all -XMP:all`):

    [OpenEXR] Tiles             : 64x32; MIMAP Levels; Round Up
    [OpenEXR] Multi View        : left, right
    [OpenEXR] My-Attr Name      : (Binary data 3 bytes, use -b option to extract)
    [OpenEXR] Tag X             : 7
    [OpenEXR] Invalid           : 8
    [IFD0]    Make              : Lex
    [IFD0]    Camera Model Name : Exr
    [XMP-xmp] Creator Tool      : EXR fixture

## `lex_OpenEXR_Multipart.exr` (585 bytes)

`vendor/exiftool/t/images/OpenEXR.exr` turned into a two-part file: the
Multipart flag (0x1000) set in the version word, `name` "left" and `type`
"scanlineimage" (both `string`) appended to its header, then the null byte
ending that header, a second header (`name` "right", `type`
"scanlineimage", `dataWindow` 0 0 15 7, `compression` 0, `chunkCount` 1),
its null byte, and the original tail (the null byte that now ends the list
of headers, the offset table and pixel data).

Covers the multipart branch of `OpenEXR.ProcessEXR`: with `-ee` the second
header is a sub-document (Doc1) and does not set the image size; without
it the parse stops after the first header.

Expected (vendored Perl exiftool, `-ee -G3:1 -Name -Type -DataWindow
-ImageWidth`):

    [OpenEXR]      Name        : left
    [Doc1:OpenEXR] Name        : right
    [OpenEXR]      Type        : scanlineimage
    [Doc1:OpenEXR] Type        : scanlineimage
    [OpenEXR]      Data Window : 0 0 2 1
    [Doc1:OpenEXR] Data Window : 0 0 15 7
    [File]         Image Width : 3

---

## `lex_M2TS_DashcamGPS.ts` (2256 bytes)

Twelve 188-byte transport packets without timecode (file type M2T) carrying
dashcam GPS records in the PIDs that `-ee3` scans without a program map
table (`ProcessM2TS` registers them with type -1, so `ParsePID` tries its
dashcam formats). There is no PAT/PMT. A packet with the start indicator
holds a PES header (`00 00 01 bf`, private_stream_2, without PES syntax
field) and one record, padded with zero bytes to the packet end; the next
start packet of the same PID hands the collected data to `ParsePID`, and at
the end of the file the remaining data of each PID is parsed in Perl's
string order of the PID numbers.

    #  PID     start  record
    0  0x0300  yes    Viofo A119V3 record (the 48 bytes of the upstream comment)
    1  0x0300  yes    Blueskysea B4K record (the 220 bytes of the upstream
    2  0x0300  no     comment), split over two packets
    3  0x0300  yes    INNOVV: "ANE\0" + lat 4807.038, lon 1131.0, speed 10,
                      track 45.5 (float LE) + accelerometer 1 -2 3 (int32 LE),
                      then "V00\0" + 16 zero bytes + accelerometer -4 5 -6
    4  0x0300  yes    "$GPSINFO,0x0004,2021.08.09 13:27:36,2341.54561,
                      12031.70135,8.0,51,153,0,0,\r" twice, then
                      "$GSNRINFO,0.01,0.04,0.25\0"
    5  0x0300  yes    forum11320 layout (84 bytes): time 12 34 56 at offset
                      32, "A\0\0\0" at 44, lat 47.5 + "N\0\0\0", lon 8.25 +
                      "E\0\0\0", speed 12.5, track 90 (float LE), date 26 10
                      21 at offset 72 (uint32 LE)
    6  0x0300  yes    DOD LS600W: four 32-byte "$S" records from offset 32
                      (big-endian speed, track, year 2026, month 10, day 21,
                      hour 10, minute 0, seconds*10 = 300, 0, 100, 200;
                      lat/lon*1e7), the first one the latest, one track
                      with bit 15 set (65000)
    7  0x01e4  yes    two $GPRMC sentences (the first upstream sample, then one
                      whose degree characters do not decrypt)
    8  0x01e4  no     a third $GPRMC sentence with day 32 (fails the sanity check)
    9  0x0e1b  yes    "$GSENSORD, 1, 2, 3,\0"
    10 0x0e1a  yes    "skip" + length + "LIGOGPSINFO\0" + 00 00 00 14 + 4 zero
                      bytes + one unencrypted 132-byte record
                      ("....2022/09/19 12:45:24 N:31.285065 W:124.759483
                      46.93 km/h x:-0.000 y:-0.000 z:-0.000", zero-padded)
    11 0x0300  yes    "JUNK" (no known format; taken because GPS was found)

Covers every dashcam branch of `M2TS.ParsePID` for type -1, the `-ee3`
GPS-PID scan in `ProcessM2TS`, and the order of the end-of-file pass.

Expected (vendored Perl exiftool, `-ee3 -a -u -G3:1`): 13 sub-documents of
GPS tags (Doc1 Viofo, Doc2 Blueskysea, Doc3/Doc4 INNOVV, Doc5 GPSINFO, Doc6
forum11320, Doc7/Doc8 GPRMC, Doc9-Doc12 DOD in time order, Doc13 LIGO and
the GSENSORD accelerometer), and the warnings "GPSLatitude/Longitude
encryption is not yet known, so these will be wrong", "Decryption of this
GPS is highly experimental. More testing samples are required" and "Error
decrypting GPS degrees". For example:

    [Doc3:QuickTime]  GPS Latitude     : 48 deg 7' 2.29" N
    [Doc3:QuickTime]  Accelerometer    : 1 -2 3
    [Doc5:QuickTime]  GPS Date/Time    : 2021:08:09 13:27:36
    [Doc6:QuickTime]  GPS Date/Time    : 2026:10:21 12:34:56
    [Doc7:QuickTime]  GPS Latitude     : 47 deg 42' 15.41" N
    [Doc9:QuickTime]  GPS Track        : 354.64
    [Doc13:LIGO]      GPS Speed        : 46.93
    [Doc13:QuickTime] Accelerometer    : 1 2 3

---

## `lex_MakerNotes_BadOffsets.jpg` (1573 bytes)

Covers the offset analysis and the user override of `MakerNotes.FixBase`
(the `FixBase` option, `-fixBase[NUM]`). None of the vendored images has
maker notes whose value offsets are off, so `-fixBase` without a value
changes nothing there.

`vendor/exiftool/t/images/Olympus.jpg` with every value offset in the
Olympus maker note IFD (11 entries, at TIFF offset 646) that points outside
the entry -- the entries with more than 4 bytes of data -- increased by 7.
Olympus maker notes carry no `FixBase` flag, and an odd difference is not
"reasonable", so upstream warns instead of fixing.

Expected (vendored Perl exiftool, `-a -G1 -Warning -Olympus:DigitalZoom`):

    [ExifTool]      Warning      : [minor] Possibly incorrect maker notes offsets (fix by -7?)
    [Olympus]       Digital Zoom : 7.8

With `-fixBase`:

    [ExifTool]      Warning      : [minor] Adjusted MakerNotes base by -7
    [Olympus]       Digital Zoom : 0.0

Checked by the CLI golden cases `default`, `fixbase`, `fixbase-8`,
`fixbase-neg` and `makernotes-v`.

---

## `lex_MakerNotes_CanonFooter.jpg` (8337 bytes)

Covers the Canon branch of `MakerNotes.FixBase`: a TIFF footer at the end
of the maker notes records the offset the maker notes were written at.

`vendor/exiftool/t/images/Canon1DmkIII.jpg` with every value offset in the
Canon maker note IFD (36 entries, at TIFF offset 664) that points outside
the entry decreased by 4, and the offset in the footer (`II*\0` + offset,
the last 8 bytes of the maker notes) decreased by 4 as well (0x298 ->
0x294) -- as if the maker notes had been moved 4 bytes without their
offsets being updated. The values at the end of the maker notes then no
longer line up with the footer, so upstream trusts the footer and moves
the base.

Expected (vendored Perl exiftool, `-a -G1 -Warning`):

    [ExifTool]      Warning      : [minor] Adjusted MakerNotes base by 4

With `-fixBase8` the footer's value is replaced by the given one
("Adjusted MakerNotes base by 8").

Checked by the CLI golden cases `default`, `fixbase`, `fixbase-8`,
`fixbase-neg` and `makernotes-v`.

---

## `lex_MakerNotes_EntryBased.jpg` (1573 bytes)

Covers the entry-based branch of `MakerNotes.FixBase`: value offsets
counted from the IFD entry that holds them instead of from the TIFF
header, which some cameras write.

`vendor/exiftool/t/images/Olympus.jpg` with every value offset in the
Olympus maker note IFD (11 entries, at TIFF offset 646) that points outside
the entry rewritten as entry-based: the TIFF offset of the value minus
`646 + 2 + 12 * index`. Upstream recognises this layout, reads the values
relative to the first entry and decodes them as in the original file.

Expected (vendored Perl exiftool, `-v`):

    | | | Warning = [minor] MakerNotes offsets are entry-based

and the Olympus tags as in `Olympus.jpg`.

Checked by the CLI golden cases `default`, `fixbase`, `fixbase-8`,
`makernotes-v`.

---

## `lex_MRC_Frames.mrc` (3328 bytes)

Covers the frame loop of `MRC.ProcessMRC` under ExtractEmbedded, including
its read error. `vendor/exiftool/t/images/MRC.mrc` (two FEI1 extended-header
frames of 768 bytes) with `ImageDepth` raised from 2 to 4,
`ExtendedHeaderSize` raised to 4 * 768 and the second frame appended once
more: three frames are present, four are claimed.

Expected (vendored Perl exiftool, `-ee -a -G3:1 -Warning -TimeStamp`):

    [Doc3:ExifTool] Warning     : Error reading extended header 3
    [File]          Time Stamp  : 2020:10:21 13:54:27
    [Doc1:File]     Time Stamp  : 2020:10:21 13:55:19
    [Doc2:File]     Time Stamp  : 2020:10:21 13:55:19

Without `-ee` only the first frame is read, with the minor warning "Use the
ExtractEmbedded option to read metadata for all frames".

Checked by the CLI golden cases `default`, `mrc-ee` and `mrc-ee-v3`.

---

## `lex_FLIR_SEQ.seq` (7782 bytes)

Covers the SEQ recursion of `FLIR.ProcessFLIR` under ExtractEmbedded. Two
FFF frames back to back: the FLIR record data of
`vendor/exiftool/t/images/FLIR.jpg` (its APP1 `FLIR` chunks joined, 3891
bytes, big-endian, the RawData record last), the second copy with the
CameraSerialNumber string changed from 470023842 to 470023843.

Expected (vendored Perl exiftool, `-ee -a -G3:1 -CameraSerialNumber
-RawThermalImage`):

    [FLIR]      Camera Serial Number : 470023842
    [Doc1:FLIR] Camera Serial Number : 470023843
    [FLIR]      Raw Thermal Image    : (Binary data 79 bytes, use -b option to extract)

With `-ee2` the later frame's RawData record is read as well
(`[Doc1:FLIR] Raw Thermal Image`).

Checked by the CLI golden cases `default`, `seq-ee`, `seq-ee2`,
`seq-ee-v3` and `api-ee-3`.

---

## LargeFileSupport fixtures

Small files whose headers claim an offset or a size beyond 2 GB. They test
the gating by the LargeFileSupport option, not the reading of large data:
0 refuses, 1 (the default) goes on, 2 goes on with a warning.

- `lex_BigTIFF_HugeOffsets.btf` (384 bytes): `vendor/exiftool/t/images/BigTIFF.btf`
  with entry 2 of IFD0 (BitsPerSample) given a count of 5 and the value
  offset 0x100000000, and the next-IFD pointer set to 0x80000000.
- `lex_InDesign_Large.indd` (12288 bytes): `vendor/exiftool/t/images/InDesign.indd`
  with the page count of the current master page set to 0x80000 (database
  end at 2 GB).
- `lex_ASF_LargeObject.wmv` (54 bytes): an empty ASF Header object
  followed by the header of a Data object of 0xC0000000 + 24 bytes.
- `lex_AIFF_LargeChunk.aif` (20 bytes): `FORM`/`AIFF` and a `NAME` chunk
  header of 0x80000000 bytes.
- `lex_ZIP_RARLargeBlock.rar` (18 bytes): a RAR v4 signature and one block
  header (type 0x7a, flags 0x8000) whose added size makes 0x80000000 bytes.
- `lex_Matroska_LargeBlock.mkv` (37 bytes): an EBML header (DocType
  `matroska`), a Segment of unknown size and a Void element of 0x80000000
  bytes.

Expected (vendored Perl exiftool, `-a -G1 -Warning`), with
`-api LargeFileSupport=0`:

    BigTIFF:  Can't handle IFD0 entry 2 (LargeFileSupport not set)
              Huge offsets not supported (LargeFileSupport not set)
    InDesign: InDesign files larger than 2 GB not supported (LargeFileSupport not set)
    ASF:      Large ASF objects not supported (LargeFileSupport not set)
    AIFF:     End of processing at large chunk (LargeFileSupport not enabled)
    RAR:      Large block encountered. Aborting.
    Matroska: (none -- the scan stops silently)

by default:

    BigTIFF:  Error reading IFD0 entry 2
              Truncated IFD1 count
    AIFF:     Skipping large Name chunk (> 100 MB)

and with `-api LargeFileSupport=2` as by default plus "Processing large
file (LargeFileSupport is 2)" (InDesign), "Skipping large ASF object
(LargeFileSupport is 2)", "Skipping large chunk (LargeFileSupport is 2)"
(AIFF) and "Processing large block (LargeFileSupport is 2)" (RAR,
Matroska).

Checked by the CLI golden cases `default`, `lfs-0`, `lfs-2`, `lfs-2-v3`
and `btf-htmlDump`.

---

## `lex_AIFF_EmptyChunks.aif` (492 bytes)

Covers the empty-chunk limit of `AIFF.ProcessAIFF`: `FORM`/`AIFF` and 60
chunk headers `XXXX` of length 0. Upstream counts an empty chunk twice (the
`++$n` before `next` and the loop's own increment), so the scan stops at
the 51st with "Aborting scan.  Too many empty chunks".

Checked by the CLI golden cases `default` and `lfs-fmt-v3`.

---

## Validate fixtures

Small files written by hand (byte by byte) for the module-local checks of
the Validate option. Each reaches its check only under `-validate`; the
plain read output is unremarkable. Checked by the CLI golden cases
`default`, `a-u-ee-G1`, `validate-fx`, `validate-v`, `w-hidden`,
`w-png-crc` and `w-png-crc-m`.

- `lex_Exif_TextHeader.tif` (176 bytes): a big-endian TIFF with IFD0
  (ImageWidth, ImageHeight, ExifIFD and GPS pointers), an ExifIFD with
  ExifVersion and a UserComment `UNICODE\0` + "Hello" in UTF-16LE, and a
  GPS IFD with GPSVersionID, a GPSProcessingMethod `ASCII\0\0 ` + "GPS"
  and a GPSAreaInformation `\0\0\0 \0\0\0\0` + "Area" (`Exif.ConvertExifText`).
- `lex_PNG_Validate.png` (136 bytes): a 1x1 grayscale PNG with a tEXt
  `Creation Time` of `2018-01-01 12:00`, a tEXt `Comment` and an IDAT
  whose CRCs are off by one bit (`PNG.ConvertPNGDate`, the CRC check in
  `PNG.ProcessPNG`; writing gives the minor error "Bad CRC for tEXt
  chunk").
- `lex_QuickTime_Validate.mov` (604 bytes): `ftyp` (qt), a `wide` atom with
  8 bytes of payload, two atoms with the ID `00 00 00 01`, and two
  identical `moov` atoms, each with two `mvhd` and a `udta` holding two
  `\xa9nam` (`QuickTime.ProcessMOV`: "Invalid 'wide' atom size",
  "Duplicate ... at ...").
- `lex_Sony_HiddenData.jpg` (174 bytes): SOI, an APP1 EXIF segment
  (little-endian; IFD0 Make `SONY`, Model `DSC-TEST`; ExifIFD with a
  `SONY DSC \0\0\0` maker note holding only tag 0x2044 HiddenInfo),
  SOS, EOI and a trailer of 4 zero bytes plus 20 bytes of HiddenData
  (`55 26 11 05 00` + "HIDDEN-DATA-123"). HiddenDataOffset points 7 bytes
  too far, so `Sony.ReadHiddenData` finds the data by scanning the trailer.
- `lex_Sony_HiddenDataMissing.jpg` (174 bytes): the same with zero bytes
  in place of the HiddenData.
- `lex_XMP_Namespaces.xmp` (639 bytes): an XMP packet that uses `dc`
  outside the `rdf:Description` that declares it, `foo` and `tiff` without
  a declaration and `xmp` before the element that declares it
  (`XMP.ParseXMPElement`).

Expected (vendored Perl exiftool, `-validate -warning -a -G1`), apart from
the "Missing required ..." warnings of the incomplete TIFF and JPEG:

    lex_Exif_TextHeader.tif:
      Wrong byte order for EXIF UserComment UNICODE text
      ASCII text header for GPSProcessingMethod has spaces instead of nulls
      Undefined text header for GPSAreaInformation has spaces instead of nulls
    lex_PNG_Validate.png:
      [minor] Non standard PNG date/time format
      Bad CRC for tEXt chunk
      Bad CRC for IDAT chunk
    lex_QuickTime_Validate.mov:
      Invalid 'wide' atom size
      Duplicate index 1 at MOV-.
      Duplicate tag 'mvhd' at MOV-Movie-mvhd [x2]
      Duplicate tag '\xa9nam' at MOV-Movie-UserData-<A9>nam [x2]
      Duplicate tag 'moov' at MOV-moov
    lex_Sony_HiddenData.jpg:
      [minor] Fixed incorrect HiddenDataOffset
    lex_Sony_HiddenDataMissing.jpg:
      [minor] Error reading HiddenData
    lex_XMP_Namespaces.xmp:
      XMP namespace dc is used out of scope
      Undefined XMP namespace: foo
      Undefined XMP namespace: xmp
      Undefined XMP namespace: tiff

(`<A9>` stands for the raw byte 0xA9 in the output.)

---

## `lex_PNG_LargeICC.png` (25654 bytes)

Covers the byte identity of deflated PNG chunks: Compress::Zlib deflates
with memLevel 9 (`MAX_MEM_LEVEL`), and from about 16k deflate symbols on,
the compressed bytes depend on it. `vendor/exiftool/t/images/` has no PNG
with compressed data that large.

The IHDR, IDAT and IEND chunks of `vendor/exiftool/t/images/PNG.png` (a
16x16 1-bit grayscale image) with an `iCCP` chunk before the IDAT: profile
name `Lexi Gray`, compression method 0 and a zlib-compressed ICC profile of
40152 bytes (written with Perl's `Compress::Zlib::compress`):

    128-byte header         size, CMM type `lexi`, version 2.1.0, class
                            `mntr`, colour space `GRAY`, PCS `XYZ `, date
                            2000:01:01 00:00:00, `acsp`, platform `APPL`,
                            manufacturer `none`, D50 illuminant, creator
                            `lexi`, zero profile ID
    00000001                tag count
    cprt <offset> <length>  the only tag: a `text` type (`text`, 4 zero
                            bytes, NUL-terminated ASCII)

The text is 1600 words of 24 lowercase letters, separated by spaces, from
the linear congruential generator `seed = (seed * 1103515245 + 12345) %
2^31` (seed 12345, letter `97 + (seed >> 16) % 26`): poorly compressible,
so the deflate stream has far more than 16k symbols.

Expected (vendored Perl exiftool, `-validate -ICC_Profile:all -PNG:all`,
excerpt):

    [ExifTool]      Validate                        : OK
    [ICC-header]    Profile CMM Type                : Unknown (lexi)
    [ICC-header]    Profile Class                   : Display Device Profile
    [ICC-header]    Color Space Data                : GRAY
    [ICC_Profile]   Profile Copyright               : serobdhgmpmribfyzchibdtm rkumtuhyyriixdcbijtqjeza ...
    [PNG]           Profile Name                    : Lexi Gray

Checked by the CLI golden cases `w-png-iccp` (the profile rewritten in
place: `PNG.FoundPNG` inflates the iCCP chunk and deflates it again) and
`w-png-iccp-new` (the profile copied into `PNG.png`, which has none:
`WritePNG.WriteProfile` creates the iCCP chunk); the written files must be
byte for byte those of exiftool.

## `lex_7Z_EncodedHeader.7z` (258 bytes), `lex_7Z_PlainHeader.7z` (124 bytes), `lex_7Z_Encrypted.7z` (206 bytes)

Cover `7Z.Process7Z` with both header kinds and the decoder setup of the
encoded one. `vendor/exiftool/t/images/` has no 7z archive at all.

Written by 7-Zip (`7z a ARCHIVE FILES`, default settings: LZMA2 for the
data, header compression on). 7-Zip compresses the archive header with
LZMA1 (the encoded header, property id 23) once it is larger than a few
bytes, so:

- `lex_7Z_EncodedHeader.7z`: six entries -- a directory `sub`, an empty
  file `empty.dat`, `f1.txt` .. `f3.txt` (`file 1\n` .. `file 3\n`) and
  `sub/e.txt` (`x\n`) -- with modification times 2019-05-05 05:05:05,
  2021-01-11 11:00, 2021-02-12 12:00, 2021-03-13 13:00 (local time,
  Europe/Berlin); the header is LZMA1-compressed. Reaches
  `ReadStreamsInfo` for the packed header, `GetDecompressor`, `ReadData`,
  `Decompress`/`Decompress_Internal` (Compress::Raw::Lzma's RawDecoder) and
  then the file list from the decoded header, with the Duplicates warning.
- `lex_7Z_PlainHeader.7z`: one file `a.txt` (`hello\n`, modified
  2020-01-02 03:04:05); 7-Zip leaves a header this small uncompressed
  (property id 1), so this is the plain-header path.
- `lex_7Z_Encrypted.7z`: the same `a.txt` with `-pLexi -mhe=on` (password
  `Lexi`, header encrypted): the coder of the header is 7zAES, and
  `GetDecompressor` gives up.

Expected (vendored Perl exiftool with Compress::Raw::Lzma installed,
`-a -u -G1 -ZIP:all -Warning`, times as printed in Europe/Berlin):

    lex_7Z_EncodedHeader.7z
    [ZIP]           File Version                    : 7z v0.04
    [ZIP]           Modify Date                     : 2019:05:05 05:05:05+02:00
    [ZIP]           Archived File Name              : sub
    [ZIP]           Modify Date                     : 2019:05:05 05:05:05+02:00
    [ZIP]           Archived File Name              : empty.dat
    [ZIP]           Modify Date                     : 2021:01:11 11:00:00+01:00
    [ZIP]           Archived File Name              : f1.txt
    [ZIP]           Modify Date                     : 2021:02:12 12:00:00+01:00
    [ZIP]           Archived File Name              : f2.txt
    [ZIP]           Modify Date                     : 2021:03:13 13:00:00+01:00
    [ZIP]           Archived File Name              : f3.txt
    [ZIP]           Modify Date                     : 2019:05:05 05:05:05+02:00
    [ZIP]           Archived File Name              : sub/e.txt

    lex_7Z_PlainHeader.7z
    [ZIP]           File Version                    : 7z v0.04
    [ZIP]           Modify Date                     : 2020:01:02 03:04:05+01:00
    [ZIP]           Archived File Name              : a.txt

    lex_7Z_Encrypted.7z
    [ZIP]           File Version                    : 7z v0.04
    [ExifTool]      Warning                         : File is encrypted.
    [ExifTool]      Warning                         : Invalid or corrupted file.

Without Compress::Raw::Lzma, Perl lists nothing for the encoded header and
warns "Install Compress::Raw::Lzma to read encoded 7z information".

Not covered by a fixture: a header that packs into more than one block of
32 KB. Upstream gives every block a new decoder, so the second block does
not decode and the loop in `Process7Z` never ends (Perl and lexiftool
alike).

Checked by the CLI golden cases `default`, `a-u-ee-G1`, `archive-v3` and
`archive-j`.

## `lex_Rawzor_NEF.rwz` (3151 bytes)

Covers `Rawzor.ProcessRWZ` in full: the bzip2-compressed metadata, the
re-assembly of the original file and the recursive `ExtractInfo`. There is
no Rawzor sample to be had, so the file is built
from the layout `Rawzor.pm` reads, with `vendor/exiftool/t/images/Nikon.nef`
(6188 bytes) as the original raw:

    0   "rawzor"                    signature
    6   int16u 110                  required SDK version (1.10)
    8   int16u 120                  creator SDK version (1.20)
    10  int64u 3151                 RWZ file size
    18  int64u 6188                 original file size
    26  12 zero bytes               reserved
    38  int64u 46                   metadata offset
    46  int64u 1376                 metadata section 0 end
    54  int64u 1394                 metadata section 1 start
    62  int64u 6170                 metadata section 1 end
    70  int64u 6188                 metadata section 2 start
    78  4 zero bytes                reserved
    82  int32u 6152                 original metadata size
    86  int32u 3061                 compressed metadata size
    90  3061 bytes                  bzip2 stream (Perl's IO::Compress::Bzip2,
                                    default block size) of the metadata

All values little-endian. The metadata are bytes 0-1375, 1394-6169 and
6188- (empty) of `Nikon.nef`: the two gaps are the 18-byte image strips of
SubIFD1 (at 1376) and IFD0 (at 6170), which the re-assembly fills with
zeros, as Rawzor leaves the image data out of the metadata. No compressed
image data follow (the original's image data are the zero-filled gaps).

Expected (vendored Perl exiftool, `-a -u -G1`, excerpt; the full output
is that of `Nikon.nef` plus the Rawzor group):

    [Rawzor]        Rawzor Required Version         : 1.10
    [Rawzor]        Rawzor Creator Version          : 1.20
    [Rawzor]        Original File Size              : 6.2 kB
    [Rawzor]        Compression Factor              : 1.96
    [Rawzor]        Original File Type              : NEF
    [File]          File Type                       : RWZ
    [IFD0]          Camera Model Name               : NIKON D70
    [ExifIFD]       Date/Time Original              : 2004:06:09 16:02:35
    [Composite]     Lens ID                         : AF-S DX Zoom-Nikkor 18-70mm f/3.5-4.5G IF-ED

Checked by the CLI golden cases `default`, `a-u-ee-G1`, `archive-v3`,
`archive-j` and `rwz-htmlDump` (the dump of the outer file at the offsets
of the embedded one: blocks past its end are read partially, as Perl's
`Read` returns them).

---

## `lex_Geotag_DOP.gpx` (549 bytes)

A GPX 1.1 track log of three points with dilution-of-precision elements --
`pdop` on the first, `hdop` and `vdop` on the second, `hdop` alone on the
third -- for `Geotag.SetGeoValues`' GPSDOP/GPSMeasureMode branch and the
`GeoHPosErr` option, whose Perl expression of `$GPSDOP` sets
GPSHPositioningError. None of the vendored track logs carries a DOP.

Expected (vendored Perl exiftool, `-geotag lex_Geotag_DOP.gpx
-api 'GeoHPosErr=$GPSDOP*5' '-Geotime=2003:05:24 17:09:21Z'` into
`ExifTool.jpg`, then `-G1 -GPS:all`):

    [GPS]           GPS Dilution Of Precision       : 1.185
    [GPS]           GPS Horizontal Positioning Error: 5.925 m

An invalid expression (`$GPSDOP*`, `$GPSDOP/0`) leaves GPSHPositioningError
unset with the minor warning "Error calculating GPSHPositioningError: syntax
error" or "...: Illegal division by zero" (shown by `-v`).

Checked by the CLI golden cases `w-geotag-hposerr`, `w-geotag-hposerr-lc`,
`w-geotag-hposerr-syntax` and `w-geotag-hposerr-die`, which compare the
written files byte for byte.

---

## `lex_Geolocation_GeoDir/` (directory)

A GeoDir directory (`-api GeoDir=...`) holding only a GeoLang translation
file for Russian, `GeoLang/ru.pm`: an extract of `Geolocation500/GeoLang/ru.pm`
from the Geolocation500 package of
https://exiftool.org/geolocation.html -- its header, the
entries whose names the Geolocation lookups of `GPS.jpg`, `Apple.jpg`,
`GoPro.jpg` and `Google.jpg` reach in the bundled database (city, region,
the region-specific `ESMadrid,`, subregion and country names), two entries
with escaped quotes and the feature type section with its bareword keys,
lines copied verbatim. `GeoLang/ru.lua` is its Lua counterpart, written by
`tools/gen_geolang.lua GeoLang/ru.pm`: Perl exiftool reads the `.pm`,
lexiftool the `.lua`, which it takes before a `.pm` beside it. There is no `Geolocation.dat` in the directory, so
both warn "Error reading .../Geolocation.dat" and fall back to the bundled
database.

Expected (vendored Perl exiftool, `-api GeoDir=lex_Geolocation_GeoDir
-api Geolocation=1 -lang ru -G1 "-Geolocation*" Google.jpg`):

    [ExifTool]      Geolocation City                : Acacias
    [ExifTool]      Geolocation Region              : Область Мадрид
    [ExifTool]      Geolocation Subregion           : Provincia de Madrid
    [ExifTool]      Geolocation Country Code        : ES
    [ExifTool]      Geolocation Country             : Испания
    [ExifTool]      Geolocation Feature Type        : Участок Населенного Пункта

Checked by the CLI golden cases `geolang-ru`, `geolang-ru-j` and
`geolang-ja` (no ja file in the directory: untranslated).

---

## `lex_Geolocation_GeoDirPm/` (directory)

The same `GeoLang/ru.pm` as in `lex_Geolocation_GeoDir/`, alone: exiftool
and lexiftool both read the `.pm` (lexiftool as data, without running Perl).
No `Geolocation.dat` either, so both warn and use the bundled database.

Expected (vendored Perl exiftool, `-api GeoDir=lex_Geolocation_GeoDirPm
-api Geolocation=1 -lang ru -G1 "-Geolocation*" Google.jpg`): the output
shown for `lex_Geolocation_GeoDir/`.

Checked by the CLI golden case `geolang-ru-pm`.

---

## `lex_Geolocation_GeoDirLua/` (directory)

A GeoDir directory with a Lua language file and a different `.pm` beside
it: `GeoLang/ru.lua` is the one of `lex_Geolocation_GeoDir/` (all entries of
the extract), `GeoLang/ru.pm` keeps only the header and the `'Spain'` entry
of the extract's `.pm`. lexiftool takes the `.lua` (a deliberate difference,
see doc/differences.md, "Geolocation language files"); exiftool would read
the `.pm`, so there is no golden comparison.

Checked by `src/test/test_cli_port.lua` (section 6): the output equals
lexiftool's on `lex_Geolocation_GeoDirPm/` (itself compared with exiftool by
`geolang-ru-pm`) and differs from lexiftool's on this `ru.pm` alone.

---

## `lex_PDF_RC4_40.pdf` (4887 bytes), `lex_PDF_RC4_128.pdf` (4888 bytes), `lex_PDF_AES128.pdf` (8236 bytes), `lex_PDF_AES256.pdf` (8536 bytes)

Cover the decryption of PDF documents with the standard security handler:
RC4 with 40-bit and 128-bit keys (`PDF.RC4Crypt`), AES-128 (AESV2) and
AES-256 (AESV3, revision 6, with the hardened hash of `PDF.GetHash`)
through `AES.Crypt`, and the re-encryption of what a write changes.
`vendor/exiftool/t/images/` has no encrypted PDF (`t/PDF.t` decrypts its
test vectors by hand).

All four are `vendor/exiftool/t/images/PDF.pdf` encrypted by qpdf with an
empty user password and the owner password `owner`:

    qpdf --allow-weak-crypto --encrypt "" owner 40 -- PDF.pdf lex_PDF_RC4_40.pdf
    qpdf --allow-weak-crypto --encrypt "" owner 128 --use-aes=n -- PDF.pdf lex_PDF_RC4_128.pdf
    qpdf --encrypt "" owner 128 --use-aes=y --cleartext-metadata -- PDF.pdf lex_PDF_AES128.pdf
    qpdf --encrypt "" owner 256 --cleartext-metadata -- PDF.pdf lex_PDF_AES256.pdf

The two AES files leave the XMP metadata stream unencrypted
(`--cleartext-metadata`): exiftool encrypts what it writes with a random
IV, and `w-Subject` (which runs over every image) then writes the new XMP
stream in the clear, so its output stays the same from run to run. The
Info dictionary strings and the other streams are encrypted. In
`lex_PDF_AES128.pdf` the Photoshop stream is larger than 10000 bytes, so
exiftool skips it ("[Minor] Skipping large AES-encrypted PhotoshopStream")
unless `-m` is given.

Expected (vendored Perl exiftool, `-a -G1 -s`, excerpt):

    lex_PDF_RC4_40.pdf
    [PDF]           Encryption                      : Standard V1.2 (40-bit)
    lex_PDF_RC4_128.pdf
    [PDF]           Encryption                      : Standard V2.3 (128-bit)
    lex_PDF_AES128.pdf
    [PDF]           Encryption                      : Standard V4.4 (128-bit)
    lex_PDF_AES256.pdf
    [ExifTool]      Warning                         : [minor] Decryption is very slow for encryption V5.6 or higher
    [PDF]           Encryption                      : Standard V5.6 (256-bit)

and in each file the Info dictionary (`[PDF] Creator : Adobe Photoshop
7.0`, ...) and the XMP, IPTC, Photoshop and EXIF tags of `PDF.pdf`.

Checked by the CLI golden cases `default`, `a-u-ee-G1` and `w-Subject` (all
images), `pdf-password` (`-password owner`), `pdf-aes-large` (`-m`) and
`w-pdf-rc4` (Info strings re-encrypted with RC4; the AES files are not
written there, the random IV makes the bytes differ from run to run).

---

## `lex_MWG_Regions.xmp` (4531 bytes)

Face regions in the three XMP region schemas -- MWG (`RegionInfo`),
Microsoft Photo (`RegionInfoMP`) and IPTC Extension (`ImageRegion`, with a
pixel and a relative rectangle, a circle and a region without a boundary) --
plus `ImageWidth`/`ImageHeight`, for the Composite tags of the bundled
config files `convert_regions.config` and `rotate_regions.config`. Their
conversions are Perl code with loops, `next`, references and nested
structures, which perl.eval runs. No vendored image has region information.

Written by the vendored Perl exiftool:

    exiftool -o lex_MWG_Regions.xmp \
      '-RegionInfo={AppliedToDimensions={W=4000,H=3000,Unit=pixel},RegionList=[{Area={X=0.5,Y=0.4,W=0.1,H=0.2,Unit=normalized},Name=Anna,Type=Face},{Area={X=0.25,Y=0.75,W=0.2,H=0.3,Unit=normalized},Name=Ben,Type=Face}]}' \
      '-RegionInfoMP={Regions=[{Rectangle=0.1|, 0.2|, 0.3|, 0.4,PersonDisplayName=Anna},{Rectangle=0.5|, 0.5|, 0.2|, 0.25,PersonDisplayName=Ben},{Rectangle=0.6|, 0.1|, 0.1|, 0.1,PersonDisplayName=ffffffffffffffff}]}' \
      '-ImageRegion=[{RegionBoundary={RbShape=rectangle,RbUnit=pixel,RbX=100,RbY=200,RbW=300,RbH=400},Name=Anna},{RegionBoundary={RbShape=rectangle,RbUnit=relative,RbX=0.5,RbY=0.5,RbW=0.1,RbH=0.1},Name=Ben},{RegionBoundary={RbShape=circle,RbUnit=relative,RbX=0.2,RbY=0.2,RbRx=0.05}},{Name=Dora}]' \
      -XMP-tiff:ImageWidth=4000 -XMP-tiff:ImageHeight=3000

Every region has a name and an area: a hash element whose value is undef
does not exist in lexiftool (doc/differences.md), and the rotations copy
`Name` and the rectangle into new structures.

Expected (vendored Perl exiftool, `-config convert_regions.config -struct
-Composite:all`, excerpt; without -struct the regions are flattened and
the Composite tags that need them are not built):

    MP Region 2 MWG Region          : {AppliedToDimensions={H=3000,Unit=pixel,W=4000},RegionList=[{Area=...
    MWG Region 2 IPTC Region        : [{Name=Anna,RegionBoundary={RbH=0.2,RbShape=rectangle,RbUnit=relat...
    MWG Region 2 MP Region          : {Regions=[{PersonDisplayName=Anna,Rectangle=0.45|, 0.3|, 0.1|, 0.2...

Checked by the CLI golden cases `d-config-regions*` (the conversions with
`-struct -j`, and a copy of the converted regions into a new file).

---

## WriteQuickTime fixtures (`lex_WriteQuickTime_*`)

Files for the branches of `WriteQuickTime.WriteQuickTime` that no vendored
QuickTime image reaches: trailers, garbage after the last atom, boxes that
must come after the media data, data references, movie fragments and HEIC
item properties. Built once with a script from vendored files and two tiny
ffmpeg movies (`ffmpeg -f lavfi -i color=c=red:s=16x16:r=25 -c:v mjpeg
-fflags +bitexact -flags +bitexact -map_metadata -1`, one frame with
`-movflags +faststart`, two frames with `-movflags
+frag_keyframe+empty_moov[+global_sidx]`).

The Insta360 trailer used below is 86 bytes: one 0x600 record (an 8-byte
timestamp, 1234567 ms) and the 78-byte footer (record ID 0x600, length 8,
trailer length 86 at offset 38, the 32-character magic
`8db42d694ccc418790edff439fe026bf` at the end). The MIE trailer is the
72-byte file the vendored Perl exiftool writes with `exiftool -o t.mie
-MIE:TrailerSignature=1 -MIE-Doc:Title=hello` (it ends in the `zmie`
trailer signature).

- `lex_WriteQuickTime_Trailers.mov` (4029 bytes): `QuickTime.mov` + the
  Insta360 trailer + the MIE trailer (`QuickTime.IdentifyTrailers` finds
  both from the end of the file).
- `lex_WriteQuickTime_Kenwood.mov` (4191 bytes): `QuickTime.mov` +
  `CCCCCCCC` + 312 bytes; `lex_WriteQuickTime_RIFFTrailer.mov` (4179
  bytes): `QuickTime.mov` + `gsen\0\0\0\0` + 300 bytes;
  `lex_WriteQuickTime_UnknownTrailer.mov` (3895 bytes): `QuickTime.mov` +
  an atom header of size 256 (`junk`) and 16 bytes. The "atom" after the
  last one is truncated, so the writer identifies a Kenwood, RIFF or
  Unknown trailer from its first bytes (more than 256 bytes, or they would
  count as garbage).
- `lex_WriteQuickTime_Garbage.mov` (3979 bytes): `QuickTime.mov` + a
  `free` atom header of size 4096 and 100 bytes;
  `lex_WriteQuickTime_HTML.mov` (4183 bytes): `QuickTime.mov` + 312 bytes
  of text starting with `<br>`.
- `lex_WriteQuickTime_InstBox.mp4` (1099 bytes): the one-frame movie + an
  `inst` box (Insta360Info, DontRead and WriteLast) holding the Insta360
  trailer as its payload.
- `lex_WriteQuickTime_ExtRef.mp4` (1005 bytes): the one-frame movie with
  the flags of its `url ` data reference set to 0 (media data not in this
  file), so the chunk offsets are left alone when the `mdat` moves.
- `lex_WriteQuickTime_Fragmented.mp4` (1506 bytes) and
  `lex_WriteQuickTime_SIDX.mp4` (1570 bytes): the fragmented two-frame
  movies, without and with a `sidx` box.
- `lex_WriteQuickTime_VRD.cr3` (52242 bytes): `CanonRaw.cr3` with a
  CanonVRD block in a `UUID-Canon2` box after the media data, written by
  the vendored Perl exiftool (`"-CanonVRD<=CanonVRD.vrd"`).
- `lex_WriteQuickTime_MotionPhoto.heic` (647 bytes): `QuickTime.heic` with
  a 24-byte `mpvd` box (MotionPhotoVideo, WriteLast) inserted before the
  first `mdat`, the `iloc` base offsets moved accordingly.
- `lex_WriteQuickTime_Rotation.heic` (653 bytes): `QuickTime.heic` with
  three `irot` boxes added to `ipco` (properties 5, 6 and 7, rotations 0, 1
  and 2) and associated in `ipma` with the primary item 20002 (5 and 7)
  and its thumbnail 20003 (6); `iloc` moved by the 20 added bytes.

Expected (vendored Perl exiftool, `-XMP:Subject=x`):

    lex_WriteQuickTime_Trailers.mov:       Warning: [minor] Copying Insta360 trailer from offset 0xf1f (86 bytes)
    lex_WriteQuickTime_Kenwood.mov:        Warning: [minor] Copying Kenwood trailer from offset 0xf1f (320 bytes)
    lex_WriteQuickTime_RIFFTrailer.mov:    Warning: [minor] Copying RIFF trailer from offset 0xf1f (308 bytes)
    lex_WriteQuickTime_UnknownTrailer.mov: Warning: [minor] Copying Unknown trailer from offset 0xf1f (24 bytes)
    lex_WriteQuickTime_Garbage.mov:        Error: [minor] Possible garbage at end of file (108 bytes)
    lex_WriteQuickTime_HTML.mov:           Error: [minor] Possible extraneous HTML at end of file (312 bytes)
    lex_WriteQuickTime_Fragmented.mp4:     Error: Can't yet handle movie fragments when writing
    lex_WriteQuickTime_SIDX.mp4:           Error: Can't yet handle sidx box when writing

and `-a -G4 -Rotation` on `lex_WriteQuickTime_Rotation.heic` gives
`Rotate 180` for the primary item, `Rotate 270 CW` (Copy1) and
`Horizontal (normal)` (Copy2). Writing `-QuickTime:Rotation#=3` changes
properties 5 and 7 only.

Checked by the CLI golden write cases `w-qt-*` (written files, stdout,
stderr and exit status compared with the vendored Perl exiftool).

---

## TIFF write fixtures (`lex_ExifTool_*` for DoProcessTIFF, `lex_PostScript_DOSTIFF.eps`)

Files for the write side of `ExifTool.DoProcessTIFF` (EXIF, TIFF and
TIFF-based raw files rewritten, and EXIF blocks rebuilt in memory through
`Writer.WriteTIFF`) that no vendored image reaches. The small TIFFs are
built byte by byte: a 1x1 8-bit image whose single strip byte ends the TIFF
data at the odd offset 111. The EXIF files and the CR3 are written by the
vendored Perl exiftool.

- `lex_ExifTool_ExifMeta.exif` (2182 bytes): `exiftool -o x.exif Canon.jpg`,
  an EXIF file with the `ExifMeta` signature after the TIFF header.
- `lex_ExifTool_LargeExif.exif` (526496 bytes): the same with a 524300-byte
  ImageDescription written into it -- larger than the 512 kB block read for
  an EXIF file ("EXIF too large to extract as a block").
- `lex_ExifTool_ORF.tif`, `lex_ExifTool_DCP.tif`, `lex_ExifTool_HDP2.tif`,
  `lex_ExifTool_PanasonicRaw.raw` (111 bytes each): the small TIFF with the
  header identifier of an Olympus ORF (`IIRO`), a DNG camera profile
  (`IIRC`), a Windows HD Photo of version 2 (`II\xbc\x02`) and a Panasonic
  RAW without the RW2 signature (`IIU\0`).
- `lex_ExifTool_BigTIFF.tif` (384 bytes): `BigTIFF.btf` under a TIFF name.
- `lex_ExifTool_BlankTrailer.tif` (4928 bytes): `ExifTool.tif` + 64 zero
  bytes.
- `lex_ExifTool_LongTrailer.tif` (135944 bytes): `ExifTool.tif` + 65540 zero
  bytes + 65540 bytes of text (an unknown trailer read in 64 kB blocks).
- `lex_ExifTool_PadTrailer.tif` (137 bytes): the small TIFF + a zero pad
  byte + 25 bytes of text.
- `lex_ExifTool_AFCPTrailer.tif` (5723 bytes): `ExifTool.tif` + the 859-byte
  AFCP trailer of `AFCP.jpg`, its start offset patched to 4864.
- `lex_ExifTool_EmptyExif.jpg` (261 bytes): `Canon.jpg` with its EXIF
  segment replaced by an APP1 segment holding only `Exif\0\0`.
- `lex_ExifTool_NoGPS.cr3` (50408 bytes): `exiftool -gps:all=
  CanonRaw.cr3`, a CR3 without the GPS box.
- `lex_PostScript_DOSTIFF.eps` (227 bytes): a DOS EPS binary header, 86
  bytes of PostScript and the small TIFF as preview.

Expected (vendored Perl exiftool, `-v -Artist=x`):

    lex_ExifTool_ExifMeta.exif:     FileType = EXIF (written back with the ExifMeta signature)
    lex_ExifTool_LargeExif.exif:    Warning: EXIF too large to extract as a block
    lex_ExifTool_ORF.tif:           FileType = ORF
    lex_ExifTool_DCP.tif:           FileType = DCP
    lex_ExifTool_HDP2.tif:          Error: Windows HD Photo version 2 files not yet supported
    lex_ExifTool_PanasonicRaw.raw:  Error: Error reading Panasonic raw data
    lex_ExifTool_BigTIFF.tif:       Error: ExifTool does not support writing of BigTIFF images
    lex_ExifTool_BlankTrailer.tif:  Deleting blank trailer (64 bytes)
    lex_ExifTool_LongTrailer.tif:   Preserving unknown trailer (131080 bytes)
    lex_ExifTool_PadTrailer.tif:    Preserving unknown trailer (25 bytes)
    lex_PostScript_DOSTIFF.eps:     Warning: Couldn't write Photoshop/XMP information
    lex_ExifTool_EmptyExif.jpg:     Warning: Multiple APP1 EXIF records

and `-v -Trailer:all=` on `lex_ExifTool_LongTrailer.tif` gives "Deleting
unknown trailer (131080 bytes)".

Checked by the CLI golden write cases `w-tiff-file`, `w-tiff-trail-del` and
`w-cr3-gps` (written files, stdout, stderr and exit status compared with the
vendored Perl exiftool).
