package MetaC::Backend::CTypeFactory;
use strict;
use warnings;
use Exporter 'import';

use MetaC::Backend::CTypeRegistry qw(
    ad_hoc_c_type_for_normalized
    is_ad_hoc_c_type
    type_to_c_type
);
use MetaC::HIR::TypeRegistry qw(canonical_scalar_base);
use MetaC::TypeSpec qw(
    normalize_type_annotation
    is_array_type
    array_type_meta
    is_union_type
    union_member_types
    is_matrix_type
    matrix_type_meta
    is_matrix_member_list_type
    matrix_member_list_meta
);

our @EXPORT_OK = qw(
    c_type_helper_keys_for_type
    c_type_default_expr_for_type
    c_type_collection_ops_for_type
    emit_c_type_factory_helpers
);

my %LEGACY_HELPERS_FOR_C = (
    'struct metac_list_i64'      => [qw(list_i64)],
    'struct metac_list_str'      => [qw(list_str)],
    'struct metac_list_list_i64' => [qw(list_i64 list_list_i64)],
);

sub _collection_elem_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    if (is_array_type($t)) {
        my $meta = array_type_meta($t);
        return $meta->{elem} if defined($meta);
    }
    if (is_matrix_type($t)) {
        my $meta = matrix_type_meta($t);
        return $meta->{elem} if defined($meta);
    }
    if (is_matrix_member_list_type($t)) {
        my $meta = matrix_member_list_meta($t);
        return $meta->{elem} if defined($meta);
    }
    return undef;
}

sub _is_collection_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    return 1 if is_array_type($t) || is_matrix_type($t) || is_matrix_member_list_type($t);
    return 0;
}

sub _is_factory_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    return 1 if _is_collection_type($t);
    return 1 if is_union_type($t) && is_ad_hoc_c_type(type_to_c_type($t));
    return 0;
}

sub _factory_key {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    return undef if $t eq '' || !_is_factory_type($t);
    my $c = type_to_c_type($t);
    return undef if !is_ad_hoc_c_type($c);
    return "ctype:$t";
}

sub _stem_for_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    my $c = ad_hoc_c_type_for_normalized($t);
    $c =~ s/^struct\s+//;
    return $c;
}

sub c_type_default_expr_for_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    my $c = type_to_c_type($t);
    return '""' if defined($c) && $c eq 'const char *';
    return '0' if !defined($c) || $c eq '';
    return 'metac_list_i64_empty()' if $c eq 'struct metac_list_i64';
    return 'metac_list_str_empty()' if $c eq 'struct metac_list_str';
    return 'metac_list_list_i64_empty()' if $c eq 'struct metac_list_list_i64';
    if (is_ad_hoc_c_type($c)) {
        my $ops = c_type_collection_ops_for_type($t);
        return $ops->{empty} . '()' if defined($ops);
        return '(' . $c . '){0}';
    }
    return '(struct metac_error){0}' if $c eq 'struct metac_error';
    return '0';
}

sub c_type_collection_ops_for_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    my $key = _factory_key($t);
    return undef if !defined($key);
    my $elem_t = _collection_elem_type($t);
    return undef if !defined($elem_t) || $elem_t eq '';
    my $c = type_to_c_type($t);
    my $elem_c = type_to_c_type($elem_t);
    return undef if !defined($c) || !defined($elem_c);
    my $stem = _stem_for_type($t);
    return {
        key => $key,
        normalized_type => $t,
        elem_type => $elem_t,
        c_type => $c,
        elem_c_type => $elem_c,
        stem => $stem,
        empty => $stem . '_empty',
        from_array => $stem . '_from_array',
        push => $stem . '_push',
        size => $stem . '_size',
        size_value => $stem . '_size_value',
        get => $stem . '_get',
        elem_default => c_type_default_expr_for_type($elem_t),
    };
}

sub c_type_helper_keys_for_type {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    return [] if $t eq '';
    my @keys;
    if (is_union_type($t)) {
        for my $member (@{ union_member_types($t) }) {
            push @keys, @{ c_type_helper_keys_for_type($member) };
        }
    }
    my $elem_t = _collection_elem_type($t);
    push @keys, @{ c_type_helper_keys_for_type($elem_t) } if defined($elem_t);
    my $c = type_to_c_type($t);
    push @keys, @{ $LEGACY_HELPERS_FOR_C{$c} // [] } if defined($c);
    my $key = _factory_key($t);
    push @keys, $key if defined($key);
    my %seen;
    return [ grep { defined($_) && $_ ne '' && !$seen{$_}++ } @keys ];
}

sub _helper_type_from_key {
    my ($key) = @_;
    return undef if !defined($key) || $key !~ /^ctype:(.+)$/;
    return $1;
}

sub _type_depth {
    my ($type) = @_;
    my $t = normalize_type_annotation($type // '');
    if (is_union_type($t)) {
        my $max = 0;
        for my $member (@{ union_member_types($t) }) {
            my $d = _type_depth($member);
            $max = $d if $d > $max;
        }
        return 1 + $max;
    }
    my $elem = _collection_elem_type($type);
    return 0 if !defined($elem);
    return 1 + _type_depth($elem);
}

sub _field_name {
    my ($idx) = @_;
    return 'v' . int($idx // 0);
}

sub _emit_union_helper {
    my ($out, $type) = @_;
    my $t = normalize_type_annotation($type // '');
    return 0 if !is_union_type($t);
    my $c = type_to_c_type($t);
    return 0 if !is_ad_hoc_c_type($c);
    my @members = @{ union_member_types($t) };
    push @$out, "$c {";
    push @$out, "  int tag;";
    for my $i (0 .. $#members) {
        my $member_c = type_to_c_type($members[$i]);
        next if !defined($member_c) || $member_c eq '';
        push @$out, "  $member_c " . _field_name($i) . ";";
    }
    push @$out, "};";
    return 1;
}

sub emit_c_type_factory_helpers {
    my ($out, $helpers) = @_;
    my @types = grep { defined($_) } map { _helper_type_from_key($_) } keys %{ $helpers // {} };
    @types = sort { _type_depth($a) <=> _type_depth($b) || $a cmp $b } @types;
    for my $type (@types) {
        next if _emit_union_helper($out, $type);
        my $ops = c_type_collection_ops_for_type($type);
        next if !defined($ops);
        my $c = $ops->{c_type};
        my $stem = $ops->{stem};
        my $elem_c = $ops->{elem_c_type};
        my $elem_default = $ops->{elem_default};
        my $aggregate_elem = ($elem_c =~ /^struct\s+/ && $elem_c ne 'struct metac_error') ? 1 : 0;
        if ($aggregate_elem) {
            push @$out, "static $elem_c *${stem}_allocs[8192];";
            push @$out, "static int64_t ${stem}_allocs_len = 0;";
            push @$out, "static int ${stem}_allocs_free_registered = 0;";
            push @$out, "static void ${stem}_free_allocs(void) {";
            push @$out, "  for (int64_t i = 0; i < ${stem}_allocs_len; ++i) {";
            push @$out, "    if (${stem}_allocs[i]) free(${stem}_allocs[i]);";
            push @$out, "    ${stem}_allocs[i] = NULL;";
            push @$out, "  }";
            push @$out, "  ${stem}_allocs_len = 0;";
            push @$out, "}";
            push @$out, "static $elem_c *${stem}_clone_item($elem_c v) {";
            push @$out, "  if (!${stem}_allocs_free_registered) {";
            push @$out, "    atexit(${stem}_free_allocs);";
            push @$out, "    ${stem}_allocs_free_registered = 1;";
            push @$out, "  }";
            push @$out, "  $elem_c *p = ($elem_c *)malloc(sizeof($elem_c));";
            push @$out, "  if (!p) return NULL;";
            push @$out, "  *p = v;";
            push @$out, "  if (${stem}_allocs_len < 8192) ${stem}_allocs[${stem}_allocs_len++] = p;";
            push @$out, "  return p;";
            push @$out, "}";
        }
        my $slot_c = $aggregate_elem ? "$elem_c *" : $elem_c;
        push @$out, "$c { int64_t len; int64_t cap; $slot_c data[256]; };";
        push @$out, "static $c ${stem}_empty(void) {";
        push @$out, "  $c out; out.len = 0; out.cap = 256; return out;";
        push @$out, "}";
        push @$out, "static $c ${stem}_from_array(const $elem_c *items, int64_t n) {";
        push @$out, "  $c out = ${stem}_empty();";
        push @$out, "  if (n < 0) n = 0;";
        push @$out, "  if (n > out.cap) n = out.cap;";
        if ($aggregate_elem) {
            push @$out, "  for (int64_t i = 0; i < n; ++i) out.data[i] = ${stem}_clone_item(items[i]);";
        } else {
            push @$out, "  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];";
        }
        push @$out, "  out.len = n;";
        push @$out, "  return out;";
        push @$out, "}";
        push @$out, "static int64_t ${stem}_push($c *l, $elem_c v) {";
        push @$out, "  if (!l) return 0;";
        if ($aggregate_elem) {
            push @$out, "  if (l->len < l->cap) l->data[l->len++] = ${stem}_clone_item(v);";
        } else {
            push @$out, "  if (l->len < l->cap) l->data[l->len++] = v;";
        }
        push @$out, "  return l->len;";
        push @$out, "}";
        push @$out, "static int64_t ${stem}_size(const $c *l) { return l ? l->len : 0; }";
        push @$out, "static int64_t ${stem}_size_value($c l) { return l.len; }";
        push @$out, "static $elem_c ${stem}_get(const $c *l, int64_t idx) {";
        push @$out, "  if (!l || idx < 0 || idx >= l->len) return $elem_default;";
        if ($aggregate_elem) {
            push @$out, "  if (!l->data[idx]) return $elem_default;";
            push @$out, "  return *l->data[idx];";
        } else {
            push @$out, "  return l->data[idx];";
        }
        push @$out, "}";
    }
    push @$out, '' if @types;
}

1;
