# Approach

**Approach** is a Swift library for message passing between apps over the network. It supports both client and server roles, with optional Bonjour service discovery for zero-configuration local networking.

## License

Approach is available under the BSD Zero Clause License. One advantage of this license is that it does not require attribution. See the [LICENSE](LICENSE) file in the repository for details.

## Requirements

Minimum OS version requirements:

- iOS 16
- tvOS 16
- visionOS 1
- macOS 13 Ventura

## Features

- TCP message transmission with structured payloads
- Optional Bonjour advertisement and discovery
- Codable-based data and metadata messaging
- Asynchronous message reception using delegate callbacks
- Configurable logging support for diagnostics

## Installation

To use a dependency of another Swift package, add the following dependency to your `Package.swift` file:

```swift
.package(url: "https://github.com/yourusername/approach.git", from: "x.y.z")
```

- Replace `x.y.z` with the release version.
- Include `Approach` in your target dependencies.

## Example

### Define Messages

The messages to pass between apps are typically defined as `Codable` enums. This allows structured, type-safe messaging.

```swift
enum GeneralMessage: Codable {
    case helloWorld
    
    /// Client sends this to the server to ask about meaning of life
    case whatsTheMeaningOfLife
    
    /// Server sends this to the client with a number as the meaning of life
    case meaningOfLife(Int)
}
```

Each message is accompanied by app specific metadata. The metadata should typically contain the type of the message, to inform the receiver about how the message should be decoded.

```swift
enum AppMessageMetadata: String, Codable {

    /// Message should be decoded as `GeneralMessage`
    case general
}
```

### Encoding / Decoding Messages

For the purposes of this example, we will add encoding/decoding helpers to the message types, to make the example code more readable.

```swift
extension GeneralMessage {
    func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> GeneralMessage {
        try! JSONDecoder().decode(GeneralMessage.self, from: data)
    }
}

extension AppMessageMetadata {
    func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> AppMessageMetadata {
        try! JSONDecoder().decode(AppMessageMetadata.self, from: data)
    }
}
```

### Setting up the Server

This example shows how to set up a server that advertises its presence on the local network using Bonjour, listens for incoming clients, performs connection handshakes, and handles structured messages.

```swift
import Foundation
import Approach

class ExampleServer: MessageServiceDelegate, RemoteMessageClientDelegate {

    private let service: MessageService
    
    init() throws {
        // "MyService" is the Bonjour name to use for automatic discovery.
        service = try MessageService(name: "MyService")
        service.delegate = self
    }
    
    @discardableResult
    func start() -> Self {
        service.start()
    }

    func messageService(
        _ service: MessageService,
        clientDidConnect remoteClient: RemoteMessageClient
    ) {
        remoteClient.delegate = self
    }

    func clientDidStartSession(_ remoteClient: RemoteMessageClient) {
        print("Session started with remote client.")
    }

    func client(
        _ remoteClient: RemoteMessageClient,
        didReceiveMessage data: Data,
        metadata: Data
    ) {
        let metadata = AppMessageMetadata.decode(from: metadata)
        guard metadata == .general else {
            print("Received unexpected metadata")
            return
        }

        print("Server received a message of type: \(metadata.rawValue)")

        let message = GeneralMessage.decode(from: data),

        switch message {
        case .helloWorld:
            print("Client says hello. Say hello back.")
            sendMessage(.helloWorld, to: remoteClient)
        case .whatsTheMeaningOfLife:
            print("Client wants to know what the meaning of life is. It is 42.")
            sendMessage(.meaningOfLife(42), to: remoteClient)
        default:
            // Server does not care about e.g. the meaningOfLife message.
            break
        }
    }
    
    private func sendMessage(
        _ message: GeneralMessage,
        to remoteClient: RemoteMessageClient
    ) {
        remoteClient.sendMessage(
            data: message.encode(),
            metadata: AppMessageMetadata.general.encode()
        )
    }
}
```

If you are starting the server from a command line tool, you probably want to start a `RunLoop`, or the process will terminate without waiting for any messages.

```swift
let exampleServer = ExampleServer().start()
RunLoop.main.run()
```

### Setting up the Client (Bonjour-based)

This example shows how to set up a client that looks for advertising servers on the local network using Bonjour, connects to the server, and sends structured messages.

```swift
import Foundation
import Approach

class ExampleClient: MessageClientDelegate {

    private let client: MessageClient

    init() {
        // "MyService" is the Bonjour name to use for automatic discovery.
        client = MessageClient(serviceName: "MyService")
        client.delegate = self
    }
    
    @discardableResult
    func connect() -> Self {
        client.connect()
    }

    func clientDidStartSession(_ client: MessageClient) {
        // Send a couple of messages once the session has started.
        sendMessage(.helloWorld, to: client)
        sendMessage(.whatsTheMeaningOfLife)
    }

    func client(
        _ client: MessageClient,
        didReceiveMessage data: Data,
        metadata: Data
    ) {
        let metadata = AppMessageMetadata.decode(from: metadata)
        guard metadata == .general else {
            print("Invalid server message")
            return
        }

        let message = GeneralMessage.decode(from: data)

        print("Client received: \(message)")
    }

    func client(_ client: MessageClient, didFailSessionWithError error: Error) {
        print("Connection failed: \(error)")
    }
    
    func sendMessage(_ message: GeneralMessage, to client: MessageClient) {
        client.sendMessage(
            data: message.encode(),
            metadata: AppMessageMetadata.general.encode()
        )
    }
}
```

If you are starting the client from a command line tool, you probably want to start a `RunLoop`, or the process will terminate without waiting for any messages.

```swift
let client = ExampleClient().connect()
RunLoop.main.run()
```

### Setting up the Client (Direct IP Address)

To connect to a known server via IP and port, replace the `init` with:

```swift
init() {
    // "MyService" is the Bonjour name to use for automatic discovery.
    client = MessageClient(host: "192.168.1.10", port: 4242)
}
```

### Logging

Approach includes optional logging hooks to help with debugging and
development. You can assign a closure to `MessageClient.log` or
`RemoteMessageClient.log` to receive diagnostic output.

**Example**

```swift
MessageClient.log = { client, message in
    print("[Client][\(client)] \(message)")
}

RemoteMessageClient.log = { client, message in
    print("[Server][\(client.id)] \(message)")
}
```

Use this to observe connection state changes, message events, and internal
behavior during development.
