#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json);
use File::Spec;

my ($json_path, $csv_path, $root) = @ARGV;
die "Usage: photo-index-format.pl INPUT.json OUTPUT.csv ROOT\n" unless defined $root;

open my $json_fh, '<:raw', $json_path or die "Cannot read metadata data: $!\n";
local $/;
my $json = <$json_fh>;
close $json_fh;

my $rows = eval { decode_json($json) };
die "Cannot understand metadata data: $@\n" if $@ || ref($rows) ne 'ARRAY';
exit 4 unless @$rows;

open my $csv_fh, '>:encoding(UTF-8)', $csv_path or die "Cannot write CSV: $!\n";
print {$csv_fh} "\x{FEFF}"; # UTF-8 marker for Excel.

my @headers = (
  'File name', 'Relative folder', 'Relative path', 'Caption', 'Alt text',
  'Extended description', 'Headline', 'Keywords', 'Photographer / creator',
  'Credit', 'Copyright', 'Date created', 'File modified', 'File type',
  'Width (pixels)', 'Height (pixels)', 'File size (bytes)'
);
write_csv_row($csv_fh, @headers);

for my $item (@$rows) {
  next unless ref($item) eq 'HASH';
  my $full_path = scalar_value($item->{'SourceFile'});
  my $file_name = first_value($item, 'System:FileName', 'File:FileName');
  my $folder = first_value($item, 'System:Directory');
  my $relative_folder = File::Spec->abs2rel($folder, $root);
  $relative_folder = '' if $relative_folder eq '.';
  my $relative = File::Spec->abs2rel($full_path, $root);

  write_csv_row(
    $csv_fh,
    $file_name,
    $relative_folder,
    $relative,
    first_value($item, 'IPTC:Caption-Abstract', 'XMP-dc:Description',
      'IFD0:ImageDescription', 'ExifIFD:ImageDescription'),
    first_value($item, 'XMP-iptcCore:AltTextAccessibility'),
    first_value($item, 'XMP-iptcCore:ExtDescrAccessibility'),
    first_value($item, 'IPTC:Headline', 'XMP-photoshop:Headline'),
    keyword_values($item->{'XMP-dc:Subject'}, $item->{'IPTC:Keywords'}),
    first_value($item, 'IPTC:By-line', 'XMP-dc:Creator',
      'IFD0:Artist', 'ExifIFD:Artist'),
    first_value($item, 'IPTC:Credit', 'XMP-photoshop:Credit'),
    first_value($item, 'IPTC:CopyrightNotice', 'XMP-dc:Rights'),
    first_value($item, 'ExifIFD:DateTimeOriginal', 'IFD0:DateTimeOriginal',
      'IPTC:DateCreated', 'XMP-photoshop:DateCreated'),
    first_value($item, 'System:FileModifyDate'),
    first_value($item, 'File:FileType'),
    first_value($item, 'File:ImageWidth', 'EXIF:ExifImageWidth'),
    first_value($item, 'File:ImageHeight', 'EXIF:ExifImageHeight'),
    first_value($item, 'System:FileSize')
  );
}
close $csv_fh or die "Cannot finish CSV: $!\n";
print scalar(@$rows), "\n";

sub scalar_value {
  my ($value) = @_;
  return '' unless defined $value;
  return join('; ', map { scalar_value($_) } @$value) if ref($value) eq 'ARRAY';
  return '' if ref($value);
  return "$value";
}

sub first_value {
  my ($item, @keys) = @_;
  for my $key (@keys) {
    my $value = scalar_value($item->{$key});
    return $value if $value ne '';
  }
  return '';
}

sub keyword_values {
  my ($xmp, $iptc) = @_;
  # Prefer XMP when present. Exporters often copy the same keywords to IPTC,
  # but IPTC may arrive as one comma-delimited string and cannot be merged
  # reliably without breaking a real keyword such as "Austin, Texas".
  my @inputs = scalar_value($xmp) ne '' ? ($xmp) : ($iptc);
  my (@values, %seen);
  for my $input (@inputs) {
    my @parts = ref($input) eq 'ARRAY' ? @$input : (scalar_value($input));
    for my $part (@parts) {
      next unless defined $part;
      for my $value (split /\s*;\s*/, "$part") {
        next if $value eq '';
        my $key = lc $value;
        next if $seen{$key}++;
        push @values, $value;
      }
    }
  }
  return join('; ', @values);
}

sub spreadsheet_safe {
  my ($value) = @_;
  $value = scalar_value($value);
  # Spreadsheet programs may run values beginning with these characters as formulas.
  $value = "'" . $value if $value =~ /^\s*[=+\-@]/;
  return $value;
}

sub write_csv_row {
  my ($fh, @values) = @_;
  my @escaped;
  for my $value (@values) {
    $value = spreadsheet_safe($value);
    $value =~ s/"/""/g;
    push @escaped, '"' . $value . '"';
  }
  print {$fh} join(',', @escaped), "\r\n";
}

