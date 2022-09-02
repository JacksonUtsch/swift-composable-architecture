import Combine
import CombineSchedulers
import ComposableArchitecture
import XCTest

@MainActor
final class ComposableArchitectureTests: XCTestCase {
  var cancellables: Set<AnyCancellable> = []

  func testHandling() async {
    struct Ft1: ReducerProtocol {
      typealias State = Int
      typealias Action = Result<Actions, Errors>
      enum Actions { case genTestError }
      enum Errors: Error, Hashable { case test }
      var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in
          switch action {
          case .success(let actions):
            switch actions {
            case .genTestError:
              return Effect(value: .failure(.test))
            }
          case .failure(_): break
          }
          return .none }
      }
    }

    struct Ft2: ReducerProtocol {
      typealias State = Int
      typealias Action = Result<Actions, Errors>
      enum Actions: Equatable {}
      enum Errors: Error, Hashable {}
      var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in return .none }
      }
    }

    struct Handling: ReducerProtocol {
      typealias State = Int

      enum Action: Equatable {
        case ft1(Ft1.Actions)
        case ft2(Ft2.Actions)
        case handle(Errors)
      }

      enum Errors: Error, Equatable {
        case ft1(Ft1.Errors)
        case ft2(Ft2.Errors)
      }

      @Dependency(\.mainQueue) var mainQueue

      var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in
          switch action {
          case .ft1(let secondary):
            return Ft1().reduce(into: &state, action: .success(secondary))
              .map { result in
                switch result {
                case .success(let value):
                  return Action.ft1(value)
                case .failure(let error):
                  return Action.handle(.ft1(error))
                }
              }
          case .ft2(let secondary):
            return Ft2().reduce(into: &state, action: .success(secondary))
              .map { result in
                switch result {
                case .success(let value):
                  return Action.ft2(value)
                case .failure(let error):
                  return Action.handle(.ft2(error))
                }
              }
          case .handle(let error):
            state += 1
            print("Handle or log: \(error)")
          }
          return .none
        }
      }
    }

    let store = TestStore(
      initialState: 2,
      reducer: Handling()
    )

    let mainQueue = DispatchQueue.test
    store.dependencies.mainQueue = mainQueue.eraseToAnyScheduler()

    await store.send(.ft1(.genTestError))
    await store.receive(Handling.Action.handle(.ft1(.test))) { $0 += 1 }
  }

  func testScheduling() async {
    struct Counter: ReducerProtocol {
      typealias State = Int
      enum Action: Equatable {
        case incrAndSquareLater
        case incrNow
        case squareNow
      }
      @Dependency(\.mainQueue) var mainQueue
      func reduce(into state: inout State, action: Action) -> Effect<Action, Never> {
        switch action {
        case .incrAndSquareLater:
          return .merge(
            Effect(value: .incrNow)
              .delay(for: 2, scheduler: self.mainQueue)
              .eraseToEffect(),
            Effect(value: .squareNow)
              .delay(for: 1, scheduler: self.mainQueue)
              .eraseToEffect(),
            Effect(value: .squareNow)
              .delay(for: 2, scheduler: self.mainQueue)
              .eraseToEffect()
          )
        case .incrNow:
          state += 1
          return .none
        case .squareNow:
          state *= state
          return .none
        }
      }
    }

    let store = TestStore(
      initialState: 2,
      reducer: Counter()
    )

    let mainQueue = DispatchQueue.test
    store.dependencies.mainQueue = mainQueue.eraseToAnyScheduler()

    await store.send(.incrAndSquareLater)
    await mainQueue.advance(by: 1)
    await store.receive(.squareNow) { $0 = 4 }
    await mainQueue.advance(by: 1)
    await store.receive(.incrNow) { $0 = 5 }
    await store.receive(.squareNow) { $0 = 25 }

    await store.send(.incrAndSquareLater)
    await mainQueue.advance(by: 2)
    await store.receive(.squareNow) { $0 = 625 }
    await store.receive(.incrNow) { $0 = 626 }
    await store.receive(.squareNow) { $0 = 391876 }
  }

  func testSimultaneousWorkOrdering() {
    let mainQueue = DispatchQueue.test

    var values: [Int] = []
    mainQueue.schedule(after: mainQueue.now, interval: 1) { values.append(1) }
      .store(in: &self.cancellables)
    mainQueue.schedule(after: mainQueue.now, interval: 2) { values.append(42) }
      .store(in: &self.cancellables)

    XCTAssertNoDifference(values, [])
    mainQueue.advance()
    XCTAssertNoDifference(values, [1, 42])
    mainQueue.advance(by: 2)
    XCTAssertNoDifference(values, [1, 42, 1, 1, 42])
  }

  func testLongLivingEffects() async {
    typealias Environment = (
      startEffect: Effect<Void, Never>,
      stopEffect: Effect<Never, Never>
    )

    enum Action { case end, incr, start }

    let effect = AsyncStream<Void>.streamWithContinuation()

    let reducer = Reduce<Int, Action> { state, action in
      switch action {
      case .end:
        return .fireAndForget {
          effect.continuation.finish()
        }
      case .incr:
        state += 1
        return .none
      case .start:
        return .run { send in
          for await _ in effect.stream {
            await send(.incr)
          }
        }
      }
    }

    let store = TestStore(initialState: 0, reducer: reducer)

    await store.send(.start)
    await store.send(.incr) { $0 = 1 }
    effect.continuation.yield()
    await store.receive(.incr) { $0 = 2 }
    await store.send(.end)
  }

  func testCancellation() async {
    let mainQueue = DispatchQueue.test

    enum Action: Equatable {
      case cancel
      case incr
      case response(Int)
    }

    struct Environment {
      let fetch: (Int) async -> Int
    }

    let reducer = AnyReducer<Int, Action, Environment> { state, action, environment in
      enum CancelID {}

      switch action {
      case .cancel:
        return .cancel(id: CancelID.self)

      case .incr:
        state += 1
        return .task { [state] in
          try await mainQueue.sleep(for: .seconds(1))
          return .response(await environment.fetch(state))
        }
        .cancellable(id: CancelID.self)

      case let .response(value):
        state = value
        return .none
      }
    }

    let store = TestStore(
      initialState: 0,
      reducer: reducer,
      environment: Environment(
        fetch: { value in value * value }
      )
    )

    await store.send(.incr) { $0 = 1 }
    await mainQueue.advance(by: .seconds(1))
    await store.receive(.response(1))

    await store.send(.incr) { $0 = 2 }
    await store.send(.cancel)
  }
}
