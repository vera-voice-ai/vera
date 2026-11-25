import COnnx
import Foundation

/// onnxruntime for Vera's voice, through the C door in `COnnx`. Loaded once per process: on the Mac from the box's
/// `libonnxruntime.dylib` (the ears' build), on the phone from the framework it links.
public enum OnnxRuntime {
    nonisolated(unsafe) private static var ready = false
    private static let lock = NSLock()

    public static func load(dylib: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if ready { return }
        guard vera_onnx_load(dylib.path) == 0 else { throw SileroError.runtime(String(cString: vera_onnx_error())) }
        ready = true
    }

    /// `apiBase` is `OrtGetApiBase()` of the linked framework.
    public static func use(apiBase: UnsafeRawPointer) throws {
        lock.lock(); defer { lock.unlock() }
        if ready { return }
        guard vera_onnx_use(apiBase) == 0 else { throw SileroError.runtime(String(cString: vera_onnx_error())) }
        ready = true
    }

    public static var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
}

/// One loaded model. `run` may be called from any thread (onnxruntime sessions are thread-safe for Run).
final class OnnxModel: @unchecked Sendable {
    enum Input {
        case float(String, [Float], [Int64])
        case int64(String, [Int64], [Int64])
    }
    struct Output { let data: [Float]; let shape: [Int64] }

    private let session: UnsafeMutableRawPointer
    let name: String

    init(url: URL, threads: Int) throws {
        guard let s = vera_onnx_open(url.path, Int32(threads)) else {
            throw SileroError.model("\(url.lastPathComponent): \(String(cString: vera_onnx_error()))")
        }
        session = s; name = url.lastPathComponent
    }

    deinit { vera_onnx_close(session) }

    func run(_ inputs: [Input], outputs: [String]) throws -> [Output] {
        // Keep every buffer alive and pinned for the call.
        var names: [UnsafeMutablePointer<CChar>] = []
        var floats: [UnsafeMutableBufferPointer<Float>] = []
        var ints: [UnsafeMutableBufferPointer<Int64>] = []
        var shapes: [UnsafeMutableBufferPointer<Int64>] = []
        defer {
            names.forEach { free($0) }
            floats.forEach { $0.deallocate() }; ints.forEach { $0.deallocate() }; shapes.forEach { $0.deallocate() }
        }
        var cIn: [vera_onnx_input] = []
        for input in inputs {
            let n: String, shape: [Int64]
            var t = vera_onnx_input()
            switch input {
            case .float(let nm, let data, let sh):
                n = nm; shape = sh
                let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, data.count))
                _ = b.initialize(from: data); floats.append(b)
                t.type = Int32(VERA_ONNX_FLOAT); t.data = UnsafeRawPointer(b.baseAddress)
            case .int64(let nm, let data, let sh):
                n = nm; shape = sh
                let b = UnsafeMutableBufferPointer<Int64>.allocate(capacity: max(1, data.count))
                _ = b.initialize(from: data); ints.append(b)
                t.type = Int32(VERA_ONNX_INT64); t.data = UnsafeRawPointer(b.baseAddress)
            }
            let cName = strdup(n)!; names.append(cName)
            let s = UnsafeMutableBufferPointer<Int64>.allocate(capacity: max(1, shape.count))
            _ = s.initialize(from: shape); shapes.append(s)
            t.name = UnsafePointer(cName); t.shape = UnsafePointer(s.baseAddress); t.rank = Int32(shape.count)
            cIn.append(t)
        }
        let outNames = outputs.map { strdup($0)! }
        defer { outNames.forEach { free($0) } }
        var cOut = [vera_onnx_output](repeating: vera_onnx_output(), count: outputs.count)
        let namePtrs = outNames.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? }
        let rc = namePtrs.withUnsafeBufferPointer { np in
            vera_onnx_run(session, cIn, Int32(cIn.count), np.baseAddress, &cOut, Int32(outputs.count))
        }
        guard rc == 0 else { throw SileroError.model("\(name): \(String(cString: vera_onnx_error()))") }
        return cOut.map { o in
            let shape = withUnsafeBytes(of: o.shape) { Array($0.bindMemory(to: Int64.self).prefix(Int(o.rank))) }
            let data = Array(UnsafeBufferPointer(start: o.data, count: Int(o.count)))
            vera_onnx_free(o.data)
            return Output(data: data, shape: shape)
        }
    }
}
