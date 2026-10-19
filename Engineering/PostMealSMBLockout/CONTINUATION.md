# Integrated SMB work: current scope and limits

Continue the existing PR #3 integration, not a second carb-trigger implementation. This branch adds an enabled-by-default preference (missing fields migrate to ON; explicit OFF remains OFF), a revisioned authenticated `post_meal_smb` remote setting, and an optional controller-reported capability/state in the existing Smart Meal status. LoopFollow displays controller state and does not claim APNs submission is acknowledgement. Local setting changes also change the revision; stale/reordered remote commands cannot replace a newer choice. Remote setting changes carry no treatment fields. A reconciliation guard prevents an awaited history query from restoring an old intent after a setting change or new meal.

A further matcher regression fix normalizes the requested dose to the pump increment before recording intent and requires delivered and programmed units to match within numeric precision. A missing 0.05 U DASH pulse is rejected as partial delivery; the exact production-gate suite passes that added assertion.

The matching LoopFollow branch is `feature/post-meal-smb-control`, based on the existing scanner build 24 source. Existing FPU and scheduled second-carb processing remains intact. No Nightscout infrastructure changes are needed.

## Confirmed trigger behavior

The user clarified: block only once after the bolus; FPU and the scheduled second-carb entry must continue and must not restart the block. The existing meal-bolus-only trigger is retained. The user subsequently requested the second entry at **+35 minutes**. The matching LoopFollow development branch changes the Rice/default split delay to +35; the SMB duration remains 30 minutes. Explicitly customized positive delays remain editable and Pizza keeps its separate +60-minute preset. At exact expiry the gate permits normal SMB calculation, but carbs alone do not guarantee an SMB dose.

Timestamp limitation: Smart Meal's second row uses request.confirmedAt, while the verified gate uses pump dose start. +35 adds margin but is not a substitute for validating controller delivery latency and the inherited confirmation gap. No FPU entry restarts the block.

The user explicitly approved pushing both named development branches to the existing Trio and LoopFollow GitHub repositories. This does not authorize a merge or app distribution.

## Validation

- Standalone policy: 26 passing tests, including default ON and explicit OFF.
- Exact production matcher and gate definitions extracted from APSManager: 8 passing tests (`python3 scripts/test-post-meal-smb-runtime.py`). These do not exercise the asynchronous Core Data adapter.
- Actual sender encoder / Trio decoder / receiver integration: 4 passing tests, including toggle command, correlated status, exact replay and reordered-disable rejection. Run matching LoopFollow `Scripts/test-smart-meal-integration.sh /path/to/Trio`.
- The full unsigned Trio and LoopFollow arm64 simulator builds passed. The LoopFollow screen test passed for ON/OFF/unsupported controller states (one test with three launches). Native Trio settings tests and checks of the updated +35-minute sender schedule are being completed; consult the final handoff for their result. Device delivery integration remains unverified.

## Known unresolved delivery limitation

The inherited integration provisionally blocks for only 120 seconds after command acceptance. Its confirmed 30-minute gate requires an observed pump-status dose and a unique immutable pump-history match, and discards unmatched intent after 300 seconds. Long boluses/history lag can therefore leave a protection gap or no confirmed timer. Do not describe this as reliable continuous 30-minute blocking until the actual DASH path is verified and this gap is resolved. An API success callback is not proof of full delivery.

Settings and intent persistence use the app's existing storage; disk-failure acknowledgement, reboot behavior, concurrent calls, multiple meal boluses, interrupted delivery and pump replacement still require integrated validation. The remote state currently reports configuration, not a verified active countdown. Existing debug logs do not provide a complete suppressed-dose/total-basal audit. Historical replay cannot establish the glucose outcome of withheld insulin without a validated counterfactual model.

This is development source, not a distributed build or a claim that the father's phone is protected. No treatments, pump settings, installations or TestFlight uploads were performed in this continuation.
