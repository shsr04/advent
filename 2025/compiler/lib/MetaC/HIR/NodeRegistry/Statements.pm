package MetaC::HIR::NodeRegistry::Statements;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(statement_registry_snapshot statement_spec statement_kinds statement_recognizers statement_step_kind statement_structured_exit statement_backend_emitter_id statement_is_known expr_kind_is_known);

my %STATEMENTS = (
    let => { parser_id => 'let', step_kind => 'Declare', backend_emitter => 'stmt.declare.v1' },
    const => { parser_id => 'const', step_kind => 'Declare', backend_emitter => 'stmt.declare.v1' },
    const_typed => { parser_id => 'const_typed', step_kind => 'Declare', backend_emitter => 'stmt.declare.v1' },
    let_producer => { parser_id => 'let_producer', step_kind => 'Declare', backend_emitter => 'stmt.raw.v1' },
    assign => { parser_id => 'assign', step_kind => 'Assign', backend_emitter => 'stmt.assign.v1' },
    typed_assign => { parser_id => 'typed_assign', step_kind => 'Assign', backend_emitter => 'stmt.assign.v1' },
    assign_op => { parser_id => 'assign_op', step_kind => 'Assign', backend_emitter => 'stmt.assign_op.v1' },
    incdec => { parser_id => 'incdec', step_kind => 'Assign', backend_emitter => 'stmt.incdec.v1' },
    destructure_match => { parser_id => 'destructure_match', step_kind => 'Destructure', backend_emitter => 'stmt.destructure_match.v1' },
    destructure_list => { parser_id => 'destructure_list', step_kind => 'Destructure', backend_emitter => 'stmt.destructure_list.v1' },
    destructure_split_or => { parser_id => 'destructure_split_or', step_kind => 'Destructure', backend_emitter => 'stmt.destructure_split_or.v1' },
    expr_stmt => { parser_id => 'expr_stmt', step_kind => 'Eval', backend_emitter => 'stmt.expr.v1' },
    expr_stmt_try => { parser_id => 'expr_stmt_try', step_kind => 'Eval', structured_exit => 'TryExit', backend_emitter => 'stmt.expr.v1' },
    const_try_expr => { parser_id => 'const_try_expr', step_kind => 'Eval', structured_exit => 'TryExit', backend_emitter => 'stmt.declare.v1' },
    const_try_tail_expr => { parser_id => 'const_try_tail_expr', step_kind => 'Eval', structured_exit => 'TryExit', backend_emitter => 'stmt.const_try_tail.v1' },
    const_or_catch => { parser_id => 'const_or_catch', step_kind => 'Eval', backend_emitter => 'stmt.const_or_catch.v1' },
    const_try_chain => { parser_id => 'const_try_chain', step_kind => 'Eval', backend_emitter => 'stmt.const_try_chain.v1' },
    expr_or_catch => { parser_id => 'expr_or_catch', step_kind => 'Eval', backend_emitter => 'stmt.expr_or_catch.v1' },
    if => { parser_id => 'if', step_kind => 'Control', structured_exit => 'IfExit', backend_emitter => 'stmt.if.v1' },
    while => { parser_id => 'while', step_kind => 'Control', structured_exit => 'WhileExit', backend_emitter => 'stmt.while.v1' },
    for_each => { parser_id => 'for_each', step_kind => 'Control', structured_exit => 'ForInExit', backend_emitter => 'stmt.for_each.v1' },
    for_each_try => { parser_id => 'for_each_try', step_kind => 'Control', structured_exit => 'ForInExit', backend_emitter => 'stmt.for_each.v1' },
    for_lines => { parser_id => 'for_lines', step_kind => 'Control', backend_emitter => 'stmt.for_each.v1' },
    break => { parser_id => 'break', step_kind => 'Control', backend_emitter => 'stmt.loop_transfer.v1' },
    continue => { parser_id => 'continue', step_kind => 'Control', backend_emitter => 'stmt.loop_transfer.v1' },
    rewind => { parser_id => 'rewind', step_kind => 'Control', backend_emitter => 'stmt.rewind.v1' },
    return => { parser_id => 'return', step_kind => 'Control', terminal_exit => 'Return', backend_emitter => 'stmt.return.v1' },
    raw => { parser_id => 'raw', step_kind => 'Control', backend_emitter => 'stmt.raw.v1' },
);

my @STATEMENT_RECOGNIZER_ORDER = qw(
  for_lines for_each_try for_each while break continue rewind if
  destructure_match destructure_split_or destructure_list
  const_typed const_try_chain const_try_expr const_or_catch const_try_tail_expr const
  let_producer let return typed_assign assign_op incdec assign expr_or_catch expr_stmt_try expr_stmt raw
);

my %EXPR_KINDS = map { $_ => 1 } qw(
  num str bool null ident list_literal unary binop index try call method_call member_access lambda1 lambda2 call_expr
);

sub statement_registry_snapshot { return { statements => \%STATEMENTS, expr_kinds => \%EXPR_KINDS }; }
sub statement_spec { my ($kind) = @_; return undef if !defined($kind) || $kind eq ''; return $STATEMENTS{$kind}; }
sub statement_kinds { return [ sort keys %STATEMENTS ]; }
sub statement_recognizers { return [ map { my $spec = $STATEMENTS{$_}; { stmt_kind => $_, parser_id => $spec->{parser_id} } } @STATEMENT_RECOGNIZER_ORDER ]; }
sub statement_is_known { my ($kind) = @_; return defined(statement_spec($kind)) ? 1 : 0; }
sub statement_step_kind { my ($kind) = @_; my $spec = statement_spec($kind); return defined($spec) ? ($spec->{step_kind} // 'Control') : 'Control'; }
sub statement_structured_exit { my ($kind) = @_; my $spec = statement_spec($kind); return undef if !defined($spec); return $spec->{structured_exit}; }
sub statement_backend_emitter_id { my ($kind) = @_; my $spec = statement_spec($kind); return undef if !defined($spec); return $spec->{backend_emitter}; }
sub expr_kind_is_known { my ($kind) = @_; return 0 if !defined($kind) || $kind eq ''; return $EXPR_KINDS{$kind} ? 1 : 0; }

1;
