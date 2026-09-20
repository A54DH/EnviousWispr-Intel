# Intel WhisperKit feasibility spike

This is **step 1, not an Intel release of EnviousWispr**. It asks whether the app's
exact WhisperKit dependency can build and transcribe a known recording on native
Intel macOS. It does not modify the app, its lockfile, release architecture,
helpers, signing, update feed, or model defaults.

## Current status and next step

**Keep repository Actions disabled and leave this PR unmerged.** The owner has
requested no further Actions execution without explicit approval.

The first run produced two different outcomes, not two Intel inference failures:

- CPU-only: dependency download failed because the runner could not connect to GitHub.
  The engine was never built or exercised in that job.
- CPU/GPU: the Intel executable built and the Tiny English model loaded. The process
  then exited with signal 11 during its first transcription. There is no completed
  transcript or saved stack trace establishing the root cause.

See [the evidence review](RESULTS-2026-09-20.md). No crash fix is claimed.
The next useful experiment is **one CPU-only test**, preferably on the intended
physical Mac after checking its macOS, memory, and Xcode/toolchain. Do not automatically
repeat the GPU run or expand the model matrix.

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

One invocation requests either CPU-only or CPU/GPU compute, never Neural Engine.
It records model-download and model-load time, then performs three transcriptions:
one first-in-process inference and two warmed repeats. Each includes the audio-file
conversion cost. The load measurement may include tokenizer downloads. These are not
controlled cold-boot measurements; Core ML's persistent cache is not cleared.

All three transcripts must be non-empty and have word error rate <= 20% after case
and punctuation normalization. This is a coarse smoke-test gate, not a dictation
quality claim. Latency is measured, not gated. Real-time factor (RTF) is elapsed
processing time divided by audio duration; below 1 means faster than real time for
this recording. It does not mean instant paste after recording stops.

## GitHub Actions: manual opt-in only

The experiment workflow now has **only `workflow_dispatch`**, with an explicit
`approved` input defaulting to false. There is no push, PR, or schedule trigger and
no two-job matrix. One approved invocation runs one selected compute setting; the
default is CPU-only with Tiny English. The job is capped at 20 minutes, with a
600-second probe limit. These are safety ceilings, not performance targets.
A whole-job timeout may prevent artifact upload; inspect the job log in that case.

This changes only the experiment workflow on `intel-spike`. The fork still contains
inherited upstream workflows, including the broad PR check. **Do not re-enable all
Actions merely to expose the manual button.** Those other workflows would need to be
reviewed or disabled separately first. The repository-wide disabled setting remains
the immediate safeguard. Future commits should also use `[skip ci]` while paused.

GitHub requires a `workflow_dispatch` workflow to be on the default branch before
manual dispatch is available. Do not merge this draft just to make that button appear.
Reference: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow

The workflow uses the explicit `macos-15-intel` runner and rejects ARM64 and Rosetta.
It has read-only repository access, no secrets, and no signing, deployment or release.
Diagnostics for future approved runs are retained for 3 days; model weights and audio
are not uploaded. Existing artifacts keep their original retention period.

## Run on a physical Intel Mac instead

Requires native Intel macOS 14+, full Xcode with a Swift 6+ toolchain, Python 3, Git,
and internet access for public dependency/model/tokenizer downloads. Check those
prerequisites first; the hosted macOS 15 result does not validate macOS 14.

From this repository on the `intel-spike` branch, run only the CPU test initially:

```bash
python3 -m unittest discover -s experiments/intel-whisperkit/tests -v
python3 experiments/intel-whisperkit/run.py --compute cpu
```

These commands run on the local computer, not GitHub Actions. No personal recording
is needed. Do not run further compute settings or larger models until this result
has been reviewed. `--compute cpu-gpu` and `--model` remain available for later,
deliberately chosen comparisons.

Each invocation creates a new timestamped results directory. `--output PATH` selects a
new directory explicitly; an existing directory is refused to prevent stale results.
Resolution, build, and inference have bounded subprocess timeouts. The local probe
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
For the first GPU failure, the important detail is in `raw.json`, not its generic summary.

**Model limitation:** dependency source and the fixture are pinned, but Hugging Face
model/tokenizer artifacts are fetched at run time, not from an immutable snapshot.
Compare fingerprints before comparing runs; do not describe changed model bytes as a
hardware-only comparison. This is not the app's production model-delivery mechanism.

A hosted Intel VM can expose a virtual or unusable Metal GPU. Requested CPU/GPU compute
is not proof that Core ML used a GPU. The saved first run lists `Apple Paravirtual device`.
That is not enough evidence to attribute the crash to the GPU. Hosted timing is not a
substitute for measurements on the target physical Mac.

A successful small-model test would establish an engine foothold only. The full app,
larger models, VAD, Parakeet gating, bundled ARM binaries, helpers, and fork-specific
updates remain separate work. No successful transcription or installable Intel app
is claimed by this experiment yet.
