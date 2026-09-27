#ifndef JULIA_RUNTIME_H
#define JULIA_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct JuliaRuntime JuliaRuntime;
typedef struct JuliaTokenizer JuliaTokenizer;

JuliaRuntime *julia_runtime_create(const char *library_path, const char *model_path,
                                   const char *execution_provider, int32_t thread_count);
bool julia_runtime_run(JuliaRuntime *runtime, const int64_t *input_ids, const int64_t *attention_mask,
                       const int64_t *marker_positions, const bool *marker_mask, const int64_t *question_types,
                       int64_t batch_size, int64_t sequence_length, int64_t option_count, float *output);
const char *julia_runtime_error(const JuliaRuntime *runtime);
void julia_runtime_destroy(JuliaRuntime *runtime);

JuliaTokenizer *julia_tokenizer_create(const char *library_path, const char *tokenizer_path);
char *julia_tokenizer_encode(JuliaTokenizer *tokenizer, const char *request, uint32_t max_length,
                             uint32_t head_length, bool strict);
const char *julia_tokenizer_error(const JuliaTokenizer *tokenizer);
void julia_tokenizer_release_string(JuliaTokenizer *tokenizer, char *value);
void julia_tokenizer_destroy(JuliaTokenizer *tokenizer);

#endif
