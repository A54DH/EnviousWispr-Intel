# Intel WhisperKit feasibility spike

This is **step 1, not an Intel release of EnviousWispr**. It asks whether the app's
exact WhisperKit dependency can build and transcribe a known recording on native
Intel macOS. It does not modify the app, its lockfile, release architecture,
helpers, signing, update feed, or model defaults.

## What runs

The separate Swift package reads `../../Package.resolved` and pins Argmax and its
Swift Argument Parser dependency to those **exact commits**. At creation these are
Argmax/WhisperKit 1.1.0 (`1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`) and Argument Parser
`626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b`. The resolved graph is checked before building.
Only the WhisperKit product is linked: no app UI, FluidAudio, analytics, or polishing.

The recording is the pinned dependency's own `Tests/WhisperKitTests/Resources/jfk.wav`.
Its Git blob identity is checked (`3184d372cd2f8b804d3a540c70ec50d927b335d2`) and its
SHA-256 recorded. The reference transcript is used **only for scoring afterward**;
it is never included in the recognition prompt. No microphone or personal audio is used.

The probe requests CPU-only and CPU/GPU compute in separate jobs, never Neural Engine.
It records model-download and model-load time, then performs three transcriptions:
one first-in-process inference and two warmed repeats. Each includes the audio-file
conversion cost. The load measurement may include tokenizer downloads. These are not
controlled cold-boot measurements; Core ML's persistent cache is not cleared.

All three transcripts must be non-empty and have word error rate <= 20% after case
and punctuation normalization. This is a coarse smoke-test gate, not a dictation
quality claim. Latency is measured, not gated. Real-time factor (RTF) is elapsed
processing time divided by audio duration; below 1 means faster than real time for
this recording. It does not mean instant paste after recording stops.

## Run on GitHub

The `Intel WhisperKit Spike` workflow runs on pushes to `intel-spike`, on the explicit
`macos-15-intel` runner. It rejects ARM64 and Rosetta rather than silently testing a
different architecture. Jobs have read-only repository access, no secrets, and do
not deploy, sign, release, or update anything. Model downloads use public upstream
endpoints. Diagnostics are retained for 14 days; model weights and audio are not uploaded.

Forks can initially have Actions disabled. If no run appears, open the fork's Actions
tab and enable workflows. A subsequent push to this branch then triggers the probe.
`workflow_dispatch` becomes available in the UI once the workflow exists on the default
branch; merely opening this PR does not make that button appear. Do not merge it only
for that reason: the push trigger works while the experiment remains unmerged.

The default model is **Tiny English**, not the app's much larger Turbo model. A Tiny
pass only establishes an engine foothold. After the initial result, test Base English
and the actual Turbo model before deciding on the application port. The manual workflow
input supports these when dispatch is available; local commands are below.

## Run on a physical Intel Mac

Requires native Intel macOS 14+, full Xcode with a Swift 6+ toolchain, Python 3, Git,
and internet access for public dependency/model/tokenizer downloads. The workflow's
macOS 15 result alone does not validate the macOS 14 deployment floor.

From this repository on the `intel-spike` branch:

```bash
python3 -m unittest discover -s experiments/intel-whisperkit/tests -v
python3 experiments/intel-whisperkit/run.py --compute cpu
python3 experiments/intel-whisperkit/run.py --compute cpu-gpu
# Later, assess the actual application model separately:
python3 experiments/intel-whisperkit/run.py --compute cpu \
  --model openai_whisper-large-v3-v20240930_turbo
```

Each command creates a new timestamped results directory. `--output PATH` selects a
new directory explicitly; an existing directory is refused to prevent stale results.
Resolution, build, and inference have bounded subprocess timeouts. The probe safety
limit defaults to 1,200 seconds and is adjustable with `--probe-timeout` (1–3,600).
A timeout is inconclusive, not proof that Intel cannot run the engine.

## Read the evidence

`summary.md` and `summary.json` contain the verdict and stage. `environment.json` records
CPU, OS, Xcode, Swift, architecture, runner image and source commit. `app-pins.json` and
`probe-pins.json` establish the dependency versions; `fixture.json` identifies the input.
`resolve.log`, `build.log` and `probe.log` distinguish network/resolution, compiler and
runtime failures. `raw.json` is checkpointed before model download/load and every inference,
so even a crash or timeout can leave its last stage. `/usr/bin/time -l` resource usage is
in `probe.log`. `model-files.json` fingerprints downloaded model/tokenizer cache files.

**Model limitation:** dependency source and the fixture are pinned, but Hugging Face
model/tokenizer artifacts are fetched at run time, not from an immutable snapshot.
Compare fingerprints before comparing runs; do not describe changed model bytes as a
hardware-only comparison. This is not the app's production model-delivery mechanism.

A hosted Intel VM can expose no usable Metal GPU. Requested CPU/GPU compute is not
proof that Core ML used a GPU. An isolated GPU-job failure does not invalidate a CPU
success, and no hosted timing substitutes for measurements on the target physical Mac.

## Next decision

- Build failure: identify the exact dependency/compiler/SDK blocker before app changes.
- Download failure: fix network/model access; no Intel compatibility conclusion yet.
- Load/inference failure: inspect Core ML errors and CPU-only behavior; then consider a
  small compatibility patch or a whisper.cpp backend rather than assuming a rewrite.
- Tiny passes: benchmark larger models and real dictations on the target Intel Mac,
  then attempt the whole app build and address VAD, Parakeet gating, bundled ARM binaries,
  helpers, and fork-specific update configuration.

No successful run is claimed until its actual workflow report exists. This addition
is intentionally not evidence of an installable Intel app or Apple Silicon feature parity.
