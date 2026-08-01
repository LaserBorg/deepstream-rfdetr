#!/usr/bin/env python3
"""Listen for DeepStream telemetry on the configured MQTT broker.

Usage:
    ./mqtt-listener.py
    ./mqtt-listener.py --topic vision/detections
    ./mqtt-listener.py --broker hivemq

Press Ctrl+C to stop listening.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
from pathlib import Path

import paho.mqtt.client as mqtt
import yaml
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "pipeline_config.yml"


def expand_environment_reference(value: object) -> str:
    if not isinstance(value, str):
        return ""
    if value.startswith("${") and value.endswith("}"):
        return os.getenv(value[2:-1], value)
    return value


def load_broker(name: str) -> tuple[dict, str]:
    try:
        with CONFIG_PATH.open(encoding="utf-8") as config_file:
            config = yaml.safe_load(config_file) or {}
        mqtt_config = config["mqtt"]
        topic = mqtt_config.get("topic", "vision/detections")
        broker = next(item for item in mqtt_config["brokers"] if item["name"] == name)
    except (OSError, KeyError, TypeError, StopIteration) as error:
        raise SystemExit(f"Unable to read broker '{name}' from {CONFIG_PATH}: {error}") from error

    broker = dict(broker)
    broker_name = broker["name"].upper()
    broker["username"] = expand_environment_reference(
        broker.get("username", os.getenv(f"{broker_name}_MQTT_USER", ""))
    )
    broker["password"] = expand_environment_reference(
        broker.get("password", os.getenv(f"{broker_name}_MQTT_PASSWORD", ""))
    )
    if not broker["username"] or not broker["password"]:
        raise SystemExit(f"Credentials for broker '{name}' are missing from .env")
    return broker, topic


def format_payload(payload: bytes) -> str:
    text = payload.decode("utf-8", errors="replace")
    try:
        return json.dumps(json.loads(text), indent=2, sort_keys=True)
    except json.JSONDecodeError:
        return text


def configure_tls(client: mqtt.Client, broker: dict) -> None:
    if not broker.get("tls", False):
        return

    ca_cert = broker.get("ca_cert")
    if ca_cert:
        ca_path = ROOT / ca_cert
        if ca_path.exists():
            print(f"TLS: using local CA cert ({ca_path})")
            client.tls_set(ca_certs=str(ca_path))
            client.tls_insecure_set(True)
            return
        print(f"TLS: CA cert '{ca_path}' not found; using system CA store")

    print("TLS: using system CA store")
    client.tls_set()
    client.tls_insecure_set(False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broker", default="hivemq", help="Broker name from pipeline_config.yml")
    parser.add_argument("--topic", help="Topic to subscribe to; defaults to the YAML topic")
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    broker, configured_topic = load_broker(args.broker)
    topic = args.topic or configured_topic
    host = broker["host"]
    port = int(broker["port"])

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"orin-listener-{os.getpid()}",
    )
    client.username_pw_set(broker["username"], broker["password"])
    print(f"Using credentials for user: {broker['username']}")
    configure_tls(client, broker)

    def on_connect(client: mqtt.Client, userdata: object, flags: dict, reason_code: object, properties: object) -> None:
        if reason_code != 0:
            print(f"Connection refused: reason code {reason_code}", file=sys.stderr)
            return
        print(f"Connected to {host}:{port}")
        print(f"Listening on {topic} (Ctrl+C to stop)\n")
        client.subscribe(topic, qos=1)

    def on_subscribe(client: mqtt.Client, userdata: object, mid: int, reason_codes: list, properties: object) -> None:
        print("Subscription active")

    def on_message(client: mqtt.Client, userdata: object, message: mqtt.MQTTMessage) -> None:
        print(f"[{message.topic}]")
        print(format_payload(message.payload))
        print()

    def stop_listener(signum: int, frame: object) -> None:
        print("\nStopping listener...")
        client.disconnect()

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    signal.signal(signal.SIGINT, stop_listener)
    signal.signal(signal.SIGTERM, stop_listener)

    try:
        client.connect(host, port, keepalive=10)
        client.loop_forever()
    except KeyboardInterrupt:
        pass
    except Exception as error:
        print(f"MQTT listener failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
