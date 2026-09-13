// CRI RuntimeService, mapped onto PodRuntime.

import Containerization
import Foundation
import GRPCCore

struct FerryRuntimeService: Runtime_V1_RuntimeService.SimpleServiceProtocol {
    let runtime: PodRuntime
    let version: String
    let streamer: StreamerClient

    private func unimplemented(_ name: String) -> RPCError {
        RPCError(code: .unimplemented, message: "ferry-cri does not implement \(name) yet")
    }

    private func failed(_ error: Error) -> RPCError {
        if let rpc = error as? RPCError { return rpc }
        return RPCError(code: .internalError, message: "\(error)")
    }

    // MARK: Identity

    func version(request: Runtime_V1_VersionRequest, context: ServerContext) async throws -> Runtime_V1_VersionResponse {
        var response = Runtime_V1_VersionResponse()
        response.version = "0.1.0"
        response.runtimeName = "ferry"
        response.runtimeVersion = self.version
        response.runtimeApiVersion = "v1"
        return response
    }

    func status(request: Runtime_V1_StatusRequest, context: ServerContext) async throws -> Runtime_V1_StatusResponse {
        var ready = Runtime_V1_RuntimeCondition()
        ready.type = "RuntimeReady"
        ready.status = true
        var network = Runtime_V1_RuntimeCondition()
        network.type = "NetworkReady"
        network.status = true

        var status = Runtime_V1_RuntimeStatus()
        status.conditions = [ready, network]

        var response = Runtime_V1_StatusResponse()
        response.status = status
        if request.verbose {
            response.info = [
                "gateway": await runtime.gateway,
                "podSubnet": await runtime.subnet,
            ]
        }
        return response
    }

    /// There is no host cgroup hierarchy to report a driver for; pods are
    /// bounded by VM sizing and containers by cgroups inside the guest.
    func runtimeConfig(request: Runtime_V1_RuntimeConfigRequest, context: ServerContext) async throws -> Runtime_V1_RuntimeConfigResponse {
        Runtime_V1_RuntimeConfigResponse()
    }

    func updateRuntimeConfig(request: Runtime_V1_UpdateRuntimeConfigRequest, context: ServerContext) async throws -> Runtime_V1_UpdateRuntimeConfigResponse {
        Runtime_V1_UpdateRuntimeConfigResponse()
    }

    // MARK: Sandboxes

    func runPodSandbox(request: Runtime_V1_RunPodSandboxRequest, context: ServerContext) async throws -> Runtime_V1_RunPodSandboxResponse {
        do {
            let id = try await runtime.runPodSandbox(config: request.config)
            var response = Runtime_V1_RunPodSandboxResponse()
            response.podSandboxID = id
            return response
        } catch { throw failed(error) }
    }

    func stopPodSandbox(request: Runtime_V1_StopPodSandboxRequest, context: ServerContext) async throws -> Runtime_V1_StopPodSandboxResponse {
        do {
            try await runtime.stopPodSandbox(request.podSandboxID)
            return Runtime_V1_StopPodSandboxResponse()
        } catch { throw failed(error) }
    }

    func removePodSandbox(request: Runtime_V1_RemovePodSandboxRequest, context: ServerContext) async throws -> Runtime_V1_RemovePodSandboxResponse {
        do {
            try await runtime.removePodSandbox(request.podSandboxID)
            return Runtime_V1_RemovePodSandboxResponse()
        } catch { throw failed(error) }
    }

    private func metadata(_ r: SandboxRecord) -> Runtime_V1_PodSandboxMetadata {
        var m = Runtime_V1_PodSandboxMetadata()
        m.name = r.name; m.uid = r.uid; m.namespace = r.namespace; m.attempt = r.attempt
        return m
    }

    func podSandboxStatus(request: Runtime_V1_PodSandboxStatusRequest, context: ServerContext) async throws -> Runtime_V1_PodSandboxStatusResponse {
        do {
            let record = try await runtime.sandbox(request.podSandboxID)
            var network = Runtime_V1_PodSandboxNetworkStatus()
            network.ip = record.ip

            var status = Runtime_V1_PodSandboxStatus()
            status.id = record.id
            status.metadata = metadata(record)
            status.state = record.ready ? .sandboxReady : .sandboxNotready
            status.createdAt = record.createdAt
            status.network = network
            status.labels = record.labels
            status.annotations = record.annotations

            var response = Runtime_V1_PodSandboxStatusResponse()
            response.status = status
            return response
        } catch { throw failed(error) }
    }

    /// The filter is not optional to honour. The kubelet decides which
    /// containers belong to which pod from these listings, so an unfiltered
    /// answer makes every pod appear to own every container.
    func listPodSandbox(request: Runtime_V1_ListPodSandboxRequest, context: ServerContext) async throws -> Runtime_V1_ListPodSandboxResponse {
        let filter = request.hasFilter ? request.filter : nil
        var items: [Runtime_V1_PodSandbox] = []
        for record in await runtime.listSandboxes() {
            let state: Runtime_V1_PodSandboxState = record.ready ? .sandboxReady : .sandboxNotready
            if let filter {
                if !filter.id.isEmpty && filter.id != record.id { continue }
                if filter.hasState && filter.state.state != state { continue }
                if !filter.labelSelector.allSatisfy({ record.labels[$0.key] == $0.value }) { continue }
            }
            var item = Runtime_V1_PodSandbox()
            item.id = record.id
            item.metadata = metadata(record)
            item.state = state
            item.createdAt = record.createdAt
            item.labels = record.labels
            item.annotations = record.annotations
            items.append(item)
        }
        var response = Runtime_V1_ListPodSandboxResponse()
        response.items = items
        return response
    }

    // MARK: Containers

    func createContainer(request: Runtime_V1_CreateContainerRequest, context: ServerContext) async throws -> Runtime_V1_CreateContainerResponse {
        do {
            let id = try await runtime.createContainer(sandboxID: request.podSandboxID, config: request.config)
            var response = Runtime_V1_CreateContainerResponse()
            response.containerID = id
            return response
        } catch { throw failed(error) }
    }

    func startContainer(request: Runtime_V1_StartContainerRequest, context: ServerContext) async throws -> Runtime_V1_StartContainerResponse {
        do {
            try await runtime.startContainer(request.containerID)
            return Runtime_V1_StartContainerResponse()
        } catch { throw failed(error) }
    }

    func stopContainer(request: Runtime_V1_StopContainerRequest, context: ServerContext) async throws -> Runtime_V1_StopContainerResponse {
        do {
            try await runtime.stopContainer(request.containerID, timeout: request.timeout)
            return Runtime_V1_StopContainerResponse()
        } catch { throw failed(error) }
    }

    func removeContainer(request: Runtime_V1_RemoveContainerRequest, context: ServerContext) async throws -> Runtime_V1_RemoveContainerResponse {
        do {
            try await runtime.removeContainer(request.containerID)
            return Runtime_V1_RemoveContainerResponse()
        } catch { throw failed(error) }
    }

    private func crioState(_ s: ContainerRunState) -> Runtime_V1_ContainerState {
        switch s {
        case .created: .containerCreated
        case .running: .containerRunning
        case .exited: .containerExited
        }
    }

    private func metadata(_ r: ContainerRecord) -> Runtime_V1_ContainerMetadata {
        var m = Runtime_V1_ContainerMetadata()
        m.name = r.name; m.attempt = r.attempt
        return m
    }

    func containerStatus(request: Runtime_V1_ContainerStatusRequest, context: ServerContext) async throws -> Runtime_V1_ContainerStatusResponse {
        do {
            let record = try await runtime.container(request.containerID)
            var spec = Runtime_V1_ImageSpec()
            spec.image = record.image

            var status = Runtime_V1_ContainerStatus()
            status.id = record.id
            status.metadata = metadata(record)
            status.state = crioState(record.state)
            status.createdAt = record.createdAt
            status.startedAt = record.startedAt
            status.finishedAt = record.finishedAt
            status.exitCode = record.exitCode
            status.image = spec
            status.imageRef = record.imageRef
            status.reason = record.reason
            status.labels = record.labels
            status.annotations = record.annotations
            status.logPath = record.logPath

            var response = Runtime_V1_ContainerStatusResponse()
            response.status = status
            return response
        } catch { throw failed(error) }
    }

    func listContainers(request: Runtime_V1_ListContainersRequest, context: ServerContext) async throws -> Runtime_V1_ListContainersResponse {
        let filter = request.hasFilter ? request.filter : nil
        var items: [Runtime_V1_Container] = []
        for record in await runtime.listContainers() {
            let state = crioState(record.state)
            if let filter {
                if !filter.id.isEmpty && filter.id != record.id { continue }
                if !filter.podSandboxID.isEmpty && filter.podSandboxID != record.sandboxID { continue }
                if filter.hasState && filter.state.state != state { continue }
                if !filter.labelSelector.allSatisfy({ record.labels[$0.key] == $0.value }) { continue }
            }
            var spec = Runtime_V1_ImageSpec()
            spec.image = record.image

            var item = Runtime_V1_Container()
            item.id = record.id
            item.podSandboxID = record.sandboxID
            item.metadata = metadata(record)
            item.image = spec
            item.imageRef = record.imageRef
            item.state = state
            item.createdAt = record.createdAt
            item.labels = record.labels
            item.annotations = record.annotations
            items.append(item)
        }
        var response = Runtime_V1_ListContainersResponse()
        response.containers = items
        return response
    }

    /// Called after the kubelet rotates a log file. Without reopening, the
    /// runtime keeps writing into the rotated file and `kubectl logs` goes
    /// quiet.
    func reopenContainerLog(request: Runtime_V1_ReopenContainerLogRequest, context: ServerContext) async throws -> Runtime_V1_ReopenContainerLogResponse {
        do {
            try await runtime.reopenContainerLog(request.containerID)
            return Runtime_V1_ReopenContainerLogResponse()
        } catch { throw failed(error) }
    }

    func updateContainerResources(request: Runtime_V1_UpdateContainerResourcesRequest, context: ServerContext) async throws -> Runtime_V1_UpdateContainerResourcesResponse {
        // In-place resize would have to reach cgroups inside the guest.
        throw unimplemented("UpdateContainerResources")
    }

    func updatePodSandboxResources(request: Runtime_V1_UpdatePodSandboxResourcesRequest, context: ServerContext) async throws -> Runtime_V1_UpdatePodSandboxResourcesResponse {
        throw unimplemented("UpdatePodSandboxResources")
    }

    // MARK: Statistics
    //
    // Empty rather than invented. The kubelet tolerates absent container stats
    // and sources node-level numbers from cadvisor; fabricated figures would
    // feed the eviction manager lies.

    func containerStats(request: Runtime_V1_ContainerStatsRequest, context: ServerContext) async throws -> Runtime_V1_ContainerStatsResponse {
        Runtime_V1_ContainerStatsResponse()
    }
    func listContainerStats(request: Runtime_V1_ListContainerStatsRequest, context: ServerContext) async throws -> Runtime_V1_ListContainerStatsResponse {
        Runtime_V1_ListContainerStatsResponse()
    }
    func podSandboxStats(request: Runtime_V1_PodSandboxStatsRequest, context: ServerContext) async throws -> Runtime_V1_PodSandboxStatsResponse {
        Runtime_V1_PodSandboxStatsResponse()
    }
    func listPodSandboxStats(request: Runtime_V1_ListPodSandboxStatsRequest, context: ServerContext) async throws -> Runtime_V1_ListPodSandboxStatsResponse {
        Runtime_V1_ListPodSandboxStatsResponse()
    }
    func listMetricDescriptors(request: Runtime_V1_ListMetricDescriptorsRequest, context: ServerContext) async throws -> Runtime_V1_ListMetricDescriptorsResponse {
        Runtime_V1_ListMetricDescriptorsResponse()
    }
    func listPodSandboxMetrics(request: Runtime_V1_ListPodSandboxMetricsRequest, context: ServerContext) async throws -> Runtime_V1_ListPodSandboxMetricsResponse {
        Runtime_V1_ListPodSandboxMetricsResponse()
    }

    // MARK: Not yet implemented

    func execSync(request: Runtime_V1_ExecSyncRequest, context: ServerContext) async throws -> Runtime_V1_ExecSyncResponse {
        throw unimplemented("ExecSync")
    }
    /// CRI does not carry exec over gRPC: the runtime returns a URL and the
    /// kubelet proxies the client's upgraded connection to it, speaking
    /// SPDY/3.1. ferry-streamer terminates that and calls back into this
    /// process to run the command, so the URL has to come from it -- the token
    /// it contains is issued by the streaming server's own request cache.
    func exec(request: Runtime_V1_ExecRequest, context: ServerContext) async throws -> Runtime_V1_ExecResponse {
        do {
            let url = try streamer.url(path: "/exec", body: [
                "container_id": request.containerID,
                "cmd": request.cmd,
                "tty": request.tty,
                "stdin": request.stdin,
                "stdout": request.stdout,
                "stderr": request.stderr,
            ])
            var response = Runtime_V1_ExecResponse()
            response.url = url
            return response
        } catch {
            throw RPCError(code: .unavailable, message: "\(error)")
        }
    }
    /// Attach would reconnect to a container's own process. The framework
    /// exposes no way to reattach to a process that is already running, so the
    /// URL is minted but the stream will report the limitation rather than
    /// silently producing nothing.
    func attach(request: Runtime_V1_AttachRequest, context: ServerContext) async throws -> Runtime_V1_AttachResponse {
        throw unimplemented("Attach")
    }
    func portForward(request: Runtime_V1_PortForwardRequest, context: ServerContext) async throws -> Runtime_V1_PortForwardResponse {
        do {
            let url = try streamer.url(path: "/portforward", body: [
                "pod_sandbox_id": request.podSandboxID,
                "port": request.port,
            ])
            var response = Runtime_V1_PortForwardResponse()
            response.url = url
            return response
        } catch {
            throw RPCError(code: .unavailable, message: "\(error)")
        }
    }
    func checkpointContainer(request: Runtime_V1_CheckpointContainerRequest, context: ServerContext) async throws -> Runtime_V1_CheckpointContainerResponse {
        throw unimplemented("CheckpointContainer")
    }
    func getContainerEvents(
        request: Runtime_V1_GetEventsRequest,
        response: GRPCCore.RPCWriter<Runtime_V1_ContainerEventResponse>,
        context: ServerContext
    ) async throws {
        throw unimplemented("GetContainerEvents")
    }
}
