#ifndef RFDETR_DETECTION_META_H_
#define RFDETR_DETECTION_META_H_

#include <glib.h>

typedef struct {
  gint class_id;
  gfloat left;
  gfloat top;
  gfloat width;
  gfloat height;
  gdouble confidence;
} RfdetrDetection;

typedef struct {
  guint count;
  RfdetrDetection *detections;
} RfdetrFrameDetections;

#endif
