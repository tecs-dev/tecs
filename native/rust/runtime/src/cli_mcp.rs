//! An RMCP stdio server backed by a running game.
//!
//! The two protocol endpoints terminate independently. RMCP owns both the
//! agent-facing stdio lifecycle and the game's Streamable HTTP lifecycle,
//! while this module forwards the game's current tool surface between them.
//! A failed call drops the HTTP client and discovers again, so restarting a
//! game does not require restarting the invoking agent.

use std::env;
use std::time::Duration;

use rmcp::model::{
    CallToolRequestParams, CallToolResponse, Implementation, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerInfo,
};
use rmcp::service::{RequestContext, RunningService};
use rmcp::transport::streamable_http_client::StreamableHttpClientTransportConfig;
use rmcp::transport::{stdio, StreamableHttpClientTransport};
use rmcp::{serve_client, serve_server, ErrorData, RoleClient, RoleServer, ServerHandler};
use tokio::runtime::Builder;
use tokio::sync::Mutex;
use tokio::time::{sleep, timeout};

const DEFAULT_PORT: u16 = 19_999;
const PORT_COUNT: u16 = 3;
const CONNECT_TIMEOUT: Duration = Duration::from_millis(750);
const RETRY_DELAY: Duration = Duration::from_secs(1);

struct GameConnection {
    port: u16,
    service: RunningService<RoleClient, ()>,
}

#[derive(Default)]
struct Proxy {
    game: Mutex<Option<GameConnection>>,
}

fn base_port() -> u16 {
    env::var("TECS_MCP_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT)
}

fn candidate_ports(base: u16) -> impl Iterator<Item = u16> {
    (0..PORT_COUNT).filter_map(move |offset| base.checked_add(offset))
}

async fn connect_once(base: u16) -> Option<GameConnection> {
    for port in candidate_ports(base) {
        let url = format!("http://127.0.0.1:{port}/mcp");
        let config =
            StreamableHttpClientTransportConfig::with_uri(url).reinit_on_expired_session(true);
        let transport = StreamableHttpClientTransport::from_config(config);
        let connected = timeout(CONNECT_TIMEOUT, serve_client((), transport)).await;
        if let Ok(Ok(service)) = connected {
            eprintln!("[tecs mcp] Found game at port {port}");
            return Some(GameConnection { port, service });
        }
    }
    None
}

async fn discover() -> Result<GameConnection, ErrorData> {
    let base = base_port();
    eprintln!(
        "[tecs mcp] Scanning ports {base}-{}",
        base.saturating_add(PORT_COUNT - 1)
    );
    if let Some(game) = connect_once(base).await {
        return Ok(game);
    }

    // Keep the bridge useful when an agent and game are launched together and
    // the agent wins the startup race.
    sleep(RETRY_DELAY).await;
    connect_once(base).await.ok_or_else(|| {
        ErrorData::internal_error(
            format!(
                "No running Tecs game found on ports {base}-{}",
                base.saturating_add(PORT_COUNT - 1)
            ),
            None,
        )
    })
}

impl Proxy {
    async fn list_tools_from_game(
        &self,
        request: Option<PaginatedRequestParams>,
    ) -> Result<ListToolsResult, ErrorData> {
        let mut last_error = None;
        for attempt in 0..2 {
            let mut game = self.game.lock().await;
            if game.is_none() {
                *game = Some(discover().await?);
            }

            let connected = game.as_ref().expect("discovery installed a connection");
            match connected.service.peer().list_tools(request.clone()).await {
                Ok(result) => return Ok(result),
                Err(error) => {
                    last_error = Some(error.to_string());
                    eprintln!(
                        "[tecs mcp] Game at port {} became unavailable; rediscovering",
                        connected.port
                    );
                    game.take();
                }
            }
            drop(game);
            if attempt == 0 {
                sleep(RETRY_DELAY).await;
            }
        }
        Err(ErrorData::internal_error(
            format!(
                "Running Tecs game became unavailable: {}",
                last_error.unwrap_or_else(|| "connection closed".to_owned())
            ),
            None,
        ))
    }

    async fn call_tool_on_game(
        &self,
        request: CallToolRequestParams,
    ) -> Result<CallToolResponse, ErrorData> {
        let mut last_error = None;
        for attempt in 0..2 {
            let mut game = self.game.lock().await;
            if game.is_none() {
                *game = Some(discover().await?);
            }

            let connected = game.as_ref().expect("discovery installed a connection");
            match connected
                .service
                .peer()
                .call_tool_once(request.clone())
                .await
            {
                Ok(result) => return Ok(result),
                Err(error) => {
                    last_error = Some(error.to_string());
                    eprintln!(
                        "[tecs mcp] Game at port {} became unavailable; rediscovering",
                        connected.port
                    );
                    game.take();
                }
            }
            drop(game);
            if attempt == 0 {
                sleep(RETRY_DELAY).await;
            }
        }
        Err(ErrorData::internal_error(
            format!(
                "Running Tecs game became unavailable: {}",
                last_error.unwrap_or_else(|| "connection closed".to_owned())
            ),
            None,
        ))
    }
}

impl ServerHandler for Proxy {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("tecs", env!("CARGO_PKG_VERSION")))
    }

    async fn list_tools(
        &self,
        request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        self.list_tools_from_game(request).await
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        self.call_tool_on_game(request).await
    }
}

async fn run() -> Result<(), String> {
    let service = serve_server(Proxy::default(), stdio())
        .await
        .map_err(|error| format!("cannot start MCP on stdio: {error}"))?;
    service
        .waiting()
        .await
        .map_err(|error| format!("MCP stdio transport failed: {error}"))?;
    Ok(())
}

/// Runs the blocking stdio MCP proxy until its client closes the stream.
#[no_mangle]
pub extern "C" fn tecsCliMcp() -> i32 {
    let runtime = match Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("tecs mcp: cannot start the async runtime: {error}");
            return 1;
        }
    };
    match runtime.block_on(run()) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("tecs mcp: {error}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{candidate_ports, DEFAULT_PORT};

    #[test]
    fn discovers_three_ports_without_wrapping() {
        assert_eq!(
            candidate_ports(DEFAULT_PORT).collect::<Vec<_>>(),
            [19_999, 20_000, 20_001]
        );
        assert_eq!(candidate_ports(u16::MAX).collect::<Vec<_>>(), [u16::MAX]);
    }
}
