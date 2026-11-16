import Foundation

/// mDNS 发现的车机（对应车机端 NsdHelper 注册的 _carlink._tcp）
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String        // 服务名（= 车机 deviceName）
    var name: String
    var host: String?
    var port: Int?

    var resolved: Bool { host != nil && port != nil }
}

final class BonjourBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_carlink._tcp"

    @Published var devices: [DiscoveredDevice] = []
    @Published var browsing = false

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stop()
        DispatchQueue.main.async { self.browsing = true }
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.removeAll()
        DispatchQueue.main.async {
            self.devices.removeAll()
            self.browsing = false
        }
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.id == service.name }) {
                self.devices.append(DiscoveredDevice(id: service.name, name: service.name, host: nil, port: nil))
            }
        }
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == service.name }
        }
        services.removeAll { $0 == service }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.browsing = false }
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? ""
        let port = sender.port
        DispatchQueue.main.async {
            if let i = self.devices.firstIndex(where: { $0.id == sender.name }) {
                self.devices[i].host = host
                self.devices[i].port = port
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
}
