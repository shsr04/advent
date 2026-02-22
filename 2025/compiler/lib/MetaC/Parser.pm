package MetaC::Parser;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(compile_error strip_comments trim split_top_level_commas parse_constraints);

our @EXPORT_OK = qw(parse_function_header collect_functions parse_function_params parse_capture_groups infer_group_type expr_tokens parse_expr parse_match_statement parse_call_invocation_text parse_iterable_expression parse_block parse_function_body);

sub normalize_type_annotation {
    my ($type) = @_;
    $type = trim($type);
    $type =~ s/\s+//g;
    return 'bool' if $type eq 'boolean';
    return 'number_list' if $type eq 'number[]';
    return 'string_list' if $type eq 'string[]';
    return 'number_or_null' if $type eq 'number|null' || $type eq 'null|number';
    return $type;
}

sub parse_function_header {
    my ($line) = @_;
    return undef if $line !~ /^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/;

    my $name = $1;
    my $open_idx = index($line, '(');
    return undef if $open_idx < 0;

    my @chars = split //, $line;
    my $depth = 0;
    my $close_idx = -1;
    for (my $i = $open_idx; $i < @chars; $i++) {
        my $ch = $chars[$i];
        if ($ch eq '(') {
            $depth++;
        } elsif ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                $close_idx = $i;
                last;
            }
            return undef if $depth < 0;
        }
    }
    return undef if $close_idx < 0 || $depth != 0;

    my $args = trim(substr($line, $open_idx + 1, $close_idx - $open_idx - 1));
    my $rest = trim(substr($line, $close_idx + 1));
    return undef if $rest !~ /\{\s*$/;

    $rest =~ s/\{\s*$//;
    $rest = trim($rest);

    my $return_type;
    if ($rest ne '') {
        return undef if $rest !~ /^:\s*(.+)$/;
        $return_type = trim($1);
    }

    return {
        name        => $name,
        args        => $args,
        return_type => $return_type,
    };
}


sub collect_functions {
    my ($source) = @_;
    my @lines = split /\n/, $source, -1;
    my %functions;
    my $idx = 0;

    while ($idx < @lines) {
        my $line = strip_comments($lines[$idx]);
        $line =~ s/\s+$//;
        my $trimmed = trim($line);

        if ($trimmed eq '') {
            $idx++;
            next;
        }

        my $header = parse_function_header($trimmed);
        if (defined $header) {
            my ($name, $args, $return_type) = ($header->{name}, $header->{args}, $header->{return_type});

            compile_error("Duplicate function definition: $name") if exists $functions{$name};

            my @body;
            my $brace_depth = 1;
            $idx++;

            while ($idx < @lines) {
                my $body_line = strip_comments($lines[$idx]);
                $body_line =~ s/\s+$//;

                my $open_count  = () = $body_line =~ /\{/g;
                my $close_count = () = $body_line =~ /\}/g;
                $brace_depth += $open_count;
                $brace_depth -= $close_count;

                compile_error("Too many closing braces near line " . ($idx + 1))
                  if $brace_depth < 0;

                last if $brace_depth == 0;

                push @body, $body_line;
                $idx++;
            }

            compile_error("Unterminated function body for '$name'") if $brace_depth != 0;

            $functions{$name} = {
                name        => $name,
                args        => $args,
                return_type => $return_type,
                body_lines  => \@body,
            };

            $idx++;
            next;
        }

        compile_error("Unexpected top-level syntax on line " . ($idx + 1) . ": $trimmed");
    }

    return \%functions;
}


sub parse_function_params {
    my ($fn) = @_;
    my $args = trim($fn->{args});
    return [] if $args eq '';

    my $parts = split_top_level_commas($args);
    my @params;
    my %seen;

    for my $part (@$parts) {
        $part =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string|bool|boolean|number\s*\|\s*null|null\s*\|\s*number)(?:\s+with\s+(.+))?$/
          or compile_error("Invalid parameter declaration in function '$fn->{name}': $part");

        my ($name, $type, $constraint_raw) = ($1, $2, $3);
        $type = normalize_type_annotation($type);
        compile_error("Duplicate parameter '$name' in function '$fn->{name}'")
          if $seen{$name};
        $seen{$name} = 1;

        my $constraints = parse_constraints($constraint_raw);
        if (($constraints->{positive} || $constraints->{negative} || defined $constraints->{range} || $constraints->{wrap}) && $type ne 'number') {
            compile_error("Numeric constraints require number type for parameter '$name' in function '$fn->{name}'");
        }

        push @params, {
            name        => $name,
            type        => $type,
            constraints => $constraints,
            c_in_name   => "__metac_in_$name",
        };
    }

    return \@params;
}


sub parse_capture_groups {
    my ($pattern) = @_;
    my @groups;
    my @chars = split //, $pattern;
    my $in_class = 0;
    my $escape = 0;

    for (my $i = 0; $i < @chars; $i++) {
        my $ch = $chars[$i];

        if ($escape) {
            $escape = 0;
            next;
        }

        if ($ch eq '\\') {
            $escape = 1;
            next;
        }

        if ($ch eq '[') {
            $in_class = 1;
            next;
        }

        if ($ch eq ']') {
            $in_class = 0;
            next;
        }

        next if $in_class;

        next if $ch ne '(';
        next if ($i + 1 < @chars && $chars[$i + 1] eq '?');

        my $depth = 1;
        my $j = $i + 1;
        my $group = '';
        my $inner_class = 0;
        my $inner_escape = 0;

        while ($j < @chars) {
            my $c = $chars[$j];

            if ($inner_escape) {
                $group .= $c;
                $inner_escape = 0;
                $j++;
                next;
            }

            if ($c eq '\\') {
                $group .= $c;
                $inner_escape = 1;
                $j++;
                next;
            }

            if ($c eq '[') {
                $inner_class = 1;
                $group .= $c;
                $j++;
                next;
            }

            if ($c eq ']') {
                $inner_class = 0;
                $group .= $c;
                $j++;
                next;
            }

            if (!$inner_class && $c eq '(') {
                $depth++;
                $group .= $c;
                $j++;
                next;
            }

            if (!$inner_class && $c eq ')') {
                $depth--;
                last if $depth == 0;
                $group .= $c;
                $j++;
                next;
            }

            $group .= $c;
            $j++;
        }

        compile_error("Unterminated capture group in regex: /$pattern/") if $j >= @chars;

        push @groups, $group;
        $i = $j;
    }

    return \@groups;
}


sub infer_group_type {
    my ($group) = @_;
    my $g = trim($group);
    return 'number' if $g =~ /^\[0-9\](\+|\*)?$/;
    return 'number' if $g =~ /^\\d(\+|\*)?$/;
    return 'string';
}


sub expr_tokens {
    my ($expr) = @_;
    my @tokens;
    pos($expr) = 0;

    while (pos($expr) < length($expr)) {
        if ($expr =~ /\G\s+/gc) {
            next;
        }
        if ($expr =~ /\G<=/gc) {
            push @tokens, { type => 'op', value => '<=' };
            next;
        }
        if ($expr =~ /\G=>/gc) {
            push @tokens, { type => 'op', value => '=>' };
            next;
        }
        if ($expr =~ /\G>=/gc) {
            push @tokens, { type => 'op', value => '>=' };
            next;
        }
        if ($expr =~ /\G==/gc) {
            push @tokens, { type => 'op', value => '==' };
            next;
        }
        if ($expr =~ /\G!=/gc) {
            push @tokens, { type => 'op', value => '!=' };
            next;
        }
        if ($expr =~ /\G\|\|/gc) {
            push @tokens, { type => 'op', value => '||' };
            next;
        }
        if ($expr =~ /\G[<>,\+\-\*\/%\.\(\)\[\]]/gc) {
            push @tokens, { type => 'op', value => $& };
            next;
        }
        if ($expr =~ /\G"((?:\\.|[^"\\])*)"/gc) {
            push @tokens, { type => 'str', value => $&, raw => $1 };
            next;
        }
        if ($expr =~ /\G\d+/gc) {
            push @tokens, { type => 'num', value => $& };
            next;
        }
        if ($expr =~ /\G[A-Za-z_][A-Za-z0-9_]*/gc) {
            push @tokens, { type => 'ident', value => $& };
            next;
        }

        my $remaining = substr($expr, pos($expr));
        compile_error("Invalid token in expression: $remaining");
    }

    return \@tokens;
}


sub parse_expr {
    my ($expr) = @_;
    my $tokens = expr_tokens($expr);
    my $idx = 0;

    my $peek = sub {
        return undef if $idx >= @$tokens;
        return $tokens->[$idx];
    };

    my $accept_op = sub {
        my ($op) = @_;
        my $tok = $peek->();
        return 0 if !defined $tok;
        return 0 if $tok->{type} ne 'op' || $tok->{value} ne $op;
        $idx++;
        return 1;
    };

    my $expect_op = sub {
        my ($op, $ctx) = @_;
        compile_error("Expected '$op' in expression" . (defined($ctx) ? " ($ctx)" : ""))
          if !$accept_op->($op);
    };

    my $parse_atom;
    my $parse_primary;
    my $parse_unary;
    my $parse_mul;
    my $parse_add;
    my $parse_cmp;
    my $parse_eq;
    my $parse_or;
    my $parse_lambda;

    $parse_atom = sub {
        my $tok = $peek->();
        compile_error("Unexpected end of expression") if !defined $tok;

        if ($tok->{type} eq 'num') {
            $idx++;
            return { kind => 'num', value => $tok->{value} };
        }
        if ($tok->{type} eq 'str') {
            $idx++;
            return { kind => 'str', value => $tok->{value}, raw => $tok->{raw} };
        }
        if ($tok->{type} eq 'ident') {
            my $name = $tok->{value};
            $idx++;

            if ($name eq 'true' || $name eq 'false') {
                return {
                    kind  => 'bool',
                    value => ($name eq 'true') ? 1 : 0,
                };
            }
            if ($name eq 'null') {
                return { kind => 'null' };
            }

            if ($accept_op->('(')) {
                my @args;
                if (!$accept_op->(')')) {
                    while (1) {
                        push @args, $parse_lambda->();
                        if ($accept_op->(')')) {
                            last;
                        }
                        $expect_op->(',', "after function-call argument");
                    }
                }
                return { kind => 'call', name => $name, args => \@args };
            }

            return { kind => 'ident', name => $name };
        }
        if ($accept_op->('(')) {
            my $inner = $parse_lambda->();
            $expect_op->(')', "to close parenthesized expression");
            return $inner;
        }

        if ($accept_op->('[')) {
            my @items;
            if (!$accept_op->(']')) {
                while (1) {
                    push @items, $parse_lambda->();
                    if ($accept_op->(']')) {
                        last;
                    }
                    $expect_op->(',', "after list-literal item");
                }
            }
            return {
                kind  => 'list_literal',
                items => \@items,
            };
        }

        compile_error("Unexpected token in expression: $tok->{value}");
    };

    $parse_primary = sub {
        my $node = $parse_atom->();

        while (1) {
            if ($accept_op->('.')) {
                my $name_tok = $peek->();
                compile_error("Expected method name after '.' in expression")
                  if !defined($name_tok) || $name_tok->{type} ne 'ident';
                my $method = $name_tok->{value};
                $idx++;

                $expect_op->('(', "after method name");
                my @args;
                if (!$accept_op->(')')) {
                    while (1) {
                        push @args, $parse_lambda->();
                        if ($accept_op->(')')) {
                            last;
                        }
                        $expect_op->(',', "after method-call argument");
                    }
                }

                $node = {
                    kind   => 'method_call',
                    recv   => $node,
                    method => $method,
                    args   => \@args,
                };
                next;
            }

            if ($accept_op->('[')) {
                my $index_expr = $parse_lambda->();
                $expect_op->(']', "to close index expression");
                $node = {
                    kind  => 'index',
                    recv  => $node,
                    index => $index_expr,
                };
                next;
            }

            last;
        }

        return $node;
    };

    $parse_unary = sub {
        if ($accept_op->('-')) {
            my $inner = $parse_unary->();
            return { kind => 'unary', op => '-', expr => $inner };
        }
        return $parse_primary->();
    };

    $parse_mul = sub {
        my $left = $parse_unary->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || ($tok->{value} ne '*' && $tok->{value} ne '/' && $tok->{value} ne '%');
            my $op = $tok->{value};
            $idx++;
            my $right = $parse_unary->();
            $left = { kind => 'binop', op => $op, left => $left, right => $right };
        }
        return $left;
    };

    $parse_add = sub {
        my $left = $parse_mul->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || ($tok->{value} ne '+' && $tok->{value} ne '-');
            my $op = $tok->{value};
            $idx++;
            my $right = $parse_mul->();
            $left = { kind => 'binop', op => $op, left => $left, right => $right };
        }
        return $left;
    };

    $parse_cmp = sub {
        my $left = $parse_add->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op';
            my $op = $tok->{value};
            last if $op ne '<' && $op ne '>' && $op ne '<=' && $op ne '>=';
            $idx++;
            my $right = $parse_add->();
            $left = { kind => 'binop', op => $op, left => $left, right => $right };
        }
        return $left;
    };

    $parse_eq = sub {
        my $left = $parse_cmp->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || ($tok->{value} ne '==' && $tok->{value} ne '!=');
            my $op = $tok->{value};
            $idx++;
            my $right = $parse_cmp->();
            $left = { kind => 'binop', op => $op, left => $left, right => $right };
        }
        return $left;
    };

    $parse_or = sub {
        my $left = $parse_eq->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || $tok->{value} ne '||';
            $idx++;
            my $right = $parse_eq->();
            $left = { kind => 'binop', op => '||', left => $left, right => $right };
        }
        return $left;
    };

    $parse_lambda = sub {
        my $tok = $peek->();

        if (defined($tok) && $tok->{type} eq 'op' && $tok->{value} eq '(') {
            my $save_idx = $idx;
            $idx++;

            my $first = $peek->();
            if (defined($first) && $first->{type} eq 'ident') {
                my $param1 = $first->{value};
                $idx++;
                if ($accept_op->(',')) {
                    my $second = $peek->();
                    if (defined($second) && $second->{type} eq 'ident') {
                        my $param2 = $second->{value};
                        $idx++;
                        if ($accept_op->(')') && $accept_op->('=>')) {
                            compile_error("Two-parameter lambda parameter names must be distinct")
                              if $param1 eq $param2;
                            my $body = $parse_lambda->();
                            return {
                                kind   => 'lambda2',
                                param1 => $param1,
                                param2 => $param2,
                                body   => $body,
                            };
                        }
                    }
                }
            }
            $idx = $save_idx;
        }

        my $next = ($idx + 1 < @$tokens) ? $tokens->[$idx + 1] : undef;
        if (defined($tok) && defined($next) && $tok->{type} eq 'ident' && $next->{type} eq 'op' && $next->{value} eq '=>') {
            my $param = $tok->{value};
            $idx += 2;
            my $body = $parse_lambda->();
            return {
                kind  => 'lambda1',
                param => $param,
                body  => $body,
            };
        }
        return $parse_or->();
    };

    my $ast = $parse_lambda->();
    compile_error("Unexpected trailing expression tokens") if $idx < @$tokens;
    return $ast;
}


sub parse_match_statement {
    my ($line) = @_;
    return undef
      if $line !~ /^const\s*\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\]\s*=\s*match\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*\/(.*)\/\s*\)\?\s*$/;

    my ($vars_raw, $source_var, $pattern) = ($1, $2, $3);
    my @vars = map { trim($_) } split /\s*,\s*/, $vars_raw;
    return {
        kind       => 'destructure_match',
        vars       => \@vars,
        source_var => $source_var,
        pattern    => $pattern,
    };
}


sub parse_call_invocation_text {
    my ($text, $name) = @_;
    my $src = trim($text);
    my $prefix = $name . '(';
    return undef if index($src, $prefix) != 0;

    my $open_idx = length($name);
    my @chars = split //, $src;
    my $depth = 0;
    my $close_idx = -1;

    for (my $i = $open_idx; $i < @chars; $i++) {
        my $ch = $chars[$i];
        if ($ch eq '(') {
            $depth++;
            next;
        }
        if ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                $close_idx = $i;
                last;
            }
            return undef if $depth < 0;
            next;
        }
    }

    return undef if $close_idx < 0 || $depth != 0;

    my $inside = substr($src, $open_idx + 1, $close_idx - $open_idx - 1);
    my $rest = trim(substr($src, $close_idx + 1));
    my $arg_parts = split_top_level_commas($inside);
    return {
        name => $name,
        args => $arg_parts,
        rest => $rest,
    };
}

sub split_try_chain_segments {
    my ($text) = @_;
    my @parts;
    my $current = '';
    my $depth = 0;
    my $in_string = 0;
    my $escape = 0;
    my @chars = split //, $text;

    for (my $i = 0; $i < @chars; $i++) {
        my $ch = $chars[$i];

        if ($in_string) {
            $current .= $ch;
            if ($escape) {
                $escape = 0;
                next;
            }
            if ($ch eq '\\') {
                $escape = 1;
                next;
            }
            if ($ch eq '"') {
                $in_string = 0;
            }
            next;
        }

        if ($ch eq '"') {
            $in_string = 1;
            $current .= $ch;
            next;
        }

        if ($ch eq '(') {
            $depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ')') {
            $depth--;
            compile_error("Unbalanced ')' in try-chain expression") if $depth < 0;
            $current .= $ch;
            next;
        }

        if ($depth == 0 && $ch eq '?' && $i + 1 < @chars && $chars[$i + 1] eq '.') {
            push @parts, trim($current);
            $current = '';
            $i++;
            next;
        }

        $current .= $ch;
    }

    compile_error("Unbalanced '(' in try-chain expression") if $depth != 0;
    push @parts, trim($current) if trim($current) ne '';
    return \@parts;
}

sub parse_method_step {
    my ($text) = @_;
    my $src = trim($text);
    $src =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\(/
      or compile_error("Invalid method step in try-chain: $src");
    my $name = $1;
    my $call = parse_call_invocation_text($src, $name);
    compile_error("Invalid method step in try-chain: $src")
      if !defined($call) || $call->{rest} ne '';

    my @args;
    for my $arg_raw (@{ $call->{args} }) {
        my $arg = trim($arg_raw);
        push @args, parse_expr($arg);
    }
    return {
        name => $name,
        args => \@args,
    };
}


sub parse_iterable_expression {
    my ($raw) = @_;
    my $text = trim($raw);
    return parse_expr($text);
}


sub parse_block {
    my ($lines, $idx_ref) = @_;
    my @stmts;

    while ($$idx_ref < @$lines) {
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

        if ($line =~ /^for\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+lines\s*\(\s*STDIN\s*\)\?\s*\{$/) {
            my $var = $1;
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, { kind => 'for_lines', var => $var, body => $body };
            next;
        }

        if ($line =~ /^for\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\s*\{$/) {
            my ($var, $iter_raw) = ($1, trim($2));
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, {
                kind     => 'for_each',
                var      => $var,
                iterable => parse_iterable_expression($iter_raw),
                body     => $body,
            };
            next;
        }

        if ($line =~ /^while\s+(.+)\s*\{$/) {
            my $cond = trim($1);
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref);
            compile_error("while-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, { kind => 'while', cond => parse_expr($cond), body => $body };
            next;
        }

        if ($line eq 'break') {
            push @stmts, { kind => 'break' };
            $$idx_ref++;
            next;
        }

        if ($line eq 'continue') {
            push @stmts, { kind => 'continue' };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^if\s+(.+)\s*\{$/) {
            my $cond = trim($1);
            $$idx_ref++;
            my ($then_body, $end_reason) = parse_block($lines, $idx_ref);

            if ($end_reason eq 'close') {
                push @stmts, { kind => 'if', cond => parse_expr($cond), then_body => $then_body, else_body => undef };
                next;
            }

            if ($end_reason eq 'close_else') {
                my ($else_body, $end2) = parse_block($lines, $idx_ref);
                compile_error("if-else missing closing brace") if $end2 ne 'close';
                push @stmts, { kind => 'if', cond => parse_expr($cond), then_body => $then_body, else_body => $else_body };
                next;
            }

            compile_error("Invalid if-block termination");
        }

        my $match_stmt = parse_match_statement($line);
        if (defined $match_stmt) {
            push @stmts, $match_stmt;
            $$idx_ref++;
            next;
        }

        if ($line =~ /^const\s*\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\]\s*=\s*(.+)$/) {
            my ($vars_raw, $rhs) = ($1, trim($2));
            my @vars = map { trim($_) } split /\s*,\s*/, $vars_raw;
            my $split = parse_call_invocation_text($rhs, 'split');
            if (defined $split && $split->{rest} =~ /^or\s+\(([A-Za-z_][A-Za-z0-9_]*)\)\s*=>\s*\{$/) {
                my $err_name = $1;
                compile_error("split(...) in destructure expects exactly 2 args")
                  if scalar(@{ $split->{args} }) != 2;

                $$idx_ref++;
                my ($handler_body, $end_reason) = parse_block($lines, $idx_ref);
                compile_error("split destructure handler missing closing brace") if $end_reason ne 'close';

                push @stmts, {
                    kind        => 'destructure_split_or',
                    vars        => \@vars,
                    source_expr => parse_expr($split->{args}[0]),
                    delim_expr  => parse_expr($split->{args}[1]),
                    err_name    => $err_name,
                    handler     => $handler_body,
                };
                next;
            }

            push @stmts, {
                kind => 'destructure_list',
                vars => \@vars,
                expr => parse_expr($rhs),
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)\s+from\s*\(\s*\)\s*=>\s*\{$/) {
            my ($name, $type) = ($1, $2);
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref);
            compile_error("producer initialization missing closing brace for '$name'") if $end_reason ne 'close';
            push @stmts, {
                kind => 'let_producer',
                name => $name,
                type => $type,
                body => $body,
            };
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
                };
                $$idx_ref++;
                next;
            }
            push @stmts, {
                kind => 'const_try_expr',
                name => $name,
                expr => parse_expr($inner),
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            my ($name, $rhs) = ($1, trim($2));
            my $split = parse_call_invocation_text($rhs, 'split');
            if (defined $split && $split->{rest} eq '?') {
                compile_error("split(...) with '?' expects exactly 2 args")
                  if scalar(@{ $split->{args} }) != 2;
                push @stmts, {
                    kind        => 'const_split_try',
                    name        => $name,
                    source_expr => parse_expr($split->{args}[0]),
                    delim_expr  => parse_expr($split->{args}[1]),
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
                };
                $$idx_ref++;
                next;
            }

            push @stmts, { kind => 'const', name => $name, expr => parse_expr($rhs) };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string|bool|boolean|number\[\]|string\[\]|number\s*\|\s*null|null\s*\|\s*number)(?:\s+with\s+(.+?))?\s*=\s*(.+)$/) {
            my ($name, $type, $constraint_raw, $expr) = ($1, $2, $3, trim($4));
            $type = normalize_type_annotation($type);
            my $constraints = parse_constraints($constraint_raw);
            if (($constraints->{positive} || $constraints->{negative} || defined $constraints->{range} || $constraints->{wrap}) && $type ne 'number') {
                compile_error("Numeric constraints require number type for variable '$name'");
            }
            push @stmts, {
                kind        => 'let',
                name        => $name,
                type        => $type,
                constraints => $constraints,
                expr        => parse_expr($expr),
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
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^return\s+(.+)$/) {
            push @stmts, { kind => 'return', expr => parse_expr(trim($1)) };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string|bool|boolean|number\[\]|string\[\]|number\s*\|\s*null|null\s*\|\s*number)(?:\s+with\s+(.+?))?\s*=\s*(.+)$/) {
            my ($name, $type, $constraint_raw, $expr) = ($1, $2, $3, trim($4));
            $type = normalize_type_annotation($type);
            my $constraints = parse_constraints($constraint_raw);
            if (($constraints->{positive} || $constraints->{negative} || defined $constraints->{range} || $constraints->{wrap}) && $type ne 'number') {
                compile_error("Numeric constraints require number type in typed assignment for '$name'");
            }
            push @stmts, {
                kind        => 'typed_assign',
                name        => $name,
                type        => $type,
                constraints => $constraints,
                expr        => parse_expr($expr),
            };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\+=\s*(.+)$/) {
            push @stmts, { kind => 'assign_op', name => $1, op => '+=', expr => parse_expr(trim($2)) };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\+\+$/) {
            push @stmts, { kind => 'incdec', name => $1, op => '++' };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*--$/) {
            push @stmts, { kind => 'incdec', name => $1, op => '--' };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            push @stmts, { kind => 'assign', name => $1, expr => parse_expr(trim($2)) };
            $$idx_ref++;
            next;
        }

        if ($line =~ /\)\s*$/) {
            my $expr = parse_expr($line);
            if ($expr->{kind} eq 'call' || $expr->{kind} eq 'method_call') {
                push @stmts, { kind => 'expr_stmt', expr => $expr };
                $$idx_ref++;
                next;
            }
        }

        push @stmts, { kind => 'raw', text => $line };
        $$idx_ref++;
    }

    return (\@stmts, 'eof');
}


sub parse_function_body {
    my ($fn) = @_;
    my $idx = 0;
    my ($stmts, $reason) = parse_block($fn->{body_lines}, \$idx);
    compile_error("Unexpected '}' in function '$fn->{name}'") if $reason ne 'eof';
    return $stmts;
}


1;
