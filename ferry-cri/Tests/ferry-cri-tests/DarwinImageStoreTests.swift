// The image-fetch pieces that do not need a live registry: parsing an OCI
// manifest, and resolving a container's command against the image the way the
// kubelet expects.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct DarwinImageStoreTests {
    @Test func decodesAPlainManifest() throws {
        let json = """
        {"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
         "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:cfg"},
         "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:layer"}]}
        """
        let m = try DarwinImageStore.decodeManifest(Data(json.utf8), reference: "app:1")
        #expect(m.config?.digest == "sha256:cfg")
        #expect(m.layers?.first?.digest == "sha256:layer")
        #expect(m.manifests == nil)
    }

    @Test func decodesAnIndexAndItsDarwinChild() throws {
        let json = """
        {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json",
         "manifests":[
           {"digest":"sha256:linux","platform":{"os":"linux","architecture":"arm64"}},
           {"digest":"sha256:darwin","platform":{"os":"darwin","architecture":"arm64"}}]}
        """
        let m = try DarwinImageStore.decodeManifest(Data(json.utf8), reference: "app:1")
        let darwinChild = m.manifests?.first { $0.platform?.os == "darwin" && $0.platform?.architecture == "arm64" }
        #expect(darwinChild?.digest == "sha256:darwin")
        #expect(m.config == nil)
    }

    private func image(entrypoint: [String] = [], cmd: [String] = []) -> DarwinImage {
        DarwinImage(entrypoint: entrypoint, cmd: cmd, env: [], workingDir: "", layer: Data())
    }

    @Test func containerCommandOverridesTheImageEntrypoint() {
        let img = image(entrypoint: ["/bin/app"], cmd: ["--serve"])
        // command set -> replaces entrypoint; args set -> replaces cmd.
        #expect(DarwinImageStore.resolvedCommand(image: img, command: ["/bin/other"], args: ["x"])
            == ["/bin/other", "x"])
        // command set, no args -> args do NOT fall back to the image cmd.
        #expect(DarwinImageStore.resolvedCommand(image: img, command: ["/bin/other"], args: [])
            == ["/bin/other"])
    }

    @Test func fallsBackToTheImageWhenTheContainerLeavesItEmpty() {
        let img = image(entrypoint: ["/bin/app"], cmd: ["--serve"])
        #expect(DarwinImageStore.resolvedCommand(image: img, command: [], args: [])
            == ["/bin/app", "--serve"])
        // only args overridden -> keep image entrypoint.
        #expect(DarwinImageStore.resolvedCommand(image: img, command: [], args: ["--debug"])
            == ["/bin/app", "--debug"])
    }

    @Test func emptyEverywhereGetsAHarmlessDefault() {
        #expect(DarwinImageStore.resolvedCommand(image: image(), command: [], args: [])
            == ["/usr/bin/true"])
    }
}
