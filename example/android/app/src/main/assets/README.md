# AppDNA SDK — Android config assets

Two files belong here for the AppDNA SDK to work on Android — both are
**gitignored** (never committed) and provided at build time by the Mac bridge
for the throwaway demo tenant:

- `google-services-appdna.json` — **required** AppDNA Firebase config (D15).
  Without it, remote config (paywalls/onboarding/experiments/flags) + push do NOT load.
  Download it from the console: Settings → SDK → API keys → "Download Config"
  (a Flutter/cross-platform app gets a ZIP with both this + the iOS plist).
- `appdna-config.json` — optional offline-first config bundle (D8). If present,
  the SDK renders from it on first launch before the network is available.
