import Foundation
import AppKit

public final class EmojiCustomizationController: NSWindowController, @unchecked Sendable {
    public static let shared = EmojiCustomizationController()

    private var windowInstance: NSWindow?
    private var textFields: [String: NSTextField] = [:]
    private var errorLabel: NSTextField?

    public struct StateItem: Sendable {
        public let key: String
        public let label: String
        public let defaultEmoji: String
        public let getCurrent: @Sendable (StatusBadgesConfig) -> String

        public init(key: String, label: String, defaultEmoji: String, getCurrent: @escaping @Sendable (StatusBadgesConfig) -> String) {
            self.key = key
            self.label = label
            self.defaultEmoji = defaultEmoji
            self.getCurrent = getCurrent
        }
    }

    public let stateItems: [StateItem] = [
        StateItem(key: "done", label: "Done / Complete", defaultEmoji: "🐶", getCurrent: { $0.done.funEmoji }),
        StateItem(key: "working", label: "Working / Thinking", defaultEmoji: "🤔", getCurrent: { $0.working.funEmoji }),
        StateItem(key: "blocked", label: "Needs You / Blocked", defaultEmoji: "🥶", getCurrent: { $0.blocked.funEmoji }),
        StateItem(key: "overworking", label: "Overworking (> threshold)", defaultEmoji: "🥵", getCurrent: { $0.overworking?.funEmoji ?? "🥵" }),
        StateItem(key: "idle", label: "Idle / Standby", defaultEmoji: "🫥", getCurrent: { $0.idle.funEmoji }),
        StateItem(key: "off", label: "Closed / Off", defaultEmoji: "😴", getCurrent: { $0.off.funEmoji }),
        StateItem(key: "quotaExhausted", label: "Quota Exhausted", defaultEmoji: "🤯", getCurrent: { $0.quotaDepleted?.funEmoji ?? "🤯" }),
        StateItem(key: "quotaRestored", label: "Quota Restored", defaultEmoji: "🥱", getCurrent: { $0.quotaRestored?.funEmoji ?? "🥱" }),
        StateItem(key: "monitorUnavailable", label: "Monitor Not Connected", defaultEmoji: "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}", getCurrent: { $0.monitorUnavailable?.funEmoji ?? "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}" })
    ]

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public static func isValidSingleEmoji(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else { return false }
        guard let firstChar = trimmed.first else { return false }
        let hasEmojiScalar = firstChar.unicodeScalars.contains { scalar in
            scalar.properties.isEmoji || scalar.properties.isEmojiPresentation || scalar.value > 0x2000
        }
        if firstChar.isASCII && !firstChar.isSymbol {
            return false
        }
        return hasEmojiScalar
    }

    public func showWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let existingWindow = self.windowInstance {
                self.populateCurrentValues()
                self.errorLabel?.stringValue = ""
                self.errorLabel?.isHidden = true
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let panelWidth: CGFloat = 430
            let panelHeight: CGFloat = 480
            let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

            let panel = NSPanel(
                contentRect: rect,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Customize Emoji — AgentBridge"
            panel.center()
            panel.isReleasedWhenClosed = false

            let contentView = NSView(frame: rect)
            panel.contentView = contentView

            // Main vertical stack
            let mainStack = NSStackView(frame: NSRect(x: 20, y: 20, width: panelWidth - 40, height: panelHeight - 40))
            mainStack.orientation = .vertical
            mainStack.alignment = .leading
            mainStack.spacing = 8
            mainStack.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(mainStack)

            NSLayoutConstraint.activate([
                mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
                mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
            ])

            // Header title
            let headerLabel = NSTextField(labelWithString: "Customize Status Emoji:")
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
                tf.isEditable = true
                tf.isSelectable = true

                self.textFields[item.key] = tf
                rowStack.addArrangedSubview(tf)

                gridStack.addArrangedSubview(rowStack)
            }

            // Error label for validation feedback
            let errLbl = NSTextField(labelWithString: "")
            errLbl.font = NSFont.systemFont(ofSize: 11)
            errLbl.textColor = .systemRed
            errLbl.isHidden = true
            self.errorLabel = errLbl
            mainStack.addArrangedSubview(errLbl)

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

    public func getTextField(for key: String) -> NSTextField? {
        return textFields[key]
    }

    public func populateCurrentValues() {
        let currentBadges = ConfigManager.shared.config.statusBadges
        for item in stateItems {
            let val = item.getCurrent(currentBadges)
            textFields[item.key]?.stringValue = val
        }
    }

    @objc public func resetButtonClicked() {
        for item in stateItems {
            textFields[item.key]?.stringValue = item.defaultEmoji
        }
        errorLabel?.stringValue = ""
        errorLabel?.isHidden = true
    }

    @objc public func cancelButtonClicked() {
        windowInstance?.close()
    }

    @objc public func saveButtonClicked() {
        var cfg = ConfigManager.shared.config
        var badges = cfg.statusBadges

        // 1. Validation pass: every field must contain exactly 1 valid emoji
        for item in stateItems {
            guard let rawUserVal = textFields[item.key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !rawUserVal.isEmpty else {
                errorLabel?.stringValue = "Error: '\(item.label)' cannot be empty."
                errorLabel?.isHidden = false
                return
            }

            guard Self.isValidSingleEmoji(rawUserVal) else {
                errorLabel?.stringValue = "Error: '\(item.label)' must be exactly 1 emoji."
                errorLabel?.isHidden = false
                return
            }
        }

        errorLabel?.stringValue = ""
        errorLabel?.isHidden = true

        // 2. Application pass: commit verified values
        for item in stateItems {
            let finalVal = textFields[item.key]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

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
                    badges.quotaDepleted = StatusBadgeItem(classic: "⛔", funEmoji: finalVal)
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
