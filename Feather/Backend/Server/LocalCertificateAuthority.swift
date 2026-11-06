//
//  LocalCertificateAuthority.swift
//  RaDown
//
//  backloop.dev, which used to hand out the certificate the local install
//  server presented, stopped issuing certificates on 4 September 2026 and the
//  one shipped with the app expired on 29 October 2026. iOS answers an expired
//  or untrusted certificate by refusing the connection in silence, so installs
//  sat on "Ready" with nothing to show for it.
//
//  So the app makes its own certificate authority on the device instead. It
//  depends on no outside service and does not expire out from under anyone;
//  the authority has to be trusted once in Settings, after which the install
//  server works offline, forever.
//

import Foundation
import Crypto
import SwiftASN1
import X509

enum LocalCertificateAuthority {
	/// The server is reached on the device itself, so the certificate only ever
	/// has to be valid for the loopback address.
	static let host = "127.0.0.1"

	static let caCertificateFileName = "RaDownLocalCA.cer"

	struct Material {
		let caCertificatePEM: String
		let caCertificateDER: Data
		let serverCertificatePEM: String
		let serverPrivateKeyPEM: String
		let commonName: String
	}

	static func generate() throws -> Material {
		let now = Date()

		// The authority. Ten years, because the person installing it should not
		// have to repeat the trust steps.
		let caKey = P256.Signing.PrivateKey()
		let caPrivateKey = Certificate.PrivateKey(caKey)

		let caName = try DistinguishedName {
			CommonName("RaDown Local CA")
			OrganizationName("RaDown")
		}

		let caCertificate = try Certificate(
			version: .v3,
			serialNumber: Certificate.SerialNumber(),
			publicKey: caPrivateKey.publicKey,
			notValidBefore: now.addingTimeInterval(-60 * 60),
			notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 60 * 60),
			issuer: caName,
			subject: caName,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try Certificate.Extensions {
				Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
				Critical(KeyUsage(keyCertSign: true, cRLSign: true))
				SubjectKeyIdentifier(hash: caPrivateKey.publicKey)
			},
			issuerPrivateKey: caPrivateKey
		)

		// The certificate the server presents. Apple refuses TLS certificates
		// that run longer than 825 days, so this one is deliberately short and
		// is replaced whenever it gets close to expiring.
		let serverKey = P256.Signing.PrivateKey()
		let serverPrivateKey = Certificate.PrivateKey(serverKey)

		let serverName = try DistinguishedName {
			CommonName(host)
			OrganizationName("RaDown")
		}

		let serverCertificate = try Certificate(
			version: .v3,
			serialNumber: Certificate.SerialNumber(),
			publicKey: serverPrivateKey.publicKey,
			notValidBefore: now.addingTimeInterval(-60 * 60),
			notValidAfter: now.addingTimeInterval(395 * 24 * 60 * 60),
			issuer: caName,
			subject: serverName,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try Certificate.Extensions {
				Critical(BasicConstraints.notCertificateAuthority)
				Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
				try ExtendedKeyUsage([.serverAuth])
				SubjectAlternativeNames([
					.dnsName("localhost"),
					.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
				])
				SubjectKeyIdentifier(hash: serverPrivateKey.publicKey)
			},
			issuerPrivateKey: caPrivateKey
		)

		let caPEM = try caCertificate.serializeAsPEM()

		// The server sends its own certificate and the authority's, so a device
		// that trusts the authority can complete the chain.
		let chain = try serverCertificate.serializeAsPEM().pemString
			+ "\n"
			+ caPEM.pemString

		return Material(
			caCertificatePEM: caPEM.pemString,
			caCertificateDER: Data(caPEM.derBytes),
			serverCertificatePEM: chain,
			serverPrivateKeyPEM: try serverPrivateKey.serializeAsPEM().pemString,
			commonName: host
		)
	}
}
