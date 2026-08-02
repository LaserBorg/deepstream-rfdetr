#ifndef INFERENCER_DETECTION_META_H_
#define INFERENCER_DETECTION_META_H

#include <glib.h>

typedef struct {
  gint class_id;
  gfloat left;
  gfloat top;
  gfloat width;
  gfloat height;
  gdouble confidence;
  guint64 tracking_id;
} InferencerDetection;

typedef struct {
  guint count;
  InferencerDetection *detections;
} InferencerFrameDetections;

#endif
