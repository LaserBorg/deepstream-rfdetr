# Detections, Tracking, and MQTT

## Detection Configuration

RF-DETR is a set-based detector, so the nvinfer configuration uses
`cluster-mode=4` and does not apply NMS or DBSCAN. The supported detector-side
controls are:

- `model.class_ids`: COCO class allowlist. Use `[]` for every class.
- `tracking.detector_threshold`: confidence threshold applied before detections
	reach the tracker.
- `tracking.min_detector_confidence`: native tracker input confidence floor.

Keep the two confidence thresholds equal unless a deliberately stricter second
filter is desired. The parser computes the winning class probability from the
RF-DETR logits and applies the configured per-class threshold.

## Tracking Configuration

The native `nvtracker` plugin writes persistent IDs into DeepStream metadata.
The current configuration supports `NvSORT`, `IOU`, `NvDCF`, and `NvDeepSORT`.
`NvDCF` provides stronger short-term occlusion handling but uses more GPU
resources than the simpler association modes.

```yaml
tracking:
	algorithm: "NvDCF"
	detector_threshold: 0.50
	min_detector_confidence: 0.50
	min_iou_diff_new_target: 0.15
	min_tracker_confidence: 0.75
	probation_age: 30
	early_termination_age: 10
	max_shadow_tracking_age: 24
	min_matching_iou: 0.35
	min_matching_score_overall: 0.60
```

`probation_age` is the main anti-flicker control. A target must persist for
more than this many frames before it becomes valid; `30` is approximately one
second at 30 FPS. `early_termination_age` allows a tentative target to survive
brief detector dropouts. Lower it to reject interrupted candidates sooner.

`min_iou_diff_new_target` suppresses a new detection when it overlaps an
existing target above the configured IoU. Lower values reject more overlapping
duplicates; `0.15` is intentionally aggressive for the stacked-box symptom.
`min_tracker_confidence` moves weakly localized tracks into shadow mode.
`max_shadow_tracking_age` controls how long a valid track can survive without a
strong detector update.

`min_matching_iou` and `min_matching_score_overall` reject weak associations.
Raising them can reduce false matches, but increases ID fragmentation. These
parameters apply most fully to NvDCF; simpler trackers do not use every field.

## MQTT Payload

The runner publishes one message per frame to the configured MQTT topic. The
message contains all detections in that frame:

```json
{
	"timestamp": "2026-08-01T12:05:47.201023Z",
	"detections": [
		{
			"bbox": [56.0, 88.0, 91.0, 121.0],
			"class": "person",
			"confidence": 0.934521,
			"track_id": 42
		}
	]
}
```

`bbox` uses pixel coordinates in `[x1, y1, x2, y2]` order. Class names come
from `coco91_labels.txt`; confidence is the RF-DETR detection confidence;
`track_id` is assigned by the native DeepStream tracker. The timestamp is UTC.

Inspect messages from another terminal:

```bash
conda activate py312
python -u mqtt-listener.py
```

The default topic is `vision/detections`. The HiveMQ broker uses TLS on port
`8883`; credentials come from `.env` through `pipeline_config.yml`.
