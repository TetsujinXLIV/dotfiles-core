#!/usr/bin/env python3
"""Scan, verify, update, and add bootable OS ISOs & bootloader on a Ventoy USB."""
# Tier: 2
# /// script
# requires-python = ">=3.12"
# dependencies = ["rich>=13.9.4"]
# ///

import argparse
import bz2
import dataclasses
import enum
import getpass
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from rich import box
from rich.console import Console
from rich.progress import (
  BarColumn,
  DownloadColumn,
  Progress,
  SpinnerColumn,
  TextColumn,
  TimeRemainingColumn,
  TransferSpeedColumn,
)
from rich.prompt import Confirm, Prompt
from rich.table import Table

CONSOLE = Console()
STDERR_CONSOLE = Console(stderr=True)

USER_AGENT = "homelab-ventoy-updater/1.0 (+https://github.com)"
MANIFEST_FILENAME = ".ventoy-manifest.json"
CHUNK_SIZE = 1024 * 1024  # 1 MiB streaming buffer
TMP_HEADROOM_BYTES = 1024 * 1024 * 1024  # 1 GiB safety margin
FALLBACK_UNKNOWN_ISO_BYTES = 12 * 1024 * 1024 * 1024  # 12 GiB conservative cap

IGNORED_DIR_NAMES: frozenset[str] = frozenset(
  {
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    ".TemporaryItems",
    "System Volume Information",
    "$RECYCLE.BIN",
    "ventoy",
  }
)

SUBCOMMANDS: frozenset[str] = frozenset(
  {
    "update",
    "add",
    "list",
    "catalog",
    "upgrade",
    "bootloader",
    "self-update",
  }
)

_HTTP_TEXT_CACHE: dict[str, str] = {}

VENTOY_GITHUB_LATEST_URL = (
  "https://api.github.com/repos/ventoy/Ventoy/releases/latest"
)
SYSTEM_CRITICAL_MOUNTPOINTS: frozenset[str] = frozenset(
  {"/", "/boot", "/boot/efi", "/home", "/System/Volumes/Data"}
)

FEDORA_RELEASES_URL = "https://fedoraproject.org/releases.json"
PROXMOX_SUMS_URL = "https://enterprise.proxmox.com/iso/SHA256SUMS"
PROXMOX_ISO_BASE = "https://enterprise.proxmox.com/iso"
DEBIAN_CD_SUMS_URL = (
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
)
DEBIAN_CD_BASE = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
DEBIAN_DVD_SUMS_URL = (
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/SHA256SUMS"
)
DEBIAN_DVD_BASE = "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd"
UBUNTU_META_LTS_URL = "https://changelogs.ubuntu.com/meta-release-lts"
UBUNTU_RELEASES_BASE = "https://releases.ubuntu.com"
CACHYOS_DOWNLOAD_URL = "https://cachyos.org/download/"
CACHYOS_CDN_BASE = "https://cdn77.cachyos.org/ISO"
TRUENAS_DOWNLOAD_PAGE_URL = "https://www.truenas.com/download-tn-scale/"
BAZZITE_DOWNLOAD_BASE = "https://download.bazzite.gg"
STEAMDECK_RECOVERY_URL = "https://steamdeck-images.steamos.cloud/recovery/"


@dataclasses.dataclass(frozen=True, slots=True)
class VentoyBootloaderRelease:
  """Upstream official Ventoy bootloader release metadata from GitHub.

  Attributes:
    version: Clean semantic version string (e.g. '1.1.18').
    linux_tarball_name: Linux installer archive filename.
    linux_tarball_url: HTTPS download URL for linux.tar.gz.
    linux_tarball_sha256: Expected SHA256 digest of linux.tar.gz.
    linux_tarball_size: Size of linux.tar.gz in bytes.
    livecd_iso_name: Bootable Ventoy LiveCD ISO filename.
    livecd_iso_url: HTTPS download URL for livecd.iso.
    livecd_iso_sha256: Expected SHA256 digest of livecd.iso.
    livecd_iso_size: Size of livecd.iso in bytes.
  """

  version: str
  linux_tarball_name: str
  linux_tarball_url: str
  linux_tarball_sha256: str = ""
  linux_tarball_size: int = 0
  livecd_iso_name: str = ""
  livecd_iso_url: str = ""
  livecd_iso_sha256: str = ""
  livecd_iso_size: int = 0


@dataclasses.dataclass(frozen=True, slots=True)
class VentoyDriveInfo:
  """Block-device and bootloader state inspected for a mounted Ventoy drive.

  Attributes:
    disk_device: Whole-disk block device path (e.g. '/dev/sdb' or '/dev/disk4').
    data_partition: Mounted data partition path (e.g. '/dev/sdb1').
    efi_partition: Sibling VTOYEFI partition path (e.g. '/dev/sdb2').
    model: Hardware vendor/model description if available.
    disk_size_bytes: Whole-disk capacity in bytes.
    is_removable: True if OS reports removable/USB external media.
    is_system_disk: True if any partition on disk hosts critical OS mounts.
    installed_version: Ventoy version parsed from VTOYEFI grub.cfg (or '').
  """

  disk_device: str = ""
  data_partition: str = ""
  efi_partition: str = ""
  model: str = ""
  disk_size_bytes: int = 0
  is_removable: bool = False
  is_system_disk: bool = False
  installed_version: str = ""


class ImageStatus(enum.Enum):
  """Evaluation states for an image on a Ventoy drive."""

  UPDATE_AVAILABLE = "Update Available"
  UP_TO_DATE = "Up-to-date"
  MANUAL_ONLY = "Manual Only"
  UNMANAGED = "Skipped"
  ERROR = "Lookup Error"


@dataclasses.dataclass(frozen=True, slots=True)
class LocalImage:
  """Metadata for an ISO/IMG file discovered on a Ventoy drive.

  Attributes:
    path: Full path to the local image file.
    rel_path: Path relative to the Ventoy root directory.
    size_bytes: Current file size in bytes.
    mtime_ns: Nanosecond modification timestamp.
    distro_id: Matched provider catalog identifier, or None if unmanaged.
    local_version: Parsed version string from filename (empty if rolling ISO).
    variant_arg: Optional sub-variant token (e.g. exact Bazzite filename).
    manual_reason: Reason string when automatic downloads are unsupported.
  """

  path: Path
  rel_path: str
  size_bytes: int
  mtime_ns: int
  distro_id: str | None
  local_version: str = ""
  variant_arg: str = ""
  manual_reason: str = ""


@dataclasses.dataclass(frozen=True, slots=True)
class RemoteRelease:
  """Upstream release artifact resolved from an official distribution source.

  Attributes:
    distro_id: Provider catalog identifier (e.g., 'truenas-scale').
    display_name: Human-readable distribution title.
    version: Upstream version string (or short hash label for rolling builds).
    filename: Final target filename to store on the Ventoy drive.
    download_url: Direct HTTPS URL for downloading the image (or archive).
    sha256: Expected lowercase 64-hex SHA256 digest of the downloaded payload.
    size_bytes: Expected download size in bytes (0 if unknown before GET).
    compression: Archive format ('none' or 'bz2').
  """

  distro_id: str
  display_name: str
  version: str
  filename: str
  download_url: str
  sha256: str = ""
  size_bytes: int = 0
  compression: str = "none"


@dataclasses.dataclass(slots=True)
class ImageEvaluation:
  """Comparison result pairing a LocalImage with its upstream RemoteRelease.

  Attributes:
    local: Discovered LocalImage on the Ventoy stick.
    remote: Resolved upstream RemoteRelease, if available.
    status: Computed ImageStatus category.
    local_label: Version or short hash displayed for the local file.
    remote_label: Version or short hash displayed for upstream.
    detail: Supplemental status note or error message.
  """

  local: LocalImage
  remote: RemoteRelease | None
  status: ImageStatus
  local_label: str
  remote_label: str
  detail: str = ""


@dataclasses.dataclass(frozen=True, slots=True)
class DistroSpec:
  """Catalog entry describing a supported distribution provider.

  Attributes:
    distro_id: Canonical CLI key (e.g. 'ubuntu-server').
    display_name: Human-readable name.
    tier: 'Core' (required distros) or 'Optional' (bonus supported images).
    description: Concise summary shown in 'ventoy add' and 'ventoy list'.
    resolver: Callable returning the latest RemoteRelease for this distro.
    default_variant: Default variant argument passed to resolver when adding.
  """

  distro_id: str
  display_name: str
  tier: str
  description: str
  resolver: Callable[[str], RemoteRelease]
  default_variant: str = ""


# ==============================================================================
# 1. Formatting, Versioning & Manifest Helpers
# ==============================================================================


def format_bytes(num_bytes: int | float) -> str:
  """Format a byte count into human-readable MiB/GiB units.

  Args:
    num_bytes: Byte count to format.

  Returns:
    Formatted size string (e.g. '3.64 GiB' or '—' when unknown).
  """
  if num_bytes <= 0:
    return "—"
  units = ("B", "KiB", "MiB", "GiB", "TiB")
  value = float(num_bytes)
  idx = 0
  while value >= 1024.0 and idx < len(units) - 1:
    value /= 1024.0
    idx += 1
  if idx >= 3:
    return f"{value:.2f} {units[idx]}"
  if idx == 2:
    return f"{value:.1f} {units[idx]}"
  return f"{int(value)} {units[idx]}"


def parse_version_tuple(version_str: str) -> tuple[int, ...]:
  """Convert a dotted or hyphenated version string into a numeric tuple.

  Args:
    version_str: Version string such as '25.10.7', '44-1.7', or '9.2-1'.

  Returns:
    Tuple of integers suitable for semantic comparison.
  """
  parts = re.findall(r"\d+", version_str)
  return tuple(int(p) for p in parts)


def is_remote_newer(local_ver: str, remote_ver: str) -> bool:
  """Determine whether an upstream version string is newer than a local one.

  Args:
    local_ver: Version extracted from the existing Ventoy filename.
    remote_ver: Version reported by the upstream provider.

  Returns:
    True if remote_ver is strictly newer than local_ver.
  """
  if not local_ver or not remote_ver or local_ver == remote_ver:
    return False
  local_tuple = parse_version_tuple(local_ver)
  remote_tuple = parse_version_tuple(remote_ver)
  if local_tuple != remote_tuple:
    return remote_tuple > local_tuple
  return remote_ver > local_ver


def load_manifest(ventoy_root: Path) -> dict[str, dict[str, Any]]:
  """Load the cached '.ventoy-manifest.json' dictionary from a Ventoy drive.

  Args:
    ventoy_root: Root directory of the Ventoy image folder.

  Returns:
    Mapping of relative filename to recorded metadata dict.
  """
  manifest_path = ventoy_root / MANIFEST_FILENAME
  if not manifest_path.is_file():
    return {}
  try:
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = raw.get("images", {}) if isinstance(raw, dict) else {}
    return entries if isinstance(entries, dict) else {}
  except (OSError, json.JSONDecodeError):
    return {}


def save_manifest(
  ventoy_root: Path, entries: dict[str, dict[str, Any]]
) -> None:
  """Persist '.ventoy-manifest.json' to the Ventoy directory.

  Args:
    ventoy_root: Root directory of the Ventoy image folder.
    entries: Mapping of relative filename to metadata dictionary.
  """
  manifest_path = ventoy_root / MANIFEST_FILENAME
  payload = {
    "updated_at": datetime.now(UTC).isoformat(),
    "images": entries,
  }
  try:
    manifest_path.write_text(
      json.dumps(payload, indent=2, sort_keys=True) + "\n",
      encoding="utf-8",
    )
  except OSError:
    # Non-fatal if drive metadata file cannot be written.
    pass


def compute_file_sha256(filepath: Path, console: Console | None = None) -> str:
  """Compute lowercase SHA256 digest of a local file with optional progress bar.

  Args:
    filepath: Local file to hash.
    console: Optional Rich Console to display read progress on large ISOs.

  Returns:
    64-character lowercase hexadecimal SHA256 digest.
  """
  digest = hashlib.sha256()
  total_size = filepath.stat().st_size

  if (
    console is None
    or total_size < 64 * 1024 * 1024
    or getattr(console, "_live", None) is not None
  ):
    with open(filepath, "rb") as fh:
      while chunk := fh.read(CHUNK_SIZE):
        digest.update(chunk)
    return digest.hexdigest()

  with Progress(
    SpinnerColumn(),
    TextColumn("[cyan]Hashing {task.fields[name]}[/cyan]"),
    BarColumn(bar_width=28),
    DownloadColumn(),
    TransferSpeedColumn(),
    console=console,
    transient=True,
  ) as progress:
    task_id = progress.add_task("hash", total=total_size, name=filepath.name)
    with open(filepath, "rb") as fh:
      while chunk := fh.read(CHUNK_SIZE):
        digest.update(chunk)
        progress.update(task_id, advance=len(chunk))
  return digest.hexdigest()


def get_cached_or_compute_sha256(
  image: LocalImage,
  manifest: dict[str, dict[str, Any]],
  ventoy_root: Path,
  console: Console | None = None,
) -> str:
  """Return cached SHA256 if size and mtime match, otherwise hash and cache it.

  Args:
    image: LocalImage entry on the Ventoy drive.
    manifest: Loaded manifest dictionary (mutated in-place when updated).
    ventoy_root: Root directory where '.ventoy-manifest.json' resides.
    console: Optional Rich Console for hashing progress display.

  Returns:
    64-character lowercase SHA256 hex string.
  """
  recorded = manifest.get(image.rel_path)
  if isinstance(recorded, dict):
    cached_sha = str(recorded.get("sha256") or "").strip().lower()
    if (
      len(cached_sha) == 64
      and recorded.get("size_bytes") == image.size_bytes
      and recorded.get("mtime_ns") == image.mtime_ns
    ):
      return cached_sha

  computed = compute_file_sha256(image.path, console=console)
  manifest[image.rel_path] = {
    "sha256": computed,
    "size_bytes": image.size_bytes,
    "mtime_ns": image.mtime_ns,
    "version": image.local_version,
    "updated_at": datetime.now(UTC).isoformat(),
  }
  save_manifest(ventoy_root, manifest)
  return computed


# ==============================================================================
# 2. HTTP Metadata & Checksum Parsing Helpers
# ==============================================================================


def http_get_text(
  url: str, *, timeout: float = 12.0, use_cache: bool = True
) -> str:
  """Fetch UTF-8 text from an HTTPS endpoint with in-memory run caching.

  Args:
    url: Target HTTPS URL.
    timeout: Socket timeout in seconds.
    use_cache: Whether to reuse cached responses within the current process.

  Returns:
    Decoded response body string.

  Raises:
    RuntimeError: On HTTP or network transport errors.
  """
  if use_cache and url in _HTTP_TEXT_CACHE:
    return _HTTP_TEXT_CACHE[url]

  req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
  try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
      text = resp.read().decode("utf-8", errors="replace")
  except (urllib.error.URLError, TimeoutError, OSError) as exc:
    raise RuntimeError(f"Failed to query {url}: {exc}") from exc

  if use_cache:
    _HTTP_TEXT_CACHE[url] = text
  return text


def http_get_json(url: str, *, timeout: float = 12.0) -> Any:
  """Fetch and decode JSON from an HTTPS endpoint.

  Args:
    url: Target HTTPS JSON URL.
    timeout: Socket timeout in seconds.

  Returns:
    Parsed JSON value.

  Raises:
    RuntimeError: On HTTP transport or JSON decode errors.
  """
  raw = http_get_text(url, timeout=timeout)
  try:
    return json.loads(raw)
  except json.JSONDecodeError as exc:
    raise RuntimeError(f"Invalid JSON from {url}: {exc}") from exc


def http_head_content_length(url: str, *, timeout: float = 8.0) -> int:
  """Query expected file size in bytes via HTTP HEAD (returning 0 on failure).

  Args:
    url: Direct download URL.
    timeout: Request timeout in seconds.

  Returns:
    Non-negative integer byte count, or 0 if unavailable.
  """
  req = urllib.request.Request(
    url, method="HEAD", headers={"User-Agent": USER_AGENT}
  )
  try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
      raw_len = resp.headers.get("Content-Length")
      return max(0, int(raw_len)) if raw_len else 0
  except (urllib.error.URLError, TimeoutError, ValueError, OSError):
    return 0


def parse_sha256sums_text(text: str) -> dict[str, str]:
  """Parse standard GNU coreutils 'SHA256SUMS' lines into {filename: sha256}.

  Args:
    text: Raw text content of a SHA256SUMS or *-CHECKSUM file.

  Returns:
    Dictionary mapping basename to lowercase 64-hex SHA256 string.
  """
  mapping: dict[str, str] = {}
  bsd_re = re.compile(r"^SHA256\s*\(([^)]+)\)\s*=\s*([0-9a-fA-F]{64})\s*$")
  gnu_re = re.compile(r"^([0-9a-fA-F]{64})\s+\*?([^\s]+)\s*$")

  for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
      continue
    gnu_match = gnu_re.match(line)
    if gnu_match:
      sha, fname = gnu_match.group(1).lower(), Path(gnu_match.group(2)).name
      mapping[fname] = sha
      continue
    bsd_match = bsd_re.match(line)
    if bsd_match:
      fname, sha = Path(bsd_match.group(1)).name, bsd_match.group(2).lower()
      mapping[fname] = sha

  if not mapping:
    bare_match = re.match(r"^([0-9a-fA-F]{64})\b", text.strip())
    if bare_match:
      mapping["*"] = bare_match.group(1).lower()
  return mapping


# ==============================================================================
# 3. Upstream Distribution Providers
# ==============================================================================


def _discover_latest_ubuntu_lts_series() -> str:
  """Determine the newest supported Ubuntu LTS 'YY.MM' series (e.g. '26.04').

  Returns:
    Two-segment Ubuntu LTS series string such as '26.04'.

  Raises:
    RuntimeError: If no supported LTS release could be parsed.
  """
  meta = http_get_text(UBUNTU_META_LTS_URL)
  candidates: list[tuple[tuple[int, int], str]] = []
  for block in meta.split("\n\n"):
    ver_match = re.search(
      r"^Version:\s*(\d{2}\.\d{2})(?:\.\d+)*\s*LTS", block, re.MULTILINE
    )
    if not ver_match:
      continue
    series = ver_match.group(1)
    major, minor = (int(x) for x in series.split("."))
    candidates.append(((major, minor), series))

  if not candidates:
    raise RuntimeError(
      "Could not parse any LTS release from Ubuntu meta-release"
    )
  candidates.sort()
  return candidates[-1][1]


def resolve_ubuntu(flavor: str = "desktop") -> RemoteRelease:
  """Resolve latest Ubuntu LTS Desktop or Server ISO and SHA256.

  Args:
    flavor: 'desktop' or 'live-server'.

  Returns:
    RemoteRelease for the newest point release in the latest Ubuntu LTS track.

  Raises:
    RuntimeError: If upstream Ubuntu SHA256SUMS has no matching ISO.
  """
  series = _discover_latest_ubuntu_lts_series()
  sums_url = f"{UBUNTU_RELEASES_BASE}/{series}/SHA256SUMS"
  sums = parse_sha256sums_text(http_get_text(sums_url))

  suffix = (
    "desktop-amd64.iso" if flavor == "desktop" else "live-server-amd64.iso"
  )
  pattern = re.compile(rf"^ubuntu-(\d+\.\d+(?:\.\d+)*)-{re.escape(suffix)}$")

  matches: list[tuple[tuple[int, ...], str, str, str]] = []
  for fname, sha in sums.items():
    m = pattern.match(fname)
    if m:
      ver = m.group(1)
      matches.append((parse_version_tuple(ver), ver, fname, sha))

  if not matches:
    raise RuntimeError(f"No Ubuntu {flavor} ISO found in {sums_url}")

  matches.sort()
  _, ver, filename, sha256 = matches[-1]
  dl_url = f"{UBUNTU_RELEASES_BASE}/{series}/{filename}"
  distro_id = "ubuntu-desktop" if flavor == "desktop" else "ubuntu-server"
  title = (
    "Ubuntu Desktop (LTS)" if flavor == "desktop" else "Ubuntu Server (LTS)"
  )
  return RemoteRelease(
    distro_id=distro_id,
    display_name=title,
    version=ver,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_debian(media_type: str = "netinst") -> RemoteRelease:
  """Resolve latest Debian stable amd64 netinst or DVD-1 ISO and SHA256.

  Args:
    media_type: 'netinst' (default server installer) or 'DVD-1'.

  Returns:
    RemoteRelease for Debian stable amd64.

  Raises:
    RuntimeError: If Debian current SHA256SUMS lacks the requested ISO.
  """
  is_dvd = media_type.upper().startswith("DVD")
  sums_url = DEBIAN_DVD_SUMS_URL if is_dvd else DEBIAN_CD_SUMS_URL
  base_url = DEBIAN_DVD_BASE if is_dvd else DEBIAN_CD_BASE
  sums = parse_sha256sums_text(http_get_text(sums_url))

  tag = "DVD-1" if is_dvd else "netinst"
  pattern = re.compile(rf"^debian-(\d+\.\d+\.\d+)-amd64-{re.escape(tag)}\.iso$")

  matches: list[tuple[tuple[int, ...], str, str, str]] = []
  for fname, sha in sums.items():
    m = pattern.match(fname)
    if m:
      ver = m.group(1)
      matches.append((parse_version_tuple(ver), ver, fname, sha))

  if not matches:
    raise RuntimeError(f"No Debian amd64 {tag} ISO found in {sums_url}")

  matches.sort()
  _, ver, filename, sha256 = matches[-1]
  dl_url = f"{base_url}/{filename}"
  return RemoteRelease(
    distro_id="debian-dvd" if is_dvd else "debian-server",
    display_name=f"Debian Server ({tag})",
    version=ver,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_cachyos(edition: str = "desktop") -> RemoteRelease:
  """Resolve latest CachyOS Desktop or Handheld ISO and SHA256 from CDN.

  Args:
    edition: 'desktop' (default) or 'handheld'.

  Returns:
    RemoteRelease for CachyOS Linux.

  Raises:
    RuntimeError: If CachyOS download page or checksum cannot be parsed.
  """
  ed = edition.lower() if edition else "desktop"
  raw_html = urllib.parse.unquote(
    html.unescape(http_get_text(CACHYOS_DOWNLOAD_URL))
  )
  pattern = re.compile(rf"cachyos-{re.escape(ed)}-linux-(\d{{6}})\.iso")
  builds = sorted(set(pattern.findall(raw_html)))
  if not builds:
    raise RuntimeError(
      f"Could not find CachyOS '{ed}' ISO version on {CACHYOS_DOWNLOAD_URL}"
    )

  latest_build = builds[-1]
  filename = f"cachyos-{ed}-linux-{latest_build}.iso"
  dl_url = f"{CACHYOS_CDN_BASE}/{ed}/{latest_build}/{filename}"
  sha_map = parse_sha256sums_text(http_get_text(f"{dl_url}.sha256"))
  sha256 = sha_map.get(filename) or sha_map.get("*", "")
  if not sha256:
    raise RuntimeError(f"Missing SHA256 digest for {filename}")

  distro_id = "cachyos" if ed == "desktop" else "cachyos-handheld"
  label = "CachyOS Desktop" if ed == "desktop" else "CachyOS Handheld"
  return RemoteRelease(
    distro_id=distro_id,
    display_name=label,
    version=latest_build,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_fedora(spec: str = "server-dvd") -> RemoteRelease:
  """Resolve latest stable Fedora Server or Desktop x86_64 ISO via releases.json.

  Args:
    spec: One of 'server-dvd', 'server-netinst', 'kde', or 'workstation'.

  Returns:
    RemoteRelease populated from official Fedora metadata.

  Raises:
    RuntimeError: If no matching stable x86_64 Fedora ISO is found.
  """
  items = json.loads(http_get_text(FEDORA_RELEASES_URL))
  if not isinstance(items, list):
    raise RuntimeError(
      "Unexpected JSON payload from fedoraproject.org/releases.json"
    )

  spec_key = (spec or "server-dvd").lower()
  variant_map = {
    "server-dvd": ("fedora-server", "Fedora Server (DVD)", "Server", "-dvd-"),
    "server-netinst": (
      "fedora-server-netinst",
      "Fedora Server (Netinst)",
      "Server",
      "-netinst-",
    ),
    "kde": (
      "fedora-kde",
      "Fedora KDE Desktop",
      "KDE",
      "Fedora-KDE-Desktop-Live",
    ),
    "workstation": (
      "fedora-workstation",
      "Fedora Workstation",
      "Workstation",
      "Fedora-Workstation-Live",
    ),
  }
  distro_id, title, target_variant, name_substr = variant_map.get(
    spec_key, variant_map["server-dvd"]
  )

  candidates: list[tuple[tuple[int, ...], str, str, str, int]] = []
  for entry in items:
    if not isinstance(entry, dict):
      continue
    ver_raw = str(entry.get("version") or "").strip()
    link = str(entry.get("link") or "").strip()
    if (
      entry.get("arch") != "x86_64"
      or entry.get("variant") != target_variant
      or not ver_raw.isdigit()
      or not link.endswith(".iso")
    ):
      continue
    fname = Path(urllib.parse.urlparse(link).path).name
    if name_substr not in fname:
      continue
    rel_match = re.search(rf"\b{re.escape(ver_raw)}-(\d+(?:\.\d+)*)", fname)
    full_ver = f"{ver_raw}-{rel_match.group(1)}" if rel_match else ver_raw
    sha = str(entry.get("sha256") or "").strip().lower()
    raw_size = entry.get("size")
    size_bytes = int(raw_size) if str(raw_size or "").isdigit() else 0
    candidates.append(
      (parse_version_tuple(full_ver), full_ver, link, sha, size_bytes)
    )

  if not candidates:
    raise RuntimeError(
      f"No stable x86_64 Fedora '{spec_key}' ISO in releases.json"
    )

  candidates.sort()
  _, full_ver, dl_url, sha256, size_bytes = candidates[-1]
  filename = Path(urllib.parse.urlparse(dl_url).path).name
  return RemoteRelease(
    distro_id=distro_id,
    display_name=title,
    version=full_ver,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=size_bytes or http_head_content_length(dl_url),
  )


def resolve_proxmox(product: str = "ve") -> RemoteRelease:
  """Resolve latest Proxmox VE (or Backup Server) x86_64 ISO and SHA256.

  Args:
    product: 've' (default) or 'pbs' (Proxmox Backup Server).

  Returns:
    RemoteRelease for Proxmox.

  Raises:
    RuntimeError: If Proxmox SHA256SUMS contains no matching x86_64 ISO.
  """
  is_pbs = (product or "ve").lower() == "pbs"
  prefix = "proxmox-backup-server" if is_pbs else "proxmox-ve"
  sums = parse_sha256sums_text(http_get_text(PROXMOX_SUMS_URL))
  pattern = re.compile(rf"^{re.escape(prefix)}_(\d+\.\d+-\d+)\.iso$")

  matches: list[tuple[tuple[int, ...], str, str, str]] = []
  for fname, sha in sums.items():
    m = pattern.match(fname)
    if m:
      ver = m.group(1)
      matches.append((parse_version_tuple(ver), ver, fname, sha))

  if not matches:
    raise RuntimeError(f"No {prefix} ISO found in {PROXMOX_SUMS_URL}")

  matches.sort()
  _, ver, filename, sha256 = matches[-1]
  dl_url = f"{PROXMOX_ISO_BASE}/{filename}"
  return RemoteRelease(
    distro_id="proxmox-pbs" if is_pbs else "proxmox",
    display_name="Proxmox Backup Server" if is_pbs else "Proxmox VE",
    version=ver,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_truenas(_variant: str = "") -> RemoteRelease:
  """Resolve latest stable TrueNAS SCALE Community Edition ISO and SHA256.

  Args:
    _variant: Unused variant placeholder for uniform provider interface.

  Returns:
    RemoteRelease for TrueNAS SCALE.

  Raises:
    RuntimeError: If TrueNAS download URL or SHA256 cannot be resolved.
  """
  page = http_get_text(TRUENAS_DOWNLOAD_PAGE_URL)
  url_pattern = re.compile(
    r"(https://download\.sys\.truenas\.net/TrueNAS-SCALE-[A-Za-z0-9_-]+/"
    r"(\d+\.\d+(?:\.\d+)*)/TrueNAS-SCALE-\2\.iso)\b"
  )
  found: list[tuple[tuple[int, ...], str, str]] = []
  for match in url_pattern.finditer(page):
    dl_url, ver = match.group(1), match.group(2)
    if "BETA" in dl_url.upper() or "-RC" in dl_url.upper():
      continue
    found.append((parse_version_tuple(ver), ver, dl_url))

  if not found:
    raise RuntimeError(
      f"Could not locate TrueNAS SCALE ISO URL on {TRUENAS_DOWNLOAD_PAGE_URL}"
    )

  found.sort()
  _, ver, dl_url = found[-1]
  filename = f"TrueNAS-SCALE-{ver}.iso"
  sha_map = parse_sha256sums_text(http_get_text(f"{dl_url}.sha256"))
  sha256 = sha_map.get(filename) or sha_map.get("*", "")
  if not sha256:
    raise RuntimeError(f"Missing SHA256 digest for {filename}")

  return RemoteRelease(
    distro_id="truenas-scale",
    display_name="TrueNAS SCALE",
    version=ver,
    filename=filename,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_bazzite(
  iso_filename: str = "bazzite-stable-live-amd64.iso",
) -> RemoteRelease:
  """Resolve rolling Bazzite Live ISO and SHA256 from download.bazzite.gg.

  Args:
    iso_filename: Exact Bazzite ISO filename (e.g. 'bazzite-deck-stable-live-amd64.iso').

  Returns:
    RemoteRelease with current rolling SHA256 digest.

  Raises:
    RuntimeError: If Bazzite '-CHECKSUM' endpoint lacks a valid SHA256.
  """
  fname = iso_filename or "bazzite-stable-live-amd64.iso"
  dl_url = f"{BAZZITE_DOWNLOAD_BASE}/{fname}"
  checksum_text = http_get_text(f"{dl_url}-CHECKSUM")
  sha_map = parse_sha256sums_text(checksum_text)
  sha256 = sha_map.get(fname) or sha_map.get("*", "")
  if not sha256:
    raise RuntimeError(f"Could not parse SHA256 from {dl_url}-CHECKSUM")

  is_deck = "deck" in fname.lower()
  distro_id = "bazzite-deck" if is_deck else "bazzite"
  title = "Bazzite Deck Live" if is_deck else "Bazzite Desktop Live"
  return RemoteRelease(
    distro_id=distro_id,
    display_name=title,
    version=f"sha256:{sha256[:12]}",
    filename=fname,
    download_url=dl_url,
    sha256=sha256,
    size_bytes=http_head_content_length(dl_url),
  )


def resolve_steamdeck(_variant: str = "") -> RemoteRelease:
  """Resolve latest SteamOS / Steam Deck OOBE repair image (.img.bz2 -> .img).

  Args:
    _variant: Unused variant placeholder.

  Returns:
    RemoteRelease configured with bz2 stream decompression.

  Raises:
    RuntimeError: If SteamOS recovery index has no oobe-repair image.
  """
  listing = http_get_text(STEAMDECK_RECOVERY_URL)
  pattern = re.compile(
    r'href="(steamdeck-oobe-repair-(\d{8}\.\d+-\d+(?:\.\d+)*)\.img\.bz2)"'
  )
  candidates: list[tuple[tuple[int, ...], str, str]] = []
  for archive_name, ver in set(pattern.findall(listing)):
    candidates.append((parse_version_tuple(ver), ver, archive_name))

  if not candidates:
    raise RuntimeError(
      f"No steamdeck-oobe-repair image found at {STEAMDECK_RECOVERY_URL}"
    )

  candidates.sort()
  _, ver, archive_name = candidates[-1]
  target_filename = archive_name.removesuffix(".bz2")
  dl_url = f"{STEAMDECK_RECOVERY_URL}{archive_name}"
  return RemoteRelease(
    distro_id="steamdeck-repair",
    display_name="SteamOS Deck Repair",
    version=ver,
    filename=target_filename,
    download_url=dl_url,
    sha256="",
    size_bytes=http_head_content_length(dl_url),
    compression="bz2",
  )


def resolve_ventoy_livecd(variant: str = "") -> RemoteRelease:
  """Resolve the latest official bootable Ventoy LiveCD updater ISO.

  Args:
    variant: Unused variant parameter (kept for resolver signature parity).

  Returns:
    RemoteRelease metadata for 'ventoy-X.Y.Z-livecd.iso'.

  Raises:
    RuntimeError: If upstream GitHub release lacks a LiveCD ISO asset.
  """
  _ = variant
  rel = resolve_ventoy_bootloader_release()
  if not rel.livecd_iso_name or not rel.livecd_iso_url:
    raise RuntimeError(
      f"Ventoy v{rel.version} GitHub release has no LiveCD ISO asset"
    )
  return RemoteRelease(
    distro_id="ventoy-livecd",
    display_name="Ventoy LiveCD Updater",
    version=rel.version,
    filename=rel.livecd_iso_name,
    download_url=rel.livecd_iso_url,
    sha256=rel.livecd_iso_sha256,
    size_bytes=rel.livecd_iso_size,
  )


DISTRO_CATALOG: tuple[DistroSpec, ...] = (
  DistroSpec(
    distro_id="ubuntu-desktop",
    display_name="Ubuntu Desktop (LTS)",
    tier="Core",
    description="Latest Ubuntu LTS Desktop amd64 Live ISO",
    resolver=resolve_ubuntu,
    default_variant="desktop",
  ),
  DistroSpec(
    distro_id="ubuntu-server",
    display_name="Ubuntu Server (LTS)",
    tier="Core",
    description="Latest Ubuntu LTS Live Server amd64 ISO",
    resolver=resolve_ubuntu,
    default_variant="live-server",
  ),
  DistroSpec(
    distro_id="debian-server",
    display_name="Debian Server (Netinst)",
    tier="Core",
    description="Latest Debian stable amd64 netinst server installer ISO",
    resolver=resolve_debian,
    default_variant="netinst",
  ),
  DistroSpec(
    distro_id="debian-dvd",
    display_name="Debian Full DVD-1",
    tier="Core",
    description="Latest Debian stable amd64 offline DVD-1 ISO",
    resolver=resolve_debian,
    default_variant="DVD-1",
  ),
  DistroSpec(
    distro_id="cachyos",
    display_name="CachyOS Desktop",
    tier="Core",
    description="Latest CachyOS Desktop x86_64 GUI installer ISO",
    resolver=resolve_cachyos,
    default_variant="desktop",
  ),
  DistroSpec(
    distro_id="fedora-server",
    display_name="Fedora Server (DVD)",
    tier="Core",
    description="Latest Fedora Server x86_64 full DVD installer ISO",
    resolver=resolve_fedora,
    default_variant="server-dvd",
  ),
  DistroSpec(
    distro_id="fedora-kde",
    display_name="Fedora KDE Desktop",
    tier="Core",
    description="Latest Fedora KDE Plasma Desktop Live x86_64 ISO",
    resolver=resolve_fedora,
    default_variant="kde",
  ),
  DistroSpec(
    distro_id="fedora-workstation",
    display_name="Fedora Workstation",
    tier="Core",
    description="Latest Fedora Workstation (GNOME) Live x86_64 ISO",
    resolver=resolve_fedora,
    default_variant="workstation",
  ),
  DistroSpec(
    distro_id="proxmox",
    display_name="Proxmox VE",
    tier="Core",
    description="Latest Proxmox Virtual Environment bare-metal installer ISO",
    resolver=resolve_proxmox,
    default_variant="ve",
  ),
  DistroSpec(
    distro_id="truenas-scale",
    display_name="TrueNAS SCALE",
    tier="Core",
    description="Latest TrueNAS SCALE Community Edition x86_64 ISO",
    resolver=resolve_truenas,
    default_variant="",
  ),
  DistroSpec(
    distro_id="bazzite",
    display_name="Bazzite Desktop Live",
    tier="Optional",
    description="Rolling Bazzite Desktop Live amd64 ISO (SHA256-tracked)",
    resolver=resolve_bazzite,
    default_variant="bazzite-stable-live-amd64.iso",
  ),
  DistroSpec(
    distro_id="bazzite-deck",
    display_name="Bazzite Deck Live",
    tier="Optional",
    description="Rolling Bazzite Handheld/Deck Live amd64 ISO (SHA256-tracked)",
    resolver=resolve_bazzite,
    default_variant="bazzite-deck-stable-live-amd64.iso",
  ),
  DistroSpec(
    distro_id="cachyos-handheld",
    display_name="CachyOS Handheld",
    tier="Optional",
    description="Latest CachyOS Handheld Edition x86_64 ISO",
    resolver=resolve_cachyos,
    default_variant="handheld",
  ),
  DistroSpec(
    distro_id="fedora-server-netinst",
    display_name="Fedora Server (Netinst)",
    tier="Optional",
    description="Latest Fedora Server x86_64 minimal netinst ISO",
    resolver=resolve_fedora,
    default_variant="server-netinst",
  ),
  DistroSpec(
    distro_id="proxmox-pbs",
    display_name="Proxmox Backup Server",
    tier="Optional",
    description="Latest Proxmox Backup Server bare-metal installer ISO",
    resolver=resolve_proxmox,
    default_variant="pbs",
  ),
  DistroSpec(
    distro_id="steamdeck-repair",
    display_name="SteamOS Deck Repair",
    tier="Optional",
    description="Latest Valve Steam Deck OOBE recovery/repair raw .img",
    resolver=resolve_steamdeck,
    default_variant="",
  ),
  DistroSpec(
    distro_id="ventoy-livecd",
    display_name="Ventoy LiveCD Updater",
    tier="Optional",
    description="Official bootable Ventoy LiveCD ISO for updating any Ventoy USB",
    resolver=resolve_ventoy_livecd,
    default_variant="",
  ),
)

CATALOG_BY_ID: dict[str, DistroSpec] = {
  spec.distro_id: spec for spec in DISTRO_CATALOG
}


# ==============================================================================
# 4. Ventoy Mount Auto-Detection & Image Filename Classification
# ==============================================================================


def detect_ventoy_mount() -> Path | None:
  """Auto-detect a mounted Ventoy USB drive on macOS or Linux.

  Returns:
    Resolved Path to the mounted Ventoy volume, or None if not found.
  """
  username = os.environ.get("USER") or getpass.getuser()
  search_roots = (
    Path("/Volumes"),
    Path(f"/run/media/{username}"),
    Path(f"/media/{username}"),
    Path("/media"),
    Path("/mnt"),
  )

  for parent in search_roots:
    try:
      if not parent.is_dir():
        continue
      for child in sorted(parent.iterdir()):
        if child.is_dir() and child.name.lower() == "ventoy":
          return child.resolve()
    except OSError:
      continue
  return None


def classify_image_filename(
  filename: str,
) -> tuple[str | None, str, str, str]:
  """Match a filename on a Ventoy drive to a supported provider specification.

  Args:
    filename: Basename of the '.iso' or '.img' file.

  Returns:
    Tuple of (distro_id, parsed_local_version, variant_arg, manual_reason).
  """
  rules: tuple[tuple[str, str, str], ...] = (
    (
      r"^ubuntu-(\d+\.\d+(?:\.\d+)*)-desktop-amd64\.iso$",
      "ubuntu-desktop",
      "desktop",
    ),
    (
      r"^ubuntu-(\d+\.\d+(?:\.\d+)*)-live-server-amd64\.iso$",
      "ubuntu-server",
      "live-server",
    ),
    (
      r"^debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso$",
      "debian-server",
      "netinst",
    ),
    (r"^debian-(\d+\.\d+\.\d+)-amd64-DVD-1\.iso$", "debian-dvd", "DVD-1"),
    (r"^cachyos-desktop-linux-(\d{6})\.iso$", "cachyos", "desktop"),
    (r"^cachyos-handheld-linux-(\d{6})\.iso$", "cachyos-handheld", "handheld"),
    (
      r"^Fedora-Server-dvd-x86_64-(\d+-[\d.]+)\.iso$",
      "fedora-server",
      "server-dvd",
    ),
    (
      r"^Fedora-Server-netinst-x86_64-(\d+-[\d.]+)\.iso$",
      "fedora-server-netinst",
      "server-netinst",
    ),
    (
      r"^Fedora-KDE(?:-Desktop)?-Live-(?:x86_64-)?(\d+-[\d.]+)(?:\.x86_64)?\.iso$",
      "fedora-kde",
      "kde",
    ),
    (
      r"^Fedora-Workstation-Live-(?:x86_64-)?(\d+-[\d.]+)(?:\.x86_64)?\.iso$",
      "fedora-workstation",
      "workstation",
    ),
    (r"^proxmox-ve_(\d+\.\d+-\d+)\.iso$", "proxmox", "ve"),
    (r"^proxmox-backup-server_(\d+\.\d+-\d+)\.iso$", "proxmox-pbs", "pbs"),
    (r"^TrueNAS-SCALE-(\d+\.\d+(?:\.\d+)*)\.iso$", "truenas-scale", ""),
    (
      r"^steamdeck-oobe-repair-(\d{8}\.\d+-\d+(?:\.\d+)*)\.img$",
      "steamdeck-repair",
      "",
    ),
    (r"^ventoy-(\d+\.\d+(?:\.\d+)*)-livecd\.iso$", "ventoy-livecd", ""),
  )

  for pattern, distro_id, variant in rules:
    m = re.match(pattern, filename, re.IGNORECASE)
    if m:
      return distro_id, m.group(1), variant, ""

  if re.match(r"^bazzite(?:-[a-z0-9-]+)?-amd64\.iso$", filename, re.IGNORECASE):
    did = "bazzite-deck" if "deck" in filename.lower() else "bazzite"
    return did, "", filename, ""

  if re.match(r"^Win(?:10|11)_.*\.iso$", filename, re.IGNORECASE):
    return None, "", "", "Microsoft gated ISO"

  return None, "", "", ""


def scan_ventoy_images(root_dir: Path) -> list[LocalImage]:
  """Recursively scan a Ventoy directory for bootable '.iso' and '.img' files.

  Args:
    root_dir: Root directory of the mounted Ventoy drive or ISO folder.

  Returns:
    Sorted list of LocalImage records (excluding macOS '._*' resource forks).
  """
  discovered: list[LocalImage] = []

  def _walk(current: Path) -> None:
    try:
      entries = sorted(current.iterdir(), key=lambda p: p.name.lower())
    except OSError:
      return

    for entry in entries:
      name = entry.name
      if name.startswith(".") or name in IGNORED_DIR_NAMES:
        continue
      if entry.is_dir() and not entry.is_symlink():
        _walk(entry)
        continue
      if not entry.is_file() or name.startswith("._"):
        continue
      if entry.suffix.lower() not in (".iso", ".img"):
        continue

      try:
        st = entry.stat()
      except OSError:
        continue
      distro_id, local_ver, variant_arg, manual_reason = (
        classify_image_filename(name)
      )
      rel_path = str(entry.relative_to(root_dir))
      discovered.append(
        LocalImage(
          path=entry,
          rel_path=rel_path,
          size_bytes=st.st_size,
          mtime_ns=st.st_mtime_ns,
          distro_id=distro_id,
          local_version=local_ver,
          variant_arg=variant_arg,
          manual_reason=manual_reason,
        )
      )

  _walk(root_dir)
  return discovered


def evaluate_local_image(
  image: LocalImage,
  manifest: dict[str, dict[str, Any]],
  ventoy_root: Path,
  console: Console,
) -> ImageEvaluation:
  """Compare a single LocalImage on the Ventoy drive against upstream metadata.

  Args:
    image: Discovered LocalImage record.
    manifest: Loaded '.ventoy-manifest.json' dictionary.
    ventoy_root: Root directory of the Ventoy folder.
    console: Rich Console for progress feedback.

  Returns:
    ImageEvaluation describing whether an update is available.
  """
  if image.manual_reason:
    return ImageEvaluation(
      local=image,
      remote=None,
      status=ImageStatus.MANUAL_ONLY,
      local_label="—",
      remote_label="—",
      detail=image.manual_reason,
    )

  if not image.distro_id or image.distro_id not in CATALOG_BY_ID:
    return ImageEvaluation(
      local=image,
      remote=None,
      status=ImageStatus.UNMANAGED,
      local_label="—",
      remote_label="—",
      detail="Skipped (unmanaged image)",
    )

  spec = CATALOG_BY_ID[image.distro_id]
  variant = image.variant_arg or spec.default_variant
  try:
    if console is not None and getattr(console, "_live", None) is None:
      with console.status(
        f"[bold cyan]Checking upstream for {image.path.name}...[/bold cyan]"
      ):
        remote = spec.resolver(variant)
    else:
      remote = spec.resolver(variant)
  except RuntimeError as exc:
    return ImageEvaluation(
      local=image,
      remote=None,
      status=ImageStatus.ERROR,
      local_label=image.local_version or "—",
      remote_label="error",
      detail=str(exc),
    )

  # Rolling unversioned ISO (e.g. Bazzite): compare SHA256 against upstream
  if not image.local_version:
    local_sha = get_cached_or_compute_sha256(
      image, manifest, ventoy_root, console=console
    )
    local_short = f"sha256:{local_sha[:12]}"
    is_outdated = (
      bool(remote.sha256) and local_sha.lower() != remote.sha256.lower()
    )
    return ImageEvaluation(
      local=image,
      remote=remote,
      status=ImageStatus.UPDATE_AVAILABLE
      if is_outdated
      else ImageStatus.UP_TO_DATE,
      local_label=local_short,
      remote_label=remote.version,
      detail=remote.filename if is_outdated else "Checksum matches upstream",
    )

  outdated = is_remote_newer(image.local_version, remote.version)
  return ImageEvaluation(
    local=image,
    remote=remote,
    status=ImageStatus.UPDATE_AVAILABLE if outdated else ImageStatus.UP_TO_DATE,
    local_label=image.local_version,
    remote_label=remote.version,
    detail=remote.filename if outdated else "Latest release installed",
  )


# ==============================================================================
# 5. Staging Directory Selection, Verified Download & Atomic Ventoy Swap
# ==============================================================================


def select_staging_dir(
  expected_bytes: int,
  explicit_temp_dir: Path | None = None,
) -> tuple[Path, bool]:
  """Choose a staging directory with sufficient free disk space.

  Uses system '/tmp' when it has at least expected_bytes + 1 GiB free; falls
  back automatically to '~/.cache/ventoy-updater' when '/tmp' is a small Linux
  RAM-backed tmpfs.

  Args:
    expected_bytes: Expected download/decompressed payload size in bytes.
    explicit_temp_dir: Optional user-specified '--temp-dir' override.

  Returns:
    Tuple of (staging_directory_path, used_cache_fallback).

  Raises:
    RuntimeError: If neither '/tmp' nor fallback cache has enough free space.
  """
  needed = (
    expected_bytes if expected_bytes > 0 else FALLBACK_UNKNOWN_ISO_BYTES
  ) + TMP_HEADROOM_BYTES

  if explicit_temp_dir is not None:
    target = explicit_temp_dir.expanduser().resolve()
    target.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(target).free
    if expected_bytes > 0 and free < expected_bytes + (256 * 1024 * 1024):
      raise RuntimeError(
        f"Staging directory '{target}' only has {format_bytes(free)} free "
        f"(need at least {format_bytes(expected_bytes)})."
      )
    return target, False

  sys_tmp = Path(tempfile.gettempdir()).resolve()
  sys_tmp.mkdir(parents=True, exist_ok=True)
  if shutil.disk_usage(sys_tmp).free >= needed:
    return sys_tmp, False

  cache_dir = (Path.home() / ".cache" / "ventoy-updater").resolve()
  cache_dir.mkdir(parents=True, exist_ok=True)
  cache_free = shutil.disk_usage(cache_dir).free
  if expected_bytes > 0 and cache_free < expected_bytes + (256 * 1024 * 1024):
    raise RuntimeError(
      f"Insufficient staging space in both '{sys_tmp}' and '{cache_dir}' "
      f"({format_bytes(cache_free)} free, need {format_bytes(expected_bytes)})."
    )
  return cache_dir, True


def _stream_download_to_part(
  release: RemoteRelease,
  part_path: Path,
  console: Console,
) -> tuple[str, int]:
  """Stream an HTTPS download to part_path while computing its SHA256.

  Args:
    release: Target RemoteRelease metadata.
    part_path: Temporary '.part' destination path.
    console: Rich Console for live progress bar.

  Returns:
    Tuple of (computed_sha256_hex, bytes_written).

  Raises:
    RuntimeError: On network error or truncated HTTP transfer.
  """
  req = urllib.request.Request(
    release.download_url, headers={"User-Agent": USER_AGENT}
  )
  digest = hashlib.sha256()
  written = 0

  try:
    with urllib.request.urlopen(req, timeout=60) as resp:
      header_len = resp.headers.get("Content-Length")
      total = (
        int(header_len)
        if header_len and header_len.isdigit()
        else (release.size_bytes or None)
      )
      with Progress(
        SpinnerColumn(),
        TextColumn("[bold cyan]{task.fields[name]}[/bold cyan]"),
        BarColumn(bar_width=30),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
        console=console,
      ) as progress:
        dl_name = Path(urllib.parse.urlparse(release.download_url).path).name
        task_id = progress.add_task("download", total=total, name=dl_name)
        with open(part_path, "wb") as out_fh:
          while chunk := resp.read(CHUNK_SIZE):
            out_fh.write(chunk)
            digest.update(chunk)
            written += len(chunk)
            progress.update(task_id, advance=len(chunk))
          out_fh.flush()
          os.fsync(out_fh.fileno())
  except (urllib.error.URLError, TimeoutError, OSError) as exc:
    raise RuntimeError(
      f"Download failed for {release.filename}: {exc}"
    ) from exc

  if written == 0:
    raise RuntimeError(f"Downloaded 0 bytes from {release.download_url}")
  if total is not None and written < total:
    raise RuntimeError(
      f"Truncated download for {release.filename}: got {written} of {total} bytes"
    )
  return digest.hexdigest(), written


def _decompress_bz2_staged(
  compressed_path: Path,
  output_path: Path,
  console: Console,
) -> tuple[str, int]:
  """Stream-decompress a staged '.bz2' image into output_path and hash it.

  Args:
    compressed_path: Downloaded '.img.bz2' archive path.
    output_path: Decompressed '.img' output path in staging.
    console: Rich Console for status display.

  Returns:
    Tuple of (decompressed_sha256_hex, decompressed_size_bytes).

  Raises:
    RuntimeError: If bzip2 stream is corrupt or empty.
  """
  decompressor = bz2.BZ2Decompressor()
  digest = hashlib.sha256()
  total_out = 0

  try:
    with (
      console.status(
        f"[bold cyan]Decompressing {compressed_path.name} -> {output_path.name}...[/bold cyan]"
      ),
      open(compressed_path, "rb") as src_fh,
      open(output_path, "wb") as dst_fh,
    ):
      while raw := src_fh.read(CHUNK_SIZE):
        data = decompressor.decompress(raw)
        if data:
          dst_fh.write(data)
          digest.update(data)
          total_out += len(data)
      dst_fh.flush()
      os.fsync(dst_fh.fileno())
  except OSError as exc:
    raise RuntimeError(
      f"Failed to decompress {compressed_path.name}: {exc}"
    ) from exc

  if not decompressor.eof or total_out == 0:
    raise RuntimeError(f"Incomplete bzip2 archive for {output_path.name}")
  return digest.hexdigest(), total_out


def download_and_stage_release(
  release: RemoteRelease,
  staging_root: Path,
  console: Console,
) -> tuple[Path, str]:
  """Download, SHA256-verify, and optionally decompress a release in staging.

  Args:
    release: Upstream RemoteRelease to fetch.
    staging_root: Validated temporary directory with sufficient disk space.
    console: Rich Console for progress output.

  Returns:
    Tuple of (verified_staged_file_path, final_file_sha256).

  Raises:
    RuntimeError: If download, checksum verification, or decompression fails.
  """
  work_dir = Path(
    tempfile.mkdtemp(prefix=f"ventoy-{release.distro_id}-", dir=staging_root)
  )
  part_path = work_dir / f"{release.filename}.download.part"
  final_staged = work_dir / release.filename

  try:
    dl_sha256, _ = _stream_download_to_part(release, part_path, console)
    if release.sha256 and dl_sha256.lower() != release.sha256.lower():
      raise RuntimeError(
        f"SHA256 mismatch for {release.filename}: "
        f"expected {release.sha256[:16]}..., got {dl_sha256[:16]}..."
      )

    if release.compression == "bz2":
      final_sha256, _ = _decompress_bz2_staged(part_path, final_staged, console)
      part_path.unlink(missing_ok=True)
    else:
      part_path.replace(final_staged)
      final_sha256 = dl_sha256

    return final_staged, final_sha256
  except BaseException:
    shutil.rmtree(work_dir, ignore_errors=True)
    raise


def _copy_file_to_ventoy(
  staged_file: Path,
  dest_path: Path,
  console: Console,
) -> None:
  """Copy verified staged image onto the Ventoy drive with progress & fsync.

  Args:
    staged_file: Verified image path in local temporary storage.
    dest_path: Final destination path on the Ventoy drive.
    console: Rich Console for transfer progress.
  """
  total_bytes = staged_file.stat().st_size
  try:
    os.replace(staged_file, dest_path)
    return
  except OSError:
    # Expected across filesystem boundaries (/tmp -> USB exFAT/FAT32 mount).
    pass

  with Progress(
    SpinnerColumn(),
    TextColumn(
      "[bold green]Writing {task.fields[name]} to Ventoy[/bold green]"
    ),
    BarColumn(bar_width=30),
    DownloadColumn(),
    TransferSpeedColumn(),
    TimeRemainingColumn(),
    console=console,
  ) as progress:
    task_id = progress.add_task("copy", total=total_bytes, name=dest_path.name)
    with open(staged_file, "rb") as src_fh, open(dest_path, "wb") as dst_fh:
      while chunk := src_fh.read(CHUNK_SIZE):
        dst_fh.write(chunk)
        progress.update(task_id, advance=len(chunk))
      dst_fh.flush()
      os.fsync(dst_fh.fileno())
  staged_file.unlink(missing_ok=True)


def resolve_new_iso_dir(ventoy_root: Path) -> Path:
  """Select destination directory on Ventoy when adding a brand-new ISO.

  Prefers an existing conventional subfolder ('ISOs', 'isos', 'ISO', 'iso') if
  present under ventoy_root; otherwise returns ventoy_root itself.

  Args:
    ventoy_root: Root directory of the mounted Ventoy drive.

  Returns:
    Target directory Path where newly added ISOs should be written.
  """
  for subdir_name in ("ISOs", "isos", "ISO", "iso"):
    candidate = ventoy_root / subdir_name
    if candidate.is_dir():
      return candidate
  return ventoy_root


def replace_image_on_ventoy(
  old_image: LocalImage | None,
  staged_file: Path,
  final_sha256: str,
  release: RemoteRelease,
  ventoy_root: Path,
  manifest: dict[str, dict[str, Any]],
  console: Console,
) -> Path:
  """Remove superseded image on Ventoy and move verified staged image into place.

  Args:
    old_image: Existing LocalImage to remove (or None when adding a new distro).
    staged_file: Checksum-verified image path in staging directory.
    final_sha256: Verified SHA256 hex digest of staged_file.
    release: Resolved RemoteRelease metadata.
    ventoy_root: Root directory of the Ventoy drive.
    manifest: Loaded '.ventoy-manifest.json' mapping to update.
    console: Rich Console for progress output.

  Returns:
    Final Path written onto the Ventoy drive.

  Raises:
    RuntimeError: If the Ventoy drive lacks sufficient free space.
  """
  dest_dir = (
    old_image.path.parent
    if old_image is not None
    else resolve_new_iso_dir(ventoy_root)
  )
  dest_path = dest_dir / release.filename
  new_size = staged_file.stat().st_size
  reclaimable = old_image.size_bytes if old_image is not None else 0
  ventoy_free = shutil.disk_usage(dest_dir).free

  if ventoy_free + reclaimable < new_size:
    raise RuntimeError(
      f"Not enough space on Ventoy drive '{dest_dir}': "
      f"{format_bytes(ventoy_free + reclaimable)} available after removing old ISO, "
      f"need {format_bytes(new_size)}."
    )

  if old_image is not None and old_image.path.exists():
    old_image.path.unlink()
    apple_double = old_image.path.parent / f"._{old_image.path.name}"
    apple_double.unlink(missing_ok=True)
    manifest.pop(old_image.rel_path, None)

  try:
    _copy_file_to_ventoy(staged_file, dest_path, console=console)
  finally:
    shutil.rmtree(staged_file.parent, ignore_errors=True)

  st = dest_path.stat()
  rel_key = str(dest_path.relative_to(ventoy_root))
  manifest[rel_key] = {
    "sha256": final_sha256,
    "size_bytes": st.st_size,
    "mtime_ns": st.st_mtime_ns,
    "version": release.version,
    "updated_at": datetime.now(UTC).isoformat(),
  }
  save_manifest(ventoy_root, manifest)
  return dest_path


# ==============================================================================
# 6. Rich Table Rendering & Interactive Prompts
# ==============================================================================


def _format_eval_badge(status: ImageStatus) -> str:
  """Return Rich markup badge string using unambiguous 2-cell emojis.

  Avoids U+FE0F variation-selector sequences and Nerd Font PUA codepoints so
  Rich cell width calculations match Ghostty and macOS/Linux terminals.

  Args:
    status: ImageStatus enum value.

  Returns:
    Styled Rich markup string.
  """
  styles = {
    ImageStatus.UPDATE_AVAILABLE: "[bold yellow]🔼 Update Available[/bold yellow]",
    ImageStatus.UP_TO_DATE: "[green]✅ Up-to-date[/green]",
    ImageStatus.MANUAL_ONLY: "[cyan]🔒 Manual Only[/cyan]",
    ImageStatus.UNMANAGED: "[dim]⚪ Skipped[/dim]",
    ImageStatus.ERROR: "[bold red]❌ Lookup Error[/bold red]",
  }
  return styles.get(status, status.value)


def _compact_version_label(label: str, keep_prefix: bool = True) -> str:
  """Shorten verbose 'sha256:<12hex>' rolling labels for compact table cells.

  Args:
    label: Raw version label (e.g. 'sha256:34847f850a6f' or '25.10.7').
    keep_prefix: Whether to retain the 'sha256:' prefix on SHA labels.

  Returns:
    Compact display label.
  """
  if label.startswith("sha256:"):
    short_hex = label.removeprefix("sha256:")[:8]
    return f"sha256:{short_hex}" if keep_prefix else short_hex
  return label


def _format_eval_row(
  ev: ImageEvaluation, display_rel_path: str
) -> tuple[str, str, str, str, str]:
  """Format a single ImageEvaluation into 5 Rich table cell strings.

  Args:
    ev: Evaluated image entry.
    display_rel_path: Filename path relative to the current table's folder.

  Returns:
    5-tuple of (file_cell, distro_cell, version_cell, size_cell, status_cell).
  """
  is_muted = ev.status == ImageStatus.UNMANAGED
  file_cell = (
    f"[dim]{display_rel_path}[/dim]"
    if is_muted
    else f"[bold cyan]{display_rel_path}[/bold cyan]"
  )

  if ev.remote is not None:
    distro_title = ev.remote.display_name
  elif ev.local.distro_id in CATALOG_BY_ID:
    distro_title = CATALOG_BY_ID[ev.local.distro_id].display_name
  elif ev.status == ImageStatus.MANUAL_ONLY:
    distro_title = "Windows Installer"
  else:
    distro_title = "[dim]Custom / External[/dim]"

  if ev.status == ImageStatus.UPDATE_AVAILABLE:
    left_v = _compact_version_label(ev.local_label, keep_prefix=True)
    right_v = _compact_version_label(
      ev.remote_label, keep_prefix=not ev.local_label.startswith("sha256:")
    )
    version_cell = f"[dim]{left_v}[/dim] → [bold green]{right_v}[/bold green]"
  elif ev.status == ImageStatus.UP_TO_DATE:
    version_cell = f"[green]{_compact_version_label(ev.remote_label, keep_prefix=True)}[/green]"
  elif ev.local_label != "—":
    version_cell = f"[dim]{_compact_version_label(ev.local_label)}[/dim]"
  else:
    version_cell = "[dim]—[/dim]"

  size_val = (
    ev.remote.size_bytes
    if ev.remote is not None and ev.remote.size_bytes > 0
    else ev.local.size_bytes
  )
  size_str = format_bytes(size_val)
  size_cell = (
    f"[dim]{size_str}[/dim]" if is_muted else f"[magenta]{size_str}[/magenta]"
  )

  status_cell = _format_eval_badge(ev.status)
  if ev.status in (ImageStatus.MANUAL_ONLY, ImageStatus.ERROR) and ev.detail:
    status_cell += f"\n[dim]{ev.detail}[/dim]"

  return file_cell, distro_title, version_cell, size_cell, status_cell


def _build_folder_table(
  title: str,
  rows_evals: list[tuple[ImageEvaluation, str]],
) -> Table:
  """Build a padded, section-grouped Rich Table for a Ventoy folder.

  Groups rows into up to 3 visual sections separated by horizontal lines:
  1. Updates Available / Errors
  2. Up-to-date Managed OS Images
  3. Manual-Only / Skipped Images in the same folder

  Args:
    title: Formatted Rich title header for the folder table.
    rows_evals: Pairs of (ImageEvaluation, display_rel_path).

  Returns:
    Populated Rich Table instance.
  """
  table = Table(
    title=title,
    title_justify="left",
    box=box.ROUNDED,
    padding=(0, 2),
    header_style="bold white",
  )
  table.add_column("Image File", overflow="fold")
  table.add_column("Distro", style="white")
  table.add_column("Version", overflow="fold")
  table.add_column("Size", justify="right", no_wrap=True)
  table.add_column("Status")

  tier_1 = [
    pair
    for pair in rows_evals
    if pair[0].status in (ImageStatus.UPDATE_AVAILABLE, ImageStatus.ERROR)
  ]
  tier_2 = [
    pair for pair in rows_evals if pair[0].status == ImageStatus.UP_TO_DATE
  ]
  tier_3 = [
    pair
    for pair in rows_evals
    if pair[0].status in (ImageStatus.MANUAL_ONLY, ImageStatus.UNMANAGED)
  ]

  non_empty_tiers = [t for t in (tier_1, tier_2, tier_3) if t]
  for tier_idx, tier_rows in enumerate(non_empty_tiers):
    if tier_idx > 0:
      table.add_section()
    for ev, display_rel in tier_rows:
      table.add_row(*_format_eval_row(ev, display_rel))

  return table


def render_evaluations_table(
  ventoy_root: Path,
  evaluations: list[ImageEvaluation],
  console: Console,
  *,
  show_skipped: bool = False,
) -> None:
  """Render folder-grouped Rich status tables highlighting OS directories.

  Folders containing managed OS images (such as 'ISOs/') render as dedicated,
  well-padded tables with status section dividers, while purely unmanaged
  external utility directories are summarized compactly below unless
  'show_skipped=True' is set.

  Args:
    ventoy_root: Root directory scanned.
    evaluations: Evaluated LocalImage/RemoteRelease rows.
    console: Rich Console instance.
    show_skipped: If True, render full tables for skipped utility folders too.
  """
  grouped: dict[str, list[tuple[ImageEvaluation, str]]] = {}
  for ev in evaluations:
    parts = Path(ev.local.rel_path).parts
    if len(parts) > 1:
      folder_key = parts[0]
      inner_rel = "/".join(parts[1:])
    else:
      folder_key = ""
      inner_rel = ev.local.rel_path
    grouped.setdefault(folder_key, []).append((ev, inner_rel))

  iso_dir_names = {"isos", "iso"}
  active_folders: list[str] = []
  skipped_folders: list[tuple[str, int]] = []

  for folder_key, items in grouped.items():
    has_managed = any(ev.status != ImageStatus.UNMANAGED for ev, _ in items)
    if show_skipped or has_managed or folder_key.lower() in iso_dir_names:
      active_folders.append(folder_key)
    else:
      skipped_folders.append((folder_key or ".", len(items)))

  # Fallback if drive ONLY contains unmanaged images in non-ISO folders
  if not active_folders and skipped_folders:
    active_folders = list(grouped.keys())
    skipped_folders = []

  # Prioritize 'ISOs/' and root directory at the very top
  active_folders.sort(
    key=lambda k: (
      0 if k.lower() in iso_dir_names else (1 if k == "" else 2),
      k.lower(),
    )
  )

  console.print()
  for idx, folder_key in enumerate(active_folders):
    if idx > 0:
      console.print()
    if folder_key:
      folder_path = ventoy_root / folder_key
      title = (
        f"📂 [bold cyan]{folder_key}/[/bold cyan]  [dim]({folder_path})[/dim]"
      )
    else:
      title = f"💾 [bold cyan]Ventoy Bootable Images[/bold cyan]  [dim]({ventoy_root})[/dim]"
    console.print(_build_folder_table(title, grouped[folder_key]))

  if skipped_folders:
    total_skipped = sum(count for _, count in skipped_folders)
    folder_summary = ", ".join(
      f"[white]{name}[/white] ({count})" for name, count in skipped_folders
    )
    console.print(
      f"\n  [dim]⚪ Skipped {total_skipped} external utility image(s) in "
      f"{len(skipped_folders)} other folder(s):[/dim] {folder_summary}\n"
      "  [dim]   Pass '--show-skipped' to expand all folders.[/dim]"
    )
  console.print()


def resolve_target_ventoy_dir(
  explicit_dir: Path | None, console: Console
) -> Path | None:
  """Resolve and validate the target Ventoy directory from CLI or auto-mount.

  Args:
    explicit_dir: Optional directory path passed on the CLI.
    console: Rich Console for error hints.

  Returns:
    Validated directory Path, or None if missing/not mounted.
  """
  if explicit_dir is not None:
    resolved = explicit_dir.expanduser().resolve()
    if not resolved.is_dir():
      STDERR_CONSOLE.print(
        f"[bold red]❌ Error:[/bold red] Directory '{resolved}' does not exist."
      )
      return None
    return resolved

  detected = detect_ventoy_mount()
  if detected is not None:
    console.print(
      f"  [dim]🔌 Auto-detected mounted Ventoy drive:[/dim] [bold cyan]{detected}[/bold cyan]"
    )
    return detected

  STDERR_CONSOLE.print(
    "[bold yellow]⚡ No mounted Ventoy drive auto-detected.[/bold yellow]\n"
    "[dim]Mount your Ventoy USB stick (e.g. /Volumes/Ventoy on macOS or "
    "/run/media/$USER/Ventoy on Linux) or pass a path explicitly: "
    "'ventoy /path/to/isos'.[/dim]"
  )
  return None


def _execute_single_transfer(
  old_image: LocalImage | None,
  release: RemoteRelease,
  ventoy_root: Path,
  manifest: dict[str, dict[str, Any]],
  *,
  temp_dir: Path | None,
  dry_run: bool,
  console: Console,
) -> bool:
  """Download, verify, and swap a single RemoteRelease onto Ventoy.

  Args:
    old_image: Existing LocalImage being replaced (None when adding).
    release: Upstream RemoteRelease to install.
    ventoy_root: Root directory of the Ventoy drive.
    manifest: Loaded '.ventoy-manifest.json' dictionary.
    temp_dir: Optional explicit '--temp-dir' path.
    dry_run: If True, preview actions without downloading or deleting.
    console: Rich Console for output.

  Returns:
    True on success, False on download/checksum/disk failure.
  """
  action_word = "Updating" if old_image is not None else "Adding"
  console.print(
    f"🚀 [bold cyan]{action_word} {release.display_name}[/bold cyan] "
    f"([bold white]{release.filename}[/bold white])"
  )

  if dry_run:
    target_dir = (
      old_image.path.parent
      if old_image is not None
      else resolve_new_iso_dir(ventoy_root)
    )
    old_note = (
      f"remove '{old_image.rel_path}' and " if old_image is not None else ""
    )
    console.print(
      f"  [cyan]🔍 [Dry Run] Would download {release.download_url}, verify SHA256, "
      f"{old_note}place '{release.filename}' in {target_dir}.[/cyan]\n"
    )
    return True

  try:
    staging_dir, used_fallback = select_staging_dir(
      release.size_bytes, explicit_temp_dir=temp_dir
    )
    if used_fallback:
      console.print(
        f"  [dim yellow]💡 /tmp has limited free space; staging in {staging_dir}[/dim yellow]"
      )
    staged_file, final_sha = download_and_stage_release(
      release, staging_dir, console=console
    )
    console.print(
      f"  [green]✅ Verified SHA256:[/green] [dim]{final_sha[:16]}...[/dim]"
    )
    dest_path = replace_image_on_ventoy(
      old_image,
      staged_file,
      final_sha,
      release,
      ventoy_root,
      manifest,
      console=console,
    )
    rel_dest = dest_path.relative_to(ventoy_root)
    console.print(
      f"  [bold green]✨ Installed {rel_dest} ({format_bytes(dest_path.stat().st_size)})[/bold green]\n"
    )
    return True
  except RuntimeError as exc:
    STDERR_CONSOLE.print(
      f"  [bold red]❌ Failed ({release.display_name}):[/bold red] {exc}\n"
      "  [dim]Existing files on your Ventoy drive were left untouched.[/dim]\n"
    )
    return False


# ==============================================================================
# 6b. Ventoy Bootloader Version Detection & Safe Non-Destructive Upgrade ('-u')
# ==============================================================================


def extract_ventoy_version_from_grub_cfg(cfg_text: str) -> str:
  """Extract 'VENTOY_VERSION' from VTOYEFI '/grub/grub.cfg' contents.

  Args:
    cfg_text: Raw text of 'grub/grub.cfg' from the VTOYEFI partition.

  Returns:
    Parsed version string (e.g. '1.1.18'), or empty string if absent.
  """
  match = re.search(r'set\s+VENTOY_VERSION="([^"]+)"', cfg_text)
  return match.group(1).strip() if match else ""


def resolve_ventoy_bootloader_release() -> VentoyBootloaderRelease:
  """Query official GitHub releases for the latest Ventoy bootloader package.

  Returns:
    VentoyBootloaderRelease with verified URLs and SHA256 digests.

  Raises:
    RuntimeError: If GitHub release metadata or assets cannot be resolved.
  """
  data = http_get_json(VENTOY_GITHUB_LATEST_URL)
  if not isinstance(data, dict):
    raise RuntimeError("Unexpected Ventoy GitHub release payload")

  raw_tag = str(data.get("tag_name") or "").strip()
  version = raw_tag.lstrip("vV")
  if not version:
    raise RuntimeError("Missing tag_name in Ventoy GitHub release response")

  assets = data.get("assets")
  if not isinstance(assets, list):
    raise RuntimeError("Missing assets list in Ventoy GitHub release response")

  by_name: dict[str, dict[str, Any]] = {
    str(a.get("name")): a
    for a in assets
    if isinstance(a, dict) and a.get("name")
  }
  tar_name = f"ventoy-{version}-linux.tar.gz"
  iso_name = f"ventoy-{version}-livecd.iso"
  tar_asset = by_name.get(tar_name)
  if tar_asset is None:
    raise RuntimeError(f"Asset '{tar_name}' not found in Ventoy v{version}")

  sums_text = ""
  sums_asset = by_name.get("sha256.txt")
  if sums_asset and sums_asset.get("browser_download_url"):
    sums_text = http_get_text(str(sums_asset["browser_download_url"]))
  checksums = parse_sha256sums_text(sums_text) if sums_text else {}

  iso_asset = by_name.get(iso_name, {})
  return VentoyBootloaderRelease(
    version=version,
    linux_tarball_name=tar_name,
    linux_tarball_url=str(tar_asset.get("browser_download_url") or ""),
    linux_tarball_sha256=checksums.get(tar_name, ""),
    linux_tarball_size=int(tar_asset.get("size") or 0),
    livecd_iso_name=iso_name if iso_asset else "",
    livecd_iso_url=str(iso_asset.get("browser_download_url") or ""),
    livecd_iso_sha256=checksums.get(iso_name, ""),
    livecd_iso_size=int(iso_asset.get("size") or 0),
  )


def _read_grub_cfg_version(mount_point: Path) -> str:
  """Read 'VENTOY_VERSION' from '<mount_point>/grub/grub.cfg' if present.

  Args:
    mount_point: Mounted root path of the VTOYEFI partition.

  Returns:
    Parsed version string, or empty string if unreadable.
  """
  cfg_path = mount_point / "grub" / "grub.cfg"
  if not cfg_path.is_file():
    return ""
  try:
    return extract_ventoy_version_from_grub_cfg(
      cfg_path.read_text(encoding="utf-8", errors="replace")
    )
  except OSError:
    return ""


def _run_plist_cmd(cmd: list[str]) -> dict[str, Any] | None:
  """Execute a macOS command returning XML plist output and parse it safely.

  Args:
    cmd: Command argv list (e.g. ['diskutil', 'info', '-plist', ...]).

  Returns:
    Parsed plist dictionary, or None on subprocess/parse failure.
  """
  try:
    proc = subprocess.run(cmd, capture_output=True, check=False, timeout=8)
  except (OSError, subprocess.SubprocessError):
    return None
  if proc.returncode != 0 or not proc.stdout:
    return None
  try:
    parsed = plistlib.loads(proc.stdout)
  except plistlib.InvalidFileException:
    return None
  return parsed if isinstance(parsed, dict) else None


def _read_macos_efi_version(efi_dev: str) -> str:
  """Read Ventoy version from a macOS VTOYEFI partition, mounting RO if needed.

  Args:
    efi_dev: Device node such as '/dev/disk4s2'.

  Returns:
    Installed Ventoy version string, or empty string if unavailable.
  """
  info = _run_plist_cmd(["diskutil", "info", "-plist", efi_dev])
  if info is None:
    return ""

  existing_mp = str(info.get("MountPoint") or "").strip()
  if existing_mp:
    return _read_grub_cfg_version(Path(existing_mp))

  mounted_temp = False
  try:
    res = subprocess.run(
      ["diskutil", "mount", "readOnly", efi_dev],
      capture_output=True,
      check=False,
      timeout=10,
    )
    if res.returncode != 0:
      return ""
    mounted_temp = True
    refreshed = _run_plist_cmd(["diskutil", "info", "-plist", efi_dev])
    mp = str((refreshed or {}).get("MountPoint") or "").strip()
    return _read_grub_cfg_version(Path(mp)) if mp else ""
  except (OSError, subprocess.SubprocessError):
    return ""
  finally:
    if mounted_temp:
      subprocess.run(
        ["diskutil", "unmount", efi_dev],
        capture_output=True,
        check=False,
        timeout=8,
      )


def _inspect_ventoy_drive_macos(ventoy_root: Path) -> VentoyDriveInfo:
  """Inspect a mounted Ventoy directory on macOS via 'diskutil'.

  Args:
    ventoy_root: Mounted Ventoy path (e.g. '/Volumes/Ventoy').

  Returns:
    Populated VentoyDriveInfo record.
  """
  part_info = _run_plist_cmd(["diskutil", "info", "-plist", str(ventoy_root)])
  if part_info is None:
    return VentoyDriveInfo()

  parent_id = str(part_info.get("ParentWholeDisk") or "").strip()
  data_dev = str(part_info.get("DeviceNode") or "").strip()
  if not parent_id:
    return VentoyDriveInfo(data_partition=data_dev)

  disk_dev = f"/dev/{parent_id}"
  disk_info = _run_plist_cmd(["diskutil", "info", "-plist", disk_dev]) or {}
  list_info = _run_plist_cmd(["diskutil", "list", "-plist", disk_dev]) or {}

  is_internal = bool(disk_info.get("Internal", part_info.get("Internal", True)))
  is_removable = bool(
    disk_info.get("RemovableMedia")
    or disk_info.get("Ejectable")
    or not is_internal
  )
  model = str(
    disk_info.get("MediaName") or part_info.get("MediaName") or ""
  ).strip()
  disk_size = int(disk_info.get("TotalSize") or 0)

  efi_dev = ""
  is_sys = False
  all_disks = list_info.get("AllDisksAndPartitions") or []
  for disk_entry in all_disks:
    if not isinstance(disk_entry, dict):
      continue
    for part in disk_entry.get("Partitions") or []:
      if not isinstance(part, dict):
        continue
      mp = str(part.get("MountPoint") or "").strip()
      if mp in SYSTEM_CRITICAL_MOUNTPOINTS:
        is_sys = True
      vol_name = str(part.get("VolumeName") or "").strip().upper()
      dev_id = str(part.get("DeviceIdentifier") or "").strip()
      p_size = int(part.get("Size") or 0)
      if dev_id and (vol_name == "VTOYEFI" or p_size == 33_554_432):
        efi_dev = f"/dev/{dev_id}"

  ver = _read_macos_efi_version(efi_dev) if efi_dev else ""
  return VentoyDriveInfo(
    disk_device=disk_dev,
    data_partition=data_dev,
    efi_partition=efi_dev,
    model=model,
    disk_size_bytes=disk_size,
    is_removable=is_removable,
    is_system_disk=is_sys,
    installed_version=ver,
  )


def _read_linux_efi_version(efi_node: dict[str, Any]) -> str:
  """Read Ventoy version from a Linux VTOYEFI partition, using udisksctl RO if needed.

  Args:
    efi_node: lsblk partition dictionary for VTOYEFI.

  Returns:
    Installed Ventoy version string, or empty string if unavailable.
  """
  mounts = [
    str(m)
    for m in (efi_node.get("mountpoints") or [efi_node.get("mountpoint")])
    if m
  ]
  if mounts:
    return _read_grub_cfg_version(Path(mounts[0]))

  efi_path = str(efi_node.get("path") or "").strip()
  udisks = shutil.which("udisksctl")
  if not efi_path or not udisks:
    return ""

  mounted_temp = False
  try:
    res = subprocess.run(
      [
        udisks,
        "mount",
        "--options",
        "ro",
        "--no-user-interaction",
        "-b",
        efi_path,
      ],
      capture_output=True,
      text=True,
      check=False,
      timeout=10,
    )
    if res.returncode != 0:
      return ""
    mounted_temp = True
    # Output format: "Mounted /dev/sdb2 at /run/media/user/VTOYEFI."
    m = re.search(r"\bat\s+(.+?)\.?\s*$", res.stdout.strip())
    return _read_grub_cfg_version(Path(m.group(1))) if m else ""
  except (OSError, subprocess.SubprocessError):
    return ""
  finally:
    if mounted_temp:
      subprocess.run(
        [udisks, "unmount", "--no-user-interaction", "-b", efi_path],
        capture_output=True,
        check=False,
        timeout=8,
      )


def _resolve_mount_source_linux(target_path: Path) -> str:
  """Determine the backing block device path for a Linux directory via 'df'.

  Args:
    target_path: Local filesystem directory path.

  Returns:
    Device path such as '/dev/sdb1', or empty string if not a '/dev/' mount.
  """
  try:
    proc = subprocess.run(
      ["df", "--output=source", str(target_path)],
      capture_output=True,
      text=True,
      check=False,
      timeout=5,
    )
  except (OSError, subprocess.SubprocessError):
    return ""
  lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
  if len(lines) < 2 or not lines[-1].startswith("/dev/"):
    return ""
  return str(Path(lines[-1]).resolve())


def _inspect_ventoy_drive_linux(ventoy_root: Path) -> VentoyDriveInfo:
  """Inspect a mounted Ventoy directory on Linux via 'df' and 'lsblk -J'.

  Args:
    ventoy_root: Mounted Ventoy path (e.g. '/run/media/user/Ventoy').

  Returns:
    Populated VentoyDriveInfo record.
  """
  part_dev = _resolve_mount_source_linux(ventoy_root)
  if not part_dev:
    return VentoyDriveInfo()

  try:
    proc = subprocess.run(
      [
        "lsblk",
        "-J",
        "-b",
        "-o",
        "NAME,PATH,PKNAME,TYPE,RM,HOTPLUG,TRAN,SIZE,LABEL,MOUNTPOINT,MOUNTPOINTS,MODEL",
      ],
      capture_output=True,
      text=True,
      check=False,
      timeout=8,
    )
    payload = json.loads(proc.stdout) if proc.returncode == 0 else {}
  except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
    return VentoyDriveInfo(data_partition=part_dev)

  for dev in payload.get("blockdevices") or []:
    if not isinstance(dev, dict) or dev.get("type") != "disk":
      continue
    children = [c for c in (dev.get("children") or []) if isinstance(c, dict)]
    if not any(str(c.get("path") or "") == part_dev for c in children):
      continue

    disk_path = str(dev.get("path") or "")
    tran = str(dev.get("tran") or "").lower()
    is_rem = bool(dev.get("rm") or dev.get("hotplug") or tran == "usb")
    is_sys = False
    efi_node: dict[str, Any] | None = None

    for child in children:
      c_mounts = [
        str(m)
        for m in (child.get("mountpoints") or [child.get("mountpoint")])
        if m
      ]
      if any(m in SYSTEM_CRITICAL_MOUNTPOINTS for m in c_mounts):
        is_sys = True
      label = str(child.get("label") or "").strip().upper()
      c_size = int(child.get("size") or 0)
      if label == "VTOYEFI" or c_size == 33_554_432:
        efi_node = child

    ver = _read_linux_efi_version(efi_node) if efi_node else ""
    return VentoyDriveInfo(
      disk_device=disk_path,
      data_partition=part_dev,
      efi_partition=str((efi_node or {}).get("path") or ""),
      model=str(dev.get("model") or "").strip(),
      disk_size_bytes=int(dev.get("size") or 0),
      is_removable=is_rem,
      is_system_disk=is_sys,
      installed_version=ver,
    )

  return VentoyDriveInfo(data_partition=part_dev)


def inspect_ventoy_drive(ventoy_root: Path) -> VentoyDriveInfo:
  """Inspect underlying USB block device and VTOYEFI bootloader version.

  Args:
    ventoy_root: Mounted Ventoy directory path.

  Returns:
    VentoyDriveInfo describing the drive and installed Ventoy version.
  """
  if sys.platform == "darwin":
    return _inspect_ventoy_drive_macos(ventoy_root)
  if sys.platform.startswith("linux"):
    return _inspect_ventoy_drive_linux(ventoy_root)
  return VentoyDriveInfo()


def render_bootloader_banner(ventoy_root: Path, console: Console) -> None:
  """Display a 1-line Ventoy bootloader status badge above ISO scan tables.

  Silently no-ops when 'ventoy_root' is a plain local directory rather than a
  physical Ventoy USB drive with a VTOYEFI partition.

  Args:
    ventoy_root: Scanned Ventoy directory.
    console: Rich Console instance.
  """
  drive = inspect_ventoy_drive(ventoy_root)
  if not drive.efi_partition and not drive.installed_version:
    return
  try:
    rel = resolve_ventoy_bootloader_release()
  except RuntimeError:
    return

  dev_hint = f"  [dim]({drive.disk_device})[/dim]" if drive.disk_device else ""
  if not drive.installed_version:
    console.print(
      f"\n  💿 [bold white]Ventoy Bootloader:[/bold white] [dim]installed version unknown "
      f"(latest v{rel.version} — run 'ventoy upgrade --check')[/dim]{dev_hint}"
    )
    return

  if is_remote_newer(drive.installed_version, rel.version):
    console.print(
      f"\n  💿 [bold white]Ventoy Bootloader:[/bold white] "
      f"[dim]v{drive.installed_version}[/dim] → [bold green]v{rel.version}[/bold green]  "
      f"[bold yellow]🔼 Update Available[/bold yellow]  [dim](run 'ventoy upgrade')[/dim]{dev_hint}"
    )
  else:
    console.print(
      f"\n  💿 [bold white]Ventoy Bootloader:[/bold white] "
      f"[green]v{drive.installed_version}[/green]  [green]✅ Up-to-date[/green]{dev_hint}"
    )


def _safe_extract_tar_gz(archive_path: Path, dest_dir: Path) -> Path:
  """Extract a verified Ventoy Linux tarball safely using PEP 706 data filter.

  Args:
    archive_path: Verified 'ventoy-X.Y.Z-linux.tar.gz' file path.
    dest_dir: Extraction parent directory.

  Returns:
    Path to the directory containing 'Ventoy2Disk.sh'.

  Raises:
    RuntimeError: If extraction fails or 'Ventoy2Disk.sh' is missing.
  """
  try:
    with tarfile.open(archive_path, "r:gz") as tf:
      tf.extractall(path=dest_dir, filter="data")
  except (tarfile.TarError, OSError) as exc:
    raise RuntimeError(f"Failed to extract {archive_path.name}: {exc}") from exc

  for script in dest_dir.rglob("Ventoy2Disk.sh"):
    return script.parent
  raise RuntimeError(f"'Ventoy2Disk.sh' not found inside {archive_path.name}")


def _validate_linux_upgrade_safety(drive: VentoyDriveInfo) -> None:
  """Enforce strict block-device safety guards before running 'Ventoy2Disk.sh -u'.

  Args:
    drive: Inspected VentoyDriveInfo for the target USB stick.

  Raises:
    RuntimeError: If any safety invariant fails.
  """
  if not drive.disk_device or not drive.disk_device.startswith("/dev/"):
    raise RuntimeError(
      "Could not map target directory to a physical '/dev/' block device."
    )
  if drive.is_system_disk:
    raise RuntimeError(
      f"Safety abort: '{drive.disk_device}' hosts critical OS filesystems!"
    )
  if not drive.is_removable:
    raise RuntimeError(
      f"Safety abort: '{drive.disk_device}' is not flagged as removable/USB media."
    )
  if not drive.efi_partition:
    raise RuntimeError(
      f"Safety abort: '{drive.disk_device}' has no VTOYEFI partition "
      "(refusing destructive initial install; only '-u' updates are permitted)."
    )


def _unmount_linux_disk_partitions(disk_device: str) -> None:
  """Flush filesystem buffers and cleanly unmount partitions on disk_device.

  Args:
    disk_device: Whole-disk path such as '/dev/sdb'.
  """
  if hasattr(os, "sync"):
    os.sync()
  udisks = shutil.which("udisksctl")
  try:
    proc = subprocess.run(
      ["lsblk", "-J", "-o", "PATH,MOUNTPOINT,MOUNTPOINTS", disk_device],
      capture_output=True,
      text=True,
      check=False,
      timeout=5,
    )
    data = json.loads(proc.stdout) if proc.returncode == 0 else {}
  except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
    return

  for dev in data.get("blockdevices") or []:
    for child in dev.get("children") or []:
      c_path = str(child.get("path") or "")
      mounts = [
        m for m in (child.get("mountpoints") or [child.get("mountpoint")]) if m
      ]
      if not c_path or not mounts:
        continue
      if udisks:
        subprocess.run(
          [udisks, "unmount", "--no-user-interaction", "-b", c_path],
          capture_output=True,
          check=False,
          timeout=15,
        )


def _execute_linux_bootloader_upgrade(
  drive: VentoyDriveInfo,
  rel: VentoyBootloaderRelease,
  *,
  temp_dir: Path | None,
  dry_run: bool,
  console: Console,
) -> bool:
  """Download, SHA256-verify, and run non-destructive 'Ventoy2Disk.sh -u' on Linux.

  Args:
    drive: Validated VentoyDriveInfo for the USB drive.
    rel: Upstream VentoyBootloaderRelease metadata.
    temp_dir: Optional explicit staging directory.
    dry_run: If True, preview without downloading or writing to the device.
    console: Rich Console for status output.

  Returns:
    True on successful upgrade, False on error.
  """
  try:
    _validate_linux_upgrade_safety(drive)
  except RuntimeError as exc:
    STDERR_CONSOLE.print(f"  [bold red]❌ {exc}[/bold red]\n")
    return False

  if dry_run:
    console.print(
      f"  [cyan]🔍 [Dry Run] Would download & SHA256-verify {rel.linux_tarball_name}, "
      f"unmount {drive.data_partition}, run 'sudo sh Ventoy2Disk.sh -u {drive.disk_device}' "
      "(preserving Partition 1 data intact), and remount.[/cyan]\n"
    )
    return True

  dl_release = RemoteRelease(
    distro_id="ventoy-bootloader",
    display_name=f"Ventoy Bootloader v{rel.version}",
    version=rel.version,
    filename=rel.linux_tarball_name,
    download_url=rel.linux_tarball_url,
    sha256=rel.linux_tarball_sha256,
    size_bytes=rel.linux_tarball_size,
  )
  work_parent: Path | None = None
  try:
    staging_dir, _ = select_staging_dir(
      rel.linux_tarball_size, explicit_temp_dir=temp_dir
    )
    staged_tar, final_sha = download_and_stage_release(
      dl_release, staging_dir, console=console
    )
    work_parent = staged_tar.parent
    console.print(
      f"  [green]✅ Verified {rel.linux_tarball_name} SHA256:[/green] [dim]{final_sha[:16]}...[/dim]"
    )
    ventoy_dir = _safe_extract_tar_gz(staged_tar, work_parent / "extracted")

    console.print(
      f"  [cyan]🔌 Flushing & unmounting {drive.data_partition} before bootloader update...[/cyan]"
    )
    _unmount_linux_disk_partitions(drive.disk_device)

    console.print(
      f"  [bold cyan]🚀 Running 'sudo sh Ventoy2Disk.sh -u {drive.disk_device}' "
      "(Partition 1 data untouched)...[/bold cyan]"
    )
    proc = subprocess.run(
      ["sudo", "sh", "./Ventoy2Disk.sh", "-u", drive.disk_device],
      cwd=ventoy_dir,
      input="y\n",
      text=True,
      check=False,
    )
    if proc.returncode != 0:
      raise RuntimeError(f"Ventoy2Disk.sh exited with status {proc.returncode}")

    udisks = shutil.which("udisksctl")
    if udisks and drive.data_partition:
      subprocess.run(
        [udisks, "mount", "--no-user-interaction", "-b", drive.data_partition],
        capture_output=True,
        check=False,
        timeout=15,
      )
    console.print(
      f"\n  [bold green]✨ Ventoy bootloader on {drive.disk_device} upgraded to v{rel.version}![/bold green]\n"
    )
    return True
  except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
    STDERR_CONSOLE.print(
      f"  [bold red]❌ Bootloader upgrade failed:[/bold red] {exc}\n"
    )
    return False
  finally:
    if work_parent is not None:
      shutil.rmtree(work_parent, ignore_errors=True)


def _install_ventoy_livecd_iso(
  rel: VentoyBootloaderRelease,
  ventoy_root: Path,
  *,
  temp_dir: Path | None,
  dry_run: bool,
  console: Console,
) -> bool:
  """Download and place 'ventoy-X.Y.Z-livecd.iso' onto the Ventoy drive.

  Args:
    rel: Upstream VentoyBootloaderRelease metadata.
    ventoy_root: Mounted Ventoy directory.
    temp_dir: Optional explicit staging directory.
    dry_run: If True, preview without writing to disk.
    console: Rich Console instance.

  Returns:
    True on success, False on failure.
  """
  if not rel.livecd_iso_url or not rel.livecd_iso_name:
    STDERR_CONSOLE.print(
      "  [bold red]❌ Upstream release does not include a LiveCD ISO asset.[/bold red]\n"
    )
    return False

  existing = [
    img
    for img in scan_ventoy_images(ventoy_root)
    if re.match(r"^ventoy-[\d.]+-livecd\.iso$", img.path.name, re.IGNORECASE)
  ]
  old_img = existing[0] if existing else None
  manifest = load_manifest(ventoy_root)
  iso_release = RemoteRelease(
    distro_id="ventoy-livecd",
    display_name="Ventoy LiveCD Updater",
    version=rel.version,
    filename=rel.livecd_iso_name,
    download_url=rel.livecd_iso_url,
    sha256=rel.livecd_iso_sha256,
    size_bytes=rel.livecd_iso_size,
  )
  return _execute_single_transfer(
    old_img,
    iso_release,
    ventoy_root,
    manifest,
    temp_dir=temp_dir,
    dry_run=dry_run,
    console=console,
  )


def _render_bootloader_status_table(
  drive: VentoyDriveInfo,
  rel: VentoyBootloaderRelease,
  ventoy_root: Path,
  console: Console,
) -> bool:
  """Render Rich summary table for Ventoy bootloader state.

  Args:
    drive: Inspected VentoyDriveInfo.
    rel: Upstream VentoyBootloaderRelease.
    ventoy_root: Mounted Ventoy directory.
    console: Rich Console instance.

  Returns:
    True if an upgrade is needed (or local version could not be read).
  """
  table = Table(
    title=f"💿 [bold cyan]Ventoy Bootloader Status[/bold cyan]  [dim]({ventoy_root})[/dim]",
    title_justify="left",
    box=box.ROUNDED,
    padding=(0, 2),
    header_style="bold white",
  )
  table.add_column("USB Disk", style="bold cyan")
  table.add_column("Model / Capacity", style="white")
  table.add_column("Installed", no_wrap=True)
  table.add_column("Latest", style="bold green", no_wrap=True)
  table.add_column("Data Partition", style="dim")
  table.add_column("Status", no_wrap=True)

  dev_label = drive.disk_device or "Not detected"
  model_parts = [
    p
    for p in (drive.model, format_bytes(drive.disk_size_bytes))
    if p and p != "—"
  ]
  model_label = " • ".join(model_parts) if model_parts else "—"
  inst_label = (
    f"v{drive.installed_version}" if drive.installed_version else "Unknown"
  )

  if not drive.installed_version:
    needs_update = True
    badge = "[yellow]⚡ Version Unread[/yellow]"
  elif is_remote_newer(drive.installed_version, rel.version):
    needs_update = True
    badge = "[bold yellow]🔼 Update Available[/bold yellow]"
  else:
    needs_update = False
    badge = "[green]✅ Up-to-date[/green]"

  table.add_row(
    dev_label,
    model_label,
    inst_label,
    f"v{rel.version}",
    f"{drive.data_partition or ventoy_root.name} (untouched)",
    badge,
  )
  console.print()
  console.print(table)
  console.print()
  return needs_update


def _confirm_bootloader_upgrade(
  drive: VentoyDriveInfo, rel: VentoyBootloaderRelease, console: Console
) -> bool:
  """Prompt user to confirm non-destructive Ventoy bootloader upgrade on Linux.

  Args:
    drive: Inspected VentoyDriveInfo.
    rel: Upstream VentoyBootloaderRelease.
    console: Rich Console instance.

  Returns:
    True if user confirmed, False otherwise.
  """
  ver_from = (
    f"v{drive.installed_version}" if drive.installed_version else "current"
  )
  try:
    confirmed = Confirm.ask(
      f"  Non-destructively upgrade Ventoy on [bold cyan]{drive.disk_device}[/bold cyan] "
      f"({ver_from} → [bold green]v{rel.version}[/bold green], Partition 1 data untouched)?",
      console=console,
      default=True,
    )
  except (KeyboardInterrupt, EOFError):
    console.print("\n  [yellow]Cancelled.[/yellow]\n")
    return False
  if not confirmed:
    console.print("\n  [yellow]Upgrade skipped.[/yellow]\n")
    return False
  console.print()
  return True


def _print_upgrade_status_only_notice(
  needs_update: bool,
  force: bool,
  check_only: bool,
  rel: VentoyBootloaderRelease,
  console: Console,
) -> bool:
  """Print early-exit notice when no Linux block upgrade should execute.

  Args:
    needs_update: Whether installed bootloader is older than upstream.
    force: Whether '--force' was passed.
    check_only: Whether '--check' was passed.
    rel: Upstream VentoyBootloaderRelease.
    console: Rich Console instance.

  Returns:
    True if the caller should stop cleanly (exit 0), False to continue.
  """
  if not needs_update and not force:
    console.print(
      f"  [bold green]✨ Ventoy bootloader is already up to date (v{rel.version})![/bold green]\n"
    )
    return True
  if check_only:
    console.print(
      f"  [bold yellow]🔼 Ventoy v{rel.version} is available.[/bold yellow] "
      "[dim]Run 'ventoy upgrade' on Linux (or 'ventoy upgrade --livecd' on macOS) to update.[/dim]\n"
    )
    return True
  if not sys.platform.startswith("linux"):
    console.print(
      "  [bold yellow]💡 Native 'Ventoy2Disk -u' requires Linux (no official macOS block updater).[/bold yellow]\n"
      "  [dim]• Recommended: Plug this drive into a Linux machine and run 'ventoy upgrade'\n"
      "    (safe 10-second '-u' update — Partition 1 ISOs & files stay 100% untouched).\n"
      f"  • Optional on macOS: Run 'ventoy upgrade --livecd' to download '{rel.livecd_iso_name}'\n"
      "    into ISOs/ so you can boot and update Ventoy on any x86 PC.[/dim]\n"
    )
    return True
  return False


def handle_upgrade_command(args: argparse.Namespace) -> int:
  """Check and non-destructively upgrade the Ventoy bootloader on a USB drive.

  Args:
    args: Parsed CLI namespace.

  Returns:
    0 on success/up-to-date, 1 on failure.
  """
  ventoy_root = resolve_target_ventoy_dir(args.dir, CONSOLE)
  if ventoy_root is None:
    return 1

  try:
    with CONSOLE.status(
      "[bold cyan]Checking installed Ventoy bootloader & GitHub releases...[/bold cyan]"
    ):
      drive = inspect_ventoy_drive(ventoy_root)
      rel = resolve_ventoy_bootloader_release()
  except RuntimeError as exc:
    STDERR_CONSOLE.print(
      f"[bold red]❌ Failed to query Ventoy release:[/bold red] {exc}"
    )
    return 1

  needs_update = _render_bootloader_status_table(
    drive, rel, ventoy_root, console=CONSOLE
  )

  if getattr(args, "livecd", False):
    ok = _install_ventoy_livecd_iso(
      rel,
      ventoy_root,
      temp_dir=args.temp_dir,
      dry_run=args.dry_run,
      console=CONSOLE,
    )
    return 0 if ok else 1

  if _print_upgrade_status_only_notice(
    needs_update,
    bool(getattr(args, "force", False)),
    bool(args.check),
    rel,
    CONSOLE,
  ):
    return 0

  if (
    not args.yes
    and not args.dry_run
    and not _confirm_bootloader_upgrade(drive, rel, CONSOLE)
  ):
    return 0

  ok = _execute_linux_bootloader_upgrade(
    drive,
    rel,
    temp_dir=args.temp_dir,
    dry_run=args.dry_run,
    console=CONSOLE,
  )
  return 0 if ok else 1


# ==============================================================================
# 7. Subcommand Handlers ('update', 'add', 'list') & CLI Entrypoint
# ==============================================================================


def _matches_target_query(img: LocalImage, query: str) -> bool:
  """Check whether a LocalImage matches a user-supplied target filter token.

  Exact distro IDs (e.g. 'bazzite' vs 'bazzite-deck') match that specific ID;
  other tokens match substrings across filename, distro ID, and display name.

  Args:
    img: LocalImage record on the Ventoy drive.
    query: Lowercase filter string from CLI.

  Returns:
    True if img matches query.
  """
  if query in CATALOG_BY_ID:
    return img.distro_id == query
  display = (
    CATALOG_BY_ID[img.distro_id].display_name.lower()
    if img.distro_id in CATALOG_BY_ID
    else ""
  )
  return (
    query in img.path.name.lower()
    or query in img.rel_path.lower()
    or bool(img.distro_id and query in img.distro_id.lower())
    or (bool(display) and query in display)
  )


def _filter_local_images(
  images: list[LocalImage], filters: list[str]
) -> list[LocalImage]:
  """Filter discovered LocalImage entries by distro ID or filename substring.

  Args:
    images: All LocalImage items found on the Ventoy drive.
    filters: Optional CLI filter tokens.

  Returns:
    Filtered list of LocalImage items.
  """
  queries = [f.strip().lower() for f in filters if f.strip()]
  if not queries:
    return images
  return [
    img for img in images if any(_matches_target_query(img, q) for q in queries)
  ]


def _confirm_batch_update(
  outdated: list[ImageEvaluation], console: Console
) -> bool:
  """Prompt the user to confirm downloading and replacing outdated images.

  Args:
    outdated: Outdated image evaluations pending download.
    console: Rich console instance.

  Returns:
    True if the user confirmed, False otherwise.
  """
  total_dl = sum(ev.remote.size_bytes for ev in outdated if ev.remote)
  size_hint = f" (~{format_bytes(total_dl)})" if total_dl > 0 else ""
  try:
    confirmed = Confirm.ask(
      f"  Download and replace [bold yellow]{len(outdated)}[/bold yellow] "
      f"image(s){size_hint} 1-by-1?",
      console=console,
      default=True,
    )
  except (KeyboardInterrupt, EOFError):
    console.print("\n  [yellow]Cancelled.[/yellow]\n")
    return False
  if not confirmed:
    console.print("\n  [yellow]Update skipped.[/yellow]\n")
    return False
  console.print()
  return True


def handle_update_command(args: argparse.Namespace) -> int:
  """Scan a Ventoy directory 1-by-1 and update outdated OS images.

  Args:
    args: Parsed CLI arguments.

  Returns:
    0 on clean completion, 1 on missing directory or transfer error.
  """
  ventoy_root = resolve_target_ventoy_dir(args.dir, CONSOLE)
  if ventoy_root is None:
    return 1

  all_images = scan_ventoy_images(ventoy_root)
  images = _filter_local_images(all_images, args.targets or [])
  if not images:
    if all_images and args.targets:
      joined = ", ".join(args.targets)
      CONSOLE.print(
        f"\n  [yellow]No installed images in '{ventoy_root}' matched '{joined}'.[/yellow]\n"
        "  [dim]Tip: Run 'ventoy --check' to see installed images or 'ventoy add' to download a new distro.[/dim]\n"
      )
    else:
      CONSOLE.print(
        f"\n  [yellow]No .iso or .img files found in '{ventoy_root}'.[/yellow]\n"
        "  [dim]Tip: Run 'ventoy add' to download supported distributions onto this drive.[/dim]\n"
      )
    return 0

  manifest = load_manifest(ventoy_root)
  evaluations = [
    evaluate_local_image(img, manifest, ventoy_root, console=CONSOLE)
    for img in images
  ]

  if not args.targets:
    render_bootloader_banner(ventoy_root, console=CONSOLE)

  render_evaluations_table(
    ventoy_root,
    evaluations,
    console=CONSOLE,
    show_skipped=bool(getattr(args, "show_skipped", False)),
  )

  outdated = [
    ev
    for ev in evaluations
    if ev.status == ImageStatus.UPDATE_AVAILABLE and ev.remote is not None
  ]
  errors = [ev for ev in evaluations if ev.status == ImageStatus.ERROR]

  if not outdated:
    CONSOLE.print(
      "  [bold green]✨ All recognized Ventoy images are up to date![/bold green]\n"
    )
    return 1 if errors else 0

  if args.check:
    CONSOLE.print(
      f"  [bold yellow]🔼 {len(outdated)} update(s) available.[/bold yellow] "
      "[dim]Re-run without '--check' to download and replace.[/dim]\n"
    )
    return 0

  if (
    not args.yes
    and not args.dry_run
    and not _confirm_batch_update(outdated, CONSOLE)
  ):
    return 0

  all_ok = all(
    _execute_single_transfer(
      ev.local,
      ev.remote,  # type: ignore[arg-type]
      ventoy_root,
      manifest,
      temp_dir=args.temp_dir,
      dry_run=args.dry_run,
      console=CONSOLE,
    )
    for ev in outdated
  )
  return 0 if (all_ok and not errors) else 1


def _parse_catalog_selection(
  raw_input: str, specs: list[DistroSpec]
) -> list[DistroSpec]:
  """Parse numeric indices or distro IDs from user selection input.

  Args:
    raw_input: User-entered numbers or distro names (e.g. '1,3' or 'ubuntu-server').
    specs: Ordered list of DistroSpec options displayed to the user.

  Returns:
    Deduplicated list of selected DistroSpec entries.

  Raises:
    ValueError: On unrecognized token or out-of-range index.
  """
  cleaned = raw_input.strip()
  if not cleaned or cleaned.lower() in ("q", "quit", "none"):
    return []
  if cleaned.lower() == "all":
    return list(specs)

  selected: list[DistroSpec] = []
  seen: set[str] = set()
  for token in re.split(r"[\s,]+", cleaned):
    if not token:
      continue
    if token.isdigit():
      idx = int(token)
      if idx < 1 or idx > len(specs):
        raise ValueError(f"Selection '{idx}' is out of range (1-{len(specs)}).")
      spec = specs[idx - 1]
    elif token.lower() in CATALOG_BY_ID:
      spec = CATALOG_BY_ID[token.lower()]
    else:
      raise ValueError(
        f"Unknown distro '{token}'. Run 'ventoy list' to see valid IDs."
      )
    if spec.distro_id not in seen:
      seen.add(spec.distro_id)
      selected.append(spec)
  return selected


def _prompt_distro_add_selection(
  ventoy_root: Path,
  present_ids: set[str],
  console: Console,
) -> list[DistroSpec]:
  """Display supported distro catalog and prompt user which images to add.

  Args:
    ventoy_root: Target Ventoy directory.
    present_ids: Set of distro_ids already present on the drive.
    console: Rich Console instance.

  Returns:
    List of selected DistroSpec items (empty if cancelled).

  Raises:
    ValueError: If user enters invalid selection tokens.
  """
  specs = list(DISTRO_CATALOG)
  table = Table(
    title=f"📦 [bold cyan]Available Ventoy Distributions ({ventoy_root})[/bold cyan]",
    title_justify="left",
    box=box.ROUNDED,
    padding=(0, 2),
    header_style="bold white",
  )
  table.add_column("#", justify="right", style="bold cyan", no_wrap=True)
  table.add_column("Distro ID", style="bold white", no_wrap=True)
  table.add_column("Name", style="green", no_wrap=True)
  table.add_column("Tier", no_wrap=True)
  table.add_column("On Drive", no_wrap=True)
  table.add_column("Description", style="dim")

  for idx, spec in enumerate(specs, start=1):
    tier_badge = (
      "[bold cyan]Core[/bold cyan]"
      if spec.tier == "Core"
      else "[dim]Optional[/dim]"
    )
    installed_badge = (
      "[green]✅ Installed[/green]"
      if spec.distro_id in present_ids
      else "[dim]—[/dim]"
    )
    table.add_row(
      str(idx),
      spec.distro_id,
      spec.display_name,
      tier_badge,
      installed_badge,
      spec.description,
    )

  console.print()
  console.print(table)
  console.print()
  try:
    raw = Prompt.ask(
      "  Select distro # or ID(s) to download (e.g. [bold]1,2,3[/bold] or [bold]q[/bold] to cancel)",
      console=console,
      default="",
    )
  except (KeyboardInterrupt, EOFError):
    console.print("\n  [yellow]Cancelled.[/yellow]\n")
    return []
  return _parse_catalog_selection(raw, specs)


def handle_add_command(args: argparse.Namespace) -> int:
  """Download and add new supported distributions onto the Ventoy drive.

  Args:
    args: Parsed CLI namespace.

  Returns:
    0 on success or cancel, 1 on invalid selection or download failure.
  """
  ventoy_root = resolve_target_ventoy_dir(args.dir, CONSOLE)
  if ventoy_root is None:
    return 1

  existing_images = scan_ventoy_images(ventoy_root)
  existing_by_id = {
    img.distro_id: img for img in existing_images if img.distro_id
  }

  try:
    if args.distros:
      selected = _parse_catalog_selection(
        " ".join(args.distros), list(DISTRO_CATALOG)
      )
    else:
      selected = _prompt_distro_add_selection(
        ventoy_root, set(existing_by_id.keys()), console=CONSOLE
      )
  except ValueError as exc:
    STDERR_CONSOLE.print(f"[bold red]❌ Selection Error:[/bold red] {exc}")
    return 1

  if not selected:
    return 0

  manifest = load_manifest(ventoy_root)
  CONSOLE.print()
  all_ok = True
  for spec in selected:
    try:
      with CONSOLE.status(
        f"[bold cyan]Resolving latest {spec.display_name} release...[/bold cyan]"
      ):
        release = spec.resolver(spec.default_variant)
    except RuntimeError as exc:
      STDERR_CONSOLE.print(
        f"  [bold red]❌ Failed to resolve {spec.display_name}:[/bold red] {exc}\n"
      )
      all_ok = False
      continue

    old_img = existing_by_id.get(spec.distro_id)
    ok = _execute_single_transfer(
      old_img,
      release,
      ventoy_root,
      manifest,
      temp_dir=args.temp_dir,
      dry_run=args.dry_run,
      console=CONSOLE,
    )
    all_ok = all_ok and ok

  return 0 if all_ok else 1


def handle_list_command(args: argparse.Namespace) -> int:
  """Display supported distribution providers and optionally query live versions.

  Args:
    args: Parsed CLI namespace.

  Returns:
    0 on success, 1 if any live upstream lookup failed when '--live' is enabled.
  """
  specs = [s for s in DISTRO_CATALOG if args.all or s.tier == "Core"]
  table = Table(
    title="💿 [bold cyan]Supported Ventoy Distributions[/bold cyan]",
    title_justify="left",
    box=box.ROUNDED,
    padding=(0, 2),
    header_style="bold white",
  )
  table.add_column("Distro ID", style="bold cyan", no_wrap=True)
  table.add_column("Distribution", style="bold white")
  table.add_column("Tier", no_wrap=True)
  if args.live:
    table.add_column("Latest", style="green", no_wrap=True)
    table.add_column("Size", justify="right", style="magenta", no_wrap=True)
    table.add_column(
      "Upstream Filename", style="white", min_width=16, overflow="fold"
    )
  else:
    table.add_column("Description", style="dim")

  had_error = False
  for spec in specs:
    tier_str = (
      "[bold cyan]Core[/bold cyan]"
      if spec.tier == "Core"
      else "[dim]Optional[/dim]"
    )
    if not args.live:
      table.add_row(
        spec.distro_id, spec.display_name, tier_str, spec.description
      )
      continue

    try:
      with CONSOLE.status(
        f"[bold cyan]Querying {spec.display_name}...[/bold cyan]"
      ):
        rel = spec.resolver(spec.default_variant)
      table.add_row(
        spec.distro_id,
        spec.display_name,
        tier_str,
        rel.version,
        format_bytes(rel.size_bytes),
        rel.filename,
      )
    except RuntimeError as exc:
      had_error = True
      table.add_row(
        spec.distro_id,
        spec.display_name,
        tier_str,
        "[red]error[/red]",
        "—",
        f"[red]{exc}[/red]",
      )

  CONSOLE.print()
  CONSOLE.print(table)
  if not args.all:
    opt_count = sum(1 for s in DISTRO_CATALOG if s.tier != "Core")
    CONSOLE.print(
      f"  [dim]Showing {len(specs)} Core distros (+{opt_count} Optional with 'ventoy list --all'). "
      "Pass '--live' to query upstream versions.[/dim]\n"
    )
  else:
    CONSOLE.print()
  return 1 if had_error else 0


def _add_common_transfer_args(parser: argparse.ArgumentParser) -> None:
  """Attach shared Ventoy directory, staging, and confirmation flags.

  Args:
    parser: Target ArgumentParser instance.
  """
  parser.add_argument(
    "-d",
    "--dir",
    type=Path,
    default=None,
    help="Mounted Ventoy drive or ISO directory (auto-detects /Volumes/Ventoy or /run/media).",
  )
  parser.add_argument(
    "--temp-dir",
    type=Path,
    default=None,
    help="Explicit temporary staging directory (defaults to /tmp with ~/.cache fallback).",
  )
  parser.add_argument(
    "-n",
    "--dry-run",
    action="store_true",
    help="Preview downloads and replacements without modifying disk.",
  )
  parser.add_argument(
    "-y",
    "--yes",
    action="store_true",
    help="Skip interactive confirmation before downloading and replacing.",
  )


def build_parser() -> argparse.ArgumentParser:
  """Build the 'ventoy' subcommand CLI argument parser.

  Returns:
    Configured ArgumentParser instance.
  """
  parser = argparse.ArgumentParser(
    prog="ventoy",
    description=(
      "💾 Cross-platform Ventoy USB bootable ISO/IMG updater & distro manager "
      "(macOS & Linux)."
    ),
  )
  subparsers = parser.add_subparsers(dest="command", metavar="<subcommand>")

  # 1. update (default when bare 'ventoy' or 'ventoy /path/to/drive' is invoked)
  update_p = subparsers.add_parser(
    "update",
    help="Scan a Ventoy drive 1-by-1 and update outdated OS images (default).",
  )
  _add_common_transfer_args(update_p)
  update_p.add_argument(
    "-c",
    "--check",
    action="store_true",
    help="Check upstream versions and display status table without downloading.",
  )
  update_p.add_argument(
    "-s",
    "--show-skipped",
    action="store_true",
    help="Expand purely unmanaged external utility folders into full tables.",
  )
  update_p.add_argument(
    "targets",
    nargs="*",
    help="Optional distro ID(s) or filename substring(s) to check/update.",
  )

  # 2. add
  add_p = subparsers.add_parser(
    "add",
    help="Download and add supported distributions onto a Ventoy drive.",
  )
  _add_common_transfer_args(add_p)
  add_p.add_argument(
    "distros",
    nargs="*",
    help="Distro ID(s) to add (e.g. 'ubuntu-server debian-server'), or omit for interactive picker.",
  )

  # 3. list (alias: catalog)
  list_p = subparsers.add_parser(
    "list",
    aliases=["catalog"],
    help="List supported distributions (pass --live to query latest upstream versions).",
  )
  list_p.add_argument(
    "-a",
    "--all",
    action="store_true",
    help="Include Optional supported images (Bazzite, SteamOS Repair, etc.).",
  )
  list_p.add_argument(
    "-l",
    "--live",
    action="store_true",
    help="Query official upstream endpoints for live version numbers and sizes.",
  )

  # 4. upgrade (aliases: bootloader, self-update)
  upgrade_p = subparsers.add_parser(
    "upgrade",
    aliases=["bootloader", "self-update"],
    help="Check and non-destructively upgrade the Ventoy bootloader itself ('-u').",
  )
  _add_common_transfer_args(upgrade_p)
  upgrade_p.add_argument(
    "-c",
    "--check",
    action="store_true",
    help="Check installed vs. latest Ventoy bootloader version without modifying disk.",
  )
  upgrade_p.add_argument(
    "--livecd",
    action="store_true",
    help="Download official 'ventoy-X.Y.Z-livecd.iso' onto the stick (ideal on macOS).",
  )
  upgrade_p.add_argument(
    "--force",
    action="store_true",
    help="Re-apply non-destructive bootloader upgrade even if versions match.",
  )

  return parser


def normalize_cli_argv(raw_argv: list[str]) -> list[str]:
  """Normalize shorthand CLI invocations like 'ventoy /Volumes/Ventoy' into 'update'.

  Args:
    raw_argv: Argument list excluding sys.argv[0].

  Returns:
    Normalized argument list understood by build_parser().
  """
  if not raw_argv:
    return ["update"]
  if raw_argv[0] in ("-h", "--help"):
    return raw_argv
  if raw_argv[0] in SUBCOMMANDS:
    return raw_argv

  # Prepend default 'update' subcommand and promote a bare directory argument to '-d'
  normalized = ["update"]
  value_flags = {"-d", "--dir", "--temp-dir"}
  skip_next = False
  dir_assigned = any(
    tok in ("-d", "--dir") or tok.startswith("--dir=") for tok in raw_argv
  )

  for tok in raw_argv:
    if skip_next:
      normalized.append(tok)
      skip_next = False
      continue
    if tok in value_flags:
      normalized.append(tok)
      skip_next = True
      continue
    if not tok.startswith("-") and not dir_assigned:
      candidate = Path(tok).expanduser()
      is_path_arg = (
        "/" in tok
        or tok in (".", "..")
        or (candidate.is_dir() and tok.lower() not in CATALOG_BY_ID)
      )
      if is_path_arg:
        normalized.extend(["-d", tok])
        dir_assigned = True
        continue
    normalized.append(tok)
  return normalized


def main(argv: list[str] | None = None) -> int:
  """Entrypoint for the 'ventoy' CLI.

  Args:
    argv: Optional explicit CLI arguments (defaults to sys.argv[1:]).

  Returns:
    Process exit status code (0 on success, 1 on error).
  """
  parser = build_parser()
  effective_argv = normalize_cli_argv(
    sys.argv[1:] if argv is None else list(argv)
  )
  args = parser.parse_args(effective_argv)

  handlers = {
    "update": handle_update_command,
    "add": handle_add_command,
    "list": handle_list_command,
    "catalog": handle_list_command,
    "upgrade": handle_upgrade_command,
    "bootloader": handle_upgrade_command,
    "self-update": handle_upgrade_command,
  }
  handler = handlers.get(args.command, handle_update_command)
  return handler(args)


if __name__ == "__main__":
  sys.exit(main())
