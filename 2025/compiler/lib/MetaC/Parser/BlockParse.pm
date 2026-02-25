package MetaC::Parser;
use strict;
use warnings;

sub parse_block {
    my ($lines, $idx_ref, $base_line) = @_;
    my @stmts;

    while ($$idx_ref < @$lines) {
        my $line_no = defined($base_line) ? ($base_line + $$idx_ref) : undef;
        set_error_line($line_no);

        my $raw = strip_comments($lines->[$$idx_ref]);
        my $line = trim($raw);

        if ($line eq '') {
            $$idx_ref++;
            next;
        }

        my $look = $$idx_ref + 1;
        while ($look < @$lines) {
            my $next_raw = strip_comments($lines->[$look]);
            my $next = trim($next_raw);
            last if $next eq '';
            last if $next !~ /^\./;
            $line .= $next;
            $look++;
        }
        if ($look > $$idx_ref + 1) {
            $$idx_ref = $look - 1;
        }

        if ($line eq '}') {
            $$idx_ref++;
            return (\@stmts, 'close');
        }

        if ($line =~ /^\}\s*else\s*\{$/) {
            $$idx_ref++;
            return (\@stmts, 'close_else');
        }

        # Normalize inline if forms into multiline block syntax so downstream parsing stays uniform.
        # Examples:
        #   if ok { return true }
        #   if ok { return true } else { return false }
        if ($line =~ /^if\s+(.+?)\s*\{\s*(.+?)\s*\}\s*else\s*\{\s*(.+?)\s*\}$/) {
            my ($cond, $then_stmt, $else_stmt) = (trim($1), trim($2), trim($3));
            splice @$lines, $$idx_ref, 1, ("if $cond {", $then_stmt, "} else {", $else_stmt, "}");
            next;
        }
        if ($line =~ /^if\s+(.+?)\s*\{\s*(.+?)\s*\}$/) {
            my ($cond, $stmt_text) = (trim($1), trim($2));
            splice @$lines, $$idx_ref, 1, ("if $cond {", $stmt_text, "}");
            next;
        }

        if ($line =~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+lines\s*\(\s*STDIN\s*\)\?\s*\{$/) {
            my $var = $1;
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, { kind => 'for_lines', var => $var, body => $body, line => $line_no };
            next;
        }

        if ($line =~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\?\s*\{$/) {
            my ($var, $iter_raw) = ($1, trim($2));
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, {
                kind     => 'for_each_try',
                var      => $var,
                iterable => parse_iterable_expression($iter_raw),
                body     => $body,
                line     => $line_no,
            };
            next;
        }

        if ($line =~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\s*\{$/) {
            my ($var, $iter_raw) = ($1, trim($2));
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, {
                kind     => 'for_each',
                var      => $var,
                iterable => parse_iterable_expression($iter_raw),
                body     => $body,
                line     => $line_no,
            };
            next;
        }

        if ($line =~ /^while\s+(.+)\s*\{$/) {
            my $cond = trim($1);
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("while-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, { kind => 'while', cond => parse_expr($cond), body => $body, line => $line_no };
            next;
        }

        if ($line eq 'break') {
            push @stmts, { kind => 'break', line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line eq 'continue') {
            push @stmts, { kind => 'continue', line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line eq 'rewind') {
            push @stmts, { kind => 'rewind', line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^if\s+(.+)\s*\{$/) {
            my $cond = trim($1);
            $$idx_ref++;
            my ($then_body, $end_reason) = parse_block($lines, $idx_ref, $base_line);

            if ($end_reason eq 'close') {
                push @stmts, {
                    kind      => 'if',
                    cond      => parse_expr($cond),
                    then_body => $then_body,
                    else_body => undef,
                    line      => $line_no,
                };
                next;
            }

            if ($end_reason eq 'close_else') {
                my ($else_body, $end2) = parse_block($lines, $idx_ref, $base_line);
                compile_error("if-else missing closing brace") if $end2 ne 'close';
                push @stmts, {
                    kind      => 'if',
                    cond      => parse_expr($cond),
                    then_body => $then_body,
                    else_body => $else_body,
                    line      => $line_no,
                };
                next;
            }

            compile_error("Invalid if-block termination");
        }

        my $match_stmt = parse_match_statement($line);
        if (defined $match_stmt) {
            $match_stmt->{line} = $line_no;
            push @stmts, $match_stmt;
            $$idx_ref++;
            next;
        }

        if ($line =~ /^const\s*\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\]\s*=\s*(.+)$/) {
            my ($vars_raw, $rhs) = ($1, trim($2));
            my @vars = map { trim($_) } split /\s*,\s*/, $vars_raw;
            my $split = parse_call_invocation_text($rhs, 'split');
            if (defined $split && $split->{rest} =~ /^or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/) {
                my $err_name = $1;
                compile_error("split(...) in destructure expects exactly 2 args")
                  if scalar(@{ $split->{args} }) != 2;

                $$idx_ref++;
                my ($handler_body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
                compile_error("split destructure handler missing closing brace") if $end_reason ne 'close';

                push @stmts, {
                    kind        => 'destructure_split_or',
                    vars        => \@vars,
                    source_expr => parse_expr($split->{args}[0]),
                    delim_expr  => parse_expr($split->{args}[1]),
                    err_name    => $err_name,
                    handler     => $handler_body,
                    line        => $line_no,
                };
                next;
            }
            if (defined $split && $split->{rest} =~ /^or\s+\(([A-Za-z_][A-Za-z0-9_]*)\)\s*=>\s*\{$/) {
                compile_error("Legacy error handler syntax removed; use 'or catch(<name>) { ... }'");
            }

            push @stmts, {
                kind => 'destructure_list',
                vars => \@vars,
                expr => parse_expr($rhs),
                line => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)\s+from\s*\(\s*\)\s*=>\s*\{$/) {
            my ($name, $type) = ($1, $2);
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("producer initialization missing closing brace for '$name'") if $end_reason ne 'close';
            push @stmts, {
                kind => 'let_producer',
                name => $name,
                type => $type,
                body => $body,
                line => $line_no,
            };
            next;
        }

        if ($line =~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/) {
            my ($name, $type_with_constraints, $expr) = ($1, trim($2), trim($3));
            my ($type, $constraints) = parse_declared_type_and_constraints(
                raw   => $type_with_constraints,
                where => "constant '$name'",
            );
            if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $type ne 'number') {
                compile_error("Numeric constraints require number type for constant '$name'");
            }
            push @stmts, {
                kind        => 'const_typed',
                name        => $name,
                type        => $type,
                constraints => $constraints,
                expr        => parse_expr($expr),
                line        => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\?\s*$/) {
            my ($name, $inner) = ($1, trim($2));
            my $segments = split_try_chain_segments($inner);
            if (@$segments > 1) {
                my @steps;
                for (my $i = 1; $i < @$segments; $i++) {
                    push @steps, parse_method_step($segments->[$i]);
                }
                push @stmts, {
                    kind  => 'const_try_chain',
                    name  => $name,
                    first => parse_expr($segments->[0]),
                    steps => \@steps,
                    line  => $line_no,
                };
                $$idx_ref++;
                next;
            }
            push @stmts, {
                kind => 'const_try_expr',
                name => $name,
                expr => parse_expr($inner),
                line => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            my ($name, $rhs) = ($1, trim($2));
            if ($rhs =~ /^(.*)\s+or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/) {
                my $inner = trim($1);
                my $err_name = $2;
                $$idx_ref++;
                my ($handler_body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
                compile_error("or catch handler missing closing brace") if $end_reason ne 'close';
                push @stmts, {
                    kind    => 'const_or_catch',
                    name    => $name,
                    expr    => parse_expr($inner),
                    err_name => $err_name,
                    handler => $handler_body,
                    line    => $line_no,
                };
                next;
            }
            my $split = parse_call_invocation_text($rhs, 'split');
            if (defined $split && $split->{rest} eq '?') {
                compile_error("split(...) with '?' expects exactly 2 args")
                  if scalar(@{ $split->{args} }) != 2;
                push @stmts, {
                    kind        => 'const_split_try',
                    name        => $name,
                    source_expr => parse_expr($split->{args}[0]),
                    delim_expr  => parse_expr($split->{args}[1]),
                    line        => $line_no,
                };
                $$idx_ref++;
                next;
            }

            my $segments = split_try_chain_segments($rhs);
            if (@$segments > 1) {
                my $first = $segments->[0];
                my @tail_parts = @$segments[1 .. $#$segments];
                my $tail_raw = join('.', @tail_parts);
                push @stmts, {
                    kind     => 'const_try_tail_expr',
                    name     => $name,
                    first    => parse_expr($first),
                    tail_raw => $tail_raw,
                    line     => $line_no,
                };
                $$idx_ref++;
                next;
            }

            push @stmts, { kind => 'const', name => $name, expr => parse_expr($rhs), line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/) {
            my ($name, $type_with_constraints, $expr) = ($1, trim($2), trim($3));
            my ($type, $constraints) = parse_declared_type_and_constraints(
                raw   => $type_with_constraints,
                where => "variable '$name'",
            );
            if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $type ne 'number') {
                compile_error("Numeric constraints require number type for variable '$name'");
            }
            push @stmts, {
                kind        => 'let',
                name        => $name,
                type        => $type,
                constraints => $constraints,
                expr        => parse_expr($expr),
                line        => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            my ($name, $expr) = ($1, trim($2));
            push @stmts, {
                kind        => 'let',
                name        => $name,
                type        => undef,
                constraints => parse_constraints(undef),
                expr        => parse_expr($expr),
                line        => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^return\s+(.+)$/) {
            push @stmts, { kind => 'return', expr => parse_expr(trim($1)), line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/) {
            my ($name, $type_with_constraints, $expr) = ($1, trim($2), trim($3));
            my ($type, $constraints) = parse_declared_type_and_constraints(
                raw   => $type_with_constraints,
                where => "typed assignment for '$name'",
            );
            if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $type ne 'number') {
                compile_error("Numeric constraints require number type in typed assignment for '$name'");
            }
            push @stmts, {
                kind        => 'typed_assign',
                name        => $name,
                type        => $type,
                constraints => $constraints,
                expr        => parse_expr($expr),
                line        => $line_no,
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\+=\s*(.+)$/) {
            push @stmts, { kind => 'assign_op', name => $1, op => '+=', expr => parse_expr(trim($2)), line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\+\+$/) {
            push @stmts, { kind => 'incdec', name => $1, op => '++', line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*--$/) {
            push @stmts, { kind => 'incdec', name => $1, op => '--', line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            push @stmts, { kind => 'assign', name => $1, expr => parse_expr(trim($2)), line => $line_no };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^(.*)\s+or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/) {
            my $inner = trim($1);
            my $err_name = $2;
            my $expr = parse_expr($inner);
            compile_error("or catch handler requires function or method call expression")
              if $expr->{kind} ne 'call' && $expr->{kind} ne 'method_call';

            $$idx_ref++;
            my ($handler_body, $end_reason) = parse_block($lines, $idx_ref, $base_line);
            compile_error("or catch handler missing closing brace") if $end_reason ne 'close';
            push @stmts, {
                kind    => 'expr_or_catch',
                expr    => $expr,
                err_name => $err_name,
                handler => $handler_body,
                line    => $line_no,
            };
            next;
        }

        if ($line =~ /^(.+)\?\s*$/) {
            my $inner = trim($1);
            my $expr = parse_expr($inner);
            if ($expr->{kind} eq 'call' || $expr->{kind} eq 'method_call') {
                push @stmts, { kind => 'expr_stmt_try', expr => $expr, line => $line_no };
                $$idx_ref++;
                next;
            }
            compile_error("try expression statement requires function or method call");
        }

        if ($line =~ /\)\s*$/) {
            my $expr = parse_expr($line);
            if ($expr->{kind} eq 'call' || $expr->{kind} eq 'method_call') {
                push @stmts, { kind => 'expr_stmt', expr => $expr, line => $line_no };
                $$idx_ref++;
                next;
            }
        }

        push @stmts, { kind => 'raw', text => $line, line => $line_no };
        $$idx_ref++;
    }

    return (\@stmts, 'eof');
}


1;
