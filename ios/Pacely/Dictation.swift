import SwiftUI
import Speech
import AVFoundation

/// Listens while you talk and turns it into text, using Apple's speech recognition on the iPhone itself where it can.
@MainActor
final class Listener: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var problem = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: Locale.current.identifier)) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))

    func start() async {
        problem = ""
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { problem = "Pacely needs permission to understand speech. You can turn it on in Settings › Pacely."; return }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { problem = "Pacely needs the microphone. You can turn it on in Settings › Pacely."; return }
        guard let rec = recogniser, rec.isAvailable else { problem = "Speech recognition isn't available right now."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            req.addsPunctuation = true
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
            listening = true
            task = rec.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let r = result { self.text = r.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            problem = "Couldn't start listening."
            stop()
        }
    }

    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct DictationView: View {
    var onDone: (String) -> Void
    @StateObject private var l = Listener()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text(l.listening ? "Listening…" : (l.text.isEmpty ? "Say it" : "Got it"))
                .font(Look.f(.title2).bold())
            ScrollView {
                Text(l.text.isEmpty ? "Talk naturally, for example “Pick up prescription tomorrow at 11”." : l.text)
                    .font(Look.f(.title3))
                    .foregroundStyle(l.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if !l.problem.isEmpty {
                Text(l.problem).font(Look.f(.callout)).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button(role: .cancel) { l.stop(); dismiss() } label: {
                    Text("Cancel").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {
                    l.stop()
                    onDone(l.text)
                    dismiss()
                } label: {
                    Label("Use this", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(l.text.isEmpty)
            }
            .controlSize(.large)
            if !l.listening && !l.text.isEmpty {
                Button("Try again") { l.text = ""; Task { await l.start() } }
            }
        }
        .padding(24)
        .task { await l.start() }
        .onDisappear { l.stop() }
        .sensoryFeedback(.start, trigger: l.listening)
    }
}
