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

sub _mark_helpers {
    my ($ctx, $helpers) = @_;
    return if !defined($ctx) || ref($ctx) ne 'HASH';
    return if !defined($helpers) || ref($helpers) ne 'ARRAY';
    for my $h (@$helpers) {
        _helper_mark($ctx, $h);
    }
}

sub _emit_log_call_for_c_type {
    my ($value_c, $c_type, $ctx) = @_;
    my $spec = c_log_strategy_for_c_type($c_type);
    return undef if !defined($spec) || ref($spec) ne 'HASH';
    my $call = $spec->{call} // '';
    return undef if $call eq '';
    _mark_helpers($ctx, $spec->{helpers});
    return $call . '(' . $value_c . ')';
}

sub _emit_log_call_for_type_hint {
    my ($value_c, $type_hint, $ctx) = @_;
    my $spec = c_log_strategy_for_type($type_hint);
    return undef if !defined($spec) || ref($spec) ne 'HASH';
    my $call = $spec->{call} // '';
    return undef if $call eq '';
    _mark_helpers($ctx, $spec->{helpers});
    return $call . '(' . $value_c . ')';
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

sub _emit_insert_call_by_registry {
    my (%args) = @_;
    my $meta = $args{meta};
    my $recv_expr = $args{recv_expr};
    my $recv = $args{recv};
    my $call_args = $args{call_args} // [];
    my $ctx = $args{ctx};
    return undef if !defined($meta) || ref($meta) ne 'HASH';

    my $receiver_type = $meta->{receiver_type_hint} // '';
    my $arg_types = $meta->{arg_type_hints};
    $arg_types = [] if !defined($arg_types) || ref($arg_types) ne 'ARRAY';

    my $strategy = c_intrinsic_method_strategy_for_types(
        op_id => 'method.insert.v1',
        receiver_type => $receiver_type,
        arg_types => $arg_types,
    );
    return undef if !defined($strategy) || ref($strategy) ne 'HASH';

    _mark_helpers($ctx, $strategy->{helpers});

    my $recv_is_ident = defined($recv_expr) && ref($recv_expr) eq 'HASH' && (($recv_expr->{kind} // '') eq 'ident');
    my $recv_ident = $recv_is_ident ? ($recv_expr->{name} // '') : '';
    my $suffix = $recv_is_ident ? '' : '_value';
    my $fn = ($strategy->{stem} // '') . $suffix;
    return undef if $fn eq '';

    my $value_arg = $call_args->[0];
    $value_arg = $strategy->{default_value_expr}
      if !defined($value_arg) || $value_arg eq '';
    my $index_mode = $strategy->{index_mode} // 'scalar';
    my $index_arg = $call_args->[1];
    if (!defined($index_arg) || $index_arg eq '') {
        $index_arg = ($index_mode eq 'matrix')
          ? ($strategy->{default_index_matrix_expr} // 'metac_list_i64_empty()')
          : ($strategy->{default_index_scalar_expr} // '0');
    }

    my $recv_arg = $recv_is_ident ? ('&' . $recv_ident) : $recv;
    my @emit_args = ($recv_arg, $value_arg, $index_arg);

    if ($index_mode eq 'matrix' && ($strategy->{supports_matrix} // 0)) {
        _mark_helpers($ctx, $strategy->{helpers_matrix});
        my $is_matrix_recv = (defined($receiver_type) && $receiver_type =~ /^matrix</) ? 1 : 0;
        my $src_ident = $recv_is_ident ? $recv_ident : _root_ident_name($recv_expr);
        my $mvar = $ctx->{matrix_meta_vars}{$src_ident} // '';
        if (($strategy->{supports_matrix_meta} // 0) && $is_matrix_recv && $mvar ne '') {
            $fn = ($strategy->{stem} // '') . '_matrix_meta' . $suffix;
            push @emit_args, '&' . $mvar;
        } else {
            $fn = ($strategy->{stem} // '') . '_matrix' . $suffix;
        }
    }

    return $fn . '(' . join(', ', @emit_args) . ')';
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
            if ($ty eq 'struct metac_list_list_i64') {
                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'list_list_i64');
                return "metac_list_list_i64_get(&$cname, $idx)";
            }
            if ($ty eq 'struct metac_list_i64') {
                _helper_mark($ctx, 'list_i64');
                return "metac_list_i64_get(&$cname, $idx)";
            }
            if ($ty eq 'struct metac_list_str') {
                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'list_str_get');
                return "metac_list_str_get(&$cname, $idx)";
            }
            my $src_type = $ctx->{var_source_types}{$name} // '';
            my $ops = c_type_collection_ops_for_type($src_type);
            if (defined($ops) && ref($ops) eq 'HASH') {
                _mark_type_helpers($ctx, $src_type);
                return $ops->{get} . "(&$cname, $idx)";
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
        my $emitter_id = backend_emitter_id_for_op($meta->{op_id} // '') // '';
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
            my $emitted = _emit_expr_by_backend_emitter($emitter_id, $expr, $ctx, $meta, $target, \@args, undef, undef);
            return $emitted if defined $emitted;
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
            my $arg_c = _expr_c_type_hint($expr->{args}[0], $ctx);
            my $from_c = _emit_log_call_for_c_type($a0, $arg_c, $ctx);
            return $from_c if defined($from_c);
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
        my $emitter_id = backend_emitter_id_for_op($meta->{op_id} // '') // '';
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
            my $emitted = _emit_expr_by_backend_emitter($emitter_id, $expr, $ctx, $meta, $target, \@args, $recv_expr, $recv);
            return $emitted if defined $emitted;
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
