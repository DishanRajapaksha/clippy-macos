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
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        label.stringValue = text
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 12, width: 236, height: 56)
        container.addSubview(label)

        view = container
    }
}
