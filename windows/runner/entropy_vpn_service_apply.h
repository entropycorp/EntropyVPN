#pragma once

#include <string>

#include "entropy_vpn_service_manifest.h"

namespace entropy_vpn_service {

// Applies a fully-staged update in place.
//
// `target`      - the manifest describing the desired final state.
// `install_dir` - the directory holding the running installation.
// `staging_dir` - the directory holding downloaded blobs (<sha256>.bin), one
//                 per file that differs from what is installed, plus the new
//                 manifest.json.
//
// On success, *service_restart_pending is set to true when the service
// executable itself was updated: the new binary has been staged as
// entropy_vpn_service.exe.new and entropy_vpn_updater.exe has been launched to
// finish the swap, so the caller must stop the service.
//
// On failure, any partial changes are rolled back and *error is set.
bool ApplyStagedUpdate(const ReleaseManifest& target,
                       const std::wstring& install_dir,
                       const std::wstring& staging_dir,
                       bool* service_restart_pending,
                       std::string* error);

}  // namespace entropy_vpn_service
