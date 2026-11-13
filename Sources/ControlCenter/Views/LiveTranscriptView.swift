import CaptureKit
import SwiftUI

/// The transcript as it is spoken: "Me" for your microphone, "Others" for the call. New lines appear a
/// moment after each pause, and the view follows the newest line.
struct LiveTranscriptView: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if recorder.isRecording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Live transcript").font(.headline)
                    Text(MeetingRecorder.duration(Int(recorder.elapsed))).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(recorder.liveLines.isEmpty ? "Live transcript" : "Last meeting").font(.headline)
                }
                Spacer()
                if !recorder.liveLines.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TranscriptAssembler.render(recorder.liveLines), forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if recorder.liveLines.isEmpty {
                            Text(recorder.isRecording ? "Listening… text appears a moment after each pause." : "Start a recording to see its transcript here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(recorder.liveLines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(stamp(line.startMs)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(line.channel == .microphone ? "Me" : "Them")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(line.channel == .microphone ? Color.accentColor : Color.orange)
                                    .frame(width: 40, alignment: .leading)
                                Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: recorder.liveLines.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 300)
    }

    private func stamp(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
