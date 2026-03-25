#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def emit(response_type: str, transcript: str | None = None, decode_ms: float | None = None, message: str | None = None) -> None:
    payload = {
        "type": response_type,
        "transcript": transcript,
        "decodeMilliseconds": decode_ms,
        "message": message,
    }
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


class NemotronRuntimeError(RuntimeError):
    pass


class NemotronRunner:
    sample_rate = 16_000

    def __init__(self, artifact_dir: Path) -> None:
        self.artifact_dir = artifact_dir
        manifest_path = artifact_dir / "manifest.json"
        if not manifest_path.is_file():
            raise NemotronRuntimeError("Nemotron runtime is missing manifest.json.")

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        checkpoint_relative_path = manifest.get("checkpointRelativePath")
        if not checkpoint_relative_path:
            raise NemotronRuntimeError("Nemotron runtime manifest is missing checkpointRelativePath.")

        self.checkpoint_path = artifact_dir / checkpoint_relative_path
        if not self.checkpoint_path.is_file():
            raise NemotronRuntimeError(f"Nemotron checkpoint is missing: {self.checkpoint_path}")

        self.chunk_milliseconds = 160
        self.samples: list[float] = []
        self.last_partial_transcript = ""
        self.last_decoded_sample_count = 0
        self._torch: Any | None = None
        self._model: Any | None = None
        self._device_name: str | None = None

    def perform_healthcheck(self) -> None:
        self._ensure_model_loaded()

    def start(self, chunk_milliseconds: int | None) -> float:
        self.chunk_milliseconds = max(80, int(chunk_milliseconds or 160))
        self.samples = []
        self.last_partial_transcript = ""
        self.last_decoded_sample_count = 0
        started = time.perf_counter()
        self._ensure_model_loaded()
        return (time.perf_counter() - started) * 1000.0

    def append(self, new_samples: list[float] | None) -> tuple[str | None, float | None]:
        if new_samples:
            self.samples.extend(float(sample) for sample in new_samples)

        if len(self.samples) < self._minimum_partial_sample_count:
            return None, None

        if self.last_partial_transcript and len(self.samples) - self.last_decoded_sample_count < self._minimum_decode_step_samples:
            return None, None

        return self._decode_current_buffer()

    def finalize(self, trailing_samples: list[float] | None) -> tuple[str, float]:
        if trailing_samples:
            self.samples.extend(float(sample) for sample in trailing_samples)

        if not self.samples:
            return "", 0.0

        transcript, decode_ms = self._decode_current_buffer()
        return transcript or "", decode_ms or 0.0

    @property
    def _minimum_partial_sample_count(self) -> int:
        return max(int(self.sample_rate * 0.45), int(self.sample_rate * self.chunk_milliseconds / 1000))

    @property
    def _minimum_decode_step_samples(self) -> int:
        return max(int(self.sample_rate * 0.45), int(self.sample_rate * self.chunk_milliseconds / 1000))

    def _ensure_runtime_imports(self) -> tuple[Any, Any, Any]:
        try:
            import numpy as np
            import torch
            from nemo.collections.asr.models import ASRModel
        except Exception as exc:  # pragma: no cover - runtime-only import path
            raise NemotronRuntimeError(
                "Nemotron runtime Python dependencies are missing. "
                "Run ./scripts/install_release.sh or ./scripts/run_dev.sh to install the managed NeMo runtime. "
                f"Import failed: {exc}"
            ) from exc

        return np, torch, ASRModel

    def _ensure_model_loaded(self) -> None:
        if self._model is not None:
            return

        _, torch, ASRModel = self._ensure_runtime_imports()

        requested_device = os.environ.get("SPK_NEMOTRON_DEVICE", "").strip()
        candidate_devices: list[str] = []
        if requested_device:
            candidate_devices.append(requested_device)
        else:
            if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
                candidate_devices.append("mps")
            candidate_devices.append("cpu")

        load_errors: list[str] = []
        for device_name in dict.fromkeys(candidate_devices):
            try:
                device = torch.device(device_name)
                model = ASRModel.restore_from(str(self.checkpoint_path), map_location=device)
                model.eval()
                if hasattr(model, "to"):
                    model = model.to(device)
                self._model = model
                self._torch = torch
                self._device_name = device_name
                return
            except Exception as exc:  # pragma: no cover - runtime-only fallback path
                load_errors.append(f"{device_name}: {exc}")

        joined_errors = "; ".join(load_errors) if load_errors else "unknown error"
        raise NemotronRuntimeError(
            "Could not load the Nemotron English checkpoint. "
            f"Tried devices {candidate_devices}. Errors: {joined_errors}"
        )

    def _decode_current_buffer(self) -> tuple[str, float]:
        self._ensure_model_loaded()
        np, _, _ = self._ensure_runtime_imports()

        audio = np.asarray(self.samples, dtype=np.float32)
        started = time.perf_counter()
        try:
            with self._torch.inference_mode():
                results = self._model.transcribe(audio=[audio], batch_size=1, verbose=False)
        except Exception as exc:  # pragma: no cover - runtime-only inference path
            raise NemotronRuntimeError(f"Nemotron English transcription failed: {exc}") from exc

        decode_ms = (time.perf_counter() - started) * 1000.0
        transcript = self._extract_transcript(results)
        self.last_partial_transcript = transcript
        self.last_decoded_sample_count = len(self.samples)
        return transcript, decode_ms

    @staticmethod
    def _extract_transcript(result: Any) -> str:
        value = result
        if isinstance(value, tuple) and value:
            value = value[0]
        if isinstance(value, list):
            value = value[0] if value else ""
        if isinstance(value, str):
            return value.strip()
        if isinstance(value, dict):
            for key in ("text", "transcript"):
                if key in value and value[key]:
                    return str(value[key]).strip()
        for attribute in ("text", "transcript"):
            candidate = getattr(value, attribute, None)
            if candidate:
                return str(candidate).strip()
        if value is None:
            return ""
        return str(value).strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", required=True)
    parser.add_argument("--healthcheck", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runner = NemotronRunner(Path(args.artifact_dir))

    if args.healthcheck:
        runner.perform_healthcheck()
        return 0

    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            return 0

        raw_line = raw_line.strip()
        if not raw_line:
            continue

        try:
            command = json.loads(raw_line)
        except Exception:
            emit("error", message="Nemotron runner received invalid JSON.")
            continue

        command_name = command.get("command")
        try:
            if command_name == "start":
                decode_ms = runner.start(command.get("chunkMilliseconds"))
                emit("ready", transcript="", decode_ms=decode_ms)
            elif command_name == "append":
                transcript, decode_ms = runner.append(command.get("samples"))
                if transcript:
                    emit("partial", transcript=transcript, decode_ms=decode_ms)
                else:
                    emit("empty", transcript=None, decode_ms=decode_ms)
            elif command_name == "finalize":
                transcript, decode_ms = runner.finalize(command.get("samples"))
                emit("final", transcript=transcript, decode_ms=decode_ms)
            elif command_name == "cancel":
                emit("cancelled")
                return 0
            else:
                emit("error", message=f"Unknown command: {command_name}")
        except NemotronRuntimeError as exc:
            emit("error", message=str(exc))
        except Exception as exc:  # pragma: no cover - runtime-only unexpected path
            emit("error", message=f"Nemotron runner crashed: {exc}")


if __name__ == "__main__":
    raise SystemExit(main())
