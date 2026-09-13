// The GPU, and work run on it.
//
// This is the half of ferry-gpud that a pod cannot do for itself. Metal is a
// macOS API: there is no pass-through on Apple silicon, so a process inside a
// pod VM has no path to the hardware at all (docs/GPU.md). Here, on the host,
// it is an ordinary framework call.
//
// Work is serialized on one device. There is one GPU, and the node advertises
// however many pods may hold a relay at once; letting several saturate it
// concurrently would serve all of them badly and report meaningless timings.

import Foundation
import Metal
import MetalPerformanceShaders

struct DeviceInfo: Encodable {
    var name: String
    var architecture: String
    var unifiedMemory: Bool
    var recommendedWorkingSetMiB: UInt64
    var maxThreadsPerThreadgroup: Int
    var maxBufferMiB: Int
}

struct MatmulResult: Encodable {
    var size: Int
    var iterations: Int
    var seconds: Double
    var gflops: Double
    /// The first element of the product. The inputs are fixed, so this is
    /// reproducible -- it is here so a caller can tell that arithmetic
    /// happened, not just that time passed.
    var checksum: Float
}

enum GPUError: Error, CustomStringConvertible {
    case unavailable
    case failed(String)

    var description: String {
        switch self {
        case .unavailable: "no Metal device on this machine"
        case .failed(let m): m
        }
    }
}

/// Owns the Metal device and serializes work on it.
final class GPU: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// One GPU, one job at a time. See the note at the top of the file.
    private let gate = DispatchSemaphore(value: 1)

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError.unavailable }
        guard let queue = device.makeCommandQueue() else {
            throw GPUError.failed("could not create a command queue")
        }
        self.device = device
        self.queue = queue
    }

    var info: DeviceInfo {
        DeviceInfo(
            name: device.name,
            architecture: device.architecture.name,
            unifiedMemory: device.hasUnifiedMemory,
            recommendedWorkingSetMiB: device.recommendedMaxWorkingSetSize / (1024 * 1024),
            maxThreadsPerThreadgroup: device.maxThreadsPerThreadgroup.width,
            maxBufferMiB: device.maxBufferLength / (1024 * 1024))
    }

    /// A square matrix multiply, `iterations` times, on the GPU.
    ///
    /// Real arithmetic rather than a sleep: it is what proves, from inside a
    /// pod, that the Mac's GPU did work the pod asked for. MPS rather than a
    /// hand-written kernel so the number means something.
    func matmul(size: Int, iterations: Int) throws -> MatmulResult {
        guard size > 0, size <= 8192 else { throw GPUError.failed("size must be 1...8192") }
        guard iterations > 0, iterations <= 1000 else { throw GPUError.failed("iterations must be 1...1000") }

        gate.wait()
        defer { gate.signal() }

        let count = size * size
        let bytes = count * MemoryLayout<Float>.size
        guard bytes <= device.maxBufferLength else {
            throw GPUError.failed("\(size)x\(size) exceeds the device's maximum buffer")
        }

        // Fixed inputs, so the checksum is reproducible across calls and hosts.
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for i in 0..<count {
            a[i] = Float((i % 13) + 1) / 13.0
            b[i] = Float((i % 7) + 1) / 7.0
        }

        guard let bufferA = device.makeBuffer(bytes: &a, length: bytes, options: .storageModeShared),
              let bufferB = device.makeBuffer(bytes: &b, length: bytes, options: .storageModeShared),
              let bufferC = device.makeBuffer(length: bytes, options: .storageModeShared)
        else { throw GPUError.failed("could not allocate \(bytes * 3) bytes on the device") }

        let rowBytes = size * MemoryLayout<Float>.size
        let descriptor = MPSMatrixDescriptor(rows: size, columns: size,
                                             rowBytes: rowBytes, dataType: .float32)
        let matrixA = MPSMatrix(buffer: bufferA, descriptor: descriptor)
        let matrixB = MPSMatrix(buffer: bufferB, descriptor: descriptor)
        let matrixC = MPSMatrix(buffer: bufferC, descriptor: descriptor)
        let multiply = MPSMatrixMultiplication(
            device: device, transposeLeft: false, transposeRight: false,
            resultRows: size, resultColumns: size, interiorColumns: size,
            alpha: 1.0, beta: 0.0)

        // One warm-up outside the timing: the first encode pays for pipeline
        // setup that has nothing to do with the arithmetic being measured.
        if let warmUp = queue.makeCommandBuffer() {
            multiply.encode(commandBuffer: warmUp, leftMatrix: matrixA,
                            rightMatrix: matrixB, resultMatrix: matrixC)
            warmUp.commit()
            warmUp.waitUntilCompleted()
        }

        let start = Date()
        for _ in 0..<iterations {
            guard let commands = queue.makeCommandBuffer() else {
                throw GPUError.failed("could not create a command buffer")
            }
            multiply.encode(commandBuffer: commands, leftMatrix: matrixA,
                            rightMatrix: matrixB, resultMatrix: matrixC)
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw GPUError.failed("\(error)") }
        }
        let seconds = Date().timeIntervalSince(start)

        // 2*n^3 flops per multiply-accumulate pass.
        let flops = 2.0 * pow(Double(size), 3) * Double(iterations)
        let checksum = bufferC.contents().bindMemory(to: Float.self, capacity: count)[0]

        return MatmulResult(size: size, iterations: iterations, seconds: seconds,
                            gflops: seconds > 0 ? flops / seconds / 1e9 : 0,
                            checksum: checksum)
    }
}
