#include <ctype.h>
#include <limits.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int is_error;
  int value;
  char message[160];
} ResultNumber;

static ResultNumber ok_number(int value) {
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

static int metac_max(int a, int b) {
  return (a > b) ? a : b;
}

static int metac_min(int a, int b) {
  return (a < b) ? a : b;
}

static int metac_wrap_range(int value, int min, int max) {
  int span = (max - min) + 1;
  int shifted = value - min;
  int r = shifted % span;
  if (r < 0) {
    r += span;
  }
  return min + r;
}

static int metac_parse_int(const char *text, int *out) {
  char *end = NULL;
  long value = strtol(text, &end, 10);
  if (text[0] == '\0' || *end != '\0') {
    return 0;
  }
  if (value < INT_MIN || value > INT_MAX) {
    return 0;
  }
  *out = (int)value;
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

static ResultNumber countNumbers(void);


static ResultNumber countNumbers(void) {
  int __metac_line_no = 0;
  char __metac_err[160];
  int dial = metac_wrap_range(50, 0, 99);
  int zeroHits = 0;
  {
    char line[512];
    while (fgets(line, sizeof(line), stdin) != NULL) {
      __metac_line_no++;
      char __metac_m0_g0[256];
      char __metac_m0_g1[256];
      char *__metac_m0_outs[2] = { __metac_m0_g0, __metac_m0_g1 };
      if (!metac_match_groups(line, "(L|R)([0-9]+)", 2, __metac_m0_outs, 256, __metac_err, sizeof(__metac_err))) {
        return err_number(__metac_err, __metac_line_no, line);
      }
      char direction[256];
      metac_copy_str(direction, sizeof(direction), __metac_m0_g0);
      int amount;
      if (!metac_parse_int(__metac_m0_g1, &amount)) {
        return err_number("Expected numeric capture", __metac_line_no, line);
      }
      if (metac_streq(direction, "L")) {
        dial = metac_wrap_range((dial - amount), 0, 99);
      }
      else {
        dial = metac_wrap_range((dial + amount), 0, 99);
      }
      if ((dial == 0)) {
        zeroHits = (zeroHits + 1);
      }
    }
    if (ferror(stdin)) { return err_number("I/O read failure", __metac_line_no, ""); }
  }
  return ok_number(zeroHits);
  return err_number("Missing return in function countNumbers", __metac_line_no, "");
}

int main(void) {
  ResultNumber result = countNumbers();
  if (result.is_error) {
    printf("Error! %s\n", result.message);
    return 1;
  }
  printf("Result: %d\n", result.value);
  return 0;
}
