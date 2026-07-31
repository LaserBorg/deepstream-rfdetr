# DeepStream RF-DETR — Orin Nano Super

Run [RF-DETR](https://github.com/roboflow/rf-detr) object detection on NVIDIA
DeepStream, tailored for the **Jetson Orin Nano Super (8 GB)** with
**JetPack 7.2**.

Forked from [RidgeRun/deepstream-rfdetr](https://github.com/ridgerun/deepstream-rfdetr)
and stripped down to a single target platform.

## Target Platform

| Component    | Version / Detail                          |
|--------------|-------------------------------------------|
| Board        | Jetson Orin Nano Super 8 GB (p3767-0005)  |
| GPU arch     | Ampere, sm_87                             |
| JetPack      | 7.2 GA (L4T R39.2.0)                     |
| OS           | Ubuntu 24.04 (Noble)                      |
| DeepStream   | 9.1                                       |
| TensorRT     | 10.16.2                                   |
| CUDA         | 13.2                                      |
| Compiler     | GCC 13.3.0, C++20                         |

> **Note:** The Orin Nano Super has no DLA cores and no hardware video
> encoder. Use `x264enc` (software) for file output pipelines.

## Quick Start

### 1. Install DeepStream

```bash
# install uv (once)
curl -LsSf https://astral.sh/uv/install.sh | sh
```

```bash
sudo apt update && sudo apt install -y deepstream-9.1
```

This pulls in TensorRT, cuDNN, and all required GStreamer plugins.
If you also need `nvcc` (e.g. building PyTorch from source):

```bash
sudo apt install -y cuda-toolkit-13-2
```

### 2. Build the parser library

```bash
make
```

Produces `libdeepstream-rfdetr.so`.

### 3. set model size and precision

```bash
# Download weights & configure
make setup  # defaults: rfdetr-small, fp16
```

Or edit modelsize / precision in the `Makefile`:

```bash
make setup MODEL=rfdetr-medium PRECISION=fp32
```

This downloads the ONNX into `checkpoints/` and updates the nvinfer config
to point at it. Available models: `rfdetr-nano`, `rfdetr-small`,
`rfdetr-medium`, `rfdetr-large`.

### 4. Run inference

```bash
gst-launch-1.0 -e \
  filesrc location=/opt/nvidia/deepstream/deepstream/samples/streams/sample_1080p_h264.mp4 \
  ! decodebin ! queue ! mux.sink_0 \
  nvstreammux name=mux width=1920 height=1080 batch-size=1 ! \
  nvinfer config-file-path=deepstream_rfdetr_bbox_config.txt ! \
  queue ! nvdsosd ! nvvideoconvert ! x264enc ! h264parse ! mp4mux ! \
  filesink location=output.mp4
```

Adjust `nvstreammux` width/height to match your input resolution.

DeepStream sources and samples: `/opt/nvidia/deepstream/deepstream-9.1`

### 5. Inference-only benchmark (no encoding overhead)

```bash
gst-launch-1.0 -e \
  filesrc location=/opt/nvidia/deepstream/deepstream/samples/streams/sample_1080p_h264.mp4 \
  ! decodebin ! queue ! mux.sink_0 \
  nvstreammux name=mux width=1920 height=1080 batch-size=1 ! queue ! \
  nvinfer config-file-path=deepstream_rfdetr_bbox_config.txt ! \
  queue ! fakesink
```

## Performance (Orin Nano Super, 25 W mode)

Measured with the fakesink pipeline above on the 1080p30 sample clip
(48.1 s = 1443 frames, includes HW decode overhead).

| Model         | Precision | Inference FPS | w/ FHD x264 encoding |
|---------------|-----------|---------------|----------------------|
| rfdetr-nano   | FP16      | 154           | —                    |
| rfdetr-small  | FP16      | 90            | —                    |
| rfdetr-medium | FP16      | 72            | 28                   |

> FP16 engine build takes a few minutes on first run. Detection quality may
> degrade slightly in FP16 — validate for your use case.

## Switching Models / Precision

```bash
make setup MODEL=rfdetr-medium PRECISION=fp16
```

This downloads the weights (if not already present) and rewrites
`deepstream_rfdetr_bbox_config.txt` for you. You can also run the steps
individually:

```bash
make weights MODEL=rfdetr-medium   # download only
make config  MODEL=rfdetr-medium PRECISION=fp16  # update config only
```

> **Note:** All paths in the config are relative to the config file's
> directory. Model files live in `checkpoints/`; the `.so` and labels stay
> in the project root. The TensorRT engine is built automatically on first
> run and cached in `checkpoints/`.

## Key Config Properties

| Property               | Value / Purpose                              |
|------------------------|----------------------------------------------|
| `net-scale-factor`     | `0.0173520736` (1/255/avg_std)               |
| `offsets`              | `123.675;116.28;103.53` (ImageNet means×255) |
| `custom-lib-path`      | `libdeepstream-rfdetr.so` (relative to config) |
| `parse-bbox-func-name` | `deepstream_rfdetr_bbox`                     |
| `num-detected-classes` | `91` (COCO 90 + background)                  |
| `model-color-format`   | `0` (RGB)                                    |
| `network-type`         | `0` (Detector)                               |
| `cluster-mode`         | `4` (no clustering — DETR is set-based)      |
| `maintain-aspect-ratio`| `1`                                          |
| `symmetric-padding`    | `1`                                          |
| `network-input-order`  | `0` (NCHW)                                   |

## Development

```bash
make DEV=1      # debug build, -Werror
make format     # clang-format
make lint       # clang-tidy
make clean
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).

