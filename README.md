# INFERENCER

RF-DETR inference and object tracking for the Jetson Orin Nano Super. The
pipeline uses DeepStream and TensorRT for detection, NVIDIA native tracking for
persistent IDs, MQTT for telemetry, and MediaMTX for RTSP/WebRTC preview.

Based on [RidgeRun/deepstream-rfdetr](https://github.com/ridgerun/deepstream-rfdetr),
with DeepStream 9.1 and JetPack 7.2 on the Orin Nano (sm_87).

![tracker](docs/track.jpg)

## Quick Start

Install dependencies, build the native libraries, configure MQTT credentials,
and prepare a model:

```bash
conda activate py312
python -m pip install -r requirements.txt
make
make setup MODEL=rfdetr-small PRECISION=fp16
./run_pipeline.sh --input hls --output webrtc
```

The default WebRTC preview is available at:

`http://<server>:8889/inferencer/`

For complete setup, service installation, and troubleshooting, see
[Installation](docs/installation.md).

## Documentation

- [Architecture and control API](docs/architecture.md): runtime flow,
  components, outputs, and REST lifecycle.
- [Installation and operation](docs/installation.md): platform prerequisites,
  dependencies, build, model setup, configuration, and systemd service.
- [Detections and tracking](docs/detections.md): detector behavior, tracker
  tuning, MQTT payloads, and telemetry inspection.
- [Performance and tuning](docs/performance.md): benchmarks, reproducibility,
  Jetson performance mode, and throughput tradeoffs.

## Repository Guide

- `pipeline_config.yml`: runtime source, model, tracker, output, and MQTT
  settings.
- `run_pipeline.sh`: standalone pipeline runner.
- `pipeline_controller.py`: authenticated REST control service.
- `inferencer_bbox.cpp`: TensorRT/RF-DETR bounding-box parser.
- `inferencer_msgmeta.cpp` and `inferencer_msgconv.cpp`: MQTT metadata bridge.
- `checkpoints/`: downloaded ONNX weights and cached TensorRT engines.

## License

See [LICENSE.txt](LICENSE.txt).
