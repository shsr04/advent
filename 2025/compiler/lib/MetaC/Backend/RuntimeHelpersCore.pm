package MetaC::Backend::RuntimeHelpersCore;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(emit_runtime_helpers_core);

sub _emit_block {
    my ($out, $block) = @_;
    return if !defined($block) || $block eq '';
    my @lines = split /\n/, $block;
    push @$out, @lines;
}

sub emit_runtime_helpers_core {
    my ($out, $helpers) = @_;
    my %h = %{ $helpers // {} };

    push @$out, 'static int64_t metac_last_member_index = 0;' if $h{member_index};
    push @$out, 'static int metac_last_error = 0;' if $h{error_flag};
    push @$out, 'static const char *metac_last_error_message = "";'
      if $h{error_flag} || $h{error_message};
    if ($h{stdin_read}) {
        _emit_block($out, <<'C');
static const char *metac_stdin_read_all(void) {
  static char buf[65536];
  static int loaded = 0;
  if (!loaded) {
    size_t n = fread(buf, 1, sizeof(buf) - 1, stdin);
    buf[n] = 0;
    loaded = 1;
  }
  return buf;
}
C
    }

    if ($h{parse_number}) {
        _emit_block($out, <<'C');
static int64_t metac_builtin_parse_number(const char *s) {
  if (!s) return 0;
  char *end = NULL;
  long long v = strtoll(s, &end, 10);
  if (end == s) { metac_last_error = 1; metac_last_error_message = "parse number failed"; return 0; }
  metac_last_error = 0;
  metac_last_error_message = "";
  return (int64_t)v;
}
C
    }
    if ($h{builtin_error}) {
        push @$out, 'static int64_t metac_builtin_error(const char *msg) {';
        push @$out, '  static char buf[1024];';
        push @$out, '  const char *m = msg ? msg : "";';
        push @$out, '  snprintf(buf, sizeof(buf), "%s (line 0: )", m);';
        push @$out, '  metac_last_error = 1;';
        push @$out, '  metac_last_error_message = buf;';
        push @$out, '  return 0;';
        push @$out, '}';
    }
    push @$out, 'static int64_t metac_builtin_log_i64(int64_t v) { printf("%lld\\n", (long long)v); return v; }'
      if $h{log_i64};
    push @$out, 'static double metac_builtin_log_f64(double v) { printf("%.15g\\n", v); return v; }'
      if $h{log_f64};
    push @$out, 'static int metac_builtin_log_bool(int v) { int b = v ? 1 : 0; printf("%d\\n", b); return b; }'
      if $h{log_bool};
    push @$out, 'static const char *metac_builtin_log_str(const char *v) { const char *s = v ? v : ""; printf("%s\\n", s); return s; }'
      if $h{log_str};

    if ($h{fmt}) {
        _emit_block($out, <<'C');
static const char *metac_format(const char *fmt, ...) {
  static char buf[4096];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  return buf;
}
C
    }

    if ($h{method_size}) {
        push @$out, 'static int64_t metac_method_size(const char *s) {';
        push @$out, '  if (!s) return 0;';
        push @$out, '  int64_t n = 0;';
        push @$out, '  for (size_t i = 0; s[i]; ) {';
        push @$out, '    unsigned char b = (unsigned char)s[i];';
        push @$out, '    size_t w = 1;';
        push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
        push @$out, '    else if ((b & 0xE0) == 0xC0 && s[i + 1]) w = 2;';
        push @$out, '    else if ((b & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) w = 3;';
        push @$out, '    else if ((b & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) w = 4;';
        push @$out, '    i += w;';
        push @$out, '    ++n;';
        push @$out, '  }';
        push @$out, '  return n;';
        push @$out, '}';
    }
    if ($h{constrained_string_assign}) {
        push @$out, 'static const char *metac_constrained_string_assign(const char *v, int64_t need) {';
        push @$out, '  const char *s = v ? v : "";';
        push @$out, '  if (need >= 0 && (int64_t)strlen(s) != need) {';
        push @$out, '    metac_last_error = 1;';
        push @$out, '    metac_last_error_message = "size constraint failed";';
        push @$out, '    exit(2);';
        push @$out, '  }';
        push @$out, '  return s;';
        push @$out, '}';
    }
    push @$out, 'static int64_t metac_method_push(int64_t recv, int64_t value) { (void)value; return recv; }'
      if $h{method_push};

    if ($h{method_isblank}) {
        push @$out, 'static int metac_method_isblank(const char *s) {';
        push @$out, '  if (!s) return 1;';
        push @$out, '  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {';
        push @$out, '    if (!isspace(*p)) return 0;';
        push @$out, '  }';
        push @$out, '  return 1;';
        push @$out, '}';
    }

    if ($h{list_i64}) {
        push @$out, 'struct metac_list_i64 { int64_t len; int64_t cap; int64_t data[1024]; };';
        push @$out, 'static struct metac_list_i64 metac_list_i64_empty(void) {';
        push @$out, '  struct metac_list_i64 out; out.len = 0; out.cap = 1024; return out;';
        push @$out, '}';
        push @$out, 'static struct metac_list_i64 metac_list_i64_from_array(const int64_t *items, int64_t n) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > out.cap) n = out.cap;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];';
        push @$out, '  out.len = n;';
        push @$out, '  return out;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_i64_push(struct metac_list_i64 *l, int64_t v) {';
        push @$out, '  if (!l) return 0;';
        push @$out, '  if (l->len < l->cap) l->data[l->len++] = v;';
        push @$out, '  return l->len;';
        push @$out, '}';
        push @$out, 'static int64_t metac_list_i64_size(const struct metac_list_i64 *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
        if ($h{list_i64_size_value}) {
            push @$out, 'static int64_t metac_list_i64_size_value(struct metac_list_i64 l) {';
            push @$out, '  return l.len;';
            push @$out, '}';
        }
        push @$out, 'static int64_t metac_list_i64_get(const struct metac_list_i64 *l, int64_t idx) {';
        push @$out, '  if (!l || idx < 0 || idx >= l->len) return 0;';
        push @$out, '  return l->data[idx];';
        push @$out, '}';
        if ($h{list_i64_render}) {
            push @$out, 'static const char *metac_list_i64_render(const struct metac_list_i64 *l) {';
            push @$out, '  static char buf[4096];';
            push @$out, '  int off = 0;';
            push @$out, '  off += snprintf(buf + off, sizeof(buf) - (size_t)off, "[");';
            push @$out, '  int64_t n = l ? l->len : 0;';
            push @$out, '  for (int64_t i = 0; i < n && off < (int)sizeof(buf); ++i) {';
            push @$out, '    off += snprintf(buf + off, sizeof(buf) - (size_t)off, "%s%lld", (i ? ", " : ""), (long long)l->data[i]);';
            push @$out, '  }';
            push @$out, '  snprintf(buf + off, sizeof(buf) - (size_t)off, "]");';
            push @$out, '  return buf;';
            push @$out, '}';
        }
        if ($h{seq_i64}) {
            push @$out, 'static struct metac_list_i64 metac_builtin_seq_i64(int64_t start, int64_t end) {';
            push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
            push @$out, '  if (end < start) return out;';
            push @$out, '  for (int64_t v = start; v <= end && out.len < out.cap; ++v) out.data[out.len++] = v;';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{last_index_i64}) {
            push @$out, 'static int64_t metac_builtin_last_index_i64(struct metac_list_i64 v) {';
            push @$out, '  if (v.len <= 0) return -1;';
            push @$out, '  return v.len - 1;';
            push @$out, '}';
        }
        if ($h{last_value_i64}) {
            push @$out, 'static int64_t metac_builtin_last_value_i64(struct metac_list_i64 v) {';
            push @$out, '  if (v.len <= 0) return 0;';
            push @$out, '  return v.data[v.len - 1];';
            push @$out, '}';
        }
        if ($h{sort_i64}) {
            push @$out, 'static struct metac_list_i64 metac_last_sort_indices = {0};';
            push @$out, 'static struct metac_list_i64 metac_sort_i64_with_index(struct metac_list_i64 recv) {';
            push @$out, '  struct metac_list_i64 out = recv;';
            push @$out, '  metac_last_sort_indices = metac_list_i64_empty();';
            push @$out, '  for (int64_t i = 0; i < out.len && i < metac_last_sort_indices.cap; ++i) {';
            push @$out, '    metac_last_sort_indices.data[i] = i;';
            push @$out, '  }';
            push @$out, '  metac_last_sort_indices.len = out.len;';
            push @$out, '  for (int64_t i = 0; i < out.len; ++i) {';
            push @$out, '    for (int64_t j = i + 1; j < out.len; ++j) {';
            push @$out, '      if (out.data[j] > out.data[i]) {';
            push @$out, '        int64_t tv = out.data[i]; out.data[i] = out.data[j]; out.data[j] = tv;';
            push @$out, '        int64_t ti = metac_last_sort_indices.data[i];';
            push @$out, '        metac_last_sort_indices.data[i] = metac_last_sort_indices.data[j];';
            push @$out, '        metac_last_sort_indices.data[j] = ti;';
            push @$out, '      }';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
            push @$out, 'static int64_t metac_sort_index_at(int64_t sorted_pos) {';
            push @$out, '  if (sorted_pos < 0 || sorted_pos >= metac_last_sort_indices.len) return sorted_pos;';
            push @$out, '  return metac_last_sort_indices.data[sorted_pos];';
            push @$out, '}';
        }
    }

    if ($h{matrix_meta}) {
        push @$out, 'struct metac_matrix_meta {';
        push @$out, '  int64_t dim;';
        push @$out, '  int constrained;';
        push @$out, '  int64_t fixed[16];';
        push @$out, '  int64_t extent[16];';
        push @$out, '};';
        push @$out, 'static struct metac_matrix_meta metac_matrix_meta_init(int64_t dim, const int64_t *sizes, int constrained) {';
        push @$out, '  struct metac_matrix_meta out;';
        push @$out, '  out.dim = dim;';
        push @$out, '  out.constrained = constrained ? 1 : 0;';
        push @$out, '  for (int i = 0; i < 16; ++i) { out.fixed[i] = -1; out.extent[i] = 0; }';
        push @$out, '  int64_t n = dim;';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > 16) n = 16;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) {';
        push @$out, '    int64_t s = sizes ? sizes[i] : -1;';
        push @$out, '    out.fixed[i] = s;';
        push @$out, '    out.extent[i] = s >= 0 ? s : 0;';
        push @$out, '  }';
        push @$out, '  return out;';
        push @$out, '}';
        push @$out, 'static int64_t metac_matrix_axis_size(const struct metac_matrix_meta *meta, int64_t axis) {';
        push @$out, '  if (!meta || axis < 0 || axis >= meta->dim || axis >= 16) return 0;';
        push @$out, '  int64_t fixed = meta->fixed[axis];';
        push @$out, '  return fixed >= 0 ? fixed : meta->extent[axis];';
        push @$out, '}';
        push @$out, 'static int metac_matrix_apply_index(struct metac_matrix_meta *meta, struct metac_list_i64 idx) {';
        push @$out, '  if (!meta) return 1;';
        push @$out, '  int64_t dim = meta->dim;';
        push @$out, '  if (dim < 0) dim = 0;';
        push @$out, '  if (dim > 16) dim = 16;';
        push @$out, '  if (idx.len != dim) {';
        push @$out, '    if (meta->constrained) exit(1);';
        push @$out, '    return 0;';
        push @$out, '  }';
        push @$out, '  for (int64_t i = 0; i < dim; ++i) {';
        push @$out, '    int64_t iv = idx.data[i];';
        push @$out, '    if (iv < 0) {';
        push @$out, '      if (meta->constrained) exit(1);';
        push @$out, '      return 0;';
        push @$out, '    }';
        push @$out, '    int64_t fixed = meta->fixed[i];';
        push @$out, '    if (fixed >= 0) {';
        push @$out, '      if (iv >= fixed) exit(1);';
        push @$out, '      continue;';
        push @$out, '    }';
        push @$out, '    int64_t need = iv + 1;';
        push @$out, '    if (need > meta->extent[i]) meta->extent[i] = need;';
        push @$out, '  }';
        push @$out, '  return 1;';
        push @$out, '}';
    }

    if ($h{list_str}) {
        push @$out, 'struct metac_list_str { int64_t len; int64_t cap; const char *data[1024]; };';
        push @$out, 'static struct metac_list_str metac_list_str_empty(void) {';
        push @$out, '  struct metac_list_str out; out.len = 0; out.cap = 1024; return out;';
        push @$out, '}';
        push @$out, 'static struct metac_list_str metac_list_str_from_array(const char *const *items, int64_t n) {';
        push @$out, '  struct metac_list_str out = metac_list_str_empty();';
        push @$out, '  if (n < 0) n = 0;';
        push @$out, '  if (n > out.cap) n = out.cap;';
        push @$out, '  for (int64_t i = 0; i < n; ++i) out.data[i] = items[i];';
        push @$out, '  out.len = n;';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{list_str_push}) {
            push @$out, 'static int64_t metac_list_str_push(struct metac_list_str *l, const char *v) {';
            push @$out, '  if (!l) return 0;';
            push @$out, '  if (l->len < l->cap) l->data[l->len++] = v ? v : "";';
            push @$out, '  return l->len;';
            push @$out, '}';
        }
        push @$out, 'static int64_t metac_list_str_size(const struct metac_list_str *l) {';
        push @$out, '  return l ? l->len : 0;';
        push @$out, '}';
        if ($h{list_str_get}) {
            push @$out, 'static const char *metac_list_str_get(const struct metac_list_str *l, int64_t idx) {';
            push @$out, '  if (!l || idx < 0 || idx >= l->len) return "";';
            push @$out, '  return l->data[idx] ? l->data[idx] : "";';
            push @$out, '}';
        }
        if ($h{list_str_size_value}) {
            push @$out, 'static int64_t metac_list_str_size_value(struct metac_list_str l) {';
            push @$out, '  return l.len;';
            push @$out, '}';
        }
        if ($h{list_str_render}) {
            push @$out, 'static const char *metac_list_str_render(const struct metac_list_str *l) {';
            push @$out, '  static char buf[4096];';
            push @$out, '  int off = 0;';
            push @$out, '  off += snprintf(buf + off, sizeof(buf) - (size_t)off, "[");';
            push @$out, '  int64_t n = l ? l->len : 0;';
            push @$out, '  for (int64_t i = 0; i < n && off < (int)sizeof(buf); ++i) {';
            push @$out, '    const char *s = l->data[i] ? l->data[i] : "";';
            push @$out, '    off += snprintf(buf + off, sizeof(buf) - (size_t)off, "%s%s", (i ? ", " : ""), s);';
            push @$out, '  }';
            push @$out, '  snprintf(buf + off, sizeof(buf) - (size_t)off, "]");';
            push @$out, '  return buf;';
            push @$out, '}';
        }
        if ($h{builtin_split}) {
            push @$out, 'static struct metac_list_str metac_builtin_split(const char *s, const char *delim) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s || !delim || !*delim) { metac_last_error = 1; metac_last_error_message = "split failed"; return out; }';
            push @$out, '  const char d = delim[0];';
            push @$out, '  static char buf[4096];';
            push @$out, '  size_t n = strlen(s);';
            push @$out, '  if (n >= sizeof(buf)) n = sizeof(buf) - 1;';
            push @$out, '  memcpy(buf, s, n); buf[n] = 0;';
            push @$out, '  char *start = buf;';
            push @$out, '  for (size_t i = 0; i <= n; ++i) {';
            push @$out, '    if (buf[i] == d || buf[i] == 0) {';
            push @$out, '      buf[i] = 0;';
            push @$out, '      if (out.len < out.cap) out.data[out.len++] = start;';
            push @$out, '      start = &buf[i + 1];';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  metac_last_error = 0;';
            push @$out, '  metac_last_error_message = "";';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{builtin_lines}) {
            push @$out, 'static struct metac_list_str metac_builtin_lines(const char *s) {';
            push @$out, '  struct metac_list_str out = metac_builtin_split(s, "\\n");';
            push @$out, '  if (out.len > 0) {';
            push @$out, '    const char *last = out.data[out.len - 1] ? out.data[out.len - 1] : "";';
            push @$out, '    if (last[0] == 0) out.len--;';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{method_chars}) {
            push @$out, 'static struct metac_list_str metac_method_chars(const char *s) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s) return out;';
            push @$out, '  static char pool[8192];';
            push @$out, '  size_t used = 0;';
            push @$out, '  size_t n = strlen(s);';
            push @$out, '  for (size_t i = 0; i < n && out.len < out.cap; ) {';
            push @$out, '    unsigned char b = (unsigned char)s[i];';
            push @$out, '    size_t w = 1;';
            push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
            push @$out, '    else if ((b & 0xE0) == 0xC0) w = 2;';
            push @$out, '    else if ((b & 0xF0) == 0xE0) w = 3;';
            push @$out, '    else if ((b & 0xF8) == 0xF0) w = 4;';
            push @$out, '    if (i + w > n) w = 1;';
            push @$out, '    if (used + w + 1 >= sizeof(pool)) break;';
            push @$out, '    memcpy(&pool[used], &s[i], w);';
            push @$out, '    pool[used + w] = 0;';
            push @$out, '    out.data[out.len++] = &pool[used];';
            push @$out, '    used += w + 1;';
            push @$out, '    i += w;';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{method_chunk}) {
            push @$out, 'static struct metac_list_str metac_method_chunk(const char *s, int64_t width) {';
            push @$out, '  struct metac_list_str out = metac_list_str_empty();';
            push @$out, '  if (!s || width <= 0) return out;';
            push @$out, '  static char pool[8192];';
            push @$out, '  size_t used = 0;';
            push @$out, '  size_t start = 0;';
            push @$out, '  size_t i = 0;';
            push @$out, '  int64_t count = 0;';
            push @$out, '  while (s[i] && out.len < out.cap) {';
            push @$out, '    unsigned char b = (unsigned char)s[i];';
            push @$out, '    size_t w = 1;';
            push @$out, '    if ((b & 0x80) == 0x00) w = 1;';
            push @$out, '    else if ((b & 0xE0) == 0xC0 && s[i + 1]) w = 2;';
            push @$out, '    else if ((b & 0xF0) == 0xE0 && s[i + 1] && s[i + 2]) w = 3;';
            push @$out, '    else if ((b & 0xF8) == 0xF0 && s[i + 1] && s[i + 2] && s[i + 3]) w = 4;';
            push @$out, '    i += w;';
            push @$out, '    ++count;';
            push @$out, '    if (count >= width || !s[i]) {';
            push @$out, '      size_t take = i - start;';
            push @$out, '      if (used + take + 1 >= sizeof(pool)) break;';
            push @$out, '      memcpy(&pool[used], &s[start], take);';
            push @$out, '      pool[used + take] = 0;';
            push @$out, '      out.data[out.len++] = &pool[used];';
            push @$out, '      used += take + 1;';
            push @$out, '      start = i;';
            push @$out, '      count = 0;';
            push @$out, '    }';
            push @$out, '  }';
            push @$out, '  return out;';
            push @$out, '}';
        }
        if ($h{last_value_str}) {
            push @$out, 'static const char *metac_builtin_last_value_str(struct metac_list_str v) {';
            push @$out, '  if (v.len <= 0) return "";';
            push @$out, '  return v.data[v.len - 1] ? v.data[v.len - 1] : "";';
            push @$out, '}';
        }
    }

    if ($h{map_parse_number}) {
        push @$out, 'static struct metac_list_i64 metac_map_parse_number(const struct metac_list_str *src) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src) { metac_last_error = 1; return out; }';
        push @$out, '  for (int64_t i = 0; i < src->len; ++i) {';
        push @$out, '    int64_t v = metac_builtin_parse_number(src->data[i]);';
        push @$out, '    if (metac_last_error) return out;';
        push @$out, '    if (out.len < out.cap) out.data[out.len++] = v;';
        push @$out, '  }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_parse_number_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_parse_number_value(struct metac_list_str src) {';
            push @$out, '  return metac_map_parse_number(&src);';
            push @$out, '}';
        }
    }
    if ($h{map_str_i64}) {
        push @$out, 'static struct metac_list_i64 metac_map_str_i64(const struct metac_list_str *src, int64_t (*fn)(const char *)) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src || !fn) return out;';
        push @$out, '  for (int64_t i = 0; i < src->len && out.len < out.cap; ++i) out.data[out.len++] = fn(src->data[i]);';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_str_i64_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_str_i64_value(struct metac_list_str src, int64_t (*fn)(const char *)) {';
            push @$out, '  return metac_map_str_i64(&src, fn);';
            push @$out, '}';
        }
    }
    if ($h{map_i64_i64}) {
        push @$out, 'static struct metac_list_i64 metac_map_i64_i64(const struct metac_list_i64 *src, int64_t (*fn)(int64_t)) {';
        push @$out, '  struct metac_list_i64 out = metac_list_i64_empty();';
        push @$out, '  if (!src || !fn) return out;';
        push @$out, '  for (int64_t i = 0; i < src->len && out.len < out.cap; ++i) out.data[out.len++] = fn(src->data[i]);';
        push @$out, '  return out;';
        push @$out, '}';
        if ($h{map_i64_i64_value}) {
            push @$out, 'static struct metac_list_i64 metac_map_i64_i64_value(struct metac_list_i64 src, int64_t (*fn)(int64_t)) {';
            push @$out, '  return metac_map_i64_i64(&src, fn);';
            push @$out, '}';
        }
    }
    if ($h{reduce_i64_mul_add}) {
        push @$out, 'static int64_t metac_reduce_i64_mul_add(struct metac_list_i64 src, int64_t init, int64_t factor) {';
        push @$out, '  int64_t acc = init;';
        push @$out, '  for (int64_t i = 0; i < src.len; ++i) acc = (acc * factor) + src.data[i];';
        push @$out, '  return acc;';
        push @$out, '}';
    }
    if ($h{reduce_str_add_size}) {
        push @$out, 'static int64_t metac_reduce_str_add_size(struct metac_list_str src, int64_t init) {';
        push @$out, '  int64_t acc = init;';
        push @$out, '  for (int64_t i = 0; i < src.len; ++i) {';
        push @$out, '    const char *s = src.data[i] ? src.data[i] : "";';
        push @$out, '    acc += (int64_t)strlen(s);';
        push @$out, '  }';
        push @$out, '  return acc;';
        push @$out, '}';
    }
    if ($h{assert_size_i64}) {
        push @$out, 'static struct metac_list_i64 metac_assert_size_i64(const struct metac_list_i64 *src, int64_t need, const char *msg) {';
        push @$out, '  struct metac_list_i64 out = src ? *src : metac_list_i64_empty();';
        push @$out, '  (void)msg;';
        push @$out, '  if (!src || src->len != need) { metac_last_error = 1; return out; }';
        push @$out, '  metac_last_error = 0;';
        push @$out, '  return out;';
        push @$out, '}';
    }

}

1;
