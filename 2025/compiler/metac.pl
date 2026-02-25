#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use File::Path qw(make_path);

use MetaC::Codegen qw(compile_source_with_hir_dump);

sub usage {
    print STDERR "Usage: perl compiler/metac.pl <source.metac> -o <output.c>\n";
    exit 1;
}

sub main {
    my $output_path;
    my $hir_dump_path;
    GetOptions(
        'o|output=s' => \$output_path,
        'dump-hir=s' => \$hir_dump_path,
    ) or usage();

    my $source_path = shift @ARGV;
    usage() if !defined $source_path || !defined $output_path;

    open my $in, '<', $source_path
      or die "io error: unable to read '$source_path': $!\n";
    local $/ = undef;
    my $source_text = <$in>;
    close $in;

    my ($c_code, $hir_dump) = compile_source_with_hir_dump($source_text);

    my $out_dir = dirname($output_path);
    make_path($out_dir) if $out_dir ne '' && !-d $out_dir;

    open my $out, '>', $output_path
      or die "io error: unable to write '$output_path': $!\n";
    print {$out} $c_code;
    close $out;

    if (defined $hir_dump_path) {
        my $hir_dir = dirname($hir_dump_path);
        make_path($hir_dir) if $hir_dir ne '' && !-d $hir_dir;
        open my $hir_out, '>', $hir_dump_path
          or die "io error: unable to write '$hir_dump_path': $!\n";
        print {$hir_out} $hir_dump;
        close $hir_out;
    }
}

eval { main(); 1 } or do {
    my $err = $@;
    print STDERR $err;
    exit 2;
};
