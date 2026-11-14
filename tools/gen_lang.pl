#!/usr/bin/perl
#------------------------------------------------------------------------------
# File:         tools/gen_lang.pl
#
# Description:  Generates src/lexiftool/Lang/*.lua -- the translation tables
#               behind -lang -- from the vendored Image::ExifTool::Lang::*.pm.
#
#               Why Perl and not Lua: the upstream Lang modules are themselves
#               machine-generated Perl source (see the Notes: line in each of
#               their banners), and the authority on what %Translate contains
#               is the Perl interpreter, not a hand-written parser.  This
#               script `require`s each module and dumps the hash that
#               Image::ExifTool would have used, so no Perl quoting, escaping
#               or continuation rule has to be re-implemented -- and a Lua-side
#               parser of Perl syntax could only ever approximate them.
#
#               The output layout mirrors Image::ExifTool::TagInfoXML's
#               WriteLangModule line for line: same key order (`sort keys`,
#               i.e. Perl's byte-wise string sort, which Lua's table.sort on
#               strings matches), same indentation steps (3 / 6 / 8 / 6 / 4
#               columns -- unusual, but they are upstream's), same one entry
#               per line.  Laid side by side, de.pm and de.lua have the same
#               structure on the same lines.
#
#               Escaping is EscapePerl's, copied from TagInfoXML: backslash
#               and single quote are the only escapes, and both mean the same
#               thing inside a Lua single-quoted string, so the escaped text
#               is byte-identical to the .pm's.  Every other byte is passed
#               through verbatim, which keeps UTF-8 intact; bytes that a Lua
#               literal cannot carry (newline, CR, NUL) are a hard error
#               rather than a silent re-encoding.
#
#               Deterministic: no timestamps, no hash order, no version
#               numbers -- running it twice produces byte-identical files.
#
# Usage:        perl tools/gen_lang.pl            # regenerate all languages
#               perl tools/gen_lang.pl de fr      # regenerate a subset
#------------------------------------------------------------------------------

use strict;
use warnings;

my $repoDir = $0;
$repoDir =~ s{[/\\][^/\\]+$}{} or $repoDir = '.';
$repoDir .= '/..';

my $vendorLib = "$repoDir/vendor/exiftool/lib";
my $langDirPm = "$vendorLib/Image/ExifTool/Lang";
my $langDirLua = "$repoDir/src/lexiftool/Lang";

unshift @INC, $vendorLib;
require Image::ExifTool;

# the port note carried by every generated module (see doc/conventions.md §10)
my @portNotes = (
    'mechanically generated from the vendored %Translate hash by',
    'tools/gen_lang.pl, which requires the .pm and dumps the hash',
    'as Lua table syntax -- same class of mechanical port as the',
    'DICOM/Qualcomm tag tables.  String entries',
    'are a bare Description translation; table entries carry a',
    'Description and/or a PrintConv value->value map, same shape as',
    'upstream.',
    '',
    'Entry order, indentation and line breaks are the .pm\'s own, so',
    'the two files can be read side by side: every line of this',
    'table has the same content on the same line of the .pm.  (The',
    'odd indentation steps -- 3 / 6 / 8 columns -- come from',
    'upstream\'s own generator, and so does the key order, except',
    'where a later hand-edit left an entry out of sort order there.)',
    '',
    'Regenerate by re-running the generator against a newer .pm',
    'rather than hand-editing.',
);

#------------------------------------------------------------------------------
# Escape a string for a single-quoted literal (TagInfoXML::EscapePerl; a Lua
# single-quoted string understands \\ and \' with the same meaning)
sub EscapePerl
{
    my $str = shift;
    $str =~ s/\\/\\\\/g;
    $str =~ s/'/\\'/g;
    return $str;
}

#------------------------------------------------------------------------------
# Die on any byte a Lua string literal cannot carry verbatim
# Inputs: 0) string, 1) context for the error message
sub CheckLiteral
{
    my ($str, $what) = @_;
    return unless $str =~ /([\x00\x0a\x0d])/;
    my $bad = sprintf('\\x%02x', ord $1);
    die "$what contains $bad, which a Lua literal cannot carry verbatim\n";
}

#------------------------------------------------------------------------------
# Read the upstream banner and re-emit it as the Lua banner
# Inputs: 0) .pm path, 1) src-relative Lua path, 2) vendor-relative .pm path
# Returns: banner text
sub Banner
{
    my ($pmPath, $luaBase, $portedFrom) = @_;
    open my $fh, '<', $pmPath or die "Error reading $pmPath\n";
    my @banner;
    my $seps = 0;
    while (<$fh>) {
        s/\r?\n$//;
        push @banner, $_;
        ++$seps if /^#-{10,}$/;
        last if $seps == 2;
    }
    close $fh;
    $seps == 2 or die "No banner found in $pmPath\n";
    my @out;
    foreach (@banner) {
        my $line = $_;
        $line =~ s/^#/--/;
        if ($line =~ s/File:         \S+/File:         $luaBase/) {
            push @out, $line;
            push @out, "-- Ported from:  $portedFrom";
            next;
        }
        push @out, $line;
    }
    # insert our Port notes: section before the closing separator
    my $sep = pop @out;
    push @out, '--';
    my $label = '-- Port notes:   ';
    foreach my $note (@portNotes) {
        push @out, length($note) ? "$label$note" : '--';
        $label = '--               ';
    }
    push @out, $sep;
    return join("\n", @out) . "\n";
}

#------------------------------------------------------------------------------
# Scan a single-quoted Perl string
# Inputs: 0) line, 1) offset of the opening quote
# Returns: (unescaped string, offset just past the closing quote), or ()
sub ScanQuoted
{
    my ($line, $pos) = @_;
    return () unless substr($line, $pos, 1) eq "'";
    my $str = '';
    my $i = $pos + 1;
    while ($i < length $line) {
        my $ch = substr($line, $i, 1);
        if ($ch eq '\\') {
            $str .= substr($line, $i + 1, 1);
            $i += 2;
        } elsif ($ch eq "'") {
            return ($str, $i + 1);
        } else {
            $str .= $ch;
            ++$i;
        }
    }
    return ();
}

#------------------------------------------------------------------------------
# Read the entry order of an upstream Lang module from its source text
#
# The .pm is machine-generated by WriteLangModule, which emits `sort keys` --
# but several modules carry later hand-edits whose lines sit out of that order
# (de.pm's AdvancedSceneMode, fr.pm's Backlight, cs/zh_cn's WhiteBalance, ...).
# Re-sorting here would silently move those lines and break the line-for-line
# correspondence with the .pm, so the order is read off the file instead.  Only
# the *order* comes from this parse; every string still comes from the loaded
# hash, and the two key sets are cross-checked below, so a parse that went
# wrong can only fail loudly, never corrupt data.
#
# Inputs: 0) .pm path, 1) language code
# Returns: array of { tag, desc (bool), conv (ordered key list or undef) }
sub ParseOrder
{
    my ($pmPath, $lang) = @_;
    open my $fh, '<', $pmPath or die "Error reading $pmPath\n";
    binmode $fh;
    my (@order, $on, $entry, $conv);
    while (<$fh>) {
        s/\r?\n$//;
        unless ($on) {
            $on = 1 if /^%Image::ExifTool::Lang::\Q$lang\E::Translate = \($/;
            next;
        }
        last if /^\);/;
        if (/^   '/) {
            my ($tag, $end) = ScanQuoted($_, 3);
            defined $tag or die "$lang: cannot parse tag on: $_\n";
            substr($_, $end, 4) eq ' => ' or die "$lang: cannot parse tag on: $_\n";
            $entry = { tag => $tag, desc => 0, conv => undef };
            push @order, $entry;
            $conv = undef;
        } elsif (/^      Description => /) {
            $entry or die "$lang: stray Description on: $_\n";
            $$entry{desc} = 1;
        } elsif (/^      PrintConv => \{$/) {
            $entry or die "$lang: stray PrintConv on: $_\n";
            $conv = $$entry{conv} = [];
        } elsif (/^        '/) {
            $conv or die "$lang: stray PrintConv entry on: $_\n";
            my ($key, $end) = ScanQuoted($_, 8);
            defined $key or die "$lang: cannot parse PrintConv key on: $_\n";
            substr($_, $end, 4) eq ' => ' or die "$lang: cannot parse PrintConv key on: $_\n";
            push @$conv, $key;
        } elsif (/^      \},$/) {
            $conv = undef;
        } elsif (/^    \},$/) {
            $entry = undef;
        } else {
            die "$lang: unexpected line in \%Translate: $_\n";
        }
    }
    close $fh;
    $on or die "$lang: \%Translate not found in $pmPath\n";
    @order or die "$lang: \%Translate is empty in $pmPath\n";
    return @order;
}

#------------------------------------------------------------------------------
# Write one src/lexiftool/Lang/$lang.lua
# Inputs: 0) language code
sub WriteLangModule
{
    my $lang = shift;
    my $pmPath = "$langDirPm/$lang.pm";
    -e $pmPath or die "No such language module: $pmPath\n";
    eval "require Image::ExifTool::Lang::$lang" or die "Can't load Lang::$lang\n";
    my $xlat = "Image::ExifTool::Lang::${lang}::Translate";
    no strict 'refs';
    my $langTags = \%$xlat;
    use strict 'refs';
    %$langTags or die "Missing Info for $lang\n";

    my $out = "$langDirLua/$lang.lua";
    my $tmp = "$out.tmp";
    open my $fh, '>', $tmp or die "Error creating $tmp\n";
    binmode $fh;
    print $fh Banner($pmPath, "lexiftool/Lang/$lang.lua",
                     "lib/Image/ExifTool/Lang/$lang.pm");
    print $fh "\nlocal Translate = {\n";
    # loop through all tag and table names, in the .pm's own order (see
    # ParseOrder); the strings come from the loaded hash, never from the parse
    my @order = ParseOrder($pmPath, $lang);
    @order == keys %$langTags
        or die sprintf("%s: %d entries in the .pm text, %d in %%Translate\n",
                       $lang, scalar(@order), scalar(keys %$langTags));
    my ($tag, $count) = (undef, 0);
    foreach my $entry (@order) {
        $tag = $$entry{tag};
        exists $$langTags{$tag} or die "$lang: '$tag' is not in %Translate\n";
        my $val = $$langTags{$tag};
        my ($desc, $conv);
        if (ref $val) {
            $desc = $$val{Description};
            $conv = $$val{PrintConv};
        } else {
            $desc = $val;
        }
        # what the parse saw and what the hash holds must agree
        (defined $desc ? 1 : 0) == (ref $val ? $$entry{desc} : 1)
            or die "$lang: '$tag' Description disagrees with the .pm text\n";
        (defined $conv ? 1 : 0) == ($$entry{conv} ? 1 : 0)
            or die "$lang: '$tag' PrintConv disagrees with the .pm text\n";
        if ($conv) {
            @{$$entry{conv}} == keys %$conv
                or die "$lang: '$tag' PrintConv key count disagrees with the .pm text\n";
        }
        CheckLiteral($tag, "$lang: tag name");
        $tag =~ /'|\\/ and die "$lang: tag name '$tag' needs escaping\n";
        if (defined $desc) {
            CheckLiteral($desc, "$lang: description of '$tag'");
            $desc = EscapePerl($desc);
        }
        ++$count;
        print $fh "   ['${tag}'] = ";
        unless ($$entry{conv}) {
            print $fh "'${desc}',\n";
            next;
        }
        print $fh "{\n";
        print $fh "      Description = '${desc}',\n" if defined $desc;
        print $fh "      PrintConv = {\n";
        foreach (@{$$entry{conv}}) {
            exists $$conv{$_} or die "$lang: '$tag' has no PrintConv key '$_'\n";
            CheckLiteral($_, "$lang: PrintConv key of '$tag'");
            CheckLiteral($$conv{$_}, "$lang: PrintConv value of '$tag'");
            my $str = EscapePerl($_);
            my $cvt = EscapePerl($$conv{$_});
            print $fh "        ['${str}'] = '${cvt}',\n";
        }
        print $fh "      },\n";
        print $fh "    },\n";
    }
    print $fh "}\n\nreturn Translate\n";
    close $fh or die "Error writing $tmp\n";
    rename($tmp, $out) or die "Error renaming $tmp\n";
    printf "  %-6s %5d entries -> src/lexiftool/Lang/%s.lua\n", $lang, $count, $lang;
}

#------------------------------------------------------------------------------
my @langs = @ARGV;
unless (@langs) {
    # (the two package variables are read once, which `use warnings` would
    #  otherwise flag as a possible typo)
    no warnings 'once';
    @langs = grep { $_ ne $Image::ExifTool::defaultLang } @Image::ExifTool::langs;
}
-d $langDirLua or mkdir $langDirLua or die "Error creating $langDirLua\n";
WriteLangModule($_) foreach @langs;
