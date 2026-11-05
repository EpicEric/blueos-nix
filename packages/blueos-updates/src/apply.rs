//! Switching the running system to another generation, and fetching published
//! closures.
//!
//! Both go through the same commands `nixos-rebuild` uses, so the rollback
//! pre-switch check arms itself exactly as it does for a manual deploy; there is
//! deliberately no bookkeeping duplicated here.

use std::path::Path;
use std::process::ExitStatus;

use anyhow::{Context, bail};
use tokio::process::Command;

/// `switch-to-configuration` exits with this when the new generation's init is
/// incompatible with the running one: it is installed, but only takes effect
/// after a reboot.
const INCOMPATIBLE_INIT: i32 = 100;

pub(crate) struct Activation {
    pub(crate) toplevel: String,
    /// True when the generation cannot take effect until the machine reboots.
    pub(crate) reboot_required: bool,
}

/// Point the system profile at `toplevel` and activate it.
///
/// The order is the one nixos-rebuild uses: set the profile, then let the
/// generation activate itself. The rollback check compares the incoming
/// toplevel against the *running* system rather than the profile, so it still
/// arms despite the profile having already moved.
pub(crate) async fn activate(toplevel: &Path, mode: &str) -> anyhow::Result<Activation> {
    let (status, stderr) = run(
        Command::new("nix-env").args([
            "--profile",
            crate::generations::SYSTEM_PROFILE,
            "--set",
            &toplevel.to_string_lossy(),
        ]),
        "nix-env",
    )
    .await?;
    if !status.success() {
        bail!(
            "nix-env could not set the system profile: {}",
            detail(&stderr)
        );
    }

    let output = Command::new(toplevel.join("bin/switch-to-configuration"))
        .arg(mode)
        .output()
        .await
        .context("switch-to-configuration could not be started")?;

    // The profile is already set, so an incompatible init is a completed update
    // that needs a reboot rather than a failure.
    let incompatible = output.status.code() == Some(INCOMPATIBLE_INIT);
    if !incompatible && !output.status.success() {
        bail!(
            "switch-to-configuration failed: {}",
            detail(&String::from_utf8_lossy(&output.stderr))
        );
    }

    Ok(Activation {
        toplevel: toplevel.to_string_lossy().into_owned(),
        reboot_required: incompatible || crate::generations::reboot_required(toplevel),
    })
}

/// Substitute a published closure from the binary cache. This is the "download"
/// step: no Nix evaluation, just the store path the publisher recorded.
pub(crate) async fn realise(toplevel: &str) -> anyhow::Result<()> {
    let (status, stderr) = run(
        Command::new("nix-store").args(["--realise", toplevel]),
        "nix-store",
    )
    .await?;

    if !status.success() {
        bail!(
            "the published build is not available from the binary cache: {}",
            detail(&stderr)
        );
    }
    Ok(())
}

/// Drop a generation from the profile, which also deletes its store path if
/// nothing else refers to it. `nix-env` is the only writer of the profile, so
/// going through it keeps the numbering and the `system` link consistent.
pub(crate) async fn delete_generation(number: &str) -> anyhow::Result<()> {
    let (status, stderr) = run(
        Command::new("nix-env").args([
            "--profile",
            crate::generations::SYSTEM_PROFILE,
            "--delete-generations",
            number,
        ]),
        "nix-env",
    )
    .await?;

    if !status.success() {
        bail!(
            "nix-env could not delete generation {number}: {}",
            detail(&stderr)
        );
    }
    Ok(())
}

async fn run(command: &mut Command, name: &str) -> anyhow::Result<(ExitStatus, String)> {
    let output = command
        .output()
        .await
        .with_context(|| format!("{name} could not be started"))?;

    Ok((
        output.status,
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

/// Nix's own error text, or a placeholder when it said nothing.
fn detail(stderr: &str) -> String {
    let trimmed = stderr.trim();
    if trimmed.is_empty() {
        "no output".to_string()
    } else {
        trimmed.to_string()
    }
}
