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

sub _runtime_memory_policies {
    return {
        metac_strdup_local                     => { mode => 'owned_return', cleanup => 'free' },
        metac_read_all_stdin                  => { mode => 'static_buffer' },
        metac_number_list_from_array          => { mode => 'owned_return', cleanup => 'metac_free_number_list' },
        metac_bool_list_from_array            => { mode => 'owned_return', cleanup => 'metac_free_bool_list' },
        metac_string_list_from_array          => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_split_string                    => { mode => 'owned_return', cleanup => 'metac_free_result_string_list' },
        metac_match_string                    => { mode => 'owned_return', cleanup => 'metac_free_result_string_list' },
        metac_slice_string_list               => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_slice_number_list               => { mode => 'owned_return', cleanup => 'metac_free_number_list' },
        metac_filter_number_list              => { mode => 'owned_return', cleanup => 'metac_free_number_list' },
        metac_filter_string_list              => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_filter_matrix_number_member_list => { mode => 'owned_return', cleanup => 'metac_free_matrix_number_member_list' },
        metac_filter_matrix_string_member_list => { mode => 'owned_return', cleanup => 'metac_free_matrix_string_member_list' },
        metac_number_list_push                => { mode => 'mutates_owner' },
        metac_number_list_list_push           => { mode => 'mutates_owner' },
        metac_sort_number_list_list_by        => { mode => 'owned_return', cleanup => 'metac_free_number_list_list' },
        metac_string_list_push                => { mode => 'mutates_owner' },
        metac_bool_list_push                  => { mode => 'mutates_owner' },
        metac_sort_number_list                => { mode => 'owned_return', cleanup => 'metac_free_indexed_number_list' },
        metac_chunk_string                    => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_chars_string                    => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_matrix_number_new               => { mode => 'owned_return', cleanup => 'metac_free_matrix_number' },
        metac_matrix_number_ensure_capacity   => { mode => 'mutates_owner' },
        metac_matrix_number_insert_try        => { mode => 'mutates_owner' },
        metac_matrix_number_members           => { mode => 'owned_return', cleanup => 'metac_free_matrix_number_member_list' },
        metac_matrix_number_neighbours        => { mode => 'owned_return', cleanup => 'metac_free_number_list' },
        metac_matrix_string_new               => { mode => 'owned_return', cleanup => 'metac_free_matrix_string' },
        metac_matrix_opaque_new               => { mode => 'owned_return', cleanup => 'metac_free_matrix_opaque' },
        metac_matrix_string_ensure_capacity   => { mode => 'mutates_owner' },
        metac_matrix_string_insert_try        => { mode => 'mutates_owner' },
        metac_matrix_string_members           => { mode => 'owned_return', cleanup => 'metac_free_matrix_string_member_list' },
        metac_matrix_string_neighbours        => { mode => 'owned_return', cleanup => 'metac_free_string_list' },
        metac_log_matrix_string               => { mode => 'scoped_temp' },
    };
}

sub _validate_runtime_memory_contract {
    my ($order, $blocks) = @_;
    my $policies = _runtime_memory_policies();

    for my $name (@$order) {
        my $body = $blocks->{$name} // '';
        next if $body !~ /\b(?:malloc|calloc|realloc)\s*\(/;

        my $policy = $policies->{$name};
        die "Runtime memory contract missing for allocator function '$name'\n"
          if !defined $policy;
        my $mode = $policy->{mode} // '';

        if ($mode eq 'owned_return') {
            my $cleanup = $policy->{cleanup};
            die "Runtime memory contract for '$name' must define cleanup\n"
              if !defined($cleanup) || $cleanup eq '';
            if ($cleanup ne 'free' && !exists $blocks->{$cleanup}) {
                die "Runtime memory contract for '$name' references unknown cleanup '$cleanup'\n";
            }
            next;
        }

        if ($mode eq 'mutates_owner') {
            next;
        }

        if ($mode eq 'static_buffer') {
            die "Runtime static-buffer contract for '$name' requires static storage declaration\n"
              if $body !~ /\bstatic\s+char\s*\*/;
            next;
        }

        if ($mode eq 'scoped_temp') {
            die "Runtime scoped-temp contract for '$name' requires free(...) in function body\n"
              if $body !~ /\bfree\s*\(/;
            next;
        }

        die "Runtime memory contract for '$name' has unsupported mode '$mode'\n";
    }
}

sub _owned_return_cleanup_map {
    my $policies = _runtime_memory_policies();
    my %owned;
    for my $name (keys %$policies) {
        my $policy = $policies->{$name};
        next if ($policy->{mode} // '') ne 'owned_return';
        my $cleanup = $policy->{cleanup} // '';
        next if $cleanup eq '';
        $owned{$name} = $cleanup;
    }
    return \%owned;
}

sub _parse_c_function_blocks {
    my ($code) = @_;
    my @lines = split /\n/, $code, -1;
    my @fns;
    my $i = 0;
    my $depth = 0;
    while ($i < @lines) {
        my $line = $lines[$i];
        if ($depth == 0
            && $line =~ /^\s*(?:static\s+)?[A-Za-z_][A-Za-z0-9_\s\*]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^;]*\)\s*\{/
            && $1 ne 'if'
            && $1 ne 'for'
            && $1 ne 'while'
            && $1 ne 'switch')
        {
            my $name = $1;
            my @block;
            my $fn_depth = 0;
            my $seen_open = 0;
            my $start_line = $i + 1;
            while ($i < @lines) {
                my $cur = $lines[$i];
                push @block, $cur;
                my $clean = _strip_c_literals_for_braces($cur);
                my $open = () = $clean =~ /\{/g;
                my $close = () = $clean =~ /\}/g;
                $fn_depth += $open;
                $fn_depth -= $close;
                $seen_open ||= $open > 0;
                $i++;
                last if $seen_open && $fn_depth == 0;
            }
            push @fns, { name => $name, start_line => $start_line, lines => \@block };
            next;
        }
        my $clean = _strip_c_literals_for_braces($line);
        my $open = () = $clean =~ /\{/g;
        my $close = () = $clean =~ /\}/g;
        $depth += $open;
        $depth -= $close;
        $depth = 0 if $depth < 0;
        $i++;
    }
    return \@fns;
}

sub _validate_consumer_owned_lifetimes {
    my ($consumer_code) = @_;
    my $owned = _owned_return_cleanup_map();
    my @owned_funcs = sort keys %$owned;
    return if !@owned_funcs;

    my $fns = _parse_c_function_blocks($consumer_code);
    for my $fn (@$fns) {
        my @lines = @{ $fn->{lines} };
        next if !@lines;
        my %label_line;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*;?\s*$/) {
                $label_line{$1} = $i;
            }
        }

        my %open_to_close;
        my @brace_stack;
        for my $i (0 .. $#lines) {
            my $clean = _strip_c_literals_for_braces($lines[$i]);
            my $open = () = $clean =~ /\{/g;
            my $close = () = $clean =~ /\}/g;
            for (1 .. $open) {
                push @brace_stack, $i;
            }
            for (1 .. $close) {
                my $open_line = pop @brace_stack;
                last if !defined $open_line;
                $open_to_close{$open_line} = $i;
            }
        }

        my @succ;
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            my @next;
            if ($line =~ /\breturn\b/ || $line =~ /\bexit\s*\(/) {
                @next = ();
            } elsif ($line =~ /\bgoto\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/) {
                my $dst = $1;
                @next = exists $label_line{$dst} ? ($label_line{$dst}) : ();
            } elsif ($line =~ /^\s*(?:if|for|while)\s*\(.*\)\s*\{\s*$/) {
                push @next, $i + 1 if $i + 1 <= $#lines;
                my $close = $open_to_close{$i};
                if (defined $close && $close + 1 <= $#lines) {
                    push @next, $close + 1;
                }
            } else {
                push @next, $i + 1 if $i + 1 <= $#lines;
            }
            my %seen;
            $succ[$i] = [ grep { !$seen{$_}++ } @next ];
        }

        my %split_src_to_alias;
        for my $line (@lines) {
            if ($line =~ /\bStringList\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\.value\s*;/) {
                my ($alias, $src) = ($1, $2);
                $split_src_to_alias{$src} = $alias;
            }
        }

        my @exit_states;
        my %seen;
        my @work = ({ line => 0, state => {} });
        while (@work) {
            my $item = shift @work;
            my $i = $item->{line};
            next if $i < 0 || $i > $#lines;
            my %state = %{ $item->{state} // {} };
            my $state_key = join(',', sort keys %state);
            my $visit_key = $i . '|' . $state_key;
            next if $seen{$visit_key}++;
            my $line = $lines[$i];
            my $line_no = $fn->{start_line} + $i;

            for my $alloc_fn (@owned_funcs) {
                next if $alloc_fn eq 'metac_split_string' || $alloc_fn eq 'metac_match_string';
                next if $line !~ /\b\Q$alloc_fn\E\s*\(/;
                next if $line !~ /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\Q$alloc_fn\E\s*\(/;
                my $var = $1;
                $state{$var} = {
                    alloc_fn => $alloc_fn,
                    cleanup  => $owned->{$alloc_fn},
                    line     => $line_no,
                };
            }
            if ($line =~ /\bStringList\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\.value\s*;/) {
                my ($alias, $src) = ($1, $2);
                if (($src =~ /^__metac_split/ || $src =~ /^__metac_match/) && !exists $state{$src}) {
                    my $alloc_fn = $src =~ /^__metac_match/ ? 'metac_match_string' : 'metac_split_string';
                    $state{$src} = {
                        alloc_fn => $alloc_fn,
                        cleanup  => ($owned->{$alloc_fn} // 'metac_free_result_string_list'),
                        line     => $line_no,
                    };
                }
                $split_src_to_alias{$src} = $alias;
            }

            # Track simple ownership moves across identifier assignment.
            my ($dst, $src);
            if ($line =~ /^\s*(?:const\s+)?[A-Za-z_][A-Za-z0-9_\s\*]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$/) {
                ($dst, $src) = ($1, $2);
            } elsif ($line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$/) {
                ($dst, $src) = ($1, $2);
            }
            if (defined($dst) && defined($src)
                && $dst ne $src
                && $dst =~ /^__metac_return\d+$/
                && exists $state{$src})
            {
                $state{$dst} = delete $state{$src};
            }

            for my $var (keys %state) {
                my $cleanup = $state{$var}{cleanup};
                my $cleanup_re = $cleanup eq 'free'
                  ? qr/\bfree\s*\(\s*\Q$var\E\s*\)/
                  : qr/\b\Q$cleanup\E\s*\(\s*&?\s*\Q$var\E\b/;
                if ($line =~ $cleanup_re) {
                    delete $state{$var};
                    next;
                }
                if ($state{$var}{alloc_fn} eq 'metac_split_string' || $state{$var}{alloc_fn} eq 'metac_match_string') {
                    my $alias = $split_src_to_alias{$var};
                    if (defined $alias && $line =~ /\bmetac_free_string_list\s*\(\s*\Q$alias\E\s*,\s*1\s*\)/) {
                        delete $state{$var};
                        next;
                    }
                }
            }

            if ($line =~ /\breturn\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/) {
                my $ret_var = $1;
                delete $state{$ret_var} if exists $state{$ret_var};
            }

            my @next = @{ $succ[$i] // [] };
            if (!@next) {
                push @exit_states, { %state };
                next;
            }
            for my $j (@next) {
                push @work, { line => $j, state => { %state } };
            }
        }

        my %leaked;
        for my $state (@exit_states) {
            for my $var (keys %$state) {
                $leaked{$var} = $state->{$var};
            }
        }
        if (%leaked) {
            my @msgs = map {
                my $m = $leaked{$_};
                "$_ from $m->{alloc_fn} (allocated at line $m->{line}, cleanup $m->{cleanup})"
            } sort keys %leaked;
            die "Owned allocations without cleanup in function '$fn->{name}': " . join('; ', @msgs) . "\n";
        }
    }
}

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
    _validate_consumer_owned_lifetimes($consumer_code);

    my $runtime = runtime_prelude();
    my ($prefix, $order, $blocks) = _parse_runtime_blocks($runtime);
    _validate_runtime_memory_contract($order, $blocks);
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
