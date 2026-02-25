package MetaC::CodegenRuntime::Lists;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_lists);

sub runtime_fragment_lists {
    return <<'C_RUNTIME_LISTS';
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
      for (size_t j = 0; j < idx; j++) {
        free(items[j]);
      }
      free(items);
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
  out.items = (char **)calloc(out.count == 0 ? 1 : out.count, sizeof(char *));
  if (out.items == NULL) {
    out.count = 0;
    return out;
  }
  for (size_t i = 0; i < out.count; i++) {
    out.items[i] = input.items[start_idx + i];
  }
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
  out.items = (int64_t *)calloc(out.count == 0 ? 1 : out.count, sizeof(int64_t));
  if (out.items == NULL) {
    out.count = 0;
    return out;
  }
  for (size_t i = 0; i < out.count; i++) {
    out.items[i] = input.items[start_idx + i];
  }
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

static NumberList metac_filter_number_list(NumberList list, int (*predicate)(int64_t)) {
  NumberList out;
  out.count = 0;
  out.items = NULL;
  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  int64_t *items = (int64_t *)calloc(list.count == 0 ? 1 : list.count, sizeof(int64_t));
  if (items == NULL) {
    return out;
  }

  size_t out_count = 0;
  for (size_t i = 0; i < list.count; i++) {
    if (predicate == NULL || predicate(list.items[i])) {
      items[out_count++] = list.items[i];
    }
  }
  out.count = out_count;
  out.items = items;
  return out;
}

static StringList metac_filter_string_list(StringList list, int (*predicate)(const char *)) {
  StringList out;
  out.count = 0;
  out.items = NULL;
  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  char **items = (char **)calloc(list.count == 0 ? 1 : list.count, sizeof(char *));
  if (items == NULL) {
    return out;
  }

  size_t out_count = 0;
  for (size_t i = 0; i < list.count; i++) {
    const char *item = list.items[i] == NULL ? "" : list.items[i];
    if (predicate == NULL || predicate(item)) {
      items[out_count++] = (char *)item;
    }
  }
  out.count = out_count;
  out.items = items;
  return out;
}

static MatrixNumberMemberList metac_filter_matrix_number_member_list(
    MatrixNumberMemberList list,
    int (*predicate)(MatrixNumberMember)
) {
  MatrixNumberMemberList out;
  out.count = 0;
  out.items = NULL;
  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  MatrixNumberMember *items =
      (MatrixNumberMember *)calloc(list.count == 0 ? 1 : list.count, sizeof(MatrixNumberMember));
  if (items == NULL) {
    return out;
  }

  size_t out_count = 0;
  for (size_t i = 0; i < list.count; i++) {
    MatrixNumberMember item = list.items[i];
    if (predicate == NULL || predicate(item)) {
      NumberList idx_copy = metac_number_list_from_array(item.index.items, item.index.count);
      if (item.index.count > 0 && idx_copy.items == NULL) {
        for (size_t j = 0; j < out_count; j++) {
          free(items[j].index.items);
        }
        free(items);
        return out;
      }
      item.index = idx_copy;
      items[out_count++] = item;
    }
  }
  out.count = out_count;
  out.items = items;
  return out;
}

static MatrixStringMemberList metac_filter_matrix_string_member_list(
    MatrixStringMemberList list,
    int (*predicate)(MatrixStringMember)
) {
  MatrixStringMemberList out;
  out.count = 0;
  out.items = NULL;
  if (list.count == 0 || list.items == NULL) {
    return out;
  }

  MatrixStringMember *items =
      (MatrixStringMember *)calloc(list.count == 0 ? 1 : list.count, sizeof(MatrixStringMember));
  if (items == NULL) {
    return out;
  }

  size_t out_count = 0;
  for (size_t i = 0; i < list.count; i++) {
    MatrixStringMember item = list.items[i];
    if (predicate == NULL || predicate(item)) {
      NumberList idx_copy = metac_number_list_from_array(item.index.items, item.index.count);
      if (item.index.count > 0 && idx_copy.items == NULL) {
        for (size_t j = 0; j < out_count; j++) {
          free(items[j].index.items);
        }
        free(items);
        return out;
      }
      item.index = idx_copy;
      items[out_count++] = item;
    }
  }
  out.count = out_count;
  out.items = items;
  return out;
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

static int64_t metac_number_list_list_push(NumberListList *list, NumberList value) {
  if (list == NULL) {
    fprintf(stderr, "push on null number-list-list\n");
    exit(1);
  }
  if (list->count == SIZE_MAX) {
    fprintf(stderr, "number-list-list push overflow\n");
    exit(1);
  }

  NumberList copied = metac_number_list_from_array(value.items, value.count);
  if (value.count > 0 && copied.items == NULL) {
    fprintf(stderr, "out of memory copying nested number list\n");
    exit(1);
  }

  size_t next_count = list->count + 1;
  NumberList *items = (NumberList *)realloc(list->items, (next_count == 0 ? 1 : next_count) * sizeof(NumberList));
  if (items == NULL) {
    metac_free_number_list(copied);
    fprintf(stderr, "out of memory in number-list-list push\n");
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

static int64_t metac_bool_list_push(BoolList *list, int value) {
  if (list == NULL) {
    return 0;
  }
  size_t next = list->count + 1;
  int *grown = (int *)realloc(list->items, next * sizeof(int));
  if (grown == NULL) {
    return (int64_t)list->count;
  }
  grown[list->count] = value ? 1 : 0;
  list->items = grown;
  list->count = next;
  return (int64_t)next;
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
C_RUNTIME_LISTS
}

1;
