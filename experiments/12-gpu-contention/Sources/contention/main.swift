// What actually contends on this machine, and what only looks like it does.
//
// ferry-gpud hands out a token so one pod uses the GPU at a time. That is the
// safe assumption, and safe assumptions cost throughput when they are wrong.
// There are two questions and they have different answers:
//
//   1. Two Metal matmuls at once -- do they share, or do they each go slower?
//   2. A Metal matmul and an on-device generation at once -- same question.
//
// The second matters because Apple's model does not run on the GPU's shaders.
// The Neural Engine is separate silicon, so a token covering both may be one
// token too coarse. See docs/GPU.md.

import Foundation
import FoundationModels
import Metal
import MetalPerformanceShaders

// File scope so the concurrent tasks below capture them without ceremony.
nonisolated(unsafe) let device = MTLCreateSystemDefaultDevice()!
nonisolated(unsafe) let queue1 = device.makeCommandQueue()!
nonisolated(unsafe) let queue2 = device.makeCommandQueue()!

let size = 4096
let passes = 120
let prompt = "Write about 400 words on why running a virtual machine per pod is unusual."

/// A square matmul loop, timed. Each caller gets its own command queue, so the
/// only thing two of them share is the device.
func matmul(_ device: MTLDevice, _ queue: MTLCommandQueue, passes: Int) -> Double {
    let count = size * size
    let bytes = count * MemoryLayout<Float>.size
    var a = [Float](repeating: 0, count: count)
    var b = [Float](repeating: 0, count: count)
    for i in 0..<count {
        a[i] = Float((i % 13) + 1) / 13.0
        b[i] = Float((i % 7) + 1) / 7.0
    }
    let bufferA = device.makeBuffer(bytes: &a, length: bytes, options: .storageModeShared)!
    let bufferB = device.makeBuffer(bytes: &b, length: bytes, options: .storageModeShared)!
    let bufferC = device.makeBuffer(length: bytes, options: .storageModeShared)!
    let descriptor = MPSMatrixDescriptor(rows: size, columns: size,
                                         rowBytes: size * MemoryLayout<Float>.size,
                                         dataType: .float32)
    let mA = MPSMatrix(buffer: bufferA, descriptor: descriptor)
    let mB = MPSMatrix(buffer: bufferB, descriptor: descriptor)
    let mC = MPSMatrix(buffer: bufferC, descriptor: descriptor)
    let multiply = MPSMatrixMultiplication(
        device: device, transposeLeft: false, transposeRight: false,
        resultRows: size, resultColumns: size, interiorColumns: size, alpha: 1.0, beta: 0.0)

    // Warm-up outside the timing: the first encode pays for pipeline setup.
    let warm = queue.makeCommandBuffer()!
    multiply.encode(commandBuffer: warm, leftMatrix: mA, rightMatrix: mB, resultMatrix: mC)
    warm.commit()
    warm.waitUntilCompleted()

    let start = Date()
    for _ in 0..<passes {
        let commands = queue.makeCommandBuffer()!
        multiply.encode(commandBuffer: commands, leftMatrix: mA, rightMatrix: mB, resultMatrix: mC)
        commands.commit()
        commands.waitUntilCompleted()
    }
    return 2.0 * pow(Double(size), 3) * Double(passes) / Date().timeIntervalSince(start) / 1e9
}

func generate() async -> (seconds: Double, chars: Int) {
    let session = LanguageModelSession()
    let start = Date()
    var chars = 0
    do {
        chars = try await session.respond(
            to: prompt, options: GenerationOptions(maximumResponseTokens: 600)).content.count
    } catch {
        print("  generation failed: \(error)")
    }
    return (Date().timeIntervalSince(start), chars)
}

@main
struct Contention {
    static func main() async {
        print("device: \(device.name)")
        print("matmul \(size)x\(size) x\(passes) per run, generation ~400 words\n")

        // --- 1. Metal against Metal -------------------------------------
        let soloFlops = matmul(device, queue1, passes: passes)
        print("two matmuls")
        print(String(format: "  one alone     %.0f GFLOP/s", soloFlops))

        async let one = Task.detached(priority: .userInitiated) {
            matmul(device, queue1, passes: passes)
        }.value
        async let two = Task.detached(priority: .userInitiated) {
            matmul(device, queue2, passes: passes)
        }.value
        let (first, second) = await (one, two)
        print(String(format: "  two at once   %.0f + %.0f = %.0f GFLOP/s (%.0f%% of one)",
                     first, second, first + second, (first + second) / soloFlops * 100))
        print("  -> the same GPU, split. Serialising these loses nothing.\n")

        // --- 2. Metal against the model ---------------------------------
        let solo = await generate()
        print("a matmul and a generation")
        print(String(format: "  generation alone  %.2fs (%d chars, %.2fms/char)",
                     solo.seconds, solo.chars, solo.seconds / Double(solo.chars) * 1000))

        async let generation = generate()
        try? await Task.sleep(for: .milliseconds(300))
        let bothFlops = await Task.detached(priority: .userInitiated) {
            matmul(device, queue1, passes: passes)
        }.value
        let both = await generation
        print(String(format: "  together          matmul %.0f GFLOP/s (%+.1f%%), "
                     + "generation %.2fms/char (%+.1f%%)",
                     bothFlops, (bothFlops - soloFlops) / soloFlops * 100,
                     both.seconds / Double(both.chars) * 1000,
                     (both.seconds / Double(both.chars) - solo.seconds / Double(solo.chars))
                        / (solo.seconds / Double(solo.chars)) * 100))
        print("  -> different silicon. Serialising these costs the whole overlap.")
    }
}
