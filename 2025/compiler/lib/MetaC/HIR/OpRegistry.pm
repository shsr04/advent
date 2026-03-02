package MetaC::HIR::OpRegistry;
use strict;
use warnings;
use Exporter 'import';

use MetaC::TypeSpec qw(
    is_matrix_type
    matrix_type_meta
    matrix_member_list_type
    matrix_neighbor_list_type
    is_matrix_member_type
    matrix_member_meta
    is_sequence_type
    sequence_element_type
    sequence_type_for_element
);

our @EXPORT_OK = qw(
    op_registry_snapshot
    user_call_op_id
    user_method_style_allowed
    builtin_is_known
    builtin_op_id
    builtin_result_type_hint
    builtin_param_contract
    method_is_known
    method_receiver_supported
    method_op_id
    method_result_type_hint
    method_fallibility_hint
    method_callback_contract
    method_param_contract
);

my %REGISTRY = (
    calls => {
        user => {
            op_id => 'call.user.v1',
            fluent_invocation => {
                enabled           => 1,
                min_param_count   => 1,
                receiver_position => 0,
            },
        },
        builtins => {
            parseNumber => {
                op_id         => 'call.builtin.parseNumber.v1',
                param_policy  => 'fixed',
                param_symbols => ['string'],
                result_policy => 'fixed',
                result_type   => 'number | error',
            },
            error => {
                op_id         => 'call.builtin.error.v1',
                param_policy  => 'fixed',
                param_symbols => ['any'],
                result_policy => 'fixed',
                result_type   => 'error',
            },
            max => {
                op_id         => 'call.builtin.max.v1',
                param_policy  => 'fixed',
                param_symbols => ['number', 'number'],
                result_policy => 'fixed',
                result_type   => 'number',
            },
            min => {
                op_id         => 'call.builtin.min.v1',
                param_policy  => 'fixed',
                param_symbols => ['number', 'number'],
                result_policy => 'fixed',
                result_type   => 'number',
            },
            last => {
                op_id         => 'call.builtin.last.v1',
                param_policy  => 'fixed',
                param_symbols => ['any'],
                result_policy => 'fixed',
                result_type   => 'number',
            },
            seq => {
                op_id         => 'call.builtin.seq.v1',
                param_policy  => 'fixed',
                param_symbols => ['number', 'number'],
                result_policy => 'fixed',
                result_type   => sequence_type_for_element('number'),
            },
            log => {
                op_id         => 'call.builtin.log.v1',
                param_policy  => 'fixed',
                param_symbols => ['any'],
                result_policy => 'arg0',
            },
            __default__ => {
                op_id         => 'call.builtin.unknown.v1',
                param_policy  => 'unknown',
                result_policy => 'unknown',
            },
        },
    },
    methods => {
        size      => { op_id => 'method.size.v1',      receiver_policy => 'sized',                    param_policy => 'size_by_receiver',   result_policy => 'fixed',             result_type => 'number',              fallibility => 'never' },
        count     => { op_id => 'method.count.v1',     receiver_policy => 'sized',                    param_policy => 'none',               result_policy => 'fixed',             result_type => 'number',              fallibility => 'never' },
        chars     => { op_id => 'method.chars.v1',     receiver_policy => 'string',                   param_policy => 'none',               result_policy => 'fixed',             result_type => sequence_type_for_element('string'),                    fallibility => 'never' },
        chunk     => { op_id => 'method.chunk.v1',     receiver_policy => 'string',                   param_policy => 'fixed',              param_type_symbols => ['number'],     result_policy => 'fixed',             result_type => sequence_type_for_element('string'),                    fallibility => 'never' },
        isBlank   => { op_id => 'method.isBlank.v1',   receiver_policy => 'string',                   param_policy => 'none',               result_policy => 'fixed',             result_type => 'bool',                fallibility => 'never' },
        split     => { op_id => 'method.split.v1',     receiver_policy => 'string',                   param_policy => 'fixed',              param_type_symbols => ['string'],     result_policy => 'fixed',             result_type => sequence_type_for_element('string') . ' | error',      fallibility => 'always' },
        match     => { op_id => 'method.match.v1',     receiver_policy => 'string',                   param_policy => 'fixed',              param_type_symbols => ['string'],     result_policy => 'fixed',             result_type => sequence_type_for_element('string') . ' | error',      fallibility => 'always' },
        compareTo => { op_id => 'method.compareTo.v1', receiver_policy => 'default_comparison',       param_policy => 'fixed',              param_type_symbols => ['receiver'],   result_policy => 'fixed',             result_type => 'comparison_result',   fallibility => 'never' },
        andThen   => { op_id => 'method.andThen.v1',   receiver_policy => 'comparison_result',        param_policy => 'fixed',              param_type_symbols => ['comparison_result'], result_policy => 'fixed',       result_type => 'comparison_result',   fallibility => 'never' },
        push      => { op_id => 'method.push.v1',      receiver_policy => 'sequence',                 param_policy => 'fixed',              param_type_symbols => ['receiver_elem'], result_policy => 'fixed',        result_type => 'number',              fallibility => 'never' },
        any       => {
            op_id => 'method.any.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'fixed',
            result_type => 'bool',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 1,
                callback_arg_index => 0,
                callback_arity => 1,
                param_type_symbols => ['elem'],
                return_type_symbol => 'bool',
            },
        },
        all       => {
            op_id => 'method.all.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'fixed',
            result_type => 'bool',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 1,
                callback_arg_index => 0,
                callback_arity => 1,
                param_type_symbols => ['elem'],
                return_type_symbol => 'bool',
            },
        },
        max       => { op_id => 'method.max.v1',       receiver_policy => 'sequence',                 param_policy => 'none',               result_policy => 'fixed',             result_type => 'indexed_number',      fallibility => 'never' },
        last      => { op_id => 'method.last.v1',      receiver_policy => 'sequence',                 param_policy => 'none',               result_policy => 'last_by_receiver',  fallibility => 'never' },
        sort      => { op_id => 'method.sort.v1',      receiver_policy => 'sequence_orderable',       param_policy => 'none',               result_policy => 'receiver',          fallibility => 'never' },
        map       => {
            op_id => 'method.map.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'receiver',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 1,
                callback_arg_index => 0,
                callback_arity => 1,
                param_type_symbols => ['elem'],
                return_type_symbol => 'elem',
            },
        },
        slice     => { op_id => 'method.slice.v1',     receiver_policy => 'sequence',                 param_policy => 'fixed',              param_type_symbols => ['number'],     result_policy => 'receiver',          fallibility => 'never' },
        filter    => {
            op_id => 'method.filter.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'receiver',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 1,
                callback_arg_index => 0,
                callback_arity => 1,
                param_type_symbols => ['elem'],
                return_type_symbol => 'bool',
            },
        },
        sortBy    => {
            op_id => 'method.sortBy.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'receiver',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 1,
                callback_arg_index => 0,
                callback_arity => 2,
                param_type_symbols => ['elem', 'elem'],
                return_type_symbol => 'comparison_result',
            },
        },
        insert    => { op_id => 'method.insert.v1',    receiver_policy => 'sequence_or_matrix',       param_policy => 'insert_by_receiver', result_policy => 'receiver',          fallibility => 'matrix_insert' },
        log       => { op_id => 'method.log.v1',       receiver_policy => 'any',                      param_policy => 'none',               result_policy => 'receiver',          fallibility => 'never' },
        members   => { op_id => 'method.members.v1',   receiver_policy => 'matrix',                   param_policy => 'none',               result_policy => 'matrix_members',    fallibility => 'never' },
        index     => { op_id => 'method.index.v1',     receiver_policy => 'element_or_matrix_member', param_policy => 'none',               result_policy => 'index_by_receiver', fallibility => 'never' },
        neighbours => { op_id => 'method.neighbours.v1', receiver_policy => 'matrix_or_member',       param_policy => 'none',               result_policy => 'matrix_neighbours', fallibility => 'never' },
        reduce    => {
            op_id => 'method.reduce.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'unknown',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 2,
                initial_arg_index => 0,
                initial_type_policy => 'any_valid',
                callback_arg_index => 1,
                callback_arity => 2,
                param_type_symbols => ['initial', 'elem'],
                return_type_symbol => 'initial',
            },
        },
        scan      => {
            op_id => 'method.scan.v1',
            receiver_policy => 'sequence',
            param_policy => 'callback_contract',
            result_policy => 'receiver',
            fallibility => 'contextual',
            callback_contract => {
                total_arg_count => 2,
                initial_arg_index => 0,
                initial_type_policy => 'elem',
                callback_arg_index => 1,
                callback_arity => 2,
                param_type_symbols => ['elem', 'elem'],
                return_type_symbol => 'elem',
            },
        },
        __default__ => { op_id => 'method.unknown.v1', receiver_policy => 'none',                     param_policy => 'unknown',            result_policy => 'unknown',           fallibility => 'never' },
    },
);

sub op_registry_snapshot {
    return \%REGISTRY;
}

sub user_call_op_id {
    return $REGISTRY{calls}{user}{op_id};
}

sub user_method_style_allowed {
    my ($sig) = @_;
    my $cfg = $REGISTRY{calls}{user}{fluent_invocation} // {};
    return 0 if !($cfg->{enabled} // 0);
    return 0 if int($cfg->{receiver_position} // 0) != 0;
    return 0 if !defined($sig) || ref($sig) ne 'HASH';
    my $params = $sig->{params};
    return 0 if !defined($params) || ref($params) ne 'ARRAY';
    my $min = int($cfg->{min_param_count} // 1);
    return scalar(@$params) >= $min ? 1 : 0;
}

sub _builtin_spec {
    my ($name) = @_;
    return $REGISTRY{calls}{builtins}{$name} // $REGISTRY{calls}{builtins}{__default__};
}

sub builtin_is_known {
    my ($name) = @_;
    return 0 if !defined($name) || $name eq '';
    return 0 if $name eq '__default__';
    return exists $REGISTRY{calls}{builtins}{$name} ? 1 : 0;
}

sub builtin_op_id {
    my ($name) = @_;
    return _builtin_spec($name)->{op_id};
}

sub builtin_result_type_hint {
    my ($name, $args, $infer_arg_type) = @_;
    my $spec = _builtin_spec($name);
    my $policy = $spec->{result_policy} // 'unknown';

    return $spec->{result_type} if $policy eq 'fixed';
    if ($policy eq 'arg0') {
        return undef if !defined($infer_arg_type) || ref($infer_arg_type) ne 'CODE';
        return undef if !defined($args) || ref($args) ne 'ARRAY' || !@$args;
        return $infer_arg_type->($args->[0]);
    }
    return undef;
}

sub _resolve_builtin_param_symbol {
    my ($symbol) = @_;
    return undef if !defined($symbol) || $symbol eq '';
    return $symbol if $symbol eq 'number' || $symbol eq 'string' || $symbol eq 'bool' || $symbol eq 'comparison_result' || $symbol eq 'any';
    return undef;
}

sub builtin_param_contract {
    my ($name) = @_;
    my $spec = _builtin_spec($name);
    my $policy = $spec->{param_policy} // 'unknown';
    return { policy => 'unknown' } if $policy eq 'unknown';
    return { policy => 'none', arity => 0, param_types => [] } if $policy eq 'none';
    if ($policy eq 'fixed') {
        my $symbols = $spec->{param_symbols};
        return undef if ref($symbols) ne 'ARRAY';
        my @types = map { _resolve_builtin_param_symbol($_) } @$symbols;
        return undef if grep { !defined($_) || $_ eq '' } @types;
        return { policy => 'fixed', arity => scalar(@types), param_types => \@types };
    }
    return undef;
}
sub _method_spec {
    my ($method) = @_;
    return $REGISTRY{methods}{$method} // $REGISTRY{methods}{__default__};
}

sub method_is_known {
    my ($method) = @_;
    return 0 if !defined($method) || $method eq '';
    return 0 if $method eq '__default__';
    return exists $REGISTRY{methods}{$method} ? 1 : 0;
}

sub method_op_id {
    my ($method) = @_;
    return _method_spec($method)->{op_id};
}

sub _is_sequence_receiver_type {
    my ($recv_type) = @_;
    return is_sequence_type($recv_type);
}

sub _type_supports_default_comparison {
    my ($type) = @_;
    return 0 if !defined($type) || $type eq '' || $type eq 'unknown';
    return 1 if $type eq 'number' || $type eq 'string';
    return 0 if $type eq 'bool';
    return 1 if is_matrix_type($type);
    if (is_sequence_type($type)) {
        my $elem = sequence_element_type($type);
        return 0 if !defined $elem;
        return _type_supports_default_comparison($elem);
    }
    return 0;
}

sub _method_receiver_supported_by_policy {
    my ($policy, $recv_type) = @_;
    return 0 if !defined($policy);
    return 1 if $policy eq 'any' && defined($recv_type) && $recv_type ne '';
    return 0 if !defined($recv_type) || $recv_type eq '' || $recv_type eq 'unknown';

    return $recv_type eq 'string' ? 1 : 0 if $policy eq 'string';
    return $recv_type eq 'number' ? 1 : 0 if $policy eq 'number';
    return $recv_type eq 'comparison_result' ? 1 : 0 if $policy eq 'comparison_result';
    return _type_supports_default_comparison($recv_type) ? 1 : 0 if $policy eq 'default_comparison';
    if ($policy eq 'sequence_orderable') {
        return 0 if !_is_sequence_receiver_type($recv_type);
        my $elem = sequence_element_type($recv_type);
        return _type_supports_default_comparison($elem);
    }
    return _is_sequence_receiver_type($recv_type) if $policy eq 'sequence';
    return 1 if $policy eq 'sized' && ($recv_type eq 'string' || _is_sequence_receiver_type($recv_type) || is_matrix_type($recv_type));
    return is_matrix_type($recv_type) ? 1 : 0 if $policy eq 'matrix';
    return 1 if $policy eq 'sequence_or_matrix' && (_is_sequence_receiver_type($recv_type) || is_matrix_type($recv_type));
    return 1 if $policy eq 'matrix_or_member' && (is_matrix_type($recv_type) || is_matrix_member_type($recv_type));
    return 1 if $policy eq 'element_or_matrix_member'
      && (is_matrix_member_type($recv_type) || $recv_type eq 'number' || $recv_type eq 'string' || $recv_type eq 'bool');
    return 0 if $policy eq 'none';
    return 0;
}

sub method_receiver_supported {
    my ($method, $recv_type) = @_;
    return 0 if !method_is_known($method);
    my $spec = _method_spec($method);
    my $policy = $spec->{receiver_policy} // 'none';
    return _method_receiver_supported_by_policy($policy, $recv_type);
}

sub _last_result_type {
    my ($recv_type) = @_;
    return sequence_element_type($recv_type);
}

sub _matrix_members_result_type {
    my ($recv_type) = @_;
    return undef if !defined($recv_type) || !is_matrix_type($recv_type);
    return matrix_member_list_type($recv_type);
}

sub _index_result_type {
    my ($recv_type) = @_;
    return sequence_type_for_element('number')
      if defined($recv_type) && is_matrix_member_type($recv_type);
    return 'number';
}

sub _matrix_neighbours_result_type {
    my ($recv_type) = @_;
    return undef if !defined $recv_type;
    if (is_matrix_type($recv_type)) {
        return matrix_neighbor_list_type($recv_type);
    }
    if (is_matrix_member_type($recv_type)) {
        my $meta = matrix_member_meta($recv_type);
        return sequence_type_for_element($meta->{elem});
    }
    return undef;
}

sub method_result_type_hint {
    my ($method, $recv_type) = @_;
    my $spec = _method_spec($method);
    my $policy = $spec->{result_policy} // 'unknown';

    return $spec->{result_type} if $policy eq 'fixed';
    return $recv_type if $policy eq 'receiver';
    return _last_result_type($recv_type) if $policy eq 'last_by_receiver';
    return _matrix_members_result_type($recv_type) if $policy eq 'matrix_members';
    return _index_result_type($recv_type) if $policy eq 'index_by_receiver';
    return _matrix_neighbours_result_type($recv_type) if $policy eq 'matrix_neighbours';
    return undef;
}

sub method_fallibility_hint {
    my ($method, $recv_type) = @_;
    my $spec = _method_spec($method);
    my $policy = $spec->{fallibility} // 'never';

    return 'always' if $policy eq 'always';
    return 'contextual' if $policy eq 'contextual';
    if ($policy eq 'matrix_insert') {
        return 'never' if !defined($recv_type) || !is_matrix_type($recv_type);
        my $meta = matrix_type_meta($recv_type);
        return $meta->{has_size} ? 'never' : 'conditional';
    }
    return 'never';
}

sub method_callback_contract {
    my ($method) = @_;
    return undef if !method_is_known($method);
    my $spec = _method_spec($method);
    my $contract = $spec->{callback_contract};
    return undef if !defined($contract) || ref($contract) ne 'HASH';

    my %copy = %$contract;
    if (defined($contract->{param_type_symbols}) && ref($contract->{param_type_symbols}) eq 'ARRAY') {
        $copy{param_type_symbols} = [ @{ $contract->{param_type_symbols} } ];
    }
    return \%copy;
}
sub _resolve_method_param_symbol {
    my ($symbol, $recv_type) = @_;
    return undef if !defined($symbol) || $symbol eq '';
    return $symbol if $symbol eq 'number' || $symbol eq 'string' || $symbol eq 'bool' || $symbol eq 'comparison_result';
    return $recv_type if $symbol eq 'receiver';
    if ($symbol eq 'receiver_elem') {
        return sequence_element_type($recv_type);
    }
    return sequence_type_for_element('number') if $symbol eq 'number_list';
    if ($symbol eq 'matrix_elem') {
        return undef if !defined($recv_type) || !is_matrix_type($recv_type);
        return matrix_type_meta($recv_type)->{elem};
    }
    return undef;
}

sub method_param_contract {
    my ($method, $recv_type) = @_;
    return undef if !method_is_known($method);
    my $spec = _method_spec($method);
    my $policy = $spec->{param_policy} // 'unknown';

    if ($policy eq 'none') {
        return { policy => 'none', arity => 0, param_types => [] };
    }
    if ($policy eq 'callback_contract') {
        return { policy => 'callback_contract' };
    }
    if ($policy eq 'fixed') {
        my $symbols = $spec->{param_type_symbols};
        return undef if ref($symbols) ne 'ARRAY';
        my @types = map { _resolve_method_param_symbol($_, $recv_type) } @$symbols;
        return undef if grep { !defined($_) || $_ eq '' } @types;
        return { policy => 'fixed', arity => scalar(@types), param_types => \@types };
    }
    if ($policy eq 'size_by_receiver') {
        return { policy => 'fixed', arity => 1, param_types => ['number'] } if defined($recv_type) && is_matrix_type($recv_type);
        return { policy => 'none', arity => 0, param_types => [] };
    }
    if ($policy eq 'insert_by_receiver') {
        if (defined($recv_type) && is_sequence_type($recv_type)) {
            my $elem = sequence_element_type($recv_type);
            return undef if !defined($elem) || $elem eq '';
            return { policy => 'fixed', arity => 2, param_types => [$elem, 'number'] };
        }
        if (defined($recv_type) && is_matrix_type($recv_type)) {
            my $elem = matrix_type_meta($recv_type)->{elem};
            return undef if !defined($elem) || $elem eq '';
            return { policy => 'fixed', arity => 2, param_types => [$elem, sequence_type_for_element('number')] };
        }
        return undef;
    }
    return undef;
}

1;
