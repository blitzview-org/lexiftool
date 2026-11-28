# Benchmark images: ordinary camera and phone JPEGs

The files of the `session-jpeg` case of `tools/bench_cli.sh`
([doc/benchmark.md](../../doc/benchmark.md)): one JPEG per maker as a
camera or phone writes it -- EXIF with maker notes, a thumbnail, for some
makers a preview in the maker notes -- around a small synthetic picture.

**Generated, not photographed.** `tools/gen_bench_images.sh` builds them
(the exact commands are in its header): the picture is a plain gradient
(ImageMagick 7, 1000x750, quality 90), the metadata is copied with the
vendored Perl exiftool (`-all= -TagsFromFile SRC -all:all -unsafe`) from one
of ExifTool's test images, then a 160x120 thumbnail and, where the maker
notes can hold one, a 640x480 preview are written. The script gives the same
bytes again for the same ImageMagick and exiftool versions.

| File | Source (`vendor/exiftool/t/images/`) | Camera | Preview | Bytes |
|---|---|---|---|---:|
| `bench_Canon1DmkIII.jpg` | `Canon1DmkIII.jpg` | Canon EOS-1D Mark III | -- | 24365 |
| `bench_NikonD70.jpg` | `NikonD70.jpg` | Nikon D70 | PreviewIFD | 26307 |
| `bench_Sony.jpg` | `Sony.jpg` | Sony DSC-F828 | -- | 19571 |
| `bench_OlympusE1.jpg` | `OlympusE1.jpg` | Olympus E-1 | Olympus maker notes | 30565 |
| `bench_Panasonic.jpg` | `Panasonic.jpg` | Panasonic DMC-FZ3 | -- | 23873 |
| `bench_FujiFilm.jpg` | `FujiFilm.jpg` | FujiFilm FinePix 2400 Zoom | -- | 18145 |
| `bench_Pentax.jpg` | `Pentax.jpg` | Pentax K10D | Pentax maker notes | 26051 |
| `bench_Apple.jpg` | `Apple.jpg` | iPhone 7 | -- | 19163 |

What the copy changes against the source (`exiftool -G1 -a -s`, File,
System, Composite and the thumbnail/preview tags left aside): all maker
note tags arrive; the placeholder thumbnails and previews of a few bytes in
the sources are replaced by the new ones; `IFD1:YCbCrPositioning` is missing
in the Nikon D70, Panasonic and FujiFilm files; Canon's
`OriginalDecisionDataOffset` is 0 (the data it points to is not copied);
the JFIF segment of the Nikon D70 and Pentax sources is written as version
1.02; the Apple file gains `GPS:GPSVersionID`.

License: the metadata comes from the test images of Image::ExifTool
(Copyright Phil Harvey, the same terms as Perl itself: Artistic-1.0-Perl OR
GPL-1.0-or-later), see LICENSE-THIRD-PARTY; the pictures are generated.
