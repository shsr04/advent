package MetaC::CodegenRuntime::Matrix;
use strict;
use warnings;
use Exporter 'import';

use MetaC::CodegenRuntime::MatrixString qw(runtime_fragment_matrix_string);

our @EXPORT_OK = qw(runtime_fragment_matrix);

sub runtime_fragment_matrix {
    my $number_fragment = <<'C_RUNTIME_MATRIX_NUMBER';
static MatrixNumber metac_matrix_number_new(int64_t dimensions, NumberList size_spec) {
  MatrixNumber out;
  out.dimensions = dimensions < 2 ? 2 : dimensions;
  out.has_size_spec = 0;
  out.size_spec = NULL;
  out.entry_count = 0;
  out.entry_cap = 0;
  out.coords = NULL;
  out.values = NULL;

  if (size_spec.count == 0) {
    return out;
  }

  size_t dims = (size_t)out.dimensions;
  if (size_spec.items == NULL || size_spec.count != dims) {
    fprintf(stderr, "invalid matrix size spec\n");
    exit(1);
  }

  int64_t *copy = (int64_t *)calloc(dims == 0 ? 1 : dims, sizeof(int64_t));
  if (copy == NULL) {
    fprintf(stderr, "out of memory in matrix size spec\n");
    exit(1);
  }
  for (size_t i = 0; i < dims; i++) {
    if (size_spec.items[i] <= 0 && size_spec.items[i] != -1) {
      fprintf(stderr, "matrix size must be positive or '*' (-1)\n");
      exit(1);
    }
    copy[i] = size_spec.items[i];
  }

  out.has_size_spec = 1;
  out.size_spec = copy;
  return out;
}

static int metac_matrix_number_coords_valid(const MatrixNumber *matrix, NumberList coords, char *err, size_t err_sz) {
  if (matrix == NULL) {
    snprintf(err, err_sz, "matrix is null");
    return 0;
  }
  size_t dims = (size_t)matrix->dimensions;
  if (coords.count != dims || coords.items == NULL) {
    snprintf(err, err_sz, "matrix coordinate arity mismatch");
    return 0;
  }

  for (size_t d = 0; d < dims; d++) {
    int64_t coord = coords.items[d];
    if (coord < 0) {
      snprintf(err, err_sz, "matrix coordinate is negative");
      return 0;
    }
    if (matrix->has_size_spec && matrix->size_spec != NULL && matrix->size_spec[d] > 0 && coord >= matrix->size_spec[d]) {
      snprintf(err, err_sz, "matrix coordinate out of bounds");
      return 0;
    }
  }
  return 1;
}

static int metac_matrix_number_coords_equal(const MatrixNumber *matrix, size_t entry_idx, NumberList coords) {
  size_t dims = (size_t)matrix->dimensions;
  size_t offset = entry_idx * dims;
  for (size_t d = 0; d < dims; d++) {
    if (matrix->coords[offset + d] != coords.items[d]) {
      return 0;
    }
  }
  return 1;
}

static size_t metac_matrix_number_find_entry(const MatrixNumber *matrix, NumberList coords) {
  for (size_t i = 0; i < matrix->entry_count; i++) {
    if (metac_matrix_number_coords_equal(matrix, i, coords)) {
      return i;
    }
  }
  return SIZE_MAX;
}

static int metac_matrix_number_ensure_capacity(MatrixNumber *matrix, size_t needed) {
  if (needed <= matrix->entry_cap) {
    return 1;
  }

  size_t dims = (size_t)matrix->dimensions;
  size_t cap = matrix->entry_cap == 0 ? 8 : matrix->entry_cap;
  while (cap < needed) {
    if (cap > SIZE_MAX / 2) {
      return 0;
    }
    cap *= 2;
  }
  if (dims != 0 && cap > SIZE_MAX / dims) {
    return 0;
  }

  size_t coord_slots = cap * dims;
  int64_t *next_coords = (int64_t *)realloc(matrix->coords, (coord_slots == 0 ? 1 : coord_slots) * sizeof(int64_t));
  int64_t *next_values = (int64_t *)realloc(matrix->values, (cap == 0 ? 1 : cap) * sizeof(int64_t));
  if (next_coords == NULL || next_values == NULL) {
    return 0;
  }
  matrix->coords = next_coords;
  matrix->values = next_values;
  matrix->entry_cap = cap;
  return 1;
}

static ResultMatrixNumber metac_matrix_number_insert_try(MatrixNumber matrix, int64_t value, NumberList coords) {
  ResultMatrixNumber out;
  out.is_error = 0;
  out.value = matrix;
  out.message[0] = '\0';

  char err[160];
  if (!metac_matrix_number_coords_valid(&out.value, coords, err, sizeof(err))) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "%s", err);
    return out;
  }

  size_t found = metac_matrix_number_find_entry(&out.value, coords);
  if (found != SIZE_MAX) {
    out.value.values[found] = value;
    return out;
  }

  size_t next_count = out.value.entry_count + 1;
  if (!metac_matrix_number_ensure_capacity(&out.value, next_count)) {
    out.is_error = 1;
    snprintf(out.message, sizeof(out.message), "out of memory in matrix insert");
    return out;
  }

  size_t dims = (size_t)out.value.dimensions;
  size_t dst = out.value.entry_count * dims;
  for (size_t d = 0; d < dims; d++) {
    out.value.coords[dst + d] = coords.items[d];
  }
  out.value.values[out.value.entry_count] = value;
  out.value.entry_count = next_count;
  return out;
}

static MatrixNumber metac_matrix_number_insert_or_die(MatrixNumber matrix, int64_t value, NumberList coords) {
  ResultMatrixNumber res = metac_matrix_number_insert_try(matrix, value, coords);
  if (res.is_error) {
    fprintf(stderr, "%s\n", res.message);
    exit(1);
  }
  return res.value;
}

static int metac_matrix_number_coord_cmp(const int64_t *a, const int64_t *b, size_t dims) {
  for (size_t d = 0; d < dims; d++) {
    if (a[d] < b[d]) {
      return -1;
    }
    if (a[d] > b[d]) {
      return 1;
    }
  }
  return 0;
}

static MatrixNumberMemberList metac_matrix_number_members(MatrixNumber matrix) {
  MatrixNumberMemberList out;
  out.count = 0;
  out.items = NULL;
  if (matrix.entry_count == 0 || matrix.coords == NULL || matrix.values == NULL) {
    return out;
  }

  size_t dims = (size_t)matrix.dimensions;
  size_t count = matrix.entry_count;
  size_t *order = (size_t *)calloc(count == 0 ? 1 : count, sizeof(size_t));
  if (order == NULL) {
    return out;
  }
  for (size_t i = 0; i < count; i++) {
    order[i] = i;
  }

  for (size_t i = 1; i < count; i++) {
    size_t j = i;
    while (j > 0) {
      const int64_t *lhs = &matrix.coords[order[j - 1] * dims];
      const int64_t *rhs = &matrix.coords[order[j] * dims];
      if (metac_matrix_number_coord_cmp(lhs, rhs, dims) <= 0) {
        break;
      }
      size_t tmp = order[j - 1];
      order[j - 1] = order[j];
      order[j] = tmp;
      j--;
    }
  }

  MatrixNumberMember *items = (MatrixNumberMember *)calloc(count == 0 ? 1 : count, sizeof(MatrixNumberMember));
  if (items == NULL) {
    free(order);
    return out;
  }

  for (size_t i = 0; i < count; i++) {
    size_t src = order[i];
    int64_t *coords = (int64_t *)calloc(dims == 0 ? 1 : dims, sizeof(int64_t));
    if (coords == NULL) {
      for (size_t j = 0; j < i; j++) {
        free(items[j].index.items);
      }
      free(items);
      free(order);
      return out;
    }
    for (size_t d = 0; d < dims; d++) {
      coords[d] = matrix.coords[src * dims + d];
    }
    items[i].matrix = matrix;
    items[i].value = matrix.values[src];
    items[i].index.count = dims;
    items[i].index.items = coords;
  }

  out.count = count;
  out.items = items;
  free(order);
  return out;
}

static NumberList metac_matrix_number_neighbours(MatrixNumber matrix, NumberList coords) {
  NumberList out;
  out.count = 0;
  out.items = NULL;

  char err[160];
  if (!metac_matrix_number_coords_valid(&matrix, coords, err, sizeof(err))) {
    fprintf(stderr, "%s\n", err);
    exit(1);
  }
  if (matrix.entry_count == 0 || matrix.coords == NULL || matrix.values == NULL) {
    return out;
  }

  int64_t *items = (int64_t *)calloc(matrix.entry_count == 0 ? 1 : matrix.entry_count, sizeof(int64_t));
  if (items == NULL) {
    return out;
  }

  size_t dims = (size_t)matrix.dimensions;
  size_t out_count = 0;
  for (size_t i = 0; i < matrix.entry_count; i++) {
    int within = 1;
    int all_same = 1;
    for (size_t d = 0; d < dims; d++) {
      int64_t cell = matrix.coords[i * dims + d];
      int64_t diff = cell - coords.items[d];
      if (diff < -1 || diff > 1) {
        within = 0;
        break;
      }
      if (diff != 0) {
        all_same = 0;
      }
    }
    if (within && !all_same) {
      items[out_count++] = matrix.values[i];
    }
  }

  out.count = out_count;
  out.items = items;
  return out;
}

static MatrixNumber metac_log_matrix_number(MatrixNumber value) {
  printf("matrix(dim=%lld", (long long)value.dimensions);
  if (value.has_size_spec && value.size_spec != NULL) {
    printf(", size=[");
    for (size_t i = 0; i < (size_t)value.dimensions; i++) {
      printf("%lld", (long long)value.size_spec[i]);
      if (i + 1 < (size_t)value.dimensions) {
        printf(", ");
      }
    }
    printf("]");
  } else {
    printf(", size=*");
  }

  MatrixNumberMemberList members = metac_matrix_number_members(value);
  printf(", entries=[");
  for (size_t i = 0; i < members.count; i++) {
    printf("{index:[");
    for (size_t d = 0; d < members.items[i].index.count; d++) {
      printf("%lld", (long long)members.items[i].index.items[d]);
      if (d + 1 < members.items[i].index.count) {
        printf(", ");
      }
    }
    printf("], value:%lld}", (long long)members.items[i].value);
    if (i + 1 < members.count) {
      printf(", ");
    }
  }
  printf("])\n");
  metac_free_matrix_number_member_list(members);
  return value;
}

C_RUNTIME_MATRIX_NUMBER
    return $number_fragment . runtime_fragment_matrix_string();
}

1;
