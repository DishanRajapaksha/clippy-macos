//
//  AgentBalloonViewController.swift
//  Clippy macOS
//
//  Created by Devran on 09.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

class BalloonViewController: NSViewController {
    private let text: String
    private let balloon: AgentBalloon?
    private let label = NSTextField(labelWithString: "")
    let contentSize: CGSize

    init(text: String, balloon: AgentBalloon? = nil) {
        self.text = text
        self.balloon = balloon
        self.contentSize = BalloonViewController.measure(text: text, balloon: balloon)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = BalloonBackgroundView(frame: NSRect(origin: .zero, size: contentSize))
        container.fillColor = balloon?.backgroundNSColor ?? NSColor.windowBackgroundColor
        container.strokeColor = balloon?.borderNSColor ?? NSColor.separatorColor

        label.stringValue = text
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.textColor = balloon?.foregroundNSColor ?? .labelColor
        label.font = balloon?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.frame = NSRect(x: 12, y: 22, width: contentSize.width - 24, height: contentSize.height - 34)
        container.addSubview(label)

        view = container
    }

    private static func measure(text: String, balloon: AgentBalloon?) -> CGSize {
        let font = balloon?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let targetWidth = CGFloat(max(balloon?.charactersPerLine ?? 28, 12)) * max(font.pointSize * 0.55, 7)
        let maxWidth = min(max(targetWidth, 180), 360)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: NSSize(width: maxWidth - 24, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lines = max(CGFloat(balloon?.numberOfLines ?? 1), ceil(bounds.height / max(font.lineHeight, 1)))
        let height = max(60, lines * font.lineHeight + 34)
        return CGSize(width: maxWidth, height: min(height, 180))
    }
}

private class BalloonBackgroundView: NSView {
    var fillColor: NSColor = .windowBackgroundColor
    var strokeColor: NSColor = .separatorColor

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bubbleRect = bounds.insetBy(dx: 1, dy: 1).insetBy(dx: 0, dy: 10)
        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 10, yRadius: 10)
        let tail = NSBezierPath()
        let tailX = bubbleRect.midX
        tail.move(to: NSPoint(x: tailX - 10, y: bubbleRect.maxY - 1))
        tail.line(to: NSPoint(x: tailX + 10, y: bubbleRect.maxY - 1))
        tail.line(to: NSPoint(x: tailX, y: bounds.maxY - 1))
        tail.close()

        fillColor.setFill()
        path.fill()
        tail.fill()

        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        tail.lineWidth = 1
        tail.stroke()
    }
}

private extension AgentBalloon {
    var font: NSFont {
        NSFont(name: fontName, size: CGFloat(max(fontHeight, 10))) ?? NSFont.systemFont(ofSize: CGFloat(max(fontHeight, 10)))
    }

    var foregroundNSColor: NSColor? {
        Self.color(from: foregroundColor)
    }

    var backgroundNSColor: NSColor? {
        Self.color(from: backgroundColor)
    }

    var borderNSColor: NSColor? {
        Self.color(from: borderColor)
    }

    static func color(from colorRef: String) -> NSColor? {
        let hex = colorRef.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let red = CGFloat(value & 0x0000ff) / 255.0
        let green = CGFloat((value & 0x00ff00) >> 8) / 255.0
        let blue = CGFloat((value & 0xff0000) >> 16) / 255.0
        return NSColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

private extension NSFont {
    var lineHeight: CGFloat {
        ascender - descender + leading
    }
}
