package MetaC::CodegenRuntime::Core;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_core);

sub runtime_fragment_core {
    return <<'C_RUNTIME_CORE';
static ResultNumber ok_number(int64_t value) {
  ResultNumber out;
  out.is_error = 0;
  out.value = value;
  out.message[0] = '\0';
  return out;
}

static ResultBool ok_bool(int value) {
  ResultBool out;
  out.is_error = 0;
  out.value = value ? 1 : 0;
  out.message[0] = '\0';
  return out;
}

static ResultStringValue ok_string_value(const char *value) {
  ResultStringValue out;
  out.is_error = 0;
  const char *src = value == NULL ? "" : value;
  strncpy(out.value, src, sizeof(out.value) - 1);
  out.value[sizeof(out.value) - 1] = '\0';
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

static ResultBool err_bool(const char *message, int line_no, const char *line_text) {
  ResultBool out;
  out.is_error = 1;
  out.value = 0;
  snprintf(out.message, sizeof(out.message), "%s (line %d: %s)", message, line_no, line_text);
  return out;
}

static ResultStringValue err_string_value(const char *message, int line_no, const char *line_text) {
  ResultStringValue out;
  out.is_error = 1;
  out.value[0] = '\0';
  snprintf(out.message, sizeof(out.message), "%s (line %d: %s)", message, line_no, line_text);
  return out;
}

static MetaCValue metac_value_number(int64_t value) {
  MetaCValue out;
  out.kind = METAC_VALUE_NUMBER;
  out.number_value = value;
  out.bool_value = 0;
  out.string_value[0] = '\0';
  out.error_message[0] = '\0';
  return out;
}

static MetaCValue metac_value_bool(int value) {
  MetaCValue out;
  out.kind = METAC_VALUE_BOOL;
  out.number_value = 0;
  out.bool_value = value ? 1 : 0;
  out.string_value[0] = '\0';
  out.error_message[0] = '\0';
  return out;
}

static MetaCValue metac_value_string(const char *value) {
  MetaCValue out;
  out.kind = METAC_VALUE_STRING;
  out.number_value = 0;
  out.bool_value = 0;
  const char *src = value == NULL ? "" : value;
  strncpy(out.string_value, src, sizeof(out.string_value) - 1);
  out.string_value[sizeof(out.string_value) - 1] = '\0';
  out.error_message[0] = '\0';
  return out;
}

static MetaCValue metac_value_null(void) {
  MetaCValue out;
  out.kind = METAC_VALUE_NULL;
  out.number_value = 0;
  out.bool_value = 0;
  out.string_value[0] = '\0';
  out.error_message[0] = '\0';
  return out;
}

static MetaCValue metac_value_error(const char *message, int line_no, const char *line_text) {
  MetaCValue out;
  out.kind = METAC_VALUE_ERROR;
  out.number_value = 0;
  out.bool_value = 0;
  out.string_value[0] = '\0';
  snprintf(out.error_message, sizeof(out.error_message), "%s (line %d: %s)", message, line_no, line_text);
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

static NumberList metac_number_list_from_array(const int64_t *items, size_t count) {
  NumberList out;
  out.count = 0;
  out.items = NULL;
  if (count == 0) {
    return out;
  }

  int64_t *copy = (int64_t *)calloc(count, sizeof(int64_t));
  if (copy == NULL) {
    return out;
  }
  for (size_t i = 0; i < count; i++) {
    copy[i] = items[i];
  }
  out.count = count;
  out.items = copy;
  return out;
}

static StringList metac_string_list_from_array(const char **items, size_t count) {
  StringList out;
  out.count = 0;
  out.items = NULL;
  if (count == 0) {
    return out;
  }

  char **copy = (char **)calloc(count, sizeof(char *));
  if (copy == NULL) {
    return out;
  }
  for (size_t i = 0; i < count; i++) {
    const char *src = items[i] == NULL ? "" : items[i];
    copy[i] = metac_strdup_local(src);
    if (copy[i] == NULL) {
      return out;
    }
  }
  out.count = count;
  out.items = copy;
  return out;
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

static void metac_rstrip_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
    s[len - 1] = '\0';
    len--;
  }
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
C_RUNTIME_CORE
}

1;
