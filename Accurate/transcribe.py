"""Local Qwen word alignment and MOSS joint transcription. No remote inference."""
import argparse
import gc
import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

MODELS = {
    "qwen": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "qwenSmall": "mlx-community/Qwen3-ASR-0.6B-8bit",
    "moss": "OpenMOSS-Team/MOSS-Transcribe-Diarize",
}
ALIGN_MODEL = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"
MOSS_REVISION = "704aa4a9c304e8520be88901e0d1960158ef5b15"
MODEL_TITLES = {"qwen": "Qwen3 1.7B", "qwenSmall": "Qwen3 0.6B", "moss": "MOSS"}


def progress(message, current=None, total=None, detail=None):
    print(f"[accurate] {message}", file=sys.stderr, flush=True)
    status = {"label": message, "current": current, "total": total, "detail": detail}
    print("[progress] " + json.dumps(status, ensure_ascii=False), file=sys.stderr, flush=True)


def chunks(audio, sr, limit=50, context=1.0):
    """Owned spans partition the file; ASR also hears context on both edges."""
    start = 0
    while start < len(audio):
        end = min(len(audio), start + limit * sr)
        if end < len(audio):
            search_start = max(start + sr, end - 2 * sr)
            hop = max(1, sr // 10)
            region = audio[search_start:end]
            count = len(region) // hop
            if count:
                energies = np.mean(region[:count * hop].reshape(-1, hop) ** 2, axis=1)
                end = search_start + int(np.argmin(energies)) * hop + hop // 2
        lo = max(0, start - int(context * sr))
        hi = min(len(audio), end + int(context * sr))
        yield lo, hi, start / sr, end / sr
        start = end


def read_audio(path):
    audio, sr = sf.read(path, dtype="float32")
    if sr != 16000 or audio.ndim != 1 or not np.all(np.isfinite(audio)):
        raise ValueError("Local transcription needs finite 16 kHz mono WAV audio.")
    return audio, sr


def original_words(text, aligner):
    words, prefix = [], []
    for token in text.split():
        if aligner.aligner_processor.clean_token(token):
            words.append(" ".join(prefix + [token]))
            prefix = []
        elif words:
            words[-1] += " " + token
        else:
            prefix.append(token)
    return words


def owns(start, end, owned_start, owned_end, duration):
    middle = (start + end) / 2
    return owned_start <= middle < owned_end or (owned_end == duration and middle == duration)


def preserve_aligned_words(text, aligned, aligner):
    """Map the aligner's subword spans back to intact original spelling."""
    originals = original_words(text, aligner)
    processor = aligner.aligner_processor
    counts = [len(processor.tokenize_space_lang(word)) for word in originals]
    expected = sum(counts)
    if len(aligned) != expected:
        raise RuntimeError(f"Word alignment could not preserve all recognized words "
            f"(expected {expected} alignment tokens, received {len(aligned)}).")
    offset = 0
    result = []
    for word, count in zip(originals, counts):
        group = aligned[offset:offset + count]
        for item in group:
            if not np.isfinite(item.start_time) or not np.isfinite(item.end_time) or item.end_time < item.start_time:
                raise RuntimeError("Word alignment returned invalid timestamps.")
        result.append((word, min(item.start_time for item in group), max(item.end_time for item in group)))
        offset += count
    return result


def parse_moss(result, offset, owned_start, owned_end, duration, chunk):
    """Fail closed on broken native timestamps; retain uncertainty in voice IDs."""
    parsed = []
    for item in result.segments or []:
        text = re.sub(r"^\[S\d+\]\s*", "", item.get("text", "")).strip()
        if not text:
            continue
        local_start, local_end = float(item["start"]), float(item["end"])
        if not np.isfinite(local_start) or not np.isfinite(local_end) or local_end <= local_start or local_start < 0:
            raise RuntimeError("MOSS returned invalid segment timestamps. No partial transcript was exported.")
        start, end = offset + local_start, offset + local_end
        if start > duration + 0.1 or end > duration + 0.2:
            raise RuntimeError("MOSS timestamps extend past the recording. Please try Qwen.")
        start, end = max(0, start), min(duration, end)
        if not owns(start, end, owned_start, owned_end, duration):
            continue
        # Context ownership removes duplicate segments. A segment spanning the
        # boundary may still be incomplete: preserve it and request review.
        speaker = item.get("speaker_id")
        valid_speaker = isinstance(speaker, str) and re.fullmatch(r"S\d+", speaker) is not None
        parsed.append({"start": round(start, 3), "end": round(end, 3), "text": text,
            "speaker": speaker if valid_speaker else None, "chunk": chunk,
            "needsReview": not valid_speaker or start < owned_start or end > owned_end})
    if result.text.strip() and not parsed and owned_start == 0 and owned_end == duration:
        raise RuntimeError("MOSS did not produce usable timestamped segments. Please try Qwen.")
    return parsed


def write_output(path, payload):
    target = Path(path)
    temporary = target.with_suffix(".pending")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    temporary.replace(target)


def recognize_shorter(asr, audio, sr, start, end, options):
    """Retry saturated recognition with bounded spans, never export loop text."""
    if end - start <= 5:
        return [], [{"start": start, "end": end}]
    middle = (start + end) / 2
    recovered, missing = [], []
    for lo, hi in [(start, middle), (middle, end)]:
        piece = audio[int(round(lo * sr)):int(round(hi * sr))]
        result = asr.generate(np.pad(piece, (0, max(0, sr - len(piece)))), **options)
        if result.generation_tokens >= options["max_tokens"]:
            pieces, gaps = recognize_shorter(asr, audio, sr, lo, hi, options)
            recovered.extend(pieces)
            missing.extend(gaps)
        elif result.text.strip():
            recovered.append((lo, hi, result))
    return recovered, missing


def run_jobs(jobs, terms):
    import mlx.core as mx
    from mlx_audio.stt import load

    started = time.perf_counter()
    groups = defaultdict(list)
    for job in jobs:
        if job["model"] not in MODELS:
            raise ValueError("Unsupported local model")
        groups[job["model"]].append(job)
    pending_alignment = []
    for model_name, model_jobs in groups.items():
        model_started = time.perf_counter()
        progress(f"Loading {MODEL_TITLES[model_name]}…")
        if model_name == "moss":
            from huggingface_hub import snapshot_download
            model_path = snapshot_download(MODELS[model_name], revision=MOSS_REVISION)
            asr = load(model_path)
        else:
            asr = load(MODELS[model_name])
        for job in model_jobs:
            audio, sr = read_audio(job["audio"])
            duration = len(audio) / sr
            transcripts, segments, recognition_reviews = [], [], []
            # Bound MOSS memory and token growth. Stable identities are restored
            # with the full-recording acoustic timeline in the native engine.
            spans = list(chunks(audio, sr, limit=180 if model_name == "moss" else 50))
            job_index = job.get("sourceIndex", jobs.index(job) + 1)
            source_count = job.get("sourceCount", len(jobs))
            label = f"Transcribing with {MODEL_TITLES[model_name]}…"
            for index, (lo, hi, owned_start, owned_end) in enumerate(spans):
                detail = f"Source {job_index} of {source_count} · Fragment {index + 1} of {len(spans)}"
                progress(label, current=index, total=len(spans), detail=detail)
                piece = audio[lo:hi]
                if not len(piece) or float(np.max(np.abs(piece))) < 1e-6:
                    progress(label, current=index + 1, total=len(spans), detail=detail)
                    continue
                padded = np.pad(piece, (0, max(0, sr - len(piece))))
                options = dict(max_tokens=8192 if model_name == "moss" else 4096, temperature=0.0, verbose=False)
                if terms:
                    options["hotwords"] = terms
                if model_name != "moss":
                    options["language"] = None
                result = asr.generate(padded, **options)
                if result.generation_tokens >= options["max_tokens"]:
                    progress(f"{detail}: recognition text limit; retrying shorter fragments…")
                    recovered, missing = recognize_shorter(asr, audio, sr, owned_start, owned_end, options)
                    recognition_reviews.append({"start": owned_start, "end": owned_end})
                    for subindex, (start, end, retry) in enumerate(recovered):
                        if model_name == "moss":
                            recovered_segments = parse_moss(retry, start, start, end, duration, index * 1024 + subindex)
                            for segment in recovered_segments:
                                segment["needsReview"] = True
                            segments.extend(recovered_segments)
                        else:
                            transcripts.append((int(round(start * sr)), int(round(end * sr)), start, end, retry.text.strip()))
                    if missing:
                        progress(f"{detail}: {len(missing)} short fragments could not be recognized; review required")
                    mx.clear_cache()
                    progress(label, current=index + 1, total=len(spans), detail=detail)
                    continue
                if model_name == "moss":
                    segments.extend(parse_moss(result, lo / sr, owned_start, owned_end, duration, index * 1024))
                elif result.text.strip():
                    transcripts.append((lo, hi, owned_start, owned_end, result.text.strip()))
                mx.clear_cache()
                progress(label, current=index + 1, total=len(spans), detail=detail)
            if model_name == "moss":
                write_output(job["output"], {"duration": duration, "segments": segments, "reviewRanges": recognition_reviews})
            else:
                pending_alignment.append((job, transcripts, recognition_reviews))
            del audio
        progress(f"{model_name} recognition complete in {time.perf_counter() - model_started:.1f}s")
        del asr
        gc.collect()
        mx.clear_cache()
    if pending_alignment:
        progress("Loading word alignment model…")
        aligner = load(ALIGN_MODEL)
        for job, transcripts, recognition_reviews in pending_alignment:
            audio, sr = read_audio(job["audio"])
            duration = len(audio) / sr
            words, review_ranges = [], list(recognition_reviews)
            for index, (lo, hi, owned_start, owned_end, text) in enumerate(transcripts, 1):
                detail = f"Source {job.get('sourceIndex', jobs.index(job) + 1)} of {job.get('sourceCount', len(jobs))} · Fragment {index} of {len(transcripts)}"
                progress("Aligning word timestamps…", current=index - 1, total=len(transcripts), detail=detail)
                piece = np.pad(audio[lo:hi], (0, max(0, sr - (hi - lo))))
                # In this pinned aligner RU and EN share the space-separated
                # tokenizer. English selects that path for mixed RU/EN too;
                # it does not force ASR language or translate the text.
                try:
                    aligned = list(aligner.generate(audio=piece, text=text, language="English"))
                    preserved = preserve_aligned_words(text, aligned, aligner)
                except (RuntimeError, ValueError, IndexError) as error:
                    progress(f"{detail}: alignment unavailable; recovering fragment text…")
                    # Recognize only the owned span again: the original text
                    # includes neighbour context whose word ownership is now
                    # unknowable. Never silently duplicate those edge words.
                    recovery_model = None
                    try:
                        recovery_model = load(MODELS[job["model"]])
                        owned_audio = audio[int(round(owned_start * sr)):int(round(owned_end * sr))]
                        options = dict(max_tokens=4096, temperature=0.0, verbose=False, language=None)
                        if terms:
                            options["hotwords"] = terms
                        recovered = recovery_model.generate(np.pad(owned_audio, (0, max(0, sr - len(owned_audio)))), **options)
                        if recovered.generation_tokens >= options["max_tokens"]:
                            raise RuntimeError(f"{detail}: recovery reached its text limit.")
                        recovered_text = recovered.text.strip()
                        if not recovered_text:
                            raise RuntimeError("Recovery returned no text.")
                    except (RuntimeError, ValueError) as recovery_error:
                        # Preserve the already recognized text even when the
                        # owned-span retry fails. Edge context may repeat and
                        # the whole fragment remains explicitly under review.
                        recovered_text = text
                        progress(f"{detail}: using recognized text with approximate timing; boundary words need review")
                    finally:
                        del recovery_model
                        gc.collect()
                        mx.clear_cache()
                    # A single fragment-level token explicitly avoids claiming
                    # estimated individual word timestamps as aligned times.
                    if recovered_text:
                        words.append({"start": round(owned_start, 3), "end": round(owned_end, 3), "text": recovered_text})
                    review_ranges.append({"start": round(owned_start, 3), "end": round(owned_end, 3)})
                    progress("Fragment recovered · approximate timestamps; review required", current=index, total=len(transcripts), detail=detail)
                    continue
                for word, word_start, word_end in preserved:
                    start = lo / sr + max(0, min((hi - lo) / sr, word_start))
                    end = lo / sr + max(0, min((hi - lo) / sr, word_end))
                    if owns(start, end, owned_start, owned_end, duration):
                        words.append({"start": round(start, 3), "end": round(end, 3), "text": word})
                mx.clear_cache()
                progress("Aligning word timestamps…", current=index, total=len(transcripts), detail=detail)
            # Ownership is temporal, not text deduplication: repeated answers
            # remain distinct and every source keeps its original time offset.
            words.sort(key=lambda w: (w["start"], w["end"]))
            write_output(job["output"], {"text": " ".join(w["text"] for w in words), "duration": duration, "words": words,
                "reviewRanges": review_ranges})
            del audio
        del aligner
        gc.collect()
        mx.clear_cache()
    progress(f"Local transcription complete in {time.perf_counter() - started:.1f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio")
    parser.add_argument("--output")
    parser.add_argument("--model", choices=MODELS, default="qwen")
    parser.add_argument("--jobs", help="JSON manifest for reusing models across sources")
    parser.add_argument("--terms", default="")
    args = parser.parse_args()
    try:
        if args.jobs:
            jobs = json.loads(Path(args.jobs).read_text(encoding="utf-8"))
        else:
            if not args.audio or not args.output:
                parser.error("--audio and --output or --jobs are required")
            jobs = [{"audio": args.audio, "output": args.output, "model": args.model}]
        terms = [term.strip() for term in re.split(r"[,\n]", args.terms) if term.strip()][:100]
        if any(len(term) > 100 for term in terms):
            raise ValueError("Use short vocabulary terms (up to 100 characters each).")
        run_jobs(jobs, terms)
    except Exception as error:
        progress(f"Local transcription failed: {error}")
        sys.exit(1)
