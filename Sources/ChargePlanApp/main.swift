import AppKit
import Foundation
import ChargePlanCore

@MainActor
final class ChargePlanAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var windowTelemetryTimer: Timer?
    private var settingsWindow: NSWindow?
    
    // Settings window controls
    private var batteryLabel: NSTextField?
    private var governorLabel: NSTextField?
    private var telemetryLabel: NSTextField?
    private var cellLabel: NSTextField?
    private var daemonBadgeLabel: NSTextField?
    private var energyLabel: NSTextField?
    private let batteryGraphView = BatteryGraphView(frame: NSRect(x: 12, y: 12, width: 528, height: 132))
    private var yScaleControl: NSSegmentedControl?
    private var limitSlider: NSSlider?
    private var limitValueLabel: NSTextField?
    private var driftCheckbox: NSButton?
    private var loginCheckbox: NSButton?
    private var installDaemonButton: NSButton?
    private var uninstallDaemonButton: NSButton?
    
    // Update state & controls
    private var latestRelease: ReleaseInfo?
    private var isUpdatingApp: Bool = false
    private var isAutoSyncingDaemon: Bool = false
    private var menuIsOpen = false
    private var replacingMenu = false
    private var controlNotice: String?
    private var controlNoticeUntil = Date.distantPast
    private var lastAutoSyncAttempt = Date.distantPast
    private var updateStatusText: String = ""
    private var updateBox: NSBox?
    private var updateLabel: NSTextField?
    private var updateSubLabel: NSTextField?
    private var updateActionButton: NSButton?
    
    private let monitor = BatteryMonitor()
    private lazy var fallbackHardware = HardwareBackend()
    private let launchAgentPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let legacyPath = ChargePlanLayout.legacyLaunchAgentPath(home: home)
        if FileManager.default.fileExists(atPath: legacyPath) {
            _ = try? FileManager.default.removeItem(atPath: legacyPath)
        }
        return ChargePlanLayout.launchAgentPath(home: home)
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⚡ --%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        
        // Enable Launch at Login by default on first run if installed in /Applications
        if Bundle.main.bundlePath.hasPrefix("/Applications") && !FileManager.default.fileExists(atPath: launchAgentPath) {
            setLaunchAtLogin(true)
        }
        
        rebuildMenu()
        
        // Automatically ensure background daemon binary matches this app version
        autoSyncDaemonIfNeeded()
        
        // Background check for updates (cached 24h, 0 overhead)
        Task {
            await checkUpdateSilently()
        }
        
        // Show the Settings / Dashboard window if launched interactively (not via --background Login Agent)
        if !CommandLine.arguments.contains("--background") {
            showSettingsWindow()
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoSyncDaemonIfNeeded()
                self?.rebuildMenu()
                self?.refreshSettingsWindow()
            }
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }
    
    private func fetchDaemonStatus() -> (running: Bool, mode: String, backend: String?, version: String?) {
        if let liveJson = UnixSocketClient.send("STATUS"),
           let data = liveJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gov = obj["governor"] as? [String: Any],
           let mode = gov["mode"] as? String {
            let backend = gov["backend"] as? String
            let version = gov["version"] as? String
            return (true, mode, backend, version)
        }
        return (false, "Daemon Not Installed", nil, nil)
    }
    
    private func rebuildMenu() {
        guard !menuIsOpen else { return }
        replacingMenu = true
        defer { replacingMenu = false }

        let status = monitor.getCurrentStatus()
        let cfg = ConfigManager.shared.load()
        let daemonInfo = fetchDaemonStatus()
        let daemonActive = daemonInfo.running
        let govMode = daemonInfo.mode
        let backendName = daemonInfo.backend ?? fallbackHardware.modeName
        
        let iconPrefix = menuBarSymbol(for: status)
        statusItem.button?.title = "\(iconPrefix) \(status.percent)% → \(cfg.targetLimit)%"
        
        let menu = NSMenu()
        menu.delegate = self
        
        if let rel = latestRelease, UpdateChecker.isVersion(rel.version, newerThan: ChargePlanVersion) {
            let updateItem = NSMenuItem(title: "⬆️ Update Available (\(rel.tagName))…", action: #selector(triggerAppUpdate), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let latestItem = NSMenuItem(title: "ChargePlan \(ChargePlanVersion)", action: nil, keyEquivalent: "")
            latestItem.isEnabled = false
            menu.addItem(latestItem)
        }
        
        let stateStr = status.isCharging ? "Charging" : (status.isACConnected ? "AC Pass-Through" : "On Battery")
        let wattageStr = String(format: "%.1fW", abs(status.wattageW))
        let pctFormatted = String(format: "%.2f%%", status.exactPercent)
        batteryGraphView.addSample(percent: status.exactPercent, targetLimit: cfg.targetLimit, isCharging: status.isCharging)
        
        var infoLines = [
            "Battery: \(pctFormatted) (\(stateStr))",
            "Target: \(cfg.targetLimit)% \(cfg.driftEnabled ? "(Drift -\(cfg.driftMargin)%)" : "(Strict)")",
            "Control Mode: \(govMode)",
            "Power: \(wattageStr) • \(status.voltageMV) mV • \(status.amperageMA) mA",
            "Health: \(String(format: "%.1f", status.healthPercent))% (\(status.cycleCount) cycles) • \(status.thermalState)"
        ]
        if !status.cellVoltagesMV.isEmpty {
            let cellsStr = status.cellVoltagesMV.map { String(format: "%.2fV", Double($0) / 1000.0) }.joined(separator: " • ")
            let delta = status.cellImbalanceMV != nil ? " (Δ \(status.cellImbalanceMV!) mV)" : ""
            let temp = status.temperatureC != nil ? String(format: " • %.1f°C", status.temperatureC!) : ""
            infoLines.append("Cells: \(cellsStr)\(delta)\(temp)")
        } else if let temp = status.temperatureC {
            infoLines.append(String(format: "Battery Temp: %.1f°C", temp))
        }
        infoLines.append("Backend: \(backendName)")
        
        let readingsMenu = NSMenu()
        for line in infoLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            readingsMenu.addItem(item)
        }
        let readingsRoot = NSMenuItem(title: "\(iconPrefix) \(status.percent)% · \(stateStr)", action: nil, keyEquivalent: "")
        readingsRoot.submenu = readingsMenu
        menu.addItem(readingsRoot)
        
        let presets: [(Int, String)] = [
            (30, "30% — Minimum Safe Floor"),
            (40, "40% — Cold Storage"),
            (50, "50% — Daily Midpoint"),
            (60, "60% — Desk / Docked"),
            (70, "70% — Hybrid"),
            (80, "80% — Longevity"),
            (100, "100% — Full Charge")
        ]
        let capMenu = NSMenu()
        for (limit, label) in presets {
            let item = NSMenuItem(title: label, action: #selector(selectPresetLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            item.state = (cfg.targetLimit == limit) ? .on : .off
            capMenu.addItem(item)
        }
        let capRoot = NSMenuItem(title: "Target: \(cfg.targetLimit)%", action: nil, keyEquivalent: "")
        capRoot.submenu = capMenu
        menu.addItem(capRoot)
        
        menu.addItem(.separator())
        
        // Drift Margin Submenu
        let driftMenu = NSMenu()
        for (enabled, margin, title) in [(true, 3, "Enabled (-3% Drift)"), (true, 5, "Enabled (-5% Drift)"), (false, 3, "Disabled (Strict)")] {
            let dItem = NSMenuItem(title: title, action: #selector(selectDriftOption(_:)), keyEquivalent: "")
            dItem.target = self
            dItem.tag = enabled ? margin : 0
            dItem.state = (cfg.driftEnabled == enabled && (!enabled || cfg.driftMargin == margin)) ? .on : .off
            driftMenu.addItem(dItem)
        }
        let driftTitle = cfg.driftEnabled ? "Drift Margin: −\(cfg.driftMargin)%" : "Drift Margin: Off"
        let driftRoot = NSMenuItem(title: driftTitle, action: nil, keyEquivalent: "")
        driftRoot.submenu = driftMenu
        menu.addItem(driftRoot)
        
        // Status Icon Legend Submenu
        let legendMenu = NSMenu()
        let legendItems = [
            ("⚡", "Charging", "Cells actively accepting power to target"),
            ("🔌", "AC Pass-Through", "Wall power idle hold (0.00W battery stress)"),
            ("🔋", "On Battery", "Discharging, AC adapter disconnected")
        ]
        for (icon, title, desc) in legendItems {
            let item = NSMenuItem(title: "\(icon)  \(title) — \(desc)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            legendMenu.addItem(item)
        }
        let legendRoot = NSMenuItem(title: "Status Icon Legend", action: nil, keyEquivalent: "")
        legendRoot.submenu = legendMenu
        menu.addItem(legendRoot)
        
        menu.addItem(.separator())
        
        let openSettingsItem = NSMenuItem(title: "Open ChargePlan Settings & Installer…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)
        
        let checkUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)
        
        let loginItem = NSMenuItem(title: "Start Menu Bar Icon at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)
        
        if !daemonActive {
            let installItem = NSMenuItem(title: "⚠️ Enable Background Controller Daemon…", action: #selector(installDaemonAction), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)
        } else if !isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version) {
            let updateItem = NSMenuItem(title: "⚠️ Update Background Daemon…", action: #selector(installDaemonAction), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
            let uninstallItem = NSMenuItem(title: "Uninstall Background Daemon…", action: #selector(uninstallDaemonAction), keyEquivalent: "")
            uninstallItem.target = self
            menu.addItem(uninstallItem)
        } else {
            let restartItem = NSMenuItem(title: "Restart Background Daemon", action: #selector(installDaemonAction), keyEquivalent: "")
            restartItem.target = self
            menu.addItem(restartItem)
            let uninstallItem = NSMenuItem(title: "Uninstall Background Daemon…", action: #selector(uninstallDaemonAction), keyEquivalent: "")
            uninstallItem.target = self
            menu.addItem(uninstallItem)
        }
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "Quit ChargePlan Menu Bar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if !replacingMenu {
            rebuildMenu()
        }
    }
    
    @objc private func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(ChargePlanLayout.projectURL)
    }
    
    @objc private func yAxisSegmentChanged(_ sender: NSSegmentedControl) {
        batteryGraphView.yAxisMode = (sender.selectedSegment == 1) ? .zoomed : .full
    }
    
    /// Keeps the settings window inside the area below the menu bar and above the Dock.
    private func placeSettingsWindowOnScreen() {
        guard let win = settingsWindow else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = win.frame
        frame.size.width = min(frame.width, visible.width - 12)
        frame.size.height = min(frame.height, visible.height - 12)
        frame.origin.x = floor(visible.midX - frame.width / 2)
        frame.origin.y = floor(visible.midY - frame.height / 2)
        if frame.minX < visible.minX { frame.origin.x = visible.minX + 6 }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width - 6 }
        if frame.minY < visible.minY { frame.origin.y = visible.minY + 6 }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height - 6 }
        win.setFrame(frame, display: true)
    }
    
    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            // 6pt grid. Controls take the left 2/3. The graph column is the right 1/3.
            let unit: CGFloat = 6
            let margin = unit * 3
            let gutter = unit * 2
            let graphColW = unit * 32
            let controlW = graphColW * 2
            let innerW = graphColW + gutter + controlW
            let width = innerW + margin * 2
            let titleH = unit * 4
            let energyH = unit * 4
            let badgeH = unit * 6
            let battH = unit * 20
            let graphBoxH = unit * 44
            let legendBoxH = unit * 21
            let columnH = graphBoxH + gutter + legendBoxH
            let controlX = margin
            let graphX = margin + controlW + gutter
            
            var cursor = margin
            let columnsY = cursor
            cursor += columnH + gutter
            let battY = cursor
            cursor += battH + gutter
            let badgeY = cursor
            cursor += badgeH + unit
            let energyY = cursor
            cursor += energyH + unit
            let titleY = cursor
            cursor += titleH + margin
            let height = cursor
            let columnTop = columnsY + columnH
            
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "ChargePlan Settings"
            win.isReleasedWhenClosed = false
            win.delegate = self
            
            let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            win.contentView = content
            
            let linkW = unit * 36
            let title = NSTextField(labelWithString: "⚡ ChargePlan Charge Controller")
            title.font = NSFont.boldSystemFont(ofSize: 16)
            title.cell?.wraps = true
            title.cell?.isScrollable = false
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: margin, y: titleY, width: innerW - linkW - gutter, height: titleH)
            content.addSubview(title)
            
            let projectLink = LinkButton(title: ChargePlanLayout.projectLinkTitle, target: self, action: #selector(openProjectPage(_:)))
            projectLink.isBordered = false
            projectLink.attributedTitle = NSAttributedString(
                string: ChargePlanLayout.projectLinkTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            projectLink.alignment = .right
            projectLink.lineBreakMode = .byTruncatingTail
            projectLink.toolTip = ChargePlanLayout.projectURL.absoluteString
            projectLink.frame = NSRect(x: margin + innerW - linkW, y: titleY, width: linkW, height: titleH)
            content.addSubview(projectLink)
            
            let energy = NSTextField(labelWithString: "")
            energy.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            energy.textColor = .secondaryLabelColor
            energy.lineBreakMode = .byTruncatingTail
            energy.frame = NSRect(x: margin, y: energyY, width: innerW, height: energyH)
            content.addSubview(energy)
            self.energyLabel = energy
            
            let daemonBadge = NSTextField(labelWithString: "")
            daemonBadge.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            daemonBadge.cell?.wraps = true
            daemonBadge.cell?.isScrollable = false
            daemonBadge.maximumNumberOfLines = 2
            daemonBadge.lineBreakMode = .byWordWrapping
            daemonBadge.frame = NSRect(x: margin, y: badgeY, width: innerW, height: badgeH)
            content.addSubview(daemonBadge)
            self.daemonBadgeLabel = daemonBadge
            
            let battBox = NSBox(frame: NSRect(x: margin, y: battY, width: innerW, height: battH))
            battBox.title = "Live Battery & Controller Telemetry"
            battBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(battBox)
            let battBounds = battBox.contentView?.bounds ?? .zero
            let battRowH = unit * 4
            let battRowW = battBounds.width - unit * 2
            let battRowY = (0..<4).map { battBounds.height - battRowH * CGFloat($0 + 1) }
            
            let bLabel = NSTextField(labelWithString: "")
            bLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            bLabel.cell?.wraps = true
            bLabel.cell?.isScrollable = false
            bLabel.maximumNumberOfLines = 2
            bLabel.lineBreakMode = .byWordWrapping
            bLabel.frame = NSRect(x: unit, y: battRowY[0], width: battRowW, height: battRowH)
            battBox.contentView?.addSubview(bLabel)
            self.batteryLabel = bLabel
            
            let gLabel = NSTextField(labelWithString: "")
            gLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            gLabel.cell?.wraps = true
            gLabel.cell?.isScrollable = false
            gLabel.maximumNumberOfLines = 2
            gLabel.lineBreakMode = .byWordWrapping
            gLabel.frame = NSRect(x: unit, y: battRowY[1], width: battRowW, height: battRowH)
            battBox.contentView?.addSubview(gLabel)
            self.governorLabel = gLabel
            
            let tLabel = NSTextField(labelWithString: "")
            tLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            tLabel.textColor = .secondaryLabelColor
            tLabel.cell?.wraps = true
            tLabel.cell?.isScrollable = false
            tLabel.maximumNumberOfLines = 2
            tLabel.lineBreakMode = .byWordWrapping
            tLabel.frame = NSRect(x: unit, y: battRowY[2], width: battRowW, height: battRowH)
            battBox.contentView?.addSubview(tLabel)
            self.telemetryLabel = tLabel
            
            let cLabel = NSTextField(labelWithString: "")
            cLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            cLabel.textColor = .secondaryLabelColor
            cLabel.cell?.wraps = true
            cLabel.cell?.isScrollable = false
            cLabel.maximumNumberOfLines = 2
            cLabel.lineBreakMode = .byWordWrapping
            cLabel.frame = NSRect(x: unit, y: battRowY[3], width: battRowW, height: battRowH)
            battBox.contentView?.addSubview(cLabel)
            self.cellLabel = cLabel
            
            let graphBox = NSBox(frame: NSRect(x: graphX, y: columnsY + legendBoxH + gutter, width: graphColW, height: graphBoxH))
            graphBox.title = "30m Timeline"
            graphBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(graphBox)
            let graphBounds = graphBox.contentView?.bounds ?? .zero
            let scaleH = unit * 4
            let graphW = unit * 28
            let graphH = unit * 34
            
            let yLabel = NSTextField(labelWithString: "Y-Scale")
            yLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            yLabel.textColor = .secondaryLabelColor
            yLabel.alignment = .left
            yLabel.frame = NSRect(x: 0, y: graphBounds.height - scaleH, width: unit * 8, height: scaleH)
            graphBox.contentView?.addSubview(yLabel)
            
            let yControl = NSSegmentedControl(labels: ["0–100%", "Zoomed"], trackingMode: .selectOne, target: self, action: #selector(yAxisSegmentChanged(_:)))
            yControl.selectedSegment = (self.batteryGraphView.yAxisMode == .zoomed) ? 1 : 0
            yControl.controlSize = .small
            yControl.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            yControl.frame = NSRect(x: unit * 9, y: graphBounds.height - scaleH, width: unit * 20, height: scaleH)
            graphBox.contentView?.addSubview(yControl)
            self.yScaleControl = yControl
            
            batteryGraphView.frame = NSRect(x: unit, y: unit, width: graphW, height: graphH)
            if batteryGraphView.superview == nil {
                graphBox.contentView?.addSubview(batteryGraphView)
            }
            
            let legendBox = NSBox(frame: NSRect(x: graphX, y: columnsY, width: graphColW, height: legendBoxH))
            legendBox.title = "Power Status"
            legendBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(legendBox)
            let legendBounds = legendBox.contentView?.bounds ?? .zero
            let legendRowH = unit * 5
            let legendRowW = legendBounds.width - unit * 2
            let legendRowY = (0..<3).map { legendBounds.height - legendRowH * CGFloat($0 + 1) - unit * CGFloat($0) }
            
            let leg1 = NSTextField(labelWithString: "⚡ Charging\nCells accepting current")
            leg1.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg1.cell?.wraps = true
            leg1.lineBreakMode = .byWordWrapping
            leg1.maximumNumberOfLines = 2
            leg1.frame = NSRect(x: unit, y: legendRowY[0], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg1)
            
            let leg2 = NSTextField(labelWithString: "🔌 AC Pass-Through\nWall power hold, 0 W")
            leg2.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg2.cell?.wraps = true
            leg2.lineBreakMode = .byWordWrapping
            leg2.maximumNumberOfLines = 2
            leg2.frame = NSRect(x: unit, y: legendRowY[1], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg2)
            
            let leg3 = NSTextField(labelWithString: "🔋 On Battery\nAdapter disconnected")
            leg3.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg3.cell?.wraps = true
            leg3.lineBreakMode = .byWordWrapping
            leg3.maximumNumberOfLines = 2
            leg3.frame = NSRect(x: unit, y: legendRowY[2], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg3)
            
            let cfg = ConfigManager.shared.load()
            let capH = unit * 4
            let sliderH = unit * 5
            let tierH = unit * 3
            let checkH = unit * 4
            let updateH = unit * 16
            let buttonH = unit * 5
            let applyW = unit * 16
            var down = columnTop
            down -= capH
            let capTitleY = down
            down -= unit * 5 + sliderH
            let sliderY = down
            down -= unit * 3 + tierH
            let tierY = down
            down -= unit * 5 + checkH
            let driftY = down
            down -= unit * 3 + checkH
            let loginY = down
            down -= unit * 5 + updateH
            let updateY = down
            down -= unit * 5 + buttonH
            let buttonY = down
            
            let sliderTitle = NSTextField(labelWithString: "Target")
            sliderTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            sliderTitle.lineBreakMode = .byTruncatingTail
            sliderTitle.frame = NSRect(x: controlX, y: capTitleY, width: controlW - unit * 11, height: capH)
            content.addSubview(sliderTitle)
            
            let valLabel = NSTextField(labelWithString: "\(cfg.targetLimit)%")
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            valLabel.frame = NSRect(x: controlX + controlW - unit * 10, y: capTitleY, width: unit * 10, height: capH)
            valLabel.alignment = .right
            content.addSubview(valLabel)
            self.limitValueLabel = valLabel
            
            let slider = NSSlider(value: Double(max(30, min(100, cfg.targetLimit))), minValue: 30, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
            slider.frame = NSRect(x: controlX, y: sliderY, width: controlW - applyW - gutter, height: sliderH)
            slider.numberOfTickMarks = 8
            slider.allowsTickMarkValuesOnly = false
            content.addSubview(slider)
            self.limitSlider = slider
            
            let applyBtn = NSButton(title: "Apply", target: self, action: #selector(applySliderLimit))
            applyBtn.bezelStyle = .rounded
            applyBtn.controlSize = .small
            applyBtn.frame = NSRect(x: controlX + controlW - applyW, y: sliderY, width: applyW, height: sliderH)
            content.addSubview(applyBtn)
            
            let tierGuideLabel = NSTextField(labelWithString: "30% floor   ·   50% daily   ·   80% health   ·   100% full")
            tierGuideLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            tierGuideLabel.textColor = .secondaryLabelColor
            tierGuideLabel.lineBreakMode = .byTruncatingTail
            tierGuideLabel.frame = NSRect(x: controlX, y: tierY, width: controlW, height: tierH)
            content.addSubview(tierGuideLabel)
            
            let driftCheck = NSButton(checkboxWithTitle: "Drift margin (−3%), avoids micro-cycling", target: self, action: #selector(toggleDriftCheckbox(_:)))
            driftCheck.state = cfg.driftEnabled ? .on : .off
            driftCheck.controlSize = .small
            driftCheck.frame = NSRect(x: controlX, y: driftY, width: controlW, height: checkH)
            content.addSubview(driftCheck)
            self.driftCheckbox = driftCheck
            
            let loginCheck = NSButton(checkboxWithTitle: "Show the menu bar icon at login", target: self, action: #selector(toggleLaunchAtLogin))
            loginCheck.state = isLaunchAtLoginEnabled() ? .on : .off
            loginCheck.controlSize = .small
            loginCheck.frame = NSRect(x: controlX, y: loginY, width: controlW, height: checkH)
            content.addSubview(loginCheck)
            self.loginCheckbox = loginCheck
            
            let uBox = NSBox(frame: NSRect(x: controlX, y: updateY, width: controlW, height: updateH))
            uBox.title = "Software Updates"
            uBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(uBox)
            self.updateBox = uBox
            let updateBounds = uBox.contentView?.bounds ?? .zero
            let updateBtnW = unit * 20
            
            let uLabel = NSTextField(labelWithString: "ChargePlan v\(ChargePlanVersion)")
            uLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            uLabel.lineBreakMode = .byTruncatingTail
            uLabel.frame = NSRect(x: unit, y: updateBounds.height - unit * 5, width: updateBounds.width - updateBtnW - unit * 3, height: unit * 4)
            uBox.contentView?.addSubview(uLabel)
            self.updateLabel = uLabel
            
            let uSub = NSTextField(labelWithString: "You are on the latest version.")
            uSub.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            uSub.textColor = .secondaryLabelColor
            uSub.lineBreakMode = .byTruncatingTail
            uSub.frame = NSRect(x: unit, y: unit * 2, width: updateBounds.width - updateBtnW - unit * 3, height: unit * 4)
            uBox.contentView?.addSubview(uSub)
            self.updateSubLabel = uSub
            
            let uBtn = NSButton(title: "Check Updates", target: self, action: #selector(updateActionButtonClicked))
            uBtn.bezelStyle = .rounded
            uBtn.controlSize = .small
            uBtn.frame = NSRect(x: updateBounds.width - updateBtnW - unit, y: unit * 3, width: updateBtnW, height: unit * 6)
            uBox.contentView?.addSubview(uBtn)
            self.updateActionButton = uBtn
            
            let buttonW = (controlW - gutter) / 2
            let installBtn = NSButton(title: "Install Daemon", target: self, action: #selector(installDaemonAction))
            installBtn.bezelStyle = .rounded
            installBtn.controlSize = .small
            installBtn.frame = NSRect(x: controlX, y: buttonY, width: buttonW, height: buttonH)
            content.addSubview(installBtn)
            self.installDaemonButton = installBtn
            
            let uninstallBtn = NSButton(title: "Uninstall Daemon", target: self, action: #selector(uninstallDaemonAction))
            uninstallBtn.bezelStyle = .rounded
            uninstallBtn.controlSize = .small
            uninstallBtn.frame = NSRect(x: controlX + buttonW + gutter, y: buttonY, width: buttonW, height: buttonH)
            content.addSubview(uninstallBtn)
            self.uninstallDaemonButton = uninstallBtn
            
            self.settingsWindow = win
        }
        
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        refreshSettingsWindow()
        placeSettingsWindowOnScreen()
        startFastTelemetryTimer()
    }
    
    private func isDaemonBinaryUpToDate(runningDaemonVersion: String? = nil) -> Bool {
        if let runningVer = runningDaemonVersion {
            return UpdateChecker.compareVersion(runningVer, ChargePlanVersion) != .orderedAscending
        }
        
        let installed = FileManager.default.isExecutableFile(atPath: ChargePlanLayout.daemonBinary)
            ? ChargePlanLayout.daemonBinary
            : ChargePlanLayout.cliBinary
        guard FileManager.default.isExecutableFile(atPath: installed) else {
            return false
        }
        
        let result = Shell.run(installed, ["version"])
        guard result.exitCode == 0 else { return false }
        let parts = result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard let ver = parts.last, !ver.isEmpty else { return false }
        return UpdateChecker.compareVersion(ver, ChargePlanVersion) != .orderedAscending
    }
    
    private func autoSyncDaemonIfNeeded() {
        guard !isAutoSyncingDaemon else { return }
        if lastAutoSyncAttempt != .distantPast, Date().timeIntervalSince(lastAutoSyncAttempt) < 60 {
            return
        }
        let daemonInfo = fetchDaemonStatus()
        guard daemonInfo.running else { return }
        let upToDate = isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version)
        guard !upToDate else { return }
        
        isAutoSyncingDaemon = true
        lastAutoSyncAttempt = Date()
        let bundled = bundledCLIBinaryPath()
        
        // Socket UPGRADE only. An older daemon that rejects it stays on the
        // explicit "Update Background Daemon" menu item, which the user chooses.
        Task.detached { [weak self] in
            let response = UnixSocketClient.send("UPGRADE \(bundled)")
            let ok = UnixSocketClient.isSuccess(response)
            if ok {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAutoSyncingDaemon = false
                if ok {
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                }
            }
        }
    }
    
    private func refreshSettingsWindow() {
        guard let win = settingsWindow, win.isVisible, !win.isMiniaturized else { return }
        let status = monitor.getCurrentStatus()
        let cfg = ConfigManager.shared.load()
        let daemonInfo = fetchDaemonStatus()
        let daemonActive = daemonInfo.running
        let upToDate = isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version)
        let govMode = daemonInfo.mode
        
        if let notice = controlNotice, Date() < controlNoticeUntil {
            governorLabel?.stringValue = notice
            governorLabel?.textColor = .systemRed
        } else {
            controlNotice = nil
            governorLabel?.stringValue = "Control Mode: \(govMode)"
            governorLabel?.textColor = .labelColor
        }
        
        if daemonActive && upToDate {
            daemonBadgeLabel?.stringValue = "✅ Background Controller Daemon Active & Running"
            daemonBadgeLabel?.textColor = .systemGreen
            installDaemonButton?.title = "Restart Daemon"
        } else if daemonActive && !upToDate {
            if isAutoSyncingDaemon {
                daemonBadgeLabel?.stringValue = "⚡ Automatically Updating Background Daemon…"
                daemonBadgeLabel?.textColor = .systemBlue
                installDaemonButton?.title = "Updating Daemon…"
            } else {
                daemonBadgeLabel?.stringValue = "⚠️ Daemon Update Available — Auto-updating…"
                daemonBadgeLabel?.textColor = .systemOrange
                installDaemonButton?.title = "Update Daemon"
            }
        } else {
            daemonBadgeLabel?.stringValue = "⚠️ Background Daemon Not Running — Click 'Install Background Daemon' below"
            daemonBadgeLabel?.textColor = .systemOrange
            installDaemonButton?.title = "Install Daemon"
        }
        
        if let energy = status.energyWattHours {
            energyLabel?.stringValue = String(format: "%.1f Wh / %.1f Wh", energy.remaining, energy.total)
        } else {
            energyLabel?.stringValue = "— Wh"
        }
        
        let stateStr = status.isCharging ? "⚡ Charging" : (status.isACConnected ? "🔌 AC Connected (Not Charging)" : "🔋 On Battery")
        let pctStr = String(format: "%.2f%%", status.exactPercent)
        batteryLabel?.stringValue = "Battery: \(pctStr) (\(stateStr))  •  Target: \(cfg.targetLimit)%  •  Live (1s poll)"
        let capText = status.remainingCapacityMAh > 0 ? "Capacity: \(status.remainingCapacityMAh) / \(status.fullChargeCapacityMAh) mAh • " : ""
        telemetryLabel?.stringValue = String(format: "%.2fW (%d mV, %d mA) • %@Health: %.1f%% (%d cycles) • %@", abs(status.wattageW), status.voltageMV, status.amperageMA, capText, status.healthPercent, status.cycleCount, status.thermalState)
        
        if !status.cellVoltagesMV.isEmpty {
            let cellsStr = status.cellVoltagesMV.map { String(format: "%.3fV", Double($0) / 1000.0) }.joined(separator: "  •  ")
            let deltaStr = status.cellImbalanceMV != nil ? "  (Δ \(status.cellImbalanceMV!) mV balance)" : ""
            let tempStr = status.temperatureC != nil ? String(format: "  •  Temp: %.1f°C (%.1f°F)", status.temperatureC!, status.temperatureC! * 9.0 / 5.0 + 32.0) : ""
            cellLabel?.stringValue = "Cells: \(cellsStr)\(deltaStr)\(tempStr)"
        } else if let temp = status.temperatureC {
            cellLabel?.stringValue = String(format: "Battery Pack Temperature: %.1f°C (%.1f°F)", temp, temp * 9.0 / 5.0 + 32.0)
        } else {
            cellLabel?.stringValue = ""
        }
        
        batteryGraphView.addSample(percent: status.exactPercent, targetLimit: cfg.targetLimit, isCharging: status.isCharging)
        
        driftCheckbox?.state = cfg.driftEnabled ? .on : .off
        loginCheckbox?.state = isLaunchAtLoginEnabled() ? .on : .off
        uninstallDaemonButton?.isEnabled = daemonActive
        
        // Update software updates section
        if isUpdatingApp {
            updateLabel?.stringValue = "⚡ Updating ChargePlan…"
            updateLabel?.textColor = .systemBlue
            updateSubLabel?.stringValue = updateStatusText
            updateActionButton?.title = "Updating…"
            updateActionButton?.isEnabled = false
        } else if let rel = latestRelease, UpdateChecker.isVersion(rel.version, newerThan: ChargePlanVersion) {
            updateLabel?.stringValue = "🎉 Update Available: \(rel.tagName)"
            updateLabel?.textColor = .systemOrange
            updateSubLabel?.stringValue = updateStatusText.isEmpty ? "New version ready to install." : updateStatusText
            updateActionButton?.title = "Update Now"
            updateActionButton?.isEnabled = true
        } else {
            updateLabel?.stringValue = "✓ ChargePlan v\(ChargePlanVersion) (Latest)"
            updateLabel?.textColor = .systemGreen
            updateSubLabel?.stringValue = updateStatusText.isEmpty ? "Up to date (Checked automatically)." : updateStatusText
            updateActionButton?.title = "Check Updates"
            updateActionButton?.isEnabled = true
        }
    }
    
    @objc private func sliderChanged(_ sender: NSSlider) {
        let rounded = Int((sender.doubleValue / 5.0).rounded()) * 5
        let clamped = max(30, min(100, rounded))
        sender.integerValue = clamped
        limitValueLabel?.stringValue = "\(clamped)%"
    }
    
    @objc private func applySliderLimit() {
        let val = limitSlider?.integerValue ?? 50
        applyLimit(val)
    }
    
    @objc private func selectPresetLimit(_ sender: NSMenuItem) {
        applyLimit(sender.tag)
    }
    
    @objc private func selectDriftOption(_ sender: NSMenuItem) {
        let margin = sender.tag
        let cmd = margin > 0 ? "DRIFT on \(margin)" : "DRIFT off"
        sendControl(cmd, failure: "Drift was not changed.")
    }
    
    @objc private func toggleDriftCheckbox(_ sender: NSButton) {
        let on = (sender.state == .on)
        let cmd = "DRIFT \(on ? "on 3" : "off")"
        sendControl(cmd, failure: "Drift was not changed.")
    }
    
    /// Menu presets and the settings slider talk only to the running daemon.
    /// Install and uninstall still ask for an administrator when the user chooses them.
    private func applyLimit(_ limit: Int) {
        let clamped = max(30, min(100, limit))
        limitSlider?.integerValue = clamped
        limitValueLabel?.stringValue = "\(clamped)%"
        sendControl("SET \(clamped)", failure: "Target was not changed.")
    }

    private func sendControl(_ command: String, failure: String) {
        Task.detached { [weak self] in
            let response = UnixSocketClient.send(command)
            let ok = UnixSocketClient.isSuccess(response)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.controlNotice = nil
                } else {
                    self.controlNotice = "The background controller did not accept the change. \(failure)"
                    self.controlNoticeUntil = Date().addingTimeInterval(6)
                }
                self.rebuildMenu()
                self.refreshSettingsWindow()
            }
        }
    }
    
    private func bundledCLIBinaryPath() -> String {
        if let resPath = Bundle.main.resourcePath {
            let candidate = "\(resPath)/chargeplan"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return ChargePlanLayout.cliBinary
    }
    
    @objc private func installDaemonAction() {
        let bundled = bundledCLIBinaryPath()
        let daemonBin = ChargePlanLayout.daemonBinary
        let cliBin = ChargePlanLayout.cliBinary
        let cmd = "mkdir -p \(ChargePlanLayout.cliDirectory) '\(ChargePlanLayout.supportDirectory)' && install -m 755 '\(bundled)' '\(daemonBin)' && install -m 755 '\(bundled)' \(cliBin) && xattr -cr '\(daemonBin)' \(cliBin) 2>/dev/null || true && codesign --force --sign - '\(daemonBin)' \(cliBin) 2>/dev/null || true && \(cliBin) install"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
        
        Thread.sleep(forTimeInterval: 0.5)
        rebuildMenu()
        refreshSettingsWindow()
    }
    
    @objc private func uninstallDaemonAction() {
        let cmd = "\(ChargePlanLayout.cliBinary) uninstall && rm -rf '\(ChargePlanLayout.supportDirectory)' '\(ChargePlanLayout.legacySupportDirectory)' \(ChargePlanLayout.cliBinary) \(ChargePlanLayout.socketPath) \(ChargePlanLayout.legacySocketPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
        
        rebuildMenu()
        refreshSettingsWindow()
    }
    
    private func isLaunchAtLoginEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentPath)
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let parent = (launchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let execPath = Bundle.main.executablePath ?? "\(ChargePlanLayout.appBundle)/Contents/MacOS/ChargePlanApp"
            let plist = ChargePlanLayout.appLaunchAgentXML(executable: execPath)
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(atPath: launchAgentPath)
        }
    }
    
    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled())
        rebuildMenu()
        refreshSettingsWindow()
    }
    
    private func checkUpdateSilently(force: Bool = false) async {
        if let info = await UpdateChecker.checkForUpdate(currentVersion: ChargePlanVersion, force: force) {
            await MainActor.run {
                self.latestRelease = info
                self.rebuildMenu()
                self.refreshSettingsWindow()
            }
        }
    }
    
    @objc private func updateActionButtonClicked() {
        if let release = latestRelease, UpdateChecker.isVersion(release.version, newerThan: ChargePlanVersion) {
            triggerAppUpdate()
        } else {
            manualCheckUpdate()
        }
    }
    
    @objc private func triggerAppUpdate() {
        showSettingsWindow()
        guard let release = latestRelease, UpdateChecker.isVersion(release.version, newerThan: ChargePlanVersion) else { return }
        guard let dmgUrl = URL(string: release.dmgUrl) else { return }
        
        isUpdatingApp = true
        updateStatusText = "Downloading update disk image…"
        refreshSettingsWindow()
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: true) { [weak self] step in
                    Task { @MainActor in
                        self?.updateStatusText = step
                        self?.refreshSettingsWindow()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isUpdatingApp = false
                    self.updateStatusText = "Update failed: \(error.localizedDescription)"
                    self.refreshSettingsWindow()
                }
            }
        }
    }
    
    @objc private func menuCheckForUpdates() {
        manualCheckUpdate(showAlertIfUpToDate: true)
    }
    
    @objc private func manualCheckUpdate() {
        manualCheckUpdate(showAlertIfUpToDate: true)
    }
    
    private func manualCheckUpdate(showAlertIfUpToDate: Bool = false) {
        updateStatusText = "Checking GitHub…"
        updateActionButton?.isEnabled = false
        refreshSettingsWindow()
        Task {
            let info = await UpdateChecker.checkForUpdate(currentVersion: ChargePlanVersion, force: true)
            await MainActor.run {
                self.latestRelease = info
                self.updateActionButton?.isEnabled = true
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                let timeStr = formatter.string(from: Date())
                
                if let inf = info, UpdateChecker.isVersion(inf.version, newerThan: ChargePlanVersion) {
                    self.updateStatusText = "New release found: \(inf.tagName)"
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                    self.showSettingsWindow()
                } else {
                    self.updateStatusText = "✓ Up to date (checked at \(timeStr))"
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                    if showAlertIfUpToDate {
                        let alert = NSAlert()
                        alert.messageText = "ChargePlan is Up to Date"
                        alert.informativeText = "Version \(ChargePlanVersion) is currently the newest version available."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    // MARK: - NSWindowDelegate & Fast Telemetry
    func windowDidBecomeKey(_ notification: Notification) {
        startFastTelemetryTimer()
    }
    
    func windowWillClose(_ notification: Notification) {
        stopFastTelemetryTimer()
    }
    
    func windowDidMiniaturize(_ notification: Notification) {
        stopFastTelemetryTimer()
    }
    
    func windowDidDeminiaturize(_ notification: Notification) {
        startFastTelemetryTimer()
    }
    
    private func startFastTelemetryTimer() {
        guard windowTelemetryTimer == nil else { return }
        refreshSettingsWindow()
        windowTelemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let win = self.settingsWindow, win.isVisible, !win.isMiniaturized else {
                    self?.stopFastTelemetryTimer()
                    return
                }
                self.refreshSettingsWindow()
                self.updateMenuBarTitleOnly()
            }
        }
    }
    
    private func stopFastTelemetryTimer() {
        windowTelemetryTimer?.invalidate()
        windowTelemetryTimer = nil
    }
    
    private func menuBarSymbol(for status: BatteryStatus) -> String {
        if status.isCharging || status.amperageMA > 50 {
            return "⚡"
        }
        if status.isACConnected {
            return "🔌"
        }
        return "🔋"
    }
    
    private func updateMenuBarTitleOnly() {
        let status = monitor.getCurrentStatus()
        let cfg = ConfigManager.shared.load()
        let iconPrefix = menuBarSymbol(for: status)
        statusItem.button?.title = "\(iconPrefix) \(status.percent)% → \(cfg.targetLimit)%"
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ChargePlanAppDelegate() }
app.delegate = delegate
app.run()
