import Foundation
import MLX

/// Reads PyTorch `.ckpt`/`.pth` state dicts (the zip format from `torch.save`) without Python.
///
/// Only what model checkpoints need is supported: an uncompressed zip, and a pickle that builds
/// a dict of tensors via `torch._utils._rebuild_tensor_v2`. Nothing in the pickle is executed.
enum TorchCheckpoint {
    enum ReadError: LocalizedError {
        case notAZip, compressedEntry(String), missingEntry(String), unsupportedOpcode(UInt8), malformed(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: "The model file isn't a PyTorch checkpoint."
            case .compressedEntry(let name): "The model file has a compressed entry (\(name))."
            case .missingEntry(let name): "The model file is missing \(name)."
            case .unsupportedOpcode(let op): "The model file uses an unsupported pickle opcode (0x\(String(op, radix: 16)))."
            case .malformed(let detail): "The model file is malformed: \(detail)."
            }
        }
    }

    /// Returns every tensor in the checkpoint's state dict, keyed by its PyTorch name.
    static func read(_ url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let zip = try ZipIndex(data)
        guard let pickleName = zip.entries.keys.first(where: { $0.hasSuffix("/data.pkl") || $0 == "data.pkl" }) else {
            throw ReadError.missingEntry("data.pkl")
        }
        let prefix = String(pickleName.dropLast("data.pkl".count))
        var machine = Unpickler(data: try zip.contents(of: pickleName))
        let root = try machine.run()

        var storages: [String: MLXArray] = [:]
        func storage(_ key: String, dtype: DType) throws -> MLXArray {
            if let cached = storages[key] { return cached }
            let array = MLXArray(try zip.contents(of: "\(prefix)data/\(key)"), dtype: dtype)
            storages[key] = array
            return array
        }

        var tensors: [String: MLXArray] = [:]
        for (key, value) in root.stateDict {
            guard case .string(let name) = key, case .tensor(let ref) = value,
                  let dtype = ref.dtype else { continue }
            let base = try storage(ref.storageKey, dtype: dtype)
            let isContiguous = ref.stride == contiguousStrides(ref.shape)
            let count = ref.shape.reduce(1, *)
            tensors[name] = isContiguous
                ? base[ref.offset ..< ref.offset + count].reshaped(ref.shape)
                : asStrided(base, ref.shape, strides: ref.stride, offset: ref.offset)
        }
        return tensors
    }

    private static func contiguousStrides(_ shape: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: shape.count)
        for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * shape[i + 1] }
        return strides
    }
}

// MARK: - Zip

/// Central-directory index of a stored (uncompressed) zip, as written by `torch.save`.
private struct ZipIndex {
    let data: Data
    var entries: [String: (offset: Int, size: Int)] = [:]

    init(_ data: Data) throws {
        self.data = data
        // End of central directory: scan back from the end for its signature.
        let minEOCD = 22
        guard data.count >= minEOCD else { throw TorchCheckpoint.ReadError.notAZip }
        var eocd = data.count - minEOCD
        let floor = max(0, data.count - minEOCD - 65_535)
        while eocd >= floor, data.u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= floor else { throw TorchCheckpoint.ReadError.notAZip }

        var count = Int(data.u16(eocd + 10))
        var directory = Int(data.u32(eocd + 16))
        // Zip64: the classic record holds 0xFFFF/0xFFFFFFFF and points at a zip64 record.
        let locator = eocd - 20
        if locator >= 0, data.u32(locator) == 0x0706_4B50 {
            let record = Int(data.u64(locator + 8))
            guard data.u32(record) == 0x0606_4B50 else { throw TorchCheckpoint.ReadError.notAZip }
            count = Int(data.u64(record + 32))
            directory = Int(data.u64(record + 48))
        }

        var cursor = directory
        for _ in 0..<count {
            guard data.u32(cursor) == 0x0201_4B50 else { throw TorchCheckpoint.ReadError.malformed("central directory") }
            let method = data.u16(cursor + 10)
            var size = Int(data.u32(cursor + 24))
            let nameLength = Int(data.u16(cursor + 28))
            let extraLength = Int(data.u16(cursor + 30))
            let commentLength = Int(data.u16(cursor + 32))
            var localHeader = Int(data.u32(cursor + 42))
            let name = String(decoding: data[(data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength)], as: UTF8.self)
            // Zip64 extra field carries the real sizes/offset when the classic fields overflow.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.u16(extra), length = Int(data.u16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if data.u32(cursor + 24) == 0xFFFF_FFFF { size = Int(data.u64(field)); field += 8 }
                    if data.u32(cursor + 20) == 0xFFFF_FFFF { field += 8 }
                    if data.u32(cursor + 42) == 0xFFFF_FFFF { localHeader = Int(data.u64(field)) }
                }
                extra += 4 + length
            }
            guard method == 0 else { throw TorchCheckpoint.ReadError.compressedEntry(name) }
            guard data.u32(localHeader) == 0x0403_4B50 else { throw TorchCheckpoint.ReadError.malformed("local header for \(name)") }
            let start = localHeader + 30 + Int(data.u16(localHeader + 26)) + Int(data.u16(localHeader + 28))
            entries[name] = (start, size)
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw TorchCheckpoint.ReadError.missingEntry(name) }
        let start = data.startIndex + entry.offset
        return data[start ..< start + entry.size]
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { load(offset, as: UInt16.self) }
    func u32(_ offset: Int) -> UInt32 { load(offset, as: UInt32.self) }
    func u64(_ offset: Int) -> UInt64 { load(offset, as: UInt64.self) }
    func load<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return 0 }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

// MARK: - Pickle

private final class PickleDict {
    var items: [(PickleValue, PickleValue)] = []
}

private struct TensorRef {
    var storageKey: String
    var storageType: String
    var offset: Int
    var shape: [Int]
    var stride: [Int]

    var dtype: DType? {
        switch storageType {
        case "FloatStorage": .float32
        case "HalfStorage": .float16
        case "BFloat16Storage": .bfloat16
        case "DoubleStorage": .float64
        case "LongStorage": .int64
        case "IntStorage": .int32
        case "BoolStorage": .bool
        default: nil
        }
    }
}

private indirect enum PickleValue {
    case none, bool(Bool), int(Int), float(Double), string(String), bytes(Data)
    case tuple([PickleValue]), list([PickleValue]), dict(PickleDict)
    case global(String, String)
    case storage(key: String, type: String)
    case tensor(TensorRef)
    case mark
    case opaque

    var ints: [Int]? {
        guard case .tuple(let items) = self else { return nil }
        return items.compactMap { if case .int(let v) = $0 { v } else { nil } }
    }

    /// The tensors dict, unwrapping Lightning-style `{"state_dict": {...}}` wrappers.
    var stateDict: [(PickleValue, PickleValue)] {
        guard case .dict(let dict) = self else { return [] }
        let hasTensors = dict.items.contains { if case .tensor = $0.1 { true } else { false } }
        if !hasTensors {
            for (key, value) in dict.items {
                if case .string(let name) = key, ["state_dict", "model", "model_state_dict"].contains(name) {
                    return value.stateDict
                }
            }
        }
        return dict.items
    }
}

/// A minimal pickle VM covering what `torch.save` emits (protocols 2–4). Calls only ever build
/// dicts or tensor references; any other callable yields an opaque value.
private struct Unpickler {
    let data: Data
    var position = 0
    var stack: [PickleValue] = []
    var memo: [Int: PickleValue] = [:]

    init(data: Data) { self.data = Data(data) }

    mutating func run() throws -> PickleValue {
        while position < data.count {
            let op = byte()
            switch op {
            case 0x80: position += 1                                  // PROTO
            case 0x95: position += 8                                  // FRAME
            case 0x2E: return stack.popLast() ?? .none                // STOP
            case 0x28: stack.append(.mark)                            // MARK
            case 0x4E: stack.append(.none)                            // NONE
            case 0x88: stack.append(.bool(true))                      // NEWTRUE
            case 0x89: stack.append(.bool(false))                     // NEWFALSE
            case 0x4B: stack.append(.int(Int(byte())))                // BININT1
            case 0x4D: stack.append(.int(Int(read(UInt16.self))))     // BININT2
            case 0x4A: stack.append(.int(Int(Int32(bitPattern: read(UInt32.self))))) // BININT
            case 0x8A:                                                 // LONG1
                let n = Int(byte())
                var value = 0
                for i in 0..<n { value |= Int(byte()) << (8 * i) }
                if n > 0, n < 8, value & (1 << (8 * n - 1)) != 0 { value -= 1 << (8 * n) }
                stack.append(.int(value))
            case 0x47:                                                 // BINFLOAT (big-endian)
                stack.append(.float(Double(bitPattern: read(UInt64.self).byteSwapped)))
            case 0x58: stack.append(.string(text(Int(read(UInt32.self)))))   // BINUNICODE
            case 0x8C: stack.append(.string(text(Int(byte()))))              // SHORT_BINUNICODE
            case 0x43: stack.append(.bytes(bytes(Int(byte()))))              // SHORT_BINBYTES
            case 0x42: stack.append(.bytes(bytes(Int(read(UInt32.self)))))   // BINBYTES
            case 0x29: stack.append(.tuple([]))                       // EMPTY_TUPLE
            case 0x85: stack.append(.tuple([pop()]))                  // TUPLE1
            case 0x86: let b = pop(), a = pop(); stack.append(.tuple([a, b]))       // TUPLE2
            case 0x87: let c = pop(), b = pop(), a = pop(); stack.append(.tuple([a, b, c])) // TUPLE3
            case 0x74: stack.append(.tuple(try popToMark()))          // TUPLE
            case 0x5D: stack.append(.list([]))                        // EMPTY_LIST
            case 0x61: let v = pop(); if case .list(var l) = stack.last { l.append(v); stack[stack.count - 1] = .list(l) } // APPEND
            case 0x65:                                                 // APPENDS
                let items = try popToMark()
                if case .list(var l) = stack.last { l.append(contentsOf: items); stack[stack.count - 1] = .list(l) }
            case 0x7D: stack.append(.dict(PickleDict()))              // EMPTY_DICT
            case 0x73:                                                 // SETITEM
                let value = pop(), key = pop()
                if case .dict(let d) = stack.last { d.items.append((key, value)) }
            case 0x75:                                                 // SETITEMS
                let items = try popToMark()
                if case .dict(let d) = stack.last {
                    for i in stride(from: 0, to: items.count - 1, by: 2) { d.items.append((items[i], items[i + 1])) }
                }
            case 0x63:                                                 // GLOBAL
                let module = line(), name = line()
                stack.append(.global(module, name))
            case 0x93:                                                 // STACK_GLOBAL
                let name = pop(), module = pop()
                if case .string(let m) = module, case .string(let n) = name { stack.append(.global(m, n)) } else { stack.append(.opaque) }
            case 0x71: memo[Int(byte())] = stack.last                 // BINPUT
            case 0x72: memo[Int(read(UInt32.self))] = stack.last      // LONG_BINPUT
            case 0x94: memo[memo.count] = stack.last                  // MEMOIZE
            case 0x68: stack.append(memo[Int(byte())] ?? .none)       // BINGET
            case 0x6A: stack.append(memo[Int(read(UInt32.self))] ?? .none) // LONG_BINGET
            case 0x51:                                                 // BINPERSID
                stack.append(persistentLoad(pop()))
            case 0x52:                                                 // REDUCE
                let args = pop(), callable = pop()
                stack.append(call(callable, args))
            case 0x81:                                                 // NEWOBJ
                let args = pop(), cls = pop()
                stack.append(call(cls, args))
            case 0x62: _ = pop()                                       // BUILD (state ignored)
            case 0x30: _ = pop()                                       // POP
            case 0x32: if let top = stack.last { stack.append(top) }   // DUP
            default: throw TorchCheckpoint.ReadError.unsupportedOpcode(op)
            }
        }
        throw TorchCheckpoint.ReadError.malformed("pickle ended without STOP")
    }

    private func call(_ callable: PickleValue, _ args: PickleValue) -> PickleValue {
        guard case .global(let module, let name) = callable, case .tuple(let a) = args else { return .opaque }
        switch (module, name) {
        case ("collections", "OrderedDict"), ("builtins", "dict"):
            return .dict(PickleDict())
        case ("torch._utils", "_rebuild_tensor_v2"), ("torch._utils", "_rebuild_tensor"):
            guard a.count >= 4, case .storage(let key, let type) = a[0], case .int(let offset) = a[1],
                  let shape = a[2].ints, let stride = a[3].ints else { return .opaque }
            return .tensor(TensorRef(storageKey: key, storageType: type, offset: offset, shape: shape, stride: stride))
        case ("torch._utils", "_rebuild_parameter"), ("torch.nn.parameter", "Parameter"):
            return a.first ?? .opaque
        default:
            return .opaque
        }
    }

    /// `('storage', torch.FloatStorage, '<key>', '<location>', numel)` → a storage reference.
    private func persistentLoad(_ pid: PickleValue) -> PickleValue {
        guard case .tuple(let items) = pid, items.count >= 3, case .global(_, let type) = items[1],
              case .string(let key) = items[2] else { return .opaque }
        return .storage(key: key, type: type)
    }

    private mutating func pop() -> PickleValue { stack.popLast() ?? .none }

    private mutating func popToMark() throws -> [PickleValue] {
        guard let index = stack.lastIndex(where: { if case .mark = $0 { true } else { false } }) else {
            throw TorchCheckpoint.ReadError.malformed("missing MARK")
        }
        let items = Array(stack[(index + 1)...])
        stack.removeSubrange(index...)
        return items
    }

    private mutating func byte() -> UInt8 {
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) -> T {
        let value = data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: position, as: T.self)) }
        position += MemoryLayout<T>.size
        return value
    }

    private mutating func bytes(_ count: Int) -> Data {
        defer { position += count }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + count))
    }

    private mutating func text(_ count: Int) -> String { String(decoding: bytes(count), as: UTF8.self) }

    private mutating func line() -> String {
        var end = position
        while end < data.count, data[data.startIndex + end] != 0x0A { end += 1 }
        defer { position = end + 1 }
        return String(decoding: data[(data.startIndex + position)..<(data.startIndex + end)], as: UTF8.self)
    }
}
