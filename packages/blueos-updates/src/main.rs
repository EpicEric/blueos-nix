//! BlueOS update daemon.
//!
//! Answers "which BlueOS is this, which ones can I go back to, and what can I
//! update to" for a system whose versions are NixOS generations rather than
//! container images. Everything here is a thin view over the system profile, so
//! a generation installed by `nixos-rebuild` or deploy-rs shows up exactly like
//! one the daemon installed itself.

mod apply;
mod config;
mod error;
mod generations;
mod manifest;

use std::future::Future;
use std::path::Path;

use actix_web::http::StatusCode;
use actix_web::{HttpResponse, delete, get, post, web};
use anyhow::Context;
use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use utoipa::{OpenApi, ToSchema};
use utoipa_actix_web::{AppExt, scope};

use crate::config::Config;
use crate::error::ApiError;
use crate::generations::GenerationInfo;

/// Where the rollback machinery records whether an activation was confirmed.
const STATE_FILE: &str = "/var/lib/blueos/updates/state.json";

#[derive(Debug, Default, Deserialize)]
pub(crate) struct ActivateParams {
    /// `switch` applies the generation now; `boot` installs it for the next boot.
    #[serde(default)]
    mode: ActivateMode,
}

#[derive(Debug, Default, Deserialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ActivateMode {
    /// Activate without rebooting, restarting the services whose units changed.
    #[default]
    Switch,
    /// Install the generation and reboot into it.
    Boot,
}

impl ActivateMode {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Switch => "switch",
            Self::Boot => "boot",
        }
    }
}

#[derive(Serialize, ToSchema)]
pub(crate) struct StatusResponse {
    /// The generation the system is running.
    current: GenerationInfo,
    /// The last generation that booted and passed its health check, which is
    /// what an automatic rollback would return to.
    known_good: Option<GenerationInfo>,
    /// What the system profile points at, when that is not what is running. An
    /// update installed with `boot` is in this state until the machine reboots.
    installed: Option<GenerationInfo>,
    /// An activation that has not confirmed itself yet. While this is set, the
    /// rollback timer is running.
    pending: Option<PendingActivation>,
    /// Whether a reboot is what stands between `installed` and `current`.
    reboot_required: bool,
    /// The generation that was running when an update failed and was rolled
    /// back. It is what the UI shows to explain why the version changed on its
    /// own; it stays set until the next activation.
    rolled_back_from: Option<String>,
    /// Output of the last activation's `switch-to-configuration`, which runs
    /// detached and so reports nothing through the request that started it.
    last_switch_log: Option<String>,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct PendingActivation {
    toplevel: String,
    mode: String,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct GenerationsResponse {
    generations: Vec<GenerationInfo>,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct ActivationResponse {
    toplevel: String,
    reboot_required: bool,
    message: String,
    /// Where the detached switch writes its progress. It is still running when
    /// this response is sent, so the outcome is read from `/status`.
    log: String,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct ReleasesResponse {
    releases: Vec<manifest::Release>,
    /// Why the release list is empty, when it is empty because something failed.
    error: Option<String>,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct DownloadResponse {
    toplevel: String,
    message: String,
}

/// What the rollback machinery knows, decoded from its state file.
#[derive(Deserialize, Default)]
struct RollbackState {
    pending: Option<String>,
    mode: Option<String>,
    #[serde(rename = "rolledBackFrom")]
    rolled_back_from: Option<String>,
}

fn rollback_state() -> RollbackState {
    std::fs::read_to_string(STATE_FILE)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

/// How much of the activation log is reported. The interesting part of a failed
/// switch is where it stopped, which is at the end.
const SWITCH_LOG_TAIL_BYTES: usize = 4096;

/// The tail of the last detached switch's output, so a failure that happened
/// after this daemon was restarted can still be explained.
fn switch_log() -> Option<String> {
    let raw = std::fs::read(apply::SWITCH_LOG).ok()?;
    let start = raw.len().saturating_sub(SWITCH_LOG_TAIL_BYTES);
    let text = String::from_utf8_lossy(&raw[start..]).trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// The running generation. It is normally one of the profile's own generations;
/// when it is not (an ad-hoc `nix-env --set`), it is reported anyway rather than
/// failing, since "what is running" still has a truthful answer.
fn current_generation() -> anyhow::Result<generations::Generation> {
    let toplevel = generations::current_toplevel().context("cannot resolve the running system")?;
    let mut generations = generations::all()?;

    if let Some(index) = generations
        .iter()
        .position(|generation| generation.toplevel == toplevel)
    {
        return Ok(generations.remove(index));
    }

    Ok(generations::Generation {
        id: 0,
        release: generations::read_release(&toplevel),
        created: Timestamp::now(),
        toplevel,
    })
}

#[utoipa::path(
    summary = "Current generation, rollback state and whether a reboot is pending",
    responses((status = 200, description = "Status", body = StatusResponse)),
    tag = "status",
)]
#[get("/status")]
async fn status() -> Result<HttpResponse, ApiError> {
    let current = current_generation()?;

    let known_good_id = generations::known_good_generation();

    let known_good = known_good_id
        .and_then(generations::find)
        .map(|generation| generation.info_with(known_good_id));

    // `nixos-rebuild boot` and the daemon's own `boot` mode move the profile
    // without changing what runs, so the two only differ while a reboot is owed.
    // A `switch` updates both, which is why comparing them is enough here: it
    // does not need the kernel comparison that deciding to reboot does.
    let installed = generations::profile_toplevel()
        .filter(|toplevel| *toplevel != current.toplevel)
        .and_then(|toplevel| {
            generations::all()
                .ok()?
                .into_iter()
                .find(|generation| generation.toplevel == toplevel)
        })
        .map(|generation| generation.info_with(known_good_id));

    let state = rollback_state();
    let pending = state.pending.map(|toplevel| PendingActivation {
        toplevel,
        mode: state.mode.unwrap_or_else(|| "switch".to_string()),
    });

    Ok(HttpResponse::Ok().json(StatusResponse {
        reboot_required: installed.is_some(),
        installed,
        current: current.info(),
        known_good,
        pending,
        rolled_back_from: state.rolled_back_from,
        last_switch_log: switch_log(),
    }))
}

#[utoipa::path(
    summary = "Every generation on the system profile, newest first",
    responses((status = 200, description = "Generations", body = GenerationsResponse)),
    tag = "generations",
)]
#[get("/generations")]
async fn list_generations() -> Result<HttpResponse, ApiError> {
    let known_good = generations::known_good_generation();
    let generations: Vec<GenerationInfo> = generations::all()?
        .iter()
        .map(|generation| generation.info_with(known_good))
        .collect();

    Ok(HttpResponse::Ok().json(GenerationsResponse { generations }))
}

#[utoipa::path(
    summary = "Activate a generation",
    description = "Switches the profile immediately and queues the activation. The switch \
                   restarts the daemon answering this request, so the response is sent before it \
                   runs; follow the outcome with GET /status, whose `pending` field is cleared \
                   only once the new generation confirmed itself.",
    params(
        ("generation" = u32, Path, description = "Generation number"),
        ("mode" = Option<ActivateMode>, Query, description = "`switch` applies the generation now; `boot` installs it for the next boot"),
    ),
    responses(
        (status = 202, description = "Activation queued", body = ActivationResponse),
        (status = 404, description = "No such generation", body = error::ErrorBody),
    ),
    tag = "generations",
)]
#[post("/generations/{generation}/activate")]
async fn activate_generation(
    generation: web::Path<u32>,
    params: web::Query<ActivateParams>,
) -> Result<HttpResponse, ApiError> {
    let number = generation.into_inner();
    let target = generations::find(number)
        .ok_or_else(|| ApiError::not_found(format!("there is no generation {number}")))?;

    let outcome = apply::activate(&target.toplevel, params.mode.as_str()).await?;

    Ok(HttpResponse::Accepted().json(ActivationResponse {
        toplevel: outcome.toplevel,
        reboot_required: outcome.reboot_required,
        message: if outcome.reboot_required {
            format!("Generation {number} is installed; reboot to boot into it.")
        } else {
            format!("Switching to generation {number}.")
        },
        log: outcome.log,
    }))
}

#[utoipa::path(
    summary = "Restart the running generation without changing it",
    responses(
        (status = 202, description = "Restart queued", body = ActivationResponse),
        (status = 500, description = "Activation failed", body = error::ErrorBody),
    ),
    tag = "status",
)]
#[post("/restart")]
async fn restart() -> Result<HttpResponse, ApiError> {
    let current = current_generation()?;
    let outcome = apply::activate(&current.toplevel, "switch").await?;

    Ok(HttpResponse::Accepted().json(ActivationResponse {
        toplevel: outcome.toplevel,
        reboot_required: outcome.reboot_required,
        message: "Restarting the BlueOS services.".to_string(),
        log: outcome.log,
    }))
}

#[utoipa::path(
    summary = "Delete a generation",
    params(("generation" = u32, Path, description = "Generation number")),
    responses(
        (status = 204, description = "Generation deleted"),
        (status = 404, description = "No such generation", body = error::ErrorBody),
        (status = 409, description = "Refused for the running or rollback generation", body = error::ErrorBody),
    ),
    tag = "generations",
)]
#[delete("/generations/{generation}")]
async fn delete_generation(generation: web::Path<u32>) -> Result<HttpResponse, ApiError> {
    let number = generation.into_inner();
    let target = generations::find(number)
        .ok_or_else(|| ApiError::not_found(format!("there is no generation {number}")))?;

    if generations::current_toplevel().as_deref() == Some(target.toplevel.as_path()) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            format!("generation {number} is running"),
        ));
    }
    if generations::known_good_generation() == Some(number) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            format!("generation {number} is the rollback target"),
        ));
    }

    apply::delete_generation(&number.to_string()).await?;
    Ok(HttpResponse::NoContent().finish())
}

#[utoipa::path(
    summary = "Published builds this vehicle can download",
    responses((status = 200, description = "Releases", body = ReleasesResponse)),
    tag = "releases",
)]
#[get("/releases")]
async fn list_releases(data: web::Data<AppState>) -> Result<HttpResponse, ApiError> {
    match data.releases().await {
        Ok(releases) => Ok(HttpResponse::Ok().json(ReleasesResponse {
            releases,
            error: None,
        })),
        // A vehicle that cannot reach the manifest still has generations to roll
        // back to, so an unreachable publisher is reported rather than fatal.
        Err(error) => Ok(HttpResponse::Ok().json(ReleasesResponse {
            releases: Vec::new(),
            error: Some(format!("{error:#}")),
        })),
    }
}

#[utoipa::path(
    summary = "Install a published build and activate it",
    params(
        ("version" = String, Path, description = "Version published in the manifest"),
        ("mode" = Option<ActivateMode>, Query, description = "`switch` applies the generation now; `boot` installs it for the next boot"),
    ),
    responses(
        (status = 202, description = "Activation queued", body = ActivationResponse),
        (status = 404, description = "Not published for this board", body = error::ErrorBody),
        (status = 502, description = "The manifest could not be read, or the build could not be downloaded", body = error::ErrorBody),
    ),
    tag = "releases",
)]
#[post("/releases/{version}/activate")]
async fn activate_release(
    version: web::Path<String>,
    params: web::Query<ActivateParams>,
    data: web::Data<AppState>,
) -> Result<HttpResponse, ApiError> {
    let version = version.into_inner();
    let target = published_release(&version, &data).await?;

    // Activation sets the profile to the store path directly, which is how a
    // downloaded build becomes a generation. Realising first means a closure
    // that is not in the cache fails before the profile moves.
    apply::realise(&target.toplevel).await?;
    let outcome = apply::activate(Path::new(&target.toplevel), params.mode.as_str()).await?;

    Ok(HttpResponse::Accepted().json(ActivationResponse {
        toplevel: outcome.toplevel,
        reboot_required: outcome.reboot_required,
        message: if outcome.reboot_required {
            format!("{version} is installed; reboot to boot into it.")
        } else {
            format!("Switching to {version}.")
        },
        log: outcome.log,
    }))
}

async fn published_release(version: &str, data: &AppState) -> Result<manifest::Release, ApiError> {
    let releases = data
        .releases()
        .await
        .map_err(|error| ApiError::bad_gateway(format!("{error:#}")))?;

    releases
        .into_iter()
        .find(|release| release.version == version)
        .ok_or_else(|| {
            ApiError::not_found(format!(
                "version {version} is not published for {}",
                data.board
            ))
        })
}

#[utoipa::path(
    summary = "Download a published build into the store",
    params(("version" = String, Path, description = "Version published in the manifest")),
    responses(
        (status = 200, description = "Downloaded", body = DownloadResponse),
        (status = 404, description = "Not published for this board", body = error::ErrorBody),
        (status = 502, description = "The manifest could not be read", body = error::ErrorBody),
    ),
    tag = "releases",
)]
#[post("/releases/{version}/download")]
async fn download_release(
    version: web::Path<String>,
    data: web::Data<AppState>,
) -> Result<HttpResponse, ApiError> {
    let version = version.into_inner();
    let target = published_release(&version, &data).await?;

    apply::realise(&target.toplevel).await?;

    Ok(HttpResponse::Ok().json(DownloadResponse {
        toplevel: target.toplevel,
        message: format!("Downloaded {version}."),
    }))
}

/// What the handlers need from the environment.
pub(crate) struct AppState {
    board: String,
    manifest_url: Option<String>,
}

impl AppState {
    fn new(config: &Config) -> Self {
        Self {
            board: config.board.clone(),
            manifest_url: config.manifest_url.clone(),
        }
    }

    fn releases(&self) -> impl Future<Output = anyhow::Result<Vec<manifest::Release>>> {
        manifest::releases(self.manifest_url.as_deref(), &self.board)
    }
}

#[derive(OpenApi)]
#[openapi(
    info(
        title = "BlueOS Updates",
        description = "On this system a BlueOS version is a NixOS generation. Activating one \
                       switches the system profile, and the rollback machinery protects the result.",
    ),
    tags(
        (name = "status", description = "What this vehicle is running"),
        (name = "generations", description = "Versions installed on the card"),
        (name = "releases", description = "Versions published for this board"),
    ),
    components(schemas(ActivateMode))
)]
struct ApiDoc;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let config = Config::from_env();
    eprintln!(
        "blueos-updates: serving {} for board {}",
        config.addr, config.board
    );

    let addr = config.addr;
    let data = web::Data::new(AppState::new(&config));

    actix_web::HttpServer::new(move || {
        let (app, openapi) = actix_web::App::new()
            .into_utoipa_app()
            .app_data(data.clone())
            .openapi(ApiDoc::openapi())
            .service(
                scope::scope("/v1.0")
                    .service(status)
                    .service(restart)
                    .service(list_generations)
                    .service(activate_generation)
                    .service(delete_generation)
                    .service(list_releases)
                    .service(activate_release)
                    .service(download_release),
            )
            .split_for_parts();

        app.wrap(actix_web::middleware::Logger::default()).service(
            utoipa_swagger_ui::SwaggerUi::new("/docs/{_:.*}")
                .url("/api-docs/openapi.json", openapi),
        )
    })
    .bind(addr)?
    .run()
    .await
}
