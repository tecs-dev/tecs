use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};

use anyhow::{Context, Result};

/// Runs a child process with inherited output and a useful failure message.
pub fn run<I, S>(program: impl AsRef<OsStr>, args: I, directory: &Path) -> Result<()>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let program = program.as_ref();
    let status = Command::new(program)
        .args(args)
        .current_dir(directory)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("failed to start {}", program.to_string_lossy()))?;
    require_success(program, status)
}

fn require_success(program: &OsStr, status: ExitStatus) -> Result<()> {
    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("{} exited with {}", program.to_string_lossy(), status)
    }
}
