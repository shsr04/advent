package MetaC::CodegenRuntime::Prefix;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_prefix);

sub runtime_prefix {
    return <<'C_RUNTIME_PREFIX';
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
  int is_error;
  int value;
  char message[160];
} ResultBool;

typedef struct {
  int is_error;
  char value[256];
  char message[160];
} ResultStringValue;

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
  size_t count;
  NumberList *items;
} NumberListList;

typedef struct {
  size_t count;
  int *items;
} BoolList;

typedef struct {
  size_t count;
  void **items;
} AnyList;

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

typedef struct {
  int64_t dimensions;
  int has_size_spec;
  int64_t *size_spec;
  size_t entry_count;
  size_t entry_cap;
  int64_t *coords;
  int64_t *values;
} MatrixNumber;

typedef struct {
  MatrixNumber matrix;
  int64_t value;
  NumberList index;
} MatrixNumberMember;

typedef struct {
  size_t count;
  MatrixNumberMember *items;
} MatrixNumberMemberList;

typedef struct {
  int is_error;
  MatrixNumber value;
  char message[160];
} ResultMatrixNumber;

typedef struct {
  int64_t dimensions;
  int has_size_spec;
  int64_t *size_spec;
  size_t entry_count;
  size_t entry_cap;
  int64_t *coords;
  char **values;
} MatrixString;

typedef struct {
  int is_error;
  MatrixString value;
  char message[160];
} ResultMatrixString;

typedef struct {
  MatrixString matrix;
  const char *value;
  NumberList index;
} MatrixStringMember;

typedef struct {
  size_t count;
  MatrixStringMember *items;
} MatrixStringMemberList;

typedef struct {
  int64_t dimensions;
  int has_size_spec;
  int64_t *size_spec;
  size_t entry_count;
  size_t entry_cap;
  int64_t *coords;
  void **values;
} MatrixOpaque;

#define METAC_VALUE_NUMBER 1
#define METAC_VALUE_BOOL 2
#define METAC_VALUE_STRING 3
#define METAC_VALUE_ERROR 4
#define METAC_VALUE_NULL 5
#define METAC_VALUE_NUMBER_LIST 6
#define METAC_VALUE_NUMBER_LIST_LIST 7
#define METAC_VALUE_STRING_LIST 8
#define METAC_VALUE_BOOL_LIST 9
#define METAC_VALUE_MATRIX_NUMBER 10
#define METAC_VALUE_MATRIX_STRING 11
#define METAC_VALUE_ANY_LIST 12
#define METAC_VALUE_MATRIX_OPAQUE 13

typedef struct {
  int kind;
  int64_t number_value;
  int bool_value;
  char string_value[256];
  char error_message[160];
  NumberList number_list_value;
  NumberListList number_list_list_value;
  StringList string_list_value;
  BoolList bool_list_value;
  AnyList any_list_value;
  MatrixNumber matrix_number_value;
  MatrixString matrix_string_value;
  MatrixOpaque matrix_opaque_value;
} MetaCValue;
C_RUNTIME_PREFIX
}

1;
