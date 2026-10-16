import Foundation

// Type-check harness only; production language selection lives in MinisApp.
extension Bundle {
    var languageBundle: Bundle? { nil }
}

func checkLocalizationCallers(count: Int) {
    let _: String = AppLocalized("Restore")
    let _: String = AppLocalized("Found \(count) backups", comment: "Backup count")
    if #available(iOS 16.0, *) {
        let resource: LocalizedStringResource = "Restore"
        let _: String = AppLocalized(resource)
    }
}
