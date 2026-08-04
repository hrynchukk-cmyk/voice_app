# Voice model enrollment & import

This workflow is **consent-first**. The point of enrollment is to let an
authorized speaker's voice be used — never to capture or clone someone without
their knowledge.

## Hard consent gate

Before any recording is imported or any model is registered, the user must
confirm, in an explicit and recorded step:

> "I confirm I have the permission of the person whose voice this is to create
> and use a voice model from these recordings."

`ConsentManager` stores this attestation (timestamp + the exact statement +
optional free-text note like "recorded consent on file") next to the model.
`VoiceModelStore` refuses to expose a model to the converter if the attestation
is missing. There is no bypass flag.

The UI also shows the standing disclaimer:

> "This does not reproduce the person's real voice identically, and converted
> audio must be disclosed to the people you talk to."

## Supported import formats

WAV, AIFF, M4A (AAC), FLAC — decoded with `AVAudioFile` / `AVAudioConverter`.
Imported files are copied into the app container; **originals on disk are
preserved** unless the user explicitly deletes them.

## Recommended training audio (shown in-app)

- **Clean speech**, one speaker, no music or background chatter.
- **Minimal noise/reverb** — a quiet room, not a hall.
- **Phonetic variety** — varied sentences covering many sounds, not one
  repeated phrase.
- **Consistent mic distance** and level; avoid clipping.
- Guideline: several minutes of good audio beats an hour of noisy audio. State
  the minimum your chosen model needs (varies by model; zero-shot models like
  Seed-VC need far less than fine-tuned RVC).

## Local storage layout

```
Application Support/VoiceBridge/
└── Models/
    └── <model-uuid>/
        ├── model.json          # name, created date, engine, format
        ├── consent.json        # attestation (see ConsentManager)
        ├── weights.mlmodelc     # or .onnx / .pth, engine-dependent
        └── sources/             # imported originals (preserved)
            ├── take01.wav
            └── take02.flac
```

Everything is inside the sandbox container. Nothing is written outside it and
nothing is uploaded.

## Progress & failure reporting

`EnrollmentView` shows:
- Per-file import progress (decode, resample, feature extraction).
- Clear, specific failures (unsupported codec, corrupt file, too short, too
  noisy) with a retry affordance.
- If model *building/training* runs (Python, offline), stream its progress and
  surface non-zero exits as readable errors — never a silent failure.

## Deletion / data removal

Per-model **Delete** removes the entire `<model-uuid>/` directory, including
imported originals and the consent record, and unregisters it from the store.
The app never keeps a hidden copy. A global "remove all local data" action is
available in Preferences.

## What enrollment must NOT do

- Must not enroll from live/covert capture without the explicit attestation.
- Must not claim the output equals the person's real voice.
- Must not upload recordings or the resulting model anywhere by default.
