import SwiftUI

/// Record a meeting: your microphone and, for calls, what your Mac plays, as two separate channels.
struct MeetingsPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: MeetingRecorder
    @ViewState private var pendingDelete: MeetingRecord?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                if recorder.isRecording {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("Recording").font(.headline)
                        Text(MeetingRecorder.duration(Int(recorder.elapsed))).monospacedDigit().foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Stop Recording", role: .destructive, action: recorder.stop)
                            .keyboardShortcut(".", modifiers: .command)
                    }
                    LiveTranscriptView(recorder: recorder).frame(height: 300)
                    HStack {
                        Spacer()
                        Button("Open in Separate Window") { openWindow(id: "live-transcript") }.controlSize(.small)
                    }
                    if let path = recorder.systemAudioPath { DetailText("System audio: \(path)") }
                    if let echo = recorder.echoState { DetailText(echo) }
                } else {
                    Picker("Meeting type", selection: $model.settings.meetings.mode) {
                        ForEach(MeetingMode.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Spacer()
                        Button("Start Recording", action: model.toggleRecording)
                            .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(recorder.notices) { notice in
                    NoticeRow(notice: notice, recorder: recorder)
                }
            } header: {
                Text("Record")
            } footer: {
                SectionFooter("Map a mouse button to “Start or stop meeting recording” on the Mouse page to record without opening this window. The menu bar icon turns into a red dot while recording.")
            }

            Section {
                Toggle("Make notes when a meeting ends", isOn: $model.settings.meetings.autoNotes)
                Toggle("Keep audio as well as the transcript", isOn: $model.settings.meetings.keepAudio)
                    .disabled(recorder.isRecording)
                HStack(alignment: .firstTextBaseline) {
                    StatusLabel(text: engineProblem ?? "Ready: speech model checked before each use, network blocked while it runs.",
                                level: engineProblem == nil ? .good : .attention)
                    Spacer(minLength: 12)
                    Button("Choose Folder…", action: chooseEngineFolder)
                }
                Text(recorder.engine.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } header: {
                Text("Transcripts and Notes")
            } footer: {
                SectionFooter("Your words are transcribed live, on this Mac, as you speak; only the transcript is saved unless you choose to keep audio. Transcription (Parakeet) and notes (a local language model) run from a separate engine folder with network access blocked, and the transcript and notes are saved encrypted with the meeting’s key.")
            }

            MeetSpeakersSection(recorder: recorder)

            Section {
                Picker("Echo cancellation", selection: $model.settings.meetings.echo) {
                    ForEach(MeetingEchoMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(recorder.isRecording)
            } header: {
                Text("Microphone")
            } footer: {
                SectionFooter("With speakers instead of headphones, your microphone also hears the other people. Apple’s echo cancellation removes most of that, but it can change how your voice sounds. Off until you have tried it on a call.")
            }

            Section {
                if recorder.meetings.isEmpty {
                    Text("No recordings yet.").foregroundStyle(.secondary)
                }
                ForEach(recorder.meetings) { record in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(summary(record)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        StatusLabel(text: statusText(record), level: statusLevel(record))
                        if record.status == .transcribing || record.status == .makingNotes {
                            ProgressView().controlSize(.small)
                        }
                        if recorder.hasSealed(record, "notes") {
                            Button("Notes") { recorder.open(record, kind: "notes") }
                        }
                        if recorder.hasSealed(record, "transcript") {
                            Button("Transcript") { recorder.open(record, kind: "transcript") }
                        }
                        if [.recorded, .interrupted, .failed].contains(record.status) && engineProblem == nil {
                            Button(record.status == .failed ? "Try Again" : "Make Notes") { recorder.makeNotes(record) }
                        }
                        Button("Delete…") { pendingDelete = record }
                            .disabled([.recording, .transcribing, .makingNotes].contains(record.status))
                    }
                }
            } header: {
                Text("Recordings")
            } footer: {
                SectionFooter("Audio, transcripts and notes are encrypted on this Mac with a separate key per meeting, kept in your Keychain. Nothing is uploaded.")
            }

            Section {
                NumberedStep(1, "Recorded: your microphone, and for calls, the sound your Mac plays, such as the other people on a call.")
                NumberedStep(2, "Not recorded: video, your screen, or anything while the red dot is off.")
                NumberedStep(3, "Nothing is uploaded. Deleting a recording destroys its key, so the audio can’t be opened again.")
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Meetings")
        .sheet(isPresented: $recorder.showExplainer) { ExplainerSheet(recorder: recorder) }
        .sheet(item: $recorder.reading) { reading in ReaderSheet(reading: reading) }
        .alert("Still recording?", isPresented: $recorder.askWhetherToStop) {
            Button("Keep Recording", action: recorder.keepRecording)
            Button("Stop", role: .destructive, action: recorder.stop)
        } message: {
            Text("Nothing has been heard for 20 minutes. Recording stops on its own in 5 minutes.")
        }
        .confirmationDialog("Delete this recording?", isPresented: deleteIsPresented, presenting: pendingDelete) { record in
            Button("Delete Recording", role: .destructive) { recorder.delete(record) }
        } message: { _ in
            Text("Its key is destroyed first, so the audio can’t be recovered.")
        }
    }

    private var engineProblem: String? { recorder.engine.problem }

    private func chooseEngineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = recorder.engine.root
        panel.message = "Choose the folder that holds the transcription and notes engines."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.meetings.enginePath = url.path
        recorder.settings.enginePath = url.path
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func summary(_ r: MeetingRecord) -> String {
        var sources = r.sources.count == 2 ? "Microphone and system audio" : r.sources == ["mic"] ? "Microphone only" : "System audio only"
        if r.audioKept == false { sources += " · transcript only" }
        var text = "\(MeetingRecorder.duration(r.durationSeconds)) · \(sources)"
        if r.damagedSegments > 0 { text += " · \(r.damagedSegments) damaged segment\(r.damagedSegments == 1 ? "" : "s")" }
        return text
    }

    private func statusText(_ r: MeetingRecord) -> String {
        switch r.status {
        case .recording: return "Recording"
        case .recorded: return "Saved"
        case .interrupted: return "Interrupted, saved up to the stop"
        case .unreadable: return "Key missing"
        case .transcribing: return r.audioKept == false ? "Finishing transcript…" : "Transcribing…"
        case .makingNotes: return "Writing notes…"
        case .ready: return "Notes ready"
        case .failed: return r.problem ?? "Notes failed"
        }
    }

    private func statusLevel(_ r: MeetingRecord) -> StatusLevel {
        switch r.status {
        case .recording, .recorded, .ready, .transcribing, .makingNotes: return .good
        case .interrupted, .failed: return .attention
        case .unreadable: return .inactive
        }
    }
}

/// Names for the people on Google Meet calls, through the Device Studio Chrome extension.
private struct MeetSpeakersSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: MeetingRecorder
    @State private var installed = MeetBridge.isInstalled
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Name the people on Google Meet calls", isOn: $model.settings.meetings.meetSpeakers)
            if model.settings.meetings.meetSpeakers {
                HStack(alignment: .firstTextBaseline) {
                    StatusLabel(text: status, level: level)
                    Spacer(minLength: 12)
                    Button(installed ? "Show Extension Folder" : "Set Up Chrome…", action: setUp)
                }
                if !recorder.meetNames.isEmpty {
                    DetailText("On this call: " + recorder.meetNames.joined(separator: ", "))
                }
                if let problem { DetailText(problem) }
                if !installed || recorder.meetTabs == 0 {
                    NumberedStep(1, "Click Set Up Chrome. The extension folder opens in Finder.")
                    NumberedStep(2, "In Chrome, open chrome://extensions, turn on Developer mode, click Load unpacked and choose that folder.")
                    NumberedStep(3, "Join a Meet call and start recording. Meet’s captions turn on, and each line gets the speaker’s name.")
                }
            }
        } header: {
            Text("Google Meet")
        } footer: {
            SectionFooter("While you record, the Device Studio extension reads Meet’s captions in Chrome (only on meet.google.com) and passes the speaker names to this app on this Mac. Captions are used to label lines and are kept, encrypted, only with the meeting. Nothing joins the call and nothing is uploaded.")
        }
        .onAppear { installed = MeetBridge.isInstalled }
    }

    private var status: String {
        if !MeetBridge.chromeInstalled { return "Google Chrome isn’t set up on this Mac." }
        if !installed { return "Not set up yet." }
        if recorder.meetTabs > 0 { return "Connected to \(recorder.meetTabs) Google Meet tab\(recorder.meetTabs == 1 ? "" : "s")." }
        return "Ready. Open a Meet call in Chrome to connect."
    }

    private var level: StatusLevel {
        recorder.meetTabs > 0 ? .good : installed ? .inactive : .attention
    }

    private func setUp() {
        do {
            guard try MeetBridge.install() else {
                problem = "Open Google Chrome once, then try again."
                return
            }
            problem = nil
            installed = MeetBridge.isInstalled
            NSWorkspace.shared.activateFileViewerSelecting([MeetBridge.extensionFolder])
        } catch {
            problem = "Could not set up Chrome: \(error.localizedDescription)"
        }
    }
}

private struct DetailText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.subheadline).foregroundStyle(.secondary) }
}

private struct NoticeRow: View {
    @EnvironmentObject private var model: AppModel
    let notice: MeetingNotice
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.kind == .info ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.kind == .info ? Color.secondary : Color.orange)
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            switch notice.kind {
            case .openPrivacySettings:
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
            case .recordSystemOnly:
                Button("Record System Audio Only") { recorder.start(settings: model.settings.meetings, systemAudioOnly: true) }
            case .info, .warning:
                Button("Dismiss") { recorder.dismiss(notice) }
            }
        }
    }
}

/// Shown once, before the first recording and before any system permission prompt.
private struct ExplainerSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: MeetingRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording meetings").font(.title2.bold())
            Text("Device Studio records two separate channels while the red dot is showing:")
            NumberedStep(1, "Your microphone: you.")
            NumberedStep(2, "What your Mac plays: for a call, the other people.")
            Text("It does not record video or your screen, does not join calls as a bot, and never uploads audio. Each recording is encrypted on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS will now ask for the microphone, and the first time a call is recorded, for “System Audio Recording Only”. Make sure the people you record know you are recording.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") {
                    model.settings.meetings.explainerAccepted = true
                    dismiss()
                    model.toggleRecording()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// The recording indicator in the window toolbar. It cannot be hidden while recording.
struct RecordingBadge: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        if recorder.isRecording {
            Label {
                Text("Recording \(MeetingRecorder.duration(Int(recorder.elapsed)))").monospacedDigit()
            } icon: {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
            .labelStyle(.titleAndIcon)
            .help("A meeting is being recorded")
        }
    }
}

/// Shows decrypted notes or a transcript. The text exists only in memory while this is open.
private struct ReaderSheet: View {
    let reading: MeetingRecorder.Reading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reading.title).font(.title3.bold())
            ScrollView {
                Text(rendered).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reading.text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: reading.text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(reading.text)
    }
}
