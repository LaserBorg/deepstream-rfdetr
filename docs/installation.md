# Installation and Operation

## Target Platform

| Component | Version / detail |
|---|---|
| Board | Jetson Orin Nano Super 8 GB (p3767-0005) |
| GPU | Ampere, sm_87 |
| JetPack | 7.2 GA (L4T R39.2.0) |
| OS | Ubuntu 24.04 (Noble) |
| DeepStream | 9.1 |
| TensorRT | 10.16.2 |
| CUDA | 13.2 |
| Compiler | GCC 13.3.0, C++20 |

The Orin Nano Super has no DLA cores and no hardware video encoder. File and
preview output therefore use software `x264enc`.

## Dependencies

```bash
sudo apt update && sudo apt install -y deepstream-9.1
sudo apt install -y \
	ca-certificates curl libmosquitto1 mosquitto-clients \
	gstreamer1.0-tools gstreamer1.0-plugins-base \
	gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
	gstreamer1.0-plugins-ugly gstreamer1.0-libav \
	libgstrtspserver-1.0-0
```

`libmosquitto1` is required by DeepStream's native MQTT adaptor.
`mosquitto-clients` is optional and provides diagnostic CLI tools. Install
`cuda-toolkit-13-2` only when `nvcc` is needed for other development work.

Install `uv` for the isolated model downloader:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Install the Python listener environment:

```bash
conda create -n py312 python=3.12 -y
conda activate py312
python -m pip install -r requirements.txt
```

Install MediaMTX on ARM64:

```bash
cd /tmp
curl -sL "https://github.com/bluenviron/mediamtx/releases/download/v1.19.3/mediamtx_v1.19.3_linux_arm64.tar.gz" -o mediamtx.tar.gz
tar xzf mediamtx.tar.gz
sudo mv mediamtx /usr/local/bin/
```

## Build and Model Setup

```bash
make
make setup MODEL=rfdetr-small PRECISION=fp16
```

Available models are `rfdetr-nano`, `rfdetr-small`, `rfdetr-medium`, and
`rfdetr-large`. Supported precisions are `fp16` and `fp32`. The runner repeats
model setup from `pipeline_config.yml` when it starts, and TensorRT engines are
cached in `checkpoints/`.

## Configuration

Set MQTT credentials in `.env`:

```bash
HIVEMQ_MQTT_USER='your-hivemq-username'
HIVEMQ_MQTT_PASSWORD='your-hivemq-password'
```

The default source is the HLS URI in `pipeline_config.yml`. Use
`source.type: file` with a `file://` URI for a local file. Override the HLS
source for one run with `--hls-uri` or the `/start` API's `hls_uri` field.

## Run Manually

```bash
./run_pipeline.sh --input hls --output webrtc
./run_pipeline.sh --input file --output file
```

Use `GST_LAUNCH_QUIET=false MEDIAMTX_LOG_LEVEL=info` for verbose diagnostics.
Timing values can be overridden with `STREAM_OFFSET_SECONDS`,
`SEGMENT_DURATION_SECONDS`, and `CAPTURE_DURATION_SECONDS`.

## REST Service

```bash
echo "INFERENCER_API_KEY=$(openssl rand -hex 32)" >> .env
sudo ./install-service.sh
```

The service listens on port `8090`. Manage it with:

```bash
sudo systemctl status inferencer
sudo systemctl restart inferencer
sudo systemctl stop inferencer
journalctl -u inferencer -f
```

See [architecture.md](architecture.md) for the API lifecycle and
[detections.md](detections.md) for MQTT output.
