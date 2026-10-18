import Foundation

@objc public protocol LidAwakeXPCProtocol {
    func getStatus(reply: @escaping (Bool, NSNumber?, String?) -> Void)
    func startSession(
        durationSeconds: NSNumber?,
        startOnLidClose: Bool,
        stopOnBattery: Bool,
        reply: @escaping (Bool, NSNumber?, String?) -> Void
    )
    func stopSession(reply: @escaping (Bool, String?) -> Void)
    func heartbeat(reply: @escaping (Bool, NSNumber?, String?) -> Void)
}
