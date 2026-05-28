package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_method_all {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

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

sub _emit_method_map {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

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

1;
