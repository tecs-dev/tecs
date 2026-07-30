//! The documentation site, which tealdoc renders from `tealdoc.site` in
//! `tlconfig.lua`.
//!
//! One program owns a module page: its Markdown title, the module prose from
//! Teal long doc comments, and the declaration reference. The gates that used
//! to hold two programs in step are the generator's own now, and run inside
//! the build: link and anchor validation is tealdoc's, and the site's
//! `before_build` hook holds the pages to `src/tecs/init.tl`.

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
        concat!(
            "HTTP/1.1 {} {}\r\n",
            "Content-Type: {}\r\n",
            "Content-Length: {}\r\n",
            "Cache-Control: no-store\r\n",
            "Connection: close\r\n\r\n"
        ),
        code,
        reason,
        kind,
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
    let site = scratch.path().join("site");
    build(root, &site)?;
    check_module_intro(root, &site)?;
    check_rendered_hierarchy(&site)?;
    check_rendered_writing(&site)?;
    println!("OK: the site builds, and every link and anchor in it resolves");
    Ok(())
}

/// Rejects generated prose that the source-page checks cannot see, including
/// declaration docs and Tealdoc's marker for an undocumented public item.
fn check_rendered_writing(site: &Path) -> Result<()> {
    for entry in WalkDir::new(site) {
        let entry = entry?;
        let path = entry.path();
        if !entry.file_type().is_file()
            || path.extension().and_then(|extension| extension.to_str()) != Some("md")
        {
            continue;
        }
        let text = fs::read_to_string(path)?;
        let mut property_heading = None;
        for (line_number, line) in text.lines().enumerate() {
            if line.contains('—') {
                anyhow::bail!("{}:{} uses an em dash", path.display(), line_number + 1);
            }
            if line.starts_with('|')
                && line
                    .split('|')
                    .nth(1)
                    .is_some_and(|cell| cell.trim().is_empty())
            {
                anyhow::bail!(
                    "{}:{} has a generated table row with an empty first cell",
                    path.display(),
                    line_number + 1
                );
            }
            if let Some(heading) = property_heading {
                if !line.trim().is_empty() {
                    let owned = ["Caller-writable.", "Read-only.", "Engine-owned."]
                        .iter()
                        .any(|prefix| line.starts_with(prefix));
                    if !owned {
                        anyhow::bail!(
                            "{}:{} documents a public field without an ownership prefix",
                            path.display(),
                            heading
                        );
                    }
                    property_heading = None;
                }
            }
            if line.starts_with('#')
                && (line.contains("tealdoc-kind-variable") || line.contains("tealdoc-kind-field"))
            {
                property_heading = Some(line_number + 1);
            }
        }
    }
    Ok(())
}

/// Requires module pages to keep one page title and a contiguous heading
/// hierarchy. Tealdoc rebases headings from module and symbol comments into
/// their rendered context, so a source `#` can never create a second page
/// title or skip from the page title to a deeper level.
fn check_rendered_hierarchy(site: &Path) -> Result<()> {
    let modules = site.join("modules");
    for entry in WalkDir::new(&modules) {
        let entry = entry?;
        let path = entry.path();
        if !entry.file_type().is_file()
            || path.extension().and_then(|extension| extension.to_str()) != Some("md")
        {
            continue;
        }

        let text = fs::read_to_string(path)?;
        let mut in_fence = false;
        let mut h1_count = 0;
        let mut previous_level = None;
        for (line_number, line) in text.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence {
                continue;
            }

            let hashes = trimmed.bytes().take_while(|byte| *byte == b'#').count();
            if hashes == 0 || hashes > 6 || trimmed.as_bytes().get(hashes).copied() != Some(b' ') {
                continue;
            }
            if hashes == 1 {
                h1_count += 1;
            }
            if let Some(previous) = previous_level {
                if hashes > previous + 1 {
                    anyhow::bail!(
                        "{}:{} skips from H{} to H{}",
                        path.display(),
                        line_number + 1,
                        previous,
                        hashes
                    );
                }
            } else if hashes != 1 {
                anyhow::bail!(
                    "{}:{} starts its hierarchy at H{}",
                    path.display(),
                    line_number + 1,
                    hashes
                );
            }
            previous_level = Some(hashes);
        }
        if h1_count != 1 {
            anyhow::bail!(
                "{} has {h1_count} H1 headings; module pages require exactly one",
                path.display()
            );
        }
    }
    Ok(())
}

/// Holds Tealdoc's three module-documentation handoffs together: the parser
/// reads the file-leading long comment, the projected public view retains it,
/// and the site places it ahead of the symbol summary.
fn check_module_intro(root: &Path, site: &Path) -> Result<()> {
    let source_path = root.join("src/tecs/io/files/init.tl");
    let source = fs::read_to_string(&source_path)?;
    let equals = source
        .strip_prefix("--[")
        .and_then(|rest| rest.find('[').map(|end| &rest[..end]))
        .filter(|value| value.chars().all(|character| character == '='))
        .with_context(|| {
            format!(
                "{} does not start with a long module doc comment",
                source_path.display()
            )
        })?;
    let opening = 4 + equals.len();
    let closing = format!("]{}]", equals);
    let end = source[opening..]
        .find(&closing)
        .map(|offset| opening + offset)
        .with_context(|| {
            format!(
                "{} has an unterminated module doc comment",
                source_path.display()
            )
        })?;
    let first_line = source[opening..end]
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(str::trim)
        .context("the filesystem module doc comment has no prose")?;

    let output_path = site.join("modules/io/files.md");
    let output = fs::read_to_string(&output_path)?;
    let introduction = output.find(first_line).with_context(|| {
        format!(
            "{} omits the module prose from {}",
            output_path.display(),
            source_path.display()
        )
    })?;
    let contents = output.find("## Module contents").with_context(|| {
        format!(
            "{} does not place its API summary in Module contents",
            output_path.display()
        )
    })?;
    let summary = ["**Types**", "**Functions**", "**Values**"]
        .into_iter()
        .filter_map(|heading| output.find(heading))
        .min()
        .with_context(|| format!("{} has no API summary", output_path.display()))?;
    if introduction > contents || contents > summary {
        anyhow::bail!(
            "{} does not order module prose, Module contents and its API summary",
            output_path.display()
        );
    }
    let function_summary = output
        .find("**Functions**")
        .with_context(|| format!("{} has no function summary", output_path.display()))?;
    let type_summary = output
        .find("**Types**")
        .with_context(|| format!("{} has no type summary", output_path.display()))?;
    if function_summary > type_summary {
        anyhow::bail!(
            "{} places the type summary before the function summary",
            output_path.display()
        );
    }
    let functions = output
        .find("\n## Functions\n")
        .with_context(|| format!("{} has no function details", output_path.display()))?;
    let types = output
        .find("\n## Types\n")
        .with_context(|| format!("{} has no type details", output_path.display()))?;
    if functions > types {
        anyhow::bail!(
            "{} places type details before function details",
            output_path.display()
        );
    }
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
