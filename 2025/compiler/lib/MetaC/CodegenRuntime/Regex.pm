package MetaC::CodegenRuntime::Regex;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_regex);

sub runtime_fragment_regex {
    return <<'C_RUNTIME_REGEX';
static int metac_regex_capture_count(const char *pattern) {
  if (pattern == NULL) {
    return 0;
  }
  int count = 0;
  int escaped = 0;
  int in_class = 0;
  for (const char *p = pattern; *p != '\0'; p++) {
    const char ch = *p;
    if (escaped) {
      escaped = 0;
      continue;
    }
    if (ch == '\\') {
      escaped = 1;
      continue;
    }
    if (ch == '[' && !in_class) {
      in_class = 1;
      continue;
    }
    if (ch == ']' && in_class) {
      in_class = 0;
      continue;
    }
    if (in_class) {
      continue;
    }
    if (ch == '(') {
      count++;
    }
  }
  return count;
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

static ResultStringList metac_match_string(const char *input, const char *pattern) {
  ResultStringList out;
  out.is_error = 0;
  out.value.count = 0;
  out.value.items = NULL;
  out.message[0] = '\0';

  if (input == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "match input is null");
    return out;
  }
  if (pattern == NULL || pattern[0] == '\0') {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "match pattern is empty");
    return out;
  }

  int capture_count = metac_regex_capture_count(pattern);
  int out_count = capture_count > 0 ? capture_count : 1;
  if (out_count > 15) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "Unsupported capture count");
    return out;
  }

  char **items = (char **)calloc((size_t)out_count, sizeof(char *));
  if (items == NULL) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "out of memory allocating match items");
    return out;
  }

  regex_t re;
  regmatch_t matches[16];
  char anchored[512];
  char line[512];
  snprintf(anchored, sizeof(anchored), "^%s$", pattern);
  metac_copy_str(line, sizeof(line), input);
  metac_rstrip_newline(line);

  if (regcomp(&re, anchored, REG_EXTENDED) != 0) {
    free(items);
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "Invalid regex pattern");
    return out;
  }

  size_t match_count = capture_count > 0 ? (size_t)capture_count + 1 : 1;
  int rc = regexec(&re, line, match_count, matches, 0);
  if (rc != 0) {
    regfree(&re);
    free(items);
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "Pattern match failed");
    return out;
  }

  for (int i = 0; i < out_count; i++) {
    regmatch_t m = capture_count > 0 ? matches[i + 1] : matches[0];
    if (m.rm_so < 0 || m.rm_eo < m.rm_so) {
      regfree(&re);
      for (int j = 0; j < i; j++) {
        free(items[j]);
      }
      free(items);
      out.is_error = 1;
      snprintf(out.message, sizeof(out.message), "Missing capture group");
      return out;
    }

    size_t len = (size_t)(m.rm_eo - m.rm_so);
    char *tok = (char *)malloc(len + 1);
    if (tok == NULL) {
      regfree(&re);
      for (int j = 0; j < i; j++) {
        free(items[j]);
      }
      free(items);
      out.is_error = 1;
      snprintf(out.message, sizeof(out.message), "out of memory allocating match token");
      return out;
    }
    memcpy(tok, line + m.rm_so, len);
    tok[len] = '\0';
    items[i] = tok;
  }

  regfree(&re);
  out.value.count = (size_t)out_count;
  out.value.items = items;
  return out;
}
C_RUNTIME_REGEX
}

1;
