#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -n "${GST_PLUGIN_PATH:-}" ]]; then
  export GST_PLUGIN_PATH="$project_root:$GST_PLUGIN_PATH"
else
  export GST_PLUGIN_PATH="$project_root"
fi
if [[ -f "$project_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$project_root/.env"
  set +a
fi

usage() {
  echo "Usage: $0 [--config pipeline_config.yml] [--input file|hls] [--model-size size] [--precision fp16|fp32] [--run-until-stopped] --output file|rtsp|webrtc" >&2
}

output=''
input_override=''
model_override=''
precision_override=''
run_until_stopped=false
config_path='pipeline_config.yml'
while (($#)); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      config_path=$2
      shift 2
      ;;
    --config=*)
      config_path=${1#--config=}
      shift
      ;;
    --input)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      input_override=$2
      shift 2
      ;;
    --input=*)
      input_override=${1#--input=}
      shift
      ;;
    --model-size)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      model_override=$2
      shift 2
      ;;
    --model-size=*)
      model_override=${1#--model-size=}
      shift
      ;;
    --precision)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      precision_override=$2
      shift 2
      ;;
    --precision=*)
      precision_override=${1#--precision=}
      shift
      ;;
    --run-until-stopped)
      run_until_stopped=true
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output=$2
      shift 2
      ;;
    --output=*)
      output=${1#--output=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ "$output" == file || "$output" == rtsp || "$output" == webrtc ]] || { usage; exit 2; }
[[ -z "$input_override" || "$input_override" == file || "$input_override" == hls ]] || { usage; exit 2; }
[[ -f "$config_path" ]] || { echo "Config file not found: $config_path" >&2; exit 2; }

mapfile -t config_values < <(python3 - "$config_path" <<'PY'
import sys
import os
import yaml

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = yaml.safe_load(config_file) or {}

try:
    source = config["source"]
    model = config["model"]
    runtime = config["runtime"]
    streammux = config["streammux"]
    rtsp = config["outputs"]["rtsp"]
    encoder = rtsp["encoder"]
    hivemq = next(broker for broker in config["mqtt"]["brokers"] if broker["name"] == "hivemq")
    username = hivemq["username"]
    password = hivemq["password"]
    if isinstance(username, str) and username.startswith("${") and username.endswith("}"):
      username = os.environ.get(username[2:-1], "")
    if isinstance(password, str) and password.startswith("${") and password.endswith("}"):
      password = os.environ.get(password[2:-1], "")
    values = (
        source["type"],
        source.get("hls_uri", ""),
        source.get("file_uri", ""),
        model["size"],
        model["precision"],
        ";".join(str(class_id) for class_id in model.get("class_ids", [])),
        config.get("tracking", {}).get("algorithm", "NvSORT"),
        config.get("tracking", {}).get("detector_threshold", 0.5),
        config.get("tracking", {}).get("min_detector_confidence", 0.5),
        config.get("tracking", {}).get("min_iou_diff_new_target", 0.5),
        config.get("tracking", {}).get("min_tracker_confidence", 0.5),
        config.get("tracking", {}).get("probation_age", 4),
        config.get("tracking", {}).get("max_shadow_tracking_age", 38),
        config.get("tracking", {}).get("min_matching_iou", 0.0),
        source.get("stream_offset_seconds", 0),
        runtime["hls_segment_duration_seconds"],
        runtime["file_segment_duration_seconds"],
        runtime["capture_duration_seconds"],
        runtime["grace_seconds"],
        str(runtime["identity_sync"]).lower(),
        streammux["batch_size"],
        streammux["width"],
        streammux["height"],
        rtsp["port"],
        rtsp["mount_point"],
        encoder["width"],
        encoder["height"],
        encoder["bitrate_mbps"],
        encoder["iframeinterval"],
        encoder["profile"],
        config["mqtt"]["topic"],
        hivemq["host"],
        hivemq["port"],
        username,
        password,
    )
except (KeyError, TypeError) as error:
    sys.exit(f"Invalid pipeline configuration: missing {error}")

for value in values:
    print(value)
PY
)

[[ ${#config_values[@]} -eq 35 ]] || { echo 'Unable to read pipeline configuration.' >&2; exit 2; }
source_type=${config_values[0]}
hls_uri=${config_values[1]}
file_uri=${config_values[2]}
model_size=${config_values[3]}
model_precision=${config_values[4]}
[[ -z "$model_override" ]] || model_size=$model_override
[[ -z "$precision_override" ]] || model_precision=$precision_override
class_ids=${config_values[5]}
tracker_algorithm=${config_values[6]}
detector_threshold=${config_values[7]}
min_detector_confidence=${config_values[8]}
min_iou_diff_new_target=${config_values[9]}
min_tracker_confidence=${config_values[10]}
probation_age=${config_values[11]}
max_shadow_tracking_age=${config_values[12]}
min_matching_iou=${config_values[13]}
stream_offset_seconds=${config_values[14]}
hls_segment_duration_seconds=${config_values[15]}
file_segment_duration_seconds=${config_values[16]}
capture_duration_seconds=${config_values[17]}
grace_seconds=${config_values[18]}
identity_sync=${config_values[19]}
batch_size=${config_values[20]}
mux_width=${config_values[21]}
mux_height=${config_values[22]}
rtsp_port=${config_values[23]}
rtsp_mount_point=${config_values[24]}
output_width=${config_values[25]}
output_height=${config_values[26]}
bitrate_mbps=${config_values[27]}
iframeinterval=${config_values[28]}
profile=${config_values[29]}
mqtt_topic=${config_values[30]}
mqtt_host=${config_values[31]}
mqtt_port=${config_values[32]}
mqtt_username=${config_values[33]}
mqtt_password=${config_values[34]}
deepstream_home="${DS_HOME:-/opt/nvidia/deepstream/deepstream-9.1}"
mqtt_proto_lib="$deepstream_home/lib/libnvds_mqtt_proto.so"
msgconv_lib="$project_root/librfdetrmsgconv.so"

[[ "$model_size" == rfdetr-nano || "$model_size" == rfdetr-small || "$model_size" == rfdetr-medium || "$model_size" == rfdetr-large ]] || {
  echo 'model.size must be rfdetr-nano, rfdetr-small, rfdetr-medium, or rfdetr-large.' >&2
  exit 2
}
[[ "$model_precision" == fp16 || "$model_precision" == fp32 ]] || {
  echo 'model.precision must be fp16 or fp32.' >&2
  exit 2
}
excluded_class_ids=$(python3 - "$class_ids" <<'PY'
import sys

selected = {int(value) for value in sys.argv[1].split(";") if value}
if any(class_id < 1 or class_id > 90 for class_id in selected):
    raise SystemExit("model.class_ids must contain COCO class IDs from 1 through 90.")
print(";".join(str(class_id) for class_id in range(1, 91) if class_id not in selected) if selected else "")
PY
)
awk -v excluded="$excluded_class_ids" 'BEGIN { updated = 0 } /^#?filter-out-class-ids=/ { if (excluded == "") print "#filter-out-class-ids="; else print "filter-out-class-ids=" excluded; updated = 1; next } { print } END { if (!updated && excluded != "") print "filter-out-class-ids=" excluded }' \
  deepstream_rfdetr_bbox_config.txt > deepstream_rfdetr_bbox_config.txt.tmp
mv deepstream_rfdetr_bbox_config.txt.tmp deepstream_rfdetr_bbox_config.txt
for threshold in "$detector_threshold" "$min_detector_confidence" "$min_iou_diff_new_target" "$min_tracker_confidence" "$min_matching_iou"; do
  [[ "$threshold" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] &&
    awk -v value="$threshold" 'BEGIN { exit !(value >= 0 && value <= 1) }' || {
    echo 'Tracking thresholds must be in the range 0..1.' >&2
    exit 2
  }
done
[[ "$probation_age" =~ ^[0-9]+$ && "$probation_age" -gt 0 ]] || { echo 'tracking.probation_age must be a positive integer.' >&2; exit 2; }
[[ "$max_shadow_tracking_age" =~ ^[0-9]+$ && "$max_shadow_tracking_age" -gt 0 ]] || { echo 'tracking.max_shadow_tracking_age must be a positive integer.' >&2; exit 2; }
awk -v threshold="$detector_threshold" 'BEGIN { updated = 0 } /^pre-cluster-threshold=/ { print "pre-cluster-threshold=" threshold; updated = 1; next } { print } END { if (!updated) exit 1 }' \
  deepstream_rfdetr_bbox_config.txt > deepstream_rfdetr_bbox_config.txt.tmp
mv deepstream_rfdetr_bbox_config.txt.tmp deepstream_rfdetr_bbox_config.txt
case "$tracker_algorithm" in
  NvSORT) tracker_config="$deepstream_home/samples/configs/deepstream-app/config_tracker_NvSORT.yml" ;;
  IOU) tracker_config="$deepstream_home/samples/configs/deepstream-app/config_tracker_IOU.yml" ;;
  NvDCF) tracker_config="$deepstream_home/samples/configs/deepstream-app/config_tracker_NvDCF_accuracy.yml" ;;
  NvDeepSORT) tracker_config="$deepstream_home/samples/configs/deepstream-app/config_tracker_NvDeepSORT.yml" ;;
  *) echo 'tracking.algorithm must be NvSORT, IOU, NvDCF, or NvDeepSORT.' >&2; exit 2 ;;
esac
[[ -f "$tracker_config" ]] || { echo "Native tracker config not found: $tracker_config" >&2; exit 2; }
tracker_runtime_config=$(mktemp --suffix=.yml)
python3 - "$tracker_config" "$tracker_runtime_config" "$min_detector_confidence" "$min_iou_diff_new_target" "$min_tracker_confidence" "$probation_age" "$max_shadow_tracking_age" "$min_matching_iou" <<'PY'
import re
import sys

source, destination, min_detector, min_iou_new, min_tracker, probation, shadow_age, matching_iou = sys.argv[1:]
replacements = {
  "BaseConfig.minDetectorConfidence": min_detector,
  "TargetManagement.minIouDiff4NewTarget": min_iou_new,
  "TargetManagement.minTrackerConfidence": min_tracker,
  "TargetManagement.probationAge": probation,
  "TargetManagement.maxShadowTrackingAge": shadow_age,
  "DataAssociator.minMatchingScore4Iou": matching_iou,
}
section = None
with open(source, encoding="utf-8") as input_file, open(destination, "w", encoding="utf-8") as output_file:
  for line in input_file:
    section_match = re.match(r"^([A-Za-z]+):\s*$", line)
    if section_match:
      section = section_match.group(1)
    key = line.split("#", 1)[0].split(":", 1)[0].strip()
    replacement_key = f"{section}.{key}"
    if replacement_key in replacements:
      line = re.sub(r"(^\s*" + re.escape(key) + r"\s*:\s*)[^#\n]+", r"\g<1>" + replacements[replacement_key] + " ", line)
    output_file.write(line)
PY
[[ "$identity_sync" == true || "$identity_sync" == false ]] || {
  echo 'runtime.identity_sync must be true or false.' >&2
  exit 2
}

command -v make >/dev/null || { echo 'make is required to prepare the configured model.' >&2; exit 127; }
make setup MODEL="$model_size" PRECISION="$model_precision"
make all MODEL="$model_size" PRECISION="$model_precision"

if [[ -n "$input_override" ]]; then
  source_type=$input_override
fi

case "$source_type" in
  hls)
    input_uri=$hls_uri
    ;;
  file)
    input_uri=$file_uri
    ;;
  csi)
    echo 'CSI input is configured but is not implemented yet.' >&2
    exit 2
    ;;
  *)
    echo "Unsupported source.type: $source_type" >&2
    exit 2
    ;;
esac

[[ -n "$input_uri" ]] || { echo "source.${source_type}_uri must not be empty." >&2; exit 2; }
[[ "$batch_size" =~ ^[0-9]+$ && "$batch_size" -gt 0 ]] || { echo 'streammux.batch_size must be a positive integer.' >&2; exit 2; }
[[ "$mux_width" =~ ^[0-9]+$ && "$mux_width" -gt 0 && "$mux_height" =~ ^[0-9]+$ && "$mux_height" -gt 0 ]] || {
  echo 'streammux.width and streammux.height must be positive integers.' >&2
  exit 2
}
[[ "$rtsp_port" =~ ^[0-9]+$ && "$rtsp_port" -le 65535 ]] || { echo 'outputs.rtsp.port must be a valid port.' >&2; exit 2; }
[[ "$rtsp_mount_point" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo 'outputs.rtsp.mount_point must start with / and contain a valid path.' >&2; exit 2; }
[[ "$output_width" =~ ^[0-9]+$ && "$output_width" -gt 0 && "$output_height" =~ ^[0-9]+$ && "$output_height" -gt 0 ]] || {
  echo 'outputs.rtsp.encoder.width and outputs.rtsp.encoder.height must be positive integers.' >&2
  exit 2
}
[[ "$bitrate_mbps" =~ ^[0-9]+$ && "$bitrate_mbps" -gt 0 ]] || { echo 'encoder.bitrate_mbps must be a positive integer.' >&2; exit 2; }
[[ "$iframeinterval" =~ ^[0-9]+$ && "$iframeinterval" -gt 0 ]] || { echo 'encoder.iframeinterval must be a positive integer.' >&2; exit 2; }
[[ "$profile" =~ ^[0-9]+$ ]] || { echo 'encoder.profile must be an integer.' >&2; exit 2; }
[[ -n "$mqtt_topic" && -n "$mqtt_host" && "$mqtt_port" =~ ^[0-9]+$ ]] || {
  echo 'mqtt HiveMQ topic, host, and port must be configured.' >&2
  exit 2
}
[[ -n "$mqtt_username" && -n "$mqtt_password" ]] || {
  echo 'HiveMQ credentials must be exported before starting the pipeline.' >&2
  exit 2
}
export USER_MQTT="$mqtt_username"
export PASSWORD_MQTT="$mqtt_password"
[[ -f "$mqtt_proto_lib" ]] || {
  echo "DeepStream MQTT adaptor not found: $mqtt_proto_lib" >&2
  exit 2
}
if ldd "$mqtt_proto_lib" 2>/dev/null | grep -q 'not found'; then
  echo 'DeepStream MQTT adaptor dependencies are missing. Install libmosquitto1:' >&2
  echo '  sudo apt install -y libmosquitto1' >&2
  exit 2
fi
[[ -f "$msgconv_lib" ]] || {
  echo "RF-DETR message converter not found: $msgconv_lib" >&2
  exit 2
}

case "$profile" in
  0) x264_profile='baseline' ;;
  1) x264_profile='constrained-baseline' ;;
  2) x264_profile='main' ;;
  4) x264_profile='high' ;;
  *)
    echo 'encoder.profile must be 0 (baseline), 1 (constrained baseline), 2 (main), or 4 (high).' >&2
    exit 2
    ;;
esac

stream_offset_seconds="${STREAM_OFFSET_SECONDS:-$stream_offset_seconds}"
hls_segment_duration_seconds="${HLS_SEGMENT_DURATION_SECONDS:-$hls_segment_duration_seconds}"
segment_duration_seconds="${SEGMENT_DURATION_SECONDS:-$file_segment_duration_seconds}"
capture_duration_seconds="${CAPTURE_DURATION_SECONDS:-$capture_duration_seconds}"
grace_seconds="${GRACE_SECONDS:-$grace_seconds}"
output_prefix="${OUTPUT_PREFIX:-output-$(date +%Y%m%d-%H%M%S)}"
mediamtx_config="${MEDIAMTX_CONFIG:-mediamtx.yml}"
mediamtx_log_level="${MEDIAMTX_LOG_LEVEL:-warn}"
webrtc_additional_hosts="${WEBRTC_ADDITIONAL_HOSTS:-192.168.1.71}"
gst_launch_quiet="${GST_LAUNCH_QUIET:-true}"
rtsp_path=${rtsp_mount_point#/}
rtmp_url="${RTMP_URL:-rtmp://127.0.0.1:1935/$rtsp_path}"
bitrate_kbps=$((bitrate_mbps * 1000))

for value in "$hls_segment_duration_seconds" "$segment_duration_seconds" "$capture_duration_seconds" "$grace_seconds"; do
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || {
    echo 'Timing variables must be positive integers in seconds.' >&2
    exit 2
  }
done
[[ "$stream_offset_seconds" =~ ^[0-9]+$ ]] || { echo 'STREAM_OFFSET_SECONDS must be a non-negative integer.' >&2; exit 2; }

media_sequence=$((stream_offset_seconds / hls_segment_duration_seconds + 1))
segment_duration_nanoseconds=$((segment_duration_seconds * 1000000000))

if [[ "$output" == rtsp || "$output" == webrtc ]] && ! command -v mediamtx >/dev/null; then
  echo 'mediamtx is required for RTSP or WebRTC output but was not found in PATH.' >&2
  exit 127
fi

pipeline_pid=''
mediamtx_pid=''
watchdog_pid=''
mediamtx_runtime_config=''
mqtt_msgconv_config=''
mqtt_broker_config=''

stop_process() {
  local pid=$1
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null || true
    (
      sleep "$grace_seconds"
      kill -KILL "$pid" 2>/dev/null || true
    ) &
    local killer_pid=$!
    wait "$pid" 2>/dev/null || true
    kill "$killer_pid" 2>/dev/null || true
    wait "$killer_pid" 2>/dev/null || true
  fi
}

cleanup() {
  [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null || true
  stop_process "$pipeline_pid"
  stop_process "$mediamtx_pid"
  [[ -z "$mediamtx_runtime_config" ]] || rm -f "$mediamtx_runtime_config"
  [[ -z "$mqtt_msgconv_config" ]] || rm -f "$mqtt_msgconv_config"
  [[ -z "$mqtt_broker_config" ]] || rm -f "$mqtt_broker_config"
  [[ -z "${tracker_runtime_config:-}" ]] || rm -f "$tracker_runtime_config"
}

trap 'cleanup; exit 130' INT TERM HUP

if [[ "$output" == rtsp || "$output" == webrtc ]] && ! ss -ltn '( sport = :1935 )' | grep -q ':1935'; then
  mediamtx_runtime_config=$(mktemp)
  python3 - "$mediamtx_config" "$mediamtx_runtime_config" "$rtsp_port" "$rtsp_path" "$mediamtx_log_level" "$webrtc_additional_hosts" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = yaml.safe_load(config_file) or {}

config["rtsp"] = True
config["rtspAddress"] = f":{sys.argv[3]}"
config["webrtc"] = True
config["logLevel"] = sys.argv[5]
config["webrtcIPsFromInterfaces"] = False
config["webrtcAdditionalHosts"] = [host.strip() for host in sys.argv[6].split(",") if host.strip()]
config["webrtcLocalTCPAddress"] = ":8189"
config["paths"] = {sys.argv[4]: {}}

with open(sys.argv[2], "w", encoding="utf-8") as config_file:
    yaml.safe_dump(config, config_file, sort_keys=False)
PY
  mediamtx "$mediamtx_runtime_config" &
  mediamtx_pid=$!
  for attempt in {1..20}; do
    ss -ltn '( sport = :1935 )' | grep -q ':1935' && break
    sleep 0.1
  done
  if ! ss -ltn '( sport = :1935 )' | grep -q ':1935'; then
    echo 'MediaMTX did not start an RTMP listener on port 1935.' >&2
    cleanup
    exit 1
  fi
fi

if [[ "$source_type" == hls ]]; then
  if [[ "$stream_offset_seconds" -gt 0 ]]; then
    playlist="/tmp/tears-of-steel-from-${stream_offset_seconds}s.m3u8"
    manifest_base=${hls_uri%/*}
    {
      printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%d\n' \
        "$hls_segment_duration_seconds" "$media_sequence"
      curl -L --fail --max-time 15 -sS "$hls_uri" |
        awk -v base="$manifest_base/" -v start_sequence="$media_sequence" '
          BEGIN { segment = 0 }
          /^#EXTINF:/ { segment++; if (segment >= start_sequence) { print; keep = 1 }; next }
          /^tears-of-steel-/ { if (keep) { print base $0; keep = 0 }; next }
          /^#EXT-X-ENDLIST/ { print }
        '
    } > "$playlist"
    input_uri="file://$playlist"
  fi
fi

umask 077
mqtt_msgconv_config=$(mktemp)
mqtt_broker_config=$(mktemp)
cat > "$mqtt_msgconv_config" <<EOF
[custom]
labels-file=$project_root/coco91_labels.txt
EOF
cat > "$mqtt_broker_config" <<EOF
[message-broker]
username = $mqtt_username
password = $mqtt_password
client-id = deepstream-rfdetr
enable-tls = 1
tls-cafile = /etc/ssl/certs/ca-certificates.crt
keep-alive = 60
set-threaded = 1
EOF

pipeline=(
  gst-launch-1.0 -e
  nvurisrcbin uri="$input_uri" disable-audio=true name=src
  src. ! queue ! identity sync="$identity_sync" ! nvvideoconvert
  ! 'video/x-raw(memory:NVMM),format=NV12' ! mux.sink_0
  nvstreammux name=mux width="$mux_width" height="$mux_height" batch-size="$batch_size" batched-push-timeout=40000 !
  nvinfer config-file-path=deepstream_rfdetr_bbox_config.txt !
  nvtracker ll-lib-file="$deepstream_home/lib/libnvds_nvmultiobjecttracker.so"
  ll-config-file="$tracker_runtime_config" tracker-width="$mux_width" tracker-height="$mux_height"
  display-tracking-id=true ! rfdetrmsgmeta frame-interval=1 ! tee name=msgtee
  msgtee. ! queue ! nvmsgconv config="$mqtt_msgconv_config" msg2p-lib="$msgconv_lib" payload-type=257 multiple-payloads=false frame-interval=1 !
  nvmsgbroker proto-lib="$mqtt_proto_lib"
  config="$mqtt_broker_config" conn-str="$mqtt_host;$mqtt_port" topic="$mqtt_topic" sync=false
  msgtee. ! queue ! nvdsosd ! nvvideoconvert
  ! video/x-raw,format=I420,width="$output_width",height="$output_height",pixel-aspect-ratio=1/1
  ! queue leaky=downstream max-size-buffers=1
  ! x264enc tune=zerolatency speed-preset=ultrafast bitrate="$bitrate_kbps" key-int-max="$iframeinterval"
  ! "video/x-h264,profile=$x264_profile"
  ! h264parse
)

if [[ "$gst_launch_quiet" == true ]]; then
  pipeline=(gst-launch-1.0 -q "${pipeline[@]:1}")
fi

if [[ "$output" == file ]]; then
  pipeline+=(
    ! splitmuxsink async-finalize=true max-size-time="$segment_duration_nanoseconds"
    send-keyframe-requests=true location="${output_prefix}-%02d.mp4"
  )
else
  pipeline+=(
    config-interval=1 ! flvmux streamable=true ! rtmpsink location="$rtmp_url" sync=false
  )
fi

"${pipeline[@]}" &
pipeline_pid=$!

if [[ "$run_until_stopped" == false ]]; then
  (
    sleep "$capture_duration_seconds"
    kill -INT "$pipeline_pid" 2>/dev/null || exit 0
    sleep "$grace_seconds"
    kill -KILL "$pipeline_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
fi

if wait "$pipeline_pid"; then
  pipeline_status=0
else
  pipeline_status=$?
fi

kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=''
stop_process "$mediamtx_pid"
[[ -z "$mediamtx_runtime_config" ]] || rm -f "$mediamtx_runtime_config"
[[ -z "$mqtt_msgconv_config" ]] || rm -f "$mqtt_msgconv_config"
[[ -z "$mqtt_broker_config" ]] || rm -f "$mqtt_broker_config"
[[ -z "$tracker_runtime_config" ]] || rm -f "$tracker_runtime_config"
mediamtx_runtime_config=''
mqtt_msgconv_config=''
mqtt_broker_config=''
tracker_runtime_config=''
trap - INT TERM HUP

printf 'Pipeline exited with status %d\n' "$pipeline_status"
exit "$pipeline_status"