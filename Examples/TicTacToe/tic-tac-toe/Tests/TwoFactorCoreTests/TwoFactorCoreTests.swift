import AuthenticationClient
import ComposableArchitecture
import TwoFactorCore
import XCTest

class TwoFactorCoreTests: XCTestCase {
  func testFlow_Success() {
    let store = _TestStore(
      initialState: TwoFactorState(token: "deadbeefdeadbeef"),
      reducer: TwoFactorReducer()
    )

    store.dependencies.mainQueue = .immediate
    store.dependencies.authenticationClient.twoFactor = { _ in
      Effect(value: .init(token: "deadbeefdeadbeef", twoFactorRequired: false))
    }

    store.send(.codeChanged("1")) {
      $0.code = "1"
    }
    store.send(.codeChanged("12")) {
      $0.code = "12"
    }
    store.send(.codeChanged("123")) {
      $0.code = "123"
    }
    store.send(.codeChanged("1234")) {
      $0.code = "1234"
      $0.isFormValid = true
    }
    store.send(.submitButtonTapped) {
      $0.isTwoFactorRequestInFlight = true
    }
    store.receive(
      .twoFactorResponse(.success(.init(token: "deadbeefdeadbeef", twoFactorRequired: false)))
    ) {
      $0.isTwoFactorRequestInFlight = false
    }
  }

  func testFlow_Failure() {
    let store = _TestStore(
      initialState: TwoFactorState(token: "deadbeefdeadbeef"),
      reducer: TwoFactorReducer()
    )

    store.dependencies.mainQueue = .immediate
    store.dependencies.authenticationClient.twoFactor = { _ in
      Effect(error: .invalidTwoFactor)
    }

    store.send(.codeChanged("1234")) {
      $0.code = "1234"
      $0.isFormValid = true
    }
    store.send(.submitButtonTapped) {
      $0.isTwoFactorRequestInFlight = true
    }
    store.receive(.twoFactorResponse(.failure(.invalidTwoFactor))) {
      $0.alert = .init(
        title: TextState(AuthenticationError.invalidTwoFactor.localizedDescription)
      )
      $0.isTwoFactorRequestInFlight = false
    }
    store.send(.alertDismissed) {
      $0.alert = nil
    }
  }
}
