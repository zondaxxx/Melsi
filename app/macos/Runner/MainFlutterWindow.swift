import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.title = "Melsi"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.remove(.fullSizeContentView)
    self.minSize = NSSize(width: 880, height: 600)

    let size = NSSize(width: 1100, height: 720)
    if let screen = self.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let width = min(size.width, visible.width)
      let height = min(size.height, visible.height)
      let origin = NSPoint(
        x: visible.origin.x + (visible.width - width) / 2,
        y: visible.origin.y + (visible.height - height) / 2
      )
      self.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    } else {
      self.setContentSize(size)
      self.center()
    }
    // Remember the user's size/position between launches.
    self.setFrameAutosaveName("MelsiMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
