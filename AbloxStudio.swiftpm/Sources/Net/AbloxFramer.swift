import Foundation
import Network

/// Message framing for the Ablox protocol, as an `NWProtocolFramer`.
///
/// TCP is a byte stream: a `receive` can hand back half a message, or three of
/// them at once. Rather than reassembling by hand at every call site, framing
/// is pushed into the protocol stack — `NWConnection.receiveMessage` then
/// delivers exactly one whole packet, with its parsed header attached as
/// message metadata.
///
/// The header layout is `PacketHeader`'s, and the same length-prefix logic is
/// mirrored in `StreamReassembler` so it can be unit-tested off-device (see
/// `WireFormatTests`). This type is the thin Network.framework shell around
/// that format.
public final class AbloxFramer: NWProtocolFramerImplementation {

    public static let label = "Ablox"
    public static let definition = NWProtocolFramer.Definition(implementation: AbloxFramer.self)

    public init(framer: NWProtocolFramer.Instance) {}

    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    public func wakeup(framer: NWProtocolFramer.Instance) {}
    public func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    public func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: Output

    public func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        guard var header = message.abloxHeader else {
            // A message with no header metadata cannot be framed. Dropping it
            // is better than writing a body the peer will read as a header.
            assertionFailure("AbloxFramer: outgoing message is missing its header")
            return
        }

        // The caller sets the payload length when it builds the packet, but
        // the framer is the last word on how many bytes actually follow.
        header.payloadLength = UInt32(messageLength)
        framer.writeOutput(data: header.encoded())

        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // Only thrown if the stack is already torn down; the connection's
            // state handler reports the real failure.
        }
    }

    // MARK: Input

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsedHeader: PacketHeader?

            let parsed = framer.parseInput(
                minimumIncompleteLength: PacketHeader.encodedSize,
                maximumLength: PacketHeader.encodedSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= PacketHeader.encodedSize else { return 0 }
                parsedHeader = PacketHeader(decoding: Data(buffer))
                // Consume the header only when it parsed; returning 0 leaves
                // it buffered for the next pass.
                return parsedHeader == nil ? 0 : PacketHeader.encodedSize
            }

            // Not enough bytes yet: ask to be woken when the rest arrives.
            guard parsed else { return PacketHeader.encodedSize }

            guard let header = parsedHeader else {
                // A header-sized run of bytes that is not a valid header means
                // the stream is desynchronised or the peer is not Ablox. There
                // is no safe resync point in a length-prefixed format, so stop
                // consuming and let the connection fail.
                return 0
            }

            let payloadLength = Int(header.payloadLength)
            guard payloadLength >= 0, payloadLength <= AbloxProtocol.maxPayloadLength else {
                return 0
            }

            if !framer.deliverInputNoCopy(
                length: payloadLength,
                message: NWProtocolFramer.Message(abloxHeader: header),
                isComplete: true
            ) {
                return 0
            }
        }
    }
}

// MARK: - Message metadata

private let abloxHeaderKey = "AbloxPacketHeader"

public extension NWProtocolFramer.Message {
    convenience init(abloxHeader: PacketHeader) {
        self.init(definition: AbloxFramer.definition)
        self[abloxHeaderKey] = abloxHeader
    }

    /// The parsed header the framer attached to an inbound message, or that
    /// the sender attached to an outbound one.
    var abloxHeader: PacketHeader? {
        self[abloxHeaderKey] as? PacketHeader
    }
}
