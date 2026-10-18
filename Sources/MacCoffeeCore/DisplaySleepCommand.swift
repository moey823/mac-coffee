/// Fixed command used only by the explicit display-sleep action. This is not
/// the system sleep command and does not invoke a shell or privileged helper.
public enum DisplaySleepCommand {
    public static let executablePath = "/usr/bin/pmset"
    public static let arguments = ["displaysleepnow"]
}
