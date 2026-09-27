#include "julia_runtime.h"
#include "onnxruntime_c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE
typedef void *JuliaLibrary;
extern void *julia_tokenizer_create_handle(const char *);
extern char *julia_tokenizer_encode_request(void *, const char *, uint32_t, uint32_t, bool);
extern const char *julia_tokenizer_last_error(void *);
extern void julia_tokenizer_free_string(char *);
extern void julia_tokenizer_destroy_handle(void *);
static JuliaLibrary open_library(const char *path) { (void)path; return (void *)1; }
static void *load_symbol(JuliaLibrary library, const char *name) {
    (void)library;
    if (!strcmp(name, "OrtGetApiBase")) return (void *)OrtGetApiBase;
    if (!strcmp(name, "julia_tokenizer_create_handle")) return (void *)julia_tokenizer_create_handle;
    if (!strcmp(name, "julia_tokenizer_encode_request")) return (void *)julia_tokenizer_encode_request;
    if (!strcmp(name, "julia_tokenizer_last_error")) return (void *)julia_tokenizer_last_error;
    if (!strcmp(name, "julia_tokenizer_free_string")) return (void *)julia_tokenizer_free_string;
    if (!strcmp(name, "julia_tokenizer_destroy_handle")) return (void *)julia_tokenizer_destroy_handle;
    return NULL;
}
static void close_library(JuliaLibrary library) { (void)library; }
#elif defined(_WIN32)
#include <windows.h>
typedef HMODULE JuliaLibrary;
static JuliaLibrary open_library(const char *path) {
    int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    wchar_t *wide_path = length > 0 ? calloc((size_t)length, sizeof(wchar_t)) : NULL;
    if (!wide_path) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide_path, length);
    JuliaLibrary library = LoadLibraryW(wide_path);
    free(wide_path);
    return library;
}
static void *load_symbol(JuliaLibrary library, const char *name) { return (void *)GetProcAddress(library, name); }
static void close_library(JuliaLibrary library) { if (library) FreeLibrary(library); }
#else
#include <dlfcn.h>
typedef void *JuliaLibrary;
static JuliaLibrary open_library(const char *path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
static void *load_symbol(JuliaLibrary library, const char *name) { return dlsym(library, name); }
static void close_library(JuliaLibrary library) { if (library) dlclose(library); }
#endif

struct JuliaRuntime {
    JuliaLibrary library;
    const OrtApi *api;
    OrtEnv *environment;
    OrtSession *session;
    OrtMemoryInfo *memory_info;
    char error[512];
};

struct JuliaTokenizer {
    JuliaLibrary library;
    void *handle;
    void *(*create)(const char *);
    char *(*encode)(void *, const char *, uint32_t, uint32_t, bool);
    const char *(*error)(void *);
    void (*release_string)(char *);
    void (*destroy)(void *);
    char message[512];
};

static bool accept_status(JuliaRuntime *runtime, OrtStatus *status) {
    if (!status) return true;
    snprintf(runtime->error, sizeof(runtime->error), "%s", runtime->api->GetErrorMessage(status));
    runtime->api->ReleaseStatus(status);
    return false;
}

const char *julia_runtime_error(const JuliaRuntime *runtime) {
    return runtime ? runtime->error : "Could not allocate Julia runtime";
}

void julia_runtime_destroy(JuliaRuntime *runtime) {
    if (!runtime) return;
    if (runtime->api) {
        if (runtime->session) runtime->api->ReleaseSession(runtime->session);
        if (runtime->memory_info) runtime->api->ReleaseMemoryInfo(runtime->memory_info);
        if (runtime->environment) runtime->api->ReleaseEnv(runtime->environment);
    }
    close_library(runtime->library);
    free(runtime);
}

JuliaRuntime *julia_runtime_create(const char *library_path, const char *model_path, int32_t thread_count) {
    JuliaRuntime *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) return NULL;
    runtime->library = open_library(library_path);
    if (!runtime->library) {
        snprintf(runtime->error, sizeof(runtime->error), "Could not load ONNX Runtime library: %s", library_path);
        return runtime;
    }
    const OrtApiBase *(*get_api_base)(void) = load_symbol(runtime->library, "OrtGetApiBase");
    if (!get_api_base) {
        snprintf(runtime->error, sizeof(runtime->error), "ONNX Runtime library has no OrtGetApiBase symbol");
        return runtime;
    }
    runtime->api = get_api_base()->GetApi(ORT_API_VERSION);
    if (!runtime->api) {
        snprintf(runtime->error, sizeof(runtime->error), "ONNX Runtime does not support API version %d", ORT_API_VERSION);
        return runtime;
    }
    OrtSessionOptions *options = NULL;
    if (!accept_status(runtime, runtime->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "julia.swift", &runtime->environment))) return runtime;
    if (!accept_status(runtime, runtime->api->CreateSessionOptions(&options))) return runtime;
    if (thread_count > 0 && !accept_status(runtime, runtime->api->SetIntraOpNumThreads(options, thread_count))) goto finish;
    if (!accept_status(runtime, runtime->api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))) goto finish;
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, 0, model_path, -1, NULL, 0);
    wchar_t *wide_path = length > 0 ? calloc((size_t)length, sizeof(wchar_t)) : NULL;
    if (!wide_path) {
        snprintf(runtime->error, sizeof(runtime->error), "Could not convert model path to UTF-16");
        goto finish;
    }
    MultiByteToWideChar(CP_UTF8, 0, model_path, -1, wide_path, length);
    OrtStatus *session_status = runtime->api->CreateSession(runtime->environment, wide_path, options, &runtime->session);
    free(wide_path);
#else
    OrtStatus *session_status = runtime->api->CreateSession(runtime->environment, model_path, options, &runtime->session);
#endif
    if (!accept_status(runtime, session_status)) goto finish;
    accept_status(runtime, runtime->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &runtime->memory_info));
finish:
    runtime->api->ReleaseSessionOptions(options);
    return runtime;
}

static bool create_tensor(JuliaRuntime *runtime, void *data, size_t byte_count, const int64_t *shape,
                          size_t dimension_count, ONNXTensorElementDataType type, OrtValue **value) {
    return accept_status(runtime, runtime->api->CreateTensorWithDataAsOrtValue(
        runtime->memory_info, data, byte_count, shape, dimension_count, type, value));
}

static bool copy_output(JuliaRuntime *runtime, OrtValue *result, int64_t batch_size,
                        int64_t option_count, float *output) {
    OrtTensorTypeAndShapeInfo *shape = NULL;
    if (!accept_status(runtime, runtime->api->GetTensorTypeAndShape(result, &shape))) return false;
    size_t dimension_count = 0;
    int64_t dimensions[2] = {0};
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    bool is_valid = accept_status(runtime, runtime->api->GetDimensionsCount(shape, &dimension_count));
    if (is_valid && dimension_count == 2) {
        is_valid = accept_status(runtime, runtime->api->GetDimensions(shape, dimensions, 2))
            && accept_status(runtime, runtime->api->GetTensorElementType(shape, &type));
    }
    runtime->api->ReleaseTensorTypeAndShapeInfo(shape);
    if (!is_valid) return false;
    if (dimension_count != 2 || dimensions[0] != batch_size || dimensions[1] != option_count
        || type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        snprintf(runtime->error, sizeof(runtime->error), "Model returned an unexpected logits shape or type");
        return false;
    }
    float *values = NULL;
    if (!accept_status(runtime, runtime->api->GetTensorMutableData(result, (void **)&values))) return false;
    memcpy(output, values, (size_t)batch_size * (size_t)option_count * sizeof(float));
    return true;
}

bool julia_runtime_run(JuliaRuntime *runtime, const int64_t *input_ids, const int64_t *attention_mask,
                       const int64_t *marker_positions, const bool *marker_mask, const int64_t *question_types,
                       int64_t batch_size, int64_t sequence_length, int64_t option_count, float *output) {
    if (!runtime || !runtime->session || !runtime->memory_info) return false;
    runtime->error[0] = '\0';
    const char *names[] = {"input_ids", "attention_mask", "marker_pos", "marker_mask", "qtype"};
    const char *output_names[] = {"logits"};
    OrtValue *inputs[5] = {0};
    OrtValue *result = NULL;
    int64_t sequence_shape[] = {batch_size, sequence_length};
    int64_t option_shape[] = {batch_size, option_count};
    int64_t type_shape[] = {batch_size};
    size_t sequence_bytes = (size_t)batch_size * (size_t)sequence_length * sizeof(int64_t);
    size_t option_bytes = (size_t)batch_size * (size_t)option_count;
    bool is_valid = create_tensor(runtime, (void *)input_ids, sequence_bytes, sequence_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0])
        && create_tensor(runtime, (void *)attention_mask, sequence_bytes, sequence_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[1])
        && create_tensor(runtime, (void *)marker_positions, option_bytes * sizeof(int64_t), option_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[2])
        && create_tensor(runtime, (void *)marker_mask, option_bytes, option_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, &inputs[3])
        && create_tensor(runtime, (void *)question_types, (size_t)batch_size * sizeof(int64_t), type_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[4]);
    if (is_valid) is_valid = accept_status(runtime, runtime->api->Run(runtime->session, NULL, names,
        (const OrtValue *const *)inputs, 5, output_names, 1, &result));
    if (is_valid) is_valid = copy_output(runtime, result, batch_size, option_count, output);
    if (result) runtime->api->ReleaseValue(result);
    for (size_t index = 0; index < 5; index++) if (inputs[index]) runtime->api->ReleaseValue(inputs[index]);
    return is_valid;
}

JuliaTokenizer *julia_tokenizer_create(const char *library_path, const char *tokenizer_path) {
    JuliaTokenizer *tokenizer = calloc(1, sizeof(*tokenizer));
    if (!tokenizer) return NULL;
    tokenizer->library = open_library(library_path);
    if (!tokenizer->library) {
        snprintf(tokenizer->message, sizeof(tokenizer->message), "Could not load tokenizer library: %s", library_path);
        return tokenizer;
    }
    tokenizer->create = load_symbol(tokenizer->library, "julia_tokenizer_create_handle");
    tokenizer->encode = load_symbol(tokenizer->library, "julia_tokenizer_encode_request");
    tokenizer->error = load_symbol(tokenizer->library, "julia_tokenizer_last_error");
    tokenizer->release_string = load_symbol(tokenizer->library, "julia_tokenizer_free_string");
    tokenizer->destroy = load_symbol(tokenizer->library, "julia_tokenizer_destroy_handle");
    if (!tokenizer->create || !tokenizer->encode || !tokenizer->error || !tokenizer->release_string || !tokenizer->destroy) {
        snprintf(tokenizer->message, sizeof(tokenizer->message), "Tokenizer library is missing required symbols");
        return tokenizer;
    }
    tokenizer->handle = tokenizer->create(tokenizer_path);
    if (!tokenizer->handle) snprintf(tokenizer->message, sizeof(tokenizer->message), "Could not load tokenizer: %s", tokenizer_path);
    return tokenizer;
}

char *julia_tokenizer_encode(JuliaTokenizer *tokenizer, const char *request, uint32_t max_length,
                             uint32_t head_length, bool strict) {
    if (!tokenizer || !tokenizer->handle) return NULL;
    return tokenizer->encode(tokenizer->handle, request, max_length, head_length, strict);
}

const char *julia_tokenizer_error(const JuliaTokenizer *tokenizer) {
    if (!tokenizer) return "Could not allocate tokenizer";
    if (tokenizer->message[0]) return tokenizer->message;
    return tokenizer->error(tokenizer->handle);
}

void julia_tokenizer_release_string(JuliaTokenizer *tokenizer, char *value) {
    if (tokenizer && value) tokenizer->release_string(value);
}

void julia_tokenizer_destroy(JuliaTokenizer *tokenizer) {
    if (!tokenizer) return;
    if (tokenizer->handle) tokenizer->destroy(tokenizer->handle);
    close_library(tokenizer->library);
    free(tokenizer);
}
