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
