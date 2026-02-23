package MetaC::CodegenRuntime;
use strict;
use warnings;
use Exporter 'import';

use MetaC::CodegenRuntime::Prefix qw(runtime_prefix);
use MetaC::CodegenRuntime::Core qw(runtime_fragment_core);
use MetaC::CodegenRuntime::Utf8 qw(runtime_fragment_utf8);
use MetaC::CodegenRuntime::Lists qw(runtime_fragment_lists);
use MetaC::CodegenRuntime::Logging qw(runtime_fragment_logging);
use MetaC::CodegenRuntime::Regex qw(runtime_fragment_regex);
use MetaC::CodegenRuntime::Matrix qw(runtime_fragment_matrix);

our @EXPORT_OK = qw(runtime_prelude runtime_prelude_for_code);

sub runtime_prelude {
    my @chunks = (
        runtime_prefix(),
        runtime_fragment_core(),
        runtime_fragment_utf8(),
        runtime_fragment_lists(),
        runtime_fragment_logging(),
        runtime_fragment_regex(),
        runtime_fragment_matrix(),
    );
    my $out = join("\n\n", grep { defined($_) && $_ ne '' } @chunks);
    $out .= "\n" if $out !~ /\n\z/;
    return $out;
}

sub _strip_c_literals_for_braces {
    my ($line) = @_;
    my $clean = $line;
    $clean =~ s/"(?:\\.|[^"\\])*"/""/g;
    $clean =~ s/'(?:\\.|[^'\\])*'/' '/g;
    return $clean;
}

sub _parse_runtime_blocks {
    my ($runtime) = @_;
    my @lines = split /\n/, $runtime, -1;
    my @prefix;
    my @order;
    my %blocks;
    my $i = 0;

    while ($i < @lines) {
        my $line = $lines[$i];
        if ($line =~ /^static\b/ && $line =~ /\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/) {
            my $name = $1;
            my @block;
            my $depth = 0;
            my $seen_open = 0;

            while ($i < @lines) {
                my $cur = $lines[$i];
                push @block, $cur;
                my $clean = _strip_c_literals_for_braces($cur);
                my $open = () = $clean =~ /\{/g;
                my $close = () = $clean =~ /\}/g;
                $depth += $open;
                $depth -= $close;
                $seen_open ||= $open > 0;
                $i++;
                last if $seen_open && $depth == 0;
            }

            $blocks{$name} = join("\n", @block) . "\n";
            push @order, $name;
            next;
        }

        push @prefix, $line;
        $i++;
    }

    my $prefix = join("\n", @prefix);
    $prefix .= "\n" if $prefix !~ /\n\z/;
    return ($prefix, \@order, \%blocks);
}

sub _build_runtime_deps {
    my ($order, $blocks) = @_;
    my %known = map { $_ => 1 } @$order;
    my %deps;

    for my $name (@$order) {
        my $body = $blocks->{$name} // '';
        my %seen;
        for my $callee (@$order) {
            next if !$known{$callee};
            next if $callee eq $name;
            next if $body !~ /\b\Q$callee\E\b/;
            next if $seen{$callee};
            $seen{$callee} = 1;
        }
        $deps{$name} = [ sort keys %seen ];
    }

    return \%deps;
}

sub _runtime_roots_from_consumer {
    my ($consumer_code, $order) = @_;
    my @roots;
    for my $name (@$order) {
        if ($consumer_code =~ /\b\Q$name\E\b/) {
            push @roots, $name;
        }
    }
    return \@roots;
}

sub _runtime_reachable {
    my ($roots, $deps) = @_;
    my %keep;
    my @stack = @$roots;

    while (@stack) {
        my $name = pop @stack;
        next if $keep{$name};
        $keep{$name} = 1;
        push @stack, @{ $deps->{$name} // [] };
    }

    return \%keep;
}

sub runtime_prelude_for_code {
    my ($consumer_code) = @_;
    $consumer_code = '' if !defined $consumer_code;

    my $runtime = runtime_prelude();
    my ($prefix, $order, $blocks) = _parse_runtime_blocks($runtime);
    my $deps = _build_runtime_deps($order, $blocks);
    my $roots = _runtime_roots_from_consumer($consumer_code, $order);
    my $keep = _runtime_reachable($roots, $deps);

    my $out = $prefix;
    for my $name (@$order) {
        next if !$keep->{$name};
        $out .= $blocks->{$name};
    }
    return $out;
}

1;
