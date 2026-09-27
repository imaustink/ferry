// Print the restore image Virtualization.framework would install on this Mac.
import Virtualization

let done = DispatchSemaphore(value: 0)
VZMacOSRestoreImage.fetchLatestSupported { result in
    switch result {
    case .success(let image):
        print(image.url.absoluteString)
        print(image.buildVersion, image.operatingSystemVersion)
        if let req = image.mostFeaturefulSupportedConfiguration {
            print("min cpus", req.minimumSupportedCPUCount, "min memory", req.minimumSupportedMemorySize)
        }
    case .failure(let error):
        print("error:", error)
    }
    done.signal()
}
done.wait()
