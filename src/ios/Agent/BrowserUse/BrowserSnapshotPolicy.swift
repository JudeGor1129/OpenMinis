import Foundation

/// [T-browser-snapshot-stride] Align the raster, never the CSS viewport.
/// 32 pixels gives a packed RGBA row a 128-byte multiple. Round UP only:
/// no detail is discarded. Runtime WebKit validation is still required.
enum BrowserSnapshotPolicy {
    struct Plan: Equatable {
        let snapshotWidth: Double
        let widthRatio: Double
        let pixelWidth: Int
    }
    static func plan(width: Double, scale: Double) -> Plan? {
        guard width.isFinite, scale.isFinite, width > 0, scale > 0 else { return nil }
        let pixels = (width * scale / 32).rounded(.up) * 32
        guard pixels.isFinite, pixels > 0, pixels < Double(Int.max) else { return nil }
        let captureWidth = pixels / scale
        return Plan(snapshotWidth: captureWidth, widthRatio: captureWidth / width,
                    pixelWidth: Int(pixels))
    }
}
