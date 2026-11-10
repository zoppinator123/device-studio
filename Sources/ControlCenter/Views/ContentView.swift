import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, camera, mouse, dictation, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .camera: return "Camera"
        case .mouse: return "Mouse"
        case .dictation: return "Dictation"
        case .setup: return "Setup Guide"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .camera: return "web.camera"
        case .mouse: return "computermouse"
        case .dictation: return "mic"
        case .setup: return "checklist"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(page: $model.selectedPage, mouse: model.mouse)
        } detail: {
            switch model.selectedPage {
            case .overview: OverviewPage(mouse: model.mouse, camera: model.camera)
            case .camera: CameraPage(camera: model.camera)
            case .mouse: MousePage(mouse: model.mouse)
            case .dictation: DictationPage(mouse: model.mouse)
            case .setup: SetupWizard(mouse: model.mouse, camera: model.camera)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .alert("Settings Need Attention", isPresented: errorIsPresented) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
}

private struct Sidebar: View {
    @Binding var page: Page
    @ObservedObject var mouse: MouseController

    private static let devicePages: [Page] = [.overview, .camera, .mouse, .dictation]

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(Self.devicePages) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(item == .overview && !mouse.trusted ? 1 : 0)
                        .tag(item)
                }
            }
            Section("Help") {
                Label(Page.setup.title, systemImage: Page.setup.symbol)
                    .tag(Page.setup)
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }

    // The sidebar always keeps one page selected.
    private var selection: Binding<Page?> {
        Binding(get: { page }, set: { if let new = $0 { page = new } })
    }
}
