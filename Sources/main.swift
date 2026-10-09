import AppKit
import ApplicationServices
import Carbon
import UniformTypeIdentifiers
import ServiceManagement

// 范围边界（不变）：只读写"目标应用当前焦点输入框"里你自己的草稿。
// 不遍历界面、不抓聊天记录、不读非焦点控件。CGEventTap 只对"目标应用前台 +
// 焦点为文本框 + 不带修饰键的回车"动作；其它按键一律原样放行，不记录不处理。
// 润色链路把你自己的草稿发给你配置的 Jev / OpenAI 接口（用你自己的 token）。
func axDescription(_ error: AXError) -> String {
    let name: String
    switch error {
    case .success: name = "success"
    case .failure: name = "failure"
    case .illegalArgument: name = "illegalArgument"
    case .invalidUIElement: name = L("invalidUIElement（控件已失效）")
    case .invalidUIElementObserver: name = "invalidUIElementObserver"
    case .cannotComplete: name = L("cannotComplete（应用无响应或 AX 通信失败）")
    case .attributeUnsupported: name = "attributeUnsupported"
    case .actionUnsupported: name = "actionUnsupported"
    case .notificationUnsupported: name = "notificationUnsupported"
    case .notImplemented: name = "notImplemented"
    case .notificationAlreadyRegistered: name = "notificationAlreadyRegistered"
    case .notificationNotRegistered: name = "notificationNotRegistered"
    case .apiDisabled: name = L("apiDisabled（检查辅助功能权限）")
    case .noValue: name = "noValue"
    case .parameterizedAttributeUnsupported: name = "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: name = "notEnoughPrecision"
    @unknown default: name = "unknown"
    }
    return "\(name) [\(error.rawValue)]"
}
func copyValue(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else { throw ProbeError("\(attribute): \(axDescription(error))") }
    guard let result = value else { throw ProbeError(L("%1$@: success 但返回空值", attribute)) }
    return result
}
func elementValue(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement {
    let value = try copyValue(element, attribute)
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
        throw ProbeError(L("%1$@: 返回类型不是 AXUIElement", attribute))
    }
    return value as! AXUIElement
}
func stringValue(_ element: AXUIElement, _ attribute: String) throws -> String {
    let value = try copyValue(element, attribute)
    guard let text = value as? String else { throw ProbeError(L("%1$@: 不是字符串；不做推测或转换", attribute)) }
    return text
}
struct Target {
    let pid: pid_t
    let application: AXUIElement
    let element: AXUIElement
    let window: AXUIElement
    let role: String
    let subrole: String
}

final class ApplicationDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private let label = NSTextField(wrappingLabelWithString: L("将一个或多个应用从“应用程序”拖到这里"))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains(where: { $0.pathExtension.lowercased() == "app" }) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
let defaultJevURL = "https://api.typesafe.ai/v1/systemone"
let defaultJevModel = "jev-latest"
var defaultJevPrompt: String { L("这段即将发送的草稿是否需要润色？语气生硬、表达不通顺、有明显口误或错别字算需要；已经通顺得体，或只是很短的确认，算不需要。") }
var defaultOAPrompt: String { L("你是文字润色助手。保持原文语言，在不改变原意、不添加新信息的前提下，让这段话更通顺、得体。只输出润色后的文本本身，不要加引号或任何解释。") }

// 目标应用、Jev、OpenAI 的配置集中在一个面板里填写。
final class SettingsController: NSObject {
    private struct Spec {
        let key: String
        let title: String
        let fallback: String
        let placeholder: String
        let multiline: Bool
    }
    private var sections: [(title: String, hint: String, fields: [Spec])] { [
        (
            "Jev",
            L("可选。开启后先判断是否需要润色；关闭后每次都调用润色接口。"),
            [
                Spec(key: SettingKey.jevURL, title: L("接口地址"), fallback: defaultJevURL, placeholder: defaultJevURL, multiline: false),
                Spec(key: SettingKey.jevToken, title: "Token", fallback: "", placeholder: "Authorization: Bearer", multiline: false),
                Spec(key: SettingKey.jevModel, title: L("模型"), fallback: defaultJevModel, placeholder: defaultJevModel, multiline: false),
                Spec(key: SettingKey.jevPrompt, title: L("判断规则提示词"), fallback: defaultJevPrompt, placeholder: "", multiline: true)
            ]
        ),
        (
            L("润色接口"),
            L("填写兼容 Chat Completions 的接口地址；Base URL 会自动补全路径。额外参数填写 JSON 对象，stream 仅支持 false。"),
            [
                Spec(key: SettingKey.oaURL, title: L("接口地址"), fallback: "", placeholder: "https://api.example.com/v1", multiline: false),
                Spec(key: SettingKey.oaToken, title: "Token", fallback: "", placeholder: "Authorization: Bearer", multiline: false),
                Spec(key: SettingKey.oaModel, title: L("模型"), fallback: "", placeholder: L("服务商提供的模型 ID"), multiline: false),
                Spec(key: SettingKey.oaExtraParameters, title: L("额外请求参数（JSON 对象）"), fallback: "", placeholder: "", multiline: true),
                Spec(key: SettingKey.oaPrompt, title: L("润色规则提示词"), fallback: defaultOAPrompt, placeholder: "", multiline: true)
            ]
        )
    ] }
    var onImported: (() -> Void)?
    private var window: NSWindow?
    private var fields: [String: NSTextField] = [:]
    private var editors: [String: NSTextView] = [:]
    private var targetRows = NSStackView()
    private var targetApplications: [TargetApplication] = []
    private var jevCheckbox: NSButton?
    private var loginCheckbox: NSButton?
    private var languagePicker: NSPopUpButton?
    private var displayedLanguage = setting(LanguagePreference.key, "system")
    private var commandRows = NSStackView()
    private var commandFields: [(pattern: NSTextField, script: NSTextView)] = []
    private var tabView: NSTabView?

    func show(commandsTab: Bool = false) {
        if window == nil { window = makeWindow() }
        if window?.isVisible != true { loadValues() }
        if commandsTab { tabView?.selectTabViewItem(withIdentifier: "commands") }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("设置")
        window.minSize = NSSize(width: 460, height: 420)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let content = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        fill(makeHeader(L("目标应用"), L("只在列表中应用的前台输入框处理回车。")), in: stack)
        let drop = ApplicationDropView()
        drop.onDrop = { [weak self] urls in self?.addApplications(urls) }
        fill(drop, in: stack)
        drop.heightAnchor.constraint(equalToConstant: 64).isActive = true
        targetRows.orientation = .vertical
        targetRows.alignment = .leading
        targetRows.spacing = 6
        fill(targetRows, in: stack)
        for (index, section) in sections.enumerated() {
            fill(makeSeparator(), in: stack)
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 10
            fill(makeHeader(section.title, section.hint), in: block)
            if index == 0 {
                let checkbox = NSButton(checkboxWithTitle: L("启用 Jev 判断"), target: nil, action: nil)
                jevCheckbox = checkbox
                fill(checkbox, in: block)
            }
            for spec in section.fields { fill(makeField(spec), in: block) }
            fill(block, in: stack)
        }

        fill(makeSeparator(), in: stack)
        fill(makeHeader(L("界面语言"), L("保存后生效；跟随系统时自动判断语言。")), in: stack)
        let picker = NSPopUpButton()
        picker.addItems(withTitles: [L("跟随系统"), "简体中文", "English"])
        languagePicker = picker
        fill(picker, in: stack)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        scroll.documentView = container
        container.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        let docBottom = container.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        docBottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.topAnchor.constraint(equalTo: clip.topAnchor),
            container.widthAnchor.constraint(equalTo: clip.widthAnchor),
            docBottom
        ])

        let line = makeSeparator()
        line.translatesAutoresizingMaskIntoConstraints = false
        let exportButton = NSButton(title: L("导出"), target: self, action: #selector(exportToFile))
        let importButton = NSButton(title: L("导入"), target: self, action: #selector(importFromFile))
        let fileButtons = NSStackView(views: [exportButton, importButton])
        fileButtons.orientation = .horizontal
        fileButtons.spacing = 8
        fileButtons.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("保存"), target: self, action: #selector(save))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let tabs = NSTabView()
        tabView = tabs
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = L("基本设置")
        generalTab.view = scroll
        tabs.addTabViewItem(generalTab)
        let commandTab = NSTabViewItem(identifier: "commands")
        commandTab.label = L("指令配置")
        commandTab.view = makeCommandsView()
        tabs.addTabViewItem(commandTab)

        content.addSubview(tabs)
        content.addSubview(line)
        content.addSubview(fileButtons)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fileButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fileButtons.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        window.contentView = content
        window.center()
        return window
    }

    private func makeCommandsView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        fill(makeHeader(L("指令配置"), L("按顺序匹配正则。脚本是一个函数，例如 async (input) => { … }，以原始 input 调用，返回 { interrupt: boolean, replacement?: string } 或其 Promise。interrupt 为 true 时拦截回车并按需替换草稿；false 时继续正常流程。")), in: stack)
        commandRows = NSStackView()
        commandRows.orientation = .vertical
        commandRows.alignment = .leading
        commandRows.spacing = 12
        fill(commandRows, in: stack)
        let add = NSButton(title: L("添加指令"), target: self, action: #selector(addCommand))
        fill(add, in: stack)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        scroll.documentView = container
        let clip = scroll.contentView
        let bottom = container.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        bottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.topAnchor.constraint(equalTo: clip.topAnchor),
            container.widthAnchor.constraint(equalTo: clip.widthAnchor), bottom
        ])
        return scroll
    }

    @objc private func addCommand() { appendCommand(CommandRule(pattern: "^#", script: "async (input) => {\n  return { interrupt: true, replacement: input.slice(1) };\n}")) }
    private func appendCommand(_ rule: CommandRule) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        let pattern = NSTextField(string: rule.pattern)
        pattern.placeholderString = L("正则表达式，例如 ^#")
        let script = NSTextView()
        script.isRichText = false
        script.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        script.isVerticallyResizable = true
        script.isHorizontallyResizable = false
        script.autoresizingMask = [.width]
        script.textContainer?.widthTracksTextView = true
        script.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        script.string = rule.script
        let scriptScroll = NSScrollView()
        scriptScroll.hasVerticalScroller = true
        scriptScroll.borderType = .bezelBorder
        scriptScroll.documentView = script
        let remove = NSButton(title: L("删除"), target: self, action: #selector(removeCommand(_:)))
        row.addArrangedSubview(pattern)
        row.addArrangedSubview(scriptScroll)
        row.addArrangedSubview(remove)
        for view in [pattern, scriptScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        scriptScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        commandRows.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: commandRows.widthAnchor).isActive = true
        commandFields.append((pattern, script))
    }
    @objc private func removeCommand(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView,
              let index = commandRows.arrangedSubviews.firstIndex(of: row) else { return }
        commandRows.removeArrangedSubview(row)
        row.removeFromSuperview()
        commandFields.remove(at: index)
    }
    private func currentCommands() throws -> [CommandRule] {
        let rules = commandFields.map { CommandRule(pattern: $0.pattern.stringValue, script: $0.script.string) }
        _ = try decodeCommands(encodeCommands(rules))
        return rules
    }

    private func fill(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
    private func makeHeader(_ title: String, _ hint: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 480
        let group = NSStackView(views: [titleLabel, hintLabel])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    private func makeField(_ spec: Spec) -> NSView {
        let label = NSTextField(labelWithString: spec.title)
        label.font = .systemFont(ofSize: 12)
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        group.addArrangedSubview(label)
        if spec.multiline {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let textView = NSTextView()
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 13)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainerInset = NSSize(width: 2, height: 4)
            scroll.documentView = textView
            editors[spec.key] = textView
            group.addArrangedSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        } else {
            let field = NSTextField()
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = spec.placeholder
            fields[spec.key] = field
            group.addArrangedSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        return group
    }
    @objc private func openLoginSettings() {
        if #available(macOS 13.0, *) { SMAppService.openSystemSettingsLoginItems() }
    }
    private func loadValues() {
        let language = setting(LanguagePreference.key, "system")
        if displayedLanguage != language {
            let oldWindow = window
            let frame = oldWindow?.frame
            let visible = oldWindow?.isVisible == true
            fields.removeAll()
            editors.removeAll()
            targetRows = NSStackView()
            commandFields.removeAll()
            window = makeWindow()
            if let frame = frame { window?.setFrame(frame, display: true) }
            oldWindow?.close()
            if visible { window?.makeKeyAndOrderFront(nil) }
            displayedLanguage = language
        }
        languagePicker?.selectItem(at: LanguagePreference.values.firstIndex(of: language) ?? 0)
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            loginCheckbox?.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        }
        targetApplications = configuredTargets()
        renderTargets()
        jevCheckbox?.state = jevEnabled() ? .on : .off
        for row in commandRows.arrangedSubviews { commandRows.removeArrangedSubview(row); row.removeFromSuperview() }
        commandFields.removeAll()
        for rule in (try? decodeCommands(setting(SettingKey.commands, "[]"))) ?? [] { appendCommand(rule) }
        for section in sections {
            for spec in section.fields {
                let value = setting(spec.key, spec.fallback)
                if spec.multiline {
                    editors[spec.key]?.string = value
                } else {
                    fields[spec.key]?.stringValue = value
                }
            }
        }
    }
    @objc private func cancel() { window?.close() }
    @objc private func save() {
        window?.makeFirstResponder(nil)
        let commands: [CommandRule]
        do {
            _ = try extraRequestParameters(editors[SettingKey.oaExtraParameters]?.string ?? "")
            commands = try currentCommands()
        } catch {
            showNotice(L("额外请求参数无效"), (error as? ProbeError)?.description ?? error.localizedDescription)
            return
        }
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            let wantsLogin = loginCheckbox?.state == .on
            do {
                if wantsLogin && service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                } else if !wantsLogin && (service.status == .enabled || service.status == .requiresApproval) {
                    try service.unregister()
                }
            } catch {
                showNotice(L("开机自启动设置失败"), error.localizedDescription)
                return
            }
            if wantsLogin && service.status == .requiresApproval {
                showNotice(L("需要允许登录项"), L("请在系统设置的登录项中允许 Hola 自启动。"))
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        setSetting(LanguagePreference.key, selectedLanguage())
        reloadLocalization()
        setSetting(SettingKey.targets, targetSettingsValue(targetApplications))
        setSetting(SettingKey.jevEnabled, jevCheckbox?.state == .on ? "true" : "false")
        for (key, field) in fields {
            setSetting(key, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for (key, editor) in editors {
            setSetting(key, editor.string)
        }
        setSetting(SettingKey.commands, encodeCommands(commands))
        window?.close()
        onImported?()
    }
    @objc func exportToFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = L("导出配置")
        panel.prompt = L("导出")
        panel.nameFieldStringValue = "hola-settings.json"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try currentValues()
            _ = try extraRequestParameters(values[SettingKey.oaExtraParameters] ?? "")
            _ = try decodeCommands(values[SettingKey.commands] ?? "[]")
            let data = try encodeSettingsFile(values)
            try data.write(to: url, options: .atomic)
            showNotice(L("配置已导出"), L("文件里包含 Token，只适合在你自己的系统之间拷贝，不要公开分享。"))
        } catch {
            showNotice(L("导出失败"), (error as? ProbeError)?.description ?? error.localizedDescription)
        }
    }
    @discardableResult
    @objc func importFromFile() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L("导入配置")
        panel.prompt = L("导入")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let values = try decodeSettingsFile(Data(contentsOf: url))
            for (key, value) in values { setSetting(key, value) }
            reloadLocalization()
            if window != nil { loadValues() }
            onImported?()
            showNotice(L("配置已导入"), L("文件中的 Apps 列表、语言、Jev 和 OpenAI 设置已导入；未包含的设置保持不变。"))
            return true
        } catch {
            showNotice(L("导入失败"), (error as? ProbeError)?.description ?? error.localizedDescription)
            return false
        }
    }
    private func selectedLanguage() -> String {
        let index = languagePicker?.indexOfSelectedItem ?? 0
        return LanguagePreference.values.indices.contains(index) ? LanguagePreference.values[index] : "system"
    }
    private func currentValues() throws -> [String: String] {
        window?.makeFirstResponder(nil)
        let useForm = window?.isVisible == true
        var values: [String: String] = [:]
        values[LanguagePreference.key] = useForm ? selectedLanguage() : setting(LanguagePreference.key, "system")
        values[SettingKey.targets] = useForm ? targetSettingsValue(targetApplications) : setting(SettingKey.targets, "[]")
        values[SettingKey.jevEnabled] = useForm ? (jevCheckbox?.state == .on ? "true" : "false") : setting(SettingKey.jevEnabled, "false")
        for section in sections {
            for spec in section.fields {
                if useForm, spec.multiline, let editor = editors[spec.key] {
                    values[spec.key] = editor.string
                } else if useForm, let field = fields[spec.key] {
                    values[spec.key] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    values[spec.key] = setting(spec.key, spec.fallback)
                }
            }
        }
        values[SettingKey.commands] = useForm ? encodeCommands(try currentCommands()) : setting(SettingKey.commands, "[]")
        return values
    }
    private func addApplications(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: resolved), let id = bundle.bundleIdentifier,
                  !id.isEmpty, id != Bundle.main.bundleIdentifier else {
                rejected.append(url.lastPathComponent)
                continue
            }
            if !targetApplications.contains(where: { $0.bundleID == id }) {
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? resolved.deletingPathExtension().lastPathComponent
                targetApplications.append(TargetApplication(name: name, bundleID: id, path: resolved.path))
            }
        }
        renderTargets()
        if !rejected.isEmpty { showNotice(L("无法添加应用"), rejected.joined(separator: "、")) }
    }
    private func renderTargets() {
        targetRows.arrangedSubviews.forEach { targetRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        if targetApplications.isEmpty {
            fill(NSTextField(labelWithString: L("尚未添加应用")), in: targetRows)
        }
        for (index, target) in targetApplications.enumerated() {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: target.path))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let title = NSTextField(labelWithString: "\(target.name)  ·  \(target.bundleID)")
            title.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton(title: L("移除"), target: self, action: #selector(removeApplication(_:)))
            remove.tag = index
            let row = NSStackView(views: [icon, title, remove])
            row.orientation = .horizontal
            row.spacing = 8
            fill(row, in: targetRows)
        }
    }
    @objc private func removeApplication(_ sender: NSButton) {
        guard targetApplications.indices.contains(sender.tag) else { return }
        targetApplications.remove(at: sender.tag)
        renderTargets()
    }
    private func showNotice(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: L("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// 一次回车对应一条记录。保存在本机，不记录 Token。
enum RoundOutcome: String, Codable {
    case pending, adjusted, unchanged, failed
}

struct CallRecord: Codable {
    let id: UUID
    let original: String
    let jevPrompt: String
    let polishPrompt: String
    let startedAt: Date
    var finishedAt: Date?
    var outcome: RoundOutcome
    var adjustedText: String
    var jevNote: String
    var polishNote: String
    var returnedPolish: String
    var unusedPolish: String

    var duration: TimeInterval? {
        guard let finishedAt = finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
    var outcomeLabel: String {
        switch outcome {
        case .pending: return L("进行中")
        case .adjusted: return L("已调整")
        case .unchanged: return L("未调整")
        case .failed: return L("失败")
        }
    }
    func optimizationBrief() -> String {
        var lines = [
            L("请根据下面这次真实调用，优化「判断提示词」和「润色提示词」。"),
            L("判断提示词只负责判断要不要润色；润色提示词只改写原句，不增加新信息。"),
            L("请分别给出优化后的两段提示词，并说明改动原因。"),
            "",
            L("## 原句"),
            original,
            "",
            L("## 是否调整"),
            outcomeLabel,
            "",
            L("## 调整后结果"),
            adjustedText.isEmpty ? L("（没有采用新文本）") : adjustedText
        ]
        if !unusedPolish.isEmpty {
            lines += ["", L("## 未采用的润色结果"), unusedPolish]
        }
        lines += [
            "",
            L("## 判断提示词"),
            jevPrompt.isEmpty ? L("（无）") : jevPrompt,
            "",
            L("## 润色提示词"),
            polishPrompt.isEmpty ? L("（无）") : polishPrompt,
            "",
            L("## 过程"),
            L("判断：%1$@", jevNote.isEmpty ? L("（无）") : jevNote),
            L("润色：%1$@", polishNote.isEmpty ? L("（无）") : polishNote)
        ]
        return lines.joined(separator: "\n")
    }
}

final class CallLog {
    static let shared = CallLog()
    private(set) var records: [CallRecord] = []
    private var observers: [UUID: () -> Void] = [:]
    private let limit = 100

    private init() {
        records = Self.load()
    }
    @discardableResult
    func observe(_ body: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }
    @discardableResult
    func begin(original: String, jevPrompt: String, polishPrompt: String) -> UUID {
        let record = CallRecord(
            id: UUID(), original: cap(original), jevPrompt: cap(jevPrompt), polishPrompt: cap(polishPrompt),
            startedAt: Date(), finishedAt: nil, outcome: .pending, adjustedText: "",
            jevNote: "", polishNote: "", returnedPolish: "", unusedPolish: ""
        )
        records.insert(record, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        persist()
        notify()
        return record.id
    }
    func noteJev(_ id: UUID, _ note: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].finishedAt == nil else { return }
        records[index].jevNote = note
        persist()
        notify()
    }
    func notePolish(_ id: UUID, result: Result<String, ProbeError>) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .failure(let err):
            records[index].polishNote = err.description
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            records[index].returnedPolish = cap(trimmed)
            if records[index].finishedAt != nil {
                let restored = EmbeddedDraft(records[index].original).restore(trimmed)?.text ?? trimmed
                if records[index].outcome != .adjusted, restored != records[index].original {
                    records[index].unusedPolish = cap(trimmed)
                    records[index].polishNote = L("已返回，未采用")
                }
            } else {
                records[index].polishNote = L("已返回")
            }
        }
        persist()
        notify()
    }
    func finish(_ id: UUID, outcome: RoundOutcome, adjustedText: String, jevNote: String, polishNote: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].finishedAt == nil else { return }
        records[index].finishedAt = Date()
        records[index].outcome = outcome
        records[index].adjustedText = cap(adjustedText)
        if !jevNote.isEmpty { records[index].jevNote = jevNote }
        if !polishNote.isEmpty { records[index].polishNote = polishNote }
        let returned = records[index].returnedPolish
        let restored = EmbeddedDraft(records[index].original).restore(returned)?.text ?? returned
        if outcome != .adjusted, !returned.isEmpty, restored != records[index].original {
            records[index].unusedPolish = returned
        }
        persist()
        notify()
    }
    func clear() {
        records.removeAll()
        persist()
        notify()
    }
    private func notify() {
        let current = Array(observers.values)
        current.forEach { $0() }
    }
    private func cap(_ text: String) -> String {
        let limit = 16000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + L("\n…（已截断）")
    }
    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.hola", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("round-history.json")
    }
    private static func load() -> [CallRecord] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var loaded = try? decoder.decode([CallRecord].self, from: data) else { return [] }
        var changed = false
        for index in loaded.indices where loaded[index].outcome == .pending {
            loaded[index].outcome = .failed
            loaded[index].finishedAt = loaded[index].finishedAt ?? Date()
            if loaded[index].polishNote.isEmpty { loaded[index].polishNote = L("未完成（应用已退出）") }
            changed = true
        }
        if loaded.count > 100 {
            loaded = Array(loaded.prefix(100))
            changed = true
        }
        if changed {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(loaded) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return loaded
    }
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: Self.fileURL(), options: .atomic)
    }
}

private let callTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()
private let callDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()
private func formatDuration(_ interval: TimeInterval?) -> String {
    guard let interval = interval else { return "—" }
    if interval < 1 { return String(format: "%.0f ms", interval * 1000) }
    return String(format: "%.1f s", interval)
}
private func oneLine(_ text: String, limit: Int = 36) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)) + "…"
}
// 配置里既可以填 Base URL（https://host/v1/），也可以填完整的 chat/completions 地址。
private func chatCompletionsURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          let scheme = components.scheme, scheme == "https" || scheme == "http",
          components.host != nil else { return nil }
    var path = components.percentEncodedPath
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
    components.percentEncodedPath = path
    return components.string
}

final class HistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var table: NSTableView?
    private var detail: NSTextView?
    private var countLabel: NSTextField?
    private var emptyLabel: NSTextField?
    private var copyButton: NSButton?
    private var copyAllButton: NSButton?
    private var clearButton: NSButton?
    private var selectedID: UUID?
    private var restoring = false

    override init() {
        super.init()
        CallLog.shared.observe { [weak self] in self?.reload() }
    }
    func show() {
        if window == nil { window = makeWindow() }
        reload()
        if table?.selectedRow ?? -1 < 0, !CallLog.shared.records.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refreshLanguage() {
        guard let oldWindow = window else { return }
        let visible = oldWindow.isVisible
        window = makeWindow()
        window?.setFrame(oldWindow.frame, display: true)
        oldWindow.close()
        reload()
        if visible { window?.makeKeyAndOrderFront(nil) }
    }
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("调用历史")
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        let columns: [(String, String, CGFloat)] = [("time", L("时间"), 90), ("original", L("原句"), 220), ("outcome", L("是否调整"), 100), ("adjusted", L("调整后结果"), 220), ("duration", L("总耗时"), 90)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 48
            column.resizingMask = (id == "original" || id == "adjusted")
                ? [.autoresizingMask, .userResizingMask]
                : .userResizingMask
            tableView.addTableColumn(column)
        }
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = tableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let empty = NSTextField(labelWithString: L("还没有调用记录"))
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailScroll.documentView = textView

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        let copy = NSButton(title: L("复制优化材料"), target: self, action: #selector(copyBrief))
        let copyAll = NSButton(title: L("复制全部"), target: self, action: #selector(copyAllBriefs))
        let clear = NSButton(title: L("清空"), target: self, action: #selector(clearLog))
        let actions = NSStackView(views: [copy, copyAll, clear])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tableScroll)
        content.addSubview(empty)
        content.addSubview(detailScroll)
        content.addSubview(count)
        content.addSubview(actions)
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailScroll.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 8),
            detailScroll.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            detailScroll.heightAnchor.constraint(equalToConstant: 240),
            actions.topAnchor.constraint(equalTo: detailScroll.bottomAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            count.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor),
            count.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor)
        ])
        window.contentView = content
        window.center()
        self.table = tableView
        self.detail = textView
        self.countLabel = count
        self.emptyLabel = empty
        self.copyButton = copy
        self.copyAllButton = copyAll
        self.clearButton = clear
        return window
    }
    private func reload() {
        guard let table = table else { return }
        restoring = true
        table.reloadData()
        if let selectedID = selectedID, let row = CallLog.shared.records.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            self.selectedID = nil
            table.deselectAll(nil)
        }
        restoring = false
        updateDetail()
        let records = CallLog.shared.records
        let pending = records.filter { $0.outcome == .pending }.count
        if records.isEmpty {
            countLabel?.stringValue = L("共 0 条 · 已保存到本地，重启后仍可查看")
        } else if pending > 0 {
            countLabel?.stringValue = L("共 %1$@ 条，进行中 %2$@ 条 · 已保存到本地", records.count, pending)
        } else {
            countLabel?.stringValue = L("共 %1$@ 条 · 已保存到本地，重启后仍可查看", records.count)
        }
        emptyLabel?.isHidden = !records.isEmpty
        clearButton?.isEnabled = !records.isEmpty
        copyAllButton?.isEnabled = !records.isEmpty
        copyButton?.isEnabled = selectedID != nil
    }
    private func updateDetail() {
        copyButton?.isEnabled = selectedID != nil
        guard let detail = detail else { return }
        guard let selectedID = selectedID, let record = CallLog.shared.records.first(where: { $0.id == selectedID }) else {
            detail.string = CallLog.shared.records.isEmpty
                ? L("开启后，每次回车润色会记成一条：原句、是否调整、调整后结果，以及当时用的两段提示词。")
                : L("选择一条记录。复制优化材料会带上原句、结果和当时的提示词。")
            return
        }
        var lines = [
            L("时间　%1$@", callDateFormatter.string(from: record.startedAt)),
            L("总耗时　%1$@", formatDuration(record.duration)),
            L("是否调整　%1$@", record.outcomeLabel),
            "",
            L("原句"),
            record.original.isEmpty ? L("（空）") : record.original,
            "",
            L("调整后结果"),
            record.adjustedText.isEmpty ? L("（没有采用新文本）") : record.adjustedText
        ]
        if !record.unusedPolish.isEmpty {
            lines += ["", L("未采用的润色结果"), record.unusedPolish]
        }
        lines += [
            "",
            L("判断提示词"),
            record.jevPrompt.isEmpty ? L("（无）") : record.jevPrompt,
            "",
            L("润色提示词"),
            record.polishPrompt.isEmpty ? L("（无）") : record.polishPrompt,
            "",
            L("过程"),
            L("判断：%1$@", record.jevNote.isEmpty ? (record.outcome == .pending ? L("等待返回…") : L("（无）")) : record.jevNote),
            L("润色：%1$@", record.polishNote.isEmpty ? (record.outcome == .pending ? L("等待返回…") : L("（无）")) : record.polishNote)
        ]
        detail.string = lines.joined(separator: "\n")
    }
    @objc private func clearLog() {
        selectedID = nil
        CallLog.shared.clear()
    }
    @objc private func copyBrief() {
        guard let selectedID = selectedID, let record = CallLog.shared.records.first(where: { $0.id == selectedID }) else { return }
        copyToPasteboard(record.optimizationBrief(), button: copyButton, title: L("复制优化材料"))
    }
    @objc private func copyAllBriefs() {
        let records = CallLog.shared.records
        guard !records.isEmpty else { return }
        let text = records.map { $0.optimizationBrief() }.joined(separator: "\n\n----\n\n")
        copyToPasteboard(text, button: copyAllButton, title: L("复制全部"))
    }
    private func copyToPasteboard(_ text: String, button: NSButton?, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        button?.title = L("已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
            button?.title = title
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { CallLog.shared.records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = CallLog.shared.records[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        let title = identifier.rawValue
        let text: String
        let tip: String
        switch title {
        case "time":
            text = callTimeFormatter.string(from: record.startedAt)
            tip = callDateFormatter.string(from: record.startedAt)
        case "original":
            text = oneLine(record.original, limit: 80)
            tip = record.original
        case "outcome":
            text = record.outcomeLabel
            tip = record.outcomeLabel
        case "adjusted":
            text = record.adjustedText.isEmpty ? "—" : oneLine(record.adjustedText, limit: 80)
            tip = record.adjustedText
        default:
            text = formatDuration(record.duration)
            tip = text
        }
        cell.textField?.stringValue = text
        cell.textField?.toolTip = tip.isEmpty ? nil : tip
        if title == "outcome" {
            switch record.outcome {
            case .failed: cell.textField?.textColor = .systemRed
            case .pending: cell.textField?.textColor = .secondaryLabelColor
            case .adjusted: cell.textField?.textColor = .systemGreen
            case .unchanged: cell.textField?.textColor = .labelColor
            }
        } else {
            cell.textField?.textColor = .labelColor
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if restoring { return }
        let row = table?.selectedRow ?? -1
        if row >= 0, row < CallLog.shared.records.count {
            selectedID = CallLog.shared.records[row].id
        } else {
            selectedID = nil
        }
        updateDetail()
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = (identifier.rawValue == "time" || identifier.rawValue == "duration")
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// 菜单栏图标右下角的结果点。点击穿透，不挡住状态栏菜单。
final class StatusDotView: NSView {
    var dotColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        dotColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class FieldActivityView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = L("润色中") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class StatusBadgeOverlay: NSView {
    let dot = StatusDotView()
    private let diameter: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.isHidden = true
        addSubview(dot)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let imageSize = (superview as? NSButton)?.image?.size ?? bounds.size
        let width = imageSize.width > 0 ? imageSize.width : bounds.width
        let height = imageSize.height > 0 ? imageSize.height : bounds.height
        let imageX = (bounds.width - width) / 2
        let imageY = (bounds.height - height) / 2
        dot.frame = NSRect(x: imageX + width - diameter, y: imageY, width: diameter, height: diameter)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsController = SettingsController()
    private let historyController = HistoryController()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusLineItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var running = false
    private var targetBundles = Set<String>()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var processing = false
    private var commandRunner: CommandRunner?
    private var pipelineToken = UUID()
    private var activeRoundID: UUID?
    private var fieldHUD: NSPanel?
    private var pendingFill: String?   // 上一次回填/确认的内容（回车二次校验的基准）
    private var pendingTarget: Target?
    private var passThroughReturn = false
    private var idleImage: NSImage?
    private var spinner: NSProgressIndicator?
    private var badgeOverlay: StatusBadgeOverlay?
    private enum PolishMark { case none, success, failure }
    private var polishMark: PolishMark = .none

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 菜单栏常驻，无 Dock 图标、无主窗口
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                if Bundle.main.object(forInfoDictionaryKey: "HolaBuildChannel") as? String == "dev" {
                    let tinted = NSImage(size: image.size)
                    tinted.lockFocus()
                    image.draw(in: NSRect(origin: .zero, size: image.size))
                    NSColor.systemYellow.setFill()
                    NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
                    tinted.unlockFocus()
                    tinted.isTemplate = false
                    idleImage = tinted
                } else {
                    image.isTemplate = true
                    idleImage = image
                }
                idleImage?.accessibilityDescription = L("Hola · 言好")
                button.image = idleImage
            } else {
                button.title = L("言")
            }
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isDisplayedWhenStopped = false
            indicator.isHidden = true
            indicator.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            spinner = indicator
            let overlay = StatusBadgeOverlay(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            button.addSubview(overlay)
            badgeOverlay = overlay
        }
        buildMenu()
        settingsController.onImported = { [weak self] in
            guard let self = self else { return }
            self.targetBundles = Set(configuredTargets().map(\.bundleID))
            self.buildMenu()
            self.toggleItem.title = self.running ? L("停止") : L("开启")
            self.refreshHistoryMenu()
            self.historyController.refreshLanguage()
            self.updateStatus(self.processing ? L("处理中，请稍候…") : (self.running ? L("运行中（%1$@ 个应用）", self.targetBundles.count) : L("未开启")))
        }
        CallLog.shared.observe { [weak self] in self?.refreshHistoryMenu() }
        refreshHistoryMenu()
        updateStatus(L("未开启"))
        DispatchQueue.main.async { [weak self] in self?.startRunning(interactive: false) }
        if CommandLine.arguments.contains("--show-commands") {
            DispatchQueue.main.async { [weak self] in self?.settingsController.show(commandsTab: true) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { stopRunning() }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key, modifiers) in [
            (L("撤销"), #selector(UndoManager.undo), "z", NSEvent.ModifierFlags.command),
            (L("重做"), #selector(UndoManager.redo), "z", [.command, .shift]),
            (L("剪切"), #selector(NSText.cut(_:)), "x", .command),
            (L("复制"), #selector(NSText.copy(_:)), "c", .command),
            (L("粘贴"), #selector(NSText.paste(_:)), "v", .command),
            (L("全选"), #selector(NSText.selectAll(_:)), "a", .command)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusLineItem = NSMenuItem(title: L("状态：未开启"), action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: L("开启"), action: #selector(toggleRunning), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let perm = NSMenuItem(title: L("请求辅助功能权限"), action: #selector(requestPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(.separator())
        addItem(menu, L("设置…"), #selector(showSettings))
        historyItem = NSMenuItem(title: L("调用历史…"), action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(.separator())
        addItem(menu, L("退出"), #selector(quit))
        statusItem.menu = menu
    }
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func updateStatus(_ text: String) {
        statusLineItem?.title = L("状态：%1$@", text)
        statusItem?.button?.toolTip = L("回车润色 · %1$@", text)
    }
    private func setBusy(_ busy: Bool) {
        guard let button = statusItem?.button else { return }
        if busy {
            polishMark = .none
            applyPolishMark()
            button.image = NSImage(size: NSSize(width: 18, height: 18))
            spinner?.isHidden = false
            spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
            if let idleImage = idleImage {
                button.image = idleImage
            } else {
                button.image = nil
                button.title = L("言")
            }
            applyPolishMark()
        }
    }
    private func applyPolishMark() {
        guard let dot = badgeOverlay?.dot else { return }
        if !running {
            dot.dotColor = .systemYellow
            dot.isHidden = false
            badgeOverlay?.needsLayout = true
            return
        }
        let busy = spinner?.isHidden == false
        switch polishMark {
        case .none:
            dot.isHidden = true
        case .success:
            dot.dotColor = .systemGreen
            dot.isHidden = busy
        case .failure:
            dot.dotColor = .systemRed
            dot.isHidden = busy
        }
        badgeOverlay?.needsLayout = true
    }
    // 输入框本身通常不能改颜色。润色期间在它的可访问区域正中盖一个不挡点击的「润色中」，不改草稿。
    private func showFieldActivity() {
        guard let target = try? currentTarget(), let axRect = composerFrame(around: target.element) else { return }
        let cocoa = cocoaRect(fromAX: axRect)
        let panel = fieldHUD ?? makeFieldHUD()
        let labelWidth = (L("润色中") as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width
        let size = NSSize(width: max(72, ceil(labelWidth) + 24), height: 28)
        let frame = NSRect(
            x: cocoa.midX - size.width / 2,
            y: cocoa.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak panel] in
            panel?.setFrame(frame, display: true)
        }
    }
    // 焦点有时只是光标或较小区域。向父级查找输入区域，用于显示处理提示。
    private func composerFrame(around element: AXUIElement) -> CGRect? {
        var composer: CGRect?
        var column: CGRect?
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let el = current else { break }
            let role = (try? stringValue(el, kAXRoleAttribute)) ?? ""
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { break }
            if let rect = axFrame(of: el), rect.width >= 400 {
                if rect.height >= 80, rect.height <= 320 {
                    composer = rect
                } else if rect.height > 320 {
                    column = rect
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent = parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        if let composer = composer { return composer }
        if let column = column {
            let height = min(180, column.height)
            return CGRect(x: column.minX, y: column.maxY - height, width: column.width, height: height)
        }
        return axFrame(of: element)
    }
    private func hideFieldActivity() {
        fieldHUD?.orderOut(nil)
    }
    private func makeFieldHUD() -> NSPanel {
        let labelWidth = (L("润色中") as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width
        let size = NSSize(width: max(72, ceil(labelWidth) + 24), height: 28)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FieldActivityView(frame: NSRect(origin: .zero, size: size))
        fieldHUD = panel
        return panel
    }
    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef = posRef, let sizeRef = sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let height = primary?.frame.height ?? rect.origin.y + rect.height
        return CGRect(x: rect.origin.x, y: height - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }
    // 补发一次回车，让输入框里的原文直接发出去。只在同一个输入框、同一段草稿还在时才发。
    private func releaseSend(original: String, target originalTarget: Target, status: String) {
        hideFieldActivity()
        processing = false
        pendingFill = nil
        pendingTarget = nil
        setBusy(false)
        guard let target = try? currentTarget(), sameTarget(target, originalTarget),
              let text = try? stringValue(target.element, kAXValueAttribute),
              text == original,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            polishMark = .failure
            applyPolishMark()
            updateStatus(status + L("（焦点已变，未自动发送）"))
            return
        }
        updateStatus(status)
        passThroughReturn = true
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    private func refreshHistoryMenu() {
        let count = CallLog.shared.records.count
        historyItem?.title = count == 0 ? L("调用历史…") : L("调用历史（%1$@）…", count)
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        updateStatus(trusted ? L("辅助功能已授权") : L("请在系统设置→隐私与安全性→辅助功能中允许本工具"))
    }

    @objc private func toggleRunning() {
        if running { stopRunning(); return }
        startRunning(interactive: true)
    }
    private func startRunning(interactive: Bool) {
        guard !running else { return }
        guard AXIsProcessTrusted() else {
            updateStatus(L("请在系统设置→隐私与安全性→辅助功能中允许本工具"))
            if interactive {
                requestPermission()
                alert(L("未获辅助功能权限"), L("请先在系统设置→隐私与安全性→辅助功能中允许本工具，然后再开启。"))
            }
            return
        }
        targetBundles = Set(configuredTargets().map(\.bundleID))
        guard !targetBundles.isEmpty else {
            updateStatus(L("目标应用未配置"))
            if interactive { alert(L("目标应用未配置"), L("请先在设置里拖入至少一个应用。")) }
            return
        }
        guard installEventTap() else {
            removeEventTap()
            updateStatus(L("无法创建键盘事件 tap。请检查输入监控权限"))
            if interactive { alert(L("开启失败"), L("无法创建键盘事件 tap。请在系统设置→隐私与安全性→输入监控中允许本工具，然后退出工具重开再试。")) }
            return
        }
        running = true
        applyPolishMark()
        pendingFill = nil
        pendingTarget = nil
        toggleItem.title = L("停止")
        updateStatus(L("运行中（%1$@ 个应用）", targetBundles.count))
    }
    private func stopRunning() {
        removeEventTap()
        pipelineToken = UUID()
        if let id = activeRoundID {
            CallLog.shared.finish(id, outcome: .failed, adjustedText: "", jevNote: "", polishNote: L("已停止"))
            activeRoundID = nil
        }
        hideFieldActivity()
        running = false
        processing = false
        pendingFill = nil
        pendingTarget = nil
        passThroughReturn = false
        polishMark = .none
        setBusy(false)
        toggleItem?.title = L("开启")
        updateStatus(L("已停止"))
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: L("好"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
    @objc private func showSettings() {
        // 菜单栏菜单结束跟踪时会关掉同步弹出的窗口，延后到下一轮再显示。
        DispatchQueue.main.async { [weak self] in self?.settingsController.show() }
    }
    @objc private func showHistory() {
        DispatchQueue.main.async { [weak self] in self?.historyController.show() }
    }

    // MARK: - 焦点目标（只取当前焦点输入框，不遍历）
    private func safeRole(_ element: AXUIElement) throws -> (String, String) {
        let role = try stringValue(element, kAXRoleAttribute)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw)
        guard error == .success || error == .attributeUnsupported || error == .noValue else {
            throw ProbeError("AXSubrole: \(axDescription(error))")
        }
        let subrole = raw as? String ?? L("（未提供）")
        guard role == kAXTextFieldRole || role == kAXTextAreaRole else {
            throw ProbeError(L("焦点不是文本框（role=%1$@）", role))
        }
        guard !subrole.lowercased().contains("secure"), !subrole.lowercased().contains("password") else {
            throw ProbeError(L("拒绝密码控件：%1$@/%2$@", role, subrole))
        }
        var protected: CFTypeRef?
        let protectedError = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected)
        if protectedError == .success {
            guard let flag = protected as? Bool, !flag else { throw ProbeError(L("拒绝受保护控件")) }
        } else if protectedError != .attributeUnsupported && protectedError != .noValue {
            throw ProbeError("AXProtectedContent: \(axDescription(protectedError))")
        }
        return (role, subrole)
    }
    private func currentTarget() throws -> Target {
        guard AXIsProcessTrusted() else { throw ProbeError(L("辅助功能权限不可用")) }
        guard !targetBundles.isEmpty else { throw ProbeError(L("未设置目标应用")) }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, targetBundles.contains(bundleID) else {
            throw ProbeError(L("目标应用不在前台"))
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)
        let element = try elementValue(app, kAXFocusedUIElementAttribute)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == front.processIdentifier else {
            throw ProbeError(L("焦点控件进程不属于目标应用"))
        }
        let (role, subrole) = try safeRole(element)
        let window = try elementValue(element, kAXWindowAttribute)
        let focusedWindow = try elementValue(app, kAXFocusedWindowAttribute)
        guard CFEqual(window, focusedWindow) else { throw ProbeError(L("控件窗口不是焦点窗口")) }
        return Target(pid: pid, application: app, element: element, window: window, role: role, subrole: subrole)
    }
    private func sameTarget(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element) && CFEqual(lhs.window, rhs.window)
            && lhs.role == rhs.role && lhs.subrole == rhs.subrole
    }
    private func writeBack(_ text: String, original: String, target originalTarget: Target) -> Bool {
        guard let target = try? currentTarget(), sameTarget(target, originalTarget),
              let current = try? stringValue(target.element, kAXValueAttribute), current == original else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, text as CFString) == .success else { return false }
        if let actual = try? stringValue(target.element, kAXValueAttribute) {
            return actual.utf16.elementsEqual(text.utf16)
        }
        return false
    }

    // 只改动对象两侧的普通文字；整段设置 AXValue 会丢失 U+FFFC 背后的附件数据。
    private func writeBackPreservingObjects(_ revised: [String], draft: EmbeddedDraft,
                                            target originalTarget: Target) -> Bool {
        guard let target = try? currentTarget(), sameTarget(target, originalTarget),
              let current = try? stringValue(target.element, kAXValueAttribute), current == draft.original,
              revised.count == draft.segments.count else { return false }
        var settable = DarwinBoolean(false)
        for attribute in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
            guard AXUIElementIsAttributeSettable(target.element, attribute as CFString, &settable) == .success,
                  settable.boolValue else { return false }
        }
        let ranges = draft.textRanges
        let changed = revised.indices.filter { revised[$0] != draft.segments[$0] }
        // 先确认每段都能准确选中，再做任何文本改动。
        for index in changed {
            var cfRange = CFRange(location: ranges[index].location, length: ranges[index].length)
            guard let selection = AXValueCreate(.cfRange, &cfRange),
                  AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, selection) == .success else { return false }
            let selected = try? stringValue(target.element, kAXSelectedTextAttribute)
            guard selected == draft.segments[index] || (draft.segments[index].isEmpty && selected == nil) else { return false }
        }
        var expected = draft.original
        for index in changed.reversed() {
            var cfRange = CFRange(location: ranges[index].location, length: ranges[index].length)
            guard let selection = AXValueCreate(.cfRange, &cfRange),
                  AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, selection) == .success,
                  AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString,
                                               revised[index] as CFString) == .success else { return false }
            guard let range = Range(ranges[index], in: expected) else { return false }
            expected.replaceSubrange(range, with: revised[index])
            guard let actual = try? stringValue(target.element, kAXValueAttribute),
                  actual == expected else { return false }
        }
        return true
    }

    // MARK: - 事件 tap（只拦截目标应用焦点输入框里的裸回车）
    private func installEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    private func removeEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        tapSource = nil
        eventTap = nil
    }
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard running, type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
            return Unmanaged.passUnretained(event) // 非回车：原样放行，不作任何检查
        }
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        guard event.flags.intersection(modifiers).isEmpty else {
            return Unmanaged.passUnretained(event) // Shift/Cmd+回车等保持原样（如换行）
        }
        if passThroughReturn {
            passThroughReturn = false
            return Unmanaged.passUnretained(event)
        }
        // 只在目标应用内接管；读取焦点失败时阻止发送并显示错误。
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, targetBundles.contains(bundleID) else {
            return Unmanaged.passUnretained(event)
        }
        guard let target = try? currentTarget(), let current = try? stringValue(target.element, kAXValueAttribute) else {
            updateStatus(L("无法读取目标输入框，回车已拦截"))
            polishMark = .failure
            applyPolishMark()
            return nil
        }
        let draft = EmbeddedDraft(current)
        if draft.segments.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return Unmanaged.passUnretained(event)
        }
        if processing {
            updateStatus(L("处理中，请稍候…"))
            return nil // 正在润色，拦下这次回车
        }
        if let fill = pendingFill, let previous = pendingTarget,
           sameTarget(target, previous), current == fill {
            // 二次校验①：与回填内容一致 → 放行发送，丢弃记忆
            pendingFill = nil
            pendingTarget = nil
            updateStatus(L("已确认，发送"))
            return Unmanaged.passUnretained(event)
        }
        // 首次回车，或二次校验②（内容被改过）→ 拦下，异步跑润色。
        processing = true
        pendingFill = nil
        pendingTarget = nil
        setBusy(true)
        updateStatus(L("判断中…"))
        DispatchQueue.main.async { [weak self] in self?.runCommandOrPipeline(current: current, target: target) }
        return nil
    }

    private func runCommandOrPipeline(current: String, target: Target) {
        let rules = (try? decodeCommands(setting(SettingKey.commands, "[]"))) ?? []
        guard let rule = matchingCommand(current, rules: rules) else {
            runPipeline(current: current, target: target)
            return
        }
        let token = UUID()
        pipelineToken = token
        updateStatus(L("执行指令中…"))
        commandRunner = CommandRunner(script: rule.script, input: current) { [weak self] result in
            guard let self = self, self.processing, self.pipelineToken == token else { return }
            self.commandRunner = nil
            switch result {
            case .failure(let error):
                self.failPipeline(L("指令失败，未发送：%1$@", error.description))
            case .success(let command):
                guard command.interrupt else {
                    self.runPipeline(current: current, target: target)
                    return
                }
                if let replacement = command.replacement, !replacement.isEmpty, replacement != current {
                    let draft = EmbeddedDraft(current)
                    let wrote: Bool
                    if draft.hasObjects {
                        let parts = replacement.split(separator: EmbeddedDraft.objectCharacter, omittingEmptySubsequences: false).map(String.init)
                        wrote = parts.count == draft.segments.count
                            && self.writeBackPreservingObjects(parts, draft: draft, target: target)
                    } else {
                        wrote = self.writeBack(replacement, original: current, target: target)
                    }
                    guard wrote else {
                        self.failPipeline(L("指令替换失败，未发送"))
                        return
                    }
                    self.pendingFill = replacement
                    self.pendingTarget = target
                }
                self.processing = false
                self.setBusy(false)
                self.updateStatus(L("指令已拦截回车"))
            }
        }
    }

    // MARK: - 润色链路
    // Jev 可选。任何已启用接口失败时都保留草稿，不自动发送。
    private final class PipelineGate {
        var jev: Result<(Bool, Double), ProbeError>?
        var polish: Result<String, ProbeError>?
        var usesJev = false
        var settled = false
        var roundID = UUID()
    }
    private func runPipeline(current: String, target: Target) {
        let token = UUID()
        pipelineToken = token
        let gate = PipelineGate()
        gate.usesJev = jevEnabled()
        let draft = EmbeddedDraft(current)
        let objectInstruction = draft.hasObjects ? "\n\n" + draft.instruction : ""
        let jevPrompt = setting(SettingKey.jevPrompt, defaultJevPrompt) + objectInstruction
        let polishPrompt = setting(SettingKey.oaPrompt, defaultOAPrompt) + objectInstruction
        gate.roundID = CallLog.shared.begin(original: current, jevPrompt: jevPrompt, polishPrompt: polishPrompt)
        activeRoundID = gate.roundID
        showFieldActivity()
        if gate.usesJev {
            callJev(current: current) { [weak self] result in
                gate.jev = result
                self?.considerPipeline(token: token, gate: gate, current: current, target: target)
            }
        } else {
            gate.jev = .success((true, 1))
            considerPipeline(token: token, gate: gate, current: current, target: target)
        }
    }
    private func settleRound(_ id: UUID, outcome: RoundOutcome, adjustedText: String, jevNote: String, polishNote: String) {
        if activeRoundID == id { activeRoundID = nil }
        CallLog.shared.finish(id, outcome: outcome, adjustedText: adjustedText, jevNote: jevNote, polishNote: polishNote)
    }
    private func considerPipeline(token: UUID, gate: PipelineGate, current: String, target: Target) {
        guard pipelineToken == token, !gate.settled, let jev = gate.jev else { return }
        switch jev {
        case .failure(let err):
            gate.settled = true
            settleRound(gate.roundID, outcome: .failed, adjustedText: "", jevNote: err.description, polishNote: "")
            failPipeline(L("Jev 失败，未发送：%1$@", err.description))
        case .success(let decision):
            let (needPolish, score) = decision
            let pct = String(format: "%.0f%%", score * 100)
            let jevNote = gate.usesJev ? "\(needPolish ? L("需要润色") : L("不需要润色")) \(pct)" : L("未启用")
            guard needPolish else {
                gate.settled = true
                settleRound(gate.roundID, outcome: .unchanged, adjustedText: "", jevNote: jevNote, polishNote: "")
                releaseSend(original: current, target: target, status: L("无需润色（Jev %1$@），已发送", pct))
                return
            }
            guard let polish = gate.polish else {
                CallLog.shared.noteJev(gate.roundID, jevNote)
                updateStatus(gate.usesJev ? L("润色中（Jev %1$@）…", pct) : L("润色中…"))
                callOpenAI(content: current) { [weak self] result in
                    CallLog.shared.notePolish(gate.roundID, result: result)
                    gate.polish = result
                    self?.considerPipeline(token: token, gate: gate, current: current, target: target)
                }
                return
            }
            gate.settled = true
            applyPolish(current: current, target: target, result: polish, roundID: gate.roundID, jevNote: jevNote)
        }
    }
    private func applyPolish(current: String, target: Target, result: Result<String, ProbeError>, roundID: UUID, jevNote: String) {
        hideFieldActivity()
        switch result {
        case .failure(let err):
            // Jev 已判定需要润色：接口失败时留下原文，不自动发送。再次回车会重试。
            settleRound(roundID, outcome: .failed, adjustedText: "", jevNote: jevNote, polishNote: err.description)
            failPipeline(L("OpenAI 失败，未发送：%1$@", err.description))
        case .success(let polished):
            let draft = EmbeddedDraft(current)
            let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let restored = draft.restore(trimmed) else {
                settleRound(roundID, outcome: .failed, adjustedText: "", jevNote: jevNote,
                            polishNote: L("模型修改了嵌入对象占位符"))
                failPipeline(L("模型修改了嵌入对象占位符；原草稿未改动"))
                return
            }
            let original = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if restored.text == original {
                settleRound(roundID, outcome: .unchanged, adjustedText: "", jevNote: jevNote, polishNote: L("与原文一致"))
                polishMark = .success
                releaseSend(original: current, target: target, status: L("润色结果与原文一致，已发送"))
                return
            }
            let wrote = draft.hasObjects
                ? writeBackPreservingObjects(restored.segments, draft: draft, target: target)
                : writeBack(restored.text, original: current, target: target)
            if wrote {
                settleRound(roundID, outcome: .adjusted, adjustedText: restored.text, jevNote: jevNote, polishNote: L("已回填"))
                pendingFill = restored.text
                pendingTarget = target
                polishMark = .success
                updateStatus(L("已润色回填，确认后再次回车发送"))
            } else {
                let changedDraft: Bool
                if draft.hasObjects, let latest = try? currentTarget(), sameTarget(latest, target),
                   let actual = try? stringValue(latest.element, kAXValueAttribute) {
                    changedDraft = actual != current
                } else {
                    changedDraft = false
                }
                let failureNote = changedDraft ? L("部分文字可能已写回，请检查草稿") : L("写回失败")
                settleRound(roundID, outcome: .failed, adjustedText: "", jevNote: jevNote, polishNote: failureNote)
                pendingFill = nil
                pendingTarget = nil
                polishMark = .failure
                updateStatus(changedDraft ? failureNote : L("写回失败，未发送；再次回车可重试"))
            }
            processing = false
            setBusy(false)
        }
    }
    private func failPipeline(_ message: String) {
        hideFieldActivity()
        processing = false
        pendingFill = nil
        pendingTarget = nil
        polishMark = .failure
        setBusy(false)
        updateStatus(message)
    }
    // TypeSafe System One：POST /v1/systemone，Noul 问题返回 0～1 的“是”概率。
    // 只把当前草稿作为 state，不附带上次回填或聊天记录。
    private func callJev(current: String, completion: @escaping (Result<(Bool, Double), ProbeError>) -> Void) {
        let urlString = setting(SettingKey.jevURL, defaultJevURL)
        let token = setting(SettingKey.jevToken)
        let model = setting(SettingKey.jevModel, defaultJevModel)
        let draft = EmbeddedDraft(current)
        let instructions = setting(SettingKey.jevPrompt, defaultJevPrompt)
            + (draft.hasObjects ? "\n\n" + draft.instruction : "")
        func fail(_ message: String) {
            completion(.failure(ProbeError(message)))
        }
        guard !token.isEmpty else { fail(L("Jev Token 未配置")); return }
        guard let url = URL(string: urlString) else { fail(L("Jev 接口地址无效")); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "state": draft.modelText,
            "model": model,
            "questions": [
                "need_polish": [
                    "type": "noul",
                    "instructions": instructions,
                    "criteria": ["true": L("需要润色"), "false": L("不需要润色")]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            fail(L("Jev 请求体序列化失败")); return
        }
        request.httpBody = data
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode
                if let error = error { fail(error.localizedDescription); return }
                guard let data = data else { fail(L("Jev 无响应数据")); return }
                let snippet = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                let code = status ?? 0
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    fail(L("Jev HTTP %1$@，响应非 JSON：%2$@", code, snippet)); return
                }
                guard (200..<300).contains(code) else {
                    fail("Jev HTTP \(code)：\(snippet)"); return
                }
                if let answers = obj["answers"] as? [String: Any],
                   let answer = answers["need_polish"] as? [String: Any],
                   let noul = (answer["noul"] as? NSNumber)?.doubleValue,
                   noul.isFinite, (0...1).contains(noul) {
                    completion(.success((noul >= 0.5, noul)))
                } else if let detail = obj["detail"] ?? obj["error"] {
                    fail("Jev HTTP \(code)：\(detail)")
                } else {
                    fail(L("Jev HTTP %1$@，无法解析 noul：%2$@", code, snippet))
                }
            }
        }.resume()
    }
    private func callOpenAI(content: String, completion: @escaping (Result<String, ProbeError>) -> Void) {
        let configuredURL = setting(SettingKey.oaURL)
        let model = setting(SettingKey.oaModel)
        let token = setting(SettingKey.oaToken)
        let draft = EmbeddedDraft(content)
        let system = setting(SettingKey.oaPrompt, defaultOAPrompt)
            + (draft.hasObjects ? "\n\n" + draft.instruction : "")
        guard !configuredURL.isEmpty else {
            completion(.failure(ProbeError(L("OpenAI 接口地址未配置"))))
            return
        }
        guard let requestURL = chatCompletionsURL(configuredURL) else {
            completion(.failure(ProbeError(L("OpenAI 接口地址无效"))))
            return
        }
        let extraParameters = setting(SettingKey.oaExtraParameters)
        chatCompletion(urlString: requestURL, token: token, model: model, system: system,
                       user: draft.modelText, extraParameters: extraParameters, completion: completion)
    }
    // OpenAI 兼容 chat/completions：{model?, messages:[system,user]} → choices[0].message.content
    private func chatCompletion(urlString: String, token: String, model: String, system: String, user: String,
                                extraParameters: String,
                                completion: @escaping (Result<String, ProbeError>) -> Void) {
        func fail(_ message: String) {
            completion(.failure(ProbeError(message)))
        }
        guard let url = URL(string: urlString) else { fail(L("接口地址无效")); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let body = try? chatCompletionBody(model: model, system: system, user: user,
                                                 extraParameters: extraParameters),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            fail(L("请求体序列化失败")); return
        }
        request.httpBody = data
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode
                if let error = error { fail(error.localizedDescription); return }
                guard let data = data else { fail(L("无响应数据")); return }
                let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    fail(L("响应非 JSON：%1$@", snippet)); return
                }
                guard let code = status, (200..<300).contains(code) else {
                    fail("HTTP \(status ?? 0)：\(snippet)"); return
                }
                if let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
                   let message = first["message"] as? [String: Any], let text = message["content"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(.success(text))
                } else if let errObj = obj["error"] as? [String: Any], let msg = errObj["message"] as? String {
                    fail(L("接口错误：%1$@", msg))
                } else {
                    fail(L("HTTP %1$@，无法解析响应：%2$@", status ?? 0, snippet))
                }
            }
        }.resume()
    }
}

// @convention(c) tap 回调：无捕获状态，经 refcon 转发给 delegate。
private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return owner.handleTapEvent(type: type, event: event)
}

migrateLegacyData()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
