import Foundation
import NetworkExtension

let xpc = XPCServer(bundle: .main)
xpc?.start()
Shared.watchStatus()
if xpc == nil { proxyLog.error("no Mach service name or team in Info.plist: the app can't reach the extension") }

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
