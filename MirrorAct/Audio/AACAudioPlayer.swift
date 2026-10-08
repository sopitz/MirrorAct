// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Spielt AAC-Pakete ohne Puffer ab: AirPlay (AAC-ELD, 44.1 kHz, 480 Frames je Paket) und Android
/// (AAC-LC, 48 kHz, 1024 Frames). Staut sich etwas, werden Pakete verworfen (Latenz vor Lückenlosigkeit).
final class AACAudioPlayer: @unchecked Sendable {
    struct Format {
        var formatID: AudioFormatID
        var sampleRate: Double
        var framesPerPacket: UInt32
        /// AudioSpecificConfig; bei Android kommt sie erst mit dem ersten Paket (setCookie)
        var cookie: Data?

        static let airPlay = Format(formatID: kAudioFormatMPEG4AAC_ELD, sampleRate: 44100, framesPerPacket: 480,
                                    cookie: Data([0xF8, 0xE8, 0x50, 0x00]))   // ELD 44.1k/2ch/480
        static let android = Format(formatID: kAudioFormatMPEG4AAC, sampleRate: 48000, framesPerPacket: 1024)
    }

    private let queue = DispatchQueue(label: "mirroract.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: Format
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var cookie: Data?
    private var converter: AVAudioConverter?
    private var started = false
    private var queued = 0
    private var gain: Float = 1
    private var isMuted = false

    /// höchstens so viele Pakete in der Warteschlange (etwa 140 ms)
    private let maxQueued: Int

    let sampleRate: Double
    private let tapLock = NSLock()
    private var tap: ((CMSampleBuffer) -> Void)?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// bekommt jeden dekodierten Block mit Host-Zeit (für Aufnahmen), auch wenn stumm
    var recordTap: ((CMSampleBuffer) -> Void)? {
        get { tapLock.lock(); defer { tapLock.unlock() }; return tap }
        set { tapLock.lock(); tap = newValue; tapLock.unlock() }
    }

    init(format: Format = .airPlay) {
        self.format = format
        sampleRate = format.sampleRate
        cookie = format.cookie
        maxQueued = max(4, Int(0.14 * format.sampleRate / Double(format.framesPerPacket)))
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: format.formatID, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: format.framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
            mReserved: 0)
        inputFormat = AVAudioFormat(streamDescription: &description)!
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    }

    var muted: Bool {
        get { queue.sync { isMuted } }
        set { queue.async { self.isMuted = newValue; self.applyVolume() } }
    }

    /// AirPlay-Lautstärke in dB (−30 … 0, −144 = stumm)
    func setAirPlayVolume(_ db: Float) {
        queue.async {
            self.gain = db <= -144 ? 0 : max(0, min(1, (db + 30) / 30))
            self.applyVolume()
        }
    }

    func handle(_ data: Data, compressionType: UInt8) {
        guard compressionType == 8 else { return }   // nur AAC-ELD (Spiegelung)
        play(data)
    }

    /// ein AAC-Paket (ohne ADTS-Kopf)
    func play(_ data: Data) {
        queue.async { self.decodeAndPlay(data) }
    }

    /// AudioSpecificConfig des Stroms (Android: erstes Paket)
    func setCookie(_ data: Data) {
        queue.async {
            self.cookie = data
            self.converter = nil
        }
    }

    func stop() {
        queue.async {
            guard self.started else { return }
            self.player.stop()
            self.engine.stop()
            self.started = false
            self.queued = 0
            self.converter = nil
        }
    }

    private func sampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        if audioFormatDescription == nil {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription,
                                           layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &audioFormatDescription)
        }
        guard let description = audioFormatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                                   sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sample
    }

    private func applyVolume() {
        player.volume = isMuted ? 0 : gain
    }

    private func decodeAndPlay(_ data: Data) {
        if converter == nil {
            guard let cookie else { return }
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.magicCookie = cookie
        }
        guard let converter else { return }
        if queued > maxQueued { return }

        let packet = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
        data.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        packet.byteLength = UInt32(data.count)
        packet.packetCount = 1
        packet.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: format.framesPerPacket * 2) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return packet
        }
        guard status != .error, pcm.frameLength > 0 else { return }
        if let tap = recordTap, let sample = sampleBuffer(from: pcm) { tap(sample) }

        if !started {
            do {
                try engine.start()
                started = true
                applyVolume()
            } catch {
                Log.error("Audio-Engine: \(error.localizedDescription)")
                return
            }
        }
        queued += 1
        player.scheduleBuffer(pcm) { [weak self] in
            self?.queue.async { self?.queued -= 1 }
        }
        if !player.isPlaying { player.play() }
    }
}
