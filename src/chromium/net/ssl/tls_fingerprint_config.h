// Copyright 2024 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef NET_SSL_TLS_FINGERPRINT_CONFIG_H_
#define NET_SSL_TLS_FINGERPRINT_CONFIG_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/component_export.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"

namespace net {

// Holds custom TLS ClientHello parameters for fingerprint spoofing.
// All numeric identifiers follow IANA TLS registry values.
//
// This struct is designed to be populated from a JA3 string or set manually,
// then applied to every SSL connection by SSLClientSocketImpl.
struct COMPONENT_EXPORT(NET) TLSFingerprintParams {
  // TLS protocol version limits (0 = use Chromium defaults).
  // 0x0301 = TLS 1.0, 0x0302 = TLS 1.1, 0x0303 = TLS 1.2, 0x0304 = TLS 1.3
  uint16_t min_version = 0;
  uint16_t max_version = 0;

  // Cipher suites in preferred send order (IANA values).
  // Empty = use Chromium/BoringSSL defaults.
  //   TLS 1.3 suite examples: 0x1301, 0x1302, 0x1303
  //   TLS 1.2 suite examples: 0xC02B (ECDHE-ECDSA-AES128-GCM-SHA256),
  //                           0xC02F (ECDHE-RSA-AES128-GCM-SHA256), ...
  std::vector<uint16_t> cipher_suites;

  // Supported elliptic curve groups (IANA NamedGroup values).
  // Empty = use Chromium/BoringSSL defaults.
  //   29 = x25519, 23 = secp256r1 (P-256), 24 = secp384r1 (P-384),
  //   25 = secp521r1 (P-521), 25497 = x25519_kyber768draft00 (post-quantum)
  std::vector<uint16_t> supported_groups;

  // EC point formats (0 = uncompressed, 1 = compressed_prime).
  // Empty = use defaults.
  std::vector<uint8_t> ec_point_formats;

  // TLS extension types in desired ClientHello send order (IANA values).
  // Extensions in this list are sent first (in listed order);
  // remaining extensions are appended after in their default order.
  // Empty = use BoringSSL's default extension order.
  //   Common values: 0=SNI, 5=status_request, 10=supported_groups,
  //   11=ec_point_formats, 13=signature_algorithms, 16=ALPN,
  //   18=signed_certificate_timestamp, 21=padding, 23=extended_master_secret,
  //   27=compress_certificate, 35=session_ticket, 43=supported_versions,
  //   45=psk_key_exchange_modes, 51=key_share, 65281=renegotiation_info
  std::vector<uint16_t> extension_order;

  // If true, randomly permute extension order each connection
  // (mutually exclusive with extension_order; permute_extensions wins).
  bool permute_extensions = false;

  // Whether this configuration is active (applied to new SSL connections).
  bool enabled = false;

  bool operator==(const TLSFingerprintParams& other) const;
  bool operator!=(const TLSFingerprintParams& other) const;
};

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

// Parses a JA3 fingerprint string into TLSFingerprintParams.
//
// JA3 format (all fields are '-'-separated decimal IANA integers):
//   "<SSLVersion>,<Ciphers>,<Extensions>,<EllipticCurves>,<PointFormats>"
//
// GREASE values (RFC 8701 – 0xXAXA patterns) are automatically stripped from
// ciphers, extensions, and curves, matching standard JA3 computation.
//
// Example:
//   "771,4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-"
//   "157-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-21,29-23-24,0"
COMPONENT_EXPORT(NET)
TLSFingerprintParams ParseJA3String(const std::string& ja3);

// Serializes TLSFingerprintParams back to a canonical JA3 string.
COMPONENT_EXPORT(NET)
std::string ToJA3String(const TLSFingerprintParams& params);

// Returns the BoringSSL/OpenSSL cipher string name for an IANA cipher suite
// value, or nullptr if the suite is not supported by BoringSSL.
COMPONENT_EXPORT(NET)
const char* CipherSuiteIANAToBoringSSL(uint16_t iana_id);

// ---------------------------------------------------------------------------
// Global singleton manager (browser process ↔ network service)
// ---------------------------------------------------------------------------

// Thread-safe singleton that stores the active TLSFingerprintParams.
// Written by the DevTools/CDP handler (browser process or network service
// depending on the IPC path used), read by SSLClientSocketImpl on every
// new connection.
class COMPONENT_EXPORT(NET) TLSFingerprintManager {
 public:
  static TLSFingerprintManager* GetInstance();

  // Activates a new fingerprint config. Thread-safe.
  void SetParams(const TLSFingerprintParams& params);

  // Returns the current config. Thread-safe.
  TLSFingerprintParams GetParams() const;

  // Disables custom fingerprinting (reverts to Chromium defaults).
  void Reset();

  // Returns true if a custom config is currently active.
  bool IsEnabled() const;

 private:
  friend class base::NoDestructor<TLSFingerprintManager>;
  TLSFingerprintManager() = default;
  ~TLSFingerprintManager() = default;

  mutable base::Lock lock_;
  TLSFingerprintParams params_ GUARDED_BY(lock_);
};

}  // namespace net

#endif  // NET_SSL_TLS_FINGERPRINT_CONFIG_H_
