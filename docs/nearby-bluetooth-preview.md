# Nearby Bluetooth read-only preview

Trio publishes encrypted local readings directly to LoopFollow using Core Bluetooth. No hotspot, router, Nightscout, Dexcom Share or internet is used for this link. Both apps must be updated. This is a preview pending physical two-iPhone validation.

## Setup

1. In Trio: Settings → Services → Nearby Bluetooth. Enable sharing and show the private QR code.
2. In LoopFollow: Menu → Nearby Bluetooth → Scan Trio pairing code. Allow Bluetooth and camera access.
3. Remain nearby and compare the displayed glucose, glucose timestamp, IOB and COB with Trio. IOB and COB retain their independent source timestamps.
4. View offline readings on the Nearby Bluetooth screen. Home, Live Activity, alarms and remote controls still use their existing data sources. This preview does not support remote treatment commands.

## Required two-phone acceptance test

Do not call offline/background delivery verified until this is recorded on physical devices:

- Disable Wi-Fi and cellular data on both phones; leave Bluetooth on.
- Pair in the foreground, receive at least two NEW glucose readings and confirm units/timestamps against Trio.
- Lock both phones for at least 15 minutes. Reopen LoopFollow and check whether new packets arrived during the locked interval using their generated/reading timestamps, rather than assuming a foreground reconnect proves background delivery.
- Repeat with one phone backgrounded, Bluetooth toggled off/on, and an out-of-range/return cycle.
- Confirm stale glucose is explicitly marked after six minutes and stale IOB/COB are withheld. Verify no remote command was sent and no dosing settings changed.
- Repeat in the actual room arrangement; walls can affect reception. There is no promised cabin-to-cabin range.
- Force-quit behavior is intentionally not represented as continuous operation; reopen the apps after force-quitting or restarting the phones.

## Implementation and scope

Private random service UUID; AES-GCM authenticated encryption; QR exchanges the 256-bit key once. Keys are stored in the device-only Keychain with after-first-unlock access. Never post the QR/code in logs, issues or screenshots. Removing the sender pairing revokes the old key.

The sender uses read/notify-only GATT characteristics, a one-byte change notice, ATT long reads capped at 512 bytes, per-reader snapshots and notification backpressure handling. The receiver scans for its exact service UUID, subscribes, authenticates frames, rejects unknown protocol versions and implausible/future/expired data, and discards older transfers. Bluetooth state restoration and reconnect are implemented. Physical background scheduling remains unverified.

Protocol checks cover encrypted roundtrip, original reading timestamp preservation, negative IOB, wrong key, tampering, expiry, clock skew, replay/order, oversize, invalid pairing and missing metric timestamps. Simulator compilation cannot test a real Bluetooth radio connection.
