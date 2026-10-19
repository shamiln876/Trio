# Integrated SMB work: current scope and limits

Continue the existing PR #3 integration, not a second carb-trigger implementation. This branch adds an enabled-by-default preference (missing fields migrate to ON; explicit OFF remains OFF), a revisioned authenticated `post_meal_smb` remote setting, and an optional controller-reported capability/state in the existing Smart Meal status. LoopFollow displays controller state and does not claim APNs submission is acknowledgement. Local setting changes also change the revision; stale/reordered remote commands cannot replace a newer choice. Remote setting changes carry no treatment fields. A reconciliation guard prevents an awaited history query from restoring an old intent after a setting change or new meal.

A further matcher regression fix normalizes the requested dose to the pump increment before recording intent and requires delivered and programmed units to match within numeric precision. A missing 0.05 U DASH pulse is rejected as partial delivery; the exact production-gate suite passes that added assertion.

The matching LoopFollow branch is `feature/post-meal-smb-control`, based on the existing scanner build 24 source. Existing FPU and scheduled second-carb processing remains intact. No Nightscout infrastructure changes are needed.

## Confirmed trigger behavior

The user clarified: block only once after the bolus; FPU and the scheduled second-carb entry must continue and must not restart the block. The existing meal-bolus-only trigger is retained. The suggested timing is a 30-minute block with the second entry at +31 minutes, rather than reducing the block to 29 minutes. The current Rice preset is still +30 minutes: do not claim it has been moved. Before changing it, reconcile the timestamp mismatch: Smart Meal's second row uses request.confirmedAt, while the verified timer uses pump dose start. APNs latency can make a one-minute margin insufficient. Coordinate these anchors rather than promising the second row always falls after expiry. At the exact expiry, the gate's comparison permits normal SMB calculation; carbs alone never guarantee an SMB dose.

The user explicitly approved pushing both named development branches to the existing Trio and LoopFollow GitHub repositories. This does not authorize a merge or app distribution.

## Validation

- Standalone policy: 26 passing tests, including default ON and explicit OFF.
- Exact production matcher and gate definitions extracted from APSManager: 8 passing tests (`python3 scripts/test-post-meal-smb-runtime.py`). These do not exercise the asynchronous Core Data adapter.
- Actual sender encoder / Trio decoder / receiver integration: 4 passing tests, including toggle command, correlated status, exact replay and reordered-disable rejection. Run matching LoopFollow `Scripts/test-smart-meal-integration.sh /path/to/Trio`.
- Full Trio compilation, native settings tests, and device delivery integration remain separate requirements; consult the final handoff for the latest build results.

## Known unresolved delivery limitation

The inherited integration provisionally blocks for only 120 seconds after command acceptance. Its confirmed 30-minute gate requires an observed pump-status dose and a unique immutable pump-history match, and discards unmatched intent after 300 seconds. Long boluses/history lag can therefore leave a protection gap or no confirmed timer. Do not describe this as reliable continuous 30-minute blocking until the actual DASH path is verified and this gap is resolved. An API success callback is not proof of full delivery.

Settings and intent persistence use the app's existing storage; disk-failure acknowledgement, reboot behavior, concurrent calls, multiple meal boluses, interrupted delivery and pump replacement still require integrated validation. The remote state currently reports configuration, not a verified active countdown. Existing debug logs do not provide a complete suppressed-dose/total-basal audit. Historical replay cannot establish the glucose outcome of withheld insulin without a validated counterfactual model.

This is development source, not a distributed build or a claim that the father's phone is protected. No treatments, pump settings, installations or TestFlight uploads were performed in this continuation.
