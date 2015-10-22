public protocol State {
  func visibleWindows() -> [Window]
}

public protocol Window {
  func rect() -> Rect
  func setRect(rect: Rect)
}

public struct Rect {
  public var x: Int;
  public var y: Int;
  public var w: Int;
  public var h: Int;
}