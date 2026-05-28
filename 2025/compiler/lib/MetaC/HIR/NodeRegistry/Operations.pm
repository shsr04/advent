package MetaC::HIR::NodeRegistry::Operations;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::NodeRegistry::OperationsData qw(operation_registry);
use MetaC::TypeSpec qw(is_matrix_type matrix_type_meta matrix_member_list_type matrix_neighbor_list_type is_matrix_member_type matrix_member_meta is_sequence_type sequence_element_type sequence_type_for_element sequence_member_type is_sequence_member_type sequence_member_meta);

our @EXPORT_OK = qw(operation_registry_snapshot op_spec backend_emitter_id_for_op user_call_op_id user_method_style_allowed builtin_is_known builtin_op_id builtin_result_type builtin_result_type_hint builtin_fallibility_hint builtin_may_be_fallible builtin_param_contract method_is_known method_receiver_supported method_op_id method_result_type method_result_type_hint method_dynamic_result_policy method_fallibility_hint method_has_tag method_has_length_semantics method_traceability_hint method_requires_matrix_axis_argument method_callback_shape_label method_callback_contract method_param_contract);

my $REGISTRY_REF = operation_registry();

sub operation_registry_snapshot { return $REGISTRY_REF; }

sub op_spec {
    my ($op_id) = @_;
    return undef if !defined($op_id) || $op_id eq '';
    return $REGISTRY_REF->{calls}{user} if $op_id eq ($REGISTRY_REF->{calls}{user}{op_id} // '');
    for my $spec (values %{ $REGISTRY_REF->{calls}{builtins} }) {
        return $spec if ($spec->{op_id} // '') eq $op_id;
    }
    for my $spec (values %{ $REGISTRY_REF->{methods} }) {
        return $spec if ($spec->{op_id} // '') eq $op_id;
    }
    return undef;
}

sub backend_emitter_id_for_op {
    my ($op_id) = @_;
    return undef if !defined($op_id) || $op_id eq '';
    my $spec = op_spec($op_id);
    return undef if !defined($spec);
    return $spec->{backend_emitter};
}

sub user_call_op_id {
    return $REGISTRY_REF->{calls}{user}{op_id};
}

sub user_method_style_allowed {
    my ($sig) = @_;
    my $cfg = $REGISTRY_REF->{calls}{user}{fluent_invocation} // {};
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
    return $REGISTRY_REF->{calls}{builtins}{$name} // $REGISTRY_REF->{calls}{builtins}{__default__};
}

sub builtin_is_known {
    my ($name) = @_;
    return 0 if !defined($name) || $name eq '';
    return 0 if $name eq '__default__';
    return exists $REGISTRY_REF->{calls}{builtins}{$name} ? 1 : 0;
}

sub builtin_op_id {
    my ($name) = @_;
    return _builtin_spec($name)->{op_id};
}

sub builtin_result_type {
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

sub builtin_result_type_hint {
    return builtin_result_type(@_);
}

sub builtin_fallibility_hint {
    my ($name) = @_;
    my $spec = _builtin_spec($name);
    my $result_policy = $spec->{result_policy} // 'unknown';

    if ($result_policy eq 'fixed') {
        my $result_type = $spec->{result_type};
        return (defined($result_type) && $result_type =~ /\berror\b/) ? 'always' : 'never';
    }
    return 'contextual' if $result_policy eq 'arg0';
    return 'contextual';
}

sub builtin_may_be_fallible {
    my ($name) = @_;
    my $hint = builtin_fallibility_hint($name);
    return 0 if !defined($hint) || $hint eq '' || $hint eq 'never';
    return 1;
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
    return $REGISTRY_REF->{methods}{$method} // $REGISTRY_REF->{methods}{__default__};
}

sub method_is_known {
    my ($method) = @_;
    return 0 if !defined($method) || $method eq '';
    return 0 if $method eq '__default__';
    return exists $REGISTRY_REF->{methods}{$method} ? 1 : 0;
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

    if ($policy eq 'string') {
        return 1 if $recv_type eq 'string';
        if (is_sequence_member_type($recv_type)) {
            my $meta = sequence_member_meta($recv_type);
            my $elem = defined($meta) ? ($meta->{elem} // '') : '';
            return $elem eq 'string' ? 1 : 0;
        }
        if (is_matrix_member_type($recv_type)) {
            my $meta = matrix_member_meta($recv_type);
            my $elem = defined($meta) ? ($meta->{elem} // '') : '';
            return $elem eq 'string' ? 1 : 0;
        }
        return 0;
    }
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
    return is_matrix_member_type($recv_type) ? 1 : 0 if $policy eq 'matrix_member';
    return 1 if $policy eq 'sequence_member_or_matrix_member'
      && (is_matrix_member_type($recv_type) || is_sequence_member_type($recv_type));
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

sub _matrix_members_result_type {
    my ($recv_type) = @_;
    return undef if !defined($recv_type) || !is_matrix_type($recv_type);
    return matrix_member_list_type($recv_type);
}

sub _index_result_type {
    my ($recv_type) = @_;
    return sequence_type_for_element('number')
      if defined($recv_type) && is_matrix_member_type($recv_type);
    return 'number' if defined($recv_type) && is_sequence_member_type($recv_type);
    return 'number';
}

sub _member_result_type {
    my ($recv_type) = @_;
    my $elem = sequence_element_type($recv_type);
    return undef if !defined($elem);
    return sequence_member_type($elem);
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

sub _matrix_elem_result_type {
    my ($recv_type) = @_;
    return undef if !defined($recv_type) || !is_matrix_type($recv_type);
    my $meta = matrix_type_meta($recv_type);
    return undef if !defined($meta) || ref($meta) ne 'HASH';
    return $meta->{elem};
}

sub method_result_type {
    my ($method, $recv_type) = @_;
    my $spec = _method_spec($method);
    my $policy = $spec->{result_policy} // 'unknown';

    my $string_elem_result_type = $spec->{string_elem_result_type};
    if (defined($string_elem_result_type) && $string_elem_result_type ne '') {
        my $elem = sequence_element_type($recv_type);
        return $string_elem_result_type if defined($elem) && $elem eq 'string';
    }

    return $spec->{result_type} if $policy eq 'fixed';
    return $recv_type if $policy eq 'receiver';
    return _member_result_type($recv_type) if $policy eq 'traceable_member';
    return _matrix_members_result_type($recv_type) if $policy eq 'matrix_members';
    return _matrix_elem_result_type($recv_type) if $policy eq 'matrix_elem';
    return _index_result_type($recv_type) if $policy eq 'index_by_receiver';
    return _matrix_neighbours_result_type($recv_type) if $policy eq 'matrix_neighbours';
    return undef;
}

sub method_result_type_hint {
    return method_result_type(@_);
}

sub method_dynamic_result_policy {
    my ($method) = @_;
    return undef if !method_is_known($method);
    my $spec = _method_spec($method);
    my $policy = $spec->{dynamic_result_policy};
    return undef if !defined($policy) || $policy eq '';
    return $policy;
}

sub method_fallibility_hint {
    my ($method, $recv_type) = @_;
    my $spec = _method_spec($method);
    my $policy = $spec->{fallibility} // 'never';

    return 'always' if $policy eq 'always';
    return 'conditional' if $policy eq 'conditional';
    return 'contextual' if $policy eq 'contextual';
    if ($policy eq 'matrix_insert') {
        return 'conditional' if defined($recv_type) && is_sequence_type($recv_type);
        return 'never' if !defined($recv_type) || !is_matrix_type($recv_type);
        my $meta = matrix_type_meta($recv_type);
        return $meta->{has_size} ? 'never' : 'conditional';
    }
    return 'never';
}

sub method_has_tag {
    my ($method, $tag) = @_;
    return 0 if !method_is_known($method);
    return 0 if !defined($tag) || $tag eq '';
    my $spec = _method_spec($method);
    my $tags = $spec->{tags};
    return 0 if !defined($tags) || ref($tags) ne 'ARRAY';
    return scalar(grep { defined($_) && $_ eq $tag } @$tags) ? 1 : 0;
}

sub method_has_length_semantics {
    my ($method) = @_;
    return 0 if !method_is_known($method);
    my $spec = _method_spec($method);
    return ($spec->{length_semantics} // 0) ? 1 : 0;
}

sub method_traceability_hint {
    my ($method) = @_;
    return undef if !method_is_known($method);
    my $spec = _method_spec($method);
    my $hint = $spec->{traceability};
    return undef if !defined($hint) || $hint eq '';
    return $hint;
}

sub method_requires_matrix_axis_argument {
    my ($method) = @_;
    return 0 if !method_is_known($method);
    my $spec = _method_spec($method);
    return ($spec->{matrix_axis_argument} // 0) ? 1 : 0;
}

sub method_callback_shape_label {
    my ($method) = @_;
    return undef if !method_is_known($method);
    my $spec = _method_spec($method);
    my $label = $spec->{callback_shape_label};
    return undef if !defined($label) || $label eq '';
    return $label;
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
    if ($policy eq 'neighbours_by_receiver') {
        if (defined($recv_type) && is_matrix_type($recv_type)) {
            return { policy => 'fixed', arity => 1, param_types => [sequence_type_for_element('number')] };
        }
        if (defined($recv_type) && is_matrix_member_type($recv_type)) {
            return { policy => 'none', arity => 0, param_types => [] };
        }
        return undef;
    }
    return undef;
}
