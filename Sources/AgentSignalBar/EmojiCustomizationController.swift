import Foundation
import AppKit

public final class EmojiCustomizationController: NSWindowController, @unchecked Sendable {
    public static let shared = EmojiCustomizationController()

    private var windowInstance: NSWindow?
    private var textFields: [String: NSTextField] = [:]

    private struct StateItem {
        let key: String
        let label: String
        let defaultEmoji: String
        let getCurrent: (StatusBadgesConfig) -> String
    }

    private let stateItems: [StateItem] = [
        StateItem(key: "done", label: "Done / Complete", defaultEmoji: "🐶", getCurrent: { $0.done.funEmoji }),
        StateItem(key: "working", label: "Working / Thinking", defaultEmoji: "🤔", getCurrent: { $0.working.funEmoji }),
        StateItem(key: "blocked", label: "Needs You / Blocked", defaultEmoji: "🥶", getCurrent: { $0.blocked.funEmoji }),
        StateItem(key: "overworking", label: "Overworking (> threshold)", defaultEmoji: "🥵", getCurrent: { $0.overworking?.funEmoji ?? "🥵" }),
        StateItem(key: "idle", label: "Idle / Standby", defaultEmoji: "🫥", getCurrent: { $0.idle.funEmoji }),
        StateItem(key: "off", label: "Closed / Off", defaultEmoji: "😴", getCurrent: { $0.off.funEmoji }),
        StateItem(key: "quotaExhausted", label: "Quota Exhausted", defaultEmoji: "🤯", getCurrent: { $0.quotaDepleted?.funEmoji ?? "🤯" }),
        StateItem(key: "quotaRestored", label: "Quota Restored", defaultEmoji: "🥱", getCurrent: { $0.quotaRestored?.funEmoji ?? "🥱" }),
        StateItem(key: "monitorUnavailable", label: "Monitor Not Connected", defaultEmoji: "😶🌫️", getCurrent: { $0.monitorUnavailable?.funEmoji ?? "😶🌫️" })
    ]

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let existingWindow = self.windowInstance {
                self.populateCurrentValues()
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let panelWidth: CGFloat = 420
            let panelHeight: CGFloat = 460
            let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

            let panel = NSPanel(
                contentRect: rect,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Customize Status Emoji — AgentBridge"
            panel.center()
            panel.isReleasedWhenClosed = false

            let contentView = NSView(frame: rect)
            panel.contentView = contentView

            // Main vertical stack
            let mainStack = NSStackView(frame: NSRect(x: 20, y: 20, width: panelWidth - 40, height: panelHeight - 40))
            mainStack.orientation = .vertical
            mainStack.alignment = .leading
            mainStack.spacing = 10
            mainStack.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(mainStack)

            NSLayoutConstraint.activate([
                mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
                mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
            ])

            // Header title
            let headerLabel = NSTextField(labelWithString: "Customize Fun Emoji badges for each status:")
            headerLabel.font = NSFont.boldSystemFont(ofSize: 13)
            mainStack.addArrangedSubview(headerLabel)

            // Grid for the 9 states
            let gridStack = NSStackView()
            gridStack.orientation = .vertical
            gridStack.alignment = .leading
            gridStack.spacing = 6
            gridStack.translatesAutoresizingMaskIntoConstraints = false
            mainStack.addArrangedSubview(gridStack)

            self.textFields.removeAll()

            for item in self.stateItems {
                let rowStack = NSStackView()
                rowStack.orientation = .horizontal
                rowStack.spacing = 12
                rowStack.alignment = .centerY

                let label = NSTextField(labelWithString: item.label)
                label.font = NSFont.systemFont(ofSize: 12)
                label.widthAnchor.constraint(equalToConstant: 220).isActive = true
                rowStack.addArrangedSubview(label)

                let tf = NSTextField(string: "")
                tf.font = NSFont.systemFont(ofSize: 14)
                tf.alignment = .center
                tf.widthAnchor.constraint(equalToConstant: 60).isActive = true
                tf.heightAnchor.constraint(equalToConstant: 24).isActive = true
                rowStack.addArrangedSubview(tf)

                self.textFields[item.key] = tf
                gridStack.addArrangedSubview(rowStack)
            }

            self.populateCurrentValues()

            // Spacer
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            mainStack.addArrangedSubview(spacer)

            // Bottom action buttons
            let buttonStack = NSStackView()
            buttonStack.orientation = .horizontal
            buttonStack.spacing = 12
            buttonStack.alignment = .centerY

            let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(self.resetButtonClicked))
            buttonStack.addArrangedSubview(resetButton)

            let buttonSpacer = NSView()
            buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            buttonStack.addArrangedSubview(buttonSpacer)

            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(self.cancelButtonClicked))
            buttonStack.addArrangedSubview(cancelButton)

            let saveButton = NSButton(title: "Save & Apply", target: self, action: #selector(self.saveButtonClicked))
            saveButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(saveButton)

            mainStack.addArrangedSubview(buttonStack)
            buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

            self.windowInstance = panel
            self.window = panel
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func populateCurrentValues() {
        let currentBadges = ConfigManager.shared.config.statusBadges
        for item in stateItems {
            let val = item.getCurrent(currentBadges)
            textFields[item.key]?.stringValue = val
        }
    }

    @objc private func resetButtonClicked() {
        for item in stateItems {
            textFields[item.key]?.stringValue = item.defaultEmoji
        }
    }

    @objc private func cancelButtonClicked() {
        windowInstance?.close()
    }

    @objc private func saveButtonClicked() {
        var cfg = ConfigManager.shared.config
        var badges = cfg.statusBadges

        for item in stateItems {
            let userVal = textFields[item.key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalVal = userVal.isEmpty ? item.defaultEmoji : userVal

            switch item.key {
            case "done":
                badges.done.funEmoji = finalVal
            case "working":
                badges.working.funEmoji = finalVal
            case "blocked":
                badges.blocked.funEmoji = finalVal
            case "overworking":
                if badges.overworking != nil {
                    badges.overworking?.funEmoji = finalVal
                } else {
                    badges.overworking = StatusBadgeItem(classic: "🟡", funEmoji: finalVal)
                }
            case "idle":
                badges.idle.funEmoji = finalVal
            case "off":
                badges.off.funEmoji = finalVal
            case "quotaExhausted":
                if badges.quotaDepleted != nil {
                    badges.quotaDepleted?.funEmoji = finalVal
                } else {
                    badges.quotaDepleted = StatusBadgeItem(classic: "⦸", funEmoji: finalVal)
                }
            case "quotaRestored":
                if badges.quotaRestored != nil {
                    badges.quotaRestored?.funEmoji = finalVal
                } else {
                    badges.quotaRestored = StatusBadgeItem(classic: "⚪", funEmoji: finalVal)
                }
            case "monitorUnavailable":
                if badges.monitorUnavailable != nil {
                    badges.monitorUnavailable?.funEmoji = finalVal
                } else {
                    badges.monitorUnavailable = StatusBadgeItem(classic: "⚠️", funEmoji: finalVal)
                }
            default:
                break
            }
        }

        cfg.statusBadges = badges
        ConfigManager.shared.saveConfig(cfg)
        print("🎨 Status Emoji configuration saved successfully!")
        MenuBarManager.shared.updateTitleAndMenu()
        windowInstance?.close()
    }
}
