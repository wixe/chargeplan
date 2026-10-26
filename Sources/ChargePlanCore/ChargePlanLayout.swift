import Foundation

/// Files, labels, and the project link. Legacy ChargeCap paths stay because
/// machines installed under the old name still boot from them.
public enum ChargePlanLayout {
    public static let projectLinkTitle = "github.com/wixe/chargeplan"
    public static let projectURL = URL(string: "https://github.com/wixe/chargeplan")!

    public static let gitHubOwner = "wixe"
    public static let gitHubRepo = "chargeplan"

    public static let socketPath = "/var/run/chargeplan.sock"
    public static let legacySocketPath = "/var/run/chargecap.sock"

    public static let systemConfigPath = "/etc/chargeplan.json"
    public static let legacyConfigPath = "/etc/chargecap.json"

    public static let supportDirectory = "/Library/Application Support/ChargePlan"
    public static let legacySupportDirectory = "/Library/Application Support/ChargeCap"
    public static let daemonBinary = "\(supportDirectory)/ChargePlanDaemon"
    public static let cliDirectory = "/usr/local/bin"
    public static let cliBinary = "\(cliDirectory)/chargeplan"

    public static let appBundle = "/Applications/ChargePlan.app"
    public static let legacyAppBundle = "/Applications/ChargeCap.app"

    public static let daemonLabel = "io.github.wixe.chargeplan.daemon"
    public static let appLabel = "io.github.wixe.chargeplan.app"
    public static let legacyAppLabel = "com.wixe.chargeplan.app"
    public static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
    public static let stdoutLog = "/var/log/chargeplan.log"
    public static let stderrLog = "/var/log/chargeplan.error.log"

    public static let previousDaemonLabel = "com.wixe.chargeplan.daemon"
    public static let chargeCapDaemonLabel = "com.wixe.chargecap.daemon"
    public static let chargeCapLabel = "com.wixe.chargecap"

    public static let legacyDaemonLabels = [
        previousDaemonLabel,
        chargeCapDaemonLabel,
        chargeCapLabel,
    ]

    public static let legacyDaemonPlists = [
        "/Library/LaunchDaemons/\(previousDaemonLabel).plist",
        "/Library/LaunchDaemons/\(chargeCapDaemonLabel).plist",
        "/Library/LaunchDaemons/\(chargeCapLabel).plist",
    ]

    public static var daemonLabels: [String] {
        [daemonLabel] + legacyDaemonLabels
    }

    public static func userConfigPath(home: String) -> String {
        "\(home)/.config/chargeplan/config.json"
    }

    public static func launchAgentPath(home: String) -> String {
        "\(home)/Library/LaunchAgents/\(appLabel).plist"
    }

    public static func legacyLaunchAgentPath(home: String) -> String {
        "\(home)/Library/LaunchAgents/\(legacyAppLabel).plist"
    }

    public static func daemonPlistXML(program: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
                <string>daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(stdoutLog)</string>
            <key>StandardErrorPath</key>
            <string>\(stderrLog)</string>
        </dict>
        </plist>
        """
    }

    public static func appLaunchAgentXML(executable: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(appLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
                <string>--background</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }
}
