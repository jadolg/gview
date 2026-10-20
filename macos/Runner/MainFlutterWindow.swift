import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate, UNUserNotificationCenterDelegate {
  private var channel: FlutterMethodChannel!
  private var statusItem: NSStatusItem!
  private var activity: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    setFrameAutosaveName("MainWindow")
    // State restoration would reopen the window hidden after a close-to-menu-bar.
    isRestorable = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    channel = FlutterMethodChannel(name: "gview/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "drag":
        if let event = NSApp.currentEvent { self.performDrag(with: event) }
      case "status":
        self.statusItem.button?.title = call.arguments as? String ?? ""
      case "notify":
        let args = call.arguments as? [String: String] ?? [:]
        let content = UNMutableNotificationContent()
        content.title = args["title"] ?? ""
        content.body = args["body"] ?? ""
        content.userInfo = ["url": args["url"] ?? ""]
        content.sound = .default
        UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
      default:
        break
      }
      result(nil)
    }

    delegate = self
    setUpStatusItem()
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    // App Nap throttles timers of apps with no visible window, which would stall the Dart poll loop.
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "Polling GitLab")

    super.awakeFromNib()
  }

  private func setUpStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(named: "Tray")
    statusItem.button?.imagePosition = .imageLeading
    let menu = NSMenu()
    menu.addItem(withTitle: "Open gview", action: #selector(showWindow), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit gview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
  }

  @objc func showWindow() {
    NSApp.setActivationPolicy(.regular)
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func refresh() {
    channel.invokeMethod("refresh", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    return false
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let s = response.notification.request.content.userInfo["url"] as? String,
      let url = URL(string: s), !s.isEmpty
    {
      NSWorkspace.shared.open(url)
    } else {
      showWindow()
    }
    completionHandler()
  }
}
