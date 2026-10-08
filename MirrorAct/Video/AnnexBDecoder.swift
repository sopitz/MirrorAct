// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import VideoToolbox

/// Dekodiert H.264/HEVC im Annex-B-Format (wie es die AirPlay-Bibliothek liefert) mit
/// VideoToolbox. Gibt jedes Bild sofort aus: keine Umsortierung, kein Puffer
/// (GStreamers vtdec hielt hier bis zu 16 Bilder zurück).
final class AnnexBDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var isHEVC = false
    private var waitingForKeyframe = true

    func reset() {
        invalidateSession()
        parameterSets = []
        waitingForKeyframe = true
    }

    deinit { invalidateSession() }

    func decode(_ bytes: UnsafeBufferPointer<UInt8>, hevc: Bool) {
        if hevc != isHEVC {
            reset()
            isHEVC = hevc
        }

        var vps: Data?, sps: Data?, pps: Data?
        var slices: [UnsafeBufferPointer<UInt8>] = []
        var keyframe = false

        for nal in Self.nalUnits(in: bytes) where !nal.isEmpty {
            if hevc {
                let type = (nal[0] >> 1) & 0x3F
                switch type {
                case 32: vps = Data(nal)
                case 33: sps = Data(nal)
                case 34: pps = Data(nal)
                case 35, 39, 40: break                    // AUD, SEI
                case 16...21: keyframe = true; slices.append(nal)  // IRAP
                case 0...31: slices.append(nal)
                default: break
                }
            } else {
                let type = nal[0] & 0x1F
                switch type {
                case 7: sps = Data(nal)
                case 8: pps = Data(nal)
                case 5: keyframe = true; slices.append(nal)
                case 1...4: slices.append(nal)
                default: break                            // SEI, AUD, ...
                }
            }
        }

        if let sps, let pps {
            let sets = hevc ? [vps, sps, pps].compactMap { $0 } : [sps, pps]
            if (!hevc || vps != nil), sets != parameterSets {
                parameterSets = sets
                rebuildSession()
            }
        }

        guard let session, let formatDescription, !slices.isEmpty else { return }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }

        // Annex-B → AVCC (4 Byte Länge vor jeder NAL)
        let total = slices.reduce(0) { $0 + 4 + $1.count }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: total,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        var offset = 0
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { header in
                _ = CMBlockBufferReplaceDataBytes(with: header.baseAddress!, blockBuffer: blockBuffer,
                                                  offsetIntoDestination: offset, dataLength: 4)
            }
            CMBlockBufferReplaceDataBytes(with: nal.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: offset + 4, dataLength: nal.count)
            offset += 4 + nal.count
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = total
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [],
                                                       infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                self?.onFrame?(imageBuffer)
            }
        }
        if status == kVTInvalidSessionErr {
            // z. B. nach Ruhezustand: Session neu aufbauen und auf nächsten Keyframe warten
            rebuildSession()
        } else if status != noErr {
            onError?("Dekodierfehler \(status)")
            waitingForKeyframe = true
        }
    }

    private func rebuildSession() {
        invalidateSession()
        waitingForKeyframe = true
        guard let description = makeFormatDescription() else {
            onError?("Ungültige Parameter-Sets")
            return
        }
        formatDescription = description

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                                  decoderSpecification: decoderSpec as CFDictionary,
                                                  imageBufferAttributes: imageAttributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            onError?("VTDecompressionSessionCreate: \(status)")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private func makeFormatDescription() -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let sets = parameterSets
        let pointers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        let status: OSStatus = constPointers.withUnsafeBufferPointer { ptrs in
            sizes.withUnsafeBufferPointer { sz in
                if isHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: sz.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                } else {
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: sz.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// Zerlegt Annex-B in NAL-Einheiten (ohne Startcodes)
    static func nalUnits(in bytes: UnsafeBufferPointer<UInt8>) -> [UnsafeBufferPointer<UInt8>] {
        var units: [UnsafeBufferPointer<UInt8>] = []
        let n = bytes.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }   // 4-Byte-Startcode
                    units.append(UnsafeBufferPointer(rebasing: bytes[start..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n {
            units.append(UnsafeBufferPointer(rebasing: bytes[start..<n]))
        }
        return units
    }
}
