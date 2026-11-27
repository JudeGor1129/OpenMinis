import SwiftUI

struct UserAskSettingsView: View {
    @State private var settings = UserAskSettings.load()
    var body: some View {
        Form {
            Section {
                Toggle(AppLocalized("User questions"), isOn: Binding(get: { settings.enabled }, set: { value in
                    settings.enabled = value
                    UserDefaults.standard.set(value, forKey: UserAskSettings.enabledKey)
                }))
                Picker(AppLocalized("Wait for answer"), selection: Binding(get: { settings.timeoutMinutes }, set: { value in
                    settings.timeoutMinutes = value
                    UserDefaults.standard.set(value, forKey: UserAskSettings.timeoutMinutesKey)
                })) {
                    ForEach(UserAskSettings.timeoutChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? AppLocalized("Until answered") : AppLocalized("\(minutes) minutes")).tag(minutes)
                    }
                }
            } header: { Text(AppLocalized("Assistant questions")) } footer: {
                Text(AppLocalized("When enabled, the assistant can ask structured questions or confirmations. Timeout never approves an action."))
            }
            Section {
                Toggle(AppLocalized("Background reminders"), isOn: Binding(get: { settings.notifyInBackground }, set: { value in
                    settings.notifyInBackground = value
                    UserDefaults.standard.set(value, forKey: UserAskSettings.notifyInBackgroundKey)
                }))
            } footer: {
                Text(AppLocalized("A neutral notification asks you to return to Minis. It never shows the question or allows approval from the lock screen."))
            }
        }
        .minisCatalogForm()
        .minisNavigationChrome()
        .navigationTitle(AppLocalized("User questions"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
