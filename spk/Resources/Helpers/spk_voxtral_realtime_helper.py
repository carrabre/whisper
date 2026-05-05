#!/usr/bin/env python3

import base64
import json
import os
import platform
import queue
import re
import subprocess
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
APPEND_PROGRESS_TIMEOUT_SECONDS = 0.35
FINISH_JOIN_TIMEOUT_SECONDS = 30
MAX_NEW_TOKENS = int(os.environ.get("SPK_VOXTRAL_MAX_NEW_TOKENS", "2048"))
SIGNAL_THRESHOLD = 1e-4
EMPTY_PREVIEW_WARNING_DELAY_SECONDS = 1.0
_STREAM_END = object()
MPS_UNAVAILABLE_PREFIX = "PyTorch MPS is unavailable, so Voxtral Realtime cannot stream locally."


class VoxtralMPSUnavailableError(RuntimeError):
    pass


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def emit_diagnostic(message):
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


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


def macos_version():
    try:
        result = subprocess.run(
            ["sw_vers", "-productVersion"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() or platform.mac_ver()[0] or "unknown"
    except Exception:
        return platform.mac_ver()[0] or "unknown"


def mps_unavailable_message(torch, reason):
    return (
        f"{MPS_UNAVAILABLE_PREFIX} {reason} "
        f"torch={getattr(torch, '__version__', 'unknown')} "
        f"macos={macos_version()} machine={platform.machine()}. "
        "Reinstall the managed Voxtral runtime so spk can use a PyTorch build with working MPS."
    )


def require_mps_runtime(torch):
    if platform.machine() != "arm64":
        raise VoxtralMPSUnavailableError(
            mps_unavailable_message(torch, "Apple Silicon arm64 hardware is required.")
        )

    if not torch.backends.mps.is_built():
        raise VoxtralMPSUnavailableError(
            mps_unavailable_message(torch, "This PyTorch build was not compiled with MPS support.")
        )

    if not torch.backends.mps.is_available():
        raise VoxtralMPSUnavailableError(
            mps_unavailable_message(torch, "torch.backends.mps.is_available() returned false.")
        )

    try:
        torch.ones(1, device="mps")
    except Exception as error:
        raise VoxtralMPSUnavailableError(
            mps_unavailable_message(torch, f"A tiny MPS tensor allocation failed: {error}")
        ) from error


def select_runtime(torch):
    require_mps_runtime(torch)
    return torch.device("mps"), torch.float16, True


def move_value_to_runtime(value, torch):
    if torch.is_tensor(value):
        if value.dtype.is_floating_point:
            return value.to(device=RUNTIME_DEVICE, dtype=RUNTIME_DTYPE)
        return value.to(device=RUNTIME_DEVICE)
    return value


def prepare_inputs_for_runtime(inputs, torch):
    return {key: move_value_to_runtime(value, torch) for key, value in inputs.items()}


def build_stream_chunk_inputs(chunk_audio, is_first_chunk):
    import torch

    prepared_inputs = PROCESSOR(
        chunk_audio,
        sampling_rate=SAMPLE_RATE,
        is_streaming=True,
        is_first_audio_chunk=is_first_chunk,
        return_tensors="pt",
    )
    return prepare_inputs_for_runtime(prepared_inputs, torch)


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


def update_preview_diagnostics(session, preview_text):
    normalized_preview_text = normalize_text(preview_text)
    if not normalized_preview_text:
        now = time.monotonic()
        with session["lock"]:
            should_log_empty_warning = (
                session["has_detected_signal"]
                and session["dispatched_stream_chunk_count"] > 0
                and session["non_empty_preview_update_count"] == 0
                and not session["has_logged_empty_preview_warning"]
                and session["speech_detected_monotonic"] is not None
                and (now - session["speech_detected_monotonic"]) >= EMPTY_PREVIEW_WARNING_DELAY_SECONDS
            )
            if should_log_empty_warning:
                session["has_logged_empty_preview_warning"] = True

        if should_log_empty_warning:
            emit_diagnostic(
                "Voxtral helper streaming audio is flowing after speech onset, but live preview text is still empty. "
                f"session={session['id']} elapsedMs={((now - session['speech_detected_monotonic']) * 1000):.1f}"
            )
        return

    now = time.monotonic()
    first_latency_ms = None
    preview_count = None
    with session["lock"]:
        session["non_empty_preview_update_count"] += 1
        preview_count = session["non_empty_preview_update_count"]
        if session["first_non_empty_preview_monotonic"] is None:
            session["first_non_empty_preview_monotonic"] = now
            if session["speech_detected_monotonic"] is not None:
                first_latency_ms = (now - session["speech_detected_monotonic"]) * 1000

    if first_latency_ms is not None:
        emit_diagnostic(
            "Voxtral helper produced the first non-empty live preview text. "
            f"session={session['id']} latencyMs={first_latency_ms:.1f} textLength={len(normalized_preview_text)}"
        )
    elif preview_count is not None and preview_count % 10 == 0:
        emit_diagnostic(
            "Voxtral helper is continuing to stream non-empty live preview text. "
            f"session={session['id']} previewUpdates={preview_count}"
        )


def ensure_session_generation_healthy(session):
    with session["lock"]:
        worker_error = session.get("worker_error")
        generation_error = session.get("generation_error")

    if worker_error:
        raise RuntimeError(worker_error)

    if generation_error:
        raise RuntimeError(generation_error)


def signal_stream_progress(session):
    progress_event = session.get("worker_progress_event")
    if progress_event is not None:
        progress_event.set()


def _run_streaming_generation(session, generation_kwargs):
    import torch

    generation_started = time.monotonic()
    try:
        with torch.inference_mode():
            MODEL.generate(**generation_kwargs)
    except Exception as error:
        with session["lock"]:
            session["generation_error"] = f"Voxtral streaming generation failed: {error}"
    finally:
        elapsed_ms = (time.monotonic() - generation_started) * 1000
        with session["lock"]:
            session["generation_finished"] = True
        signal_stream_progress(session)
        emit_diagnostic(
            "Voxtral helper streaming generation finished. "
            f"session={session['id']} elapsedMs={elapsed_ms:.1f}"
        )


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
        "max_new_tokens": MAX_NEW_TOKENS,
        "return_dict_in_generate": False,
    }

    generation_thread = threading.Thread(
        target=_run_streaming_generation,
        args=(session, generation_kwargs),
        daemon=True,
        name=f"voxtral-stream-{session['id']}",
    )

    with session["lock"]:
        session["feature_queue"] = feature_queue
        session["streamer"] = streamer
        session["generation_thread"] = generation_thread
        session["generation_started"] = True
        generation_started_monotonic = session["stream_generation_started_monotonic"]
        speech_detected_monotonic = session["speech_detected_monotonic"]
        dispatched_stream_chunk_count = session["dispatched_stream_chunk_count"]

    generation_thread.start()
    signal_stream_progress(session)
    latency_ms = None
    if generation_started_monotonic is not None and speech_detected_monotonic is not None:
        latency_ms = (generation_started_monotonic - speech_detected_monotonic) * 1000
    emit_diagnostic(
        "Voxtral helper started streaming generation. "
        f"session={session['id']} dispatchedChunks={dispatched_stream_chunk_count} "
        f"speechToGenerationMs={(f'{latency_ms:.1f}' if latency_ms is not None else 'unknown')}"
    )


def required_stream_sample_count(is_first_chunk):
    if is_first_chunk:
        return PROCESSOR.num_samples_first_audio_chunk
    return PROCESSOR.num_samples_per_audio_chunk


def next_stream_start_after_first_chunk():
    hop_length = int(getattr(PROCESSOR.feature_extractor, "hop_length", 160))
    win_length = int(getattr(PROCESSOR.feature_extractor, "win_length", 400))
    first_mel_frames = int(getattr(PROCESSOR, "num_mel_frames_first_audio_chunk", 0))
    return max(0, first_mel_frames * hop_length - win_length // 2)


def streaming_chunk_step_sample_count():
    hop_length = int(getattr(PROCESSOR.feature_extractor, "hop_length", 160))
    audio_length_per_token = int(getattr(PROCESSOR, "audio_length_per_tok", 0))
    raw_audio_length_per_token = int(getattr(PROCESSOR, "raw_audio_length_per_tok", 0))
    if audio_length_per_token > 0:
        return audio_length_per_token * hop_length
    if raw_audio_length_per_token > 0:
        return raw_audio_length_per_token
    return PROCESSOR.num_samples_per_audio_chunk


def right_pad_sample_count():
    num_right_pad_tokens = getattr(PROCESSOR, "num_right_pad_tokens", None)
    if callable(num_right_pad_tokens):
        token_count = int(num_right_pad_tokens())
    else:
        token_count = int(num_right_pad_tokens or 0)

    raw_audio_length_per_token = int(getattr(PROCESSOR, "raw_audio_length_per_tok", 0))
    if raw_audio_length_per_token <= 0:
        raw_audio_length_per_token = streaming_chunk_step_sample_count()
    return max(0, token_count * raw_audio_length_per_token)


def pending_audio_size(session):
    return int(session["pending_audio_size"])


def pending_audio_end_sample(session):
    return int(session["pending_audio_start_sample"]) + pending_audio_size(session)


def next_stream_chunk_range(session):
    if session["is_first_chunk"]:
        start_sample = 0
        end_sample = required_stream_sample_count(True)
    else:
        start_sample = int(session["next_stream_chunk_start_sample"])
        end_sample = start_sample + required_stream_sample_count(False)
    return start_sample, end_sample


def has_ready_stream_chunk(session):
    start_sample, end_sample = next_stream_chunk_range(session)
    return (
        pending_audio_size(session) > 0
        and int(session["pending_audio_start_sample"]) <= start_sample
        and pending_audio_end_sample(session) >= end_sample
    )


def append_pending_audio(session, audio):
    if audio.size == 0:
        return

    session["pending_audio_chunks"].append(audio)
    session["pending_audio_size"] += int(audio.size)


def materialize_pending_audio(session):
    import numpy as np

    chunks = session["pending_audio_chunks"]
    if not chunks:
        return np.array([], dtype="float32")

    if len(chunks) == 1:
        return chunks[0]

    combined = np.concatenate(chunks)
    session["pending_audio_chunks"] = [combined]
    return combined


def slice_pending_audio(session, start_sample, end_sample):
    pending_audio = materialize_pending_audio(session)
    relative_start = start_sample - int(session["pending_audio_start_sample"])
    relative_end = end_sample - int(session["pending_audio_start_sample"])
    if relative_start < 0 or relative_end > pending_audio.size:
        raise RuntimeError("Voxtral streaming audio chunk was requested before the audio was available.")
    return pending_audio[relative_start:relative_end].copy()


def drop_stream_audio_before(session, sample_index):
    pending_audio = materialize_pending_audio(session)
    base_sample = int(session["pending_audio_start_sample"])
    drop_count = max(0, min(sample_index - base_sample, pending_audio.size))
    if drop_count <= 0:
        return

    remaining_audio = pending_audio[drop_count:].copy()
    session["pending_audio_chunks"] = [remaining_audio] if remaining_audio.size > 0 else []
    session["pending_audio_size"] = int(remaining_audio.size)
    session["pending_audio_start_sample"] = base_sample + drop_count


def clear_pending_audio(session):
    session["pending_audio_chunks"] = []
    session["pending_audio_size"] = 0
    session["pending_audio_start_sample"] = int(session["next_stream_chunk_start_sample"])


def process_next_ready_stream_chunk(session):
    with session["lock"]:
        is_first_chunk = session["is_first_chunk"]
        start_sample, end_sample = next_stream_chunk_range(session)
        if not has_ready_stream_chunk(session):
            return False

        chunk_audio = slice_pending_audio(session, start_sample, end_sample)

    prepared_inputs = build_stream_chunk_inputs(chunk_audio, is_first_chunk)

    with session["lock"]:
        if session["worker_should_stop"] and not session["worker_should_flush_before_stop"]:
            return False

        feature_queue = session.get("feature_queue")
        should_start_generation = is_first_chunk and not session["generation_started"]
        if should_start_generation:
            session["is_first_chunk"] = False
            session["stream_generation_started_monotonic"] = time.monotonic()
            session["next_stream_chunk_start_sample"] = next_stream_start_after_first_chunk()
        elif not is_first_chunk:
            session["next_stream_chunk_start_sample"] = (
                int(session["next_stream_chunk_start_sample"]) + streaming_chunk_step_sample_count()
            )
        session["dispatched_stream_chunk_count"] += 1
        dispatched_stream_chunk_count = session["dispatched_stream_chunk_count"]
        next_start_sample = int(session["next_stream_chunk_start_sample"])
        drop_stream_audio_before(session, next_start_sample)

    if should_start_generation:
        start_streaming_generation(session, prepared_inputs)
    elif feature_queue is not None:
        feature_queue.put(prepared_inputs["input_features"])
        signal_stream_progress(session)

    if dispatched_stream_chunk_count == 1 or dispatched_stream_chunk_count % 10 == 0:
        emit_diagnostic(
            "Voxtral helper dispatched streaming audio chunk. "
            f"session={session['id']} chunkIndex={dispatched_stream_chunk_count} "
            f"samples={chunk_audio.size} firstChunk={is_first_chunk} "
            f"startSample={start_sample} nextStartSample={next_start_sample}"
        )

    return True


def flush_pending_stream_audio(session):
    import numpy as np

    with session["lock"]:
        if pending_audio_size(session) == 0:
            return
        is_first_chunk = session["is_first_chunk"]
        _, required_end_sample = next_stream_chunk_range(session)
        available_end_sample = pending_audio_end_sample(session)
        if available_end_sample < required_end_sample:
            append_pending_audio(
                session,
                np.zeros(required_end_sample - available_end_sample, dtype="float32"),
            )

    if not has_ready_stream_chunk(session):
        return

    process_next_ready_stream_chunk(session)

    with session["lock"]:
        dispatched_stream_chunk_count = session["dispatched_stream_chunk_count"]

    emit_diagnostic(
        "Voxtral helper flushed pending streaming audio. "
        f"session={session['id']} chunkIndex={dispatched_stream_chunk_count} "
        f"firstChunk={is_first_chunk}"
    )


def append_stream_flush_padding(session):
    import numpy as np

    flush_padding_sample_count = session["streaming_right_pad_sample_count"]
    if flush_padding_sample_count <= 0:
        return

    with session["lock"]:
        append_pending_audio(session, np.zeros(flush_padding_sample_count, dtype="float32"))


def _run_stream_preprocessing_worker(session):
    try:
        while True:
            session["worker_event"].wait()
            session["worker_event"].clear()

            while True:
                ensure_session_generation_healthy(session)

                with session["lock"]:
                    should_stop = session["worker_should_stop"]
                    should_flush_before_stop = session["worker_should_flush_before_stop"]
                    has_detected_signal = session["has_detected_signal"]
                    has_ready_chunk = has_ready_stream_chunk(session)

                if has_detected_signal and has_ready_chunk:
                    processed_chunk = process_next_ready_stream_chunk(session)
                    if processed_chunk:
                        continue

                if should_stop:
                    if should_flush_before_stop and has_detected_signal:
                        flush_pending_stream_audio(session)
                    return

                break
    except Exception as error:
        with session["lock"]:
            session["worker_error"] = f"Voxtral audio preprocessing failed: {error}"
    finally:
        with session["lock"]:
            session["worker_finished"] = True
        signal_stream_progress(session)
        session["worker_event"].set()


def start_stream_preprocessing_worker(session):
    worker_thread = threading.Thread(
        target=_run_stream_preprocessing_worker,
        args=(session,),
        daemon=True,
        name=f"voxtral-audio-{session['id']}",
    )
    session["worker_thread"] = worker_thread
    worker_thread.start()


def stop_stream_preprocessing_worker(session, flush_pending_audio):
    with session["lock"]:
        session["worker_should_stop"] = True
        session["worker_should_flush_before_stop"] = flush_pending_audio
    session["worker_event"].set()


def join_stream_preprocessing_worker(session, timeout_seconds):
    worker_thread = session.get("worker_thread")
    if worker_thread is None:
        return

    worker_thread.join(timeout=timeout_seconds)
    if worker_thread.is_alive():
        raise RuntimeError("Voxtral audio preprocessing timed out while finalizing the session.")

    ensure_session_generation_healthy(session)


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
            max_new_tokens=MAX_NEW_TOKENS,
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
    except VoxtralMPSUnavailableError as error:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": str(error),
            }
        )
        return

    emit_diagnostic(
        "Voxtral helper MPS preflight succeeded. "
        f"torch={getattr(torch, '__version__', 'unknown')} macos={macos_version()} "
        f"machine={platform.machine()} device={runtime_device} dtype={runtime_dtype}"
    )

    try:
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
            "streaming_chunk_sample_count": int(
                getattr(
                    processor,
                    "num_samples_per_audio_chunk",
                    getattr(processor, "num_samples_first_audio_chunk", 3840),
                )
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
    import numpy as np

    if MODEL is None or PROCESSOR is None:
        emit(
            {
                "request_id": request_id,
                "type": "error",
                "message": "No Voxtral model is loaded. Send `load_model` first.",
            }
        )
        return

    streaming_right_pad_sample_count = right_pad_sample_count()
    SESSIONS[session_id] = {
        "id": session_id,
        "lock": threading.Lock(),
        "worker_event": threading.Event(),
        "worker_progress_event": threading.Event(),
        "worker_thread": None,
        "worker_should_stop": False,
        "worker_should_flush_before_stop": False,
        "worker_finished": False,
        "worker_error": None,
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
        "streaming_right_pad_sample_count": streaming_right_pad_sample_count,
        "speech_detected_monotonic": None,
        "stream_generation_started_monotonic": None,
        "first_non_empty_preview_monotonic": None,
        "non_empty_preview_update_count": 0,
        "has_logged_empty_preview_warning": False,
        "dispatched_stream_chunk_count": 0,
        "pending_audio_chunks": [],
        "pending_audio_size": 0,
        "pending_audio_start_sample": 0,
        "next_stream_chunk_start_sample": 0,
    }
    start_stream_preprocessing_worker(SESSIONS[session_id])
    emit_diagnostic(
        "Started Voxtral helper live session. "
        f"session={session_id} rightPadSamples={streaming_right_pad_sample_count} "
        f"firstChunkSamples={PROCESSOR.num_samples_first_audio_chunk} "
        f"steadyChunkSamples={PROCESSOR.num_samples_per_audio_chunk} "
        f"chunkStepSamples={streaming_chunk_step_sample_count()}"
    )
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
            detected_signal = audio_has_signal(new_audio)
            with session["lock"]:
                if detected_signal:
                    session["has_detected_signal"] = True
                    if session["speech_detected_monotonic"] is None:
                        session["speech_detected_monotonic"] = time.monotonic()

                append_pending_audio(session, new_audio)

                should_wake_worker = session["has_detected_signal"]
                should_wait_for_progress = (
                    should_wake_worker
                    and not session["worker_finished"]
                    and has_ready_stream_chunk(session)
                )
                if should_wait_for_progress:
                    session["worker_progress_event"].clear()

            if should_wake_worker:
                session["worker_event"].set()
            if should_wait_for_progress:
                session["worker_progress_event"].wait(timeout=APPEND_PROGRESS_TIMEOUT_SECONDS)

        preview_text = drain_streamer(session, APPEND_DRAIN_TIMEOUT_SECONDS)
        update_preview_diagnostics(session, preview_text)
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


def normalized_timeout_seconds(timeout_seconds):
    try:
        parsed_timeout = float(timeout_seconds)
    except (TypeError, ValueError):
        return FINISH_JOIN_TIMEOUT_SECONDS

    if parsed_timeout <= 0:
        return FINISH_JOIN_TIMEOUT_SECONDS

    return max(1.0, min(parsed_timeout, 600.0))


def finalize_session_text(session, timeout_seconds=FINISH_JOIN_TIMEOUT_SECONDS):
    timeout_seconds = normalized_timeout_seconds(timeout_seconds)
    finalization_started = time.monotonic()
    with session["lock"]:
        should_flush_pending_audio = session["has_detected_signal"] or session["generation_started"]

    if should_flush_pending_audio:
        append_stream_flush_padding(session)

    stop_stream_preprocessing_worker(session, flush_pending_audio=should_flush_pending_audio)
    worker_join_started = time.monotonic()
    join_stream_preprocessing_worker(session, timeout_seconds)
    emit_diagnostic(
        "Voxtral helper preprocessing worker joined during finalization. "
        f"session={session['id']} elapsedMs={((time.monotonic() - worker_join_started) * 1000):.1f}"
    )
    ensure_session_generation_healthy(session)

    with session["lock"]:
        has_detected_signal = session["has_detected_signal"]
        generation_started = session["generation_started"]
        feature_queue = session.get("feature_queue")
        generation_thread = session.get("generation_thread")

    if not has_detected_signal and not generation_started:
        return ""

    if feature_queue is not None:
        feature_queue.put(_STREAM_END)

    if generation_thread is not None:
        generation_join_started = time.monotonic()
        generation_thread.join(timeout=timeout_seconds)
        generation_join_elapsed_ms = (time.monotonic() - generation_join_started) * 1000
        if generation_thread.is_alive():
            emit_diagnostic(
                "Voxtral helper streaming generation timed out during finalization. "
                f"session={session['id']} timeoutSeconds={timeout_seconds:.1f} "
                f"joinElapsedMs={generation_join_elapsed_ms:.1f}"
            )
            raise RuntimeError("Voxtral streaming generation timed out while finalizing the session.")
        emit_diagnostic(
            "Voxtral helper streaming generation joined during finalization. "
            f"session={session['id']} elapsedMs={generation_join_elapsed_ms:.1f}"
        )

    preview_text = drain_streamer(session)
    ensure_session_generation_healthy(session)
    emit_diagnostic(
        "Voxtral helper finalized live session text. "
        f"session={session['id']} elapsedMs={((time.monotonic() - finalization_started) * 1000):.1f} "
        f"timeoutSeconds={timeout_seconds:.1f} textLength={len(normalize_text(preview_text))}"
    )
    return normalize_text(preview_text)


def handle_finish_session(request_id, session_id, finalization_timeout_seconds=None):
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
        text = finalize_session_text(session, finalization_timeout_seconds)
        emit_diagnostic(
            "Finished Voxtral helper live session. "
            f"session={session_id} nonEmptyPreviewUpdates={session['non_empty_preview_update_count']} finalTextLength={len(normalize_text(text))}"
        )
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
    if session is not None:
        stop_stream_preprocessing_worker(session, flush_pending_audio=False)
        with session["lock"]:
            feature_queue = session.get("feature_queue")
        if feature_queue is not None:
            feature_queue.put(_STREAM_END)
        emit_diagnostic(
            "Cancelled Voxtral helper live session. "
            f"session={session_id} nonEmptyPreviewUpdates={session['non_empty_preview_update_count']}"
        )

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
                payload.get("finalizationTimeoutSeconds")
                or payload.get("finalization_timeout_seconds"),
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
