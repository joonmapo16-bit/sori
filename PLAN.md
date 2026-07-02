# Plan: "Sori" — a free, local, shareable macOS dictation app (VoiceInk fork)

## Context

The user wants to replace macOS's native dictation (which handles Korean poorly) with a
system-wide app that: (1) runs locally and free via Whisper, keeping **audio on-device**;
(2) optionally cleans up the Korean transcript with **Claude Sonnet 5** (`claude-sonnet-5`);
and (3) can be **packaged and shared with friends** to run on their own Macs.

Decisions already made with the user:
- **Home:** a **new separate repo** (this `biopharma-deal-analyzer` repo is an unrelated Python
  library — confirmed to have zero reusable audio/LLM/packaging code).
- **Approach:** **fork/extend VoiceInk** (open-source native Swift dictation app).
- **Cleanup:** **bring-your-own API key** — each user supplies their own Anthropic key; cloud
  cleanup is opt-in, so the app stays free to distribute and audio never leaves the device.

## Key finding that reshapes scope

**Stock VoiceInk already satisfies most of the requirements out of the box:**
- Native macOS Swift app, system-wide dictation (hotkey → text into any app).
- Local, free transcription via **whisper.cpp** (models downloaded on first run).
- **"AI Enhancement" already supports bring-your-own-key providers including Anthropic** —
  i.e. the Sonnet-5 cleanup step is a *configuration/prompt* feature, not something to build.
- GPL v3.0, `VoiceInk.xcodeproj`, `brew install --cask voiceink`, `BUILDING.md`.

So this is **~80% configuration + prompt tuning + packaging**, and only a small amount of
actual Swift code. The fork exists mainly to set Korean-friendly defaults, guarantee the
current `claude-sonnet-5` model is selectable, optionally rebrand to "Sori", and produce a
signed build friends can run. Do **not** rebuild dictation/Whisper/hotkey/accessibility from
scratch — VoiceInk already has them.

## Constraints (important)

- **Must be built on a Mac with Xcode.** This is a native Swift/Xcode app. The current
  execution environment is a **Linux cloud container** — it **cannot build, run, or test**
  this app. Execution of this plan happens on the user's Mac (ideally a Claude Code session
  started there, or manual Xcode work).
- **GPL v3.0:** forking and sharing with friends is fully allowed. If binaries are
  distributed, the (modified) source must be offered too. Fine for this use case; keep the
  fork public or provide source alongside any build sent to friends.
- **"Free" caveat to state honestly in the app:** local Whisper is free; the optional Sonnet-5
  cleanup consumes the *user's own* Anthropic credits (per-token cost on their key). The app
  and transcription are free; cloud cleanup is opt-in.
- **Privacy caveat:** with cleanup enabled, transcribed *text* (not audio) is sent to Anthropic.
  Keep enhancement opt-in and label it clearly.

## Approach & work items

### 1. Repo setup (GitHub + Mac)
- Fork `Beingpax/VoiceInk` on GitHub into a new repo (e.g. `sori` / `sori-dictation`).
- Clone to the user's Mac. Keep the upstream remote to pull future VoiceInk updates.

### 2. Baseline build & smoke test (verify stock works before changing anything)
- Follow `BUILDING.md`; open `VoiceInk.xcodeproj` in Xcode; build & run.
- On first run: download a Whisper model — use a **`large`-class model** for Korean accuracy
  (small models transcribe Korean poorly); grant **Microphone** and **Accessibility**
  permissions.
- Verify end-to-end in a couple of apps (TextEdit/Notes/browser): hotkey → speak Korean →
  text inserted.

### 3. Cleanup provider & model (BYO key) — pluggable, not locked to Sonnet 5

The cleanup step runs **after every utterance**, so this is a **latency ↔ price ↔ Korean-quality**
tradeoff, and it should be **provider-swappable**, not hardwired to Sonnet 5.

**Two provider paths (both BYO key):**
- **Anthropic direct** — Sonnet 5 (`claude-sonnet-5`). Highest quality, highest cost/latency,
  US-hosted.
- **Fireworks (OpenAI-compatible)** — one custom endpoint
  `https://api.fireworks.ai/inference/v1` + a Fireworks key gives access to many open models by
  just swapping the model string. Fireworks is **US-hosted**; note that DeepSeek is a Chinese
  *model* but runs on Fireworks' *US infrastructure* under Fireworks' no-training data policy —
  text does not go to China. Data-privacy depends on the host's policy, not the model's origin.

**Model tiers to offer / test (cleanup is a simple task — favor small/fast):**

| Model | Price /1M (in/out) | Role |
|---|---|---|
| DeepSeek V4 Flash (Fireworks) | $0.14 / $0.28 | Default to try first — cheapest & fastest |
| Qwen3.6 Plus (Fireworks) | $0.50 / $3.00 | Best step-up; Qwen is strongest at Korean/CJK |
| GLM-5.1 / Kimi K2.6 (Fireworks) | see Fireworks pricing | Alternatives to A/B |
| Claude Sonnet 5 (Anthropic) | $3 / $15 ($2/$10 intro) | Premium fallback, highest quality |

**Wiring:**
- If VoiceInk exposes a **custom / OpenAI-compatible provider with a configurable base URL**
  (it advertises custom BYO-key providers), point it at Fireworks — no code change; swapping
  model = changing a string. Verify this in settings first.
- If it does **not** expose a custom base URL, the fork's main code change is adding an
  **OpenAI-compatible provider** (configurable `base_url` + key + model field). Easy, since
  Fireworks speaks the OpenAI API.
- For Anthropic direct, verify `claude-sonnet-5` is selectable; if VoiceInk's Anthropic model
  list is hardcoded/outdated, add it. Ensure the request doesn't send params Sonnet 5 rejects
  (`temperature`/`top_p`/`budget_tokens`); for cleanup prefer `thinking:{"type":"disabled"}`.
- Grep the Mac source for `anthropic`, `openai`, `baseURL`/`base_url`, `model`, `Enhancement`
  to locate the provider/model-list and request-builder files under `VoiceInk/`.

**Empirical Korean test (decides the default):** no reliable public Korean benchmark exists for
these July-2026 models, so run the **same messy Korean transcript** through DeepSeek V4 Flash,
Qwen3.6 Plus, and Sonnet 5; compare spacing/맞춤법/punctuation quality and measured latency;
pick the cheapest one that's good enough as the shipped default (keep the others selectable).

### 4. Korean cleanup prompt (the actual differentiator)
- Set the enhancement prompt to target the exact failure modes of raw Korean Whisper output:
  **띄어쓰기(spacing) correction, 맞춤법(spelling), 문장부호(punctuation), 구어체→문어체,
  존댓말/말투 통일**, and domain-term correction. Instruct it to **only correct, never add or
  summarize** content.
- If VoiceInk supports named presets / Power Mode per-app prompts, add a "Korean" preset.
  Prefer configuration over code where possible.

### 5. Branding to "Sori" (light, optional)
- Rename display name + bundle identifier; swap the app icon in
  `VoiceInk/Assets.xcassets/AppIcon.appiconset/`. Keep this minimal — it does not affect
  function and can be deferred.

### 6. Distribution to friends (the real friction — plan for it)
- **First-run model download:** the Whisper model (~GB) is downloaded on first launch, not
  bundled — document this for friends and expect the first-run delay.
- **Gatekeeper / signing — pick one:**
  - **Best:** code-sign + notarize with an **Apple Developer account ($99/yr)** so friends can
    open it normally.
  - **Free workaround:** ship unsigned and give friends the right-click → Open (or
    `xattr -d com.apple.quarantine`) instructions. Acceptable for a few friends.
- **Architecture:** build a universal binary (Apple Silicon + Intel) or note the requirement.
- Provide a short README for friends: install, grant Mic + Accessibility, (optional) paste
  their own Anthropic key, pick `large` Whisper model + Korean preset.

## Files likely to change (pattern, verify by grepping on the Mac)
- LLM provider / model list + enhancement-request builder under `VoiceInk/` → add/default
  `claude-sonnet-5`; ensure Sonnet-5-compatible request params.
- Enhancement prompt / preset config → Korean cleanup prompt.
- `Info.plist` / bundle id + `Assets.xcassets/AppIcon.appiconset/` → "Sori" branding (optional).
- New top-level `README.md` (setup + friend distribution instructions).

## Verification (all on a Mac — cannot be done in this container)
1. Clean build in Xcode from the fork; app launches as a menu-bar app.
2. Permissions granted; `large` Whisper model downloaded.
3. Dictate Korean into TextEdit/Notes/browser → text inserted (transcription-only path works
   offline with network off, proving audio stays local).
4. Enable enhancement and run the **provider A/B test** on a messy Korean sample: DeepSeek V4
   Flash + Qwen3.6 Plus (via the Fireworks endpoint) and Sonnet 5 (Anthropic direct). Confirm
   each returns without request errors, compare spacing/맞춤법/punctuation quality and latency,
   and set the cheapest good-enough model as the shipped default (others stay selectable).
5. Distribution test: install the produced build on a **second Mac** (or a friend's), complete
   first-run (perms + model download + own key), and confirm it works there.

## Notes / deferred
- Consider whether a fully-offline cleanup option (local LLM via Ollama) is worth adding later
  for friends who don't want any cloud step — out of scope for v1 (BYO-key chosen).
- Because execution requires a Mac + Xcode, the next step is to run this plan from a Claude Code
  session on the user's Mac (or hand it to the user to execute in Xcode), not from this
  Linux environment.
