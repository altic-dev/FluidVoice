import Darwin
import Hummingbird
import Logging
import NIOCore
import NIOHTTPTypes
import ServiceLifecycle

@MainActor
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    private var serverTask: Task<Void, Never>?
    private var serviceGroup: ServiceGroup?
    private var isStopping = false

    func start(configuration config: LocalAPI.Configuration = .current) {
        guard self.serverTask == nil else { return }
        guard config.enabled else {
            DebugLogger.shared.info("Local API disabled", source: "LocalAPIServer")
            return
        }

        self.isStopping = false
        self.serverTask = Task {
            defer { self.serverTask = nil }
            await self.run(port: config.port)
        }
    }

    func stop() {
        self.isStopping = true
        if let group = self.serviceGroup {
            Task { await group.triggerGracefulShutdown() }
        } else {
            self.serverTask?.cancel()
        }
    }

    private func run(port: UInt16) async {
        let router = LocalAPIRouter(port: port)
        let clock = ContinuousClock()
        var deadline: ContinuousClock.Instant?
        var delay = Duration.milliseconds(250)

        while !self.isStopping {
            do {
                try await self.runOnce(router: router, port: port)
                return
            } catch {
                guard !self.isStopping else { return }
                guard let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE else {
                    DebugLogger.shared.error("Local API listener failed: \(error)", source: "LocalAPIServer")
                    return
                }

                let now = clock.now
                if deadline == nil {
                    // Give the outgoing process time to finish its update shutdown.
                    deadline = now + .seconds(30)
                    DebugLogger.shared.warning("Local API port \(port) is in use; retrying for up to 30 seconds", source: "LocalAPIServer")
                }
                guard let deadline, now < deadline else {
                    DebugLogger.shared.error("Local API port \(port) is still in use after retrying: \(error)", source: "LocalAPIServer")
                    return
                }

                do {
                    try await clock.sleep(until: min(now + delay, deadline))
                } catch {
                    return
                }
                delay = min(delay * 2, .seconds(2))
            }
        }
    }

    private func runOnce(router: LocalAPIRouter, port: UInt16) async throws {
        let services = ["127.0.0.1", "::1"].map { host in
            let application = Application(
                responder: router,
                server: .http1(configuration: .init(additionalChannelHandlers: [CloseAfterResponse()])),
                configuration: .init(address: .hostname(host, port: Int(port))),
                onServerRunning: { _ in
                    let address = host == "::1" ? "[::1]" : host
                    DebugLogger.shared.info("Local API listening on http://\(address):\(port)", source: "LocalAPIServer")
                }
            )
            return ServiceGroupConfiguration.ServiceConfiguration(
                service: application,
                failureTerminationBehavior: .gracefullyShutdownGroup
            )
        }

        // AppDelegate manages shutdown. Leave process signal handling to the app.
        var configuration = ServiceGroupConfiguration(services: services, logger: Logger(label: "LocalAPIServer"))
        configuration.maximumGracefulShutdownDuration = .seconds(1)
        let group = ServiceGroup(configuration: configuration)
        self.serviceGroup = group
        defer { self.serviceGroup = nil }
        try await group.run()
    }
}

// Preserve one request per connection, including rejections that leave the request body unread.
private nonisolated final class CloseAfterResponse: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPResponsePart
    typealias OutboundOut = HTTPResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .end = self.unwrapOutboundIn(data) {
            context.writeAndFlush(data, promise: promise)
            context.close(promise: nil)
        } else {
            context.write(data, promise: promise)
        }
    }
}
