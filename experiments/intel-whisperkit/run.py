#!/usr/bin/env python3
"""Build and measure an isolated Intel WhisperKit smoke test. Standard library only."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE_BLOB = "3184d372cd2f8b804d3a540c70ec50d927b335d2"
REFERENCE = (
    "And so my fellow Americans ask not what your country can do for you "
    "ask what you can do for your country."
)
MODELS = ("openai_whisper-tiny.en", "openai_whisper-base.en",
          "openai_whisper-large-v3-v20240930_turbo")
MAX_WER = 0.20  # Smoke-test tolerance, not a product-quality acceptance threshold.


def tokens(text: str) -> list[str]:
    return re.findall(r"[^\W_]+", text.casefold(), flags=re.UNICODE)


def word_error_rate(reference: str, hypothesis: str) -> float:
    expected, actual = tokens(reference), tokens(hypothesis)
    if not expected:
        raise ValueError("Reference must contain words")
    previous = list(range(len(actual) + 1))
    for i, word in enumerate(expected, 1):
        current = [i]
        for j, observed in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (word != observed)))
        previous = current
    return previous[-1] / len(expected)


def evaluate(raw: dict) -> list[dict]:
    """Fail closed: require all three valid measurements, not merely process exit 0."""
    if raw.get("schemaVersion") != 1 or raw.get("status") != "completed":
        raise ValueError("Probe did not produce a completed schema-v1 report")
    duration = raw.get("audioSeconds", 0)
    if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
        raise ValueError("Missing or invalid audio duration")
    inferences = raw.get("inferences", [])
    if len(inferences) != 3:
        raise ValueError("Expected one first-in-process and two warmed-up transcriptions")
    scored = []
    for i, inference in enumerate(inferences, 1):
        seconds = inference.get("seconds", -1)
        text = inference.get("transcript", "")
        kind = "first_in_process" if i == 1 else "warmed_repeat"
        if inference.get("iteration") != i or inference.get("kind") != kind:
            raise ValueError("Missing, duplicated or mislabelled inference")
        if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0:
            raise ValueError("Invalid inference timing")
        if not isinstance(text, str) or not tokens(text):
            raise ValueError("Empty transcript")
        wer = word_error_rate(REFERENCE, text)
        scored.append({**inference, "realTimeFactor": seconds / duration,
                       "wordErrorRate": wer, "correctnessPassed": wer <= MAX_WER})
    return scored


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def capture(command: list[str], required: bool = True) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if required and result.returncode:
        raise RuntimeError(f"{' '.join(command)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def execute(command: list[str], log: Path, timeout: int) -> None:
    print(f"Running: {' '.join(command)} (log: {log.name})", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        with subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                              text=True, start_new_session=True) as process:
            try:
                returncode = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # Also terminate compiler/probe descendants, not just /usr/bin/time.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                raise
    if returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-60:]), flush=True)
        raise RuntimeError(f"Command exited {returncode}; see {log.name}")


def verify_resolution(app_lock: dict, probe_lock: dict) -> None:
    wanted = {pin["identity"]: pin["state"]["revision"] for pin in app_lock["pins"]
              if pin["identity"] in ("argmax-oss-swift", "swift-argument-parser")}
    actual = {pin["identity"]: pin["state"]["revision"] for pin in probe_lock["pins"]}
    if len(wanted) != 2 or actual != wanted:
        raise ValueError(f"Dependency graph differs from app pins: expected {wanted}, got {actual}")


def model_fingerprints(cache: Path) -> list[dict]:
    records = []
    for path in sorted(cache.rglob("*")):
        if path.is_file() and not path.is_symlink():
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            records.append({"path": str(path.relative_to(cache)), "bytes": path.stat().st_size,
                            "sha256": digest.hexdigest()})
    return records


def markdown(summary: dict) -> str:
    lines = ["# Intel WhisperKit feasibility probe", "", f"Status: **{summary['status']}**",
             f"Stage: `{summary['stage']}`", f"Model: `{summary['model']}`",
             f"Requested compute: `{summary['compute']}`", ""]
    if "error" in summary:
        lines += ["Failure:", "```text", summary["error"], "```", ""]
    for row in summary.get("inferences", []):
        lines += [f"- {row['kind']} #{row['iteration']}: {row['seconds']:.3f}s; "
                  f"RTF {row['realTimeFactor']:.3f}; WER {row['wordErrorRate']:.1%}"]
    lines += ["", "RTF = processing seconds / audio seconds. No latency pass/fail gate.",
              "This is a short English engine smoke test, NOT validation of the complete app,",
              "its default Turbo model (unless explicitly selected), macOS 14, or everyday dictation quality.",
              "The CPU/GPU setting is requested placement, not proof of GPU execution.",
              "A hosted VM is not a performance substitute for the user's Intel Mac.", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compute", choices=("cpu", "cpu-gpu"), default="cpu")
    parser.add_argument("--model", choices=MODELS, default=MODELS[0])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--probe-timeout", type=int, default=1200,
                        help="Whole probe safety limit in seconds; not a performance target")
    args = parser.parse_args()
    if not 1 <= args.probe_timeout <= 3600:
        parser.error("--probe-timeout must be between 1 and 3600 seconds")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = (args.output or HERE / "results" / f"{stamp}-{args.compute}").resolve()
    # Never mix an earlier successful run with a new failed run.
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error(f"Output directory already exists; choose a new directory: {output}")
    summary = {"schemaVersion": 1, "status": "running", "stage": "environment",
               "model": args.model, "compute": args.compute, "startedAt": stamp,
               "maxWordErrorRate": MAX_WER}
    started = time.monotonic()
    cache = output / "model-cache"
    try:
        if platform.system() != "Darwin" or platform.machine() != "x86_64":
            raise RuntimeError("Run this probe natively on an Intel Mac, not Linux or Apple Silicon")
        if capture(["sysctl", "-in", "sysctl.proc_translated"], required=False) == "1":
            raise RuntimeError("Rosetta is not an Intel hardware test")
        environment = {
            "platform": platform.platform(), "architecture": platform.machine(),
            "cpu": capture(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "hardwareModel": capture(["sysctl", "-n", "hw.model"]),
            "swift": capture(["swift", "--version"]),
            "xcode": capture(["xcodebuild", "-version"]),
            "sourceCommit": capture(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
            "runner": {key: os.environ[key] for key in
                       ("RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion", "GITHUB_SHA")
                       if key in os.environ},
        }
        save(output / "environment.json", environment)
        app_lock = json.loads((ROOT / "Package.resolved").read_text())
        save(output / "app-pins.json", app_lock)
        summary["stage"] = "dependency_resolution"
        save(output / "summary.json", summary)
        execute(["swift", "package", "--package-path", str(HERE), "resolve"],
                output / "resolve.log", 600)
        resolved = json.loads((HERE / "Package.resolved").read_text())
        save(output / "probe-pins.json", resolved)
        verify_resolution(app_lock, resolved)

        summary["stage"] = "build"
        save(output / "summary.json", summary)
        execute(["swift", "build", "--package-path", str(HERE), "-c", "release",
                 "--disable-automatic-resolution", "--product", "intel-whisper-probe"],
                output / "build.log", 900)
        binary_directory = capture(["swift", "build", "--package-path", str(HERE),
                                    "-c", "release", "--show-bin-path"])
        binary = Path(binary_directory) / "intel-whisper-probe"
        architecture = capture(["lipo", "-archs", str(binary)])
        if architecture != "x86_64":
            raise RuntimeError(f"Unexpected binary architecture: {architecture}")
        summary["binaryArchitecture"] = architecture

        summary["stage"] = "fixture_verification"
        fixture = HERE / ".build/checkouts/argmax-oss-swift/Tests/WhisperKitTests/Resources/jfk.wav"
        data = fixture.read_bytes()
        blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if blob != FIXTURE_BLOB:
            raise RuntimeError("Upstream fixture changed; review it before changing the expected transcript")
        save(output / "fixture.json", {"source": str(fixture.relative_to(HERE)),
             "gitBlob": blob, "sha256": hashlib.sha256(data).hexdigest(),
             "reference": REFERENCE, "referenceIsNotPassedToModel": True})

        summary["stage"] = "probe"
        save(output / "summary.json", summary)
        execute(["/usr/bin/time", "-l", str(binary), str(fixture), str(cache),
                 args.compute, args.model, str(output / "raw.json")],
                output / "probe.log", args.probe_timeout)
        summary["stage"] = "correctness"
        raw = json.loads((output / "raw.json").read_text())
        summary["inferences"] = evaluate(raw)
        if not all(row["correctnessPassed"] for row in summary["inferences"]):
            raise RuntimeError(f"At least one transcript exceeds the {MAX_WER:.0%} smoke-test WER limit")
        summary["stage"] = "complete"
        summary["status"] = "passed"
    except (Exception, KeyboardInterrupt) as error:
        summary["status"] = "failed"
        summary["error"] = f"{type(error).__name__}: {error}"
        raw_path = output / "raw.json"
        if raw_path.exists():
            try:
                raw = json.loads(raw_path.read_text())
                summary["probeStage"] = raw.get("stage")
                summary["probeError"] = raw.get("error")
            except (ValueError, OSError):
                pass
    finally:
        # Model files are fetched at run time, not revision-pinned. Fingerprint actual
        # bytes (including cached tokenizers) so comparisons can detect changed inputs.
        try:
            save(output / "model-files.json", model_fingerprints(cache))
        except OSError as error:
            summary["fingerprintWarning"] = str(error)
        summary["elapsedSeconds"] = time.monotonic() - started
        save(output / "summary.json", summary)
        report = markdown(summary)
        (output / "summary.md").write_text(report, encoding="utf-8")
        print(report, flush=True)
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a", encoding="utf-8") as destination:
                destination.write(report)
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
