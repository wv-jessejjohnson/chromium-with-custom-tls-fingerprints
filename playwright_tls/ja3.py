"""
JA3 fingerprint utilities.

JA3 is a method for fingerprinting TLS ClientHello messages by hashing:
  SSLVersion, Ciphers, Extensions, EllipticCurves, EllipticCurvePointFormats

This module provides:
  - parse_ja3()   : parse a JA3 string into a dict of TLS parameters
  - build_ja3()   : serialise parameters back to a JA3 string
  - compute_ja3() : compute JA3 hash from parameters (for verification)
  - is_grease()   : identify GREASE values (RFC 8701)
"""

from __future__ import annotations

import hashlib
import re
from typing import Dict, List, Optional


# ---------------------------------------------------------------------------
# GREASE detection
# ---------------------------------------------------------------------------

def is_grease(value: int) -> bool:
    """Return True if *value* is a GREASE value (RFC 8701, 0x?A?A pattern)."""
    return (value & 0x0F0F) == 0x0A0A and ((value >> 8) & 0xFF) == (value & 0xFF)


def filter_grease(values: List[int]) -> List[int]:
    """Remove GREASE values from *values*."""
    return [v for v in values if not is_grease(v)]


# ---------------------------------------------------------------------------
# JA3 string parsing
# ---------------------------------------------------------------------------

def _parse_int_list(s: str, filter_grease_values: bool = True) -> List[int]:
    if not s:
        return []
    parts = s.split("-")
    result: List[int] = []
    for p in parts:
        p = p.strip()
        if p.isdigit():
            v = int(p)
            if filter_grease_values and is_grease(v):
                continue
            result.append(v)
    return result


def parse_ja3(ja3: str) -> Dict:
    """Parse a JA3 string into a parameter dict.

    Returns a dict with keys:
      ssl_version       (int)
      cipher_suites     (list[int])  — GREASE filtered
      extensions        (list[int])  — GREASE filtered
      elliptic_curves   (list[int])  — GREASE filtered
      point_formats     (list[int])

    Raises ``ValueError`` if the string format is invalid.
    """
    fields = ja3.split(",")
    if len(fields) < 5:
        # Some JA3 strings omit trailing empty fields; pad them.
        fields += [""] * (5 - len(fields))

    try:
        ssl_version = int(fields[0].strip()) if fields[0].strip() else 0
    except ValueError:
        raise ValueError(f"Invalid JA3 string: bad ssl_version field '{fields[0]}'")

    return {
        "ssl_version":     ssl_version,
        "cipher_suites":   _parse_int_list(fields[1]),
        "extensions":      _parse_int_list(fields[2]),
        "elliptic_curves": _parse_int_list(fields[3]),
        "point_formats":   _parse_int_list(fields[4], filter_grease_values=False),
    }


def build_ja3(
    ssl_version: int,
    cipher_suites: List[int],
    extensions: List[int],
    elliptic_curves: List[int],
    point_formats: List[int],
) -> str:
    """Build a JA3 string from individual TLS parameters."""
    def join(lst: List[int]) -> str:
        return "-".join(str(v) for v in lst)

    return ",".join([
        str(ssl_version),
        join(cipher_suites),
        join(extensions),
        join(elliptic_curves),
        join(point_formats),
    ])


def compute_ja3_hash(ja3_string: str) -> str:
    """Compute the MD5 JA3 hash of a JA3 string."""
    return hashlib.md5(ja3_string.encode()).hexdigest()


# ---------------------------------------------------------------------------
# CDP parameter conversion
# ---------------------------------------------------------------------------

def ja3_to_cdp_params(ja3: str) -> Dict:
    """Convert a JA3 string to CDP ``Emulation.setTLSFingerprint`` parameters.

    Returns a dict suitable for passing as ``**kwargs`` to
    ``page.cdp_session.send("Emulation.setTLSFingerprint", ...)``
    """
    p = parse_ja3(ja3)
    params: Dict = {"ja3String": ja3}

    if p["cipher_suites"]:
        params["cipherSuites"] = p["cipher_suites"]
    if p["extensions"]:
        params["extensionOrder"] = p["extensions"]
    if p["elliptic_curves"]:
        params["supportedGroups"] = p["elliptic_curves"]
    if p["ssl_version"]:
        params["maxVersion"] = p["ssl_version"]
        # Set minVersion to TLS 1.0 (769) as a safe default.
        params["minVersion"] = 769

    return params


# ---------------------------------------------------------------------------
# Known TLS extension names (for debugging / display)
# ---------------------------------------------------------------------------

EXTENSION_NAMES: Dict[int, str] = {
    0:     "server_name",
    1:     "max_fragment_length",
    5:     "status_request",
    10:    "supported_groups",
    11:    "ec_point_formats",
    13:    "signature_algorithms",
    14:    "use_srtp",
    15:    "heartbeat",
    16:    "application_layer_protocol_negotiation",
    17:    "status_request_v2",
    18:    "signed_certificate_timestamp",
    21:    "padding",
    22:    "encrypt_then_mac",
    23:    "extended_master_secret",
    27:    "compress_certificate",
    28:    "record_size_limit",
    35:    "session_ticket",
    41:    "pre_shared_key",
    42:    "early_data",
    43:    "supported_versions",
    44:    "cookie",
    45:    "psk_key_exchange_modes",
    47:    "certificate_authorities",
    48:    "oid_filters",
    49:    "post_handshake_auth",
    50:    "signature_algorithms_cert",
    51:    "key_share",
    17513: "application_settings",  # ALPS (0x4469)
    65281: "renegotiation_info",    # 0xFF01
}

CIPHER_NAMES: Dict[int, str] = {
    0x1301: "TLS_AES_128_GCM_SHA256",
    0x1302: "TLS_AES_256_GCM_SHA384",
    0x1303: "TLS_CHACHA20_POLY1305_SHA256",
    0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    0xC013: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
    0xC014: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
    0x009C: "TLS_RSA_WITH_AES_128_GCM_SHA256",
    0x009D: "TLS_RSA_WITH_AES_256_GCM_SHA384",
    0x002F: "TLS_RSA_WITH_AES_128_CBC_SHA",
    0x0035: "TLS_RSA_WITH_AES_256_CBC_SHA",
    0x000A: "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
}

GROUP_NAMES: Dict[int, str] = {
    29:    "x25519",
    23:    "secp256r1",
    24:    "secp384r1",
    25:    "secp521r1",
    256:   "ffdhe2048",
    257:   "ffdhe3072",
    25497: "x25519_kyber768draft00",
}


def describe_ja3(ja3: str) -> str:
    """Return a human-readable summary of a JA3 string."""
    p = parse_ja3(ja3)
    lines = [
        f"JA3 hash     : {compute_ja3_hash(ja3)}",
        f"JA3 string   : {ja3}",
        f"TLS version  : {p['ssl_version']} (0x{p['ssl_version']:04X})",
        "Cipher suites:",
    ]
    for c in p["cipher_suites"]:
        name = CIPHER_NAMES.get(c, "unknown")
        lines.append(f"  0x{c:04X}  {name}")
    lines.append("Extensions (order):")
    for e in p["extensions"]:
        name = EXTENSION_NAMES.get(e, "unknown")
        lines.append(f"  {e:5d}  {name}")
    lines.append("Elliptic curves:")
    for g in p["elliptic_curves"]:
        name = GROUP_NAMES.get(g, "unknown")
        lines.append(f"  {g:5d}  {name}")
    lines.append(f"Point formats: {p['point_formats']}")
    return "\n".join(lines)
