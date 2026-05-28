package MetaC::HIR::BackendC;
use strict;
use warnings;

my %EXPR_BACKEND_EMITTERS = (
    'call.builtin.parseNumber.v1' => \&_emit_call_builtin_parseNumber,
    'call.builtin.error.v1' => \&_emit_call_builtin_error,
    'call.builtin.split.v1' => \&_emit_call_builtin_split,
    'call.builtin.lines.v1' => \&_emit_call_builtin_lines,
    'call.builtin.max.v1' => \&_emit_call_builtin_max,
    'call.builtin.min.v1' => \&_emit_call_builtin_min,
    'call.builtin.log.v1' => \&_emit_call_builtin_log,
    'call.builtin.seq.v1' => \&_emit_call_builtin_seq,
    'call.builtin.last.v1' => \&_emit_call_builtin_last,
    'method.match.v1' => \&_emit_method_match,
    'method.split.v1' => \&_emit_method_split,
    'method.compareTo.v1' => \&_emit_method_compareTo,
    'method.andThen.v1' => \&_emit_method_andThen,
    'method.chars.v1' => \&_emit_method_chars,
    'method.chunk.v1' => \&_emit_method_chunk,
    'method.isBlank.v1' => \&_emit_method_isBlank,
    'method.size.v1' => \&_emit_method_size,
    'method.push.v1' => \&_emit_method_push,
    'method.last.v1' => \&_emit_method_last,
    'method.any.v1' => \&_emit_method_any,
    'method.max.v1' => \&_emit_method_max,
    'method.slice.v1' => \&_emit_method_slice,
    'method.index.v1' => \&_emit_method_index,
    'method.members.v1' => \&_emit_method_members,
    'method.insert.v1' => \&_emit_method_insert,
    'method.at.v1' => \&_emit_method_at,
    'method.log.v1' => \&_emit_method_log,
    'method.count.v1' => \&_emit_method_count,
    'method.filter.v1' => \&_emit_method_filter,
    'method.neighbours.v1' => \&_emit_method_neighbours,
    'method.sort.v1' => \&_emit_method_sort,
    'method.sortBy.v1' => \&_emit_method_sortBy,
    'method.all.v1' => \&_emit_method_all,
    'method.map.v1' => \&_emit_method_map,
    'method.reduce.v1' => \&_emit_method_reduce,
    'method.assert.v1' => \&_emit_method_assert,
    'method.scan.v1' => \&_emit_method_scan,
);

sub _emit_expr_by_backend_emitter {
    my ($emitter_id, $expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv) = @_;
    my $emitter = $EXPR_BACKEND_EMITTERS{$emitter_id // ''};
    return undef if !defined $emitter;
    return $emitter->($expr, $ctx, $meta, $target, $args_ref, $recv_expr, $recv);
}


require MetaC::Backend::ExprEmittersBuiltins;
require MetaC::Backend::ExprEmittersMethods;
require MetaC::Backend::ExprEmittersCollections;
require MetaC::Backend::ExprEmittersCallbacks;

1;
