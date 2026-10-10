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
    private let prompt = NSTextField(wrappingLabelWithString: L("将一个或多个应用从“应用程序”拖到这里"))
    private let more = NSTextField(wrappingLabelWithString: L("将应用图标拖到这里，即可继续添加"))
    private let topSpacer = NSView()
    private let bottomSpacer = NSView()
    private let root = NSStackView()
    private let tilesView = AppTileFlowView()
    private var emptyHeight: NSLayoutConstraint?
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateBorder()
        prompt.alignment = .center
        prompt.textColor = .secondaryLabelColor
        prompt.maximumNumberOfLines = 3
        more.alignment = .center
        more.font = .systemFont(ofSize: 11)
        more.textColor = .secondaryLabelColor
        more.maximumNumberOfLines = 2
        more.isHidden = true
        tilesView.isHidden = true
        root.orientation = .vertical
        root.alignment = .centerX
        root.detachesHiddenViews = true
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        topSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(topSpacer)
        root.addArrangedSubview(prompt)
        root.addArrangedSubview(bottomSpacer)
        root.addArrangedSubview(tilesView)
        root.addArrangedSubview(more)
        root.setCustomSpacing(10, after: tilesView)
        let balance = topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor)
        balance.priority = .defaultHigh
        balance.isActive = true
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        more.translatesAutoresizingMaskIntoConstraints = false
        more.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        tilesView.translatesAutoresizingMaskIntoConstraints = false
        tilesView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        let height = heightAnchor.constraint(equalToConstant: 88)
        height.isActive = true
        emptyHeight = height
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    func setShowingApps(_ showing: Bool) {
        topSpacer.isHidden = showing
        prompt.isHidden = showing
        bottomSpacer.isHidden = showing
        tilesView.isHidden = !showing
        more.isHidden = !showing
        emptyHeight?.isActive = !showing
    }
    func setTiles(_ tiles: [NSView]) {
        tilesView.setTiles(tiles)
    }
    private func updateBorder() {
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains(where: { $0.pathExtension.lowercased() == "app" })
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        highlighted = true
        updateBorder()
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        updateBorder()
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        updateBorder()
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

private final class AppTileFlowView: NSView {
    static let tileWidth: CGFloat = 96
    static let minimumGap: CGFloat = 16
    private var tiles: [NSView] = []
    private var tileHeight: CGFloat = 96
    private var laidOutColumns = 0
    private var positionConstraints: [NSLayoutConstraint] = []

    override var isFlipped: Bool { true }

    func setTiles(_ tiles: [NSView]) {
        positionConstraints.forEach { $0.isActive = false }
        positionConstraints.removeAll()
        self.tiles.forEach { $0.removeFromSuperview() }
        self.tiles = tiles
        var height: CGFloat = 0
        for tile in tiles {
            tile.translatesAutoresizingMaskIntoConstraints = false
            let width = tile.widthAnchor.constraint(equalToConstant: Self.tileWidth)
            width.priority = .defaultHigh
            width.isActive = true
            height = max(height, tile.fittingSize.height)
            addSubview(tile)
        }
        if height > 1 { tileHeight = height }
        laidOutColumns = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func columnCapacity(for width: CGFloat) -> Int {
        let stride = Self.tileWidth + Self.minimumGap
        guard width >= Self.tileWidth, stride > 0 else { return 1 }
        return max(1, Int((width + Self.minimumGap) / stride))
    }

    override var intrinsicContentSize: NSSize {
        guard !tiles.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        let width = bounds.width > 1 ? bounds.width : Self.tileWidth
        let columns = min(tiles.count, columnCapacity(for: width))
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let height = CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * Self.minimumGap
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let columns = min(tiles.count, columnCapacity(for: bounds.width))
        if columns != laidOutColumns {
            laidOutColumns = columns
            invalidateIntrinsicContentSize()
        }
        let used = CGFloat(columns) * Self.tileWidth + CGFloat(max(0, columns - 1)) * Self.minimumGap
        let extra = max(0, bounds.width - used)
        let gap = columns > 1 ? Self.minimumGap + extra / CGFloat(columns - 1) : 0
        positionConstraints.forEach { $0.isActive = false }
        positionConstraints.removeAll()
        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column) * (Self.tileWidth + gap)
            let y = CGFloat(row) * (tileHeight + Self.minimumGap)
            let constraints = [
                tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
                tile.topAnchor.constraint(equalTo: topAnchor, constant: y),
                tile.widthAnchor.constraint(equalToConstant: Self.tileWidth),
                tile.heightAnchor.constraint(equalToConstant: tileHeight)
            ]
            NSLayoutConstraint.activate(constraints)
            positionConstraints.append(contentsOf: constraints)
        }
    }
}

private final class AppTileView: NSView {
    var onSelect: (() -> Void)?
    private let chosen: Bool
    private let nameField: NSTextField

    init(image: NSImage?, title: String, chosen: Bool, template: Bool = false) {
        self.chosen = chosen
        nameField = NSTextField(wrappingLabelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = image
        if template { icon.contentTintColor = .secondaryLabelColor }
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = nameField
        name.alignment = .center
        name.font = .systemFont(ofSize: 11)
        name.textColor = chosen ? .controlAccentColor : .labelColor
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.preferredMaxLayoutWidth = 88
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(name)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        toolTip = title
        updateChrome()
    }
    override func layout() {
        super.layout()
        nameField.preferredMaxLayoutWidth = max(72, bounds.width - 8)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }
    private func updateChrome() {
        layer?.backgroundColor = chosen ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onSelect != nil }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func resetCursorRects() {
        if onSelect != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

private final class InterceptHoverView: NSView {
    private let cover = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cover.isBordered = false
        cover.isTransparent = true
        cover.title = ""
        cover.focusRingType = .none
        cover.bezelStyle = .shadowlessSquare
        cover.setButtonType(.momentaryChange)
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.isHidden = true
        addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.topAnchor.constraint(equalTo: topAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func showReason(_ text: String?) {
        addSubview(cover)
        cover.toolTip = text
        cover.isHidden = text == nil
    }
}
let defaultJevURL = "https://api.typesafe.ai/v1/systemone"
let defaultJevModel = "jev-latest"
var defaultJevPrompt: String { L("这段即将发送的草稿是否需要润色？语气生硬、表达不通顺、有明显口误或错别字算需要；已经通顺得体，或只是很短的确认，算不需要。") }
var defaultOAPrompt: String { L("你是文字润色助手。保持原文语言，在不改变原意、不添加新信息的前提下，让这段话更通顺、得体。只输出润色后的文本本身，不要加引号或任何解释。") }

private final class CommandDragHandle: NSView {
    var onMove: ((CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = L("拖动调整优先级")
    }
    required init?(coder: NSCoder) { nil }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
    }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        window?.invalidateCursorRects(for: self)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onMove?(event.locationInWindow.y)
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
        onFinish?()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        let dot: CGFloat = 2
        let gap: CGFloat = 3
        let origin = NSPoint(x: (bounds.width - dot * 2 - gap) / 2, y: (bounds.height - dot * 3 - gap * 2) / 2)
        for row in 0..<3 {
            for column in 0..<2 {
                let rect = NSRect(x: origin.x + CGFloat(column) * (dot + gap), y: origin.y + CGFloat(row) * (dot + gap), width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

private final class PanelTabButton: NSView {
    let tabIdentifier: String
    let tabTitle: String
    let symbolName: String
    var chosen = false {
        didSet { needsDisplay = true }
    }
    var marksRequired = false {
        didSet { needsDisplay = true }
    }
    weak var clickTarget: AnyObject?
    var clickAction: Selector?

    init(identifier: String, title: String, symbol: String) {
        tabIdentifier = identifier
        tabTitle = title
        symbolName = symbol
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 64) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard let clickAction else { return }
        NSApp.sendAction(clickAction, to: clickTarget, from: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 4), xRadius: 10, yRadius: 10).fill()
        }
        let tint: NSColor = chosen ? .controlAccentColor : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tabTitle)?.withSymbolConfiguration(config) {
            image.isTemplate = false
            let side: CGFloat = 22
            let iconRect = NSRect(x: (bounds.width - side) / 2, y: bounds.height - 10 - side, width: side, height: side)
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let star = marksRequired ? "* " : ""
        let starAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemRed]
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let starSize = (star as NSString).size(withAttributes: starAttrs)
        let textSize = (tabTitle as NSString).size(withAttributes: textAttrs)
        var textX = (bounds.width - starSize.width - textSize.width) / 2
        if marksRequired {
            (star as NSString).draw(at: NSPoint(x: textX, y: 8), withAttributes: starAttrs)
            textX += starSize.width
        }
        (tabTitle as NSString).draw(at: NSPoint(x: textX, y: 8), withAttributes: textAttrs)
    }
}

// 点击菜单栏图标后打开的分区面板。
final class SettingsController: NSObject, NSTabViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private struct Spec {
        let key: String
        let title: String
        let fallback: String
        let placeholder: String
        let multiline: Bool
    }
    private var jevSpecs: [Spec] { [
        Spec(key: SettingKey.jevURL, title: L("接口地址"), fallback: defaultJevURL, placeholder: defaultJevURL, multiline: false),
        Spec(key: SettingKey.jevToken, title: "Token", fallback: "", placeholder: "Authorization: Bearer", multiline: false),
        Spec(key: SettingKey.jevModel, title: L("模型"), fallback: defaultJevModel, placeholder: defaultJevModel, multiline: false)
    ] }
    private var openAISpecs: [Spec] { [
        Spec(key: SettingKey.oaURL, title: L("接口地址"), fallback: "", placeholder: "https://api.example.com/v1", multiline: false),
        Spec(key: SettingKey.oaToken, title: "Token", fallback: "", placeholder: "Authorization: Bearer", multiline: false),
        Spec(key: SettingKey.oaModel, title: L("模型"), fallback: "", placeholder: L("服务商提供的模型 ID"), multiline: false),
        Spec(key: SettingKey.oaExtraParameters, title: L("额外请求参数（JSON 对象）"), fallback: "", placeholder: "", multiline: true)
    ] }
    private var personaSpecs: [Spec] { [
        Spec(key: SettingKey.jevPrompt, title: L("判断提示词"), fallback: defaultJevPrompt, placeholder: "", multiline: true),
        Spec(key: SettingKey.oaPrompt, title: L("润色提示词"), fallback: defaultOAPrompt, placeholder: "", multiline: true)
    ] }
    private var fieldSpecs: [Spec] { jevSpecs + openAISpecs + personaSpecs }
    var onImported: (() -> Void)?
    private var window: NSWindow?
    private var fields: [String: NSTextField] = [:]
    private var editors: [String: NSTextView] = [:]
    private var appDropView: ApplicationDropView?
    private var targetDetail = NSStackView()
    private var focusedBundleID: String?
    private var interceptHover: InterceptHoverView?
    private var targetApplications: [TargetApplication] = []
    private var componentChoiceIndex: [ObjectIdentifier: (Int, Int)] = [:]
    private var jevCheckbox: NSButton?
    private var loginCheckbox: NSButton?
    private var languagePicker: NSPopUpButton?
    private var displayedLanguage = setting(LanguagePreference.key, "system")
    private var commandRows = NSStackView()
    private var commandFields: [(pattern: NSTextField, script: NSTextView)] = []
    private var testPanel: NSWindow?
    private var testInput: NSTextView?
    private var testResult: NSTextView?
    private var testButton: NSButton?
    private var testRunner: CommandRunner?
    private var testToken: UUID?
    private var tabView: NSTabView?
    private var tabButtons: [PanelTabButton] = []
    private var interceptCheckbox: NSButton?
    private var axStatusLabel: NSTextField?
    private var listenStatusLabel: NSTextField?
    private var axGrantButton: NSButton?
    private var listenGrantButton: NSButton?
    private var loginHint: NSTextField?
    private var runtimeRunning = false
    private var runtimeStatus = ""
    private var extraErrorLabel: NSTextField?
    private var applyingForm = false
    var onQuit: (() -> Void)?
    var onIntercept: ((Bool) -> Void)?
    var onConfigurationChanged: (() -> Void)?
    var historyContent: (() -> NSView)?

    func show() {
        let opening = window?.isVisible != true
        if window == nil { window = makeWindow() }
        if opening {
            loadValues()
            tabView?.selectTabViewItem(withIdentifier: "general")
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("通用")
        window.minSize = NSSize(width: 680, height: 560)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let pages: [(String, String, String, Bool, NSView)] = [
            ("general", L("通用"), "slider.horizontal.3", true, makeGeneralView()),
            ("model", L("模型"), "cpu", true, makeModelView()),
            ("persona", L("人设"), "person", false, makePersonaView()),
            ("commands", L("指令"), "terminal", false, makeCommandsView()),
            ("history", L("日志"), "clock", false, historyContent?() ?? NSView())
        ]
        tabButtons = pages.map { id, title, symbol, required, _ in
            let button = PanelTabButton(identifier: id, title: title, symbol: symbol)
            button.marksRequired = required
            button.clickTarget = self
            button.clickAction = #selector(selectTab(_:))
            return button
        }
        let tabBar = NSStackView(views: tabButtons)
        tabBar.orientation = .horizontal
        tabBar.distribution = .fillEqually
        tabBar.spacing = 4
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

        let tabs = NSTabView()
        tabView = tabs
        tabs.delegate = self
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, _, _, view) in pages {
            let item = NSTabViewItem(identifier: id)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
        tabs.selectTabViewItem(withIdentifier: "general")
        for button in tabButtons { button.chosen = button.tabIdentifier == "general" }

        let line = makeSeparator()
        line.translatesAutoresizingMaskIntoConstraints = false
        let footerLine = makeSeparator()
        footerLine.translatesAutoresizingMaskIntoConstraints = false
        let importButton = NSButton(title: L("导入"), target: self, action: #selector(importFromFile))
        let exportButton = NSButton(title: L("导出"), target: self, action: #selector(exportToFile))
        let testButton = NSButton(title: L("测试"), target: self, action: #selector(showTestPanel))
        let fileButtons = NSStackView(views: [importButton, exportButton, testButton])
        fileButtons.orientation = .horizontal
        fileButtons.spacing = 8
        fileButtons.translatesAutoresizingMaskIntoConstraints = false
        let quit = NSButton(title: L("退出"), target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        quit.translatesAutoresizingMaskIntoConstraints = false
        let intercept = NSButton(checkboxWithTitle: L("开启拦截"), target: self, action: #selector(interceptToggled(_:)))
        interceptCheckbox = intercept
        let interceptHolder = InterceptHoverView()
        interceptHover = interceptHolder
        intercept.translatesAutoresizingMaskIntoConstraints = false
        interceptHolder.translatesAutoresizingMaskIntoConstraints = false
        interceptHolder.addSubview(intercept)
        NSLayoutConstraint.activate([
            intercept.leadingAnchor.constraint(equalTo: interceptHolder.leadingAnchor, constant: 2),
            intercept.trailingAnchor.constraint(equalTo: interceptHolder.trailingAnchor, constant: -2),
            intercept.topAnchor.constraint(equalTo: interceptHolder.topAnchor, constant: 2),
            intercept.bottomAnchor.constraint(equalTo: interceptHolder.bottomAnchor, constant: -2)
        ])

        let content = NSView()
        content.addSubview(tabBar)
        content.addSubview(line)
        content.addSubview(tabs)
        content.addSubview(footerLine)
        content.addSubview(fileButtons)
        content.addSubview(interceptHolder)
        content.addSubview(quit)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 72),
            line.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: line.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerLine.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            footerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fileButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fileButtons.centerYAnchor.constraint(equalTo: quit.centerYAnchor),
            fileButtons.trailingAnchor.constraint(lessThanOrEqualTo: interceptHolder.leadingAnchor, constant: -12),
            interceptHolder.centerYAnchor.constraint(equalTo: quit.centerYAnchor),
            interceptHolder.trailingAnchor.constraint(equalTo: quit.leadingAnchor, constant: -12),
            quit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            quit.topAnchor.constraint(equalTo: footerLine.bottomAnchor, constant: 12),
            quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        let flexible = NSLayoutConstraint.Priority(rawValue: 1)
        content.setContentHuggingPriority(flexible, for: .horizontal)
        content.setContentHuggingPriority(flexible, for: .vertical)
        content.setContentCompressionResistancePriority(flexible, for: .horizontal)
        content.setContentCompressionResistancePriority(flexible, for: .vertical)
        window.contentView = content
        window.setContentSize(NSSize(width: 760, height: 680))
        window.center()
        refreshReadiness()
        return window
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let id = tabViewItem?.identifier as? String ?? "general"
        window?.title = tabViewItem?.label ?? L("通用")
        for button in tabButtons { button.chosen = button.tabIdentifier == id }
        refreshReadiness()
    }
    @objc private func selectTab(_ sender: PanelTabButton) {
        tabView?.selectTabViewItem(withIdentifier: sender.tabIdentifier)
    }
    private func makeGeneralView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        fill(formRow(L("权限"), makePermissionControls(), top: true, required: true), in: stack)
        fill(formRow(L("目标应用"), makeTargetControls(), top: true, required: true), in: stack)
        fill(formRow(L("开机启动"), makeLoginControls(), top: true), in: stack)
        let picker = NSPopUpButton()
        picker.addItems(withTitles: [L("跟随系统"), "简体中文", "English"])
        picker.target = self
        picker.action = #selector(languageChanged)
        languagePicker = picker
        fill(formRow(L("界面语言"), picker), in: stack)
        return wrapScroll(stack)
    }
    private func makePermissionControls() -> NSView {
        let axStatus = NSTextField(labelWithString: "")
        axStatus.font = .systemFont(ofSize: 13)
        axStatusLabel = axStatus
        let axButton = NSButton(title: L("授予"), target: self, action: #selector(grantAccessibility))
        axButton.bezelStyle = .rounded
        axGrantButton = axButton
        let listenStatus = NSTextField(labelWithString: "")
        listenStatus.font = .systemFont(ofSize: 13)
        listenStatusLabel = listenStatus
        let listenButton = NSButton(title: L("授予"), target: self, action: #selector(grantInputMonitoring))
        listenButton.bezelStyle = .rounded
        listenGrantButton = listenButton
        let axRow = NSStackView(views: [axStatus, axButton])
        axRow.orientation = .horizontal
        axRow.alignment = .centerY
        axRow.spacing = 8
        let listenRow = NSStackView(views: [listenStatus, listenButton])
        listenRow.orientation = .horizontal
        listenRow.alignment = .centerY
        listenRow.spacing = 8
        let group = NSStackView(views: [axRow, listenRow])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        return group
    }
    private func makeOpenAIControls() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: L("填写接口地址、Token 和模型后，才能开启拦截。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        let error = NSTextField(wrappingLabelWithString: "")
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.preferredMaxLayoutWidth = 460
        error.isHidden = true
        extraErrorLabel = error
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 10
        block.detachesHiddenViews = true
        fill(hint, in: block)
        for spec in openAISpecs { fill(makeField(spec), in: block) }
        fill(error, in: block)
        return block
    }
    private func makeTargetControls() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: L("只在这些应用里处理回车。点选一个应用后，可以修改它的劫持范围。默认全部劫持；改成部分劫持后，每个输入框第一次回车会询问处理方式。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        let drop = ApplicationDropView()
        drop.onDrop = { [weak self] urls in self?.addApplications(urls) }
        appDropView = drop
        let open = NSButton(title: L("打开应用程序文件夹"), target: self, action: #selector(openApplicationsFolder))
        open.bezelStyle = .rounded
        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.detachesHiddenViews = true
        detail.isHidden = true
        targetDetail = detail
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        fill(hint, in: block)
        fill(drop, in: block)
        block.addArrangedSubview(open)
        fill(detail, in: block)
        return block
    }
    @objc private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }
    private func makeLoginControls() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: L("登录时启动"), target: self, action: #selector(loginToggled(_:)))
        loginCheckbox = checkbox
        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        loginHint = hint
        let block = NSStackView(views: [checkbox, hint])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }
    private func makeModelView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        fill(formRow("OpenAI", makeOpenAIControls(), top: true, required: true), in: stack)
        fill(formRow("Jev", makeJevControls(), top: true), in: stack)
        return wrapScroll(stack)
    }
    private func makeJevControls() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: L("可选。开启后先判断是否需要润色；关闭后每次都调用润色接口。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        let checkbox = NSButton(checkboxWithTitle: L("启用 Jev 判断"), target: self, action: #selector(jevChanged))
        jevCheckbox = checkbox
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 10
        fill(hint, in: block)
        block.addArrangedSubview(checkbox)
        for spec in jevSpecs { fill(makeField(spec), in: block) }
        return block
    }
    private func makePersonaView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        fill(makeHeader(L("人设"), L("判断提示词决定要不要润色；润色提示词只改写原句。修改后，下一次回车生效。")), in: stack)
        for spec in personaSpecs { fill(makeField(spec), in: stack) }
        return wrapScroll(stack)
    }
    private func wrapScroll(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)
        ])
        scroll.documentView = container
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
        return scroll
    }
    private func formRow(_ title: String, _ content: NSView, top: Bool = false, required: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        if required {
            let text = NSMutableAttributedString(string: "* ", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.systemRed
            ])
            text.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]))
            label.attributedStringValue = text
        } else {
            label.stringValue = title
            label.font = .systemFont(ofSize: 13)
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 124).isActive = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, content])
        row.orientation = .horizontal
        row.alignment = top ? .top : .centerY
        row.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -140).isActive = true
        return row
    }
    func applyRuntime(running: Bool, status: String) {
        runtimeRunning = running
        runtimeStatus = status
        refreshReadiness()
    }
    func refreshReadiness() {
        let axGranted = AXIsProcessTrusted()
        let listenGranted = CGPreflightListenEventAccess()
        axStatusLabel?.stringValue = L("辅助功能：%1$@", axGranted ? L("已授权") : L("未授权"))
        axStatusLabel?.textColor = axGranted ? .labelColor : .secondaryLabelColor
        axGrantButton?.isEnabled = !axGranted
        listenStatusLabel?.stringValue = L("输入监控：%1$@", listenGranted ? L("已授权") : L("未授权"))
        listenStatusLabel?.textColor = listenGranted ? .labelColor : .secondaryLabelColor
        listenGrantButton?.isEnabled = !listenGranted
        syncLoginCheckbox()
        let openAIReady = savedOpenAIConfigurationReady()
        var missing: [String] = []
        if !axGranted { missing.append(L("辅助功能")) }
        if !listenGranted { missing.append(L("输入监控")) }
        if !openAIReady { missing.append(L("OpenAI 配置")) }
        if targetApplications.isEmpty { missing.append(L("目标应用")) }
        let ready = missing.isEmpty
        interceptCheckbox?.isEnabled = runtimeRunning || ready
        interceptCheckbox?.state = runtimeRunning ? .on : .off
        let reason: String?
        if ready || runtimeRunning {
            reason = nil
        } else if !openAIReady && missing.count == 1 {
            reason = L("请先填写 OpenAI 的接口地址、Token 和模型")
        } else {
            reason = L("开启拦截前，请先完成：%1$@", missing.joined(separator: L("项分隔")))
        }
        interceptHover?.showReason(reason)
    }
    @objc private func grantAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshReadiness()
    }
    @objc private func grantInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refreshReadiness()
    }
    @objc private func interceptToggled(_ sender: NSButton) {
        onIntercept?(sender.state == .on)
    }
    @objc private func loginToggled(_ sender: NSButton) {
        _ = applyLoginPreference()
    }
    @objc private func quitApp() { onQuit?() }

    private func makeCommandsView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = makeHeader(L("指令配置"), L("按顺序匹配正则。脚本是一个函数，例如 async (input) => { … }，以原始 input 调用，返回 { interrupt: boolean, replacement?: string } 或其 Promise。interrupt 为 true 时拦截回车并按需替换草稿；false 时继续正常流程。发起网络请求使用 fetch，用法与 Fetch 标准一致。排在前面的规则优先匹配，拖动左侧手柄可调整顺序。"))
        fill(header, in: stack)
        commandRows = NSStackView()
        commandRows.orientation = .vertical
        commandRows.alignment = .leading
        commandRows.spacing = 12
        fill(commandRows, in: stack)
        let add = NSButton(title: L("添加指令"), target: self, action: #selector(addCommand))
        fill(add, in: stack)
        for view in [header, commandRows, add] {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        stack.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16)
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

    private func makeTestPanel() -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("测试")
        panel.minSize = NSSize(width: 440, height: 380)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let body = makeGlobalTest()
        let close = NSButton(title: L("关闭"), target: self, action: #selector(closeTestPanel))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let container = NSView()
        container.addSubview(body)
        container.addSubview(close)
        body.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            close.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        panel.contentView = container
        return panel
    }
    private func makeGlobalTest() -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        let title = NSTextField(labelWithString: L("测试文稿"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: L("先按当前指令匹配；没有拦截时，再用当前人设试跑润色。不记入历史，也不会发送。文稿可以手写，或从历史记录里选择曾经出现的原文和润色结果。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 500
        let editor = makeDraftTextView(editable: true, monospaced: false)
        let history = NSButton(title: L("从历史选择"), target: self, action: #selector(showHistoryDrafts(_:)))
        history.setContentHuggingPriority(.required, for: .horizontal)
        let button = NSButton(title: L("测试"), target: self, action: #selector(runTest))
        button.setContentHuggingPriority(.required, for: .horizontal)
        testButton = button
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [history, spacer, button])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let resultLabel = NSTextField(labelWithString: L("测试结果"))
        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        let resultView = makeDraftTextView(editable: false, monospaced: false)
        testInput = editor.text
        testResult = resultView.text
        group.addArrangedSubview(title)
        group.addArrangedSubview(hint)
        group.addArrangedSubview(editor.scroll)
        group.addArrangedSubview(controls)
        group.addArrangedSubview(resultLabel)
        group.addArrangedSubview(resultView.scroll)
        for view in [title, hint, editor.scroll, controls, resultLabel] {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        resultView.scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        resultView.scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for view in [hint, editor.scroll, controls, resultView.scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        editor.scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        resultView.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        return group
    }
    private func makeDraftTextView(editable: Bool, monospaced: Bool) -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView()
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.font = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 13)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = text
        return (scroll, text)
    }
    @objc private func showTestPanel() {
        guard let window else { return }
        if testPanel == nil { testPanel = makeTestPanel() }
        guard let panel = testPanel else { return }
        if window.attachedSheet == panel { return }
        window.beginSheet(panel)
    }
    @objc private func closeTestPanel() {
        guard let panel = testPanel else { return }
        window?.endSheet(panel)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == testPanel else { return true }
        window?.endSheet(sender)
        return false
    }
    private func dismissTestPanel() {
        testToken = nil
        testRunner = nil
        guard let panel = testPanel else { return }
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
        testPanel = nil
        testInput = nil
        testResult = nil
        testButton = nil
    }
    @objc private func showHistoryDrafts(_ sender: NSButton) {
        let menu = NSMenu()
        let records = CallLog.shared.records.map {
            (original: $0.original, adjusted: $0.adjustedText, unused: $0.unusedPolish)
        }
        let choices = historyDraftChoices(records)
        if choices.isEmpty {
            let item = NSMenuItem(title: L("还没有可选择的文稿"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for choice in choices {
                let item = NSMenuItem(title: historyDraftTitle(choice), action: #selector(applyHistoryDraft(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.text
                item.toolTip = choice.text
                menu.addItem(item)
            }
        }
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }
    @objc private func applyHistoryDraft(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        testInput?.string = text
    }
    private func historyDraftTitle(_ choice: HistoryDraftChoice) -> String {
        let preview = oneLine(choice.text, limit: 48)
        switch choice.kind {
        case .original: return L("原句：%1$@", preview)
        case .adjusted: return L("调整后结果：%1$@", preview)
        case .unused: return L("未采用的润色结果：%1$@", preview)
        }
    }
    private func editorPrompt(_ key: String, _ fallback: String) -> String {
        let raw = editors[key]?.string ?? setting(key, fallback)
        return raw.isEmpty ? fallback : raw
    }
    @objc private func runTest() {
        testPanel?.makeFirstResponder(nil)
        let input = testInput?.string ?? ""
        let draft = EmbeddedDraft(input)
        if draft.segments.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            showTestResult(L("空白草稿会原样放行"))
            return
        }
        let token = UUID()
        testToken = token
        testButton?.isEnabled = false
        showTestResult(L("测试中…"))
        let rules = commandFields.map { CommandRule(pattern: $0.pattern.stringValue, script: $0.script.string) }
        guard let rule = matchingCommand(input, rules: rules) else {
            runPolishTest(input: input, token: token, commandNote: L("未命中"))
            return
        }
        testRunner = CommandRunner(script: rule.script, input: input) { [weak self] result in
            guard let self, self.testToken == token else { return }
            self.testRunner = nil
            switch result {
            case .failure(let error):
                self.finishTest(L("指令失败，未发送：%1$@", error.description), token: token)
            case .success(let value):
                let note = formatCommandResult(value)
                guard value.interrupt else {
                    self.runPolishTest(input: input, token: token, commandNote: note)
                    return
                }
                var lines = [L("指令：%1$@", note), "", L("指令已拦截回车")]
                if let replacement = value.replacement, !replacement.isEmpty, replacement != input {
                    lines += ["", replacement]
                }
                self.finishTest(lines.joined(separator: "\n"), token: token)
            }
        }
    }
    private func runPolishTest(input: String, token: UUID, commandNote: String) {
        let jevPrompt = editorPrompt(SettingKey.jevPrompt, defaultJevPrompt)
        let polishPrompt = editorPrompt(SettingKey.oaPrompt, defaultOAPrompt)
        let useJev = jevCheckbox?.state == .on
        func stillCurrent() -> Bool { testToken == token }
        func present(judgment: String, body: String) {
            var lines = [L("指令：%1$@", commandNote), "", L("判断：%1$@", judgment)]
            if !body.isEmpty { lines += ["", body] }
            finishTest(lines.joined(separator: "\n"), token: token)
        }
        func runPolish(judgment: String) {
            callOpenAI(content: input, prompt: polishPrompt) { result in
                guard stillCurrent() else { return }
                switch result {
                case .failure(let error):
                    present(judgment: judgment, body: error.description)
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let restored = EmbeddedDraft(input).restore(trimmed) else {
                        present(judgment: judgment, body: L("模型修改了嵌入对象占位符；原草稿未改动"))
                        return
                    }
                    let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if restored.text == original {
                        present(judgment: judgment, body: L("与原文一致"))
                    } else {
                        present(judgment: judgment, body: restored.text)
                    }
                }
            }
        }
        if useJev {
            callJev(current: input, prompt: jevPrompt) { [weak self] result in
                guard let self, stillCurrent() else { return }
                switch result {
                case .failure(let error):
                    self.finishTest([L("指令：%1$@", commandNote), "", error.description].joined(separator: "\n"), token: token)
                case .success(let decision):
                    let (needPolish, score) = decision
                    let pct = String(format: "%.0f%%", score * 100)
                    let judgment = "\(needPolish ? L("需要润色") : L("不需要润色")) \(pct)"
                    guard needPolish else {
                        present(judgment: judgment, body: "")
                        return
                    }
                    self.showTestResult(L("润色中（Jev %1$@）…", pct))
                    runPolish(judgment: judgment)
                }
            }
        } else {
            showTestResult(L("润色中…"))
            runPolish(judgment: L("未启用"))
        }
    }
    private func finishTest(_ text: String, token: UUID) {
        guard testToken == token else { return }
        testButton?.isEnabled = true
        showTestResult(text)
    }
    private func showTestResult(_ text: String) {
        testResult?.string = text
    }
    @objc private func addCommand() { appendCommand(CommandRule(pattern: "^#", script: "async (input) => {\n  return { interrupt: true, replacement: input.slice(1) };\n}")) }
    private func appendCommand(_ rule: CommandRule) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        let handle = CommandDragHandle()
        handle.onMove = { [weak self, weak row] windowY in
            guard let self, let row else { return }
            row.alphaValue = 0.55
            let y = self.commandRows.convert(NSPoint(x: 0, y: windowY), from: nil).y
            self.dragCommand(row, toY: y)
        }
        handle.onFinish = { [weak row] in row?.alphaValue = 1 }
        let priority = NSTextField(labelWithString: "")
        priority.tag = 8701
        priority.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        priority.textColor = .secondaryLabelColor
        priority.alignment = .right
        let spacer = NSView()
        let remove = NSButton(title: L("删除"), target: self, action: #selector(removeCommand(_:)))
        let header = NSStackView(views: [handle, priority, spacer, remove])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 6
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pattern = NSTextField(string: rule.pattern)
        pattern.placeholderString = L("正则表达式，例如 ^#")
        pattern.delegate = self
        let script = NSTextView()
        script.isRichText = false
        script.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        script.isVerticallyResizable = true
        script.isHorizontallyResizable = false
        script.autoresizingMask = [.width]
        script.textContainer?.widthTracksTextView = true
        script.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        script.delegate = self
        script.string = rule.script
        let scriptScroll = NSScrollView()
        scriptScroll.hasVerticalScroller = true
        scriptScroll.borderType = .bezelBorder
        scriptScroll.documentView = script
        row.addArrangedSubview(header)
        row.addArrangedSubview(pattern)
        row.addArrangedSubview(scriptScroll)
        for view in [header, pattern, scriptScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.widthAnchor.constraint(equalToConstant: 18).isActive = true
        handle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        priority.translatesAutoresizingMaskIntoConstraints = false
        priority.widthAnchor.constraint(equalToConstant: 28).isActive = true
        scriptScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        commandRows.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: commandRows.widthAnchor).isActive = true
        commandFields.append((pattern, script))
        updatePriorityLabels()
        commitForm()
    }
    private func dragCommand(_ row: NSView, toY y: CGFloat) {
        var steps = 0
        while steps < commandRows.arrangedSubviews.count {
            steps += 1
            let rows = commandRows.arrangedSubviews
            guard let from = rows.firstIndex(of: row) else { return }
            if from > 0, y > rows[from - 1].frame.midY {
                moveCommand(from: from, to: from - 1)
                commandRows.layoutSubtreeIfNeeded()
                continue
            }
            if from + 1 < rows.count, y < rows[from + 1].frame.midY {
                moveCommand(from: from, to: from + 1)
                commandRows.layoutSubtreeIfNeeded()
                continue
            }
            return
        }
    }
    private func moveCommand(from: Int, to: Int) {
        guard from != to,
              commandRows.arrangedSubviews.indices.contains(from),
              commandRows.arrangedSubviews.indices.contains(to) else { return }
        let row = commandRows.arrangedSubviews[from]
        commandRows.removeArrangedSubview(row)
        commandRows.insertArrangedSubview(row, at: to)
        reorder(&commandFields, from: from, to: to)
        updatePriorityLabels()
        commitForm()
    }
    private func updatePriorityLabels() {
        for (index, row) in commandRows.arrangedSubviews.enumerated() {
            (row.viewWithTag(8701) as? NSTextField)?.stringValue = "\(index + 1)"
        }
    }
    @objc private func removeCommand(_ sender: NSButton) {
        guard let row = commandRow(containing: sender),
              let index = commandRows.arrangedSubviews.firstIndex(of: row) else { return }
        commandRows.removeArrangedSubview(row)
        row.removeFromSuperview()
        commandFields.remove(at: index)
        updatePriorityLabels()
        commitForm()
    }
    private func commandRow(containing view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current, candidate !== commandRows {
            if commandRows.arrangedSubviews.contains(candidate) { return candidate }
            current = candidate.superview
        }
        return nil
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
            textView.delegate = self
            scroll.documentView = textView
            editors[spec.key] = textView
            group.addArrangedSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            let tall = spec.key == SettingKey.jevPrompt || spec.key == SettingKey.oaPrompt
            scroll.heightAnchor.constraint(equalToConstant: tall ? 160 : 88).isActive = true
        } else {
            let field = NSTextField()
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = spec.placeholder
            field.delegate = self
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
    private func syncLoginCheckbox() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            loginCheckbox?.isEnabled = true
            loginCheckbox?.state = (status == .enabled || status == .requiresApproval) ? .on : .off
            loginHint?.stringValue = status == .requiresApproval
                ? L("请在系统设置的登录项中允许 Hola 自启动。")
                : L("开启后，登录 macOS 时自动打开。")
        } else {
            loginCheckbox?.isEnabled = false
            loginCheckbox?.state = .off
            loginHint?.stringValue = L("macOS 12 请在系统偏好设置 → 用户与群组 → 登录项中手动添加 Hola。")
        }
    }
    @discardableResult
    private func applyLoginPreference() -> Bool {
        guard #available(macOS 13.0, *) else { return true }
        let service = SMAppService.mainApp
        let wantsLogin = loginCheckbox?.state == .on
        var justRegistered = false
        do {
            if wantsLogin && service.status != .enabled && service.status != .requiresApproval {
                try service.register()
                justRegistered = true
            } else if !wantsLogin && (service.status == .enabled || service.status == .requiresApproval) {
                try service.unregister()
            }
        } catch {
            showNotice(L("开机自启动设置失败"), error.localizedDescription)
            syncLoginCheckbox()
            return false
        }
        if justRegistered && service.status == .requiresApproval {
            showNotice(L("需要允许登录项"), L("请在系统设置的登录项中允许 Hola 自启动。"))
            SMAppService.openSystemSettingsLoginItems()
        }
        syncLoginCheckbox()
        return true
    }
    func controlTextDidChange(_ notification: Notification) { commitForm() }
    func textDidChange(_ notification: Notification) { commitForm() }
    @objc private func languageChanged() {
        let language = selectedLanguage()
        guard language != displayedLanguage else { return }
        setSetting(LanguagePreference.key, language)
        reloadLocalization()
        loadValues()
    }
    @objc private func jevChanged() {
        setSetting(SettingKey.jevEnabled, jevCheckbox?.state == .on ? "true" : "false")
    }
    private func commitForm() {
        guard !applyingForm, window != nil else { return }
        for (key, field) in fields {
            setSetting(key, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for (key, editor) in editors where key != SettingKey.oaExtraParameters {
            setSetting(key, editor.string)
        }
        if let editor = editors[SettingKey.oaExtraParameters] {
            do {
                _ = try extraRequestParameters(editor.string)
                setSetting(SettingKey.oaExtraParameters, editor.string)
                extraErrorLabel?.stringValue = ""
                extraErrorLabel?.isHidden = true
            } catch {
                extraErrorLabel?.stringValue = (error as? ProbeError)?.description ?? error.localizedDescription
                extraErrorLabel?.isHidden = false
            }
        }
        if let commands = try? currentCommands() {
            setSetting(SettingKey.commands, encodeCommands(commands))
        }
        refreshReadiness()
    }
    private func persistTargets() {
        setSetting(SettingKey.targets, targetSettingsValue(targetApplications))
        onConfigurationChanged?()
    }
    private func loadValues() {
        applyingForm = true
        defer { applyingForm = false }
        let language = setting(LanguagePreference.key, "system")
        if displayedLanguage != language {
            dismissTestPanel()
            let oldWindow = window
            let frame = oldWindow?.frame
            let visible = oldWindow?.isVisible == true
            fields.removeAll()
            editors.removeAll()
            commandFields.removeAll()
            window = makeWindow()
            if let frame = frame { window?.setFrame(frame, display: true) }
            oldWindow?.close()
            if visible { window?.makeKeyAndOrderFront(nil) }
            displayedLanguage = language
        }
        languagePicker?.selectItem(at: LanguagePreference.values.firstIndex(of: language) ?? 0)
        targetApplications = configuredTargets()
        renderTargets()
        jevCheckbox?.state = jevEnabled() ? .on : .off
        for row in commandRows.arrangedSubviews { commandRows.removeArrangedSubview(row); row.removeFromSuperview() }
        commandFields.removeAll()
        for rule in (try? decodeCommands(setting(SettingKey.commands, "[]"))) ?? [] { appendCommand(rule) }
        for spec in fieldSpecs {
            let value = setting(spec.key, spec.fallback)
            if spec.multiline {
                editors[spec.key]?.string = value
            } else {
                fields[spec.key]?.stringValue = value
            }
        }
        refreshReadiness()
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
        for spec in fieldSpecs {
            if useForm, spec.multiline, let editor = editors[spec.key] {
                values[spec.key] = editor.string
            } else if useForm, let field = fields[spec.key] {
                values[spec.key] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                values[spec.key] = setting(spec.key, spec.fallback)
            }
        }
        values[SettingKey.commands] = useForm ? encodeCommands(try currentCommands()) : setting(SettingKey.commands, "[]")
        return values
    }
    func applySavedComponentDecision(bundleID: String, permission: ComponentPermission) {
        guard let index = targetApplications.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        if let existing = targetApplications[index].components.firstIndex(where: { $0.id == permission.id }) {
            targetApplications[index].components[existing] = permission
        } else {
            targetApplications[index].components.append(permission)
        }
        if window?.isVisible == true { renderTargets() }
    }
    private func addApplications(_ urls: [URL]) {
        var rejected: [String] = []
        let before = targetApplications.count
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
        if targetApplications.count != before { persistTargets() }
        if !rejected.isEmpty { showNotice(L("无法添加应用"), rejected.joined(separator: "、")) }
    }
    private func renderTargets() {
        componentChoiceIndex.removeAll()
        guard let drop = appDropView else { return }
        targetDetail.arrangedSubviews.forEach { targetDetail.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let focused = focusedBundleID, !targetApplications.contains(where: { $0.bundleID == focused }) {
            focusedBundleID = nil
        }
        let hasApps = !targetApplications.isEmpty
        drop.setShowingApps(hasApps)
        if !hasApps { drop.setTiles([]) }
        if hasApps {
            let cells: [NSView] = targetApplications.map { app in
                let tile = AppTileView(
                    image: NSWorkspace.shared.icon(forFile: app.path),
                    title: app.name,
                    chosen: app.bundleID == focusedBundleID
                )
                tile.onSelect = { [weak self] in
                    self?.focusedBundleID = app.bundleID
                    self?.renderTargets()
                }
                return tile
            }
            drop.setTiles(cells)
        }
        if let index = targetApplications.firstIndex(where: { $0.bundleID == focusedBundleID }) {
            targetDetail.isHidden = false
            fill(makeTargetBlock(targetApplications[index], index: index), in: targetDetail)
            targetDetail.layoutSubtreeIfNeeded()
            targetDetail.scrollToVisible(targetDetail.bounds)
        } else {
            targetDetail.isHidden = true
        }
        refreshReadiness()
    }
    private func makeTargetBlock(_ target: TargetApplication, index: Int) -> NSView {
        let title = NSTextField(labelWithString: target.name)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let scope = NSPopUpButton()
        scope.controlSize = .small
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scope.addItems(withTitles: [L("全部劫持"), L("部分劫持")])
        scope.selectItem(at: target.hijackScope == .partial ? 1 : 0)
        scope.tag = index
        scope.target = self
        scope.action = #selector(changeHijackScope(_:))
        scope.setContentHuggingPriority(.required, for: .horizontal)
        let remove = NSButton(title: L("移除"), target: self, action: #selector(removeApplication(_:)))
        remove.tag = index
        remove.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [title, scope, remove])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6
        block.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        guard target.hijackScope == .partial else { return block }
        if target.components.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L("尚未记录输入框。部分劫持时，在输入框按回车后会询问。"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.preferredMaxLayoutWidth = 420
            block.addArrangedSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
            return block
        }
        let caption = NSTextField(labelWithString: L("组件权限"))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        block.addArrangedSubview(caption)
        for (componentIndex, component) in target.components.enumerated() {
            let display = componentPermissionDisplay(component)
            let tree = NSTextField(labelWithString: display.tree)
            tree.lineBreakMode = .byTruncatingMiddle
            tree.font = .systemFont(ofSize: 12)
            tree.toolTip = component.id
            tree.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView()
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            text.addArrangedSubview(tree)
            if !display.detail.isEmpty {
                let detail = NSTextField(labelWithString: display.detail)
                detail.lineBreakMode = .byTruncatingMiddle
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                detail.toolTip = component.id
                detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                text.addArrangedSubview(detail)
            }
            let choice = NSPopUpButton()
            choice.controlSize = .small
            choice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            choice.addItems(withTitles: [L("允许劫持"), L("不劫持"), L("下次再问")])
            choice.selectItem(at: component.decision == .allow ? 0 : 1)
            choice.target = self
            choice.action = #selector(changeComponentDecision(_:))
            choice.setContentHuggingPriority(.required, for: .horizontal)
            componentChoiceIndex[ObjectIdentifier(choice)] = (index, componentIndex)
            let indent = NSView()
            indent.translatesAutoresizingMaskIntoConstraints = false
            indent.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let row = NSStackView(views: [indent, text, choice])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            block.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        }
        return block
    }
    @objc private func changeHijackScope(_ sender: NSPopUpButton) {
        guard targetApplications.indices.contains(sender.tag) else { return }
        targetApplications[sender.tag].hijackScope = sender.indexOfSelectedItem == 1 ? .partial : .all
        persistTargets()
        DispatchQueue.main.async { [weak self] in self?.renderTargets() }
    }
    @objc private func changeComponentDecision(_ sender: NSPopUpButton) {
        guard let (appIndex, componentIndex) = componentChoiceIndex[ObjectIdentifier(sender)],
              targetApplications.indices.contains(appIndex),
              targetApplications[appIndex].components.indices.contains(componentIndex) else { return }
        switch sender.indexOfSelectedItem {
        case 0:
            targetApplications[appIndex].components[componentIndex].decision = .allow
        case 1:
            targetApplications[appIndex].components[componentIndex].decision = .deny
        default:
            targetApplications[appIndex].components.remove(at: componentIndex)
            DispatchQueue.main.async { [weak self] in self?.renderTargets() }
        }
        persistTargets()
    }
    @objc private func removeApplication(_ sender: NSButton) {
        guard targetApplications.indices.contains(sender.tag) else { return }
        if targetApplications[sender.tag].bundleID == focusedBundleID { focusedBundleID = nil }
        targetApplications.remove(at: sender.tag)
        renderTargets()
        persistTargets()
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
    func makeContentView() -> NSView {
        let content = buildContent()
        reload()
        if table?.selectedRow ?? -1 < 0, !CallLog.shared.records.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return content
    }
    func refreshLanguage() { reload() }
    private func buildContent() -> NSView {
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
        self.table = tableView
        self.detail = textView
        self.countLabel = count
        self.emptyLabel = empty
        self.copyButton = copy
        self.copyAllButton = copyAll
        self.clearButton = clear
        content.autoresizingMask = [.width, .height]
        return content
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

// 菜单栏图标右下角的结果点。点击穿透，不挡住状态栏按钮。
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

private enum HijackPromptChoice {
    case deny, allow, dismiss
}

private struct HijackPromptContext {
    let bundleID: String
    let signatureID: String
    let label: String
    let target: Target
}

private final class PromptButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HijackPromptPanel: NSObject {
    var onChoose: ((HijackPromptChoice) -> Void)?
    private let panel: NSPanel
    private let titleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "")
    private let denyButton = PromptButton(title: "", target: nil, action: nil)
    private let allowButton = PromptButton(title: "", target: nil, action: nil)
    private let dismissButton = PromptButton(title: "", target: nil, action: nil)

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 148),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintField.font = .systemFont(ofSize: 11)
        hintField.textColor = .secondaryLabelColor
        hintField.preferredMaxLayoutWidth = 396
        denyButton.target = self
        denyButton.action = #selector(chooseDeny)
        allowButton.target = self
        allowButton.action = #selector(chooseAllow)
        dismissButton.target = self
        dismissButton.action = #selector(chooseDismiss)
        for button in [denyButton, allowButton, dismissButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        let buttons = NSStackView(views: [denyButton, allowButton, dismissButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        let stack = NSStackView(views: [titleField, hintField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.contentView = background
    }

    func show(title: String, near cocoa: CGRect?) {
        titleField.stringValue = title
        hintField.stringValue = L("这次回车已拦截，不会发送。不劫持和允许劫持会记住；放弃则下次仍会询问。")
        denyButton.title = L("不劫持")
        allowButton.title = L("允许劫持")
        dismissButton.title = L("放弃")
        let size = NSSize(width: 420, height: 148)
        let screen = NSScreen.screens.first { screen in
            guard let cocoa else { return false }
            return screen.frame.intersects(cocoa)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if let cocoa {
            origin.x = cocoa.midX - size.width / 2
            origin.y = cocoa.maxY + 8
            if origin.y + size.height > visible.maxY {
                origin.y = cocoa.minY - size.height - 8
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    @objc private func chooseDeny() { onChoose?(.deny) }
    @objc private func chooseAllow() { onChoose?(.allow) }
    @objc private func chooseDismiss() { onChoose?(.dismiss) }
}

final class FieldBorderView: NSView {
    enum Tone { case yellow, breathing, green }
    var tone: Tone = .yellow
    var breath: CGFloat = 1
    var strokeInset: CGFloat = 3

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch tone {
        case .yellow:
            color = .systemYellow
        case .green:
            color = .systemGreen
        case .breathing:
            color = NSColor.systemYellow.withAlphaComponent(0.28 + 0.72 * breath)
        }
        color.setStroke()
        let field = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        guard field.width > 1, field.height > 1 else { return }
        let path = NSBezierPath(rect: field.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
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
    private var running = false
    private var targetBundles = Set<String>()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var processing = false
    private var commandRunner: CommandRunner?
    private var pipelineToken = UUID()
    private var activeRoundID: UUID?
    private var fieldHUD: NSPanel?
    private var outlineElement: AXUIElement?
    private var outlineTone: FieldBorderView.Tone?
    private var outlineTimer: Timer?
    private var outlineCheckedAt = Date.distantPast
    private var outlineFrameTick = 0
    private var pendingFill: String?   // 上一次回填/确认的内容（回车二次校验的基准）
    private var pendingTarget: Target?
    private var passThroughReturn = false
    private var hijackPrompt: HijackPromptContext?
    private var hijackPromptPanel: HijackPromptPanel?
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
            button.target = self
            button.action = #selector(openPanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        settingsController.historyContent = { [weak self] in self?.historyController.makeContentView() ?? NSView() }
        settingsController.onQuit = { NSApp.terminate(nil) }
        settingsController.onIntercept = { [weak self] wants in
            guard let self else { return }
            if wants { self.startRunning(interactive: true) }
            else { self.stopRunning() }
        }
        settingsController.onConfigurationChanged = { [weak self] in
            self?.targetBundles = Set(configuredTargets().map(\.bundleID))
        }
        settingsController.onImported = { [weak self] in
            guard let self = self else { return }
            self.targetBundles = Set(configuredTargets().map(\.bundleID))
            self.historyController.refreshLanguage()
            self.updateStatus(self.processing ? L("处理中，请稍候…") : (self.running ? L("运行中（%1$@ 个应用）", self.targetBundles.count) : L("未开启")))
        }
        updateStatus(L("未开启"))
        DispatchQueue.main.async { [weak self] in self?.startRunning(interactive: false) }
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in self?.settingsController.show() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { stopRunning() }
    func applicationDidBecomeActive(_ notification: Notification) { settingsController.refreshReadiness() }

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

    @objc private func openPanel() { settingsController.show() }

    private func updateStatus(_ text: String) {
        statusItem?.button?.toolTip = L("回车润色 · %1$@", text)
        settingsController.applyRuntime(running: running, status: text)
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
    // 输入框本身通常不能改颜色。在焦点输入框的可访问区域上盖一层不挡点击的描边。
    private let outlinePad: CGFloat = 3
    private func showFieldOutline(_ tone: FieldBorderView.Tone, around element: AXUIElement) {
        outlineElement = element
        outlineTone = tone
        ensureOutlineTimer()
        placeFieldOutline(around: element, tone: tone)
    }
    private func placeFieldOutline(around element: AXUIElement, tone: FieldBorderView.Tone) {
        guard outlineFocusContains(element), let axRect = outlineFrame(around: element) else {
            fieldHUD?.orderOut(nil)
            return
        }
        let cocoa = cocoaRect(fromAX: axRect)
        let panel = fieldHUD ?? makeFieldHUD()
        let frame = cocoa.insetBy(dx: -outlinePad, dy: -outlinePad)
        if let border = panel.contentView as? FieldBorderView {
            border.tone = tone
            border.strokeInset = outlinePad
            border.frame = NSRect(origin: .zero, size: frame.size)
            border.needsDisplay = true
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func hideFieldOutline() {
        outlineTimer?.invalidate()
        outlineTimer = nil
        outlineElement = nil
        outlineTone = nil
        outlineFrameTick = 0
        fieldHUD?.orderOut(nil)
    }
    private func ensureOutlineTimer() {
        guard outlineTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickFieldOutline()
        }
        RunLoop.main.add(timer, forMode: .common)
        outlineTimer = timer
    }
    private func tickFieldOutline() {
        guard let tone = outlineTone, let element = outlineElement else {
            hideFieldOutline()
            return
        }
        outlineFrameTick += 1
        if outlineFrameTick % 3 == 0 {
            placeFieldOutline(around: element, tone: tone)
        }
        guard fieldHUD?.isVisible == true, tone == .breathing,
              let border = fieldHUD?.contentView as? FieldBorderView else { return }
        let wave = sin(Date().timeIntervalSinceReferenceDate * .pi)
        border.breath = CGFloat(0.5 + 0.5 * wave)
        border.needsDisplay = true
    }
    private func outlineFocusContains(_ element: AXUIElement) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, 0.15)
        guard let focused = try? elementValue(app, kAXFocusedUIElementAttribute) else { return false }
        var current: AXUIElement? = focused
        for _ in 0..<8 {
            guard let el = current else { return false }
            if CFEqual(el, element) { return true }
            let role = (try? stringValue(el, kAXRoleAttribute)) ?? ""
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { return false }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }
    // 优先用输入框自己的区域。光标太小时，再向上找最近的一块像输入框的区域。
    private func outlineFrame(around element: AXUIElement) -> CGRect? {
        var current: AXUIElement? = element
        var fallback: CGRect?
        for _ in 0..<8 {
            guard let el = current else { break }
            let role = (try? stringValue(el, kAXRoleAttribute)) ?? ""
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { break }
            if let rect = axFrame(of: el), rect.width >= 48, rect.height >= 18 {
                if rect.height <= 160 { return rect }
                if fallback == nil { fallback = rect }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return fallback ?? axFrame(of: element)
    }
    private func restoreYellowOutlineIfPermitted() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, targetBundles.contains(bundleID),
              let target = try? currentTarget(),
              let current = try? stringValue(target.element, kAXValueAttribute),
              fieldPermitsIntercept(bundleID: bundleID, target: target, value: current) else {
            hideFieldOutline()
            return
        }
        showFieldOutline(.yellow, around: target.element)
    }
    private func noteTyping() {
        if processing { return }
        if outlineTone == .yellow, Date().timeIntervalSince(outlineCheckedAt) < 0.25 { return }
        outlineCheckedAt = Date()
        restoreYellowOutlineIfPermitted()
    }
    private func fieldPermitsIntercept(bundleID: String, target: Target, value: String) -> Bool {
        guard let app = configuredTargets().first(where: { $0.bundleID == bundleID }) else { return false }
        if app.hijackScope == .all { return true }
        let signature = componentSignature(for: target, value: value)
        return app.components.first(where: { $0.id == signature.id })?.decision == .allow
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
        hideFieldOutline()
    }
    private func makeFieldHUD() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 80, height: 32)),
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
        let border = FieldBorderView(frame: panel.contentView?.bounds ?? .zero)
        border.autoresizingMask = [.width, .height]
        panel.contentView = border
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
    private func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        updateStatus(trusted ? L("辅助功能已授权") : L("请在系统设置→隐私与安全性→辅助功能中允许本工具"))
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
        guard CGPreflightListenEventAccess() else {
            updateStatus(L("请在系统设置→隐私与安全性→输入监控中允许本工具"))
            if interactive {
                alert(L("未获输入监控权限"), L("请先在系统设置→隐私与安全性→输入监控中允许本工具，然后再开启拦截。"))
            }
            return
        }
        guard savedOpenAIConfigurationReady() else {
            updateStatus(L("请先填写 OpenAI 的接口地址、Token 和模型"))
            if interactive {
                alert(L("OpenAI 配置尚未就绪"), L("请先填写 OpenAI 的接口地址、Token 和模型，然后再开启拦截。"))
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
        clearHijackPrompt()
        running = false
        processing = false
        pendingFill = nil
        pendingTarget = nil
        passThroughReturn = false
        polishMark = .none
        setBusy(false)
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
        let isReturn = keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter)
        if !isReturn {
            noteTyping()
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        guard event.flags.intersection(modifiers).isEmpty else {
            return Unmanaged.passUnretained(event) // Shift/Cmd+回车等保持原样（如换行）
        }
        if passThroughReturn {
            passThroughReturn = false
            hideFieldOutline()
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
        if processing {
            updateStatus(L("处理中，请稍候…"))
            return nil // 正在润色，拦下这次回车
        }
        let signature = componentSignature(for: target, value: current)
        if let prompt = hijackPrompt {
            if prompt.bundleID == bundleID && prompt.signatureID == signature.id {
                return nil
            }
            clearHijackPrompt()
        }
        switch hijackDecision(bundleID: bundleID, signatureID: signature.id) {
        case .some(.deny):
            return Unmanaged.passUnretained(event)
        case .none:
            askHijackPermission(bundleID: bundleID, signature: signature, target: target)
            return nil
        case .some(.allow):
            break
        }
        if beginReturnHandling(current: current, target: target, eventWasConsumed: false) {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func hijackDecision(bundleID: String, signatureID: String) -> ComponentHijackDecision? {
        guard let app = configuredTargets().first(where: { $0.bundleID == bundleID }),
              app.hijackScope == .partial else { return .allow }
        return app.components.first(where: { $0.id == signatureID })?.decision
    }
    private func askHijackPermission(bundleID: String, signature: ComponentSignature, target: Target) {
        if hijackPrompt?.bundleID == bundleID, hijackPrompt?.signatureID == signature.id { return }
        hijackPrompt = HijackPromptContext(bundleID: bundleID, signatureID: signature.id, label: signature.label, target: target)
        let frame = composerFrame(around: target.element).map { cocoaRect(fromAX: $0) }
        let title = L("是否劫持「%1$@」？", signature.label)
        updateStatus(L("请选择是否劫持此输入框"))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hijackPrompt?.signatureID == signature.id, self.hijackPrompt?.bundleID == bundleID else { return }
            self.ensureHijackPromptPanel().show(title: title, near: frame)
        }
    }
    private func ensureHijackPromptPanel() -> HijackPromptPanel {
        if let panel = hijackPromptPanel { return panel }
        let panel = HijackPromptPanel()
        panel.onChoose = { [weak self] choice in self?.resolveHijackPrompt(choice) }
        hijackPromptPanel = panel
        return panel
    }
    private func resolveHijackPrompt(_ choice: HijackPromptChoice) {
        guard let pending = hijackPrompt else {
            clearHijackPrompt()
            return
        }
        hijackPrompt = nil
        hijackPromptPanel?.hide()
        switch choice {
        case .dismiss:
            restoreRunningStatus()
        case .deny:
            let permission = ComponentPermission(id: pending.signatureID, label: pending.label, decision: .deny)
            saveComponentDecision(bundleID: pending.bundleID, permission: permission)
            settingsController.applySavedComponentDecision(bundleID: pending.bundleID, permission: permission)
            restoreRunningStatus()
        case .allow:
            let permission = ComponentPermission(id: pending.signatureID, label: pending.label, decision: .allow)
            saveComponentDecision(bundleID: pending.bundleID, permission: permission)
            settingsController.applySavedComponentDecision(bundleID: pending.bundleID, permission: permission)
            guard let target = try? currentTarget(), sameTarget(target, pending.target),
                  let current = try? stringValue(target.element, kAXValueAttribute) else {
                updateStatus(L("焦点已变，未继续处理"))
                return
            }
            _ = beginReturnHandling(current: current, target: target, eventWasConsumed: true)
        }
    }
    private func clearHijackPrompt() {
        let wasAsking = hijackPrompt != nil
        hijackPrompt = nil
        hijackPromptPanel?.hide()
        if wasAsking && running && !processing { restoreRunningStatus() }
    }
    private func restoreRunningStatus() {
        updateStatus(L("运行中（%1$@ 个应用）", targetBundles.count))
    }
    @discardableResult
    private func replayReturnIfFocused(_ expected: Target) -> Bool {
        guard let target = try? currentTarget(), sameTarget(target, expected),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            updateStatus(L("焦点已变，未继续处理"))
            return false
        }
        passThroughReturn = true
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
    // 返回 true 表示这次回车应交给原应用。eventWasConsumed 为 true 时改为补发回车。
    private func beginReturnHandling(current: String, target: Target, eventWasConsumed: Bool) -> Bool {
        if processing {
            updateStatus(L("处理中，请稍候…"))
            return false
        }
        let draft = EmbeddedDraft(current)
        let idle = draft.segments.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if idle {
            if eventWasConsumed { restoreRunningStatus() }
            return !eventWasConsumed
        }
        if let fill = pendingFill, let previous = pendingTarget,
           sameTarget(target, previous), current == fill {
            pendingFill = nil
            pendingTarget = nil
            hideFieldOutline()
            updateStatus(L("已确认，发送"))
            if eventWasConsumed { replayReturnIfFocused(target) }
            return !eventWasConsumed
        }
        processing = true
        pendingFill = nil
        pendingTarget = nil
        setBusy(true)
        updateStatus(L("判断中…"))
        showFieldOutline(.breathing, around: target.element)
        DispatchQueue.main.async { [weak self] in self?.runCommandOrPipeline(current: current, target: target) }
        return false
    }
    private func optionalAXString(_ element: AXUIElement, _ attribute: String) -> String {
        (try? stringValue(element, attribute)) ?? ""
    }
    private func componentSignature(for target: Target, value: String) -> ComponentSignature {
        makeComponentSignature(
            role: target.role,
            subrole: optionalAXString(target.element, kAXSubroleAttribute),
            identifier: optionalAXString(target.element, kAXIdentifierAttribute),
            title: optionalAXString(target.element, kAXTitleAttribute),
            placeholder: optionalAXString(target.element, kAXPlaceholderValueAttribute),
            description: optionalAXString(target.element, kAXDescriptionAttribute),
            value: value,
            treePosition: componentTreePosition(of: target.element)
        )
    }
    /// 从输入框走到窗口为止，每一层记成「角色[在父节点中的序号]」。窗口本身不计入。
    private func componentTreePosition(of element: AXUIElement) -> String {
        var parts: [String] = []
        var current = element
        for _ in 0..<16 {
            let role = optionalAXString(current, kAXRoleAttribute)
            if role.isEmpty || role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { break }
            if let index = siblingIndex(of: current) {
                parts.append("\(role)[\(index)]")
            } else {
                parts.append(role)
            }
            guard let parent = axParent(current) else { break }
            current = parent
        }
        return parts.reversed().joined(separator: "/")
    }
    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        return (parent as! AXUIElement)
    }
    private func siblingIndex(of element: AXUIElement) -> Int? {
        guard let parent = axParent(element) else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let childrenRef else { return nil }
        let children: [AXUIElement]
        if let list = childrenRef as? [AXUIElement] {
            children = list
        } else if let list = childrenRef as? [AnyObject] {
            children = list.compactMap { item in
                guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
                return (item as! AXUIElement)
            }
        } else {
            return nil
        }
        return children.firstIndex { CFEqual($0, element) }
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
                    self.processing = false
                    self.setBusy(false)
                    self.showFieldOutline(.green, around: target.element)
                    self.updateStatus(L("指令已拦截回车"))
                    return
                }
                self.processing = false
                self.setBusy(false)
                self.restoreYellowOutlineIfPermitted()
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
        showFieldOutline(.breathing, around: target.element)
        if gate.usesJev {
            callJev(current: current, prompt: setting(SettingKey.jevPrompt, defaultJevPrompt)) { [weak self] result in
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
                callOpenAI(content: current, prompt: setting(SettingKey.oaPrompt, defaultOAPrompt)) { [weak self] result in
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
                showFieldOutline(.green, around: target.element)
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
                restoreYellowOutlineIfPermitted()
            }
            processing = false
            setBusy(false)
        }
    }
    private func failPipeline(_ message: String) {
        hideFieldOutline()
        processing = false
        pendingFill = nil
        pendingTarget = nil
        polishMark = .failure
        setBusy(false)
        updateStatus(message)
        restoreYellowOutlineIfPermitted()
    }
}

// 人设测试和正式润色共用。测试传入编辑中的提示词，不写入历史。
// TypeSafe System One：POST /v1/systemone，Noul 问题返回 0～1 的“是”概率。
// 只把当前草稿作为 state，不附带上次回填或聊天记录。
private func callJev(current: String, prompt: String, completion: @escaping (Result<(Bool, Double), ProbeError>) -> Void) {
    let urlString = setting(SettingKey.jevURL, defaultJevURL)
    let token = setting(SettingKey.jevToken)
    let model = setting(SettingKey.jevModel, defaultJevModel)
    let draft = EmbeddedDraft(current)
    let instructions = prompt + (draft.hasObjects ? "\n\n" + draft.instruction : "")
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

private func callOpenAI(content: String, prompt: String, completion: @escaping (Result<String, ProbeError>) -> Void) {
    let configuredURL = setting(SettingKey.oaURL)
    let model = setting(SettingKey.oaModel)
    let token = setting(SettingKey.oaToken)
    let draft = EmbeddedDraft(content)
    let system = prompt + (draft.hasObjects ? "\n\n" + draft.instruction : "")
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
