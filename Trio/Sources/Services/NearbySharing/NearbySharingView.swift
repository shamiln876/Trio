import SwiftUI
import CoreImage.CIFilterBuiltins

struct NearbySharingView: View {
    @ObservedObject var link: NearbyBluetooth
    var scan: (() -> Void)? = nil
    @State private var code = ""
    @State private var showCode = false
    @AppStorage("nearby.display.mmol") private var mmol = true

    var body: some View {
        Form {
            Section {
                Toggle("Nearby Bluetooth sharing", isOn: Binding(get: { link.enabled }, set: { link.setEnabled($0) }))
                Text(link.status).accessibilityIdentifier("nearby.status")
            } footer: {
                Text("Preview: verify updates with both phones locked before relying on this connection. Keep Bluetooth on and do not force-quit either app.")
            }
            if link.sender {
                Section("Pair with LoopFollow") {
                    if !link.pairingCode.isEmpty {
                        Button(showCode ? "Hide private pairing code" : "Show private pairing code") { showCode.toggle() }
                        if showCode, let qr = qrImage {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 280).padding().background(Color.white)
                            Text(link.pairingCode).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text("On the other phone, open LoopFollow → Menu → Nearby Bluetooth and scan this code. Anyone with this code can read nearby shared values.")
                    } else { Text("Enable sharing to create a private pairing code.") }
                }
            } else {
                Section("Pair with Trio") {
                    if let scan { Button("Scan Trio pairing code", action: scan) }
                    TextField("Or paste private pairing code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Pair") { link.pair(code); code = "" }.disabled(code.isEmpty)
                }
            }
            Section("Values from Trio over Bluetooth") {
                Toggle("Display mmol/L", isOn: $mmol)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    if let value = link.packet {
                        let now = context.date.timeIntervalSince1970
                        let age = max(0, now - value.glucoseDate)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(age > 360 ? "STALE GLUCOSE — check Trio" : "Glucose reading")
                                .font(.headline).foregroundStyle(age > 360 ? Color.orange : Color.secondary)
                            Text(mmol ? String(format: "%.1f mmol/L", Double(value.glucoseMgdl) / 18.0) : "\(value.glucoseMgdl) mg/dL")
                                .font(.largeTitle.bold())
                            Text("Read \(Int(age / 60)) min ago • \(Date(timeIntervalSince1970: value.glucoseDate).formatted(date: .omitted, time: .standard))")
                                .font(.caption)
                            if let delta = value.deltaMgdl {
                                Text(mmol ? String(format: "Change %+.1f mmol/L", Double(delta) / 18.0) : "Change \(delta > 0 ? "+" : "")\(delta) mg/dL")
                            }
                            Text(metric("IOB", value.iob, value.iobDate, now, "U"))
                            Text(metric("COB", value.cob, value.cobDate, now, "g"))
                            if now - value.generatedAt > 360 {
                                Text("NO RECENT TRANSFER").bold().foregroundStyle(Color.orange)
                            }
                        }.accessibilityIdentifier("nearby.values")
                    } else { Text("No Bluetooth values received yet") }
                }
            }
            Section {
                Text("These values are read-only and appear on this screen. Home, Live Activity, alarms and remote controls still use their existing internet data source.")
                if !link.pairingCode.isEmpty {
                    Button("Remove pairing", role: .destructive) { link.forget(); showCode = false }
                }
            }
        }
        .navigationTitle("Nearby Bluetooth")
    }

    private func metric(_ name: String, _ value: Double?, _ date: Double?, _ now: Double, _ unit: String) -> String {
        guard let value, let date else { return "\(name): unavailable" }
        let age = max(0, now - date)
        guard age <= 360 else { return "\(name): stale (\(Int(age / 60)) min old)" }
        return String(format: "%@: %.2f %@ (%d min ago)", name, value, unit, Int(age / 60))
    }

    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.pairingCode.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}
