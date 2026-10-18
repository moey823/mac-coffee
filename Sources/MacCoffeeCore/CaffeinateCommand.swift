public enum CaffeinateCommand {
    public static let executablePath = "/usr/bin/caffeinate"

    /// -i prevents idle system sleep, -d prevents display sleep, -m prevents
    /// disk idle sleep, -s prevents system sleep only on AC power, -t bounds
    /// these assertions, and -w ties them to the owning app process.
    public static func displayAssertionEnabled(savedPreference: Bool, temporaryDarkMode: Bool) -> Bool {
        savedPreference || temporaryDarkMode
    }

    public static func arguments(
        ownerPID: Int32,
        keepsDisplayOn: Bool,
        timeoutSeconds: Int?,
        keepsDisksAwake: Bool = false,
        preventsSystemSleepOnAC: Bool = false
    ) -> [String] {
        var arguments = ["-i"]
        if keepsDisplayOn { arguments.append("-d") }
        if keepsDisksAwake { arguments.append("-m") }
        if preventsSystemSleepOnAC { arguments.append("-s") }
        if let timeoutSeconds { arguments += ["-t", String(max(1, timeoutSeconds))] }
        arguments += ["-w", String(ownerPID)]
        return arguments
    }

    /// A separate five-second user-activity pulse. Keep this out of the
    /// session assertion because -t would otherwise shorten the whole session.
    public static func wakeScreenPulseArguments(ownerPID: Int32) -> [String] {
        ["-u", "-t", "5", "-w", String(ownerPID)]
    }
}
