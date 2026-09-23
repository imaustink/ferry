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
        // Not ferry's version: this field is the version of the kubelet
        // runtime API itself, which is "0.1.0" for every CRI runtime and what
        // containerd answers too. The node's CONTAINER-RUNTIME column comes
        // from runtimeVersion below, which is where the release goes.
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
            status.state = record.reportedReady ? .sandboxReady : .sandboxNotready
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
            let state: Runtime_V1_PodSandboxState = record.reportedReady ? .sandboxReady : .sandboxNotready
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
            let began = ContinuousClock.now
            let id = try await runtime.createContainer(sandboxID: request.podSandboxID, config: request.config)
            trace("create", request.config.metadata.name + " " + id, since: began)
            var response = Runtime_V1_CreateContainerResponse()
            response.containerID = id
            return response
        } catch { throw failed(error) }
    }

    func startContainer(request: Runtime_V1_StartContainerRequest, context: ServerContext) async throws -> Runtime_V1_StartContainerResponse {
        do {
            let began = ContinuousClock.now
            try await runtime.startContainer(request.containerID)
            trace("start", request.containerID, since: began)
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

    /// FERRY_CRI_TRACE=1 prints how long each container call took, which is
    /// what the kubelet's own log cannot say to better than its 1s relist.
    private static let tracing = ProcessInfo.processInfo.environment["FERRY_CRI_TRACE"] == "1"

    private func trace(_ call: String, _ what: String, since began: ContinuousClock.Instant) {
        guard Self.tracing else { return }
        let ms = (ContinuousClock.now - began).components
        let millis = ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000
        print("    trace     \(call) \(what) \(millis)ms")
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
            // The kubelet finds a container's termination message by looking
            // here for the mount at its terminationMessagePath and reading the
            // host side. Without them no pod ever had one, and a crash loop's
            // own explanation of itself never reached `kubectl describe`.
            status.mounts = record.mounts

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
    // Real numbers now, from the cgroups inside each pod's VM. The kubelet
    // tolerates an empty answer here and metrics-server does not, so an empty
    // one meant `kubectl top` and every autoscaler stayed broken.
    func containerStats(request: Runtime_V1_ContainerStatsRequest, context: ServerContext) async throws -> Runtime_V1_ContainerStatsResponse {
        var response = Runtime_V1_ContainerStatsResponse()
        let measured = await runtime.containerStatistics(ids: [request.containerID])
        if let first = measured.first, let stats = await containerStats(for: first.id, from: first.stats) {
            response.stats = stats
        }
        return response
    }

    func listContainerStats(request: Runtime_V1_ListContainerStatsRequest, context: ServerContext) async throws -> Runtime_V1_ListContainerStatsResponse {
        var response = Runtime_V1_ListContainerStatsResponse()
        var wanted = await runtime.runningContainerIDs()
        if !request.filter.id.isEmpty { wanted = wanted.filter { $0 == request.filter.id } }
        for entry in await runtime.containerStatistics(ids: wanted) {
            if let stats = await containerStats(for: entry.id, from: entry.stats) {
                response.stats.append(stats)
            }
        }
        return response
    }

    /// Translates the framework's numbers into CRI's shape.
    private func containerStats(for id: String,
                                from statistics: ContainerStatistics) async -> Runtime_V1_ContainerStats? {
        guard let record = try? await runtime.container(id) else { return nil }

        var attributes = Runtime_V1_ContainerAttributes()
        attributes.id = id
        var metadata = Runtime_V1_ContainerMetadata()
        metadata.name = record.name
        metadata.attempt = record.attempt
        attributes.metadata = metadata
        attributes.labels = record.labels
        attributes.annotations = record.annotations

        var stats = Runtime_V1_ContainerStats()
        stats.attributes = attributes

        let now = Self.now()
        if let cpu = statistics.cpu {
            var usage = Runtime_V1_CpuUsage()
            usage.timestamp = now
            var nanos = Runtime_V1_UInt64Value()
            // cgroup v2 counts microseconds; CRI wants nanoseconds.
            nanos.value = cpu.usageUsec * 1000
            usage.usageCoreNanoSeconds = nanos
            stats.cpu = usage
        }
        if let memory = statistics.memory {
            var usage = Runtime_V1_MemoryUsage()
            usage.timestamp = now
            var working = Runtime_V1_UInt64Value()
            // Working set is usage minus what the kernel can reclaim, which is
            // the number the kubelet evicts on and `kubectl top` shows.
            working.value = memory.usageBytes > memory.cacheBytes
                ? memory.usageBytes - memory.cacheBytes : memory.usageBytes
            usage.workingSetBytes = working
            var used = Runtime_V1_UInt64Value(); used.value = memory.usageBytes
            usage.usageBytes = used
            var rss = Runtime_V1_UInt64Value(); rss.value = working.value
            usage.rssBytes = rss
            stats.memory = usage
        }
        return stats
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }

    // Per-sandbox rollups are still empty: the kubelet does not require them and
    // metrics-server reads the per-container numbers above.
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

    /// A command run to completion, its output collected: what an exec
    /// probe is. Without it every exec liveness and readiness probe "errored
    /// and resulted in unknown state", so a hung container was never restarted
    /// and a pod gated on an exec readiness probe never became ready.
    ///
    /// A command that outlives the timeout is killed and reported as a
    /// DeadlineExceeded, which the kubelet counts as the probe timing out.
    func execSync(request: Runtime_V1_ExecSyncRequest, context: ServerContext) async throws -> Runtime_V1_ExecSyncResponse {
        let stdout = CollectingWriter(), stderr = CollectingWriter()
        let process: LinuxProcess
        do {
            process = try await runtime.exec(containerID: request.containerID, command: request.cmd, tty: false,
                                             stdin: nil, stdout: stdout, stderr: stderr)
        } catch { throw failed(error) }
        do {
            try await process.start()
            let status: ExitStatus
            do {
                status = try await process.wait(timeoutInSeconds: request.timeout > 0 ? request.timeout : nil)
            } catch {
                try? await process.kill(.kill)
                _ = try? await process.wait(timeoutInSeconds: 2)
                try? await process.delete()
                throw RPCError(code: .deadlineExceeded,
                               message: "command \(request.cmd) timed out after \(request.timeout)s")
            }
            // Every exec holds a process in the guest agent and ports on the
            // host until it is deleted; probes run every few seconds for ever.
            try? await process.delete()
            var response = Runtime_V1_ExecSyncResponse()
            response.stdout = stdout.data
            response.stderr = stderr.data
            response.exitCode = status.exitCode
            return response
        } catch {
            try? await process.delete()
            throw failed(error)
        }
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
    /// Attach reconnects to a container's own process. The framework cannot
    /// re-open a running process's stdio, but ferry-cri owns that stdio -- the
    /// container's output already flows through its log writer -- so attaching
    /// is a subscription to it. Input requires the pod to have asked for stdin,
    /// since the stream has to be wired in at creation.
    func attach(request: Runtime_V1_AttachRequest, context: ServerContext) async throws -> Runtime_V1_AttachResponse {
        do {
            let url = try streamer.url(path: "/attach", body: [
                "container_id": request.containerID,
                "stdin": request.stdin,
                "stdout": request.stdout,
                "stderr": request.stderr,
                "tty": request.tty,
            ])
            var response = Runtime_V1_AttachResponse()
            response.url = url
            return response
        } catch {
            throw RPCError(code: .unavailable, message: "\(error)")
        }
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
