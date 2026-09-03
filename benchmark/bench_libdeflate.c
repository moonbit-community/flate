// Standalone libdeflate throughput benchmark for file-backed corpora.
// Build on this machine with:
//   cc -O3 -DNDEBUG bench_libdeflate.c $(pkg-config --cflags --libs libdeflate) -o /tmp/bench_libdeflate
//
// This measures codec work only: corpus I/O, allocations, and object creation
// happen outside the timed loops. Use the same corpus and format with the
// MoonBit benchmark before comparing results.

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
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

static void usage(const char *program) {
  fprintf(
    stderr,
    "Usage: %s [-l level] [-n iterations] [-f raw|zlib|gzip] INPUT\n"
    "\n"
    "Measures libdeflate compression and decompression over INPUT.\n"
    "The default iteration count processes about 256 MiB, clamped to 10..100000.\n"
    "-l, --level       Compression level 0..12 (default: 6)\n"
    "-n, --iterations  Timed iterations per phase\n"
    "-f, --format      Stream format: raw, zlib, or gzip (default: raw)\n",
    program
  );
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

static const char *format_name(enum stream_format format) {
  switch (format) {
    case FORMAT_RAW:
      return "raw-deflate";
    case FORMAT_ZLIB:
      return "zlib";
    case FORMAT_GZIP:
      return "gzip";
  }
  return "unknown";
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

static size_t default_iterations(size_t input_size) {
  const size_t target_bytes = 256 * 1024 * 1024;
  if (input_size == 0) {
    return 100000;
  }
  size_t iterations = target_bytes / input_size;
  if (target_bytes % input_size != 0) {
    iterations = iterations + 1;
  }
  if (iterations < 10) {
    return 10;
  }
  if (iterations > 100000) {
    return 100000;
  }
  return iterations;
}

static void print_rate(
  const char *name,
  size_t bytes_per_iteration,
  size_t iterations,
  double seconds
) {
  double total_mib =
    (double)bytes_per_iteration * (double)iterations / (1024.0 * 1024.0);
  double mib_per_second = seconds == 0.0 ? 0.0 : total_mib / seconds;
  printf(
    "%s: %.2f MiB/s  %.3f s  %zu iterations  %.1f MiB processed\n",
    name,
    mib_per_second,
    seconds,
    iterations,
    total_mib
  );
}

int main(int argc, char **argv) {
  int level = 6;
  size_t iterations = 0;
  enum stream_format format = FORMAT_RAW;
  const char *input_path = NULL;

  for (int i = 1; i < argc; i++) {
    const char *arg = argv[i];
    if (strcmp(arg, "-l") == 0 || strcmp(arg, "--level") == 0) {
      if (++i == argc) {
        usage(argv[0]);
        return EXIT_FAILURE;
      }
      level = parse_level(argv[i]);
    } else if (strcmp(arg, "-n") == 0 || strcmp(arg, "--iterations") == 0) {
      if (++i == argc) {
        usage(argv[0]);
        return EXIT_FAILURE;
      }
      iterations = parse_size(argv[i], "iteration count");
      if (iterations == 0) {
        die("iteration count must be positive");
      }
    } else if (strcmp(arg, "-f") == 0 || strcmp(arg, "--format") == 0) {
      if (++i == argc) {
        usage(argv[0]);
        return EXIT_FAILURE;
      }
      format = parse_format(argv[i]);
    } else if (arg[0] == '-') {
      usage(argv[0]);
      return EXIT_FAILURE;
    } else if (input_path == NULL) {
      input_path = arg;
    } else {
      usage(argv[0]);
      return EXIT_FAILURE;
    }
  }
  if (input_path == NULL) {
    usage(argv[0]);
    return EXIT_FAILURE;
  }

  size_t input_size;
  uint8_t *input = read_file(input_path, &input_size);
  if (iterations == 0) {
    iterations = default_iterations(input_size);
  }

  struct libdeflate_compressor *compressor =
    libdeflate_alloc_compressor(level);
  struct libdeflate_decompressor *decompressor =
    libdeflate_alloc_decompressor();
  if (compressor == NULL || decompressor == NULL) {
    die("could not allocate a libdeflate codec object");
  }

  size_t compressed_capacity = compress_bound(format, compressor, input_size);
  uint8_t *compressed = malloc(compressed_capacity == 0 ? 1 : compressed_capacity);
  uint8_t *decoded = malloc(input_size == 0 ? 1 : input_size);
  if (compressed == NULL || decoded == NULL) {
    die("could not allocate codec buffers");
  }

  size_t compressed_size = compress_once(
    format, compressor, input, input_size, compressed, compressed_capacity
  );
  if (compressed_size == 0) {
    die("compression did not fit in its documented bound");
  }
  size_t decoded_size = 0;
  enum libdeflate_result result = decompress_once(
    format,
    decompressor,
    compressed,
    compressed_size,
    decoded,
    input_size,
    &decoded_size
  );
  if (
    result != LIBDEFLATE_SUCCESS || decoded_size != input_size ||
    memcmp(input, decoded, input_size) != 0
  ) {
    die("libdeflate did not round-trip the input");
  }

  // Warm the codec objects and CPU caches; these calls are deliberately not timed.
  for (int i = 0; i < 3; i++) {
    sink += compress_once(
      format, compressor, input, input_size, compressed, compressed_capacity
    );
    result = decompress_once(
      format,
      decompressor,
      compressed,
      compressed_size,
      decoded,
      input_size,
      &decoded_size
    );
    if (result != LIBDEFLATE_SUCCESS || decoded_size != input_size) {
      die("decompression failed during warmup");
    }
  }

  double started = monotonic_seconds();
  for (size_t i = 0; i < iterations; i++) {
    compressed_size = compress_once(
      format, compressor, input, input_size, compressed, compressed_capacity
    );
    if (compressed_size == 0) {
      die("compression failed during measurement");
    }
    sink += compressed_size;
  }
  double compression_seconds = monotonic_seconds() - started;

  started = monotonic_seconds();
  for (size_t i = 0; i < iterations; i++) {
    result = decompress_once(
      format,
      decompressor,
      compressed,
      compressed_size,
      decoded,
      input_size,
      &decoded_size
    );
    if (result != LIBDEFLATE_SUCCESS || decoded_size != input_size) {
      die("decompression failed during measurement");
    }
    sink += decoded_size;
  }
  double decompression_seconds = monotonic_seconds() - started;
  if (memcmp(input, decoded, input_size) != 0) {
    die("decompression changed the input");
  }

  double ratio = input_size == 0 ? 0.0 :
    (double)compressed_size / (double)input_size;
  printf(
    "libdeflate %s, level %d, input %s (%zu bytes)\n",
    format_name(format),
    level,
    input_path,
    input_size
  );
  printf(
    "compressed: %zu bytes, ratio %.4f\n",
    compressed_size,
    ratio
  );
  print_rate("compress", input_size, iterations, compression_seconds);
  print_rate("decompress", input_size, iterations, decompression_seconds);
  printf("sink: %zu\n", sink);

  free(decoded);
  free(compressed);
  libdeflate_free_decompressor(decompressor);
  libdeflate_free_compressor(compressor);
  free(input);
  return EXIT_SUCCESS;
}
