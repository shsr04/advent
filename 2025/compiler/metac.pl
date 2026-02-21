#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use File::Path qw(make_path);

sub compile_error {
    my ($msg) = @_;
    die "compile error: $msg\n";
}

sub strip_comments {
    my ($line) = @_;
    $line =~ s{//.*$}{};
    return $line;
}

sub trim {
    my ($s) = @_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub c_escape_string {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return '"' . $s . '"';
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

sub split_top_level_commas {
    my ($text) = @_;
    my @parts;
    my $current = '';
    my $depth = 0;
    my @chars = split //, $text;

    for my $ch (@chars) {
        if ($ch eq '(') {
            $depth++;
            $current .= $ch;
            next;
        }
        if ($ch eq ')') {
            $depth--;
            compile_error("Unbalanced ')' in parameter list") if $depth < 0;
            $current .= $ch;
            next;
        }
        if ($ch eq ',' && $depth == 0) {
            push @parts, trim($current);
            $current = '';
            next;
        }
        $current .= $ch;
    }

    compile_error("Unbalanced '(' in parameter list") if $depth != 0;
    push @parts, trim($current) if trim($current) ne '';
    return \@parts;
}

sub parse_constraints {
    my ($raw) = @_;
    my %constraints = (
        range    => undef,
        wrap     => 0,
        positive => 0,
        negative => 0,
    );

    return \%constraints if !defined $raw || trim($raw) eq '';

    my @terms = map { trim($_) } split /\s*\+\s*/, $raw;
    for my $term (@terms) {
        if ($term =~ /^range\s*\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)$/) {
            $constraints{range} = { min => int($1), max => int($2) };
            next;
        }
        if ($term eq 'wrap') {
            $constraints{wrap} = 1;
            next;
        }
        if ($term eq 'positive') {
            $constraints{positive} = 1;
            next;
        }
        if ($term eq 'negative') {
            $constraints{negative} = 1;
            next;
        }
        compile_error("Unsupported constraint term: $term");
    }

    compile_error("Constraint conflict: cannot require both positive and negative")
      if $constraints{positive} && $constraints{negative};

    return \%constraints;
}

sub parse_function_params {
    my ($fn) = @_;
    my $args = trim($fn->{args});
    return [] if $args eq '';

    my $parts = split_top_level_commas($args);
    my @params;
    my %seen;

    for my $part (@$parts) {
        $part =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)(?:\s+with\s+(.+))?$/
          or compile_error("Invalid parameter declaration in function '$fn->{name}': $part");

        my ($name, $type, $constraint_raw) = ($1, $2, $3);
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
        if ($expr =~ /\G>=/gc) {
            push @tokens, { type => 'op', value => '>=' };
            next;
        }
        if ($expr =~ /\G==/gc) {
            push @tokens, { type => 'op', value => '==' };
            next;
        }
        if ($expr =~ /\G[<>,\+\-\(\)]/gc) {
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

    my $parse_primary;
    my $parse_unary;
    my $parse_add;
    my $parse_cmp;
    my $parse_eq;

    $parse_primary = sub {
        my $tok = $peek->();
        compile_error("Unexpected end of expression") if !defined $tok;

        if ($tok->{type} eq 'num') {
            $idx++;
            return { kind => 'num', value => $tok->{value} };
        }
        if ($tok->{type} eq 'str') {
            $idx++;
            return { kind => 'str', value => $tok->{value} };
        }
        if ($tok->{type} eq 'ident') {
            my $name = $tok->{value};
            $idx++;

            if ($accept_op->('(')) {
                my @args;
                if (!$accept_op->(')')) {
                    while (1) {
                        push @args, $parse_eq->();
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
            my $inner = $parse_eq->();
            $expect_op->(')', "to close parenthesized expression");
            return $inner;
        }

        compile_error("Unexpected token in expression: $tok->{value}");
    };

    $parse_unary = sub {
        if ($accept_op->('-')) {
            my $inner = $parse_unary->();
            return { kind => 'unary', op => '-', expr => $inner };
        }
        return $parse_primary->();
    };

    $parse_add = sub {
        my $left = $parse_unary->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || ($tok->{value} ne '+' && $tok->{value} ne '-');
            my $op = $tok->{value};
            $idx++;
            my $right = $parse_unary->();
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
            last if !defined $tok || $tok->{type} ne 'op' || $tok->{value} ne '==';
            my $op = $tok->{value};
            $idx++;
            my $right = $parse_cmp->();
            $left = { kind => 'binop', op => $op, left => $left, right => $right };
        }
        return $left;
    };

    my $ast = $parse_eq->();
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

        if ($line eq '}') {
            $$idx_ref++;
            return (\@stmts, 'close');
        }

        if ($line =~ /^\}\s*else\s*\{$/) {
            $$idx_ref++;
            return (\@stmts, 'close_else');
        }

        if ($line =~ /^for\s+const\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+lines\s*\(\s*STDIN\s*\)\?\s*\{$/) {
            my $var = $1;
            $$idx_ref++;
            my ($body, $end_reason) = parse_block($lines, $idx_ref);
            compile_error("for-loop missing closing brace") if $end_reason ne 'close';
            push @stmts, { kind => 'for_lines', var => $var, body => $body };
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

        if ($line =~ /^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/) {
            push @stmts, { kind => 'const', name => $1, expr => parse_expr(trim($2)) };
            $$idx_ref++;
            next;
        }

        if ($line =~ /^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)(?:\s+with\s+(.+?))?\s*=\s*(.+)$/) {
            my ($name, $type, $constraint_raw, $expr) = ($1, $2, $3, trim($4));
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

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(number|string)(?:\s+with\s+(.+?))?\s*=\s*(.+)$/) {
            my ($name, $type, $constraint_raw, $expr) = ($1, $2, $3, trim($4));
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

sub producer_definitely_assigns {
    my ($stmts, $target) = @_;
    my $assigned = 0;

    for my $stmt (@$stmts) {
        if (($stmt->{kind} eq 'typed_assign' || $stmt->{kind} eq 'assign') && $stmt->{name} eq $target) {
            $assigned = 1;
            last;
        }

        if ($stmt->{kind} eq 'if' && defined $stmt->{else_body}) {
            my $then_ok = producer_definitely_assigns($stmt->{then_body}, $target);
            my $else_ok = producer_definitely_assigns($stmt->{else_body}, $target);
            if ($then_ok && $else_ok) {
                $assigned = 1;
                last;
            }
        }
    }

    return $assigned;
}

sub param_c_type {
    my ($param) = @_;
    return 'int' if $param->{type} eq 'number';
    return 'const char *' if $param->{type} eq 'string';
    compile_error("Unsupported parameter type: $param->{type}");
}

sub render_c_params {
    my ($params) = @_;
    return 'void' if !@$params;
    return join(', ', map { param_c_type($_) . ' ' . $_->{c_in_name} } @$params);
}

sub new_scope {
    my ($ctx) = @_;
    push @{ $ctx->{scopes} }, {};
}

sub pop_scope {
    my ($ctx) = @_;
    pop @{ $ctx->{scopes} };
}

sub lookup_var {
    my ($ctx, $name) = @_;
    for (my $i = $#{ $ctx->{scopes} }; $i >= 0; $i--) {
        my $scope = $ctx->{scopes}[$i];
        return $scope->{$name} if exists $scope->{$name};
    }
    return undef;
}

sub declare_var {
    my ($ctx, $name, $info) = @_;
    my $scope = $ctx->{scopes}[-1];
    compile_error("Variable already declared in this scope: $name") if exists $scope->{$name};
    $info->{c_name} = $name if !exists $info->{c_name};
    $info->{immutable} = 0 if !exists $info->{immutable};
    $scope->{$name} = $info;
}

sub expr_condition_flags {
    my ($expr, $ctx) = @_;
    my %flags = (
        has_comparison => 0,
        has_immutable  => 0,
        has_mutable    => 0,
    );

    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable in condition analysis: $expr->{name}")
          if !defined $info;
        if ($info->{immutable}) {
            $flags{has_immutable} = 1;
        } else {
            $flags{has_mutable} = 1;
        }
        return \%flags;
    }

    if ($expr->{kind} eq 'num' || $expr->{kind} eq 'str') {
        return \%flags;
    }

    if ($expr->{kind} eq 'unary') {
        return expr_condition_flags($expr->{expr}, $ctx);
    }

    if ($expr->{kind} eq 'call') {
        for my $arg (@{ $expr->{args} }) {
            my $sub = expr_condition_flags($arg, $ctx);
            $flags{has_comparison} ||= $sub->{has_comparison};
            $flags{has_immutable}  ||= $sub->{has_immutable};
            $flags{has_mutable}    ||= $sub->{has_mutable};
        }
        return \%flags;
    }

    if ($expr->{kind} eq 'binop') {
        my $left = expr_condition_flags($expr->{left}, $ctx);
        my $right = expr_condition_flags($expr->{right}, $ctx);

        $flags{has_comparison} = $left->{has_comparison} || $right->{has_comparison};
        $flags{has_immutable} = $left->{has_immutable} || $right->{has_immutable};
        $flags{has_mutable} = $left->{has_mutable} || $right->{has_mutable};

        if ($expr->{op} eq '==' || $expr->{op} eq '<' || $expr->{op} eq '>' || $expr->{op} eq '<=' || $expr->{op} eq '>=') {
            $flags{has_comparison} = 1;
        }

        return \%flags;
    }

    return \%flags;
}

sub enforce_condition_diagnostics {
    my ($expr, $ctx, $where) = @_;
    my $flags = expr_condition_flags($expr, $ctx);

    if ($flags->{has_comparison} && $flags->{has_immutable} && !$flags->{has_mutable}) {
        compile_error("Conditional comparison in $where depends only on immutable values");
    }
}

sub compile_expr {
    my ($expr, $ctx) = @_;

    if ($expr->{kind} eq 'num') {
        return ($expr->{value}, 'number');
    }
    if ($expr->{kind} eq 'str') {
        return ($expr->{value}, 'string');
    }
    if ($expr->{kind} eq 'ident') {
        my $info = lookup_var($ctx, $expr->{name});
        compile_error("Unknown variable: $expr->{name}") if !defined $info;
        return ($info->{c_name}, $info->{type});
    }
    if ($expr->{kind} eq 'unary') {
        my ($inner_code, $inner_type) = compile_expr($expr->{expr}, $ctx);
        if ($expr->{op} eq '-') {
            compile_error("Unary '-' requires number operand") if $inner_type ne 'number';
            return ("(-$inner_code)", 'number');
        }
        compile_error("Unsupported unary operator: $expr->{op}");
    }
    if ($expr->{kind} eq 'call') {
        my $functions = $ctx->{functions} // {};
        my $sig = $functions->{ $expr->{name} };
        if (!defined $sig) {
            if ($expr->{name} eq 'max' || $expr->{name} eq 'min') {
                my $actual = scalar @{ $expr->{args} };
                compile_error("Builtin '$expr->{name}' expects 2 args, got $actual")
                  if $actual != 2;
                my ($a_code, $a_type) = compile_expr($expr->{args}[0], $ctx);
                my ($b_code, $b_type) = compile_expr($expr->{args}[1], $ctx);
                compile_error("Builtin '$expr->{name}' requires number args")
                  if $a_type ne 'number' || $b_type ne 'number';
                return ("metac_$expr->{name}($a_code, $b_code)", 'number');
            }
            compile_error("Unknown function in expression: $expr->{name}");
        }

        my $return_type = $sig->{return_type};
        compile_error("Function '$expr->{name}' returning '$return_type' is not expression-callable")
          if $return_type ne 'number';

        my $expected = scalar @{ $sig->{params} };
        my $actual = scalar @{ $expr->{args} };
        compile_error("Function '$expr->{name}' expects $expected args, got $actual")
          if $expected != $actual;

        my @arg_code;
        for (my $i = 0; $i < $expected; $i++) {
            my ($arg_c, $arg_t) = compile_expr($expr->{args}[$i], $ctx);
            my $param_t = $sig->{params}[$i]{type};
            compile_error("Arg " . ($i + 1) . " to '$expr->{name}' must be $param_t, got $arg_t")
              if $arg_t ne $param_t;
            push @arg_code, $arg_c;
        }

        return ("$expr->{name}(" . join(', ', @arg_code) . ")", 'number');
    }
    if ($expr->{kind} eq 'binop') {
        my ($l_code, $l_type) = compile_expr($expr->{left}, $ctx);
        my ($r_code, $r_type) = compile_expr($expr->{right}, $ctx);

        if ($expr->{op} eq '+' || $expr->{op} eq '-') {
            compile_error("Operator '$expr->{op}' requires number operands")
              if $l_type ne 'number' || $r_type ne 'number';
            return ("($l_code $expr->{op} $r_code)", 'number');
        }

        if ($expr->{op} eq '==') {
            compile_error("Type mismatch in '==': $l_type vs $r_type") if $l_type ne $r_type;
            return ("($l_code == $r_code)", 'bool') if $l_type eq 'number';
            return ("metac_streq($l_code, $r_code)", 'bool') if $l_type eq 'string';
            compile_error("Unsupported '==' operand type: $l_type");
        }
        if ($expr->{op} eq '<' || $expr->{op} eq '>' || $expr->{op} eq '<=' || $expr->{op} eq '>=') {
            compile_error("Operator '$expr->{op}' requires number operands")
              if $l_type ne 'number' || $r_type ne 'number';
            return ("($l_code $expr->{op} $r_code)", 'bool');
        }

        compile_error("Unsupported binary operator: $expr->{op}");
    }

    compile_error("Unsupported expression kind: $expr->{kind}");
}

sub emit_line {
    my ($out, $indent, $text) = @_;
    push @$out, (' ' x $indent) . $text;
}

sub compile_block {
    my ($stmts, $ctx, $out, $indent, $current_fn_return) = @_;

    for my $stmt (@$stmts) {
        if ($stmt->{kind} eq 'let') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            my $decl_type = defined($stmt->{type}) ? $stmt->{type} : $expr_type;
            if (defined $stmt->{type}) {
                compile_error("Type mismatch in let '$stmt->{name}': expected $stmt->{type}, got $expr_type")
                  if $expr_type ne $stmt->{type};
            }

            my $constraints = $stmt->{constraints} // parse_constraints(undef);
            if (($constraints->{positive} || $constraints->{negative} || defined $constraints->{range} || $constraints->{wrap}) && $decl_type ne 'number') {
                compile_error("Numeric constraints require number type for variable '$stmt->{name}'");
            }

            if ($decl_type eq 'number') {
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if (defined $constraints->{range} && !$constraints->{wrap}) {
                        compile_error("range($constraints->{range}{min},$constraints->{range}{max}) variable '$stmt->{name}' initialized out of range")
                          if $v < $constraints->{range}{min} || $v > $constraints->{range}{max};
                    }
                    compile_error("Variable '$stmt->{name}' requires positive value")
                      if $constraints->{positive} && $v <= 0;
                    compile_error("Variable '$stmt->{name}' requires negative value")
                      if $constraints->{negative} && $v >= 0;
                }

                my $init_expr = $expr_code;
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $init_expr = "metac_wrap_range($init_expr, $constraints->{range}{min}, $constraints->{range}{max})";
                }
                emit_line($out, $indent, "int $stmt->{name} = $init_expr;");
            } elsif ($decl_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } elsif ($decl_type eq 'bool') {
                emit_line($out, $indent, "int $stmt->{name} = $expr_code;");
            } else {
                compile_error("Unsupported let type: $decl_type");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type        => $decl_type,
                    constraints => $constraints,
                    immutable   => 0,
                }
            );
            next;
        }

        if ($stmt->{kind} eq 'const') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($expr_type eq 'number') {
                emit_line($out, $indent, "const int $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'bool') {
                emit_line($out, $indent, "const int $stmt->{name} = $expr_code;");
            } elsif ($expr_type eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "metac_copy_str($stmt->{name}, sizeof($stmt->{name}), $expr_code);");
            } else {
                compile_error("Unsupported const expression type for '$stmt->{name}': $expr_type");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type      => $expr_type,
                    immutable => 1,
                }
            );
            next;
        }

        if ($stmt->{kind} eq 'let_producer') {
            compile_error("Producer for '$stmt->{name}' does not assign target on all recognized paths")
              if !producer_definitely_assigns($stmt->{body}, $stmt->{name});

            if ($stmt->{type} eq 'number') {
                emit_line($out, $indent, "int $stmt->{name} = 0;");
            } elsif ($stmt->{type} eq 'string') {
                emit_line($out, $indent, 'char ' . $stmt->{name} . '[256];');
                emit_line($out, $indent, "$stmt->{name}[0] = '\\0';");
            } else {
                compile_error("Unsupported producer variable type: $stmt->{type}");
            }

            declare_var(
                $ctx,
                $stmt->{name},
                {
                    type        => $stmt->{type},
                    immutable   => 0,
                    constraints => parse_constraints(undef),
                }
            );

            emit_line($out, $indent, '{');
            new_scope($ctx);
            compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');
            next;
        }

        if ($stmt->{kind} eq 'typed_assign') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Typed assignment to undeclared variable '$stmt->{name}'")
              if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'")
              if $info->{immutable};
            compile_error("Typed assignment type mismatch for '$stmt->{name}': expected $info->{type}, got $stmt->{type}")
              if $info->{type} ne $stmt->{type};

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Typed assignment expression mismatch for '$stmt->{name}': expected $stmt->{type}, got $expr_type")
              if $expr_type ne $stmt->{type};

            my $target = $info->{c_name};
            if ($stmt->{type} eq 'number') {
                my $constraints = $stmt->{constraints} // parse_constraints(undef);
                if ($stmt->{expr}{kind} eq 'num') {
                    my $v = int($stmt->{expr}{value});
                    if (defined $constraints->{range} && !$constraints->{wrap}) {
                        compile_error("typed assignment range($constraints->{range}{min},$constraints->{range}{max}) violation for '$stmt->{name}'")
                          if $v < $constraints->{range}{min} || $v > $constraints->{range}{max};
                    }
                    compile_error("Typed assignment for '$stmt->{name}' requires positive value")
                      if $constraints->{positive} && $v <= 0;
                    compile_error("Typed assignment for '$stmt->{name}' requires negative value")
                      if $constraints->{negative} && $v >= 0;
                }

                my $rhs = $expr_code;
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    $rhs = "metac_wrap_range($rhs, $constraints->{range}{min}, $constraints->{range}{max})";
                }
                emit_line($out, $indent, "$target = $rhs;");
            } elsif ($stmt->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
            } else {
                compile_error("Unsupported typed assignment type: $stmt->{type}");
            }
            next;
        }

        if ($stmt->{kind} eq 'assign') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Assign to undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'") if $info->{immutable};
            my $target = $info->{c_name};

            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
            compile_error("Type mismatch in assignment to '$stmt->{name}': expected $info->{type}, got $expr_type")
              if $expr_type ne $info->{type};

            if ($info->{type} eq 'number') {
                my $constraints = $info->{constraints} // parse_constraints(undef);
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($expr_code, $constraints->{range}{min}, $constraints->{range}{max});");
                } else {
                    emit_line($out, $indent, "$target = $expr_code;");
                }
            } elsif ($info->{type} eq 'bool') {
                emit_line($out, $indent, "$target = $expr_code;");
            } elsif ($info->{type} eq 'string') {
                emit_line($out, $indent, "metac_copy_str($target, sizeof($target), $expr_code);");
            } else {
                compile_error("Unsupported assignment target type for '$stmt->{name}': $info->{type}");
            }
            next;
        }

        if ($stmt->{kind} eq 'assign_op') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Assign to undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot assign to immutable variable '$stmt->{name}'") if $info->{immutable};
            my $target = $info->{c_name};

            if ($stmt->{op} eq '+=') {
                compile_error("'+=' requires numeric target '$stmt->{name}'")
                  if $info->{type} ne 'number';
                my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);
                compile_error("'+=' requires numeric expression for '$stmt->{name}'")
                  if $expr_type ne 'number';

                my $combined = "($target + $expr_code)";
                my $constraints = $info->{constraints} // parse_constraints(undef);
                if (defined $constraints->{range} && $constraints->{wrap}) {
                    emit_line($out, $indent,
                        "$target = metac_wrap_range($combined, $constraints->{range}{min}, $constraints->{range}{max});");
                } else {
                    emit_line($out, $indent, "$target = $combined;");
                }
                next;
            }

            compile_error("Unsupported compound assignment operator: $stmt->{op}");
        }

        if ($stmt->{kind} eq 'incdec') {
            my $info = lookup_var($ctx, $stmt->{name});
            compile_error("Inc/dec on undeclared variable '$stmt->{name}'") if !defined $info;
            compile_error("Cannot modify immutable variable '$stmt->{name}'") if $info->{immutable};
            compile_error("Inc/dec requires numeric variable '$stmt->{name}'")
              if $info->{type} ne 'number';

            my $target = $info->{c_name};
            my $constraints = $info->{constraints} // parse_constraints(undef);
            my $delta = $stmt->{op} eq '++' ? '1' : '-1';
            my $combined = "($target + $delta)";
            if (defined $constraints->{range} && $constraints->{wrap}) {
                emit_line($out, $indent,
                    "$target = metac_wrap_range($combined, $constraints->{range}{min}, $constraints->{range}{max});");
            } else {
                emit_line($out, $indent, "$target = $combined;");
            }
            next;
        }

        if ($stmt->{kind} eq 'for_lines') {
            emit_line($out, $indent, '{');
            emit_line($out, $indent + 2, 'char ' . $stmt->{var} . '[512];');
            emit_line($out, $indent + 2, "while (fgets($stmt->{var}, sizeof($stmt->{var}), stdin) != NULL) {");
            emit_line($out, $indent + 4, '__metac_line_no++;');

            new_scope($ctx);
            declare_var($ctx, $stmt->{var}, { type => 'string', immutable => 1 });
            compile_block($stmt->{body}, $ctx, $out, $indent + 4, $current_fn_return);
            pop_scope($ctx);

            emit_line($out, $indent + 2, '}');
            emit_line($out, $indent + 2,
                'if (ferror(stdin)) { return err_number("I/O read failure", __metac_line_no, ""); }');
            emit_line($out, $indent, '}');
            next;
        }

        if ($stmt->{kind} eq 'while') {
            enforce_condition_diagnostics($stmt->{cond}, $ctx, "while condition");
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("while condition must evaluate to bool, got $cond_type")
              if $cond_type ne 'bool';

            emit_line($out, $indent, "while ($cond_code) {");
            new_scope($ctx);
            compile_block($stmt->{body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');
            next;
        }

        if ($stmt->{kind} eq 'destructure_match') {
            my $src = lookup_var($ctx, $stmt->{source_var});
            compile_error("match() source must be an existing string variable: $stmt->{source_var}")
              if !defined($src) || $src->{type} ne 'string';

            my $groups = parse_capture_groups($stmt->{pattern});
            my $expected = scalar @{ $stmt->{vars} };
            my $actual = scalar @$groups;
            compile_error("Destructuring expects $expected captures but regex provides $actual")
              if $expected != $actual;

            my $tmp_id = $ctx->{tmp_counter}++;
            my @tmp_buffers;
            for (my $i = 0; $i < $expected; $i++) {
                my $tmp = "__metac_m${tmp_id}_g$i";
                push @tmp_buffers, $tmp;
                emit_line($out, $indent, "char $tmp\[256\];");
            }

            my $outs_name = "__metac_m${tmp_id}_outs";
            my $outs_list = join(', ', map { $_ } @tmp_buffers);
            emit_line($out, $indent, "char *$outs_name\[$expected\] = { $outs_list };" );

            my $pattern_c = c_escape_string($stmt->{pattern});
            emit_line($out, $indent,
                "if (!metac_match_groups($stmt->{source_var}, $pattern_c, $expected, $outs_name, 256, __metac_err, sizeof(__metac_err))) {");
            emit_line($out, $indent + 2,
                "return err_number(__metac_err, __metac_line_no, $stmt->{source_var});");
            emit_line($out, $indent, '}');

            for (my $i = 0; $i < $expected; $i++) {
                my $name = $stmt->{vars}[$i];
                my $kind = infer_group_type($groups->[$i]);

                if ($kind eq 'number') {
                    emit_line($out, $indent, "int $name;");
                    emit_line($out, $indent, "if (!metac_parse_int($tmp_buffers[$i], &$name)) {");
                    emit_line($out, $indent + 2,
                        "return err_number(\"Expected numeric capture\", __metac_line_no, $stmt->{source_var});");
                    emit_line($out, $indent, '}');
                } else {
                    emit_line($out, $indent, "char $name\[256\];");
                    emit_line($out, $indent, "metac_copy_str($name, sizeof($name), $tmp_buffers[$i]);");
                }

                declare_var($ctx, $name, { type => $kind, immutable => 1 });
            }
            next;
        }

        if ($stmt->{kind} eq 'if') {
            my ($cond_code, $cond_type) = compile_expr($stmt->{cond}, $ctx);
            compile_error("if condition must evaluate to bool, got $cond_type") if $cond_type ne 'bool';

            emit_line($out, $indent, "if ($cond_code) {");
            new_scope($ctx);
            compile_block($stmt->{then_body}, $ctx, $out, $indent + 2, $current_fn_return);
            pop_scope($ctx);
            emit_line($out, $indent, '}');

            if (defined $stmt->{else_body}) {
                emit_line($out, $indent, 'else {');
                new_scope($ctx);
                compile_block($stmt->{else_body}, $ctx, $out, $indent + 2, $current_fn_return);
                pop_scope($ctx);
                emit_line($out, $indent, '}');
            }
            next;
        }

        if ($stmt->{kind} eq 'return') {
            my ($expr_code, $expr_type) = compile_expr($stmt->{expr}, $ctx);

            if ($current_fn_return eq 'number_or_error') {
                compile_error("return type mismatch: expected number for number|error function")
                  if $expr_type ne 'number';
                emit_line($out, $indent, "return ok_number($expr_code);");
            } elsif ($current_fn_return eq 'number') {
                compile_error("return type mismatch: expected number return")
                  if $expr_type ne 'number';
                emit_line($out, $indent, "return $expr_code;");
            } else {
                compile_error("Unsupported function return mode: $current_fn_return");
            }
            next;
        }

        if ($stmt->{kind} eq 'raw') {
            compile_error("Unsupported statement in day1 subset: $stmt->{text}");
        }

        compile_error("Unsupported statement kind: $stmt->{kind}");
    }
}

sub compile_main_body {
    my ($main_fn, $number_error_functions) = @_;
    my $body = join "\n", @{ $main_fn->{body_lines} };

    my ($result_fmt, $callee, $err_var) =
      $body =~ /printf\(\s*(\"(?:\\.|[^\"\\])*\")\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s+or\s+\(([A-Za-z_][A-Za-z0-9_]*)\)\s*=>\s*\{/m;
    compile_error("main must include: printf(<fmt>, <fn>() or (<e>) => { ... })")
      if !defined $callee;

    compile_error("Function '$callee' is not available as number | error")
      if !exists $number_error_functions->{$callee};

    my ($error_fmt) =
      $body =~ /printf\(\s*(\"(?:\\.|[^\"\\])*\")\s*,\s*\Q$err_var\E\.message\s*\)/m;
    compile_error("main error handler must print $err_var.message")
      if !defined $error_fmt;

    my $c = "int main(void) {\n";
    $c .= "  ResultNumber result = $callee();\n";
    $c .= "  if (result.is_error) {\n";
    $c .= "    printf($error_fmt, result.message);\n";
    $c .= "    return 1;\n";
    $c .= "  }\n";
    $c .= "  printf($result_fmt, result.value);\n";
    $c .= "  return 0;\n";
    $c .= "}\n";
    return $c;
}

sub emit_param_bindings {
    my ($params, $ctx, $out, $indent, $return_mode) = @_;

    for my $param (@$params) {
        my $name = $param->{name};
        my $in_name = $param->{c_in_name};
        my $constraints = $param->{constraints};

        if ($param->{type} eq 'number') {
            my $expr = $in_name;
            if (defined $constraints->{range} && $constraints->{wrap}) {
                $expr = "metac_wrap_range($expr, $constraints->{range}{min}, $constraints->{range}{max})";
            }
            emit_line($out, $indent, "const int $name = $expr;");
            declare_var(
                $ctx,
                $name,
                {
                    type        => 'number',
                    immutable   => 1,
                    c_name      => $name,
                    constraints => $constraints,
                }
            );
            next;
        }

        if ($param->{type} eq 'string') {
            emit_line($out, $indent, "const char *$name = $in_name;");
            declare_var(
                $ctx,
                $name,
                {
                    type      => 'string',
                    immutable => 1,
                    c_name    => $name,
                }
            );
            next;
        }

        compile_error("Unsupported parameter type binding: $param->{type}");
    }
}

sub compile_number_or_error_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number | error")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number | error';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static ResultNumber $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number_or_error');
    compile_block($stmts, $ctx, \@out, 2, 'number_or_error');
    my $missing_return_msg = c_escape_string("Missing return in function $fn->{name}");
    push @out, "  return err_number($missing_return_msg, __metac_line_no, \"\");";
    push @out, '}';
    return join("\n", @out) . "\n";
}

sub compile_number_function {
    my ($fn, $params, $function_sigs) = @_;
    compile_error("Function '$fn->{name}' must have return type: number")
      if !defined($fn->{return_type}) || $fn->{return_type} ne 'number';

    my $stmts = parse_function_body($fn);
    my @out;
    my $sig_params = render_c_params($params);
    push @out, "static int $fn->{name}($sig_params) {";
    push @out, '  int __metac_line_no = 0;';
    push @out, '  char __metac_err[160];';

    my $ctx = {
        scopes      => [ {} ],
        tmp_counter => 0,
        functions   => $function_sigs,
    };

    emit_param_bindings($params, $ctx, \@out, 2, 'number');
    compile_block($stmts, $ctx, \@out, 2, 'number');
    push @out, '  return 0;';
    push @out, '}';
    return join("\n", @out) . "\n";
}

sub emit_function_prototypes {
    my ($ordered_names, $functions) = @_;
    my @out;

    for my $name (@$ordered_names) {
        my $fn = $functions->{$name};
        my $params = $fn->{parsed_params};
        my $sig_params = render_c_params($params);

        if ($fn->{return_type} eq 'number | error') {
            push @out, "static ResultNumber $name($sig_params);";
            next;
        }
        if ($fn->{return_type} eq 'number') {
            push @out, "static int $name($sig_params);";
            next;
        }
        compile_error("Unsupported function return type for '$name': $fn->{return_type}");
    }

    return join("\n", @out) . "\n";
}

sub runtime_prelude {
    return <<'C_RUNTIME';
#include <ctype.h>
#include <limits.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int is_error;
  int value;
  char message[160];
} ResultNumber;

static ResultNumber ok_number(int value) {
  ResultNumber out;
  out.is_error = 0;
  out.value = value;
  out.message[0] = '\0';
  return out;
}

static ResultNumber err_number(const char *message, int line_no, const char *line_text) {
  ResultNumber out;
  out.is_error = 1;
  out.value = 0;
  snprintf(out.message, sizeof(out.message), "%s (line %d: %s)", message, line_no, line_text);
  return out;
}

static void metac_copy_str(char *dst, size_t dst_sz, const char *src) {
  if (dst_sz == 0) {
    return;
  }
  strncpy(dst, src, dst_sz - 1);
  dst[dst_sz - 1] = '\0';
}

static int metac_streq(const char *a, const char *b) {
  return strcmp(a, b) == 0;
}

static int metac_max(int a, int b) {
  return (a > b) ? a : b;
}

static int metac_min(int a, int b) {
  return (a < b) ? a : b;
}

static int metac_wrap_range(int value, int min, int max) {
  int span = (max - min) + 1;
  int shifted = value - min;
  int r = shifted % span;
  if (r < 0) {
    r += span;
  }
  return min + r;
}

static int metac_parse_int(const char *text, int *out) {
  char *end = NULL;
  long value = strtol(text, &end, 10);
  if (text[0] == '\0' || *end != '\0') {
    return 0;
  }
  if (value < INT_MIN || value > INT_MAX) {
    return 0;
  }
  *out = (int)value;
  return 1;
}

static void metac_rstrip_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
    s[len - 1] = '\0';
    len--;
  }
}

static int metac_match_groups(
    const char *input,
    const char *pattern,
    int expected_groups,
    char **outs,
    size_t out_cap,
    char *err,
    size_t err_sz) {
  regex_t re;
  regmatch_t matches[16];
  char anchored[512];
  char line[512];

  if (expected_groups <= 0 || expected_groups > 15) {
    snprintf(err, err_sz, "Unsupported capture count");
    return 0;
  }

  snprintf(anchored, sizeof(anchored), "^%s$", pattern);
  metac_copy_str(line, sizeof(line), input);
  metac_rstrip_newline(line);

  if (regcomp(&re, anchored, REG_EXTENDED) != 0) {
    snprintf(err, err_sz, "Invalid regex pattern");
    return 0;
  }

  int rc = regexec(&re, line, (size_t)expected_groups + 1, matches, 0);
  if (rc != 0) {
    regfree(&re);
    snprintf(err, err_sz, "Pattern match failed");
    return 0;
  }

  for (int i = 0; i < expected_groups; i++) {
    regmatch_t m = matches[i + 1];
    if (m.rm_so < 0 || m.rm_eo < m.rm_so) {
      regfree(&re);
      snprintf(err, err_sz, "Missing capture group");
      return 0;
    }

    size_t len = (size_t)(m.rm_eo - m.rm_so);
    if (len >= out_cap) {
      regfree(&re);
      snprintf(err, err_sz, "Capture too long");
      return 0;
    }

    memcpy(outs[i], line + m.rm_so, len);
    outs[i][len] = '\0';
  }

  regfree(&re);
  return 1;
}
C_RUNTIME
}

sub compile_source {
    my ($source) = @_;
    my $functions = collect_functions($source);

    compile_error("Missing required function: main") if !exists $functions->{main};

    my $main = $functions->{main};
    compile_error("main must not declare arguments in this subset") if $main->{args} ne '';

    my %number_error_functions;
    my %number_functions;
    my %function_sigs;
    my @ordered_names = sort grep { $_ ne 'main' } keys %$functions;
    for my $name (@ordered_names) {
        my $fn = $functions->{$name};
        $fn->{parsed_params} = parse_function_params($fn);
        $function_sigs{$name} = {
            return_type => $fn->{return_type},
            params      => $fn->{parsed_params},
        };

        if (defined $fn->{return_type} && $fn->{return_type} eq 'number | error') {
            $number_error_functions{$name} = 1;
            next;
        }
        if (defined $fn->{return_type} && $fn->{return_type} eq 'number') {
            $number_functions{$name} = 1;
            next;
        }
        compile_error("Unsupported function return type for '$name'; supported: number | error, number");
    }

    my $c = runtime_prelude();
    $c .= "\n";
    $c .= emit_function_prototypes(\@ordered_names, $functions);
    $c .= "\n\n";
    for my $name (@ordered_names) {
        if ($number_error_functions{$name}) {
            $c .= compile_number_or_error_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $c .= "\n";
            next;
        }
        if ($number_functions{$name}) {
            $c .= compile_number_function(
                $functions->{$name},
                $functions->{$name}{parsed_params},
                \%function_sigs
            );
            $c .= "\n";
            next;
        }
        compile_error("Internal: unclassified function '$name'");
    }
    $c .= compile_main_body($main, \%number_error_functions);
    return $c;
}

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
