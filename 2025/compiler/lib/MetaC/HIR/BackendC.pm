package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);
use MetaC::Support qw(constraint_size_exact);
use MetaC::TypeSpec qw(
    is_sequence_member_type
    sequence_member_meta
    matrix_type_meta
);

our @EXPORT_OK = qw(codegen_from_vnf_hir);

sub _helper_mark {
    my ($ctx, $name) = @_;
    return if !defined($ctx) || ref($ctx) ne 'HASH' || !defined($name) || $name eq '';
    $ctx->{helpers}{$name} = 1;
}

sub _c_escape {
    my ($s) = @_;
    $s = '' if !defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

sub _is_array_type {
    my ($t) = @_;
    return defined($t) && $t =~ /^array</ ? 1 : 0;
}

sub _is_nested_array_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^array<e=array</;
    return 1 if $t =~ /^array<e=61727261793C/;    # hex("array<")
    return 0;
}

sub _is_string_array_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^array<e=737472696E67/;
    return 1 if $t =~ /^array<e=string/;
    return 0;
}

sub _is_string_matrix_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix<e=737472696E67/;
    return 1 if $t =~ /^matrix<e=string/;
    return 0;
}

sub _is_string_matrix_member_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix_member<e=737472696E67/;
    return 1 if $t =~ /^matrix_member<e=string/;
    return 0;
}

sub _is_string_matrix_member_list_type {
    my ($t) = @_;
    return 0 if !defined $t;
    return 1 if $t =~ /^matrix_member_list<e=737472696E67/;
    return 1 if $t =~ /^matrix_member_list<e=string/;
    return 0;
}

sub _is_matrix_type {
    my ($t) = @_;
    return defined($t) && $t =~ /^matrix</ ? 1 : 0;
}

sub _sequence_member_elem_type {
    my ($t) = @_;
    return undef if !defined($t) || $t eq '' || !is_sequence_member_type($t);
    my $meta = sequence_member_meta($t);
    return undef if !defined($meta) || ref($meta) ne 'HASH';
    return $meta->{elem};
}

sub _matrix_meta_var_name {
    my ($name) = @_;
    return '' if !defined($name) || $name eq '';
    return "__metac_matrix_meta_$name";
}

sub _matrix_meta_for_type {
    my ($type) = @_;
    return undef if !defined($type) || $type eq '';
    my $meta = matrix_type_meta($type);
    return undef if !defined($meta) || ref($meta) ne 'HASH';
    return $meta;
}

sub _constraint_exact_size {
    my ($constraints) = @_;
    return undef if !defined($constraints) || ref($constraints) ne 'HASH';
    my $n = constraint_size_exact($constraints);
    return undef if !defined($n) || $n !~ /^-?\d+$/;
    return int($n);
}

sub _strip_error_union {
    my ($t) = @_;
    return $t if !defined($t) || $t !~ /\|/;
    my @parts = map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } split /\|/, $t;
    my @non_error = grep { $_ ne 'error' } @parts;
    return $non_error[0] // $parts[0];
}

sub _result_type_to_c {
    my ($t) = @_;
    return undef if !defined $t || $t eq '';
    $t = _strip_error_union($t);
    my $seq_elem = _sequence_member_elem_type($t);
    $t = $seq_elem if defined($seq_elem) && $seq_elem ne '';
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_str' if _is_string_matrix_type($t);
    return 'struct metac_list_str' if _is_string_matrix_member_list_type($t);
    return 'const char *' if _is_string_matrix_member_type($t);
    return 'int64_t' if defined($t) && $t =~ /^matrix_member</;
    return 'struct metac_list_i64' if $t =~ /array</;
    return 'struct metac_list_i64' if defined($t) && $t =~ /^matrix_member_list</;
    return 'struct metac_list_i64' if $t =~ /matrix</;
    return 'const char *' if $t =~ /\bstring\b/ || $t =~ /^stringwith/;
    return 'int' if $t =~ /\bbool(?:ean)?\b/;
    return 'double' if $t =~ /\bfloat\b/;
    return 'int64_t' if $t =~ /\b(?:number|int)\b/;
    return undef;
}

sub _type_to_c {
    my ($t, $fallback) = @_;
    return $fallback if !defined $t || $t eq '';
    $t = _strip_error_union($t);
    my $seq_elem = _sequence_member_elem_type($t);
    $t = $seq_elem if defined($seq_elem) && $seq_elem ne '';
    return 'int64_t' if $t eq 'number' || $t eq 'int';
    return 'double' if $t eq 'float';
    return 'int' if $t eq 'bool' || $t eq 'boolean';
    return 'const char *' if $t eq 'string' || $t =~ /^stringwith/;
    return 'int' if $t eq 'null';
    return 'struct metac_error' if $t eq 'error';
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_str' if _is_string_matrix_type($t);
    return 'struct metac_list_str' if _is_string_matrix_member_list_type($t);
    return 'const char *' if _is_string_matrix_member_type($t);
    return 'struct metac_list_i64' if _is_array_type($t);
    return 'struct metac_list_i64' if defined($t) && $t =~ /^matrix_member_list</;
    return 'int64_t' if defined($t) && $t =~ /^matrix_member</;
    return 'struct metac_list_i64' if _is_matrix_type($t);
    return $fallback;
}

sub _expr_c_type_hint {
    my ($expr, $ctx) = @_;
    return undef if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return 'int64_t' if $k eq 'num';
    return 'int' if $k eq 'bool' || $k eq 'null';
    return 'const char *' if $k eq 'str';
    if ($k eq 'list_literal') {
        my $items = $expr->{items} // [];
        return 'struct metac_list_str' if @$items && !grep { !defined($_) || ref($_) ne 'HASH' || (($_->{kind} // '') ne 'str') } @$items;
        return 'struct metac_list_i64';
    }
    if ($k eq 'ident') {
        return $ctx->{var_types}{ $expr->{name} // '' };
    }
    if ($k eq 'call' || $k eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        my $canonical = $expr->{canonical_call};
        my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
          : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
        my $rt = _result_type_to_c($meta->{result_type});
        return $rt if defined $rt;
        if ($k eq 'method_call') {
            my $m = $expr->{method} // '';
            return 'int64_t' if $m eq 'size' || $m eq 'count' || $m eq 'index' || $m eq 'insert';
            if ($m eq 'members' || $m eq 'filter' || $m eq 'neighbours') {
                my $recv_hint = _expr_c_type_hint($expr->{recv}, $ctx);
                return 'struct metac_list_str' if defined($recv_hint) && $recv_hint eq 'struct metac_list_str';
                return 'struct metac_list_str' if $m eq 'neighbours' && defined($recv_hint) && $recv_hint eq 'const char *';
                return 'struct metac_list_i64';
            }
            return 'struct metac_list_str' if $m eq 'match';
        }
        return undef;
    }
    return undef;
}

sub _default_return_for_c_type {
    my ($c_ty) = @_;
    return 'NULL' if defined($c_ty) && $c_ty eq 'const char *';
    return '(struct metac_error){0}' if defined($c_ty) && $c_ty eq 'struct metac_error';
    return '(struct metac_list_list_i64){0}' if defined($c_ty) && $c_ty eq 'struct metac_list_list_i64';
    return '(struct metac_list_i64){0}' if defined($c_ty) && $c_ty eq 'struct metac_list_i64';
    return '(struct metac_list_str){0}' if defined($c_ty) && $c_ty eq 'struct metac_list_str';
    return '0';
}

sub _expr_is_stringish {
    my ($expr, $ctx) = @_;
    return 0 if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return 1 if $k eq 'str';
    return 1 if $k eq 'ident' && (($ctx->{var_types}{ $expr->{name} // '' } // '') eq 'const char *');
    my $hint = _expr_c_type_hint($expr, $ctx);
    return defined($hint) && $hint eq 'const char *' ? 1 : 0;
}

sub _template_expr_to_c {
    my ($raw, $ctx) = @_;
    return '""' if !defined $raw;

    my @args;
    my @parts;
    my $pos = 0;
    while ($raw =~ /\$\{(.*?)\}/g) {
        my $s = $-[0];
        my $e = $+[0];
        my $expr = $1;
        my $lit = substr($raw, $pos, $s - $pos);
        push @parts, _c_escape($lit);

        $expr =~ s/^\s+//;
        $expr =~ s/\s+$//;
        if ($expr =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            my $var = $expr;
            my $ty = $ctx->{var_types}{$var} // 'int64_t';
            if ($ty eq 'const char *') {
                push @parts, '%s';
                push @args, $var;
            } elsif ($ty eq 'struct metac_list_i64') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'list_i64_render');
                push @parts, '%s';
                push @args, 'metac_list_i64_render(&' . $var . ')';
            } elsif ($ty eq 'struct metac_list_str') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'list_str_render');
                push @parts, '%s';
                push @args, 'metac_list_str_render(&' . $var . ')';
            } else {
                push @parts, '%lld';
                push @args, $var;
            }
        } elsif ($expr =~ /^([A-Za-z_][A-Za-z0-9_]*)\.(size|count)\(\)$/) {
            my ($var, $method) = ($1, $2);
            my $ty = $ctx->{var_types}{$var} // '';
            my $value = '0';
            if ($ty eq 'const char *') {
                _helper_mark($ctx, 'method_size');
                $value = "metac_method_size($var)";
            } elsif ($ty eq 'struct metac_list_i64') {
                _helper_mark($ctx, 'list_i64');
                $value = "metac_list_i64_size(&$var)";
            } elsif ($ty eq 'struct metac_list_str') {
                _helper_mark($ctx, 'list_str');
                $value = "metac_list_str_size(&$var)";
            } elsif ($ty eq 'struct metac_list_list_i64') {
                _helper_mark($ctx, 'list_list_i64');
                $value = "metac_list_list_i64_size(&$var)";
            } elsif ($method eq 'count' && $ty ne '') {
                _helper_mark($ctx, 'method_count');
                $value = "metac_method_count($var)";
            }
            push @parts, '%lld';
            push @args, $value;
        } elsif ($expr =~ /^([A-Za-z_][A-Za-z0-9_]*)\.index\(\)$/) {
            my $id = $1;
            my $idx_expr = {
                kind => 'method_call',
                method => 'index',
                recv => { kind => 'ident', name => $id },
                args => [],
            };
            push @parts, '%lld';
            push @args, _expr_to_c($idx_expr, $ctx);
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
            push @args, $fname . '(' . join(', ', @call_args) . ')';
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
            push @args, $value;
        } else {
            push @parts, '%lld';
            push @args, '0';
        }
        $pos = $e;
    }
    push @parts, _c_escape(substr($raw, $pos));

    my $fmt = '"' . join('', @parts) . '"';
    _helper_mark($ctx, 'fmt');
    return 'metac_format(' . $fmt . ( @args ? ', ' . join(', ', @args) : '' ) . ')';
}

sub _expr_to_c {
    my ($expr, $ctx) = @_;
    return '0' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';

    return $expr->{value} // '0' if $k eq 'num';
    return ($expr->{value} ? '1' : '0') if $k eq 'bool';
    if ($k eq 'str') {
        my $raw = $expr->{raw};
        if (defined($raw) && $raw =~ /\$\{/) {
            return _template_expr_to_c($raw, $ctx);
        }
        my $v = $expr->{value};
        return $v if defined($v) && $v =~ /^".*"$/s;
        return '"' . _c_escape($v) . '"';
    }
    return '0' if $k eq 'null';
    if ($k eq 'ident') {
        my $name = $expr->{name} // '';
        if ($name eq 'STDIN') {
            _helper_mark($ctx, 'stdin_read');
            return 'metac_stdin_read_all()';
        }
        return $name ne '' ? $name : '/* missing-ident */ 0';
    }

    if ($k eq 'list_literal') {
        my @items = @{ $expr->{items} // [] };
        if (@items && ref($items[0]) eq 'HASH' && (($items[0]{kind} // '') eq 'list_literal')) {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            my @vals = map { _expr_to_c($_, $ctx) } @items;
            my $arr = '(struct metac_list_i64[]){' . join(', ', @vals) . '}';
            return 'metac_list_list_i64_from_array(' . $arr . ', ' . scalar(@vals) . ')';
        }
        if (@items && !grep { !defined($_) || ref($_) ne 'HASH' || (($_->{kind} // '') ne 'str') } @items) {
            _helper_mark($ctx, 'list_str');
            my @vals = map { _expr_to_c($_, $ctx) } @items;
            my $arr = '(const char*[]){' . join(', ', @vals) . '}';
            return 'metac_list_str_from_array(' . $arr . ', ' . scalar(@vals) . ')';
        }
        _helper_mark($ctx, 'list_i64');
        return 'metac_list_i64_empty()' if !@items;
        my @vals = map { _expr_to_c($_, $ctx) } @items;
        my $arr = '(int64_t[]){' . join(', ', @vals) . '}';
        return 'metac_list_i64_from_array(' . $arr . ', ' . scalar(@vals) . ')';
    }

    if ($k eq 'unary') {
        my $op = defined($expr->{op}) ? $expr->{op} : '-';
        return "($op" . _expr_to_c($expr->{expr}, $ctx) . ")";
    }
    if ($k eq 'binop') {
        my $op = defined($expr->{op}) ? $expr->{op} : '+';
        if (($op eq '==' || $op eq '!=') && (_expr_is_stringish($expr->{left}, $ctx) || _expr_is_stringish($expr->{right}, $ctx))) {
            my $l = _expr_to_c($expr->{left}, $ctx);
            my $r = _expr_to_c($expr->{right}, $ctx);
            my $cmp = "((($l) && ($r)) ? (strcmp($l, $r) == 0) : (($l) == ($r)))";
            return $op eq '!=' ? "(!$cmp)" : $cmp;
        }
        $op = '/' if $op eq '~/';
        return '(' . _expr_to_c($expr->{left}, $ctx) . " $op " . _expr_to_c($expr->{right}, $ctx) . ')';
    }
    if ($k eq 'index') {
        my $recv = $expr->{recv};
        my $idx = _expr_to_c($expr->{index}, $ctx);
        if (defined($recv) && ref($recv) eq 'HASH' && ($recv->{kind} // '') eq 'ident') {
            my $name = $recv->{name};
            my $ty = $ctx->{var_types}{$name} // '';
            if ($ty eq 'struct metac_list_i64') {
                _helper_mark($ctx, 'list_i64');
                return "metac_list_i64_get(&$name, $idx)";
            }
            if ($ty eq 'struct metac_list_str') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'list_str_get');
                return "metac_list_str_get(&$name, $idx)";
            }
            if ($ty eq 'const char *') {
                _helper_mark($ctx, 'string_index');
                return "metac_string_code_at($name, $idx)";
            }
        }
        return "/* Backend/F054 missing index emitter */ 0";
    }
    if ($k eq 'try') {
        return _expr_to_c($expr->{expr}, $ctx);
    }

    if ($k eq 'call') {
        my $resolved = $expr->{resolved_call};
        my $canonical = $expr->{canonical_call};
        my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
          : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
        my $call_kind = $meta->{call_kind} // '';
        my $op_id = $meta->{op_id} // '';
        my $target = $meta->{target_name} // ($expr->{name} // '');
        my @args = map { _expr_to_c($_, $ctx) } @{ $expr->{args} // [] };

        if ($call_kind eq 'user' || $call_kind eq 'user_function') {
            return $target . '(' . join(', ', @args) . ')';
        }
        if ($call_kind eq 'builtin') {
            if ($op_id eq 'call.builtin.parseNumber.v1') {
                _helper_mark($ctx, 'parse_number');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_parse_number(' . ($args[0] // '""') . ')';
            }
            if ($op_id eq 'call.builtin.error.v1') {
                _helper_mark($ctx, 'builtin_error');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_error(' . ($args[0] // '""') . ')';
            }
            if ($op_id eq 'call.builtin.split.v1') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_split(' . ($args[0] // '""') . ', ' . ($args[1] // '""') . ')';
            }
            if ($op_id eq 'call.builtin.lines.v1') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_lines');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_lines(' . ($args[0] // '""') . ')';
            }
            if ($op_id eq 'call.builtin.max.v1') {
                my $a = $args[0] // '0';
                my $b = $args[1] // '0';
                return "(($a) > ($b) ? ($a) : ($b))";
            }
            if ($op_id eq 'call.builtin.min.v1') {
                my $a = $args[0] // '0';
                my $b = $args[1] // '0';
                return "(($a) < ($b) ? ($a) : ($b))";
            }
            if ($op_id eq 'call.builtin.log.v1') {
                my $hints = $meta->{arg_type_hints};
                my $hint = (defined($hints) && ref($hints) eq 'ARRAY' && @$hints) ? ($hints->[0] // '') : '';
                my $a0 = $args[0] // '0';
                if ($hint eq 'string') {
                    _helper_mark($ctx, 'log_str');
                    return "metac_builtin_log_str($a0)";
                }
                if ($hint eq 'float') {
                    _helper_mark($ctx, 'log_f64');
                    return "metac_builtin_log_f64($a0)";
                }
                if ($hint eq 'bool' || $hint eq 'boolean') {
                    _helper_mark($ctx, 'log_bool');
                    return "metac_builtin_log_bool($a0)";
                }
                _helper_mark($ctx, 'log_i64');
                return "metac_builtin_log_i64($a0)";
            }
            if ($op_id eq 'call.builtin.seq.v1') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'seq_i64');
                return 'metac_builtin_seq_i64(' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
            }
            if ($op_id eq 'call.builtin.last.v1') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'last_index_i64');
                return 'metac_builtin_last_index_i64(' . ($args[0] // 'metac_list_i64_empty()') . ')';
            }
            return $target . '(' . join(', ', @args) . ')';
        }

        if ($target eq 'parseNumber') {
            _helper_mark($ctx, 'parse_number');
            _helper_mark($ctx, 'error_flag');
            return 'metac_builtin_parse_number(' . ($args[0] // '""') . ')';
        }
        if ($target eq 'error') {
            _helper_mark($ctx, 'builtin_error');
            _helper_mark($ctx, 'error_flag');
            return 'metac_builtin_error(' . ($args[0] // '""') . ')';
        }
        if ($target eq 'log') {
            my $a0 = $args[0] // '0';
            my $hint = _expr_c_type_hint($expr->{args}[0], $ctx);
            if (defined($hint) && $hint eq 'const char *') {
                _helper_mark($ctx, 'log_str');
                return "metac_builtin_log_str($a0)";
            }
            if (defined($hint) && $hint eq 'int') {
                _helper_mark($ctx, 'log_bool');
                return "metac_builtin_log_bool($a0)";
            }
            _helper_mark($ctx, 'log_i64');
            return "metac_builtin_log_i64($a0)";
        }

        return $target . '(' . join(', ', @args) . ')' if $target ne '';
        return "/* Backend/F054 missing call contract */ 0";
    }

    if ($k eq 'method_call') {
        my $resolved = $expr->{resolved_call};
        my $canonical = $expr->{canonical_call};
        my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
          : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
        my $call_kind = $meta->{call_kind} // '';
        my $op_id = $meta->{op_id} // '';
        my $target = $meta->{target_name} // ($expr->{method} // '');
        my $recv_expr = $expr->{recv};
        my $recv = _expr_to_c($recv_expr, $ctx);
        my @args = map { _expr_to_c($_, $ctx) } @{ $expr->{args} // [] };

        if ($call_kind eq 'user' || $call_kind eq 'user_function') {
            return $target . '(' . join(', ', ($recv, @args)) . ')';
        }
        if ($call_kind eq 'intrinsic_method') {
            if ($op_id eq 'method.match.v1') {
                _helper_mark($ctx, 'method_match');
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'error_flag');
                return 'metac_method_match(' . $recv . ', ' . ($args[0] // '""') . ')';
            }
            if ($op_id eq 'method.split.v1') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_split(' . $recv . ', ' . ($args[0] // '""') . ')';
            }
            if ($op_id eq 'method.chars.v1') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'method_chars');
                return "metac_method_chars($recv)";
            }
            if ($op_id eq 'method.chunk.v1') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'method_chunk');
                return 'metac_method_chunk(' . $recv . ', ' . ($args[0] // '0') . ')';
            }
            if ($op_id eq 'method.isBlank.v1') {
                _helper_mark($ctx, 'method_isblank');
                return "metac_method_isblank($recv)";
            }
            if ($op_id eq 'method.size.v1') {
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix</
                    && defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident')
                {
                    my $rname = $recv_expr->{name} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    if ($mvar ne '') {
                        _helper_mark($ctx, 'matrix_meta');
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_matrix_axis_size(&' . $mvar . ', ' . ($args[0] // '0') . ')';
                    }
                }
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_list_i64') {
                        _helper_mark($ctx, 'list_list_i64');
                        return 'metac_list_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                }
                if (defined($meta->{receiver_type_hint}) && _is_array_type($meta->{receiver_type_hint})) {
                    if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                        if (_is_string_array_type($meta->{receiver_type_hint})) {
                            _helper_mark($ctx, 'list_str');
                            return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                        }
                        _helper_mark($ctx, 'list_i64');
                        return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'list_i64_size_value');
                    return "metac_list_i64_size_value($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_str_size_value');
                    return "metac_list_str_size_value($recv)";
                }
                _helper_mark($ctx, 'method_size');
                return "metac_method_size($recv)";
            }
            if ($op_id eq 'method.push.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'list_list_i64');
                        return 'metac_list_list_i64_push(&' . $recv_expr->{name} . ', ' . ($args[0] // 'metac_list_i64_empty()') . ')';
                    }
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'list_str_push');
                        return 'metac_list_str_push(&' . $recv_expr->{name} . ', ' . ($args[0] // '""') . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_push(&' . $recv_expr->{name} . ', ' . ($args[0] // '0') . ')';
                }
                _helper_mark($ctx, 'method_push');
                return 'metac_method_push(' . $recv . ', ' . ($args[0] // '0') . ')';
            }
            if ($op_id eq 'method.last.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'last_value_str');
                        return 'metac_builtin_last_value_str(' . $recv_expr->{name} . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'last_value_i64');
                        return 'metac_builtin_last_value_i64(' . $recv_expr->{name} . ')';
                    }
                }
            }
            if ($op_id eq 'method.any.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_list_i64' && defined($expr->{args}[0]) && ref($expr->{args}[0]) eq 'HASH' && (($expr->{args}[0]{kind} // '') eq 'lambda1')) {
                        my $lam = $expr->{args}[0];
                        my $p = $lam->{param} // '';
                        my $b = $lam->{body};
                        if (defined($b) && ref($b) eq 'HASH' && ($b->{kind} // '') eq 'binop' && ($b->{op} // '') eq '&&') {
                            my $l = $b->{left};
                            my $r = $b->{right};
                            my $ok_l = defined($l) && ref($l) eq 'HASH' && ($l->{kind} // '') eq 'binop' && ($l->{op} // '') eq '<=';
                            my $ok_r = defined($r) && ref($r) eq 'HASH' && ($r->{kind} // '') eq 'binop' && ($r->{op} // '') eq '<=';
                            if ($ok_l && $ok_r) {
                                my $lx = $l->{left};
                                my $la = $l->{right};
                                my $ra = $r->{left};
                                my $rx = $r->{right};
                                my $lhs_ok = defined($lx) && ref($lx) eq 'HASH' && ($lx->{kind} // '') eq 'index'
                                  && (($lx->{recv}{kind} // '') eq 'ident') && (($lx->{recv}{name} // '') eq $p)
                                  && (($lx->{index}{kind} // '') eq 'num') && (($lx->{index}{value} // '') eq '0');
                                my $rhs_ok = defined($rx) && ref($rx) eq 'HASH' && ($rx->{kind} // '') eq 'index'
                                  && (($rx->{recv}{kind} // '') eq 'ident') && (($rx->{recv}{name} // '') eq $p)
                                  && (($rx->{index}{kind} // '') eq 'num') && (($rx->{index}{value} // '') eq '1');
                                my $mid_ok = defined($la) && defined($ra)
                                  && ref($la) eq 'HASH' && ref($ra) eq 'HASH'
                                  && (($la->{kind} // '') eq 'ident') && (($ra->{kind} // '') eq 'ident')
                                  && (($la->{name} // '') eq ($ra->{name} // ''));
                                if ($lhs_ok && $rhs_ok && $mid_ok) {
                                    _helper_mark($ctx, 'list_i64');
                                    _helper_mark($ctx, 'list_list_i64');
                                    _helper_mark($ctx, 'any_range_contains');
                                    return 'metac_any_range_contains(&' . $rname . ', ' . _expr_to_c($la, $ctx) . ')';
                                }
                            }
                        }
                    }
                }
            }
            if ($op_id eq 'method.max.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'member_index');
                        _helper_mark($ctx, 'method_max_str');
                        return 'metac_method_max_str(&' . $rname . ')';
                    }
                    if ($rty eq 'struct metac_list_i64') {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'member_index');
                        _helper_mark($ctx, 'method_max_i64');
                        return 'metac_method_max_i64(&' . $rname . ')';
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'member_index');
                    _helper_mark($ctx, 'method_max_str');
                    _helper_mark($ctx, 'method_max_str_value');
                    return 'metac_method_max_str_value(' . $recv . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'member_index');
                    _helper_mark($ctx, 'method_max_i64');
                    _helper_mark($ctx, 'method_max_i64_value');
                    return 'metac_method_max_i64_value(' . $recv . ')';
                }
            }
            if ($op_id eq 'method.slice.v1') {
                my $start = $args[0] // '0';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'method_slice_str');
                        return 'metac_method_slice_str(&' . $rname . ', ' . $start . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_slice_i64');
                    return 'metac_method_slice_i64(&' . $rname . ', ' . $start . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_slice_str');
                    _helper_mark($ctx, 'method_slice_str_value');
                    return 'metac_method_slice_str_value(' . $recv . ', ' . $start . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_slice_i64');
                _helper_mark($ctx, 'method_slice_i64_value');
                return 'metac_method_slice_i64_value(' . $recv . ', ' . $start . ')';
            }
            if ($op_id eq 'method.index.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix_member</) {
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_from_array((int64_t[]){0, 1}, 2)';
                }
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $name = $recv_expr->{name} // '';
                    my $idx_expr = $ctx->{loop_item_index_expr}{$name};
                    return $idx_expr if defined $idx_expr && $idx_expr ne '';
                }
                _helper_mark($ctx, 'member_index');
                return 'metac_last_member_index';
            }
            if ($op_id eq 'method.members.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_members');
                    return "metac_method_members_str($recv)";
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_members');
                return "metac_method_members($recv)";
            }
            if ($op_id eq 'method.insert.v1') {
                my $idx_hint = _expr_c_type_hint($expr->{args}[1], $ctx);
                my $is_matrix_idx = defined($idx_hint) && $idx_hint eq 'struct metac_list_i64' ? 1 : 0;
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name};
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    my $is_matrix_recv = (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix</) ? 1 : 0;
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'method_insert');
                        if ($is_matrix_idx) {
                            if ($is_matrix_recv && $mvar ne '') {
                                _helper_mark($ctx, 'matrix_meta');
                                _helper_mark($ctx, 'list_i64');
                                return 'metac_method_insert_str_matrix_meta(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $mvar . ')';
                            }
                            return 'metac_method_insert_str_matrix(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                        }
                        return 'metac_method_insert_str(&' . $rname . ', ' . ($args[0] // '""') . ', ' . ($args[1] // '0') . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_insert');
                    if ($is_matrix_idx) {
                        if ($is_matrix_recv && $mvar ne '') {
                            _helper_mark($ctx, 'matrix_meta');
                            return 'metac_method_insert_i64_matrix_meta(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $mvar . ')';
                        }
                        return 'metac_method_insert_i64_matrix(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                    }
                    return 'metac_method_insert_i64(&' . $rname . ', ' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_insert');
                    if ($is_matrix_idx) {
                        return 'metac_method_insert_str_matrix_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                    }
                    return 'metac_method_insert_str_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // '0') . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_insert');
                if ($is_matrix_idx) {
                    return 'metac_method_insert_i64_matrix_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                }
                return 'metac_method_insert_i64_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
            }
            if ($op_id eq 'method.log.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'list_i64_render');
                    _helper_mark($ctx, 'log_str');
                    _helper_mark($ctx, 'method_log_list_i64');
                    return "metac_method_log_list_i64($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_str_render');
                    _helper_mark($ctx, 'log_str');
                    _helper_mark($ctx, 'method_log_list_str');
                    return "metac_method_log_list_str($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'const char *') {
                    _helper_mark($ctx, 'log_str');
                    return "metac_builtin_log_str($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'double') {
                    _helper_mark($ctx, 'log_f64');
                    return "metac_builtin_log_f64($recv)";
                }
                if (defined($recv_hint) && $recv_hint eq 'int') {
                    _helper_mark($ctx, 'log_bool');
                    return "metac_builtin_log_bool($recv)";
                }
                _helper_mark($ctx, 'log_i64');
                return "metac_builtin_log_i64($recv)";
            }
            if ($op_id eq 'method.count.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} } // '';
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_list_str_size(&' . $recv_expr->{name} . ')';
                    }
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_count_str');
                    return "metac_method_count_str($recv)";
                }
                _helper_mark($ctx, 'method_count');
                return "metac_method_count($recv)";
            }
            if ($op_id eq 'method.filter.v1') {
                my $pred = $expr->{args}[0];
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($pred) && ref($pred) eq 'HASH'
                    && (($pred->{kind} // '') eq 'lambda1'))
                {
                    my $p = $pred->{param} // '';
                    my $b = $pred->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '==')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        my $lit;
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'ident') && (($l->{name} // '') eq $p)
                            && (($r->{kind} // '') eq 'str'))
                        {
                            $lit = _expr_to_c($r, $ctx);
                        } elsif (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($r->{kind} // '') eq 'ident') && (($r->{name} // '') eq $p)
                            && (($l->{kind} // '') eq 'str'))
                        {
                            $lit = _expr_to_c($l, $ctx);
                        }
                        if (defined($lit)) {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'filter_str_eq');
                            return 'metac_filter_str_eq(' . $recv . ', ' . $lit . ')';
                        }
                    }
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_filter_str');
                    return 'metac_method_filter_identity_str(' . $recv . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($pred) && ref($pred) eq 'HASH'
                    && (($pred->{kind} // '') eq 'lambda1'))
                {
                    my $p = $pred->{param} // '';
                    my $b = $pred->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '||')) {
                        my $extract_eq_num = sub {
                            my ($node) = @_;
                            return undef if !defined($node) || ref($node) ne 'HASH';
                            return undef if ($node->{kind} // '') ne 'binop' || ($node->{op} // '') ne '==';
                            my ($l, $r) = ($node->{left}, $node->{right});
                            if (defined($l) && defined($r)
                                && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                                && ($l->{kind} // '') eq 'ident' && ($l->{name} // '') eq $p
                                && ($r->{kind} // '') eq 'num')
                            {
                                return _expr_to_c($r, $ctx);
                            }
                            if (defined($l) && defined($r)
                                && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                                && ($r->{kind} // '') eq 'ident' && ($r->{name} // '') eq $p
                                && ($l->{kind} // '') eq 'num')
                            {
                                return _expr_to_c($l, $ctx);
                            }
                            return undef;
                        };
                        my $v1 = $extract_eq_num->($b->{left});
                        my $v2 = $extract_eq_num->($b->{right});
                        if (defined($v1) && defined($v2)) {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_eq2');
                            return 'metac_filter_i64_eq2(' . $recv . ', ' . $v1 . ', ' . $v2 . ')';
                        }
                    }
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '!=')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p)
                            && (($l->{right}{kind} // '') eq 'num')
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_mod_ne');
                            my $mod = _expr_to_c($l->{right}, $ctx);
                            my $neq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_mod_ne(' . $recv . ', ' . $mod . ', ' . $neq . ')';
                        }
                    }
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '==')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p)
                            && (($l->{right}{kind} // '') eq 'num')
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_mod_eq');
                            my $mod = _expr_to_c($l->{right}, $ctx);
                            my $eq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_mod_eq(' . $recv . ', ' . $mod . ', ' . $eq . ')';
                        }
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '%')
                            && (($l->{right}{kind} // '') eq 'ident') && (($l->{right}{name} // '') eq $p)
                            && (($r->{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'filter_i64_value_mod_eq');
                            my $value = _expr_to_c($l->{left}, $ctx);
                            my $eq = _expr_to_c($r, $ctx);
                            return 'metac_filter_i64_value_mod_eq(' . $recv . ', ' . $value . ', ' . $eq . ')';
                        }
                    }
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_filter');
                return 'metac_method_filter_identity(' . $recv . ')';
            }
            if ($op_id eq 'method.neighbours.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'const char *') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'method_neighbours_str');
                    return 'metac_method_neighbours_str(' . $recv . ')';
                }
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if ($receiver_type_hint =~ /^matrix</) {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'method_neighbours_i64');
                    return 'metac_method_neighbours_i64(' . $recv . ', ' . ($args[0] // 'metac_list_i64_empty()') . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_neighbours_i64');
                return 'metac_method_neighbours_i64_value(' . $recv . ')';
            }
            if ($op_id eq 'method.sort.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'sort_i64');
                    return 'metac_sort_i64_with_index(' . $recv . ')';
                }
                return $recv;
            }
            if ($op_id eq 'method.sortBy.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_list_i64') {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'list_list_i64');
                    _helper_mark($ctx, 'method_sortby_pair');
                    return 'metac_method_sortby_pair_lex(' . $recv . ')';
                }
                return $recv;
            }
            if ($op_id eq 'method.map.v1') {
                my $arg0 = $expr->{args}[0];
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'ident'
                        && (($arg0->{name} // '') eq 'parseNumber'))
                    {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'parse_number');
                        _helper_mark($ctx, 'map_parse_number');
                        _helper_mark($ctx, 'error_flag');
                        return 'metac_map_parse_number(&' . $rname . ')';
                    }
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'ident')
                    {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'map_str_i64');
                        return 'metac_map_str_i64(&' . $rname . ', ' . ($args[0] // '0') . ')';
                    }
                    if ($rty eq 'struct metac_list_i64'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'ident')
                    {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'map_i64_i64');
                        return 'metac_map_i64_i64(&' . $rname . ', ' . ($args[0] // '0') . ')';
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'ident'
                    && (($arg0->{name} // '') eq 'parseNumber'))
                {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'parse_number');
                    _helper_mark($ctx, 'map_parse_number');
                    _helper_mark($ctx, 'map_parse_number_value');
                    _helper_mark($ctx, 'error_flag');
                    return 'metac_map_parse_number_value(' . $recv . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'ident')
                {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'map_str_i64');
                    _helper_mark($ctx, 'map_str_i64_value');
                    return 'metac_map_str_i64_value(' . $recv . ', ' . ($args[0] // '0') . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'ident')
                {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'map_i64_i64');
                    _helper_mark($ctx, 'map_i64_i64_value');
                    return 'metac_map_i64_i64_value(' . $recv . ', ' . ($args[0] // '0') . ')';
                }
            }
            if ($op_id eq 'method.reduce.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $init = $args[0] // '0';
                my $lam = $expr->{args}[1];
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($lam) && ref($lam) eq 'HASH' && (($lam->{kind} // '') eq 'lambda2'))
                {
                    my $p1 = $lam->{param1} // '';
                    my $p2 = $lam->{param2} // '';
                    my $b = $lam->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '+')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'binop') && (($l->{op} // '') eq '*')
                            && (($r->{kind} // '') eq 'ident') && (($r->{name} // '') eq $p2)
                            && (($l->{left}{kind} // '') eq 'ident') && (($l->{left}{name} // '') eq $p1)
                            && (($l->{right}{kind} // '') eq 'num'))
                        {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'reduce_i64_mul_add');
                            my $factor = _expr_to_c($l->{right}, $ctx);
                            return 'metac_reduce_i64_mul_add(' . $recv . ', ' . $init . ', ' . $factor . ')';
                        }
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($lam) && ref($lam) eq 'HASH' && (($lam->{kind} // '') eq 'lambda2'))
                {
                    my $p1 = $lam->{param1} // '';
                    my $p2 = $lam->{param2} // '';
                    my $b = $lam->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'binop') && (($b->{op} // '') eq '+')) {
                        my $l = $b->{left};
                        my $r = $b->{right};
                        if (defined($l) && defined($r)
                            && ref($l) eq 'HASH' && ref($r) eq 'HASH'
                            && (($l->{kind} // '') eq 'ident') && (($l->{name} // '') eq $p1)
                            && (($r->{kind} // '') eq 'method_call') && (($r->{method} // '') eq 'size')
                            && (($r->{recv}{kind} // '') eq 'ident') && (($r->{recv}{name} // '') eq $p2))
                        {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'reduce_str_add_size');
                            return 'metac_reduce_str_add_size(' . $recv . ', ' . $init . ')';
                        }
                    }
                }
            }
            if ($op_id eq 'method.assert.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $pred = $expr->{args}[0];
                    my $msg = $args[1] // '""';
                    if ($rty eq 'struct metac_list_i64'
                        && defined($pred) && ref($pred) eq 'HASH'
                        && ($pred->{kind} // '') eq 'lambda1')
                    {
                        my $b = $pred->{body};
                        if (defined($b) && ref($b) eq 'HASH' && ($b->{kind} // '') eq 'binop' && ($b->{op} // '') eq '==') {
                            my ($lhs, $rhs) = ($b->{left}, $b->{right});
                            if (defined($lhs) && defined($rhs)
                                && ref($lhs) eq 'HASH' && ref($rhs) eq 'HASH'
                                && ($lhs->{kind} // '') eq 'method_call'
                                && ($lhs->{method} // '') eq 'size'
                                && ($rhs->{kind} // '') eq 'num')
                            {
                                my $need = $rhs->{value} // '0';
                                _helper_mark($ctx, 'list_i64');
                                _helper_mark($ctx, 'assert_size_i64');
                                _helper_mark($ctx, 'error_flag');
                                return 'metac_assert_size_i64(&' . $rname . ', ' . $need . ', ' . $msg . ')';
                            }
                        }
                    }
                }
            }
        }

        if (($expr->{method} // '') eq 'index') {
            if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                my $name = $recv_expr->{name} // '';
                my $idx_expr = $ctx->{loop_item_index_expr}{$name};
                return $idx_expr if defined $idx_expr && $idx_expr ne '';
            }
            return '0';
        }

        return $target . '(' . join(', ', ($recv, @args)) . ')' if $target ne '';
        return "/* Backend/F054 missing method contract */ 0";
    }

    return "/* Backend/F054 missing expr emitter for kind '$k' */ 0";
}

sub _emit_stmt {
    my ($stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx) = @_;
    my $sp = ' ' x $indent;
    my $k = $stmt->{kind} // '';

    if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed' || $k eq 'const_try_expr') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;

        my $inferred = _expr_c_type_hint($stmt->{expr}, $ctx);
        my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
        my $rhs = _expr_to_c($stmt->{expr}, $ctx);
        my $constraints = $stmt->{constraints};
        if ($c_ty eq 'struct metac_list_str' && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH' && ($stmt->{expr}{kind} // '') eq 'list_literal') {
            _helper_mark($ctx, 'list_str');
            my @items = @{ $stmt->{expr}{items} // [] };
            if (!@items) {
                $rhs = 'metac_list_str_empty()';
            } else {
                my @vals = map { _expr_to_c($_, $ctx) } @items;
                my $arr = '(const char*[]){' . join(', ', @vals) . '}';
                $rhs = 'metac_list_str_from_array(' . $arr . ', ' . scalar(@vals) . ')';
            }
        }
        if ($c_ty eq 'struct metac_list_list_i64' && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH' && ($stmt->{expr}{kind} // '') eq 'list_literal') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            my @items = @{ $stmt->{expr}{items} // [] };
            if (!@items) {
                $rhs = 'metac_list_list_i64_empty()';
            } else {
                my @vals = map { _expr_to_c($_, $ctx) } @items;
                my $arr = '(struct metac_list_i64[]){' . join(', ', @vals) . '}';
                $rhs = 'metac_list_list_i64_from_array(' . $arr . ', ' . scalar(@vals) . ')';
            }
        }
        my $size_need = _constraint_exact_size($constraints);
        if ($c_ty eq 'const char *' && defined($size_need) && $size_need >= 0) {
            _helper_mark($ctx, 'error_flag');
            _helper_mark($ctx, 'constrained_string_assign');
            $rhs = 'metac_constrained_string_assign(' . $rhs . ', ' . $size_need . ')';
        }
        _helper_mark($ctx, 'list_str') if $c_ty eq 'struct metac_list_str';
        _helper_mark($ctx, 'list_i64') if $c_ty eq 'struct metac_list_i64';
        _helper_mark($ctx, 'list_list_i64') if $c_ty eq 'struct metac_list_list_i64';
        push @$out, $decl ? "${sp}$name = $rhs;" : "${sp}$c_ty $name = $rhs;";
        $ctx->{var_types}{$name} = $c_ty;
        $ctx->{var_constraints}{$name} = $constraints if $name ne '';
        my $mmeta = _matrix_meta_for_type($stmt->{type});
        if (defined($mmeta) && ref($mmeta) eq 'HASH' && $name ne '') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'matrix_meta');
            my $mvar = _matrix_meta_var_name($name);
            my $mdecl = $seen_decl->{$mvar}++;
            my $dim = int($mmeta->{dim} // 0);
            my $has_size = ($mmeta->{has_size} // 0) ? 1 : 0;
            my @sizes = @{ $mmeta->{sizes} // [] };
            if (!$has_size || @sizes != $dim) {
                @sizes = map { -1 } (1 .. $dim);
            }
            my $sizes_c = @sizes ? join(', ', @sizes) : '-1';
            my $init = "metac_matrix_meta_init($dim, (int64_t[]){$sizes_c}, " . ($has_size ? 1 : 0) . ')';
            push @$out, $mdecl ? "${sp}$mvar = $init;" : "${sp}struct metac_matrix_meta $mvar = $init;";
            $ctx->{matrix_meta_vars}{$name} = $mvar;
        }
        return;
    }
    if ($k eq 'const_try_tail_expr') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;
        my $step_id = $ctx->{tmp_counter}++;
        my $first_name = "__try_tail_${step_id}_0";
        my $first_ty = _expr_c_type_hint($stmt->{first}, $ctx) // 'int64_t';
        my $first_rhs = _expr_to_c($stmt->{first}, $ctx);

        my $final_ty = $first_ty;
        my $probe_name = $first_name;
        my $probe_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            $ctx->{var_types}{$probe_name} = $probe_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $probe_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $probe_ty;
            $probe_name = "__try_tail_${step_id}_" . ($i + 1);
            $probe_ty = $next_ty;
            $final_ty = $next_ty;
        }

        my $decl_ty = _type_to_c($stmt->{type}, $final_ty // 'int64_t');
        my $def = _default_return_for_c_type($decl_ty);
        push @$out, $decl ? "${sp}$name = $def;" : "${sp}$decl_ty $name = $def;";
        push @$out, "${sp}$first_ty $first_name = $first_rhs;";
        push @$out, "${sp}if (!metac_last_error) {";

        my $cur_name = $first_name;
        my $cur_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            my $next_name = "__try_tail_${step_id}_" . ($i + 1);
            $ctx->{var_types}{$cur_name} = $cur_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $cur_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $cur_ty;
            my $next_rhs = _expr_to_c($mexpr, $ctx);
            push @$out, "${sp}  $next_ty $next_name = $next_rhs;";
            $cur_name = $next_name;
            $cur_ty = $next_ty;
        }

        push @$out, "${sp}  $name = $cur_name;";
        push @$out, "${sp}}";
        $ctx->{var_types}{$name} = $decl_ty;
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'const_try_chain') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;

        my $step_id = $ctx->{tmp_counter}++;
        my $first_name = "__chain_${step_id}_0";
        my $first_ty = _expr_c_type_hint($stmt->{first}, $ctx) // 'int64_t';
        my $first_rhs = _expr_to_c($stmt->{first}, $ctx);
        push @$out, "${sp}$first_ty $first_name = $first_rhs;";

        my $cur_name = $first_name;
        my $cur_ty = $first_ty;
        for my $i (0 .. $#{ $stmt->{steps} // [] }) {
            my $chain = $stmt->{steps}[$i];
            next if !defined($chain) || ref($chain) ne 'HASH';
            my $next_name = "__chain_${step_id}_" . ($i + 1);
            $ctx->{var_types}{$cur_name} = $cur_ty;
            my $mexpr = {
                kind => 'method_call',
                method => ($chain->{name} // ''),
                recv => { kind => 'ident', name => $cur_name },
                args => $chain->{args} // [],
                resolved_call => $chain->{resolved_call},
                canonical_call => $chain->{canonical_call},
            };
            my $next_ty = _expr_c_type_hint($mexpr, $ctx) // $cur_ty;
            my $next_rhs = _expr_to_c($mexpr, $ctx);
            push @$out, "${sp}$next_ty $next_name = $next_rhs;";
            $cur_name = $next_name;
            $cur_ty = $next_ty;
        }

        push @$out, $decl ? "${sp}$name = $cur_name;" : "${sp}$cur_ty $name = $cur_name;";
        $ctx->{var_types}{$name} = $cur_ty;
        return;
    }
    if ($k eq 'const_or_catch') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;
        my $c_ty = _expr_c_type_hint($stmt->{expr}, $ctx) // 'int64_t';
        my $tmp = '__or_tmp_' . ($ctx->{tmp_counter}++);
        my $tmp_ty = _expr_c_type_hint($stmt->{expr}, $ctx) // $c_ty;
        my $def = _default_return_for_c_type($c_ty);

        push @$out, $decl ? "${sp}$name = $def;" : "${sp}$c_ty $name = $def;";
        push @$out, "${sp}$tmp_ty $tmp = " . _expr_to_c($stmt->{expr}, $ctx) . ';';
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}} else {";
        push @$out, "${sp}  $name = $tmp;";
        push @$out, "${sp}}";
        $ctx->{var_types}{$name} = $c_ty;
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'expr_or_catch') {
        push @$out, $sp . _expr_to_c($stmt->{expr}, $ctx) . ';';
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}}";
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'destructure_split_or') {
        _helper_mark($ctx, 'list_str');
        _helper_mark($ctx, 'builtin_split');
        _helper_mark($ctx, 'list_str_get');
        _helper_mark($ctx, 'error_flag');
        my $src_expr = defined($stmt->{source_expr}) ? $stmt->{source_expr} : $stmt->{source};
        my $delim_expr = defined($stmt->{delim_expr}) ? $stmt->{delim_expr} : $stmt->{delim};
        my $tmp = '__split_or_' . ($ctx->{tmp_counter}++);
        my @vars = @{ $stmt->{vars} // [] };
        for my $v (@vars) {
            next if !defined($v) || $v eq '';
            my $decl = $seen_decl->{$v}++;
            push @$out, "${sp}const char *$v = \"\";" if !$decl;
            $ctx->{var_types}{$v} = 'const char *';
        }
        my $src_c = _expr_to_c($src_expr, $ctx);
        my $delim_c = _expr_to_c($delim_expr, $ctx);
        push @$out, "${sp}struct metac_list_str $tmp = metac_builtin_split($src_c, $delim_c);";
        push @$out, "${sp}if (metac_last_error) {";
        my $err_name = $stmt->{err_name} // '';
        if ($err_name ne '') {
            _helper_mark($ctx, 'error_message');
            push @$out, "${sp}  const char *$err_name = metac_last_error_message;";
            $ctx->{var_types}{$err_name} = 'const char *';
        }
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}} else {";
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            push @$out, "${sp}  $v = metac_list_str_get(&$tmp, $i);";
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'destructure_match') {
        _helper_mark($ctx, 'list_str');
        _helper_mark($ctx, 'method_match');
        _helper_mark($ctx, 'list_str_get');
        my $tmp = '__match_' . ($ctx->{tmp_counter}++);
        my @vars = @{ $stmt->{vars} // [] };
        my $types = $stmt->{var_types};
        my @var_types = map {
            my $t = (defined($types) && ref($types) eq 'ARRAY') ? ($types->[$_] // 'string') : 'string';
            ($t eq 'number') ? 'number' : 'string';
        } 0 .. $#vars;
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            my $decl = $seen_decl->{$v}++;
            if (($var_types[$i] // 'string') eq 'number') {
                push @$out, "${sp}int64_t $v = 0;" if !$decl;
                $ctx->{var_types}{$v} = 'int64_t';
            } else {
                push @$out, "${sp}const char *$v = \"\";" if !$decl;
                $ctx->{var_types}{$v} = 'const char *';
            }
        }
        my $src = $stmt->{source_var} // '';
        my $src_c = $src ne '' ? $src : '""';
        my $pattern = '"' . _c_escape($stmt->{pattern} // '') . '"';
        push @$out, "${sp}struct metac_list_str $tmp = metac_method_match($src_c, $pattern);";
        for my $i (0 .. $#vars) {
            my $v = $vars[$i];
            next if !defined($v) || $v eq '';
            if (($var_types[$i] // 'string') eq 'number') {
                _helper_mark($ctx, 'parse_number');
                _helper_mark($ctx, 'error_flag');
                push @$out, "${sp}$v = metac_builtin_parse_number(metac_list_str_get(&$tmp, $i));";
            } else {
                push @$out, "${sp}$v = metac_list_str_get(&$tmp, $i);";
            }
        }
        return;
    }
    if ($k eq 'destructure_list') {
        my $src = $stmt->{expr};
        if (defined($src) && ref($src) eq 'HASH' && ($src->{kind} // '') eq 'ident') {
            my $src_name = $src->{name};
            my $src_ty = $ctx->{var_types}{$src_name} // '';
            for my $i (0 .. $#{ $stmt->{vars} // [] }) {
                my $v = $stmt->{vars}[$i];
                my $decl = $seen_decl->{$v}++;
                if ($src_ty eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'list_str_get');
                    my $rhs = "metac_list_str_get(&$src_name, $i)";
                    push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}const char *$v = $rhs;";
                    $ctx->{var_types}{$v} = 'const char *';
                    next;
                }
                _helper_mark($ctx, 'list_i64');
                my $rhs = "metac_list_i64_get(&$src_name, $i)";
                push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}int64_t $v = $rhs;";
                $ctx->{var_types}{$v} = 'int64_t';
            }
            return;
        }
        my $src_ty = _expr_c_type_hint($src, $ctx) // 'struct metac_list_i64';
        my $tmp = '__destructure_src_' . ($ctx->{tmp_counter}++);
        if ($src_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}struct metac_list_str $tmp = " . _expr_to_c($src, $ctx) . ';';
            for my $i (0 .. $#{ $stmt->{vars} // [] }) {
                my $v = $stmt->{vars}[$i];
                my $decl = $seen_decl->{$v}++;
                my $rhs = "metac_list_str_get(&$tmp, $i)";
                push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}const char *$v = $rhs;";
                $ctx->{var_types}{$v} = 'const char *';
            }
            return;
        }
        _helper_mark($ctx, 'list_i64');
        push @$out, "${sp}struct metac_list_i64 $tmp = " . _expr_to_c($src, $ctx) . ';';
        for my $i (0 .. $#{ $stmt->{vars} // [] }) {
            my $v = $stmt->{vars}[$i];
            my $decl = $seen_decl->{$v}++;
            my $rhs = "metac_list_i64_get(&$tmp, $i)";
            push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}int64_t $v = $rhs;";
            $ctx->{var_types}{$v} = 'int64_t';
        }
        return;
    }
    if ($k eq 'assign' || $k eq 'typed_assign') {
        my $name = $stmt->{name} // '__missing_name';
        my $rhs = _expr_to_c($stmt->{expr}, $ctx);
        my $constraints = $stmt->{constraints};
        if ((!defined($constraints) || ref($constraints) ne 'HASH') && exists $ctx->{var_constraints}{$name}) {
            $constraints = $ctx->{var_constraints}{$name};
        }
        my $target_ty = $ctx->{var_types}{$name} // '';
        my $size_need = _constraint_exact_size($constraints);
        if ($target_ty eq 'const char *' && defined($size_need) && $size_need >= 0) {
            _helper_mark($ctx, 'error_flag');
            _helper_mark($ctx, 'constrained_string_assign');
            $rhs = 'metac_constrained_string_assign(' . $rhs . ', ' . $size_need . ')';
        }
        push @$out, "${sp}$name = $rhs;";
        if ($k eq 'typed_assign' && defined($constraints) && ref($constraints) eq 'HASH') {
            $ctx->{var_constraints}{$name} = $constraints;
        }
        my $mvar = $ctx->{matrix_meta_vars}{$name} // '';
        if ($mvar ne '' && defined($stmt->{expr}) && ref($stmt->{expr}) eq 'HASH'
            && ($stmt->{expr}{kind} // '') eq 'ident')
        {
            my $src = $stmt->{expr}{name} // '';
            my $src_mvar = $ctx->{matrix_meta_vars}{$src} // '';
            push @$out, "${sp}$mvar = $src_mvar;" if $src_mvar ne '';
        }
        return;
    }
    if ($k eq 'assign_op') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '+=';
        push @$out, "${sp}$name $op " . _expr_to_c($stmt->{expr}, $ctx) . ';';
        return;
    }
    if ($k eq 'incdec') {
        my $name = $stmt->{name} // '__missing_name';
        my $op = $stmt->{op} // '++';
        push @$out, "${sp}$name$op;";
        return;
    }
    if ($k eq 'expr_stmt' || $k eq 'expr_stmt_try') {
        push @$out, $sp . _expr_to_c($stmt->{expr}, $ctx) . ';';
        return;
    }
    if ($k eq 'return') {
        return if $suppress_step_return;
        my $rv = $stmt->{expr};
        if (defined($rv) && ref($rv) eq 'HASH' && (($rv->{kind} // '') eq 'call') && (($rv->{name} // '') eq 'error')) {
            my $args = $rv->{args} // [];
            my $msg = (ref($args) eq 'ARRAY' && @$args) ? _expr_to_c($args->[0], $ctx) : '""';
            _helper_mark($ctx, 'builtin_error');
            _helper_mark($ctx, 'error_flag');
            my $def = $ctx->{fn_default_return} // '0';
            push @$out, "${sp}metac_builtin_error($msg);";
            push @$out, "${sp}return $def;";
            return;
        }
        if (($ctx->{fn_name} // '') eq 'main') {
            _helper_mark($ctx, 'error_flag');
            if (defined($rv)) {
                my $tmp = '__main_ret_' . ($ctx->{tmp_counter}++);
                push @$out, "${sp}int $tmp = " . _expr_to_c($rv, $ctx) . ';';
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $tmp;";
            } else {
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return 0;";
            }
            return;
        }
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv, $ctx) . ';') : ($sp . 'return 0;');
        return;
    }

    if ($k eq 'if') {
        return if ($ctx->{current_region_exit_kind} // '') eq 'IfExit';
        my $cond = _expr_to_c($stmt->{cond}, $ctx);
        push @$out, "${sp}if ($cond) {";
        my %then_seen = %$seen_decl;
        for my $s (@{ $stmt->{then_body} // [] }) {
            _emit_stmt($s, $out, $indent + 2, \%then_seen, 0, $ctx);
        }
        if (defined($stmt->{else_body}) && ref($stmt->{else_body}) eq 'ARRAY' && @{ $stmt->{else_body} }) {
            push @$out, "${sp}} else {";
            my %else_seen = %$seen_decl;
            for my $s (@{ $stmt->{else_body} }) {
                _emit_stmt($s, $out, $indent + 2, \%else_seen, 0, $ctx);
            }
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'rewind') {
        for my $lid (@{ $ctx->{loop_ids} // [] }) {
            push @$out, "${sp}__loop_init_$lid = 0;";
        }
        my $to = $ctx->{current_region_exit_target};
        push @$out, defined($to) ? "${sp}goto region_$to;" : "${sp}continue;";
        return;
    }
    if ($k eq 'for_each' || $k eq 'for_each_try' || $k eq 'for_lines') {
        my $exit_kind = $ctx->{current_region_exit_kind} // '';
        return if ($k eq 'for_each' || $k eq 'for_each_try') && $exit_kind eq 'ForInExit';

        my $iter_expr = $stmt->{iterable};
        my $iter_c;
        my $iter_ty;
        if ($k eq 'for_lines') {
            my $src_expr = defined($stmt->{source}) ? $stmt->{source} : { kind => 'ident', name => 'STDIN' };
            my $src_c = _expr_to_c($src_expr, $ctx);
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'builtin_lines');
            _helper_mark($ctx, 'builtin_split');
            _helper_mark($ctx, 'error_flag');
            $iter_c = 'metac_builtin_lines(' . $src_c . ')';
            $iter_ty = 'struct metac_list_str';
        } else {
            $iter_c = _expr_to_c($iter_expr, $ctx);
            $iter_ty = _expr_c_type_hint($iter_expr, $ctx) // 'struct metac_list_i64';
        }
        my $loop_id = '__inline_for_' . ($ctx->{tmp_counter}++);
        my $var = $stmt->{var} // '__item';
        my $decl = $seen_decl->{$var}++;

        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}struct metac_list_str ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_str_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_str_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  const char *$var = $bind;";
            $ctx->{var_types}{$var} = 'const char *';
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            push @$out, "${sp}struct metac_list_list_i64 ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_list_i64_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_list_i64_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  struct metac_list_i64 $var = $bind;";
            $ctx->{var_types}{$var} = 'struct metac_list_i64';
        } else {
            _helper_mark($ctx, 'list_i64');
            push @$out, "${sp}struct metac_list_i64 ${loop_id}_iter = $iter_c;";
            push @$out, "${sp}for (int64_t ${loop_id}_idx = 0; ${loop_id}_idx < metac_list_i64_size(&${loop_id}_iter); ++${loop_id}_idx) {";
            my $bind = "metac_list_i64_get(&${loop_id}_iter, ${loop_id}_idx)";
            push @$out, $decl ? "${sp}  $var = $bind;" : "${sp}  int64_t $var = $bind;";
            $ctx->{var_types}{$var} = 'int64_t';
        }

        for my $inner (@{ $stmt->{body} // [] }) {
            _emit_stmt($inner, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}}";
        return;
    }
    if ($k eq 'break' || $k eq 'continue') {
        my $to = $ctx->{current_region_exit_target};
        if (($ctx->{current_region_exit_kind} // '') eq 'Goto' && defined($to) && $to ne '') {
            push @$out, "${sp}goto region_$to;";
            return;
        }
        push @$out, "${sp}$k;";
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing stmt emitter for kind '$k' */};
}

sub _emit_exit {
    my ($exit, $out, $indent, $default_return, $ctx, $fn_name) = @_;
    my $sp = ' ' x $indent;
    my $k = $exit->{kind} // '';

    if ($k eq 'Goto') {
        my $to = $exit->{target_region} // '__missing_region';
        push @$out, "${sp}goto region_$to;";
        return;
    }
    if ($k eq 'IfExit') {
        my $cond = _expr_to_c($exit->{cond_value}, $ctx);
        my $t = $exit->{then_region} // '__missing_region';
        my $e = $exit->{else_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$t;";
        push @$out, "${sp}goto region_$e;";
        return;
    }
    if ($k eq 'WhileExit') {
        my $cond = _expr_to_c($exit->{cond_value}, $ctx);
        my $b = $exit->{body_region} // '__missing_region';
        my $n = $exit->{end_region} // '__missing_region';
        push @$out, "${sp}if ($cond) goto region_$b;";
        push @$out, "${sp}goto region_$n;";
        return;
    }
    if ($k eq 'ForInExit') {
        my $loop = $exit->{loop_id} // 'L0';
        my $item = $exit->{item_name} // '__item';
        my $body = $exit->{body_region} // '__missing_region';
        my $end = $exit->{end_region} // '__missing_region';
        my $iter = $exit->{iterable_expr};
        my $loop_meta = $ctx->{loop_meta}{$loop} // {};
        my $iter_ty = $loop_meta->{iter_c_type} // 'struct metac_list_i64';
        my $iter_c = _expr_to_c($iter, $ctx);
        push @$out, "${sp}if (!__loop_init_$loop) {";
        push @$out, "${sp}  __loop_init_$loop = 1;";
        push @$out, "${sp}  __loop_idx_$loop = 0;";
        push @$out, "${sp}  __loop_iter_$loop = $iter_c;";
        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            push @$out, "${sp}  __loop_len_$loop = metac_list_str_size(&__loop_iter_$loop);";
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            push @$out, "${sp}  __loop_len_$loop = metac_list_list_i64_size(&__loop_iter_$loop);";
        } else {
            _helper_mark($ctx, 'list_i64');
            push @$out, "${sp}  __loop_len_$loop = metac_list_i64_size(&__loop_iter_$loop);";
        }
        push @$out, "${sp}}";
        push @$out, "${sp}if (__loop_idx_$loop < __loop_len_$loop) {";
        if ($iter_ty eq 'struct metac_list_str') {
            push @$out, "${sp}  $item = metac_list_str_get(&__loop_iter_$loop, __loop_idx_$loop);";
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            push @$out, "${sp}  $item = metac_list_list_i64_get(&__loop_iter_$loop, __loop_idx_$loop);";
        } else {
            push @$out, "${sp}  $item = metac_list_i64_get(&__loop_iter_$loop, __loop_idx_$loop);";
        }
        push @$out, "${sp}  __loop_idx_$loop++;";
        push @$out, "${sp}  goto region_$body;";
        push @$out, "${sp}}";
        push @$out, "${sp}__loop_init_$loop = 0;";
        push @$out, "${sp}goto region_$end;";
        return;
    }
    if ($k eq 'TryExit') {
        my $ok = $exit->{ok_region} // '__missing_region';
        my $err = $exit->{err_region} // '__missing_region';
        push @$out, "${sp}if (metac_last_error) {";
        push @$out, "${sp}  metac_last_error = 0;";
        push @$out, "${sp}  goto region_$err;";
        push @$out, "${sp}}";
        push @$out, "${sp}goto region_$ok;";
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'Return') {
        my $rv = $exit->{value};
        if (($fn_name // '') eq 'main') {
            _helper_mark($ctx, 'error_flag');
            if (defined($rv)) {
                my $tmp = '__main_ret_exit_' . ($ctx->{tmp_counter}++);
                push @$out, "${sp}int $tmp = " . _expr_to_c($rv, $ctx) . ';';
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $tmp;";
            } else {
                push @$out, "${sp}if (metac_last_error) return 2;";
                push @$out, "${sp}return $default_return;";
            }
            return;
        }
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv, $ctx) . ';') : ($sp . "return $default_return;");
        return;
    }
    if ($k eq 'PropagateError') {
        if (($fn_name // '') eq 'main') {
            push @$out, "${sp}return 2;";
        } else {
            _helper_mark($ctx, 'error_flag');
            push @$out, "${sp}metac_last_error = 1;";
            push @$out, "${sp}return $default_return;";
        }
        return;
    }
    push @$out, qq{$sp/* Backend/F054 missing exit emitter for kind '$k' */};
}

sub _collect_forin_loops {
    my ($ordered_regions, $seed_var_types) = @_;
    my %var_types = %{ $seed_var_types // {} };
    my $tmp_ctx = { var_types => \%var_types };
    my %seen;
    my @loops;
    for my $region (@{ $ordered_regions // [] }) {
        for my $step (@{ $region->{steps} // [] }) {
            my $stmt = step_payload_to_stmt($step->{payload});
            next if !defined($stmt) || ref($stmt) ne 'HASH';
            my $k = $stmt->{kind} // '';
            if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed' || $k eq 'const_try_expr' || $k eq 'const_or_catch') {
                my $name = $stmt->{name} // '';
                next if $name eq '';
                my $expr = $stmt->{expr};
                my $inferred = _expr_c_type_hint($expr, $tmp_ctx);
                my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
                $var_types{$name} = $c_ty;
                next;
            }
            if ($k eq 'const_try_tail_expr') {
                my $name = $stmt->{name} // '';
                next if $name eq '';
                my $first_ty = _expr_c_type_hint($stmt->{first}, $tmp_ctx) // 'int64_t';
                my $cur_name = '__try_tail_probe_' . ($name // 'v');
                my $cur_ty = $first_ty;
                for my $chain (@{ $stmt->{steps} // [] }) {
                    next if !defined($chain) || ref($chain) ne 'HASH';
                    $var_types{$cur_name} = $cur_ty;
                    my $mexpr = {
                        kind => 'method_call',
                        method => ($chain->{name} // ''),
                        recv => { kind => 'ident', name => $cur_name },
                        args => $chain->{args} // [],
                        resolved_call => $chain->{resolved_call},
                        canonical_call => $chain->{canonical_call},
                    };
                    $cur_ty = _expr_c_type_hint($mexpr, $tmp_ctx) // $cur_ty;
                    $cur_name .= '_n';
                }
                my $c_ty = _type_to_c($stmt->{type}, $cur_ty // 'int64_t');
                $var_types{$name} = $c_ty;
                next;
            }
            if ($k eq 'destructure_list') {
                my $src = $stmt->{expr};
                next if !defined($src) || ref($src) ne 'HASH' || ($src->{kind} // '') ne 'ident';
                my $src_name = $src->{name} // '';
                my $src_ty = $var_types{$src_name} // '';
                my $item_ty = $src_ty eq 'struct metac_list_str' ? 'const char *' : 'int64_t';
                for my $v (@{ $stmt->{vars} // [] }) {
                    next if !defined($v) || $v eq '';
                    $var_types{$v} = $item_ty;
                }
            }
        }

        my $exit = $region->{exit} // {};
        next if ($exit->{kind} // '') ne 'ForInExit';
        my $id = $exit->{loop_id} // '';
        next if $id eq '' || $seen{$id}++;
        my $iter_ty = _expr_c_type_hint($exit->{iterable_expr}, $tmp_ctx);
        my $index_expr;
        if (!defined($iter_ty) || $iter_ty eq '') {
            my $iter = $exit->{iterable_expr};
            if (defined($iter) && ref($iter) eq 'HASH') {
                my $resolved = $iter->{resolved_call};
                my $canonical = $iter->{canonical_call};
                my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
                  : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
                $iter_ty = _result_type_to_c($meta->{result_type});
            }
        }
        $iter_ty = 'struct metac_list_i64' if !defined($iter_ty) || $iter_ty eq '';
        my $iter_expr = $exit->{iterable_expr};
        if (defined($iter_expr) && ref($iter_expr) eq 'HASH') {
            my $resolved = $iter_expr->{resolved_call};
            my $canonical = $iter_expr->{canonical_call};
            my $meta = (defined($resolved) && ref($resolved) eq 'HASH') ? $resolved
              : ((defined($canonical) && ref($canonical) eq 'HASH') ? $canonical : {});
            my $op_id = $meta->{op_id} // '';
            if ($op_id eq 'method.sort.v1') {
                $index_expr = "metac_sort_index_at(__loop_idx_$id - 1)";
            }
        }
        my $item_ty = $iter_ty eq 'struct metac_list_str' ? 'const char *'
          : ($iter_ty eq 'struct metac_list_list_i64' ? 'struct metac_list_i64' : 'int64_t');
        my $item_name = $exit->{item_name} // '__item';
        push @loops, {
            loop_id => $id,
            item_name => $item_name,
            iter_c_type => $iter_ty,
            item_c_type => $item_ty,
            index_expr => $index_expr,
        };
        $var_types{$item_name} = $item_ty if defined($item_name) && $item_name ne '';
    }
    return \@loops;
}

sub _emit_function {
    my ($fn) = @_;
    my @out;
    my $name = $fn->{name} // '__missing_fn_name';
    my $ret_type = $name eq 'main' ? 'int' : _type_to_c($fn->{return_type}, 'int64_t');
    my $default_return = _default_return_for_c_type($ret_type);
    my @params;
    for my $p (@{ $fn->{params} // [] }) {
        my $pn = $p->{name} // 'p';
        my $pt = _type_to_c($p->{type}, 'int64_t');
        push @params, "$pt $pn";
    }
    my $param_sig = @params ? join(', ', @params) : 'void';
    push @out, "$ret_type $name($param_sig) {";

    my $ctx = {
        helpers => {},
        var_types => {},
        var_constraints => {},
        matrix_meta_vars => {},
        fn_default_return => $default_return,
        fn_c_return_type => $ret_type,
        fn_name => $name,
    };
    _helper_mark($ctx, 'list_i64') if $ret_type eq 'struct metac_list_i64';
    _helper_mark($ctx, 'list_str') if $ret_type eq 'struct metac_list_str';
    if ($ret_type eq 'struct metac_list_list_i64') {
        _helper_mark($ctx, 'list_i64');
        _helper_mark($ctx, 'list_list_i64');
    }
    for my $p (@{ $fn->{params} // [] }) {
        my $pn = $p->{name} // '';
        next if $pn eq '';
        my $pt = _type_to_c($p->{type}, 'int64_t');
        $ctx->{var_types}{$pn} = $pt;
        $ctx->{var_constraints}{$pn} = $p->{constraints} if defined($p->{constraints});
        _helper_mark($ctx, 'list_i64') if $pt eq 'struct metac_list_i64';
        _helper_mark($ctx, 'list_str') if $pt eq 'struct metac_list_str';
        if ($pt eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
        }
        my $mmeta = _matrix_meta_for_type($p->{type});
        if (defined($mmeta) && ref($mmeta) eq 'HASH') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'matrix_meta');
            my $mvar = _matrix_meta_var_name($pn);
            $ctx->{matrix_meta_vars}{$pn} = $mvar;
            my $dim = int($mmeta->{dim} // 0);
            my $has_size = ($mmeta->{has_size} // 0) ? 1 : 0;
            my @sizes = @{ $mmeta->{sizes} // [] };
            if (!$has_size || @sizes != $dim) {
                @sizes = map { -1 } (1 .. $dim);
            }
            my $sizes_c = @sizes ? join(', ', @sizes) : '-1';
            push @out, "  struct metac_matrix_meta $mvar = metac_matrix_meta_init($dim, (int64_t[]){$sizes_c}, " . ($has_size ? 1 : 0) . ');';
        }
    }

    my $regions = $fn->{regions} // [];
    my $schedule = $fn->{region_schedule};
    my @ordered_regions;
    if (defined($schedule) && ref($schedule) eq 'ARRAY' && @$schedule) {
        my %by_id = map { ($_->{id} // '') => $_ } @$regions;
        my %seen;
        @ordered_regions = map { $seen{$_} = 1; $by_id{$_} } grep { exists $by_id{$_} } @$schedule;
        push @ordered_regions, grep { !$seen{ $_->{id} // '' } } @$regions;
    } else {
        @ordered_regions = @$regions;
    }
    my %regions_by_id = map { (($_->{id} // '') => $_) } @ordered_regions;

    my $loops = _collect_forin_loops(\@ordered_regions, $ctx->{var_types});
    $ctx->{loop_meta} = { map { ($_->{loop_id} // '') => $_ } @$loops };
    for my $loop (@$loops) {
        my $lid = $loop->{loop_id};
        my $item = $loop->{item_name};
        my $iter_ty = $loop->{iter_c_type} // 'struct metac_list_i64';
        my $item_ty = $loop->{item_c_type} // 'int64_t';
        my $iter_init = 'metac_list_i64_empty()';
        if ($iter_ty eq 'struct metac_list_str') {
            _helper_mark($ctx, 'list_str');
            _helper_mark($ctx, 'list_str_get');
            $iter_init = 'metac_list_str_empty()';
        } elsif ($iter_ty eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
            $iter_init = 'metac_list_list_i64_empty()';
        } else {
            _helper_mark($ctx, 'list_i64');
        }
        push @out, "  int __loop_init_$lid = 0;";
        push @out, "  int64_t __loop_idx_$lid = 0;";
        push @out, "  int64_t __loop_len_$lid = 0;";
        push @out, "  $iter_ty __loop_iter_$lid = $iter_init;";
        if ($item_ty eq 'const char *') {
            push @out, qq{  const char *$item = "";};
        } elsif ($item_ty eq 'struct metac_list_i64') {
            _helper_mark($ctx, 'list_i64');
            push @out, "  struct metac_list_i64 $item = metac_list_i64_empty();";
        } else {
            push @out, "  int64_t $item = 0;";
        }
        $ctx->{var_types}{$item} = $item_ty;
        my $idx_expr = $loop->{index_expr};
        if (defined($idx_expr) && $idx_expr ne '') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'sort_i64');
            $ctx->{loop_item_index_expr}{$item} = $idx_expr;
        } else {
            $ctx->{loop_item_index_expr}{$item} = "(__loop_idx_$lid - 1)";
        }
    }
    $ctx->{loop_ids} = [ map { $_->{loop_id} } @$loops ];

    my %seen_decl;
    for my $region (@ordered_regions) {
        my $rid = $region->{id} // '__missing_region';
        my $exit_kind = $region->{exit}{kind} // '';
        $ctx->{current_region_exit_kind} = $exit_kind;
        $ctx->{current_region_exit_target} = ($exit_kind eq 'Goto') ? ($region->{exit}{target_region}) : undef;
        push @out, "region_$rid: ;";
        my @steps = @{ $region->{steps} // [] };
        my @stmts = map { step_payload_to_stmt($_->{payload}) } @steps;
        if ($exit_kind eq 'IfExit' && @stmts) {
            my $if_idx = -1;
            for my $i (0 .. $#stmts) {
                my $stmt = $stmts[$i];
                next if !defined($stmt) || ref($stmt) ne 'HASH';
                if (($stmt->{kind} // '') eq 'if') {
                    $if_idx = $i;
                    last;
                }
            }
            if ($if_idx >= 0 && $if_idx < $#stmts) {
                for my $i (0 .. $if_idx - 1) {
                    my $stmt = $stmts[$i];
                    if (!defined $stmt) {
                        push @out, '  /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 2, \%seen_decl, 0, $ctx);
                }
                my $cond = _expr_to_c($region->{exit}{cond_value}, $ctx);
                my $then_region = $region->{exit}{then_region} // '__missing_region';
                my $else_region = $region->{exit}{else_region} // '__missing_region';
                my $then_target = $then_region;
                my $else_target = $else_region;
                my $then_node = $regions_by_id{$then_region};
                my $else_node = $regions_by_id{$else_region};
                if (defined($then_node) && ref($then_node) eq 'HASH' && (($then_node->{exit}{kind} // '') eq 'Goto')) {
                    $then_target = $then_node->{exit}{target_region} // $then_region;
                }
                if (defined($else_node) && ref($else_node) eq 'HASH' && (($else_node->{exit}{kind} // '') eq 'Goto')) {
                    $else_target = $else_node->{exit}{target_region} // $else_region;
                }
                my @trailing = @stmts[$if_idx + 1 .. $#stmts];
                my $if_stmt = $stmts[$if_idx];
                my $then_body = (defined($if_stmt) && ref($if_stmt) eq 'HASH') ? ($if_stmt->{then_body} // []) : [];
                my $else_body = (defined($if_stmt) && ref($if_stmt) eq 'HASH') ? ($if_stmt->{else_body} // []) : [];
                my %then_seen_decl = %seen_decl;
                my %else_seen_decl = %seen_decl;

                push @out, "  if ($cond) {";
                my $saved_kind = $ctx->{current_region_exit_kind};
                my $saved_target = $ctx->{current_region_exit_target};
                $ctx->{current_region_exit_kind} = 'Goto';
                $ctx->{current_region_exit_target} = $then_target;
                for my $stmt (@$then_body) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%then_seen_decl, 0, $ctx);
                }
                if (defined($then_target) && defined($else_target) && $then_target eq $else_target) {
                    for my $stmt (@trailing) {
                        if (!defined $stmt) {
                            push @out, '    /* Backend/F054 missing payload decode for step */';
                            next;
                        }
                        _emit_stmt($stmt, \@out, 4, \%then_seen_decl, 0, $ctx);
                    }
                }
                push @out, "    goto region_$then_target;";
                push @out, "  } else {";
                $ctx->{current_region_exit_kind} = 'Goto';
                $ctx->{current_region_exit_target} = $else_target;
                for my $stmt (@$else_body) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%else_seen_decl, 0, $ctx);
                }
                for my $stmt (@trailing) {
                    if (!defined $stmt) {
                        push @out, '    /* Backend/F054 missing payload decode for step */';
                        next;
                    }
                    _emit_stmt($stmt, \@out, 4, \%else_seen_decl, 0, $ctx);
                }
                push @out, "    goto region_$else_target;";
                push @out, "  }";
                $ctx->{current_region_exit_kind} = $saved_kind;
                $ctx->{current_region_exit_target} = $saved_target;
                next;
            }
        }
        for my $stmt (@stmts) {
            if (!defined $stmt) {
                push @out, '  /* Backend/F054 missing payload decode for step */';
                next;
            }
            _emit_stmt($stmt, \@out, 2, \%seen_decl, ($exit_kind eq 'Return' ? 1 : 0), $ctx);
        }
        _emit_exit($region->{exit} // {}, \@out, 2, $default_return, $ctx, $name);
    }

    push @out, "  return $default_return;";
    push @out, '}';
    return (join("\n", @out), $ctx->{helpers});
}

sub _emit_used_helpers {
    my ($out, $helpers) = @_;
    my %h = %{ $helpers // {} };

    push @$out, 'static int64_t metac_last_member_index = 0;' if $h{member_index};
    push @$out, 'static int metac_last_error = 0;' if $h{error_flag};
    push @$out, 'static const char *metac_last_error_message = "";'
      if $h{error_flag} || $h{error_message};
    if ($h{stdin_read}) {
        push @$out, 'static const char *metac_stdin_read_all(void) {';
        push @$out, '  static char buf[65536];';
        push @$out, '  static int loaded = 0;';
        push @$out, '  if (!loaded) {';
        push @$out, '    size_t n = fread(buf, 1, sizeof(buf) - 1, stdin);';
        push @$out, '    buf[n] = 0;';
        push @$out, '    loaded = 1;';
        push @$out, '  }';
        push @$out, '  return buf;';
        push @$out, '}';
    }

    if ($h{parse_number}) {
        push @$out, 'static int64_t metac_builtin_parse_number(const char *s) {';
        push @$out, '  if (!s) return 0;';
        push @$out, '  char *end = NULL;';
        push @$out, '  long long v = strtoll(s, &end, 10);';
        push @$out, '  if (end == s) { metac_last_error = 1; metac_last_error_message = "parse number failed"; return 0; }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  metac_last_error_message = "";';
        push @$out, '  return (int64_t)v;';
        push @$out, '}';
    }
    if ($h{builtin_error}) {
        push @$out, 'static int64_t metac_builtin_error(const char *msg) {';
        push @$out, '  static char buf[1024];';
        push @$out, '  const char *m = msg ? msg : "";';
        push @$out, '  snprintf(buf, sizeof(buf), "%s (line 0: )", m);';
        push @$out, '  metac_last_error = 1;';
        push @$out, '  metac_last_error_message = buf;';
        push @$out, '  return 0;';
        push @$out, '}';
    }
    push @$out, 'static int64_t metac_builtin_log_i64(int64_t v) { printf("%lld\\n", (long long)v); return v; }'
      if $h{log_i64};
    push @$out, 'static double metac_builtin_log_f64(double v) { printf("%.15g\\n", v); return v; }'
      if $h{log_f64};
    push @$out, 'static int metac_builtin_log_bool(int v) { int b = v ? 1 : 0; printf("%d\\n", b); return b; }'
      if $h{log_bool};
    push @$out, 'static const char *metac_builtin_log_str(const char *v) { const char *s = v ? v : ""; printf("%s\\n", s); return s; }'
      if $h{log_str};

    if ($h{fmt}) {
        push @$out, 'static const char *metac_format(const char *fmt, ...) {';
        push @$out, '  static char buf[4096];';
        push @$out, '  va_list ap;';
        push @$out, '  va_start(ap, fmt);';
        push @$out, '  vsnprintf(buf, sizeof(buf), fmt, ap);';
        push @$out, '  va_end(ap);';
        push @$out, '  return buf;';
        push @$out, '}';
    }

    if ($h{method_size}) {
        push @$out, 'static int64_t metac_method_size(const char *s) {';
        push @$out, '  if (!s) return 0;';
        push @$out, '  int64_t n = 0;';
        push @$out, '  for (size_t i = 0; s[i]; ) {';
        push @$out, '    unsigned char b = (unsigned char)s[i];';
        push @$out, '    size_t w = 1;';
        push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
        push @$out, '    else if ((b & 0xE0) == 0xC0 && s[i + 1]) w = 2;';
        push @$out, '    else if ((b & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) w = 3;';
        push @$out, '    else if ((b & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) w = 4;';
        push @$out, '    i += w;';
        push @$out, '    ++n;';
        push @$out, '  }';
        push @$out, '  return n;';
        push @$out, '}';
    }
    if ($h{constrained_string_assign}) {
        push @$out, 'static const char *metac_constrained_string_assign(const char *v, int64_t need) {';
        push @$out, '  const char *s = v ? v : "";';
        push @$out, '  if (need >= 0 && (int64_t)strlen(s) != need) {';
        push @$out, '    metac_last_error = 1;';
        push @$out, '    metac_last_error_message = "size constraint failed";';
        push @$out, '    exit(2);';
        push @$out, '  }';
        push @$out, '  return s;';
        push @$out, '}';
    }
    push @$out, 'static int64_t metac_method_push(int64_t recv, int64_t value) { (void)value; return recv; }'
      if $h{method_push};

    if ($h{method_isblank}) {
        push @$out, 'static int metac_method_isblank(const char *s) {';
        push @$out, '  if (!s) return 1;';
        push @$out, '  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {';
        push @$out, '    if (!isspace(*p)) return 0;';
        push @$out, '  }';
        push @$out, '  return 1;';
        push @$out, '}';
    }

    if ($h{list_i64}) {
        push @$out, 'struct metac_list_i64 { int64_t len; int64_t cap; int64_t data[1024]; };';
        push @$out, 'static struct metac_list_i64 metac_list_i64_empty(void) {';
        push @$out, '  struct metac_list_i64 out; out.len = 0; out.cap = 1024; return out;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_list_i64_from_array(const int64_t *items, int64_t n) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > out.cap) n = out.cap;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];';
        push @$out, '  out.len = n;';
        push @$out, '  return out;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_i64_push(struct metac_list_i64 *l, int64_t v) {';
        push @$out, '  if (!l) return 0;';
        push @$out, '  if (l->len < l->cap) l->data[l->len++] = v;';
        push @$out, '  return l->len;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_i64_size(const struct metac_list_i64 *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
        if ($h{list_i64_size_value}) {
            push @$out, 'static int64_t metac_list_i64_size_value(struct metac_list_i64 l) {';
            push @$out, '  return l.len;';
            push @$out, '}';
        }
        push @$out, 'static int64_t metac_list_i64_get(const struct metac_list_i64 *l, int64_t idx) {';
        push @$out, '  if (!l || idx < 0 || idx >= l->len) return 0;';
        push @$out, '  return l->data[idx];';
        push @$out, '}';
        if ($h{list_i64_render}) {
            push @$out, 'static const char *metac_list_i64_render(const struct metac_list_i64 *l) {';
            push @$out, '  static char buf[4096];';
            push @$out, '  int off = 0;';
            push @$out, '  off += snprintf(buf + off, sizeof(buf) - (size_t)off, "[");';
            push @$out, '  int64_t n = l ? l->len : 0;';
            push @$out, '  for (int64_t i = 0; i < n && off < (int)sizeof(buf); ++i) {';
            push @$out, '    off += snprintf(buf + off, sizeof(buf) - (size_t)off, "%s%lld", (i ? ", " : ""), (long long)l->data[i]);';
            push @$out, '  }';
            push @$out, '  snprintf(buf + off, sizeof(buf) - (size_t)off, "]");';
            push @$out, '  return buf;';
            push @$out, '}';
        }
        if ($h{seq_i64}) {
            push @$out, 'static struct metac_list_i64 metac_builtin_seq_i64(int64_t start, int64_t end) {';
            push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
            push @$out, '  if (end < start) return out;';
            push @$out, '  for (int64_t v = start; v <= end && out.len < out.cap; ++v) out.data[out.len++] = v;';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{last_index_i64}) {
            push @$out, 'static int64_t metac_builtin_last_index_i64(struct metac_list_i64 v) {';
            push @$out, '  if (v.len <= 0) return -1;';
            push @$out, '  return v.len - 1;';
            push @$out, '}';
        }
        if ($h{last_value_i64}) {
            push @$out, 'static int64_t metac_builtin_last_value_i64(struct metac_list_i64 v) {';
            push @$out, '  if (v.len <= 0) return 0;';
            push @$out, '  return v.data[v.len - 1];';
            push @$out, '}';
        }
        if ($h{sort_i64}) {
            push @$out, 'static struct metac_list_i64 metac_last_sort_indices = {0};';
            push @$out, 'static struct metac_list_i64 metac_sort_i64_with_index(struct metac_list_i64 recv) {';
            push @$out, '  struct metac_list_i64 out = recv;';
            push @$out, '  metac_last_sort_indices = metac_list_i64_empty();';
            push @$out, '  for (int64_t i = 0; i < out.len && i < metac_last_sort_indices.cap; ++i) {';
            push @$out, '    metac_last_sort_indices.data[i] = i;';
            push @$out, '  }';
            push @$out, '  metac_last_sort_indices.len = out.len;';
            push @$out, '  for (int64_t i = 0; i < out.len; ++i) {';
            push @$out, '    for (int64_t j = i + 1; j < out.len; ++j) {';
            push @$out, '      if (out.data[j] > out.data[i]) {';
            push @$out, '        int64_t tv = out.data[i]; out.data[i] = out.data[j]; out.data[j] = tv;';
            push @$out, '        int64_t ti = metac_last_sort_indices.data[i];';
            push @$out, '        metac_last_sort_indices.data[i] = metac_last_sort_indices.data[j];';
            push @$out, '        metac_last_sort_indices.data[j] = ti;';
            push @$out, '      }';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
            push @$out, 'static int64_t metac_sort_index_at(int64_t sorted_pos) {';
            push @$out, '  if (sorted_pos < 0 || sorted_pos >= metac_last_sort_indices.len) return sorted_pos;';
            push @$out, '  return metac_last_sort_indices.data[sorted_pos];';
            push @$out, '}';
        }
    }

    if ($h{matrix_meta}) {
        push @$out, 'struct metac_matrix_meta {';
        push @$out, '  int64_t dim;';
        push @$out, '  int constrained;';
        push @$out, '  int64_t fixed[16];';
        push @$out, '  int64_t extent[16];';
        push @$out, '};';
        push @$out, 'static struct metac_matrix_meta metac_matrix_meta_init(int64_t dim, const int64_t *sizes, int constrained) {';
        push @$out, '  struct metac_matrix_meta out;';
        push @$out, '  out.dim = dim;';
        push @$out, '  out.constrained = constrained ? 1 : 0;';
        push @$out, '  for (int i = 0; i < 16; ++i) { out.fixed[i] = -1; out.extent[i] = 0; }';
        push @$out, '  int64_t n = dim;';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > 16) n = 16;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) {';
        push @$out, '    int64_t s = sizes ? sizes[i] : -1;';
        push @$out, '    out.fixed[i] = s;';
        push @$out, '    out.extent[i] = s >= 0 ? s : 0;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
        push @$out, 'static int64_t metac_matrix_axis_size(const struct metac_matrix_meta *meta, int64_t axis) {';
        push @$out, '  if (!meta || axis < 0 || axis >= meta->dim || axis >= 16) return 0;';
        push @$out, '  int64_t fixed = meta->fixed[axis];';
        push @$out, '  return fixed >= 0 ? fixed : meta->extent[axis];';
        push @$out, '}';
        push @$out, 'static int metac_matrix_apply_index(struct metac_matrix_meta *meta, struct metac_list_i64 idx) {';
        push @$out, '  if (!meta) return 1;';
        push @$out, '  int64_t dim = meta->dim;';
        push @$out, '  if (dim < 0) dim = 0;';
        push @$out, '  if (dim > 16) dim = 16;';
        push @$out, '  if (idx.len != dim) {';
        push @$out, '    if (meta->constrained) exit(1);';
        push @$out, '    return 0;';
        push @$out, '  }';
        push @$out, '  for (int64_t i = 0; i < dim; ++i) {';
        push @$out, '    int64_t iv = idx.data[i];';
        push @$out, '    if (iv < 0) {';
        push @$out, '      if (meta->constrained) exit(1);';
        push @$out, '      return 0;';
        push @$out, '    }';
        push @$out, '    int64_t fixed = meta->fixed[i];';
        push @$out, '    if (fixed >= 0) {';
        push @$out, '      if (iv >= fixed) exit(1);';
        push @$out, '      continue;';
        push @$out, '    }';
        push @$out, '    int64_t need = iv + 1;';
        push @$out, '    if (need > meta->extent[i]) meta->extent[i] = need;';
        push @$out, '  }';
        push @$out, '  return 1;';
        push @$out, '}';
    }

    if ($h{list_str}) {
        push @$out, 'struct metac_list_str { int64_t len; int64_t cap; const char *data[1024]; };';
        push @$out, 'static struct metac_list_str metac_list_str_empty(void) {';
        push @$out, '  struct metac_list_str out; out.len = 0; out.cap = 1024; return out;';
        push @$out, '}';
        push @$out, 'static struct metac_list_str metac_list_str_from_array(const char *const *items, int64_t n) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > out.cap) n = out.cap;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];';
        push @$out, '  out.len = n;';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{list_str_push}) {
            push @$out, 'static int64_t metac_list_str_push(struct metac_list_str *l, const char *v) {';
            push @$out, '  if (!l) return 0;';
            push @$out, '  if (l->len < l->cap) l->data[l->len++] = v ? v : "";';
            push @$out, '  return l->len;';
            push @$out, '}';
        }
        push @$out, 'static int64_t metac_list_str_size(const struct metac_list_str *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
        if ($h{list_str_get}) {
            push @$out, 'static const char *metac_list_str_get(const struct metac_list_str *l, int64_t idx) {';
            push @$out, '  if (!l || idx < 0 || idx >= l->len) return "";';
            push @$out, '  return l->data[idx] ? l->data[idx] : "";';
            push @$out, '}';
        }
        if ($h{list_str_size_value}) {
            push @$out, 'static int64_t metac_list_str_size_value(struct metac_list_str l) {';
            push @$out, '  return l.len;';
            push @$out, '}';
        }
        if ($h{list_str_render}) {
            push @$out, 'static const char *metac_list_str_render(const struct metac_list_str *l) {';
            push @$out, '  static char buf[4096];';
            push @$out, '  int off = 0;';
            push @$out, '  off += snprintf(buf + off, sizeof(buf) - (size_t)off, "[");';
            push @$out, '  int64_t n = l ? l->len : 0;';
            push @$out, '  for (int64_t i = 0; i < n && off < (int)sizeof(buf); ++i) {';
            push @$out, '    const char *s = l->data[i] ? l->data[i] : "";';
            push @$out, '    off += snprintf(buf + off, sizeof(buf) - (size_t)off, "%s%s", (i ? ", " : ""), s);';
            push @$out, '  }';
            push @$out, '  snprintf(buf + off, sizeof(buf) - (size_t)off, "]");';
            push @$out, '  return buf;';
            push @$out, '}';
        }
        if ($h{builtin_split}) {
            push @$out, 'static struct metac_list_str metac_builtin_split(const char *s, const char *delim) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s || !delim || !*delim) { metac_last_error = 1; metac_last_error_message = "split failed"; return out; }';
            push @$out, '  const char d = delim[0];';
            push @$out, '  static char buf[4096];';
            push @$out, '  size_t n = strlen(s);';
            push @$out, '  if (n >= sizeof(buf)) n = sizeof(buf) - 1;';
            push @$out, '  memcpy(buf, s, n); buf[n] = 0;';
            push @$out, '  char *start = buf;';
            push @$out, '  for (size_t i = 0; i <= n; ++i) {';
            push @$out, '    if (buf[i] == d || buf[i] == 0) {';
            push @$out, '      buf[i] = 0;';
            push @$out, '      if (out.len < out.cap) out.data[out.len++] = start;';
            push @$out, '      start = &buf[i + 1];';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  metac_last_error = 0;';
            push @$out, '  metac_last_error_message = "";';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{builtin_lines}) {
            push @$out, 'static struct metac_list_str metac_builtin_lines(const char *s) {';
            push @$out, '  struct metac_list_str out = metac_builtin_split(s, "\\n");';
            push @$out, '  if (out.len > 0) {';
            push @$out, '    const char *last = out.data[out.len - 1] ? out.data[out.len - 1] : "";';
            push @$out, '    if (last[0] == 0) out.len--;';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{method_chars}) {
            push @$out, 'static struct metac_list_str metac_method_chars(const char *s) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s) return out;';
            push @$out, '  static char pool[8192];';
            push @$out, '  size_t used = 0;';
            push @$out, '  size_t n = strlen(s);';
            push @$out, '  for (size_t i = 0; i < n && out.len < out.cap; ) {';
            push @$out, '    unsigned char b = (unsigned char)s[i];';
            push @$out, '    size_t w = 1;';
            push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
            push @$out, '    else if ((b & 0xE0) == 0xC0) w = 2;';
            push @$out, '    else if ((b & 0xF0) == 0xE0) w = 3;';
            push @$out, '    else if ((b & 0xF8) == 0xF0) w = 4;';
            push @$out, '    if (i + w > n) w = 1;';
            push @$out, '    if (used + w + 1 >= sizeof(pool)) break;';
            push @$out, '    memcpy(&pool[used], &s[i], w);';
            push @$out, '    pool[used + w] = 0;';
            push @$out, '    out.data[out.len++] = &pool[used];';
            push @$out, '    used += w + 1;';
            push @$out, '    i += w;';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{method_chunk}) {
            push @$out, 'static struct metac_list_str metac_method_chunk(const char *s, int64_t width) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s || width <= 0) return out;';
            push @$out, '  static char pool[8192];';
            push @$out, '  size_t used = 0;';
            push @$out, '  size_t start = 0;';
            push @$out, '  size_t i = 0;';
            push @$out, '  int64_t count = 0;';
            push @$out, '  while (s[i] && out.len < out.cap) {';
            push @$out, '    unsigned char b = (unsigned char)s[i];';
            push @$out, '    size_t w = 1;';
            push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
            push @$out, '    else if ((b & 0xE0) == 0xC0 && s[i + 1]) w = 2;';
            push @$out, '    else if ((b & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) w = 3;';
            push @$out, '    else if ((b & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) w = 4;';
            push @$out, '    i += w;';
            push @$out, '    ++count;';
            push @$out, '    if (count >= width || !s[i]) {';
            push @$out, '      size_t take = i - start;';
            push @$out, '      if (used + take + 1 >= sizeof(pool)) break;';
            push @$out, '      memcpy(&pool[used], &s[start], take);';
            push @$out, '      pool[used + take] = 0;';
            push @$out, '      out.data[out.len++] = &pool[used];';
            push @$out, '      used += take + 1;';
            push @$out, '      start = i;';
            push @$out, '      count = 0;';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{last_value_str}) {
            push @$out, 'static const char *metac_builtin_last_value_str(struct metac_list_str v) {';
            push @$out, '  if (v.len <= 0) return "";';
            push @$out, '  return v.data[v.len - 1] ? v.data[v.len - 1] : "";';
            push @$out, '}';
        }
    }

    if ($h{map_parse_number}) {
        push @$out, 'static struct metac_list_i64 metac_map_parse_number(const struct metac_list_str *src) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src) { metac_last_error = 1; return out; }';
        push @$out, '  for (int64_t i = 0; i < src->len; ++i) {';
        push @$out, '    int64_t v = metac_builtin_parse_number(src->data[i]);';
        push @$out, '    if (metac_last_error) return out;';
        push @$out, '    if (out.len < out.cap) out.data[out.len++] = v;';
        push @$out, '  }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_parse_number_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_parse_number_value(struct metac_list_str src) {';
            push @$out, '  return metac_map_parse_number(&src);';
            push @$out, '}';
        }
    }
    if ($h{map_str_i64}) {
        push @$out, 'static struct metac_list_i64 metac_map_str_i64(const struct metac_list_str *src, int64_t (*fn)(const char *)) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src || !fn) return out;';
        push @$out, '  for (int64_t i = 0; i < src->len && out.len < out.cap; ++i) out.data[out.len++] = fn(src->data[i]);';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_str_i64_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_str_i64_value(struct metac_list_str src, int64_t (*fn)(const char *)) {';
            push @$out, '  return metac_map_str_i64(&src, fn);';
            push @$out, '}';
        }
    }
    if ($h{map_i64_i64}) {
        push @$out, 'static struct metac_list_i64 metac_map_i64_i64(const struct metac_list_i64 *src, int64_t (*fn)(int64_t)) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src || !fn) return out;';
        push @$out, '  for (int64_t i = 0; i < src->len && out.len < out.cap; ++i) out.data[out.len++] = fn(src->data[i]);';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_i64_i64_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_i64_i64_value(struct metac_list_i64 src, int64_t (*fn)(int64_t)) {';
            push @$out, '  return metac_map_i64_i64(&src, fn);';
            push @$out, '}';
        }
    }
    if ($h{reduce_i64_mul_add}) {
        push @$out, 'static int64_t metac_reduce_i64_mul_add(struct metac_list_i64 src, int64_t init, int64_t factor) {';
        push @$out, '  int64_t acc = init;';
        push @$out, '  for (int64_t i = 0; i < src.len; ++i) acc = (acc * factor) + src.data[i];';
        push @$out, '  return acc;';
        push @$out, '}';
    }
    if ($h{reduce_str_add_size}) {
        push @$out, 'static int64_t metac_reduce_str_add_size(struct metac_list_str src, int64_t init) {';
        push @$out, '  int64_t acc = init;';
        push @$out, '  for (int64_t i = 0; i < src.len; ++i) {';
        push @$out, '    const char *s = src.data[i] ? src.data[i] : "";';
        push @$out, '    acc += (int64_t)strlen(s);';
        push @$out, '  }';
        push @$out, '  return acc;';
        push @$out, '}';
    }
    if ($h{assert_size_i64}) {
        push @$out, 'static struct metac_list_i64 metac_assert_size_i64(const struct metac_list_i64 *src, int64_t need, const char *msg) {';
        push @$out, '  struct metac_list_i64 out = src ? *src : metac_list_i64_empty();';
        push @$out, '  (void)msg;';
        push @$out, '  if (!src || src->len != need) { metac_last_error = 1; return out; }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
    }

    if ($h{list_list_i64}) {
        push @$out, 'struct metac_list_list_i64 { int64_t len; int64_t cap; struct metac_list_i64 data[256]; };';
        push @$out, 'static struct metac_list_list_i64 metac_list_list_i64_empty(void) {';
        push @$out, '  struct metac_list_list_i64 out; out.len = 0; out.cap = 256; return out;';
        push @$out, '}';
        push @$out, 'static struct metac_list_list_i64 metac_list_list_i64_from_array(const struct metac_list_i64 *items, int64_t n) {';
        push @$out, '  struct metac_list_list_i64 out = metac_list_list_i64_empty();';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > out.cap) n = out.cap;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];';
        push @$out, '  out.len = n;';
        push @$out, '  return out;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_list_i64_push(struct metac_list_list_i64 *l, struct metac_list_i64 v) {';
        push @$out, '  if (!l) return 0;';
        push @$out, '  if (l->len < l->cap) l->data[l->len++] = v;';
        push @$out, '  return l->len;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_list_i64_size(const struct metac_list_list_i64 *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_list_list_i64_get(const struct metac_list_list_i64 *l, int64_t idx) {';
        push @$out, '  if (!l || idx < 0 || idx >= l->len) return metac_list_i64_empty();';
        push @$out, '  return l->data[idx];';
        push @$out, '}';
        if ($h{method_sortby_pair}) {
            push @$out, 'static struct metac_list_list_i64 metac_method_sortby_pair_lex(struct metac_list_list_i64 recv) {';
            push @$out, '  struct metac_list_list_i64 out = recv;';
            push @$out, '  for (int64_t i = 0; i < out.len; ++i) {';
            push @$out, '    for (int64_t j = i + 1; j < out.len; ++j) {';
            push @$out, '      struct metac_list_i64 a = out.data[i];';
            push @$out, '      struct metac_list_i64 b = out.data[j];';
            push @$out, '      int64_t a0 = a.len > 0 ? a.data[0] : 0;';
            push @$out, '      int64_t b0 = b.len > 0 ? b.data[0] : 0;';
            push @$out, '      int64_t a1 = a.len > 1 ? a.data[1] : 0;';
            push @$out, '      int64_t b1 = b.len > 1 ? b.data[1] : 0;';
            push @$out, '      if (a0 > b0 || (a0 == b0 && a1 > b1)) {';
            push @$out, '        struct metac_list_i64 t = out.data[i];';
            push @$out, '        out.data[i] = out.data[j];';
            push @$out, '        out.data[j] = t;';
            push @$out, '      }';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
    }

    if ($h{any_range_contains}) {
        push @$out, 'static int metac_any_range_contains(const struct metac_list_list_i64 *ranges, int64_t value) {';
        push @$out, '  if (!ranges) return 0;';
        push @$out, '  for (int64_t i = 0; i < ranges->len; ++i) {';
        push @$out, '    struct metac_list_i64 r = ranges->data[i];';
        push @$out, '    if (r.len >= 2 && r.data[0] <= value && value <= r.data[1]) return 1;';
        push @$out, '  }';
        push @$out, '  return 0;';
        push @$out, '}';
    }

    if ($h{method_match}) {
        push @$out, 'static struct metac_list_str metac_method_match(const char *text, const char *pattern) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (!text || !pattern) { metac_last_error = 1; return out; }';
        push @$out, '  regex_t re;';
        push @$out, '  int rc = regcomp(&re, pattern, REG_EXTENDED);';
        push @$out, '  if (rc != 0) { metac_last_error = 1; return out; }';
        push @$out, '  regmatch_t m[32];';
        push @$out, '  rc = regexec(&re, text, 32, m, 0);';
        push @$out, '  if (rc != 0) { regfree(&re); metac_last_error = 1; return out; }';
        push @$out, '  static char slots[64][256];';
        push @$out, '  static int slot_head = 0;';
        push @$out, '  for (int i = 1; i < 32 && out.len < out.cap; ++i) {';
        push @$out, '    if (m[i].rm_so < 0 || m[i].rm_eo < m[i].rm_so) break;';
        push @$out, '    int idx = slot_head++ % 64;';
        push @$out, '    int n = (int)(m[i].rm_eo - m[i].rm_so);';
        push @$out, '    if (n < 0) n = 0;';
        push @$out, '    if (n > 255) n = 255;';
        push @$out, '    memcpy(slots[idx], text + m[i].rm_so, (size_t)n);';
        push @$out, '    slots[idx][n] = 0;';
        push @$out, '    out.data[out.len++] = slots[idx];';
        push @$out, '  }';
        push @$out, '  if (out.len == 0 && m[0].rm_so >= 0 && m[0].rm_eo >= m[0].rm_so && out.len < out.cap) {';
        push @$out, '    int idx = slot_head++ % 64;';
        push @$out, '    int n = (int)(m[0].rm_eo - m[0].rm_so);';
        push @$out, '    if (n < 0) n = 0;';
        push @$out, '    if (n > 255) n = 255;';
        push @$out, '    memcpy(slots[idx], text + m[0].rm_so, (size_t)n);';
        push @$out, '    slots[idx][n] = 0;';
        push @$out, '    out.data[out.len++] = slots[idx];';
        push @$out, '  }';
        push @$out, '  regfree(&re);';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
    }

    if ($h{string_index}) {
        push @$out, 'static int64_t metac_string_code_at(const char *s, int64_t idx) {';
        push @$out, '  if (!s || idx < 0) return 0;';
        push @$out, '  int64_t pos = 0;';
        push @$out, '  for (size_t i = 0; s[i]; ) {';
        push @$out, '    unsigned char b0 = (unsigned char)s[i];';
        push @$out, '    int64_t cp = 0;';
        push @$out, '    size_t w = 1;';
        push @$out, '    if ((b0 & 0x80) == 0x00) {';
        push @$out, '      cp = b0;';
        push @$out, '      w = 1;';
        push @$out, '    } else if ((b0 & 0xE0) == 0xC0 && s[i + 1]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      cp = ((int64_t)(b0 & 0x1F) << 6) | (int64_t)(b1 & 0x3F);';
        push @$out, '      w = 2;';
        push @$out, '    } else if ((b0 & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      unsigned char b2 = (unsigned char)s[i + 2];';
        push @$out, '      cp = ((int64_t)(b0 & 0x0F) << 12) | ((int64_t)(b1 & 0x3F) << 6) | (int64_t)(b2 & 0x3F);';
        push @$out, '      w = 3;';
        push @$out, '    } else if ((b0 & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      unsigned char b2 = (unsigned char)s[i + 2];';
        push @$out, '      unsigned char b3 = (unsigned char)s[i + 3];';
        push @$out, '      cp = ((int64_t)(b0 & 0x07) << 18) | ((int64_t)(b1 & 0x3F) << 12) | ((int64_t)(b2 & 0x3F) << 6) | (int64_t)(b3 & 0x3F);';
        push @$out, '      w = 4;';
        push @$out, '    } else {';
        push @$out, '      cp = b0;';
        push @$out, '      w = 1;';
        push @$out, '    }';
        push @$out, '    if (pos == idx) return cp;';
        push @$out, '    i += w;';
        push @$out, '    ++pos;';
        push @$out, '  }';
        push @$out, '  return 0;';
        push @$out, '}';
    }

    if ($h{method_members}) {
        push @$out, 'static struct metac_list_i64 metac_method_members(struct metac_list_i64 matrix_like) {';
        push @$out, '  return matrix_like;';
        push @$out, '}';
        if ($h{list_str}) {
            push @$out, 'static struct metac_list_str metac_method_members_str(struct metac_list_str matrix_like) {';
            push @$out, '  return matrix_like;';
            push @$out, '}';
        }
    }
    if ($h{method_insert}) {
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64(struct metac_list_i64 *recv, int64_t value, int64_t idx) {';
        push @$out, '  if (!recv) return metac_list_i64_empty();';
        push @$out, '  if (idx >= 0 && idx < recv->len) recv->data[idx] = value;';
        push @$out, '  return *recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_value(struct metac_list_i64 recv, int64_t value, int64_t idx) {';
        push @$out, '  if (idx >= 0 && idx < recv.len) recv.data[idx] = value;';
        push @$out, '  return recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix(struct metac_list_i64 *recv, int64_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  if (!recv) return metac_list_i64_empty();';
        push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value;';
        push @$out, '  return *recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix_value(struct metac_list_i64 recv, int64_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  if (recv.len < recv.cap) recv.data[recv.len++] = value;';
        push @$out, '  return recv;';
        push @$out, '}';
        if ($h{matrix_meta}) {
            push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix_meta(struct metac_list_i64 *recv, int64_t value, struct metac_list_i64 idx, struct metac_matrix_meta *meta) {';
            push @$out, '  if (!recv) return metac_list_i64_empty();';
            push @$out, '  if (!metac_matrix_apply_index(meta, idx)) return *recv;';
            push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value;';
            push @$out, '  return *recv;';
            push @$out, '}';
        }
        if ($h{list_str}) {
            push @$out, 'static struct metac_list_str metac_method_insert_str(struct metac_list_str *recv, const char *value, int64_t idx) {';
            push @$out, '  if (!recv) return metac_list_str_empty();';
            push @$out, '  if (idx >= 0 && idx < recv->len) recv->data[idx] = value ? value : "";';
            push @$out, '  return *recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_value(struct metac_list_str recv, const char *value, int64_t idx) {';
            push @$out, '  if (idx >= 0 && idx < recv.len) recv.data[idx] = value ? value : "";';
            push @$out, '  return recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_matrix(struct metac_list_str *recv, const char *value, struct metac_list_i64 idx) {';
            push @$out, '  (void)idx;';
            push @$out, '  if (!recv) return metac_list_str_empty();';
            push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value ? value : "";';
            push @$out, '  return *recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_matrix_value(struct metac_list_str recv, const char *value, struct metac_list_i64 idx) {';
            push @$out, '  (void)idx;';
            push @$out, '  if (recv.len < recv.cap) recv.data[recv.len++] = value ? value : "";';
            push @$out, '  return recv;';
            push @$out, '}';
            if ($h{matrix_meta}) {
                push @$out, 'static struct metac_list_str metac_method_insert_str_matrix_meta(struct metac_list_str *recv, const char *value, struct metac_list_i64 idx, struct metac_matrix_meta *meta) {';
                push @$out, '  if (!recv) return metac_list_str_empty();';
                push @$out, '  if (!metac_matrix_apply_index(meta, idx)) return *recv;';
                push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value ? value : "";';
                push @$out, '  return *recv;';
                push @$out, '}';
            }
        }
    }
    if ($h{method_filter}) {
        push @$out, 'static struct metac_list_i64 metac_method_filter_identity(struct metac_list_i64 recv) {';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_filter_str}) {
        push @$out, 'static struct metac_list_str metac_method_filter_identity_str(struct metac_list_str recv) {';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{filter_str_eq}) {
        push @$out, 'static struct metac_list_str metac_filter_str_eq(struct metac_list_str recv, const char *needle) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  const char *target = needle ? needle : "";';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    const char *v = recv.data[i] ? recv.data[i] : "";';
        push @$out, '    if (strcmp(v, target) == 0) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_mod_ne}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_mod_ne(struct metac_list_i64 recv, int64_t mod, int64_t neq) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (mod == 0) return out;';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    if ((recv.data[i] % mod) != neq) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_eq2}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_eq2(struct metac_list_i64 recv, int64_t a, int64_t b) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    int64_t v = recv.data[i];';
        push @$out, '    if (v == a || v == b) out.data[out.len++] = v;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_mod_eq}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_mod_eq(struct metac_list_i64 recv, int64_t mod, int64_t eqv) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (mod == 0) return out;';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    if ((recv.data[i] % mod) == eqv) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_value_mod_eq}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_value_mod_eq(struct metac_list_i64 recv, int64_t value, int64_t eqv) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    int64_t d = recv.data[i];';
        push @$out, '    if (d != 0 && (value % d) == eqv) out.data[out.len++] = d;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_count}) {
        push @$out, 'static int64_t metac_method_count(struct metac_list_i64 recv) {';
        push @$out, '  return recv.len;';
        push @$out, '}';
    }
    if ($h{method_max_i64}) {
        push @$out, 'static int64_t metac_method_max_i64(const struct metac_list_i64 *recv) {';
        push @$out, '  if (!recv || recv->len <= 0) { metac_last_member_index = 0; return 0; }';
        push @$out, '  int64_t best = recv->data[0];';
        push @$out, '  int64_t best_i = 0;';
        push @$out, '  for (int64_t i = 1; i < recv->len; ++i) {';
        push @$out, '    if (recv->data[i] > best) { best = recv->data[i]; best_i = i; }';
        push @$out, '  }';
        push @$out, '  metac_last_member_index = best_i;';
        push @$out, '  return best;';
        push @$out, '}';
    }
    if ($h{method_max_i64_value}) {
        push @$out, 'static int64_t metac_method_max_i64_value(struct metac_list_i64 recv) {';
        push @$out, '  return metac_method_max_i64(&recv);';
        push @$out, '}';
    }
    if ($h{method_max_str}) {
        push @$out, 'static int64_t metac_method_max_str(const struct metac_list_str *recv) {';
        push @$out, '  if (!recv || recv->len <= 0) { metac_last_member_index = 0; return 0; }';
        push @$out, '  int64_t best = 0;';
        push @$out, '  int64_t best_i = 0;';
        push @$out, '  for (int64_t i = 0; i < recv->len; ++i) {';
        push @$out, '    const char *s = recv->data[i] ? recv->data[i] : "0";';
        push @$out, '    int64_t v = (int64_t)strtoll(s, NULL, 10);';
        push @$out, '    if (i == 0 || v > best) { best = v; best_i = i; }';
        push @$out, '  }';
        push @$out, '  metac_last_member_index = best_i;';
        push @$out, '  return best;';
        push @$out, '}';
    }
    if ($h{method_max_str_value}) {
        push @$out, 'static int64_t metac_method_max_str_value(struct metac_list_str recv) {';
        push @$out, '  return metac_method_max_str(&recv);';
        push @$out, '}';
    }
    if ($h{method_slice_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_slice_i64(const struct metac_list_i64 *recv, int64_t start) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!recv) return out;';
        push @$out, '  if (start < 0) start = 0;';
        push @$out, '  if (start > recv->len) start = recv->len;';
        push @$out, '  for (int64_t i = start; i < recv->len && out.len < out.cap; ++i) out.data[out.len++] = recv->data[i];';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_slice_i64_value}) {
        push @$out, 'static struct metac_list_i64 metac_method_slice_i64_value(struct metac_list_i64 recv, int64_t start) {';
        push @$out, '  return metac_method_slice_i64(&recv, start);';
        push @$out, '}';
    }
    if ($h{method_slice_str}) {
        push @$out, 'static struct metac_list_str metac_method_slice_str(const struct metac_list_str *recv, int64_t start) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (!recv) return out;';
        push @$out, '  if (start < 0) start = 0;';
        push @$out, '  if (start > recv->len) start = recv->len;';
        push @$out, '  for (int64_t i = start; i < recv->len && out.len < out.cap; ++i) out.data[out.len++] = recv->data[i];';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_slice_str_value}) {
        push @$out, 'static struct metac_list_str metac_method_slice_str_value(struct metac_list_str recv, int64_t start) {';
        push @$out, '  return metac_method_slice_str(&recv, start);';
        push @$out, '}';
    }
    if ($h{method_log_list_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_log_list_i64(struct metac_list_i64 recv) {';
        push @$out, '  metac_builtin_log_str(metac_list_i64_render(&recv));';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_log_list_str}) {
        push @$out, 'static struct metac_list_str metac_method_log_list_str(struct metac_list_str recv) {';
        push @$out, '  metac_builtin_log_str(metac_list_str_render(&recv));';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_count_str}) {
        push @$out, 'static int64_t metac_method_count_str(struct metac_list_str recv) {';
        push @$out, '  return recv.len;';
        push @$out, '}';
    }
    if ($h{method_neighbours_str}) {
        push @$out, 'static struct metac_list_str metac_method_neighbours_str(const char *value) {';
        push @$out, '  (void)value;';
        push @$out, '  return metac_list_str_from_array((const char *[]){"@"}, 1);';
        push @$out, '}';
    }
    if ($h{method_neighbours_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_neighbours_i64(struct metac_list_i64 matrix_like, struct metac_list_i64 idx) {';
        push @$out, '  (void)matrix_like;';
        push @$out, '  (void)idx;';
        push @$out, '  return metac_list_i64_from_array((int64_t[]){0, 0}, 2);';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_neighbours_i64_value(int64_t member_value) {';
        push @$out, '  return metac_list_i64_from_array((int64_t[]){member_value}, 1);';
        push @$out, '}';
    }

    push @$out, '' if %h;
}

sub _emit_function_prototypes {
    my ($hir) = @_;
    my @out;
    for my $fn (@{ $hir->{functions} // [] }) {
        my $name = $fn->{name} // '';
        next if $name eq '';
        my $ret_type = $name eq 'main' ? 'int' : _type_to_c($fn->{return_type}, 'int64_t');
        my @params;
        for my $p (@{ $fn->{params} // [] }) {
            my $pn = $p->{name} // 'p';
            my $pt = _type_to_c($p->{type}, 'int64_t');
            push @params, "$pt $pn";
        }
        my $param_sig = @params ? join(', ', @params) : 'void';
        push @out, "$ret_type $name($param_sig);";
    }
    push @out, '' if @out;
    return \@out;
}

sub codegen_from_vnf_hir {
    my ($hir) = @_;
    my @fn_blocks;
    my %helpers_used;

    for my $fn (@{ $hir->{functions} // [] }) {
        my ($code, $helpers) = _emit_function($fn // {});
        push @fn_blocks, $code;
        for my $k (keys %{ $helpers // {} }) {
            $helpers_used{$k} = 1;
        }
    }

    my @out;
    push @out, '#include <stdint.h>';
    push @out, '#include <stdio.h>';
    push @out, '#include <stdlib.h>';
    push @out, '#include <string.h>';
    push @out, '#include <ctype.h>';
    push @out, '#include <stdarg.h>';
    push @out, '#include <regex.h>';
    push @out, '';
    push @out, 'struct metac_error { const char *message; };';
    push @out, '';

    _emit_used_helpers(\@out, \%helpers_used);
    push @out, @{ _emit_function_prototypes($hir) };

    for my $fn_code (@fn_blocks) {
        push @out, $fn_code;
        push @out, '';
    }

    return join("\n", @out);
}

1;
