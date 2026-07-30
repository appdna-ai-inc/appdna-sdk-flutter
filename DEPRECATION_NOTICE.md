# Deprecation Notice — AppDNA Flutter SDK MIT-licensed versions (≤ v1.0.0)

**TL;DR:** All MIT-licensed versions of the AppDNA Flutter SDK (**v1.0.0 and earlier**) are deprecated. **v1.0.1** is the new license-cutover release and the only version that will receive updates, support, and continued server compatibility. **You must migrate before 15 May 2026.**

---

## What's deprecated

Starting with **v1.0.1** (released **5 May 2026**), all MIT-licensed versions of the AppDNA Flutter SDK are **deprecated**:

| Platform | Final MIT version | First proprietary version |
| --- | --- | --- |
| Flutter | v1.0.0 | **v1.0.1** (released 5 May 2026) |

Until each platform's first proprietary release ships, the corresponding final MIT version remains temporarily supported on that platform only. Once the proprietary release is available, the migration timeline below begins.

## Migration timeline (Flutter)

| Date | Day | Milestone |
| --- | --- | --- |
| 5 May 2026 | Day 0 | v1.0.1 released. Migration guide published. Email reminder #1 sent to all v1.0.0-and-earlier users. |
| 10 May 2026 | Day 5 | Email reminder #2. v1.0.0-and-earlier receives no new features or fixes from this point. |
| 13 May 2026 | Day 8 | **Final warning email.** Console banner alerting MIT-version users to migrate. |
| **15 May 2026** | **Day 10** | **End of life:** Server-side support for v1.0.0 and earlier is disabled. v1.0.0-and-earlier SDK calls to AppDNA servers will fail. Apps still running MIT-licensed versions will lose all SDK functionality. |

**Existing customers must migrate to v1.0.1 before 15 May 2026 to avoid service disruption.** No exceptions; this is a hard cutover.

⚠️ **App Store and Google Play review can take 24–48 hours or longer.** Plan to submit your v1.0.1 release for review no later than **10 May 2026** to ensure approval and rollout before 15 May 2026.

## What changes in v1.0.1

1. **License**: v1.0.0 and earlier were distributed under the MIT License. v1.0.1 is distributed under AppDNA's proprietary license — see [LICENSE](./LICENSE) and [NOTICE.md](./NOTICE.md). For paying customers, your existing Terms of Service or Statement of Work continues to govern your rights; nothing changes for you operationally.
2. **API**: v1.0.1 is API-identical to v1.0.0. This is a license-only release — no code changes, no breaking changes.
3. **Supported version**: v1.0.1 is the first version under the new license model. All future Flutter SDK releases will continue from this baseline.

## How to migrate

1. Update your dependency to v1.0.1 (or later) of the Flutter SDK in your `pubspec.yaml`:
   ```yaml
   dependencies:
     appdna_sdk:
       git:
         url: https://github.com/appdna-ai-inc/appdna-sdk-flutter.git
         ref: v1.0.1
   ```
   Then run `flutter pub get`.
2. Review the migration guide at https://docs.appdna.ai/migrations/v1-0-to-v1-1.
3. Test in staging on both iOS and Android.
4. Submit a new release of your app to the App Store and Google Play for review.
5. Once approved, ship the release to your users.
6. Confirm the new version is reporting in your AppDNA Console.

## Why such a short window?

We have a small, hands-on customer base, which lets us move quickly. Our team is available to provide direct migration support for every affected customer — contact support@appdna.ai and we will help you complete the migration well before 15 May 2026. Because v1.0.1 is API-identical to v1.0.0 (license-only release), the upgrade is a one-line dependency change for nearly all customers.

## Why are we doing this?

To consolidate the SDK on a single supported version under a clear, sustainable license that funds continued development and lets us responsibly ship significant new features that the open-licensed v1.0.x architecture cannot support. We're committed to making the migration as smooth as possible — please contact support@appdna.ai if you encounter any issues.

## Rights to MIT-licensed versions (v1.0.0 and earlier)

If you obtained v1.0.0 or earlier under the MIT License before v1.0.1 was released, **you retain MIT rights to those specific prior versions**. However, please note:

- After 15 May 2026, AppDNA will no longer accept connections from v1.0.0 or earlier Flutter SDKs. The MIT license gives you the right to keep running the v1.0.0 code, but it does not require AppDNA to keep its servers responding to it. Your app will lose AppDNA functionality.
- AppDNA does not provide support, security fixes, or store-compliance updates for v1.0.0 or earlier.
- Continuing to run v1.0.0 or earlier after 15 May 2026 in production is not advisable.

## Questions

- Migration help: support@appdna.ai
- Licensing questions: legal@appdna.ai
- Account / billing questions: billing@appdna.ai

---

© 2026 AppDNA AI, Inc.
