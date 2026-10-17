import Foundation

public enum LidAwakeServiceConfiguration {
    public static let applicationIdentifier = "com.moey823.MacCoffee"
    public static let serviceLabel = "com.moey823.MacCoffee.LidAwake"
    public static let machServiceName = serviceLabel
    public static let servicePlistName = "com.moey823.MacCoffee.LidAwake.plist"
    public static let helperExecutableName = "MacCoffeeLidAwakeHelper"

    public static func helperExecutableURL(in appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library/HelperTools", isDirectory: true)
            .appendingPathComponent(helperExecutableName, isDirectory: false)
    }

    public static func applicationBundleURL(containingHelperAt helperExecutableURL: URL) -> URL {
        var bundleURL = helperExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<4 {
            bundleURL.deleteLastPathComponent()
        }
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func applicationExecutableURL(in appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("MacCoffee", isDirectory: false)
    }
}
