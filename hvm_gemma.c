#include "hvm.h"

#include <curl/curl.h>
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *data;
  size_t length;
} Buffer;

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
  Str prompt = readback_str(net, book, arg);
  const char *model = getenv("HVM_GEMMA_MODEL");
  if (model == NULL || model[0] == '\0') {
    model = "gemma4:26b";
  }
  struct json_object *request = json_object_new_object();
  struct json_object *options = json_object_new_object();
  json_object_object_add(request, "model", json_object_new_string(model));
  json_object_object_add(request, "prompt", json_object_new_string_len(prompt.buf, prompt.len));
  json_object_object_add(request, "stream", json_object_new_boolean(0));
  json_object_object_add(request, "think", json_object_new_boolean(0));
  json_object_object_add(request, "keep_alive", json_object_new_string("10m"));
  json_object_object_add(options, "num_ctx", json_object_new_int(2048));
  json_object_object_add(options, "temperature", json_object_new_double(0.0));
  json_object_object_add(options, "seed", json_object_new_int(42));
  json_object_object_add(options, "num_predict", json_object_new_int(256));
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
  curl_easy_setopt(curl, CURLOPT_URL, "http://127.0.0.1:11434/api/generate");
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_object_to_json_string_ext(request, JSON_C_TO_STRING_PLAIN));
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_response);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);

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
  free(prompt.buf);
  return result;
}
