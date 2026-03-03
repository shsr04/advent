package MetaC::Backend::RuntimeHelpersExtra;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(emit_runtime_helpers_extra);

sub _emit_block {
    my ($out, $block) = @_;
    return if !defined($block) || $block eq '';
    my @lines = split /\n/, $block;
    push @$out, @lines;
}

sub emit_runtime_helpers_extra {
    my ($out, $helpers) = @_;
    my %h = %{ $helpers // {} };
    if ($h{list_list_i64}) {
        _emit_block($out, <<'C');
struct metac_list_list_i64 { int64_t len; int64_t cap; struct metac_list_i64 data[256]; };
static struct metac_list_list_i64 metac_list_list_i64_empty(void) {
  struct metac_list_list_i64 out; out.len = 0; out.cap = 256; return out;
}
static struct metac_list_list_i64 metac_list_list_i64_from_array(const struct metac_list_i64 *items, int64_t n) {
  struct metac_list_list_i64 out = metac_list_list_i64_empty();
  if (n < 0) n = 0;
  if (n > out.cap) n = out.cap;
  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];
  out.len = n;
  return out;
}
static int64_t metac_list_list_i64_push(struct metac_list_list_i64 *l, struct metac_list_i64 v) {
  if (!l) return 0;
  if (l->len < l->cap) l->data[l->len++] = v;
  return l->len;
}
static int64_t metac_list_list_i64_size(const struct metac_list_list_i64 *l) {
  return l ? l->len : 0;
}
static struct metac_list_i64 metac_list_list_i64_get(const struct metac_list_list_i64 *l, int64_t idx) {
  if (!l || idx < 0 || idx >= l->len) return metac_list_i64_empty();
  return l->data[idx];
}
C
        if ($h{method_sortby_pair}) {
            push @$out, 'static struct metac_list_list_i64 metac_method_sortby_pair_lex(struct metac_list_list_i64 recv) {';
            push @$out, '  struct metac_list_list_i64 out = recv;';
            push @$out, '  for (int64_t i = 0; i < out.len; ++i) {';
            push @$out, '    for (int64_t j = i + 1; j < out.len; ++j) {';
            push @$out, '      struct metac_list_i64 a = out.data[i];';
            push @$out, '      struct metac_list_i64 b = out.data[j];';
            push @$out, '      int64_t a0 = a.len > 0 ? a.data[0] : 0;';
            push @$out, '      int64_t b0 = b.len > 0 ? b.data[0] : 0;';
            push @$out, '      int64_t a1 = a.len > 1 ? a.data[1] : 0;';
            push @$out, '      int64_t b1 = b.len > 1 ? b.data[1] : 0;';
            push @$out, '      if (a0 > b0 || (a0 == b0 && a1 > b1)) {';
            push @$out, '        struct metac_list_i64 t = out.data[i];';
            push @$out, '        out.data[i] = out.data[j];';
            push @$out, '        out.data[j] = t;';
            push @$out, '      }';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
    }

    if ($h{any_range_contains}) {
        push @$out, 'static int metac_any_range_contains(const struct metac_list_list_i64 *ranges, int64_t value) {';
        push @$out, '  if (!ranges) return 0;';
        push @$out, '  for (int64_t i = 0; i < ranges->len; ++i) {';
        push @$out, '    struct metac_list_i64 r = ranges->data[i];';
        push @$out, '    if (r.len >= 2 && r.data[0] <= value && value <= r.data[1]) return 1;';
        push @$out, '  }';
        push @$out, '  return 0;';
        push @$out, '}';
    }

    if ($h{method_match}) {
        push @$out, 'static struct metac_list_str metac_method_match(const char *text, const char *pattern) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (!text || !pattern) { metac_last_error = 1; return out; }';
        push @$out, '  regex_t re;';
        push @$out, '  int rc = regcomp(&re, pattern, REG_EXTENDED);';
        push @$out, '  if (rc != 0) { metac_last_error = 1; return out; }';
        push @$out, '  regmatch_t m[32];';
        push @$out, '  rc = regexec(&re, text, 32, m, 0);';
        push @$out, '  if (rc != 0) { regfree(&re); metac_last_error = 1; return out; }';
        push @$out, '  static char slots[64][256];';
        push @$out, '  static int slot_head = 0;';
        push @$out, '  for (int i = 1; i < 32 && out.len < out.cap; ++i) {';
        push @$out, '    if (m[i].rm_so < 0 || m[i].rm_eo < m[i].rm_so) break;';
        push @$out, '    int idx = slot_head++ % 64;';
        push @$out, '    int n = (int)(m[i].rm_eo - m[i].rm_so);';
        push @$out, '    if (n < 0) n = 0;';
        push @$out, '    if (n > 255) n = 255;';
        push @$out, '    memcpy(slots[idx], text + m[i].rm_so, (size_t)n);';
        push @$out, '    slots[idx][n] = 0;';
        push @$out, '    out.data[out.len++] = slots[idx];';
        push @$out, '  }';
        push @$out, '  if (out.len == 0 && m[0].rm_so >= 0 && m[0].rm_eo >= m[0].rm_so && out.len < out.cap) {';
        push @$out, '    int idx = slot_head++ % 64;';
        push @$out, '    int n = (int)(m[0].rm_eo - m[0].rm_so);';
        push @$out, '    if (n < 0) n = 0;';
        push @$out, '    if (n > 255) n = 255;';
        push @$out, '    memcpy(slots[idx], text + m[0].rm_so, (size_t)n);';
        push @$out, '    slots[idx][n] = 0;';
        push @$out, '    out.data[out.len++] = slots[idx];';
        push @$out, '  }';
        push @$out, '  regfree(&re);';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
    }

    if ($h{string_index}) {
        push @$out, 'static int64_t metac_string_code_at(const char *s, int64_t idx) {';
        push @$out, '  if (!s || idx < 0) return 0;';
        push @$out, '  int64_t pos = 0;';
        push @$out, '  for (size_t i = 0; s[i]; ) {';
        push @$out, '    unsigned char b0 = (unsigned char)s[i];';
        push @$out, '    int64_t cp = 0;';
        push @$out, '    size_t w = 1;';
        push @$out, '    if ((b0 & 0x80) == 0x00) {';
        push @$out, '      cp = b0;';
        push @$out, '      w = 1;';
        push @$out, '    } else if ((b0 & 0xE0) == 0xC0 && s[i + 1]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      cp = ((int64_t)(b0 & 0x1F) << 6) | (int64_t)(b1 & 0x3F);';
        push @$out, '      w = 2;';
        push @$out, '    } else if ((b0 & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      unsigned char b2 = (unsigned char)s[i + 2];';
        push @$out, '      cp = ((int64_t)(b0 & 0x0F) << 12) | ((int64_t)(b1 & 0x3F) << 6) | (int64_t)(b2 & 0x3F);';
        push @$out, '      w = 3;';
        push @$out, '    } else if ((b0 & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) {';
        push @$out, '      unsigned char b1 = (unsigned char)s[i + 1];';
        push @$out, '      unsigned char b2 = (unsigned char)s[i + 2];';
        push @$out, '      unsigned char b3 = (unsigned char)s[i + 3];';
        push @$out, '      cp = ((int64_t)(b0 & 0x07) << 18) | ((int64_t)(b1 & 0x3F) << 12) | ((int64_t)(b2 & 0x3F) << 6) | (int64_t)(b3 & 0x3F);';
        push @$out, '      w = 4;';
        push @$out, '    } else {';
        push @$out, '      cp = b0;';
        push @$out, '      w = 1;';
        push @$out, '    }';
        push @$out, '    if (pos == idx) return cp;';
        push @$out, '    i += w;';
        push @$out, '    ++pos;';
        push @$out, '  }';
        push @$out, '  return 0;';
        push @$out, '}';
    }

    if ($h{method_members}) {
        push @$out, 'static struct metac_list_i64 metac_method_members(struct metac_list_i64 matrix_like) {';
        push @$out, '  return matrix_like;';
        push @$out, '}';
        if ($h{list_str}) {
            push @$out, 'static struct metac_list_str metac_method_members_str(struct metac_list_str matrix_like) {';
            push @$out, '  return matrix_like;';
            push @$out, '}';
        }
    }
    if ($h{method_insert}) {
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64(struct metac_list_i64 *recv, int64_t value, int64_t idx) {';
        push @$out, '  if (!recv) return metac_list_i64_empty();';
        push @$out, '  if (idx >= 0 && idx < recv->len) recv->data[idx] = value;';
        push @$out, '  return *recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_value(struct metac_list_i64 recv, int64_t value, int64_t idx) {';
        push @$out, '  if (idx >= 0 && idx < recv.len) recv.data[idx] = value;';
        push @$out, '  return recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix(struct metac_list_i64 *recv, int64_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  if (!recv) return metac_list_i64_empty();';
        push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value;';
        push @$out, '  return *recv;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix_value(struct metac_list_i64 recv, int64_t value, struct metac_list_i64 idx) {';
        push @$out, '  (void)idx;';
        push @$out, '  if (recv.len < recv.cap) recv.data[recv.len++] = value;';
        push @$out, '  return recv;';
        push @$out, '}';
        if ($h{matrix_meta}) {
            push @$out, 'static struct metac_list_i64 metac_method_insert_i64_matrix_meta(struct metac_list_i64 *recv, int64_t value, struct metac_list_i64 idx, struct metac_matrix_meta *meta) {';
            push @$out, '  if (!recv) return metac_list_i64_empty();';
            push @$out, '  if (!metac_matrix_apply_index(meta, idx)) return *recv;';
            push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value;';
            push @$out, '  return *recv;';
            push @$out, '}';
        }
        if ($h{list_str}) {
            push @$out, 'static struct metac_list_str metac_method_insert_str(struct metac_list_str *recv, const char *value, int64_t idx) {';
            push @$out, '  if (!recv) return metac_list_str_empty();';
            push @$out, '  if (idx >= 0 && idx < recv->len) recv->data[idx] = value ? value : "";';
            push @$out, '  return *recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_value(struct metac_list_str recv, const char *value, int64_t idx) {';
            push @$out, '  if (idx >= 0 && idx < recv.len) recv.data[idx] = value ? value : "";';
            push @$out, '  return recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_matrix(struct metac_list_str *recv, const char *value, struct metac_list_i64 idx) {';
            push @$out, '  (void)idx;';
            push @$out, '  if (!recv) return metac_list_str_empty();';
            push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value ? value : "";';
            push @$out, '  return *recv;';
            push @$out, '}';
            push @$out, 'static struct metac_list_str metac_method_insert_str_matrix_value(struct metac_list_str recv, const char *value, struct metac_list_i64 idx) {';
            push @$out, '  (void)idx;';
            push @$out, '  if (recv.len < recv.cap) recv.data[recv.len++] = value ? value : "";';
            push @$out, '  return recv;';
            push @$out, '}';
            if ($h{matrix_meta}) {
                push @$out, 'static struct metac_list_str metac_method_insert_str_matrix_meta(struct metac_list_str *recv, const char *value, struct metac_list_i64 idx, struct metac_matrix_meta *meta) {';
                push @$out, '  if (!recv) return metac_list_str_empty();';
                push @$out, '  if (!metac_matrix_apply_index(meta, idx)) return *recv;';
                push @$out, '  if (recv->len < recv->cap) recv->data[recv->len++] = value ? value : "";';
                push @$out, '  return *recv;';
                push @$out, '}';
            }
        }
    }
    if ($h{method_filter}) {
        push @$out, 'static struct metac_list_i64 metac_method_filter_identity(struct metac_list_i64 recv) {';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_filter_str}) {
        push @$out, 'static struct metac_list_str metac_method_filter_identity_str(struct metac_list_str recv) {';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{filter_str_eq}) {
        push @$out, 'static struct metac_list_str metac_filter_str_eq(struct metac_list_str recv, const char *needle) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  const char *target = needle ? needle : "";';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    const char *v = recv.data[i] ? recv.data[i] : "";';
        push @$out, '    if (strcmp(v, target) == 0) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_mod_ne}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_mod_ne(struct metac_list_i64 recv, int64_t mod, int64_t neq) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (mod == 0) return out;';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    if ((recv.data[i] % mod) != neq) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_eq2}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_eq2(struct metac_list_i64 recv, int64_t a, int64_t b) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    int64_t v = recv.data[i];';
        push @$out, '    if (v == a || v == b) out.data[out.len++] = v;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_mod_eq}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_mod_eq(struct metac_list_i64 recv, int64_t mod, int64_t eqv) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (mod == 0) return out;';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    if ((recv.data[i] % mod) == eqv) out.data[out.len++] = recv.data[i];';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{filter_i64_value_mod_eq}) {
        push @$out, 'static struct metac_list_i64 metac_filter_i64_value_mod_eq(struct metac_list_i64 recv, int64_t value, int64_t eqv) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  for (int64_t i = 0; i < recv.len && out.len < out.cap; ++i) {';
        push @$out, '    int64_t d = recv.data[i];';
        push @$out, '    if (d != 0 && (value % d) == eqv) out.data[out.len++] = d;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_count}) {
        push @$out, 'static int64_t metac_method_count(struct metac_list_i64 recv) {';
        push @$out, '  return recv.len;';
        push @$out, '}';
    }
    if ($h{method_max_i64}) {
        push @$out, 'static int64_t metac_method_max_i64(const struct metac_list_i64 *recv) {';
        push @$out, '  if (!recv || recv->len <= 0) { metac_last_member_index = 0; return 0; }';
        push @$out, '  int64_t best = recv->data[0];';
        push @$out, '  int64_t best_i = 0;';
        push @$out, '  for (int64_t i = 1; i < recv->len; ++i) {';
        push @$out, '    if (recv->data[i] > best) { best = recv->data[i]; best_i = i; }';
        push @$out, '  }';
        push @$out, '  metac_last_member_index = best_i;';
        push @$out, '  return best;';
        push @$out, '}';
    }
    if ($h{method_max_i64_value}) {
        push @$out, 'static int64_t metac_method_max_i64_value(struct metac_list_i64 recv) {';
        push @$out, '  return metac_method_max_i64(&recv);';
        push @$out, '}';
    }
    if ($h{method_max_str}) {
        push @$out, 'static int64_t metac_method_max_str(const struct metac_list_str *recv) {';
        push @$out, '  if (!recv || recv->len <= 0) { metac_last_member_index = 0; return 0; }';
        push @$out, '  int64_t best = 0;';
        push @$out, '  int64_t best_i = 0;';
        push @$out, '  for (int64_t i = 0; i < recv->len; ++i) {';
        push @$out, '    const char *s = recv->data[i] ? recv->data[i] : "0";';
        push @$out, '    int64_t v = (int64_t)strtoll(s, NULL, 10);';
        push @$out, '    if (i == 0 || v > best) { best = v; best_i = i; }';
        push @$out, '  }';
        push @$out, '  metac_last_member_index = best_i;';
        push @$out, '  return best;';
        push @$out, '}';
    }
    if ($h{method_max_str_value}) {
        push @$out, 'static int64_t metac_method_max_str_value(struct metac_list_str recv) {';
        push @$out, '  return metac_method_max_str(&recv);';
        push @$out, '}';
    }
    if ($h{method_slice_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_slice_i64(const struct metac_list_i64 *recv, int64_t start) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!recv) return out;';
        push @$out, '  if (start < 0) start = 0;';
        push @$out, '  if (start > recv->len) start = recv->len;';
        push @$out, '  for (int64_t i = start; i < recv->len && out.len < out.cap; ++i) out.data[out.len++] = recv->data[i];';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_slice_i64_value}) {
        push @$out, 'static struct metac_list_i64 metac_method_slice_i64_value(struct metac_list_i64 recv, int64_t start) {';
        push @$out, '  return metac_method_slice_i64(&recv, start);';
        push @$out, '}';
    }
    if ($h{method_slice_str}) {
        push @$out, 'static struct metac_list_str metac_method_slice_str(const struct metac_list_str *recv, int64_t start) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (!recv) return out;';
        push @$out, '  if (start < 0) start = 0;';
        push @$out, '  if (start > recv->len) start = recv->len;';
        push @$out, '  for (int64_t i = start; i < recv->len && out.len < out.cap; ++i) out.data[out.len++] = recv->data[i];';
        push @$out, '  return out;';
        push @$out, '}';
    }
    if ($h{method_slice_str_value}) {
        push @$out, 'static struct metac_list_str metac_method_slice_str_value(struct metac_list_str recv, int64_t start) {';
        push @$out, '  return metac_method_slice_str(&recv, start);';
        push @$out, '}';
    }
    if ($h{method_log_list_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_log_list_i64(struct metac_list_i64 recv) {';
        push @$out, '  metac_builtin_log_str(metac_list_i64_render(&recv));';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_log_list_str}) {
        push @$out, 'static struct metac_list_str metac_method_log_list_str(struct metac_list_str recv) {';
        push @$out, '  metac_builtin_log_str(metac_list_str_render(&recv));';
        push @$out, '  return recv;';
        push @$out, '}';
    }
    if ($h{method_count_str}) {
        push @$out, 'static int64_t metac_method_count_str(struct metac_list_str recv) {';
        push @$out, '  return recv.len;';
        push @$out, '}';
    }
    if ($h{method_neighbours_str}) {
        push @$out, 'static struct metac_list_str metac_method_neighbours_str(const char *value) {';
        push @$out, '  (void)value;';
        push @$out, '  return metac_list_str_from_array((const char *[]){"@"}, 1);';
        push @$out, '}';
    }
    if ($h{method_neighbours_i64}) {
        push @$out, 'static struct metac_list_i64 metac_method_neighbours_i64(struct metac_list_i64 matrix_like, struct metac_list_i64 idx) {';
        push @$out, '  (void)matrix_like;';
        push @$out, '  (void)idx;';
        push @$out, '  return metac_list_i64_from_array((int64_t[]){0, 0}, 2);';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_method_neighbours_i64_value(int64_t member_value) {';
        push @$out, '  return metac_list_i64_from_array((int64_t[]){member_value}, 1);';
        push @$out, '}';
    }

    push @$out, '' if %h;
}

1;
