#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json);

sub slurp_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "io error: unable to read '$path': $!\n";
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "io error: unable to write '$path': $!\n";
    print {$fh} $content;
    close $fh;
}

sub parse_case_annotation {
    my ($name, $source_text) = @_;
    my $tag_pos = index($source_text, '@Test(');
    if ($tag_pos < 0) {
        die "[FAIL] $name: missing \@Test({...}) annotation directly before main()\n";
    }

    my $open_paren = $tag_pos + length('@Test');
    my $depth = 0;
    my $in_string = 0;
    my $escaped = 0;
    my $close_paren = -1;
    my $len = length($source_text);

    for (my $i = $open_paren; $i < $len; $i += 1) {
        my $ch = substr($source_text, $i, 1);
        if ($in_string) {
            if ($escaped) {
                $escaped = 0;
                next;
            }
            if ($ch eq '\\') {
                $escaped = 1;
                next;
            }
            if ($ch eq '"') {
                $in_string = 0;
            }
            next;
        }

        if ($ch eq '"') {
            $in_string = 1;
            next;
        }

        if ($ch eq '(') {
            $depth += 1;
            next;
        }

        if ($ch eq ')') {
            $depth -= 1;
            if ($depth == 0) {
                $close_paren = $i;
                last;
            }
            next;
        }
    }

    if ($close_paren < 0) {
        die "[FAIL] $name: unterminated \@Test(...) annotation\n";
    }

    my $suffix = substr($source_text, $close_paren + 1);
    if ($suffix !~ /\A([ \t\r\n]*)(?=function\s+main\s*\()/s) {
        die "[FAIL] $name: \@Test annotation must be directly before main()\n";
    }
    my $gap_len = length($1);

    my $json_text = substr($source_text, $open_paren + 1, $close_paren - $open_paren - 1);
    my $expect = eval { decode_json($json_text) };
    if (!$expect || ref($expect) ne 'HASH') {
        my $err = $@ // 'invalid JSON payload';
        die "[FAIL] $name: invalid \@Test JSON: $err\n";
    }

    my %allowed = map { $_ => 1 } qw(compile_err stdout exit stdin hir);
    for my $key (keys %$expect) {
        die "[FAIL] $name: unsupported \@Test key '$key'\n" if !$allowed{$key};
    }

    if (exists $expect->{compile_err}) {
        die "[FAIL] $name: \@Test.compile_err must be a string\n"
            if !defined($expect->{compile_err}) || ref($expect->{compile_err});
    } else {
        die "[FAIL] $name: \@Test.stdout must be present for run tests\n"
            if !exists $expect->{stdout};
        die "[FAIL] $name: \@Test.stdout must be a string\n"
            if !defined($expect->{stdout}) || ref($expect->{stdout});
    }

    if (exists $expect->{exit}) {
        die "[FAIL] $name: \@Test.exit must be an integer\n"
            if !defined($expect->{exit}) || ref($expect->{exit}) || $expect->{exit} !~ /^-?\d+$/;
        $expect->{exit} = int($expect->{exit});
    } else {
        $expect->{exit} = 0;
    }

    if (exists $expect->{stdin}) {
        die "[FAIL] $name: \@Test.stdin must be a string\n"
            if !defined($expect->{stdin}) || ref($expect->{stdin});
    } else {
        $expect->{stdin} = '';
    }

    if (exists $expect->{hir}) {
        die "[FAIL] $name: \@Test.hir must be a string\n"
            if !defined($expect->{hir}) || ref($expect->{hir});
    }

    my $stripped = $source_text;
    substr($stripped, $tag_pos, $close_paren - $tag_pos + 1 + $gap_len, '');
    return ($expect, $stripped);
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

my @purity_files = (
    "$compiler_dir/lib/MetaC/HIR/BackendC.pm",
    "$compiler_dir/lib/MetaC/HIR/MaterializeC.pm",
);
for my $file (@purity_files) {
    next if !-f $file;
    my $text = slurp_file($file);
    if ($text =~ /\btype_is_[A-Za-z0-9_]+\b/) {
        print "[FAIL] purity-check: forbidden type-shape helper in $file\n";
        print "\nSummary: 0 passed, 1 failed\n";
        exit 1;
    }
}

opendir my $dh, $cases_dir or die "io error: unable to open '$cases_dir': $!\n";
my @cases = sort grep { /\.metac$/ } readdir($dh);
closedir $dh;

my $passed = 0;
my $failed = 0;

for my $case_file (@cases) {
    my ($name) = $case_file =~ /^(.*)\.metac$/;
    my $prefix = "$cases_dir/$name";
    my $source = "$prefix.metac";

    my $source_text = slurp_file($source);
    my ($expect, $stripped_source) = parse_case_annotation($name, $source_text);
    my $source_for_compile = "$build_dir/$name.test.metac";
    write_file($source_for_compile, $stripped_source);

    my $c_out = "$build_dir/$name.c";
    my $bin_out = "$build_dir/$name";
    my $hir_out = "$build_dir/$name.hir";

    my $compile = run_cmd(cmd => ['perl', $metac, $source_for_compile, '-o', $c_out, '--dump-hir', $hir_out]);

    if (exists $expect->{compile_err}) {
        my $needle = $expect->{compile_err};
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

    if (exists $expect->{hir}) {
        my $actual_hir = read_optional($hir_out);
        if (!defined $actual_hir) {
            $failed += 1;
            fail_case($name, 'missing generated HIR dump');
            next;
        }
        if ($actual_hir ne $expect->{hir}) {
            $failed += 1;
            fail_case($name, "HIR dump mismatch\nexpected:\n$expect->{hir}\nactual:\n$actual_hir");
            next;
        }
    }

    my $cc_result = run_cmd(cmd => [$cc, @cflags, $c_out, '-o', $bin_out]);
    if ($cc_result->{exit} != 0) {
        $failed += 1;
        fail_case($name, "C compile failed:\n$cc_result->{stderr}");
        next;
    }

    my $run = run_cmd(cmd => [$bin_out], stdin => $expect->{stdin});
    if ($run->{exit} != $expect->{exit}) {
        $failed += 1;
        fail_case($name, "unexpected exit code $run->{exit}, expected $expect->{exit}");
        next;
    }

    if ($run->{stdout} ne $expect->{stdout}) {
        $failed += 1;
        fail_case($name, "stdout mismatch\nexpected:\n$expect->{stdout}\nactual:\n$run->{stdout}");
        next;
    }

    $passed += 1;
    pass_case($name);
}

print "\nSummary: $passed passed, $failed failed\n";
exit($failed == 0 ? 0 : 1);
