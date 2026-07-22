#include "hvm.h"

#include <curl/curl.h>
#include <json-c/json.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>

typedef struct {
  char *data;
  size_t length;
} Buffer;

static int env_int(const char *name, int fallback, int minimum, int maximum, int *value) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == '\0') {
    *value = fallback;
    return 1;
  }
  char *end = NULL;
  errno = 0;
  long parsed = strtol(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0' || parsed < minimum || parsed > maximum) {
    return 0;
  }
  *value = (int)parsed;
  return 1;
}

static int env_double(const char *name, double fallback, double minimum, double maximum, double *value) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == '\0') {
    *value = fallback;
    return 1;
  }
  char *end = NULL;
  errno = 0;
  double parsed = strtod(raw, &end);
  if (errno != 0 || end == raw || *end != '\0' || parsed < minimum || parsed > maximum) {
    return 0;
  }
  *value = parsed;
  return 1;
}

static int env_bool(const char *name, int fallback, int *value) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == '\0') {
    *value = fallback;
    return 1;
  }
  if (strcmp(raw, "1") == 0 || strcmp(raw, "true") == 0) {
    *value = 1;
    return 1;
  }
  if (strcmp(raw, "0") == 0 || strcmp(raw, "false") == 0) {
    *value = 0;
    return 1;
  }
  return 0;
}

static int env_model(const char *name, const char *fallback, const char **value) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == '\0') {
    *value = fallback;
    return 1;
  }
  for (const unsigned char *p = (const unsigned char *)raw; *p != '\0'; ++p) {
    if (isgraph((int)*p) == 0) {
      return 0;
    }
  }
  *value = raw;
  return 1;
}

static int normalize_endpoint(const char *raw, char *normalized, size_t capacity) {
  size_t length = strlen(raw);
  if (length == 0 || length >= capacity) {
    return 0;
  }

  const char *scheme_http = "http://";
  const char *scheme_https = "https://";
  if (strncmp(raw, scheme_http, strlen(scheme_http)) != 0 &&
      strncmp(raw, scheme_https, strlen(scheme_https)) != 0) {
    return 0;
  }

  if (strpbrk(raw, "\t\r\n ") != NULL) {
    return 0;
  }

  memcpy(normalized, raw, length + 1);
  while (length > 0 && normalized[length - 1] == '/') {
    normalized[length - 1] = '\0';
    length--;
  }

  if (length == 0) {
    return 0;
  }
  return 1;
}

static int resolve_endpoint(char *value, size_t capacity) {
  const char *endpoint = getenv("HVM_GEMMA_ENDPOINT");
  if (endpoint == NULL || endpoint[0] == '\0') {
    endpoint = getenv("HVM_GEMMA_BASE_URL");
  }
  if (endpoint == NULL || endpoint[0] == '\0') {
    endpoint = getenv("OLLAMA_ENDPOINT");
  }
  if (endpoint == NULL || endpoint[0] == '\0') {
    endpoint = "http://127.0.0.1:11434";
  }
  return normalize_endpoint(endpoint, value, capacity);
}

static int env_keep_alive(const char *name, const char *fallback, char *value, size_t capacity) {
  const char *raw = getenv(name);
  if (raw == NULL || raw[0] == '\0') {
    raw = fallback;
  }

  char *end = NULL;
  errno = 0;
  long numeric = strtol(raw, &end, 10);
  if (errno != 0 || end == raw || numeric < 0) {
    return 0;
  }

  if (*end == '\0') {
    if (snprintf(value, capacity, "%ld", numeric) >= (int)capacity) {
      return 0;
    }
    return 1;
  }

  if (*(end + 1) != '\0') {
    return 0;
  }

  if (*end != 'm' && *end != 'h' && *end != 's' && *end != 'd') {
    return 0;
  }

  if (snprintf(value, capacity, "%ld%c", numeric, *end) >= (int)capacity) {
    return 0;
  }
  return 1;
}

static int read_file_bytes(const char *path, char **buf_out, size_t *len_out) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return 0;
  }

  size_t cap = 4096;
  size_t len = 0;
  char *buf = malloc(cap + 1);
  if (buf == NULL) {
    close(fd);
    return 0;
  }

  for (;;) {
    if (len == cap) {
      if (cap > (SIZE_MAX - 1) / 2) {
        free(buf);
        close(fd);
        return 0;
      }
      size_t next = cap * 2;
      char *grown = realloc(buf, next + 1);
      if (grown == NULL) {
        free(buf);
        close(fd);
        return 0;
      }
      buf = grown;
      cap = next;
    }
    ssize_t got = read(fd, buf + len, cap - len);
    if (got < 0) {
      if (errno == EINTR) continue;
      free(buf);
      close(fd);
      return 0;
    }
    if (got == 0) break;
    len += (size_t)got;
  }
  close(fd);
  buf[len] = '\0';
  *buf_out = buf;
  *len_out = len;
  return 1;
}

static size_t append_response(void *contents, size_t size, size_t count, void *userdata) {
  size_t incoming = size * count;
  Buffer *buffer = userdata;
  char *grown = realloc(buffer->data, buffer->length + incoming + 1);
  if (grown == NULL) {
    return 0;
  }
  buffer->data = grown;
  memcpy(buffer->data + buffer->length, contents, incoming);
  buffer->length += incoming;
  buffer->data[buffer->length] = '\0';
  return incoming;
}

static Port inject_text(Net *net, const char *text) {
  Bytes bytes = {
    .buf = (char *)text,
    .len = strlen(text),
  };
  return inject_bytes(net, &bytes);
}

Port gemma_generate(Net *net, Book *book, Port arg) {
  Str prompt = {0};
  const char *prompt_text = NULL;
  size_t prompt_length = 0;
  char *prompt_file_buf = NULL;
  const char *prompt_file = getenv("HVM_GEMMA_PROMPT_FILE");
  if (prompt_file != NULL && prompt_file[0] != '\0') {
    if (!read_file_bytes(prompt_file, &prompt_file_buf, &prompt_length)) {
      free(prompt.buf);
      return inject_text(net, "HVM_GEMMA_ERROR: failed to read prompt file");
    }
    prompt_text = prompt_file_buf;
  } else {
    prompt = readback_str(net, book, arg);
    prompt_text = prompt.buf;
    prompt_length = prompt.len;
  }

  const char *model = NULL;
  char endpoint_buffer[256];
  char keep_alive[128];
  int timeout_seconds;
  int num_ctx;
  int seed;
  int num_predict;
  int think;
  double temperature;

  if (!env_model("HVM_GEMMA_MODEL", "gemma4-hvm:official-q4", &model) ||
      !resolve_endpoint(endpoint_buffer, sizeof(endpoint_buffer)) ||
      !env_keep_alive("HVM_GEMMA_KEEP_ALIVE", "10m", keep_alive, sizeof(keep_alive)) ||
      !env_int("HVM_GEMMA_NUM_CTX", 2048, 128, 1048576, &num_ctx) ||
      !env_int("HVM_GEMMA_SEED", 42, INT_MIN, INT_MAX, &seed) ||
      !env_int("HVM_GEMMA_NUM_PREDICT", 256, 1, 1048576, &num_predict) ||
      !env_double("HVM_GEMMA_TEMPERATURE", 0.0, 0.0, 2.0, &temperature) ||
      !env_bool("HVM_GEMMA_THINK", 0, &think) ||
      !env_int("HVM_GEMMA_HTTP_TIMEOUT", 300, 1, 86400, &timeout_seconds)) {
    free(prompt_file_buf);
    free(prompt.buf);
    return inject_text(net, "HVM_GEMMA_ERROR: invalid generation environment");
  }

  struct json_object *request = json_object_new_object();
  struct json_object *options = json_object_new_object();
  json_object_object_add(request, "model", json_object_new_string(model));
  json_object_object_add(request, "prompt", json_object_new_string_len(prompt_text, prompt_length));
  json_object_object_add(request, "stream", json_object_new_boolean(0));
  json_object_object_add(request, "think", json_object_new_boolean(think));
  json_object_object_add(request, "keep_alive", json_object_new_string(keep_alive));
  json_object_object_add(options, "num_ctx", json_object_new_int(num_ctx));
  json_object_object_add(options, "temperature", json_object_new_double(temperature));
  json_object_object_add(options, "seed", json_object_new_int(seed));
  json_object_object_add(options, "num_predict", json_object_new_int(num_predict));
  json_object_object_add(request, "options", options);

  CURL *curl = curl_easy_init();
  Buffer response = {0};
  struct curl_slist *headers = NULL;
  Port result;
  if (curl == NULL) {
    result = inject_text(net, "HVM_GEMMA_ERROR: curl initialization failed");
    goto cleanup_json;
  }

  headers = curl_slist_append(headers, "Content-Type: application/json");
  char generate_url[2048];
  snprintf(generate_url, sizeof(generate_url), "%s/api/generate", endpoint_buffer);
  curl_easy_setopt(curl, CURLOPT_URL, generate_url);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_object_to_json_string_ext(request, JSON_C_TO_STRING_PLAIN));
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_response);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)timeout_seconds);

  CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    char message[512];
    snprintf(message, sizeof(message), "HVM_GEMMA_ERROR: %s", curl_easy_strerror(code));
    result = inject_text(net, message);
    goto cleanup_curl;
  }

  struct json_object *root = json_tokener_parse(response.data);
  struct json_object *generated = NULL;
  struct json_object *error = NULL;
  if (root != NULL && json_object_object_get_ex(root, "response", &generated)) {
    result = inject_text(net, json_object_get_string(generated));
  } else if (root != NULL && json_object_object_get_ex(root, "error", &error)) {
    char message[1024];
    snprintf(message, sizeof(message), "HVM_GEMMA_ERROR: %s", json_object_get_string(error));
    result = inject_text(net, message);
  } else {
    result = inject_text(net, "HVM_GEMMA_ERROR: invalid Ollama response");
  }
  if (root != NULL) {
    json_object_put(root);
  }

cleanup_curl:
  free(response.data);
  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);
  cleanup_json:
    json_object_put(request);
    free(prompt_file_buf);
    free(prompt.buf);
    return result;
}
