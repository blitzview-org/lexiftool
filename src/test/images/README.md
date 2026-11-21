# Additional test images

Additions to the vendored test images (`vendor/exiftool/t/images/`) for code
paths that have no representative there. The vendored tree is never
modified; this directory is a second source of test images.

**These files are fixtures.** They were built once (by hand or by a one-off
script) and are the reference; there is no build step. Changing one changes
the test scenario.

Name prefix `lex_`: tools that key on the base name must never see a
collision with an upstream image name.

Every fixture is compared with the vendored Perl exiftool by the CLI golden
test ([doc/cli-tests.md](../../../doc/cli-tests.md)): the variants with
`scope = 'all'` run over all images, and a branch that needs a particular
option gets its own variant with an explicit image list in
`src/test-cli/Cases.lua`. The *Test* column names `golden` for that and any
unit test in `src/test/` that reads the file as well.

Origin: *from X* means a vendored image (`vendor/exiftool/t/images/X`) with
the stated change; *by hand* means built byte by byte or by a one-off script
from invented data.

## Single fixtures

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_PhotoshopLayers.psd` | by hand (see below) | `Photoshop.ProcessLayersAndMask`/`ProcessLayers`, additional layer info blocks, tag list padding (`Photoshop.psd` has `LayerCount 0`) | golden, `test_photoshop_layers` |
| `lex_Flash_CWS.swf` | from `Flash.swf`, stored as compressed `CWS` (see below) | zlib branch of `Flash.ReadCompressed`, incl. the second read on the same inflate stream | golden |
| `lex_DICOM_Deflated.dcm` | from `DICOM.dcm` (see below) | deflated transfer syntax `1.2.840.10008.1.2.1.99` in `DICOM.ProcessDICOM` | golden |
| `lex_PLIST_Compressed.aae` | from `PLIST.aae`: the `adjustmentData` binary PLIST raw-deflated, then Base64 | `CompressedPLIST` branch of `PLIST.FoundTag` | golden |
| `lex_XMP_InvalidPrefix.xmp` | by hand: prefix `1x` with an unknown URI, two properties | prefix validation in `XMP.FoundXMP` (warning, renamed group `ns_1x`) | golden |
| `lex_XMP_Base64.xmp` | by hand: `dc:source` of datatype `base64Binary` | base64 branch of `XMP.FoundXMP`; the decoded text avoids `x`, `0`, `c`, which upstream's character class also matches | golden |
| `lex_XMP_Pantry.xmp` | by hand: an `xmpMM:Pantry` item with `dc:format` and `tiff:Orientation` besides its `InstanceID` | variable-namespace structure (`NAMESPACE` present but undef) in `XMP.FoundXMP`: the fields take the top-level tags' info and groups | golden |
| `lex_XMP_DoubleUTF8.xmp` | by hand: UTF-8 BOM, packet bytes UTF-8-encoded twice | double-encoded UTF-8 branch of `XMP.ProcessXMP` | golden |
| `lex_XMP_DoubleUTF16.xmp` | by hand: BOM `fe ff`, each byte of the above packet as one UTF-16BE unit | double-encoded UTF-16 branch of `XMP.ProcessXMP` | golden |
| `lex_XMP_SuperfluousBOM.jpg` | from `Writer.jpg`: APP1 XMP with BOM and a character above U+00FF after SOI | leading-BOM check for embedded XMP in `XMP.ProcessXMP` | golden |
| `lex_Text_QuotedDelim.csv` | by hand: two lines with quoted commas | quoted-field column count in `Text.ProcessTXT` | golden |
| `lex_Text_UTF8Trunc.txt` | by hand: the first 64 KiB end inside a 2-byte UTF-8 character | `trunc` argument of `ExifTool.IsUTF8` via `Text.ProcessTXT` | golden |
| `lex_ExifTool_DNGVersion.tif` | from `ExifTool.tif`: `-IFD0:DNGVersion=1.4.0.0` | DNG override at the end of `DoProcessTIFF`, wrong-extension check of `-validate` | golden |
| `lex_ExifTool_MultiPage.tif` | from `ExifTool.tif`: `-IFD0:SubfileType#=2` | `PageCount` at the end of `DoProcessTIFF` | golden |
| `lex_ExifTool_NRW.nrw` | from `Nikon.nef`: raw `Compression` 34713 -> 1 (offset 1208) | NRW-to-NEF correction at the end of `DoProcessTIFF` | golden |
| `lex_FlashPix_Vignette.vnt` | by hand (see below) | Scene7 Vignette branch of `FlashPix.ProcessContents`, `GetFileType('VNT', 1)` | golden, `test_filedescription` |
| `lex_JSON_ON1.json` | by hand: two `settings<GUID>Metadata...` keys, two `c2pa` keys | ON1 branch of `JSON.FoundTag` (file type ONP), C2PA name fix | golden |
| `lex_Sony_SR2Private.arw` | by hand (see below) | `Sony.ProcessSR2` with encrypted `SR2SubIFD`, `IDC_IFD`/`IDC2_IFD`, `SonyIDC.ExtractPreviews`, `MinoltaRaw.ProcessMRW` from memory | golden |
| `lex_Sony_A100.arw` | by hand (see below) | DSLR-A100 layout: `Sony.SetARW` (`A100DataOffset`), MRW block via `Sony.ProcessSR2`, A100 RIF entries, `Sony.FinishARW` when writing | golden |
| `lex_DPX_AspectRatio.dpx` | from `DPX.dpx`: AspectRatio (offset 1628) set to 1920/1080 | `AspectRatio` PrintConv via `Rationalize` | golden |
| `lex_FLAC_ID3.flac` | from `FLAC.flac`: ID3v2.3 header prepended, 128-byte ID3v1 trailer appended | leading/trailing ID3 check of `FLAC.ProcessFLAC` | golden |
| `lex_FLAC_ID3v1.flac` | from `FLAC.flac`: the same ID3v1 trailer only | ID3v1 found by `FLAC.ProcessFLAC` itself via `ID3.ProcessID3` | golden |
| `lex_FLAC_ManyBlocks.flac` | from `FLAC.flac`: 130 empty PADDING blocks inserted | unbounded metadata-block loop of `FLAC.ProcessFLAC` | golden |
| `lex_APE_ID3v1.ape` | from `APE.ape`: the same ID3v1 trailer appended | ID3 check of `APE.ProcessAPE`, footer search before ID3v1 | golden |
| `lex_MPC_NoID3.mpc` | from `APE.mpc`: ID3v2 header and ID3v1 trailer removed | `MPC.ProcessMPC` without ID3 | golden |
| `lex_ID3_FrameFlags.mp3` | by hand: ID3v2.4 with flagged `TIT2`, `TPE1`, unknown `XXYZ`, two silent MPEG frames | ID3v2.4 frame flags in `ID3.ProcessID3v2` (data length, grouping, verbose `Flags=`) | golden |
| `lex_Vorbis_TagNames.flac` | from `FLAC.flac`: five comments with odd field names (`metaflac --set-tag`) | tag-name construction of `Vorbis.ProcessComments` | golden |
| `lex_Ogg_Theora.ogv` | ffmpeg/libtheora, one 16x16 frame, `title` comment | Theora in `Ogg.ProcessPacket` (OGV override, `SET_GROUP1`) | golden |
| `lex_RIFF_RF64.wav` | from `RIFF.wav`: `RF64` signature, `ds64` chunk, `data` size 0xFFFFFFFF | RF64 header and 64-bit sizes in `RIFF.ProcessRIFF` | golden |
| `lex_RIFF_AVIX.avi` | from `RIFF.avi`: filled `LIST_movi`, appended `RIFF`/`AVIX` chunk | `LIST_movi` descent under ExtractEmbedded, concatenated RIFF chunk | golden |

### `lex_PhotoshopLayers.psd`

Big-endian PSD, 8x8 RGB, no colour mode data or image resources, raw image
data. Layer and Mask Info with two layer records (rectangle 0 0 8 8, no
channels, blend mode `norm`, opacity 255), each with a padded Pascal name
and Additional Layer Info blocks (`8BIM <tag> <len> <data>`):

| Layer | Name | Blocks |
|---|---|---|
| 1 | `Ebene 1` | `luni` = "Ebene 1", `lyid` = 42 |
| 2 | `Hintergrund` | `luni` = "Hintergrund", `lyid` = 43, `lsct` = 1 |

`luni` payload: character count (4 bytes), then UTF-16BE text.

### `lex_Flash_CWS.swf`

`CWS 06`, the uncompressed file length 384 (LE), then bytes 8..383 of
`Flash.swf` as a zlib stream (RFC 1950, level 9). The XMP record (359
bytes) needs a second, larger read on the same inflate stream.

### `lex_DICOM_Deflated.dcm`

`DICOM.dcm` with `(0002,0000)` = 182 and `(0002,0010)` =
`1.2.840.10008.1.2.1.99`; from offset 0x146 the data set of `DICOM.dcm`
(its bytes from 0x144) as a raw deflate stream (RFC 1951, level 9).

### `lex_FlashPix_Vignette.vnt`

Compound document with 512-byte sectors: header, FAT (sector 0), directory
(sector 1: Root Entry and the stream `Contents`, 4096 bytes so it lives in
the FAT), `Contents` in sectors 2..9: 4 zero bytes, `01`, the name
`lex_Vignette.vnt`, marker `60 a1 3f 22 0000000000`, width 640 and height
480 (LE), zero padding.

### `lex_Sony_SR2Private.arw`

Little-endian TIFF, absolute offsets: IFD0 at 8 (Make, Model `DSLR-A700`,
`SR2Private` -> 72); SR2Private IFD at 72 with `SR2SubIFDOffset` 152,
`SR2SubIFDLength` 52, `SR2SubIFDKey` 0x12345678, `IDC_IFD` 204, `IDC2_IFD`
260 (offsets relative to itself), `MRWInfo` (148 bytes at 312); the
SR2SubIFD at 152 encrypted with the key (WB_RGGBLevels, focal lengths);
two 4-byte JPEG stubs at 304; the MRW block `\0MRI` with `PRD`, `WBG`,
`RIF` at 312. The SR2Private IFD sits at 72, not 68, because the RIF
segment's address is 68 and Perl's directory loop check would refuse the
write.

### `lex_Sony_A100.arw`

Little-endian TIFF: IFD0 at 8 (SubfileType 1, Compression 6, Make, Model
`DSLR-A100`, `A100DataOffset` 256, `SR2Private` 104); at 104 a big-endian
MRW block `\0MRM` with `PRD` (24), `WBG` (12), `RIF` (84: ColorMode, ten
WB_RBLevels, ColorTemperature/ColorFilter at 76/77); at 256 16 bytes 0xFF
as raw data.

## File type detection

`ExifTool.ExtractInfo` (`DetectAndProcess`): extension candidates first,
then every other `@fileTypes` entry after its `%magicNumber` test.

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_ExifTool_WrongExt.tif` | byte copy of `GIF.gif` | scan past a non-matching extension type; `-fast4`; wrong-extension warning | golden |
| `lex_ExifTool_RecognizedExt.dir` | by hand: `01..06` four times | type known by extension only, unsupported | golden |
| `lex_ExifTool_Zeros.jpg` | by hand: 1024 zero bytes + `lexiftool\n` | "binary zeros" errors (also `-fast`) | golden |
| `lex_ExifTool_FormatError.png` | by hand: bytes `01..20` | "File format error" | golden |
| `lex_ExifTool_Unknown` | same bytes, no extension | "Unknown file type" | golden |
| `lex_ExifTool_BadRaw.raw` | same bytes | "Unsupported RAW file type" | golden |
| `lex_ExifTool_UnknownHeader.jpg` | by hand: 16 junk bytes + 8x8 ffmpeg JPEG | JPEG/TIFF header search after an unknown header | golden |
| `lex_ExifTool_Unsupported.bz2` | `printf 'lexiftool\n' \| bzip2 -9` | recognized but unsupported type | golden |
| `lex_QuickTime_NoExt` | ffmpeg mpeg4 in MP4, 16x16, no extension | type from content alone; `-fast4` | golden |
| `lex_MPEG_Video.mpg` | ffmpeg mpeg1video, one 16x16 frame | `MPEG.ProcessMPEG` as a file type | golden |
| `lex_Red_Truncated.r3d` | by hand: R3D header announcing 256 bytes, 8 present | truncated R3D in `Red.ProcessR3D` | golden |
| `lex_FLIR_FFF.fff` | by hand: bare FFF header, creator `CAMCTRL`, 0 records | file-level `FLIR.ProcessFLIR` | golden |
| `lex_DICOM_ACR.acr` | by hand: ACR-NEMA, implicit VR LE, seven elements | headerless branch of `DICOM.ProcessDICOM`, VR lookup from the table | golden |

## Further single fixtures

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_PPM_LongComment.ppm` | by hand: 3x2 `P6` with a 1113-character comment, a comment after the size | read-more loop of `PPM.ProcessPPM` | golden |
| `lex_PPM_SEAL.pgm` | by hand: 3x2 `P5` with a SEAL record as comment | SEAL branch of `PPM.ProcessPPM`, `-SEAL:all=` | golden |
| `lex_OpenEXR_ExifXMP.exr` | from `OpenEXR.exr`: seven attributes added (`exif`, `xmp`, `tiles`, `multiView`, opaque, odd names) | EXIF/XMP subdirectories, tiledesc/stringvector, unknown types and names in `OpenEXR.ProcessEXR` | golden |
| `lex_OpenEXR_Multipart.exr` | from `OpenEXR.exr`: multipart flag, a second header | multipart branch of `OpenEXR.ProcessEXR` (`-ee`) | golden |
| `lex_M2TS_DashcamGPS.ts` | by hand (see below) | every type -1 dashcam branch of `M2TS.ParsePID`, `-ee3` PID scan, end-of-file order | golden |
| `lex_MakerNotes_BadOffsets.jpg` | from `Olympus.jpg`: out-of-entry value offsets of the maker note IFD +7 | offset analysis and `-fixBase` override of `MakerNotes.FixBase` | golden |
| `lex_MakerNotes_CanonFooter.jpg` | from `Canon1DmkIII.jpg`: maker note value offsets and footer offset -4 | Canon footer branch of `MakerNotes.FixBase` | golden |
| `lex_MakerNotes_EntryBased.jpg` | from `Olympus.jpg`: value offsets rewritten relative to their entry | entry-based branch of `MakerNotes.FixBase` | golden |
| `lex_MRC_Frames.mrc` | from `MRC.mrc`: four frames claimed, three present | frame loop and read error of `MRC.ProcessMRC` (`-ee`) | golden |
| `lex_FLIR_SEQ.seq` | two FFF frames from the FLIR data of `FLIR.jpg`, the second with another serial number | SEQ recursion of `FLIR.ProcessFLIR` (`-ee`, `-ee2`) | golden |
| `lex_AIFF_EmptyChunks.aif` | by hand: 60 empty chunks | empty-chunk limit of `AIFF.ProcessAIFF` | golden |
| `lex_PNG_LargeICC.png` | from `PNG.png`: an `iCCP` chunk with a 40152-byte profile (see below) | byte identity of large deflated chunks (`PNG.FoundPNG`, `WritePNG.WriteProfile`) | golden |

### `lex_M2TS_DashcamGPS.ts`

Twelve 188-byte packets without timecode, no PAT/PMT. A start packet holds
a PES header `00 00 01 bf` and one record, zero-padded. PID 0x0300 carries
Viofo A119V3, Blueskysea B4K (over two packets), INNOVV, `$GPSINFO`, the
forum11320 layout, DOD LS600W and finally `JUNK`; PID 0x01e4 three `$GPRMC`
sentences (one with undecryptable degrees, one with day 32); 0x0e1b
`$GSENSORD`; 0x0e1a a `LIGOGPSINFO` record. The records are the upstream
comment samples or invented values in the documented layouts.

### `lex_PNG_LargeICC.png`

IHDR/IDAT/IEND of `PNG.png` with `iCCP` (name `Lexi Gray`) before the IDAT,
zlib-compressed by Perl's `Compress::Zlib::compress`. The profile: a
128-byte header (CMM `lexi`, class `mntr`, `GRAY`, PCS `XYZ `), one `cprt`
tag of type `text` holding 1600 pseudo-random 24-letter words (LCG
`seed = (seed * 1103515245 + 12345) % 2^31`, seed 12345, letter
`97 + (seed >> 16) % 26`), so the deflate stream exceeds 16k symbols, where
Compress::Zlib's memLevel 9 shows in the bytes.

## LargeFileSupport fixtures

Headers claiming an offset or size beyond 2 GB, for the gating by the
LargeFileSupport option (0 refuses, 1 goes on, 2 goes on with a warning).

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_BigTIFF_HugeOffsets.btf` | from `BigTIFF.btf`: IFD0 entry 2 count 5 at offset 0x100000000, next IFD 0x80000000 | BigTIFF offsets | golden |
| `lex_InDesign_Large.indd` | from `InDesign.indd`: master page count 0x80000 | InDesign database size | golden |
| `lex_ASF_LargeObject.wmv` | by hand: empty Header object, Data object of 0xC0000000 + 24 bytes | ASF objects | golden |
| `lex_AIFF_LargeChunk.aif` | by hand: `NAME` chunk of 0x80000000 bytes | AIFF chunks | golden |
| `lex_ZIP_RARLargeBlock.rar` | by hand: RAR v4 block header of 0x80000000 bytes | RAR blocks | golden |
| `lex_Matroska_LargeBlock.mkv` | by hand: EBML header, Segment of unknown size, Void of 0x80000000 bytes | Matroska elements | golden |

## Validate fixtures

Hand-built files for module-local checks that only `-validate` reaches.

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_Exif_TextHeader.tif` | by hand: UserComment `UNICODE` in LE, GPS text headers with spaces | `Exif.ConvertExifText` | golden |
| `lex_PNG_Validate.png` | by hand: 1x1 PNG, nonstandard `Creation Time`, CRCs off by one bit | `PNG.ConvertPNGDate`, CRC check of `PNG.ProcessPNG` | golden |
| `lex_QuickTime_Validate.mov` | by hand: bad `wide` atom, duplicate IDs, two `moov` | `QuickTime.ProcessMOV` duplicate checks | golden |
| `lex_Sony_HiddenData.jpg` | by hand: Sony maker note with HiddenInfo, HiddenDataOffset 7 bytes off | `Sony.ReadHiddenData` trailer scan | golden |
| `lex_Sony_HiddenDataMissing.jpg` | the same with the HiddenData zeroed | "Error reading HiddenData" | golden |
| `lex_XMP_Namespaces.xmp` | by hand: out-of-scope and undeclared prefixes | `XMP.ParseXMPElement` namespace checks | golden |

## 7z archives

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_7Z_EncodedHeader.7z` | 7-Zip, six entries, LZMA1 header | `7Z.Process7Z` encoded header: `ReadStreamsInfo`, `GetDecompressor`, `ReadData`, `Decompress` | golden |
| `lex_7Z_PlainHeader.7z` | 7-Zip, one file `a.txt` | plain header | golden |
| `lex_7Z_Encrypted.7z` | 7-Zip, `-pLexi -mhe=on` | 7zAES header coder, `GetDecompressor` gives up | golden |
| `lex_7Z_ExternalAttr.7z` | from `lex_7Z_PlainHeader.7z`: empty kDummy property after the attributes | attributes not last in `7Z.ReadFilesInfo`; upstream dies (known deviation `upstream-bug`) | golden |

Written by `7z a ARCHIVE FILES` (default settings). The encoded archive
holds a directory `sub`, an empty `empty.dat`, `f1.txt`..`f3.txt`
(`file 1\n`..) and `sub/e.txt`, modified 2019-05-05 05:05:05 and
2021-01-11/02-12/03-13 (Europe/Berlin); `a.txt` holds `hello\n`, modified
2020-01-02 03:04:05. For `lex_7Z_ExternalAttr.7z` the next header size and
both CRCs were fixed up after inserting the property (7-Zip still tests it
as correct). The reference Perl needs `Compress::Raw::Lzma`.

## Rawzor

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_Rawzor_NEF.rwz` | by hand from `Nikon.nef` (see below) | `Rawzor.ProcessRWZ`: bzip2 metadata, re-assembly, recursive `ExtractInfo` | golden |

Little-endian header: `rawzor`, SDK versions 110/120, RWZ size 3151,
original size 6188, 12 reserved bytes, metadata offset 46, section bounds
1376 / 1394 / 6170 / 6188, 4 reserved bytes, original metadata size 6152,
compressed size 3061, then the bzip2 stream (`IO::Compress::Bzip2`, default
block size) of bytes 0-1375 and 1394-6169 of `Nikon.nef`. The two gaps are
the 18-byte image strips, which the re-assembly fills with zeros; no image
data follow.

## Geotagging and Geolocation

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_Geotag_DOP.gpx` | by hand: GPX 1.1, three points with `pdop`/`hdop`/`vdop` | GPSDOP/GPSMeasureMode in `Geotag.SetGeoValues`, `GeoHPosErr` | golden |
| `lex_Geolocation_GeoDir/` (`GeoLang/ru.pm`, `GeoLang/ru.lua`) | extract of Geolocation500 `GeoLang/ru.pm`; `ru.lua` generated from it | `-api GeoDir` with `-lang ru`; lexiftool prefers the `.lua` | golden, `test_cli_port` |
| `lex_Geolocation_GeoDirPm/` (`GeoLang/ru.pm`) | the same `ru.pm` alone | both tools read the `.pm` (lexiftool as data) | golden, `test_cli_port` |
| `lex_Geolocation_GeoDirLua/` (`GeoLang/ru.lua`, `GeoLang/ru.pm`) | the full `ru.lua` beside a `ru.pm` with only the `'Spain'` entry | lexiftool takes the `.lua` (deliberate difference, no golden comparison) | `test_cli_port` |
| `lex_Geolocation_GeoDirTrunc/` (`Geolocation.dat`) | from the bundled `Geolocation.dat`: the header with a city count of 2, the comment line, the first two city records and the end marker of the city list, nothing after it | a truncated database in `Geolocation.ReadDatabase`: "Error reading ... (truncated file?)", then the bundled database | golden (`api-geodir-trunc`) |
| `lex_Geolocation_GeoDirTruncList/` (`Geolocation.dat`) | the same city section as `lex_Geolocation_GeoDirTrunc/`, followed by the bundled database's first five country records (`AD`..`AI`), without the end marker of the country list | a database truncated inside the country list, where exiftool's `ReadDatabase` never clears it before falling back to the bundled database: the leftover records shift every index into it (upstream bug, `doc/differences.md`) | golden (`api-geodir-trunc-list`) |

`ru.pm` is an extract of `Geolocation500/GeoLang/ru.pm` from
<https://exiftool.org/geolocation.html>, lines copied verbatim: the header,
the entries the lookups of `GPS.jpg`, `Apple.jpg`, `GoPro.jpg` and
`Google.jpg` reach in the bundled database, two entries with escaped quotes
and the feature type section. `ru.lua` is written by
`tools/gen_geolang.lua GeoLang/ru.pm`. No `GeoLang` directory holds a
`Geolocation.dat`, so the bundled database is used after a warning.

## Encrypted PDF

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_PDF_RC4_40.pdf` | `PDF.pdf` encrypted by qpdf | `PDF.RC4Crypt`, 40-bit key | golden |
| `lex_PDF_RC4_128.pdf` | likewise | `PDF.RC4Crypt`, 128-bit key; re-encryption when writing | golden |
| `lex_PDF_AES128.pdf` | likewise | AESV2 via `AES.Crypt`; large AES stream skipped without `-m` | golden |
| `lex_PDF_AES256.pdf` | likewise | AESV3 rev. 6 with `PDF.GetHash` | golden |

Empty user password, owner password `owner`:

    qpdf --allow-weak-crypto --encrypt "" owner 40 -- PDF.pdf lex_PDF_RC4_40.pdf
    qpdf --allow-weak-crypto --encrypt "" owner 128 --use-aes=n -- PDF.pdf lex_PDF_RC4_128.pdf
    qpdf --encrypt "" owner 128 --use-aes=y --cleartext-metadata -- PDF.pdf lex_PDF_AES128.pdf
    qpdf --encrypt "" owner 256 --cleartext-metadata -- PDF.pdf lex_PDF_AES256.pdf

The AES files keep the XMP stream unencrypted: exiftool encrypts what it
writes with a random IV, and an unencrypted XMP stream keeps the write
output the same from run to run.

## Region config

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_MWG_Regions.xmp` | written by the vendored exiftool (see below) | Composite tags of `convert_regions.config`/`rotate_regions.config` via `perl.eval` | golden, `test_perlconfig` |

    exiftool -o lex_MWG_Regions.xmp \
      '-RegionInfo={AppliedToDimensions={W=4000,H=3000,Unit=pixel},RegionList=[{Area={X=0.5,Y=0.4,W=0.1,H=0.2,Unit=normalized},Name=Anna,Type=Face},{Area={X=0.25,Y=0.75,W=0.2,H=0.3,Unit=normalized},Name=Ben,Type=Face}]}' \
      '-RegionInfoMP={Regions=[{Rectangle=0.1|, 0.2|, 0.3|, 0.4,PersonDisplayName=Anna},{Rectangle=0.5|, 0.5|, 0.2|, 0.25,PersonDisplayName=Ben},{Rectangle=0.6|, 0.1|, 0.1|, 0.1,PersonDisplayName=ffffffffffffffff}]}' \
      '-ImageRegion=[{RegionBoundary={RbShape=rectangle,RbUnit=pixel,RbX=100,RbY=200,RbW=300,RbH=400},Name=Anna},{RegionBoundary={RbShape=rectangle,RbUnit=relative,RbX=0.5,RbY=0.5,RbW=0.1,RbH=0.1},Name=Ben},{RegionBoundary={RbShape=circle,RbUnit=relative,RbX=0.2,RbY=0.2,RbRx=0.05}},{Name=Dora}]' \
      -XMP-tiff:ImageWidth=4000 -XMP-tiff:ImageHeight=3000

Every region has a name and an area: a hash element whose value is undef
does not exist in lexiftool (doc/differences.md).

## WriteQuickTime fixtures

Branches of `WriteQuickTime.WriteQuickTime` no vendored image reaches.

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_WriteQuickTime_Trailers.mov` | `QuickTime.mov` + Insta360 trailer + MIE trailer | `QuickTime.IdentifyTrailers`, trailer copy | golden |
| `lex_WriteQuickTime_Kenwood.mov` | `QuickTime.mov` + `CCCCCCCC` + 312 bytes | Kenwood trailer | golden |
| `lex_WriteQuickTime_RIFFTrailer.mov` | `QuickTime.mov` + `gsen\0\0\0\0` + 300 bytes | RIFF trailer | golden |
| `lex_WriteQuickTime_UnknownTrailer.mov` | `QuickTime.mov` + truncated `junk` atom | Unknown trailer | golden |
| `lex_WriteQuickTime_Garbage.mov` | `QuickTime.mov` + truncated `free` atom | garbage at end of file | golden |
| `lex_WriteQuickTime_HTML.mov` | `QuickTime.mov` + 312 bytes of `<br>` text | extraneous HTML | golden |
| `lex_WriteQuickTime_InstBox.mp4` | one-frame movie + `inst` box with the Insta360 trailer | WriteLast box after the media data | golden |
| `lex_WriteQuickTime_ExtRef.mp4` | one-frame movie, `url ` flags 0 | external data reference: chunk offsets left alone | golden |
| `lex_WriteQuickTime_Fragmented.mp4` | fragmented two-frame movie | "Can't yet handle movie fragments" | golden |
| `lex_WriteQuickTime_SIDX.mp4` | the same with `sidx` | "Can't yet handle sidx box" | golden |
| `lex_WriteQuickTime_VRD.cr3` | `CanonRaw.cr3` + `"-CanonVRD<=CanonVRD.vrd"` (vendored exiftool) | `UUID-Canon2` box after the media data | golden |
| `lex_WriteQuickTime_MotionPhoto.heic` | `QuickTime.heic` + 24-byte `mpvd` box, `iloc` adjusted | MotionPhotoVideo (WriteLast) | golden |
| `lex_WriteQuickTime_Rotation.heic` | `QuickTime.heic` + three `irot` boxes associated in `ipma` | HEIC item rotation, `-QuickTime:Rotation#=` | golden |

The movies are ffmpeg output (`ffmpeg -f lavfi -i color=c=red:s=16x16:r=25
-c:v mjpeg -fflags +bitexact -flags +bitexact -map_metadata -1`, one frame
with `-movflags +faststart`, two frames with `-movflags
+frag_keyframe+empty_moov[+global_sidx]`). The Insta360 trailer is 86
bytes: a 0x600 record (8-byte timestamp 1234567 ms) and the 78-byte footer
(record ID 0x600, length 8, trailer length 86, the magic
`8db42d694ccc418790edff439fe026bf`). The MIE trailer is what
`exiftool -o t.mie -MIE:TrailerSignature=1 -MIE-Doc:Title=hello` writes.

## TIFF write fixtures

Write side of `ExifTool.DoProcessTIFF` and `Writer.WriteTIFF`. "Small TIFF"
is a hand-built 1x1 8-bit TIFF whose strip byte ends the data at offset 111.

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_ExifTool_ExifMeta.exif` | `exiftool -o x.exif Canon.jpg` | EXIF file with the `ExifMeta` signature | golden |
| `lex_ExifTool_LargeExif.exif` | the same with a 524300-byte ImageDescription | "EXIF too large to extract as a block" | golden |
| `lex_ExifTool_ORF.tif` | small TIFF, header `IIRO` | ORF identification | golden |
| `lex_ExifTool_DCP.tif` | small TIFF, header `IIRC` | DNG camera profile | golden |
| `lex_ExifTool_HDP2.tif` | small TIFF, header `II\xbc\x02` | HD Photo v2 refused | golden |
| `lex_ExifTool_PanasonicRaw.raw` | small TIFF, header `IIU\0` | Panasonic RAW without RW2 signature | golden |
| `lex_ExifTool_BigTIFF.tif` | `BigTIFF.btf` under a TIFF name | BigTIFF write refused | golden |
| `lex_ExifTool_BlankTrailer.tif` | `ExifTool.tif` + 64 zero bytes | blank trailer deleted | golden |
| `lex_ExifTool_LongTrailer.tif` | `ExifTool.tif` + 65540 zero bytes + 65540 bytes of text | unknown trailer in 64 kB blocks, `-Trailer:all=` | golden |
| `lex_ExifTool_PadTrailer.tif` | small TIFF + pad byte + 25 bytes of text | unknown trailer after padding | golden |
| `lex_ExifTool_AFCPTrailer.tif` | `ExifTool.tif` + the AFCP trailer of `AFCP.jpg`, offset patched | AFCP trailer in a TIFF | golden |
| `lex_ExifTool_EmptyExif.jpg` | `Canon.jpg` with APP1 `Exif\0\0` only | "Multiple APP1 EXIF records" | golden |
| `lex_ExifTool_NoGPS.cr3` | `exiftool -gps:all= CanonRaw.cr3` | CR3 without the GPS box | golden |
| `lex_Photoshop_DigestMeSa.tif` | by hand: 4x4 8-bit gray TIFF, IFD0 IPTC-NAA (int32u, 24 bytes) and PhotoshopSettings (format int8u) holding an 8BIM IPTCDigest that matches, then a `MeSa` resource 0x1f40 | `WritePhotoshop.WritePhotoshop` meeting a non-8BIM resource after the IPTCDigest it rewrites; `-IPTCDigest=new` over the padded IPTC-NAA in `WriteIPTC.WriteIPTC` | golden (`stay/s-iptcdigest`) |
| `lex_Exif_BadFirstFormat.tif` | `ExifTool.tif` with the format of the first IFD0 entry set to 0x33 | "First entry for IFD0 has an invalid format" in `Exif.ProcessExif` | golden (`bounds-v3`) |
| `lex_WriteExif_SamplesPerPixel.tif` | from `ExifTool.tif` by a one-off script: BitsPerSample removed, SamplesPerPixel 2000 | "Invalid SamplesPerPixel" in `WriteExif.ValidateImageData` (validation and writing) | golden (`validate-fx`) |
| `lex_WriteExif_SonyARW.arw` | from `Nikon.nef` by a one-off script: Make `SONY`, the second SubIFD's Compression 32767 | Sony RAW written with the ExifIFD before the SubIFDs in `WriteExif.WriteExif` | golden (`w-arw-order`) |
| `lex_PostScript_DOSTIFF.eps` | by hand: DOS EPS header, 86 bytes PostScript, small TIFF preview | EPS with TIFF preview | golden |

## GIF fixtures

1x1 GIFs assembled block by block for `GIF.ProcessGIF`.

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_GIF_Plain87a.gif` | by hand: GIF87a, image only | creating comment/XMP/ICC blocks, promotion to 89a | golden |
| `lex_GIF_Animated.gif` | by hand: NETSCAPE loop, comments, MIDI extensions, unknown extensions, plain text, two frames, data after the trailer | the read branches of `GIF.ProcessGIF` | golden |
| `lex_GIF_LateXMP.gif` | by hand: XMP after the image, without xpacket trailer | "Duplicate XMP block created" | golden |
| `lex_GIF_UserExt.gif` | by hand: application extensions `LEXTEST1/001`, `LEXTEST2/002`, `LEXTEST3/003` | user-defined GIF extensions | golden |
| `lex_GIF_C2PA.gif` | `GIF.gif` with a `C2PA_GIF` application extension (a minimal JUMBF `c2pa` box) before the comment | C2PA JUMBF deleted from a GIF (`-JUMBF:all=`, `-all=`) | golden (`gif-v3`, `w-gif-c2pa-*`) |
| `lex_GIF_Config/gifext.config` | by hand: Perl data only | defines LexTestText, LexTestPadded, LexTestXMP | golden |
| `lex_GIF_Config/nullbyte.txt` | by hand: `a\0b` | "LexTestPadded contained NULL character" | golden |

## Maker notes, raw formats and other modules

| File | Origin | Covers | Test |
|---|---|---|---|
| `lex_APP12_BadDucky.jpg` | `Writer.jpg` + APP12 Ducky with a too long Comment block | "Invalid Ducky block length" when reading and writing | golden |
| `lex_Jpeg2000_ToEOF.jp2` | by hand from `Jpeg2000.jp2`: unknown boxes, extended-length box, boxes of length 0, oversize child | `Jpeg2000.ProcessJP2`/`ProcessJpeg2000Box` | golden |
| `lex_Jpeg2000_UUID.jp2` | by hand: colr before ihdr, many uuid kinds | uuid boxes read but not written | golden |
| `lex_Jpeg2000_Truncated.jp2` | `Jpeg2000.jp2` without its last 40 bytes | truncated box | golden |
| `lex_Jpeg2000_Codestream.jp2` | `Jpeg2000.j2c` under a JP2 name | J2C branch of `ProcessJP2` | golden |
| `lex_Jpeg2000_Fragmented.jpx` | by hand: `ftbl`/`flst` | fragmented JPX | golden |
| `lex_Jpeg2000_JUMBF.c2pa` | by hand: C2PA JUMBF with flawed description boxes, `json`/`cbor`/`bfdb`/`bidb` | `ProcessJUMD` | golden |
| `lex_Jpeg2000_BrotliCase.jxl` | by hand from `JXL2.jxl`: `brob` boxes `EXIF`/`XML `, small-form `jxlc` | `ProcessBrotli` case check, `ProcessJXLCodestream` | golden |
| `lex_Jpeg2000_BrotliBad.jxl` | by hand: bad offsets, non-Brotli `brob` | Brotli error paths | golden |
| `lex_Jpeg2000_BrotliJUMBF/BrotliJUMBF.jxl` | by hand: Brotli-compressed JUMBF | own directory, so no write variant meets it (Perl warns there) | golden |
| `lex_Jpeg2000_Plain.jxl` | by hand: plain Exif and `xml ` boxes, `jxlp` | uncompressed JXL boxes | golden |
| `lex_JVC_TextUnknown.jpg` | `JVC.jpg` with a minimal EXIF, JVC text maker note with two unknown tags | Unknown branch of `ProcessJVCText` | golden |
| `lex_Pentax_K5.jpg` | `Writer.jpg` image data + EXIF for a K-5 with filters, encrypted ShutterCount, BatteryInfo | write conversions of the Pentax tags | golden |
| `lex_FujiFilm_FaceRec.jpg` | `FujiFilm.jpg` with FaceRecInfo (two faces) | `ProcessFaceRec` | golden |
| `lex_FujiFilm_MRAW.raf` | `FujiFilm.raf` with an M-RAW header and an appended copy | `ProcessMRAW`, M-RAW in `ProcessRAF`/`WriteRAF` | golden |
| `lex_FujiFilm_MRAWLen.raf` | the same, M-RAW header length other than 0x11c | refused by `WriteRAF` | golden |
| `lex_FujiFilm_MRAWLayout.raf` | the same, first raw image not at offset 0 | refused by `WriteRAF` | golden |
| `lex_FujiFilm_PadJunk.raf` | non-null padding byte after the JPEG | minor error when writing | golden |
| `lex_FujiFilm_BadPtr.raf` | directory pointer into the JPEG | bad RAF pointer | golden |
| `lex_FujiFilm_Corrupt.raf` | JPEG offset not a multiple of 4 | corrupt RAF | golden |
| `lex_FujiFilm_Truncated.raf` | JPEG length past the end | truncated RAF | golden |
| `lex_FujiFilm_BadJPEG.raf` | embedded JPEG without SOI | bad embedded JPEG | golden |
| `lex_FujiFilm_Header.raf` | bare 0x80-byte header | RAF without JPEG or directories | golden |
| `lex_NikonSettings_Missing.jpg` | `Nikon.jpg`, Z 7 maker notes with a NikonSettings directory announcing more entries, one unknown format | NikonSettings bounds | golden |
| `lex_NikonSettings_Unused.jpg` | the same with unused space after the entries | NikonSettings unused space | golden |
| `lex_Nikon_ShotInfoZ6III.jpg` | `Writer.jpg` image data + EXIF by a one-off script: Z6_3 maker notes, SerialNumber, ShutterCount, ShotInfo 0809 (firmware 02.00) encrypted with `Nikon::Decrypt`, offsets to a SeqInfo and a MenuSettings block filled with small values | `Nikon.PrepareNikonOffsets` taking the first entry of a conditional list (SequenceOffset, MenuOffset) for the piecewise decryption, `MenuSettingsZ6IIIv2`/`SeqInfoZ6iiiv2` | golden (`canon-nikon-*`) |
| `lex_Canon_AFTrackingR5m2.jpg` | `Writer.jpg` image data + EXIF by a one-off script: EOS R5m2 CameraInfo with a ring of 168-byte AF tracking records (valid ones, an empty slot, two of another layout), CameraSettings for LensType 368 at 85 mm f/1.4, LensModel with ` + RF1.4x` | `Canon.AFTrackingHistory`; the unscaled try with the extender name in `Canon.PrintLensID` | golden (`canon-nikon-*`) |
| `lex_Canon_AFTracking128.jpg` | the same for an EOS R6m2: 128-byte records of the R3 layout (skipped areas, a time that increases), LensType 137 at 85 mm f/1.2, LensModel with ` + 2x` | `Canon.AFTrackingHistory128` layout 0; `Canon.PrintLensID` with an extender without `RF` | golden (`canon-nikon-*`) |
| `lex_Canon_AFTrackingR6.jpg` | the same for an EOS R6: 128-byte records without a fixed first byte, a time gap above 1 s | `Canon.AFTrackingHistory128` layout 1 | golden (`canon-nikon-*`) |
| `lex_Canon_AFTrackingR10.jpg` | the same for an EOS R10: 64-byte records with the raw centre only (one out of range) | `Canon.AFTrackingHistory128` layout 2 | golden (`canon-nikon-*`) |
| `lex_Canon_FirmInfo5DmkIII.jpg` | the same for an EOS 5D Mark III: CameraInfo of pseudo-random bytes without digits, firmware string at 0x242 | `Canon.FindFirmVer` with a lookup (CanonFirm 4 for the Hooks of CameraInfo5DmkIII) | golden (`canon-nikon-*`) |
| `lex_Canon_FirmInfoUnknown.jpg` | the same for an EOS-1D X, firmware string at 0x290 | `Canon.FindFirmVer`: offset not in the lookup, warning, CanonFirm 0 | golden (`canon-nikon-*`) |
| `lex_DJI_Protobuf.mp4` | by a one-off script: MP4 with one `djmd` timed-metadata track, nine samples of the protocols `dvtm_ac204`, `dvtm_ac203`, `dvtm_NEO2`, `dvtm_ac206`, `dvtm_Lito_X1`, `dvtm_wm260`, `dvtm_pm320`, `dvtm_Air3s` (GPS in degrees and radians, a LEN record for an `unsigned` tag) and a truncated one | `DJI.Protobuf` incl. the tags re-used for similar protocols and the `CoordUnits` conditions; `Protobuf.ProcessProtobuf` (protobuf-only formats, numbered sub-tables, unknown-tag prefix, truncation warning) | golden (`dji-*`) |
| `lex_Garmin_DevFields.fit` | by a one-off script: FIT file with two developer data IDs that both define a field `speed`, float32/float64/uint64 developer fields holding the invalid value in turn, and the new Split, SplitSummary, CoursePoint, SensorSettings and GPSEvent fields | developer-field names made unique and the NaN/invalid-value test in `Garmin.ProcessFIT` | golden (`garmin-*`) |
| `lex_XMP_ExifEX31.xmp` | by hand: the Exif 3.1 `exifEX` properties (structures `LearningOptOutIn`, `DevelopmentType`) and a `dc:title` with malformed UTF-8 (lone bytes, an overlong and a surrogate sequence, a truncated character at the end) | `XMP.exifEX`; `XMP.FixUTF8` in the JSON/XML output and when writing | golden (`xmp-exifex-*`, `w-xmp-fixutf8`) |
| `lex_QuickTime_StereoXiaomi.heic` | by a one-off script: HEIC with a 16-byte `ftyp` `mif3`/`heic`, two `hvc1` items grouped by a `grpl` `ster` box, and an `Exif` item in the Android/Xiaomi layout (header length 10, then JPEG APP1 Exif and an APP2 `XMTH` preview) | `ftyp` CompatibleBrand in place of MinorVersion, file type MIF3; `QuickTime.GroupsList`/`StereoImage`; `XiaomiMess` in `QuickTime.HandleItemInfo` (`ProcessJPEG` on the item) | golden (`qt-new-*`) |
| `lex_QuickTime_VideoExt.mp4` | by a one-off script: MP4 with three top-level `skip` atoms (QuickTime atoms `ver `/`tima`, RIFF chunks after 32 bytes, 12 bytes + JPEG), an `hvc1` sample description with `vexu` (`eyes` with `stri`, a `cams` written as a full box, `cmfy`; `proj` with `prji`) and `hfov` followed by 4 spare bytes, track Keys `camera.lens_irisfnumber`, movie Keys `spatial.*`, ItemList `cust`, and an empty `free` and `wide` atom before `mdat` | `QuickTime.SkipInfo` (big- and little-endian), the `skip` list order; `vexu`/`eyes`/`cams`/`cmfy`/`prji`/`hfov`; the "fullbox found" fix-up and the end-4 child search of `ProcessHybrid`; empty atoms under FastScan on a pipe | golden (`qt-new-*`, `s-stdin-qt-fast`) |
| `lex_QuickTime_LigoGPS116.mp4` | by a one-off script: MP4 with a `text` track whose `stsz` claims 200000001 samples, and an unreferenced 32 kB `freeGPS ` block in `mdat` with `LIGOGPSINFO` at offset 116 holding two plain-text records | sample-count limit in `QuickTimeStream.ParseTag`; the offset-116 LIGOGPSINFO branch of `ProcessFreeGPS` (scan of the media data) | golden (`qt-new-*`) |
| `lex_QuickTime_InstX6.mp4` | from `lex_WriteQuickTime_InstBox.mp4`: 4 bytes inserted before the Insta360 trailer inside the `inst` box, as Insta360 X6 files have it | `inst` box ending at the trailer end in `QuickTime.ProcessMOV` (no trailer warning) | golden (`qt-new-*`) |
| `lex_QuickTime_SkipPreview.mov` | by hand: `ftyp`, a `skip` atom of 8 bytes, a 4-byte length and a small JPEG (the DuDuBell M1 layout), `mdat` | `PreviewImage` entry of the `skip` conditional list in `QuickTime.Main`, checked before `Skip` (known deviation, doc/differences.md) | golden |
| `lex_Exif_NRWFromNEF.nef` | from `Nikon.nef`: IFD0 `Compression` set to 6, its `StripOffsets`/`StripByteCounts` turned into `ThumbnailOffset`/`ThumbnailLength` | the NRW recognition in the `ThumbnailOffset` condition of `Exif.Main` (`OverrideFileType` with the MIME type of the type table) | golden (`override-sigma-v3`) |
| `lex_MakerNotes_SigmaVerNL.jpg` | from `Sigma.jpg`: the maker note's byte after `SIGMA\0\0\0` set to 0x0a, the version byte to 3 | `MakerNoteSigmaVer` with a newline byte before the version (`/s` in the Sigma condition of `MakerNotes`) | golden (`override-sigma-v3`), `test_sigma` |
| `lex_WriteQuickTime_SefdOrder.heic` | from `lex_WriteQuickTime_MotionPhoto.heic`: the `mpvd` box replaced by a `free` box of the same size, and a `sefd` box (Samsung SEFT trailer with one `Image_UTC_Data` block) and the `mpvd` box appended after the media data, in that order | WriteLast boxes written in WriteLast order (`mpvd` 1 before `sefd` 2) in `QuickTime.WriteQuickTime` | golden (`w-qt-lastorder`) |
| `lex_Mini_Compressed.avif` | `Mini.avif` rewritten by exiftool 13.64 with `-api Compress=1 -api Compact=all -ForceWrite=xmp` | compressed EXIF/XMP chunks of a `mini` box (Inflate on reading and rewriting, Deflate) | golden (`mini-*`, `w-mini-*`) |
| `lex_Mini_Msf3.avif` | `Mini.avif` with the `ftyp` major brand `msf3` | msf3: not read (`Mini.Process_mini`), not written (`QuickTime.WriteMOV`) | golden (`mini-*`, `w-mini-*`) |
| `lex_Mini_Trailing.avif` | `Mini.avif` with one byte appended to the `mini` box | chunk sizes not adding up: "Unexpected mini box size" on reading, "Format error in mif3 mini box" on writing | golden (`mini-*`, `w-mini-*`) |
| `lex_Red_LargeDir.r3d` | by a one-off script from `Red.r3d`: RED2 header and `rdi` record, then a Red directory of about 3 kB (2048 <= length < 10000) holding the tags new in Red.pm 1.05 (camera position, clip ID, LUT, audio file, ND filter, exposure time, tint, contrast, tone map, lens mount, pipeline, ND stops with two values, sensor size, firmware revision, near/far focus distances incl. infinity, frame rates, focal length) and a 2400-byte format-7 tag | directory length sanity check of `Red.ProcessR3D`; the new `Red.Main` tags and conversions | golden (`red-*`) |
| `lex_Red_XE.r3d` | the same directory without the padding tag, starting with tag 0x10ad (length 0x0f) as in RED XE files, the directory length word set to 0xffff | directory search for `\0\x0f\x10\xad` in `Red.ProcessR3D`, "This R3D file is different" warning | golden (`red-*`) |
| `lex_Jpeg2000_JXLOrient.jxl` | `cjxl` 0.11 (lossless JPEG transcoding) of a 24x16 JPEG with EXIF Orientation 6: container with the codestream split into two `jxlp` boxes, `jbrd`, Brotli `Exif` | `Jpeg2000.ProcessJXLCodestream` as the `JXL` table's proc: Orientation from the codestream, the second `jxlp` box skipped | golden (`j2k-*`, `jxl-n`, `w-j2k-*`) |
| `lex_Jpeg2000_JXLCodestream.jxl` | `cjxl` 0.11 (lossy, `--container=0`) of the same JPEG: bare codestream with Orientation 6 | `Jpeg2000.ProcessJXLCodestream` called from `ProcessJXL`; wrapping for writing | golden (`j2k-*`, `jxl-n`, `w-j2k-*`, `w-jxl-wrap-orient`) |
| `lex_Samsung_STMN.jpg` | by hand: STMN maker notes with a Samsung IFD at tag 11 | Samsung STMN, `-htmlDump` header | golden |
| `lex_Samsung_Type2.jpg` | by hand: type-2 maker notes with EncryptionKey and encrypted tags | Samsung decryption and conversions | golden |
| `lex_Samsung_Trailer.jpg` | by hand: SEFT trailer (QDIO, audio, mpv2, DOFS with a wrong count, unknown block) | Samsung trailer | golden |
| `lex_Samsung_Gallery.jpg` | by hand: junk after SEFT, non-DOFS SingleShotMeta, QDIO of wrong length | Samsung Gallery trailer | golden |
| `lex_Samsung_INFO.mov` | by hand: udta INFO atom, top-level `sefd` with a flawed SEFT | Samsung in QuickTime | golden |
| `lex_RIFF_Tags.wav` | by hand: `fmt `, `fact`, `bext`, `CSET`, INFO, adtl, `smpl`, `inst`, `acid`, ... | RIFF audio chunks and conversions | golden |
| `lex_RIFF_Streams.avi` | by hand: video/audio/text streams, `dmlh`, IDIT forms, second RIFF | RIFF stream headers, Duration | golden |
| `lex_RIFF_Embedded.avi` | by hand: BikeBro `SGLT`/`SLLT`, Lucas `0GPS`/`0GDA`, bad INFO chunk | embedded RIFF data | golden |
| `lex_RIFF_Anim.webp` | by hand: `VP8X`, `ANIM`, `ANMF`, `ALPH`, `EXIF`, `XMP\0`, `VP8 ` | extended WebP | golden |
| `lex_RIFF_Lossless.webp` | by hand: `VP8L` only | lossless WebP | golden |
| `lex_RIFF_Header.ofr` | by hand: OptimFROG header before WAVE | obscure lossless audio branch of `ProcessRIFF` | golden |
| `lex_TNEF_Props.tnef` | by hand: every property type of `ProcessProps`, named properties, LZFu RTF, attachment | TNEF properties | golden |
| `lex_TNEF_RTF.tnef` | by hand: uncompressed, unknown and too short RTF bodies, invalid named property | TNEF RTF branches | golden |
| `lex_Exif_UserCommentBad.jpg` | by hand: UserComment without header, not UTF-8 | copy fails in RawConvInv, old value kept | golden |
| `lex_Olympus_FocusInfoBad.jpg` | by hand: FocusInfo count past the data | patched count carried into a copy | golden |
| `lex_MakerNotes_GE2.jpg` | by hand: GE type 2 maker notes (FujiFilm IFD without count) | `ProcessGE2` count written before rebuild | golden |
| `lex_FLIR_PlanckZero.jpg` | `FLIR.jpg` with PlanckB 0.0 | Composite dies on division by zero, tag not generated | golden |
| `lex_HTML_TotalTime0.htm` | by hand: MS Office HTML, TotalTime 0 | `ConvertTimeSpan` keeps "0" | golden |
| `lex_HTML_TotalTime05.htm` | by hand: TotalTime 0.5 | "30 seconds" | golden |
| `lex_Exif_PSRaw.tif` | by hand: IFD0 tags 0xfde8, 0xfe10, 0xfe11 | Photoshop RAW tag generation in `Exif.ProcessExif` | golden |
| `lex_XMP_ListLimit.xmp` | by hand: 1005 `dc:subject` items, empty elements with raw attributes, comment-only element | `XMP.ParseXMPElement` list limit and empty values | golden |
| `lex_Google_HDRPRaw.xmp` | by hand: three HDRP maker notes, payloads plain, zlib and bad gzip | gunzip step of `Google.ProcessHDRP` | golden |
| `lex_Ricoh_RMETA.jpg` | by hand: seven APP5 RMETA segments | `Ricoh.ProcessRicohRMETA` | golden |
| `lex_ZIP_EPUB.epub` | by hand: EPUB with OPF dates and thumbnail | EPUB in `ZIP.ProcessZIP` | golden |
| `lex_ZIP_Sketch.zip` | by hand: two `mimetype` members, Sketch `meta.json` | unrecognized MIME type, SKETCH | golden |
| `lex_ZIP_Stream.docx` | by hand: local headers only, stream-mode member | ZIP processed by hand after a format error | golden |
| `lex_M2TS_Cut.ts` | ffmpeg (libx264, ac3), first 100 bytes cut off | sync search, PES continuation, backward PCR scan in `M2TS.ProcessM2TS` | golden |
| `lex_PLIST_Binary.plist` | by hand: `bplist00` with every object type | `PLIST.ExtractObject` | golden |
| `lex_PCAP_NetMon.cap` | by hand: Network Monitor 2.0 header with comment | CAP branch of `PCAP.ProcessPCAP` | golden |
| `lex_FLIF_PlainXMP.flif` | by hand: 16x16 FLIF with uncompressed `eXmp` | transparent rawinflate in `FLIF.ProcessFLIF`/`WriteFLIF` | golden |
| `lex_FLIF_LongVarInt.flif` | by hand: FLIF header whose image width is a varint of 12 bytes, then the height and the image chunk byte | `FLIF.GetVarInt` giving up after 10 bytes | golden (`bounds-v3`) |
| `lex_FLIF_LongChunkSize.flif` | by hand: FLIF header, an `eXmp` chunk whose size is a varint of more than 10 bytes | the undefined chunk size in `FLIF.ProcessFLIF` ("Truncated FLIF eXmp chunk") | golden (`bounds-v3`) |
| `lex_PGF_DeepNesting.pgf` | by hand: PGF headers, each one's thumbnail another PGF, 15 levels | "PGF nesting too deep" in `PGF.ProcessPGF` | golden (`bounds-v3`) |
| `lex_M2TS_Sync47.mts` | from `M2TS.mts`: its 7 packets three times, with timecodes whose fourth byte is 0x47 in the first four packets | the sync-byte check of `M2TS.ProcessM2TS` (timecode length) | golden (`m2ts-sync-v3`) |
| `lex_M2TS_MidPacket.mts` | the same packets with plain timecodes, the first 5 bytes (timecode and sync byte) cut off | "File doesn't begin with the start of a packet" | golden (`m2ts-sync-v3`) |
| `lex_M2TS_Garbage.m2t` | the same packets without timecodes after 100 bytes of zeros with a 0x47 at offset 5, and one 188 bytes later in the first packet's stuffing | the sync-byte search trying every 0x47 of the first 192 bytes | golden (`m2ts-sync-v3`) |
| `lex_PDF_XrefLax.pdf` | `PDF.pdf` with the second xref entry written `9 0 n` and padded with spaces (short numbers, more than one space) | the lax xref entry format in `PDF.ReadPDF` | golden |
| `lex_PDF_XrefJunk.pdf` | `PDF.pdf` with an `X` right after the second xref entry's `n` | "Invalid xref table" in `PDF.ReadPDF` | golden |
| `lex_Pentax_ImageToneGRIV.jpg` | `Pentax.jpg` with ImageTone written as 33024 by exiftool (`-n -Pentax:ImageTone=33024`) | ImageTone 33024 of the GR IV Monochrome (known deviation, doc/differences.md) | golden (`pentax-imagetone`) |
| `lex_QuickTime_SigmaPreview.mov` | `QuickTime.mov` + `udta` with a Sigma `SIGM` atom holding `Canon.jpg` | `PreviewImage` conversion, re-entrant `ExtractInfo` (`-ee`) | golden |

`lex_M2TS_Cut.ts` depends on the ffmpeg and x264 versions that made it; the
file is the reference.
