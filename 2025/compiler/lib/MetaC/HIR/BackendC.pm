package MetaC::HIR::BackendC;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::TypedNodes qw(step_payload_to_stmt);

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
    return 1 if $t =~ /^array<e=737472696E67(?:;|>)/;
    return 1 if $t =~ /^array<e=string(?:;|>)/;
    return 0;
}

sub _is_matrix_type {
    my ($t) = @_;
    return defined($t) && $t =~ /^matrix</ ? 1 : 0;
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
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_i64' if $t =~ /array</;
    return 'struct metac_list_i64' if $t =~ /matrix</;
    return 'const char *' if $t =~ /\bstring\b/;
    return 'int' if $t =~ /\bbool(?:ean)?\b/;
    return 'double' if $t =~ /\bfloat\b/;
    return 'int64_t' if $t =~ /\b(?:number|int)\b/;
    return undef;
}

sub _type_to_c {
    my ($t, $fallback) = @_;
    return $fallback if !defined $t || $t eq '';
    $t = _strip_error_union($t);
    return 'int64_t' if $t eq 'number' || $t eq 'int';
    return 'double' if $t eq 'float';
    return 'int' if $t eq 'bool' || $t eq 'boolean';
    return 'const char *' if $t eq 'string';
    return 'int' if $t eq 'null';
    return 'struct metac_error' if $t eq 'error';
    return 'struct metac_list_list_i64' if _is_nested_array_type($t);
    return 'struct metac_list_str' if _is_string_array_type($t);
    return 'struct metac_list_i64' if _is_array_type($t);
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
    return 'struct metac_list_i64' if $k eq 'list_literal';
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
            return 'struct metac_list_i64' if $m eq 'members' || $m eq 'filter';
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
        return $expr->{name} // '/* missing-ident */ 0';
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
            if ($op_id eq 'method.isBlank.v1') {
                _helper_mark($ctx, 'method_isblank');
                return "metac_method_isblank($recv)";
            }
            if ($op_id eq 'method.size.v1') {
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
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_push(&' . $recv_expr->{name} . ', ' . ($args[0] // '0') . ')';
                }
                _helper_mark($ctx, 'method_push');
                return 'metac_method_push(' . $recv . ', ' . ($args[0] // '0') . ')';
            }
            if ($op_id eq 'method.last.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rty = $ctx->{var_types}{ $recv_expr->{name} // '' } // '';
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
            if ($op_id eq 'method.index.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $name = $recv_expr->{name} // '';
                    my $idx_expr = $ctx->{loop_item_index_expr}{$name};
                    return $idx_expr if defined $idx_expr && $idx_expr ne '';
                }
                return '0';
            }
            if ($op_id eq 'method.members.v1') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_members');
                return "metac_method_members($recv)";
            }
            if ($op_id eq 'method.insert.v1') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_insert');
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    return 'metac_method_insert(&' . $recv_expr->{name} . ', (uintptr_t)(' . ($args[0] // '0') . '), ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                }
                return 'metac_method_insert_value(' . $recv . ', (uintptr_t)(' . ($args[0] // '0') . '), ' . ($args[1] // 'metac_list_i64_empty()') . ')';
            }
            if ($op_id eq 'method.count.v1') {
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_size(&' . $recv_expr->{name} . ')';
                }
                _helper_mark($ctx, 'method_count');
                return "metac_method_count($recv)";
            }
            if ($op_id eq 'method.filter.v1') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_filter');
                return 'metac_method_filter_identity(' . $recv . ')';
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

    if ($k eq 'let' || $k eq 'const' || $k eq 'const_typed' || $k eq 'const_try_expr' || $k eq 'const_try_tail_expr') {
        my $name = $stmt->{name} // '__missing_name';
        my $decl = $seen_decl->{$name}++;

        my $inferred = _expr_c_type_hint($stmt->{expr}, $ctx);
        my $c_ty = _type_to_c($stmt->{type}, $inferred // 'int64_t');
        my $rhs = _expr_to_c($stmt->{expr}, $ctx);
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
        _helper_mark($ctx, 'list_str') if $c_ty eq 'struct metac_list_str';
        _helper_mark($ctx, 'list_i64') if $c_ty eq 'struct metac_list_i64';
        _helper_mark($ctx, 'list_list_i64') if $c_ty eq 'struct metac_list_list_i64';
        push @$out, $decl ? "${sp}$name = $rhs;" : "${sp}$c_ty $name = $rhs;";
        $ctx->{var_types}{$name} = $c_ty;
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
        push @$out, "${sp}  metac_last_error = 0;";
        for my $h (@{ $stmt->{handler} // [] }) {
            _emit_stmt($h, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        push @$out, "${sp}}";
        _helper_mark($ctx, 'error_flag');
        return;
    }
    if ($k eq 'destructure_list') {
        my $src = $stmt->{expr};
        if (defined($src) && ref($src) eq 'HASH' && ($src->{kind} // '') eq 'ident') {
            my $src_name = $src->{name};
            for my $i (0 .. $#{ $stmt->{vars} // [] }) {
                my $v = $stmt->{vars}[$i];
                my $decl = $seen_decl->{$v}++;
                _helper_mark($ctx, 'list_i64');
                my $rhs = "metac_list_i64_get(&$src_name, $i)";
                push @$out, $decl ? "${sp}$v = $rhs;" : "${sp}int64_t $v = $rhs;";
                $ctx->{var_types}{$v} = 'int64_t';
            }
            return;
        }
        push @$out, qq{$sp/* Backend/F054 missing destructure_list source support */};
        return;
    }
    if ($k eq 'assign' || $k eq 'typed_assign') {
        my $name = $stmt->{name} // '__missing_name';
        push @$out, "${sp}$name = " . _expr_to_c($stmt->{expr}, $ctx) . ';';
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
        push @$out, defined($rv) ? ($sp . 'return ' . _expr_to_c($rv, $ctx) . ';') : ($sp . 'return 0;');
        return;
    }

    if ($k eq 'if') {
        return if ($ctx->{current_region_exit_kind} // '') eq 'IfExit';
        my $cond = _expr_to_c($stmt->{cond}, $ctx);
        push @$out, "${sp}if ($cond) {";
        for my $s (@{ $stmt->{then_body} // [] }) {
            _emit_stmt($s, $out, $indent + 2, $seen_decl, 0, $ctx);
        }
        if (defined($stmt->{else_body}) && ref($stmt->{else_body}) eq 'ARRAY' && @{ $stmt->{else_body} }) {
            push @$out, "${sp}} else {";
            for my $s (@{ $stmt->{else_body} }) {
                _emit_stmt($s, $out, $indent + 2, $seen_decl, 0, $ctx);
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
    return if $k eq 'while' || $k eq 'for_each' || $k eq 'for_each_try' || $k eq 'for_lines';
    if ($k eq 'break' || $k eq 'continue') {
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
        _helper_mark($ctx, 'list_i64');
        my $iter_c = _expr_to_c($iter, $ctx);
        push @$out, "${sp}if (!__loop_init_$loop) {";
        push @$out, "${sp}  __loop_init_$loop = 1;";
        push @$out, "${sp}  __loop_idx_$loop = 0;";
        push @$out, "${sp}  __loop_iter_$loop = $iter_c;";
        push @$out, "${sp}  __loop_len_$loop = metac_list_i64_size(&__loop_iter_$loop);";
        push @$out, "${sp}}";
        push @$out, "${sp}if (__loop_idx_$loop < __loop_len_$loop) {";
        push @$out, "${sp}  $item = metac_list_i64_get(&__loop_iter_$loop, __loop_idx_$loop);";
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
    my ($regions) = @_;
    my %seen;
    my @loops;
    for my $region (@{ $regions // [] }) {
        my $exit = $region->{exit} // {};
        next if ($exit->{kind} // '') ne 'ForInExit';
        my $id = $exit->{loop_id} // '';
        next if $id eq '' || $seen{$id}++;
        push @loops, {
            loop_id => $id,
            item_name => ($exit->{item_name} // '__item'),
        };
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

    my $ctx = { helpers => {}, var_types => {} };
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
        _helper_mark($ctx, 'list_i64') if $pt eq 'struct metac_list_i64';
        _helper_mark($ctx, 'list_str') if $pt eq 'struct metac_list_str';
        if ($pt eq 'struct metac_list_list_i64') {
            _helper_mark($ctx, 'list_i64');
            _helper_mark($ctx, 'list_list_i64');
        }
    }

    my $regions = $fn->{regions} // [];
    my $loops = _collect_forin_loops($regions);
    for my $loop (@$loops) {
        my $lid = $loop->{loop_id};
        my $item = $loop->{item_name};
        _helper_mark($ctx, 'list_i64');
        push @out, "  int __loop_init_$lid = 0;";
        push @out, "  int64_t __loop_idx_$lid = 0;";
        push @out, "  int64_t __loop_len_$lid = 0;";
        push @out, "  struct metac_list_i64 __loop_iter_$lid = metac_list_i64_empty();";
        push @out, "  int64_t $item = 0;";
        $ctx->{var_types}{$item} = 'int64_t';
        $ctx->{loop_item_index_expr}{$item} = "(__loop_idx_$lid - 1)";
    }
    $ctx->{loop_ids} = [ map { $_->{loop_id} } @$loops ];

    my %seen_decl;
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

    for my $region (@ordered_regions) {
        my $rid = $region->{id} // '__missing_region';
        my $exit_kind = $region->{exit}{kind} // '';
        $ctx->{current_region_exit_kind} = $exit_kind;
        $ctx->{current_region_exit_target} = ($exit_kind eq 'Goto') ? ($region->{exit}{target_region}) : undef;
        push @out, "region_$rid: ;";
        for my $step (@{ $region->{steps} // [] }) {
            my $stmt = step_payload_to_stmt($step->{payload});
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

    push @$out, 'static int metac_last_error = 0;' if $h{error_flag};

    if ($h{parse_number}) {
        push @$out, 'static int64_t metac_builtin_parse_number(const char *s) {';
        push @$out, '  if (!s) return 0;';
        push @$out, '  char *end = NULL;';
        push @$out, '  long long v = strtoll(s, &end, 10);';
        push @$out, '  if (end == s) { metac_last_error = 1; return 0; }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return (int64_t)v;';
        push @$out, '}';
    }
    if ($h{builtin_error}) {
        push @$out, 'static int64_t metac_builtin_error(const char *msg) {';
        push @$out, '  (void)msg;';
        push @$out, '  metac_last_error = 1;';
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

    push @$out, 'static int64_t metac_method_size(const char *s) { return s ? (int64_t)strlen(s) : 0; }'
      if $h{method_size};
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
        push @$out, 'static int64_t metac_list_str_size(const struct metac_list_str *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
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
            push @$out, '  if (!s || !delim || !*delim) { metac_last_error = 1; return out; }';
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
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{builtin_lines}) {
            push @$out, 'static struct metac_list_str metac_builtin_lines(const char *s) {';
            push @$out, '  return metac_builtin_split(s, "\\n");';
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
        push @$out, '  rc = regexec(&re, text, 0, NULL, 0);';
        push @$out, '  if (rc != 0) { regfree(&re); metac_last_error = 0; return out; }';
        push @$out, '  out.data[0] = text;';
        push @$out, '  out.len = 1;';
        push @$out, '  regfree(&re);';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
    }

    if ($h{string_index}) {
        push @$out, 'static int64_t metac_string_code_at(const char *s, int64_t idx) {';
        push @$out, '  if (!s || idx < 0) return 0;';
        push @$out, '  return (unsigned char)s[idx];';
        push @$out, '}';
    }

    if ($h{method_members}) {
        push @$out, 'static struct metac_list_i64 metac_method_members(struct metac_list_i64 matrix_like) {';
        push @$out, '  return matrix_like;';
        push @$out, '}';
    }
    if ($h{method_insert}) {
        push @$out, 'static int64_t metac_method_insert(struct metac_list_i64 *recv, uintptr_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  (void)value;';
        push @$out, '  if (!recv) return 0;';
        push @$out, '  return 0;';
        push @$out, '}';
        push @$out, 'static int64_t metac_method_insert_value(struct metac_list_i64 recv, uintptr_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  (void)recv;';
        push @$out, '  (void)value;';
        push @$out, '  return 0;';
        push @$out, '}';
    }
    if ($h{method_filter}) {
        push @$out, 'static struct metac_list_i64 metac_method_filter_identity(struct metac_list_i64 recv) {';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_count}) {
        push @$out, 'static int64_t metac_method_count(struct metac_list_i64 recv) {';
        push @$out, '  return recv.len;';
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
