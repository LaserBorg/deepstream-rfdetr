#!/usr/bin/env python3
"""REST control API for the Inferencer DeepStream pipeline."""

from __future__ import annotations

import json
import hmac
import os
import shlex
import signal
import subprocess
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
RUNNER = ROOT / "run_pipeline.sh"
HOST = os.environ.get("PIPELINE_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("PIPELINE_API_PORT", "8090"))
VALID_MODELS = {"rfdetr-nano", "rfdetr-small", "rfdetr-medium", "rfdetr-large"}
VALID_PRECISIONS = {"fp16", "fp32"}


def load_api_key() -> str:
    api_key = os.environ.get("INFERENCER_API_KEY", "")
    if api_key:
        return api_key
    env_file = ROOT / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            name, separator, value = line.partition("=")
            if separator and name.strip() == "INFERENCER_API_KEY":
                return shlex.split(value.strip(), comments=True)[0]
    raise SystemExit("INFERENCER_API_KEY must be set in the environment or .env")


API_KEY = load_api_key()

state_lock = threading.Lock()
pipeline: subprocess.Popen[bytes] | None = None
selected_model: str | None = None
selected_precision: str | None = None
last_error: str | None = None


def validate_model(model: Any, precision: Any) -> tuple[str, str]:
    if model not in VALID_MODELS:
        raise ValueError("model must be rfdetr-nano, rfdetr-small, rfdetr-medium, or rfdetr-large")
    if precision not in VALID_PRECISIONS:
        raise ValueError("precision must be fp16 or fp32")
    return model, precision


def reap_pipeline() -> None:
    global pipeline
    if pipeline is not None and pipeline.poll() is not None:
        pipeline = None


def stop_pipeline() -> None:
    global pipeline
    with state_lock:
        reap_pipeline()
        process = pipeline
        pipeline = None
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGINT)
        process.wait(timeout=15)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def load_model(model: str, precision: str) -> None:
    validate_model(model, precision)
    result = subprocess.run(
        ["make", "setup", f"MODEL={model}", f"PRECISION={precision}"],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "model setup failed")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        return

    def send_json(
        self,
        status: HTTPStatus,
        payload: dict[str, Any],
        headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length > 4096:
            raise ValueError("request body is too large")
        body = self.rfile.read(length) if length else b"{}"
        value = json.loads(body)
        if not isinstance(value, dict):
            raise ValueError("request body must be a JSON object")
        return value

    def require_api_key(self) -> bool:
        authorization = self.headers.get("Authorization", "")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(token, API_KEY):
            self.send_json(
                HTTPStatus.UNAUTHORIZED,
                {"error": "invalid or missing API key"},
                {"WWW-Authenticate": "Bearer"},
            )
            return False
        return True

    def do_GET(self) -> None:
        if self.path != "/status":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "unknown endpoint"})
            return
        with state_lock:
            reap_pipeline()
            process = pipeline
            self.send_json(
                HTTPStatus.OK,
                {
                    "running": process is not None,
                    "pid": process.pid if process is not None else None,
                    "model": selected_model,
                    "precision": selected_precision,
                    "last_error": last_error,
                },
            )

    def do_POST(self) -> None:
        global last_error, selected_model, selected_precision, pipeline
        if not self.require_api_key():
            return
        try:
            request = self.read_json()
            if self.path == "/load-model":
                model = request.get("model", selected_model)
                precision = request.get("precision", selected_precision)
                if model is None or precision is None:
                    raise ValueError("model and precision are required")
                validate_model(model, precision)
                with state_lock:
                    reap_pipeline()
                    if pipeline is not None:
                        self.send_json(HTTPStatus.CONFLICT, {"error": "stop the pipeline before loading another model"})
                        return
                    load_model(model, precision)
                    selected_model = model
                    selected_precision = precision
                    last_error = None
                self.send_json(HTTPStatus.OK, {"prepared": True, "model": model, "precision": precision})
                return

            if self.path == "/start":
                with state_lock:
                    reap_pipeline()
                    if pipeline is not None:
                        self.send_json(HTTPStatus.CONFLICT, {"error": "pipeline is already running"})
                        return
                    model = request.get("model", selected_model)
                    precision = request.get("precision", selected_precision)
                    if model is not None or precision is not None:
                        if model is None or precision is None:
                            raise ValueError("model and precision must be supplied together")
                        validate_model(model, precision)
                        selected_model = model
                        selected_precision = precision
                    command = [str(RUNNER), "--output", request.get("output", "rtsp"), "--run-until-stopped"]
                    if selected_model is not None:
                        command += ["--model-size", selected_model, "--precision", selected_precision]
                    pipeline = subprocess.Popen(command, cwd=ROOT, start_new_session=True)
                    last_error = None
                    self.send_json(HTTPStatus.ACCEPTED, {"running": True, "pid": pipeline.pid})
                return

            if self.path == "/stop":
                stop_pipeline()
                self.send_json(HTTPStatus.OK, {"running": False})
                return

            if self.path == "/unload-model":
                stop_pipeline()
                with state_lock:
                    selected_model = None
                    selected_precision = None
                    last_error = None
                self.send_json(HTTPStatus.OK, {"running": False, "loaded": False})
                return

            self.send_json(HTTPStatus.NOT_FOUND, {"error": "unknown endpoint"})
        except (ValueError, RuntimeError, OSError) as error:
            last_error = str(error)
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": last_error})


def main() -> None:
    if not RUNNER.is_file():
        raise SystemExit(f"runner not found: {RUNNER}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Pipeline API listening on http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        stop_pipeline()


if __name__ == "__main__":
    main()
