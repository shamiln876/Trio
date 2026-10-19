# Integrated SMB work: current scope and limits

Continue the existing PR #3 integration, not a second carb-trigger implementation. This branch adds an enabled-by-default preference (missing fields migrate to ON; explicit OFF remains OFF), a revisioned authenticated `post_meal_smb` remote setting, and an optional controller-reported capability/state in the existing Smart Meal status. LoopFollow displays controller state and does not claim APNs submission is acknowledgement. Local setting changes also change the revision; stale/reordered remote commands cannot replace a newer choice. Remote setting changes carry no treatment fields. A reconciliation guard prevents an awaited history query from restoring an old intent after a setting change or new meal.

A further matcher regression fix normalizes the requested dose to the pump increment before recording intent and requires delivered and programmed units to match within numeric precision. A missing 0.05 U DASH pulse is rejected as partial delivery; the exact production-gate suite passes that added assertion.

The matching LoopFollow branch is `feature/post-meal-smb-control`, based on the existing scanner build 24 source. Existing FPU and scheduled second-carb processing remains intact. No Nightscout infrastructure changes are needed.

## Confirmed trigger behavior

The user clarified: block only once after the bolus; FPU and the scheduled second-carb entry must continue and must not restart the block. The existing meal-bolus-only trigger is retained. The user subsequently requested the second entry at **+35 minutes**. The matching LoopFollow development branch changes the Rice/default split delay to +35; the SMB duration remains 30 minutes. Explicitly customized positive delays remain editable and Pizza keeps its separate +60-minute preset. At exact expiry the gate permits normal SMB calculation, but carbs alone do not guarantee an SMB dose.

Timestamp limitation: Smart Meal's second row uses request.confirmedAt, while the verified gate uses pump dose start. +35 adds margin but is not a substitute for validating controller delivery latency and the controller initiation timestamp. No FPU entry restarts the block.

The user explicitly approved pushing both named development branches to the existing Trio and LoopFollow GitHub repositories. This does not authorize a merge or app distribution.

## Validation

- Standalone policy: 26 passing tests, including default ON and explicit OFF.
- Exact production matcher and gate definitions extracted from APSManager: 8 passing tests (`python3 scripts/test-post-meal-smb-runtime.py`). These do not exercise the asynchronous Core Data adapter.
- Actual sender encoder / Trio decoder / receiver integration: 4 passing tests, including toggle command, correlated status, exact replay and reordered-disable rejection. Run matching LoopFollow `Scripts/test-smart-meal-integration.sh /path/to/Trio`.
- The full unsigned Trio and LoopFollow arm64 simulator builds passed. The LoopFollow screen test passed for ON/OFF/unsupported controller states (one test with three launches). Final native Trio run: 14 settings/gate tests passed, zero failures/skips, after the initiation-anchor fix. The updated +35-minute sender suites passed: 50 calculation/delivery tests and 4 cross-app tests. The native +35 screen test is being retried separately; consult the final handoff. Device delivery integration remains unverified.

## Continuous wait and delivery semantics

The 120-second gap has been removed in this continuation. A successful callback from the explicit meal-bolus path records a separate persisted initiation timestamp; both SMB calculation and enactment honor the full 30-minute window from that timestamp. Discarding an unmatched history intent after 300 seconds no longer removes the timer. Final pump history remains separate evidence of delivered insulin and is never inferred from API acceptance. The 8 exact production-gate tests pass with a no-final-history case at 1799 seconds and expiry at 1800 seconds. A failed command does not set the initiation timestamp. Delayed carbs, FPU and correction-only boluses never set it.

Setting synchronization now compares revisions as well as the boolean, so OFF/ON transitions between loop checks clear prior anchors. A late meal callback must still match the setting revision from its initiation; it cannot revive a timer after OFF/ON. Physical DASH callback behavior, crash windows around pump acceptance/persistence and interrupted bolus handling still need device validation. The history matcher remains strict about complete delivered units for its audit result, but final history is no longer a prerequisite for the waiting period.

Settings and intent persistence use the app's existing storage; disk-failure acknowledgement, reboot behavior, concurrent calls, multiple meal boluses, interrupted delivery and pump replacement still require integrated validation. The remote state currently reports configuration, not a verified active countdown. Existing debug logs do not provide a complete suppressed-dose/total-basal audit. Historical replay cannot establish the glucose outcome of withheld insulin without a validated counterfactual model.

This is development source, not a distributed build or a claim that the father's phone is protected. No treatments, pump settings, installations or TestFlight uploads were performed in this continuation.
