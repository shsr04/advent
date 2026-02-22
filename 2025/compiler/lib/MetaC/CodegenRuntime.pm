package MetaC::CodegenRuntime;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_prelude runtime_prelude_for_code);

sub runtime_prelude {
    return <<'C_RUNTIME';
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <regex.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int is_error;
  int64_t value;
  char message[160];
} ResultNumber;

typedef struct {
  int is_null;
  int64_t value;
} NullableNumber;

typedef struct {
  size_t count;
  char **items;
} StringList;

typedef struct {
  size_t count;
  int64_t *items;
} NumberList;

typedef struct {
  int64_t value;
  int64_t index;
} IndexedNumber;

typedef struct {
  size_t count;
  IndexedNumber *items;
} IndexedNumberList;

typedef struct {
  int is_error;
  StringList value;
  char message[160];
} ResultStringList;

static ResultNumber ok_number(int64_t value) {
  ResultNumber out;
  out.is_error = 0;
  out.value = value;
  out.message[0] = '\0';
  return out;
}

static NullableNumber metac_null_number(void) {
  NullableNumber out;
  out.is_null = 1;
  out.value = 0;
  return out;
}

static NullableNumber metac_some_number(int64_t value) {
  NullableNumber out;
  out.is_null = 0;
  out.value = value;
  return out;
}

static ResultNumber err_number(const char *message, int line_no, const char *line_text) {
  ResultNumber out;
  out.is_error = 1;
  out.value = 0;
  snprintf(out.message, sizeof(out.message), "%s (line %d: %s)", message, line_no, line_text);
  return out;
}

static const char *metac_fmt(const char *fmt, ...) {
  static char out[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(out, sizeof(out), fmt, ap);
  va_end(ap);
  return out;
}

static char *metac_strdup_local(const char *s) {
  size_t n = strlen(s);
  char *out = (char *)malloc(n + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, s, n + 1);
  return out;
}

static char *metac_read_all_stdin(void) {
  size_t cap = 4096;
  size_t len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) {
    return NULL;
  }

  int ch = 0;
  while ((ch = fgetc(stdin)) != EOF) {
    if (len + 1 >= cap) {
      size_t next = cap * 2;
      char *grown = (char *)realloc(buf, next);
      if (grown == NULL) {
        free(buf);
        return NULL;
      }
      buf = grown;
      cap = next;
    }
    buf[len++] = (char)ch;
  }
  buf[len] = '\0';
  return buf;
}

static size_t metac_utf8_symbol_len(const char *s, size_t len, size_t pos) {
  if (pos >= len) {
    return 0;
  }

  unsigned char lead = (unsigned char)s[pos];
  size_t symbol_len = 1;
  if ((lead & 0x80) == 0x00) {
    symbol_len = 1;
  } else if ((lead & 0xE0) == 0xC0) {
    symbol_len = 2;
  } else if ((lead & 0xF0) == 0xE0) {
    symbol_len = 3;
  } else if ((lead & 0xF8) == 0xF0) {
    symbol_len = 4;
  }

  if (pos + symbol_len > len) {
    return 1;
  }

  if (symbol_len > 1) {
    for (size_t j = 1; j < symbol_len; j++) {
      unsigned char cont = (unsigned char)s[pos + j];
      if ((cont & 0xC0) != 0x80) {
        return 1;
      }
    }
  }

  return symbol_len;
}

static int64_t metac_utf8_decode_symbol(const char *s, size_t pos, size_t symbol_len) {
  unsigned char b0 = (unsigned char)s[pos];
  if (symbol_len == 1) {
    return (int64_t)b0;
  }
  if (symbol_len == 2) {
    unsigned char b1 = (unsigned char)s[pos + 1];
    return (int64_t)(((uint32_t)(b0 & 0x1F) << 6) | (uint32_t)(b1 & 0x3F));
  }
  if (symbol_len == 3) {
    unsigned char b1 = (unsigned char)s[pos + 1];
    unsigned char b2 = (unsigned char)s[pos + 2];
    return (int64_t)(((uint32_t)(b0 & 0x0F) << 12) |
                     ((uint32_t)(b1 & 0x3F) << 6) |
                     (uint32_t)(b2 & 0x3F));
  }
  if (symbol_len == 4) {
    unsigned char b1 = (unsigned char)s[pos + 1];
    unsigned char b2 = (unsigned char)s[pos + 2];
    unsigned char b3 = (unsigned char)s[pos + 3];
    return (int64_t)(((uint32_t)(b0 & 0x07) << 18) |
                     ((uint32_t)(b1 & 0x3F) << 12) |
                     ((uint32_t)(b2 & 0x3F) << 6) |
                     (uint32_t)(b3 & 0x3F));
  }
  return (int64_t)b0;
}

static int64_t metac_strlen(const char *s) {
  if (s == NULL) {
    return 0;
  }

  size_t len = strlen(s);
  size_t pos = 0;
  int64_t count = 0;
  while (pos < len) {
    if (count == INT64_MAX) {
      return INT64_MAX;
    }
    size_t symbol_len = metac_utf8_symbol_len(s, len, pos);
    if (symbol_len == 0) {
      break;
    }
    pos += symbol_len;
    count++;
  }
  return count;
}

static int64_t metac_char_at(const char *s, int64_t idx) {
  if (s == NULL || idx < 0) {
    return -1;
  }

  size_t len = strlen(s);
  size_t pos = 0;
  int64_t current = 0;
  while (pos < len) {
    size_t symbol_len = metac_utf8_symbol_len(s, len, pos);
    if (symbol_len == 0) {
      break;
    }
    if (current == idx) {
      return metac_utf8_decode_symbol(s, pos, symbol_len);
    }
    pos += symbol_len;
    current++;
  }
  return -1;
}

static StringList metac_chunk_string(const char *input, int64_t chunk_size) {
  StringList out;
  out.count = 0;
  out.items = NULL;

  if (input == NULL) {
    return out;
  }

  if (chunk_size <= 0) {
    return out;
  }

  size_t len = strlen(input);
  if (len == 0) {
    return out;
  }

  char **items = (char **)calloc(len, sizeof(char *));
  if (items == NULL) {
    return out;
  }

  size_t pos = 0;
  size_t count = 0;
  while (pos < len) {
    size_t start = pos;
    int64_t taken = 0;
    while (pos < len && taken < chunk_size) {
      size_t symbol_len = metac_utf8_symbol_len(input, len, pos);
      if (symbol_len == 0) {
        break;
      }
      pos += symbol_len;
      taken++;
    }

    size_t seg_len = pos - start;
    char *tok = (char *)malloc(seg_len + 1);
    if (tok == NULL) {
      return out;
    }
    memcpy(tok, input + start, seg_len);
    tok[seg_len] = '\0';
    items[count++] = tok;
  }

  out.count = count;
  out.items = items;
  return out;
}

static StringList metac_chars_string(const char *input) {
  StringList out;
  out.count = 0;
  out.items = NULL;

  if (input == NULL) {
    return out;
  }

  size_t len = strlen(input);
  if (len == 0) {
    return out;
  }

  char **items = (char **)calloc(len, sizeof(char *));
  if (items == NULL) {
    return out;
  }

  size_t i = 0;
  size_t count = 0;
  while (i < len) {
    size_t char_len = metac_utf8_symbol_len(input, len, i);
    if (char_len == 0) {
      break;
    }

    char *tok = (char *)malloc(char_len + 1);
    if (tok == NULL) {
      return out;
    }
    memcpy(tok, input + i, char_len);
    tok[char_len] = '\0';
    items[count++] = tok;
    i += char_len;
  }

  out.count = count;
  out.items = items;
  return out;
}

static ResultStringList metac_split_string(const char *input, const char *delim) {
  ResultStringList out;
  out.is_error = 0;
  out.value.count = 0;
  out.value.items = NULL;
  out.message[0] = '\0';

  if (input == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "split input is null");
    return out;
  }
  if (delim == NULL || delim[0] == '\0') {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "split delimiter is empty");
    return out;
  }

  size_t delim_len = strlen(delim);
  size_t count = 1;
  const char *scan = input;
  while (1) {
    const char *p = strstr(scan, delim);
    if (p == NULL) {
      break;
    }
    count++;
    scan = p + delim_len;
  }

  char **items = (char **)calloc(count, sizeof(char *));
  if (items == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "out of memory allocating split items");
    return out;
  }

  size_t idx = 0;
  const char *start = input;
  while (1) {
    const char *p = strstr(start, delim);
    size_t len = (p == NULL) ? strlen(start) : (size_t)(p - start);
    char *tok = (char *)malloc(len + 1);
    if (tok == NULL) {
      out.is_error = 1;
      snprintf(out.message, sizeof(out.message), "out of memory allocating split token");
      return out;
    }
    memcpy(tok, start, len);
    tok[len] = '\0';
    items[idx++] = tok;

    if (p == NULL) {
      break;
    }
    start = p + delim_len;
  }

  out.value.count = idx;
  out.value.items = items;
  return out;
}

static int64_t metac_last_index_from_count(size_t count) {
  if (count == 0) {
    return -1;
  }
  if (count - 1 > (size_t)INT64_MAX) {
    return INT64_MAX;
  }
  return (int64_t)(count - 1);
}

static int64_t metac_clamp_slice_start(int64_t start, size_t count) {
  if (start <= 0) {
    return 0;
  }
  if ((uint64_t)start >= count) {
    return (int64_t)count;
  }
  return start;
}

static StringList metac_slice_string_list(StringList input, int64_t start) {
  StringList out;
  out.count = 0;
  out.items = NULL;

  int64_t start_i64 = metac_clamp_slice_start(start, input.count);
  size_t start_idx = (size_t)start_i64;
  if (start_idx >= input.count || input.items == NULL) {
    return out;
  }

  out.count = input.count - start_idx;
  out.items = input.items + start_idx;
  return out;
}

static NumberList metac_slice_number_list(NumberList input, int64_t start) {
  NumberList out;
  out.count = 0;
  out.items = NULL;

  int64_t start_i64 = metac_clamp_slice_start(start, input.count);
  size_t start_idx = (size_t)start_i64;
  if (start_idx >= input.count || input.items == NULL) {
    return out;
  }

  out.count = input.count - start_idx;
  out.items = input.items + start_idx;
  return out;
}

static int64_t metac_reduce_number_list(NumberList list, int64_t initial, int64_t (*reducer)(int64_t, int64_t)) {
  int64_t acc = initial;
  if (reducer == NULL || list.items == NULL) {
    return acc;
  }

  for (size_t i = 0; i < list.count; i++) {
    acc = reducer(acc, list.items[i]);
  }
  return acc;
}

static int64_t metac_reduce_string_list(StringList list, int64_t initial, int64_t (*reducer)(int64_t, const char *)) {
  int64_t acc = initial;
  if (reducer == NULL || list.items == NULL) {
    return acc;
  }

  for (size_t i = 0; i < list.count; i++) {
    const char *item = list.items[i] == NULL ? "" : list.items[i];
    acc = reducer(acc, item);
  }
  return acc;
}

static int64_t metac_number_list_push(NumberList *list, int64_t value) {
  if (list == NULL) {
    fprintf(stderr, "push on null number list\n");
    exit(1);
  }

  if (list->count == SIZE_MAX) {
    fprintf(stderr, "number list push overflow\n");
    exit(1);
  }

  size_t next_count = list->count + 1;
  int64_t *items = (int64_t *)realloc(list->items, (next_count == 0 ? 1 : next_count) * sizeof(int64_t));
  if (items == NULL) {
    fprintf(stderr, "out of memory in number list push\n");
    exit(1);
  }

  items[list->count] = value;
  list->items = items;
  list->count = next_count;
  if (next_count > (size_t)INT64_MAX) {
    return INT64_MAX;
  }
  return (int64_t)next_count;
}

static int64_t metac_string_list_push(StringList *list, const char *value) {
  if (list == NULL) {
    fprintf(stderr, "push on null string list\n");
    exit(1);
  }

  if (list->count == SIZE_MAX) {
    fprintf(stderr, "string list push overflow\n");
    exit(1);
  }

  size_t next_count = list->count + 1;
  char **items = (char **)realloc(list->items, (next_count == 0 ? 1 : next_count) * sizeof(char *));
  if (items == NULL) {
    fprintf(stderr, "out of memory in string list push\n");
    exit(1);
  }

  const char *src = value == NULL ? "" : value;
  char *copied = metac_strdup_local(src);
  if (copied == NULL) {
    fprintf(stderr, "out of memory duplicating string list item\n");
    exit(1);
  }

  items[list->count] = copied;
  list->items = items;
  list->count = next_count;
  if (next_count > (size_t)INT64_MAX) {
    return INT64_MAX;
  }
  return (int64_t)next_count;
}

static int64_t metac_parse_int_or_zero(const char *text) {
  if (text == NULL) {
    return 0;
  }
  char *end = NULL;
  errno = 0;
  long long value = strtoll(text, &end, 10);
  if (text[0] == '\0' || *end != '\0' || errno == ERANGE) {
    return 0;
  }
  return (int64_t)value;
}

static IndexedNumber metac_list_max_number(NumberList list) {
  IndexedNumber out;
  out.value = 0;
  out.index = -1;

  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  out.value = list.items[0];
  out.index = 0;
  for (size_t i = 1; i < list.count; i++) {
    if (list.items[i] > out.value) {
      out.value = list.items[i];
      out.index = (i > (size_t)INT64_MAX) ? INT64_MAX : (int64_t)i;
    }
  }
  return out;
}

static IndexedNumber metac_list_max_string_number(StringList list) {
  IndexedNumber out;
  out.value = 0;
  out.index = -1;

  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  out.value = metac_parse_int_or_zero(list.items[0]);
  out.index = 0;
  for (size_t i = 1; i < list.count; i++) {
    int64_t value = metac_parse_int_or_zero(list.items[i]);
    if (value > out.value) {
      out.value = value;
      out.index = (i > (size_t)INT64_MAX) ? INT64_MAX : (int64_t)i;
    }
  }
  return out;
}

static int metac_cmp_indexed_number_desc(const void *a_ptr, const void *b_ptr) {
  const IndexedNumber *a = (const IndexedNumber *)a_ptr;
  const IndexedNumber *b = (const IndexedNumber *)b_ptr;
  if (a->value < b->value) {
    return 1;
  }
  if (a->value > b->value) {
    return -1;
  }
  if (a->index > b->index) {
    return 1;
  }
  if (a->index < b->index) {
    return -1;
  }
  return 0;
}

static IndexedNumberList metac_sort_number_list(NumberList list) {
  IndexedNumberList out;
  out.count = 0;
  out.items = NULL;

  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  IndexedNumber *items =
      (IndexedNumber *)calloc(list.count == 0 ? 1 : list.count, sizeof(IndexedNumber));
  if (items == NULL) {
    return out;
  }

  for (size_t i = 0; i < list.count; i++) {
    items[i].value = list.items[i];
    items[i].index = (i > (size_t)INT64_MAX) ? INT64_MAX : (int64_t)i;
  }

  qsort(items, list.count, sizeof(IndexedNumber), metac_cmp_indexed_number_desc);
  out.count = list.count;
  out.items = items;
  return out;
}

static int64_t metac_last_index_string_list(StringList list) {
  return metac_last_index_from_count(list.count);
}

static int64_t metac_last_index_number_list(NumberList list) {
  return metac_last_index_from_count(list.count);
}

static void metac_copy_str(char *dst, size_t dst_sz, const char *src) {
  if (dst_sz == 0) {
    return;
  }
  strncpy(dst, src, dst_sz - 1);
  dst[dst_sz - 1] = '\0';
}

static int metac_streq(const char *a, const char *b) {
  return strcmp(a, b) == 0;
}

static int64_t metac_log_number(int64_t value) {
  printf("%lld\n", (long long)value);
  return value;
}

static const char *metac_log_string(const char *value) {
  const char *out = value == NULL ? "" : value;
  printf("%s\n", out);
  return out;
}

static int metac_log_bool(int value) {
  printf("%d\n", value);
  return value;
}

static IndexedNumber metac_log_indexed_number(IndexedNumber value) {
  printf("%lld\n", (long long)value.value);
  return value;
}

static StringList metac_log_string_list(StringList value) {
  printf("[");
  for (size_t i = 0; i < value.count; i++) {
    const char *item = value.items[i] == NULL ? "" : value.items[i];
    printf("%s", item);
    if (i + 1 < value.count) {
      printf(", ");
    }
  }
  printf("]\n");
  return value;
}

static NumberList metac_log_number_list(NumberList value) {
  printf("[");
  for (size_t i = 0; i < value.count; i++) {
    printf("%lld", (long long)value.items[i]);
    if (i + 1 < value.count) {
      printf(", ");
    }
  }
  printf("]\n");
  return value;
}

static IndexedNumberList metac_log_indexed_number_list(IndexedNumberList value) {
  printf("[");
  for (size_t i = 0; i < value.count; i++) {
    printf("{v=%lld,i=%lld}", (long long)value.items[i].value, (long long)value.items[i].index);
    if (i + 1 < value.count) {
      printf(", ");
    }
  }
  printf("]\n");
  return value;
}

static int64_t metac_max(int64_t a, int64_t b) {
  return (a > b) ? a : b;
}

static int64_t metac_min(int64_t a, int64_t b) {
  return (a < b) ? a : b;
}

static int64_t metac_wrap_range(int64_t value, int64_t min, int64_t max) {
  int64_t span = (max - min) + 1;
  int64_t shifted = value - min;
  int64_t r = shifted % span;
  if (r < 0) {
    r += span;
  }
  return min + r;
}

static int metac_parse_int(const char *text, int64_t *out) {
  char *end = NULL;
  errno = 0;
  long long value = strtoll(text, &end, 10);
  if (text[0] == '\0' || *end != '\0' || errno == ERANGE) {
    return 0;
  }
  *out = (int64_t)value;
  return 1;
}

static void metac_rstrip_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
    s[len - 1] = '\0';
    len--;
  }
}

static int metac_match_groups(
    const char *input,
    const char *pattern,
    int expected_groups,
    char **outs,
    size_t out_cap,
    char *err,
    size_t err_sz) {
  regex_t re;
  regmatch_t matches[16];
  char anchored[512];
  char line[512];

  if (expected_groups <= 0 || expected_groups > 15) {
    snprintf(err, err_sz, "Unsupported capture count");
    return 0;
  }

  snprintf(anchored, sizeof(anchored), "^%s$", pattern);
  metac_copy_str(line, sizeof(line), input);
  metac_rstrip_newline(line);

  if (regcomp(&re, anchored, REG_EXTENDED) != 0) {
    snprintf(err, err_sz, "Invalid regex pattern");
    return 0;
  }

  int rc = regexec(&re, line, (size_t)expected_groups + 1, matches, 0);
  if (rc != 0) {
    regfree(&re);
    snprintf(err, err_sz, "Pattern match failed");
    return 0;
  }

  for (int i = 0; i < expected_groups; i++) {
    regmatch_t m = matches[i + 1];
    if (m.rm_so < 0 || m.rm_eo < m.rm_so) {
      regfree(&re);
      snprintf(err, err_sz, "Missing capture group");
      return 0;
    }

    size_t len = (size_t)(m.rm_eo - m.rm_so);
    if (len >= out_cap) {
      regfree(&re);
      snprintf(err, err_sz, "Capture too long");
      return 0;
    }

    memcpy(outs[i], line + m.rm_so, len);
    outs[i][len] = '\0';
  }

  regfree(&re);
  return 1;
}
C_RUNTIME
}

sub _strip_c_literals_for_braces {
    my ($line) = @_;
    my $clean = $line;
    $clean =~ s/"(?:\\.|[^"\\])*"/""/g;
    $clean =~ s/'(?:\\.|[^'\\])*'/' '/g;
    return $clean;
}

sub _parse_runtime_blocks {
    my ($runtime) = @_;
    my @lines = split /\n/, $runtime, -1;
    my @prefix;
    my @order;
    my %blocks;
    my $i = 0;

    while ($i < @lines) {
        my $line = $lines[$i];
        if ($line =~ /^static\b/ && $line =~ /\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/) {
            my $name = $1;
            my @block;
            my $depth = 0;
            my $seen_open = 0;

            while ($i < @lines) {
                my $cur = $lines[$i];
                push @block, $cur;
                my $clean = _strip_c_literals_for_braces($cur);
                my $open = () = $clean =~ /\{/g;
                my $close = () = $clean =~ /\}/g;
                $depth += $open;
                $depth -= $close;
                $seen_open ||= $open > 0;
                $i++;
                last if $seen_open && $depth == 0;
            }

            $blocks{$name} = join("\n", @block) . "\n";
            push @order, $name;
            next;
        }

        push @prefix, $line;
        $i++;
    }

    my $prefix = join("\n", @prefix);
    $prefix .= "\n" if $prefix !~ /\n\z/;
    return ($prefix, \@order, \%blocks);
}

sub _build_runtime_deps {
    my ($order, $blocks) = @_;
    my %known = map { $_ => 1 } @$order;
    my %deps;

    for my $name (@$order) {
        my $body = $blocks->{$name} // '';
        my %seen;
        for my $callee (@$order) {
            next if !$known{$callee};
            next if $callee eq $name;
            next if $body !~ /\b\Q$callee\E\b/;
            next if $seen{$callee};
            $seen{$callee} = 1;
        }
        $deps{$name} = [ sort keys %seen ];
    }

    return \%deps;
}

sub _runtime_roots_from_consumer {
    my ($consumer_code, $order) = @_;
    my @roots;
    for my $name (@$order) {
        if ($consumer_code =~ /\b\Q$name\E\b/) {
            push @roots, $name;
        }
    }
    return \@roots;
}

sub _runtime_reachable {
    my ($roots, $deps) = @_;
    my %keep;
    my @stack = @$roots;

    while (@stack) {
        my $name = pop @stack;
        next if $keep{$name};
        $keep{$name} = 1;
        push @stack, @{ $deps->{$name} // [] };
    }

    return \%keep;
}

sub runtime_prelude_for_code {
    my ($consumer_code) = @_;
    $consumer_code = '' if !defined $consumer_code;

    my $runtime = runtime_prelude();
    my ($prefix, $order, $blocks) = _parse_runtime_blocks($runtime);
    my $deps = _build_runtime_deps($order, $blocks);
    my $roots = _runtime_roots_from_consumer($consumer_code, $order);
    my $keep = _runtime_reachable($roots, $deps);

    my $out = $prefix;
    for my $name (@$order) {
        next if !$keep->{$name};
        $out .= $blocks->{$name};
    }
    return $out;
}

1;
