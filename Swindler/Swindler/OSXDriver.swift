import AXSwift
import PromiseKit

public var state: StateType = OSXState<UIElement, Application, Observer>()

// MARK: - Injectable protocols

protocol UIElementType: Equatable {
  func pid() throws -> pid_t
  func attribute<T>(attribute: Attribute) throws -> T?
  func setAttribute(attribute: Attribute, value: Any) throws
  func getMultipleAttributes(attributes: [AXSwift.Attribute]) throws -> [Attribute: Any]
}
extension AXSwift.UIElement: UIElementType { }

protocol ObserverType {
  typealias UIElement: UIElementType

  init(processID: pid_t, callback: (observer: Self, element: UIElement, notification: AXSwift.Notification) -> ()) throws
  func addNotification(notification: AXSwift.Notification, forElement: UIElement) throws
}
extension AXSwift.Observer: ObserverType {
  typealias UIElement = AXSwift.UIElement
}

protocol ApplicationType: UIElementType {
  typealias UIElement: UIElementType

  static func all() -> [Self]

  // Until the Swift type system improves, I don't see a way around this.
  var toElement: UIElement { get }
}
extension AXSwift.Application: ApplicationType {
  typealias UIElement = AXSwift.UIElement
  var toElement: UIElement { return self }
}

// MARK: - Internal protocols

protocol Notifier: class {
  func notify<Event: EventType>(event: Event)
}

// MARK: - Implementation

class OSXState<
    UIElement: UIElementType, Application: ApplicationType, Observer: ObserverType
    where Observer.UIElement == UIElement, Application.UIElement == UIElement
>: StateType, Notifier {
  typealias Window = OSXWindow<UIElement, Application, Observer>
  var applications: [Application] = []
  var observers: [Observer] = []
  var windows: [Window] = []

  // TODO: handle errors
  // TODO: fix strong ref cycle

  init() {
    print("Initializing Swindler")
    for app in Application.all() {
      do {
        let observer = try Observer(processID: app.pid(), callback: handleEvent)
        try observer.addNotification(.WindowCreated,     forElement: app.toElement)
        try observer.addNotification(.MainWindowChanged, forElement: app.toElement)

        applications.append(app)
        observers.append(observer)
      } catch {
        // TODO: handle timeouts
        let application = try? NSRunningApplication(processIdentifier: app.pid())
        print("Could not watch application \(application): \(error)")
        assert(error is AXSwift.Error)
      }
    }
    print("Done initializing")
  }

  private func handleEvent(observer observer: Observer, element: UIElement, notification: AXSwift.Notification) {
    if .WindowCreated == notification {
      onWindowCreated(element, observer: observer)
      return
    }

    let handled = onWindowEvent(notification, windowElement: element, observer: observer)
    if !handled {
      print("Event \(notification) on unknown element \(element)")
    }
  }

  private func onWindowCreated(windowElement: UIElement, observer: Observer) {
    do {
      let window = try Window(notifier: self, axElement: windowElement, observer: observer)
      windows.append(window)
      // TODO: wait until window is ready
      notify(WindowCreatedEvent(external: true, window: window))
    } catch {
      // TODO: handle timeouts
      print("Error: Could not watch [\(windowElement)]: \(error)")
      assert(error is AXSwift.Error || error is OSXDriverError)
    }
  }

  private func onWindowEvent(notification: AXSwift.Notification, windowElement: UIElement, observer: Observer) -> Bool {
    guard let (index, window) = findWindowAndIndex(windowElement) else {
      return false
    }

    window.handleEvent(notification, observer: observer)

    if .UIElementDestroyed == notification {
      windows.removeAtIndex(index)
      notify(WindowDestroyedEvent(external: true, window: window))
    }

    return true
  }

  private func findWindowAndIndex(axElement: UIElement) -> (Int, Window)? {
    return windows.enumerate().filter({ $0.1.axElement == axElement }).first
  }

  var visibleWindows: [WindowType] {
    return windows.map({ $0 as WindowType })
  }

  private typealias EventHandler = (EventType) -> ()
  private var eventHandlers: [String: [EventHandler]] = [:]

  func on<Event: EventType>(handler: (Event) -> ()) {
    let notification = Event.typeName
    if eventHandlers[notification] == nil {
      eventHandlers[notification] = []
    }

    // Wrap in a casting closure to preserve type information that gets erased in the dictionary.
    eventHandlers[notification]!.append({ handler($0 as! Event) })
  }

  func notify<Event: EventType>(event: Event) {
    if let handlers = eventHandlers[Event.typeName] {
      for handler in handlers {
        handler(event)
      }
    }
  }
}

enum OSXDriverError: ErrorType {
  case MissingAttributes
}

protocol AXPropertyType {
  var attribute: AXSwift.Attribute { get }
  func refresh()
  func initializeValue(value: Any)
}
extension AXProperty: AXPropertyType {
  func refresh() {
    let _: Promise<Type> = refresh()
  }
}
extension AXWriteableProperty: AXPropertyType {
  func refresh() {
    let _: Promise<Type> = refresh()
  }
}

class OSXWindow<
    UIElement: UIElementType, Application: ApplicationType, Observer: ObserverType
    where Observer.UIElement == UIElement, Application.UIElement == UIElement
>: WindowType, WindowPropertyNotifier {
  typealias State = OSXState<UIElement, Application, Observer>
  let notifier: Notifier
  let axElement: UIElement

  init(notifier: Notifier, axElement: UIElement, observer: Observer) throws {
    self.notifier = notifier
    self.axElement = axElement

    try loadAttributes()

    try observer.addNotification(.UIElementDestroyed, forElement: axElement)
    try observer.addNotification(.Moved, forElement: axElement)
    try observer.addNotification(.Resized, forElement: axElement)
    try observer.addNotification(.TitleChanged, forElement: axElement)
  }

  func handleEvent(event: AXSwift.Notification, observer: Observer) {
    switch event {
    case .UIElementDestroyed:
      valid = false
    default:
      if let property = watchedAxProperties[event] {
        property.refresh()
      } else {
        print("Unknown event on \(self): \(event)")
      }
    }
  }

  private(set) var valid: Bool = true

  var pos: AXWriteableProperty<CGPoint, WindowPosChangedEvent, UIElement>
  var size: AXWriteableProperty<CGSize, WindowSizeChangedEvent, UIElement>
  var title: AXProperty<String, WindowTitleChangedEvent, UIElement>

  var watchedAxProperties: [AXSwift.Notification: AXPropertyType]

  private func loadAttributes() throws {
    pos = AXWriteableProperty(axElement, .Position, notifier: self)
    size = AXWriteableProperty(axElement, .Size, notifier: self)
    title = AXProperty(axElement, .Title, notifier: self)

    watchedAxProperties = [
      .Moved: pos,
      .Resized: size,
      .TitleChanged: title
    ]

    let axProperties = watchedAxProperties.values
    let attrNames: [Attribute] = axProperties.map({ $0.attribute })
    let attributes = try axElement.getMultipleAttributes(attrNames)

    axProperties.forEach { property in
      if let value = attributes[property.attribute] {
        property.initializeValue(value)
      }
    }

    guard attributes.count == attrNames.count else {
      print("Could not get required attributes for window. Wanted: \(attrNames). Got: \(attributes.keys)")
      throw OSXDriverError.MissingAttributes
    }
  }

  func notify<Event: WindowPropertyEventInternalType>(event: Event.Type, external: Bool, oldValue: Event.PropertyType, newValue: Event.PropertyType) {
    notifier.notify(Event(external: external, window: self, oldVal: oldValue, newVal: newValue))
  }

  func notifyInvalid() {
    valid = false
  }
}

// MARK: - Error handling

// Handle unexpected errors with detailed logging, and abort when in debug mode.
func unexpectedError(error: ErrorType, file: String = __FILE__, line: Int = __LINE__) {
  print("unexpected error: \(error) at \(file):\(line)")
  assertionFailure()
}
func unexpectedError<UIElement: UIElementType>(
    error: ErrorType, onElement element: UIElement, file: String = __FILE__, line: Int = __LINE__) {
  let application = try? NSRunningApplication(processIdentifier: element.pid())
  print("unexpected error: \(error) on element: \(element) of application: \(application) at \(file):\(line)")
  assertionFailure()
}
