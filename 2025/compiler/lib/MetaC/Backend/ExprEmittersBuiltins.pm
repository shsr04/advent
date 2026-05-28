package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _emit_call_builtin_parseNumber {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'parse_number');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_parse_number(' . ($args[0] // '""') . ')';
            
}

sub _emit_call_builtin_error {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'builtin_error');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_error(' . ($args[0] // '""') . ')';
            
}

sub _emit_call_builtin_split {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_split(' . ($args[0] // '""') . ', ' . ($args[1] // '""') . ')';
            
}

sub _emit_call_builtin_lines {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_str');
                _helper_mark($ctx, 'builtin_lines');
                _helper_mark($ctx, 'builtin_split');
                _helper_mark($ctx, 'error_flag');
                return 'metac_builtin_lines(' . ($args[0] // '""') . ')';
            
}

sub _emit_call_builtin_max {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $a = $args[0] // '0';
                my $b = $args[1] // '0';
                return "(($a) > ($b) ? ($a) : ($b))";
            
}

sub _emit_call_builtin_min {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $a = $args[0] // '0';
                my $b = $args[1] // '0';
                return "(($a) < ($b) ? ($a) : ($b))";
            
}

sub _emit_call_builtin_log {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                my $hints = $meta->{arg_type_hints};
                my $hint = (defined($hints) && ref($hints) eq 'ARRAY' && @$hints) ? ($hints->[0] // '') : '';
                my $a0 = $args[0] // '0';
                my $from_hint = _emit_log_call_for_type_hint($a0, $hint, $ctx);
                return $from_hint if defined($from_hint);
                my $arg_c = _expr_c_type_hint($expr->{args}[0], $ctx);
                my $from_c = _emit_log_call_for_c_type($a0, $arg_c, $ctx);
                return $from_c if defined($from_c);
                _helper_mark($ctx, 'log_i64');
                return "metac_builtin_log_i64($a0)";
            
}

sub _emit_call_builtin_seq {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'seq_i64');
                return 'metac_builtin_seq_i64(' . ($args[0] // '0') . ', ' . ($args[1] // '0') . ')';
            
}

sub _emit_call_builtin_last {
    my ($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my @args = @{ $args_ref // [] };

                _helper_mark($ctx, 'list_i64');
                _helper_mark($ctx, 'last_index_i64');
                return 'metac_builtin_last_index_i64(' . ($args[0] // 'metac_list_i64_empty()') . ')';
            
}

1;
