//! The documentation site, which tealdoc renders from `tealdoc.site` in
//! `tlconfig.lua`.
//!
//! One program owns both halves of a page: the prose above the page's
//! `<!-- @generated` marker and the reference rendered from the modules the
//! page names. The gates that used to hold two programs in step are the
//! generator's own now, and run inside the build: link and anchor validation
//! is tealdoc's, and the site's `before_build` hook holds the pages to
//! `src/tecs/init.tl`.

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use walkdir::WalkDir;

/// Where a rendered site lands, relative to the repository root.
pub const OUTPUT: &str = "out/docs";

/// The site generator, which has to run under LuaJIT with the vendored
/// `package.cpath`: it needs `lfs`, and the system Lua 5.1 on macOS carries an
/// `lfs.so` that fails to load. The wrapper luarocks installs beside the rock
/// is what sets both, so nothing here invokes the script directly.
fn generator(root: &Path) -> Result<PathBuf> {
    let tealdoc = root.join("vendor/bin/tealdoc");
    if !tealdoc.is_file() {
        anyhow::bail!(
            "{} is missing; run `cargo xtask dev-tools` inside this worktree",
            tealdoc.display()
        );
    }
    Ok(tealdoc)
}

/// Renders the site into `output`, replacing whatever was there.
///
/// The render lands in a directory of its own and is swapped in, so a build
/// that fails leaves the last one that worked in place rather than half a
/// site, and a renamed page cannot leave its old output behind.
pub fn build(root: &Path, output: &Path) -> Result<()> {
    let staging = output.with_extension("next");
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    if let Some(parent) = staging.parent() {
        fs::create_dir_all(parent)?;
    }
    let status = Command::new(generator(root)?)
        .arg("site")
        .arg("--output")
        .arg(&staging)
        .current_dir(root)
        .status()
        .context("running tealdoc")?;
    if !status.success() {
        anyhow::bail!("tealdoc exited with {status}");
    }
    if output.exists() {
        fs::remove_dir_all(output)?;
    }
    fs::rename(&staging, output)?;
    Ok(())
}

/// Builds the site, serves it, and rebuilds when a page, a documented module
/// or the site configuration changes.
///
/// Tealdoc has no watch mode of its own, and a whole-tree render costs a few
/// seconds, so this polls rather than holding a file-system watcher open. The
/// browser is not reloaded: a rebuild finishes before a hand reaches the
/// keyboard, so refreshing is the whole of the workflow.
pub fn serve(root: &Path, port: u16) -> Result<()> {
    let output = root.join(OUTPUT);
    build(root, &output)?;

    let listener = TcpListener::bind(("127.0.0.1", port))
        .with_context(|| format!("listening on port {port}"))?;
    println!();
    println!("  Serving {OUTPUT} at http://localhost:{port}/");
    println!("  Rebuilding on a change under docs/ or src/. Ctrl-C to stop.");
    println!();

    let served = output.clone();
    thread::spawn(move || {
        for connection in listener.incoming().flatten() {
            let root = served.clone();
            thread::spawn(move || {
                let _ = respond(&root, connection);
            });
        }
    });

    let mut previous = fingerprint(root)?;
    loop {
        thread::sleep(Duration::from_secs(1));
        let current = fingerprint(root)?;
        if current == previous {
            continue;
        }
        previous = current;
        println!("  rebuilding");
        // A build that fails leaves the last good output being served, so an
        // unfinished edit does not take the site down while it is being made.
        if let Err(error) = build(root, &output) {
            println!("  {error}");
            println!("  the served site is the last one that built");
        }
    }
}

/// Everything the render reads, as a path to its modification time. `src` is
/// in here because a page's reference comes out of it, so editing a docblock
/// is editing the site.
fn fingerprint(root: &Path) -> Result<BTreeMap<PathBuf, SystemTime>> {
    let mut seen = BTreeMap::new();
    for directory in ["docs", "src"] {
        for entry in WalkDir::new(root.join(directory)) {
            let entry = entry?;
            if !entry.file_type().is_file() {
                continue;
            }
            let watched = matches!(
                entry.path().extension().and_then(|value| value.to_str()),
                Some("md" | "tl" | "css")
            );
            if watched {
                seen.insert(entry.path().to_path_buf(), entry.metadata()?.modified()?);
            }
        }
    }
    let config = root.join("tlconfig.lua");
    seen.insert(config.clone(), fs::metadata(config)?.modified()?);
    Ok(seen)
}

/// Answers one request out of the rendered site.
///
/// A route is a clean URL, so a path naming a directory is that directory's
/// `index.html` and an extensionless path that is not a file is tried as one
/// too. Anything reaching outside the output is refused rather than resolved.
fn respond(output: &Path, mut connection: TcpStream) -> Result<()> {
    let mut request = String::new();
    BufReader::new(connection.try_clone()?).read_line(&mut request)?;
    let mut fields = request.split_whitespace();
    let method = fields.next().unwrap_or_default();
    let target = fields.next().unwrap_or("/");
    if method != "GET" && method != "HEAD" {
        return reply(&mut connection, 405, "text/plain", b"method not allowed");
    }
    let route = target.split(['?', '#']).next().unwrap_or("/");
    let Some(path) = resolve(output, route) else {
        return reply(&mut connection, 404, "text/plain", b"not found");
    };
    let body = fs::read(&path)?;
    let kind = match path.extension().and_then(|value| value.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json",
        Some("md" | "txt") => "text/plain; charset=utf-8",
        Some("xml") => "application/xml",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("ico") => "image/x-icon",
        _ => "application/octet-stream",
    };
    reply(&mut connection, 200, kind, &body)
}

fn resolve(output: &Path, route: &str) -> Option<PathBuf> {
    let relative = Path::new(route.trim_start_matches('/'));
    if relative
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
    {
        return None;
    }
    let candidate = output.join(relative);
    if candidate.is_file() {
        return Some(candidate);
    }
    let index = candidate.join("index.html");
    index.is_file().then_some(index)
}

fn reply(connection: &mut TcpStream, code: u16, kind: &str, body: &[u8]) -> Result<()> {
    let reason = if code == 200 { "OK" } else { "Error" };
    write!(
        connection,
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    connection.write_all(body)?;
    connection.flush()?;
    Ok(())
}

/// The documentation gate.
///
/// Two things, and the second is the render itself. Every page carries a
/// one-line `description:`, which nothing else can see because it is
/// frontmatter rather than content. Everything else the gate used to hold is
/// the generator's now and fails the build it runs in: the site's
/// `before_build` hook holds the pages to `src/tecs/init.tl`, and tealdoc
/// validates every link and anchor over the HTML it just wrote.
pub fn check(root: &Path) -> Result<()> {
    check_descriptions(root)?;
    let scratch = tempfile::Builder::new().prefix("tecs-docs.").tempdir()?;
    build(root, &scratch.path().join("site"))?;
    println!("OK: the site builds, and every link and anchor in it resolves");
    Ok(())
}

/// Requires a one-line `description:` on every page, which is what labels a
/// page in the site's navigation and in a search result.
fn check_descriptions(root: &Path) -> Result<()> {
    let script = root.join("scripts/check-docs-descriptions.sh");
    let status = Command::new("bash")
        .arg(&script)
        .current_dir(root)
        .status()
        .with_context(|| format!("running {}", script.display()))?;
    if !status.success() {
        anyhow::bail!("documentation description check exited with {status}");
    }
    Ok(())
}
