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
//  Every X509 type is written out in full here, because the app has a
//  `Certificate` of its own for signing certificates and it would otherwise
//  win the name.
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
		let caPrivateKey = X509.Certificate.PrivateKey(caKey)

		let caName = try X509.DistinguishedName {
			X509.CommonName("RaDown Local CA")
			X509.OrganizationName("RaDown")
		}

		let caCertificate = try X509.Certificate(
			version: X509.Certificate.Version.v3,
			serialNumber: X509.Certificate.SerialNumber(),
			publicKey: caPrivateKey.publicKey,
			notValidBefore: now.addingTimeInterval(-60 * 60),
			notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 60 * 60),
			issuer: caName,
			subject: caName,
			signatureAlgorithm: X509.Certificate.SignatureAlgorithm.ecdsaWithSHA256,
			extensions: try X509.Certificate.Extensions {
				Critical(X509.BasicConstraints.isCertificateAuthority(maxPathLength: 0))
				Critical(X509.KeyUsage(keyCertSign: true, cRLSign: true))
				X509.SubjectKeyIdentifier(hash: caPrivateKey.publicKey)
			},
			issuerPrivateKey: caPrivateKey
		)

		// The certificate the server presents. Apple refuses TLS certificates
		// that run longer than 825 days, so this one is deliberately short and
		// is replaced whenever it gets close to expiring.
		let serverKey = P256.Signing.PrivateKey()
		let serverPrivateKey = X509.Certificate.PrivateKey(serverKey)

		let serverName = try X509.DistinguishedName {
			X509.CommonName(host)
			X509.OrganizationName("RaDown")
		}

		let serverCertificate = try X509.Certificate(
			version: X509.Certificate.Version.v3,
			serialNumber: X509.Certificate.SerialNumber(),
			publicKey: serverPrivateKey.publicKey,
			notValidBefore: now.addingTimeInterval(-60 * 60),
			notValidAfter: now.addingTimeInterval(395 * 24 * 60 * 60),
			issuer: caName,
			subject: serverName,
			signatureAlgorithm: X509.Certificate.SignatureAlgorithm.ecdsaWithSHA256,
			extensions: try X509.Certificate.Extensions {
				Critical(X509.BasicConstraints.notCertificateAuthority)
				Critical(X509.KeyUsage(digitalSignature: true, keyEncipherment: true))
				try X509.ExtendedKeyUsage([X509.ExtendedKeyUsage.Usage.serverAuth])
				X509.SubjectAlternativeNames([
					X509.GeneralName.dnsName("localhost"),
					X509.GeneralName.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
				])
				X509.SubjectKeyIdentifier(hash: serverPrivateKey.publicKey)
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
