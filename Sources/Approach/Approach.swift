//
// BSD Zero Clause License
//
// Copyright (c) 2025 Apparata AB
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
// OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.
//

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#else
import Foundation
#endif

import Network

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

private let messageServiceProtocolVersion = "0001"
public let messageServiceType = "_apparata-approach-v\(messageServiceProtocolVersion)._tcp"
private let messageServiceVersion = "APPSERVICEV\(messageServiceProtocolVersion)"
private let messageClientVersion = "APPCLIENTV\(messageServiceProtocolVersion)"
private let maxMessageDataLength: Int32 = 10_000_000

// ---------------------------------------------------------------------------
// MARK: - Result types
// ---------------------------------------------------------------------------

/// The result of a send message operation.
public enum SendMessageResult {

    /// The message was sent successfully.
    case success

    /// The message failed to send due to an error.
    case failure(Swift.Error)
}

/// The result of a receive message operation.
public enum ReceiveMessageResult {

    /// The message was received successfully along with its metadata.
    case success(Data, metadata: Data)

    /// The message receive operation failed with an error.
    case failure(Swift.Error)
}

/// Errors that can occur during message service operations.
public enum MessageServiceError: Swift.Error {

    /// An unknown error occurred.
    case unknownError

    /// The message received was corrupt or invalid.
    case corruptMessage

    /// No active connection was available.
    case noConnection

    /// The handshake process failed, with an optional error reason.
    case handshakeFailed(reason: Error?)
}

// ----------------------------------------------------------------------------
// MARK: - Server
// ----------------------------------------------------------------------------

/// `MessageService` is a server-side class for managing TCP-based message
/// services using Apple's Network framework. It listens for incoming client connections
/// and handles messages via a delegate.
public class MessageService {

    /// Optional logging callback for diagnostic messages.
    public static var log: ((MessageService, String) -> Void)?

    /// Delegate that receives connection and advertisement events.
    public weak var delegate: MessageServiceDelegate?

    /// The current port the service is listening on, or nil if not started.
    public var port: Int? {
        if let value = listener?.port?.rawValue {
            return Int(value)
        }
        return nil
    }

    /// A set of all currently connected clients.
    public var allClients: Set<RemoteMessageClient> {
        Set(clients.values)
    }

    private let queue = DispatchQueue(label: "MessageServiceQueue", qos: .userInteractive)

    private var listener: NWListener?

    private var clients: [UUID: RemoteMessageClient] = [:]

    private var serviceName: String?

    private var serviceType: String

    private var restartOnDidBecomeActive = false

    private var requestedPort: Int?

    /// Initializes a new `MessageService` instance.
    ///
    /// - Parameters:
    ///   - name: Optional name to advertise the service under.
    ///   - serviceType: Bonjour service type.
    ///   - port: Optional specific port to bind to.
    /// - Throws: An error if the service listener could not be created.
    ///
    public init(
        name: String? = nil,
        serviceType: String = messageServiceType,
        port: Int? = nil
    ) throws {
        serviceName = name
        self.serviceType = serviceType
        requestedPort = port
        observeAppState()
        try createService()
    }

    deinit {
        stop()
    }

    /// Starts observing application state changes to pause and resume service appropriately.
    public func observeAppState() {
#if os(iOS) || os(tvOS) || os(visionOS)
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(appWillResignActive(notification:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive(notification:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }

    private func createService() throws {

        if listener != nil {
            listener?.cancel()
            listener = nil
        }

        let newListener: NWListener
        if let port = requestedPort, let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) {
            newListener = try NWListener(using: .tcp, on: endpointPort)
        } else {
            newListener = try NWListener(using: .tcp)
        }
        newListener.service = NWListener.Service(name: serviceName, type: serviceType)

        newListener.serviceRegistrationUpdateHandler = { [weak self] serviceChange in
            switch serviceChange {
            case .add(let endpoint):
                if case .service(let name, _, _, _) = endpoint, let self = self {
                    self.delegate?.messageService(self, didAdvertiseAs: name)
                }
            case .remove(let endpoint):
                if case .service(let name, _, _, _) = endpoint, let self = self {
                    self.delegate?.messageService(self, didUnadvertiseAs: name)
                }
            @unknown default:
                assert(false)
            }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        self.listener = newListener
    }

    /// Starts the message service listener.
    public func start() {
        listener?.start(queue: queue)
    }

    private func recreateService() throws {
        try createService()
        start()
    }

    /// Stops the message service and closes all active client connections.
    public func stop() {
        for (_, remoteClient) in clients {
            remoteClient.cancelConnection()
        }
        if listener != nil {
            listener?.cancel()
            listener = nil
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {

        MessageService.log?(self, "Incoming connection: \(connection)")

        let newClient = RemoteMessageClient(connection: connection)

        newClient.didInvalidate = { [weak self] client in
            self?.clients.removeValue(forKey: client.id)
        }

        clients[newClient.id] = newClient

        delegate?.messageService(self, clientDidConnect: newClient)
        newClient.start(queue: queue)
    }

    private func handleStateUpdate(_ newState: NWListener.State) {

        MessageService.log?(self, "State: \(newState)")

        switch newState {

            /// Prior to start, the listener will be in the setup state
        case .setup:
            break

            /// Waiting listeners do not have a viable network
        case .waiting(let error):
            _ = error

            /// Ready listeners are able to receive incoming connections
            /// Bonjour service may not yet be registered
        case .ready:
            break

            /// Failed listeners are no longer able to receive incoming connections
        case .failed(let error):
            _ = error

            /// Cancelled listeners have been invalidated by the client and will send no more events
        case .cancelled:
            break

        @unknown default:
            assert(false)
        }
    }

    // MARK: - App state handling.

#if os(iOS) || os(tvOS) || os(visionOS)

    @objc private func appWillResignActive(notification: NSNotification) {
        restartOnDidBecomeActive = true
        listener?.cancel()
        listener = nil
    }

    @objc private func appDidBecomeActive(notification: NSNotification) {
        if restartOnDidBecomeActive {
            do {
                try recreateService()
            } catch {
                MessageService.log?(self, "Error: Failed to recreate service: \(error.localizedDescription)")
            }
        }
    }

#endif
}

/// A delegate protocol used by `MessageService` to notify about service
/// advertisement and client connection events.
public protocol MessageServiceDelegate: AnyObject {

    /// Called when the service has been advertised with the given name.
    ///
    /// - Parameters:
    ///   - service: The `MessageService` instance.
    ///   - name: The Bonjour name it was advertised as.
    ///
    func messageService(_ service: MessageService, didAdvertiseAs name: String)

    /// Called when the service is no longer advertised with the given name.
    ///
    /// - Parameters:
    ///   - service: The `MessageService` instance.
    ///   - name: The Bonjour name it was unadvertised from.
    ///
    func messageService(_ service: MessageService, didUnadvertiseAs name: String)

    /// Called when a new client has connected to the service.
    ///
    /// - Parameters:
    ///   - service: The `MessageService` instance.
    ///   - client: The connected `RemoteMessageClient`.
    ///
    func messageService(_ service: MessageService, clientDidConnect client: RemoteMessageClient)
}

// Default implementations.
public extension MessageServiceDelegate {
    func messageService(_ service: MessageService, didAdvertiseAs name: String) {}
    func messageService(_ service: MessageService, didUnadvertiseAs name: String) {}
}

// ----------------------------------------------------------------------------
// MARK: - Remote Client
// ----------------------------------------------------------------------------

/// `RemoteMessageClient` represents a single client connection accepted
/// by the `MessageService`. It manages communication, including
/// handshakes and message exchange, with the connected client.
public class RemoteMessageClient {

    /// Optional logging callback for diagnostic messages.
    public static var log: ((RemoteMessageClient, String) -> Void)?

    /// Unique identifier for the remote client.
    public let id: UUID

    fileprivate var didInvalidate: ((RemoteMessageClient) -> Void)?

    /// Delegate that receives session and message events.
    public weak var delegate: RemoteMessageClientDelegate?

    private let connection: NWConnection

    private let messageSender = MessageSender()
    private let messageReceiver = MessageReceiver()

    /// Indicates whether the initial handshake has been completed.
    public private(set) var didHandshake: Bool = false

    fileprivate init(connection: NWConnection) {
        id = UUID()
        self.connection = connection
        configureConnection(connection)
    }

    /// Sends a message to the remote client.
    ///
    /// - Parameters:
    ///   - data: The message payload.
    ///   - metadata: Metadata to send with the message.
    ///   - completion: Called with the result of the send operation.
    public func sendMessage(data: Data, metadata: Data,
                            completion: ((SendMessageResult) -> Void)? = nil) {
        messageSender.sendMessage(on: connection, data: data, metadata: metadata, completion: completion)
    }

    private func receiveMessage(completion: @escaping (ReceiveMessageResult) -> Void) {
        messageReceiver.receiveMessage(on: connection, completion: completion)
    }

    fileprivate func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    fileprivate func cancelConnection() {
        connection.cancel()
    }

    private func configureConnection(_ connection: NWConnection) {

        connection.stateUpdateHandler = { [weak self] newState in
            self?.handleStateUpdate(newState)
        }
    }

    private func handleStateUpdate(_ newState: NWConnection.State) {

        RemoteMessageClient.log?(self, "State: \(newState)")

        switch newState {

            /// The initial state prior to start
        case .setup:
            break

            // Waiting connections have not yet been started, or do not have
            // a viable network
        case .waiting(let error):
            delegate?.client(self, didPauseSessionWithError: error)

            // Preparing connections are actively establishing the connection
        case .preparing:
            break

            /// Ready connections can send and receive data
        case .ready:
            if !didHandshake {
                didHandshake = true
                sendHandshake()
            }

            /// Failed connections are disconnected and can no longer
            /// send or receive data.
        case .failed(let error):
            delegate?.client(self, didFailSessionWithError: error)

            // All connections will eventually end up in this state.
        case .cancelled:
            didInvalidate?(self)
            delegate?.clientDidEndSession(self)

        @unknown default:
            assert(false)
        }
    }

    private func sendHandshake() {
        RemoteMessageClient.log?(self, "Sending handshake: \(messageServiceVersion)")
        let data = messageServiceVersion.data(using: .utf8)
        connection.send(content: data, completion: .contentProcessed({ [weak self] error in
            if error != nil {
                self?.didFailHandshake(error: error)
            } else {
                self?.receiveHandshake()
            }
        }))
    }

    private func receiveHandshake() {
        RemoteMessageClient.log?(self, "Receiving handshake...")
        connection.receive(exactLength: messageClientVersion.count) { [weak self] data, _, _, error in
            if let data = data {
                self?.didReceiveHandshake(data: data)
            } else {
                self?.didFailHandshake(error: error)
            }
        }
    }

    private func didReceiveHandshake(data: Data) {
        let string = String(data: data, encoding: .utf8) ?? "<Corrupt data>"
        if string != messageClientVersion {
            RemoteMessageClient.log?(self, "Received incorrect handshake: \(string)")
            didFailHandshake(error: MessageServiceError.handshakeFailed(reason: nil))
        } else {
            RemoteMessageClient.log?(self, "Received handshake: \(string)")
            didCompleteHandshake()
        }
    }

    private func didCompleteHandshake() {
        RemoteMessageClient.log?(self, "Completed handshake.")
        delegate?.clientDidStartSession(self)
        receiveNextMessage()
    }

    private func didFailHandshake(error: Error?) {
        let errorString: String = error?.localizedDescription ?? "Unknown error"
        RemoteMessageClient.log?(self, "Error: Handshake failed: \(errorString)")
        delegate?.client(self, didFailSessionWithError: MessageServiceError.handshakeFailed(reason: error))
        connection.cancel()
    }

    private func receiveNextMessage() {
        RemoteMessageClient.log?(self, "Waiting to receive message...")
        receiveMessage { [weak self] result in
            guard let strongSelf = self else {
                return
            }
            switch result {

            case .success(let data, let metadata):
                RemoteMessageClient.log?(strongSelf, "Received message.")
                strongSelf.delegate?.client(strongSelf, didReceiveMessage: data, metadata: metadata)
                strongSelf.receiveNextMessage()

            case .failure(_):
                RemoteMessageClient.log?(strongSelf, "Failed to receive message, aborting...")
                strongSelf.connection.cancel()
            }
        }
    }
}

extension RemoteMessageClient: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func ==(lhs: RemoteMessageClient, rhs: RemoteMessageClient) -> Bool {
        return lhs.id == rhs.id
    }
}

/// A delegate protocol used by `RemoteMessageClient` to notify about
/// session lifecycle and message events.
public protocol RemoteMessageClientDelegate: AnyObject {

    /// Called when the client has completed the handshake and the session starts.
    func clientDidStartSession(_ client: RemoteMessageClient)

    /// Called when the session is temporarily paused due to a network issue.
    ///
    /// - Parameters:
    ///   - client: The remote client instance.
    ///   - error: The underlying network error that caused the pause.
    ///
    func client(_ client: RemoteMessageClient, didPauseSessionWithError error: NWError)

    /// Called when the session has failed and cannot continue.
    ///
    /// - Parameters:
    ///   - client: The remote client instance.
    ///   - error: The error that caused the session failure.
    ///
    func client(_ client: RemoteMessageClient, didFailSessionWithError error: Error)

    /// Called when the session has ended, either due to disconnection or error.
    ///
    /// - Parameter client: The remote client instance.
    ///
    func clientDidEndSession(_ client: RemoteMessageClient)

    /// Called when a message is received from the client.
    ///
    /// - Parameters:
    ///   - client: The remote client instance.
    ///   - data: The message payload.
    ///   - metadata: The metadata associated with the message.
    ///
    func client(_ client: RemoteMessageClient, didReceiveMessage data: Data, metadata: Data)
}

// Default implementations
public extension RemoteMessageClientDelegate {
    func clientDidStartSession(_ client: RemoteMessageClient) {}
    func client(_ client: RemoteMessageClient, didPauseSessionWithError error: NWError) {}
    func client(_ client: RemoteMessageClient, didFailSessionWithError error: Error) {}
    func clientDidEndSession(_ client: RemoteMessageClient) {}
}

// ----------------------------------------------------------------------------
// MARK: - Client
// ----------------------------------------------------------------------------

/// `MessageClient` is a client-side class for connecting to a message
/// service using Apple's Network framework. It connects to a server via
/// TCP, performs a handshake, and enables sending and receiving messages.
/// Messages are received asynchronously via delegate callbacks.
public class MessageClient {

    /// Optional logging callback for diagnostic messages. If set, this closure
    /// will be invoked with logging output generated by the client.
    public static var log: ((MessageClient, String) -> Void)?

    /// Delegate that receives connection and message events from the client.
    public weak var delegate: MessageClientDelegate?

    private let queue = DispatchQueue(label: "MessageClientQueue", qos: .userInteractive)

    private var connection: NWConnection?

    private let serviceName: String
    private let serviceType: String

    private let serviceEndpoint: NWEndpoint

    private let messageSender = MessageSender()
    private let messageReceiver = MessageReceiver()

    private var didHandshake: Bool = false

    /// Initializes a `MessageClient` for a Bonjour service.
    ///
    /// - Parameters:
    ///   - serviceName: The advertised name of the Bonjour service.
    ///   - serviceType: The type of Bonjour service. Defaults to `messageServiceType`.
    ///
    public init(serviceName: String, serviceType: String = messageServiceType) {
        self.serviceName = serviceName
        self.serviceType = serviceType

        serviceEndpoint = .service(name: serviceName,
                                   type: serviceType,
                                   domain: "local",
                                   interface: nil)
    }

    /// Initializes a `MessageClient` for a specific host and port.
    ///
    /// - Parameters:
    ///   - host: The host address of the server.
    ///   - port: The TCP port number to connect to.
    ///
    public init(host: String, port: UInt16) {
        serviceName = host
        serviceType = "\(port)"

        serviceEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(4040))
    }

    deinit {
        connection?.cancel()
    }

    /// Connects to the specified service or host. Performs a handshake with
    /// the server and begins listening for messages. If already connected,
    /// the call is ignored.
    public func connect() {

        guard self.connection == nil || self.connection?.state == .cancelled else {
            MessageClient.log?(self, "Error: Cannot reconnect, connection not in cancelled state.")
            return
        }

        self.connection = nil
        didHandshake = false

        let connection = NWConnection(to: serviceEndpoint, using: .tcp)
        self.connection = connection

        connection.restart()

        connection.stateUpdateHandler = { [weak self] newState in
            self?.handleStateUpdate(newState)
        }

        connection.start(queue: queue)
    }

    /// Sends a message to the connected server.
    ///
    /// - Parameters:
    ///   - data: The message payload.
    ///   - metadata: Metadata to send with the message.
    ///   - completion: Called with the result of the send operation.
    ///
    public func sendMessage(
        data: Data,
        metadata: Data,
        completion: ((SendMessageResult) -> Void)? = nil
    ) {
        guard let connection = connection else {
            completion?(.failure(MessageServiceError.noConnection))
            return
        }
        messageSender.sendMessage(on: connection, data: data, metadata: metadata, completion: completion)
    }

    /// Receives a single message from the server.
    ///
    /// - Parameter completion: Called with the result of the receive
    ///   operation. Use only for manual reception.
    ///
    public func receiveMessage(completion: @escaping (ReceiveMessageResult) -> Void) {
        MessageClient.log?(self, "Entered receiveMessage")
        guard let connection = connection else {
            MessageClient.log?(self, "No connection")
            completion(.failure(MessageServiceError.noConnection))
            return
        }
        messageReceiver.receiveMessage(on: connection, completion: completion)
    }

    private func handleStateUpdate(_ newState: NWConnection.State) {

        MessageClient.log?(self, "State: \(newState)")

        switch newState {

            /// The initial state prior to start
        case .setup:
            break

            /// Waiting connections have not yet been started, or do not have a viable network
        case .waiting(let error):
            delegate?.client(self, didPauseSessionWithError: error)

            /// Preparing connections are actively establishing the connection
        case .preparing:
            break

            /// Ready connections can send and receive data
        case .ready:
            if !didHandshake {
                didHandshake = true
                receiveHandshake()
            }

            /// Failed connections are disconnected and can no longer send or receive data
        case .failed(let error):
            delegate?.client(self, didFailSessionWithError: error)

            /// Cancelled connections have been invalidated by the client and will send no more events
        case .cancelled:
            delegate?.clientDidEndSession(self)

        @unknown default:
            assert(false)
        }
    }

    private func receiveHandshake() {
        MessageClient.log?(self, "Receiving handshake...")
        connection?.receive(exactLength: messageServiceVersion.count) { [weak self] data, _, _, error in
            if let data = data {
                self?.didReceiveHandshake(data: data)
            } else {
                self?.didFailHandshake(error: error)
            }
        }
    }

    private func didReceiveHandshake(data: Data) {
        let string = String(data: data, encoding: .utf8) ?? "<Corrupt data>"
        if string != messageServiceVersion {
            MessageClient.log?(self, "Error: Received incorrect handshake: \(string)")
        } else {
            MessageClient.log?(self, "Received handshake: \(string)")
            sendHandshake()
        }
    }

    private func sendHandshake() {
        MessageClient.log?(self, "Sending handshake: \(messageClientVersion)")
        let data = messageClientVersion.data(using: .utf8)
        connection?.send(content: data, completion: .contentProcessed({ [weak self] error in
            if error != nil {
                self?.didFailHandshake(error: error)
            } else {
                self?.didCompleteHandshake()
            }
        }))
    }

    private func didCompleteHandshake() {
        MessageClient.log?(self, "Completed handshake.")
        delegate?.clientDidStartSession(self)
        receiveNextMessage()
    }

    private func didFailHandshake(error: Error?) {
        let errorString: String = error?.localizedDescription ?? "Unknown error"
        MessageClient.log?(self, "Error: Handshake failed: \(errorString)")
        delegate?.client(self, didFailSessionWithError: MessageServiceError.handshakeFailed(reason: error))
        connection?.cancel()
    }

    private func receiveNextMessage() {
        MessageClient.log?(self, "Waiting to receive message...")
        receiveMessage { [weak self] result in
            guard let strongSelf = self else {
                return
            }
            switch result {

            case .success(let data, let metadata):
                MessageClient.log?(strongSelf, "Received message.")
                strongSelf.delegate?.client(strongSelf, didReceiveMessage: data, metadata: metadata)
                strongSelf.receiveNextMessage()

            case .failure(_):
                MessageClient.log?(strongSelf, "Failed to receive message, aborting...")
                strongSelf.connection?.cancel()
            }
        }
    }
}

/// A delegate protocol used by `MessageClient` to notify about session
/// lifecycle and message reception events.
public protocol MessageClientDelegate: AnyObject {

    /// Called when the client has successfully completed the handshake.
    ///
    /// - Parameter client: The `MessageClient` instance.
    ///
    func clientDidStartSession(_ client: MessageClient)

    /// Called when the connection is temporarily paused due to a network issue.
    ///
    /// - Parameters:
    ///   - client: The `MessageClient` instance.
    ///   - error: The underlying network error.
    ///
    func client(_ client: MessageClient, didPauseSessionWithError error: NWError)

    /// Called when the session has failed and cannot continue.
    ///
    /// - Parameters:
    ///   - client: The `MessageClient` instance.
    ///   - error: The error that caused the session failure.
    ///
    func client(_ client: MessageClient, didFailSessionWithError error: Error)

    /// Called when the session has ended.
    ///
    /// - Parameter client: The `MessageClient` instance.
    ///
    func clientDidEndSession(_ client: MessageClient)

    /// Called when a message is received from the server.
    ///
    /// - Parameters:
    ///   - client: The `MessageClient` instance.
    ///   - data: The message payload.
    ///   - metadata: The metadata associated with the message.
    ///
    func client(_ client: MessageClient, didReceiveMessage data: Data, metadata: Data)
}

// Default implementations
public extension MessageClientDelegate {
    func clientDidStartSession(_ client: MessageClient) {}
    func client(_ client: MessageClient, didPauseSessionWithError error: NWError) {}
    func client(_ client: MessageClient, didFailSessionWithError error: Error) {}
    func clientDidEndSession(_ client: MessageClient) {}
}

// ----------------------------------------------------------------------------
// MARK: - Message Sender
// ----------------------------------------------------------------------------

private class MessageSender {

    func sendMessage(
        on connection: NWConnection,
        data: Data,
        metadata: Data,
        completion: ((SendMessageResult) -> Void)?
    ) {

        connection.batch {
            let metadataLength = serialize(value: Int16(metadata.count))
            connection.send(content: metadataLength, completion: .contentProcessed({ error in
                if let error = error {
                    completion?(.failure(error))
                }
            }))
            connection.send(content: metadata, completion: .contentProcessed({ error in
                if let error = error {
                    completion?(.failure(error))
                }
            }))
            let dataLength = serialize(value: Int32(data.count))
            connection.send(content: dataLength, completion: .contentProcessed({ error in
                if let error = error {
                    completion?(.failure(error))
                }
            }))
            guard data.count > 0 else {
                completion?(.success)
                return
            }
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    completion?(.failure(error))
                } else {
                    completion?(.success)
                }
            }))
        }
    }

    private func serialize<T>(value: T) -> Data {
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        bytes.withUnsafeMutableBufferPointer {
            UnsafeMutableRawPointer($0.baseAddress!).storeBytes(of: value, as: T.self)
        }
        let data = Data(bytes)
        return data
    }
}

// ----------------------------------------------------------------------------
// MARK: - Message Receiver
// ----------------------------------------------------------------------------

private class MessageReceiver {

    /// Int16 - Metadata Length
    /// Data - Metadata
    /// Int32 - Data Length
    /// Data - Data
    func receiveMessage(
        on connection: NWConnection,
        completion: @escaping (ReceiveMessageResult) -> Void
    ) {
        receiveMetadataLength(on: connection, completion: completion)
    }

    private func receiveMetadataLength(
        on connection: NWConnection,
        completion: @escaping (ReceiveMessageResult) -> Void
    ) {
        connection.receive(exactLength: 2) { [weak self] data, _, _, error in
            guard let data = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            let length: Int16 = data.scanValue()
            self?.receiveMetadata(on: connection, length: Int(length), completion: completion)
        }
    }

    private func receiveMetadata(
        on connection: NWConnection,
        length: Int,
        completion: @escaping (ReceiveMessageResult) -> Void
    ) {
        connection.receive(exactLength: length) { [weak self] data, _, _, error in
            guard let metadata = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            self?.receiveDataLength(on: connection, metadata: metadata, completion: completion)
        }
    }

    private func receiveDataLength(
        on connection: NWConnection,
        metadata: Data,
        completion: @escaping (ReceiveMessageResult) -> Void
    ) {
        connection.receive(exactLength: 4) { [weak self] data, _, _, error in
            guard let data = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            let length: Int32 = data.scanValue()
            guard length < maxMessageDataLength else {
                completion(.failure(MessageServiceError.corruptMessage))
                return
            }
            guard length > 0 else {
                completion(.success(Data(), metadata: metadata))
                return
            }
            self?.receiveData(on: connection, length: Int(length), metadata: metadata, completion: completion)
        }
    }

    private func receiveData(
        on connection: NWConnection,
        length: Int,
        metadata: Data,
        completion: @escaping (ReceiveMessageResult) -> Void
    ) {
        connection.receive(exactLength: length) { data, _, _, error in
            guard let data = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            completion(.success(data, metadata: metadata))
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Internals
// ---------------------------------------------------------------------------

private extension NWConnection {

    /// Receives exactly the specified number of bytes from the connection.
    ///
    /// - Parameters:
    ///   - exactLength: The exact number of bytes to receive.
    ///   - completion: A closure called when the data has been received or an error occurs.
    ///     Includes the received data, content context, completion flag, and error if any.
    ///
    func receive(
        exactLength: Int,
        completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) {
        receive(minimumIncompleteLength: exactLength, maximumLength: exactLength, completion: completion)
    }
}

private extension Data {

    /// Scans a value of type `T` from the beginning of the data or from the
    /// given start index.
    ///
    /// - Parameter start: The byte offset to start reading from. Defaults to 0.
    /// - Returns: The decoded value of type `T`.
    ///
    func scanValue<T>(start: Int = 0) -> T {
        return scanValue(start: start, length: MemoryLayout<T>.size)
    }

    /// Scans a value of type `T` from the specified range in the data.
    ///
    /// - Parameters:
    ///   - start: The byte offset to start reading from.
    ///   - length: The number of bytes to read.
    /// - Returns: The decoded value of type `T`.
    ///
    func scanValue<T>(start: Int, length: Int) -> T {
        return subdata(in: start..<start+length)
            .withUnsafeBytes { $0.load(as: T.self) }
    }
}
