// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Ton der AirPlay-Bildschirmsynchronisierung: AAC-ELD, 44.1 kHz, stereo, 480 Frames je Paket.
/// Wird ohne Puffer abgespielt; staut sich etwas, werden Pakete verworfen (Latenz vor Lückenlosigkeit).
final class AirPlayAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mirroract.airplay.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inputFormat: AVAudioFormat
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var converter: AVAudioConverter?
    private var started = false
    private var queued = 0
    private var gain: Float = 1
    private var isMuted = false

    /// höchstens so viele Pakete (à ~11 ms) in der Warteschlange
    private let maxQueued = 12

    static let sampleRate: Double = 44100
    private let tapLock = NSLock()
    private var tap: ((CMSampleBuffer) -> Void)?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// bekommt jeden dekodierten Block mit Host-Zeit (für Aufnahmen), auch wenn stumm
    var recordTap: ((CMSampleBuffer) -> Void)? {
        get { tapLock.lock(); defer { tapLock.unlock() }; return tap }
        set { tapLock.lock(); tap = newValue; tapLock.unlock() }
    }

    init() {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        inputFormat = AVAudioFormat(streamDescription: &description)!
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
        queue.async { self.decodeAndPlay(data) }
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
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
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.magicCookie = Data([0xF8, 0xE8, 0x50, 0x00])   // AudioSpecificConfig ELD 44.1k/2ch/480
        }
        guard let converter else { return }
        if queued > maxQueued { return }

        let packet = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
        data.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        packet.byteLength = UInt32(data.count)
        packet.packetCount = 1
        packet.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 960) else { return }
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
