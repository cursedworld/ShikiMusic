use std::sync::Mutex;

pub use crate::api::types::RPCActivity;
use discord_rich_presence::{
    activity::{Activity, Button, Timestamps},
    DiscordIpc, DiscordIpcClient,
};
use lazy_static::lazy_static;

use super::types::ActivityType;

lazy_static! {
    static ref DISCORD_CLIENT: Mutex<Option<Box<DiscordIpcClient>>> = Mutex::new(None);
}

pub fn discord_init(client_id: String) -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();
    *client = Some(Box::new(
        DiscordIpcClient::new(client_id.as_str())
            .map_err(|_| anyhow::anyhow!("Failed to create IPC client"))?,
    ));

    Ok(())
}

pub fn discord_connect() -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();

    let res = client
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("IPC client not initialized"))?
        .connect()
        .map_err(|e| anyhow::anyhow!("Failed to connect to Discord IPC: {:?}", e));

    res
}

pub fn discord_reconnect() -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();
    let res = client
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("IPC client not initialized"))?
        .reconnect()
        .map_err(|e| anyhow::anyhow!("Failed to reconnect to Discord IPC: {:?}", e));

    res
}

pub fn discord_close() -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();
    let res = client
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("IPC client not initialized"))?
        .close()
        .map_err(|e| anyhow::anyhow!("Failed to close to Discord IPC: {:?}", e));

    res
}

pub fn discord_clear_activity() -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();
    let res = client
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("IPC client not initialized"))?
        .clear_activity()
        .map_err(|e| anyhow::anyhow!("Failed to clear presence: {:?}", e));

    res
}

pub fn discord_set_activity(activity: RPCActivity) -> anyhow::Result<()> {
    let activity_payload = build_activity_payload(&activity)?;
    let command = serde_json::json!({
        "cmd": "SET_ACTIVITY",
        "args": {
            "pid": std::process::id(),
            "activity": activity_payload,
        },
        "nonce": uuid::Uuid::new_v4().to_string(),
    });
    let mut client = DISCORD_CLIENT.lock().unwrap();

    // Keep the upstream IPC envelope; add Discord's member-list display field
    // without changing the Flutter/Rust bridge ABI or dropping rich presence.
    client
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("IPC client not initialized"))?
        .send(command, 1)
        .map_err(|e| anyhow::anyhow!("Failed to set presence: {:?}", e))?;

    Ok(())
}

fn build_activity_payload(activity: &RPCActivity) -> anyhow::Result<serde_json::Value> {
    let mut r_activity = Activity::new();

    if let Some(state) = &activity.state {
        r_activity = r_activity.state(state.as_str());
    }

    if let Some(details) = &activity.details {
        r_activity = r_activity.details(details.as_str());
    }

    if let Some(timestamps) = &activity.timestamps {
        let mut r_timestamps = Timestamps::new();

        if let Some(start) = timestamps.start {
            r_timestamps = r_timestamps.start(start);
        }
        if let Some(end) = timestamps.end {
            r_timestamps = r_timestamps.end(end);
        }

        r_activity = r_activity.timestamps(r_timestamps);
    }

    if let Some(party) = &activity.party {
        let mut r_party = discord_rich_presence::activity::Party::new();

        if let Some(id) = &party.id {
            r_party = r_party.id(id.as_str());
        }

        if let Some(size) = &party.size {
            r_party = r_party.size(*size);
        }

        r_activity = r_activity.party(r_party);
    }

    if let Some(assets) = &activity.assets {
        let mut r_assets = discord_rich_presence::activity::Assets::new();

        if let Some(large_image) = &assets.large_image {
            r_assets = r_assets.large_image(large_image.as_str());
        }

        if let Some(large_text) = &assets.large_text {
            r_assets = r_assets.large_text(large_text.as_str());
        }

        if let Some(small_image) = &assets.small_image {
            r_assets = r_assets.small_image(small_image.as_str());
        }

        if let Some(small_text) = &assets.small_text {
            r_assets = r_assets.small_text(small_text.as_str());
        }

        r_activity = r_activity.assets(r_assets);
    }

    if let Some(secrets) = &activity.secrets {
        let mut r_secrets = discord_rich_presence::activity::Secrets::new();

        if let Some(join) = &secrets.join {
            r_secrets = r_secrets.join(join.as_str());
        }

        if let Some(spectate) = &secrets.spectate {
            r_secrets = r_secrets.spectate(spectate.as_str());
        }

        if let Some(match_str) = &secrets.match_str {
            r_secrets = r_secrets.r#match(match_str.as_str());
        }

        r_activity = r_activity.secrets(r_secrets);
    }

    if let Some(buttons) = &activity.buttons {
        let mut r_buttons = Vec::<Button>::new();

        for button in buttons {
            r_buttons.push(Button::new(button.label.as_str(), button.url.as_str()));
        }

        r_activity = r_activity.buttons(r_buttons);
    }

    if let Some(activity_type) = &activity.activity_type {
        r_activity = r_activity.activity_type(match activity_type {
            ActivityType::Playing => discord_rich_presence::activity::ActivityType::Playing,
            ActivityType::Listening => discord_rich_presence::activity::ActivityType::Listening,
            ActivityType::Watching => discord_rich_presence::activity::ActivityType::Watching,
            ActivityType::Competing => discord_rich_presence::activity::ActivityType::Competing,
        });
    }

    let mut payload = serde_json::to_value(r_activity)?;
    if matches!(activity.activity_type, Some(ActivityType::Listening)) {
        payload["status_display_type"] = serde_json::json!(2);
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::types::{RPCButton, RPCTimestamps};

    fn listening_activity() -> RPCActivity {
        RPCActivity {
            state: Some("Current lyric line".to_owned()),
            details: Some("Song — Artist".to_owned()),
            timestamps: Some(RPCTimestamps {
                start: Some(1_000),
                end: Some(2_000),
            }),
            party: None,
            assets: None,
            secrets: None,
            buttons: Some(vec![RPCButton {
                label: "GitHub".to_owned(),
                url: "https://github.com/cursedworld/ShikiMusic".to_owned(),
            }]),
            activity_type: Some(ActivityType::Listening),
        }
    }

    #[test]
    fn listening_status_uses_details_and_preserves_card_fields() {
        let payload = build_activity_payload(&listening_activity()).unwrap();
        assert_eq!(payload["type"], 2);
        assert_eq!(payload["status_display_type"], 2);
        assert_eq!(payload["details"], "Song — Artist");
        assert_eq!(payload["state"], "Current lyric line");
        assert_eq!(payload["timestamps"]["end"], 2_000);
        assert_eq!(payload["buttons"][0]["label"], "GitHub");
    }

    #[test]
    fn other_activity_types_keep_their_default_display() {
        let mut activity = listening_activity();
        activity.activity_type = Some(ActivityType::Playing);
        let payload = build_activity_payload(&activity).unwrap();
        assert_eq!(payload["type"], 0);
        assert!(payload.get("status_display_type").is_none());
    }
}

pub fn discord_dispose() -> anyhow::Result<()> {
    let mut client = DISCORD_CLIENT.lock().unwrap();
    *client = None;

    Ok(())
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}
