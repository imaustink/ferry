// CRI ImageService. Images are pulled with ContainerizationOCI and unpacked to
// ext4 block devices, which is what a pod VM can actually boot -- there are no
// overlayfs snapshots here because there is no shared kernel to overlay on.

import Foundation
import GRPCCore

struct FerryImageService: Runtime_V1_ImageService.SimpleServiceProtocol {
    let runtime: PodRuntime

    func pullImage(request: Runtime_V1_PullImageRequest, context: ServerContext) async throws -> Runtime_V1_PullImageResponse {
        let reference = request.image.image
        do {
            _ = try await runtime.pullImage(reference)
            var response = Runtime_V1_PullImageResponse()
            response.imageRef = reference
            return response
        } catch {
            throw RPCError(code: .internalError, message: "pull \(reference): \(error)")
        }
    }

    /// A miss is an empty response, not an error: that is how the kubelet is
    /// told an image is absent and a pull is required.
    func imageStatus(request: Runtime_V1_ImageStatusRequest, context: ServerContext) async throws -> Runtime_V1_ImageStatusResponse {
        var response = Runtime_V1_ImageStatusResponse()
        if let image = await runtime.imageStatus(request.image.image) {
            response.image = image
        }
        return response
    }

    func listImages(request: Runtime_V1_ListImagesRequest, context: ServerContext) async throws -> Runtime_V1_ListImagesResponse {
        var response = Runtime_V1_ListImagesResponse()
        response.images = await runtime.listImages()
        return response
    }

    func removeImage(request: Runtime_V1_RemoveImageRequest, context: ServerContext) async throws -> Runtime_V1_RemoveImageResponse {
        await runtime.removeImage(request.image.image)
        return Runtime_V1_RemoveImageResponse()
    }

    func imageFsInfo(request: Runtime_V1_ImageFsInfoRequest, context: ServerContext) async throws -> Runtime_V1_ImageFsInfoResponse {
        let usage = await runtime.stateDirUsage()
        var used = Runtime_V1_UInt64Value(); used.value = usage.used
        var inodes = Runtime_V1_UInt64Value(); inodes.value = usage.inodes
        var identifier = Runtime_V1_FilesystemIdentifier()
        identifier.mountpoint = await runtime.stateDirPath()

        var entry = Runtime_V1_FilesystemUsage()
        entry.timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        entry.fsID = identifier
        entry.usedBytes = used
        entry.inodesUsed = inodes

        var response = Runtime_V1_ImageFsInfoResponse()
        response.imageFilesystems = [entry]
        response.containerFilesystems = [entry]
        return response
    }
}
