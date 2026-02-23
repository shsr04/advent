package MetaC::CodegenRuntime::Logging;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_logging);

sub runtime_fragment_logging {
    return <<'C_RUNTIME_LOGGING';
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
C_RUNTIME_LOGGING
}

1;
