import AXSwift

public var state: State = OSXState()

class OSXState: State {
  var applications: [Application] = []
  var observers: [Observer] = []
  var windows: [OSXWindow] = []

  // TODO: fix strong ref cycle

  init() {
    let app = Application.allForBundleID("com.apple.finder").first!
    print("app attrs: \(try! app.attributes())")
    let observer = app.createObserver() { (observer, element, notification) in
      if notification == .WindowCreated {
        self.windows.append(try! OSXWindow(axElement: element, observer: observer))
      } else if let (index, target) = self.findWindowAndIndex(element) {
        if notification == .UIElementDestroyed {
          self.windows.removeAtIndex(index)
        }
        target.onEvent(observer, event: notification)
      } else {
        print("Event \(notification) on unknown element \(element)")
      }
    }!
    try! observer.addNotification(.WindowCreated,     forElement: app)
    try! observer.addNotification(.MainWindowChanged, forElement: app)
    observer.start()

    applications.append(app)
    observers.append(observer)
  }

  func visibleWindows() -> [Window] {
    return windows
  }

  private func findWindowAndIndex(axElement: UIElement) -> (Int, OSXWindow)? {
    return self.windows.enumerate().filter({ $0.1.axElement == axElement }).first
  }
}

class OSXWindow: Window {
  let axElement: UIElement

  var rect_: Rect!

  init(axElement: UIElement, observer: Observer) throws {
    self.axElement = axElement
    try getAttributes()
    let attrs = try! axElement.attributes()
    print("new window, attrs: \(attrs)")
    print("- settable: \(attrs.filter({ try! axElement.attributeIsSettable($0) }))")

    do {
      try observer.addNotification(.UIElementDestroyed, forElement: axElement)
      try observer.addNotification(.Moved, forElement: axElement)
    } catch let error {
      NSLog("Error: Could not watch [\(axElement)]: \(error)")
    }

    print("- rect: \(rect_)")
  }

  private func getAttributes() throws {
    let attrNames: [Attribute] = [.Position, .Size]
    let attributes = try axElement.getMultipleAttributes(attrNames)

    guard attributes.count == attrNames.count else {
      NSLog("Could not get required attributes for window. Wanted: \(attrNames). Got: \(attributes.keys)")
      throw AXSwift.Error.InvalidUIElement  // TODO: make our own
    }

    let pos  = attributes[.Position]! as! CGPoint
    let size = attributes[.Size]! as! CGSize
    rect_ = Rect(x: Int(pos.x), y: Int(pos.y), w: Int(size.width), h: Int(size.height))
  }

  func onEvent(observer: Observer, event: Notification) {
    print("\(axElement): \(event)")
    if event == .Moved {
      if let pos: CGPoint = try! axElement.attribute(.Position) {
        rect_.x = Int(pos.x)
        rect_.y = Int(pos.y)
        print("- rect: \(rect_)")
      }
    }
  }

  func rect() -> Rect {
    return rect_
  }

  func setRect(rect: Rect) {
    do {
      try axElement.setAttribute(Attribute.Position, value: NSValue(point: NSPoint(x: rect_.x, y: rect_.y)))
      try axElement.setAttribute(Attribute.Size, value: NSValue(size: NSSize(width: rect_.w, height: rect_.h)))
    } catch {}
  }
}
