// Alternative #2 - the "typical Swift app" approach: play silence through
// AVAudioEngine so the default output device never stops.
// Built only to measure it against the C agent; see README.md.
import AVFoundation

let engine = AVAudioEngine()
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
let source = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
    for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)

// AVAudioEngine stops itself when the output device changes; restart it.
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: engine, queue: .main) { _ in
    try? engine.start()
}

do {
    try engine.start()
} catch {
    FileHandle.standardError.write("engine start failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
RunLoop.main.run()
