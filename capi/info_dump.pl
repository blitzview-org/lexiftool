#!/usr/bin/perl
#------------------------------------------------------------------------------
# File:         capi/info_dump.pl
#
# Description:  Reference for the C API's lexiftool_image_info: reads the
#               tags of files through Perl's Image::ExifTool (the vendored
#               upstream library) with the calls lexiftool_image_info makes
#               in the session's Lua state -- one ExifTool object for all
#               files, Options, ImageInfo with the tag list, then per found
#               tag GetTagName, GetGroup (families 0, 1, 2 and 4),
#               GetDescription, GetTagID and GetValue(ValueConv) -- and
#               prints them in the format of capi/example.c (see there), so
#               that `diff` compares the two.
#
#               Usage: info_dump.pl [-b] [-o OPTION=VALUE]... [-t TAG]... FILE...
#------------------------------------------------------------------------------

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../vendor/exiftool/lib";
use Image::ExifTool;

my $et = Image::ExifTool->new;
my ($binary, @tags, @files);
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '-b') {
        $binary = 1;
    } elsif ($a eq '-t' and @ARGV) {
        push @tags, shift @ARGV;
    } elsif ($a eq '-o' and @ARGV) {
        my ($name, $val) = split /=/, shift(@ARGV), 2;
        $et->Options($name => $val);
    } else {
        push @files, $a;
    }
}
binmode STDOUT;

sub Escaped($)
{
    my $s = shift;
    $s =~ s/([\\\t\n\r]|[\x00-\x1f\x7f])/
        $1 eq '\\' ? '\\\\' : $1 eq "\t" ? '\\t' : $1 eq "\n" ? '\\n' :
        $1 eq "\r" ? '\\r' : sprintf('\\x%02x', ord $1)/ge;
    return $s;
}

sub Value($$)
{
    my ($s, $kind) = @_;
    return Escaped($s) unless $kind == 2;
    my $h = 2166136261;
    $h = (($h ^ $_) * 16777619) & 0xffffffff foreach unpack 'C*', $s;
    return sprintf('data:%d:%08x', length $s, $h);
}

# a value as lexiftool_image_info delivers it: text, binary kind, length
sub ValueOf($$);
sub ValueOf($$)
{
    my ($val, $wantBin) = @_;
    if (ref $val eq 'SCALAR') {
        my $data = $$val;
        if ($data =~ /^Binary data (\d+) bytes$/) {
            return ("($data, use -b option to extract)", 1, $1 + 0);
        } elsif ($wantBin) {
            return ($data, 2, length $data);
        }
        return ('(Binary data ' . length($data) . ' bytes, use -b option to extract)', 1, length $data);
    } elsif (ref $val eq 'ARRAY') {
        my @items = map { (ValueOf($_, $wantBin))[0] } @$val;
        return (join($et->Options('ListSep'), @items), 0, 0);
    } elsif (ref $val eq 'HASH') {
        require 'Image/ExifTool/XMPStruct.pl';
        return (Image::ExifTool::XMP::SerializeStruct($et, $val), 0, 0);
    }
    return ("$val", 0, 0);
}

foreach my $file (@files) {
    my @found = @tags;
    my $info = $binary ? $et->ImageInfo($file, \@found, { Binary => 1 })
                       : $et->ImageInfo($file, \@found);
    my $req = $$et{REQ_TAG_LOOKUP} || { };
    my (@lines, $error, $warning);
    foreach my $key (@found) {
        my $val = $$info{$key};
        next unless defined $val;
        my $name = Image::ExifTool::GetTagName($key);
        my $wantBin = ($binary or defined $$req{lc $name});
        my ($value, $kind, $len) = ValueOf($val, $wantBin);
        my $num = $et->GetValue($key, 'ValueConv');
        $num = defined $num ? (ValueOf($num, $wantBin))[0] : $value;
        my $copy = $et->GetGroup($key, 4);
        $copy = $copy =~ /^Copy(\d+)$/ ? $1 : 0;
        my @g = map { $et->GetGroup($key, $_) } 0, 1, 2;
        my $id = $et->GetTagID($key);
        if ($g[0] eq 'ExifTool') {
            if (not defined $error and $name eq 'Error') {
                $error = $value;
            } elsif (not defined $warning and $name eq 'Warning') {
                $warning = $value;
            }
        }
        push @lines, join("\t", $name, @g, Escaped($et->GetDescription($key)),
            Escaped("$id"), $copy, $kind, $len, Value($value, $kind), Value($num, $kind)) . "\n";
    }
    print "== $file\n# ", scalar(@lines), ' tags';
    print ', error ', Escaped($error) if defined $error;
    print ', warning ', Escaped($warning) if defined $warning;
    print "\n", @lines;
}
