import AXSwift
import PromiseKit

protocol WindowPropertyNotifier: class {
  func notify<Event: WindowPropertyEventTypeInternal>(event: Event.Type, external: Bool, oldValue: Event.PropertyType, newValue: Event.PropertyType)
  func notifyInvalid()
}

protocol PropertyDelegate {
  typealias T: Equatable
  func writeValue(newValue: T) throws
  func readValue() throws -> T

  // Returns a promise of the property's initial value. It's the responsibility of whoever defines
  // the property to ensure that the property is not accessed before this promise resolves.
  // We could make this optional and use `readValue()` otherwise.
  func initialize() -> Promise<T>
}

// If the underlying UI object becomes invalid, throw a PropertyError.Invalid which wraps a public
// error type from your delegate. The unwrapped error will be presented to the user.
enum PropertyError: ErrorType {
  case Invalid(error: ErrorType)
}

public class Property<Type: Equatable> {
  private var value_: Type!
  private var notifier: PropertyNotifierThunk<Type>
  private var delegate_: PropertyDelegateThunk<Type>

  public var value: Type { return value_ }
  private(set) var delegate: Any
  private(set) var initialized: Promise<Void>

  init<Event: WindowPropertyEventTypeInternal, Impl: PropertyDelegate where Event.PropertyType == Type, Impl.T == Type>(_ eventType: Event.Type, _ notifier: WindowPropertyNotifier, _ delegate: Impl) {
    self.notifier = PropertyNotifierThunk<Type>(eventType, notifier)
    self.delegate = delegate
    self.delegate_ = PropertyDelegateThunk(delegate)

    let (initialized, fulfill, _) = Promise<Void>.pendingPromise()
    self.initialized = initialized
    delegate.initialize().then({ value in
      self.value_ = value
      fulfill()
    })
  }

  public func refresh() -> Promise<Type> {
    return Promise<Void>().thenInBackground({
      do {
        let oldValue = self.value_
        self.value_ = try self.delegate_.readValue()
        if self.value_ != oldValue {
          self.notifier.notify(external: true, oldValue: oldValue, newValue: self.value_)
        }
        return self.value_
      } catch PropertyError.Invalid(let wrappedError) {
        self.notifier.notifyInvalid()
        throw wrappedError
      }
    } as () throws -> Type)  // type inference gets confused without this, for some reason
    // TODO handle invalid
  }
}

public class WriteableProperty<Type: Equatable>: Property<Type> {
  override public var value: Type {
    get { return value_ }
    set { set(newValue) }
  }

  override init<Event: WindowPropertyEventTypeInternal, Impl: PropertyDelegate where Event.PropertyType == Type, Impl.T == Type>(_ eventType: Event.Type, _ notifier: WindowPropertyNotifier, _ delegate: Impl) {
    super.init(eventType, notifier, delegate)
  }

  public func set(newValue: Type) -> Promise<Type> {
    return Promise<Void>().thenInBackground({
      do {
        try self.delegate_.writeValue(newValue)
        let actual = try self.delegate_.readValue()

        if actual != self.value_ {
          let oldValue = self.value_
          self.value_ = actual
          self.notifier.notify(external: false, oldValue: oldValue, newValue: actual)
        }

        return actual
      } catch PropertyError.Invalid(let wrappedError) {
        print("Marking invalid")
        self.notifier.notifyInvalid()
        throw wrappedError
      } catch {
        print("error caught: \(error)")
        throw error
      }
    } as () throws -> (Type))
  }
}

// Because Swift doesn't have generic protocols, we have to use these ugly thunks to simulate them.
// Hopefully this will be addressed in a future Swift release.

private struct PropertyDelegateThunk<Type: Equatable>: PropertyDelegate {
  init<Impl: PropertyDelegate where Impl.T == Type>(_ impl: Impl) {
    writeValue_ = impl.writeValue
    readValue_ = impl.readValue
    initialize_ = impl.initialize
  }

  let writeValue_: (newValue: Type) throws -> ()
  let readValue_: () throws -> Type
  let initialize_: () -> Promise<Type>

  func writeValue(newValue: Type) throws { try writeValue_(newValue: newValue) }
  func readValue() throws -> Type { return try readValue_() }
  func initialize() -> Promise<Type> { return initialize_() }
}

class PropertyNotifierThunk<PropertyType: Equatable> {
  let wrappedNotifier: WindowPropertyNotifier
  let notify_: (external: Bool, oldValue: PropertyType, newValue: PropertyType) -> ()

  init<Event: WindowPropertyEventTypeInternal where Event.PropertyType == PropertyType>(_ eventType: Event.Type, _ wrappedNotifier: WindowPropertyNotifier) {
    self.wrappedNotifier = wrappedNotifier

    notify_ = { (external: Bool, oldValue: PropertyType, newValue: PropertyType) in
      wrappedNotifier.notify(Event.self, external: external, oldValue: oldValue, newValue: newValue)
    }
  }

  func notify(external external: Bool, oldValue: PropertyType, newValue: PropertyType) {
    notify_(external: external, oldValue: oldValue, newValue: newValue)
  }
  func notifyInvalid() {
    wrappedNotifier.notifyInvalid()
  }
}
