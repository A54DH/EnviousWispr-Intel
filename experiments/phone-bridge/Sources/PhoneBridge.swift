#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import CoreImage
import CryptoKit
import Security

private func randomHex(_ count: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw BridgeError(500, "Could not create a secure pairing token. Restart the app.")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private struct ArmedTarget {
    let ticket: String
    let deadline: TimeInterval
    let name: String
    let process: pid_t?
    let element: AXUIElement?
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var addressPicker: NSPopUpButton!
    var statusLabel: NSTextField!
    var linkField: NSTextField!
    var qrView: NSImageView!
    var pasteBox: NSButton!
    var startButton: NSButton!
    var server: LANServer!
    var addresses: [(name: String, address: String)] = []
    var host = ""
    var secret = ""
    var pairedClient: String?
    var pendingClient: String?
    var target: ArmedTarget?
    var ledger = DeliveryLedger()
    var autoPaste = false
    var expiry: Timer?
    var requestTimes: [TimeInterval] = []
    var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = LANServer { [weak self] request in
            self?.route(request) ?? .error(BridgeError(503, "Receiver stopped."))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Phone→Mac"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Open PhoneBridge…", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let stop = NSMenuItem(title: "Stop receiving", action: #selector(stopReceiver), keyEquivalent: "")
        stop.target = self; menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PhoneBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        buildWindow()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stopReceiver() })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.stopReceiver() })
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return field
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PhoneBridge · local prototype"
        window.isReleasedWhenClosed = false
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        window.contentView!.addSubview(scroll)
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 520, height: 940))
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24)
        ])
        stack.addArrangedSubview(label("Your phone speaks. Your Mac receives.", size: 21, bold: true))
        let warning = label("TRUSTED HOME WI-FI ONLY\nThis prototype sends text over unencrypted HTTP. Pairing is not encryption. Do not use passwords, confidential text, shared/public Wi-Fi, or port forwarding.")
        warning.textColor = .systemOrange
        stack.addArrangedSubview(warning)
        addresses = localAddresses()
        addressPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        if addresses.isEmpty { addressPicker.addItem(withTitle: "No private network found — connect to Wi-Fi and reopen the app") }
        else { addresses.forEach { addressPicker.addItem(withTitle: "\($0.address) (\($0.name))") } }
        stack.addArrangedSubview(addressPicker)
        startButton = NSButton(title: "Start on my trusted Wi-Fi", target: self, action: #selector(startReceiver))
        startButton.bezelStyle = .rounded; stack.addArrangedSubview(startButton)
        pasteBox = NSButton(checkboxWithTitle: "Enable automatic paste (requires Accessibility)", target: self, action: #selector(togglePaste))
        stack.addArrangedSubview(pasteBox)
        stack.addArrangedSubview(label("Default: copy to the Mac clipboard only. To insert automatically, enable paste, allow PhoneBridge in Accessibility, then click this checkbox again."))
        qrView = NSImageView()
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.widthAnchor.constraint(equalToConstant: 216).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 216).isActive = true
        stack.addArrangedSubview(qrView)
        linkField = label("Start the receiver to create a one-session QR code.")
        linkField.isSelectable = true
        linkField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(linkField)
        statusLabel = label("Stopped. No connection is listening.", bold: true)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(label("Scan with the iPhone Camera and open in Safari. Approve the phone here. Then click a text field on your Mac and choose it from the phone page. Receiving stops after 30 minutes, on sleep, or when you press Stop."))
        let stop = NSButton(title: "Stop receiving / forget phone", target: self, action: #selector(stopReceiver))
        stop.bezelStyle = .rounded; stack.addArrangedSubview(stop)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
    }

    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func togglePaste() {
        target = nil
        if pasteBox.state == .on {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            autoPaste = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            if !autoPaste {
                pasteBox.state = .off
                statusLabel.stringValue = "Allow PhoneBridge in System Settings → Privacy & Security → Accessibility, then enable paste here again."
            } else { statusLabel.stringValue = "Paste enabled. Click your Mac destination, then choose it on the phone." }
        } else { autoPaste = false; statusLabel.stringValue = "Copy-only mode. No keyboard events will be sent." }
    }
    @objc func startReceiver() {
        stopReceiver()
        guard addresses.indices.contains(addressPicker.indexOfSelectedItem) else {
            statusLabel.stringValue = "Connect to a private Wi-Fi/Ethernet network and reopen PhoneBridge."; return
        }
        do {
            secret = try randomHex(32)
            startButton.isEnabled = false; addressPicker.isEnabled = false
            try server.start(address: addresses[addressPicker.indexOfSelectedItem].address, ready: { [weak self] host in
                guard let self = self else { return }
                self.host = host
                let link = "http://\(host)/#\(self.secret)"
                self.linkField.stringValue = link
                if let filter = CIFilter(name: "CIQRCodeGenerator") {
                    filter.setValue(Data(link.utf8), forKey: "inputMessage")
                    filter.setValue("M", forKey: "inputCorrectionLevel")
                    if let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                       let cg = CIContext().createCGImage(image, from: image.extent) {
                        let qr = NSImage(size: NSSize(width: 216, height: 216))
                        qr.lockFocus()
                        NSColor.white.setFill()
                        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 216, height: 216)).fill()
                        NSGraphicsContext.current?.imageInterpolation = .none
                        NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 16, y: 16, width: 184, height: 184))
                        qr.unlockFocus()
                        self.qrView.image = qr
                    }
                }
                self.statusLabel.stringValue = "Scan this QR code with your iPhone. Awaiting pairing."
                self.expiry = Timer.scheduledTimer(withTimeInterval: 1800, repeats: false) { [weak self] _ in self?.stopReceiver() }
            }, failed: { [weak self] in
                self?.stopReceiver()
                self?.statusLabel.stringValue = "Could not listen on that address. Check Wi-Fi, firewall and Local Network permission."
            })
        } catch { stopReceiver(); statusLabel.stringValue = "Receiver could not start. Check your local network and try again." }
    }
    @objc func stopReceiver() {
        expiry?.invalidate(); expiry = nil
        server?.stop(); host = ""; secret = ""; pairedClient = nil; pendingClient = nil
        target = nil; ledger = DeliveryLedger(); requestTimes.removeAll()
        qrView?.image = nil; linkField?.stringValue = "Stopped. Start again for a new QR code."
        statusLabel?.stringValue = "Stopped. Previous pairing and send IDs are no longer accepted."
        startButton?.isEnabled = true; addressPicker?.isEnabled = true
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        do {
            guard !host.isEmpty, request.headers["host"] == host else { throw BridgeError(403, "Wrong or stopped receiver.") }
            let now = ProcessInfo.processInfo.systemUptime
            requestTimes.removeAll { now - $0 > 1 }
            guard requestTimes.count < 30 else { throw BridgeError(429, "Too many requests. Try again shortly.") }
            requestTimes.append(now)
            let files: [String: (String, String)] = [
                "/": ("index.html", "text/html; charset=utf-8"),
                "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                "/style.css": ("style.css", "text/css; charset=utf-8")
            ]
            if request.method == "GET", let file = files[request.path] {
                guard let resource = Bundle.main.resourceURL?.appendingPathComponent("Web").appendingPathComponent(file.0),
                      let bytes = try? Data(contentsOf: resource) else { throw BridgeError(500, "Webpage missing. Rebuild the app.") }
                return HTTPResponse(status: 200, type: file.1, body: bytes)
            }
            let client = try AccessPolicy.authorize(request, host: host, secret: secret)
            if request.path == "/api/connect", request.method == "POST" {
                if pairedClient == client { return .json(200, ["paired": true]) }
                guard pairedClient == nil, pendingClient == nil || pendingClient == client else {
                    throw BridgeError(403, "Another browser is paired or awaiting approval. Restart the receiver to change phones.")
                }
                if pendingClient == nil { pendingClient = client; requestApproval(client) }
                return .json(202, ["paired": false, "message": "Approve this browser on your Mac."])
            }
            if request.path == "/api/status", request.method == "GET" {
                return .json(200, ["paired": pairedClient == client, "mode": autoPaste ? "paste" : "clipboard"])
            }
            guard pairedClient == client else { throw BridgeError(403, "Approve this browser on the Mac first.") }
            if request.path == "/api/arm", request.method == "POST" {
                target = nil
                let armed = try captureTarget()
                target = armed
                return .json(200, ["ticket": armed.ticket, "target": armed.name, "expiresIn": 120,
                                   "mode": armed.process == nil ? "clipboard" : "paste"])
            }
            if request.path == "/api/send", request.method == "POST" { return try send(request.body) }
            throw BridgeError(404, "Not found.")
        } catch let error as BridgeError { return .error(error) }
        catch { return .error(BridgeError(400, "Invalid request.")) }
    }

    private func requestApproval(_ client: String) {
        let session = secret
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.secret == session else { return }
            self.showWindow()
            let alert = NSAlert()
            alert.messageText = "Allow the phone you just scanned with?"
            alert.informativeText = "Only approve if you opened the current QR code yourself. This grants this browser permission to send text for this session. The connection is not encrypted."
            alert.addButton(withTitle: "Allow this browser"); alert.addButton(withTitle: "Deny and stop")
            alert.beginSheetModal(for: self.window) { [weak self] result in
                guard let self = self, self.secret == session else { return }
                if result == .alertFirstButtonReturn {
                    self.pairedClient = client; self.pendingClient = nil
                    self.statusLabel.stringValue = "Paired. Click a text field in TextEdit, then choose the target on your phone."
                } else { self.stopReceiver() }
            }
        }
    }

    private func focusedElement(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func allowedElement(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = attribute(element, kAXSubroleAttribute as String) ?? ""
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
            && subrole != "AXSecureTextField"
    }
    private func captureTarget() throws -> ArmedTarget {
        let ticket = try randomHex(16)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        if !autoPaste { return ArmedTarget(ticket: ticket, deadline: deadline, name: "Mac clipboard", process: nil, element: nil) }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            throw BridgeError(409, "Enable Accessibility for PhoneBridge, or turn off automatic paste for copy-only mode.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw BridgeError(409, "Click inside your destination document on the Mac first.")
        }
        let blocked = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
        guard !blocked.contains(app.bundleIdentifier ?? ""), let element = focusedElement(app.processIdentifier), allowedElement(element) else {
            throw BridgeError(409, "Choose a normal text field, such as a TextEdit document. Terminal and password fields are not supported. Use copy-only mode for other apps.")
        }
        return ArmedTarget(ticket: ticket, deadline: deadline, name: app.localizedName ?? "Selected Mac app",
                           process: app.processIdentifier, element: element)
    }
    private func canPaste(_ armed: ArmedTarget) -> Bool {
        guard autoPaste, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let pid = armed.process, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let old = armed.element, let current = focusedElement(pid), CFEqual(old, current), allowedElement(current)
        else { return false }
        let held = CGEventSource.flagsState(.combinedSessionState)
        return held.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
    private func send(_ data: Data) throws -> HTTPResponse {
        struct Payload: Decodable { let id: String; let ticket: String; let text: String }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try AccessPolicy.validateText(payload.text)
        guard AccessPolicy.validID(payload.ticket) else { throw BridgeError(400, "Choose a target first.") }
        let fingerprint = SHA256.hash(data: Data((payload.ticket + "\u{0}" + payload.text).utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let old = try ledger.lookup(payload.id, fingerprint: fingerprint) { return old }
        guard let armed = target, armed.ticket == payload.ticket,
              ProcessInfo.processInfo.systemUptime <= armed.deadline else {
            throw BridgeError(409, "Target expired or changed. Choose the target again; your text has not been sent by this request.")
        }
        // Consume before any side effects. All routes and delivery run serially on the main queue.
        target = nil
        let shouldPaste = armed.process != nil && canPaste(armed)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(payload.text, forType: .string) else {
            let response = HTTPResponse.error(BridgeError(500, "Mac clipboard write failed. Check the Mac before trying again."))
            ledger.record(payload.id, fingerprint: fingerprint, response: response)
            return response
        }
        var kind = "clipboard"
        var message = "Copied to the Mac clipboard. Press Command–V in your document."
        if shouldPaste, canPaste(armed),
           let source = CGEventSource(stateID: .combinedSessionState),
           let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            down.flags = .maskCommand; up.flags = .maskCommand
            // Do not activate an application, synthesize Return, or resend partial transcripts.
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            kind = "paste_requested"
            message = "Paste shortcut sent to \(armed.name). Check the Mac; if it did not insert, press Command–V."
        } else if armed.process != nil {
            message = "Target or permission changed. Copied only — nothing was automatically pasted. Press Command–V where you want it."
        }
        let response = HTTPResponse.json(200, ["id": payload.id, "result": kind, "message": message])
        ledger.record(payload.id, fingerprint: fingerprint, response: response)
        statusLabel.stringValue = kind == "paste_requested" ? "Paste requested. Check the destination document." : "Text copied to the Mac clipboard."
        return response
    }
}

@main
private enum PhoneBridgeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
