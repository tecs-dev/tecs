use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tecs_build_support::command;
use tecs_build_support::docs;
use tecs_build_support::formatting;
use tecs_build_support::nupp;
use tecs_build_support::package::{self, Preset};
use tecs_build_support::repository_root;

#[derive(Debug, Parser)]
#[command(name = "cargo xtask", about = "Build and maintain Tecs")]
struct Arguments {
    #[command(subcommand)]
    command: Task,
}

#[derive(Debug, Subcommand)]
enum Task {
    /// Install the development dependencies this checkout does not carry.
    Deps,
    /// List the manifest's configured targets and tasks.
    Targets,
    /// Type-check every Nupp source under the manifest's include roots.
    Check,
    /// Build native services and require all Nupp tests to pass without skips.
    Test,
    /// Build one configured target.
    Build {
        #[arg(long, default_value = nupp::DEFAULT_TARGET)]
        target: String,
    },
    /// Build a component target and run it through the Rust host.
    Run {
        #[arg(default_value = nupp::DEFAULT_COMPONENT)]
        target: String,
        /// The exported session constructor, defaulting to `<target>.create`.
        #[arg(long)]
        entry: Option<String>,
        #[arg(last = true)]
        arguments: Vec<OsString>,
    },
    /// Run a benchmark from bench/nupp.
    Bench {
        name: String,
        #[arg(last = true)]
        arguments: Vec<OsString>,
    },
    /// Format every supported source language in place.
    ///
    /// Naming paths narrows this to the suffix-dispatched formatters over
    /// those paths; with none, Cargo and the Nupp compiler format their own
    /// trees too.
    Format { paths: Vec<String> },
    /// Report sources that are not formatted.
    FormatCheck { paths: Vec<String> },
    /// Check, format, test, validate docs/Rust, and run headless smokes (SDK required).
    Verify,
    /// List the packaging presets and what each one produces.
    Presets,
    /// Build and install a relocatable release tree into out/package.
    Package {
        #[arg(long)]
        preset: Option<Preset>,
        /// A component target to install, repeatable. Defaults to the showcase
        /// and the native smoke component.
        #[arg(long = "component")]
        components: Vec<String>,
    },
    /// Verify that an installed package is complete and relocatable.
    CheckPackage {
        #[arg(default_value = package::OUTPUT)]
        prefix: PathBuf,
    },
    /// Install a clean release, check it, and run it from a relocated copy.
    TestPackage {
        #[arg(long)]
        preset: Option<Preset>,
    },
    /// Build the documentation site into out/docs.
    Docs {
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Verify documentation metadata, pages, and links by rendering the site.
    DocsCheck,
    /// Serve the documentation site, rebuilding it on a change.
    DocsDev {
        #[arg(long, default_value_t = 5173)]
        port: u16,
    },
    /// Remove Cargo and build output.
    Clean,
}

fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let root = repository_root(&env::current_dir()?)?;
    match arguments.command {
        Task::Deps => deps(&root)?,
        Task::Targets => nupp::targets(&root)?,
        Task::Check => nupp::check(&root)?,
        Task::Test => nupp::test(&root)?,
        Task::Build { target } => {
            let output = nupp::build(&root, &target)?;
            println!("built {} into {}", target, output.display());
        }
        Task::Run {
            target,
            entry,
            arguments,
        } => nupp::host(&root, &target, entry.as_deref(), &arguments)?,
        Task::Bench { name, arguments } => nupp::benchmark(&root, &name, &arguments)?,
        Task::Format { paths } => formatting::apply(&root, &paths, false)?,
        Task::FormatCheck { paths } => formatting::apply(&root, &paths, true)?,
        Task::Verify => nupp::verify(&root)?,
        Task::Presets => package::list(),
        Task::Package { preset, components } => {
            let preset = preset.map_or_else(package::host_default, Ok)?;
            let prefix = package::install(&root, preset, &components)?;
            println!("installed {}", prefix.display());
        }
        Task::CheckPackage { prefix } => package::check(&root.join(prefix))?,
        Task::TestPackage { preset } => {
            package::test(&root, preset.map_or_else(package::host_default, Ok)?)?;
        }
        Task::Docs { out } => {
            let output = out.unwrap_or_else(|| root.join(docs::OUTPUT));
            docs::build(&root, &output)?;
            println!("built {}", output.display());
        }
        Task::DocsCheck => docs::check(&root)?,
        Task::DocsDev { port } => docs::serve(&root, port)?,
        Task::Clean => {
            for path in [root.join("out"), root.join("target")] {
                if path.exists() {
                    fs::remove_dir_all(path)?;
                }
            }
        }
    }
    Ok(())
}

/// Installs what a checkout needs and cannot build for itself, then reports
/// what it still has to be given.
///
/// Two of the four are formatters, which Homebrew carries and no version here
/// pins. The other two are the Rust toolchain, which `rust-toolchain.toml`
/// names and `rustup` fetches on the first build, and the Nupp compiler, which
/// has no formula: this tree is developed against a compiler newer than the
/// published release, so a checkout beside this one is the supported answer
/// and `NUPP` is the override. So `deps` installs what it can and says plainly
/// where the compiler resolved, rather than reporting a checkout ready that is
/// missing the one tool every other command starts with.
fn deps(root: &std::path::Path) -> Result<()> {
    if std::env::consts::OS != "macos" {
        anyhow::bail!("automatic dependency installation is currently macOS-only");
    }
    command::run("brew", ["install", "stylua", "prettier"], root)?;
    match nupp::compiler(root) {
        Ok(compiler) => println!("Nupp compiler: {}", compiler.display()),
        Err(error) => println!("{error:#}"),
    }
    Ok(())
}
