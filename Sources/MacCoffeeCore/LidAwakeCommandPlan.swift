public enum LidAwakeCommandPlan {
    public static let executablePath = "/usr/bin/pmset"
    public static func setSleepDisabled(_ disabled: Bool) -> [String] {
        ["-a", "disablesleep", disabled ? "1" : "0"]
    }
    public static let sleepNow = ["sleepnow"]
}
