// Copyright 2024 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "net/ssl/tls_fingerprint_config.h"

#include <sstream>

#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"

namespace net {

namespace {

// Returns true if |value| is a GREASE value as defined by RFC 8701.
// GREASE values follow the 0x?A?A pattern (e.g. 0x0A0A, 0x1A1A, ...).
bool IsGREASE(uint16_t value) {
  return (value & 0x0F0F) == 0x0A0A &&
         ((value >> 8) & 0xFF) == (value & 0xFF);
}

// Splits a '-'-separated string of decimal integers into a vector.
// Optionally filters GREASE values.
std::vector<uint16_t> SplitUint16List(const std::string& s,
                                      bool filter_grease = true) {
  std::vector<uint16_t> result;
  for (const auto& part : base::SplitString(s, "-", base::TRIM_WHITESPACE,
                                            base::SPLIT_WANT_NONEMPTY)) {
    unsigned int val = 0;
    if (base::StringToUint(part, &val) && val <= 0xFFFF) {
      uint16_t v = static_cast<uint16_t>(val);
      if (!filter_grease || !IsGREASE(v)) {
        result.push_back(v);
      }
    }
  }
  return result;
}

std::vector<uint8_t> SplitUint8List(const std::string& s) {
  std::vector<uint8_t> result;
  for (const auto& part : base::SplitString(s, "-", base::TRIM_WHITESPACE,
                                            base::SPLIT_WANT_NONEMPTY)) {
    unsigned int val = 0;
    if (base::StringToUint(part, &val) && val <= 0xFF) {
      result.push_back(static_cast<uint8_t>(val));
    }
  }
  return result;
}

std::string JoinUint16(const std::vector<uint16_t>& v) {
  std::string out;
  for (size_t i = 0; i < v.size(); ++i) {
    if (i > 0) out += '-';
    out += base::NumberToString(v[i]);
  }
  return out;
}

std::string JoinUint8(const std::vector<uint8_t>& v) {
  std::string out;
  for (size_t i = 0; i < v.size(); ++i) {
    if (i > 0) out += '-';
    out += base::NumberToString(v[i]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// IANA → BoringSSL cipher name table
// ---------------------------------------------------------------------------
struct CipherEntry {
  uint16_t iana_id;
  const char* boringssl_name;
};

// BoringSSL cipher names accepted by SSL_set_cipher_list / SSL_set_ciphersuites
static constexpr CipherEntry kCipherMap[] = {
    // ── TLS 1.3 (use SSL_CTX_set_ciphersuites) ──────────────────────────────
    {0x1301, "TLS_AES_128_GCM_SHA256"},
    {0x1302, "TLS_AES_256_GCM_SHA384"},
    {0x1303, "TLS_CHACHA20_POLY1305_SHA256"},

    // ── TLS 1.2 ECDHE-ECDSA ─────────────────────────────────────────────────
    {0xC02B, "ECDHE-ECDSA-AES128-GCM-SHA256"},
    {0xC02C, "ECDHE-ECDSA-AES256-GCM-SHA384"},
    {0xCCA9, "ECDHE-ECDSA-CHACHA20-POLY1305"},
    {0xC009, "ECDHE-ECDSA-AES128-SHA"},
    {0xC00A, "ECDHE-ECDSA-AES256-SHA"},
    {0xC023, "ECDHE-ECDSA-AES128-SHA256"},
    {0xC024, "ECDHE-ECDSA-AES256-SHA384"},

    // ── TLS 1.2 ECDHE-RSA ───────────────────────────────────────────────────
    {0xC02F, "ECDHE-RSA-AES128-GCM-SHA256"},
    {0xC030, "ECDHE-RSA-AES256-GCM-SHA384"},
    {0xCCA8, "ECDHE-RSA-CHACHA20-POLY1305"},
    {0xC013, "ECDHE-RSA-AES128-SHA"},
    {0xC014, "ECDHE-RSA-AES256-SHA"},
    {0xC027, "ECDHE-RSA-AES128-SHA256"},
    {0xC028, "ECDHE-RSA-AES256-SHA384"},

    // ── TLS 1.2 RSA ─────────────────────────────────────────────────────────
    {0x009C, "AES128-GCM-SHA256"},
    {0x009D, "AES256-GCM-SHA384"},
    {0x002F, "AES128-SHA"},
    {0x0035, "AES256-SHA"},
    {0x000A, "DES-CBC3-SHA"},
    {0x003C, "AES128-SHA256"},
    {0x003D, "AES256-SHA256"},

    // ── TLS 1.2 DHE-RSA ─────────────────────────────────────────────────────
    {0x009E, "DHE-RSA-AES128-GCM-SHA256"},
    {0x009F, "DHE-RSA-AES256-GCM-SHA384"},
    {0xCCAA, "DHE-RSA-CHACHA20-POLY1305"},
    {0x0033, "DHE-RSA-AES128-SHA"},
    {0x0039, "DHE-RSA-AES256-SHA"},
    {0x0067, "DHE-RSA-AES128-SHA256"},
    {0x006B, "DHE-RSA-AES256-SHA256"},

    // ── Fallback / legacy ────────────────────────────────────────────────────
    {0x00FF, "TLS_EMPTY_RENEGOTIATION_INFO_SCSV"},
};

}  // namespace

// ---------------------------------------------------------------------------
// TLSFingerprintParams
// ---------------------------------------------------------------------------

bool TLSFingerprintParams::operator==(const TLSFingerprintParams& o) const {
  return enabled == o.enabled && min_version == o.min_version &&
         max_version == o.max_version && cipher_suites == o.cipher_suites &&
         supported_groups == o.supported_groups &&
         ec_point_formats == o.ec_point_formats &&
         extension_order == o.extension_order &&
         permute_extensions == o.permute_extensions;
}

bool TLSFingerprintParams::operator!=(const TLSFingerprintParams& o) const {
  return !(*this == o);
}

// ---------------------------------------------------------------------------
// ParseJA3String
// ---------------------------------------------------------------------------

TLSFingerprintParams ParseJA3String(const std::string& ja3) {
  TLSFingerprintParams params;

  // JA3 is comma-separated: Version,Ciphers,Extensions,Curves,PointFormats
  std::vector<std::string> fields =
      base::SplitString(ja3, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_ALL);

  if (fields.size() < 1 || fields[0].empty()) {
    return params;  // invalid
  }

  // Field 0: TLS version (single value)
  unsigned int version = 0;
  if (base::StringToUint(fields[0], &version) && version <= 0xFFFF) {
    uint16_t v = static_cast<uint16_t>(version);
    // JA3 records the negotiated version; use it as max_version.
    // min_version = TLS 1.0 by default (0x0301) unless overridden.
    params.max_version = v;
    params.min_version = 0x0301;  // TLS 1.0
  }

  // Field 1: Cipher suites (filter GREASE)
  if (fields.size() > 1) {
    params.cipher_suites = SplitUint16List(fields[1], /*filter_grease=*/true);
  }

  // Field 2: Extension types → extension_order (filter GREASE)
  if (fields.size() > 2) {
    params.extension_order =
        SplitUint16List(fields[2], /*filter_grease=*/true);
  }

  // Field 3: Elliptic curves / supported groups (filter GREASE)
  if (fields.size() > 3) {
    params.supported_groups =
        SplitUint16List(fields[3], /*filter_grease=*/true);
  }

  // Field 4: EC point formats
  if (fields.size() > 4) {
    params.ec_point_formats = SplitUint8List(fields[4]);
  }

  params.enabled = true;
  return params;
}

// ---------------------------------------------------------------------------
// ToJA3String
// ---------------------------------------------------------------------------

std::string ToJA3String(const TLSFingerprintParams& params) {
  // Use max_version as the JA3 "SSLVersion" field.
  std::string version = base::NumberToString(params.max_version
                                                 ? params.max_version
                                                 : 771 /* TLS 1.2 default */);
  return version + "," + JoinUint16(params.cipher_suites) + "," +
         JoinUint16(params.extension_order) + "," +
         JoinUint16(params.supported_groups) + "," +
         JoinUint8(params.ec_point_formats);
}

// ---------------------------------------------------------------------------
// CipherSuiteIANAToBoringSSL
// ---------------------------------------------------------------------------

const char* CipherSuiteIANAToBoringSSL(uint16_t iana_id) {
  for (const auto& entry : kCipherMap) {
    if (entry.iana_id == iana_id) {
      return entry.boringssl_name;
    }
  }
  return nullptr;
}

// ---------------------------------------------------------------------------
// TLSFingerprintManager
// ---------------------------------------------------------------------------

// static
TLSFingerprintManager* TLSFingerprintManager::GetInstance() {
  static base::NoDestructor<TLSFingerprintManager> instance;
  return instance.get();
}

void TLSFingerprintManager::SetParams(const TLSFingerprintParams& params) {
  base::AutoLock lock(lock_);
  params_ = params;
  params_.enabled = true;
}

TLSFingerprintParams TLSFingerprintManager::GetParams() const {
  base::AutoLock lock(lock_);
  return params_;
}

void TLSFingerprintManager::Reset() {
  base::AutoLock lock(lock_);
  params_ = TLSFingerprintParams();
}

bool TLSFingerprintManager::IsEnabled() const {
  base::AutoLock lock(lock_);
  return params_.enabled;
}

}  // namespace net
