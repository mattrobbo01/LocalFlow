# LocalFlow

A private, fully-local Wispr Flow alternative for macOS. Hold **fn**, speak, release — clean formatted text appears in whatever app has focus. Nothing ever leaves your Mac.

Native Swift menu-bar app, no Electron. Speech-to-text and speaker verification run on the Apple Neural Engine; a typical dictation lands in ~150 ms — faster than the cloud product it replaces.

## Why

Wispr Flow streams your audio **plus** your screen's accessibility tree, app/URL history, and current textbox contents to cloud GPUs, targeting ~700 ms round-trip. LocalFlow replaces the entire cloud pipeline with on-device inference:

| | Wispr Flow | LocalFlow |
|---|---|---|
| Speech-to-text | Cloud (Baseten gRPC) | Parakeet-TDT-0.6B-v3 CoreML on the Apple Neural Engine |
| Cleanup/formatting | Fine-tuned Llama in the cloud | Rule-based pass (+ optional local Ollama) |
| Screen context sent off-device | AX tree, app/URL log, textbox contents | Nothing, ever |
| Dictation history | Cloud-synced SQLite | Local JSONL you own |
| Typical latency after release | ~700 ms (network-bound) | **~100 ms** (measured 83 ms for 6.6 s audio on M5) |

## Build & run

```sh
./build_app.sh      # swift build -c release + assembles LocalFlow.app
open LocalFlow.app
```

First launch downloads the Parakeet CoreML models (~600 MB, one time) from HuggingFace into `~/Library/Application Support/FluidAudio/Models`. All inference afterwards is offline.

### Permissions (one-time)

macOS will prompt for, or you grant in **System Settings → Privacy & Security**:

1. **Microphone** — to hear you
2. **Accessibility** — to post the synthetic ⌘V that inserts text
3. **Input Monitoring** — for the listen-only event tap that watches the fn key

Also set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**, so holding fn doesn't trigger Apple's emoji picker/dictation alongside LocalFlow.

## Use

- **Hold fn** (Globe), speak, **release** → text is pasted into the focused app (your clipboard is saved and restored).
- **Double-tap fn** → hands-free mode: keep talking with nothing held; **press fn once** to stop and insert (5-minute cap).
- Taps shorter than ~0.35 s are ignored; pressing another key mid-hold (fn+arrow etc.) cancels — chords never trigger dictation.
- Say **"new line"** / **"new paragraph"** for line breaks. Fillers (um, uh…) are stripped automatically.
- Menu bar (waveform icon): model status, last-dictation latency, personal dictionary, history, Ollama toggle.

### Personal dictionary

Menu → **Personal Dictionary…** opens an editor window (add, edit, delete spoken → written replacements; matching is case-insensitive). Backing file: `~/Library/Application Support/LocalFlow/dictionary.json`.

**Auto-learning** (menu → Learn From My Edits, on by default): after inserting text, LocalFlow remembers what it typed and where. If you correct a word in place — fix casing, spelling, jargon — it re-reads the field (Accessibility API, locally), word-aligns old vs new, and adds the correction to the dictionary so it never makes that mistake again. Guardrails: only similar-word substitutions and mid-sentence case fixes are learned (never rewrites-for-meaning or sentence-start capitalization), max 3 per dictation, and everything learned is visible/deletable in the dictionary window.

### Voice enrollment (background-speech filter)

Menu → **Enroll My Voice (20s)…** and speak naturally until the pill confirms. LocalFlow builds a local voice fingerprint (WeSpeaker embedding via FluidAudio; first enrollment downloads the diarization models). With **Only Type My Voice** ticked, every dictation is diarized and segments that don't match your voice — TV, other people in the room — are cut before transcription. Fail-open: if the filter can't run, audio passes through untouched. Tune strictness via `voiceMatchThreshold` in settings.json (default 0.6; lower = stricter).

### Optional LLM polish

If [Ollama](https://ollama.com) is installed (`ollama pull llama3.2`), enable **Polish with local LLM** in the menu for grammar/self-correction cleanup — still fully on-device, best-effort with fallback to the rule-based pass.

### Settings

`~/Library/Application Support/LocalFlow/settings.json`: hotkey (`fn` | `rightCommand` | `rightOption`), sounds, Ollama model, minimum utterance length. Restart the app after editing.

## Verify headlessly

```sh
say -o t.aiff "testing local flow" && afconvert -f WAVE -d LEI16@16000 -c 1 t.aiff t.wav
.build/release/LocalFlow --transcribe t.wav
```

## Architecture

```
fn down ──► CGEventTap (listen-only, flagsChanged) ──► AVAudioEngine 16 kHz mono
fn up   ──► Parakeet-TDT v3 (CoreML / ANE, via FluidAudio) ──► ASR text
        ──► rule pass: fillers, spoken commands, dictionary [+ Ollama]
        ──► NSPasteboard + synthetic ⌘V (clipboard restored) ──► focused app
```

Design notes:
- The event tap is **listen-only** on purpose: modifying taps can suppress keystrokes system-wide, and one missed key-up bricks the keyboard (the documented Wispr "ate my spacebar" failure mode).
- Paste-based injection over per-character synthetic keystrokes: layout-independent and fast for long text.
- Each utterance gets a fresh decoder state; Parakeet's transducer stays silent during silence (no Whisper-style hallucinated words in pauses).

## Not yet implemented

Voice command/editing mode, per-app tone styles, streaming partial results, multilingual hint UI (Parakeet v3 already supports 25 languages).

## How this was built

Built end-to-end in a day, pair-programming with [Claude Code](https://claude.com/claude-code): researching Wispr Flow's architecture (including the forensic teardowns of what it ships to the cloud), choosing the on-device stack, and iterating through the real-world macOS pain — TCC permission invalidation on re-signing, fn-key events being invisible to `flagsState`, voice-processing silently muting capture, diarization garbage on partial windows — with a live `log stream` feedback loop between builds. The commit history and code comments preserve the war stories.

## Credits & licenses

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) — CoreML runtime for ASR, VAD, and diarization
- [Parakeet-TDT-0.6B-v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) (CC-BY-4.0, NVIDIA) — speech-to-text model, downloaded at first run
- Speaker models: pyannote segmentation + WeSpeaker embeddings via FluidAudio's CoreML conversions
- LocalFlow itself: MIT
