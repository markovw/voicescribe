"""Runner regressions without speech weights or network access."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace, ModuleType
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import soundfile as sf

spec = importlib.util.spec_from_file_location("local_transcribe", Path(__file__).resolve().parents[1] / "Accurate/transcribe.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LocalModelTests(unittest.TestCase):
    def test_saturated_recognition_retries_shorter_and_reports_missing_audio(self):
        calls = []
        def generate(audio, **options):
            calls.append(len(audio))
            saturated = len(audio) > 6 * 16000
            return SimpleNamespace(text="loop" if saturated else "Short text.", generation_tokens=100 if saturated else 3)
        audio = np.ones(20 * 16000, dtype=np.float32)
        recovered, missing = runner.recognize_shorter(SimpleNamespace(generate=generate), audio, 16000, 0, 20, {"max_tokens": 100})
        self.assertFalse(missing)
        self.assertEqual([(lo, hi) for lo, hi, _ in recovered], [(0, 5), (5, 10), (10, 15), (15, 20)])
        self.assertTrue(all(result.text == "Short text." for _, _, result in recovered))
        failed = SimpleNamespace(generate=lambda audio, **options: SimpleNamespace(text="loop", generation_tokens=100))
        recovered, missing = runner.recognize_shorter(failed, audio, 16000, 0, 20, {"max_tokens": 100})
        self.assertFalse(recovered)
        self.assertEqual(sum(item["end"] - item["start"] for item in missing), 20)

    def test_failed_alignment_recovers_owned_span_and_continues(self):
        calls = []
        asr = SimpleNamespace(generate=lambda audio, **kwargs: (calls.append(len(audio)) or
            SimpleNamespace(text="Recovered text.", generation_tokens=3)))
        processor = SimpleNamespace(clean_token=lambda text: text.strip("."),
            tokenize_space_lang=lambda text: [text.strip(".")])
        alignment_calls = []
        def align(**kwargs):
            alignment_calls.append(1)
            if len(alignment_calls) == 1:
                return []
            return [SimpleNamespace(start_time=2, end_time=2.5), SimpleNamespace(start_time=2.5, end_time=3)]
        aligner = SimpleNamespace(aligner_processor=processor, generate=align)
        mlx = ModuleType("mlx")
        core = ModuleType("mlx.core")
        core.clear_cache = lambda: None
        mlx.core = core
        stt = ModuleType("mlx_audio.stt")
        stt.load = lambda model: aligner if model == runner.ALIGN_MODEL else asr
        with tempfile.TemporaryDirectory() as folder:
            audio = Path(folder) / "input.wav"
            sf.write(audio, np.ones(60 * 16000, dtype=np.float32) * 0.05, 16000)
            job = {"audio": str(audio), "output": str(Path(folder) / "result.json"), "model": "qwen"}
            with patch.dict(sys.modules, {"mlx": mlx, "mlx.core": core, "mlx_audio": ModuleType("mlx_audio"), "mlx_audio.stt": stt}):
                runner.run_jobs([job], [])
            result = json.loads(Path(job["output"]).read_text())
            self.assertEqual(len(result["reviewRanges"]), 1)
            span = result["reviewRanges"][0]
            self.assertEqual(result["words"][0], {"start": span["start"], "end": span["end"], "text": "Recovered text."})
            self.assertLess(calls[-1], calls[0])  # recovery excludes neighbour context
            self.assertEqual(len(result["words"]), 3)  # subsequent fragment still aligned

    def test_alignment_subtokens_preserve_original_text_and_times(self):
        processor = SimpleNamespace(clean_token=lambda text: text.strip("!,"),
            tokenize_space_lang=lambda text: ["中", "文"] if "中文" in text else [text.strip("!,")])
        aligner = SimpleNamespace(aligner_processor=processor)
        aligned = [SimpleNamespace(start_time=i, end_time=i + 0.5) for i in range(3)]
        result = runner.preserve_aligned_words("中文, yes!", aligned, aligner)
        self.assertEqual(result, [("中文,", 0, 1.5), ("yes!", 2, 2.5)])
        with self.assertRaisesRegex(RuntimeError, "expected 3 alignment tokens, received 2"):
            runner.preserve_aligned_words("中文, yes!", aligned[:2], aligner)
        aligned[1].end_time = float("nan")
        with self.assertRaisesRegex(RuntimeError, "invalid timestamps"):
            runner.preserve_aligned_words("中文, yes!", aligned, aligner)

    def test_context_ownership_partitions_without_erasing_repetitions(self):
        audio = np.ones(110 * 16000, dtype=np.float32)
        spans = list(runner.chunks(audio, 16000))
        self.assertEqual(spans[0][2], 0)
        self.assertEqual(spans[-1][3], 110)
        for first, second in zip(spans, spans[1:]):
            self.assertEqual(first[3], second[2])
            self.assertGreater(first[1], second[0])
            boundary = first[3]
            self.assertFalse(runner.owns(boundary - 0.1, boundary + 0.1, first[2], first[3], 110))
            self.assertTrue(runner.owns(boundary - 0.1, boundary + 0.1, second[2], second[3], 110))

    def test_moss_native_times_and_missing_voice_evidence(self):
        result = SimpleNamespace(text="hello", segments=[{"start": 1, "end": 2, "text": "[S01] hello", "speaker_id": "S01"}])
        segments = runner.parse_moss(result, 10, 10, 20, 30, 3)
        self.assertEqual((segments[0]["start"], segments[0]["end"], segments[0]["chunk"]), (11, 12, 3))
        self.assertEqual(segments[0]["text"], "hello")
        result.segments[0]["speaker_id"] = "invalid"
        self.assertTrue(runner.parse_moss(result, 10, 10, 20, 30, 3)[0]["needsReview"])
        result.segments[0]["end"] = 40
        with self.assertRaises(RuntimeError):
            runner.parse_moss(result, 10, 10, 20, 30, 3)

    def test_models_reused_across_sources_with_terms_and_original_words(self):
        loaded, options = [], []
        asr = SimpleNamespace(generate=lambda audio, **kwargs: (options.append(kwargs) or SimpleNamespace(text="Да, yes!", generation_tokens=3)))
        aligner = SimpleNamespace(aligner_processor=SimpleNamespace(clean_token=lambda text: text.strip("!,"),
            tokenize_space_lang=lambda text: [text.strip("!,")]),
            generate=lambda **kwargs: [SimpleNamespace(start_time=0, end_time=0.5), SimpleNamespace(start_time=0.5, end_time=1)])
        mlx = ModuleType("mlx")
        mlx_core = ModuleType("mlx.core")
        mlx_core.clear_cache = lambda: None
        mlx.core = mlx_core
        stt = ModuleType("mlx_audio.stt")
        stt.load = lambda model: (loaded.append(model) or (aligner if model == runner.ALIGN_MODEL else asr))
        with tempfile.TemporaryDirectory() as folder:
            audio = Path(folder) / "input.wav"
            sf.write(audio, np.ones(16000, dtype=np.float32) * 0.05, 16000)
            jobs = [{"audio": str(audio), "output": str(Path(folder) / f"result-{i}.json"), "model": "qwen"} for i in range(2)]
            with patch.dict(sys.modules, {"mlx": mlx, "mlx.core": mlx_core, "mlx_audio": ModuleType("mlx_audio"), "mlx_audio.stt": stt}):
                runner.run_jobs(jobs, ["AsyncSequence"])
            self.assertEqual(loaded, [runner.MODELS["qwen"], runner.ALIGN_MODEL])
            self.assertTrue(all(item["hotwords"] == ["AsyncSequence"] for item in options))
            for job in jobs:
                result = json.loads(Path(job["output"]).read_text())
                self.assertEqual(result["text"], "Да, yes!")
                self.assertEqual(len(result["words"]), 2)


if __name__ == "__main__":
    unittest.main()
