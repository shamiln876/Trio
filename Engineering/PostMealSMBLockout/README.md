# Post-meal SMB lockout — simulation-only policy

**NOT connected to Trio dosing or a pump. OFF by default.** This is an independently testable first stage of the requested feature, not a therapy-ready implementation.

Intended behavior after *verified pump delivery* of a bolus explicitly classified as meal-associated:

- Suppress automated SMB **permission** for 30 minutes, without changing basal, targets, CR, ISF, DIA, correction boluses, or the global SMB settings.
- Never trigger/restart after an SMB, correction-only bolus, delayed carb entry, rescue carbs or an acknowledgment that a remote bolus was merely initiated.
- Expire using the persisted original delivery timestamp; deduplicate stable pump-event identifiers. No lockout when configuration is off, state unavailable, or duration invalid.
- Newly confirmed *distinct meal* bolus may start a fresh window.
- The ordinary algorithm retains full responsibility for all dose decisions after expiration; this policy does not create insulin requests.

## Verification

Run `swift test` under `Engineering/PostMealSMBLockout/`; nine pure policy tests passed in an isolated Linux Swift 6.2.1 toolchain on 2026-10-18. This **does not** constitute testing in the iOS app, simulator, real dosing algorithm or pump.

## Required before integration, build, or deployment

1. Identify actual delivered meal boluses from **pump history** and matched treatment/meal records; local and remote bolus UI paths must agree. Remote SmartMealReceiver currently reports initiation, **not delivery**, and cannot alone be a source of truth.
2. Specify matching/time-window rules robustly (including dual carb entries, prebolusing, correction-only boluses, rescued lows, retries and background reconnection). Do not classify every `isSMB == false` manual bolus as a meal.
3. Integrate this policy into **both** native algorithm SMB permission and the final SMB enactment path to prevent a stale algorithm result from sending an SMB during a lockout. Verify temp-basal behavior and total insulin delivered, not just SMB counts.
4. Reconcile time changes, pump-history lag, pump changes, interruptions, persistence, and reboots. Add visible reasons and timestamped telemetry for suppressed SMBs; retain original requested SMB for retrospective comparison only.
5. Replay representative Nightscout/Trio meals (and correction-only episodes) before pump-in-loop testing, then controlled validation with appropriate clinical oversight. Prove low-glucose safety and failure behavior. Protect activation behind a separately controlled setting default OFF.
6. Do not merge or install this prototype on a live therapy device. It is intentionally disconnected from insulin delivery.
