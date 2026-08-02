use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tecs_build_support::abi;
use tecs_build_support::cdef::{self, Options as CdefOptions};
use tecs_build_support::command;
use tecs_build_support::docs;
use tecs_build_support::formatting;
use tecs_build_support::package::{self, Options as PackageCheckOptions};
use tecs_build_support::payload::{self, Root};
use tecs_build_support::presets::{host_default, Preset, PRESETS};
use tecs_build_support::product;
use tecs_build_support::registry::{self, Options as RegistryOptions};
use tecs_build_support::repository_root;
use tecs_build_support::{staging, tooling};

mod example_assets;

#[derive(Debug, Parser)]
#[command(name = "cargo xtask", about = "Build and maintain Tecs")]
struct Arguments {
    #[command(subcommand)]
    command: Task,
}

#[derive(Debug, Subcommand)]
enum Task {
    /// List the supported target configurations.
    Presets,
    /// Install platform and repository development dependencies.
    Deps,
    /// Install the pinned Teal, Cerulean, tealdoc, and Busted tools locally.
    DevTools,
    /// Build the selected target configuration.
    Build {
        #[arg(long)]
        preset: Option<Preset>,
    },
    /// Type-check engine, CLI, benchmark, and example Teal sources.
    Check,
    /// Run the Rust workspace tests and complete spec suite.
    Test {
        #[arg(long)]
        preset: Option<Preset>,
    },
    /// Run a named example through the native SDL host.
    Example {
        name: String,
        #[arg(long)]
        preset: Option<Preset>,
        #[arg(last = true)]
        arguments: Vec<OsString>,
    },
    /// Fetch a pinned large example asset into the ignored local cache.
    Fetch {
        /// Asset name. Supports `sponza` and `bistro`.
        name: String,
    },
    /// Build the shader pack consumed by release packages.
    Shaders {
        #[arg(long)]
        preset: Option<Preset>,
    },
    /// Run a native-host benchmark.
    Bench {
        name: String,
        #[arg(long)]
        preset: Option<Preset>,
        #[arg(last = true)]
        arguments: Vec<OsString>,
    },
    /// Build and install a relocatable release tree into out/package.
    Package {
        #[arg(long)]
        preset: Preset,
    },
    /// Verify a freshly installed release package and its headless runtime.
    TestPackage {
        #[arg(long)]
        preset: Preset,
    },
    /// Build the one-file macOS command-line tool into out/single.
    Single,
    /// Remove Cargo and product build output.
    Clean,
    /// Format all supported source languages in place.
    Format { paths: Vec<String> },
    /// Report files that are not formatted.
    FormatCheck { paths: Vec<String> },
    /// Verify generated LuaJIT records against the C ABI.
    AbiCheck {
        #[arg(long)]
        generated: Option<PathBuf>,
        #[arg(long)]
        preset: Option<Preset>,
    },
    /// Verify that an installed package is relocatable and complete.
    CheckPackage {
        prefix: PathBuf,
        #[arg(long)]
        allow_compiler: bool,
        #[arg(long)]
        teal_compiler: Option<PathBuf>,
        #[arg(long)]
        teal_types: Option<PathBuf>,
    },
    /// Verify documentation metadata, pages, and links by rendering the site.
    DocsCheck,
    /// Serve the documentation site, rebuilding it on a change.
    DocsDev {
        #[arg(long, default_value_t = 5173)]
        port: u16,
    },
    /// Build the documentation site into out/docs.
    DocsBuild,
    /// Internal deterministic generators used by the product build.
    Generate {
        #[command(subcommand)]
        generator: Generator,
    },
}

#[derive(Debug, Subcommand)]
enum Generator {
    /// Generate LuaJIT declarations and constants from C headers.
    Cdef {
        #[arg(long, default_value = "cc")]
        compiler: String,
        #[arg(long = "header")]
        headers: Vec<String>,
        #[arg(long = "include")]
        includes: Vec<PathBuf>,
        #[arg(long = "define")]
        defines: Vec<String>,
        #[arg(long = "keep")]
        keeps: Vec<String>,
        #[arg(long = "need")]
        needed: Vec<String>,
        #[arg(long = "define-prefix")]
        define_prefixes: Vec<String>,
        #[arg(long = "defines-out")]
        constants_output: Option<PathBuf>,
        #[arg(long)]
        out: PathBuf,
    },
    /// Pack content roots into the single-file payload.
    Payload {
        #[arg(long = "root", value_parser = parse_root)]
        roots: Vec<Root>,
        #[arg(long)]
        out: PathBuf,
    },
    /// Generate a native function-pointer registry.
    Registry {
        #[arg(long)]
        cdef: PathBuf,
        #[arg(long)]
        name: String,
        #[arg(long = "struct")]
        struct_name: String,
        #[arg(long, default_value = "")]
        prefix: String,
        #[arg(long = "header")]
        headers: Vec<String>,
        #[arg(long = "source-out")]
        source_output: PathBuf,
        #[arg(long = "cdef-out")]
        cdef_output: PathBuf,
    },
    /// Stage the pinned Teal and Cerulean tools.
    Tools {
        #[arg(long)]
        vendor: PathBuf,
        /// The repository's own Teal sources, which carry the declarations no
        /// rock provides.
        #[arg(long)]
        source: PathBuf,
        #[arg(long)]
        licenses: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Generate the CLI's formatter and revision table.
    Tooling {
        #[arg(long = "teal-ref")]
        teal: String,
        #[arg(long = "cerulean-ref")]
        cerulean: String,
        #[arg(long)]
        out: PathBuf,
    },
}

fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let root = repository_root(&env::current_dir()?)?;
    match arguments.command {
        Task::Presets => {
            for preset in PRESETS {
                println!(
                    "{:<24} {:<30} {:?}",
                    preset.name, preset.rust_target, preset.dependencies
                );
            }
        }
        Task::Deps => {
            if std::env::consts::OS != "macos" {
                anyhow::bail!("automatic dependency installation is currently macOS-only");
            }
            command::run(
                "brew",
                [
                    "install",
                    "cmake",
                    "pkg-config",
                    "sdl3",
                    "sdl3_mixer",
                    "sdl3_ttf",
                    "luajit",
                    "clang-format",
                    "stylua",
                    "prettier",
                    "luarocks",
                ],
                &root,
            )?;
            install_dev_tools(&root)?;
            // Homebrew carries one version of each formula and it is the
            // current one, so four of the packages above are pinned by this
            // tree and unpinnable through `brew`: SDL3, SDL3_mixer, SDL3_ttf,
            // and LuaJIT. Installing them can therefore leave the
            // machine outside the tree's own version gate, which is what a
            // build fails on next. So `deps` runs that gate itself, here,
            // while whoever ran it is still reading the output and knows what
            // moved.
            product::check_system_dependencies(host_default()?).map_err(|error| {
                error.context(
                    "`cargo xtask deps` installed the current Homebrew version of \
                     each system dependency, and Homebrew carries no older one",
                )
            })?;
        }
        Task::DevTools => install_dev_tools(&root)?,
        Task::Build { preset } => {
            let preset = preset.map_or_else(host_default, Ok)?;
            let executable = product::build(&root, preset)?;
            println!("built {}", executable.display());
        }
        Task::Check => product::check(&root)?,
        Task::Test { preset } => {
            product::test(&root, preset.map_or_else(host_default, Ok)?)?;
        }
        Task::Example {
            name,
            preset,
            arguments,
        } => {
            example_assets::require_for_example(&root, &name)?;
            product::run_example(
                &root,
                preset.map_or_else(host_default, Ok)?,
                &name,
                &arguments,
            )?;
        }
        Task::Fetch { name } => example_assets::fetch(&root, &name)?,
        Task::Shaders { preset } => {
            product::shaders(&root, preset.map_or_else(host_default, Ok)?)?;
        }
        Task::Bench {
            name,
            preset,
            arguments,
        } => {
            product::benchmark(
                &root,
                preset.map_or_else(host_default, Ok)?,
                &name,
                &arguments,
            )?;
        }
        Task::Package { preset } => {
            let prefix = product::install_package(&root, preset)?;
            println!("installed {}", prefix.display());
        }
        Task::TestPackage { preset } => product::test_package(&root, preset)?,
        Task::Single => {
            let executable = product::single(&root)?;
            println!("built {}", executable.display());
        }
        Task::Clean => {
            for path in [root.join("out"), root.join("target")] {
                if path.exists() {
                    fs::remove_dir_all(path)?;
                }
            }
        }
        Task::Format { paths } => {
            formatting::apply(&root, &default_paths(paths), false)?;
        }
        Task::FormatCheck { paths } => {
            formatting::apply(&root, &default_paths(paths), true)?;
        }
        Task::AbiCheck { generated, preset } => {
            if let Some(generated) = generated {
                abi::check(&root, &generated)?;
            } else {
                product::abi_check(&root, preset.map_or_else(host_default, Ok)?)?;
            }
        }
        Task::CheckPackage {
            prefix,
            allow_compiler,
            teal_compiler,
            teal_types,
        } => {
            let teal_compiler = teal_compiler.unwrap_or_else(|| root.join("vendor/bin/tl"));
            let teal_types = teal_types.unwrap_or_else(|| root.join("vendor/share/lua/5.1"));
            package::check(&PackageCheckOptions {
                prefix: &prefix,
                allow_compiler,
                teal_compiler: &teal_compiler,
                teal_types: Some(&teal_types),
            })?;
        }
        Task::DocsCheck => docs::check(&root)?,
        Task::DocsDev { port } => docs::serve(&root, port)?,
        Task::DocsBuild => {
            let output = root.join(docs::OUTPUT);
            docs::build(&root, &output)?;
            println!("built {}", output.display());
        }
        Task::Generate { generator } => match generator {
            Generator::Cdef {
                compiler,
                headers,
                includes,
                defines,
                keeps,
                needed,
                define_prefixes,
                constants_output,
                out,
            } => cdef::generate(&CdefOptions {
                compiler: &compiler,
                headers: &headers,
                include_directories: &includes,
                defines: &defines,
                keeps: &keeps,
                needed: &needed,
                define_prefixes: &define_prefixes,
                constants_output: constants_output.as_deref(),
                output: &out,
            })?,
            Generator::Payload { roots, out } => payload::generate(&roots, &out)?,
            Generator::Registry {
                cdef,
                name,
                struct_name,
                prefix,
                headers,
                source_output,
                cdef_output,
            } => {
                registry::generate(&RegistryOptions {
                    cdef: &cdef,
                    name: &name,
                    struct_name: &struct_name,
                    prefix: &prefix,
                    headers: &headers,
                    source_output: &source_output,
                    cdef_output: &cdef_output,
                })?;
            }
            Generator::Tools {
                vendor,
                source,
                licenses,
                out,
            } => {
                staging::tools(&vendor, &source, &licenses, &out)?;
            }
            Generator::Tooling {
                teal,
                cerulean,
                out,
            } => tooling::generate(&teal, &cerulean, &out)?,
        },
    }
    Ok(())
}

fn default_paths(paths: Vec<String>) -> Vec<String> {
    if paths.is_empty() {
        vec![".".to_owned()]
    } else {
        paths
    }
}

fn parse_root(value: &str) -> Result<Root, String> {
    let Some((prefix, directory)) = value.split_once('=') else {
        return Err("expected PREFIX=DIRECTORY".to_owned());
    };
    Ok(Root {
        prefix: prefix.to_owned(),
        directory: directory.into(),
    })
}

fn install_dev_tools(root: &std::path::Path) -> Result<()> {
    let status = std::process::Command::new(root.join("scripts/install-dev-tools.sh"))
        .env("TL_REF", product::TEAL_REVISION)
        .env("CERULEAN_REF", product::CERULEAN_REVISION)
        .env("TEALDOC_REF", product::TEALDOC_REVISION)
        .env("BUSTED_VERSION", product::BUSTED_VERSION)
        .env("LUAJIT_TYPES_VERSION", product::LUAJIT_TYPES_VERSION)
        .env("BUSTED_TYPES_VERSION", product::BUSTED_TYPES_VERSION)
        .env("LUASSERT_TYPES_VERSION", product::LUASSERT_TYPES_VERSION)
        .env("SCINTILLUA_REF", product::SCINTILLUA_REVISION)
        .current_dir(root)
        .status()?;
    if !status.success() {
        anyhow::bail!("development tool installation exited with {status}");
    }

    // The LuaRocks launcher has previously installed successfully while
    // dropping the checkout-local package path before Busted starts. Exercise
    // the launcher itself so `dev-tools` cannot report a checkout ready in that
    // state.
    let status = std::process::Command::new(root.join("vendor/bin/busted"))
        .arg("--version")
        .current_dir(root)
        .status()?;
    if !status.success() {
        anyhow::bail!("installed Busted launcher exited with {status}");
    }
    Ok(())
}
