#!/usr/bin/env python3
"""Compile production AR capture/math on macOS; encode a real MP4 and exercise HTTP.
No ARKit accuracy, device relocalization, or live backend claims are made here.
Run: python3 MyApp/AR/Tests/verify_capture.py
"""
import email.policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import tempfile
import threading

SOURCE = Path(__file__).resolve().parents[1] / 'PlayerTracking.swift'
SWIFT = r'''
import Foundation
import AVFoundation
import CoreImage
import simd

enum TrackingQuality: Equatable {
    case normal, notAvailable, relocalizing
    var isReliable: Bool { self == .normal }
}
final class TrackingStub: PlayerTracking {
    var pose: TrackedPose?
    var quality: TrackingQuality = .normal
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "FAILED: " + name); count += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("FAILED: " + name) } catch { count += 1 }
        }
        let tracking = TrackingStub()
        check(tracking.reliablePosition(at: 100) == nil, "missing pose")
        tracking.pose = TrackedPose(position: SIMD3(1, 2, 3), quality: .normal, timestamp: 100)
        check(tracking.reliablePosition(at: 100.5) != nil, "freshness boundary")
        check(tracking.reliablePosition(at: 100.501) == nil, "stale pose")
        check(tracking.reliablePosition(at: 99) == nil, "future pose")
        tracking.quality = .notAvailable
        check(tracking.reliablePosition(at: 100) == nil, "quality downgrade invalidates recent pose")
        tracking.quality = .normal
        tracking.pose?.position.x = .nan
        check(tracking.reliablePosition(at: 100) == nil, "invalid position")

        let playable = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)]
        let grid = try ServerGridTracking(cols: 2, rows: 2, tileSize: 1, originX: -2, originZ: -3, playable: playable)
        check(grid.tile(at: SIMD3(-1.9, 99, -2.9)) == SIMD2(0, 0), "world x/z with negative origin")
        check(grid.tile(at: SIMD3(-1, 99, -3)) == SIMD2(1, 0), "exact tile boundary")
        check(grid.tile(at: SIMD3(-2.01, 0, -3)) == nil, "floor not truncation")
        check(grid.tile(at: SIMD3(-1.9, 0, -1.9)) == nil, "nonplayable tile rejected")
        check(grid.tile(at: SIMD3(0, 0, -2)) == nil, "upper grid bound")
        check(grid.tile(at: SIMD3(.infinity, 0, 0)) == nil, "nonfinite tile rejected")
        check(grid.worldCenter(x: 1, y: 1, elevation: 0) == SIMD3(-0.5, 0, -1.5), "station center")
        check(grid.worldCenter(x: 0, y: 1, elevation: 0) == nil, "no icon outside playable area")
        rejects("invalid tile size") { _ = try ServerGridTracking(cols: 2, rows: 2, tileSize: 2, originX: 0, originZ: 0, playable: []) }
        rejects("invalid playable tile") { _ = try ServerGridTracking(cols: 2, rows: 2, tileSize: 1, originX: 0, originZ: 0, playable: [SIMD2(2, 0)]) }
        rejects("invalid grid origin") { _ = try ServerGridTracking(cols: 2, rows: 2, tileSize: 1, originX: .nan, originZ: 0, playable: []) }

        var intrinsics = matrix_identity_float3x3
        intrinsics[0, 0] = 1000; intrinsics[1, 1] = 1000
        intrinsics[2, 0] = 960; intrinsics[2, 1] = 720
        let geometry = try CaptureVideoGeometry(sourceWidth: 1920, sourceHeight: 1440, matrix: intrinsics)
        check(abs(geometry.intrinsics.fx - 2000.0 / 3) < 0.001, "focal length scaled")
        check(geometry.intrinsics.cx == 640 && geometry.intrinsics.cy == 360, "principal point center-cropped")
        check(geometry.offsetY == -120, "4:3 to 16:9 crop")
        rejects("invalid camera dimensions") { _ = try CaptureVideoGeometry(sourceWidth: 0, sourceHeight: 1, matrix: intrinsics) }
        var invalid = intrinsics; invalid[0, 0] = .nan
        rejects("invalid calibration") { _ = try CaptureVideoGeometry(sourceWidth: 1920, sourceHeight: 1440, matrix: invalid) }

        var source: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &source)
        check(status == kCVReturnSuccess && source != nil, "source buffer")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1440))
        CIContext().render(image, to: source!)
        let recorder = try CaptureRecorder(sourceWidth: 1920, sourceHeight: 1440, intrinsics: intrinsics)
        for frame in 0..<90 {
            var transform = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
            transform.columns.3 = SIMD4(Float(frame) / 30, 1.5, -2, 1)
            try recorder.append(pixelBuffer: source!, timestamp: 100 + Double(frame) / 30, transform: transform)
            try await Task.sleep(for: .milliseconds(8))
        }
        let artifact = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let posesData = try Data(contentsOf: artifact.posesURL)
        let poses = try JSONDecoder().decode([CapturePose].self, from: posesData)
        check(poses.count >= 20, "pose log contains samples")
        check(abs(Double(poses.count) / artifact.duration - 10) < 2, "about 10 Hz pose log")
        check(poses.first?.t == 0, "video-relative time begins at zero")
        check(zip(poses, poses.dropFirst()).allSatisfy { $0.t < $1.t }, "monotonic pose times")
        check(poses.allSatisfy { abs($0.qy - sqrt(0.5)) < 0.001 && abs($0.qw - sqrt(0.5)) < 0.001 }, "quaternion from camera transform")
        check(poses.allSatisfy { abs(($0.x - poses[0].x) - $0.t) < 0.001 }, "pose timeline matches captured trajectory")
        let json = try JSONSerialization.jsonObject(with: posesData) as! [[String: Any]]
        check(Set(json[0].keys) == Set(["t", "x", "y", "z", "qx", "qy", "qz", "qw"]), "exact documented pose schema")
        let calibration = try JSONDecoder().decode(CaptureIntrinsics.self, from: Data(contentsOf: artifact.intrinsicsURL))
        check(calibration == geometry.intrinsics, "matching exported calibration")
        let asset = AVURLAsset(url: artifact.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        check(tracks.count == 1, "one video track")
        let naturalSize = try await tracks[0].load(.naturalSize)
        check(naturalSize == CGSize(width: 1280, height: 720), "actual MP4 is 720p")
        let matrix = try await tracks[0].load(.preferredTransform)
        check(matrix == .identity, "video orientation matches exported intrinsics")
        let duration = try await asset.load(.duration).seconds
        check(duration >= poses.last!.t && duration <= artifact.duration + 0.2, "poses within encoded timeline")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        check(audio.isEmpty, "no microphone recording")
        let decoded = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        check(decoded.image.width == 1280 && decoded.image.height == 720, "video actually decodes")
        let average = CIImage(cgImage: decoded.image).applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: 1280, height: 720))])
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        check(Int(rgba[2]) > Int(rgba[0]) + 50, "encoded frames contain camera image rather than black video")
        let cancelled = try CaptureRecorder(sourceWidth: 1920, sourceHeight: 1440, intrinsics: intrinsics)
        cancelled.cancel()
        do { _ = try await cancelled.finish(); preconditionFailure("Cancelled recorder finished") }
        catch { count += 1 }
        try? FileManager.default.removeItem(at: cancelled.directory)

        let url = URL(string: CommandLine.arguments[1])!
        let transport = ARCaptureTransport(baseURL: url, room: "ABCD")
        let endpoint = try transport.endpoint(["scan", "ABCD", "overview"])
        check(endpoint.path == "/scan/ABCD/overview", "endpoint path")
        for room in ["A", "ABCDE", "../x", "12AB", "abcd"] {
            rejects("invalid room " + room) { _ = try ARCaptureTransport(baseURL: url, room: room).endpoint(["map", room]) }
        }
        rejects("invalid scheme") { _ = try ARCaptureTransport(baseURL: URL(string: "file:///tmp")!, room: "ABCD").endpoint([]) }
        rejects("URL credentials") { _ = try ARCaptureTransport(baseURL: URL(string: "http://user:pass@localhost")!, room: "ABCD").endpoint([]) }
        let badResponse = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        rejects("HTTP failure") { try ARCaptureTransport.validate(badResponse, data: Data("host only".utf8)) }
        let mapFile = artifact.directory.appendingPathComponent("map.bin")
        let mapData = Data("synthetic-map-transport-test".utf8)
        try mapData.write(to: mapFile)
        try await transport.upload(artifact, pass: .overview)
        try await transport.upload(artifact, pass: .edge)
        try await transport.uploadMap(mapFile)
        let downloaded = try await transport.downloadMap()
        check(downloaded == mapData, "binary map round-trip transport")
        try await transport.process()
        do {
            _ = try await ARCaptureTransport(baseURL: url, room: "FAIL").downloadMap()
            preconditionFailure("HTTP 404 accepted")
        } catch { count += 1 }
        print("Passed \(count) checks including real 720p MP4 encoding and HTTP contract tests.")
    }
}
'''

class Handler(BaseHTTPRequestHandler):
    requests = []
    map_bytes = b''
    errors = []

    def log_message(self, *_):
        pass

    def respond(self, status, data=b'{}'):
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        try:
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if self.path in ('/scan/ABCD/overview', '/scan/ABCD/edge'):
                headers = ('Content-Type: ' + self.headers['Content-Type'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode()
                parts = list(BytesParser(policy=email.policy.default).parsebytes(headers + data).iter_parts())
                fields = {p.get_param('name', header='content-disposition'): p for p in parts}
                assert set(fields) == {'video', 'poses', 'intrinsics'}
                assert fields['video'].get_content_type() == 'video/mp4'
                assert fields['video'].get_filename() == 'video.mp4'
                assert b'ftyp' in fields['video'].get_payload(decode=True)[:32]
                poses = json.loads(fields['poses'].get_payload(decode=True))
                calibration = json.loads(fields['intrinsics'].get_payload(decode=True))
                assert set(poses[0]) == {'t', 'x', 'y', 'z', 'qx', 'qy', 'qz', 'qw'}
                assert set(calibration) == {'fx', 'fy', 'cx', 'cy', 'width', 'height'}
                assert calibration['width'] == 1280 and calibration['height'] == 720
            elif self.path == '/map/ABCD':
                assert self.headers['Content-Type'] == 'application/octet-stream'
                type(self).map_bytes = data
            elif self.path == '/scan/ABCD/process':
                assert type(self).requests == ['/scan/ABCD/overview', '/scan/ABCD/edge', '/map/ABCD', '/map/ABCD:GET']
            else:
                raise AssertionError('Unexpected request: ' + self.path)
            type(self).requests.append(self.path)
            self.respond(200)
        except Exception as error:
            type(self).errors.append(repr(error))
            self.respond(400, str(error).encode())

    def do_GET(self):
        if self.path == '/map/ABCD':
            type(self).requests.append(self.path + ':GET')
            self.respond(200, type(self).map_bytes)
        else:
            self.respond(404)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='arkit-checks-') as directory:
            directory = Path(directory)
            harness = directory / 'Checks.swift'
            harness.write_text(SWIFT)
            binary = directory / 'checks'
            subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos27.0',
                            str(SOURCE), str(harness), '-o', str(binary)], check=True)
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'], check=True)
            assert not Handler.errors, Handler.errors
            assert Handler.requests[-1] == '/scan/ABCD/process', Handler.requests
            print('Multipart fields, binary map transfer, and processing request verified against a local test server.')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
