#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Temp qw(tempfile);

sub slurp_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "io error: unable to read '$path': $!\n";
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub run_cmd {
    my (%args) = @_;
    my $cmd = $args{cmd};
    my $stdin_text = defined($args{stdin}) ? $args{stdin} : '';

    my ($in_fh, $in_path) = tempfile();
    print {$in_fh} $stdin_text;
    close $in_fh;

    my ($out_fh, $out_path) = tempfile();
    close $out_fh;

    my ($err_fh, $err_path) = tempfile();
    close $err_fh;

    my $pid = fork();
    die "fork failed: $!\n" if !defined $pid;

    if ($pid == 0) {
        open STDIN, '<', $in_path or die "stdin redirect failed: $!\n";
        open STDOUT, '>', $out_path or die "stdout redirect failed: $!\n";
        open STDERR, '>', $err_path or die "stderr redirect failed: $!\n";
        exec { $cmd->[0] } @$cmd;
        die "exec failed: $!\n";
    }

    waitpid($pid, 0);
    my $status = $?;

    my $stdout = slurp_file($out_path);
    my $stderr = slurp_file($err_path);

    unlink $in_path;
    unlink $out_path;
    unlink $err_path;

    return {
        status => $status,
        exit   => ($status >> 8),
        signal => ($status & 127),
        stdout => $stdout,
        stderr => $stderr,
    };
}

sub fail_case {
    my ($name, $reason) = @_;
    print "[FAIL] $name: $reason\n";
    return 0;
}

sub pass_case {
    my ($name) = @_;
    print "[PASS] $name\n";
    return 1;
}

sub read_optional {
    my ($path) = @_;
    return undef if !-f $path;
    return slurp_file($path);
}

my $tests_dir = dirname(__FILE__);
my $compiler_dir = dirname($tests_dir);
my $cases_dir = "$tests_dir/cases";
my $build_dir = "$tests_dir/build";
make_path($build_dir) if !-d $build_dir;

my $metac = "$compiler_dir/metac.pl";
my $cc = $ENV{CC} // 'clang';
my @cflags = split /\s+/, ($ENV{CFLAGS} // '-std=c17 -O2 -Wall -Wextra -Wpedantic');

opendir my $dh, $cases_dir or die "io error: unable to open '$cases_dir': $!\n";
my @cases = sort grep { /\.metac$/ } readdir($dh);
closedir $dh;

my $passed = 0;
my $failed = 0;

for my $case_file (@cases) {
    my ($name) = $case_file =~ /^(.*)\.metac$/;
    my $prefix = "$cases_dir/$name";
    my $source = "$prefix.metac";
    my $expect_compile_err = read_optional("$prefix.compile_err");
    my $expect_hir = read_optional("$prefix.hir");

    my $c_out = "$build_dir/$name.c";
    my $bin_out = "$build_dir/$name";
    my $hir_out = "$build_dir/$name.hir";

    my $compile = run_cmd(cmd => ['perl', $metac, $source, '-o', $c_out, '--dump-hir', $hir_out]);

    if (defined $expect_compile_err) {
        my $needle = $expect_compile_err;
        $needle =~ s/\s+$//;

        if ($compile->{exit} == 0) {
            $failed += 1;
            fail_case($name, 'expected compile failure but compile succeeded');
            next;
        }

        my $combined = $compile->{stdout} . $compile->{stderr};
        if (index($combined, $needle) < 0) {
            $failed += 1;
            fail_case($name, "compile failed but missing expected diagnostic: $needle");
            next;
        }

        $passed += 1;
        pass_case($name);
        next;
    }

    if ($compile->{exit} != 0) {
        $failed += 1;
        fail_case($name, "compile failed:\n$compile->{stderr}");
        next;
    }

    if (defined $expect_hir) {
        my $actual_hir = read_optional($hir_out);
        if (!defined $actual_hir) {
            $failed += 1;
            fail_case($name, 'missing generated HIR dump');
            next;
        }
        if ($actual_hir ne $expect_hir) {
            $failed += 1;
            fail_case($name, "HIR dump mismatch\nexpected:\n$expect_hir\nactual:\n$actual_hir");
            next;
        }
    }

    my $cc_result = run_cmd(cmd => [$cc, @cflags, $c_out, '-o', $bin_out]);
    if ($cc_result->{exit} != 0) {
        $failed += 1;
        fail_case($name, "C compile failed:\n$cc_result->{stderr}");
        next;
    }

    my $input = read_optional("$prefix.in");
    $input = '' if !defined $input;
    my $expected_out = read_optional("$prefix.out");
    if (!defined $expected_out) {
        $failed += 1;
        fail_case($name, 'missing expected output file (.out) for run test');
        next;
    }

    my $expected_exit_raw = read_optional("$prefix.exit");
    my $expected_exit = 0;
    if (defined $expected_exit_raw) {
        $expected_exit_raw =~ s/\s+$//;
        $expected_exit = int($expected_exit_raw);
    }

    my $run = run_cmd(cmd => [$bin_out], stdin => $input);
    if ($run->{exit} != $expected_exit) {
        $failed += 1;
        fail_case($name, "unexpected exit code $run->{exit}, expected $expected_exit");
        next;
    }

    if ($run->{stdout} ne $expected_out) {
        $failed += 1;
        fail_case($name, "stdout mismatch\nexpected:\n$expected_out\nactual:\n$run->{stdout}");
        next;
    }

    $passed += 1;
    pass_case($name);
}

print "\nSummary: $passed passed, $failed failed\n";
exit($failed == 0 ? 0 : 1);
