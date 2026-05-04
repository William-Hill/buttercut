use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use once_cell::sync::OnceCell;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::Emitter;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};
use tokio::time::timeout;

static SIDECAR: OnceCell<Sidecar> = OnceCell::new();

const CALL_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug)]
pub enum SidecarError {
    NotStarted,
    Io(std::io::Error),
    Serde(serde_json::Error),
    Rpc { code: i64, message: String },
    Closed,
    Timeout,
}

impl fmt::Display for SidecarError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SidecarError::NotStarted => write!(f, "sidecar not started"),
            SidecarError::Io(e) => write!(f, "sidecar io: {e}"),
            SidecarError::Serde(e) => write!(f, "sidecar serde: {e}"),
            SidecarError::Rpc { code, message } => write!(f, "sidecar rpc {code}: {message}"),
            SidecarError::Closed => write!(f, "sidecar pipe closed"),
            SidecarError::Timeout => write!(f, "sidecar call timed out"),
        }
    }
}

impl std::error::Error for SidecarError {}

impl From<std::io::Error> for SidecarError {
    fn from(e: std::io::Error) -> Self { SidecarError::Io(e) }
}

impl From<serde_json::Error> for SidecarError {
    fn from(e: serde_json::Error) -> Self { SidecarError::Serde(e) }
}

struct Sidecar {
    stdin: Mutex<ChildStdin>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, SidecarError>>>>>,
    next_id: AtomicU64,
    _child: Child,
}

#[derive(Serialize)]
struct Request<'a> {
    jsonrpc: &'a str,
    id: u64,
    method: &'a str,
    params: Value,
}

#[derive(Deserialize)]
struct Response {
    id: Option<u64>,
    #[serde(default)]
    result: Option<Value>,
    #[serde(default)]
    error: Option<RpcError>,
}

#[derive(Deserialize)]
struct RpcError {
    code: i64,
    message: String,
}

#[derive(Deserialize)]
struct Notification {
    method: String,
    #[serde(default)]
    params: Value,
}

pub fn init(
    app: tauri::AppHandle,
    ruby_bin: PathBuf,
    sidecar_script: PathBuf,
    libraries_root: PathBuf,
) -> std::io::Result<()> {
    let mut child = Command::new(&ruby_bin)
        .arg(&sidecar_script)
        .arg(&libraries_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()?;

    let stdin = child.stdin.take().expect("stdin piped");
    let stdout = child.stdout.take().expect("stdout piped");

    let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, SidecarError>>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let pending_for_reader = pending.clone();
    let app_for_reader = app.clone();

    tokio::spawn(async move {
        let mut reader = BufReader::new(stdout).lines();
        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<Response>(&line) {
                        Ok(resp) if resp.id.is_some() => {
                            let id = resp.id.unwrap();
                            let mut map = pending_for_reader.lock().await;
                            if let Some(tx) = map.remove(&id) {
                                let payload = if let Some(err) = resp.error {
                                    Err(SidecarError::Rpc { code: err.code, message: err.message })
                                } else {
                                    Ok(resp.result.unwrap_or(Value::Null))
                                };
                                let _ = tx.send(payload);
                            }
                        }
                        _ => match serde_json::from_str::<Notification>(&line) {
                            Ok(n) => {
                                let job_id = n.params.get("job_id").and_then(|v| v.as_str()).unwrap_or("");
                                let event_name = if job_id.is_empty() {
                                    "sidecar-event".to_string()
                                } else {
                                    format!("sidecar-event:{job_id}")
                                };
                                let payload = serde_json::json!({ "method": n.method, "params": n.params });
                                if let Err(e) = app_for_reader.emit(&event_name, payload) {
                                    eprintln!("[sidecar] emit error: {e}");
                                }
                            }
                            Err(e) => {
                                eprintln!("[sidecar] parse error: {e}: {line}");
                            }
                        },
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    eprintln!("[sidecar] read error: {e}");
                    break;
                }
            }
        }
        let mut map = pending_for_reader.lock().await;
        for (_, tx) in map.drain() {
            let _ = tx.send(Err(SidecarError::Closed));
        }
    });

    let sidecar = Sidecar {
        stdin: Mutex::new(stdin),
        pending,
        next_id: AtomicU64::new(1),
        _child: child,
    };

    SIDECAR
        .set(sidecar)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::AlreadyExists, "sidecar already initialized"))?;
    Ok(())
}

pub async fn call(method: &str, params: Value) -> Result<Value, SidecarError> {
    let sidecar = SIDECAR.get().ok_or(SidecarError::NotStarted)?;

    let id = sidecar.next_id.fetch_add(1, Ordering::Relaxed);

    let (tx, rx) = oneshot::channel();
    {
        let mut map = sidecar.pending.lock().await;
        map.insert(id, tx);
    }

    let req = Request { jsonrpc: "2.0", id, method, params };
    let send_result: Result<(), SidecarError> = async {
        let mut line = serde_json::to_string(&req)?;
        line.push('\n');
        let mut stdin = sidecar.stdin.lock().await;
        stdin.write_all(line.as_bytes()).await?;
        stdin.flush().await?;
        Ok(())
    }
    .await;

    if let Err(err) = send_result {
        sidecar.pending.lock().await.remove(&id);
        return Err(err);
    }

    match timeout(CALL_TIMEOUT, rx).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(SidecarError::Closed),
        Err(_) => {
            sidecar.pending.lock().await.remove(&id);
            Err(SidecarError::Timeout)
        }
    }
}
