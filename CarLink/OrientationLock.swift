import UIKit

// MARK: - 屏幕方向锁
//
// 全 App 默认竖屏（设计要求），只有播放器进入全屏时才允许横屏。
// AppDelegate 的 supportedInterfaceOrientationsFor 返回这里的 mask，
// 切换时用 UIWindowScene.requestGeometryUpdate 主动触发旋转（iOS 16+）。

final class OrientationLock {
    static let shared = OrientationLock()

    private(set) var mask: UIInterfaceOrientationMask = .portrait

    func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

// MARK: - AppDelegate（仅用于接管屏幕方向）

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
