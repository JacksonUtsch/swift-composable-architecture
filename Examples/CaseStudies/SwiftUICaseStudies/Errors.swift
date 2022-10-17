@preconcurrency import Combine
import ComposableArchitecture
import SwiftUI

struct ParentViewPreviews: PreviewProvider {
  static var previews: some View {
    ParentView(viewStore: .init(.init(initialState: .init(), reducer: ParentFt()), removeDuplicates: { _, _ in false }))
  }
}

struct ParentView: View {
  @ObservedObject var viewStore: ViewStoreOf<ParentFt>

  var body: some View {
    ZStack {
      VStack {
        Text(viewStore.api ?? "")
        Text(viewStore.state.ftA.fact ?? "")
        Text("\(viewStore.count)")

        Button("Login") {
          viewStore.send(.api(()))
        }

        Button("Get fact") {
          viewStore.send(.ftA(.getFact))
        }
      }

      if let error = viewStore.toast {
        VStack {
          Text(error)
            .padding()
            .background {
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.4))
            }

          Spacer()
        }
      }
    }.onAppear {
      viewStore.send(.listenForErrs)
    }
  }
}

struct ParentFt: ReducerProtocol {
  struct State {
    var ftA: FtA.State
    var api: Api.State
    var toast: String?
    var count = 0

    init(
      ftA: FtA.State = .init(),
      api: Api.State = .init(),
      toast: String? = nil
    ) {
      self.ftA = ftA
      self.api = api
      self.toast = toast
    }
  }

  enum Action {
    case ftA(FtA.Ok)
    case api(Api.Ok)
    case listenForErrs
    case report(Err)
    case setToast(String?)
    case incr
  }

  enum Err {
    case ftA(FtA.Err)
    case api(String)
  }

  @Dependency(\.errors) var errors

  var body: some ReducerProtocol<State, Action> {
    Reduce { state, action in
      switch action {
      case .incr:
        state.count += 1
      case .ftA(let secondary):
        return FtA()
          .reduce(into: &state.ftA, action: .ok(secondary))
          .map({ action in
            switch action {
            case .ok(let ok):
              return Action.ftA(ok)
            case .err(let err):
              return Action.report(.ftA(err))
            }
          })
          .eraseToEffect()
      case .api(let secondary):
        return Api()
          .reduce(into: &state.api, action: .ok(secondary))
          .compactMap({ (action: Api.Action) -> Action? in
            switch action {
            case .ok():
              return .none
            case .err(let error):
              return Action.report(.api(error))
            }
          }).eraseToEffect()
      case .listenForErrs:
        return errors.publisher()
          .map(Action.setToast)
          .eraseToEffect()
      case .report(let error):
        switch error {
        case .ftA(.factClient(let error)):
          errors.report(error.localizedDescription)
        case .ftA(.downloadClient(let error)):
          errors.report(error.localizedDescription)
        case .api(let message):
          errors.report(message)
        }
      case .setToast(let message):
        state.toast = message
      }
      return .none
    }
  }
}

struct FtA: ReducerProtocol {
  struct State {
    var download: DownloadClient.Event?
    var fact: String?
  }

  typealias Action = Res<Ok, Err>

  enum Ok {
    case getDownload
    case setDownload(DownloadClient.Event?)
    case getFact
    case setFact(String?)
  }

  enum Err {
    case downloadClient(Error)
    case factClient(Error)
  }

  @Dependency(\.downloadClient) var downloadClient
  @Dependency(\.factClient) var factClient

  func reduce(into state: inout State, action: Action) -> Effect<Action, Never> {
    enum UnexpectedError: Error { case emptyStream }
    guard let action = action.ok else { return .none }
    switch action {
    case .getDownload:
      state.download = .updateProgress(0)
      return .task {
        do {
          for try await download in downloadClient.download(.init(string: "")!) {
            return .ok(.setDownload(download))
          }
        } catch {
          return .err(.downloadClient(error))
        }
        return .err(.downloadClient(UnexpectedError.emptyStream))
      }
    case .setDownload(let download):
      state.download = download
    case .getFact:
      return .task {
        do {
          let fact = try await factClient.fetch(1)
          return .ok(.setFact(fact))
        } catch {
          return .err(.factClient(error))
        }
      }
    case .setFact(let value):
      state.fact = value
    }

    return .none
  }
}

struct Api: ReducerProtocol {
  typealias State = String?
  typealias Action = Res<Ok, Err>

  typealias Ok = Void
  typealias Err = String

  func reduce(into state: inout State, action: Action) -> Effect<Action, Never> {
    switch action {
    case .ok():
      return Effect(value: .err("Unable to connect to server"))
    case .err(_):
      return .none
    }
  }
}

/// A simple result type without the Error type requirement
enum Res<Ok, Err> {
  case ok(Ok)
  case err(Err)

  var ok: Ok? {
    if case .ok(let value) = self {
      return value
    }

    return nil
  }
}

extension DependencyValues {
  var errors: ErrorsClient<String> {
    get { self[ErrorsClient<String>.self] }
    set { self[ErrorsClient<String>.self] = newValue }
  }
}

public struct ErrorsClient<T> {
  public var publisher: () -> AnyPublisher<T?, Never>
  public var report: (T) -> Void

  public init(
    publisher: @escaping () -> AnyPublisher<T?, Never>,
    report: @escaping (T) -> Void
  ) {
    self.publisher = publisher
    self.report = report
  }
}

extension ErrorsClient: TestDependencyKey {
  public static var testValue: ErrorsClient<String> {
    .liveValue
  }
}

fileprivate let errorQueue = DispatchQueue(label: "errors", qos: .utility)

extension ErrorsClient: DependencyKey where T == String {
  public static var previewValue: ErrorsClient<String> = {
    .liveValue
  }()

  public static var liveValue: ErrorsClient<String> = {
    let displaySeconds: UInt32 = 3
    var queue: [T] = []
    let publisher = PassthroughSubject<String?, Never>()

    return .init(
      publisher: { publisher.eraseToAnyPublisher() },
      report: { newError in
        guard queue.count < 3 else {
          queue[2] = newError
          return
        }
        queue += [newError]
        Thread.detachNewThread {
          errorQueue.sync {
            publisher.send(queue.first!)
            usleep(1_000_000 * displaySeconds)
            queue.removeFirst()
            if queue.isEmpty {
              publisher.send(nil)
            }
          }
        }
      }
    )
  }()
}

public struct _Observe<Reducers: ReducerProtocol>: ReducerProtocol {
  @usableFromInline
  let reducers: (Reducers.State, Reducers.Action) -> Reducers

  /// Initializes a reducer that builds a reducer from the current state and action.
  ///
  /// - Parameter build: A reducer builder that has access to the current state and action.
  @inlinable
  public init<State, Action>(
    @ReducerBuilder<State, Action> _ build: @escaping (State, Action) -> Reducers
  ) where Reducers.State == State, Reducers.Action == Action {
    self.reducers = build
  }

  @inlinable
  public func reduce(
    into state: inout Reducers.State, action: Reducers.Action
  ) -> Effect<Reducers.Action, Never> {
    self.reducers(state, action).reduce(into: &state, action: action)
  }
}
