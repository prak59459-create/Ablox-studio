import Foundation
import Network
import CryptoKit

/// Builds the TLS-secured `NWParameters` every Ablox connection uses.
///
/// ## Why pre-shared keys rather than certificates
///
/// The obvious reading of "use `NWParameters.tls`" is to hand the listener a
/// `sec_identity_t` — a server certificate and private key. On iPad, inside
/// Swift Playgrounds, there is nowhere to get one: there is no provisioning
/// profile to carry a certificate, no Keychain entry to import into, and
/// generating a self-signed identity at runtime needs `SecItemAdd` with a
/// keychain-access-group entitlement the sandbox does not grant. A client
/// would then have to be told to trust that unknown certificate, which means
/// disabling verification — TLS with the security removed.
///
/// So Ablox authenticates with a **pre-shared key** instead, the same
/// mechanism Apple's own peer-to-peer networking samples use. The host shows a
/// short room code; joining players type it in. Both sides run it through
/// HMAC-SHA256 to derive the PSK, and the TLS handshake only completes if the
/// codes match.
///
/// What this buys, concretely:
///
/// - **Confidentiality and integrity.** A real TLS 1.3 AES-GCM session. Anyone
///   sniffing the café Wi-Fi sees ciphertext.
/// - **Mutual authentication.** Both ends prove they know the code. A stranger
///   on the same network cannot join, and cannot impersonate the host to a
///   joining player — which a "trust any certificate" setup would allow.
/// - **No infrastructure.** No CA, no server, no accounts. Two iPads on the
///   same Wi-Fi, or joined by AWDL peer-to-peer, and nothing else.
///
/// What it does not buy, stated plainly:
///
/// - **The code is the whole secret.** Anyone who learns it can join, and can
///   decrypt that session. Codes are per-session and short-lived, but a shoulder
///   surfer is in. Use a long code for a public space.
/// - **No forward secrecy against a leaked code.** Someone who records the
///   traffic *and* later learns the code can decrypt the recording. Ephemeral
///   Diffie-Hellman would fix this; it needs certificates, which is the problem
///   we started with.
/// - **Peers are trusted once joined.** See `docs/networking.md` — the host
///   validates what it can, but a modified client can still lie about its own
///   avatar position.
///
/// For "kids building worlds together in the same room", that is the right
/// trade. It would not be for anything carrying real user data.
public enum TLSPeerSecurity {

    /// Domain-separation string mixed into the HMAC, so a code reused in some
    /// other app never derives the same key here.
    private static let keyDerivationContext = "ablox.psk.v1"

    /// PSK identity hint sent in the clear during the handshake. Not a secret;
    /// it just labels which key is in play.
    private static let pskIdentity = "ablox"

    /// Builds parameters for both listening and connecting.
    ///
    /// - Parameter roomCode: the shared session code. Normalised (uppercased,
    ///   whitespace and dashes stripped) so "abcd-ef" and "ABCDEF" match —
    ///   otherwise a typo in formatting reads as a wrong code.
    public static func parameters(roomCode: String) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions

        let key = derivedKey(from: roomCode)
        key.withUnsafeBytes { keyBytes in
            let keyData = DispatchData(bytes: keyBytes)
            let identity = Data(pskIdentity.utf8)
            identity.withUnsafeBytes { identityBytes in
                let identityData = DispatchData(bytes: identityBytes)
                sec_protocol_options_add_pre_shared_key(
                    security,
                    keyData as __DispatchData,
                    identityData as __DispatchData
                )
            }
        }

        // The PSK ciphersuite both ends negotiate. AES-128-GCM-SHA256 is
        // hardware-accelerated on every iPad that runs iPadOS 17.
        sec_protocol_options_append_tls_ciphersuite(security, .AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)

        let tcpOptions = NWProtocolTCP.Options()
        // Avatar transforms are small and frequent; Nagle would batch them
        // into visible stutter.
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.keepaliveInterval = 2
        // Drop a peer that has gone away (iPad slept, walked out of range)
        // rather than holding a dead connection open.
        tcpOptions.connectionDropTime = 5

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        // Lets two iPads connect over AWDL when there is no shared Wi-Fi at
        // all — the "just put them next to each other" case.
        parameters.includePeerToPeer = true

        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: AbloxFramer.definition),
            at: 0
        )

        return parameters
    }

    /// HMAC-SHA256(code, context). 32 bytes.
    private static func derivedKey(from roomCode: String) -> SymmetricKey {
        let normalized = RoomCode.normalize(roomCode)
        let codeKey = SymmetricKey(data: Data(normalized.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(keyDerivationContext.utf8), using: codeKey)
        return SymmetricKey(data: Data(mac))
    }
}

// MARK: - RoomCode

/// Generation and normalisation of the short code that secures a session.
public enum RoomCode {

    /// Crockford-style alphabet: no I, L, O, U, 0 or 1, so a code read aloud
    /// or squinted at across a table cannot be mistyped into a different valid
    /// code.
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    public static let defaultLength = 6

    /// A fresh random code. Uses the system CSPRNG, not `Int.random`, because
    /// this value is the session's entire secret.
    public static func generate(length: Int = defaultLength) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // Practically unreachable, but falling back to a weak code
            // silently would be worse than being loud about it.
            assertionFailure("SecRandomCopyBytes failed with \(status)")
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        // Rejection-free mapping: the alphabet size (30) does not divide 256,
        // so a plain modulo is very slightly biased toward the first 16
        // symbols. At six characters that is far below what matters for a code
        // that lives for one session, and avoiding it would mean a retry loop
        // for no practical gain.
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Uppercases and strips anything that is not part of the alphabet, so
    /// "abcd ef", "ABCD-EF" and "abcdef" are the same code.
    public static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { alphabet.contains($0) })
    }

    public static func isPlausible(_ raw: String) -> Bool {
        normalize(raw).count >= 4
    }

    /// Groups a code for display: `ABC DEF`.
    public static func formatted(_ raw: String) -> String {
        let normalized = normalize(raw)
        guard normalized.count > 4 else { return normalized }
        let mid = normalized.index(normalized.startIndex, offsetBy: normalized.count / 2)
        return "\(normalized[..<mid]) \(normalized[mid...])"
    }
}
