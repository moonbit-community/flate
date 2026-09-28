// libdeflate runner for the paired benchmark protocol in benchmark/run.py.
// Codec setup, fixture I/O and validation stay outside the timed samples.

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <libdeflate.h>

enum stream_format {
  FORMAT_RAW,
  FORMAT_ZLIB,
  FORMAT_GZIP,
};

static volatile size_t sink;

static void die(const char *message) {
  fprintf(stderr, "error: %s\n", message);
  exit(EXIT_FAILURE);
}

static size_t parse_size(const char *value, const char *option) {
  char *end = NULL;
  errno = 0;
  unsigned long long parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed > SIZE_MAX) {
    fprintf(stderr, "error: invalid %s: %s\n", option, value);
    exit(EXIT_FAILURE);
  }
  return (size_t)parsed;
}

static int parse_level(const char *value) {
  size_t level = parse_size(value, "level");
  if (level > 12) {
    die("level must be in the range 0..12");
  }
  return (int)level;
}

static enum stream_format parse_format(const char *value) {
  if (strcmp(value, "raw") == 0) {
    return FORMAT_RAW;
  }
  if (strcmp(value, "zlib") == 0) {
    return FORMAT_ZLIB;
  }
  if (strcmp(value, "gzip") == 0) {
    return FORMAT_GZIP;
  }
  die("format must be raw, zlib, or gzip");
  return FORMAT_RAW;
}

static uint8_t *read_file(const char *path, size_t *size_out) {
  struct stat st;
  if (stat(path, &st) != 0) {
    perror(path);
    exit(EXIT_FAILURE);
  }
  if (st.st_size < 0 || (uintmax_t)st.st_size > SIZE_MAX) {
    die("input file is too large for this process");
  }

  size_t size = (size_t)st.st_size;
  uint8_t *data = malloc(size == 0 ? 1 : size);
  if (data == NULL) {
    die("could not allocate input buffer");
  }

  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    perror(path);
    free(data);
    exit(EXIT_FAILURE);
  }
  if (size != 0 && fread(data, 1, size, file) != size) {
    perror(path);
    fclose(file);
    free(data);
    exit(EXIT_FAILURE);
  }
  if (fclose(file) != 0) {
    perror(path);
    free(data);
    exit(EXIT_FAILURE);
  }
  *size_out = size;
  return data;
}

static void write_file(const char *path, const uint8_t *data, size_t size) {
  FILE *file = fopen(path, "wb");
  if (file == NULL) {
    perror(path);
    exit(EXIT_FAILURE);
  }
  if (size != 0 && fwrite(data, 1, size, file) != size) {
    perror(path);
    fclose(file);
    exit(EXIT_FAILURE);
  }
  if (fclose(file) != 0) {
    perror(path);
    exit(EXIT_FAILURE);
  }
}

static size_t compress_bound(
  enum stream_format format,
  struct libdeflate_compressor *compressor,
  size_t input_size
) {
  switch (format) {
    case FORMAT_RAW:
      return libdeflate_deflate_compress_bound(compressor, input_size);
    case FORMAT_ZLIB:
      return libdeflate_zlib_compress_bound(compressor, input_size);
    case FORMAT_GZIP:
      return libdeflate_gzip_compress_bound(compressor, input_size);
  }
  die("unknown format");
  return 0;
}

static size_t compress_once(
  enum stream_format format,
  struct libdeflate_compressor *compressor,
  const uint8_t *input,
  size_t input_size,
  uint8_t *output,
  size_t output_capacity
) {
  switch (format) {
    case FORMAT_RAW:
      return libdeflate_deflate_compress(
        compressor, input, input_size, output, output_capacity
      );
    case FORMAT_ZLIB:
      return libdeflate_zlib_compress(
        compressor, input, input_size, output, output_capacity
      );
    case FORMAT_GZIP:
      return libdeflate_gzip_compress(
        compressor, input, input_size, output, output_capacity
      );
  }
  die("unknown format");
  return 0;
}

static enum libdeflate_result decompress_once(
  enum stream_format format,
  struct libdeflate_decompressor *decompressor,
  const uint8_t *input,
  size_t input_size,
  uint8_t *output,
  size_t output_capacity,
  size_t *actual_output_size
) {
  switch (format) {
    case FORMAT_RAW:
      return libdeflate_deflate_decompress(
        decompressor,
        input,
        input_size,
        output,
        output_capacity,
        actual_output_size
      );
    case FORMAT_ZLIB:
      return libdeflate_zlib_decompress(
        decompressor,
        input,
        input_size,
        output,
        output_capacity,
        actual_output_size
      );
    case FORMAT_GZIP:
      return libdeflate_gzip_decompress(
        decompressor,
        input,
        input_size,
        output,
        output_capacity,
        actual_output_size
      );
  }
  die("unknown format");
  return LIBDEFLATE_BAD_DATA;
}

static double monotonic_seconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    die("clock_gettime failed");
  }
  return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

struct sample_context {
  enum stream_format format;
  int level;
  int allocating;
  int decoding;
  const uint8_t *input;
  size_t input_size;
  const uint8_t *fixture;
  size_t fixture_size;
  uint8_t *output;
  size_t capacity;
  size_t expected_output_size;
  struct libdeflate_compressor *compressor;
  struct libdeflate_decompressor *decompressor;
};

static size_t sample_once(struct sample_context *s, int validate) {
  struct libdeflate_compressor *compressor = s->compressor;
  struct libdeflate_decompressor *decompressor = s->decompressor;
  uint8_t *output = s->output;
  size_t capacity = s->capacity;
  if (s->allocating) {
    if (s->decoding) {
      decompressor = libdeflate_alloc_decompressor();
      if (decompressor == NULL) die("could not allocate decompressor");
    } else {
      compressor = libdeflate_alloc_compressor(s->level);
      if (compressor == NULL) die("could not allocate compressor");
      capacity = compress_bound(s->format, compressor, s->input_size);
    }
    output = malloc(capacity == 0 ? 1 : capacity);
    if (output == NULL) die("could not allocate output");
  }
  size_t written = 0;
  if (s->decoding) {
    enum libdeflate_result result = decompress_once(
      s->format, decompressor, s->fixture, s->fixture_size,
      output, capacity, &written
    );
    if (result != LIBDEFLATE_SUCCESS || written != s->input_size)
      die("sample decompression failed");
  } else {
    written = compress_once(s->format, compressor, s->input, s->input_size,
                            output, capacity);
    if (written == 0 || written != s->expected_output_size)
      die("sample compression failed or changed size");
  }
  sink += written + (written == 0 ? 0 : output[written - 1]);
  if (validate) {
    if (s->decoding) {
      if (memcmp(output, s->input, s->input_size) != 0)
        die("allocated decode payload mismatch");
    } else {
      uint8_t *check = malloc(s->input_size == 0 ? 1 : s->input_size);
      size_t actual = 0;
      if (check == NULL) die("validation allocation failed");
      if (decompress_once(s->format, s->decompressor, output, written,
          check, s->input_size, &actual) != LIBDEFLATE_SUCCESS ||
          actual != s->input_size || memcmp(check, s->input, s->input_size) != 0)
        die("allocated compression payload mismatch");
      free(check);
    }
  }
  if (s->allocating) {
    free(output);
    if (s->decoding) libdeflate_free_decompressor(decompressor);
    else libdeflate_free_compressor(compressor);
  }
  return written;
}

static int sample_main(int argc, char **argv) {
  if (argc != 10)
    die("--sample bound|export|compress|decompress direct|oneshot raw|zlib|gzip LEVEL INPUT FIXTURE MILLISECONDS OUTPUT_CAPACITY");
  const char *operation = argv[2];
  struct sample_context s = {0};
  s.allocating = strcmp(argv[3], "oneshot") == 0;
  s.format = parse_format(argv[4]);
  if (!s.allocating && (strcmp(argv[3], "direct") != 0 || s.format != FORMAT_RAW))
    die("direct mode supports only raw DEFLATE");
  s.level = parse_level(argv[5]);
  uint8_t *input = read_file(argv[6], &s.input_size);
  s.input = input;
  size_t milliseconds = parse_size(argv[8], "milliseconds");
  size_t capacity = parse_size(argv[9], "output capacity");
  if (strcmp(operation, "bound") == 0) {
    if (s.allocating) die("bound requires direct mode");
    s.compressor = libdeflate_alloc_compressor(s.level);
    if (s.compressor == NULL) die("codec allocation failed");
    printf("%zu\n", compress_bound(s.format, s.compressor, s.input_size));
    libdeflate_free_compressor(s.compressor);
    free(input);
    return EXIT_SUCCESS;
  }
  s.decoding = strcmp(operation, "decompress") == 0;
  int exporting = strcmp(operation, "export") == 0;
  if (!s.decoding && !exporting && strcmp(operation, "compress") != 0)
    die("invalid operation");
  s.compressor = libdeflate_alloc_compressor(s.level);
  s.decompressor = libdeflate_alloc_decompressor();
  if (s.compressor == NULL || s.decompressor == NULL) die("codec allocation failed");
  size_t compressed_capacity = compress_bound(s.format, s.compressor, s.input_size);
  if (!s.allocating) {
    if (s.decoding) {
      if (capacity != s.input_size) die("decode capacity mismatch");
    } else {
      if (capacity < compressed_capacity) die("compression capacity below bound");
      compressed_capacity = capacity;
    }
  }
  uint8_t *compressed = malloc(compressed_capacity);
  uint8_t *decoded = malloc(s.input_size == 0 ? 1 : s.input_size);
  if (compressed == NULL || decoded == NULL) die("buffer allocation failed");
  // Match MoonBit's initialized buffers; first-touch cost is outside timing.
  memset(compressed, 0, compressed_capacity);
  memset(decoded, 0, s.input_size);
  size_t compressed_size = compress_once(s.format, s.compressor, input,
    s.input_size, compressed, compressed_capacity);
  if (compressed_size == 0) die("fixture compression failed");
  uint8_t *external_fixture = NULL;
  s.fixture = compressed;
  s.fixture_size = compressed_size;
  if (s.decoding) {
    external_fixture = read_file(argv[7], &s.fixture_size);
    s.fixture = external_fixture;
  }
  size_t decoded_size = 0;
  if (decompress_once(s.format, s.decompressor, s.fixture, s.fixture_size,
      decoded, s.input_size, &decoded_size) != LIBDEFLATE_SUCCESS ||
      decoded_size != s.input_size || memcmp(decoded, input, s.input_size) != 0)
    die("fixture payload mismatch");
  if (exporting) {
    write_file(argv[7], compressed, compressed_size);
  } else {
    s.output = s.decoding ? decoded : compressed;
    s.capacity = s.decoding ? s.input_size : compressed_capacity;
    s.expected_output_size = s.decoding ? s.input_size : compressed_size;
    sample_once(&s, 1);
    size_t iterations = 0;
    double seconds = 0;
    size_t written = s.expected_output_size;
    if (milliseconds > 0) {
      for (int i = 0; i < 3; i++) sample_once(&s, 0);
      iterations = 1;
    }
    while (milliseconds > 0) {
      double started = monotonic_seconds();
      for (size_t i = 0; i < iterations; i++) written = sample_once(&s, 0);
      seconds = monotonic_seconds() - started;
      if (seconds * 1000 >= milliseconds) break;
      if (iterations >= 536870912) die("calibration iteration limit");
      iterations *= 2;
    }
    // Validate the direct output after timing; allocating calls have freed theirs.
    if (s.allocating) written = sample_once(&s, 1);
    if (!s.allocating && !s.decoding) {
      if (decompress_once(s.format, s.decompressor, compressed, written,
          decoded, s.input_size, &decoded_size) != LIBDEFLATE_SUCCESS ||
          decoded_size != s.input_size) die("post-sample decompression failed");
    }
    if (memcmp(decoded, input, s.input_size) != 0) die("post-sample payload mismatch");
    printf("{\"iterations\":%zu,\"seconds\":%.9f,\"output_bytes\":%zu,\"sink\":%zu}\n",
           iterations, seconds, written, sink);
  }
  free(external_fixture);
  free(decoded);
  free(compressed);
  free(input);
  libdeflate_free_compressor(s.compressor);
  libdeflate_free_decompressor(s.decompressor);
  return EXIT_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "--sample") != 0)
    die("use benchmark/run.py to invoke the paired runner");
  return sample_main(argc, argv);
}
