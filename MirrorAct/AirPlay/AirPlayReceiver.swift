// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

private func receiver(_ ctx: UnsafeMutableRawPointer?) -> AirPlayReceiver {
    Unmanaged<AirPlayReceiver>.fromOpaque(ctx!).takeUnretainedValue()
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// Kabelloser Empfang: AirPlay-Bildschirmsynchronisierung über die UxPlay-Bibliothek,
/// Dekodierung mit VideoToolbox, Ton mit AVAudioEngine.
final class AirPlayReceiver: @unchecked Sendable {
    struct Client: Equatable {
        let deviceID: String
        let model: String
        let name: String
    }

    struct Config {
        var name: String
        var deviceID: String
        var keyfile: String
        var streamHeight: Int
        var maxFPS: Int
        var hevc: Bool
        var peerToPeer: Bool
        var pin: Int32
    }

    // Alle Callbacks kommen auf dem Main-Thread
    var onClient: ((Client) -> Void)?
    var onConnectionLost: (() -> Void)?
    var onConnectionCount: ((Int) -> Void)?
    var onPin: ((String) -> Void)?
    var onSourceSize: ((CGSize) -> Void)?

    private(set) var isRunning = false
    let audio = AirPlayAudioPlayer()

    private let decodeQueue = DispatchQueue(label: "mirroract.airplay.decode", qos: .userInteractive)
    private let decoder = AnnexBDecoder()
    private let lock = NSLock()
    private var currentSink: FrameSink?

    init() {
        decoder.onFrame = { [weak self] buffer in self?.sink?.push(buffer) }
        decoder.onError = { message in Log.error("AirPlay-Video: \(message)") }
    }

    /// Ziel für dekodierte Bilder (das Spiegelfenster)
    var sink: FrameSink? {
        get { lock.lock(); defer { lock.unlock() }; return currentSink }
        set { lock.lock(); currentSink = newValue; lock.unlock() }
    }

    @discardableResult
    func start(_ config: Config) -> Int32 {
        stop()
        var callbacks = mb_airplay_callbacks()
        callbacks.ctx = Unmanaged.passUnretained(self).toOpaque()
        callbacks.video = { ctx, data, length, isHEVC in
            guard let data, length > 0 else { return }
            receiver(ctx).handleVideo(Data(bytes: data, count: Int(length)), hevc: isHEVC)
        }
        callbacks.audio = { ctx, data, length, type in
            guard let data, length > 0 else { return }
            receiver(ctx).audio.handle(Data(bytes: data, count: Int(length)), compressionType: type)
        }
        callbacks.client = { ctx, deviceID, model, name in
            let client = Client(deviceID: string(deviceID), model: string(model), name: string(name))
            let r = receiver(ctx)
            r.decodeQueue.async { r.decoder.reset() }
            DispatchQueue.main.async { r.onClient?(client) }
        }
        callbacks.connections = { ctx, count in
            let r = receiver(ctx)
            DispatchQueue.main.async { r.onConnectionCount?(Int(count)) }
        }
        callbacks.video_size = { ctx, sourceWidth, sourceHeight, _, _ in
            let r = receiver(ctx)
            let size = CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight))
            DispatchQueue.main.async { r.onSourceSize?(size) }
        }
        callbacks.video_reset = { ctx in
            let r = receiver(ctx)
            r.decodeQueue.async { r.decoder.reset() }
        }
        callbacks.connection_lost = { ctx in
            let r = receiver(ctx)
            r.decodeQueue.async { r.decoder.reset() }
            r.audio.stop()
            DispatchQueue.main.async { r.onConnectionLost?() }
        }
        callbacks.pin = { ctx, pin in
            let r = receiver(ctx)
            let value = string(pin)
            DispatchQueue.main.async { r.onPin?(value) }
        }
        callbacks.volume = { ctx, volume in
            receiver(ctx).audio.setAirPlayVolume(volume)
        }
        callbacks.log = { _, level, message in
            let text = string(message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if level <= 3 { Log.error("AirPlay: \(text)") } else { Log.info("AirPlay: \(text)") }
        }

        let height = UInt16(clamping: config.streamHeight)
        let width = UInt16(clamping: config.streamHeight * 16 / 9)
        let result: Int32 = config.name.withCString { name in
            config.deviceID.withCString { deviceID in
                config.keyfile.withCString { keyfile in
                    var c = mb_airplay_config()
                    c.name = name
                    c.device_id = deviceID
                    c.keyfile = keyfile
                    c.width = width
                    c.height = height
                    c.refresh_rate = 60
                    c.max_fps = UInt16(clamping: config.maxFPS)
                    c.h265 = config.hevc
                    c.peer_to_peer = config.peerToPeer
                    c.pin = config.peerToPeer ? config.pin : 0
                    c.log_level = 6
                    return mb_airplay_start(&c, &callbacks)
                }
            }
        }
        isRunning = result == 0
        if isRunning {
            Log.info("AirPlay receiver started: “\(config.name)”, \(height)p, \(config.maxFPS) fps, HEVC \(config.hevc), AWDL \(config.peerToPeer)")
        } else {
            Log.error("AirPlay receiver could not start (\(result))")
        }
        return result
    }

    func stop() {
        guard isRunning else { return }
        mb_airplay_stop()
        isRunning = false
        audio.stop()
        decodeQueue.sync { decoder.reset() }
    }

    func disconnect() {
        mb_airplay_disconnect()
    }

    private func handleVideo(_ data: Data, hevc: Bool) {
        decodeQueue.async { [decoder] in
            data.withUnsafeBytes { raw in
                decoder.decode(raw.bindMemory(to: UInt8.self), hevc: hevc)
            }
        }
    }
}
