//! NixOS generations of the system profile: what "a BlueOS version" means on
//! this system.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

pub(crate) const PROFILE_DIR: &str = "/nix/var/nix/profiles";
pub(crate) const SYSTEM_PROFILE: &str = "/nix/var/nix/profiles/system";
pub(crate) const CURRENT_SYSTEM: &str = "/run/current-system";
pub(crate) const BOOTED_SYSTEM: &str = "/run/booted-system";
pub(crate) const KNOWN_GOOD_ROOT: &str = "/nix/var/nix/gcroots/blueos/known-good";

/// `etc/blueos/release.json`, written by modules/blueos/version.nix. Every
/// generation carries its own copy, so a generation answers which BlueOS it is
/// without evaluating any Nix.
#[derive(Deserialize, Clone)]
pub(crate) struct Release {
    pub(crate) version: String,
    #[serde(default)]
    pub(crate) revision: String,
    #[serde(default)]
    pub(crate) channel: String,
}

/// A generation as the API reports it.
#[derive(Clone, Serialize, ToSchema)]
pub(crate) struct GenerationInfo {
    /// Generation number from `system-<n>-link`.
    pub(crate) generation: u32,
    /// Store path of the system closure. Two builds of one version differ here.
    pub(crate) toplevel: String,
    pub(crate) version: String,
    pub(crate) channel: String,
    pub(crate) revision: String,
    /// When the generation link was created.
    pub(crate) created: Timestamp,
    /// Whether this is what the system is running right now.
    pub(crate) current: bool,
    /// Whether the rollback machinery recorded this generation as healthy.
    pub(crate) known_good: bool,
    /// Whether the kernel and initrd match what the machine booted, which is
    /// what decides if activating this generation needs a reboot.
    pub(crate) reboot_required: bool,
}

#[derive(Clone)]
pub(crate) struct Generation {
    pub(crate) id: u32,
    pub(crate) toplevel: PathBuf,
    pub(crate) release: Option<Release>,
    pub(crate) created: Timestamp,
}

impl Generation {
    pub(crate) fn version(&self) -> String {
        self.release
            .as_ref()
            .map(|release| release.version.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }
}

pub(crate) fn read_release(toplevel: &Path) -> Option<Release> {
    let raw = fs::read_to_string(toplevel.join("etc/blueos/release.json")).ok()?;
    serde_json::from_str(&raw).ok()
}

/// The link's own mtime, which is when the generation was created. The store
/// path's mtime is normalised to the epoch, so following the symlink would date
/// every generation to 1970.
fn created(path: &Path) -> anyhow::Result<Timestamp> {
    let meta = fs::symlink_metadata(path).context("generation link is unreadable")?;
    let modified = meta.modified().context("generation link has no mtime")?;
    Ok(Timestamp::try_from(modified)?)
}

fn read_generation(id: u32, link: &Path) -> anyhow::Result<Generation> {
    let toplevel = fs::canonicalize(link).context("generation link is broken")?;
    Ok(Generation {
        id,
        release: read_release(&toplevel),
        created: created(link)?,
        toplevel,
    })
}

/// Every generation on the profile, newest first. Reading the links rather than
/// asking nix-env keeps this working without taking the profile lock.
pub(crate) fn all() -> anyhow::Result<Vec<Generation>> {
    let entries = fs::read_dir(PROFILE_DIR).context("cannot read the profile directory")?;

    let mut links: Vec<(u32, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_str()?;
            let id = name.strip_prefix("system-")?.strip_suffix("-link")?;
            Some((id.parse::<u32>().ok()?, entry.path()))
        })
        .collect();
    links.sort_by_key(|(id, _)| std::cmp::Reverse(*id));

    Ok(links
        .into_iter()
        .filter_map(|(id, link)| read_generation(id, &link).ok())
        .collect())
}

pub(crate) fn find(id: u32) -> Option<Generation> {
    all().ok()?.into_iter().find(|item| item.id == id)
}

pub(crate) fn current_toplevel() -> Option<PathBuf> {
    fs::canonicalize(CURRENT_SYSTEM).ok()
}

pub(crate) fn known_good() -> Option<PathBuf> {
    fs::canonicalize(KNOWN_GOOD_ROOT).ok()
}

/// Whether activating `candidate` needs a reboot before it takes effect. Mirrors
/// what nixos-rebuild compares, plus the init interface version that
/// `switch-to-configuration` refuses to activate across.
pub(crate) fn reboot_required(candidate: &Path) -> bool {
    for file in ["kernel", "initrd", "kernel-modules"] {
        let new = fs::canonicalize(candidate.join(file));
        let booted = fs::canonicalize(Path::new(BOOTED_SYSTEM).join(file));
        if let (Ok(new), Ok(booted)) = (new, booted)
            && new != booted
        {
            return true;
        }
    }

    let new_interface = fs::read_to_string(candidate.join("init-interface-version"));
    let running_interface =
        fs::read_to_string(Path::new(CURRENT_SYSTEM).join("init-interface-version"));
    match (new_interface, running_interface) {
        (Ok(new), Ok(running)) => !new.is_empty() && new != running,
        _ => false,
    }
}

impl Generation {
    pub(crate) fn info(&self) -> GenerationInfo {
        let current = current_toplevel().as_deref() == Some(self.toplevel.as_path());
        let known_good = known_good().as_deref() == Some(self.toplevel.as_path());
        GenerationInfo {
            generation: self.id,
            toplevel: self.toplevel.to_string_lossy().into_owned(),
            version: self.version(),
            channel: self
                .release
                .as_ref()
                .map(|release| release.channel.clone())
                .unwrap_or_default(),
            revision: self
                .release
                .as_ref()
                .map(|release| release.revision.clone())
                .unwrap_or_default(),
            created: self.created,
            current,
            known_good,
            reboot_required: reboot_required(&self.toplevel),
        }
    }
}
