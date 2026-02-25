package MetaC::CodegenRuntime::Utf8;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(runtime_fragment_utf8);

sub runtime_fragment_utf8 {
    return <<'C_RUNTIME_UTF8';
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
      for (size_t j = 0; j < count; j++) {
        free(items[j]);
      }
      free(items);
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
      for (size_t j = 0; j < count; j++) {
        free(items[j]);
      }
      free(items);
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
C_RUNTIME_UTF8
}

1;
