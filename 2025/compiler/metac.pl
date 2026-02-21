#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use File::Path qw(make_path);

use MetaC::Codegen qw(compile_source);

sub usage {
    print STDERR "Usage: perl compiler/metac.pl <source.metac> -o <output.c>\n";
    exit 1;
}

sub main {
    my $output_path;
    GetOptions('o|output=s' => \$output_path) or usage();

    my $source_path = shift @ARGV;
    usage() if !defined $source_path || !defined $output_path;

    open my $in, '<', $source_path
      or die "io error: unable to read '$source_path': $!\n";
    local $/ = undef;
    my $source_text = <$in>;
    close $in;

    my $c_code = compile_source($source_text);

    my $out_dir = dirname($output_path);
    make_path($out_dir) if $out_dir ne '' && !-d $out_dir;

    open my $out, '>', $output_path
      or die "io error: unable to write '$output_path': $!\n";
    print {$out} $c_code;
    close $out;
}

eval { main(); 1 } or do {
    my $err = $@;
    print STDERR $err;
    exit 2;
};
