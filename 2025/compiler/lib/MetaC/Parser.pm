package MetaC::Parser;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Support qw(
    compile_error
    set_error_line
    clear_error_line
    strip_comments
    trim
    split_top_level_commas
    parse_constraints
);
use MetaC::TypeSpec qw(normalize_type_annotation apply_matrix_constraints is_matrix_type);

our @EXPORT_OK = qw(
    parse_function_header
    collect_functions
    parse_function_params
    parse_capture_groups
    infer_group_type
    expr_tokens
    parse_expr
    parse_match_statement
    parse_call_invocation_text
    parse_iterable_expression
    parse_block
    parse_function_body
);

require MetaC::Parser::Functions;
require MetaC::Parser::Regex;
require MetaC::Parser::Expr;
require MetaC::Parser::Block;

1;
