# Smart Meal receiver, protocol 1

This coordinated LoopFollow/Trio change adds `smart_meal` alongside existing remote commands. It does not change dosing preferences, basal profiles, the existing recommendation percentage, SMB rules, or ordinary remote Meal behavior. The matching LoopFollow branch is `feature/read-only-smart-meal-advisor`.

## User-visible behavior

LoopFollow calculates using the full meal, lets the caregiver accept or edit the upfront insulin amount, then prefills the standard editable Meal confirmation/authentication screen. Rice defaults to 75% carbs now and 25% at +30 minutes; Pizza to 70% now and 30% at +60; Fruit & Dessert to all carbs now; Custom is editable. Carb split and upfront insulin percentage are independent. The chosen percentage applies after Trio's existing adjusted full recommendation. An edited dose replaces the suggested units directly.

One confirmed request stores both dated carb entries. Only one upfront bolus can be requested. **No later insulin bolus is scheduled**, and the algorithm is not assigned a fixed remaining insulin percentage. Normal later automation still depends on its inputs.

## Receiver boundaries

- Existing shared-secret encryption, remote-enable and outer timestamp guards remain in place.
- The request is valid for 120 seconds; its calculation must be current, at most ten minutes old, and match the latest determination. Current settings must match the configuration hash.
- This implementation advertises only the verified Trio 1.0.2 standard calculation with an actual DASH pump and 0.05 U increment. Unsupported pump settings fail closed.
- Trio recomputes its native recommendation with **all new meal carbs** and requires agreement with the full recommendation in the request. The requested edited dose is independently limited by native bolus safety checks. A bolus since the calculation holds positive-dose processing rather than using an obsolete insulin snapshot.
- The outer legacy carbs/bolus/schedule fields must be absent. The new request contains no delayed insulin property.
- `SmartMealReceiver` durably claims the UUID before effects, atomically writes and flushes its ledger, serializes transactions, and returns the saved result for an exact replay. Reusing an ID with changed contents is rejected.
- Both carb rows use deterministic IDs. `BaseCarbsStorage.storeSmartMeal` saves them together in a fresh context through `SmartMealCarbBatch`; validation or save failure rolls back the entire batch. The normal legacy storage path remains unchanged.
- The later row contains carbs only and is excluded by the native meal algorithm until its date. No caregiver-phone timer or second APNs request is used.
- Protein/fat are zero unless explicitly included. Opting in allows the existing native FPU conversion; generated equivalents are part of the same atomic carb batch and have stable IDs. The later meal-carb row still has zero protein/fat and no FPU link.

The phase sequence is `claimed → carbsStored → bolusRequested → accepted` (the bolus phase is skipped for zero insulin). Validation rejection has no treatment effects. Interrupted/ambiguous effects become `uncertain` and prevent a new transaction until a caregiver checks both carb entries and actual delivery, then explicitly acknowledges that check in Settings → Remote Control. Acknowledgement never retries a command.

`accepted` reports stored carbs and, for a positive dose, successful initiation reported by the bolus callback. It is **not proof of full pump delivery**. Actual pump/treatment records remain the delivery record. An accepted APNs submission alone confirms neither storage nor insulin.

## Settings and result upload

The existing Nightscout device status gains an optional `openaps.smartMeal` object with protocol version, generated/calculation times, paired bundle identity, actual current percentage and limits, increment, and recent correlated receipts. No remote credential is included. Processing/reconciliation requests an immediate device-status upload through the existing serialized pipeline. Older clients ignore the additional object.

LoopFollow accepts the capability only when fresh, calculation-matched and paired to its configured Trio identity. It automatically imports these live settings; historical copies cannot authorize dose transfer. It clears its pending send only for a receipt whose entire request matches and whose phase is accepted/rejected/reconciled. Missing or uncertain receipts remain visible and never cause an automatic retry.

The append-only transaction ledger retains up to 5,000 operations and is excluded from backup. Corrupt, unavailable or full replay-protection storage holds new transactions instead of silently resetting IDs.

## Verification

`bash scripts/test-smart-meal-receiver.sh` runs the exact receiver, wire and batch sources in an isolated macOS package with temporary SQLite stores and stubbed treatment effects. The matching LoopFollow script `Scripts/test-smart-meal-integration.sh /path/to/Trio` encodes the actual sender payload, decodes it with Trio's real command decoder, exercises the receiver and returns a correlated receipt. No pump/remote transport is initialized by these scripts.

The full arm64 iOS Simulator app build succeeded under Xcode 26.1.1. The final native run passed **42 tests across five suites**: SmartMealReceiverTests, SmartMealCarbBatchTests, CarbsStorageTests, MealTotalTests, and BolusCalculatorTests. This includes the actual production storage adapter, optional FPU behavior, future-carb exclusion, concurrency, replay/restart, forced rollback and calculator regressions. Narrow method filters in an earlier run skipped the adapter/meal tests; only the final whole-suite run is counted for those cases. Existing dependency/build warnings remain. No live insulin, treatments or pump-setting changes were used.

For native simulator tests, use scheme **Trio Tests** and those five suites, with ad-hoc signing (`CODE_SIGN_IDENTITY=-`, manual style, empty team/profile) so the test host has its App Group entitlement. Keep DerivedData outside the checkout because the formatter scans source. Preserve pinned submodules and Package.resolved.

## Deployment

This source must be installed as an in-place update on the phone actually running Trio; updating the caregiver's LoopFollow alone cannot add this receiver. Preserve the original bundle ID, signing team and App Group, back up controller data, and retain the existing signed build. The signed development iPhone build 1.0.2 (15), from source 5544c7d, also succeeded and passed strict signature, original bundle identity, App Group and development push-entitlement verification. The prepared profile covers six registered devices. No controller installation or physical-device treatment workflow has been verified.

Keep the existing distribution channel where possible. Switching from TestFlight/production push to a locally signed development build changes the APNs environment and can change the device token. Trio already uploads token/environment changes in its Nightscout profile, and LoopFollow's existing profile importer updates those connection fields. Verify the refreshed token/environment after installation; re-import only if that automatic refresh fails. Do not assume an old production token reaches a development build. Nightscout configuration does not need to be recreated.

## Remote TestFlight release

The feature branch has a manual `4. Build Trio` workflow with an explicit `publish` input, defaulting to false. It builds the requested commit, reuses existing signing assets with read-only Match, and verifies the exported IPA before an approved upload to the existing TestFlight application. It does not sync upstream, recreate/revoke certificates, invite new testers, or alter pump settings. The main branch workflow is unchanged. Signing credentials are supplied only to the existing Fastlane build/upload steps. Artifacts exclude raw logs, private keys and provisioning profiles.

The upload gate checks the original app identity/team/App Group, 1.0.2 version, embedded source commit, strict signature, production push entitlement and App Store profile. A development build was used as a negative check and correctly rejected. Local signed build 15 is a development build for a connected controller phone; it is not the distribution IPA.

TestFlight availability and actual installation must be checked separately after upload. The updated receiver supplies live calculator settings and typed transaction receipts; the caregiver phone cannot enable these capabilities in an older controller app.
