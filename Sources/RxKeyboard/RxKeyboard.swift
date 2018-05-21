//
//  RxKeyboard.swift
//  RxKeyboard
//
//  Created by Suyeol Jeon on 09/10/2016.
//  Copyright © 2016 Suyeol Jeon. All rights reserved.
//

#if os(iOS)
import UIKit

import RxCocoa
import RxSwift

public protocol KeyboardStateType {
  var frame: CGRect { get }
  var animationDuration: Double { get }
}

public protocol RxKeyboardType {
  var frame: Driver<CGRect> { get }
  var willChangeHeightWithAnimation: Driver<KeyboardStateType> { get }
  var visibleHeight: Driver<CGFloat> { get }
  var willShowVisibleHeight: Driver<CGFloat> { get }
  var isHidden: Driver<Bool> { get }
}

struct KeyboardState: KeyboardStateType {
  let frame: CGRect
  let animationDuration: Double
  
  init(frame: CGRect, duration: Double) {
    self.frame = frame
    self.animationDuration = duration
  }
  
  func mutateTopPosition(_ positionMutator: (CGFloat) -> (CGFloat)) -> KeyboardState {
    var newFrame = self.frame
    newFrame.origin.y = positionMutator(self.frame.origin.y)
    return KeyboardState(frame: newFrame, duration: self.animationDuration)
  }
}

extension KeyboardState {
  init(fromNotification notification : Notification) {
    let rectValue = notification.userInfo?[UIKeyboardFrameEndUserInfoKey] as? NSValue
    self.frame = rectValue?.cgRectValue ?? CGRect.null
    let animationDuratonValue = notification.userInfo?[UIKeyboardAnimationDurationUserInfoKey] as? Double
    self.animationDuration = animationDuratonValue ?? 0.0
  }
}

extension KeyboardState {
  init() {
    self.frame = CGRect(
      x: 0,
      y: UIScreen.main.bounds.height,
      width: UIScreen.main.bounds.width,
      height: 0
    )
    self.animationDuration = 0.0
  }
}

/// RxKeyboard provides a reactive way of observing keyboard frame changes.
public class RxKeyboard: NSObject, RxKeyboardType {

  // MARK: Public

  /// Get a singleton instance.
  public static let instance = RxKeyboard()

  /// An observable keyboard frame.
  public let frame: Driver<CGRect>

  /// An observable visible height of keyboard with animation duration. Emits keyboard height with animation duration if the keyboard is visible
  /// or `0` if the keyboard is not visible.
  public let willChangeHeightWithAnimation: Driver<KeyboardStateType>
    
  /// An observable visible height of keyboard. Emits keyboard height if the keyboard is visible
  /// or `0` if the keyboard is not visible.
  public let visibleHeight: Driver<CGFloat>

  /// Same with `visibleHeight` but only emits values when keyboard is about to show. This is
  /// useful when adjusting scroll view content offset.
  public let willShowVisibleHeight: Driver<CGFloat>
  
  /// An observable visibility of keyboard. Emits keyboard visibility
  /// when changed keyboard show and hide.
  public let isHidden: Driver<Bool>

  // MARK: Private

  private let disposeBag = DisposeBag()
  private let panRecognizer = UIPanGestureRecognizer()


  // MARK: Initializing

  override init() {

    let stateVariable = BehaviorRelay<KeyboardState>(value: KeyboardState())
    let frameVariable = stateVariable.map { $0.frame }
    self.frame = frameVariable.asDriver().distinctUntilChanged()
    self.visibleHeight = self.frame.map { UIScreen.main.bounds.height - $0.origin.y }
    self.willChangeHeightWithAnimation = stateVariable
      .map { state -> KeyboardState in
        return state.mutateTopPosition { yPos in UIScreen.main.bounds.height - yPos }
      }
      .asDriver()
    self.willShowVisibleHeight = self.visibleHeight
      .scan((visibleHeight: 0, isShowing: false)) { lastState, newVisibleHeight in
        return (visibleHeight: newVisibleHeight, isShowing: lastState.visibleHeight == 0 && newVisibleHeight > 0)
      }
      .filter { state in state.isShowing }
      .map { state in state.visibleHeight }
    self.isHidden = self.visibleHeight.map({ $0 == 0.0 }).distinctUntilChanged()
    super.init()

    // keyboard will change frame
    let willChangeFrame = NotificationCenter.default.rx.notification(.UIKeyboardWillChangeFrame)
      .map { notification -> KeyboardState in
        return KeyboardState(fromNotification: notification)
      }
      .map { state -> KeyboardState in
        if state.frame.origin.y < 0 { // if went to wrong frame
          return state.mutateTopPosition { yPos in UIScreen.main.bounds.height - yPos}
        }
        return state
      }

    // keyboard will hide
    let willHide = NotificationCenter.default.rx.notification(.UIKeyboardWillHide)
      .map { notification -> KeyboardState in
        return KeyboardState(fromNotification: notification)
      }
      .map { state -> KeyboardState in
        if state.frame.origin.y < 0 { // if went to wrong frame
          return state.mutateTopPosition { _ in UIScreen.main.bounds.height}
        }
        return state
      }

    // pan gesture
    let didPan = self.panRecognizer.rx.event
      .withLatestFrom(stateVariable.asObservable()) { ($0, $1) }
      .flatMap { (gestureRecognizer, state) -> Observable<KeyboardState> in
        guard case .changed = gestureRecognizer.state,
          let window = UIApplication.shared.windows.first,
          state.frame.origin.y < UIScreen.main.bounds.height
        else { return .empty() }
        let origin = gestureRecognizer.location(in: window)
        var newFrame = state.frame
        newFrame.origin.y = max(origin.y, UIScreen.main.bounds.height - state.frame.height)
        return .just(KeyboardState(frame: newFrame, duration: 0.0))
      }

    // merge into single sequence
    Observable.of(didPan, willChangeFrame, willHide).merge()
      .bind(to: stateVariable)
      .disposed(by: self.disposeBag)

    // gesture recognizer
    self.panRecognizer.delegate = self
    NotificationCenter.default.rx.notification(.UIApplicationDidFinishLaunching)
      .map { _ in Void() }
      .startWith(Void()) // when RxKeyboard is initialized before UIApplication.window is created
      .subscribe(onNext: { _ in
        UIApplication.shared.windows.first?.addGestureRecognizer(self.panRecognizer)
      })
      .disposed(by: self.disposeBag)
  }

}

extension Observable where Element == CGRect {
  public func asDriver() -> Driver<Element> {
    let source = self.observeOn(DriverSharingStrategy.scheduler)
    return source.asDriver(onErrorJustReturn: CGRect.null)
  }
}

extension Observable where Element == KeyboardStateType {
  public func asDriver() -> Driver<Element> {
    let source = self.observeOn(DriverSharingStrategy.scheduler)
    return source.asDriver(onErrorJustReturn: KeyboardState())
  }
}

// MARK: - UIGestureRecognizerDelegate

extension RxKeyboard: UIGestureRecognizerDelegate {

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    let point = touch.location(in: gestureRecognizer.view)
    var view = gestureRecognizer.view?.hitTest(point, with: nil)
    while let candidate = view {
      if let scrollView = candidate as? UIScrollView,
        case .interactive = scrollView.keyboardDismissMode {
        return true
      }
      view = candidate.superview
    }
    return false
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return gestureRecognizer === self.panRecognizer
  }

}
#endif

