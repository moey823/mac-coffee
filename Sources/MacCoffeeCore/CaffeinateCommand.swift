public enum CaffeinateCommand {
    public static let executablePath = "/usr/bin/caffeinate"

    /// -i prevents idle system sleep, -d also prevents display sleep,
    /// -t bounds the assertion, and -w ties it to the owning app process.
    public static func arguments(
        ownerPID: Int32,
        keepsDisplayOn: Bool,
        timeoutSeconds: Int?
    ) -> [String] {
        var arguments = ["-i"]
        if keepsDisplayOn { arguments.append("-d") }
        if let timeoutSeconds { arguments += ["-t", String(max(1, timeoutSeconds))] }
        arguments += ["-w", String(ownerPID)]
        return arguments
    }
}
