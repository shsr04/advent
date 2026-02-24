package MetaC::Codegen;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(
    compile_error
    set_error_line
    clear_error_line
    c_escape_string
    parse_constraints
    constraints_has_kind
    constraints_has_any_kind
    constraint_range_bounds
    constraint_size_exact
    constraint_size_is_wildcard
    emit_line
    trim
);
use MetaC::Parser qw(collect_functions parse_function_params parse_capture_groups infer_group_type parse_function_body parse_expr);
use MetaC::CodegenType qw(
    param_c_type
    render_c_params
    is_number_like_type
    number_like_to_c_expr
    type_matches_expected
    number_or_null_to_c_expr
    generic_union_to_c_expr
);
use MetaC::CodegenScope qw(
    new_scope
    pop_scope
    lookup_var
    declare_var
    set_list_len_fact
    lookup_list_len_fact
    set_nonnull_fact_by_c_name
    clear_nonnull_fact_by_c_name
    has_nonnull_fact_by_c_name
    set_nonnull_fact_for_var_name
    clear_nonnull_fact_for_var_name
);
use MetaC::CodegenRuntime qw(runtime_prelude_for_code);
use MetaC::TypeSpec qw(
    normalize_type_annotation
    union_member_types
    union_contains_member
    is_union_type
    is_supported_generic_union_return
    type_is_number_or_error
    type_is_bool_or_error
    type_is_string_or_error
    type_is_number_or_null
    non_error_member_of_error_union
    type_without_union_member
    is_matrix_type
    matrix_type_meta
    matrix_member_type
    matrix_member_list_type
    is_matrix_member_type
    matrix_member_meta
    is_matrix_member_list_type
    matrix_member_list_meta
    matrix_neighbor_list_type
);

our @EXPORT_OK = qw(compile_source);

require MetaC::Codegen::Facts;
require MetaC::Codegen::MethodMetadata;
require MetaC::Codegen::MethodChainSupport;
require MetaC::Codegen::LoopSupport;
require MetaC::Codegen::ProofIter;
require MetaC::Codegen::ExprMethodCall;
require MetaC::Codegen::Expr;
require MetaC::Codegen::BlockStageDecls;
require MetaC::Codegen::BlockStageDeclsTry;
require MetaC::Codegen::BlockStageTry;
require MetaC::Codegen::BlockStageAssignLoops;
require MetaC::Codegen::BlockStageControl;
require MetaC::Codegen::CompileParams;
require MetaC::Codegen::Compile;

1;
