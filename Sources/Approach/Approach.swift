//
// MIT License
//
// Copyright (c) 2018 Apparata AB
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

#if os(iOS) || os(tvOS)
import UIKit
#else
import Foundation
#endif

#if !canImport(Network)
#error("Minimum system requirements: iOS 12, macOS 10.14 Mojave, tvOS 12")
#else
import Network

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

private let messageServiceProtocolVersion = "0001"
private let messageServiceType = "_apparata-approach-v\(messageServiceProtocolVersion)._tcp"
private let messageServiceVersion = "APPSERVICEV\(messageServiceProtocolVersion)"
private let messageClientVersion = "APPCLIENTV\(messageServiceProtocolVersion)"
private let maxMessageDataLength: Int32 = 10_000_000

// ---------------------------------------------------------------------------
// MARK: - Result types
// ---------------------------------------------------------------------------

public enum SendMessageResult {
    case success
    case failure(Swift.Error)
}

public enum ReceiveMessageResult {
    case success(Data, metadata: Data)
    case failure(Swift.Error)
}

public enum MessageServiceError: Swift.Error {
    case unknownError
    case corruptMessage
    case noConnection
    case handshakeFailed(reason: Error?)
}

// ----------------------------------------------------------------------------
// MARK: - Server
// ----------------------------------------------------------------------------

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public class MessageService {
    
    public static var log: ((MessageService, String) -> Void)?
    
    public weak var delegate: MessageServiceDelegate?
    
    private let queue = DispatchQueue(label: "MessageServiceQueue", qos: .userInteractive)
    
    private var listener: NWListener?
    
    private var clients: [UUID: RemoteMessageClient] = [:]
    
    private var serviceName: String?
    
    private var restartOnDidBecomeActive = false
    
    public init(name: String? = nil) throws {
        serviceName = name
        observeAppState()
        try createService()
    }
    
    public func observeAppState() {
        #if os(iOS) || os(tvOS)
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appWillResignActive(notification:)),
                                       name: UIApplication.willResignActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appDidBecomeActive(notification:)),
                                       name: UIApplication.didBecomeActiveNotification, object: nil)
        #endif
    }
    
    public func createService() throws {
        
        if listener != nil {
            listener?.cancel()
            listener = nil
        }
        
        let newListener = try NWListener(using: .tcp)
        newListener.service = NWListener.Service(name: serviceName, type: messageServiceType)
        
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
    
    public func start() {
        listener?.start(queue: queue)
    }
    
    private func recreateService() throws {
        try createService()
        start()
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
        }
    }
    
    // MARK: - Background and foreground handling.
    
    #if os(iOS) || os(tvOS)
    
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

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public protocol MessageServiceDelegate: class {
    func messageService(_ service: MessageService, didAdvertiseAs name: String)
    func messageService(_ service: MessageService, didUnadvertiseAs name: String)
    
    func messageService(_ service: MessageService, clientDidConnect client: RemoteMessageClient)
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public extension MessageServiceDelegate {
    public func messageService(_ service: MessageService, didAdvertiseAs name: String) {}
    public func messageService(_ service: MessageService, didUnadvertiseAs name: String) {}
}

// ----------------------------------------------------------------------------
// MARK: - Remote Client
// ----------------------------------------------------------------------------

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public class RemoteMessageClient {
    
    public static var log: ((RemoteMessageClient, String) -> Void)?
    
    public let id: UUID
    
    fileprivate var didInvalidate: ((RemoteMessageClient) -> Void)?
    
    weak var delegate: RemoteMessageClientDelegate?
    
    private let connection: NWConnection
    
    private let messageSender = MessageSender()
    private let messageReceiver = MessageReceiver()
    
    private var didHandshake: Bool = false
    
    fileprivate init(connection: NWConnection) {
        id = UUID()
        self.connection = connection
        configureConnection(connection)
    }
    
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

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
extension RemoteMessageClient: Hashable {
    
    public var hashValue: Int {
        return id.hashValue
    }
    
    public static func ==(lhs: RemoteMessageClient, rhs: RemoteMessageClient) -> Bool {
        return lhs.id == rhs.id
    }
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public protocol RemoteMessageClientDelegate: class {
    func clientDidStartSession(_ client: RemoteMessageClient)
    func client(_ client: RemoteMessageClient, didPauseSessionWithError error: NWError)
    func client(_ client: RemoteMessageClient, didFailSessionWithError error: Error)
    func clientDidEndSession(_ client: RemoteMessageClient)
    func client(_ client: RemoteMessageClient, didReceiveMessage data: Data, metadata: Data)
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
extension RemoteMessageClientDelegate {
    func clientDidStartSession(_ client: RemoteMessageClient) {}
    func client(_ client: RemoteMessageClient, didPauseSessionWithError error: NWError) {}
    func client(_ client: RemoteMessageClient, didFailSessionWithError error: Error) {}
    func clientDidEndSession(_ client: RemoteMessageClient) {}
}

// ----------------------------------------------------------------------------
// MARK: - Client
// ----------------------------------------------------------------------------

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public class MessageClient {
    
    public static var log: ((MessageClient, String) -> Void)?
    
    public weak var delegate: MessageClientDelegate?
    
    private let queue = DispatchQueue(label: "MessageClientQueue", qos: .userInteractive)
    
    private var connection: NWConnection?
    
    private let serviceName: String
    
    private let messageSender = MessageSender()
    private let messageReceiver = MessageReceiver()
    
    private var didHandshake: Bool = false
    
    public init(serviceName: String) {
        self.serviceName = serviceName
    }
    
    public func connect() {
        
        guard self.connection == nil || self.connection?.state == .cancelled else {
            MessageClient.log?(self, "Error: Cannot reconnect, connection not in cancelled state.")
            return
        }
        
        self.connection = nil
        didHandshake = false
        
        let service: NWEndpoint = .service(name: serviceName,
                                           type: messageServiceType,
                                           domain: "local",
                                           interface: nil)
        
        let connection = NWConnection(to: service, using: .tcp)
        self.connection = connection
        
        connection.restart()
        
        connection.stateUpdateHandler = { [weak self] newState in
            self?.handleStateUpdate(newState)
        }
        
        connection.start(queue: queue)
    }
    
    public func sendMessage(data: Data,
                            metadata: Data,
                            completion: ((SendMessageResult) -> Void)? = nil) {
        guard let connection = connection else {
            completion?(.failure(MessageServiceError.noConnection))
            return
        }
        messageSender.sendMessage(on: connection, data: data, metadata: metadata, completion: completion)
    }
    
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

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public protocol MessageClientDelegate: class {
    func clientDidStartSession(_ client: MessageClient)
    func client(_ client: MessageClient, didPauseSessionWithError error: NWError)
    func client(_ client: MessageClient, didFailSessionWithError error: Error)
    func clientDidEndSession(_ client: MessageClient)
    func client(_ client: MessageClient, didReceiveMessage data: Data, metadata: Data)
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
public extension MessageClientDelegate {
    func clientDidStartSession(_ client: MessageClient) {}
    func client(_ client: MessageClient, didPauseSessionWithError error: NWError) {}
    func client(_ client: MessageClient, didFailSessionWithError error: Error) {}
    func clientDidEndSession(_ client: MessageClient) {}
}

// ----------------------------------------------------------------------------
// MARK: - Message Sender
// ----------------------------------------------------------------------------

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
private class MessageSender {
    
    func sendMessage(on connection: NWConnection, data: Data, metadata: Data,
                     completion: ((SendMessageResult) -> Void)?) {

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
        let data = Data(bytes: bytes)
        return data
    }
}

// ----------------------------------------------------------------------------
// MARK: - Message Receiver
// ----------------------------------------------------------------------------

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
private class MessageReceiver {
    
    /// Int16 - Metadata Length
    /// Data - Metadata
    /// Int32 - Data Length
    /// Data - Data
    func receiveMessage(on connection: NWConnection,
                        completion: @escaping (ReceiveMessageResult) -> Void) {
        receiveMetadataLength(on: connection, completion: completion)
    }
    
    private func receiveMetadataLength(on connection: NWConnection,
                                       completion: @escaping (ReceiveMessageResult) -> Void) {
        connection.receive(exactLength: 2) { [weak self] data, _, _, error in
            guard let data = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            let length: Int16 = data.scanValue()
            self?.receiveMetadata(on: connection, length: Int(length), completion: completion)
        }
    }
    
    private func receiveMetadata(on connection: NWConnection, length: Int,
                                 completion: @escaping (ReceiveMessageResult) -> Void) {
        connection.receive(exactLength: length) { [weak self] data, _, _, error in
            guard let metadata = data else {
                completion(.failure(error ?? MessageServiceError.unknownError))
                return
            }
            self?.receiveDataLength(on: connection, metadata: metadata, completion: completion)
        }
    }
    
    private func receiveDataLength(on connection: NWConnection, metadata: Data,
                                   completion: @escaping (ReceiveMessageResult) -> Void) {
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
    
    private func receiveData(on connection: NWConnection, length: Int, metadata: Data, completion: @escaping (ReceiveMessageResult) -> Void) {
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

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
private extension NWConnection {
    
    func receive(exactLength: Int, completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        receive(minimumIncompleteLength: exactLength, maximumLength: exactLength, completion: completion)
    }
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, *)
private extension Data {
    
    func scanValue<T>(start: Int = 0) -> T {
        return scanValue(start: start, length: MemoryLayout<T>.size)
    }
    
    func scanValue<T>(start: Int, length: Int) -> T {
        return subdata(in: start..<start+length).withUnsafeBytes { $0.pointee }
    }
}

#endif
