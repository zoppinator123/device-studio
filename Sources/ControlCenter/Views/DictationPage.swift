import SwiftUI

/// Hold the MX Master thumb button to hold Granola's voice-typing key.
struct DictationPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var mouse: MouseController

    private var isOn: Bool { model.settings.granolaThumb.enabled }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.settings.granolaThumb.enabled) {
                    Text("Hold thumb button to dictate")
                    Text("Holds Granola’s voice-typing key for as long as the button is down.")
                }
                if isOn {
                    HStack(alignment: .firstTextBaseline) {
                        StatusLabel(text: statusText, level: statusLevel)
                        Spacer(minLength: 12)
                        Button("Reconnect", action: mouse.reconnectGranola)
                    }
                    if !mouse.trusted {
                        PermissionNotice(
                            message: "The \(mouse.controlPermissionName) permission is needed to hold the key for you.",
                            actionTitle: "Open Settings…",
                            action: mouse.requestAccessibility
                        )
                    }
                }
            }
            Section {
                Picker("Thumb button", selection: $model.settings.granolaThumb.controlID) {
                    ForEach(thumbControls, id: \.self) { Text(ThumbControl.name($0)).tag($0) }
                }
                Picker("Key to hold", selection: $model.settings.granolaThumb.modifier) {
                    ForEach(DictationModifier.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Setup")
            } footer: {
                SectionFooter("The key must match Granola → Settings → Voice typing → Hold to talk.")
            }
            Section {
                NumberedStep(1, "Click into the text field you want to dictate into.")
                NumberedStep(2, "Hold the thumb button and speak.")
                NumberedStep(3, "Release the button to finish.")
            } header: {
                Text("How to Use")
            } footer: {
                SectionFooter("The button goes back to its normal behavior when you turn this off or quit. If it doesn’t, switch the mouse off and on.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
    }

    /// The thumb controls this mouse reports, or every known one until a mouse has answered.
    private var thumbControls: [Int] {
        let reported = mouse.supportedThumbControls
        let selected = model.settings.granolaThumb.controlID
        guard !reported.isEmpty else { return ThumbControl.all }
        return reported.contains(selected) ? reported : reported + [selected]
    }

    private var statusText: String {
        mouse.granolaPressed ? "Holding the key. Release the button to stop." : mouse.granolaStatus
    }

    private var statusLevel: StatusLevel {
        mouse.granolaListening ? .good : .attention
    }
}
