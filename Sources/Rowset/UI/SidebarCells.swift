import AppKit

/// The base of every sidebar cell.
///
/// AppKit tells a cell when its row turns into the blue selection. The text fields hear it
/// through their cells, which turns the system colors white.
class SidebarCellView: NSTableCellView {
    static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let captionFont = NSFont.preferredFont(forTextStyle: .caption1)

    private var fields: [NSTextField] = []
    private var tintedIcon: (view: NSImageView, tint: SidebarLook.Tint)?

    func configure(_ look: SidebarLook) {}

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for field in fields { field.cell?.backgroundStyle = backgroundStyle }
            applyIconTint()
        }
    }

    func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false
        fields.append(label)
        return label
    }

    func makeIcon() -> NSImageView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        return icon
    }

    func show(_ symbol: String?, in icon: NSImageView, tint: SidebarLook.Tint) {
        icon.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        icon.isHidden = icon.image == nil
        tintedIcon = (icon, tint)
        applyIconTint()
    }

    /// A status color keeps its meaning on the selection. Grey turns white like the text.
    private func applyIconTint() {
        guard let tinted = tintedIcon else { return }
        tinted.view.contentTintColor = switch tinted.tint {
        case .secondary:
            backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    func pinCentered(_ view: NSView, leading: CGFloat = 2, trailing: CGFloat = 4) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    static func spinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }

    static func show(_ isBusy: Bool, in spinner: NSProgressIndicator) {
        spinner.isHidden = !isBusy
        if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// A section title.
final class SidebarHeaderCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")
    private lazy var label = makeLabel(
        font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        pinCentered(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        label.stringValue = look.title
    }
}

/// A connection: its name over its address, and a spinner while it connects.
final class SidebarBookmarkCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarBookmarkCell")
    private lazy var icon = makeIcon()
    private lazy var name = makeLabel(font: Self.titleFont, color: .labelColor)
    private lazy var address = makeLabel(font: Self.captionFont, color: .secondaryLabelColor)
    private let spinner = SidebarCellView.spinner()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        let lines = NSStackView(views: [name, address])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setViews([icon, lines], in: .leading)
        stack.setViews([spinner], in: .trailing)
        stack.detachesHiddenViews = true
        // The address gives way first, then the name.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        pinCentered(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        name.stringValue = look.title
        address.stringValue = look.detail ?? ""
        show(look.symbol, in: icon, tint: look.tint)
        Self.show(look.isBusy, in: spinner)
    }
}

/// A schema, table, view or column: its name and grey detail, and a spinner while it loads.
final class SidebarRowCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRowCell")
    private lazy var icon = makeIcon()
    private lazy var title = makeLabel(font: Self.titleFont, color: .labelColor)
    private lazy var detail = makeLabel(font: Self.captionFont, color: .tertiaryLabelColor)
    private let spinner = SidebarCellView.spinner()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setViews([icon, title, detail], in: .leading)
        stack.setCustomSpacing(4, after: title)
        stack.setViews([spinner], in: .trailing)
        stack.detachesHiddenViews = true
        // The detail gives way first, then the name.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        pinCentered(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        title.stringValue = look.title
        detail.stringValue = look.detail ?? ""
        detail.isHidden = look.detail == nil
        show(look.symbol, in: icon, tint: look.tint)
        Self.show(look.isBusy, in: spinner)
    }
}

/// A grey line such as "Loading…".
final class SidebarNoteCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarNoteCell")
    private lazy var icon = makeIcon()
    private lazy var label = makeLabel(font: Self.captionFont, color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.detachesHiddenViews = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pinCentered(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        label.stringValue = look.title
        show(look.symbol, in: icon, tint: .secondary)
    }
}

/// A red message that wraps, such as why a connect failed. You can select and copy it.
final class SidebarErrorCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarErrorCell")
    static let font = SidebarCellView.captionFont
    static let maximumLines = 6
    static let inset: CGFloat = 3

    private lazy var label = makeLabel(font: Self.font, color: .systemRed)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = Self.maximumLines
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        // The row height comes from `height(of:width:)`, so the frame wins over the text.
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        label.stringValue = look.title
    }

    /// The height the message needs at this width, at most `maximumLines` lines.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: max(width, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        return min(ceil(measured), lineHeight * CGFloat(maximumLines)) + 2 * inset
    }
}

/// The "Connect" button under a connection that is closed.
final class SidebarLinkCell: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarLinkCell")
    var onClick: () -> Void = {}
    private let button = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        button.isBordered = false
        button.font = Self.captionFont
        button.contentTintColor = .linkColor
        button.target = self
        button.action = #selector(clicked)
        button.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.setViews([button], in: .leading)
        pinCentered(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ look: SidebarLook) {
        button.title = look.title
    }

    @objc private func clicked() {
        onClick()
    }
}
