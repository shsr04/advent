package MetaC::Parser;
use strict;
use warnings;

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
        if ($expr =~ /\G&&/gc) {
            push @tokens, { type => 'op', value => '&&' };
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
    my $parse_and;
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

    $parse_and = sub {
        my $left = $parse_eq->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || $tok->{value} ne '&&';
            $idx++;
            my $right = $parse_eq->();
            $left = { kind => 'binop', op => '&&', left => $left, right => $right };
        }
        return $left;
    };

    $parse_or = sub {
        my $left = $parse_and->();
        while (1) {
            my $tok = $peek->();
            last if !defined $tok || $tok->{type} ne 'op' || $tok->{value} ne '||';
            $idx++;
            my $right = $parse_and->();
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
                } elsif ($accept_op->(')') && $accept_op->('=>')) {
                    my $body = $parse_lambda->();
                    return {
                        kind  => 'lambda1',
                        param => $param1,
                        body  => $body,
                    };
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


1;
