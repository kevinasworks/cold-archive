# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
# Complement the text report with typed binary metadata, never blanket -b output.
use strict;
use warnings;
use Image::ExifTool;
use Image::ExifTool::MacOS;
{ no warnings 'redefine'; *Image::ExifTool::MacOS::ExtractMDItemTags = sub ($$) { return; }; }
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha256_hex);
my $et=Image::ExifTool->new;
$et->Options(Unknown=>2, Binary=>1, Duplicates=>1, ExtractEmbedded=>3,
             RequestAll=>3, LargeFileSupport=>1, Struct=>1, SaveFormat=>1, SavePath=>1);
$et->ExtractInfo($ARGV[0]);
my @fields;
my @values;
sub safe_value {
    my ($v)=@_;
    return { status=>'binary_nested_in_structure', bytes=>length($$v) } if ref($v) eq 'SCALAR';
    return [map { safe_value($_) } @$v] if ref($v) eq 'ARRAY';
    return {map { $_=>safe_value($v->{$_}) } keys %$v} if ref($v) eq 'HASH';
    return "$v" if ref($v);
    return $v;
}
for my $tag ($et->GetFoundTags()) {
    my $v=$et->GetValue($tag,'ValueConv');
    if (ref($v) ne 'SCALAR') {
        push @values, {tag=>$tag, group=>$et->GetGroup($tag,1),
            document=>$et->GetGroup($tag,3), instance=>$et->GetGroup($tag,4),
            path=>$et->GetGroup($tag,5), format=>$et->GetGroup($tag,6),
            raw_value=>safe_value($et->GetValue($tag,'Raw')),
            value=>safe_value($v), display_value=>safe_value($et->GetValue($tag,'PrintConv'))};
        next;
    }
    my $group=$et->GetGroup($tag,1);
    my $category=$et->GetGroup($tag,2);
    my $name=$tag; $name =~ s/ \(\d+\)$//;
    my %field=(tag=>$tag, group=>$group, category=>$category,
               document=>$et->GetGroup($tag,3), instance=>$et->GetGroup($tag,4),
               path=>$et->GetGroup($tag,5), format=>$et->GetGroup($tag,6), bytes=>length($$v));
    # This policy is deliberately explicit: an unknown blob isn't assumed metadata.
    if ($category eq 'Preview' or $name =~ /(?:ThumbnailImage|PreviewImage|JpgFromRaw|OtherImage|RawThermalImage|RawImage|EmbeddedVideo|AudioData|ImageData|DepthMap|GainMapImage|PixelData|FloatPixelData|DoubleFloatPixelData|WaveformData|EncapsulatedDocument)$/) {
        $field{status}='content_payload_omitted';
    } elsif ($name =~ /Unknown|Undefined|DataDump/ or $category eq 'Unknown') {
        $field{status}='unclassified_binary';
        $field{sha256}=sha256_hex($$v);
    } elsif ($category =~ /^(Camera|Location|Time|Author|Printing)$/ or $name =~ /^(ICC_Profile|XMP|IPTC|DeviceSettingDescription|AEMatrix|Palette|XAttrProvenance)$/) {
        $field{status}='binary_metadata_retained';
        $field{encoding}='base64';
        $field{data}=encode_base64($$v,'');
        $field{sha256}=sha256_hex($$v);
    }
    unless ($field{status}) {
        $field{status}='unclassified_binary';
        $field{sha256}=sha256_hex($$v);
    }
    push @fields, \%field;
}
print JSON::PP->new->utf8->canonical->encode({fields=>\@fields, values=>\@values, policy=>'typed-binary-v1',
    warnings=>[$et->GetValue('Warning')], errors=>[$et->GetValue('Error')]});
