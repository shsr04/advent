package MetaC::HIR::TypedNodes;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    stmt_to_payload
    step_payload_to_stmt
);

my %EXPR_KINDS = map { $_ => 1 } qw(
  num str bool null ident list_literal unary binop index try call method_call lambda1 lambda2 call_expr
);
my %STMT_KINDS = map { $_ => 1 } qw(
  let const const_typed assign typed_assign assign_op incdec
  destructure_match destructure_list destructure_split_or
  expr_stmt expr_stmt_try const_try_expr const_try_tail_expr const_or_catch const_try_chain
  if while for_each for_each_try for_lines break continue rewind return
);

sub _looks_like_expr {
    my ($v) = @_;
    return 0 if !defined($v) || ref($v) ne 'HASH';
    my $kind = $v->{kind} // '';
    return $EXPR_KINDS{$kind} ? 1 : 0;
}

sub _looks_like_stmt {
    my ($v) = @_;
    return 0 if !defined($v) || ref($v) ne 'HASH';
    my $kind = $v->{kind} // '';
    return $STMT_KINDS{$kind} ? 1 : 0;
}

sub _encode_misc {
    my ($v) = @_;
    return _encode_expr_node($v) if _looks_like_expr($v);
    return _encode_stmt_node($v) if _looks_like_stmt($v);
    if (ref($v) eq 'ARRAY') {
        return [ map { _encode_misc($_) } @$v ];
    }
    if (ref($v) eq 'HASH') {
        my %out;
        for my $k (keys %$v) {
            $out{$k} = _encode_misc($v->{$k});
        }
        return \%out;
    }
    return $v;
}

sub _decode_misc {
    my ($v) = @_;
    return _decode_expr_node($v) if ref($v) eq 'HASH' && ($v->{node_kind} // '') eq 'Expr';
    return _decode_stmt_node($v) if ref($v) eq 'HASH' && ($v->{node_kind} // '') eq 'Stmt';
    if (ref($v) eq 'ARRAY') {
        return [ map { _decode_misc($_) } @$v ];
    }
    if (ref($v) eq 'HASH') {
        my %out;
        for my $k (keys %$v) {
            $out{$k} = _decode_misc($v->{$k});
        }
        return \%out;
    }
    return $v;
}

sub _encode_expr_node {
    my ($expr) = @_;
    my %fields;
    for my $k (keys %{$expr // {}}) {
        next if $k eq 'kind';
        $fields{$k} = _encode_misc($expr->{$k});
    }
    return {
        node_kind => 'Expr',
        expr_kind => $expr->{kind} // '',
        fields    => \%fields,
    };
}

sub _decode_expr_node {
    my ($node) = @_;
    my %expr = (kind => ($node->{expr_kind} // ''));
    my $fields = $node->{fields};
    if (defined($fields) && ref($fields) eq 'HASH') {
        for my $k (keys %$fields) {
            $expr{$k} = _decode_misc($fields->{$k});
        }
    }
    return \%expr;
}

sub _encode_stmt_node {
    my ($stmt) = @_;
    my %fields;
    for my $k (keys %{$stmt // {}}) {
        next if $k eq 'kind' || $k eq 'line';
        $fields{$k} = _encode_misc($stmt->{$k});
    }
    return {
        node_kind => 'Stmt',
        stmt_kind => $stmt->{kind} // '',
        line      => $stmt->{line} // 0,
        fields    => \%fields,
    };
}

sub _decode_stmt_node {
    my ($node) = @_;
    my %stmt = (
        kind => ($node->{stmt_kind} // ''),
        line => ($node->{line} // 0),
    );
    my $fields = $node->{fields};
    if (defined($fields) && ref($fields) eq 'HASH') {
        for my $k (keys %$fields) {
            $stmt{$k} = _decode_misc($fields->{$k});
        }
    }
    return \%stmt;
}

sub stmt_to_payload {
    my ($stmt) = @_;
    return _encode_stmt_node($stmt);
}

sub step_payload_to_stmt {
    my ($payload) = @_;
    return undef if !defined($payload) || ref($payload) ne 'HASH';
    return undef if ($payload->{node_kind} // '') ne 'Stmt';
    my $stmt = _decode_stmt_node($payload);
    return undef if !defined($stmt->{kind}) || $stmt->{kind} eq '';
    return $stmt;
}

1;
