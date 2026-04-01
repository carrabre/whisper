#!/usr/bin/env python3

import base64
import json
import os
import platform
import queue
import re
import sys
import threading
import time
import wave
from pathlib import Path


os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

MODEL = None
PROCESSOR = None
MODEL_PATH = None
RUNTIME_DEVICE = None
RUNTIME_DTYPE = None
SUPPORTS_STREAMING_PREVIEW = False
SESSIONS = {}

SAMPLE_RATE = 16_000
APPEND_DRAIN_TIMEOUT_SECONDS = 0.25
FINISH_JOIN_TIMEOUT_SECONDS = 30
SIGNAL_THRESHOLD = 1e-4
_STREAM_END = object()


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def normalize_text(text):
    return re.sub(r"\s+", " ", text or "").strip()


def read_wave_file(path):
    with wave.open(path, "rb") as wav_file:
        channels = wav_file.getnchannels()
        sample_width = wav_file.getsampwidth()
        frame_rate = wav_file.getframerate()
        frame_count = wav_file.getnframes()
        frames = wav_file.readframes(frame_count)

    if sample_width != 2:
        raise RuntimeError("Expected a 16-bit PCM wav file.")
    if channels != 1:
        raise RuntimeError("Expected a mono wav file.")
    if frame_rate != SAMPLE_RATE:
        raise RuntimeError("Expected a 16 kHz wav file.")

    import numpy as np

    audio = np.frombuffer(frames, dtype="<i2").astype("float32")
    return audio / 32768.0


def decode_pcm16_base64(samples_base64):
    import numpy as np

    pcm_bytes = base64.b64decode(samples_base64)
    if not pcm_bytes:
        return np.array([], dtype="float32")

    audio = np.frombuffer(pcm_bytes, dtype="<i2").astype("float32")
    return audio / 32768.0


def audio_has_signal(audio):
    import numpy as np

    if audio.size == 0:
        return False

    return bool(np.max(np.abs(audio)) >= SIGNAL_THRESHOLD)


def select_runtime(torch):
    if platform.machine() == "arm64" and torch.backends.mps.is_available():
        return torch.device("mps"), torch.float16, True

    return torch.device("cpu"), torch.float32, False


def move_value_to_runtime(value, torch):
    if torch.is_tensor(value):
        if value.dtype.is_floating_point:
            return value.to(device=RUNTIME_DEVICE, dtype=RUNTIME_DTYPE)
        return value.to(device=RUNTIME_DEVICE)
    return value


def prepare_inputs_for_runtime(inputs, torch):
    return {key: move_value_to_runtime(value, torch) for key, value in inputs.items()}


def build_feature_generator(feature_queue):
    while True:
        next_features = feature_queue.get()
        if next_features is _STREAM_END:
            return
        yield next_features


class FullTextQueueStreamer:
    def __init__(self, tokenizer, skip_prompt=False, timeout=None, **decode_kwargs):
        self.tokenizer = tokenizer
        self.skip_prompt = skip_prompt
        self.timeout = timeout
        self.decode_kwargs = decode_kwargs
        self.text_queue = queue.Queue()
        self.stop_signal = object()
        self.token_cache = []
        self.next_tokens_are_prompt = True
        self.latest_text = ""

    def put(self, value):
        if len(value.shape) > 1 and value.shape[0] > 1:
            raise ValueError("FullTextQueueStreamer only supports batch size 1")
        if len(value.shape) > 1:
            value = value[0]

        if self.skip_prompt and self.next_tokens_are_prompt:
            self.next_tokens_are_prompt = False
            return

        self.token_cache.extend(value.tolist())
        decoded_text = normalize_text(self.tokenizer.decode(self.token_cache, **self.decode_kwargs))
        if decoded_text != self.latest_text:
            self.latest_text = decoded_text
            self.text_queue.put(decoded_text, timeout=self.timeout)

    def end(self):
        final_text = normalize_text(self.tokenizer.decode(self.token_cache, **self.decode_kwargs))
        if final_text != self.latest_text:
            self.latest_text = final_text
            self.text_queue.put(final_text, timeout=self.timeout)

        self.next_tokens_are_prompt = True
        self.text_queue.put(self.stop_signal, timeout=self.timeout)


def drain_streamer(session, block_timeout_seconds=0):
    streamer = session.get("streamer")
    if streamer is None:
        return session.get("latest_partial_text", "")

    text_queue = streamer.text_queue
    stop_signal = streamer.stop_signal
    should_block = block_timeout_seconds > 0
    deadline = time.monotonic() + block_timeout_seconds

    while True:
        try:
            if should_block:
                timeout = max(0, deadline - time.monotonic())
                if timeout <= 0:
                    break
                next_text = text_queue.get(timeout=timeout)
                should_block = False
            else:
                next_text = text_queue.get_nowait()
        except queue.Empty:
            break

        if next_text == stop_signal:
            session["stream_complete"] = True
            continue

        session["latest_partial_text"] = normalize_text(next_text)

    return session["latest_partial_text"]


def ensure_session_generation_healthy(session):
    generation_error = session.get("generation_error")
    if generation_error:
        raise RuntimeError(generation_error)


def _run_streaming_generation(session, generation_kwargs):
    import torch

    try:
        with torch.inference_mode():
            MODEL.generate(**generation_kwargs)
    except Exception as error:
        session["generation_error"] = f"Voxtral streaming generation failed: {error}"
    finally:
        session["generation_finished"] = True


def start_streaming_generation(session, first_inputs):
    feature_queue = queue.Queue()
    first_features = first_inputs["input_features"]
    feature_queue.put(first_features)

    streamer = FullTextQueueStreamer(
        PROCESSOR.tokenizer,
        skip_prompt=True,
        timeout=1.0,
        skip_special_tokens=True,
        clean_up_tokenization_spaces=False,
    )
    generation_kwargs = {
        "input_ids": first_inputs["input_ids"],
        "attention_mask": first_inputs["attention_mask"],
        "input_features": build_feature_generator(feature_queue),
        "num_delay_tokens": first_inputs["num_delay_tokens"],
        "streamer": streamer,
        "do_sample": False,
        "use_cache": True,
        "return_dict_in_generate": False,
    }

    generation_thread = threading.Thread(
        target=_run_streaming_generation,
        args=(session, generation_kwargs),
        daemon=True,
        name=f"voxtral-stream-{session['id']}",
    )

    session["feature_queue"] = feature_queue
    session["streamer"] = streamer
    session["generation_thread"] = generation_thread
    session["generation_started"] = True

    generation_thread.start()


def minimum_required_stream_samples(session):
    if session["is_first_chunk"]:
        return PROCESSOR.num_samples_first_audio_chunk
    return PROCESSOR.num_samples_per_audio_chunk


def process_ready_stream_chunks(session):
    import numpy as np
    import torch

    pending_audio = session["pending_audio"]
    while pending_audio.size >= minimum_required_stream_samples(session):
        chunk_sample_count = minimum_required_stream_samples(session)
        chunk_audio = pending_audio[:chunk_sample_count]
        pending_audio = pending_audio[chunk_sample_count:]

        prepared_inputs = PROCESSOR(
            chunk_audio,
            sampling_rate=SAMPLE_RATE,
            is_streaming=True,
            is_first_audio_chunk=session["is_first_chunk"],
            return_tensors="pt",
        )
        prepared_inputs = prepare_inputs_for_runtime(prepared_inputs, torch)

        if session["is_first_chunk"]:
            start_streaming_generation(session, prepared_inputs)
            session["is_first_chunk"] = False
        elif session["feature_queue"] is not None:
            session["feature_queue"].put(prepared_inputs["input_features"])

    session["pending_audio"] = pending_audio


def flush_pending_stream_audio(session):
    import numpy as np
    import torch

    pending_audio = session["pending_audio"]
    if pending_audio.size == 0:
        return

    required_sample_count = minimum_required_stream_samples(session)
    if pending_audio.size < required_sample_count:
        pending_audio = np.pad(
            pending_audio,
            (0, required_sample_count - pending_audio.size),
            mode="constant",
        )

    prepared_inputs = PROCESSOR(
        pending_audio,
        sampling_rate=SAMPLE_RATE,
        is_streaming=True,
        is_first_audio_chunk=session["is_first_chunk"],
        return_tensors="pt",
    )
    prepared_inputs = prepare_inputs_for_runtime(prepared_inputs, torch)

    if session["is_first_chunk"]:
        start_streaming_generation(session, prepared_inputs)
        session["is_first_chunk"] = False
    elif session["feature_queue"] is not None:
        session["feature_queue"].put(prepared_inputs["input_features"])

    session["pending_audio"] = pending_audio[:0]


def append_stream_flush_padding(session):
    import numpy as np

    right_pad_token_count = PROCESSOR.num_right_pad_tokens()
    if right_pad_token_count <= 0:
        return

    flush_padding = np.zeros(
        PROCESSOR.num_samples_per_audio_chunk * right_pad_token_count,
        dtype="float32",
    )
    if session["pending_audio"].size == 0:
        session["pending_audio"] = flush_padding
    else:
        session["pending_audio"] = np.concatenate((session["pending_audio"], flush_padding))


def transcribe_audio(audio):
    global MODEL
    global PROCESSOR

    import torch

    prepared_inputs = PROCESSOR(
        audio,
        sampling_rate=SAMPLE_RATE,
        is_streaming=False,
        return_tensors="pt",
    )
    prepared_inputs = prepare_inputs_for_runtime(prepared_inputs, torch)

    with torch.inference_mode():
        outputs = MODEL.generate(
            **prepared_inputs,
            do_sample=False,
            use_cache=True,
            return_dict_in_generate=False,
        )

    decoded = PROCESSOR.batch_decode(
        outputs,
        skip_special_tokens=True,
        clean_up_tokenization_spaces=True,
    )
    return normalize_text(decoded[0] if decoded else "")


def handle_load_model(request_id, model_path):
    global MODEL
    global PROCESSOR
    global MODEL_PATH
    global RUNTIME_DEVICE
    global RUNTIME_DTYPE
    global SUPPORTS_STREAMING_PREVIEW
    global SESSIONS

    try:
        import torch
        from transformers import AutoProcessor, VoxtralRealtimeForConditionalGeneration
    except Exception as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": "Missing Voxtral helper dependencies. Install `transformers>=5.2.0`, `torch`, and `mistral-common[audio]`. " + str(error),
            }
        )
        return

    resolved_model_path = str(Path(model_path).expanduser().resolve())
    if not os.path.isdir(resolved_model_path):
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Model folder does not exist: {resolved_model_path}",
            }
        )
        return

    try:
        runtime_device, runtime_dtype, supports_streaming_preview = select_runtime(torch)
        processor = AutoProcessor.from_pretrained(resolved_model_path, local_files_only=True)
        model = VoxtralRealtimeForConditionalGeneration.from_pretrained(
            resolved_model_path,
            local_files_only=True,
            low_cpu_mem_usage=True,
            torch_dtype=runtime_dtype,
        )
        model = model.to(runtime_device)
        if hasattr(model, "eval"):
            model.eval()
    except Exception as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Failed to load Voxtral Realtime from {resolved_model_path}: {error}",
            }
        )
        return

    PROCESSOR = processor
    MODEL = model
    MODEL_PATH = resolved_model_path
    RUNTIME_DEVICE = runtime_device
    RUNTIME_DTYPE = runtime_dtype
    SUPPORTS_STREAMING_PREVIEW = supports_streaming_preview
    SESSIONS = {}

    emit(
        {
            "request_id": request_id,
            "type": "ready",
            "model_display_name": os.path.basename(resolved_model_path),
            "supports_streaming_preview": supports_streaming_preview,
            "first_streaming_chunk_sample_count": int(
                getattr(processor, "num_samples_first_audio_chunk", 3840)
            ),
        }
    )


def handle_transcribe_file(request_id, audio_path):
    global MODEL
    global PROCESSOR

    if MODEL is None or PROCESSOR is None:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": "No Voxtral model is loaded. Send `load_model` first.",
            }
        )
        return

    try:
        audio = read_wave_file(audio_path)
        text = transcribe_audio(audio)
    except Exception as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Voxtral transcription failed: {error}",
            }
        )
        return

    emit(
        {
            "request_id": request_id,
            "type": "final_transcript",
            "text": text,
        }
    )


def handle_start_session(request_id, session_id):
    global MODEL
    global PROCESSOR

    if MODEL is None or PROCESSOR is None:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": "No Voxtral model is loaded. Send `load_model` first.",
            }
        )
        return

    SESSIONS[session_id] = {
        "id": session_id,
        "is_first_chunk": True,
        "has_detected_signal": False,
        "generation_started": False,
        "generation_finished": False,
        "generation_error": None,
        "feature_queue": None,
        "generation_thread": None,
        "streamer": None,
        "stream_complete": False,
        "latest_partial_text": "",
        "pending_audio": __import__("numpy").array([], dtype="float32"),
    }
    emit(
        {
            "request_id": request_id,
            "type": "session_started",
            "session_id": session_id,
        }
    )


def handle_append_audio(request_id, session_id, samples_base64):
    session = SESSIONS.get(session_id)
    if session is None:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Unknown Voxtral session: {session_id}",
            }
        )
        return

    try:
        import numpy as np

        ensure_session_generation_healthy(session)

        new_audio = decode_pcm16_base64(samples_base64)
        if new_audio.size > 0:
            if audio_has_signal(new_audio):
                session["has_detected_signal"] = True

            if session["pending_audio"].size == 0:
                session["pending_audio"] = new_audio
            else:
                session["pending_audio"] = np.concatenate((session["pending_audio"], new_audio))

            if session["has_detected_signal"]:
                process_ready_stream_chunks(session)

        preview_text = drain_streamer(session, APPEND_DRAIN_TIMEOUT_SECONDS)
        ensure_session_generation_healthy(session)
    except Exception as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Voxtral preview update failed: {error}",
            }
        )
        return

    emit(
        {
            "request_id": request_id,
            "type": "preview_update",
            "session_id": session_id,
            "text": preview_text,
        }
    )


def finalize_session_text(session):
    ensure_session_generation_healthy(session)

    if not session["has_detected_signal"] and not session["generation_started"]:
        return ""

    append_stream_flush_padding(session)
    process_ready_stream_chunks(session)

    if not session["generation_started"]:
        flush_pending_stream_audio(session)

    if session["generation_started"]:
        flush_pending_stream_audio(session)

        feature_queue = session.get("feature_queue")
        if feature_queue is not None:
            feature_queue.put(_STREAM_END)

        generation_thread = session.get("generation_thread")
        if generation_thread is not None:
            generation_thread.join(timeout=FINISH_JOIN_TIMEOUT_SECONDS)
            if generation_thread.is_alive():
                raise RuntimeError("Voxtral streaming generation timed out while finalizing the session.")

    preview_text = drain_streamer(session)
    ensure_session_generation_healthy(session)
    return normalize_text(preview_text)


def handle_finish_session(request_id, session_id):
    session = SESSIONS.pop(session_id, None)
    if session is None:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Unknown Voxtral session: {session_id}",
            }
        )
        return

    try:
        text = finalize_session_text(session)
    except Exception as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": f"Voxtral finalization failed: {error}",
            }
        )
        return

    emit(
        {
            "request_id": request_id,
            "type": "final_transcript",
            "session_id": session_id,
            "text": text,
        }
    )


def handle_cancel_session(request_id, session_id):
    session = SESSIONS.pop(session_id, None)
    if session is not None and session.get("feature_queue") is not None:
        session["feature_queue"].put(_STREAM_END)

    emit(
        {
            "request_id": request_id,
            "type": "session_cancelled",
            "session_id": session_id,
        }
    )


def main():
    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue

        try:
            payload = json.loads(raw_line)
        except json.JSONDecodeError as error:
            emit({"type": "error", "message": f"Invalid JSON request: {error}"})
            continue

        request_id = payload.get("requestID") or payload.get("request_id")
        request_type = payload.get("type")

        if request_type == "load_model":
            handle_load_model(request_id, payload.get("modelPath") or payload.get("model_path"))
        elif request_type == "start_session":
            handle_start_session(
                request_id,
                payload.get("sessionID") or payload.get("session_id"),
            )
        elif request_type == "append_audio":
            handle_append_audio(
                request_id,
                payload.get("sessionID") or payload.get("session_id"),
                payload.get("samplesBase64") or payload.get("samples_base64"),
            )
        elif request_type == "finish_session":
            handle_finish_session(
                request_id,
                payload.get("sessionID") or payload.get("session_id"),
            )
        elif request_type == "cancel_session":
            handle_cancel_session(
                request_id,
                payload.get("sessionID") or payload.get("session_id"),
            )
        elif request_type == "transcribe_file":
            handle_transcribe_file(request_id, payload.get("audioPath") or payload.get("audio_path"))
        elif request_type == "shutdown":
            emit({"request_id": request_id, "type": "shutdown"})
            return
        else:
            emit(
                {
                    "request_id": request_id,
                    "type": "error",
                    "message": f"Unsupported command: {request_type}",
                }
            )


if __name__ == "__main__":
    main()
