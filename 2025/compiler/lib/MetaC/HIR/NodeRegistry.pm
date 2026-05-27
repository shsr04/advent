package MetaC::HIR::NodeRegistry;
use strict;
use warnings;
use Exporter 'import';

use MetaC::HIR::NodeRegistry::Statements qw(
    statement_registry_snapshot
    statement_spec
    statement_kinds
    statement_recognizers
    statement_step_kind
    statement_structured_exit
    statement_backend_emitter_id
    statement_is_known
    expr_kind_is_known
);
use MetaC::HIR::NodeRegistry::Exits qw(
    exit_registry_snapshot
    exit_spec
    exit_edge_tags
    exit_target_fields
);
use MetaC::HIR::NodeRegistry::Operations qw(
    operation_registry_snapshot
    op_spec
    backend_emitter_id_for_op
    user_call_op_id
    user_method_style_allowed
    builtin_is_known
    builtin_op_id
    builtin_result_type
    builtin_result_type_hint
    builtin_fallibility_hint
    builtin_may_be_fallible
    builtin_param_contract
    method_is_known
    method_receiver_supported
    method_op_id
    method_result_type
    method_result_type_hint
    method_dynamic_result_policy
    method_fallibility_hint
    method_has_tag
    method_has_length_semantics
    method_traceability_hint
    method_requires_matrix_axis_argument
    method_callback_shape_label
    method_callback_contract
    method_param_contract
);

our @EXPORT_OK = qw(
    node_registry_snapshot
    statement_spec
    statement_kinds
    statement_recognizers
    statement_step_kind
    statement_structured_exit
    statement_backend_emitter_id
    statement_is_known
    expr_kind_is_known
    exit_spec
    exit_edge_tags
    exit_target_fields
    op_spec
    backend_emitter_id_for_op
    user_call_op_id
    user_method_style_allowed
    builtin_is_known
    builtin_op_id
    builtin_result_type
    builtin_result_type_hint
    builtin_fallibility_hint
    builtin_may_be_fallible
    builtin_param_contract
    method_is_known
    method_receiver_supported
    method_op_id
    method_result_type
    method_result_type_hint
    method_dynamic_result_policy
    method_fallibility_hint
    method_has_tag
    method_has_length_semantics
    method_traceability_hint
    method_requires_matrix_axis_argument
    method_callback_shape_label
    method_callback_contract
    method_param_contract
);

sub node_registry_snapshot {
    my $stmt = statement_registry_snapshot();
    my $exit = exit_registry_snapshot();
    return {
        statements => $stmt->{statements},
        expr_kinds => $stmt->{expr_kinds},
        exits      => $exit->{exits},
        exit_target_fields => $exit->{target_fields},
        operations => operation_registry_snapshot(),
    };
}

1;
