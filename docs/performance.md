# Performance and Tuning

## Measured Throughput

Measured on a Jetson Orin Nano Super in 25 W mode using the 1080p30 sample
clip. The fakesink test processed 1,443 frames in 48.1 seconds and includes
hardware decode overhead.

| Model | Precision | Inference FPS | With FHD x264 encoding |
|---|---:|---:|---:|
| `rfdetr-nano` | FP16 | 154 | — |
| `rfdetr-small` | FP16 | 90 | 24.8 |
| `rfdetr-medium` | FP16 | 72 | 28 |

FP16 engine creation takes several minutes on the first run. Detection quality
can differ slightly from FP32 and should be validated for the target scene.

## Reproduce Measurements

```bash
gst-launch-1.0 -e \
	filesrc location=/opt/nvidia/deepstream/deepstream/samples/streams/sample_1080p_h264.mp4 \
	! decodebin ! queue ! mux.sink_0 \
	nvstreammux name=mux width=1920 height=1080 batch-size=1 ! queue ! \
	nvinfer config-file-path=inferencer_bbox_config.txt ! \
	queue ! fakesink
```

For encoded output, use `./run_pipeline.sh --input file --output file`.

## Performance Controls

The pipeline processes frames at `streammux.width` and `streammux.height`, not
at the full source resolution. Lowering these values reduces inference and
encoding work but can reduce small-object recall. Encoder dimensions under
`outputs.rtsp.encoder` are independent.

For maximum throughput on the target board:

```bash
sudo nvpmodel -m 2
sudo jetson_clocks
```

Use `runtime.identity_sync: false` for file benchmarking when real-time pacing
is not required. Keep it `true` for HLS, RTSP, and WebRTC playback.

## Stability Versus Throughput

Increasing `probation_age`, association thresholds, or detector thresholds can
reduce flicker and false tracks, but may delay valid IDs or fragment tracks.
`NvDCF` generally costs more than `NvSORT` or `IOU`; `NvDeepSORT` adds
appearance-based re-identification and has the highest resource use.

The `file` output uses software `x264enc` because the Orin Nano Super has no
hardware video encoder. RTSP and WebRTC also pass through this encoder before
MediaMTX, so output resolution, bitrate, and `iframeinterval` affect CPU load
and latency.

## Development Checks

```bash
make DEV=1
make format
make lint
make clean
```
