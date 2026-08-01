#include <gst/base/gstbasetransform.h>
#include <gst/gst.h>

#include "gstnvdsmeta.h"
#include "nvdsmeta_schema.h"

#ifndef PACKAGE
#define PACKAGE "deepstream-rfdetr"
#endif

typedef struct _RfdetrMsgMeta {
  GstBaseTransform parent;
  guint frame_interval;
  guint64 frame_number;
} RfdetrMsgMeta;

typedef struct _RfdetrMsgMetaClass {
  GstBaseTransformClass parent_class;
} RfdetrMsgMetaClass;

G_DEFINE_TYPE(RfdetrMsgMeta, rfdetr_msg_meta, GST_TYPE_BASE_TRANSFORM)

enum { PROP_0, PROP_FRAME_INTERVAL };

static void free_event(NvDsEventMsgMeta *event) {
  g_free(event->ts);
  g_free(event->objectId);
  g_free(event->sensorStr);
  g_free(event);
}

static gpointer copy_event_meta(gpointer data, gpointer user_data) {
  auto *source = static_cast<NvDsUserMeta *>(data);
  auto *source_event = static_cast<NvDsEventMsgMeta *>(source->user_meta_data);
  auto *copy = static_cast<NvDsEventMsgMeta *>(g_memdup2(source_event, sizeof(*source_event)));
  copy->ts = g_strdup(source_event->ts);
  copy->objectId = g_strdup(source_event->objectId);
  copy->sensorStr = g_strdup(source_event->sensorStr);
  return copy;
}

static void release_event_meta(gpointer data, gpointer user_data) {
  auto *meta = static_cast<NvDsUserMeta *>(data);
  free_event(static_cast<NvDsEventMsgMeta *>(meta->user_meta_data));
}

static gchar *timestamp_now() {
  GDateTime *now = g_date_time_new_now_utc();
  gchar *timestamp = g_date_time_format_iso8601(now);
  g_date_time_unref(now);
  return timestamp;
}

static GstFlowReturn transform_ip(GstBaseTransform *base, GstBuffer *buffer) {
  auto *self = reinterpret_cast<RfdetrMsgMeta *>(base);
  NvDsBatchMeta *batch_meta = gst_buffer_get_nvds_batch_meta(buffer);
  if (batch_meta == nullptr) {
    return GST_FLOW_OK;
  }

  self->frame_number++;
  if (self->frame_number % self->frame_interval != 0) {
    return GST_FLOW_OK;
  }

  for (NvDsMetaList *frame_node = batch_meta->frame_meta_list; frame_node != nullptr;
       frame_node = frame_node->next) {
    auto *frame_meta = static_cast<NvDsFrameMeta *>(frame_node->data);
    for (NvDsMetaList *object_node = frame_meta->obj_meta_list; object_node != nullptr;
         object_node = object_node->next) {
      auto *object_meta = static_cast<NvDsObjectMeta *>(object_node->data);
      auto *event = static_cast<NvDsEventMsgMeta *>(g_malloc0(sizeof(NvDsEventMsgMeta)));
      event->type = NVDS_EVENT_MOVING;
      event->objType = NVDS_OBJECT_TYPE_UNKNOWN;
      event->objClassId = object_meta->class_id;
      event->bbox.top = object_meta->rect_params.top;
      event->bbox.left = object_meta->rect_params.left;
      event->bbox.width = object_meta->rect_params.width;
      event->bbox.height = object_meta->rect_params.height;
      event->frameId = frame_meta->frame_num;
      event->trackingId = object_meta->object_id;
      event->confidence = object_meta->confidence;
      event->ts = timestamp_now();
      event->objectId = g_strdup(object_meta->obj_label);
      event->sensorStr = g_strdup_printf("source-%u", frame_meta->pad_index);

      NvDsUserMeta *user_meta = nvds_acquire_user_meta_from_pool(batch_meta);
      if (user_meta == nullptr) {
        free_event(event);
        continue;
      }
      user_meta->user_meta_data = event;
      user_meta->base_meta.meta_type = NVDS_EVENT_MSG_META;
      user_meta->base_meta.copy_func = copy_event_meta;
      user_meta->base_meta.release_func = release_event_meta;
      nvds_add_user_meta_to_frame(frame_meta, user_meta);
    }
  }
  return GST_FLOW_OK;
}

static void set_property(GObject *object, guint property_id, const GValue *value,
                         GParamSpec *pspec) {
  auto *self = reinterpret_cast<RfdetrMsgMeta *>(object);
  if (property_id == PROP_FRAME_INTERVAL) {
    self->frame_interval = g_value_get_uint(value);
  } else {
    G_OBJECT_WARN_INVALID_PROPERTY_ID(object, property_id, pspec);
  }
}

static void get_property(GObject *object, guint property_id, GValue *value,
                         GParamSpec *pspec) {
  auto *self = reinterpret_cast<RfdetrMsgMeta *>(object);
  if (property_id == PROP_FRAME_INTERVAL) {
    g_value_set_uint(value, self->frame_interval);
  } else {
    G_OBJECT_WARN_INVALID_PROPERTY_ID(object, property_id, pspec);
  }
}

static void rfdetr_msg_meta_class_init(RfdetrMsgMetaClass *klass) {
  auto *object_class = G_OBJECT_CLASS(klass);
  auto *transform_class = GST_BASE_TRANSFORM_CLASS(klass);
  object_class->set_property = set_property;
  object_class->get_property = get_property;
  g_object_class_install_property(
      object_class, PROP_FRAME_INTERVAL,
      g_param_spec_uint("frame-interval", "Frame interval",
                        "Attach events every Nth frame", 1, G_MAXUINT, 1,
                        static_cast<GParamFlags>(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS)));
  transform_class->transform_ip = transform_ip;
  gst_element_class_set_static_metadata(
      GST_ELEMENT_CLASS(klass), "RF-DETR message metadata", "Filter/Metadata",
      "Attaches DeepStream detection event metadata", "RidgeRun");
  gst_element_class_add_pad_template(
      GST_ELEMENT_CLASS(klass),
      gst_pad_template_new("sink", GST_PAD_SINK, GST_PAD_ALWAYS, gst_caps_new_any()));
  gst_element_class_add_pad_template(
      GST_ELEMENT_CLASS(klass),
      gst_pad_template_new("src", GST_PAD_SRC, GST_PAD_ALWAYS, gst_caps_new_any()));
}

static void rfdetr_msg_meta_init(RfdetrMsgMeta *self) {
  self->frame_interval = 1;
  self->frame_number = 0;
  gst_base_transform_set_passthrough(GST_BASE_TRANSFORM(self), FALSE);
}

static gboolean plugin_init(GstPlugin *plugin) {
  return gst_element_register(plugin, "rfdetrmsgmeta", GST_RANK_NONE,
                              rfdetr_msg_meta_get_type());
}

GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, rfdetrmsgmeta,
                  "RF-DETR DeepStream message metadata", plugin_init, "0.1.0",
                  "MIT", PACKAGE, "https://github.com/")