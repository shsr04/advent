package MetaC::CodegenRuntime::Regex;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_regex);

sub runtime_fragment_regex {
    return <<'C_RUNTIME_REGEX';
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
C_RUNTIME_REGEX
}

1;
