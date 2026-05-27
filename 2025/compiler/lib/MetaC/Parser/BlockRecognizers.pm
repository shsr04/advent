package MetaC::Parser;
use strict;
use warnings;

use MetaC::HIR::NodeRegistry qw(statement_recognizers);

sub _stmt_result {
    my (@stmts) = @_;
    return { matched => 1, statements => \@stmts };
}

sub _parse_nested_block_stmt {
    my ($ctx, $missing_diag) = @_;
    ${ $ctx->{idx_ref} }++;
    my ($body, $end_reason) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
    compile_error($missing_diag) if $end_reason ne 'close';
    return $body;
}

sub _recognize_for_lines {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+lines\s*\(\s*STDIN\s*\)\?\s*\{$/;
    my $body = _parse_nested_block_stmt($ctx, "for-loop missing closing brace");
    return _stmt_result({ kind => 'for_lines', var => $1, body => $body, line => $ctx->{line_no} });
}

sub _recognize_for_each_try {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\?\s*\{$/;
    my ($var, $iter_raw) = ($1, trim($2));
    my $body = _parse_nested_block_stmt($ctx, "for-loop missing closing brace");
    return _stmt_result({
        kind => 'for_each_try',
        var => $var,
        iterable => parse_iterable_expression($iter_raw),
        body => $body,
        line => $ctx->{line_no},
    });
}

sub _recognize_for_each {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^for\s+(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\s*\{$/;
    my ($var, $iter_raw) = ($1, trim($2));
    my $body = _parse_nested_block_stmt($ctx, "for-loop missing closing brace");
    return _stmt_result({
        kind => 'for_each',
        var => $var,
        iterable => parse_iterable_expression($iter_raw),
        body => $body,
        line => $ctx->{line_no},
    });
}

sub _recognize_while {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^while\s+(.+)\s*\{$/;
    my $cond = trim($1);
    my $body = _parse_nested_block_stmt($ctx, "while-loop missing closing brace");
    return _stmt_result({ kind => 'while', cond => parse_expr($cond), body => $body, line => $ctx->{line_no} });
}

sub _recognize_simple_control {
    my ($ctx, $kind) = @_;
    return undef if $ctx->{line} ne $kind;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => $kind, line => $ctx->{line_no} });
}

sub _recognize_if {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^if\s+(.+)\s*\{$/;
    my $cond = trim($1);
    ${ $ctx->{idx_ref} }++;
    my ($then_body, $end_reason) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
    my $else_body = _parse_if_else_tail($ctx, $end_reason);
    return _stmt_result({
        kind => 'if',
        cond => parse_expr($cond),
        then_body => $then_body,
        else_body => $else_body,
        line => $ctx->{line_no},
    });
}

sub _parse_if_else_tail {
    my ($ctx, $end_reason) = @_;
    return undef if $end_reason eq 'close';
    if ($end_reason eq 'close_else') {
        my ($else_body, $end2) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
        compile_error("if-else missing closing brace") if $end2 ne 'close';
        return $else_body;
    }
    if ($end_reason =~ /^close_else_if:(.*)$/) {
        return [ _parse_else_if_chain($ctx, trim($1)) ];
    }
    compile_error("Invalid if-block termination");
}

sub _parse_else_if_chain {
    my ($ctx, $first_cond) = @_;
    my ($then_body, $end_reason) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
    my $root = { kind => 'if', cond => parse_expr($first_cond), then_body => $then_body, else_body => undef, line => $ctx->{line_no} };
    my $chain = $root;
    while (1) {
        last if $end_reason eq 'close';
        if ($end_reason eq 'close_else') {
            my ($else_body, $end2) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
            compile_error("if-else missing closing brace") if $end2 ne 'close';
            $chain->{else_body} = $else_body;
            last;
        }
        if ($end_reason =~ /^close_else_if:(.*)$/) {
            my $next_cond = trim($1);
            my ($next_then, $next_end) = parse_block($ctx->{lines}, $ctx->{idx_ref}, $ctx->{base_line});
            my $next_node = { kind => 'if', cond => parse_expr($next_cond), then_body => $next_then, else_body => undef, line => $ctx->{line_no} };
            $chain->{else_body} = [$next_node];
            $chain = $next_node;
            $end_reason = $next_end;
            next;
        }
        compile_error("if-else missing closing brace");
    }
    return $root;
}

sub _recognize_destructure_match {
    my ($ctx) = @_;
    my $stmt = parse_match_statement($ctx->{line});
    return undef if !defined($stmt);
    $stmt->{line} = $ctx->{line_no};
    ${ $ctx->{idx_ref} }++;
    return _stmt_result($stmt);
}

sub _destructure_parts {
    my ($line) = @_;
    return undef if $line !~ /^const\s*\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\]\s*=\s*(.+)$/;
    return [[ map { trim($_) } split /\s*,\s*/, $1 ], trim($2)];
}

sub _recognize_destructure_split_or {
    my ($ctx) = @_;
    my $parts = _destructure_parts($ctx->{line}) // return undef;
    my ($vars, $rhs) = @$parts;
    my $split = parse_call_invocation_text($rhs, 'split');
    return undef if !defined($split) || $split->{rest} !~ /^or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/;
    my $err_name = $1;
    compile_error("split(...) in destructure expects exactly 2 args") if scalar(@{ $split->{args} }) != 2;
    my $handler_body = _parse_nested_block_stmt($ctx, "split destructure handler missing closing brace");
    return _stmt_result({
        kind => 'destructure_split_or',
        vars => $vars,
        source_expr => parse_expr($split->{args}[0]),
        delim_expr => parse_expr($split->{args}[1]),
        err_name => $err_name,
        handler => $handler_body,
        line => $ctx->{line_no},
    });
}

sub _recognize_destructure_list {
    my ($ctx) = @_;
    my $parts = _destructure_parts($ctx->{line}) // return undef;
    my ($vars, $rhs) = @$parts;
    my $split = parse_call_invocation_text($rhs, 'split');
    if (defined($split) && $split->{rest} =~ /^or\s+\(([A-Za-z_][A-Za-z0-9_]*)\)\s*=>\s*\{$/) {
        compile_error("Legacy error handler syntax removed; use 'or catch(<name>) { ... }'");
    }
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'destructure_list', vars => $vars, expr => parse_expr($rhs), line => $ctx->{line_no} });
}

sub _recognize_let_producer {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)\s+from\s*\(\s*\)\s*=>\s*\{$/;
    my ($name, $type) = ($1, $2);
    my $body = _parse_nested_block_stmt($ctx, "producer initialization missing closing brace for '$name'");
    return _stmt_result({ kind => 'let_producer', name => $name, type => $type, body => $body, line => $ctx->{line_no} });
}

sub _typed_decl_stmt {
    my ($ctx, $kind, $name, $type_raw, $expr, $where, $diag) = @_;
    my ($type, $constraints, $declared_numeric_kind) = parse_declared_type_and_constraints(raw => $type_raw, where => $where);
    if (constraints_has_any_kind($constraints, qw(range wrap positive negative)) && $type ne 'number') {
        compile_error($diag);
    }
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({
        kind => $kind,
        name => $name,
        type => $type,
        declared_numeric_kind => $declared_numeric_kind,
        constraints => $constraints,
        expr => parse_expr($expr),
        line => $ctx->{line_no},
    });
}

sub _recognize_const_typed {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/;
    my ($name, $type_raw, $expr) = ($1, trim($2), trim($3));
    return _typed_decl_stmt($ctx, 'const_typed', $name, $type_raw, $expr, "constant '$name'", "Numeric constraints require number type for constant '$name'");
}

sub _recognize_const_try_chain {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\?\s*$/;
    my ($name, $inner) = ($1, trim($2));
    my $segments = split_try_chain_segments($inner);
    return undef if @$segments <= 1;
    my @steps = map { parse_method_step($segments->[$_]) } (1 .. $#$segments);
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'const_try_chain', name => $name, first => parse_expr($segments->[0]), steps => \@steps, line => $ctx->{line_no} });
}

sub _recognize_const_try_expr {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\?\s*$/;
    my ($name, $inner) = ($1, trim($2));
    return undef if @{ split_try_chain_segments($inner) } > 1;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'const_try_expr', name => $name, expr => parse_expr($inner), line => $ctx->{line_no} });
}

sub _recognize_const_or_catch {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/;
    my ($name, $rhs) = ($1, trim($2));
    return undef if $rhs !~ /^(.*)\s+or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/;
    my ($inner, $err_name) = (trim($1), $2);
    my $handler_body = _parse_nested_block_stmt($ctx, "or catch handler missing closing brace");
    return _stmt_result({ kind => 'const_or_catch', name => $name, expr => parse_expr($inner), err_name => $err_name, handler => $handler_body, line => $ctx->{line_no} });
}

sub _recognize_const_try_tail_expr {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/;
    my ($name, $rhs) = ($1, trim($2));
    my $rhs_expr = parse_expr($rhs);
    my $segments = split_try_chain_segments($rhs);
    return undef if @$segments <= 1 || !expr_is_try_tail_chain_candidate($rhs_expr);
    my @tail_parts = @$segments[1 .. $#$segments];
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({
        kind => 'const_try_tail_expr',
        name => $name,
        first => parse_expr($segments->[0]),
        tail_raw => join('.', @tail_parts),
        steps => [ map { parse_method_step($_) } @tail_parts ],
        line => $ctx->{line_no},
    });
}

sub _recognize_const {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'const', name => $1, expr => parse_expr(trim($2)), line => $ctx->{line_no} });
}

sub _recognize_let {
    my ($ctx) = @_;
    if ($ctx->{line} =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/) {
        my ($name, $type_raw, $expr) = ($1, trim($2), trim($3));
        return _typed_decl_stmt($ctx, 'let', $name, $type_raw, $expr, "variable '$name'", "Numeric constraints require number type for variable '$name'");
    }
    return undef if $ctx->{line} !~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'let', name => $1, type => undef, constraints => parse_constraints(undef), expr => parse_expr(trim($2)), line => $ctx->{line_no} });
}

sub _recognize_return {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^return\s+(.+)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'return', expr => parse_expr(trim($1)), line => $ctx->{line_no} });
}

sub _recognize_typed_assign {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+?)\s*=\s*(.+)$/;
    my ($name, $type_raw, $expr) = ($1, trim($2), trim($3));
    return _typed_decl_stmt($ctx, 'typed_assign', $name, $type_raw, $expr, "typed assignment for '$name'", "Numeric constraints require number type in typed assignment for '$name'");
}

sub _recognize_assign_op {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\+=\s*(.+)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'assign_op', name => $1, op => '+=', expr => parse_expr(trim($2)), line => $ctx->{line_no} });
}

sub _recognize_incdec {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)(\+\+|--)$/ && $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)\s*(\+\+|--)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'incdec', name => $1, op => $2, line => $ctx->{line_no} });
}

sub _recognize_assign {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'assign', name => $1, expr => parse_expr(trim($2)), line => $ctx->{line_no} });
}

sub _recognize_expr_or_catch {
    my ($ctx) = @_;
    if ($ctx->{line} =~ /^([A-Za-z_][A-Za-z0-9_]*)\(/) {
        my $nested = _recognize_nested_or_catch_call($ctx);
        return $nested if defined($nested);
    }
    return undef if $ctx->{line} !~ /^(.*)\s+or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/;
    my ($inner, $err_name) = (trim($1), $2);
    my $expr = parse_expr($inner);
    compile_error("or catch handler requires function or method call expression") if $expr->{kind} ne 'call' && $expr->{kind} ne 'method_call';
    my $handler_body = _parse_nested_block_stmt($ctx, "or catch handler missing closing brace");
    return _stmt_result({ kind => 'expr_or_catch', expr => $expr, err_name => $err_name, handler => $handler_body, line => $ctx->{line_no} });
}

sub _recognize_nested_or_catch_call {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^([A-Za-z_][A-Za-z0-9_]*)\((.*)\s+or\s+catch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\{$/;
    my ($outer_name, $args_prefix_raw, $err_name) = ($1, trim($2), $3);
    return undef if $args_prefix_raw !~ /,/;
    my @parts = split_top_level_commas($args_prefix_raw);
    return undef if !@parts;
    my $fallible_raw = trim(pop @parts);
    my @outer_args = map { parse_expr(trim($_)) } grep { trim($_) ne '' } @parts;
    ${ $ctx->{idx_ref} }++;
    my $close_idx = _find_nested_handler_close($ctx);
    my @handler_lines = @{ $ctx->{lines} }[${ $ctx->{idx_ref} } .. $close_idx - 1];
    push @handler_lines, '}';
    my $handler_idx = 0;
    my ($handler_body, $end_reason) = parse_block(\@handler_lines, \$handler_idx, $ctx->{base_line});
    compile_error("or catch handler missing closing brace") if $end_reason ne 'close';
    ${ $ctx->{idx_ref} } = $close_idx + 1;
    my $tmp_name = '__orcatch_tmp_' . (defined($ctx->{line_no}) ? $ctx->{line_no} : ${ $ctx->{idx_ref} });
    return _stmt_result(
        { kind => 'const_or_catch', name => $tmp_name, expr => parse_expr($fallible_raw), err_name => $err_name, handler => $handler_body, line => $ctx->{line_no} },
        { kind => 'expr_stmt', expr => { kind => 'call', name => $outer_name, args => [ @outer_args, { kind => 'ident', name => $tmp_name } ] }, line => $ctx->{line_no} },
    );
}

sub _find_nested_handler_close {
    my ($ctx) = @_;
    for (my $scan = ${ $ctx->{idx_ref} }; $scan < @{ $ctx->{lines} }; $scan++) {
        my $scan_line = trim(strip_comments($ctx->{lines}[$scan]));
        return $scan if $scan_line eq '})';
    }
    compile_error("nested or catch call is missing closing '})'");
}

sub _recognize_expr_stmt_try {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /^(.+)\?\s*$/;
    my $expr = parse_expr(trim($1));
    if ($expr->{kind} eq 'call' || $expr->{kind} eq 'method_call') {
        ${ $ctx->{idx_ref} }++;
        return _stmt_result({ kind => 'expr_stmt_try', expr => $expr, line => $ctx->{line_no} });
    }
    compile_error("try expression statement requires function or method call");
}

sub _recognize_expr_stmt {
    my ($ctx) = @_;
    return undef if $ctx->{line} !~ /\)\s*$/;
    my $expr = parse_expr($ctx->{line});
    return undef if $expr->{kind} ne 'call' && $expr->{kind} ne 'method_call';
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'expr_stmt', expr => $expr, line => $ctx->{line_no} });
}

sub _recognize_raw {
    my ($ctx) = @_;
    ${ $ctx->{idx_ref} }++;
    return _stmt_result({ kind => 'raw', text => $ctx->{line}, line => $ctx->{line_no} });
}

my %RECOGNIZER_FOR = (
    for_lines => \&_recognize_for_lines,
    for_each_try => \&_recognize_for_each_try,
    for_each => \&_recognize_for_each,
    while => \&_recognize_while,
    break => sub { _recognize_simple_control($_[0], 'break') },
    continue => sub { _recognize_simple_control($_[0], 'continue') },
    rewind => sub { _recognize_simple_control($_[0], 'rewind') },
    if => \&_recognize_if,
    destructure_match => \&_recognize_destructure_match,
    destructure_split_or => \&_recognize_destructure_split_or,
    destructure_list => \&_recognize_destructure_list,
    let_producer => \&_recognize_let_producer,
    const_typed => \&_recognize_const_typed,
    const_try_chain => \&_recognize_const_try_chain,
    const_try_expr => \&_recognize_const_try_expr,
    const_or_catch => \&_recognize_const_or_catch,
    const_try_tail_expr => \&_recognize_const_try_tail_expr,
    const => \&_recognize_const,
    let => \&_recognize_let,
    return => \&_recognize_return,
    typed_assign => \&_recognize_typed_assign,
    assign_op => \&_recognize_assign_op,
    incdec => \&_recognize_incdec,
    assign => \&_recognize_assign,
    expr_or_catch => \&_recognize_expr_or_catch,
    expr_stmt_try => \&_recognize_expr_stmt_try,
    expr_stmt => \&_recognize_expr_stmt,
    raw => \&_recognize_raw,
);

sub _parse_registered_statement {
    my ($ctx) = @_;
    for my $entry (@{ statement_recognizers() }) {
        my $parser_id = $entry->{parser_id} // next;
        my $recognizer = $RECOGNIZER_FOR{$parser_id} // next;
        my $result = $recognizer->($ctx);
        return $result if defined($result) && ($result->{matched} // 0);
    }
    return undef;
}

1;
