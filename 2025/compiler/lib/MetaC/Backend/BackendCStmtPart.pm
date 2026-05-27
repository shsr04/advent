package MetaC::HIR::BackendC;
use strict;
use warnings;

sub _matrix_meta_alias_source_name_stmt {
    my ($expr) = @_;
    return '' if !defined($expr) || ref($expr) ne 'HASH';
    my $k = $expr->{kind} // '';
    return $expr->{name} // '' if $k eq 'ident';
    if ($k eq 'method_call') {
        return _matrix_meta_alias_source_name_stmt($expr->{recv});
    }
    return '';
}

my %STMT_EMITTERS = map { $_ => \&_emit_stmt_body } qw(
  stmt.declare.v1
  stmt.const_try_tail.v1
  stmt.const_try_chain.v1
  stmt.const_or_catch.v1
  stmt.expr_or_catch.v1
  stmt.destructure_split_or.v1
  stmt.destructure_match.v1
  stmt.destructure_list.v1
  stmt.assign.v1
  stmt.assign_op.v1
  stmt.incdec.v1
  stmt.expr.v1
  stmt.return.v1
  stmt.if.v1
  stmt.while.v1
  stmt.rewind.v1
  stmt.for_each.v1
  stmt.loop_transfer.v1
  stmt.raw.v1
);

sub _emit_stmt {
    my ($stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx) = @_;
    my $k = $stmt->{kind} // '';
    my $emitter_id = statement_backend_emitter_id($k) // 'stmt.missing.v1';
    return _emit_stmt_registered($emitter_id, $stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx);
}

sub _emit_stmt_registered {
    my ($emitter_id, $stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx) = @_;
    my $emitter = $STMT_EMITTERS{$emitter_id};
    if (!defined($emitter)) {
        my $sp = ' ' x $indent;
        my $k = $stmt->{kind} // '';
        push @$out, qq{$sp/* Backend/F054 missing stmt emitter for kind '$k' */};
        return;
    }
    return $emitter->($stmt, $out, $indent, $seen_decl, $suppress_step_return, $ctx);
}

require MetaC::Backend::BackendCStmtEmitters;

1;
