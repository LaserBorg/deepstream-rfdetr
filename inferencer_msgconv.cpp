#include "nvmsgconv.h"

#include <glib.h>
#include "inferencer_detection_meta.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <string>
#include <vector>

namespace {

struct Context {
  std::vector<std::string> labels;
};

void append_json_string(GString *json, const gchar *value) {
  g_string_append_c(json, '"');
  if (value != nullptr) {
    for (const gchar *cursor = value; *cursor != '\0'; ++cursor) {
      switch (*cursor) {
        case '"':
          g_string_append(json, "\\\"");
          break;
        case '\\':
          g_string_append(json, "\\\\");
          break;
        case '\n':
          g_string_append(json, "\\n");
          break;
        case '\r':
          g_string_append(json, "\\r");
          break;
        case '\t':
          g_string_append(json, "\\t");
          break;
        default:
          g_string_append_c(json, *cursor);
          break;
      }
    }
  }
  g_string_append_c(json, '"');
}

void append_detection(GString *json, const InferencerDetection *detection,
                      const Context *context) {
  const auto class_id = static_cast<std::size_t>(std::max(detection->class_id, 0));
  const gchar *class_name = nullptr;
  if (class_id < context->labels.size()) {
    class_name = context->labels[class_id].c_str();
  }

  const float x1 = detection->left;
  const float y1 = detection->top;
  const float x2 = x1 + detection->width;
  const float y2 = y1 + detection->height;

  gchar number[32];
  g_string_append(json, "{\"bbox\":[");
  g_string_append(json, g_ascii_dtostr(number, sizeof(number), x1));
  g_string_append_c(json, ',');
  g_string_append(json, g_ascii_dtostr(number, sizeof(number), y1));
  g_string_append_c(json, ',');
  g_string_append(json, g_ascii_dtostr(number, sizeof(number), x2));
  g_string_append_c(json, ',');
  g_string_append(json, g_ascii_dtostr(number, sizeof(number), y2));
  g_string_append(json, "],\"class\":");
  append_json_string(json, class_name != nullptr ? class_name : "unknown");
  g_string_append(json, ",\"confidence\":");
  g_string_append(json, g_ascii_dtostr(number, sizeof(number), detection->confidence));
  g_string_append_printf(json, ",\"track_id\":%" G_GUINT64_FORMAT, detection->tracking_id);
  g_string_append_c(json, '}');
}

NvDsPayload *make_payload(const NvDsEvent *events, guint size,
                          const Context *context) {
  if (events == nullptr || size == 0) {
    return nullptr;
  }

  const NvDsEventMsgMeta *first_event = nullptr;
  for (guint index = 0; index < size; ++index) {
    if (events[index].metadata != nullptr) {
      first_event = events[index].metadata;
      break;
    }
  }
  if (first_event == nullptr) {
    return nullptr;
  }

  GString *json = g_string_new("{\"timestamp\":");
  append_json_string(json, first_event->ts);
  g_string_append(json, ",\"detections\":[");
  gboolean first_detection = TRUE;
  auto *frame_detections = static_cast<InferencerFrameDetections *>(first_event->extMsg);
  if (frame_detections != nullptr && frame_detections->count > 0) {
    for (guint index = 0; index < frame_detections->count; ++index) {
      if (!first_detection) {
        g_string_append_c(json, ',');
      }
      append_detection(json, &frame_detections->detections[index], context);
      first_detection = FALSE;
    }
  } else {
    for (guint index = 0; index < size; ++index) {
      if (events[index].metadata == nullptr) {
        continue;
      }
      InferencerDetection detection = {
          events[index].metadata->objClassId,
          events[index].metadata->bbox.left,
          events[index].metadata->bbox.top,
          events[index].metadata->bbox.width,
          events[index].metadata->bbox.height,
          events[index].metadata->confidence,
          events[index].metadata->trackingId};
      if (!first_detection) {
        g_string_append_c(json, ',');
      }
      append_detection(json, &detection, context);
      first_detection = FALSE;
    }
  }
  g_string_append(json, "]}");

  NvDsPayload *payload = g_new0(NvDsPayload, 1);
  payload->payload = g_string_free(json, FALSE);
  payload->payloadSize = static_cast<guint>(strlen(static_cast<gchar *>(payload->payload)));
  return payload;
}

}  // namespace

extern "C" NvDsMsg2pCtx *nvds_msg2p_ctx_create(const gchar *file,
                                                 NvDsPayloadType type) {
  auto *context = g_new0(Context, 1);
  if (file != nullptr) {
    GKeyFile *key_file = g_key_file_new();
    GError *error = nullptr;
    if (g_key_file_load_from_file(key_file, file, G_KEY_FILE_NONE, &error)) {
      gchar *labels_file = g_key_file_get_string(key_file, "custom", "labels-file", nullptr);
      if (labels_file != nullptr) {
        std::ifstream labels(labels_file);
        std::string label;
        while (std::getline(labels, label)) {
          if (!label.empty() && label.back() == '\r') {
            label.pop_back();
          }
          context->labels.push_back(label);
        }
        g_free(labels_file);
      }
    }
    g_clear_error(&error);
    g_key_file_unref(key_file);
  }

  auto *ctx = g_new0(NvDsMsg2pCtx, 1);
  ctx->payloadType = type;
  ctx->privData = context;
  return ctx;
}

extern "C" void nvds_msg2p_ctx_destroy(NvDsMsg2pCtx *ctx) {
  if (ctx == nullptr) {
    return;
  }
  delete static_cast<Context *>(ctx->privData);
  g_free(ctx);
}

extern "C" NvDsPayload *nvds_msg2p_generate(NvDsMsg2pCtx *ctx, NvDsEvent *events,
                                             guint size) {
  if (ctx == nullptr || events == nullptr || size == 0) {
    return nullptr;
  }
  return make_payload(events, size, static_cast<Context *>(ctx->privData));
}

extern "C" NvDsPayload **nvds_msg2p_generate_multiple(NvDsMsg2pCtx *ctx,
                                                        NvDsEvent *events,
                                                        guint size,
                                                        guint *payload_count) {
  if (payload_count == nullptr) {
    return nullptr;
  }
  *payload_count = 0;
  if (ctx == nullptr || events == nullptr || size == 0) {
    return nullptr;
  }

  auto **payloads = g_new0(NvDsPayload *, 1);
  payloads[0] = make_payload(events, size, static_cast<Context *>(ctx->privData));
  if (payloads[0] != nullptr) {
    *payload_count = 1;
  }
  return payloads;
}

extern "C" NvDsPayload *nvds_msg2p_generate_new(NvDsMsg2pCtx *, void *) {
  return nullptr;
}

extern "C" NvDsPayload **nvds_msg2p_generate_multiple_new(NvDsMsg2pCtx *,
                                                            void *,
                                                            guint *payload_count) {
  if (payload_count != nullptr) {
    *payload_count = 0;
  }
  return nullptr;
}

extern "C" void nvds_msg2p_release(NvDsMsg2pCtx *, NvDsPayload *payload) {
  if (payload == nullptr) {
    return;
  }
  g_free(payload->payload);
  g_free(payload);
}
