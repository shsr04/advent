package MetaC::HIR::BackendC;
use strict;
use warnings;

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
    return template_expr_to_c(
        raw => $raw,
        ctx => $ctx,
        expr_to_c => \&_expr_to_c,
        expr_c_type_hint => \&_expr_c_type_hint,
        helper_mark => \&_helper_mark,
        c_escape => \&_c_escape,
    );
}

sub _collect_lambda_idents {
    my ($expr, $out) = @_;
    return if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    if ($k eq 'ident') {
        my $n = $expr->{name} // '';
        $out->{$n} = 1 if $n ne '';
        return;
    }
    for my $v (values %$expr) {
        if (ref($v) eq 'HASH') {
            _collect_lambda_idents($v, $out);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $it (@$v) {
            _collect_lambda_idents($it, $out) if ref($it) eq 'HASH';
        }
    }
}

sub _root_ident_name {
    my ($expr) = @_;
    return '' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return $expr->{name} // '' if $k eq 'ident';
    return _root_ident_name($expr->{recv}) if $k eq 'method_call';
    return '';
}

sub _annotate_backend_call_contracts {
    my ($expr) = @_;
    return if !defined($expr) || ref($expr) ne 'HASH';
    my $kind = $expr->{kind} // '';

    for my $k (keys %$expr) {
        my $v = $expr->{$k};
        if (ref($v) eq 'HASH') {
            _annotate_backend_call_contracts($v);
            next;
        }
        next if ref($v) ne 'ARRAY';
        for my $it (@$v) {
            _annotate_backend_call_contracts($it) if ref($it) eq 'HASH';
        }
    }

    if ($kind eq 'call') {
        my $name = $expr->{name} // '';
        if (builtin_is_known($name)) {
            $expr->{resolved_call} //= {
                call_kind => 'builtin',
                op_id => builtin_op_id($name),
                target_name => $name,
                arity => scalar(@{ $expr->{args} // [] }),
            };
        }
        return;
    }
    if ($kind eq 'method_call') {
        my $method = $expr->{method} // '';
        if (method_is_known($method)) {
            $expr->{resolved_call} //= {
                call_kind => 'intrinsic_method',
                op_id => method_op_id($method),
                target_name => $method,
                method_name => $method,
                arity => scalar(@{ $expr->{args} // [] }),
            };
        }
        return;
    }
}

sub _lambda_callback_codegen {
    my (%args) = @_;
    my $ctx = $args{ctx};
    my $lambda = $args{lambda};
    my $param_names = $args{param_names} // [];
    my $param_types = $args{param_types} // [];
    my $ret_c = $args{return_c} // 'int64_t';
    return undef if !defined($ctx) || ref($ctx) ne 'HASH';
    return undef if !defined($lambda) || ref($lambda) ne 'HASH';

    my %params = map { $_ => 1 } grep { defined($_) && $_ ne '' } @$param_names;
    my %idents;
    _collect_lambda_idents($lambda->{body}, \%idents);
    my @captures = grep {
        !exists($params{$_}) && exists($ctx->{var_types}{$_})
    } sort keys %idents;

    my $cb_id = ++$ctx->{callback_counter};
    my $fn_safe = $ctx->{fn_name} // 'fn';
    $fn_safe =~ s/[^A-Za-z0-9_]/_/g;
    my $cb_name = "__metac_cb_${fn_safe}_$cb_id";

    my %alias = %{ $ctx->{ident_alias} // {} };
    my @setup;
    for my $cap (@captures) {
        my $cap_ty = $ctx->{var_types}{$cap} // 'int64_t';
        my $gname = "__metac_cbcap_${fn_safe}_${cb_id}_$cap";
        $gname =~ s/[^A-Za-z0-9_]/_/g;
        if (!exists $ctx->{generated_globals}{$gname}) {
            $ctx->{generated_globals}{$gname} = "static $cap_ty $gname;";
            push @{ $ctx->{generated_globals_order} }, $gname;
        }
        $alias{$cap} = $gname;
        push @setup, "$gname = " . _expr_to_c({ kind => 'ident', name => $cap }, $ctx);
    }

    my %cb_var_types = %{ $ctx->{var_types} // {} };
    for my $i (0 .. $#$param_names) {
        my $pn = $param_names->[$i];
        next if !defined($pn) || $pn eq '';
        $cb_var_types{$pn} = $param_types->[$i] // 'int64_t';
    }
    my %cb_ctx = %$ctx;
    $cb_ctx{ident_alias} = \%alias;
    $cb_ctx{var_types} = \%cb_var_types;
    _annotate_backend_call_contracts($lambda->{body});
    my $body_c = _expr_to_c($lambda->{body}, \%cb_ctx);

    my @cparams;
    for my $i (0 .. $#$param_names) {
        my $pn = $param_names->[$i] // '';
        my $pt = $param_types->[$i] // 'int64_t';
        next if $pn eq '';
        push @cparams, "$pt $pn";
    }
    my $sig = @cparams ? join(', ', @cparams) : 'void';
    my $fn_code = join("\n",
        "static $ret_c $cb_name($sig) {",
        "  return $body_c;",
        "}",
    );
    push @{ $ctx->{generated_callbacks} }, $fn_code;

    my $pre = @setup ? join(', ', @setup) : '';
    return { fn => $cb_name, pre => $pre };
}

sub _with_callback_setup {
    my ($pre, $call) = @_;
    return $call if !defined($pre) || $pre eq '';
    return '((' . $pre . '), (' . $call . '))';
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
        if (defined($ctx->{ident_alias}) && ref($ctx->{ident_alias}) eq 'HASH' && exists($ctx->{ident_alias}{$name})) {
            return $ctx->{ident_alias}{$name};
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
            my $cname = _expr_to_c($recv, $ctx);
            my $ty = $ctx->{var_types}{$name} // '';
            if ($ty eq 'struct metac_list_i64') {
                _helper_mark($ctx, 'list_i64');
                return "metac_list_i64_get(&$cname, $idx)";
            }
            if ($ty eq 'struct metac_list_str') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'list_str_get');
                return "metac_list_str_get(&$cname, $idx)";
            }
            if ($ty eq 'const char *') {
                _helper_mark($ctx, 'string_index');
                return "metac_string_code_at($cname, $idx)";
            }
        }
        return "/* Backend/F054 missing index emitter */ 0";
    }
    if ($k eq 'member_access') {
        my $member = $expr->{member} // '';
        return _expr_to_c($expr->{recv}, $ctx) if $member eq 'message';
        return "/* Backend/F054 missing member emitter */ 0";
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
            my $call = $target . '(' . join(', ', @args) . ')';
            my $setup = '';
            for my $arg_expr (@{ $expr->{args} // [] }) {
                next if !defined($arg_expr) || ref($arg_expr) ne 'HASH' || ($arg_expr->{kind} // '') ne 'ident';
                my $arg_name = $arg_expr->{name} // '';
                next if $arg_name eq '';
                my $mvar = $ctx->{matrix_meta_vars}{$arg_name} // '';
                next if $mvar eq '';
                _helper_mark($ctx, 'matrix_meta');
                $setup = "metac_set_last_matrix_meta($mvar)";
                last;
            }
            return $setup ne '' ? "(($setup), ($call))" : $call;
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
                if (scalar_is_string($hint)) {
                    _helper_mark($ctx, 'log_str');
                    return "metac_builtin_log_str($a0)";
                }
                if ($hint eq 'float') {
                    _helper_mark($ctx, 'log_f64');
                    return "metac_builtin_log_f64($a0)";
                }
                if (scalar_is_boolean($hint)) {
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
            my $call = $target . '(' . join(', ', ($recv, @args)) . ')';
            my $setup = '';
            if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                my $recv_name = $recv_expr->{name} // '';
                my $mvar = $ctx->{matrix_meta_vars}{$recv_name} // '';
                if ($mvar ne '') {
                    _helper_mark($ctx, 'matrix_meta');
                    $setup = "metac_set_last_matrix_meta($mvar)";
                }
            }
            if ($setup eq '') {
                for my $arg_expr (@{ $expr->{args} // [] }) {
                    next if !defined($arg_expr) || ref($arg_expr) ne 'HASH' || ($arg_expr->{kind} // '') ne 'ident';
                    my $arg_name = $arg_expr->{name} // '';
                    next if $arg_name eq '';
                    my $mvar = $ctx->{matrix_meta_vars}{$arg_name} // '';
                    next if $mvar eq '';
                    _helper_mark($ctx, 'matrix_meta');
                    $setup = "metac_set_last_matrix_meta($mvar)";
                    last;
                }
            }
            return $setup ne '' ? "(($setup), ($call))" : $call;
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
                my $arg0 = $expr->{args}[0];
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if (($rty eq 'struct metac_list_i64' || $rty eq 'struct metac_list_str' || $rty eq 'struct metac_list_list_i64')
                        && defined($arg0) && ref($arg0) eq 'HASH')
                    {
                        my ($param_ty, $helper, $list_helper);
                        if ($rty eq 'struct metac_list_i64') {
                            ($param_ty, $helper, $list_helper) = ('int64_t', 'any_i64', 'list_i64');
                        } elsif ($rty eq 'struct metac_list_str') {
                            ($param_ty, $helper, $list_helper) = ('const char *', 'any_str', 'list_str');
                        } else {
                            ($param_ty, $helper, $list_helper) = ('struct metac_list_i64', 'any_list_i64', 'list_list_i64');
                        }
                        my $cb;
                        if (($arg0->{kind} // '') eq 'lambda1') {
                            $cb = _lambda_callback_codegen(
                                ctx => $ctx,
                                lambda => $arg0,
                                param_names => [ $arg0->{param} // 'x' ],
                                param_types => [ $param_ty ],
                                return_c => 'int',
                            );
                        } elsif (($arg0->{kind} // '') eq 'ident') {
                            $cb = { fn => ($arg0->{name} // ''), pre => '' };
                        }
                        if (defined($cb) && ($cb->{fn} // '') ne '') {
                            _helper_mark($ctx, $list_helper);
                            _helper_mark($ctx, $helper);
                            my $call;
                            if ($rty eq 'struct metac_list_i64') {
                                $call = 'metac_any_i64(&' . $rname . ', ' . $cb->{fn} . ')';
                            } elsif ($rty eq 'struct metac_list_str') {
                                $call = 'metac_any_str(&' . $rname . ', ' . $cb->{fn} . ')';
                            } else {
                                $call = 'metac_any_list_i64(&' . $rname . ', ' . $cb->{fn} . ')';
                            }
                            return _with_callback_setup($cb->{pre}, $call);
                        }
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if ((defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str' || $recv_hint eq 'struct metac_list_list_i64'))
                    && defined($arg0) && ref($arg0) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper);
                    if ($recv_hint eq 'struct metac_list_i64') {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('int64_t', 'any_i64', 'any_i64_value', 'list_i64');
                    } elsif ($recv_hint eq 'struct metac_list_str') {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('const char *', 'any_str', 'any_str_value', 'list_str');
                    } else {
                        ($param_ty, $helper, $helper_value, $list_helper) = ('struct metac_list_i64', 'any_list_i64', 'any_list_i64_value', 'list_list_i64');
                    }
                    my $cb;
                    if (($arg0->{kind} // '') eq 'lambda1') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ $param_ty ],
                            return_c => 'int',
                        );
                    } elsif (($arg0->{kind} // '') eq 'ident') {
                        $cb = { fn => ($arg0->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        _helper_mark($ctx, $helper_value);
                        my $call;
                        if ($recv_hint eq 'struct metac_list_i64') {
                            $call = 'metac_any_i64_value(' . $recv . ', ' . $cb->{fn} . ')';
                        } elsif ($recv_hint eq 'struct metac_list_str') {
                            $call = 'metac_any_str_value(' . $recv . ', ' . $cb->{fn} . ')';
                        } else {
                            $call = 'metac_any_list_i64_value(' . $recv . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
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
                my $receiver_type_hint = $meta->{receiver_type_hint} // '';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $name = $recv_expr->{name} // '';
                    my $idx_expr = $ctx->{loop_item_index_expr}{$name};
                    return $idx_expr if defined $idx_expr && $idx_expr ne '';
                }
                if (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix_member</) {
                    _helper_mark($ctx, 'list_i64');
                    return 'metac_list_i64_empty()';
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
                my $is_matrix_recv = (defined($receiver_type_hint) && $receiver_type_hint =~ /^matrix</) ? 1 : 0;
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name};
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
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
                        my $src_ident = _root_ident_name($recv_expr);
                        my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                        if ($src_mvar ne '' && $is_matrix_recv) {
                            _helper_mark($ctx, 'matrix_meta');
                            return 'metac_method_insert_str_matrix_meta_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $src_mvar . ')';
                        }
                        return 'metac_method_insert_str_matrix_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                    }
                    return 'metac_method_insert_str_value(' . $recv . ', ' . ($args[0] // '""') . ', ' . ($args[1] // '0') . ')';
                }
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'method_insert');
                if ($is_matrix_idx) {
                    my $src_ident = _root_ident_name($recv_expr);
                    my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                    if ($src_mvar ne '' && $is_matrix_recv) {
                        _helper_mark($ctx, 'matrix_meta');
                        return 'metac_method_insert_i64_matrix_meta_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ', &' . $src_mvar . ')';
                    }
                    return 'metac_method_insert_i64_matrix_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // 'metac_list_i64_empty()') . ')';
                }
                return 'metac_method_insert_i64_value(' . $recv . ', ' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
            }
            if ($op_id eq 'method.at.v1') {
                my $idx = $args[0] // 'metac_list_i64_empty()';
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    my $mvar = $ctx->{matrix_meta_vars}{$rname} // '';
                    return ($rty eq 'struct metac_list_str') ? '""' : '0' if $mvar eq '';
                    _helper_mark($ctx, 'method_at');
                    _helper_mark($ctx, 'matrix_meta');
                    _helper_mark($ctx, 'list_i64');
                    if ($rty eq 'struct metac_list_str') {
                        _helper_mark($ctx, 'list_str');
                        return 'metac_method_at_str_matrix_meta(&' . $rname . ', ' . $idx . ', &' . $mvar . ')';
                    }
                    return 'metac_method_at_i64_matrix_meta(&' . $rname . ', ' . $idx . ', &' . $mvar . ')';
                }
                my $src_ident = _root_ident_name($recv_expr);
                my $src_mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                return (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') ? '""' : '0'
                  if $src_mvar eq '';
                _helper_mark($ctx, 'method_at');
                _helper_mark($ctx, 'matrix_meta');
                _helper_mark($ctx, 'list_i64');
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str') {
                    _helper_mark($ctx, 'list_str');
                    return 'metac_method_at_str_matrix_meta_value(' . $recv . ', ' . $idx . ', &' . $src_mvar . ')';
                }
                return 'metac_method_at_i64_matrix_meta_value(' . $recv . ', ' . $idx . ', &' . $src_mvar . ')';
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
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($pred) && ref($pred) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? ('int64_t', 'filter_i64_cb', 'filter_i64_cb_value', 'list_i64')
                      : ('const char *', 'filter_str_cb', 'filter_str_cb_value', 'list_str');
                    my $cb;
                    if (($pred->{kind} // '') eq 'lambda1') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $pred,
                            param_names => [ $pred->{param} // 'x' ],
                            param_types => [ $param_ty ],
                            return_c => 'int',
                        );
                    } elsif (($pred->{kind} // '') eq 'ident') {
                        $cb = { fn => ($pred->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_filter_i64_cb(&' . $rname . ', ' . $cb->{fn} . ')'
                              : 'metac_filter_str_cb(&' . $rname . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_filter_i64_cb_value(' . $recv . ', ' . $cb->{fn} . ')'
                              : 'metac_filter_str_cb_value(' . $recv . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
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
            if ($op_id eq 'method.all.v1') {
                my $arg0 = $expr->{args}[0];
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ 'const char *' ],
                            return_c => 'int',
                        );
                        if (defined($cb)) {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'all_str');
                            return _with_callback_setup($cb->{pre}, 'metac_all_str(&' . $rname . ', ' . $cb->{fn} . ')');
                        }
                    }
                    if ($rty eq 'struct metac_list_i64'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ 'int64_t' ],
                            return_c => 'int',
                        );
                        if (defined($cb)) {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'all_i64');
                            return _with_callback_setup($cb->{pre}, 'metac_all_i64(&' . $rname . ', ' . $cb->{fn} . ')');
                        }
                    }
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'ident')
                    {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'all_str');
                        return 'metac_all_str(&' . $rname . ', ' . ($args[0] // '0') . ')';
                    }
                    if ($rty eq 'struct metac_list_i64'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'ident')
                    {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'all_i64');
                        return 'metac_all_i64(&' . $rname . ', ' . ($args[0] // '0') . ')';
                    }
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $p = $arg0->{param} // '';
                        my $b = $arg0->{body};
                        if (defined($b) && ref($b) eq 'HASH'
                            && (($b->{kind} // '') eq 'method_call')
                            && (($b->{method} // '') eq 'isBlank')
                            && defined($b->{recv}) && ref($b->{recv}) eq 'HASH'
                            && (($b->{recv}{kind} // '') eq 'ident')
                            && (($b->{recv}{name} // '') eq $p))
                        {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'method_isblank');
                            _helper_mark($ctx, 'all_str');
                            _helper_mark($ctx, 'all_str_isblank');
                            return 'metac_all_str_isblank(&' . $rname . ')';
                        }
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'lambda1')
                {
                    my $cb = _lambda_callback_codegen(
                        ctx => $ctx,
                        lambda => $arg0,
                        param_names => [ $arg0->{param} // 'x' ],
                        param_types => [ 'const char *' ],
                        return_c => 'int',
                    );
                    if (defined($cb)) {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'all_str');
                        _helper_mark($ctx, 'all_str_value');
                        return _with_callback_setup($cb->{pre}, 'metac_all_str_value(' . $recv . ', ' . $cb->{fn} . ')');
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'lambda1')
                {
                    my $cb = _lambda_callback_codegen(
                        ctx => $ctx,
                        lambda => $arg0,
                        param_names => [ $arg0->{param} // 'x' ],
                        param_types => [ 'int64_t' ],
                        return_c => 'int',
                    );
                    if (defined($cb)) {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'all_i64');
                        _helper_mark($ctx, 'all_i64_value');
                        return _with_callback_setup($cb->{pre}, 'metac_all_i64_value(' . $recv . ', ' . $cb->{fn} . ')');
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'ident')
                {
                    _helper_mark($ctx, 'list_str');
                    _helper_mark($ctx, 'all_str');
                    _helper_mark($ctx, 'all_str_value');
                    return 'metac_all_str_value(' . $recv . ', ' . ($args[0] // '0') . ')';
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'ident')
                {
                    _helper_mark($ctx, 'list_i64');
                    _helper_mark($ctx, 'all_i64');
                    _helper_mark($ctx, 'all_i64_value');
                    return 'metac_all_i64_value(' . $recv . ', ' . ($args[0] // '0') . ')';
                }
            }
            if ($op_id eq 'method.map.v1') {
                my $arg0 = $expr->{args}[0];
                if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                    my $rname = $recv_expr->{name} // '';
                    my $rty = $ctx->{var_types}{$rname} // '';
                    if ($rty eq 'struct metac_list_str'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ 'const char *' ],
                            return_c => 'int64_t',
                        );
                        if (defined($cb)) {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'map_str_i64');
                            return _with_callback_setup($cb->{pre}, 'metac_map_str_i64(&' . $rname . ', ' . $cb->{fn} . ')');
                        }
                    }
                    if ($rty eq 'struct metac_list_i64'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $map_out_hint = _expr_c_type_hint($expr, $ctx) // 'struct metac_list_i64';
                        my $ret_c = $map_out_hint eq 'struct metac_list_str' ? 'const char *' : 'int64_t';
                        my $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $arg0,
                            param_names => [ $arg0->{param} // 'x' ],
                            param_types => [ 'int64_t' ],
                            return_c => $ret_c,
                        );
                        if (defined($cb)) {
                            _helper_mark($ctx, 'list_i64');
                            if ($map_out_hint eq 'struct metac_list_str') {
                                _helper_mark($ctx, 'list_str');
                                _helper_mark($ctx, 'map_i64_str');
                                return _with_callback_setup($cb->{pre}, 'metac_map_i64_str(&' . $rname . ', ' . $cb->{fn} . ')');
                            }
                            _helper_mark($ctx, 'map_i64_i64');
                            return _with_callback_setup($cb->{pre}, 'metac_map_i64_i64(&' . $rname . ', ' . $cb->{fn} . ')');
                        }
                    }
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
                    if ($rty eq 'struct metac_list_i64'
                        && defined($arg0) && ref($arg0) eq 'HASH'
                        && ($arg0->{kind} // '') eq 'lambda1')
                    {
                        my $b = $arg0->{body};
                        if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'num')) {
                            _helper_mark($ctx, 'list_i64');
                            _helper_mark($ctx, 'map_i64_const');
                            return 'metac_map_i64_const(&' . $rname . ', ' . _expr_to_c($b, $ctx) . ')';
                        }
                    }
                }
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_str'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'lambda1')
                {
                    my $cb = _lambda_callback_codegen(
                        ctx => $ctx,
                        lambda => $arg0,
                        param_names => [ $arg0->{param} // 'x' ],
                        param_types => [ 'const char *' ],
                        return_c => 'int64_t',
                    );
                    if (defined($cb)) {
                        _helper_mark($ctx, 'list_str');
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'map_str_i64');
                        _helper_mark($ctx, 'map_str_i64_value');
                        return _with_callback_setup($cb->{pre}, 'metac_map_str_i64_value(' . $recv . ', ' . $cb->{fn} . ')');
                    }
                }
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'lambda1')
                {
                    my $map_out_hint = _expr_c_type_hint($expr, $ctx) // 'struct metac_list_i64';
                    my $ret_c = $map_out_hint eq 'struct metac_list_str' ? 'const char *' : 'int64_t';
                    my $cb = _lambda_callback_codegen(
                        ctx => $ctx,
                        lambda => $arg0,
                        param_names => [ $arg0->{param} // 'x' ],
                        param_types => [ 'int64_t' ],
                        return_c => $ret_c,
                    );
                    if (defined($cb)) {
                        _helper_mark($ctx, 'list_i64');
                        if ($map_out_hint eq 'struct metac_list_str') {
                            _helper_mark($ctx, 'list_str');
                            _helper_mark($ctx, 'map_i64_str');
                            _helper_mark($ctx, 'map_i64_str_value');
                            return _with_callback_setup($cb->{pre}, 'metac_map_i64_str_value(' . $recv . ', ' . $cb->{fn} . ')');
                        }
                        _helper_mark($ctx, 'map_i64_i64');
                        _helper_mark($ctx, 'map_i64_i64_value');
                        return _with_callback_setup($cb->{pre}, 'metac_map_i64_i64_value(' . $recv . ', ' . $cb->{fn} . ')');
                    }
                }
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
                if (defined($recv_hint) && $recv_hint eq 'struct metac_list_i64'
                    && defined($arg0) && ref($arg0) eq 'HASH'
                    && ($arg0->{kind} // '') eq 'lambda1')
                {
                    my $b = $arg0->{body};
                    if (defined($b) && ref($b) eq 'HASH' && (($b->{kind} // '') eq 'num')) {
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, 'map_i64_const');
                        _helper_mark($ctx, 'map_i64_const_value');
                        return 'metac_map_i64_const_value(' . $recv . ', ' . _expr_to_c($b, $ctx) . ')';
                    }
                }
            }
            if ($op_id eq 'method.reduce.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $init = $args[0] // '0';
                my $lam = $expr->{args}[1];
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($lam) && ref($lam) eq 'HASH')
                {
                    my ($param_types, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? (['int64_t', 'int64_t'], 'reduce_i64_cb', 'reduce_i64_cb_value', 'list_i64')
                      : (['int64_t', 'const char *'], 'reduce_str_cb', 'reduce_str_cb_value', 'list_str');
                    my $cb;
                    if (($lam->{kind} // '') eq 'lambda2') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $lam,
                            param_names => [ $lam->{param1} // 'acc', $lam->{param2} // 'x' ],
                            param_types => $param_types,
                            return_c => 'int64_t',
                        );
                    } elsif (($lam->{kind} // '') eq 'ident') {
                        $cb = { fn => ($lam->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_reduce_i64_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_reduce_str_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_reduce_i64_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_reduce_str_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
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
                            && (($r->{kind} // '') eq 'method_call')
                            && method_has_length_semantics($r->{method} // '')
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
                my $pred = $expr->{args}[0];
                my $msg = $args[1] // '""';
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($pred) && ref($pred) eq 'HASH')
                {
                    my ($param_ty, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? ('struct metac_list_i64', 'assert_i64_cb', 'assert_i64_cb_value', 'list_i64')
                      : ('struct metac_list_str', 'assert_str_cb', 'assert_str_cb_value', 'list_str');
                    my $cb;
                    if (($pred->{kind} // '') eq 'lambda1') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $pred,
                            param_names => [ $pred->{param} // 'x' ],
                            param_types => [ $param_ty ],
                            return_c => 'int',
                        );
                    } elsif (($pred->{kind} // '') eq 'ident') {
                        $cb = { fn => ($pred->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, $helper);
                        _helper_mark($ctx, 'error_flag');
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_assert_i64_cb(&' . $rname . ', ' . $cb->{fn} . ', ' . $msg . ')'
                              : 'metac_assert_str_cb(&' . $rname . ', ' . $cb->{fn} . ', ' . $msg . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_assert_i64_cb_value(' . $recv . ', ' . $cb->{fn} . ', ' . $msg . ')'
                              : 'metac_assert_str_cb_value(' . $recv . ', ' . $cb->{fn} . ', ' . $msg . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
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
                                && method_has_length_semantics($lhs->{method} // '')
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
            if ($op_id eq 'method.scan.v1') {
                my $recv_hint = _expr_c_type_hint($recv_expr, $ctx);
                my $init = $args[0] // '0';
                my $lam = $expr->{args}[1];
                if (defined($recv_hint) && ($recv_hint eq 'struct metac_list_i64' || $recv_hint eq 'struct metac_list_str')
                    && defined($lam) && ref($lam) eq 'HASH')
                {
                    my ($param_types, $helper, $helper_value, $list_helper) = $recv_hint eq 'struct metac_list_i64'
                      ? (['int64_t', 'int64_t'], 'scan_i64_cb', 'scan_i64_cb_value', 'list_i64')
                      : (['int64_t', 'const char *'], 'scan_str_cb', 'scan_str_cb_value', 'list_str');
                    my $cb;
                    if (($lam->{kind} // '') eq 'lambda2') {
                        $cb = _lambda_callback_codegen(
                            ctx => $ctx,
                            lambda => $lam,
                            param_names => [ $lam->{param1} // 'acc', $lam->{param2} // 'x' ],
                            param_types => $param_types,
                            return_c => 'int64_t',
                        );
                    } elsif (($lam->{kind} // '') eq 'ident') {
                        $cb = { fn => ($lam->{name} // ''), pre => '' };
                    }
                    if (defined($cb) && ($cb->{fn} // '') ne '') {
                        _helper_mark($ctx, $list_helper);
                        _helper_mark($ctx, 'list_i64');
                        _helper_mark($ctx, $helper);
                        my $call;
                        if (defined($recv_expr) && ref($recv_expr) eq 'HASH' && ($recv_expr->{kind} // '') eq 'ident') {
                            my $rname = $recv_expr->{name} // '';
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_scan_i64_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_scan_str_cb(&' . $rname . ', ' . $init . ', ' . $cb->{fn} . ')';
                        } else {
                            _helper_mark($ctx, $helper_value);
                            $call = $recv_hint eq 'struct metac_list_i64'
                              ? 'metac_scan_i64_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')'
                              : 'metac_scan_str_cb_value(' . $recv . ', ' . $init . ', ' . $cb->{fn} . ')';
                        }
                        return _with_callback_setup($cb->{pre}, $call);
                    }
                }
            }
        }

        if ((method_traceability_hint($expr->{method} // '') // '') eq 'requires_source_index_metadata') {
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

1;
