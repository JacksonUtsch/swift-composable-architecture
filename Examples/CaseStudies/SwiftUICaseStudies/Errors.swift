@preconcurrency import Combine
import ComposableArchitecture
import SwiftUI

private let readMe = """
  This application demonstrates some methodologies for error handling in the Composable Architecture.

  It makes use of `_Observe` for dynamic dependencies, which helps demonstrate different client cases.
  Here we handle typed and untyped errors and create an app level error enum for deciding what to do with these errors.
  We can display them in a toast, call another action, log, etc..
  """

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
        Toggle("Errors", isOn: viewStore.binding(get: \.errors, send: { ParentFt.Action.setErrors($0) }))
          .frame(width: 110)

        Text(viewStore.state.ftA.fact ?? "")

        Button("Get fact") {
          viewStore.send(.ftA(.getFact))
        }.padding(.bottom)

        if viewStore.api.auth.accessToken == nil {
          Button("Login") {
            viewStore.send(.api(.login(name: "", password: "")))
          }
        } else {
          Text(viewStore.api.message)

          Button("Logout") {
            viewStore.send(.api(.setAuth(.init())))
          }

          Button("Get a message") {
            viewStore.send(.api(.getMessage))
          }

          // Demo for server error catch
          Button("Expired token") {
            viewStore.send(.api(.expiredToken))
          }
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
    var errors: Bool
    var ftA: FtA.State
    var api: Api.State
    var toast: String?

    init(
      errors: Bool = false,
      ftA: FtA.State = .init(),
      api: Api.State = .init(),
      toast: String? = nil
    ) {
      self.errors = errors
      self.ftA = ftA
      self.api = api
      self.toast = toast
    }
  }

  enum Action {
    case setErrors(Bool)
    case ftA(FtA.Ok)
    case api(Api.Ok)
    case listenForErrs
    case report(Err)
    case setToast(String?)
  }

  enum Err {
    case ftA(FtA.Err)
    case api(Api.Err)
  }

  @Dependency(\.errors) var errors

  var body: some ReducerProtocol<State, Action> {
    _Observe { state, _  in
      Reduce { state, action in
        switch action {
        case .setErrors(let value):
          state.errors = value
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
              case .ok(let value):
                return Action.api(value)
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
            errors.report("\(error)")
          case .ftA(.downloadClient(let error)):
            errors.report(error.localizedDescription)
          case .api(let message):
            if case .server(let error) = message {
              if error.code == 401 {
                return Effect(value: .api(.setAuth(.init())))
              }
            }
            errors.report(message.userMessage)
          }
        case .setToast(let message):
          state.toast = message
        }
        return .none
      }
      .dependency(\.factClient, state.errors ? .noInternet : .liveValue)
      .dependency(\.api, state.errors ? .internalServerError : .liveValue)
    }
  }
}

extension FactClient {
  static let noInternet = {
    enum Err: Error { case noInternet }
    return Self.init { _ in
      throw Err.noInternet
    }
  }()
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
  struct State: Hashable {
    var auth: Auth
    var message: String

    init(auth: Auth = .init(), message: String = "") {
      self.auth = auth
      self.message = message
    }

    struct Auth: Hashable {
      var accessToken: String?
      var refreshToken: String?

      init(
        accessToken: String? = nil,
        refreshToken: String? = nil
      ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
      }
    }
  }

  typealias Action = Res<Ok, Err>

  enum Ok: Hashable {
    case login(name: String, password: String)
    case setAuth(State.Auth)
    case getMessage
    case setMessage(String)
    case expiredToken
  }

  enum Err: Error {
    case server(ServerError)
    case noAuth

    var userMessage: String {
      switch self {
      case .server(let error):
        return "(\(error.code)) \(error.message)"
      case .noAuth:
        return "User is not signed in"
      }
    }

    struct ServerError {
      var code: Int
      var message: String

      init(code: Int, message: String) {
        self.code = code
        self.message = message
      }
    }
  }

  @Dependency(\.api) var api

  func reduce(into state: inout State, action: Action) -> Effect<Action, Never> {
    guard let action = action.ok else { return .none }
    switch action {
    case .login(let name, let password):
      return .task {
        switch await api.login(name, password) {
        case .success(let auth):
          return Action.ok(.setAuth(auth))
        case .failure(let error):
          return .err(error)
        }
      }
    case .setAuth(let auth):
      state.auth = auth
    case .getMessage:
      guard let accessToken = state.auth.accessToken else {
        return Effect(value: .err(.noAuth))
      }
      return .task {
        switch await api.getMessage(accessToken) {
        case .success(let message):
          return .ok(.setMessage(message))
        case .failure(let error):
          return .err(error)
        }
      }
    case .setMessage(let message):
      state.message = message
    case .expiredToken:
      return Effect(value: .err(.server(.init(code: 401, message: "Expired token"))))
    }
    return .none
  }
}

extension Api {
  struct Client {
    var login: (_ name: String, _ password: String) async -> Result<Api.State.Auth, Api.Err>
    var getMessage: (_ token: String) async -> Result<String, Api.Err>
  }
}

extension DependencyValues {
  var api: Api.Client {
    get { self[Api.Client.self] }
    set { self[Api.Client.self] = newValue }
  }
}

extension Api.Client: TestDependencyKey {
  static var testValue: Self {
    Self(
      login: { _, _ in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return .success(.init(accessToken: "123", refreshToken: "321"))
      },
      getMessage: { token in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return .success(["The first message", "Another message", "Just a message", "The last message"].randomElement()!)
      }
    )
  }
}

extension Api.Client {
  static let internalServerError: Self = {
    Self(
      login: { _, _ in return .failure(.server(.init(code: 500, message: "Internal server error")))},
      getMessage: { _ in return .failure(.server(.init(code: 500, message: "Internal server error"))) }
    )
  }()
}

extension Api.Client: DependencyKey {
  static var liveValue: Api.Client {
    testValue
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
