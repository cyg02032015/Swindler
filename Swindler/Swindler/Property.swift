import AXSwift
import PromiseKit

// An ugly workaround for the fact that you can't have generic protocols in Swift: a not-so-abstract
// class.
public class Property<Type> {
  public var value: Type { fatalError("not implemented") }

  public func refresh() -> Promise<Type> { fatalError("not implemented") }

  private init() { }
}

public class WriteableProperty<Type>: Property<Type> {
  override public var value: Type {
    get { fatalError("not implemented") }
    set { fatalError("not implemented") }
  }

  public func set(value: Type) -> Promise<Type> { fatalError("not implemented") }
}

// DELEGATE PATTERN, IT MUST BE
// writeValue -> Promise
// refreshValue -> Promise
// readInitialValue -> Promise<Type?>
// 
// on Property:
// internal var delegate - this won't be typesafe ???
// initializeValue (for external caller)

// or, maybe we just need to accept more repetition in OSXWindow with private type / public proxy


//public protocol PropertyType {
//  typealias Type
//
//  var value: Type { get }
//
//  func refresh() -> Promise<Type>
//
//  // func onChange(handler: WindowPropertyEventType)
//}
//
//public protocol WriteablePropertyType: PropertyType {
//  var value: Type { get set }
//
//  func set(value: Type) -> Promise<Type>
//  // func setNoVerify(value: Type) -> Promise<Void>
//}

protocol WindowPropertyNotifier: class {
  func notify<Event: WindowPropertyEventInternalType>(event: Event.Type, external: Bool, oldValue: Event.PropertyType, newValue: Event.PropertyType)
  func notifyInvalid()
}

// Since we have to use classes for differentiating read-only from read-write properties, we can't
// derive from the actual implementation read-only class in order to implement the read-write
// implementation (Swift doesn't have multiple class inheritance). So instead, I made this lovely
// protocol extension that mixes in the functionality. It avoids repetition of actual code, but
// adds a lot of redundancy to the class configurations...
protocol AXProp: class {
  typealias Type: Equatable
  typealias EventT: WindowPropertyEventInternalType
  typealias UIElement: UIElementType

  var notifier: WindowPropertyNotifier! { get }
  var axElement: UIElement { get }
  var attribute: AXSwift.Attribute { get }
  var value_: Type! { get set }
}
extension AXProp where EventT.PropertyType == Type {
  // Window will initialize all values from a single getMultipleAttributes call instead of issuing
  // a bunch of individual calls. Before this is called, the property MUST NOT be used.
  func initializeValue(value: Type) {
    assert(value_ == nil, "Property for AX attribute \(attribute) was re-initialized")
    value_ = value
  }
  func initializeValue(value: Any) {
    initializeValue(value as! Type)
  }

  private func refresh_() -> Promise<Type> {
    return Promise<Void>().thenInBackground({
      // TODO deal with optional attributes
      let newValue: Type = try self.axElement.attribute(self.attribute)!
      self.updateFromSystem(newValue)
      return newValue
      } as () throws -> Type)  // type inference gets confused without this, for some reason
  }

  func updateFromSystem(newValue: Type) {
    if value_ != newValue {
      let oldVal = value_
      value_ = newValue
      notifier.notify(EventT.self, external: true, oldValue: oldVal, newValue: newValue)
    }
  }
}

class AXProperty<
  Type: Equatable, Event: WindowPropertyEventInternalType, UIElement: UIElementType where Event.PropertyType == Type
>: Property<Type>, AXProp {
  // I DON'T UNDERSTAND why we can't just use Event, some Swift bug.
  typealias EventT = Event

  weak var notifier: WindowPropertyNotifier!
  let axElement: UIElement
  let attribute: AXSwift.Attribute


  init(_ axElement: UIElement, _ attribute: AXSwift.Attribute, notifier: WindowPropertyNotifier) {
    self.axElement = axElement
    self.attribute = attribute
    self.notifier = notifier
  }

  var value_: Type!
  override var value: Type { return value_ }

  override func refresh() -> Promise<Type> {
    return refresh_()
  }
}

class AXWriteableProperty<
    Type: Equatable, Event: WindowPropertyEventInternalType, UIElement: UIElementType where Event.PropertyType == Type
>: WriteableProperty<Type>, AXProp {
  typealias EventT = Event

  weak var notifier: WindowPropertyNotifier!
  let axElement: UIElement
  let attribute: AXSwift.Attribute

  init(_ axElement: UIElement, _ attribute: AXSwift.Attribute, notifier: WindowPropertyNotifier) {
    self.axElement = axElement
    self.attribute = attribute
    self.notifier = notifier
  }

  var value_: Type!
  override var value: Type {
    get { return value_ }
    set {
      do {
        try doSet(newValue)
      } catch {
        // errors are handled in doSet; no way to continue propagating them here
      }
    }
  }

  override func refresh() -> Promise<Type> {
    return refresh_()
  }

  override func set(newValue: Type) -> Promise<Type> {
    return Promise<Void>().thenInBackground {
      return try self.doSet(newValue)
    }
  }

  func doSet(newValue: Type) throws -> Type {
    // TODO: purge all events for this attribute? otherwise a notification could come through with an old value.
    do {
      try axElement.setAttribute(attribute, value: newValue)
      // Ask for the new value to find out what actually resulted
      let actual: Type = try axElement.attribute(attribute)!
      if value_ != actual {
        let oldVal = value_
        value_ = actual
        notifier.notify(Event.self, external: false, oldValue: oldVal, newValue: value_)
      }
      return actual
    } catch AXSwift.Error.InvalidUIElement {
      notifier.notifyInvalid()
      throw AXSwift.Error.InvalidUIElement
    } catch {
      // TODO: handle kAXErrorIllegalArgument, kAXErrorAttributeUnsupported, kAXErrorCannotComplete, kAXErrorNotImplemented
      unexpectedError(error, onElement: axElement)
      notifier.notifyInvalid()
      // Probably shouldn't rethrow here, just abort?
      throw error
    }
  }
}
