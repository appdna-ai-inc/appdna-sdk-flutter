# AppDNA SDK — iOS config assets

Place these in `ios/Runner/` (add to the Xcode "Runner" target's Copy Bundle Resources) —
both are **gitignored** and bridge-provided for the demo tenant:

- `GoogleService-Info-AppDNA.plist` — **required** AppDNA Firebase config (D15).
  Download from console → Settings → SDK → API keys → "Download Config" (ZIP for Flutter apps).
- `appdna-config.json` — optional offline-first config bundle (D8).
