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

    let output = switch(toplevel, mode).await?;

    // The profile is already set, so an incompatible init is a completed update
    // that needs a reboot rather than a failure.
    let incompatible = output.status.code() == Some(INCOMPATIBLE_INIT);
    if !incompatible && !output.status.success() {
        // `switch-to-configuration` narrates its progress on stdout and only
        // reports the failure itself on stderr, so both are needed to say what
        // went wrong.
        bail!(
            "switch-to-configuration failed: {}",
            detail(&format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ))
        );
    }

    // `boot` only installs the generation, so nothing takes effect until the
    // machine reboots, whatever the incoming kernel looks like.
    let reboot_required =
        mode == "boot" || incompatible || crate::generations::reboot_required(toplevel);

    Ok(Activation {
        toplevel: toplevel.to_string_lossy().into_owned(),
        reboot_required,
    })
}

/// Run the generation's own `switch-to-configuration` outside this process's
/// cgroup.
///
/// The switch restarts every BlueOS unit, and this daemon is one of them. As a
/// plain child it is killed partway through its own switch, which leaves the
/// profile moved, the update unconfirmed and the request unanswered. A
/// transient unit is not part of this cgroup, so it runs to completion even when
/// the daemon restarting is what it is doing; `--wait` blocks until it ends so
/// the exit status still reaches the caller.
///
/// Output is captured through `StandardOutput=file:` rather than `--pipe`.
/// `--pipe` hands the unit's streams to this process, so killing this process
/// would kill the switch — exactly the coupling being removed. The files are
/// created by systemd, which also means they survive this process going away
/// mid-switch.
///
/// The PATH is forwarded explicitly. A transient unit otherwise starts with
/// systemd's own default, which lacks coreutils, and the rollback pre-switch
/// check runs `readlink` before it does anything else.
async fn switch(toplevel: &Path, mode: &str) -> anyhow::Result<std::process::Output> {
    let capture = std::env::temp_dir().join(format!(
        "blueos-activate-{}-{}",
        std::process::id(),
        jiff::Timestamp::now().as_nanosecond()
    ));
    let stdout_path = capture.with_extension("out");
    let stderr_path = capture.with_extension("err");

    let status = Command::new("systemd-run")
        .args([
            "--quiet",
            "--collect",
            "--wait",
            "--service-type=oneshot",
            // The switch runs as root and restarts system units, so it must not
            // be scoped to the caller's session.
            "--system",
            "--description=BlueOS update activation",
            // A switch that hangs must not hold the request open forever.
            "--property=TimeoutStartSec=15min",
        ])
        .arg(format!(
            "--setenv=PATH={}",
            std::env::var("PATH").unwrap_or_else(|_| "/run/current-system/sw/bin".to_string())
        ))
        .arg(format!(
            "--property=StandardOutput=file:{}",
            stdout_path.display()
        ))
        .arg(format!(
            "--property=StandardError=file:{}",
            stderr_path.display()
        ))
        .arg(toplevel.join("bin/switch-to-configuration"))
        .arg(mode)
        .status()
        .await
        .context("systemd-run could not be started")?;

    let stdout = std::fs::read(&stdout_path).unwrap_or_default();
    let stderr = std::fs::read(&stderr_path).unwrap_or_default();
    let _ = std::fs::remove_file(&stdout_path);
    let _ = std::fs::remove_file(&stderr_path);

    Ok(std::process::Output {
        status,
        stdout,
        stderr,
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
