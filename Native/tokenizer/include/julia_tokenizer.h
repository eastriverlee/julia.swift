#ifndef JULIA_TOKENIZER_H
#define JULIA_TOKENIZER_H

#include <stdbool.h>
#include <stdint.h>

void *julia_tokenizer_create_handle(const char *path);
char *julia_tokenizer_encode_request(void *handle, const char *request, uint32_t max_length,
                                     uint32_t head_length, bool strict);
const char *julia_tokenizer_last_error(void *handle);
void julia_tokenizer_free_string(char *value);
void julia_tokenizer_destroy_handle(void *handle);

#endif
