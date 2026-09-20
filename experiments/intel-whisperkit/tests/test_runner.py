import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("probe_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def good_report():
    return {"schemaVersion": 1, "status": "completed", "audioSeconds": 10.0,
            "inferences": [{"iteration": i, "kind": "first_in_process" if i == 1 else "warmed_repeat",
                            "seconds": 2.0, "transcript": runner.REFERENCE} for i in range(1, 4)]}


class ScoringTests(unittest.TestCase):
    def test_case_and_punctuation_do_not_count_as_errors(self):
        self.assertEqual(runner.word_error_rate("Hello, WORLD!", "hello world"), 0)

    def test_edit_operations(self):
        self.assertEqual(runner.word_error_rate("one two three", "one three"), 1 / 3)
        self.assertEqual(runner.word_error_rate("one two", "one new two"), 0.5)
        self.assertEqual(runner.word_error_rate("one two", "one three"), 0.5)

    def test_empty_reference_rejected(self):
        with self.assertRaises(ValueError):
            runner.word_error_rate("...", "something")

    def test_correct_transcript_passes_all_repeats(self):
        scored = runner.evaluate(good_report())
        self.assertTrue(all(row["correctnessPassed"] for row in scored))
        self.assertEqual(scored[0]["realTimeFactor"], 0.2)

    def test_wrong_nonempty_transcript_fails(self):
        raw = good_report()
        raw["inferences"][1]["transcript"] = "completely unrelated words"
        self.assertFalse(runner.evaluate(raw)[1]["correctnessPassed"])

    def test_missing_or_invalid_evidence_never_passes(self):
        changes = [lambda r: r.update(status="running"),
                   lambda r: r.update(schemaVersion=99),
                   lambda r: r.update(audioSeconds=0),
                   lambda r: r.update(audioSeconds=float("nan")),
                   lambda r: r["inferences"].pop(),
                   lambda r: r["inferences"][0].update(transcript="..."),
                   lambda r: r["inferences"][0].update(seconds=float("inf")),
                   lambda r: r["inferences"][0].update(seconds=-1),
                   lambda r: r["inferences"][1].update(iteration=1),
                   lambda r: r["inferences"][1].update(kind="first_in_process")]
        for change in changes:
            with self.subTest(change=change):
                raw = copy.deepcopy(good_report())
                change(raw)
                with self.assertRaises(ValueError):
                    runner.evaluate(raw)

    def test_dependency_drift_rejected(self):
        lock = {"pins": [{"identity": "argmax-oss-swift", "state": {"revision": "a"}},
                         {"identity": "swift-argument-parser", "state": {"revision": "b"}}]}
        runner.verify_resolution(lock, lock)
        changed = copy.deepcopy(lock)
        changed["pins"][0]["state"]["revision"] = "new"
        with self.assertRaises(ValueError):
            runner.verify_resolution(lock, changed)

    def test_model_fingerprint_streams_actual_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "model.bin").write_bytes(b"abc")
            rows = runner.model_fingerprints(path)
            self.assertEqual(rows[0]["sha256"],
                             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    def test_report_persistence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.json"
            runner.save(path, {"status": "failed"})
            self.assertEqual(json.loads(path.read_text())["status"], "failed")
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_failed_subprocess_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                runner.execute([sys.executable, "-c", "raise SystemExit(7)"],
                               Path(directory) / "child.log", 10)

    def test_subprocess_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.execute([sys.executable, "-c", "import time; time.sleep(2)"],
                               Path(directory) / "child.log", 0.05)


if __name__ == "__main__":
    unittest.main()
