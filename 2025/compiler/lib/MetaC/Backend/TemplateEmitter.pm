package MetaC::Backend::TemplateEmitter;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Parser qw(parse_expr);
use MetaC::HIR::OpRegistry qw(
    builtin_is_known
    builtin_op_id
    method_is_known
    method_op_id
    method_has_length_semantics
    method_traceability_hint
);

our @EXPORT_OK = qw(template_expr_to_c);

sub _annotate_template_call_contracts {
    my ($expr) = @_;
    return if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    if ($kind eq 'unary') {
        _annotate_template_call_contracts($expr->{expr});
        return;
    }
    if ($kind eq 'binop') {
        _annotate_template_call_contracts($expr->{left});
        _annotate_template_call_contracts($expr->{right});
        return;
    }
    if ($kind eq 'index') {
        _annotate_template_call_contracts($expr->{recv});
        _annotate_template_call_contracts($expr->{index});
        return;
    }
    if ($kind eq 'try') {
        _annotate_template_call_contracts($expr->{expr});
        return;
    }
    if ($kind eq 'list_literal') {
        _annotate_template_call_contracts($_) for @{ $expr->{items} // [] };
        return;
    }
    if ($kind eq 'lambda1' || $kind eq 'lambda2') {
        _annotate_template_call_contracts($expr->{body});
        return;
    }

    if ($kind eq 'call') {
        _annotate_template_call_contracts($_) for @{ $expr->{args} // [] };
        my $name = $expr->{name} // '';
        if (builtin_is_known($name)) {
            $expr->{resolved_call} //= {
                call_kind   => 'builtin',
                op_id       => builtin_op_id($name),
                target_name => $name,
                arity       => scalar(@{ $expr->{args} // [] }),
            };
        }
        return;
    }
    if ($kind eq 'method_call') {
        _annotate_template_call_contracts($expr->{recv});
        _annotate_template_call_contracts($_) for @{ $expr->{args} // [] };
        my $method = $expr->{method} // '';
        if (method_is_known($method)) {
            $expr->{resolved_call} //= {
                call_kind   => 'intrinsic_method',
                op_id       => method_op_id($method),
                target_name => $method,
                method_name => $method,
                arity       => scalar(@{ $expr->{args} // [] }),
            };
        }
        return;
    }
}

sub template_expr_to_c {
    my (%args) = @_;
    my $raw = $args{raw};
    my $ctx = $args{ctx};
    my $expr_to_c = $args{expr_to_c};
    my $expr_c_type_hint = $args{expr_c_type_hint};
    my $helper_mark = $args{helper_mark};
    my $c_escape = $args{c_escape};

    return '""' if !defined $raw;

    my @out_args;
    my @parts;
    my $pos = 0;
    while ($raw =~ /\$\{(.*?)\}/g) {
        my $s = $-[0];
        my $e = $+[0];
        my $expr = $1;
        my $lit = substr($raw, $pos, $s - $pos);
        push @parts, $c_escape->($lit);

        $expr =~ s/^\s+//;
        $expr =~ s/\s+$//;
        my $slot_expr = eval { parse_expr($expr) };
        if (!$@ && defined($slot_expr) && ref($slot_expr) eq 'HASH') {
            _annotate_template_call_contracts($slot_expr);
            my $ty = $expr_c_type_hint->($slot_expr, $ctx) // '';
            my $value = $expr_to_c->($slot_expr, $ctx);
            if ($ty eq 'const char *') {
                push @parts, '%s';
                push @out_args, $value;
            } elsif ($ty eq 'struct metac_list_i64'
                && (($slot_expr->{kind} // '') eq 'ident'))
            {
                $helper_mark->($ctx, 'list_i64');
                $helper_mark->($ctx, 'list_i64_render');
                push @parts, '%s';
                push @out_args, 'metac_list_i64_render(&' . ($slot_expr->{name} // '') . ')';
            } elsif ($ty eq 'struct metac_list_str'
                && (($slot_expr->{kind} // '') eq 'ident'))
            {
                $helper_mark->($ctx, 'list_str');
                $helper_mark->($ctx, 'list_str_render');
                push @parts, '%s';
                push @out_args, 'metac_list_str_render(&' . ($slot_expr->{name} // '') . ')';
            } else {
                push @parts, '%lld';
                push @out_args, $value;
            }
            $pos = $e;
            next;
        }

        if ($expr =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            my $var = $expr;
            my $ty = $ctx->{var_types}{$var} // 'int64_t';
            if ($ty eq 'const char *') {
                push @parts, '%s';
                push @out_args, $var;
            } elsif ($ty eq 'struct metac_list_i64') {
                $helper_mark->($ctx, 'list_i64');
                $helper_mark->($ctx, 'list_i64_render');
                push @parts, '%s';
                push @out_args, 'metac_list_i64_render(&' . $var . ')';
            } elsif ($ty eq 'struct metac_list_str') {
                $helper_mark->($ctx, 'list_str');
                $helper_mark->($ctx, 'list_str_render');
                push @parts, '%s';
                push @out_args, 'metac_list_str_render(&' . $var . ')';
            } else {
                push @parts, '%lld';
                push @out_args, $var;
            }
        } elsif ($expr =~ /^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\(\)$/) {
            my ($var, $method) = ($1, $2);
            my $traceability = method_traceability_hint($method) // '';
            if (!method_has_length_semantics($method)) {
                if ($traceability eq 'requires_source_index_metadata') {
                    my $idx_expr = {
                        kind => 'method_call',
                        method => $method,
                        recv => { kind => 'ident', name => $var },
                        args => [],
                    };
                    push @parts, '%lld';
                    push @out_args, $expr_to_c->($idx_expr, $ctx);
                    $pos = $e;
                    next;
                }
                push @parts, '%lld';
                push @out_args, '0';
                $pos = $e;
                next;
            }
            my $ty = $ctx->{var_types}{$var} // '';
            my $value = '0';
            if ($ty eq 'const char *') {
                $helper_mark->($ctx, 'method_size');
                $value = "metac_method_size($var)";
            } elsif ($ty eq 'struct metac_list_i64') {
                $helper_mark->($ctx, 'list_i64');
                $value = "metac_list_i64_size(&$var)";
            } elsif ($ty eq 'struct metac_list_str') {
                $helper_mark->($ctx, 'list_str');
                $value = "metac_list_str_size(&$var)";
            } elsif ($ty eq 'struct metac_list_list_i64') {
                $helper_mark->($ctx, 'list_list_i64');
                $value = "metac_list_list_i64_size(&$var)";
            } elsif ($method ne 'size' && $ty ne '') {
                $helper_mark->($ctx, 'method_count');
                $value = "metac_method_count($var)";
            }
            push @parts, '%lld';
            push @out_args, $value;
        } elsif ($expr =~ /^([A-Za-z_][A-Za-z0-9_]*)\((.*)\)$/) {
            my ($fname, $raw_args) = ($1, $2);
            my @call_args;
            my $trimmed = defined($raw_args) ? $raw_args : '';
            $trimmed =~ s/^\s+//;
            $trimmed =~ s/\s+$//;
            if ($trimmed ne '') {
                my @arg_parts = split /\s*,\s*/, $trimmed;
                for my $arg (@arg_parts) {
                    if ($arg =~ /^[A-Za-z_][A-Za-z0-9_]*$/ || $arg =~ /^-?\d+$/ || $arg =~ /^"(?:\\.|[^"\\])*"$/) {
                        push @call_args, $arg;
                    } else {
                        push @call_args, '0';
                    }
                }
            }
            push @parts, '%lld';
            push @out_args, $fname . '(' . join(', ', @call_args) . ')';
        } elsif ($expr =~ /^(-?\d+)\s*([+\-*\/])\s*(-?\d+)$/) {
            my ($a, $op, $b) = ($1, $2, $3);
            my $value = 0;
            if ($op eq '+') {
                $value = $a + $b;
            } elsif ($op eq '-') {
                $value = $a - $b;
            } elsif ($op eq '*') {
                $value = $a * $b;
            } elsif ($op eq '/') {
                $value = $b == 0 ? 0 : int($a / $b);
            }
            push @parts, '%lld';
            push @out_args, $value;
        } else {
            push @parts, '%lld';
            push @out_args, '0';
        }
        $pos = $e;
    }
    push @parts, $c_escape->(substr($raw, $pos));

    my $fmt = '"' . join('', @parts) . '"';
    $helper_mark->($ctx, 'fmt');
    return 'metac_format(' . $fmt . ( @out_args ? ', ' . join(', ', @out_args) : '' ) . ')';
}

1;
