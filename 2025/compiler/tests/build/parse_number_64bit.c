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
  size_t count;
  char **items;
} StringList;

typedef struct {
  size_t count;
  int64_t *items;
} NumberList;

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

static int64_t metac_strlen(const char *s) {
  if (s == NULL) {
    return 0;
  }
  size_t n = strlen(s);
  if (n > (size_t)INT64_MAX) {
    return INT64_MAX;
  }
  return (int64_t)n;
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

  size_t n = (size_t)chunk_size;
  size_t count = (len + n - 1) / n;
  char **items = (char **)calloc(count, sizeof(char *));
  if (items == NULL) {
    return out;
  }

  for (size_t i = 0; i < count; i++) {
    size_t start = i * n;
    size_t seg_len = n;
    if (start + seg_len > len) {
      seg_len = len - start;
    }
    char *tok = (char *)malloc(seg_len + 1);
    if (tok == NULL) {
      return out;
    }
    memcpy(tok, input + start, seg_len);
    tok[seg_len] = '\0';
    items[i] = tok;
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

static ResultNumber solve(void);


static ResultNumber solve(void) {
  int __metac_line_no = 0;
  char __metac_err[160];
  ResultStringList __metac_split1 = metac_split_string("7676687127-7676687127", "-");
  if (__metac_split1.is_error) {
    return err_number(__metac_split1.message, __metac_line_no, "");
  }
  StringList __metac_chain0 = __metac_split1.value;
  StringList __metac_map_src3 = __metac_chain0;
  size_t __metac_map_count4 = __metac_map_src3.count;
  int64_t *__metac_map_items6 = (int64_t *)calloc(__metac_map_count4 == 0 ? 1 : __metac_map_count4, sizeof(int64_t));
  if (__metac_map_items6 == NULL) {
    return err_number("out of memory in map", __metac_line_no, "");
  }
  for (size_t __metac_map_i5 = 0; __metac_map_i5 < __metac_map_count4; __metac_map_i5++) {
    int64_t __metac_map_num7 = 0;
    if (!metac_parse_int(__metac_map_src3.items[__metac_map_i5], &__metac_map_num7)) {
      return err_number("Invalid number", __metac_line_no, __metac_map_src3.items[__metac_map_i5]);
    }
    __metac_map_items6[__metac_map_i5] = __metac_map_num7;
  }
  NumberList __metac_chain2;
  __metac_chain2.count = __metac_map_count4;
  __metac_chain2.items = __metac_map_items6;
  NumberList __metac_assert_list9 = __metac_chain2;
  if (!((((int64_t)__metac_assert_list9.count) == 2))) {
    return err_number("Invalid range", __metac_line_no, "");
  }
  NumberList bounds = __metac_assert_list9;
  NumberList __metac_list10 = bounds;
  const int64_t start = __metac_list10.items[0];
  const int64_t end = __metac_list10.items[1];
  return ok_number((start + end));
  return err_number("Missing return in function solve", __metac_line_no, "");
}

int main(void) {
  ResultNumber result = solve();
  if (result.is_error) {
    printf("Error! %s\n", result.message);
    return 1;
  }
  printf("Result: %lld\n", (long long)result.value);
  return 0;
}
